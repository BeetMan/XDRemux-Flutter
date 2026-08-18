import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO

/// The RAW path intentionally exposes a processed-linear candidate, not a
/// claim about untouched sensor samples.  OPPO RAW MAX is known to be a
/// post-JDD RGB-to-Bayer remosaic on the primary branch.
public enum CoreImageRAW {
    public static let algorithmVersion = "coreimage-cirawfilter-neutral-diagonal-wb-v2"
    public static let calibrationVersion = "preview-paired-exposure-diagonal-wb-v2"

    public struct DNGMetadata: Sendable {
        public let endian: String
        public let rawIFDName: String
        public let rawWidth: Int
        public let rawHeight: Int
        public let rawBitsPerSample: [Int]
        public let rawCompression: Int?
        public let rawPhotometricInterpretation: Int?
        public let rawSamplesPerPixel: Int?
        public let rawPlanarConfiguration: Int?
        public let cfaRepeatPatternDim: [Int]
        public let cfaPattern: [Int]
        public let blackLevelRepeatDim: [Int]
        public let blackLevel: [Double]
        public let whiteLevel: [Double]
        public let activeArea: [Int]
        public let defaultCropOrigin: [Double]
        public let defaultCropSize: [Double]
        public let defaultScale: [Double]
        public let bestQualityScale: [Double]
        public let orientation: Int
        public let baselineExposure: Double?
        public let calibrationIlluminant1: Double?
        public let calibrationIlluminant2: Double?
        public let colorMatrix1: [Double]
        public let colorMatrix2: [Double]
        public let cameraCalibration1: [Double]
        public let cameraCalibration2: [Double]
        public let forwardMatrix1: [Double]
        public let forwardMatrix2: [Double]
        public let analogBalance: [Double]
        public let asShotNeutral: [Double]
        public let linearizationTablePresent: Bool
        public let opcodeList1Present: Bool
        public let opcodeList2Present: Bool
        public let opcodeList3Present: Bool
        public let profileHueSatMapPresent: Bool
        public let profileToneCurvePresent: Bool
        public let noiseProfile: [Double]
        public let makerNotePresent: Bool

        public var effectiveBitDepth: Int? {
            guard let white = whiteLevel.max(), white.isFinite, white >= 0 else {
                return nil
            }
            return max(1, Int(ceil(log2(white + 1))))
        }

        public var dictionary: [String: Any] {
            [
                "endian": endian,
                "rawIFD": rawIFDName,
                "rawImageWidth": rawWidth,
                "rawImageHeight": rawHeight,
                "rawBitsPerSample": rawBitsPerSample,
                "effectiveBitDepth": effectiveBitDepth.map { $0 as Any } ?? NSNull(),
                "effectiveBitDepthMethod": "ceil(log2(max(WhiteLevel)+1)); metadata-derived code domain",
                "rawCompression": rawCompression.map { $0 as Any } ?? NSNull(),
                "rawPhotometricInterpretation": rawPhotometricInterpretation.map { $0 as Any } ?? NSNull(),
                "rawSamplesPerPixel": rawSamplesPerPixel.map { $0 as Any } ?? NSNull(),
                "rawPlanarConfiguration": rawPlanarConfiguration.map { $0 as Any } ?? NSNull(),
                "cfaRepeatPatternDim": cfaRepeatPatternDim,
                "cfaPattern": cfaPattern,
                "blackLevelRepeatDim": blackLevelRepeatDim,
                "blackLevel": blackLevel,
                "whiteLevel": whiteLevel,
                "activeArea": activeArea,
                "defaultCropOrigin": defaultCropOrigin,
                "defaultCropSize": defaultCropSize,
                "defaultScale": defaultScale,
                "bestQualityScale": bestQualityScale,
                "orientation": orientation,
                "baselineExposure": baselineExposure.map { $0 as Any } ?? NSNull(),
                "calibrationIlluminant1": calibrationIlluminant1.map { $0 as Any } ?? NSNull(),
                "calibrationIlluminant2": calibrationIlluminant2.map { $0 as Any } ?? NSNull(),
                "colorMatrix1": colorMatrix1,
                "colorMatrix2": colorMatrix2,
                "cameraCalibration1": cameraCalibration1,
                "cameraCalibration2": cameraCalibration2,
                "forwardMatrix1": forwardMatrix1,
                "forwardMatrix2": forwardMatrix2,
                "analogBalance": analogBalance,
                "asShotNeutral": asShotNeutral,
                "linearizationTablePresent": linearizationTablePresent,
                "opcodeList1Present": opcodeList1Present,
                "opcodeList2Present": opcodeList2Present,
                "opcodeList3Present": opcodeList3Present,
                "profileHueSatMapPresent": profileHueSatMapPresent,
                "profileToneCurvePresent": profileToneCurvePresent,
                "noiseProfile": noiseProfile,
                "makerNotePresent": makerNotePresent,
            ]
        }
    }

    public struct EmbeddedPreview: Sendable {
        public let data: Data
        public let offset: Int
        public let length: Int
        public let tagType: Int
        public let tagCount: Int
        public let width: Int
        public let height: Int
        public let orientation: Int
        public let dngOrientation: Int
        public let colorModel: String?
        public let profileName: String?
        public let depth: Int?
        public let exifDateTimeOriginal: String?
        public let hasICCProfile: Bool
        public let sha256: String
    }

    public struct PairValidation: Sendable {
        public let validated: Bool
        public let correlation: Double
        public let toneInvariantCorrelation: Double
        public let normalizedRMSE: Double
        public let alignmentError: Double
        public let previewSize: [Int]
        public let referenceSize: [Int]
        public let orientationMatch: Bool

        public var dictionary: [String: Any] {
            [
                "validated": validated,
                "correlation": correlation,
                "toneInvariantCorrelation": toneInvariantCorrelation,
                "normalizedRMSE": normalizedRMSE,
                "alignmentError": alignmentError,
                "previewSize": previewSize,
                "referenceSize": referenceSize,
                "orientationMatch": orientationMatch,
                "method": "low-resolution normalized luminance correlation; no optical flow",
            ]
        }
    }

