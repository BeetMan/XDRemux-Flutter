import Foundation

/// Batch organizer: copies originals (not conversions) into per-capture-mode
/// folders, Live Photo pairs under their own top folder. Mirrors the Flutter
/// `organize_page.dart` / upstream `categorize` layout:
///
///     <root>/<still folder>/<mode folder>/<name>
///     <root>/<live folder>/<mode folder>/<name> + <name>.mov
///
/// Uncategorizable photos go directly under the still / live folder.
public enum OrganizePlanner {
    public struct Item: Equatable, Sendable {
        public var sourceURL: URL
        /// Capture-mode folder from `xdremux_classify` (`folderName`), nil when
        /// the photo could not be categorized.
        public var folderName: String?
        /// Same-stem MOV that validated as this photo's Live Photo pair.
        public var pairedVideoURL: URL?

        public init(sourceURL: URL, folderName: String? = nil, pairedVideoURL: URL? = nil) {
            self.sourceURL = sourceURL
            self.folderName = folderName
            self.pairedVideoURL = pairedVideoURL
        }

        public var isLivePhoto: Bool { pairedVideoURL != nil }
    }

    public struct Entry: Equatable, Sendable {
        public var item: Item
        public var destination: URL
        public var videoDestination: URL?
        /// The source already sits at its destination; nothing to copy.
        public var isDuplicate: Bool
    }

    public struct Layout: Equatable, Sendable {
        public var stillFolder: String
        public var liveFolder: String
        public init(stillFolder: String, liveFolder: String) {
            self.stillFolder = stillFolder
            self.liveFolder = liveFolder
        }
    }

    /// `<dir>/<stem> (n)<ext>` until the name is neither reserved by another
    /// planned copy nor taken by an existing file other than `keep` itself
    /// (organizing a photo into its own folder is not a collision).
    public static func avoidCollision(directory: URL, stem: String, ext: String,
                                      reserved: Set<String>, keep: URL?,
                                      exists: (URL) -> Bool) -> URL {
        func collides(_ candidate: URL) -> Bool {
            if reserved.contains(candidate.path.lowercased()) { return true }
            guard exists(candidate) else { return false }
            guard let keep else { return true }
            return candidate.standardizedFileURL.path != keep.standardizedFileURL.path
        }
        let dotExt = ext.isEmpty ? "" : "." + ext
        var candidate = directory.appendingPathComponent(stem + dotExt)
        var n = 2
        while collides(candidate) {
            candidate = directory.appendingPathComponent("\(stem) (\(n))\(dotExt)")
            n += 1
        }
        return candidate
    }

    /// Plans every item's destination under `root`, avoiding collisions among
    /// the planned copies and with files already on disk.
    public static func plan(_ items: [Item], root: URL, layout: Layout,
                            exists: (URL) -> Bool) -> [Entry] {
        var reserved = Set<String>()
        var videoReserved = Set<String>()
        return items.map { item in
            var dir = root.appendingPathComponent(item.isLivePhoto ? layout.liveFolder : layout.stillFolder, isDirectory: true)
            if let folder = item.folderName, !folder.isEmpty {
                dir = dir.appendingPathComponent(folder, isDirectory: true)
            }
            let stem = item.sourceURL.deletingPathExtension().lastPathComponent
            let ext = item.sourceURL.pathExtension
            let destination = avoidCollision(directory: dir, stem: stem, ext: ext, reserved: reserved,
                                             keep: item.sourceURL, exists: exists)
            reserved.insert(destination.path.lowercased())
            var videoDestination: URL?
            if let video = item.pairedVideoURL {
                let v = avoidCollision(directory: dir, stem: stem, ext: "mov", reserved: videoReserved,
                                       keep: video, exists: exists)
                videoReserved.insert(v.path.lowercased())
                videoDestination = v
            }
            let duplicate = destination.standardizedFileURL.path == item.sourceURL.standardizedFileURL.path
            return Entry(item: item, destination: destination, videoDestination: videoDestination, isDuplicate: duplicate)
        }
    }

    public struct Outcome: Equatable, Sendable {
        public var copied = 0
        public var skipped = 0
        public var failed: [(URL, String)] = []
        public static func == (a: Outcome, b: Outcome) -> Bool {
            a.copied == b.copied && a.skipped == b.skipped && a.failed.map(\.0) == b.failed.map(\.0)
        }
    }

    /// Copies each planned entry; duplicates are skipped, the paired MOV is
    /// copied only when it moves. `copy` creates parent folders as needed.
    public static func execute(_ entries: [Entry], copy: (URL, URL) throws -> Void,
                               progress: (Int, Int) -> Void = { _, _ in }) -> Outcome {
        var outcome = Outcome()
        for (index, entry) in entries.enumerated() {
            defer { progress(index + 1, entries.count) }
            if entry.isDuplicate { outcome.skipped += 1; continue }
            do {
                try copy(entry.item.sourceURL, entry.destination)
                if let video = entry.item.pairedVideoURL, let target = entry.videoDestination,
                   video.standardizedFileURL.path != target.standardizedFileURL.path {
                    try copy(video, target)
                }
                outcome.copied += 1
            } catch {
                outcome.failed.append((entry.item.sourceURL, String(describing: error)))
            }
        }
        return outcome
    }
}
