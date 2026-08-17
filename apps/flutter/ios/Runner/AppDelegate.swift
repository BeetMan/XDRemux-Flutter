import Flutter
import UIKit
import XDremuxAppleProviders
import XDremuxFlutterBackendIOS

/// Mirrors the macOS SwiftBackendProgressStreamHandler: forwards Swift
/// backend progress events to Dart via the shared event channel contract
/// (xdremux/swift-backend/progress).
private final class SwiftBackendProgressStreamHandler: NSObject, FlutterStreamHandler, @unchecked Sendable {
  private var sink: FlutterEventSink?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  func send(requestID: String, progress: SwiftBackendProgress) {
    let event: [String: Any] = [
      "requestId": requestID,
      "stage": progress.stage,
      "current": progress.current,
      "total": progress.total,
    ]
    DispatchQueue.main.async { [weak self] in
      self?.sink?(event)
    }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Research probe (Phase 0, 2026-08-16): Apple private ABI availability
    // survey - results are settled (18/18 classes present on iOS 27, see
    // docs/validation/ios-device-20260816.md). DEBUG builds only.
    #if DEBUG
    if !UserDefaults.standard.bool(forKey: "xdremux.abiProbe.done") {
      UserDefaults.standard.set(true, forKey: "xdremux.abiProbe.done")
      DispatchQueue.global(qos: .utility).async {
        ApplePrivateAbiProbe.run()
      }
    }
    #endif
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private let swiftProgressStreamHandler = SwiftBackendProgressStreamHandler()

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // iOS Swift backend (Phase 2): install the in-process providers for the
    // upstream helper executables the pipeline otherwise compiles+runs on
    // macOS. Installing the runner only makes the helpers callable; the
    // Flutter-side capability gates stay closed until each feature is
    // verified on-device, so release behavior is unchanged.
    AppleHelperRunner.install()

    // Scene-based lifecycle (FlutterSceneDelegate): the window/root view
    // controller does not exist yet when the implicit engine is initialized,
    // so `window?.rootViewController` is nil here and any channel guarded on
    // it would never register (MissingPluginException from Dart). Use the
    // engine-level messenger instead - channels registered on it work in
    // every scene state.
    let messenger = engineBridge.applicationRegistrar.messenger()

    // Native HEIC thumbnail rendering (ImageIO) for the photo wall.
    let thumbChannel = FlutterMethodChannel(
      name: "xdremux/thumbnail",
      binaryMessenger: messenger
    )
    thumbChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "render":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(code: "bad_args", message: "invalid render args", details: nil))
          return
        }
        let maxPixel = (args["maxPixelSize"] as? Int) ?? 256
        if let jpeg = HeicThumbnailRenderer.thumbnail(forPath: path, maxPixelSize: maxPixel) {
          result(FlutterStandardTypedData(bytes: jpeg))
        } else {
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Capability probe for the embedded Swift backend (vendored upstream
    // v1.3.1 with in-process iOS providers). Photographic Styles is gated
    // on iOS 18+, provider availability, the NeutrinoCore style engine and
    // the private Vision SPI classes; Portrait stays closed on iOS.
    let backendChannel = FlutterMethodChannel(
      name: "xdremux/swift-backend",
      binaryMessenger: messenger
    )
    let progressChannel = FlutterEventChannel(
      name: "xdremux/swift-backend/progress",
      binaryMessenger: messenger
    )
    progressChannel.setStreamHandler(swiftProgressStreamHandler)
    backendChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "getCapabilities":
        result(XDremuxSwiftBackendIOS.capabilities())
      case "convert":
        guard let args = call.arguments as? [String: Any],
              let requestID = args["requestId"] as? String,
              let inputPath = args["inputPath"] as? String,
              let outputPath = args["outputPath"] as? String else {
          result(FlutterError(code: "bad_args", message: "invalid Swift convert args", details: nil))
          return
        }
        let request = SwiftBackendRequest(
          requestID: requestID,
          inputPath: inputPath,
          outputPath: outputPath,
          outputMode: (args["outputMode"] as? String) ?? "oppo",
          oppoCompatibility: (args["oppoCompat"] as? Int) ?? 0,
          oppoCameraTail: (args["oppoCameraTail"] as? Int) ?? 255,
          strictTmap: (args["strictTmap"] as? Bool) ?? false,
          applePhotographicStyles: (args["applePhotographicStyles"] as? Bool) ?? false,
          applePortrait: (args["applePortrait"] as? Bool) ?? false,
          appleWatermarkPolicy: (args["appleWatermarkPolicy"] as? String) ?? "preserve"
        )
        let progressStreamHandler = self?.swiftProgressStreamHandler
        DispatchQueue.global(qos: .userInitiated).async {
          let response = XDremuxSwiftBackendIOS.convert(request) { progress in
            progressStreamHandler?.send(requestID: requestID, progress: progress)
          }
          print("[XDRemux][swift] convert success=\(response.success) "
            + "outputValid=\(response.outputValid.map { "\($0)" } ?? "nil") "
            + "error=\(response.errorMessage ?? "nil")")
          let payload: [String: Any] = [
            "success": response.success,
            "cancelled": response.cancelled,
            "outputValid": response.outputValid.map { $0 as Any } ?? NSNull(),
            "errorMessage": response.errorMessage.map { $0 as Any } ?? NSNull(),
          ]
          DispatchQueue.main.async {
            result(payload)
          }
        }
      case "verifyOutput":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(code: "bad_args", message: "invalid verifyOutput args", details: nil))
          return
        }
        result(XDremuxSwiftBackendIOS.verifyOutput(
          path,
          applePhotographicStyles: (args["applePhotographicStyles"] as? Bool) ?? false,
          applePortrait: (args["applePortrait"] as? Bool) ?? false
        ))
      case "cancel":
        if let args = call.arguments as? [String: Any],
           let requestID = args["requestId"] as? String {
          XDremuxSwiftBackendIOS.cancel(requestID: requestID)
        }
        result(true)
      case "diagnosePortrait":
        guard let args = call.arguments as? [String: Any],
              let inputPath = args["inputPath"] as? String else {
          result(FlutterError(code: "bad_args", message: "invalid Portrait diagnostic args", details: nil))
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let report: [String: Any]
          do {
            report = try PortraitDepthDiagnostics.report(
              for: URL(fileURLWithPath: inputPath).standardizedFileURL)
          } catch {
            report = [
              "schema": PortraitDepthDiagnostics.schema,
              "inputPath": inputPath,
              "available": false,
              "safeToTransform": false,
              "classification": "diagnostic-error",
              "error": String(describing: error),
            ]
          }
          DispatchQueue.main.async {
            result(report)
          }
        }
      case "researchPortrait":
        guard let args = call.arguments as? [String: Any],
              let inputPaths = args["inputPaths"] as? [String],
              !inputPaths.isEmpty,
              let outputDirectory = args["outputDirectory"] as? String else {
          result(FlutterError(
            code: "bad_args",
            message: "invalid Portrait research args",
            details: nil
          ))
          return
        }
        let variantSpecs = (args["variants"] as? [String])
          ?? PortraitCalibrationResearch.defaultVariantSpecs
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            let manifest = try PortraitCalibrationResearch.runEmbedded(
              inputs: inputPaths.map { URL(fileURLWithPath: $0) },
              outputDirectory: URL(fileURLWithPath: outputDirectory, isDirectory: true),
              variantSpecs: variantSpecs
            )
            DispatchQueue.main.async {
              result(manifest)
            }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(
                code: "portrait_research_failed",
                message: String(describing: error),
                details: nil
              ))
            }
          }
        }
      case "writebackReturnedPhoto":
        guard let args = call.arguments as? [String: Any],
              let returnedPath = args["returnedPath"] as? String,
              let outputPath = args["outputPath"] as? String,
              let outputMode = args["outputMode"] as? String,
              outputMode == "oppo" || outputMode == "apple" else {
          result(FlutterError(
            code: "bad_args",
            message: "invalid returned-photo writeback args",
            details: nil
          ))
          return
        }
        let originalPath = args["originalPath"] as? String
        let restoreWatermark = (args["restoreWatermark"] as? Bool) ?? true
        if outputMode == "oppo" && originalPath == nil {
          result(FlutterError(
            code: "bad_args",
            message: "OPPO output mode requires the untouched donor photo",
            details: nil
          ))
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            let report: AppleReturnedPhotoWritebackBridge.Report
            if outputMode == "oppo" {
              report = try AppleReturnedPhotoWritebackBridge.restore(
                originalURL: URL(fileURLWithPath: originalPath!),
                returnedURL: URL(fileURLWithPath: returnedPath),
                outputURL: URL(fileURLWithPath: outputPath),
                restoreCompleteOppoTail: true,
                restoreWatermarkCanvas: restoreWatermark
              )
            } else if restoreWatermark, let originalPath {
              report = try AppleReturnedPhotoWritebackBridge.restore(
                originalURL: URL(fileURLWithPath: originalPath),
                returnedURL: URL(fileURLWithPath: returnedPath),
                outputURL: URL(fileURLWithPath: outputPath),
                restoreCompleteOppoTail: false,
                restoreWatermarkCanvas: true
              )
            } else {
              report = try AppleReturnedPhotoWritebackBridge.copyAppleOutput(
                from: URL(fileURLWithPath: returnedPath),
                to: URL(fileURLWithPath: outputPath)
              )
            }
            // The bridge itself validates the output via ImageIO readback
            // (dimensions + ISO gain-map preservation); it throws instead of
            // returning an invalid file. There is no linked Swift Core
            // validator on iOS, so the readback report is the validation.
            let payload: [String: Any] = [
              "success": true,
              "outputMode": outputMode,
              "outputValid": true,
              "width": report.width,
              "height": report.height,
              "preservedISOGainMap": report.preservedISOGainMap,
              "restoredOppoEntries": report.restoredOppoEntries,
              "errorMessage": NSNull(),
            ]
            DispatchQueue.main.async {
              result(payload)
            }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(
                code: "writeback_failed",
                message: String(describing: error),
                details: nil
              ))
            }
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Hardware HEVC encoding for gain-map tiles (VideoToolbox).
    let hwChannel = FlutterMethodChannel(
      name: "xdremux/hw-encode",
      binaryMessenger: messenger
    )
    hwChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "canEncode":
        result(VideoToolboxHevcEncoder.canEncode420())
      case "reset":
        VideoToolboxHevcEncoder.isFirstTile = true
        result(true)
      case "encodeTile":
        guard let args = call.arguments as? [String: Any],
              let yuv = args["yuv"] as? FlutterStandardTypedData,
              let width = args["width"] as? Int,
              let height = args["height"] as? Int else {
          result(FlutterError(code: "bad_args", message: "invalid encodeTile args", details: nil))
          return
        }
        let encoded = VideoToolboxHevcEncoder.encodeTile(
          yuv: yuv.data, width: width, height: height)
        if let encoded = encoded {
          result(FlutterStandardTypedData(bytes: encoded))
        } else {
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