    public struct RasterStatistics: Sendable {
        public let minimum: [Double]
        public let maximum: [Double]
        public let mean: [Double]
        public let p01: [Double]
        public let p50: [Double]
        public let p99: [Double]
        public let finite: Bool
        public let clippedHighFraction: [Double]

        public var dictionary: [String: Any] {
            [
                "minimum": minimum,
                "maximum": maximum,
                "mean": mean,
                "p01": p01,
                "p50": p50,
                "p99": p99,
                "finite": finite,
                "clippedHighFraction": clippedHighFraction,
            ]
        }
    }

    public struct DecodeResult: Sendable {
        public let rgbaFloat32: [Float]
        public let rgbaFloat16: Data
        public let normalizedRGBA16: Data
        public let width: Int
        public let height: Int
        public let rawStatistics: RasterStatistics
        public let previewStatistics: RasterStatistics
        public let embeddedPreview: EmbeddedPreview
        public let pairValidation: PairValidation?
        public let filterDefaults: [String: String]
        public let filterEffectiveValues: [String: String]
        public let effectiveScale: Double
        public let calibrationChannelGains: [Double]
        public let calibrationSampleCount: Int
        public let calibrationModel: String
        public let calibrationConfidence: Double
        public let dngSHA256: String
        public let dngMetadata: DNGMetadata
        public let cacheKey: String

        public var provenance: [String: Any] {
            var result: [String: Any] = [
                "linearThumbnailSource": "CIRAWNeutral",
                "rawFileSHA256": dngSHA256,
                "embeddedPreviewSHA256": embeddedPreview.sha256,
                "dngDecodeMode": "coreimage-cirawfilter-neutral",
                "rawIsProcessedRemosaic": true,
                "dngCfaPattern": dngMetadata.cfaPattern.map(String.init).joined(separator: ","),
                "effectiveBitDepth": dngMetadata.effectiveBitDepth.map { $0 as Any } ?? NSNull(),
                "dngMetadata": dngMetadata.dictionary,
                "sceneLinearConfidence": "processed-linear-candidate",
                "remosaicAwareReconstruction": false,
                "cameraProducerExact": false,
                "consumerExactForProvidedLinearInput": false,
                "behaviorEquivalentLinearInputValidated": false,
                "productionEligible": false,
                "calibrationVersion": CoreImageRAW.calibrationVersion,
                "algorithmVersion": CoreImageRAW.algorithmVersion,
                "calibrationConfidence": calibrationConfidence,
                "effectiveExposureScale": effectiveScale,
                "calibrationChannelGains": calibrationChannelGains,
                "calibrationSampleCount": calibrationSampleCount,
                "calibrationModel": calibrationModel,
                "outputColorSpace": "extended-linear-Display-P3",
                "outputFormat": "RGBAf-Float32-and-RGBA16Float",
                "consumerLinearInputFormat": "RGBA16Unorm",
                "cacheKey": cacheKey,
                "dngEmbeddedPreview": [
                    "offset": embeddedPreview.offset,
                    "length": embeddedPreview.length,
                    "tagType": embeddedPreview.tagType,
                    "tagCount": embeddedPreview.tagCount,
                    "width": embeddedPreview.width,
                    "height": embeddedPreview.height,
                    "orientation": embeddedPreview.orientation,
                    "dngOrientation": embeddedPreview.dngOrientation,
                    "colorModel": embeddedPreview.colorModel as Any? ?? NSNull(),
                    "profileName": embeddedPreview.profileName as Any? ?? NSNull(),
                    "depth": embeddedPreview.depth as Any? ?? NSNull(),
                    "exifDateTimeOriginal": embeddedPreview.exifDateTimeOriginal as Any? ?? NSNull(),
                    "hasICCProfile": embeddedPreview.hasICCProfile,
                    "sha256": embeddedPreview.sha256,
                ],
                "rawStatistics": rawStatistics.dictionary,
                "previewStatistics": previewStatistics.dictionary,
                "cirawFilterDefaults": filterDefaults,
                "cirawFilterEffectiveValues": filterEffectiveValues,
                "highlightRecoveryDiagnostic": "available only through explicit diagnostic decode; neutral path disabled",
            ]
            if let pairValidation {
                result["rawPreviewPairValidated"] = pairValidation.validated
                result["rawPreviewAlignmentError"] = pairValidation.alignmentError
                result["rawPreviewPair"] = pairValidation.dictionary
            } else {
                result["rawPreviewPairValidated"] = false
                result["rawPreviewAlignmentError"] = NSNull()
                result["rawPreviewPair"] = NSNull()
            }
            return result
        }
    }

    public enum DecodeError: Error, CustomStringConvertible {
        case invalidDNG(String)
        case missingEmbeddedPreview
        case invalidPreview(String)
        case rawFilterUnavailable
        case rawFilterProducedNoImage
        case invalidTargetSize
        case nonFiniteOutput

        public var description: String {
            switch self {
            case .invalidDNG(let message): return "invalid DNG: \(message)"
            case .missingEmbeddedPreview: return "DNG has no extractable embedded PreviewImage"
            case .invalidPreview(let message): return "invalid embedded preview: \(message)"
            case .rawFilterUnavailable: return "CIRAWFilter cannot open DNG"
            case .rawFilterProducedNoImage: return "CIRAWFilter produced no output image"
            case .invalidTargetSize: return "Core Image RAW target size must be positive"
            case .nonFiniteOutput: return "CIRAWFilter output contains NaN or Inf"
            }
        }
    }

    private struct TIFFTag {
        let tag: Int
        let type: Int
        let count: Int
        let valueOffset: Int
        let valueByteOffset: Int
    }

    private struct TIFFReader {
        let bytes: [UInt8]
        let littleEndian: Bool
        let tiffStart: Int

        func read16(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 2 <= bytes.count else { return nil }
            if littleEndian {
                return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            }
            return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        }

        func read32(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            if littleEndian {
                return Int(bytes[offset])
                    | Int(bytes[offset + 1]) << 8
                    | Int(bytes[offset + 2]) << 16
                    | Int(bytes[offset + 3]) << 24
            }
            return Int(bytes[offset]) << 24
                | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8
                | Int(bytes[offset + 3])
        }

