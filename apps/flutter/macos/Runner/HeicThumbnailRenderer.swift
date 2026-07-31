import Foundation
import ImageIO
import CoreImage
import CoreGraphics
import UniformTypeIdentifiers

/// Native HEIC thumbnail rendering for the photo wall.
///
/// macOS-only. Decodes the full-resolution HEIC via ImageIO (crisper than the
/// Rust EXIF-embedded JPEG thumbnail). For ISO 21496-1 files (our converted
/// output) we additionally apply an approximate HDR boost derived from the
/// gain-map tone parameters, so the photo wall shows the HDR effect — while
/// the untouched source file stays SDR, giving a visible before/after contrast.
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

        // Approximate HDR boost for files that carry an ISO gain-map metadata
        // block. Source OPPO ProXDR files (no standard aux) stay SDR.
        let headroom = hdrHeadroom(from: src)
        let image = headroom > 1.0 ? hdrBoost(cg, headroom: headroom) : cg
        return encodeJPEG(image)
    }

    /// Read the gain-map `AlternateHeadroom` from the ISO 21496-1 aux metadata.
    /// Returns 1.0 (no boost) when the file has no usable gain map.
    private static func hdrHeadroom(from src: CGImageSource) -> Double {
        // kCGImageAuxiliaryDataTypeISOGainMap requires macOS 15+.
        guard #available(macOS 15.0, *) else { return 1.0 }
        guard let aux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            src, 0, kCGImageAuxiliaryDataTypeISOGainMap as CFString
        ) as? [CFString: Any],
        let meta = aux[kCGImageAuxiliaryDataInfoMetadata] else {
            return 1.0
        }
        // The metadata prints as an NSObject description like
        // "HDRToneMap:AlternateHeadroom = 2.300450". Parse the numeric value.
        let s = String(describing: meta)
        guard let range = s.range(of: "AlternateHeadroom = ") else { return 1.0 }
        let tail = s[range.upperBound...]
        let numStr = tail.prefix(while: { $0.isNumber || $0 == "." })
        guard let headroom = Double(numStr), headroom.isFinite, headroom > 1.0 else {
            return 1.0
        }
        return headroom
    }

    /// Apply an approximate HDR boost: expand highlights using a soft knee,
    /// scaled by the gain-map headroom. Pure CoreImage (GPU), no per-pixel loop.
    private static func hdrBoost(_ cg: CGImage, headroom: Double) -> CGImage {
        let ci = CIImage(cgImage: cg)
        // Boost factor: higher headroom -> stronger highlight expansion.
        // Clamp to a sane range (2.0–3.5 for typical OPPO images).
        let boost = min(max(headroom, 1.5), 4.0)
        // A color matrix that lifts highlights non-linearly is hard to express
        // with a single matrix; use a gamma curve tuned so mid-tones stay near
        // and highlights bloom. gamma < 1 brightens.
        let gamma = 1.0 / (1.0 + (boost - 1.0) * 0.35)
        let filter = CIFilter(name: "CIGammaAdjust")
        filter?.setValue(ci, forKey: kCIInputImageKey)
        filter?.setValue(gamma, forKey: "inputPower")
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let filter = filter, let out = filter.outputImage,
              let result = ctx.createCGImage(out, from: ci.extent) else {
            return cg
        }
        return result
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
