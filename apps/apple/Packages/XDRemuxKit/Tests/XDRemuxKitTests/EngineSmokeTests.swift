import Foundation
import XCTest
@testable import XDRemuxKit
import XDRemuxCoreC
import XDRemuxModel

/// P0 acceptance (docs/plans/apple-native.md §3): the Swift wrapper reaches the
/// Rust core, releases what it allocates, and survives bad input. No private
/// photos are needed; conversions on real samples are opt-in via
/// `XDREMUX_SAMPLE_DIR`, like the Rust `local_samples` test.
final class EngineSmokeTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xdremux-kit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCoreVersionMatchesCargoToml() throws {
        let cargo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // XDRemuxKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // XDRemuxKit
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // apple
            .deletingLastPathComponent() // apps
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("xdremux/rust/Cargo.toml")
        let toml = try String(contentsOf: cargo, encoding: .utf8)
        let line = try XCTUnwrap(toml.split(separator: "\n").first { $0.hasPrefix("version") })
        let expected = line.split(separator: "\"")[1]
        XCTAssertEqual(XDRemuxEngine.coreVersion(), String(expected))
    }

    func testCodecCapabilitiesIsJSON() async throws {
        let report = try await XDRemuxEngine.shared.codecCapabilities()
        let object = try JSONSerialization.jsonObject(with: Data(report.raw.utf8))
        XCTAssertTrue(object is [String: Any], report.raw)
    }

    func testClassifyMissingFileDoesNotCrash() async throws {
        let result = try await XDRemuxEngine.shared.classify(path: tempDir.appendingPathComponent("missing.heic").path)
        XCTAssertNotNil(result.status)
        XCTAssertNil(result.hdrKind)
    }

    func testClassifyGarbageFile() async throws {
        let garbage = tempDir.appendingPathComponent("garbage.heic")
        try Data(repeating: 0x42, count: 4096).write(to: garbage)
        let result = try await XDRemuxEngine.shared.classify(path: garbage.path)
        XCTAssertNotNil(result.status)
        XCTAssertNil(result.family)
    }

    func testInspectMissingFileReportsFailure() async throws {
        let report = try await XDRemuxEngine.shared.inspect(path: tempDir.appendingPathComponent("missing.heic").path)
        XCTAssertFalse(report.success)
        XCTAssertNotNil(report.errorMessage)
        XCTAssertThrowsError(try report.checked())
    }

    /// Rust reports unreadable EXIF as an empty-but-successful details record
    /// (it is a summary, not a validation); a missing file is a failure.
    func testPhotoDetailsEnvelope() async throws {
        struct Envelope: Decodable { let success: Bool; let errorMessage: String? }
        let garbage = tempDir.appendingPathComponent("garbage.jpg")
        try Data(repeating: 0xFF, count: 64).write(to: garbage)
        let onGarbage: Envelope = try await XDRemuxEngine.shared.photoDetails(path: garbage.path).decode()
        XCTAssertTrue(onGarbage.success, onGarbage.errorMessage ?? "")

        let missing = try await XDRemuxEngine.shared.photoDetails(path: tempDir.appendingPathComponent("nope.jpg").path)
        XCTAssertThrowsError(try missing.checked())
    }

    func testConvertSamePathIsRefused() async throws {
        let garbage = tempDir.appendingPathComponent("same.heic")
        try Data(repeating: 0, count: 16).write(to: garbage)
        let report = try await XDRemuxEngine.shared.convert(
            input: garbage.path, output: garbage.path, config: ConversionConfig().rustConfig)
        XCTAssertFalse(report.success)
        XCTAssertNotNil(report.errorMessage)
    }

    func testProgressHandleRoundTrip() {
        let handle = xdremux_progress_begin()
        XCTAssertNotEqual(handle, 0)
        xdremux_progress_report(handle, 3, 10)
        let p = XDRemuxEngine.readProgress(handle)
        XCTAssertEqual(p.current, 3)
        XCTAssertEqual(p.total, 10)
        XCTAssertEqual(p.fraction, 0.3, accuracy: 1e-9)
        xdremux_progress_end(handle)
    }

    /// Leak / crash soak: 500 allocate-and-free cycles across the string and
    /// struct ownership paths. Run under Instruments Leaks for the P0 record.
    func testRepeatedCallsDoNotCrash() async throws {
        let garbage = tempDir.appendingPathComponent("soak.heic")
        try Data(repeating: 0x00, count: 1024).write(to: garbage)
        for _ in 0..<500 {
            _ = XDRemuxEngine.coreVersion()
            _ = try await XDRemuxEngine.shared.classify(path: garbage.path)
            _ = try await XDRemuxEngine.shared.inspect(path: garbage.path)
        }
    }

    /// Opt-in: converts the first .heic in `XDREMUX_SAMPLE_DIR` and verifies
    /// the output, with progress observed at least once.
    func testConvertRealSampleIfProvided() async throws {
        guard let dir = ProcessInfo.processInfo.environment["XDREMUX_SAMPLE_DIR"] else {
            throw XCTSkip("set XDREMUX_SAMPLE_DIR to a folder of ProXDR .heic files")
        }
        let inputs = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.lowercased().hasSuffix(".heic") }.sorted()
        let input = try XCTUnwrap(inputs.first, "no .heic in \(dir)")
        let output = tempDir.appendingPathComponent("out_iso.heic").path

        let seen = Seen()
        let report = try await XDRemuxEngine.shared.convert(
            input: (dir as NSString).appendingPathComponent(input),
            output: output,
            config: ConversionConfig().rustConfig,
            progress: { (_: ConversionProgress) in seen.mark() })
        try report.checked()
        XCTAssertTrue(seen.value)
        let ok = try await XDRemuxEngine.shared.verifyOutput(path: output)
        XCTAssertTrue(ok)
    }
}