        func read64(_ offset: Int) -> UInt64? {
            guard offset >= 0, offset + 8 <= bytes.count else { return nil }
            var value: UInt64 = 0
            if littleEndian {
                for index in 0..<8 {
                    value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
                }
            } else {
                for index in 0..<8 {
                    value = (value << 8) | UInt64(bytes[offset + index])
                }
            }
            return value
        }

        func typeSize(_ type: Int) -> Int? {
            switch type {
            case 1, 2, 6, 7: return 1
            case 3, 8: return 2
            case 4, 9, 11: return 4
            case 5, 10, 12: return 8
            default: return nil
            }
        }

        func tags(inIFDAtAbsoluteOffset offset: Int) -> [TIFFTag]? {
            guard let count = read16(offset), count <= 4096 else { return nil }
            var tags: [TIFFTag] = []
            tags.reserveCapacity(count)
            for index in 0..<count {
                let entry = offset + 2 + index * 12
                guard let tag = read16(entry),
                      let type = read16(entry + 2),
                      let count = read32(entry + 4),
                      let size = typeSize(type),
                      count >= 0,
                      count <= Int.max / max(size, 1),
                      entry + 12 <= bytes.count else {
                    return nil
                }
                let byteCount = count * size
                let valueByteOffset = byteCount <= 4 ? entry + 8 : (tiffStart + (read32(entry + 8) ?? -1))
                guard valueByteOffset >= 0,
                      valueByteOffset <= bytes.count,
                      byteCount <= bytes.count - valueByteOffset else {
                    return nil
                }
                tags.append(TIFFTag(
                    tag: tag,
                    type: type,
                    count: count,
                    valueOffset: read32(entry + 8) ?? 0,
                    valueByteOffset: valueByteOffset
                ))
            }
            return tags
        }

        func scalar(_ tag: TIFFTag) -> Int? {
            guard tag.count > 0 else { return nil }
            switch tag.type {
            case 3:
                return read16(tag.valueByteOffset)
            case 4:
                return read32(tag.valueByteOffset)
            default:
                return nil
            }
        }

        func values(_ tag: TIFFTag) -> [Double] {
            guard tag.count > 0 else { return [] }
            switch tag.type {
            case 1, 6, 7:
                return (0..<tag.count).map { Double(bytes[tag.valueByteOffset + $0]) }
            case 3:
                return (0..<tag.count).compactMap { read16(tag.valueByteOffset + $0 * 2).map(Double.init) }
            case 4:
                return (0..<tag.count).compactMap { read32(tag.valueByteOffset + $0 * 4).map(Double.init) }
            case 5, 10:
                return (0..<tag.count).compactMap { index in
                    let offset = tag.valueByteOffset + index * 8
                    guard let numerator = read32(offset), let denominator = read32(offset + 4), denominator != 0 else {
                        return nil
                    }
                    if tag.type == 10 {
                        return Double(Int32(bitPattern: UInt32(numerator)))
                            / Double(Int32(bitPattern: UInt32(denominator)))
                    }
                    return Double(numerator) / Double(denominator)
                }
            case 8:
                return (0..<tag.count).compactMap { read16(tag.valueByteOffset + $0 * 2).map { Double(Int16(bitPattern: UInt16($0))) } }
            case 9:
                return (0..<tag.count).compactMap { read32(tag.valueByteOffset + $0 * 4).map { Double(Int32(bitPattern: UInt32($0))) } }
            case 11:
                return (0..<tag.count).compactMap { index in
                    read32(tag.valueByteOffset + index * 4).map { Double(Float(bitPattern: UInt32($0))) }
                }
            case 12:
                return (0..<tag.count).compactMap { index in
                    read64(tag.valueByteOffset + index * 8).map(Double.init(bitPattern:))
                }
            default:
                return []
            }
        }

