import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Minimum window size — allow a narrow phone-like portrait ratio; the
    // photo-wall grid adapts its column count so the UI never overlaps.
    self.minSize = NSSize(width: 480, height: 800)
    self.contentMinSize = NSSize(width: 480, height: 800)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
