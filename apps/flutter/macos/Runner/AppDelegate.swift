import Cocoa
import FlutterMacOS

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

    // Capability probe for the backend abstraction. The Swift Core is not
    // linked in P0.0, so report that explicitly instead of falling back to a
    // Swift CLI subprocess (which is not suitable for the production bridge).
    let backendChannel = FlutterMethodChannel(
      name: "xdremux/swift-backend",
      binaryMessenger: flutterVC.engine.binaryMessenger
    )
    backendChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "getCapabilities":
        result([
          "swiftAvailable": false,
          "swiftStandardHdr": false,
          "swiftAppleFeatures": false,
          "swiftUnavailableReason":
            "Swift Core 尚未作为嵌入式 Library 链接；当前版本不会启动 Swift CLI。"
        ])
      case "convert":
        result(FlutterError(
          code: "swift_backend_unavailable",
          message: "Swift Core 尚未链接到当前 macOS 构建。",
          details: nil
        ))
      case "verifyOutput":
        result(false)
      case "cancel":
        // Reserved for native cancellation once Swift Core is linked.
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