        func rawIFDMetadata(
            _ tags: [TIFFTag],
            name: String,
            orientation: Int = 1,
            makerNotePresent: Bool = false
        ) -> DNGMetadata? {
            func values(_ tagID: Int) -> [Double] {
                guard let tag = tags.first(where: { $0.tag == tagID }) else { return [] }
                return self.values(tag)
            }
            func ints(_ tagID: Int) -> [Int] {
                values(tagID).map { Int($0.rounded()) }
            }
            func scalar(_ tagID: Int) -> Int? {
                ints(tagID).first
            }
            let width = scalar(0x0100) ?? 0
            let height = scalar(0x0101) ?? 0
            guard width > 0, height > 0 else { return nil }
            let whiteLevel = values(0xC61D)
            return DNGMetadata(
                endian: littleEndian ? "little" : "big",
                rawIFDName: name,
                rawWidth: width,
                rawHeight: height,
                rawBitsPerSample: ints(0x0102),
                rawCompression: scalar(0x0103),
                rawPhotometricInterpretation: scalar(0x0106),
                rawSamplesPerPixel: scalar(0x0115),
                rawPlanarConfiguration: scalar(0x011C),
                cfaRepeatPatternDim: ints(0x828D),
                cfaPattern: ints(0x828E),
                blackLevelRepeatDim: ints(0xC619),
                blackLevel: values(0xC61A),
                whiteLevel: whiteLevel,
                activeArea: ints(0xC68D),
                defaultCropOrigin: values(0xC61F),
                defaultCropSize: values(0xC620),
                defaultScale: values(0xC61E),
                bestQualityScale: values(0xC65C),
                orientation: orientation,
                baselineExposure: values(0xC62A).first,
                calibrationIlluminant1: values(0xC65A).first,
                calibrationIlluminant2: values(0xC65B).first,
                colorMatrix1: values(0xC621),
                colorMatrix2: values(0xC622),
                cameraCalibration1: values(0xC623),
                cameraCalibration2: values(0xC624),
                forwardMatrix1: values(0xC714),
                forwardMatrix2: values(0xC715),
                analogBalance: values(0xC627),
                asShotNeutral: values(0xC628),
                linearizationTablePresent: tags.contains { $0.tag == 0xC618 },
                opcodeList1Present: tags.contains { $0.tag == 0xC740 },
                opcodeList2Present: tags.contains { $0.tag == 0xC741 },
                opcodeList3Present: tags.contains { $0.tag == 0xC74E },
                profileHueSatMapPresent: tags.contains { [0xC6F9, 0xC6FA, 0xC6FB].contains($0.tag) },
                profileToneCurvePresent: tags.contains { $0.tag == 0xC6FC },
                noiseProfile: values(0xC761),
                makerNotePresent: makerNotePresent
            )
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func tiffReader(for data: Data) throws -> TIFFReader {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { throw DecodeError.invalidDNG("TIFF header is truncated") }
        let littleEndian: Bool
        if bytes[0] == 0x49 && bytes[1] == 0x49 {
            littleEndian = true
        } else if bytes[0] == 0x4d && bytes[1] == 0x4d {
            littleEndian = false
        } else {
            throw DecodeError.invalidDNG("unknown TIFF endian marker")
        }
        let reader = TIFFReader(bytes: bytes, littleEndian: littleEndian, tiffStart: 0)
        guard reader.read16(2) == 42 else {
            throw DecodeError.invalidDNG("BigTIFF or unsupported TIFF magic")
        }
        return reader
    }

    private static func dngMetadata(from dngData: Data) throws -> DNGMetadata {
        let reader = try tiffReader(for: dngData)
        guard let firstIFD = reader.read32(4),
              let ifd0 = reader.tags(inIFDAtAbsoluteOffset: firstIFD) else {
            throw DecodeError.invalidDNG("IFD0 is malformed")
        }
        let subIFDOffsets = ifd0.first(where: { $0.tag == 0x014A }).map(reader.values)
            .map { $0.map { Int($0.rounded()) } } ?? []
        let raw: (name: String, tags: [TIFFTag]) = subIFDOffsets.enumerated().compactMap { index, offset in
            guard let tags = reader.tags(inIFDAtAbsoluteOffset: offset),
                  tags.contains(where: { $0.tag == 0x828E }) else { return nil }
            return ("SubIFD[\(index)]", tags)
        }.first ?? ("IFD0", ifd0)
        let exifOffset = ifd0.first(where: { $0.tag == 0x8769 }).flatMap { reader.values($0).first }
            .map { Int($0.rounded()) }
        let makerNotePresent = exifOffset
            .flatMap { reader.tags(inIFDAtAbsoluteOffset: $0) }
            .map { tags in tags.contains { $0.tag == 0x927C } }
            ?? false
        guard let metadata = reader.rawIFDMetadata(
            raw.tags,
            name: raw.name,
            orientation: ifd0.first(where: { $0.tag == 0x0112 }).flatMap(reader.scalar) ?? 1,
            makerNotePresent: makerNotePresent
        ) else {
            throw DecodeError.invalidDNG("RAW SubIFD has no valid dimensions")
        }
        return metadata
    }

    public static func extractDNGMetadata(from dngURL: URL) throws -> DNGMetadata {
        try dngMetadata(from: Data(contentsOf: dngURL, options: [.mappedIfSafe]))
    }

    private static func previewData(from dngData: Data) throws -> EmbeddedPreview {
        let reader = try tiffReader(for: dngData)
        guard let firstIFD = reader.read32(4),
              let tags = reader.tags(inIFDAtAbsoluteOffset: firstIFD) else {
            throw DecodeError.invalidDNG("IFD0 is malformed")
        }
        guard let startTag = tags.first(where: { $0.tag == 0x0111 }),
              let lengthTag = tags.first(where: { $0.tag == 0x0117 }),
              let start = reader.scalar(startTag),
              let length = reader.scalar(lengthTag),
              start >= 0, length > 0, start <= dngData.count,
              length <= dngData.count - start else {
            throw DecodeError.missingEmbeddedPreview
        }
        let preview = dngData.subdata(in: start..<(start + length))
        guard preview.starts(with: Data([0xff, 0xd8])) else {
            throw DecodeError.invalidPreview("PreviewImage is not a JPEG stream")
        }
        guard let source = CGImageSourceCreateWithData(preview as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            throw DecodeError.invalidPreview("ImageIO cannot decode JPEG properties")
        }
        let colorModel = properties[kCGImagePropertyColorModel] as? String
        let profileName = properties["ProfileName" as CFString] as? String
        let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let exifDateTimeOriginal = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let dngOrientation = tags.first(where: { $0.tag == 0x0112 }).flatMap(reader.scalar) ?? 1
        return EmbeddedPreview(
            data: preview,
            offset: start,
            length: length,
            tagType: startTag.type,
            tagCount: startTag.count,
            width: width,
            height: height,
            orientation: orientation,
            dngOrientation: dngOrientation,
            colorModel: colorModel,
            profileName: profileName,
            depth: depth,
            exifDateTimeOriginal: exifDateTimeOriginal,
            hasICCProfile: profileName != nil,
            sha256: sha256(preview)
        )
    }

    public static func extractEmbeddedPreview(from dngURL: URL) throws -> EmbeddedPreview {
        try previewData(from: Data(contentsOf: dngURL, options: [.mappedIfSafe]))
    }

    /// Cache identity is intentionally content-bound.  Callers may persist
    /// research artifacts, but a changed DNG, embedded preview, algorithm, or
    /// calibration revision must never reuse a prior Linear Thumbnail.
    public static func cacheKey(
        dngSHA256: String,
        embeddedPreviewSHA256: String
    ) -> String {
        sha256(Data(
            "\(dngSHA256):\(embeddedPreviewSHA256):\(algorithmVersion):\(calibrationVersion)".utf8
        ))
    }

    /// Check that the embedded preview belongs to the source image being
    /// converted.  The DNG-internal pair check alone would accept a valid RAW
    /// from a different photo, so the SceneBundle performs this second,
    /// low-capacity tone-invariant comparison against its source primary.
    public static func validateEmbeddedPreview(
        _ preview: EmbeddedPreview,
        against referenceImage: CIImage,
        targetWidth: Int,
        targetHeight: Int
    ) throws -> PairValidation {
        guard targetWidth > 0, targetHeight > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
              let previewImage = CIImage(
                  data: preview.data,
                  options: [.applyOrientationProperty: false]
              ) else {
            throw DecodeError.invalidPreview("cannot construct source-reference preview pair")
        }
        let orientedPreview = previewImage.oriented(forExifOrientation: Int32(preview.dngOrientation))
        let context = CIContext(options: [
            .cacheIntermediates: false,
            .useSoftwareRenderer: true,
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
        ])
        let previewPixels = render(
            context: context,
            image: orientedPreview,
            width: targetWidth,
            height: targetHeight,
            colorSpace: colorSpace
        )
        let referencePixels = render(
            context: context,
            image: referenceImage,
            width: targetWidth,
            height: targetHeight,
            colorSpace: colorSpace
        )
        let direct = normalizedCorrelation(luminance(referencePixels), luminance(previewPixels))
        let toneInvariant = normalizedCorrelation(
            toneInvariantLuminance(referencePixels),
            toneInvariantLuminance(previewPixels)
        )
        let displayPreviewSize = [5, 6, 7, 8].contains(preview.dngOrientation)
            ? [preview.height, preview.width]
            : [preview.width, preview.height]
        let previewAspect = Double(displayPreviewSize[0]) / Double(displayPreviewSize[1])
        let referenceAspect = Double(targetWidth) / Double(targetHeight)
        let aspectDelta = abs(previewAspect - referenceAspect) / max(1e-9, previewAspect)
        return PairValidation(
            validated: toneInvariant.correlation >= 0.80
                && direct.correlation >= 0.50
                && aspectDelta <= 0.01,
            correlation: direct.correlation,
            toneInvariantCorrelation: toneInvariant.correlation,
            normalizedRMSE: direct.rmse,
            alignmentError: max(0, 1 - direct.correlation),
            previewSize: displayPreviewSize,
            referenceSize: [targetWidth, targetHeight],
            orientationMatch: true
        )
    }

    private static func filterString(_ value: Any?) -> String {
        guard let value else { return "<nil>" }
        if let number = value as? NSNumber { return number.stringValue }
        if let string = value as? NSString { return String(string) }
        return String(describing: value)
    }

    private static let neutralControlKeys = [
        "inputEV",
        "inputBoost",
        "inputBoostShadowAmount",
        "inputBias",
        "inputBaselineExposure",
        "inputScaleFactor",
        "inputIgnoreOrientation",
        "inputEnableSharpening",
        "inputEnableNoiseTracking",
        "inputEnableVendorLensCorrection",
        "inputNoiseReductionAmount",
        "inputLuminanceNoiseReductionAmount",
        "inputColorNoiseReductionAmount",
        "inputNoiseReductionSharpnessAmount",
        "inputNoiseReductionContrastAmount",
        "inputNoiseReductionDetailAmount",
        "inputMoireAmount",
        "inputDisableGamutMap",
        "inputEnableGamutMap",
        "inputDisableHighlightRecovery",
        "inputEnableHighlightRecovery",
        "inputEnableEDRMode",
        "inputLocalToneMapAmount",
        "inputEnableLocalToneMap",
    ]

    private static func filterValues(_ filter: CIFilter) -> [String: String] {
        var values = Dictionary(uniqueKeysWithValues: filter.inputKeys.map { key in
            (key, filterString(filter.value(forKey: key)))
        })
        for key in neutralControlKeys where values[key] == nil {
            values[key] = "<unsupported>"
        }
        return values
    }

    private static func setIfSupported(_ filter: CIFilter, _ key: String, _ value: Any) {
        guard filter.inputKeys.contains(key) else { return }
        filter.setValue(value, forKey: key)
    }

    private static func neutralize(_ filter: CIFilter, enableHighlightRecovery: Bool) {
        setIfSupported(filter, "inputEV", 0)
        setIfSupported(filter, "inputBoost", 0)
        setIfSupported(filter, "inputBoostShadowAmount", 0)
        setIfSupported(filter, "inputBias", 0)
        setIfSupported(filter, "inputBaselineExposure", 0)
        setIfSupported(filter, "inputScaleFactor", 1.0)
        setIfSupported(filter, "inputIgnoreOrientation", true)
        setIfSupported(filter, "inputEnableSharpening", false)
        setIfSupported(filter, "inputEnableNoiseTracking", false)
        setIfSupported(filter, "inputEnableVendorLensCorrection", false)
        setIfSupported(filter, "inputNoiseReductionAmount", 0)
        setIfSupported(filter, "inputLuminanceNoiseReductionAmount", 0)
        setIfSupported(filter, "inputColorNoiseReductionAmount", 0)
        setIfSupported(filter, "inputNoiseReductionSharpnessAmount", 0)
        setIfSupported(filter, "inputNoiseReductionContrastAmount", 0)
        setIfSupported(filter, "inputNoiseReductionDetailAmount", 0)
        setIfSupported(filter, "inputMoireAmount", 0)
        setIfSupported(filter, "inputDisableGamutMap", true)
        setIfSupported(filter, "inputEnableGamutMap", false)
        setIfSupported(filter, "inputDisableHighlightRecovery", !enableHighlightRecovery)
        setIfSupported(filter, "inputEnableHighlightRecovery", enableHighlightRecovery)
        setIfSupported(filter, "inputEnableEDRMode", false)
        setIfSupported(filter, "inputLocalToneMapAmount", 0)
        setIfSupported(filter, "inputEnableLocalToneMap", false)
    }

    private static func normalized(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(
            translationX: -image.extent.origin.x,
            y: -image.extent.origin.y
        ))
    }

