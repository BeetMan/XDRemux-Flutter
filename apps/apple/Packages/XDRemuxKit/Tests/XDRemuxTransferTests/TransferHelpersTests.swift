import XCTest
@testable import XDRemuxTransfer

final class TransferHelpersTests: XCTestCase {
    func testAliasCleaning() {
        XCTAssertNil(TransferAlias.clean(nil))
        XCTAssertNil(TransferAlias.clean("   "))
        XCTAssertNil(TransferAlias.clean("\u{1}\u{7f}"))
        XCTAssertEqual(TransferAlias.clean("  My\u{0}Phone\n "), "MyPhone")
        XCTAssertEqual(TransferAlias.clean(String(repeating: "x", count: 100))?.count, 64)
    }

    func testLivePhotoPairing() {
        let names = ["IMG_0001.HEIC", "IMG_0001.mov", "IMG_0002.heic", "clip.mov"]
        XCTAssertEqual(LivePhotoPairing.pairedMovie(for: "IMG_0001.HEIC", in: names), "IMG_0001.mov")
        XCTAssertNil(LivePhotoPairing.pairedMovie(for: "IMG_0002.heic", in: names))
        XCTAssertNil(LivePhotoPairing.pairedMovie(for: "clip.mov", in: names))
        XCTAssertTrue(LivePhotoPairing.isPairedMovie("IMG_0001.MOV", in: names))
        XCTAssertFalse(LivePhotoPairing.isPairedMovie("clip.mov", in: names))
        XCTAssertFalse(LivePhotoPairing.isPairedMovie("IMG_0002.heic", in: names))
    }

    func testSubnetTargets() {
        let targets = SubnetScan.targets(own: ["192.168.1.20", "10.0.0.5", "fe80::1", "192.168.1.30"])
        // Two /24s, 254 hosts each minus the three own addresses, two ports.
        XCTAssertEqual(targets.count, (254 * 2 - 3) * 2)
        XCTAssertFalse(targets.contains { $0.host == "192.168.1.20" || $0.host == "10.0.0.5" })
        XCTAssertEqual(targets.first, SubnetScan.Target(host: "192.168.1.1", port: 53319))
        XCTAssertEqual(targets[1], SubnetScan.Target(host: "192.168.1.1", port: 53317))
        XCTAssertTrue(SubnetScan.targets(own: ["not-an-ip"]).isEmpty)
    }

    func testOpenPortsFindsLoopbackListener() async throws {
        // A listener on loopback answers; a closed port does not.
        let receiver = TransferService()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("xdremux-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let ready = try await receiver.start(.init(root: base.appendingPathComponent("rx"), bind: "127.0.0.1:0", alias: "rx"))
        defer { Task { await receiver.stop() } }
        let port = UInt16(ready.address.split(separator: ":").last!)!
        let hits = await SubnetScan.openPorts([SubnetScan.Target(host: "127.0.0.1", port: port),
                                               SubnetScan.Target(host: "127.0.0.1", port: 1)])
        XCTAssertEqual(hits, [SubnetScan.Target(host: "127.0.0.1", port: port)])
        await receiver.stop()
    }
}
