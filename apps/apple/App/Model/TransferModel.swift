import Foundation
import Observation
import OSLog
import XDRemuxTransfer
#if os(iOS)
import UIKit
#endif

/// UI state over one `TransferService` (LocalSend v2). The service runs
/// only while the transfer sheet is open: receiving binds a LAN port, so
/// it is an explicit, visible state, never something left on in the
/// background. Fingerprints are confirmed per session; nothing is sent to
/// a peer the user has not looked at.
@MainActor @Observable
final class TransferModel {
    struct Progress: Equatable { var bytes: UInt64 = 0; var total: UInt64 = 0 }

    private(set) var service: TransferService?
    private(set) var isReceiving = false
    private(set) var ready: TransferReady?
    private(set) var isBusy = false
    var error: String?

    var interfaces: [LocalInterface] = []
    var selectedInterface: String?
    var port = 53319

    private(set) var discovering = false
    private(set) var discoveryError: String?
    private(set) var peers: [DiscoveredPeer] = []
    var manualAddress = ""
    private(set) var selectedPeer: TransferPeer?
    private(set) var selectedAlias: String?
    /// Set when `connect` probed a peer the user has not yet confirmed.
    var pendingConfirmation: TransferPeer?
    private var confirmed: Set<String> = []

    private(set) var offers: [TransferOffer] = []
    private(set) var transfers: [TransferSummary] = []
    private(set) var progress: [String: [String: Progress]] = [:]
    private(set) var inbox: [TransferReceipt] = []

    private let root: URL
    private let log = Logger(subsystem: "io.github.beetman.xdremux.swiftui", category: "transfer")
    private var eventTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    init(root: URL) {
        self.root = root
    }

    var alias: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    var isRunning: Bool { service != nil }

    func refreshInterfaces() {
        interfaces = LocalNetwork.ipv4Interfaces()
        if selectedInterface == nil || !interfaces.contains(where: { $0.address == selectedInterface }) {
            selectedInterface = interfaces.first?.address
        }
    }

    // MARK: Lifecycle

    /// Send-only service on loopback; nothing is reachable from the LAN.
    func ensureLocal() async throws {
        if service != nil { return }
        try await start(bind: "127.0.0.1:0", receiving: false)
    }

    /// Binds the chosen interface so other devices can send to us.
    func startReceiving() async {
        log.info("startReceiving interface=\(self.selectedInterface ?? "nil", privacy: .public) port=\(self.port)")
        guard let address = selectedInterface else {
            error = L("没有可用的局域网地址，请连接 Wi-Fi 后重试。")
            return
        }
        await stop()
        do {
            try await start(bind: "\(address):\(port)", receiving: true)
            await refreshDiscovery()
        } catch {
            log.error("startReceiving failed: \(Self.code(error), privacy: .public)")
            self.error = Self.describe(error)
        }
    }

    func stopReceiving() async {
        await stop()
    }

