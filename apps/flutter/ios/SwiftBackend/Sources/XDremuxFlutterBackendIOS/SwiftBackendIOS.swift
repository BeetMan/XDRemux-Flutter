import Foundation

#if canImport(UIKit)
import UIKit
import XDremuxAppleFeatures
import XDremuxAppleProviders
import XDRemuxCore

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

/// iOS bridge around the vendored Swift Core / AppleFeatures libraries.
///
/// Capability semantics differ from macOS: instead of checking
/// /usr/bin/xcrun and /usr/bin/zstd, iOS requires the in-process helper
/// providers (installed by the host app via AppleHelperRunner.install())
/// and the private ABI surface the helpers probe. Photographic Styles is
/// additionally gated on iOS 18+ (ISO gain-map HEIF authoring) and the
/// presence of the private Vision SPI classes the semantic matte helper
/// resolves at runtime.
public enum XDremuxSwiftBackendIOS {
    private static let state = CancellationState()
    private static let capabilitiesLock = NSLock()
    private static var cachedCapabilities: [String: Any]?

    public static func capabilities() -> [String: Any] {
        capabilitiesLock.lock()
        defer { capabilitiesLock.unlock() }
        if let cachedCapabilities {
            return cachedCapabilities
        }

        let providersInstalled = AppleNativeToolchain.inProcessRunner != nil
        let ios18Plus = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 18, minorVersion: 0, patchVersion: 0))
        let neutrinoCorePresent = NSClassFromString("_NUSemanticStyleProperties") != nil
        let visionSPIAvailable =
            NSClassFromString("VNGenerateHumanAttributesSegmentationRequest") != nil
            && NSClassFromString("VNGenerateSkySegmentationRequest") != nil

        let stylesAvailable =
            providersInstalled && ios18Plus && neutrinoCorePresent && visionSPIAvailable
        let stylesReason: String
        if !providersInstalled {
            stylesReason = "iOS 未安装 in-process Apple helper providers。"
        } else if !ios18Plus {
            stylesReason = "Apple Photographic Styles 需要 iOS 18+（ISO gain map HEIF 写入）。"
        } else if !neutrinoCorePresent {
            stylesReason = "本机缺少 NeutrinoCore（_NUSemanticStyleProperties 不可用）。"
        } else {
            stylesReason = visionSPIAvailable
                ? "Photographic Styles 为实验性能力，尚未完成 Apple Photos 全流程验收。"
                : "本机 Vision 私有语义分割 SPI 不可用。"
        }

        let standardHdrAvailable = providersInstalled && ios18Plus
        let standardReason = standardHdrAvailable
            ? ""
            : "Swift 标准 HDR 需要 iOS 18+ 且已安装 in-process providers。"

        let result: [String: Any] = [
            "swiftAvailable": providersInstalled,
            "swiftStandardHdr": standardHdrAvailable,
            "swiftAppleFeatures": stylesAvailable,
            "swiftPhotographicStyles": stylesAvailable,
            // Portrait stays closed on iOS: the rear.depth disparity
            // calibration research line has not converged (P0.2.x on
            // macOS); the embedded zstd decoder is in place but the
            // transform itself is unproven.
            "swiftPortrait": false,
            "swiftPortraitResearch": false,
            "swiftPackageVersion": "1.3.1-ios",
            "swiftDeploymentTarget": "iOS 15 (styles require iOS 18)",
            "swiftUnavailableReason": standardReason,
            "swiftAppleFeaturesUnavailableReason": stylesAvailable
                ? ""
                : stylesReason,
        ]
        cachedCapabilities = result
        return result
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
                    errorMessage: "Apple Portrait 在 iOS 上尚未开放（disparity 标定研究中）。"
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

        progress(SwiftBackendProgress(stage: 1, current: 0, total: 1))
        do {
            let conversionRequest = ConversionRequest(
                input: InputSource(url: inputURL),
                output: OutputDestination(url: outputURL),
                configuration: configuration
            )
            if configuration.appleFeaturesEnabled {
                _ = try AppleFeatureConversionEngine.convert(conversionRequest)
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
#endif
