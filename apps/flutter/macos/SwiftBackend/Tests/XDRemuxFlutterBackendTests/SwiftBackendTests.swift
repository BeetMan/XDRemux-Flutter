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
                outputMode: "apple",
                oppoCompatibility: 0,
                oppoCameraTail: 0,
                strictTmap: false,
                applePhotographicStyles: true
            )
            let result = XDRemuxSwiftBackend.convert(request) { _ in }
            XCTAssertTrue(result.success, "Apple Styles conversion failed for \(inputURL.lastPathComponent): \(result.errorMessage ?? "unknown error")")
            XCTAssertEqual(result.outputValid, true, "Apple Styles validation failed for \(inputURL.lastPathComponent)")
        }
    }

    func testPhotographicStylesWatermarkIsolationForConfiguredSample() throws {
        guard ProcessInfo.processInfo.environment[
            "XDREMUX_APPLE_STYLES_ISOLATE_OPPO_WATERMARK"
        ] == "1" else {
            throw XCTSkip("set XDREMUX_APPLE_STYLES_ISOLATE_OPPO_WATERMARK=1 to run the watermark isolation prototype")
        }
        guard let inputPath = ProcessInfo.processInfo.environment[
            "XDREMUX_P02_WATERMARK_SAMPLE"
        ] else {
            throw XCTSkip("set XDREMUX_P02_WATERMARK_SAMPLE to run the watermark isolation prototype")
        }
        guard XDRemuxSwiftBackend.capabilities()["swiftPhotographicStyles"] as? Bool == true else {
            throw XCTSkip("Apple Photographic Styles capability gate is closed on this host")
        }

        let outputPath = ProcessInfo.processInfo.environment["XDREMUX_P02_WATERMARK_OUTPUT"]
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("IMG20240321181713.styles-watermark.heic")
                .path
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let request = SwiftBackendRequest(
            requestID: "p02-watermark-isolation-IMG20240321181713",
            inputPath: inputPath,
            outputPath: outputPath,
            outputMode: "apple",
            oppoCompatibility: 0,
            oppoCameraTail: 0,
            strictTmap: false,
            applePhotographicStyles: true
        )
        let result = XDRemuxSwiftBackend.convert(request) { _ in }
        XCTAssertTrue(
            result.success,
            "Apple Styles watermark isolation failed: \(result.errorMessage ?? "unknown error")"
        )
        XCTAssertEqual(result.outputValid, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))
    }

    func testPhotographicStylesWatermarkStyleMaskForConfiguredSample() throws {
        guard ProcessInfo.processInfo.environment[
            "XDREMUX_APPLE_STYLES_NEUTRALIZE_OPPO_WATERMARK"
        ] == "1" else {
            throw XCTSkip("set XDREMUX_APPLE_STYLES_NEUTRALIZE_OPPO_WATERMARK=1 to run the style-data mask prototype")
        }
        guard let inputPath = ProcessInfo.processInfo.environment[
            "XDREMUX_P02_WATERMARK_SAMPLE"
        ] else {
            throw XCTSkip("set XDREMUX_P02_WATERMARK_SAMPLE to run the style-data mask prototype")
        }
        guard XDRemuxSwiftBackend.capabilities()["swiftPhotographicStyles"] as? Bool == true else {
            throw XCTSkip("Apple Photographic Styles capability gate is closed on this host")
        }

        if let existingOutput = ProcessInfo.processInfo.environment[
            "XDREMUX_P02_WATERMARK_MASK_EXISTING_OUTPUT"
        ] {
            let report = try AppleStylesWatermarkMaskBridge.neutralizeBottomWatermarkRows(
                outputURL: URL(fileURLWithPath: existingOutput),
                bottomRows: Int(
                    ProcessInfo.processInfo.environment[
                        "XDREMUX_APPLE_STYLES_WATERMARK_BOTTOM_ROWS"
                    ] ?? "2"
                ) ?? 2
            )
            XCTAssertEqual(report.patchedBlocks, 192)
            XCTAssertTrue(
                XDRemuxSwiftBackend.verifyOutput(
                    existingOutput,
                    applePhotographicStyles: true
                )
            )
            return
        }

        let outputPath = ProcessInfo.processInfo.environment["XDREMUX_P02_WATERMARK_MASK_OUTPUT"]
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("IMG20240321181713.styles-watermark-mask.heic")
                .path
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let request = SwiftBackendRequest(
            requestID: "p02-watermark-style-mask-IMG20240321181713",
            inputPath: inputPath,
            outputPath: outputPath,
            outputMode: "apple",
            oppoCompatibility: 0,
            oppoCameraTail: 0,
            strictTmap: false,
            applePhotographicStyles: true
        )
        let result = XDRemuxSwiftBackend.convert(request) { _ in }
        XCTAssertTrue(
            result.success,
            "Apple Styles watermark style-data mask failed: \(result.errorMessage ?? "unknown error")"
        )
        XCTAssertEqual(result.outputValid, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))
    }

    func testReturnedPhotoWatermarkWritebackForConfiguredPair() throws {
        guard let originalPath = ProcessInfo.processInfo.environment[
            "XDREMUX_P02_WRITEBACK_ORIGINAL"
        ] else {
            throw XCTSkip("set XDREMUX_P02_WRITEBACK_ORIGINAL to run the returned-photo writeback prototype")
        }
        guard let returnedPath = ProcessInfo.processInfo.environment[
            "XDREMUX_P02_WRITEBACK_RETURNED"
        ] else {
            throw XCTSkip("set XDREMUX_P02_WRITEBACK_RETURNED to run the returned-photo writeback prototype")
        }

        let outputPath = ProcessInfo.processInfo.environment["XDREMUX_P02_WRITEBACK_OUTPUT"]
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("IMG20240321181713.watermark-restored.heic")
                .path
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputURL)

        let report = try AppleReturnedPhotoWritebackBridge.restore(
            originalURL: URL(fileURLWithPath: originalPath),
            returnedURL: URL(fileURLWithPath: returnedPath),
            outputURL: outputURL,
            restoreCompleteOppoTail: true
        )

        XCTAssertEqual(report.width, 4096)
        XCTAssertEqual(report.height, 3512)
        XCTAssertTrue(report.restoredCanvas.height > 0)
        XCTAssertTrue(report.preservedISOGainMap)
        XCTAssertTrue(report.restoredOppoEntries.contains("watermark"))
        XCTAssertTrue(report.restoredOppoEntries.contains("local.hdr.linear.mask"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))
        XCTAssertTrue(
            XDRemuxSwiftBackend.verifyOutput(outputPath),
            "writeback output failed ISO HDR validation"
        )
    }

    func testReturnedPhotoAppleOutputForConfiguredSample() throws {
        guard let returnedPath = ProcessInfo.processInfo.environment[
            "XDREMUX_P02_WRITEBACK_RETURNED"
        ] else {
            throw XCTSkip("set XDREMUX_P02_WRITEBACK_RETURNED to run the Apple output prototype")
        }

        let outputPath = ProcessInfo.processInfo.environment[
            "XDREMUX_P02_WRITEBACK_APPLE_OUTPUT"
        ] ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("IMG_3323.apple-output.heic")
            .path
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputURL)

        let report = try AppleReturnedPhotoWritebackBridge.copyAppleOutput(
            from: URL(fileURLWithPath: returnedPath),
            to: outputURL
        )
        XCTAssertEqual(report.restoredOppoEntries, [])
        XCTAssertTrue(report.preservedISOGainMap)
        XCTAssertEqual(
            try Data(contentsOf: outputURL),
            try Data(contentsOf: URL(fileURLWithPath: returnedPath))
        )
        XCTAssertTrue(XDRemuxSwiftBackend.verifyOutput(outputPath))
    }

    func testOutputModesForConfiguredOppoSample() throws {
        guard let inputPath = ProcessInfo.processInfo.environment[
            "XDREMUX_OUTPUT_MODE_SAMPLE"
        ] else {
            throw XCTSkip("set XDREMUX_OUTPUT_MODE_SAMPLE to run the OPPO/Apple output mode smoke test")
        }

        let outputDirectory = ProcessInfo.processInfo.environment[
            "XDREMUX_OUTPUT_MODE_OUTPUT_DIR"
        ] ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("xdremux-output-modes", isDirectory: true)
            .path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: outputDirectory),
            withIntermediateDirectories: true
        )

        for outputMode in ["oppo", "apple"] {
            let outputPath = URL(fileURLWithPath: outputDirectory)
                .appendingPathComponent("IMG20260807131731.\(outputMode).heic")
                .path
            let request = SwiftBackendRequest(
                requestID: "output-mode-IMG20260807131731-\(outputMode)",
                inputPath: inputPath,
                outputPath: outputPath,
                outputMode: outputMode,
                oppoCompatibility: outputMode == "oppo" ? 2 : 0,
                oppoCameraTail: outputMode == "oppo" ? 3 : 0,
                strictTmap: false
            )
            let result = XDRemuxSwiftBackend.convert(request) { _ in }
            XCTAssertTrue(
                result.success,
                "\(outputMode) conversion failed: \(result.errorMessage ?? "unknown error")"
            )
            XCTAssertEqual(result.outputValid, true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))
        }
    }

    func testOppoThenPhotographicStylesForConfiguredSample() throws {
        guard let inputPath = ProcessInfo.processInfo.environment[
            "XDREMUX_OPPO_THEN_STYLES_SAMPLE"
        ] else {
            throw XCTSkip("set XDREMUX_OPPO_THEN_STYLES_SAMPLE to run the two-stage OPPO then Styles smoke test")
        }
        guard XDRemuxSwiftBackend.capabilities()["swiftPhotographicStyles"] as? Bool == true else {
            throw XCTSkip("Apple Photographic Styles capability gate is closed on this host")
        }

        let outputDirectory = ProcessInfo.processInfo.environment[
            "XDREMUX_OPPO_THEN_STYLES_OUTPUT_DIR"
        ] ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("xdremux-oppo-then-styles", isDirectory: true)
            .path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: outputDirectory),
            withIntermediateDirectories: true
        )

        let oppoOutputPath = URL(fileURLWithPath: outputDirectory)
            .appendingPathComponent("IMG20260807131731.oppo-first.heic")
            .path
        let stylesOutputPath = URL(fileURLWithPath: outputDirectory)
            .appendingPathComponent("IMG20260807131731.oppo-first.styles.heic")
            .path

        let oppoResult = XDRemuxSwiftBackend.convert(
            SwiftBackendRequest(
                requestID: "oppo-then-styles-oppo-IMG20260807131731",
                inputPath: inputPath,
                outputPath: oppoOutputPath,
                outputMode: "oppo",
                oppoCompatibility: 2,
                oppoCameraTail: 3,
                strictTmap: false
            )
        ) { _ in }
        XCTAssertTrue(
            oppoResult.success,
            "OPPO-compatible first conversion failed: \(oppoResult.errorMessage ?? "unknown error")"
        )
        XCTAssertEqual(oppoResult.outputValid, true)

        let stylesResult = XDRemuxSwiftBackend.convert(
            SwiftBackendRequest(
                requestID: "oppo-then-styles-apple-IMG20260807131731",
                inputPath: oppoOutputPath,
                outputPath: stylesOutputPath,
                outputMode: "apple",
                oppoCompatibility: 0,
                oppoCameraTail: 0,
                strictTmap: false,
                applePhotographicStyles: true
            )
        ) { _ in }
        XCTAssertTrue(
            stylesResult.success,
            "Apple Styles second conversion failed: \(stylesResult.errorMessage ?? "unknown error")"
        )
        XCTAssertEqual(stylesResult.outputValid, true)
        XCTAssertFalse(
            try AppleWatermarkTailBridge.containsRecognizedWatermark(
                sourceURL: URL(fileURLWithPath: stylesOutputPath)
            ),
            "Apple output still contains a recognized OPPO watermark footer"
        )
        XCTAssertTrue(
            XDRemuxSwiftBackend.verifyOutput(
                stylesOutputPath,
                applePhotographicStyles: true
            )
        )
    }
}
