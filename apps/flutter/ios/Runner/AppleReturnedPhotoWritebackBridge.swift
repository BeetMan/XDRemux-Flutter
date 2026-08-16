import CoreGraphics
import Foundation
import ImageIO

/// The ISO gain-map auxiliary data type is only exposed by ImageIO starting
/// with iOS 18 (macOS 15). On older iOS runtimes the writeback still restores
/// the watermark canvas and the OPPO footer, but cannot carry the returned
/// file's ISO gain map through the recompression.
private let iosGainMapAuxiliaryType: CFString? = {
  if #available(iOS 18.0, *) {
    return kCGImageAuxiliaryDataTypeISOGainMap
  }
  return nil
}()

/// Experimental two-input writeback for a returned Apple Photos image.
///
/// The donor is the untouched OPPO HEIC. The returned image is the flattened
/// iPhone/Photos result. Styles metadata is normally gone by this point, so
/// the bridge restores the donor's OPPO watermark canvas into the returned
/// raster, then keeps the returned file's ISO gain map and metadata. Finally,
/// it can append the donor's complete OPPO footer.
enum AppleReturnedPhotoWritebackBridge {
    struct Report {
        let width: Int
        let height: Int
        let restoredCanvas: CGRect
        let preservedISOGainMap: Bool
        let restoredOppoEntries: [String]
    }

