import CoreGraphics
import Foundation
import ImageIO

/// ImageIO helpers shared by iOS and macOS (the Flutter runners carried one
/// copy each in `HeicThumbnailRenderer.swift`). ImageIO decodes HEVC HEIC on
/// both platforms, including the 4:4:4 screenshots the Rust decoder rejects.
public enum ImageLoading {
    /// SDR thumbnail, orientation applied, long edge ≤ `maxPixelSize`.
    public static func thumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Full-size decode with the gain map applied so SwiftUI can show the
    /// HDR result via `.allowedDynamicRange(.high)` (iOS 17 / macOS 14).
    /// Falls back to SDR when the decoder cannot produce HDR content.
    public static func hdrImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Pixel size from the container header without decoding.
    public static func pixelSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: w, height: h)
    }
}
