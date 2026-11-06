import Foundation
import XCTest
@testable import XDRemuxTransfer

/// Two services on loopback: probe, confirm, send one file, accept the
/// offer, wait for the receipt, read the bytes back under a lease.
final class LoopbackTransferTests: XCTestCase {
    func testABIVersion() {
        let v = TransferBridge.abiVersion()
        XCTAssertEqual(v.major, 1)
        XCTAssertGreaterThanOrEqual(v.minor, 3)
    }

    func testLoopbackRoundTrip() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("xdremux-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let source = base.appendingPathComponent("IMG_test.heic")
        try payload.write(to: source)

        let receiver = TransferService()
        let sender = TransferService()
        let ready = try await receiver.start(.init(root: base.appendingPathComponent("rx"), bind: "127.0.0.1:0", alias: "rx"))
        _ = try await sender.start(.init(root: base.appendingPathComponent("tx"), bind: "127.0.0.1:0", alias: "tx"))

        // Receiver side: accept the offer when it arrives, collect the receipt.
        let accepted = Task { () -> TransferReceipt in
            for await event in await receiver.events {
                if event.kind == "offer", let offer = event.offer {
                    XCTAssertEqual(offer.files.first?.name, "IMG_test.heic")
                    try await receiver.decide(transferId: offer.sessionId, accept: true)
                }
                if event.kind == "committed", let receipt = event.receipt { return receipt }
                if event.kind == "failed" { XCTFail("receive failed: \(event.code ?? "?")") }
            }
            throw TransferError.closed
        }

        let peer = try await sender.probe(address: ready.address)
        XCTAssertEqual(peer.fingerprint, ready.fingerprint)
        let transferId = try await sender.send(peer: peer, paths: [source.path])
        XCTAssertFalse(transferId.isEmpty)

        let receipt = try await accepted.value
        XCTAssertEqual(receipt.size, UInt64(payload.count))

        let lease = try await receiver.acquireReceipt(id: receipt.id)
        let received = try Data(contentsOf: URL(fileURLWithPath: lease.path))
        XCTAssertEqual(received, payload)
        try await receiver.releaseReceipt(leaseId: lease.leaseId)

        // Sender history shows the completed job.
        var done = false
        for _ in 0..<50 where !done {
            let page = try await sender.snapshot()
            done = page.transfers.contains { $0.id == transferId && $0.phase == .completed }
            if !done { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertTrue(done)

        let receipts = try await receiver.receipts()
        XCTAssertTrue(receipts.contains { $0.id == receipt.id })
        try await receiver.deleteReceipt(id: receipt.id)

        await sender.stop()
        await receiver.stop()
    }
}

/// Opt-in: `XDREMUX_TRANSFER_PEER=192.168.1.20:53319 XDREMUX_TRANSFER_FILE=/path/x.heic swift test --filter ExternalPeer`
/// sends one real file (or several, `:`-separated, e.g. a Live Photo pair)
/// to a device that is receiving (the app on a phone or simulator, or
/// LocalSend). Accept the offer on that device; the test waits up to two
/// minutes for the ACK.
final class ExternalPeerTests: XCTestCase {
    func testSendToExternalPeer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["XDREMUX_TRANSFER_PEER"], let file = env["XDREMUX_TRANSFER_FILE"] else {
            throw XCTSkip("set XDREMUX_TRANSFER_PEER and XDREMUX_TRANSFER_FILE")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xdremux-transfer-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sender = TransferService()
        _ = try await sender.start(.init(root: root.appendingPathComponent("tx"), alias: "swift-test"))
        let peer = try await sender.probe(address: address)
        print("peer fingerprint:", peer.groupedFingerprint)
        let id = try await sender.send(peer: peer, paths: file.split(separator: ":").map(String.init))
        var final: TransferSummary?
        for _ in 0..<1200 where final == nil {
            let page = try await sender.snapshot()
            if let t = page.transfers.first(where: { $0.id == id }), t.phase.isTerminal { final = t }
            else { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertEqual(final?.phase, .completed, "error: \(final?.error ?? "timeout")")
        await sender.stop()
    }
}

/// Opt-in: `XDREMUX_TRANSFER_BIND=192.168.1.20:53319 swift test --filter BindTests`
/// binds a LAN address the way the app's receive toggle does.
final class BindTests: XCTestCase {
    func testBindRequestedAddress() async throws {
        guard let bind = ProcessInfo.processInfo.environment["XDREMUX_TRANSFER_BIND"] else {
            throw XCTSkip("set XDREMUX_TRANSFER_BIND")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xdremux-transfer-bind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = TransferService()
        let ready = try await service.start(.init(root: root.appendingPathComponent("rx"), bind: bind, alias: "bind-test"))
        print("ready:", ready.address, ready.fingerprint)
        XCTAssertEqual(ready.address, bind)
        let discovery = try await service.discoveryStart()
        print("discovery:", discovery.enabled, discovery.error ?? "-", discovery.peers.count)
        await service.stop()
    }
}

/// Opt-in counterpart of `ExternalPeerTests`: `XDREMUX_TRANSFER_RECEIVE=192.168.1.20:53317 swift test --filter ExternalReceiver`
/// receives on that address (a Mac standing in for a second device),
/// accepts every offer, and copies each received file into
/// `XDREMUX_TRANSFER_OUT` (default: a temporary folder, printed). It stops
/// after `XDREMUX_TRANSFER_WAIT` seconds (default 180). Connect to it from
/// the app by its IP:port; it prints its fingerprint for the confirmation.
final class ExternalReceiverTests: XCTestCase {
    func testReceiveFromExternalPeer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let bind = env["XDREMUX_TRANSFER_RECEIVE"] else {
            throw XCTSkip("set XDREMUX_TRANSFER_RECEIVE=ip:port to run")
        }
        let wait = Double(env["XDREMUX_TRANSFER_WAIT"] ?? "") ?? 180
        let out = URL(fileURLWithPath: env["XDREMUX_TRANSFER_OUT"]
                      ?? FileManager.default.temporaryDirectory.appendingPathComponent("xdremux-received-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xdremux-receiver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let receiver = TransferService()
        let ready = try await receiver.start(.init(root: root, bind: bind, alias: "swift test receiver"))
        print("receiving at \(ready.address) fingerprint \(ready.fingerprint); files go to \(out.path)")

        let deadline = Date().addingTimeInterval(wait)
        let pump = Task {
            for await event in await receiver.events {
                switch event.kind {
                case "offer":
                    if let offer = event.offer {
                        print("offer from \(offer.alias): \(offer.files.map(\.name))")
                        try await receiver.decide(transferId: offer.sessionId, accept: true)
                    }
                case "committed":
                    if let receipt = event.receipt {
                        let lease = try await receiver.acquireReceipt(id: receipt.id)
                        let destination = out.appendingPathComponent(receipt.name)
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.copyItem(at: URL(fileURLWithPath: lease.path), to: destination)
                        try await receiver.releaseReceipt(leaseId: lease.leaseId)
                        print("received \(receipt.name) (\(receipt.size) bytes)")
                    }
                case "failed":
                    print("receive failed: \(event.code ?? "?")")
                default:
                    break
                }
            }
        }
        while Date() < deadline { try await Task.sleep(for: .seconds(1)) }
        pump.cancel()
        await receiver.stop()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        print("done; received \(names.sorted())")
    }
}
