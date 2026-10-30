import Foundation
#if os(macOS)
import AppKit
#endif

/// Where published outputs go. The default is the app's own `outputs/`
/// folder; on macOS the user can pick any folder, which the sandbox lets us
/// keep only through a security-scoped bookmark (plan §3 P3, pulled into P2
/// because it is the basic Mac workflow).
@MainActor
final class OutputLocation {
    static let bookmarkKey = "xdremux.outputDirectoryBookmark"

    private let defaults: UserDefaults
    private var scopedURL: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Resolves the saved bookmark (starting security-scoped access) or
    /// returns `fallback`. Call once per launch.
    func resolve(fallback: URL) -> URL {
        #if os(macOS)
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return fallback }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else {
            defaults.removeObject(forKey: Self.bookmarkKey)
            return fallback
        }
        if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope]) {
            defaults.set(fresh, forKey: Self.bookmarkKey)
        }
        scopedURL = url
        return url
        #else
        return fallback
        #endif
    }

    #if os(macOS)
    /// Lets the user pick a folder; persists a bookmark and returns the URL.
    func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "选择输出目录")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope]) else { return nil }
        scopedURL?.stopAccessingSecurityScopedResource()
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        _ = url.startAccessingSecurityScopedResource()
        scopedURL = url
        return url
    }
    #endif

    /// Back to the app's own folder.
    func reset() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        defaults.removeObject(forKey: Self.bookmarkKey)
    }

    var isCustom: Bool { scopedURL != nil }
}
