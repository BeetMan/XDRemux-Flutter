import Foundation

/// App-group folder the Share Extension drops photos into; the app drains it
/// on launch and whenever it becomes active. Shared source between the app
/// and the extension targets.
enum SharedInbox {
    static let appGroup = "group.io.github.beetman.xdremux.swiftui"

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Files waiting in the inbox, oldest first.
    static func pending() -> [URL] {
        guard let directory,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return da < db
        }
    }

    /// `<stem> (n).<ext>` when `url` already exists.
    static func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let stem = url.deletingPathExtension().lastPathComponent
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(stem) (\(n)).\(url.pathExtension)")
            n += 1
        }
        return candidate
    }
}
