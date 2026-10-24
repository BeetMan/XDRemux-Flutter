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
        guard let cg = CGImageSourceCreateThumbnailAtIndex(
            src, 0, options as CFDictionary
        ) else {
            return nil
        }
        guard let data = encodeJPEG(normalized(cg)) else { return nil }
        // iOS decodes some HDR HEICs (HEIF with a large `Headroom`, e.g. iPhone
        // HDR photos) to a black frame that re-encodes to a black JPEG. Report
        // failure instead so the Dart layer falls back to the Rust preview,
        // rather than rendering a black card on the photo wall.
        if isBlack(data) { return nil }
        return data
    }

    /// Draw the thumbnail into an explicit 8-bit sRGB buffer before JPEG
    /// encoding.
    ///
    /// ImageIO hands back `CGImage`s with `colorSpace == nil` for some HDR
    /// HEICs (wide-gamut / gain-map sources such as iPhone HDR photos).
    /// Handing such an image straight to the JPEG encoder produces an
    /// all-black JPEG on iOS, which surfaced as black photo-wall cards.
    /// Drawing through a device-independent sRGB context materializes the
    /// pixels and gives the encoder a valid color space; it also puts 10-bit
    /// HDR pixels through CoreGraphics' tone mapping.
    private static func normalized(_ image: CGImage) -> CGImage {
        if image.colorSpace != nil && image.bitsPerComponent == 8 {
            return image
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return ctx.makeImage() ?? image
    }

    /// Cheap "is this JPEG essentially black" probe, used to reject the
    /// degenerate frames iOS produces for some HDR HEICs.
    private static func isBlack(_ jpeg: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            return false
        }
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { return false }
        var sum = 0
        for i in stride(from: 0, to: side * side * 4, by: 4) {
            sum += Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
        }
        return sum / (side * side * 3) < 6
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
