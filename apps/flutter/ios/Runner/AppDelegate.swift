import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let controller = window?.rootViewController as? FlutterViewController else {
      return
    }

    // Native HEIC thumbnail rendering (ImageIO) for the photo wall.
    let thumbChannel = FlutterMethodChannel(
      name: "xdremux/thumbnail",
      binaryMessenger: controller.binaryMessenger
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

    // Capability probe for the embedded Swift backend. iOS must never spawn
    // the Swift CLI; until a Swift Core framework is linked, keep this
    // backend unavailable and let Flutter show the verified status.
    let backendChannel = FlutterMethodChannel(
      name: "xdremux/swift-backend",
      binaryMessenger: controller.binaryMessenger
    )
    backendChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "getCapabilities":
        result([
          "swiftAvailable": false,
          "swiftStandardHdr": false,
          "swiftAppleFeatures": false,
          "swiftPhotographicStyles": false,
          "swiftPortrait": false,
          "swiftPortraitResearch": false,
          "swiftUnavailableReason":
            "iOS 当前未链接 Swift Core；上游 v1.3.1 Package 只声明 macOS 15，iOS 不启动 Swift CLI。",
          "swiftAppleFeaturesUnavailableReason":
            "iOS 暂不开放 Apple Styles/Portrait：当前上游实现包含 macOS AppKit、NeutrinoCore 私有框架、Process/xcrun 和 macOS-only 工具链；需拆分为嵌入式 Library 并完成真机验证。"
        ])
      case "convert":
        result(FlutterError(
          code: "swift_backend_unavailable",
          message: "Swift Core 尚未链接到当前 iOS 构建。",
          details: nil
        ))
      case "verifyOutput":
        result(false)
      case "cancel":
        result(true)
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
      binaryMessenger: controller.binaryMessenger
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
