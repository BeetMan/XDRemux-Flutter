import SwiftUI

@main
struct XDRemuxApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .defaultSize(width: 720, height: 520)
        #endif
    }
}