    private func start(bind: String, receiving: Bool) async throws {
        let service = TransferService()
        isBusy = true
        defer { isBusy = false }
        log.info("starting transfer service bind=\(bind, privacy: .public) root=\(self.root.path, privacy: .public)")
        let ready = try await service.start(.init(root: root, bind: bind, alias: alias))
        log.info("transfer service ready at \(ready.address, privacy: .public)")
        self.service = service
        self.ready = ready
        self.isReceiving = receiving
        eventTask = Task { [weak self] in
            for await event in await service.events {
                await self?.handle(event)
            }
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.refresh(discovery: true)
            }
        }
        await refresh(discovery: false)
    }

    func stop() async {
        refreshTask?.cancel(); refreshTask = nil
        eventTask?.cancel(); eventTask = nil
        if let service {
            await service.stop()
        }
        service = nil
        ready = nil
        isReceiving = false
        discovering = false
        peers = []
        offers = []
        transfers = []
        progress = [:]
        selectedPeer = nil
        selectedAlias = nil
        confirmed = []
    }

    // MARK: Discovery and peers

    func refreshDiscovery() async {
        guard let service, isReceiving else { return }
        do {
            apply(try await service.discoveryStart(interface: selectedInterface))
        } catch {
            discoveryError = Self.code(error)
            discovering = false
        }
    }

    private func apply(_ snapshot: DiscoverySnapshot) {
        discovering = snapshot.enabled
        discoveryError = snapshot.error
        peers = snapshot.enabled ? snapshot.peers : []
    }

    /// Probes `address` (`IP:port`), then asks for confirmation unless the
    /// fingerprint was confirmed earlier in this session.
    func connect(address: String, alias: String? = nil) async {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard Self.isAddress(trimmed) else { error = L("请输入对方的 IP:端口，例如 192.168.1.20:53317"); return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await ensureLocal()
            guard let service else { return }
            let peer = try await service.probe(address: trimmed)
            selectedAlias = alias
            if confirmed.contains(peer.fingerprint) {
                selectedPeer = peer
            } else {
                selectedPeer = nil
                pendingConfirmation = peer
            }
        } catch {
            self.error = Self.describe(error)
        }
    }

    func confirm(_ peer: TransferPeer) {
        confirmed.insert(peer.fingerprint)
        selectedPeer = peer
        pendingConfirmation = nil
    }

    func clearPeer() {
        selectedPeer = nil
        selectedAlias = nil
    }

    // MARK: Send

    func send(_ urls: [URL]) async {
        guard let peer = selectedPeer, confirmed.contains(peer.fingerprint) else {
            error = L("请先连接并确认对方设备。"); return
        }
        guard !urls.isEmpty else { error = L("没有可发送的文件。"); return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await ensureLocal()
            guard let service else { return }
            _ = try await service.send(peer: peer, paths: urls.map(\.path))
            await refresh(discovery: false)
        } catch {
            self.error = Self.describe(error)
        }
    }

    func retry(_ transfer: TransferSummary) async {
        guard let service, let peer = selectedPeer, confirmed.contains(peer.fingerprint),
              peer.fingerprint == transfer.peerFingerprint else {
            error = L("重试需要先重新连接并确认同一台设备。"); return
        }
        do {
            _ = try await service.retrySend(transferId: transfer.id, peer: peer)
            await refresh(discovery: false)
        } catch {
            self.error = Self.describe(error)
        }
    }

    func cancel(_ transfer: TransferSummary) async {
        guard let service else { return }
        do {
            try await service.cancel(transferId: transfer.id, direction: transfer.direction)
            await refresh(discovery: false)
        } catch {
            self.error = Self.describe(error)
        }
    }

    // MARK: Receive

    func decide(_ offer: TransferOffer, accept: Bool) async {
        guard let service else { return }
        do {
            try await service.decide(transferId: offer.sessionId, accept: accept)
            offers.removeAll { $0.id == offer.id }
            await refresh(discovery: false)
        } catch {
            self.error = Self.describe(error)
        }
    }

    /// Copies a received file into the library under its original name
    /// while holding the receipt lease, then releases it.
    func importReceipt(_ receipt: TransferReceipt, into library: LibraryModel) async {
        guard let service else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let lease = try await service.acquireReceipt(id: receipt.id)
            defer { Task { try? await service.releaseReceipt(leaseId: lease.leaseId) } }
            await library.importFile(at: URL(fileURLWithPath: lease.path), named: receipt.name)
        } catch {
            self.error = Self.describe(error)
        }
    }

    func deleteReceipt(_ receipt: TransferReceipt) async {
        guard let service else { return }
        do {
            try await service.deleteReceipt(id: receipt.id)
            inbox.removeAll { $0.id == receipt.id }
        } catch {
            self.error = Self.describe(error)
        }
    }

    // MARK: State

    private func handle(_ event: TransferEvent) {
        switch event.kind {
        case "offer":
            if let offer = event.offer, !offers.contains(where: { $0.id == offer.id }) { offers.append(offer) }
        case "accepted", "session_ended":
            if let id = event.sessionId { offers.removeAll { $0.id == id } }
            Task { await refresh(discovery: false) }
        case "progress":
            if let t = event.transferId, let f = event.fileId {
                progress[t, default: [:]][f] = Progress(bytes: event.bytes ?? 0, total: event.total ?? 0)
            }
        case "committed":
            if let receipt = event.receipt, !inbox.contains(where: { $0.id == receipt.id }) { inbox.insert(receipt, at: 0) }
        case "receipt_deleted":
            if let id = event.receiptId { inbox.removeAll { $0.id == id } }
        case "sent", "failed", "send_started", "prepared", "file_sent":
            Task { await refresh(discovery: false) }
        case "stopped", "fatal":
            Task { await stop() }
            if event.kind == "fatal" { error = L("传输服务异常停止：\(event.code ?? "unknown")") }
        default:
            break
        }
    }

    private func refresh(discovery: Bool) async {
        guard let service else { return }
        do {
            transfers = try await service.snapshot().transfers.sorted { $0.id > $1.id }
            let receipts = try await service.receipts()
            inbox = receipts.sorted { $0.id > $1.id }
            if discovery, isReceiving { apply(try await service.discoveryStatus()) }
        } catch TransferError.closed {
            // The service went away underneath us; the stopped event handles it.
        } catch {
            self.error = Self.describe(error)
        }
    }

    func totalProgress(for transfer: TransferSummary) -> Double? {
        guard let files = progress[transfer.id], !files.isEmpty else { return nil }
        let total = files.values.reduce(0) { $0 + $1.total }
        guard total > 0 else { return nil }
        return Double(files.values.reduce(0) { $0 + $1.bytes }) / Double(total)
    }

    // MARK: Helpers

    static func isAddress(_ text: String) -> Bool {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port) else { return false }
        let octets = parts[0].split(separator: ".")
        return octets.count == 4 && octets.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    static func code(_ error: Error) -> String {
        switch error {
        case TransferError.code(let code), TransferError.startFailed(let code): return code
        case TransferError.status(let s): return "status_\(s)"
        case TransferError.closed: return "closed"
        case TransferError.malformed: return "malformed"
        case TransferError.unsupportedABI: return "unsupported_abi"
        default: return String(describing: error)
        }
    }

    /// Stable core codes → sentences. Unknown codes are shown as-is.
    static func describe(_ error: Error) -> String {
        switch code(error) {
        case "port_in_use": return L("端口已被占用，换一个端口再试。")
        case "identity_mismatch": return L("对方设备的证书与之前确认的不一致，请重新连接并核对指纹。")
        case "discovery_unavailable": return L("自动发现不可用，请手动输入对方的 IP:端口。")
        case "network": return L("连不上对方设备，确认两台设备在同一个 Wi-Fi 下，且对方已开启接收。")
        case "declined", "rejected": return L("对方拒绝了这次传输。")
        case "pin_required", "invalid_pin": return L("对方要求 PIN 码。")
        case "closed": return L("传输服务已停止。")
        case "no_space": return L("存储空间不足。")
        case let code: return L("传输失败：\(code)")
        }
    }

    static func phaseText(_ t: TransferSummary) -> String {
        switch t.phase {
        case .preparing: return L("准备中…")
        case .pending: return L("等待对方确认…")
        case .accepted: return L("已接受")
        case .transferring: return L("传输中")
        case .completed: return L("已完成")
        case .failed: return t.error.map { L("失败：\($0)") } ?? L("失败")
        }
    }
}