    static func restore(
        originalURL: URL,
        returnedURL: URL,
        outputURL: URL,
        restoreCompleteOppoTail: Bool = true,
        restoreWatermarkCanvas: Bool = true
    ) throws -> Report {
        guard let originalSource = CGImageSourceCreateWithURL(originalURL as CFURL, nil),
              let returnedSource = CGImageSourceCreateWithURL(returnedURL as CFURL, nil),
              let originalImage = CGImageSourceCreateImageAtIndex(originalSource, 0, nil),
              let returnedImage = CGImageSourceCreateImageAtIndex(returnedSource, 0, nil) else {
            throw BridgeError.imageSourceUnavailable
        }

        let width = returnedImage.width
        let height = returnedImage.height
        guard originalImage.width == width, originalImage.height == height else {
            throw BridgeError.dimensionMismatch(
                "donor (originalImage.width)x\(originalImage.height), "
                    + "returned \(width)x\(height)"
            )
        }

        let restoredCanvas: CGRect
        if restoreWatermarkCanvas {
            restoredCanvas = try AppleWatermarkTailBridge.watermarkCanvasRect(
                sourceURL: originalURL,
                imageWidth: width,
                imageHeight: height
            ) ?? CGRect(x: 0, y: height, width: 0, height: 0)
            guard !restoredCanvas.isEmpty else {
                throw BridgeError.watermarkLayoutUnavailable
            }
        } else {
            restoredCanvas = .zero
        }

        guard let colorSpace = returnedImage.colorSpace
                ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            throw BridgeError.bitmapContextUnavailable
        }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw BridgeError.bitmapContextUnavailable
        }

        context.interpolationQuality = .high
        context.draw(
            returnedImage,
            in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        )
        if restoreWatermarkCanvas {
            guard let donorWatermarkCanvas = originalImage.cropping(to: restoredCanvas) else {
                throw BridgeError.watermarkCropUnavailable
            }
            let contextCanvas = CGRect(
                x: restoredCanvas.minX,
                y: CGFloat(height) - restoredCanvas.maxY,
                width: restoredCanvas.width,
                height: restoredCanvas.height
            )
            context.draw(donorWatermarkCanvas, in: contextCanvas)
        }

        guard let composedImage = context.makeImage() else {
            throw BridgeError.bitmapContextUnavailable
        }

        let returnedProperties = CGImageSourceCopyPropertiesAtIndex(returnedSource, 0, nil)
        let returnedGainMap: [String: Any]?
        if let gainMapType = iosGainMapAuxiliaryType,
           let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
             returnedSource,
             0,
             gainMapType
           ) as? [String: Any] {
          returnedGainMap = info
        } else {
          returnedGainMap = nil
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            "public.heic" as CFString,
            1,
            nil
        ) else {
            throw BridgeError.destinationUnavailable
        }
        CGImageDestinationAddImage(destination, composedImage, returnedProperties)
        if let returnedGainMap, let gainMapType = iosGainMapAuxiliaryType {
            CGImageDestinationAddAuxiliaryDataInfo(
                destination,
                gainMapType,
                returnedGainMap as CFDictionary
            )
        }
        guard CGImageDestinationFinalize(destination) else {
            throw BridgeError.destinationFinalizeFailed
        }

        let repackedTail: AppleWatermarkTailBridge.RepackedTail?
        if restoreCompleteOppoTail {
            repackedTail = try AppleWatermarkTailBridge.repackedCompleteTail(
                sourceURL: originalURL
            )
            if let repackedTail {
                try AppleWatermarkTailBridge.appendCompleteTail(
                    repackedTail,
                    to: outputURL
                )
            }
        } else {
            repackedTail = nil
        }

        guard let outputSource = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
              let outputImage = CGImageSourceCreateImageAtIndex(outputSource, 0, nil),
              outputImage.width == width,
              outputImage.height == height else {
            throw BridgeError.outputReadbackFailed
        }
        let outputHasGainMap: Bool
        if let gainMapType = iosGainMapAuxiliaryType {
            outputHasGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                outputSource,
                0,
                gainMapType
            ) != nil
        } else {
            outputHasGainMap = false
        }
        if returnedGainMap != nil && !outputHasGainMap {
            throw BridgeError.gainMapNotPreserved
        }

        return Report(
            width: width,
            height: height,
            restoredCanvas: restoredCanvas,
            preservedISOGainMap: returnedGainMap != nil && outputHasGainMap,
            restoredOppoEntries: repackedTail?.entryNames ?? []
        )
    }

    /// Apple output mode intentionally keeps the returned Photos file byte
    /// intact. This is useful when the user wants Apple editing metadata and
    /// does not need OPPO Gallery compatibility on the next device.
    static func copyAppleOutput(
        from returnedURL: URL,
        to outputURL: URL
    ) throws -> Report {
        guard let source = CGImageSourceCreateWithURL(returnedURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw BridgeError.imageSourceUnavailable
        }
        let data = try Data(contentsOf: returnedURL, options: [.mappedIfSafe])
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: [.atomic])

        let hasGainMap: Bool
        if let gainMapType = iosGainMapAuxiliaryType {
            hasGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                source,
                0,
                gainMapType
            ) != nil
        } else {
            hasGainMap = false
        }
        return Report(
            width: image.width,
            height: image.height,
            restoredCanvas: .zero,
            preservedISOGainMap: hasGainMap,
            restoredOppoEntries: []
        )
    }

    private enum BridgeError: LocalizedError {
        case imageSourceUnavailable
        case dimensionMismatch(String)
        case watermarkLayoutUnavailable
        case bitmapContextUnavailable
        case watermarkCropUnavailable
        case destinationUnavailable
        case destinationFinalizeFailed
        case outputReadbackFailed
        case gainMapNotPreserved

        var errorDescription: String? {
            switch self {
            case .imageSourceUnavailable:
                return "returned-photo writeback could not decode both HEIC inputs"
            case .dimensionMismatch(let message):
                return "returned-photo writeback dimensions differ: \(message)"
            case .watermarkLayoutUnavailable:
                return "returned-photo writeback could not derive the OPPO watermark canvas"
            case .bitmapContextUnavailable:
                return "returned-photo writeback could not create a bitmap context"
            case .watermarkCropUnavailable:
                return "returned-photo writeback could not crop the donor watermark canvas"
            case .destinationUnavailable:
                return "returned-photo writeback could not create a HEIC destination"
            case .destinationFinalizeFailed:
                return "returned-photo writeback HEIC destination failed to finalize"
            case .outputReadbackFailed:
                return "returned-photo writeback output failed ImageIO readback"
            case .gainMapNotPreserved:
                return "returned-photo writeback failed to preserve the returned ISO gain map"
            }
        }
    }
}
