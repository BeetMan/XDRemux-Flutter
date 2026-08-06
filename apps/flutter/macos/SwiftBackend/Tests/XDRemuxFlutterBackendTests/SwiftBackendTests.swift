import Foundation
import XCTest
@testable import XDRemuxFlutterBackend

final class SwiftBackendTests: XCTestCase {
    func testCapabilitiesExposePinnedCoreContract() {
        let capabilities = XDRemuxSwiftBackend.capabilities()

        XCTAssertEqual(capabilities["swiftPackageVersion"] as? String, "1.3.1")
        XCTAssertEqual(capabilities["swiftDeploymentTarget"] as? String, "macOS 15")
        XCTAssertEqual(capabilities["swiftAppleFeatures"] as? Bool, true)
        XCTAssertEqual(capabilities["swiftPhotographicStyles"] as? Bool, true)
        XCTAssertEqual(capabilities["swiftPortrait"] as? Bool, false)
        XCTAssertNotNil(capabilities["swiftAppleFeaturesUnavailableReason"] as? String)
    }

    func testDirectConversionForExternalSamplesIfConfigured() throws {
        guard let sampleDirectory = ProcessInfo.processInfo.environment["XDREMUX_P01_SAMPLE_DIR"] else {
            throw XCTSkip("set XDREMUX_P01_SAMPLE_DIR to run the external ProXDR sample smoke test")
        }

        let outputDirectory = ProcessInfo.processInfo.environment["XDREMUX_P01_OUTPUT_DIR"]
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("xdremux-p01-swift", isDirectory: true)
                .path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: outputDirectory),
            withIntermediateDirectories: true
        )

        let sampleURLs = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: sampleDirectory),
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "heic" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertFalse(sampleURLs.isEmpty, "no HEIC samples found in \(sampleDirectory)")
        for inputURL in sampleURLs {
            let outputURL = URL(fileURLWithPath: outputDirectory)
                .appendingPathComponent(inputURL.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("swift.heic")
            let request = SwiftBackendRequest(
                requestID: "p01-\(inputURL.lastPathComponent)",
                inputPath: inputURL.path,
                outputPath: outputURL.path,
                oppoCompatibility: 0,
                oppoCameraTail: 255,
                strictTmap: false
            )
            let result = XDRemuxSwiftBackend.convert(request) { _ in }
            XCTAssertTrue(result.success, "Swift conversion failed for \(inputURL.lastPathComponent): \(result.errorMessage ?? "unknown error")")
            XCTAssertEqual(result.outputValid, true, "Swift output validation failed for \(inputURL.lastPathComponent)")
        }
    }

    func testPhotographicStylesForExternalSamplesIfConfigured() throws {
        guard let sampleDirectory = ProcessInfo.processInfo.environment["XDREMUX_P02_SAMPLE_DIR"] else {
            throw XCTSkip("set XDREMUX_P02_SAMPLE_DIR to run the experimental Apple Photographic Styles smoke test")
        }
        guard XDRemuxSwiftBackend.capabilities()["swiftPhotographicStyles"] as? Bool == true else {
            throw XCTSkip("Apple Photographic Styles capability gate is closed on this host")
        }

        let outputDirectory = ProcessInfo.processInfo.environment["XDREMUX_P02_OUTPUT_DIR"]
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("xdremux-p02-styles", isDirectory: true)
                .path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: outputDirectory),
            withIntermediateDirectories: true
        )

        let sampleURLs = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: sampleDirectory),
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "heic" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertFalse(sampleURLs.isEmpty, "no HEIC samples found in \(sampleDirectory)")
        for inputURL in sampleURLs {
            let outputURL = URL(fileURLWithPath: outputDirectory)
                .appendingPathComponent(inputURL.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("styles.heic")
            let request = SwiftBackendRequest(
                requestID: "p02-styles-\(inputURL.lastPathComponent)",
                inputPath: inputURL.path,
                outputPath: outputURL.path,
                oppoCompatibility: 0,
                oppoCameraTail: 255,
                strictTmap: false,
                applePhotographicStyles: true
            )
            let result = XDRemuxSwiftBackend.convert(request) { _ in }
            XCTAssertTrue(result.success, "Apple Styles conversion failed for \(inputURL.lastPathComponent): \(result.errorMessage ?? "unknown error")")
            XCTAssertEqual(result.outputValid, true, "Apple Styles validation failed for \(inputURL.lastPathComponent)")
        }
    }
}
