import Foundation
import XDRemuxCore
import XDRemuxAppleFeatures

public struct SwiftBackendRequest: Sendable {
    public let requestID: String
    public let inputPath: String
    public let outputPath: String
    public let outputMode: String
    public let oppoCompatibility: Int
    public let oppoCameraTail: Int
    public let strictTmap: Bool
    public let applePhotographicStyles: Bool
    public let applePortrait: Bool
    public let appleWatermarkPolicy: String

    public init(
        requestID: String,
        inputPath: String,
        outputPath: String,
        outputMode: String = "oppo",
        oppoCompatibility: Int,
        oppoCameraTail: Int,
        strictTmap: Bool,
        applePhotographicStyles: Bool = false,
        applePortrait: Bool = false,
        appleWatermarkPolicy: String = "preserve"
    ) {
        self.requestID = requestID
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.outputMode = outputMode
        self.oppoCompatibility = oppoCompatibility
        self.oppoCameraTail = oppoCameraTail
        self.strictTmap = strictTmap
        self.applePhotographicStyles = applePhotographicStyles
        self.applePortrait = applePortrait
        self.appleWatermarkPolicy = appleWatermarkPolicy
    }
}

public struct SwiftBackendProgress: Sendable {
    public let stage: Int
    public let current: Int
    public let total: Int

    public init(stage: Int, current: Int, total: Int) {
        self.stage = stage
        self.current = current
        self.total = total
    }
}

public struct SwiftBackendResult: Sendable {
    public let success: Bool
    public let cancelled: Bool
    public let outputValid: Bool?
    public let errorMessage: String?

    public init(
        success: Bool,
        cancelled: Bool = false,
        outputValid: Bool? = nil,
        errorMessage: String? = nil
    ) {
        self.success = success
        self.cancelled = cancelled
        self.outputValid = outputValid
        self.errorMessage = errorMessage
    }
}

/// macOS-only bridge around the upstream Swift Core library.
///
/// This target deliberately depends on the tagged Swift package instead of
/// launching the upstream CLI. The upstream package currently requires
/// macOS 15, so callers must gate this bridge on the same deployment target.
public enum XDRemuxSwiftBackend {
    private static let state = CancellationState()
    private static let capabilitiesLock = NSLock()
    private static var cachedCapabilities: [String: Any]?

    public static func capabilities() -> [String: Any] {
        capabilitiesLock.lock()
        defer { capabilitiesLock.unlock() }
        if let cachedCapabilities {
            return cachedCapabilities
        }

        let xcrunAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun")
        let zstdAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/zstd")
        let selfTestPassed = (try? AppleFeatureConversionEngine.portraitSelfTestReport()) != nil
        let resourceCompatibility = AppleFeatureResourceCompatibility.prepare()
        let appleFeaturesAvailable = xcrunAvailable
            && selfTestPassed
            && resourceCompatibility.available
        let appleUnavailableReason: String
        if !xcrunAvailable {
            appleUnavailableReason = "AppleFeatures 需要 /usr/bin/xcrun；当前不可用。"
        } else if !selfTestPassed {
            appleUnavailableReason = "AppleFeatures 静态自检失败；当前不可用。"
        } else if !resourceCompatibility.available {
            appleUnavailableReason = resourceCompatibility.reason
        } else {
            appleUnavailableReason = zstdAvailable
                ? ""
                : "Apple Portrait 需要 /usr/bin/zstd；Photographic Styles 仍须保留实验性警告。"
        }
        let result: [String: Any] = [
            "swiftAvailable": xcrunAvailable,
            "swiftStandardHdr": xcrunAvailable,
            "swiftAppleFeatures": appleFeaturesAvailable,
            "swiftPhotographicStyles": appleFeaturesAvailable,
            "swiftPortrait": appleFeaturesAvailable && zstdAvailable,
            "swiftPortraitResearch": appleFeaturesAvailable && PortraitDepthDiagnostics.isAvailable,
            "swiftPortraitDiagnostic": PortraitDepthDiagnostics.isAvailable,
            "swiftPortraitDiagnosticZstd": PortraitDepthDiagnostics.zstdExecutablePath ?? NSNull(),
            "swiftPackageVersion": "1.3.1",
            "swiftDeploymentTarget": "macOS 15",
            "swiftUnavailableReason": xcrunAvailable
                ? ""
                : "macOS Swift Core requires /usr/bin/xcrun for native tile encoding.",
            "swiftAppleFeaturesUnavailableReason": appleUnavailableReason,
        ]
        cachedCapabilities = result
        return result
    }