    private static func resized(_ image: CIImage, width: Int, height: Int) -> CIImage {
        let source = normalized(image)
        return source.transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / source.extent.width,
            y: CGFloat(height) / source.extent.height
        )).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private static func render(
        context: CIContext,
        image: CIImage,
        width: Int,
        height: Int,
        colorSpace: CGColorSpace?
    ) -> [Float] {
        var pixels = Array(repeating: Float(0), count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(
                resized(image, width: width, height: height),
                toBitmap: base,
                rowBytes: width * 4 * MemoryLayout<Float>.size,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBAf,
                colorSpace: colorSpace
            )
        }
        return pixels
    }

    private static func statistics(_ pixels: [Float]) -> RasterStatistics {
        let channels = 4
        var minimum = [Double](repeating: .infinity, count: channels)
        var maximum = [Double](repeating: -.infinity, count: channels)
        var sum = [Double](repeating: 0, count: channels)
        var values = Array(repeating: [Double](), count: channels)
        for index in 0..<channels {
            values[index].reserveCapacity(min(200_000, max(1, pixels.count / channels)))
        }
        var finite = true
        let pixelCount = pixels.count / channels
        let stride = max(1, pixelCount / 200_000)
        for pixel in Swift.stride(from: 0, to: pixelCount, by: stride) {
            for channel in 0..<channels {
                let value = Double(pixels[pixel * channels + channel])
                guard value.isFinite else {
                    finite = false
                    continue
                }
                minimum[channel] = min(minimum[channel], value)
                maximum[channel] = max(maximum[channel], value)
                sum[channel] += value
                values[channel].append(value)
            }
        }
        let sampleCount = max(1, values.first?.count ?? 0)
        let percentile: ([Double], Double) -> [Double] = { samples, p in
            guard !samples.isEmpty else { return [Double.nan] }
            let sorted = samples.sorted()
            let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
            return [sorted[index]]
        }
        let p01 = (0..<channels).map { percentile(values[$0], 0.01)[0] }
        let p50 = (0..<channels).map { percentile(values[$0], 0.50)[0] }
        let p99 = (0..<channels).map { percentile(values[$0], 0.99)[0] }
        let clipped = (0..<channels).map { channel in
            let count = values[channel].filter { $0 >= 0.999 }.count
            return Double(count) / Double(sampleCount)
        }
        return RasterStatistics(
            minimum: minimum,
            maximum: maximum,
            mean: sum.map { $0 / Double(sampleCount) },
            p01: p01,
            p50: p50,
            p99: p99,
            finite: finite,
            clippedHighFraction: clipped
        )
    }

