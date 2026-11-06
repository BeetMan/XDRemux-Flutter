import Foundation

/// One running transfer service (LocalSend v2 over mTLS) behind the C ABI.
///
/// `start` creates the native handle and runs a poll loop that correlates
/// `result` records with the awaiting command, publishes core events on
/// `events`, and notices the stopped phase. Every public command returns
/// only after the core produced its result; none of them completes before
/// the operation is actually done. Files never cross this layer: send takes
/// paths, receive publishes receipts whose data the caller copies out under
/// a lease.
public actor TransferService {
    public struct Config: Sendable {
        /// App-private directory; its parent must exist. The core keeps the
        /// certificate, staging and the inbox under it.
        public var root: URL
        /// `127.0.0.1:0` for send-only, `<lan-ip>:<port>` to receive.
        public var bind: String
        public var alias: String
        public var pin: String?

        public init(root: URL, bind: String = "127.0.0.1:0", alias: String, pin: String? = nil) {
            self.root = root
            self.bind = bind
            self.alias = alias
            self.pin = pin
        }
    }

    public enum Phase: Int, Sendable { case starting = 0, running, stopping, stopped }

    public let events: AsyncStream<TransferEvent>
    private let eventSink: AsyncStream<TransferEvent>.Continuation

    public private(set) var ready: TransferReady?
    public private(set) var phase: Phase = .stopped

    private let bridge = TransferBridge()
    private var loop: Task<Void, Never>?
    private var pending: [UInt64: CheckedContinuation<Data, Error>] = [:]
    private var startWaiter: CheckedContinuation<TransferReady, Error>?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {
        (events, eventSink) = AsyncStream.makeStream(of: TransferEvent.self, bufferingPolicy: .bufferingNewest(512))
    }

    // MARK: Lifecycle

    public func start(_ config: Config) async throws -> TransferReady {
        guard phase == .stopped, loop == nil else { throw TransferError.status(3) }
        try FileManager.default.createDirectory(at: config.root.deletingLastPathComponent(), withIntermediateDirectories: true)
        var json: [String: Any] = ["root": config.root.path, "bind": config.bind, "alias": config.alias]
        json["pin"] = config.pin ?? NSNull()
        try bridge.create(configJSON: JSONSerialization.data(withJSONObject: json))
        phase = .starting
        loop = Task { [weak self] in await self?.run() }
        return try await withCheckedThrowingContinuation { startWaiter = $0 }
    }

    /// Stops the listener, waits for the core to report `stopped`, releases
    /// the handle. Safe to call twice.
    public func stop() async {
        guard phase != .stopped, loop != nil else { return }
        phase = .stopping
        bridge.stop()
        await withCheckedContinuation { stopWaiters.append($0) }
    }

    private func run() async {
        var idle = 0
        while !Task.isCancelled {
            let drained: Bool
            do {
                drained = try handle(page: bridge.poll())
            } catch {
                finish()
                return
            }
            if phase == .stopped { return }
            idle = drained ? 0 : min(idle + 1, 6)
            // 50 ms while busy, backing off to 300 ms when nothing happens.
            try? await Task.sleep(for: .milliseconds(drained ? 20 : 50 * idle))
        }
    }

    /// Returns `true` when the page carried records.
    private func handle(page data: Data) throws -> Bool {
        guard let page = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TransferError.malformed }
        if let readyObject = page["ready"] as? [String: Any], ready == nil,
           let decoded = try? TransferJSON.decoder.decode(TransferReady.self, from: JSONSerialization.data(withJSONObject: readyObject)) {
            ready = decoded
        }
        let records = page["records"] as? [[String: Any]] ?? []
        for record in records {
            guard let body = record["body"] as? [String: Any], let kind = body["kind"] as? String else { continue }
            switch kind {
            case "ready":
                if let data = body["data"] as? [String: Any],
                   let decoded = try? TransferJSON.decoder.decode(TransferReady.self, from: JSONSerialization.data(withJSONObject: data)) {
                    ready = decoded
                    if phase == .starting { phase = .running }
                    startWaiter?.resume(returning: decoded)
                    startWaiter = nil
                }
            case "start_failed":
                let code = (body["error"] as? String) ?? "start_failed"
                startWaiter?.resume(throwing: TransferError.startFailed(code))
                startWaiter = nil
            case "result":
                guard let op = (body["operation_id"] as? NSNumber)?.uint64Value,
                      let waiter = pending.removeValue(forKey: op) else { continue }
                if let code = body["error"] as? String {
                    waiter.resume(throwing: TransferError.code(code))
                } else {
                    let payload = body["data"].map { $0 } ?? NSNull()
                    waiter.resume(returning: (try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])) ?? Data("null".utf8))
                }
            case "event":
                if let event = body["event"] as? [String: Any],
                   let data = try? JSONSerialization.data(withJSONObject: event),
                   let decoded = try? TransferJSON.decoder.decode(TransferEvent.self, from: data) {
                    eventSink.yield(decoded)
                }
            case "resync_required":
                eventSink.yield(TransferEvent(kind: "resync"))
            case "fatal":
                eventSink.yield(TransferEvent(kind: "fatal", code: body["error"] as? String))
            default:
                break
            }
        }
        if let phaseValue = (page["phase"] as? NSNumber)?.intValue, phaseValue == Phase.stopped.rawValue {
            finish()
        } else if phase == .starting, (page["phase"] as? NSNumber)?.intValue == Phase.running.rawValue, let ready {
            phase = .running
            startWaiter?.resume(returning: ready)
            startWaiter = nil
        }
        return !records.isEmpty
    }

    private func finish() {
        guard phase != .stopped else { return }
        phase = .stopped
        bridge.release()
        for (_, waiter) in pending { waiter.resume(throwing: TransferError.closed) }
        pending.removeAll()
        startWaiter?.resume(throwing: TransferError.closed)
        startWaiter = nil
        eventSink.yield(TransferEvent(kind: "stopped"))
        for waiter in stopWaiters { waiter.resume() }
        stopWaiters.removeAll()
        loop?.cancel()
        loop = nil
    }

    // MARK: Commands

    private func command(_ fields: [String: Any]) async throws -> Data {
        guard phase == .running || phase == .starting else { throw TransferError.closed }
        let json = try JSONSerialization.data(withJSONObject: fields)
        let op = try bridge.submit(json)
        return try await withCheckedThrowingContinuation { pending[op] = $0 }
    }

    private func command<T: Decodable>(_ fields: [String: Any], as type: T.Type) async throws -> T {
        let data = try await command(fields)
        do { return try TransferJSON.decoder.decode(type, from: data) } catch { throw TransferError.malformed }
    }

    /// Reads the peer's certificate over HTTPS. Show the fingerprint and
    /// let the user confirm it before `send`; the core pins it afterwards.
    public func probe(address: String) async throws -> TransferPeer {
        try await command(["command": "probe", "address": address], as: TransferPeer.self)
    }

    private struct TransferID: Decodable { var transferId: String }

    public func send(peer: TransferPeer, paths: [String], pin: String? = nil) async throws -> String {
        var fields: [String: Any] = ["command": "send",
                                     "peer": ["address": peer.address, "fingerprint": peer.fingerprint],
                                     "paths": paths]
        fields["pin"] = pin ?? NSNull()
        return try await command(fields, as: TransferID.self).transferId
    }

    public func retrySend(transferId: String, peer: TransferPeer, pin: String? = nil) async throws -> String {
        var fields: [String: Any] = ["command": "retry_send", "transfer_id": transferId,
                                     "peer": ["address": peer.address, "fingerprint": peer.fingerprint]]
        fields["pin"] = pin ?? NSNull()
        return try await command(fields, as: TransferID.self).transferId
    }

    public func discoveryStart(interface: String? = nil) async throws -> DiscoverySnapshot {
        var fields: [String: Any] = ["command": "discovery_start"]
        fields["interface"] = interface ?? NSNull()
        return try await command(fields, as: DiscoverySnapshot.self)
    }

    public func discoveryStatus() async throws -> DiscoverySnapshot {
        try await command(["command": "discovery_status"], as: DiscoverySnapshot.self)
    }

    public func discoveryStop() async throws {
        _ = try await command(["command": "discovery_stop"])
    }

    public func decide(transferId: String, accept: Bool) async throws {
        _ = try await command(["command": "decide", "transfer_id": transferId, "accept": accept])
    }

    public func cancel(transferId: String, direction: TransferDirection) async throws {
        _ = try await command(["command": direction == .send ? "cancel_send" : "cancel_receive", "transfer_id": transferId])
    }

    public func snapshot(after: String? = nil, limit: Int = 64) async throws -> TransferSnapshotPage {
        var fields: [String: Any] = ["command": "snapshot", "limit": limit]
        if let after { fields["after"] = after }
        return try await command(fields, as: TransferSnapshotPage.self)
    }

    public func transfer(id: String, after: String? = nil, limit: Int = 64) async throws -> TransferDetail {
        var fields: [String: Any] = ["command": "transfer", "transfer_id": id, "limit": limit]
        if let after { fields["after"] = after }
        return try await command(fields, as: TransferDetail.self)
    }

    public func receipts(after: String? = nil, limit: Int = 64) async throws -> [TransferReceipt] {
        var fields: [String: Any] = ["command": "receipts", "limit": limit]
        if let after { fields["after"] = after }
        return try await command(fields, as: [TransferReceipt].self)
    }

    /// Protects the received file until `releaseReceipt`; copy it out in
    /// between. Never move or modify the leased path.
    public func acquireReceipt(id: String) async throws -> ReceiptLease {
        try await command(["command": "acquire_receipt", "receipt_id": id], as: ReceiptLease.self)
    }

    public func releaseReceipt(leaseId: UInt64) async throws {
        _ = try await command(["command": "release_receipt", "lease_id": leaseId])
    }

    public func deleteReceipt(id: String) async throws {
        _ = try await command(["command": "delete_receipt", "receipt_id": id])
    }
}