    /// Runs the read-only rear.depth variant probe. This is intentionally not
    /// part of `convert` and does not make an input eligible for Portrait.
    public static func diagnosePortrait(_ path: String) -> [String: Any] {
        do {
            return try PortraitDepthDiagnostics.report(
                for: URL(fileURLWithPath: path).standardizedFileURL
            )
        } catch {
            return [
                "schema": PortraitDepthDiagnostics.schema,
                "inputPath": path,
                "available": false,
                "safeToTransform": false,
                "classification": "diagnostic-error",
                "error": String(describing: error),
            ]
        }
    }

    public static func convert(
        _ request: SwiftBackendRequest,
        progress: @escaping @Sendable (SwiftBackendProgress) -> Void
    ) -> SwiftBackendResult {
        if state.takeCancellation(for: request.requestID) {
            return SwiftBackendResult(success: false, cancelled: true, errorMessage: "转换已取消")
        }

        if request.applePhotographicStyles || request.applePortrait {
            let featureCapabilities = capabilities()
            let stylesAvailable = featureCapabilities["swiftPhotographicStyles"] as? Bool == true
            let portraitAvailable = featureCapabilities["swiftPortrait"] as? Bool == true
            if request.applePhotographicStyles && !stylesAvailable {
                return SwiftBackendResult(
                    success: false,
                    errorMessage: featureCapabilities["swiftAppleFeaturesUnavailableReason"] as? String
                        ?? "Apple Photographic Styles 当前未通过 capability 验证。"
                )
            }
            if request.applePortrait && !portraitAvailable {
                return SwiftBackendResult(
                    success: false,
                    errorMessage: featureCapabilities["swiftAppleFeaturesUnavailableReason"] as? String
                        ?? "Apple Portrait 当前未通过 capability 验证。"
                )
            }
        }

        let inputURL = URL(fileURLWithPath: request.inputPath)
        let outputURL = URL(fileURLWithPath: request.outputPath)
        let appleOutput = request.outputMode == "apple"
        let oppoCompatibility = appleOutput
            ? OppoCompatibility.off
            : mapOppoCompatibility(request.oppoCompatibility)
        let oppoCameraTail = appleOutput
            ? OppoCameraTail.off
            : mapOppoCameraTail(
                request.oppoCameraTail,
                compatibility: oppoCompatibility
            )
        let configuration = ConversionConfiguration(
            family: .auto,
            oppoCompatibility: oppoCompatibility,
            inputProcessingBranch: .hybrid,
            oppoCameraTail: oppoCameraTail,
            tmapFormat: request.strictTmap ? .strict : .imageIO,
            applePhotographicStyles: request.applePhotographicStyles,
            applePortrait: request.applePortrait,
            eventHandler: { event in
                switch event {
                case .diagnostic:
                    progress(SwiftBackendProgress(stage: 3, current: 1, total: 1))
                }
            }
        )
        let watermarkIsolationEnabled = request.applePhotographicStyles
            && !request.applePortrait
            && (request.appleWatermarkPolicy == "isolate"
                || ProcessInfo.processInfo.environment[
                    "XDREMUX_APPLE_STYLES_ISOLATE_OPPO_WATERMARK"
                ] == "1")
        let watermarkStyleMaskEnabled = request.applePhotographicStyles
            && !request.applePortrait
            && ProcessInfo.processInfo.environment[
                "XDREMUX_APPLE_STYLES_NEUTRALIZE_OPPO_WATERMARK"
            ] == "1"
        var preparedWatermarkInput: AppleWatermarkTailBridge.PreparedInput?
        defer {
            if let scratchURL = preparedWatermarkInput?.url {
                try? FileManager.default.removeItem(at: scratchURL)
            }
        }

        progress(SwiftBackendProgress(stage: 1, current: 0, total: 1))
        do {
            let conversionInputURL: URL
            if watermarkIsolationEnabled {
                preparedWatermarkInput = try AppleWatermarkTailBridge.prepare(sourceURL: inputURL)
                conversionInputURL = preparedWatermarkInput?.url ?? inputURL
                if let preparedWatermarkInput {
                    print(
                        "styles watermark isolation=input-filtered "
                            + "entries=\(preparedWatermarkInput.entryNames.joined(separator: ","))"
                    )
                } else {
                    print("styles watermark isolation=input-unchanged no-recognized-oppo-tail")
                }
            } else {
                conversionInputURL = inputURL
            }

            let conversionRequest = ConversionRequest(
                input: InputSource(url: conversionInputURL),
                output: OutputDestination(url: outputURL),
                configuration: configuration
            )
            if configuration.appleFeaturesEnabled {
                _ = try AppleFeatureConversionEngine.convert(conversionRequest)
                if watermarkStyleMaskEnabled {
                    if try AppleWatermarkTailBridge.containsRecognizedWatermark(
                        sourceURL: inputURL
                    ) {
                        let bottomRows = Int(
                            ProcessInfo.processInfo.environment[
                                "XDREMUX_APPLE_STYLES_WATERMARK_BOTTOM_ROWS"
                            ] ?? "2"
                        ) ?? 2
                        let report = try AppleStylesWatermarkMaskBridge
                            .neutralizeBottomWatermarkRows(
                                outputURL: outputURL,
                                bottomRows: bottomRows
                            )
                        print(
                            "styles watermark mask=identity "
                                + "blocks=\(report.patchedBlocks) "
                                + "rows=\(report.bottomRows) "
                                + "grid=\(report.spatialColumns)x\(report.spatialRows)x\(report.subtileCount)"
                        )
                    } else {
                        print("styles watermark mask=input-unchanged no-recognized-oppo-tail")
                    }
                }
                if let preparedWatermarkInput {
                    try AppleWatermarkTailBridge.appendWatermarkTail(
                        preparedWatermarkInput.watermarkTail,
                        to: outputURL
                    )
                    print("styles watermark isolation=output-watermark-tail-restored")
                }
                if appleOutput,
                   try AppleWatermarkTailBridge.stripRecognizedOppoTail(from: outputURL) {
                    print("apple output=recognized-oppo-tail-stripped")
                }
            } else {
                _ = try ConversionEngine.convert(conversionRequest)
            }
            progress(SwiftBackendProgress(stage: 4, current: 1, total: 1))

            if state.takeCancellation(for: request.requestID) {
                return SwiftBackendResult(success: false, cancelled: true, errorMessage: "转换已取消")
            }

            let valid = configuration.appleFeaturesEnabled
                ? AppleFeatureConversionEngine.isValidOutput(
                    outputURL,
                    options: configuration.appleFeatureOptions
                )
                : ConversionEngine.isValidOutput(outputURL, config: configuration)
            guard valid else {
                return SwiftBackendResult(
                    success: false,
                    outputValid: false,
                    errorMessage: "Swift 后端输出不是有效的 ISO HDR HEIC"
                )
            }
            return SwiftBackendResult(success: true, outputValid: true)
        } catch {
            return SwiftBackendResult(
                success: false,
                errorMessage: String(describing: error)
            )
        }
    }

