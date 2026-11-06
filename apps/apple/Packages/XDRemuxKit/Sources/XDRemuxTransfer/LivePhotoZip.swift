import Foundation

/// LocalSend moves files, not folders, so the Flutter app sends a `.pvt`
/// Live Photo bundle as `<stem>.pvt.zip` with flat entries under
/// `<stem>.pvt/`. Mirrors `transfer_live_photo.dart`.
public enum LivePhotoZip {
    public enum Failure: Error, Equatable { case invalidLivePhoto, alreadyExists }

    public struct Parts: Equatable, Sendable {
        public var bundle: URL
        public var still: URL
        public var movie: URL
    }

    public static func isLivePhotoZip(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".pvt.zip")
    }

    /// `IMG_0001.pvt.zip` → `IMG_0001.pvt`.
    public static func bundleName(_ name: String) -> String {
        String(name.dropLast(4))
    }

    /// Validates the layout like the Flutter app does: every file entry is
    /// `<bundle>/<file>` with no hidden names, exactly one still and one MOV.
    private static func fileEntries(_ archive: ZipArchive, bundleName: String) throws -> [ZipArchive.Entry] {
        var files: [ZipArchive.Entry] = []
        for entry in archive.entries {
            let parts = entry.name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if entry.isDirectory {
                guard parts.filter({ !$0.isEmpty }).joined(separator: "/") == bundleName else { throw Failure.invalidLivePhoto }
                continue
            }
            guard parts.count == 2, parts[0] == bundleName, !parts[1].isEmpty,
                  !parts[1].hasPrefix("."), !parts[1].contains("\\") else { throw Failure.invalidLivePhoto }
            files.append(entry)
        }
        return files
    }

    private static func leaf(_ entry: ZipArchive.Entry) -> String {
        String(entry.name.split(separator: "/").last ?? "")
    }

    private static func pick(_ names: [String], _ extensions: Set<String>) -> String? {
        let hits = names.filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
        return hits.count == 1 ? hits[0] : nil
    }

    /// Unpacks `zip` (received as `name`) into `directory/<stem>.pvt`.
    public static func unpack(_ zip: URL, name: String, into directory: URL) throws -> Parts {
        let bundleName = bundleName(name)
        let bundle = directory.appendingPathComponent(bundleName, isDirectory: true)
        if FileManager.default.fileExists(atPath: bundle.path) { throw Failure.alreadyExists }
        let archive = try ZipArchive(url: zip)
        let files = try fileEntries(archive, bundleName: bundleName)
        let names = files.map(leaf)
        guard let still = pick(names, LivePhotoPairing.stillExtensions), let movie = pick(names, ["mov"]) else {
            throw Failure.invalidLivePhoto
        }
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        do {
            for entry in files {
                try archive.extract(entry, to: bundle.appendingPathComponent(leaf(entry)))
            }
        } catch {
            try? FileManager.default.removeItem(at: bundle)
            throw error
        }
        return Parts(bundle: bundle, still: bundle.appendingPathComponent(still), movie: bundle.appendingPathComponent(movie))
    }

    /// Writes only the still into `directory`, for a preview.
    public static func extractStill(_ zip: URL, into directory: URL) throws -> URL {
        let archive = try ZipArchive(url: zip)
        let stills = archive.entries.filter { entry in
            let parts = entry.name.split(separator: "/").map(String.init)
            return !entry.isDirectory && parts.count == 2 && parts[0].lowercased().hasSuffix(".pvt")
                && !parts[1].hasPrefix(".") && LivePhotoPairing.stillExtensions.contains((parts[1] as NSString).pathExtension.lowercased())
        }
        guard stills.count == 1 else { throw Failure.invalidLivePhoto }
        let url = directory.appendingPathComponent(leaf(stills[0]))
        try archive.extract(stills[0], to: url)
        return url
    }
}
