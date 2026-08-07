import Cocoa
import FlutterMacOS
import XDRemuxFlutterBackend

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

/// A transparent overlay that intercepts file-drop events and forwards
/// them to Flutter via MethodChannel.  All other events pass through to
/// the Flutter view underneath.
private class DropOverlayView: NSView {
  var onDrop: (([String]) -> Void)?

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    if sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) != nil {
      return .copy
    }
    return []
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
      return false
    }
    let paths = items.filter { $0.isFileURL }.map { $0.path }
    onDrop?(paths)
    return !paths.isEmpty
  }

  // Let all other mouse/key events fall through to the Flutter view.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@main
class AppDelegate: FlutterAppDelegate {
  private var dropChannel: FlutterMethodChannel?
  private let swiftProgressStreamHandler = SwiftBackendProgressStreamHandler()

  override func applicationDidFinishLaunching(_ notification: Notification) {
    guard let flutterVC = mainFlutterWindow?.contentViewController as? FlutterViewController,
          let contentView = mainFlutterWindow?.contentView else {
      return
    }
    let flutterView = flutterVC.view

    dropChannel = FlutterMethodChannel(
      name: "xdremux/drop",
      binaryMessenger: flutterVC.engine.binaryMessenger
    )

    let overlay = DropOverlayView(frame: contentView.bounds)
    overlay.autoresizingMask = [.width, .height]
    overlay.registerForDraggedTypes([.fileURL])
    overlay.onDrop = { [weak self] paths in
      self?.dropChannel?.invokeMethod("onFilesDropped", arguments: paths)
    }
    // Place overlay on top so it receives drag events first.
    contentView.addSubview(overlay, positioned: .above, relativeTo: flutterView)

    // The Swift backend is an embedded package call. It never launches the
    // upstream CLI or parses stdout.
    let backendChannel = FlutterMethodChannel(
      name: "xdremux/swift-backend",
      binaryMessenger: flutterVC.engine.binaryMessenger
    )
    let progressChannel = FlutterEventChannel(
      name: "xdremux/swift-backend/progress",
      binaryMessenger: flutterVC.engine.binaryMessenger
    )
    progressChannel.setStreamHandler(swiftProgressStreamHandler)
    backendChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "getCapabilities":
        result(XDRemuxSwiftBackend.capabilities())
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
          let response = XDRemuxSwiftBackend.convert(request) { progress in
            progressStreamHandler?.send(requestID: requestID, progress: progress)
          }
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
            let valid = XDRemuxSwiftBackend.verifyOutput(outputPath)
            let payload: [String: Any] = [
              "success": valid,
              "outputMode": outputMode,
              "outputValid": valid,
              "width": report.width,
              "height": report.height,
              "preservedISOGainMap": report.preservedISOGainMap,
              "restoredOppoEntries": report.restoredOppoEntries,
              "errorMessage": valid ? NSNull() : "returned-photo output validation failed",
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
      case "verifyOutput":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(code: "bad_args", message: "invalid Swift verify args", details: nil))
          return
        }
        result(XDRemuxSwiftBackend.verifyOutput(
          path,
          applePhotographicStyles: (args["applePhotographicStyles"] as? Bool) ?? false,
          applePortrait: (args["applePortrait"] as? Bool) ?? false
        ))
      case "diagnosePortrait":
        guard let args = call.arguments as? [String: Any],
              let inputPath = args["inputPath"] as? String else {
          result(FlutterError(code: "bad_args", message: "invalid Portrait diagnostic args", details: nil))
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let report = XDRemuxSwiftBackend.diagnosePortrait(inputPath)
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
      case "cancel":
        guard let args = call.arguments as? [String: Any],
              let requestID = args["requestId"] as? String else {
          result(FlutterError(code: "bad_args", message: "invalid Swift cancel args", details: nil))
          return
        }
        XDRemuxSwiftBackend.cancel(requestID: requestID)
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Register the hardware-encode MethodChannel (VideoToolbox HEVC).
    let hwChannel = FlutterMethodChannel(
      name: "xdremux/hw-encode",
      binaryMessenger: flutterVC.engine.binaryMessenger
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

    // Register the native thumbnail MethodChannel (ImageIO HEIC decode).
    let thumbChannel = FlutterMethodChannel(
      name: "xdremux/thumbnail",
      binaryMessenger: flutterVC.engine.binaryMessenger
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
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
