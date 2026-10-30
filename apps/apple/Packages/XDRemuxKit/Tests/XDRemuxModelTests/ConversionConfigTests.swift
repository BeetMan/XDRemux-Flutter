import Foundation
import XCTest
@testable import XDRemuxModel

final class ConversionConfigTests: XCTestCase {
    func testDefaultsMatchDart() {
        let c = ConversionConfig()
        XCTAssertEqual(c.language, .chinese)
        XCTAssertEqual(c.family, .auto)
        XCTAssertEqual(c.outputMode, .oppo)
        XCTAssertEqual(c.oppoCompatibility, .on)
        XCTAssertEqual(c.oppoCameraTail, .automatic)
        XCTAssertEqual(c.maxConcurrentJobs, 4)
        XCTAssertEqual(c.fileNameSuffix, "_iso")
        XCTAssertTrue(c.skipExisting)
        XCTAssertEqual(c.motionPhotoDefaultMode, .livePhotoPair)
    }

    /// A record as written by the Flutter app's `ConversionConfig.toJson()`.
    func testDecodesDartRecord() throws {
        let json = """
        {"language":"english","family":"x7","backend":"rust","outputMode":"apple",
         "outputDirectory":"/tmp/out","oppoCompatibility":"isoGraph","oppoCameraTail":"preserveNoHdr",
         "strictTmap":true,"applePhotographicStyles":true,"applePortrait":false,
         "applePhotographicStyles3":true,"skipExisting":false,"maxConcurrentJobs":2,
         "fileNameSuffix":"_hdr","categorizeOutputByMode":true,"autoSaveToGallery":true,
         "hardwareEncode":false,"motionPhotoDefaultMode":"stillAndVideo"}
        """
        let c = try JSONDecoder().decode(ConversionConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.language, .english)
        XCTAssertEqual(c.family, .x7)
        XCTAssertEqual(c.outputMode, .apple)
        XCTAssertEqual(c.outputDirectory, "/tmp/out")
        XCTAssertEqual(c.oppoCompatibility, .isoGraph)
        XCTAssertEqual(c.oppoCameraTail, .preserveNoHdr)
        XCTAssertTrue(c.strictTmap)
        XCTAssertTrue(c.applePhotographicStyles3)
        XCTAssertEqual(c.maxConcurrentJobs, 2)
        XCTAssertEqual(c.fileNameSuffix, "_hdr")
        XCTAssertEqual(c.motionPhotoDefaultMode, .stillAndVideo)
    }

    func testMissingKeysFallBackToDefaults() throws {
        let c = try JSONDecoder().decode(ConversionConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(c, ConversionConfig())
    }

    func testRoundTripKeepsDartKeys() throws {
        var c = ConversionConfig()
        c.outputMode = .apple
        c.applePortrait = true
        let data = try JSONEncoder().encode(c)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["outputMode"] as? String, "apple")
        XCTAssertEqual(object["oppoCompatibility"] as? String, "on")
        XCTAssertEqual(object["motionPhotoDefaultMode"] as? String, "livePhotoPair")
        XCTAssertEqual(try JSONDecoder().decode(ConversionConfig.self, from: data), c)
    }

    func testRustValuesMatchFfiContract() {
        XCTAssertEqual(OppoCompatMode.off.rustValue, 0)
        XCTAssertEqual(OppoCompatMode.auto.rustValue, 1)
        XCTAssertEqual(OppoCompatMode.on.rustValue, 2)
        XCTAssertEqual(OppoCompatMode.isoGraph.rustValue, 6)
        XCTAssertEqual(OppoCameraTailMode.automatic.rustValue, 255)
        XCTAssertEqual(OppoCameraTailMode.preserveNoHdr.rustValue, 9)
    }

    func testAppleOutputDropsOppoPrivateData() {
        var c = ConversionConfig()
        c.outputMode = .apple
        c.oppoCompatibility = .on
        c.oppoCameraTail = .preserve
        c.applePhotographicStyles3 = true
        let r = c.rustConfig
        XCTAssertEqual(r.oppoCompat, 0)
        XCTAssertEqual(r.oppoCameraTail, 0)
        XCTAssertEqual(r.applePhotographicStyles, 1, "PS3 implies the 2023 styles graph")
        XCTAssertEqual(r.applePortrait, 0)
    }

    func testOppoOutputDefaults() {
        let r = ConversionConfig().rustConfig
        XCTAssertEqual(r, RustConvertConfig(oppoCompat: 2, oppoCameraTail: 255, strictTmap: 0,
                                            applePhotographicStyles: 0, applePortrait: 0))
    }
}
