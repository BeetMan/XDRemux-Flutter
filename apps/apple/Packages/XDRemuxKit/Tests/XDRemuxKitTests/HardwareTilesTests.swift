import XCTest
import XDRemuxModel
@testable import XDRemuxKit

final class HardwareTilesTests: XCTestCase {
    /// NAL unit types in an Annex-B stream with 4-byte start codes.
    private func nalTypes(_ data: Data) -> [Int] {
        var types: [Int] = []
        let bytes = [UInt8](data)
        var i = 0
        while i + 4 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                types.append(Int(bytes[i + 4] >> 1) & 0x3F)
                i += 4
            } else {
                i += 1
            }
        }
        return types
    }

    func testEncodesOneTileAsIDRWithParameterSets() throws {
        guard VideoToolboxTileEncoder.isAvailable else { throw XCTSkip("no hardware HEVC encoder on this machine") }
        let encoder = try VideoToolboxTileEncoder(width: 512, height: 512)
        // A gradient luma with flat chroma, like a gray gain map.
        var tile = [UInt8](repeating: 128, count: 512 * 512 * 3 / 2)
        for y in 0..<512 { for x in 0..<512 { tile[y * 512 + x] = UInt8((x + y) / 4) } }
        let stream = try tile.withUnsafeBytes { try encoder.encode($0) }
        let types = nalTypes(stream)
        XCTAssertTrue(types.contains(32), "VPS")
        XCTAssertTrue(types.contains(33), "SPS")
        XCTAssertTrue(types.contains(34), "PPS")
        XCTAssertTrue(types.contains { (16...21).contains($0) }, "IRAP slice, got \(types)")
        // A second tile from the same session still carries its parameter sets.
        let second = try tile.withUnsafeBytes { try encoder.encode($0) }
        XCTAssertTrue(nalTypes(second).contains(33))
        XCTAssertThrowsError(try Data(count: 10).withUnsafeBytes { try encoder.encode($0) })
    }

    func testApplicabilityGate() {
        var config = ConversionConfig()
        XCTAssertFalse(XDRemuxEngine.hardwareTilesApplicable(config))
        config.hardwareEncode = true
        XCTAssertEqual(XDRemuxEngine.hardwareTilesApplicable(config), VideoToolboxTileEncoder.isAvailable)
        config.applePhotographicStyles = true
        XCTAssertFalse(XDRemuxEngine.hardwareTilesApplicable(config))
    }

    /// Opt-in: converts the first .heic in `XDREMUX_SAMPLE_DIR` through the
    /// hardware path and verifies the output.
    func testHardwarePathOnRealSampleIfProvided() async throws {
        guard let dir = ProcessInfo.processInfo.environment["XDREMUX_SAMPLE_DIR"] else {
            throw XCTSkip("set XDREMUX_SAMPLE_DIR to a folder of ProXDR .heic files")
        }
        guard VideoToolboxTileEncoder.isAvailable else { throw XCTSkip("no hardware HEVC encoder") }
        let inputs = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.lowercased().hasSuffix(".heic") }.sorted()
        let input = try XCTUnwrap(inputs.first)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("xdremux-hw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var config = ConversionConfig()
        config.hardwareEncode = true
        let output = temp.appendingPathComponent("hw.heic").path
        let report = try await XDRemuxEngine.shared.convertHardwareTiles(
            input: (dir as NSString).appendingPathComponent(input), output: output, config: config)
        XCTAssertTrue(report.success)
        XCTAssertEqual(report.outputValid, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output))
        // Side by side with the x265 pipeline, for inspection outside the test.
        if let keep = ProcessInfo.processInfo.environment["XDREMUX_HW_KEEP_DIR"] {
            let x265 = temp.appendingPathComponent("x265.heic").path
            config.hardwareEncode = false
            _ = try await XDRemuxEngine.shared.convertPipeline(
                input: (dir as NSString).appendingPathComponent(input), output: x265, config: config)
            try FileManager.default.createDirectory(atPath: keep, withIntermediateDirectories: true)
            for name in ["hw.heic", "x265.heic"] {
                let dst = (keep as NSString).appendingPathComponent(name)
                try? FileManager.default.removeItem(atPath: dst)
                try FileManager.default.copyItem(atPath: temp.appendingPathComponent(name).path, toPath: dst)
            }
        }
    }
}
