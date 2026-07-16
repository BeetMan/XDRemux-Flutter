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
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
