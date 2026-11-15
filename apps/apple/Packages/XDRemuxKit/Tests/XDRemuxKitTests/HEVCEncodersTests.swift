import XCTest
@testable import XDRemuxKit
import XDRemuxModel

/// The encoder names below are placeholders: the real ones come from the core
/// at run time, and no test may depend on which encoders a build carries.
final class HEVCEncodersTests: XCTestCase {
    func testParsesTheCapabilityReport() {
        let single = HEVCEncoders(capabilitiesJSON: #"{"hevcEncoders":["system"],"defaultHevcEncoder":"system"}"#)
        XCTAssertEqual(single.available, ["system"])
        XCTAssertFalse(single.offersChoice)
        XCTAssertNil(single.alternativeName)

        let dual = HEVCEncoders(capabilitiesJSON: #"{"hevcEncoders":["system","other"],"defaultHevcEncoder":"system"}"#)
        XCTAssertTrue(dual.offersChoice)
        XCTAssertEqual(dual.defaultName, "system")
        XCTAssertEqual(dual.alternativeName, "other")
        XCTAssertTrue(dual.contains("other"))
        XCTAssertFalse(dual.contains("missing"))
    }

    func testOldOrBrokenReportsOfferNoChoice() {
        for json in ["{}", "not json", #"{"hevcEncoders":[]}"#] {
            let encoders = HEVCEncoders(capabilitiesJSON: json)
            XCTAssertFalse(encoders.offersChoice, json)
            XCTAssertNil(encoders.name(systemEncoder: false), json)
        }
        // No explicit default: the first listed encoder is the default.
        let implied = HEVCEncoders(capabilitiesJSON: #"{"hevcEncoders":["a","b"]}"#)
        XCTAssertEqual(implied.defaultName, "a")
        XCTAssertEqual(implied.alternativeName, "b")
    }

    func testSettingMapsToAnEncoderName() {
        let dual = HEVCEncoders(available: ["system", "other"], defaultName: "system")
        XCTAssertNil(dual.name(systemEncoder: true), "the default is expressed by sending no name")
        XCTAssertEqual(dual.name(systemEncoder: false), "other")
        let single = HEVCEncoders(available: ["system"], defaultName: "system")
        XCTAssertNil(single.name(systemEncoder: false), "nothing to switch to in a single-encoder build")
    }

    func testPipelineConfigCarriesTheChoice() throws {
        let dual = HEVCEncoders(available: ["system", "other"], defaultName: "system")
        var config = ConversionConfig()
        func object(_ encoders: HEVCEncoders) throws -> [String: Any] {
            let json = try XDRemuxEngine.configJSON(config, encoders: encoders)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }
        XCTAssertNil(try object(dual)["hevcEncoder"], "system encoder: no key, the core uses its default")
        config.hardwareEncode = false
        XCTAssertEqual(try object(dual)["hevcEncoder"] as? String, "other")
        XCTAssertEqual(try object(dual)["outputMode"] as? String, "oppo", "the rest of the config is intact")
        XCTAssertNil(try object(HEVCEncoders(available: ["system"], defaultName: "system"))["hevcEncoder"])
    }

    /// Against the linked core: the report is consistent and the process-wide
    /// selection accepts exactly the reported names.
    func testLinkedCoreReportsItsEncoders() {
        let encoders = XDRemuxEngine.hevcEncoders
        XCTAssertFalse(encoders.available.isEmpty)
        XCTAssertEqual(encoders.defaultName, encoders.available.first)
        XCTAssertFalse(XDRemuxEngine.selectHEVCEncoder(named: "no-such-encoder"))
        for name in encoders.available {
            XCTAssertTrue(XDRemuxEngine.selectHEVCEncoder(named: name), name)
        }
        XCTAssertTrue(XDRemuxEngine.selectHEVCEncoder(named: nil))
    }

    /// Opt-in, whole pipeline: the same photo converted with each setting.
    /// Both must succeed and verify. When the core carries two encoders the
    /// setting has to reach it, so the two outputs differ. Set
    /// `XDREMUX_TEST_OUTPUT_DIR` to keep the files for inspection.
    func testEncoderSettingReachesTheCoreIfSampleProvided() async throws {
        guard let dir = ProcessInfo.processInfo.environment["XDREMUX_SAMPLE_DIR"] else {
            throw XCTSkip("set XDREMUX_SAMPLE_DIR to a folder of ProXDR .heic files")
        }
        let inputs = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.lowercased().hasSuffix(".heic") }.sorted()
        let input = (dir as NSString).appendingPathComponent(try XCTUnwrap(inputs.first, "no .heic in \(dir)"))
        let keep = ProcessInfo.processInfo.environment["XDREMUX_TEST_OUTPUT_DIR"]
        let outDir = keep.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("xdremux-encoder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { if keep == nil { try? FileManager.default.removeItem(at: outDir) } }

        var outputs: [Bool: Data] = [:]
        for systemEncoder in [true, false] {
            var config = ConversionConfig()
            config.outputMode = .apple
            config.hardwareEncode = systemEncoder
            let output = outDir.appendingPathComponent(systemEncoder ? "system.heic" : "alternative.heic").path
            try? FileManager.default.removeItem(atPath: output)
            let outcome = try await XDRemuxEngine.shared.runPipeline(input: input, output: output, config: config) { _ in }
            XCTAssertTrue(outcome.success, outcome.errorMessage ?? "pipeline failed")
            let verified = try await XDRemuxEngine.shared.verifyOutput(path: output)
            XCTAssertTrue(verified)
            outputs[systemEncoder] = try Data(contentsOf: URL(fileURLWithPath: output))
        }
        if XDRemuxEngine.hevcEncoders.offersChoice {
            XCTAssertNotEqual(outputs[true], outputs[false], "two encoders, one output: the setting did not reach the core")
        }
    }
}