    private static func luminance(_ pixels: [Float]) -> [Double] {
        (0..<(pixels.count / 4)).map { index in
            let offset = index * 4
            return 0.22897456 * Double(pixels[offset])
                + 0.69173852 * Double(pixels[offset + 1])
                + 0.07928691 * Double(pixels[offset + 2])
        }
    }

    private static func toneInvariantLuminance(_ pixels: [Float]) -> [Double] {
        luminance(pixels).map { sqrt(max($0, 0)) }
    }

    private static func normalizedCorrelation(
        _ first: [Double],
        _ second: [Double]
    ) -> (correlation: Double, rmse: Double, count: Int) {
        let count = min(first.count, second.count)
        guard count > 0 else { return (0, .infinity, 0) }
        var a: [Double] = []
        var b: [Double] = []
        a.reserveCapacity(count)
        b.reserveCapacity(count)
        for index in 0..<count {
            guard first[index].isFinite, second[index].isFinite else { continue }
            a.append(first[index]); b.append(second[index])
        }
        guard a.count > 1 else { return (0, .infinity, a.count) }
        func range(_ values: [Double]) -> (Double, Double) {
            let sorted = values.sorted()
            let low = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.01))]
            let high = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.99))]
            return (low, max(low + 1e-9, high))
        }
        let ar = range(a), br = range(b)
        let aa = a.map { ($0 - ar.0) / (ar.1 - ar.0) }
        let bb = b.map { ($0 - br.0) / (br.1 - br.0) }
        let am = aa.reduce(0, +) / Double(aa.count)
        let bm = bb.reduce(0, +) / Double(bb.count)
        let numerator = zip(aa, bb).reduce(0) { $0 + ($1.0 - am) * ($1.1 - bm) }
        let denominator = sqrt(
            aa.reduce(0) { $0 + ($1 - am) * ($1 - am) }
                * bb.reduce(0) { $0 + ($1 - bm) * ($1 - bm) }
        )
        let correlation = denominator > 0 ? numerator / denominator : 0
        let rmse = sqrt(zip(aa, bb).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) } / Double(aa.count))
        return (correlation, rmse, aa.count)
    }

    private static func previewPair(
        preview: EmbeddedPreview,
        rawPixels: [Float],
        previewPixels: [Float],
        width: Int,
        height: Int,
        dngMetadata: DNGMetadata
    ) throws -> PairValidation {
        guard rawPixels.count == width * height * 4,
              previewPixels.count == width * height * 4 else {
            throw DecodeError.invalidPreview("RAW and embedded preview raster sizes differ")
        }
        let result = normalizedCorrelation(luminance(rawPixels), luminance(previewPixels))
        let toneInvariant = normalizedCorrelation(
            toneInvariantLuminance(rawPixels),
            toneInvariantLuminance(previewPixels)
        )
        let refSize = [width, height]
        let aspectDelta = abs(
            Double(preview.width) / Double(preview.height)
                - Double(width) / Double(height)
        ) / max(1e-9, Double(preview.width) / Double(preview.height))
        let orientationMatch = preview.orientation == dngMetadata.orientation
            || preview.orientation == 1
            || dngMetadata.orientation == 1
        let validated = toneInvariant.correlation >= 0.80
            && result.correlation >= 0.50
            && aspectDelta <= 0.01
            && preview.width == dngMetadata.rawWidth
            && preview.height == dngMetadata.rawHeight
            && orientationMatch
        return PairValidation(
            validated: validated,
            correlation: result.correlation,
            toneInvariantCorrelation: toneInvariant.correlation,
            normalizedRMSE: result.rmse,
            alignmentError: max(0, 1 - result.correlation),
            previewSize: [preview.width, preview.height],
            referenceSize: refSize,
            orientationMatch: orientationMatch
        )
    }

    private struct Calibration {
        let scale: Double
        let channelGains: [Double]
        let sampleCount: Int
        let confidence: Double
        let model: String
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Estimate only a diagonal color-domain correction from robust, mostly
    /// neutral mid-tone samples.  This is deliberately lower capacity than a
    /// free 3x3/LUT fit: preview tone mapping can change common brightness, but
    /// its mid-tone channel ratios still provide a useful per-photo WB cue.
    private static func calibrate(
        raw: [Float],
        preview: [Float],
        exposure: (scale: Double, confidence: Double)
    ) -> Calibration {
        let count = min(raw.count, preview.count) / 4
        guard count > 0 else {
            return Calibration(
                scale: exposure.scale,
                channelGains: [1, 1, 1],
                sampleCount: 0,
                confidence: exposure.confidence * 0.75,
                model: "exposure-only-no-overlap"
            )
        }
        var ratios = (0..<3).map { _ in [Double]() }
        for channel in ratios.indices {
            ratios[channel].reserveCapacity(min(20_000, count))
        }
        let stride = max(1, count / 200_000)
        for pixel in Swift.stride(from: 0, to: count, by: stride) {
            let offset = pixel * 4
            let rawRGB = (0..<3).map { Double(raw[offset + $0]) }
            let previewRGB = (0..<3).map { Double(preview[offset + $0]) }
            let rawLuma = 0.22897456 * rawRGB[0]
                + 0.69173852 * rawRGB[1]
                + 0.07928691 * rawRGB[2]
            let previewLuma = 0.22897456 * previewRGB[0]
                + 0.69173852 * previewRGB[1]
                + 0.07928691 * previewRGB[2]
            guard rawLuma.isFinite, previewLuma.isFinite,
                  rawLuma > 0.02, rawLuma < 0.75,
                  previewLuma > 0.02, previewLuma < 0.95 else {
                continue
            }
            let rawMin = rawRGB.min() ?? 0
            let rawMax = rawRGB.max() ?? 0
            let previewMin = previewRGB.min() ?? 0
            let previewMax = previewRGB.max() ?? 0
            let rawChroma = (rawMax - rawMin) / max(rawLuma, 1e-6)
            let previewChroma = (previewMax - previewMin) / max(previewLuma, 1e-6)
            guard rawChroma < 0.65, previewChroma < 0.65 else { continue }
            guard (0..<3).allSatisfy({ channel in
                rawRGB[channel] > 0.005
                    && previewRGB[channel] > 0.002
                    && rawRGB[channel].isFinite
                    && previewRGB[channel].isFinite
            }) else { continue }
            for channel in 0..<3 {
                let ratio = previewRGB[channel]
                    / max(rawRGB[channel] * exposure.scale, 1e-6)
                if ratio.isFinite, ratio > 0.1, ratio < 10 {
                    ratios[channel].append(ratio)
                }
            }
        }
        guard let red = median(ratios[0]),
              let green = median(ratios[1]),
              let blue = median(ratios[2]),
              [red, green, blue].allSatisfy({ $0.isFinite && $0 > 0 }),
              green > 0 else {
            return Calibration(
                scale: exposure.scale,
                channelGains: [1, 1, 1],
                sampleCount: ratios.map(\.count).min() ?? 0,
                confidence: exposure.confidence * 0.75,
                model: "exposure-only-no-neutral-samples"
            )
        }
        let medians = [red, green, blue]
        let gains = medians.map { min(max($0 / green, 0.5), 2.0) }
        let robustSpreads = ratios.map { values -> Double in
            guard values.count > 1 else { return 4 }
            let sorted = values.sorted()
            let low = sorted[Int(Double(sorted.count - 1) * 0.10)]
            let high = sorted[Int(Double(sorted.count - 1) * 0.90)]
            return high / max(low, 1e-6)
        }
        let sampleConfidence = min(1, Double(ratios.map(\.count).min() ?? 0) / 5_000)
        let spreadConfidence = robustSpreads
            .map { min(1, 1 / max(1, $0 - 0.25)) }
            .reduce(0, +) / 3
        let confidence = min(1, exposure.confidence * 0.65 + sampleConfidence * spreadConfidence * 0.35)
        return Calibration(
            scale: exposure.scale,
            channelGains: gains,
            sampleCount: ratios.map(\.count).min() ?? 0,
            confidence: confidence,
            model: "exposure-plus-diagonal-preview-paired-WB; constrained-3x3"
        )
    }

    private static func float16RGBA(_ pixels: [Float]) -> Data {
        var output = Data(count: pixels.count * MemoryLayout<UInt16>.size)
        output.withUnsafeMutableBytes { raw in
            guard let destination = raw.bindMemory(to: UInt16.self).baseAddress else { return }
            for index in pixels.indices {
                destination[index] = XDRemuxHalf.encode(pixels[index]).littleEndian
            }
        }
        return output
    }

    private static func normalizedRGBA16(
        _ pixels: [Float],
        scale: Double,
        channelGains: [Double]
    ) -> Data {
        var output = Data(count: pixels.count * MemoryLayout<UInt16>.size)
        output.withUnsafeMutableBytes { raw in
            guard let destination = raw.bindMemory(to: UInt16.self).baseAddress else { return }
            for index in pixels.indices {
                let channel = index % 4
                let gain = channel < 3 && channel < channelGains.count
                    ? channelGains[channel]
                    : 1
                let value = min(max(Double(pixels[index]) * scale * gain, 0), 1)
                destination[index] = UInt16((value * 65_535).rounded()).littleEndian
            }
        }
        return output
    }

    /// Reorders a storage-coordinate RGBA16 raster into presentation order.
    /// The source dimensions remain explicit so orientation cannot silently
    /// change the crop geometry used by the SceneBundle.
    public static func orientedRGBA16(
        _ data: Data,
        width: Int,
        height: Int,
        orientation: Int
    ) throws -> (data: Data, width: Int, height: Int) {
        guard width > 0, height > 0, data.count == width * height * 8 else {
            throw DecodeError.invalidTargetSize
        }
        let swapsAxes = [5, 6, 7, 8].contains(orientation)
        let outputWidth = swapsAxes ? height : width
        let outputHeight = swapsAxes ? width : height
        var output = Data(count: data.count)
        data.withUnsafeBytes { sourceRaw in
            output.withUnsafeMutableBytes { destinationRaw in
                guard let source = sourceRaw.bindMemory(to: UInt16.self).baseAddress,
                      let destination = destinationRaw.bindMemory(to: UInt16.self).baseAddress else { return }
                for y in 0..<height {
                    for x in 0..<width {
                        let target: (Int, Int)
                        switch orientation {
                        case 2: target = (width - 1 - x, y)
                        case 3: target = (width - 1 - x, height - 1 - y)
                        case 4: target = (x, height - 1 - y)
                        case 5: target = (y, x)
                        case 6: target = (height - 1 - y, x)
                        case 7: target = (height - 1 - y, width - 1 - x)
                        case 8: target = (y, width - 1 - x)
                        default: target = (x, y)
                        }
                        let sourceOffset = (y * width + x) * 4
                        let targetOffset = (target.1 * outputWidth + target.0) * 4
                        for component in 0..<4 {
                            destination[targetOffset + component] = source[sourceOffset + component]
                        }
                    }
                }
            }
        }
        return (output, outputWidth, outputHeight)
    }

    private static func exposureScale(raw: [Float], preview: [Float]) -> (scale: Double, confidence: Double) {
        let rawLuma = luminance(raw)
        let previewLuma = luminance(preview)
        var ratios: [Double] = []
        ratios.reserveCapacity(min(200_000, rawLuma.count))
        let stride = max(1, rawLuma.count / 200_000)
        for index in Swift.stride(from: 0, to: min(rawLuma.count, previewLuma.count), by: stride) {
            let r = rawLuma[index], p = previewLuma[index]
            guard r.isFinite, p.isFinite, r > 1e-5, p > 0.02, p < 0.98 else { continue }
            ratios.append(p / r)
        }
        guard !ratios.isEmpty else { return (1, 0) }
        ratios.sort()
        let median = ratios[ratios.count / 2]
        let low = ratios[Int(Double(ratios.count - 1) * 0.1)]
        let high = ratios[Int(Double(ratios.count - 1) * 0.9)]
        let spread = high / max(low, 1e-9)
        let confidence = min(1, Double(ratios.count) / 10_000) * min(1, 2 / max(spread, 1))
        return (min(max(median, 0.03125), 32), confidence)
    }

    public static func decode(
        dngURL: URL,
        targetWidth: Int,
        targetHeight: Int,
        enableHighlightRecovery: Bool = false
    ) throws -> DecodeResult {
        guard targetWidth > 0, targetHeight > 0 else { throw DecodeError.invalidTargetSize }
        let dngData = try Data(contentsOf: dngURL, options: [.mappedIfSafe])
        let metadata = try dngMetadata(from: dngData)
        let embeddedPreview = try previewData(from: dngData)
        guard embeddedPreview.width == metadata.rawWidth,
              embeddedPreview.height == metadata.rawHeight else {
            throw DecodeError.invalidPreview(
                "embedded preview dimensions \(embeddedPreview.width)x\(embeddedPreview.height) "
                    + "do not match RAW \(metadata.rawWidth)x\(metadata.rawHeight)"
            )
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
            throw DecodeError.invalidPreview("extended-linear Display P3 is unavailable")
        }
        guard let filter = CIFilter(imageURL: dngURL, options: nil) else {
            throw DecodeError.rawFilterUnavailable
        }
        let defaults = filterValues(filter)
        neutralize(filter, enableHighlightRecovery: enableHighlightRecovery)
        let effective = filterValues(filter)
        guard let rawImage = filter.outputImage else { throw DecodeError.rawFilterProducedNoImage }
        let context = CIContext(options: [
            .cacheIntermediates: false,
            .useSoftwareRenderer: true,
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
        ])
        let rawPixels = render(
            context: context,
            image: rawImage,
            width: targetWidth,
            height: targetHeight,
            colorSpace: colorSpace
        )
        let rawStatistics = statistics(rawPixels)
        guard rawStatistics.finite,
              rawPixels.allSatisfy(\.isFinite) else {
            throw DecodeError.nonFiniteOutput
        }
        // Keep both rasters in DNG/JPEG storage coordinates.  Their Orientation
        // tags are recorded and applied only when the SceneBundle is assembled.
        let previewImage = CIImage(data: embeddedPreview.data, options: [.applyOrientationProperty: false])
        let previewPixels = previewImage.map {
            render(context: context, image: $0, width: targetWidth, height: targetHeight, colorSpace: colorSpace)
        } ?? []
        let previewStatistics = previewPixels.isEmpty
            ? RasterStatistics(minimum: [], maximum: [], mean: [], p01: [], p50: [], p99: [], finite: false, clippedHighFraction: [])
            : statistics(previewPixels)
        let pair = try previewPair(
            preview: embeddedPreview,
            rawPixels: rawPixels,
            previewPixels: previewPixels,
            width: targetWidth,
            height: targetHeight,
            dngMetadata: metadata
        )
        let exposure = previewPixels.isEmpty
            ? (scale: 1.0, confidence: 0.0)
            : exposureScale(raw: rawPixels, preview: previewPixels)
        let calibration = previewPixels.isEmpty
            ? Calibration(
                scale: 1.0,
                channelGains: [1, 1, 1],
                sampleCount: 0,
                confidence: 0,
                model: "unavailable-no-preview"
            )
            : calibrate(raw: rawPixels, preview: previewPixels, exposure: exposure)
        let normalized = normalizedRGBA16(
            rawPixels,
            scale: calibration.scale,
            channelGains: calibration.channelGains
        )
        let float16 = float16RGBA(rawPixels)
        let dngHash = sha256(dngData)
        return DecodeResult(
            rgbaFloat32: rawPixels,
            rgbaFloat16: float16,
            normalizedRGBA16: normalized,
            width: targetWidth,
            height: targetHeight,
            rawStatistics: rawStatistics,
            previewStatistics: previewStatistics,
            embeddedPreview: embeddedPreview,
            pairValidation: pair,
            filterDefaults: defaults,
            filterEffectiveValues: effective,
            effectiveScale: calibration.scale,
            calibrationChannelGains: calibration.channelGains,
            calibrationSampleCount: calibration.sampleCount,
            calibrationModel: calibration.model,
            calibrationConfidence: calibration.confidence,
            dngSHA256: dngHash,
            dngMetadata: metadata,
            cacheKey: cacheKey(
                dngSHA256: dngHash,
                embeddedPreviewSHA256: embeddedPreview.sha256
            )
        )
    }
}
