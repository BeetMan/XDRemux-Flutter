import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Native HEIC thumbnail rendering for the photo wall (iOS).
///
/// Rust's `xdremux_extract_thumbnail` returns the EXIF-embedded JPEG which is
/// typically a tiny (160×120-ish) preview, so the photo wall looks low-res.
/// On iOS we decode the full-resolution HEIC via ImageIO and downsample it to
/// a crisp thumbnail. ImageIO also applies the HDR tone-map / gain-map when
/// creating the thumbnail, so the preview matches the real image.
enum HeicThumbnailRenderer {
    /// Render a JPEG thumbnail of `path`, max `maxPixelSize` on the long edge.
    static func thumbnail(forPath path: String, maxPixelSize: Int) -> Data? {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return nil
        }
        return encodeJPEG(cg)
    }

    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85,
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
