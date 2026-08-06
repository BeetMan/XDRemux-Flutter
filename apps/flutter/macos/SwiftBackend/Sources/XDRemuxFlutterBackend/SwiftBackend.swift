import Foundation
import XDRemuxCore
import XDRemuxAppleFeatures

public struct SwiftBackendRequest: Sendable {
    public let requestID: String
    public let inputPath: String
    public let outputPath: String
    public let oppoCompatibility: Int
    public let oppoCameraTail: Int
    public let strictTmap: Bool
    public let applePhotographicStyles: Bool
    public let applePortrait: Bool

    public init(
        requestID: String,
        inputPath: String,
        outputPath: String,
        oppoCompatibility: Int,
        oppoCameraTail: Int,
        strictTmap: Bool,
        applePhotographicStyles: Bool = false,
        applePortrait: Bool = false
    ) {
        self.requestID = requestID
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.oppoCompatibility = oppoCompatibility
        self.oppoCameraTail = oppoCameraTail
        self.strictTmap = strictTmap
        self.applePhotographicStyles = applePhotographicStyles
        self.applePortrait = applePortrait
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

    public static func capabilities() -> [String: Any] {
        let xcrunAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun")
        let zstdAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/zstd")
        let selfTestPassed = (try? AppleFeatureConversionEngine.portraitSelfTestReport()) != nil
        // The package can compile and its static Portrait contract can pass
        // while the private Photos renderer used by Photographic Styles has
        // changed on the host OS. Keep this capability conservative: the
        // current macOS 27/Xcode 27 environment failed the real-sample style
        // smoke test because PLPhotoEditSource no longer exposes the selector
        // required by upstream v1.3.1. Do not expose Apple UI until a runtime
        // sample validation passes on the target system.
        let appleFeaturesAvailable = false
        let appleUnavailableReason: String
        if !xcrunAvailable {
            appleUnavailableReason = "AppleFeatures 需要 /usr/bin/xcrun；当前不可用。"
        } else if !selfTestPassed {
            appleUnavailableReason = "AppleFeatures 静态自检失败；当前不可用。"
        } else if !zstdAvailable {
            appleUnavailableReason = "Apple Photographic Styles 尚未通过当前 macOS 的真实样例验证；Apple Portrait 另需要 /usr/bin/zstd。"
        } else {
            appleUnavailableReason = "Apple Photographic Styles 尚未通过当前 macOS 的真实样例验证；当前版本保持实验性功能关闭。"
        }
        return [
            "swiftAvailable": xcrunAvailable,
            "swiftStandardHdr": xcrunAvailable,
            "swiftAppleFeatures": appleFeaturesAvailable,
            "swiftPhotographicStyles": appleFeaturesAvailable,
            "swiftPortrait": appleFeaturesAvailable && zstdAvailable,
            "swiftPackageVersion": "1.3.1",
            "swiftDeploymentTarget": "macOS 15",
            "swiftUnavailableReason": xcrunAvailable
                ? ""
                : "macOS Swift Core requires /usr/bin/xcrun for native tile encoding.",
            "swiftAppleFeaturesUnavailableReason": appleUnavailableReason,
        ]
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
        let oppoCompatibility = mapOppoCompatibility(request.oppoCompatibility)
        let oppoCameraTail = mapOppoCameraTail(
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
        let conversionRequest = ConversionRequest(
            input: InputSource(url: inputURL),
            output: OutputDestination(url: outputURL),
            configuration: configuration
        )

        progress(SwiftBackendProgress(stage: 1, current: 0, total: 1))
        do {
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
