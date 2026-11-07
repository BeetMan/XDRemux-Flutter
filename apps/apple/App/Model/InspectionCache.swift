import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XDRemuxKit
import XDRemuxModel

/// What `LibraryModel.inspect` learned about a photo, kept on disk so a
/// relaunch restores the list without re-reading every input through the
/// core and re-decoding every thumbnail. Lives under Caches: a purge just
/// means the next launch inspects again.
struct InspectionSnapshot: Codable, Equatable {
    // 2: inspection failures carry the explained message, not the core's.
    static let version = 2
    var version = InspectionSnapshot.version
    var classification: Classification?
    var inspection: ConversionReport?
    var details: PhotoDetails?
    var motionPhoto: MotionPhotoInfo?
    var huawei: HuaweiPhotoInfo?
    /// Not a ProXDR source (another phone's photo, a plain HEIC, a file the
    /// app already converted): converts only through the Styles SDR path.
    var plainSource: Bool?
}

struct InspectionCache: Sendable {
    let root: URL

    private func json(_ id: PhotoItem.ID) -> URL { root.appendingPathComponent("\(id.uuidString).json") }
    private func thumb(_ id: PhotoItem.ID) -> URL { root.appendingPathComponent("\(id.uuidString).jpg") }

    func store(_ id: PhotoItem.ID, snapshot: InspectionSnapshot, thumbnail: CGImage?) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: json(id), options: .atomic)
        }
        if let thumbnail,
           let destination = CGImageDestinationCreateWithURL(thumb(id) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            CGImageDestinationFinalize(destination)
        }
    }

    /// Both halves or nothing: a snapshot without its thumbnail would show
    /// a placeholder tile until the next full inspection.
    func load(_ id: PhotoItem.ID) -> (InspectionSnapshot, CGImage)? {
        guard let data = try? Data(contentsOf: json(id)),
              let snapshot = try? JSONDecoder().decode(InspectionSnapshot.self, from: data),
              snapshot.version == InspectionSnapshot.version,
              let source = CGImageSourceCreateWithURL(thumb(id) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (snapshot, image)
    }

    func remove(_ id: PhotoItem.ID) {
        try? FileManager.default.removeItem(at: json(id))
        try? FileManager.default.removeItem(at: thumb(id))
    }
}