    public static func verifyOutput(
        _ path: String,
        applePhotographicStyles: Bool = false,
        applePortrait: Bool = false
    ) -> Bool {
        let outputURL = URL(fileURLWithPath: path)
        guard applePhotographicStyles || applePortrait else {
            return ConversionEngine.isValidISOGainMapOutput(outputURL)
        }
        return AppleFeatureConversionEngine.isValidOutput(
            outputURL,
            options: AppleFeatureOptions(
                photographicStyles: applePhotographicStyles,
                portrait: applePortrait
            )
        )
    }

    public static func cancel(requestID: String) {
        state.cancel(requestID: requestID)
    }

    private static func mapOppoCompatibility(_ value: Int) -> OppoCompatibility {
        switch value {
        case 1: return .auto
        case 2: return .on
        case 3: return .tail
        case 4: return .iso
        case 5: return .isoNoLocal
        case 6: return .isoGraph
        default: return .off
        }
    }

    private static func mapOppoCameraTail(
        _ value: Int,
        compatibility: OppoCompatibility
    ) -> OppoCameraTail {
        switch value {
        case 0: return .off
        case 1: return .watermark
        case 2: return .compact
        case 3: return .preserve
        case 4: return .preserveWithoutPortrait
        case 5: return .preserveWithoutPortraitOrPrivateHDR
        case 6: return .preserveWithoutPrivateUHDR
        case 7: return .preserveWithoutPrivateHDR
        case 8: return .preserveNoUHDR
        case 9: return .preserveNoHDR
        default:
            return compatibility.wantsOppoCompat ? .preserve : .preserveWithoutPrivateHDR
        }
    }
}

private final class CancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledIDs = Set<String>()

    func cancel(requestID: String) {
        lock.lock()
        cancelledIDs.insert(requestID)
        lock.unlock()
    }

    func takeCancellation(for requestID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledIDs.remove(requestID) != nil
    }
}