extension EngineSmokeTests {
    /// Opt-in end-to-end through the model's `ConversionJob` with the real
    /// engine: temp output, verification, publish; the input's bytes are
    /// untouched (plan §3 P1 acceptance).
    func testConversionJobEndToEndIfSampleProvided() async throws {
        guard let dir = ProcessInfo.processInfo.environment["XDREMUX_SAMPLE_DIR"] else {
            throw XCTSkip("set XDREMUX_SAMPLE_DIR to a folder of ProXDR .heic files")
        }
        let inputs = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.lowercased().hasSuffix(".heic") }.sorted()
        let name = try XCTUnwrap(inputs.first, "no .heic in \(dir)")
        let input = tempDir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: dir).appendingPathComponent(name), to: input)
        let before = try Data(contentsOf: input)

        var config = ConversionConfig()
        config.outputMode = .apple
        let job = ConversionJob(backend: XDRemuxEngine.shared,
                                scratchRoot: tempDir.appendingPathComponent("scratch"),
                                outputRoot: tempDir.appendingPathComponent("out"))
        let product = try await job.run(input: input, config: config)
        XCTAssertEqual(product.outputURL.lastPathComponent, (name as NSString).deletingPathExtension + "_iso.heic")
        XCTAssertTrue(FileManager.default.fileExists(atPath: product.outputURL.path))
        XCTAssertEqual(try Data(contentsOf: input), before, "input bytes unchanged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("scratch").path)
                       && (try? FileManager.default.contentsOfDirectory(atPath: tempDir.appendingPathComponent("scratch").path))?.isEmpty == false,
                       "scratch cleaned")
        let details: PhotoDetails = try await XDRemuxEngine.shared.decodedPhotoDetails(path: product.outputURL.path)
        XCTAssertTrue(details.success)
        XCTAssertNotNil(details.width)
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func mark() { lock.withLock { flag = true } }
}

extension EngineSmokeTests {
    /// Opt-in: `XDREMUX_MOTION_SAMPLE_DIR` with OPPO Motion Photo JPEGs →
    /// inspect, convert as a Live Photo pair, validate the pair.
    func testLivePhotoPairEndToEndIfSampleProvided() async throws {
        guard let dir = ProcessInfo.processInfo.environment["XDREMUX_MOTION_SAMPLE_DIR"] else {
            throw XCTSkip("set XDREMUX_MOTION_SAMPLE_DIR to a folder of OPPO Motion Photo .jpg files")
        }
        let candidates = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.lowercased().hasSuffix(".jpg") && !$0.contains("_iso") }.sorted()
        var picked: String?
        for name in candidates {
            let report = try await XDRemuxEngine.shared.motionPhotoReport(path: (dir as NSString).appendingPathComponent(name))
            if report.isMotionPhoto { picked = name; break }
        }
        let name = try XCTUnwrap(picked, "no Motion Photo in \(dir)")
        let input = tempDir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: dir).appendingPathComponent(name), to: input)

        var config = ConversionConfig()
        config.outputMode = .apple
        let job = ConversionJob(backend: XDRemuxEngine.shared,
                                scratchRoot: tempDir.appendingPathComponent("scratch"),
                                outputRoot: tempDir.appendingPathComponent("out"))
        let product = try await job.run(input: input, config: config, motionMode: .livePhotoPair)
        let mov = try XCTUnwrap(product.pairedVideoURL)
        XCTAssertEqual(mov.deletingPathExtension().lastPathComponent, product.outputURL.deletingPathExtension().lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mov.path))
        let valid = try await XDRemuxEngine.shared.livePhotoPairValid(still: product.outputURL.path, video: mov.path)
        XCTAssertTrue(valid)
        let ok = try await XDRemuxEngine.shared.verifyOutput(path: product.outputURL.path)
        XCTAssertTrue(ok)

        let clips = try await ConversionJob(backend: XDRemuxEngine.shared,
                                            scratchRoot: tempDir.appendingPathComponent("scratch2"),
                                            outputRoot: tempDir.appendingPathComponent("out2"))
            .run(input: input, config: config, motionMode: .stillAndVideo)
        XCTAssertFalse(clips.extraVideoURLs.isEmpty)
    }
}
