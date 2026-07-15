#!/usr/bin/env swift

import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Darwin
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Vision

private let cgImageDestinationEncodeGainMapSubsampleFactorCompat =
    "kCGImageDestinationEncodeGainMapSubsampleFactor" as CFString

private enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case invalidCommand(String)
    case missingArgument(String)
    case unknownOption(String)
    case invalidValue(option: String, value: String)
    case inputNotFound(URL)
    case noFilesMatched(URL, String)
    case unableToRead(URL)
    case unableToReadCheckpoint(URL)
    case unableToWriteCheckpoint(URL)
    case invalidCheckpoint(URL, String)
    case checkpointConfigMismatch(URL, expected: String, actual: String)
    case batchFailed(failures: Int, checkpoint: URL)
    case unableToCreateDirectory(URL)
    case outputParentIsNotDirectory(URL)
    case outputPathCollision(output: URL, firstInput: URL, secondInput: URL)
    case qtiMarkerNotFound
    case manifestNotFound
    case invalidLHDR(String)
    case unableToDecodeMask(URL)
    case unableToLoadBaseImage(URL)
    case unableToCreateDestination(URL)
    case unableToFinalizeDestination(URL)
    case unableToCreateMetadata
    case unableToWriteDebugAsset(URL)
    case outputVerificationFailed(URL)
    case gainMapPixelFormatMismatch(URL, expected: UInt32, actual: UInt32?)
    case invalidContainer(String)

    var description: String {
        switch self {
        case .usage(let message):
            return message
        case .invalidCommand(let command):
            return "invalid command: \(command)"
        case .missingArgument(let name):
            return "missing required argument: \(name)"
        case .unknownOption(let option):
            return "unknown option: \(option)"
        case .invalidValue(let option, let value):
            return "invalid value for \(option): \(value)"
        case .inputNotFound(let url):
            return "input not found: \(url.path)"
        case .noFilesMatched(let url, let glob):
            return "no files matched \(glob) under \(url.path)"
        case .unableToRead(let url):
            return "unable to read file: \(url.path)"
        case .unableToReadCheckpoint(let url):
            return "unable to read checkpoint: \(url.path)"
        case .unableToWriteCheckpoint(let url):
            return "unable to write checkpoint: \(url.path)"
        case .invalidCheckpoint(let url, let message):
            return "invalid checkpoint \(url.path): \(message)"
        case .checkpointConfigMismatch(let url, let expected, let actual):
            return "checkpoint config mismatch in \(url.path): expected \(expected), got \(actual) (use --no-resume or a different --checkpoint)"
        case .batchFailed(let failures, let checkpoint):
            return "batch failed for \(failures) file(s); checkpoint kept at \(checkpoint.path)"
        case .unableToCreateDirectory(let url):
            return "unable to create directory: \(url.path)"
        case .outputParentIsNotDirectory(let url):
            return "output parent is not a directory: \(url.path)"
        case .outputPathCollision(let output, let firstInput, let secondInput):
            return "output path collision \(output.path) (two inputs map to the same output): \(firstInput.path) and \(secondInput.path)"
        case .qtiMarkerNotFound:
            return "QTI extension marker not found (unsupported input: expected a Local HDR (LHDR/UHDR) HEIC with embedded QTI extension payload; file may already be ISO gain-map or plain HEIC)"
        case .manifestNotFound:
            return "Local HDR manifest not found (unsupported input: missing embedded JSON manifest)"
        case .invalidLHDR(let message):
            return "invalid LHDR payload: \(message)"
        case .unableToDecodeMask(let url):
            return "unable to decode LHDR mask JPEG: \(url.path)"
        case .unableToLoadBaseImage(let url):
            return "unable to decode SDR base image: \(url.path)"
        case .unableToCreateDestination(let url):
            return "unable to create HEIC destination: \(url.path)"
        case .unableToFinalizeDestination(let url):
            return "failed to finalize HEIC destination: \(url.path)"
        case .unableToCreateMetadata:
            return "unable to create HDR tone-map metadata"
        case .unableToWriteDebugAsset(let url):
            return "unable to write debug artifact: \(url.path)"
        case .outputVerificationFailed(let url):
            return "output verification failed (no ISO gain-map auxiliary data found): \(url.path)"
        case .gainMapPixelFormatMismatch(let url, let expected, let actual):
            return "gain map pixel format mismatch in \(url.path): expected \(fourCCString(expected)), got \(fourCCString(actual))"
        case .invalidContainer(let message):
            return "invalid HEIC container: \(message)"
        }
    }
}

private enum Family: String {
    case auto
    case x6
    case x7
}

private enum InputProcessingBranch: String {
    case system
    case systemDecoded = "system-decoded"
    case hybrid
    case passthrough
}

/// Controls OPPO Gallery compatibility behavior.
/// - `auto`: ISO-only diagnostic path which avoids private OPPO HDR tagflags.
/// - `on`/`tail`: OPPO activation path with private UHDR tagflags, but no compatibility tail.
/// - `off`: Apple/ImageIO output without adding OPPO private HDR activation tagflags.
private enum OppoCompatibility: String {
    case auto
    case iso
    case isoNoLocal = "iso-no-local"
    case isoGraph = "iso-graph"
    case on
    case tail
    case off

    /// Whether to apply OPPO-oriented tmap metadata preservation.
    var wantsOppoCompat: Bool { self != .off }

}

/// Controls preservation of OPPO Camera FileExtendedContainer entries.
///
/// This is intentionally separate from `--oppo-compat`: OPPO HDR compatibility
/// can remain no-tail, preserve selected metadata, or copy the complete source
/// tail byte-for-byte after rebuilding the ISO 21496-1 HDR graph.
private enum OppoCameraTail: String {
    case off
    case watermark
    case compact
    case preserve
    case preserveWithoutPortrait = "preserve-without-portrait"
    case preserveWithoutPrivateUHDR = "preserve-without-private-uhdr"
    case preserveWithoutPrivateHDR = "preserve-without-private-hdr"
    case preserveNoUHDR = "preserve-no-uhdr"
    case preserveNoHDR = "preserve-no-hdr"
}

private enum TmapFormat: String {
    case strict
    case imageIO = "imageio"
}

private func fourCCString(_ value: UInt32?) -> String {
    guard let value else { return "missing" }
    var bigEndian = value.bigEndian
    let label = withUnsafeBytes(of: &bigEndian) { buffer -> String in
        let bytes = buffer.map { byte -> UInt8 in
            (32...126).contains(byte) ? byte : UInt8(ascii: ".")
        }
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
    return "\(value) ('\(label)')"
}

private struct ConvertCommand {
    let inputURL: URL
    let outputURL: URL
    let family: Family
    let debugRootURL: URL?
    let oppoCompatibility: OppoCompatibility
    let inputProcessingBranch: InputProcessingBranch
    let portraitMode: PortraitMode
    let oppoCameraTail: OppoCameraTail
    let tmapFormat: TmapFormat
}

private enum PortraitMode: String {
    case on
    case off
}

private struct BatchCommand {
    let inputDirURL: URL
    let outputDirURL: URL
    let family: Family
    let glob: String
    let debugRootURL: URL?
    let oppoCompatibility: OppoCompatibility
    let inputProcessingBranch: InputProcessingBranch
    let portraitMode: PortraitMode
    let oppoCameraTail: OppoCameraTail
    let tmapFormat: TmapFormat
    let jobs: Int
    /// Nil means auto checkpoint path under output-dir.
    let checkpointURL: URL?
    /// If false, ignore any existing checkpoint and start a fresh run.
    let resume: Bool
    /// Skip valid existing outputs (default on).
    let skipExisting: Bool
}

private struct ManifestEntry {
    let name: String
    let offset: Int
    let length: Int
    let version: Any?
    let jsonOrder: Int
    let start: Int
    let end: Int
}

private struct ManifestInfo {
    let extensionStart: Int
    let jsonStart: Int
    let jsonEnd: Int
    let entries: [ManifestEntry]
}

private struct LocalHDRInfo: Encodable {
    let version: Double
    let length: Double
    let metaSize: Double
    let offset: Double
}

private enum ExtractionMode: String, Encodable {
    case lhdr
    case uhdr
}

private struct ExtractedLHDR {
    let mode: ExtractionMode
    let metaBytes: Data
    let metaFloats: [Double]
    let localHDRInfo: LocalHDRInfo?
    let maskJPEGData: Data
    let manifestInfo: ManifestInfo
    let dataBase: Int
}

private struct GainMapRaster {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let channelCount: Int
    let data: Data
}

private extension GainMapRaster {
    func replicatingLumaToRGB() -> GainMapRaster {
        guard channelCount == 1 else { return self }

        let outputBytesPerRow = alignUp(width * 4, toMultipleOf: 64)
        var output = Data(count: outputBytesPerRow * height)
        data.withUnsafeBytes { sourceRawBuffer in
            output.withUnsafeMutableBytes { outputRawBuffer in
                guard let source = sourceRawBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let destination = outputRawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return
                }

                for y in 0..<height {
                    let sourceRow = y * bytesPerRow
                    let destinationRow = y * outputBytesPerRow
                    for x in 0..<width {
                        let value = source[sourceRow + x]
                        let offset = destinationRow + x * 4
                        destination[offset] = value
                        destination[offset + 1] = value
                        destination[offset + 2] = value
                        destination[offset + 3] = 255
                    }
                }
            }
        }

        return GainMapRaster(
            width: width,
            height: height,
            bytesPerRow: outputBytesPerRow,
            channelCount: 3,
            data: output
        )
    }
}

private struct AuxiliaryGainMapPayload {
    let data: Data
    let bytesPerRow: Int
    let pixelFormat: UInt32
}

private struct ISOBMFFBox {
    let type: String
    let dataStart: Int
    let dataEnd: Int
    let boxStart: Int
    let size: Int
}

private struct ISOBMFFILocEntry {
    let itemID: Int
    let constructionMethod: Int
    let dataReferenceIndex: Int
    let extents: [(offset: Int, length: Int)]
}

private struct ISOBMFFIPMAEntry {
    let itemID: Int
    let associations: [Int]
}

private struct ISOBMFFItemInfo {
    let itemID: Int
    let type: String
    let flags: Int
    let rawInfe: Data
}

private struct ISOBMFFIRefEntry {
    let type: String
    let from: Int
    let to: [Int]
}

private struct ISOBMFFPropertyInfo {
    let index: Int
    let type: String
    let rawBox: Data
}

private struct ResolvedScale {
    let edrScale: Double
    let ratioMin: Double
    let ratioMax: Double
    let gamma: Double
    let epsilonSdr: Double
    let epsilonHdr: Double
    let displayRatioSdr: Double
    let displayRatioHdr: Double
    let scale: Double
    let gainMapMin: Double
    let gainMapMax: Double
    let baseHeadroom: Double
    let alternateHeadroom: Double
    let source: String
    let channelCount: Int
    let perChannelGainMapMin: [Double]
    let perChannelGainMapMax: [Double]
    let perChannelGamma: [Double]
    let perChannelBaseOffset: [Double]
    let perChannelAlternateOffset: [Double]
}

private struct GainMapParams {
    let family: Family
    let knee: Double
    let kneeRange: Double
    let headroomScale: Double
    let maxBoost: Double
    let log2Scale: Double
    let kneeSource: String
}

private struct HDRToneMapStyle: Encodable {
    let version: Int
    let baseHeadroom: Double
    let alternateHeadroom: Double
    let baseColorIsWorkingColor: Bool
    let gainMapMin: Double
    let gainMapMax: Double
    let gamma: Double
    let baseOffset: Double
    let alternateOffset: Double
    let channelCount: Int
    let perChannelGainMapMin: [Double]
    let perChannelGainMapMax: [Double]
    let perChannelGamma: [Double]
    let perChannelBaseOffset: [Double]
    let perChannelAlternateOffset: [Double]
}

private extension HDRToneMapStyle {
    func replicatingMonochromeToRGB() -> HDRToneMapStyle {
        guard channelCount == 1 else { return self }

        func triplet(_ values: [Double], fallback: Double) -> [Double] {
            Array(repeating: values.first ?? fallback, count: 3)
        }

        return HDRToneMapStyle(
            version: version,
            baseHeadroom: baseHeadroom,
            alternateHeadroom: alternateHeadroom,
            baseColorIsWorkingColor: baseColorIsWorkingColor,
            gainMapMin: gainMapMin,
            gainMapMax: gainMapMax,
            gamma: gamma,
            baseOffset: baseOffset,
            alternateOffset: alternateOffset,
            channelCount: 3,
            perChannelGainMapMin: triplet(perChannelGainMapMin, fallback: gainMapMin),
            perChannelGainMapMax: triplet(perChannelGainMapMax, fallback: gainMapMax),
            perChannelGamma: triplet(perChannelGamma, fallback: gamma),
            perChannelBaseOffset: triplet(perChannelBaseOffset, fallback: baseOffset),
            perChannelAlternateOffset: triplet(perChannelAlternateOffset, fallback: alternateOffset)
        )
    }
}

private struct DebugMeta: Encodable {
    struct Projection: Encodable {
        let familyDetected: String
        let familyUsed: String
        let f0: Double
        let edrScale: Double
        let ratioMin: Double
        let ratioMax: Double
        let gamma: Double
        let epsilonSdr: Double
        let epsilonHdr: Double
        let displayRatioSdr: Double
        let displayRatioHdr: Double
        let scale: Double
        let gainMapMin: Double
        let gainMapMax: Double
        let baseHeadroom: Double
        let alternateHeadroom: Double
        let scaleSource: String
        let knee: Double
        let kneeSource: String
        let kneeRange: Double
        let headroomScale: Double
        let maxBoost: Double
        let log2Scale: Double
    }

    let inputPath: String
    let mode: String
    let metaSHA256: String
    let maskSHA256: String
    let metaFloat32: [Double]
    let localHDRInfo: LocalHDRInfo?
    let maskWidth: Int
    let maskHeight: Int
    let projection: Projection
    let semanticFields: [String: LHDRSemanticField]
}

private struct LHDRSemanticField: Encodable {
    let index: Int
    let value: Double
    let meaning: String
    let confidence: String
    let note: String?
}

private struct FloatAuditEntry: Encodable {
    let index: Int
    let value: Double
    let naturalLog: Double?
    let log2: Double?
    let log10: Double?
    let square: Double
    let sqrt: Double?
    let reciprocal: Double?
    let exp: Double?
    let exp2: Double?
    let cube: Double
    let cubeRoot: Double
}

private struct CalibrationTrace: Encodable {
    struct BasePath: Encodable {
        let branch: String
        let log2f32: Double?
        let highlightRef: Double?
        let log2rm: Double?
        let preCorrectionEDR: Double
        let faceCorrectionApplied: Bool
        let sqrtCorrectionApplied: Bool
        let finalEDR: Double
    }

    struct StrictPath: Encodable {
        let intercept: Double
        let baseContribution: Double
        let facePenalty: Double
        let highlightPenalty: Double
        let sceneTerm: Double
        let hdrBoostTerm: Double
        let rawCalibratedEDR: Double
        let clampedEDR: Double
        let ratioMax: Double
        let gainMapMax: Double
    }

    let familyDetected: String
    let familyUsed: String
    let floatAudits: [FloatAuditEntry]
    let basePath: BasePath
    let strictPath: StrictPath
    let resolvedEDRScale: Double
}

private func buildLHDRSemanticFields(floats: [Double]) -> [String: LHDRSemanticField] {
    func field(index: Int, meaning: String, confidence: String, note: String? = nil) -> LHDRSemanticField {
        return LHDRSemanticField(
            index: index,
            value: index < floats.count ? floats[index] : 0.0,
            meaning: meaning,
            confidence: confidence,
            note: note
        )
    }

    return [
        "versionOrHdrBoost": field(
            index: 0,
            meaning: "Version / HDR boost factor",
            confidence: "direct_from_code",
            note: "Device-constant on current X6/X7 samples."
        ),
        "structSizeSelfRef": field(
            index: 2,
            meaning: "Struct size self-reference",
            confidence: "direct_from_code",
            note: "Expected to be exactly 144.0 for LHDR metadata blocks."
        ),
        "sceneExposureOrDynamicRangeEv": field(
            index: 4,
            meaning: "Scene dynamic range / exposure EV",
            confidence: "strongly_inferred_from_samples"
        ),
        "sentinelFlag": field(
            index: 5,
            meaning: "Constant sentinel / mode marker",
            confidence: "constant_observation",
            note: "Observed as -1.0 across current X6/X7 samples."
        ),
        "binarySceneModeFlag": field(
            index: 7,
            meaning: "Binary scene/mode indicator",
            confidence: "behaviorally_confirmed"
        ),
        "toneCurveOffset": field(
            index: 8,
            meaning: "Tone curve offset",
            confidence: "strongly_inferred_from_samples"
        ),
        "toneCurveShapeModifier": field(
            index: 9,
            meaning: "Tone curve shape modifier",
            confidence: "strongly_inferred_from_samples"
        ),
        "luminanceReferenceA": field(
            index: 11,
            meaning: "Device-dependent luminance reference A",
            confidence: "strongly_inferred_from_samples"
        ),
        "luminanceReferenceB": field(
            index: 12,
            meaning: "Device-dependent luminance reference B",
            confidence: "strongly_inferred_from_samples"
        ),
        "colorBalanceCoeff0": field(
            index: 13,
            meaning: "Color balance coefficient 0",
            confidence: "weakly_inferred_from_samples"
        ),
        "colorBalanceCoeff1": field(
            index: 14,
            meaning: "Color balance coefficient 1",
            confidence: "weakly_inferred_from_samples"
        ),
        "colorBalanceCoeff2": field(
            index: 15,
            meaning: "Color balance coefficient 2",
            confidence: "weakly_inferred_from_samples"
        ),
        "colorBalanceCoeff3": field(
            index: 16,
            meaning: "Color balance coefficient 3",
            confidence: "weakly_inferred_from_samples"
        ),
        "histogramAccumulator": field(
            index: 17,
            meaning: "Histogram accumulator / mask energy sum",
            confidence: "strongly_inferred_from_samples"
        ),
        "configParamA": field(
            index: 18,
            meaning: "Fixed configuration parameter A",
            confidence: "constant_observation"
        ),
        "configParamB": field(
            index: 19,
            meaning: "Fixed configuration parameter B",
            confidence: "constant_observation"
        ),
        "f23Threshold": field(
            index: 23,
            meaning: "High-light threshold (Main EDR path selection)",
            confidence: "derived_from_empirical_analysis"
        ),
        "f24Correction": field(
            index: 24,
            meaning: "Sigmoid and linear path correction factor",
            confidence: "derived_from_empirical_analysis"
        ),
        "f29EdrBase": field(
            index: 29,
            meaning: "EDR Base Reference (Drives scaling segments)",
            confidence: "derived_from_empirical_analysis"
        ),
        "f32RawGain": field(
            index: 32,
            meaning: "Linear raw gain (Converted to log-domain)",
            confidence: "derived_from_empirical_analysis"
        ),
        "precomputedEdrScale": field(
            index: 33,
            meaning: "Pre-computed EDR scale bypass",
            confidence: "direct_from_code",
            note: "If >= 1.0, use this directly instead of computing EDR."
        ),
        "f34ConfigFlag": field(
            index: 34,
            meaning: "Binary configuration flag (sqrt smoothing logic)",
            confidence: "derived_from_empirical_analysis"
        )
    ]
}

private struct GainMapMetaProjectionDebug: Encodable {
    let familyDetected: String
    let familyUsed: String
    let source: String
    let edrScale: Double
    let ratioMin: Double
    let ratioMax: Double
    let gamma: Double
    let epsilonSdr: Double
    let epsilonHdr: Double
    let displayRatioSdr: Double
    let displayRatioHdr: Double
    let scale: Double
    let gainMapMin: Double
    let gainMapMax: Double
    let baseHeadroom: Double
    let alternateHeadroom: Double
}

private struct SampleReport {
    let inputURL: URL
    let outputURL: URL
    let family: Family
    let scale: ResolvedScale
    let gainMapParams: GainMapParams
    let debugDirURL: URL?
}

private enum LHDRExtractor {
    private static let qtiMarkers: [Data] = [
        Data("QTI Debug".utf8),
        Data("QTI ".utf8)
    ]

    private static let float144: Data = {
        let value = Float(144.0)
        var little = value.bitPattern.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }()

    static func extract(from data: Data) throws -> ExtractedLHDR {
        let manifestInfo = try locateManifest(in: data)
        let dataBase = calibrateDataBase(in: data, manifestInfo: manifestInfo) ?? manifestInfo.extensionStart
        let blocks = materializeBlocks(in: data, manifestInfo: manifestInfo, dataBase: dataBase)

        if let infoEntry = manifestInfo.entries.first(where: { $0.name == "local.uhdr.gainmap.info" }),
           let dataEntry = manifestInfo.entries.first(where: { $0.name == "local.uhdr.gainmap.data" }) {
            
            let infoStart = blockStart(for: infoEntry, in: data, manifestInfo: manifestInfo, dataBase: dataBase)
            let infoEnd = infoStart + infoEntry.length
            
            var metaBytes: Data
            if infoStart >= 0, infoEnd <= data.count {
                metaBytes = data.subdata(in: infoStart..<infoEnd)
            } else {
                metaBytes = Data(count: 80)
            }
            
            var metaFloats = (try? unpackFloatArrayLE(metaBytes, count: 20)) ?? Array(repeating: 0.0, count: 20)
            
            // Check for valid Identity or Swapped manifest
            if metaFloats.allSatisfy({ $0 == 0.0 }) || abs(metaFloats[0] - 1.0) > 0.1 {
                metaFloats = [
                    1.0, 1.0, 1.0,             // ratioMin
                    1.0,                       // padding
                    4.926, 4.926, 4.926,       // ratioMax
                    1.0, 1.0, 1.0,             // gamma
                    0.0, 0.0, 0.0,             // epsilonSdr
                    0.0, 0.0, 0.0,             // epsilonHdr
                    1.0,                       // displayRatioSdr
                    4.926,                     // displayRatioHdr
                    4.926,                     // scale
                    0.0,                       // baseImageType
                    0.0                        // type
                ]
                var repacked = Data()
                for floatValue in metaFloats {
                    var bits = Float(floatValue).bitPattern.littleEndian
                    repacked.append(withUnsafeBytes(of: &bits) { Data($0) })
                }
                metaBytes = repacked
            }
            
            let dataStart = blockStart(for: dataEntry, in: data, manifestInfo: manifestInfo, dataBase: dataBase)
            let dataEnd = dataStart + dataEntry.length
            guard dataStart >= 0, dataEnd <= data.count else { throw CLIError.invalidLHDR("Out of bounds UHDR data block") }
            let maskJPEGData = data.subdata(in: dataStart..<dataEnd)
            
            return ExtractedLHDR(
                mode: .uhdr,
                metaBytes: metaBytes,
                metaFloats: metaFloats,
                localHDRInfo: nil,
                maskJPEGData: maskJPEGData,
                manifestInfo: manifestInfo,
                dataBase: dataBase
            )
        }

        let metaBytes = try extractMeta(from: data, manifestInfo: manifestInfo, blocks: blocks)
        let localHDRInfo = try decodeLocalHDRInfo(from: metaBytes)
        let maskJPEGData = try extractMask(from: data, manifestInfo: manifestInfo, dataBase: dataBase, blocks: blocks)
        let metaFloats = try unpack36FloatLE(metaBytes)

        return ExtractedLHDR(
            mode: .lhdr,
            metaBytes: metaBytes,
            metaFloats: metaFloats,
            localHDRInfo: localHDRInfo,
            maskJPEGData: maskJPEGData,
            manifestInfo: manifestInfo,
            dataBase: dataBase
        )
    }

    static func portraitBlocks(from data: Data) throws -> [String: Data] {
        let manifestInfo = try locateManifest(in: data)
        let dataBase = calibrateDataBase(in: data, manifestInfo: manifestInfo)
            ?? manifestInfo.extensionStart
        var blocks: [String: Data] = [:]
        for entry in manifestInfo.entries {
            let start = blockStart(
                for: entry,
                in: data,
                manifestInfo: manifestInfo,
                dataBase: dataBase
            )
            let end = start + entry.length
            if start >= 0, end <= data.count {
                blocks[entry.name] = data.subdata(in: start..<end)
            }
        }
        return blocks
    }

    private static func blockStart(
        for entry: ManifestEntry,
        in data: Data,
        manifestInfo: ManifestInfo,
        dataBase: Int
    ) -> Int {
        let manifestRelativeStart = manifestInfo.jsonStart - entry.offset
        if manifestRelativeStart >= 0,
           manifestRelativeStart + entry.length <= data.count {
            return manifestRelativeStart
        }
        return dataBase + entry.start
    }

    private static func locateManifest(in data: Data) throws -> ManifestInfo {
        let detectedExtensionStart = try? findExtensionStart(in: data)
        guard let manifestArray = parseManifest(in: data) else {
            throw CLIError.manifestNotFound
        }

        guard let jsonStart = lastIndex(of: Data("[{".utf8), in: data),
              let jsonEndBase = firstIndex(of: UInt8(ascii: "]"), in: data, startingAt: jsonStart) else {
            throw CLIError.manifestNotFound
        }
        let jsonEnd = jsonEndBase + 1
        let markerStart = lastIndex(of: Data([0] + "jxrs".utf8), in: data)
        let hasValidJXRSFooter: Bool = markerStart.map { marker in
            guard marker + 9 == data.count else { return false }
            let footerLength = Int(data[marker + 5])
                | (Int(data[marker + 6]) << 8)
                | (Int(data[marker + 7]) << 16)
                | (Int(data[marker + 8]) << 24)
            return footerLength == data.count - jsonStart
        } ?? false
        guard detectedExtensionStart != nil || hasValidJXRSFooter else {
            throw CLIError.qtiMarkerNotFound
        }

        var entries: [ManifestEntry] = []
        for (jsonOrder, raw) in manifestArray.enumerated() {
            guard let dict = raw as? [String: Any],
                  let offset = dict["offset"] as? NSNumber,
                  let length = dict["length"] as? NSNumber else {
                continue
            }
            let name = String(describing: dict["name"] ?? "")
            let offsetValue = offset.intValue
            let lengthValue = length.intValue
            entries.append(
                ManifestEntry(
                    name: name,
                    offset: offsetValue,
                    length: lengthValue,
                    version: dict["version"],
                    jsonOrder: jsonOrder,
                    start: offsetValue - lengthValue,
                    end: offsetValue
                )
            )
        }
        entries.sort { $0.start < $1.start }
        let extensionStart = detectedExtensionStart
            ?? entries.map { jsonStart - $0.offset }.filter { $0 >= 0 }.min()
            ?? jsonStart

        return ManifestInfo(
            extensionStart: extensionStart,
            jsonStart: jsonStart,
            jsonEnd: jsonEnd,
            entries: entries
        )
    }

    private static func findExtensionStart(in data: Data) throws -> Int {
        for marker in qtiMarkers {
            if let pos = firstIndex(of: marker, in: data) {
                let boxStart = pos - 4
                guard boxStart >= 0 else { continue }
                let boxSize = try readUInt32BE(from: data, at: boxStart)
                return boxStart + Int(boxSize)
            }
        }
        throw CLIError.qtiMarkerNotFound
    }

    private static func parseManifest(in data: Data) -> [Any]? {
        guard let jsonStart = lastIndex(of: Data("[{".utf8), in: data),
              let jsonEndBase = firstIndex(of: UInt8(ascii: "]"), in: data, startingAt: jsonStart) else {
            return nil
        }
        let jsonSlice = data.subdata(in: jsonStart..<(jsonEndBase + 1))
        guard let object = try? JSONSerialization.jsonObject(with: jsonSlice, options: []),
              let array = object as? [Any] else {
            return nil
        }
        return array
    }

    private static func calibrateDataBase(in data: Data, manifestInfo: ManifestInfo) -> Int? {
        let imagePositions = discoverImagePositions(in: data, start: manifestInfo.extensionStart)
        guard !imagePositions.isEmpty else { return nil }

        var interesting = manifestInfo.entries.filter {
            ["watermark", "local.hdr.linear.mask", "local.uhdr.gainmap.data"].contains($0.name)
        }
        if interesting.isEmpty {
            interesting = manifestInfo.entries.filter { $0.length > 64 }
        }

        var bestBase: Int?
        var bestScore = Int.min
        let metaEntry = manifestInfo.entries.first { $0.name == "local.hdr.meta.data" }
        let infoEntry = manifestInfo.entries.first { $0.name == "local.uhdr.gainmap.info" }

        for imagePos in imagePositions {
            for entry in interesting {
                let candidateBase = imagePos - entry.start
                if candidateBase < manifestInfo.extensionStart {
                    continue
                }

                var score = 0
                let entryStart = candidateBase + entry.start
                if entryStart >= 0, entryStart + 4 <= data.count {
                    let magic = data.subdata(in: entryStart..<(entryStart + 4))
                    if magic.starts(with: Data([0xFF, 0xD8])) || magic.starts(with: Data([0x89, 0x50, 0x4E, 0x47])) {
                        score += 5
                    }
                }

                if let metaEntry {
                    let metaStart = candidateBase + metaEntry.start
                    let metaEnd = metaStart + metaEntry.length
                    if metaStart >= 0, metaEnd <= data.count {
                        score += max(0, scoreMetaChunk(data.subdata(in: metaStart..<metaEnd)))
                    }
                }

                if let infoEntry {
                    let infoStart = candidateBase + infoEntry.start
                    let infoEnd = infoStart + infoEntry.length
                    if infoStart >= 0, infoEnd <= data.count,
                       let floats = try? unpackFloatArrayLE(data.subdata(in: infoStart..<infoEnd), count: 20) {
                        let bounded = floats.filter { $0.isFinite && abs($0) <= 10.0 }
                        if bounded.count >= 10 {
                            score += 3
                        }
                    }
                }

                if score > bestScore {
                    bestScore = score
                    bestBase = candidateBase
                }
            }
        }

        return bestBase
    }

    private static func materializeBlocks(
        in data: Data,
        manifestInfo: ManifestInfo,
        dataBase: Int
    ) -> [String: Data] {
        var blocks: [String: Data] = [:]
        for entry in manifestInfo.entries {
            let start = dataBase + entry.start
            let end = start + entry.length
            if start >= 0, end <= data.count {
                blocks[entry.name] = data.subdata(in: start..<end)
            }
        }
        return blocks
    }

    private static func extractMeta(
        from data: Data,
        manifestInfo: ManifestInfo,
        blocks: [String: Data]
    ) throws -> Data {
        let extensionData = data.subdata(in: manifestInfo.extensionStart..<data.count)
        let manifestStart = relativeManifestStart(in: extensionData)

        if let manifestEntry = manifestInfo.entries.first(where: { $0.name == "local.hdr.meta.data" && $0.length >= 144 }) {
            let absoluteCandidates = [
                manifestInfo.jsonStart - manifestEntry.offset,
                manifestInfo.extensionStart + manifestEntry.offset
            ]

            for start in absoluteCandidates {
                let end = start + 144
                if start >= 0, end <= data.count {
                    let chunk = data.subdata(in: start..<end)
                    if let floats = try? unpack36FloatLE(chunk), scoreMetaCandidate(floats) >= 6 {
                        return chunk
                    }
                }
            }
        }

        if let block = blocks["local.hdr.meta.data"], block.count >= 144 {
            let candidate = block.prefix(144)
            if let floats = try? unpack36FloatLE(candidate), scoreMetaCandidate(floats) >= 6 {
                return candidate
            }
        }

        if let manifestStart {
            for entry in manifestInfo.entries where entry.name == "local.hdr.meta.data" && entry.length >= 144 {
                let start = manifestStart - entry.offset
                let end = start + 144
                if start >= 0, end <= extensionData.count {
                    let chunk = extensionData.subdata(in: start..<end)
                    if let floats = try? unpack36FloatLE(chunk), scoreMetaCandidate(floats) >= 6 {
                        return chunk
                    }
                }
            }
        }

        var best: (score: Int, chunk: Data)?
        var searchStart = 0
        while let hit = firstIndex(of: float144, in: extensionData, startingAt: searchStart) {
            let start = hit - 8
            let end = start + 144
            if start >= 0, end <= extensionData.count {
                let chunk = extensionData.subdata(in: start..<end)
                if let floats = try? unpack36FloatLE(chunk) {
                    let score = scoreMetaCandidate(floats)
                    if best == nil || score > best!.score {
                        best = (score, chunk)
                    }
                }
            }
            searchStart = hit + 1
        }

        guard let best, best.score >= 8 else {
            throw CLIError.invalidLHDR("failed to locate plausible 144-byte local.hdr.meta.data block")
        }
        return best.chunk
    }

    private static func extractMask(
        from data: Data,
        manifestInfo: ManifestInfo,
        dataBase: Int,
        blocks: [String: Data]
    ) throws -> Data {
        if let mask = blocks["local.hdr.linear.mask"], mask.starts(with: Data([0xFF, 0xD8])) {
            return mask
        }

        if let entry = manifestInfo.entries.first(where: { $0.name == "local.hdr.linear.mask" }) {
            let candidates = [
                manifestInfo.jsonStart - entry.offset,
                dataBase + entry.start,
                manifestInfo.extensionStart + entry.offset,
            ]

            for start in candidates {
                let end = start + entry.length
                if start >= 0, end <= data.count {
                    let candidate = data.subdata(in: start..<end)
                    if candidate.starts(with: Data([0xFF, 0xD8])) {
                        return candidate
                    }
                }
            }
        }

        let extensionData = data.subdata(in: manifestInfo.extensionStart..<data.count)
        let jpegStart = Data([0xFF, 0xD8, 0xFF])
        var blobs: [(length: Int, data: Data)] = []
        var pos = 0
        while let hit = firstIndex(of: jpegStart, in: extensionData, startingAt: pos) {
            if let endMarker = firstIndex(of: Data([0xFF, 0xD9]), in: extensionData, startingAt: hit + 3) {
                let blobEnd = endMarker + 2
                let blob = extensionData.subdata(in: hit..<blobEnd)
                blobs.append((blob.count, blob))
                pos = blobEnd
            } else {
                pos = hit + 1
            }
        }
        guard !blobs.isEmpty else {
            throw CLIError.invalidLHDR("failed to locate local.hdr.linear.mask JPEG")
        }

        if let maskEntry = manifestInfo.entries.first(where: { $0.name == "local.hdr.linear.mask" }) {
            return blobs.min { abs($0.length - maskEntry.length) < abs($1.length - maskEntry.length) }!.data
        }
        return blobs[0].data
    }

    private static func discoverImagePositions(in data: Data, start: Int) -> [Int] {
        let needles = [Data([0xFF, 0xD8, 0xFF]), Data([0x89, 0x50, 0x4E, 0x47])]
        var hits: Set<Int> = []
        for needle in needles {
            var pos = start
            while let idx = firstIndex(of: needle, in: data, startingAt: pos) {
                hits.insert(idx)
                pos = idx + 1
            }
        }
        return hits.sorted()
    }

    private static func relativeManifestStart(in extensionData: Data) -> Int? {
        lastIndex(of: Data("[{".utf8), in: extensionData)
    }

    private static func scoreMetaCandidate(_ floats: [Double]) -> Int {
        guard floats.count == 36 else { return Int.min }
        var score = 0
        if abs(floats[2] - 144.0) < 0.01 { score += 5 }
        if abs(floats[5] + 1.0) < 0.01 { score += 3 }
        if abs(floats[18] - 10.0) < 0.01 { score += 2 }
        if abs(floats[19] - 6.0) < 0.01 { score += 2 }
        if 2.0 <= floats[0], floats[0] <= 5.0 { score += 2 }
        if 0.0 <= floats[29], floats[29] <= 2000.0 { score += 1 }
        return score
    }

    private static func scoreMetaChunk(_ chunk: Data) -> Int {
        guard let floats = try? unpack36FloatLE(chunk) else { return Int.min }
        var score = 0
        if abs(floats[2] - 144.0) < 0.01 { score += 8 }
        if abs(floats[5] + 1.0) < 0.01 { score += 4 }
        if abs(floats[18] - 10.0) < 0.01 { score += 2 }
        if abs(floats[19] - 6.0) < 0.01 { score += 2 }
        if [0, 1, 7, 16].allSatisfy({ abs(floats[$0] - 1.0) < 0.25 }) { score += 2 }
        if [10, 11, 12, 13, 14, 15].allSatisfy({ abs(floats[$0]) < 0.25 }) { score += 2 }
        return score
    }

    private static func decodeLocalHDRInfo(from metaBytes: Data) throws -> LocalHDRInfo {
        let values = try unpackFloatArrayLE(Data(metaBytes.prefix(16)), count: 4)
        return LocalHDRInfo(
            version: values[0],
            length: values[1],
            metaSize: values[2],
            offset: values[3]
        )
    }
}

private enum MaskDecoder {
    static func decodeMaskJPEG(_ data: Data, sourceURL: URL, channelCount: Int = 1) throws -> GainMapRaster {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw CLIError.unableToDecodeMask(sourceURL)
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw CLIError.unableToDecodeMask(sourceURL)
        }

        if channelCount == 3 {
            // UHDR: decode directly as 32-bit BGRA (Native iOS/macOS alignment = B,G,R,A)
            let bytesPerRow = alignUp(width * 4, toMultipleOf: 64)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            var bgraData = Data(count: bytesPerRow * height)

            let ok = bgraData.withUnsafeMutableBytes { buffer -> Bool in
                guard let base = buffer.baseAddress,
                      let ctx = CGContext(
                        data: base,
                        width: width,
                        height: height,
                        bitsPerComponent: 8,
                        bytesPerRow: bytesPerRow,
                        space: colorSpace,
                        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
                      ) else {
                    return false
                }
                ctx.interpolationQuality = .none
                ctx.setBlendMode(.copy)
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }

            guard ok else {
                throw CLIError.unableToDecodeMask(sourceURL)
            }

            return GainMapRaster(width: width, height: height, bytesPerRow: bytesPerRow, channelCount: 3, data: bgraData)
        } else {
            // LHDR: single-channel grayscale
            let bytesPerRow = width
            let colorSpace = CGColorSpaceCreateDeviceGray()
            var raster = Data(count: bytesPerRow * height)

            let ok = raster.withUnsafeMutableBytes { buffer -> Bool in
                guard let base = buffer.baseAddress,
                      let ctx = CGContext(
                        data: base,
                        width: width,
                        height: height,
                        bitsPerComponent: 8,
                        bytesPerRow: bytesPerRow,
                        space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.none.rawValue
                      ) else {
                    return false
                }
                ctx.interpolationQuality = .none
                ctx.setBlendMode(.copy)
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }

            guard ok else {
                throw CLIError.unableToDecodeMask(sourceURL)
            }

            return GainMapRaster(width: width, height: height, bytesPerRow: bytesPerRow, channelCount: 1, data: raster)
        }
    }
}

private enum EDRScaleResolver {
    static func resolve(metaFloats: [Double], mode: ExtractionMode) throws -> ResolvedScale {
        if mode == .uhdr {
            guard metaFloats.count >= 20 else {
                throw CLIError.invalidLHDR("local.uhdr.gainmap.info must contain at least 20 float32 values")
            }
            let ratioMin = metaFloats[0]
            let ratioMax = metaFloats[4]
            let gamma = metaFloats[7]
            let epsilonSdr = metaFloats[10]
            let epsilonHdr = metaFloats[13]
            let displayRatioSdr = metaFloats[16]
            let displayRatioHdr = metaFloats[17]
            let scaleVal = metaFloats[18]
            
            return ResolvedScale(
                edrScale: scaleVal,
                ratioMin: ratioMin,
                ratioMax: ratioMax,
                gamma: gamma,
                epsilonSdr: epsilonSdr,
                epsilonHdr: epsilonHdr,
                displayRatioSdr: displayRatioSdr,
                displayRatioHdr: displayRatioHdr,
                scale: scaleVal,
                gainMapMin: safeLog2(ratioMin),
                gainMapMax: safeLog2(ratioMax),
                baseHeadroom: safeLog2(displayRatioSdr),
                alternateHeadroom: safeLog2(displayRatioHdr),
                source: "local.uhdr.gainmap.info",
                channelCount: 3,
                perChannelGainMapMin: [safeLog2(metaFloats[0]), safeLog2(metaFloats[1]), safeLog2(metaFloats[2])],
                perChannelGainMapMax: [safeLog2(metaFloats[4]), safeLog2(metaFloats[5]), safeLog2(metaFloats[6])],
                perChannelGamma: [metaFloats[7], metaFloats[8], metaFloats[9]],
                perChannelBaseOffset: [metaFloats[10], metaFloats[11], metaFloats[12]],
                perChannelAlternateOffset: [metaFloats[13], metaFloats[14], metaFloats[15]]
            )
        }

        guard metaFloats.count == 36 else {
            throw CLIError.invalidLHDR("local.hdr.meta.data must contain exactly 36 float32 values")
        }

        return resolvedScale(
            edrScale: edrScaleCalculator(metaFloats),
            source: metaFloats[0] < 3.0 ? "float32_early_lhdr_edr_scale" : "empirical_edrScaleCalculator"
        )
    }

    private static func resolvedScale(
        edrScale: Double,
        source: String
    ) -> ResolvedScale {
        let edrScale = clamp(edrScale, min: 1.0, max: 7.9)
        let ratioMin = 1.0
        let ratioMax = edrScale
        let gamma = 1.0
        let epsilonSdr = 0.0
        let epsilonHdr = 0.0
        let displayRatioSdr = 1.0
        let displayRatioHdr = ratioMax
        let scaleValue = displayRatioHdr

        return ResolvedScale(
            edrScale: edrScale,
            ratioMin: ratioMin,
            ratioMax: ratioMax,
            gamma: gamma,
            epsilonSdr: epsilonSdr,
            epsilonHdr: epsilonHdr,
            displayRatioSdr: displayRatioSdr,
            displayRatioHdr: displayRatioHdr,
            scale: scaleValue,
            gainMapMin: safeLog2(ratioMin),
            gainMapMax: safeLog2(ratioMax),
            baseHeadroom: safeLog2(displayRatioSdr),
            alternateHeadroom: safeLog2(displayRatioHdr),
            source: source,
            channelCount: 1,
            perChannelGainMapMin: [safeLog2(ratioMin)],
            perChannelGainMapMax: [safeLog2(ratioMax)],
            perChannelGamma: [gamma],
            perChannelBaseOffset: [epsilonSdr],
            perChannelAlternateOffset: [epsilonHdr]
        )
    }

    /// Compute the early-LHDR Reinhard knee point from EDR scale factor.
    static func getKneePoint(_ edr: Double) -> Double {
        getKneePointResult(edr).value
    }

    static func getKneePointResult(_ edr: Double) -> (value: Double, source: String) {
        let scale = Float(edr)
        let invGamma = Float(0.45454543828964233)
        let t = 1.0 / (scale * Float(100.0))
        let k = 1.0 - t

        // Three-stage power chain for curve fitting
        let p1 = powf(scale, invGamma)
        let div1 = 1.0 / p1
        let xNorm = (Float(0.9800000190734863) - t) / k
        let p2 = powf(xNorm, invGamma)
        let y = (p2 * Float(1.003937005996704) - div1) / (1.0 - div1)
        return (Double(quantizedKnee(fromPoweredBase: y, invGamma: invGamma)), "float32_early_lhdr_knee")
    }

    private static func quantizedKnee(fromPoweredBase base: Float, invGamma: Float) -> Float {
        guard base.isFinite, base > 0.0 else { return .nan }
        let p3 = powf(base, invGamma)
        guard p3.isFinite, p3 != 1.0 else { return .nan }

        // Reinhard knee point discretization and rounding
        let kneeRaw = p3 * Float(255.0) + Float(-254.0)
        let kneeAdj = kneeRaw / (p3 - 1.0)
        var result = kneeAdj.rounded(.toNearestOrAwayFromZero)
        if result <= 0.0 { result = kneeRaw }
        return result / Float(255.0)
    }

    /// Complete EDR scale calculation — verified against device probe data.
    ///
    /// The calculation uses two distinct empirical models based on device generation and scene detection:
    ///
    /// **SIGMOID PATH** (f23 <= 0.99 || f0 < 3.0):
    ///   sigmoid(f32) → dynamic range correction → sqrt adjustment (by f29) → clamp
    ///
    /// **MAIN PATH** (f23 > 0.99 && f0 >= 3.0):
    ///   3-segment linear mapping → clamp
    ///
    /// Note: Adjustments include linear interpolations and threshold cutoffs observed in raw sample EXIF data.
    private static func edrScaleCalculator(_ f: [Double]) -> Double {
        // Keep the established f0 >= 3.0 LHDR path below unchanged.
        if f[0] < 3.0 {
            return Double(float32EarlyLHDRScaleCalculator(f))
        }

        // Path A: EDR version < 2.0 → return 1.0
        if f[0] < 2.0 { return 1.0 }

        // Path B: Precomputed EDR >= 1.0 → bypass
        if f[33] >= 1.0 { return f[33] }

        // Path C: Raw gain <= 0 → error
        if f[32] <= 0.0 { return 1.0 }

        let f23 = f[23]
        let f24 = f[24]
        let f29 = max(f[29], 1.0)
        let f32 = f[32]
        let cfg = Int(f[34]) == 1

        // Branch: f23 <= 0.99 || f0 < 3.0 → SIGMOID PATH
        if f23 <= 0.99 || f[0] < 3.0 {
            // Sigmoid: 780.3 / (exp2(f32*(-0.1175) - 6.829) + 1) - 772.3
            let expArg = f32 * (-0.1175) + (-6.829)
            var edr = 780.3 / (pow(2.0, expArg) + 1.0) + (-772.3)

            // Face correction (f24 > 0): factor = min(f24, 1/f24)
            if f24 > 0.0 {
                let factor = (f24 < 1.0) ? f24 : 1.0 / f24
                edr = (edr - 1.0) * factor + 1.0
            }

            // f29-dependent sqrt adjustment
            if f29 >= 200.0 {
                // Complex sqrt — two sub-branches by f29 vs 320
                let s4 = abs(sqrt(abs(edr))) - 1.0
                if f29 >= 320.0 {
                    edr = s4 * 1.34 + 1.0
                } else {
                    edr = s4 * (f29 * (-0.0205) + 7.9) + 1.0
                }
            } else {
                // Simple sqrt with 3.8 factor
                let s4 = abs(sqrt(abs(edr))) - 1.0
                edr = s4 * 3.8 + 1.0
            }

            // Config flag / final adjustment
            if cfg {
                edr = (abs(sqrt(abs(edr))) - 1.0) * 1.3 + 1.0
            } else if f24 > 0.0 {
                let adjusted = (abs(sqrt(abs(edr))) - 1.0) * 1.85 + 1.0
                edr = f29 <= 320.0 ? adjusted : (adjusted - 1.0) * 0.8 + 1.0
            } else {
                edr = f29 <= 320.0 ? edr : (edr - 1.0) * 0.8 + 1.0
            }

            return clamp(edr, min: 1.0, max: 7.9)
        }

        // MAIN PATH (f23 > 0.99 && f0 >= 3.0): no face correction, no sqrt — direct 3-segment + clamp
        let normGain = (f32 * 1023.0) / 65535.0
        let scaled = log2(normGain * 63.0 + 1.0) / f29 * 100.0

        let edr: Double
        if f29 <= 210.0 {
            edr = scaled * 0.3456 + 1.824
        } else if f29 > 340.0 {
            edr = scaled * 0.1046 + 1.878
        } else {
            edr = scaled * 0.5883 + 1.401
        }

        return clamp(edr, min: 1.0, max: 7.9)
    }

    private static func float32EarlyLHDRScaleCalculator(_ f: [Double]) -> Float {
        let version = Float(f[0])
        if version < 2.0 { return 1.0 }

        let precomputed = Float(f[33])
        if precomputed >= 1.0 { return precomputed }

        let rawGain = Float(f[32])
        if rawGain <= 0.0 { return 1.0 }

        let faceStrength = Float(f[24])
        let highlight = Float(f[29])

        var edr = exp2f(fmaf(rawGain, Float(-0.11749999970197678), Float(-6.828999996185303)))
        edr = Float(780.2999877929688) / (edr + 1.0) + Float(-772.2999877929688)

        var faceAdjusted = edr
        if faceStrength > 0.0 {
            let factor = faceStrength < 1.0 ? faceStrength : 1.0 / faceStrength
            faceAdjusted = fmaf(edr - 1.0, factor, 1.0)
        }

        let sqrtTerm = abs(sqrtf(faceAdjusted)) - 1.0
        let highlightAdjusted: Float
        if highlight >= Float(200.0) {
            let highHighlight = fmaf(sqrtTerm, Float(1.340000033378601), 1.0)
            let midFactor = fmaf(highlight, Float(-0.020500000566244125), Float(7.900000095367432))
            let midHighlight = fmaf(sqrtTerm, midFactor, 1.0)
            highlightAdjusted = highlight >= Float(320.0) ? highHighlight : midHighlight
        } else {
            highlightAdjusted = fmaf(sqrtTerm, Float(3.799999952316284), 1.0)
        }

        if Float(f[34]).bitPattern == 1 {
            let cfgTerm = abs(sqrtf(highlightAdjusted)) - 1.0
            return fmaf(cfgTerm, Float(1.2999999523162842), 1.0)
        }

        if faceStrength > 0.0 {
            let faceTerm = abs(sqrtf(highlightAdjusted)) - 1.0
            let adjusted = fmaf(faceTerm, Float(1.850000023841858), 1.0)
            if highlight <= Float(320.0) {
                return adjusted
            }
            return fmaf(adjusted - 1.0, Float(0.800000011920929), 1.0)
        }

        if highlight <= Float(320.0) {
            return highlightAdjusted
        }
        return fmaf(highlightAdjusted - 1.0, Float(0.800000011920929), 1.0)
    }

    static func makeTrace(
        metaFloats: [Double],
        scale: ResolvedScale,
        familyDetected: Family,
        familyUsed: Family
    ) -> CalibrationTrace {
        let floatAudits = buildFloatAudits(metaFloats)
        let f = metaFloats
        let log2f32 = f.count > 32 ? optionalLog2(f[32]) : nil
        let highlightRef = f.count > 29 ? max(f[29], 1.0) : 1.0

        let branch = f.count > 0 && f[0] < 3.0
            ? "float32_early_lhdr_edr_scale"
            : "empirical_edrScaleCalculator"

        let preCorrectionEDR = scale.edrScale
        let finalEDR = scale.edrScale
        let faceCorrectionApplied = f.count > 24 ? f[24] > 0.0 : false
        let sqrtCorrectionApplied = f.count > 34 ? (Int(f[34]) == 1 || (f[24] > 0.0)) : false

        return CalibrationTrace(
            familyDetected: familyDetected.rawValue,
            familyUsed: familyUsed.rawValue,
            floatAudits: floatAudits,
            basePath: CalibrationTrace.BasePath(
                branch: branch,
                log2f32: log2f32.map { round($0, digits: 7) },
                highlightRef: round(highlightRef, digits: 7),
                log2rm: nil,
                preCorrectionEDR: round(preCorrectionEDR, digits: 7),
                faceCorrectionApplied: faceCorrectionApplied,
                sqrtCorrectionApplied: sqrtCorrectionApplied,
                finalEDR: round(finalEDR, digits: 7)
            ),
            strictPath: CalibrationTrace.StrictPath(
                intercept: 0, baseContribution: 0, facePenalty: 0, highlightPenalty: 0,
                sceneTerm: 0, hdrBoostTerm: 0, rawCalibratedEDR: 0, clampedEDR: 0,
                ratioMax: 0, gainMapMax: 0
            ), // Maintained for schema compatibility, but zeroed out
            resolvedEDRScale: round(scale.edrScale, digits: 7)
        )
    }

}

private enum GainMapReconstructor {
    static func reconstruct(
        mask: GainMapRaster,
        family: Family,
        scale: ResolvedScale,
        metaFloats: [Double]
    ) throws -> (raster: GainMapRaster, params: GainMapParams) {
        let params = try parameters(for: family, scale: scale, metaFloats: metaFloats)
        let lut0 = makeLUT(count: 1001) { x in pow(x, 0.625) }
        let lut1 = makeLUT(count: 1001) { x in pow(x, 2.2) }
        let lut2 = makeLUT(count: 1001) { x in pow(x * params.headroomScale + 1.0, 2.2) }
        let lut3 = makeLUT(count: 8001) { x in
            if x == 0.0 { return 0.0 }
            let clamped = min(max(x, 1.0), params.maxBoost)
            return params.log2Scale * log2(clamped)
        }

        let outputBytesPerRow = alignUp(mask.width, toMultipleOf: 256)
        var output = Data(count: outputBytesPerRow * mask.height)
        let maskBytes = [UInt8](mask.data)

        output.withUnsafeMutableBytes { rawBuffer in
            guard let outBase = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<mask.height {
                let inRow = y * mask.bytesPerRow
                let outRow = y * outputBytesPerRow
                for x in 0..<mask.width {
                    let maskValue = Double(maskBytes[inRow + x]) / 255.0
                    let idx0 = clamp(Int(maskValue * 1000.0), min: 0, max: 1000)
                    let linGray = lut0[idx0]

                    let boosted: Double
                    if linGray < params.knee {
                        boosted = 1.0
                    } else {
                        let t = (linGray - params.knee) / params.kneeRange
                        let idx1 = clamp(Int(t * 1000.0), min: 0, max: 1000)
                        let linear = lut1[idx1]
                        let idx2 = clamp(Int(linear * 1000.0), min: 0, max: 1000)
                        boosted = lut2[idx2]
                    }

                    let idx3: Int
                    if boosted < 1.0 {
                        idx3 = 1000
                    } else {
                        idx3 = clamp(Int(min(boosted, 8.0) * 1000.0), min: 0, max: 8000)
                    }

                    let logGain = clamp(Int(lut3[idx3]), min: 0, max: 255)
                    outBase[outRow + x] = UInt8(logGain)
                }
            }
        }

        return (
            GainMapRaster(width: mask.width, height: mask.height, bytesPerRow: outputBytesPerRow, channelCount: 1, data: output),
            params
        )
    }

    /// Determine gain map parameters based on EDR version
    /// The parameter selection splits based on device generation (EDR >= 3.0 uses direct log2 scale)
    private static func parameters(for family: Family, scale: ResolvedScale, metaFloats: [Double]) throws -> GainMapParams {
        // Calculate headroom scale using standard gamma compensation
        let gammaFactor = pow(1.0 / scale.edrScale, 1.0 / 2.2)
        let headroomScale = (1.0 - gammaFactor) / gammaFactor
        let maxBoost = scale.edrScale > 1.0 ? scale.edrScale : 2.0

        // Log2Scale maps maximum EDR boost to full 8-bit dynamic range
        let log2Scale = scale.edrScale > 1.0 ? 255.0 / log2(scale.edrScale) : 0.0

        let edrVersion = metaFloats.count > 0 ? metaFloats[0] : 3.0
        let knee: Double
        let kneeSource: String

        // Path selection based on EDR version
        if edrVersion >= 3.0 {
            // EDR >= 3.0: pure log2 path — no knee point used
            knee = 0.0
            kneeSource = "edr_ge3_log2_path"
        } else {
            // EDR < 3.0: Reinhard knee path
            let result = EDRScaleResolver.getKneePointResult(scale.edrScale)
            knee = result.value
            kneeSource = result.source
        }

        let kneeRange = 1.0 - knee
        guard knee.isFinite, kneeRange.isFinite, kneeRange > 0 else {
            throw CLIError.invalidLHDR("non-finite gain map params: knee=\(knee), kneeRange=\(kneeRange)")
        }

        return GainMapParams(
            family: family,
            knee: knee,
            kneeRange: kneeRange,
            headroomScale: headroomScale,
            maxBoost: maxBoost,
            log2Scale: log2Scale,
            kneeSource: kneeSource
        )
    }

    private static func makeLUT(count: Int, generator: (Double) -> Double) -> [Double] {
        (0..<count).map { generator(Double($0) / 1000.0) }
    }
}

private enum ISOHDRWriter {
    static func write(
        baseImageURL: URL,
        gainMap: GainMapRaster,
        style: HDRToneMapStyle,
        outputURL: URL,
        oppoCompatibility: OppoCompatibility = .off,
        inputProcessingBranch: InputProcessingBranch = .system
    ) throws {
        if inputProcessingBranch == .hybrid {
            // Phase 1: write intermediate using existing aux-data path
            let intermediateURL = outputURL.appendingPathExtension("intermediate")
            let source = try makeImageSource(url: baseImageURL)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let sourceData = try Data(contentsOf: baseImageURL)
            let patchedUserComment = adjustedOppoUserComment(in: sourceData, compatibility: oppoCompatibility)
            let metadata = try makeHDRToneMapMetadata(style: style)
            let auxInfo = try makeAuxiliaryDataInfo(gainMap: gainMap, metadata: metadata, inputProcessingBranch: .system)
            let primaryMetadata = try makeUltraHDRXMPMetadata(style: style)
            try writeHEIC(
                source: source,
                originalProperties: properties,
                auxiliaryDataInfo: auxInfo,
                primaryMetadata: primaryMetadata,
                patchedUserComment: patchedUserComment,
                outputURL: intermediateURL,
                gainMapChannelCount: gainMap.channelCount,
                inputProcessingBranch: .system,
                oppoCompatibility: oppoCompatibility
            )

            // Phase 2: re-read intermediate and write with preserve
            try writeWithPreserveReencode(
                intermediateURL: intermediateURL,
                outputURL: outputURL,
                patchedUserComment: patchedUserComment,
                oppoCompatibility: oppoCompatibility
            )
            try? FileManager.default.removeItem(at: intermediateURL)
        } else {
            let source = try makeImageSource(url: baseImageURL)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]

            // Extract adjusted UserComment from source file bytes (bypasses ImageIO typing issues).
            let sourceData = try Data(contentsOf: baseImageURL)
            let patchedUserComment = adjustedOppoUserComment(in: sourceData, compatibility: oppoCompatibility)

            let metadata = try makeHDRToneMapMetadata(style: style)
            let auxInfo = try makeAuxiliaryDataInfo(gainMap: gainMap, metadata: metadata, inputProcessingBranch: inputProcessingBranch)
            let primaryMetadata = try makeUltraHDRXMPMetadata(style: style)
            try writeHEIC(
                source: source,
                originalProperties: properties,
                auxiliaryDataInfo: auxInfo,
                primaryMetadata: primaryMetadata,
                patchedUserComment: patchedUserComment,
                outputURL: outputURL,
                gainMapChannelCount: gainMap.channelCount,
                inputProcessingBranch: inputProcessingBranch,
                oppoCompatibility: oppoCompatibility,
                decodePrimaryImage: inputProcessingBranch == .systemDecoded
            )
            try verifyOutput(outputURL, requiredGainMapPixelFormat: requiredPixelFormat(for: inputProcessingBranch, channelCount: gainMap.channelCount))
        }
    }

    private static func makeImageSource(url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw CLIError.unableToLoadBaseImage(url)
        }
        return source
    }

    private static func makeSDRBaseImage(source: CGImageSource, url: URL) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR
        ]
        let imageIndex = CGImageSourceGetPrimaryImageIndex(source)
        guard let image = CGImageSourceCreateImageAtIndex(source, imageIndex, options as CFDictionary) else {
            throw CLIError.unableToLoadBaseImage(url)
        }
        return image
    }

     private static func makeHDRToneMapMetadata(style: HDRToneMapStyle) throws -> CGImageMetadata {
        let metadata = CGImageMetadataCreateMutable()

        let namespace = "http://ns.apple.com/HDRToneMap/1.0/" as CFString
        let prefix = "HDRToneMap" as CFString
        var error: Unmanaged<CFError>?
        guard CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace, prefix, &error) else {
            if let error { throw error.takeRetainedValue() as Error }
            throw CLIError.unableToCreateMetadata
        }

        func set(_ path: String, _ value: CFTypeRef) throws {
            guard CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value) else {
                throw CLIError.unableToCreateMetadata
            }
        }

        try set("HDRToneMap:Version", String(style.version) as CFString)
        try set("HDRToneMap:BaseHeadroom", formatFloat(style.baseHeadroom, digits: 6) as CFString)
        try set("HDRToneMap:AlternateHeadroom", formatFloat(style.alternateHeadroom, digits: 6) as CFString)
        try set("HDRToneMap:BaseColorIsWorkingColor", style.baseColorIsWorkingColor ? kCFBooleanTrue! : kCFBooleanFalse!)

        for ch in 0..<style.channelCount {
            let gmMin = ch < style.perChannelGainMapMin.count ? style.perChannelGainMapMin[ch] : style.gainMapMin
            let gmMax = ch < style.perChannelGainMapMax.count ? style.perChannelGainMapMax[ch] : style.gainMapMax
            let gm = ch < style.perChannelGamma.count ? style.perChannelGamma[ch] : style.gamma
            let bo = ch < style.perChannelBaseOffset.count ? style.perChannelBaseOffset[ch] : style.baseOffset
            let ao = ch < style.perChannelAlternateOffset.count ? style.perChannelAlternateOffset[ch] : style.alternateOffset
            try set("HDRToneMap:ChannelMetadata[\(ch)].GainMapMin", formatFloat(gmMin, digits: 6) as CFString)
            try set("HDRToneMap:ChannelMetadata[\(ch)].GainMapMax", formatFloat(gmMax, digits: 6) as CFString)
            try set("HDRToneMap:ChannelMetadata[\(ch)].Gamma", formatFloat(gm, digits: 6) as CFString)
            try set("HDRToneMap:ChannelMetadata[\(ch)].BaseOffset", formatFloat(bo, digits: 6) as CFString)
            try set("HDRToneMap:ChannelMetadata[\(ch)].AlternateOffset", formatFloat(ao, digits: 6) as CFString)
        }
        return metadata
    }

    private static func makeUltraHDRXMPMetadata(style: HDRToneMapStyle) throws -> CGImageMetadata {
        let metadata = CGImageMetadataCreateMutable()
        let namespace = "http://ns.adobe.com/hdr-gain-map/1.0/" as CFString
        let prefix = "hdrgm" as CFString
        var error: Unmanaged<CFError>?
        guard CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace, prefix, &error) else {
            if let error { throw error.takeRetainedValue() as Error }
            throw CLIError.unableToCreateMetadata
        }

        func set(_ path: String, _ value: CFTypeRef) throws {
            guard CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value) else {
                throw CLIError.unableToCreateMetadata
            }
        }

        try set("hdrgm:Version", "1.0" as CFString)
        try set("hdrgm:GainMapMin", formatFloat(style.gainMapMin, digits: 6) as CFString)
        try set("hdrgm:GainMapMax", formatFloat(style.gainMapMax, digits: 6) as CFString)
        try set("hdrgm:Gamma", formatFloat(style.gamma, digits: 6) as CFString)
        try set("hdrgm:OffsetSDR", formatFloat(style.baseOffset, digits: 6) as CFString)
        try set("hdrgm:OffsetHDR", formatFloat(style.alternateOffset, digits: 6) as CFString)
        try set("hdrgm:HDRCapacityMin", formatFloat(style.baseHeadroom, digits: 6) as CFString)
        try set("hdrgm:HDRCapacityMax", formatFloat(style.alternateHeadroom, digits: 6) as CFString)
        try set("hdrgm:BaseRenditionIsHDR", "False" as CFString)

        return metadata
    }

    private static func makeAuxiliaryDataInfo(
        gainMap: GainMapRaster,
        metadata: CGImageMetadata,
        inputProcessingBranch: InputProcessingBranch
    ) throws -> CFDictionary {
        let payload = try makeAuxiliaryGainMapPayload(gainMap: gainMap, branch: inputProcessingBranch)

        let description: [CFString: Any] = [
            kCGImagePropertyWidth: NSNumber(value: gainMap.width),
            kCGImagePropertyHeight: NSNumber(value: gainMap.height),
            kCGImagePropertyBytesPerRow: NSNumber(value: payload.bytesPerRow),
            kCGImagePropertyPixelFormat: NSNumber(value: payload.pixelFormat)
        ]

        let info: [CFString: Any] = [
            kCGImageAuxiliaryDataInfoData: payload.data,
            kCGImageAuxiliaryDataInfoDataDescription: description,
            kCGImageAuxiliaryDataInfoMetadata: metadata
        ]
        return info as CFDictionary
    }

    private static func makeAuxiliaryGainMapPayload(gainMap: GainMapRaster, branch: InputProcessingBranch) throws -> AuxiliaryGainMapPayload {
        guard gainMap.channelCount == 3 else {
            return AuxiliaryGainMapPayload(
                data: gainMap.data,
                bytesPerRow: gainMap.bytesPerRow,
                pixelFormat: fourCC("L008")
            )
        }

        return AuxiliaryGainMapPayload(
            data: gainMap.data,
            bytesPerRow: gainMap.bytesPerRow,
            pixelFormat: fourCC("BGRA")
        )
    }

    private static func writeHEIC(
        source: CGImageSource,
        originalProperties: [CFString: Any]?,
        auxiliaryDataInfo: CFDictionary,
        primaryMetadata: CGImageMetadata,
        patchedUserComment: String?,
        outputURL: URL,
        gainMapChannelCount: Int,
        inputProcessingBranch: InputProcessingBranch,
        oppoCompatibility: OppoCompatibility,
        decodePrimaryImage: Bool = false
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw CLIError.unableToCreateDestination(outputURL)
        }

        var requestOptions: [CFString: Any] = [
            kCGImageDestinationEncodeBaseIsSDR: true,
            kCGImageDestinationLossyCompressionQuality: 1.0
        ]
        if oppoCompatibility.wantsOppoCompat {
            requestOptions[cgImageDestinationEncodeGainMapSubsampleFactorCompat] = NSNumber(value: 2)
        }
        try configureGainMapEncodingOptions(&requestOptions, channelCount: gainMapChannelCount, branch: inputProcessingBranch)

        var imageOptions: [CFString: Any] = [
            kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOGainmap,
            kCGImageDestinationEncodeRequestOptions: requestOptions as CFDictionary,
            kCGImageDestinationMergeMetadata: primaryMetadata
        ]
        
        if let originalProperties, !decodePrimaryImage {
            for (key, value) in originalProperties {
                imageOptions[key] = value
            }
        }

        if let patchedUserComment {
            var exifDictionary: [CFString: Any] = [:]
            if let existing = imageOptions[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exifDictionary = existing
            } else if let existing = imageOptions[kCGImagePropertyExifDictionary] as? [String: Any] {
                for (key, value) in existing {
                    exifDictionary[key as CFString] = value
                }
            }
            exifDictionary[kCGImagePropertyExifUserComment] = patchedUserComment
            imageOptions[kCGImagePropertyExifDictionary] = exifDictionary as CFDictionary
        }

        if decodePrimaryImage {
            guard let decodedImage = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            let context = CGContext(
                data: nil,
                width: decodedImage.width,
                height: decodedImage.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw CLIError.unableToLoadBaseImage(outputURL)
            }
            context.draw(decodedImage, in: CGRect(x: 0, y: 0, width: decodedImage.width, height: decodedImage.height))
            guard let image8Bit = context.makeImage() else {
                throw CLIError.unableToLoadBaseImage(outputURL)
            }
            CGImageDestinationAddImage(destination, image8Bit, imageOptions as CFDictionary)
        } else {
            CGImageDestinationAddImageFromSource(destination, source, 0, imageOptions as CFDictionary)
        }
        CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeISOGainMap, auxiliaryDataInfo)

        guard CGImageDestinationFinalize(destination) else {
            throw CLIError.unableToFinalizeDestination(outputURL)
        }
    }

    private static func verifyOutput(_ outputURL: URL, requiredGainMapPixelFormat: UInt32?) throws {
        guard let source = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
              let auxInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString: Any] else {
            throw CLIError.outputVerificationFailed(outputURL)
        }

        guard let requiredGainMapPixelFormat else { return }
        let description = auxInfo[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any]
        let actualPixelFormat = pixelFormatValue(description?[kCGImagePropertyPixelFormat])
        guard actualPixelFormat == requiredGainMapPixelFormat else {
            throw CLIError.gainMapPixelFormatMismatch(
                outputURL,
                expected: requiredGainMapPixelFormat,
                actual: actualPixelFormat
            )
        }
    }

    static func writeWithPreserveReencode(
        intermediateURL: URL,
        outputURL: URL,
        patchedUserComment: String? = nil,
        oppoCompatibility: OppoCompatibility = .off
    ) throws {
        guard let intermediateSource = CGImageSourceCreateWithURL(intermediateURL as CFURL, nil) else {
            throw CLIError.unableToLoadBaseImage(intermediateURL)
        }

        // Verify intermediate has ISO gain map
        guard let auxInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(intermediateSource, 0, kCGImageAuxiliaryDataTypeISOGainMap) else {
            throw CLIError.outputVerificationFailed(intermediateURL)
        }
        let desc = (auxInfo as? [CFString: Any])?[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any]
        let pfRaw = pixelFormatValue(desc?[kCGImagePropertyPixelFormat])

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw CLIError.unableToCreateDestination(outputURL)
        }

        // Build preserve options
        var imageOptions: [CFString: Any] = [
            kCGImageDestinationPreserveGainMap: true
        ]
        if oppoCompatibility.wantsOppoCompat {
            let requestOptions: [CFString: Any] = [
                cgImageDestinationEncodeGainMapSubsampleFactorCompat: NSNumber(value: 2)
            ]
            imageOptions[kCGImageDestinationEncodeRequestOptions] = requestOptions as CFDictionary
        }

        // Pass through original properties from intermediate
        let originalProperties = CGImageSourceCopyPropertiesAtIndex(intermediateSource, 0, nil) as? [CFString: Any]
        if let originalProperties {
            for (key, value) in originalProperties {
                imageOptions[key] = value
            }
        }
        if let patchedUserComment {
            var exifDictionary: [CFString: Any] = [:]
            if let existing = imageOptions[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exifDictionary = existing
            } else if let existing = imageOptions[kCGImagePropertyExifDictionary] as? [String: Any] {
                for (key, value) in existing {
                    exifDictionary[key as CFString] = value
                }
            }
            exifDictionary[kCGImagePropertyExifUserComment] = patchedUserComment
            imageOptions[kCGImagePropertyExifDictionary] = exifDictionary as CFDictionary
        }

        // Write: CGImageDestinationAddImageFromSource ONLY — no AddAuxiliaryDataInfo
        CGImageDestinationAddImageFromSource(destination, intermediateSource, 0, imageOptions as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw CLIError.unableToFinalizeDestination(outputURL)
        }

        // Verify: just check gain map is present (no pixel format enforcement initially)
        let verifySource = CGImageSourceCreateWithURL(outputURL as CFURL, nil)
        let verifyAux = verifySource.flatMap { CGImageSourceCopyAuxiliaryDataInfoAtIndex($0, 0, kCGImageAuxiliaryDataTypeISOGainMap) }
        guard verifyAux != nil else {
            throw CLIError.outputVerificationFailed(outputURL)
        }

        // Log pixel format for observation
        if let verifyDesc = (verifyAux as? [CFString: Any])?[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any] {
            let outputPF = pixelFormatValue(verifyDesc[kCGImagePropertyPixelFormat])
            let intermediatePFStr = fourCCString(pfRaw)
            let outputPFStr = fourCCString(outputPF)
            if outputPF != pfRaw {
                fputs("[preserve] gain map pixel format changed: \(intermediatePFStr) -> \(outputPFStr)\n", stderr)
            } else {
                fputs("[preserve] gain map pixel format preserved: \(outputPFStr)\n", stderr)
            }
        }
    }

    private static func requiredPixelFormat(for branch: InputProcessingBranch, channelCount: Int) throws -> UInt32? {
        switch branch {
        case .system, .systemDecoded, .hybrid, .passthrough:
            return nil
        }
    }

    private static func configureGainMapEncodingOptions(
        _ requestOptions: inout [CFString: Any],
        channelCount: Int,
        branch: InputProcessingBranch
    ) throws {
        switch branch {
        case .system, .systemDecoded, .hybrid, .passthrough:
            return
        }
    }

    private static func pixelFormatValue(_ value: Any?) -> UInt32? {
        if let number = value as? NSNumber {
            return number.uint32Value
        }
        if let value = value as? UInt32 {
            return value
        }
        if let value = value as? Int {
            return UInt32(value)
        }
        return nil
    }

    private static func fourCC(_ value: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in value.utf8 {
            result = (result << 8) | UInt32(byte)
        }
        return result
    }
}

private enum DebugWriter {
    static func writeArtifacts(
        extracted: ExtractedLHDR,
        inputURL: URL,
        debugDirURL: URL,
        familyDetected: Family,
        familyUsed: Family,
        maskRaster: GainMapRaster,
        gainMapRaster: GainMapRaster,
        scale: ResolvedScale,
        params: GainMapParams,
        style: HDRToneMapStyle
    ) throws {
        let fileManager = FileManager.default
        try ensureDirectory(debugDirURL, fileManager: fileManager)

        let metaURL = debugDirURL.appendingPathComponent("meta.json")
        let localHDRInfoURL = debugDirURL.appendingPathComponent("local_hdr_info.json")
        let projectionURL = debugDirURL.appendingPathComponent("gainmap_meta_projection.json")
        let calibrationURL = debugDirURL.appendingPathComponent("calibration_trace.json")
        let styleURL = debugDirURL.appendingPathComponent("style.json")
        let maskURL = debugDirURL.appendingPathComponent("mask.png")
        let gainURL = debugDirURL.appendingPathComponent("gainmap.png")
        let calibrationTrace = EDRScaleResolver.makeTrace(
            metaFloats: extracted.metaFloats,
            scale: scale,
            familyDetected: familyDetected,
            familyUsed: familyUsed
        )

        let debugMeta = DebugMeta(
            inputPath: inputURL.path,
            mode: extracted.mode.rawValue,
            metaSHA256: sha256Hex(extracted.metaBytes),
            maskSHA256: sha256Hex(extracted.maskJPEGData),
            metaFloat32: extracted.metaFloats.map { round($0, digits: 6) },
            localHDRInfo: extracted.localHDRInfo,
            maskWidth: maskRaster.width,
            maskHeight: maskRaster.height,
            projection: DebugMeta.Projection(
                familyDetected: familyDetected.rawValue,
                familyUsed: familyUsed.rawValue,
                f0: round(extracted.metaFloats[0], digits: 6),
                edrScale: round(scale.edrScale, digits: 7),
                ratioMin: round(scale.ratioMin, digits: 7),
                ratioMax: round(scale.ratioMax, digits: 7),
                gamma: round(scale.gamma, digits: 7),
                epsilonSdr: round(scale.epsilonSdr, digits: 7),
                epsilonHdr: round(scale.epsilonHdr, digits: 7),
                displayRatioSdr: round(scale.displayRatioSdr, digits: 7),
                displayRatioHdr: round(scale.displayRatioHdr, digits: 7),
                scale: round(scale.scale, digits: 7),
                gainMapMin: round(scale.gainMapMin, digits: 7),
                gainMapMax: round(scale.gainMapMax, digits: 7),
                baseHeadroom: round(scale.baseHeadroom, digits: 7),
                alternateHeadroom: round(scale.alternateHeadroom, digits: 7),
                scaleSource: scale.source,
                knee: round(params.knee, digits: 6),
                kneeSource: params.kneeSource,
                kneeRange: round(params.kneeRange, digits: 6),
                headroomScale: round(params.headroomScale, digits: 6),
                maxBoost: round(params.maxBoost, digits: 6),
                log2Scale: round(params.log2Scale, digits: 6)
            ),
            semanticFields: buildLHDRSemanticFields(floats: extracted.metaFloats)
        )

        let projectionDebug = GainMapMetaProjectionDebug(
            familyDetected: familyDetected.rawValue,
            familyUsed: familyUsed.rawValue,
            source: scale.source,
            edrScale: round(scale.edrScale, digits: 7),
            ratioMin: round(scale.ratioMin, digits: 7),
            ratioMax: round(scale.ratioMax, digits: 7),
            gamma: round(scale.gamma, digits: 7),
            epsilonSdr: round(scale.epsilonSdr, digits: 7),
            epsilonHdr: round(scale.epsilonHdr, digits: 7),
            displayRatioSdr: round(scale.displayRatioSdr, digits: 7),
            displayRatioHdr: round(scale.displayRatioHdr, digits: 7),
            scale: round(scale.scale, digits: 7),
            gainMapMin: round(scale.gainMapMin, digits: 7),
            gainMapMax: round(scale.gainMapMax, digits: 7),
            baseHeadroom: round(scale.baseHeadroom, digits: 7),
            alternateHeadroom: round(scale.alternateHeadroom, digits: 7)
        )

        try writeJSON(debugMeta, to: metaURL)
        try writeJSON(extracted.localHDRInfo, to: localHDRInfoURL)
        try writeJSON(projectionDebug, to: projectionURL)
        try writeJSON(calibrationTrace, to: calibrationURL)
        try writeJSON(style, to: styleURL)
        try writePNG(maskRaster, to: maskURL)
        try writePNG(gainMapRaster, to: gainURL)
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(value)
            try data.write(to: url)
        } catch {
            throw CLIError.unableToWriteDebugAsset(url)
        }
    }

    private static func writePNG(_ raster: GainMapRaster, to url: URL) throws {
        let isColor = raster.channelCount == 3
        guard let provider = CGDataProvider(data: raster.data as CFData),
              let image = CGImage(
                width: raster.width,
                height: raster.height,
                bitsPerComponent: 8,
                bitsPerPixel: isColor ? 32 : 8,
                bytesPerRow: raster.bytesPerRow,
                space: isColor ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: isColor ? (CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue) : CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CLIError.unableToWriteDebugAsset(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CLIError.unableToWriteDebugAsset(url)
        }
    }
}

private func verifyImageIOISOGainMap(_ outputURL: URL) throws {
    guard let source = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
          CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil else {
        throw CLIError.outputVerificationFailed(outputURL)
    }
}

private func isoGainMapPixelFormat(at url: URL) -> UInt32? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
              source,
              0,
              kCGImageAuxiliaryDataTypeISOGainMap
          ) as? [CFString: Any],
          let description = info[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any] else {
        return nil
    }
    if let number = description[kCGImagePropertyPixelFormat] as? NSNumber {
        return number.uint32Value
    }
    if let string = description[kCGImagePropertyPixelFormat] as? String, string.utf8.count == 4 {
        return pixelFormatFourCC(string)
    }
    return nil
}

private func isSubsampledGainMapPixelFormat(_ pixelFormat: UInt32) -> Bool {
    pixelFormat == pixelFormatFourCC("420f")
        || pixelFormat == pixelFormatFourCC("420v")
        || pixelFormat == pixelFormatFourCC("x420")
}

private func gainMapEncodingMatchesTarget(at url: URL, compatibility: OppoCompatibility) -> Bool {
    guard let pixelFormat = isoGainMapPixelFormat(at: url) else { return false }
    if compatibility.wantsOppoCompat {
        return isSubsampledGainMapPixelFormat(pixelFormat)
    }
    return pixelFormat == pixelFormatFourCC("444f")
        || pixelFormat == pixelFormatFourCC("L008")
}

private func pixelFormatFourCC(_ value: String) -> UInt32 {
    value.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

private func rejectLossyGainMapPromotion(inputURL: URL, compatibility: OppoCompatibility) throws {
    guard !compatibility.wantsOppoCompat,
          let pixelFormat = isoGainMapPixelFormat(at: inputURL),
          isSubsampledGainMapPixelFormat(pixelFormat) else { return }
    throw CLIError.invalidContainer(
        "cannot promote an existing 4:2:0 Gain Map to high-spec 4:4:4 because chroma information has already been discarded"
    )
}

private let oppoCameraWatermarkAuxiliaryEntryNames: Set<String> = [
    "color.space",
    "gr.effect.info",
    "master.mode.preset.info",
    "private.emptyspace"
]

private let oppoCameraPortraitEditingEntryNames: Set<String> = [
    "crop.region",
    "front.depth",
    "front.depth.config",
    "front.hair.mask",
    "front.matter.info",
    "front.negevimg",
    "front.segment",
    "mesh.coord",
    "mesh.coord.config",
    "rear.depth",
    "rear.depth.config",
    "rear.spotlight",
    "src.image",
    "src.image.block"
]

private let oppoCameraCompactPortraitTailEntryNames: Set<String> =
    oppoCameraPortraitEditingEntryNames.union(["hdr.transform.data", "src.local.hdr.linear.mask"])

private func shouldPreserveOppoCameraTailEntry(_ name: String, mode: OppoCameraTail) -> Bool {
    switch mode {
    case .off:
        return false
    case .watermark:
        return name.hasPrefix("watermark.") || oppoCameraWatermarkAuxiliaryEntryNames.contains(name)
    case .compact:
        return shouldPreserveOppoCameraTailEntry(name, mode: .watermark)
            || oppoCameraCompactPortraitTailEntryNames.contains(name)
    case .preserveWithoutPortrait:
        return !oppoCameraPortraitEditingEntryNames.contains(name)
    case .preserveWithoutPrivateUHDR:
        return !oppoPrivateUHDRTailEntryNames.contains(name)
    case .preserveWithoutPrivateHDR:
        return !isOppoPrivateHDRTailEntry(name)
    case .preserve, .preserveNoUHDR, .preserveNoHDR:
        return true
    }
}

private let oppoPrivateUHDRTailEntryNames: Set<String> = [
    "local.uhdr.gainmap.data",
    "local.uhdr.gainmap.info"
]

private func isOppoPrivateHDRTailEntry(_ name: String) -> Bool {
    oppoPrivateUHDRTailEntryNames.contains(name)
        || name.hasPrefix("hdr.")
        || name.hasPrefix("local.hdr.")
        || name.hasPrefix("src.local.hdr.")
}

private func shouldNeutralizeOppoCameraTailEntry(_ name: String, mode: OppoCameraTail) -> Bool {
    switch mode {
    case .preserveNoUHDR:
        return oppoPrivateUHDRTailEntryNames.contains(name)
    case .preserveNoHDR:
        return isOppoPrivateHDRTailEntry(name)
    case .off, .watermark, .compact, .preserve, .preserveWithoutPortrait, .preserveWithoutPrivateUHDR, .preserveWithoutPrivateHDR:
        return false
    }
}

private func appendCompleteSourceTail(
    outputURL: URL,
    sourceData: Data,
    manifestInfo: ManifestInfo,
    mode: OppoCameraTail
) throws {
    guard let sourceMdat = isobmffBoxes(in: sourceData, start: 0, end: sourceData.count)
        .first(where: { $0.type == "mdat" }) else {
        throw CLIError.invalidContainer("source mdat missing while preserving OPPO metadata tail")
    }
    let tailStart = sourceMdat.boxStart + sourceMdat.size
    guard tailStart < sourceData.count else { return }
    var tail = sourceData.subdata(in: tailStart..<sourceData.count)

    if mode == .preserveNoUHDR || mode == .preserveNoHDR {
        let jsonStart = manifestInfo.jsonStart - tailStart
        let jsonEnd = manifestInfo.jsonEnd - tailStart
        guard jsonStart >= 0, jsonEnd <= tail.count, jsonStart < jsonEnd else {
            throw CLIError.invalidContainer("OPPO manifest is outside preserved tail")
        }
        for entry in manifestInfo.entries where shouldNeutralizeOppoCameraTailEntry(entry.name, mode: mode) {
            let nameBytes = Data(entry.name.utf8)
            guard let range = tail.range(of: nameBytes, options: [], in: jsonStart..<jsonEnd),
                  !range.isEmpty else {
                throw CLIError.invalidContainer("unable to neutralize OPPO tail entry \(entry.name)")
            }
            tail[range.lowerBound] = UInt8(ascii: "x")
        }
    }

    if let outputData = try? Data(contentsOf: outputURL, options: [.mappedIfSafe]),
       outputData.count >= tail.count,
       outputData.suffix(tail.count) == tail {
        return
    }

    let handle = try FileHandle(forWritingTo: outputURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: tail)
}

private struct PackedOppoCameraTailEntry {
    let entry: ManifestEntry
    let payloadStart: Int
}

private struct OppoCameraTailManifestRecord: Encodable {
    let length: Int
    let name: String
    let offset: Int
    let version: Int
}

private func oppoCameraTailTag(in sourceData: Data) -> Data {
    guard sourceData.count >= 9,
          sourceData[sourceData.count - 9] == 0 else {
        return Data("jxrs".utf8)
    }
    let tag = sourceData.subdata(in: sourceData.count - 8..<sourceData.count - 4)
    guard tag.allSatisfy({ (32...126).contains($0) }) else {
        return Data("jxrs".utf8)
    }
    return tag
}

private func appendOppoCameraTailIfNeeded(
    outputURL: URL,
    sourceData: Data,
    extracted: ExtractedLHDR,
    mode: OppoCameraTail
) throws {
    guard mode != .off else { return }

    if mode == .preserve || mode == .preserveNoUHDR || mode == .preserveNoHDR {
        try appendCompleteSourceTail(
            outputURL: outputURL,
            sourceData: sourceData,
            manifestInfo: extracted.manifestInfo,
            mode: mode
        )
        return
    }

    let selected = extracted.manifestInfo.entries.filter {
        shouldPreserveOppoCameraTailEntry($0.name, mode: mode)
    }
    guard !selected.isEmpty else { return }

    var payload = Data()
    var packedEntries: [PackedOppoCameraTailEntry] = []
    let selectedWithSourceStart = selected.map { entry -> (entry: ManifestEntry, sourceStart: Int) in
        let manifestRelativeStart = extracted.manifestInfo.jsonStart - entry.offset
        if manifestRelativeStart >= 0,
           manifestRelativeStart + entry.length <= sourceData.count {
            return (entry, manifestRelativeStart)
        }
        return (entry, extracted.dataBase + entry.start)
    }

    for (entry, sourceStart) in selectedWithSourceStart.sorted(by: { $0.sourceStart < $1.sourceStart }) {
        let sourceEnd = sourceStart + entry.length
        guard sourceStart >= 0, sourceEnd <= sourceData.count else {
            throw CLIError.invalidContainer("OPPO camera tail entry \(entry.name) is out of bounds")
        }
        let payloadStart = payload.count
        payload.append(sourceData.subdata(in: sourceStart..<sourceEnd))
        packedEntries.append(PackedOppoCameraTailEntry(entry: entry, payloadStart: payloadStart))
    }

    let payloadLength = payload.count
    var packedByName: [String: PackedOppoCameraTailEntry] = [:]
    for packed in packedEntries {
        packedByName[packed.entry.name] = packed
    }
    let manifestRecords: [OppoCameraTailManifestRecord] = selected
        .sorted { $0.jsonOrder < $1.jsonOrder }
        .compactMap { entry in
            guard let packed = packedByName[entry.name] else { return nil }
            return OppoCameraTailManifestRecord(
                length: entry.length,
                name: entry.name,
                offset: payloadLength - packed.payloadStart,
                version: manifestVersion(entry.version)
            )
        }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let manifestJSON = try encoder.encode(manifestRecords)
    var tail = Data()
    tail.append(payload)
    tail.append(manifestJSON)
    tail.append(0)
    tail.append(oppoCameraTailTag(in: sourceData))
    appendUInt32LE(manifestJSON.count + 1 + 4 + 4, to: &tail)

    let handle = try FileHandle(forWritingTo: outputURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: tail)
}

private func isValidOutput(
    _ outputURL: URL,
    oppoCameraTail: OppoCameraTail,
    oppoCompatibility: OppoCompatibility
) -> Bool {
    guard gainMapEncodingMatchesTarget(at: outputURL, compatibility: oppoCompatibility) else { return false }
    switch oppoCameraTail {
    case .off:
        return true
    case .watermark, .compact, .preserve, .preserveWithoutPortrait, .preserveWithoutPrivateUHDR, .preserveWithoutPrivateHDR, .preserveNoUHDR, .preserveNoHDR:
        return hasValidCompactOppoCameraTail(outputURL, mode: oppoCameraTail)
    }
}

private func hasValidCompactOppoCameraTail(_ outputURL: URL, mode: OppoCameraTail) -> Bool {
    guard let data = try? Data(contentsOf: outputURL, options: [.mappedIfSafe]),
          data.count >= 9 else {
        return false
    }
    let markerStart = data.count - 9
    let tag = data.subdata(in: markerStart + 1..<markerStart + 5)
    guard data[markerStart] == 0,
          tag == Data("jxrs".utf8) || tag == Data("wtmk".utf8),
          markerStart + 9 == data.count,
          let jsonStart = lastIndex(of: Data("[{".utf8), in: data),
          jsonStart < markerStart else {
        return false
    }

    let footerOffset = markerStart + 5
    let footerLength = Int(data[footerOffset])
        | (Int(data[footerOffset + 1]) << 8)
        | (Int(data[footerOffset + 2]) << 16)
        | (Int(data[footerOffset + 3]) << 24)
    guard footerLength == data.count - jsonStart,
          let jsonEndBase = firstIndex(of: UInt8(ascii: "]"), in: data, startingAt: jsonStart),
          jsonEndBase < markerStart else {
        return false
    }

    let manifestData = data.subdata(in: jsonStart..<(jsonEndBase + 1))
    guard let object = try? JSONSerialization.jsonObject(with: manifestData, options: []),
          let manifest = object as? [[String: Any]] else {
        return false
    }
    let names = manifest.compactMap { $0["name"] as? String }
    if mode == .preserve {
        return !names.isEmpty
    }
    if mode == .preserveWithoutPortrait {
        return !names.isEmpty && names.allSatisfy { !oppoCameraPortraitEditingEntryNames.contains($0) }
    }
    if mode == .preserveWithoutPrivateUHDR {
        return !names.isEmpty && names.allSatisfy { !oppoPrivateUHDRTailEntryNames.contains($0) }
    }
    if mode == .preserveWithoutPrivateHDR {
        return !names.isEmpty && names.allSatisfy { !isOppoPrivateHDRTailEntry($0) }
    }
    if mode == .preserveNoUHDR {
        return !names.isEmpty && names.allSatisfy { !oppoPrivateUHDRTailEntryNames.contains($0) }
    }
    if mode == .preserveNoHDR {
        return !names.isEmpty && names.allSatisfy { !shouldNeutralizeOppoCameraTailEntry($0, mode: mode) }
    }
    return !names.isEmpty && names.allSatisfy {
        shouldPreserveOppoCameraTailEntry($0, mode: mode) && !$0.hasPrefix("local.uhdr.")
    }
}

private func manifestVersion(_ value: Any?) -> Int {
    if let number = value as? NSNumber {
        return number.intValue
    }
    if let string = value as? String, let parsed = Int(string) {
        return parsed
    }
    return 1
}

private enum XDRemuxProductCore {
    private static let fileManager = FileManager.default

    static func convert(
        inputURL: URL,
        outputURL: URL,
        familyPreference: Family,
        debugRootURL: URL?,
        oppoCompatibility: OppoCompatibility = .off,
        inputProcessingBranch: InputProcessingBranch = .hybrid,
        oppoCameraTail: OppoCameraTail = .preserve,
        tmapFormat: TmapFormat = .imageIO
    ) throws -> SampleReport {
        guard fileManager.fileExists(atPath: inputURL.path) else {
            throw CLIError.inputNotFound(inputURL)
        }

        let parentURL = outputURL.deletingLastPathComponent()
        try ensureDirectory(parentURL, fileManager: fileManager)

        let sourceData: Data
        do {
            sourceData = try Data(contentsOf: inputURL, options: [.mappedIfSafe])
        } catch {
            throw CLIError.unableToRead(inputURL)
        }

        try rejectLossyGainMapPromotion(inputURL: inputURL, compatibility: oppoCompatibility)
        let productInput = try prepareProductInput(
            inputURL: inputURL,
            sourceData: sourceData,
            familyPreference: familyPreference
        )
        let debugDirURL = try writeDiagnosticsIfRequested(
            debugRootURL: debugRootURL,
            inputURL: inputURL,
            productInput: productInput
        )
        let actualOutputURL = temporaryOutputURLIfNeeded(inputURL: inputURL, outputURL: outputURL)
        let writesInPlace = actualOutputURL != outputURL
        defer {
            if writesInPlace {
                try? fileManager.removeItem(at: actualOutputURL)
            }
        }

        // Complete OPPO preservation requires the source-primary graft path. ImageIO's
        // direct writer and the experimental passthrough writer may normalize or omit
        // non-HDR HEIF items before the opaque camera tail is restored.
        let effectiveInputProcessingBranch: InputProcessingBranch = (
            oppoCameraTail == .preserve
                || oppoCameraTail == .preserveWithoutPortrait
                || oppoCameraTail == .preserveWithoutPrivateUHDR
                || oppoCameraTail == .preserveWithoutPrivateHDR
                || tmapFormat == .strict
        )
            ? .hybrid
            : inputProcessingBranch
        try ProductGainMapWriter.write(
            inputURL: inputURL,
            outputURL: actualOutputURL,
            sourceData: sourceData,
            productInput: productInput,
            oppoCompatibility: oppoCompatibility,
            inputProcessingBranch: effectiveInputProcessingBranch,
            strictISO21496: tmapFormat == .strict
        )
        try restoreOppoUserCommentFromSource(
            outputURL: actualOutputURL,
            sourceData: sourceData,
            compatibility: oppoCompatibility
        )
        try appendOppoCameraTailIfNeeded(
            outputURL: actualOutputURL,
            sourceData: sourceData,
            extracted: productInput.extracted,
            mode: oppoCameraTail
        )
        guard gainMapEncodingMatchesTarget(at: actualOutputURL, compatibility: oppoCompatibility) else {
            throw CLIError.invalidContainer("output Gain Map encoding does not match the selected compatibility target")
        }

        if writesInPlace {
            _ = try fileManager.replaceItemAt(outputURL, withItemAt: actualOutputURL)
        }

        return SampleReport(
            inputURL: inputURL,
            outputURL: outputURL,
            family: productInput.effectiveFamily,
            scale: productInput.scale,
            gainMapParams: productInput.params,
            debugDirURL: debugDirURL
        )
    }

    struct ProductInput {
        let extracted: ExtractedLHDR
        let detectedFamily: Family
        let effectiveFamily: Family
        let scale: ResolvedScale
        let maskRaster: GainMapRaster
        let gainMapRaster: GainMapRaster
        let params: GainMapParams
        let style: HDRToneMapStyle
    }

    private static func prepareProductInput(
        inputURL: URL,
        sourceData: Data,
        familyPreference: Family
    ) throws -> ProductInput {
        let extracted = try LHDRExtractor.extract(from: sourceData)
        let detectedFamily = detectFamily(from: extracted)
        let effectiveFamily = familyPreference == .auto ? detectedFamily : familyPreference
        let scale = try EDRScaleResolver.resolve(metaFloats: extracted.metaFloats, mode: extracted.mode)
        let decoderChannels = extracted.mode == .uhdr ? 3 : 1
        let maskRaster = try MaskDecoder.decodeMaskJPEG(
            extracted.maskJPEGData,
            sourceURL: inputURL,
            channelCount: decoderChannels
        )
        let gainMap = try buildProductGainMap(
            extracted: extracted,
            maskRaster: maskRaster,
            family: effectiveFamily,
            scale: scale
        )

        return ProductInput(
            extracted: extracted,
            detectedFamily: detectedFamily,
            effectiveFamily: effectiveFamily,
            scale: scale,
            maskRaster: maskRaster,
            gainMapRaster: gainMap.raster,
            params: gainMap.params,
            style: makeHDRToneMapStyle(from: scale)
        )
    }

    private static func detectFamily(from extracted: ExtractedLHDR) -> Family {
        if extracted.mode == .uhdr {
            return .x7
        }
        return extracted.metaFloats[0] >= 3.0 ? .x7 : .x6
    }

    private static func buildProductGainMap(
        extracted: ExtractedLHDR,
        maskRaster: GainMapRaster,
        family: Family,
        scale: ResolvedScale
    ) throws -> (raster: GainMapRaster, params: GainMapParams) {
        if extracted.mode == .uhdr {
            return (
                maskRaster,
                GainMapParams(
                    family: family,
                    knee: 0,
                    kneeRange: 1,
                    headroomScale: 0,
                    maxBoost: 0,
                    log2Scale: 0,
                    kneeSource: "uhdr_precomputed_skip_reconstruction"
                )
            )
        }
        return try GainMapReconstructor.reconstruct(
            mask: maskRaster,
            family: family,
            scale: scale,
            metaFloats: extracted.metaFloats
        )
    }

    private static func makeHDRToneMapStyle(from scale: ResolvedScale) -> HDRToneMapStyle {
        HDRToneMapStyle(
            version: 1,
            baseHeadroom: scale.baseHeadroom,
            alternateHeadroom: scale.alternateHeadroom,
            baseColorIsWorkingColor: false,
            gainMapMin: scale.gainMapMin,
            gainMapMax: scale.gainMapMax,
            gamma: scale.gamma,
            baseOffset: scale.epsilonSdr,
            alternateOffset: scale.epsilonHdr,
            channelCount: scale.channelCount,
            perChannelGainMapMin: scale.perChannelGainMapMin,
            perChannelGainMapMax: scale.perChannelGainMapMax,
            perChannelGamma: scale.perChannelGamma,
            perChannelBaseOffset: scale.perChannelBaseOffset,
            perChannelAlternateOffset: scale.perChannelAlternateOffset
        )
    }

    private static func writeDiagnosticsIfRequested(
        debugRootURL: URL?,
        inputURL: URL,
        productInput: ProductInput
    ) throws -> URL? {
        guard let debugRootURL else { return nil }
        let dir = debugRootURL.appendingPathComponent(inputURL.deletingPathExtension().lastPathComponent, isDirectory: true)
        try DebugWriter.writeArtifacts(
            extracted: productInput.extracted,
            inputURL: inputURL,
            debugDirURL: dir,
            familyDetected: productInput.detectedFamily,
            familyUsed: productInput.effectiveFamily,
            maskRaster: productInput.maskRaster,
            gainMapRaster: productInput.gainMapRaster,
            scale: productInput.scale,
            params: productInput.params,
            style: productInput.style
        )
        return dir
    }

    private static func temporaryOutputURLIfNeeded(inputURL: URL, outputURL: URL) -> URL {
        guard inputURL.standardizedFileURL.path == outputURL.standardizedFileURL.path else {
            return outputURL
        }
        return outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).xdremux-\(UUID().uuidString)")
    }
}

private enum ProductGainMapWriter {
    static func write(
        inputURL: URL,
        outputURL: URL,
        sourceData: Data,
        productInput: XDRemuxProductCore.ProductInput,
        oppoCompatibility: OppoCompatibility,
        inputProcessingBranch: InputProcessingBranch,
        strictISO21496: Bool
    ) throws {
        switch inputProcessingBranch {
        case .system, .systemDecoded:
            let writerInput = gainMapWriterInput(
                productInput: productInput,
                oppoCompatibility: oppoCompatibility
            )
            try ISOHDRWriter.write(
                baseImageURL: inputURL,
                gainMap: writerInput.gainMap,
                style: writerInput.style,
                outputURL: outputURL,
                oppoCompatibility: oppoCompatibility,
                inputProcessingBranch: inputProcessingBranch
            )
        case .hybrid:
            try HybridGainMapWriter.write(
                inputURL: inputURL,
                outputURL: outputURL,
                sourceData: sourceData,
                productInput: productInput,
                oppoCompatibility: oppoCompatibility,
                strictISO21496: strictISO21496
            )
        case .passthrough:
            try DirectPassthroughGainMapWriter.write(
                inputURL: inputURL,
                outputURL: outputURL,
                sourceData: sourceData,
                productInput: productInput,
                oppoCompatibility: oppoCompatibility
            )
        }
    }
}

private func gainMapWriterInput(
    productInput: XDRemuxProductCore.ProductInput,
    oppoCompatibility: OppoCompatibility
) -> (gainMap: GainMapRaster, style: HDRToneMapStyle) {
    guard productInput.extracted.mode == .lhdr, oppoCompatibility.wantsOppoCompat else {
        return (productInput.gainMapRaster, productInput.style)
    }
    return (
        productInput.gainMapRaster.replicatingLumaToRGB(),
        productInput.style.replicatingMonochromeToRGB()
    )
}

private enum HybridGainMapWriter {
    static func write(
        inputURL: URL,
        outputURL: URL,
        sourceData: Data,
        productInput: XDRemuxProductCore.ProductInput,
        oppoCompatibility: OppoCompatibility,
        strictISO21496: Bool
    ) throws {
        try writeImageIOPreservedGainMapPassthrough(
            inputURL: inputURL,
            outputURL: outputURL,
            sourceData: sourceData,
            productInput: productInput,
            oppoCompatibility: oppoCompatibility,
            temporaryLabel: "hybrid",
            strictISO21496: strictISO21496
        )
    }
}

private enum DirectPassthroughGainMapWriter {
    static func write(
        inputURL: URL,
        outputURL: URL,
        sourceData: Data,
        productInput: XDRemuxProductCore.ProductInput,
        oppoCompatibility: OppoCompatibility
    ) throws {
        if oppoCompatibility.wantsOppoCompat && productInput.extracted.mode != .uhdr {
            try writeImageIOPreservedGainMapPassthrough(
                inputURL: inputURL,
                outputURL: outputURL,
                sourceData: sourceData,
                productInput: productInput,
                oppoCompatibility: oppoCompatibility,
                temporaryLabel: "passthrough-oppo"
            )
            return
        }

        let patchedUserComment = adjustedOppoUserComment(in: sourceData, compatibility: oppoCompatibility)
        let tmapPayload: Data? = oppoCompatibility.wantsOppoCompat && productInput.extracted.mode == .uhdr
            ? makeImageIONativeTmapPayload(infoFloats: productInput.extracted.metaFloats)
            : nil
        let tmapColorBox: Data? = tmapPayload == nil ? nil : isoColrBT2020PQBox
        _ = try writePrivateJPEGPassthroughOutput(
            inputURL: inputURL,
            outputURL: outputURL,
            infoFloats: privateGainMapInfoFloats(for: productInput),
            gainMapJPEG: productInput.extracted.maskJPEGData,
            patchedUserComment: patchedUserComment,
            tmapPayload: tmapPayload,
            tmapColorBox: tmapColorBox
        )
        try verifyImageIOISOGainMap(outputURL)
    }

    private static func privateGainMapInfoFloats(for productInput: XDRemuxProductCore.ProductInput) -> [Double] {
        if productInput.extracted.mode == .uhdr {
            return productInput.extracted.metaFloats
        }
        return makePrivateGainMapInfoFloats(scale: productInput.scale)
    }
}

private func writeImageIOPreservedGainMapPassthrough(
    inputURL: URL,
    outputURL: URL,
    sourceData: Data,
    productInput: XDRemuxProductCore.ProductInput,
    oppoCompatibility: OppoCompatibility,
    temporaryLabel: String,
    strictISO21496: Bool = false
) throws {
    let parent = outputURL.deletingLastPathComponent()
    let stem = outputURL.deletingPathExtension().lastPathComponent
    let privateIntermediateURL = parent.appendingPathComponent(".\(stem).\(temporaryLabel)-private-\(UUID().uuidString).heic")
    let preservedURL = parent.appendingPathComponent(".\(stem).\(temporaryLabel)-preserve-\(UUID().uuidString).heic")
    defer {
        try? FileManager.default.removeItem(at: privateIntermediateURL)
        try? FileManager.default.removeItem(at: preservedURL)
    }

    let patchedUserComment = adjustedOppoUserComment(in: sourceData, compatibility: oppoCompatibility)
    switch productInput.extracted.mode {
    case .uhdr:
        if oppoCompatibility.wantsOppoCompat {
            try ISOHDRWriter.write(
                baseImageURL: inputURL,
                gainMap: productInput.gainMapRaster,
                style: productInput.style,
                outputURL: preservedURL,
                oppoCompatibility: oppoCompatibility,
                inputProcessingBranch: .system
            )
        } else if gainMapEncodingMatchesTarget(at: inputURL, compatibility: oppoCompatibility) {
            // The input already has the requested high-spec ISO Gain Map. Reusing
            // that graph avoids appending a second temporary JPEG/tmap graph,
            // which ImageIO rejects as ambiguous during preserve re-encoding.
            try FileManager.default.copyItem(at: inputURL, to: preservedURL)
        } else {
            _ = try writePrivateJPEGPassthroughOutput(
                inputURL: inputURL,
                outputURL: privateIntermediateURL,
                infoFloats: productInput.extracted.metaFloats,
                gainMapJPEG: productInput.extracted.maskJPEGData,
                patchedUserComment: patchedUserComment,
                tmapPayload: nil,
                tmapColorBox: nil
            )
            try ISOHDRWriter.writeWithPreserveReencode(
                intermediateURL: privateIntermediateURL,
                outputURL: preservedURL,
                patchedUserComment: patchedUserComment
            )
        }
    case .lhdr:
        let writerInput = gainMapWriterInput(
            productInput: productInput,
            oppoCompatibility: oppoCompatibility
        )
        let branch: InputProcessingBranch = oppoCompatibility.wantsOppoCompat ? .system : .hybrid
        try ISOHDRWriter.write(
            baseImageURL: inputURL,
            gainMap: writerInput.gainMap,
            style: writerInput.style,
            outputURL: preservedURL,
            oppoCompatibility: oppoCompatibility,
            inputProcessingBranch: branch
        )
    }

    try writeHybridPrimaryPassthrough(
        sourceURL: inputURL,
        preservedURL: preservedURL,
        outputURL: outputURL,
        patchedUserComment: patchedUserComment,
        preserveTmapColor: oppoCompatibility.wantsOppoCompat,
        strictISO21496Tmap: strictISO21496,
        fallbackXMPPayload: makeHdrgmXMP(infoFloats: productInput.extracted.metaFloats)
    )
}

struct LHDRToISOHDRCLI {
    private static let fileManager = FileManager.default
    private static let usage = """
    Usage:
             XDRemux.swift convert --input <file.heic> [--output <out.heic>] [--oppo-compatible|--apple-portrait] [--discard-portrait-data] [--debug-dir <dir>]
             XDRemux.swift batch --input-dir <dir> [--output-dir <dir>] [--glob *.heic] [--jobs <n>] [--oppo-compatible|--apple-portrait] [--discard-portrait-data] [--checkpoint <file>] [--resume|--no-resume] [--skip-existing|--no-skip-existing] [--debug-dir <dir>]

    Notes:
      - Product output always uses the metadata-preserving source-primary remux path.
      - With neither product switch, output is standard ISO HDR and preserves the complete metadata tail.
        Gain Maps retain their source channel structure and may use HEVC Range Extensions 4:4:4.
      - --oppo-compatible converts a high-spec Gain Map to OPPO-compatible Main Still Picture 4:2:0.
      - --no-oppo-compat is a legacy spelling for the default standard-ISO mode.
      - Existing 4:2:0 Gain Maps cannot be promoted to high-spec 4:4:4 because the discarded chroma is unrecoverable.
      - Source UserComment routing flags and, by default, the complete OPPO/QTI/FileExtendedContainer tail are preserved.
      - --discard-portrait-data removes large depth/re-edit resources while retaining watermark, master-mode, HDR, and small metadata.
      - Only the active Gain Map graph and its required container descriptions may change.
      - Batch defaults: --jobs min(cpu,4), --resume, --skip-existing.
      - A JSONL checkpoint is written under output-dir by default; it is deleted only when the batch finishes with zero failures.
      - --apple-portrait requires rear.depth + rear.depth.config + src.image. The UserComment
        portrait bit is the strong route; an explicit run can recover a missing bit with a warning.
        It maps OPPO portrait/pet/hair planes to Apple mattes, generates Focus, and restores
        first-assembly base/gain HEVC payloads without re-encoding them.
      - Batch --apple-portrait automatically filters non-portrait inputs instead of failing them.
      - Apple portrait and OPPO-compatible output are mutually exclusive product modes. Apple portrait
        output omits the redundant large OPPO portrait tail; without the switch, that tail stays intact.
      - If --output is omitted, the input file is overwritten in place.
      - If --output-dir is omitted, files are written to the input directory.
    """

    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let command = args.first else {
                throw CLIError.usage(usage)
            }

            switch command {
            case "convert":
                let cmd = try parseConvert(Array(args.dropFirst()))
                try runConvert(cmd)
            case "batch":
                let cmd = try parseBatch(Array(args.dropFirst()))
                try runBatch(cmd)
            case "-h", "--help", "help":
                print(usage)
            default:
                throw CLIError.invalidCommand(command)
            }
        } catch {
            if let cli = error as? CLIError {
                switch cli {
                case .usage(let message):
                    FileHandle.standardError.write(Data("\(message)\n".utf8))
                case .invalidCommand, .missingArgument, .unknownOption, .invalidValue:
                    FileHandle.standardError.write(Data("error: \(cli)\n\n\(usage)\n".utf8))
                default:
                    FileHandle.standardError.write(Data("error: \(cli)\n".utf8))
                }
            } else {
                FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            }
            exit(1)
        }
    }

    private static func runConvert(_ cmd: ConvertCommand) throws {
        if try PortraitConversionPipeline.convertIfNeeded(
            inputURL: cmd.inputURL,
            outputURL: cmd.outputURL,
            mode: cmd.portraitMode
        ) {
            print("converted OPPO portrait \(cmd.inputURL.lastPathComponent) -> \(cmd.outputURL.path)")
            return
        }
        let report = try XDRemuxProductCore.convert(
            inputURL: cmd.inputURL,
            outputURL: cmd.outputURL,
            familyPreference: cmd.family,
            debugRootURL: cmd.debugRootURL,
            oppoCompatibility: cmd.oppoCompatibility,
            inputProcessingBranch: cmd.inputProcessingBranch,
            oppoCameraTail: cmd.oppoCameraTail,
            tmapFormat: cmd.tmapFormat
        )
        print("converted \(report.inputURL.lastPathComponent) -> \(report.outputURL.path)")
    }

    private static func runBatch(_ cmd: BatchCommand) throws {
        try ensureDirectory(cmd.outputDirURL, fileManager: fileManager)
        let discovered = try enumerateInputs(root: cmd.inputDirURL, glob: cmd.glob)
        let matched: [URL]
        if cmd.portraitMode == .on {
            matched = discovered.filter { PortraitConversionPipeline.isConvertibleInput($0) }
            let skipped = discovered.count - matched.count
            if skipped > 0 {
                print("apple-portrait filter: selected \(matched.count), skipped \(skipped) non-portrait files")
            }
        } else {
            matched = discovered
        }
        guard !matched.isEmpty else {
            throw CLIError.noFilesMatched(cmd.inputDirURL, cmd.glob)
        }

        let jobs = max(1, cmd.jobs)
        let configHash = batchConfigHash(cmd)
        let checkpointURL = resolvedCheckpointURL(cmd: cmd, configHash: configHash)

        // Precompute outputs and fail fast on collisions.
        let workItems = matched.map { inputURL -> BatchWorkItem in
            let stem = inputURL.deletingPathExtension().lastPathComponent
            let outputURL = cmd.outputDirURL.appendingPathComponent("\(stem).heic")
            return BatchWorkItem(inputURL: inputURL, outputURL: outputURL)
        }
        try assertNoOutputCollisions(workItems)

        var checkpointState: [String: BatchCheckpointItem] = [:]
        if cmd.resume {
            checkpointState = try loadCheckpointStateIfPresent(url: checkpointURL, expectedConfigHash: configHash)
        } else {
            // Fresh run: truncate any existing checkpoint so future resumes are consistent.
            if fileManager.fileExists(atPath: checkpointURL.path) {
                do {
                    try fileManager.removeItem(at: checkpointURL)
                } catch {
                    // If removal fails, best-effort truncate.
                    if let handle = try? FileHandle(forWritingTo: checkpointURL) {
                        try? handle.truncate(atOffset: 0)
                        try? handle.close()
                    }
                }
            }
        }

        let checkpointWriter = try BatchCheckpointWriter(url: checkpointURL, fileManager: fileManager)
        defer {
            try? checkpointWriter.close()
        }
        try checkpointWriter.appendHeader(configHash: configHash, jobs: jobs)

        let logLock = NSLock()
        func log(_ message: String) {
            logLock.lock()
            defer { logLock.unlock() }
            print(message)
        }

        let statsLock = NSLock()
        var convertedCount = 0
        var skippedExistingCount = 0
        var failureCount = 0

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = jobs
        queue.qualityOfService = .userInitiated

        for item in workItems {
            queue.addOperation {
                autoreleasepool {
                    let inputKey = item.inputURL.standardizedFileURL.path
                    let outputKey = item.outputURL.standardizedFileURL.path
                    let signature = (try? fileSignature(for: item.inputURL, fileManager: fileManager))

                    func record(status: BatchCheckpointStatus, error: String? = nil) {
                        do {
                            try checkpointWriter.appendItem(
                                inputPath: inputKey,
                                outputPath: outputKey,
                                status: status,
                                inputSize: signature?.size,
                                inputMtimeNs: signature?.mtimeNs,
                                error: error
                            )
                        } catch {
                            // Checkpoint failure should be visible, but do not abort in-flight conversions.
                            log("checkpoint write failed: \(error)")
                        }
                    }

                    func isOutputValid() -> Bool {
                        guard fileManager.fileExists(atPath: item.outputURL.path) else { return false }
                        if cmd.portraitMode == .on {
                            return PortraitConversionPipeline.isValidOutput(item.outputURL)
                        }
                        return isValidOutput(
                            item.outputURL,
                            oppoCameraTail: cmd.oppoCameraTail,
                            oppoCompatibility: cmd.oppoCompatibility
                        )
                    }

                    // Resume: only treat checkpoint success/skipped as done. Failures always retry.
                    if cmd.resume, let prior = checkpointState[inputKey], prior.matchesSignature(signature) {
                        if (prior.status == .success || prior.status == .skippedExisting), prior.outputPath == outputKey {
                            if isOutputValid() {
                                statsLock.lock(); skippedExistingCount += 1; statsLock.unlock()
                                record(status: .skippedExisting)
                                log("skipped-existing \(item.inputURL.lastPathComponent)")
                                return
                            }
                        }

                        if prior.status == .failure {
                            // fallthrough: retry conversion even if an output exists.
                        }
                    }

                    // Skip-existing: filesystem-based fast path, unless resume explicitly says we must retry.
                    if cmd.skipExisting {
                        let prior = cmd.resume ? checkpointState[inputKey] : nil
                        let signatureMatchesCheckpoint = prior?.matchesSignature(signature) == true
                        let mustRetryFromCheckpoint = signatureMatchesCheckpoint && (prior?.status == .failure)
                        let inputChangedSinceCheckpoint = (prior != nil) && !signatureMatchesCheckpoint
                        if !mustRetryFromCheckpoint && !inputChangedSinceCheckpoint {
                            if isOutputValid() {
                                statsLock.lock(); skippedExistingCount += 1; statsLock.unlock()
                                record(status: .skippedExisting)
                                log("skipped-existing \(item.inputURL.lastPathComponent)")
                                return
                            }
                        }
                    }

                    // If we are going to write to a different output path and it exists, remove it to avoid ImageIO failures.
                    if item.outputURL.standardizedFileURL.path != item.inputURL.standardizedFileURL.path,
                       fileManager.fileExists(atPath: item.outputURL.path) {
                        try? fileManager.removeItem(at: item.outputURL)
                    }

                    do {
                        if cmd.portraitMode == .on {
                            guard try PortraitConversionPipeline.convertIfNeeded(
                                inputURL: item.inputURL,
                                outputURL: item.outputURL,
                                mode: .on
                            ) else {
                                throw CLIError.invalidContainer(
                                    "input stopped matching the OPPO portrait requirements"
                                )
                            }
                        } else {
                            _ = try XDRemuxProductCore.convert(
                                inputURL: item.inputURL,
                                outputURL: item.outputURL,
                                familyPreference: cmd.family,
                                debugRootURL: cmd.debugRootURL,
                                oppoCompatibility: cmd.oppoCompatibility,
                                inputProcessingBranch: cmd.inputProcessingBranch,
                                oppoCameraTail: cmd.oppoCameraTail,
                                tmapFormat: cmd.tmapFormat
                            )
                        }
                        statsLock.lock(); convertedCount += 1; statsLock.unlock()
                        record(status: .success)
                        log("converted \(item.inputURL.lastPathComponent)")
                    } catch {
                        statsLock.lock(); failureCount += 1; statsLock.unlock()
                        record(status: .failure, error: String(describing: error))
                        log("failed \(item.inputURL.lastPathComponent): \(error)")
                    }
                }
            }
        }

        queue.waitUntilAllOperationsAreFinished()
        try checkpointWriter.close()

        log("batch complete: converted \(convertedCount) files, skipped-existing \(skippedExistingCount) files, failed \(failureCount) files into \(cmd.outputDirURL.path)")
        if failureCount == 0 {
            try? fileManager.removeItem(at: checkpointURL)
        } else {
            log("checkpoint kept (failures present): \(checkpointURL.path)")
            throw CLIError.batchFailed(failures: failureCount, checkpoint: checkpointURL)
        }
    }

    private struct BatchWorkItem {
        let inputURL: URL
        let outputURL: URL
    }

    private enum BatchCheckpointStatus: String {
        case success = "success"
        case failure = "failure"
        case skippedExisting = "skipped_existing"
    }

    private struct BatchCheckpointItem {
        let inputPath: String
        let outputPath: String
        let status: BatchCheckpointStatus
        let inputSize: Int64?
        let inputMtimeNs: Int64?

        func matchesSignature(_ signature: FileSignature?) -> Bool {
            guard let signature else { return true }
            if let inputSize, inputSize != signature.size { return false }
            if let inputMtimeNs, inputMtimeNs != signature.mtimeNs { return false }
            return true
        }

        func isDone(for expectedOutputPath: String, signature: FileSignature?) -> Bool {
            guard status == .success || status == .skippedExisting else { return false }
            guard outputPath == expectedOutputPath else { return false }
            return matchesSignature(signature)
        }
    }

    private struct FileSignature {
        let size: Int64
        let mtimeNs: Int64
    }

    private static func fileSignature(for url: URL, fileManager: FileManager) throws -> FileSignature {
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        let sizeValue = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let mtimeNs = Int64(mtime * 1_000_000_000)
        return FileSignature(size: sizeValue, mtimeNs: mtimeNs)
    }

    private final class BatchCheckpointWriter {
        private let url: URL
        private let queue = DispatchQueue(label: "xdremux.checkpoint")
        private var fileHandle: FileHandle?
        private var isClosed = false

        init(url: URL, fileManager: FileManager) throws {
            self.url = url
            let parent = url.deletingLastPathComponent()
            try ensureDirectory(parent, fileManager: fileManager)
            if !fileManager.fileExists(atPath: url.path) {
                let ok = fileManager.createFile(atPath: url.path, contents: nil)
                guard ok else { throw CLIError.unableToWriteCheckpoint(url) }
            }
            do {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                self.fileHandle = handle
            } catch {
                throw CLIError.unableToWriteCheckpoint(url)
            }
        }

        func appendHeader(configHash: String, jobs: Int) throws {
            let record: [String: Any] = [
                "kind": "header",
                "schema": 1,
                "configHash": configHash,
                "jobs": jobs,
                "startedAtMs": Int64(Date().timeIntervalSince1970 * 1000)
            ]
            try appendJSONLine(record)
        }

        func appendItem(
            inputPath: String,
            outputPath: String,
            status: BatchCheckpointStatus,
            inputSize: Int64?,
            inputMtimeNs: Int64?,
            error: String?
        ) throws {
            var record: [String: Any] = [
                "kind": "item",
                "schema": 1,
                "inputPath": inputPath,
                "outputPath": outputPath,
                "status": status.rawValue,
                "finishedAtMs": Int64(Date().timeIntervalSince1970 * 1000)
            ]
            if let inputSize { record["inputSize"] = inputSize }
            if let inputMtimeNs { record["inputMtimeNs"] = inputMtimeNs }
            if let error { record["error"] = error }
            try appendJSONLine(record)
        }

        func close() throws {
            var thrown: Error?
            queue.sync {
                if isClosed { return }
                isClosed = true
                do {
                    try fileHandle?.close()
                } catch {
                    thrown = error
                }
                fileHandle = nil
            }
            if let thrown {
                throw thrown
            }
        }

        private func appendJSONLine(_ record: [String: Any]) throws {
            let data: Data
            do {
                data = try JSONSerialization.data(withJSONObject: record, options: [])
            } catch {
                throw CLIError.unableToWriteCheckpoint(url)
            }
            var line = data
            line.append(UInt8(ascii: "\n"))

            var thrown: Error?
            queue.sync {
                guard !isClosed, let fileHandle else {
                    thrown = CLIError.unableToWriteCheckpoint(url)
                    return
                }
                do {
                    try fileHandle.write(contentsOf: line)
                    try? fileHandle.synchronize()
                } catch {
                    thrown = CLIError.unableToWriteCheckpoint(url)
                }
            }
            if let thrown {
                throw thrown
            }
        }
    }

    private static func loadCheckpointStateIfPresent(url: URL, expectedConfigHash: String) throws -> [String: BatchCheckpointItem] {
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw CLIError.unableToReadCheckpoint(url)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CLIError.unableToReadCheckpoint(url)
        }

        var items: [String: BatchCheckpointItem] = [:]
        var sawHeader = false

        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            guard let lineData = line.data(using: .utf8) else { continue }

            let obj: Any
            do {
                obj = try JSONSerialization.jsonObject(with: lineData, options: [])
            } catch {
                // Tolerate a partially-written trailing line after interruption.
                continue
            }
            guard let dict = obj as? [String: Any] else {
                continue
            }
            let kind = dict["kind"] as? String
            if kind == "header" {
                sawHeader = true
                let actual = dict["configHash"] as? String ?? "missing"
                if actual != expectedConfigHash {
                    throw CLIError.checkpointConfigMismatch(url, expected: expectedConfigHash, actual: actual)
                }
                continue
            }
            guard kind == "item" else { continue }

            let inputPath = dict["inputPath"] as? String ?? ""
            if inputPath.isEmpty { continue }
            let outputPath = dict["outputPath"] as? String ?? ""
            let statusRaw = dict["status"] as? String ?? ""
            let status = BatchCheckpointStatus(rawValue: statusRaw) ?? .failure

            let inputSize = (dict["inputSize"] as? NSNumber)?.int64Value
            let inputMtimeNs = (dict["inputMtimeNs"] as? NSNumber)?.int64Value
            items[inputPath] = BatchCheckpointItem(
                inputPath: inputPath,
                outputPath: outputPath,
                status: status,
                inputSize: inputSize,
                inputMtimeNs: inputMtimeNs
            )
        }

        guard sawHeader else {
            throw CLIError.invalidCheckpoint(url, "missing header")
        }
        return items
    }

    private static func batchConfigHash(_ cmd: BatchCommand) -> String {
        let entries: [(String, String)] = [
            ("family", cmd.family.rawValue),
            ("inputDir", cmd.inputDirURL.standardizedFileURL.path),
            ("inputProcessing", cmd.inputProcessingBranch.rawValue),
            ("oppoCameraTail", cmd.oppoCameraTail.rawValue),
            ("oppoCompat", cmd.oppoCompatibility.rawValue),
            ("portraitMode", cmd.portraitMode.rawValue),
            ("tmapFormat", cmd.tmapFormat.rawValue),
            ("outputDir", cmd.outputDirURL.standardizedFileURL.path)
        ]
        let stable = entries.sorted(by: { $0.0 < $1.0 }).map { "\($0.0)=\($0.1)" }.joined(separator: "\n")
        return sha256Hex(Data(stable.utf8))
    }

    private static func resolvedCheckpointURL(cmd: BatchCommand, configHash: String) -> URL {
        if let checkpointURL = cmd.checkpointURL {
            return checkpointURL
        }
        let short = String(configHash.prefix(16))
        return cmd.outputDirURL.appendingPathComponent(".xdremux-batch.\(short).jsonl")
    }

    private static func assertNoOutputCollisions(_ items: [BatchWorkItem]) throws {
        var seen: [String: URL] = [:]
        for item in items {
            let key = item.outputURL.standardizedFileURL.path
            if let prior = seen[key] {
                throw CLIError.outputPathCollision(output: item.outputURL, firstInput: prior, secondInput: item.inputURL)
            }
            seen[key] = item.inputURL
        }
    }

    private static func parseConvert(_ rawArgs: [String]) throws -> ConvertCommand {
        var inputPath: String?
        var outputPath: String?
        var family = Family.auto
        var debugDirPath: String?
        var oppoCompatibility: OppoCompatibility = .off
        var inputProcessingBranch = InputProcessingBranch.hybrid
        var applePortraitEnabled = false
        var oppoCompatibilityWasExplicit = false
        var oppoCameraTail = OppoCameraTail.preserve
        var tmapFormat = TmapFormat.imageIO

        var index = 0
        while index < rawArgs.count {
            let option = rawArgs[index]
            index += 1

            func nextValue(for option: String) throws -> String {
                guard index < rawArgs.count else {
                    throw CLIError.missingArgument(option)
                }
                defer { index += 1 }
                return rawArgs[index]
            }

            switch option {
            case "--apple-portrait":
                applePortraitEnabled = true
            case "--input":
                inputPath = try nextValue(for: option)
            case "--output":
                outputPath = try nextValue(for: option)
            case "--family":
                let value = try nextValue(for: option)
                guard let parsed = Family(rawValue: value) else {
                    throw CLIError.invalidValue(option: option, value: value)
                }
                family = parsed
            case "--input-processing":
                let value = try nextValue(for: option)
                guard let parsed = InputProcessingBranch(rawValue: value) else {
                    throw CLIError.invalidValue(option: option, value: value)
                }
                inputProcessingBranch = parsed
            case "--debug-dir":
                debugDirPath = try nextValue(for: option)
            case "--oppo-camera-tail":
                let value = try nextValue(for: option)
                guard let parsed = OppoCameraTail(rawValue: value) else {
                    throw CLIError.invalidValue(option: option, value: value)
                }
                oppoCameraTail = parsed
            case "--tmap-format":
                let value = try nextValue(for: option)
                guard let parsed = TmapFormat(rawValue: value) else {
                    throw CLIError.invalidValue(option: option, value: value)
                }
                tmapFormat = parsed
            case "--oppo-compat":
                // Bare --oppo-compat means "on"; --oppo-compat auto|on|tail|off for explicit mode.
                if index < rawArgs.count, let parsed = OppoCompatibility(rawValue: rawArgs[index]) {
                    oppoCompatibility = parsed
                    index += 1
                } else {
                    oppoCompatibility = .on
                }
                oppoCompatibilityWasExplicit = true
            case "--no-oppo-compat":
                oppoCompatibility = .off
                oppoCompatibilityWasExplicit = true
            case "--oppo-compatible":
                oppoCompatibility = .auto
                oppoCompatibilityWasExplicit = true
            case "--discard-portrait-data":
                oppoCameraTail = .preserveWithoutPortrait
            default:
                throw CLIError.unknownOption(option)
            }
        }

        guard let inputPath else { throw CLIError.missingArgument("--input") }

        if applePortraitEnabled, oppoCompatibilityWasExplicit, oppoCompatibility.wantsOppoCompat {
            throw CLIError.invalidValue(
                option: "--apple-portrait",
                value: "cannot be combined with OPPO-compatible output"
            )
        }
        if applePortraitEnabled {
            oppoCompatibility = .off
            oppoCameraTail = .preserveWithoutPortrait
        }

        return ConvertCommand(
            inputURL: URL(fileURLWithPath: inputPath),
            outputURL: URL(fileURLWithPath: outputPath ?? inputPath),
            family: family,
            debugRootURL: debugDirPath.map { URL(fileURLWithPath: $0) },
            oppoCompatibility: oppoCompatibility,
            inputProcessingBranch: inputProcessingBranch,
            portraitMode: applePortraitEnabled ? .on : .off,
            oppoCameraTail: oppoCameraTail,
            tmapFormat: tmapFormat
        )
    }

    private static func parseBatch(_ rawArgs: [String]) throws -> BatchCommand {
        var inputDirPath: String?
        var outputDirPath: String?
        var family = Family.auto
        var glob = "*.heic"
        var debugDirPath: String?
        var oppoCompatibility: OppoCompatibility = .off
        var inputProcessingBranch = InputProcessingBranch.hybrid
        var applePortraitEnabled = false
        var oppoCompatibilityWasExplicit = false
        var oppoCameraTail = OppoCameraTail.preserve
        var tmapFormat = TmapFormat.imageIO
        var jobs = min(ProcessInfo.processInfo.activeProcessorCount, 4)
        var checkpointPath: String?
        var resume = true
        var skipExisting = true

        var index = 0
        while index < rawArgs.count {
            let option = rawArgs[index]
            index += 1

            func nextValue(for option: String) throws -> String {
                guard index < rawArgs.count else {
                    throw CLIError.missingArgument(option)
                }
                defer { index += 1 }
                return rawArgs[index]
            }

            switch option {
            case "--apple-portrait":
                applePortraitEnabled = true
            case "--input-dir":
                inputDirPath = try nextValue(for: option)
            case "--output-dir":
                outputDirPath = try nextValue(for: option)
            case "--family":
                let value = try nextValue(for: option)
                guard let parsed = Family(rawValue: value) else {
                    throw CLIError.invalidValue(option: option, value: value)
                }
                family = parsed
            case "--input-processing":
                let value = try nextValue(for: option)
                guard let parsed = InputProcessingBranch(rawValue: value) else {
                    throw CLIError.invalidValue(option: option, value: value)
                }
                inputProcessingBranch = parsed
            case "--glob":
                glob = try nextValue(for: option)
            case "--jobs":
                let value = try nextValue(for: option)
                guard let parsed = Int(value), parsed > 0 else {
                    throw CLIError.invalidValue(option: option, value: value)
                }
                jobs = parsed
            case "--checkpoint":
                checkpointPath = try nextValue(for: option)
            case "--resume":
                resume = true
            case "--no-resume":
                resume = false
            case "--skip-existing":
                skipExisting = true
            case "--no-skip-existing":
                skipExisting = false
            case "--debug-dir":
                debugDirPath = try nextValue(for: option)
            case "--oppo-camera-tail":
                let value = try nextValue(for: option)
                guard let parsed = OppoCameraTail(rawValue: value) else {
                    throw CLIError.invalidValue(option: option, value: value)
                }
                oppoCameraTail = parsed
            case "--tmap-format":
                let value = try nextValue(for: option)
                guard let parsed = TmapFormat(rawValue: value) else {
                    throw CLIError.invalidValue(option: option, value: value)
                }
                tmapFormat = parsed
            case "--oppo-compat":
                if index < rawArgs.count, let parsed = OppoCompatibility(rawValue: rawArgs[index]) {
                    oppoCompatibility = parsed
                    index += 1
                } else {
                    oppoCompatibility = .on
                }
                oppoCompatibilityWasExplicit = true
            case "--no-oppo-compat":
                oppoCompatibility = .off
                oppoCompatibilityWasExplicit = true
            case "--oppo-compatible":
                oppoCompatibility = .auto
                oppoCompatibilityWasExplicit = true
            case "--discard-portrait-data":
                oppoCameraTail = .preserveWithoutPortrait
            default:
                throw CLIError.unknownOption(option)
            }
        }

        guard let inputDirPath else { throw CLIError.missingArgument("--input-dir") }

        if applePortraitEnabled, oppoCompatibilityWasExplicit, oppoCompatibility.wantsOppoCompat {
            throw CLIError.invalidValue(
                option: "--apple-portrait",
                value: "cannot be combined with OPPO-compatible output"
            )
        }
        if applePortraitEnabled {
            oppoCompatibility = .off
            oppoCameraTail = .preserveWithoutPortrait
        }

        return BatchCommand(
            inputDirURL: URL(fileURLWithPath: inputDirPath),
            outputDirURL: URL(fileURLWithPath: outputDirPath ?? inputDirPath),
            family: family,
            glob: glob,
            debugRootURL: debugDirPath.map { URL(fileURLWithPath: $0) },
            oppoCompatibility: oppoCompatibility,
            inputProcessingBranch: inputProcessingBranch,
            portraitMode: applePortraitEnabled ? .on : .off,
            oppoCameraTail: oppoCameraTail,
            tmapFormat: tmapFormat,
            jobs: jobs,
            checkpointURL: checkpointPath.map { URL(fileURLWithPath: $0) },
            resume: resume,
            skipExisting: skipExisting
        )
    }

    private static func enumerateInputs(root: URL, glob: String) throws -> [URL] {
        guard fileManager.fileExists(atPath: root.path) else {
            throw CLIError.inputNotFound(root)
        }

        let regex = try globToRegex(glob)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CLIError.inputNotFound(root)
        }

        var matched: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }

            let relative = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            let filename = fileURL.lastPathComponent
            if regex.firstMatch(in: relative, options: [], range: NSRange(relative.startIndex..., in: relative)) != nil ||
                regex.firstMatch(in: filename, options: [], range: NSRange(filename.startIndex..., in: filename)) != nil {
                matched.append(fileURL)
            }
        }
        return matched.sorted { $0.path < $1.path }
    }

    private static func globToRegex(_ glob: String) throws -> NSRegularExpression {
        var pattern = "^"
        for scalar in glob.unicodeScalars {
            switch scalar {
            case "*":
                pattern += ".*"
            case "?":
                pattern += "."
            case ".", "(", ")", "[", "]", "{", "}", "+", "^", "$", "|", "\\":
                pattern += "\\\(scalar)"
            default:
                pattern.append(Character(scalar))
            }
        }
        pattern += "$"
        return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}

private let oppoUltraHDRFlag = 0x20000000
private let isoUltraHDRFlag = 0x00200000
private let localHDRFlag = 0x00040000
private let oppoTagFlagPrefixes = [
    "ASCIIOplus_",
    "ASCIIoppo_",
    "Oplus_",
    "oplus_",
    "oppo_"
]

private func targetOppoTagFlags(_ sourceFlags: Int, compatibility: OppoCompatibility) -> Int {
    switch compatibility {
    case .auto, .off:
        return sourceFlags
    case .on, .tail:
        return sourceFlags | oppoUltraHDRFlag
    case .iso:
        return (sourceFlags & ~oppoUltraHDRFlag) | isoUltraHDRFlag
    case .isoNoLocal:
        return (sourceFlags & ~oppoUltraHDRFlag & ~localHDRFlag) | isoUltraHDRFlag
    case .isoGraph:
        return sourceFlags & ~oppoUltraHDRFlag & ~isoUltraHDRFlag
    }
}

/// Extract OPPO tagflags and adjust only explicit HDR routing bits.
private func adjustedOppoUserComment(in data: Data, compatibility: OppoCompatibility) -> String? {
    if let userComment = oppoUserComment(in: data),
       let source = oppoTagFlags(from: userComment) {
        let adjustedFlags = targetOppoTagFlags(source.flags, compatibility: compatibility)
        guard adjustedFlags != source.flags else { return nil }
        let digits = String(adjustedFlags)
        return source.prefix
            + String(repeating: "0", count: max(0, source.digitCount - digits.count))
            + digits
    }

    // Fallback for malformed vendor Exif that ImageIO cannot type as a string.
    for prefix in oppoTagFlagPrefixes {
        let prefixData = Data(prefix.utf8)
        var searchRange: Range<Data.Index>? = data.startIndex..<data.endIndex
        while let range = data.range(of: prefixData, options: [], in: searchRange) {
            var digitEnd = range.upperBound
            while digitEnd < data.count, (48...57).contains(data[digitEnd]) {
                digitEnd += 1
            }
            if digitEnd > range.upperBound,
               let flagStr = String(data: data.subdata(in: range.upperBound..<digitEnd), encoding: .utf8),
               let flags = Int(flagStr) {
                let adjustedFlags = targetOppoTagFlags(flags, compatibility: compatibility)
                guard adjustedFlags != flags else { return nil }
                let digits = String(adjustedFlags)
                return prefix
                    + String(repeating: "0", count: max(0, digitEnd - range.upperBound - digits.count))
                    + digits
            }
            searchRange = range.upperBound..<data.endIndex
        }
    }
    return nil
}

private func restoreOppoUserCommentFromSource(
    outputURL: URL,
    sourceData: Data,
    compatibility: OppoCompatibility
) throws {
    guard let sourceUserComment = oppoUserComment(in: sourceData),
          let sourceTagFlags = oppoTagFlags(from: sourceUserComment) else {
        return
    }

    let targetFlags = targetOppoTagFlags(sourceTagFlags.flags, compatibility: compatibility)

    var data = try Data(contentsOf: outputURL)
    guard let outputUserComment = oppoUserComment(in: data),
          let outputTagFlags = oppoTagFlags(from: outputUserComment) else {
        return
    }

    guard outputTagFlags.flags != targetFlags else { return }

    let originalBytes = Data(outputUserComment.utf8)
    let targetDigits = String(targetFlags)
    guard targetDigits.count <= outputTagFlags.digitCount else {
        throw CLIError.invalidContainer("unable to preserve source OPPO UserComment without resizing")
    }
    let patchedUserComment = outputTagFlags.prefix
        + String(repeating: "0", count: outputTagFlags.digitCount - targetDigits.count)
        + targetDigits
    let patchedBytes = Data(patchedUserComment.utf8)
    guard originalBytes.count == patchedBytes.count,
          let range = data.range(of: originalBytes) else {
        throw CLIError.invalidContainer("unable to patch OPPO UserComment")
    }

    data.replaceSubrange(range, with: patchedBytes)
    try data.write(to: outputURL, options: [.atomic])
}

private func oppoUserComment(in data: Data) -> String? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
          let value = exif[kCGImagePropertyExifUserComment] else {
        return nil
    }
    return value as? String
}

private func oppoTagFlags(from userComment: String) -> (prefix: String, digitCount: Int, flags: Int)? {
    for prefix in oppoTagFlagPrefixes {
        guard userComment.hasPrefix(prefix) else { continue }
        let digits = String(userComment.dropFirst(prefix.count).prefix { $0.isNumber })
        guard !digits.isEmpty, let flags = Int(digits) else { return nil }
        return (prefix, digits.count, flags)
    }
    return nil
}

private struct OppoUserCommentPatch {
    let sourceRange: Range<Int>
    let delta: Int
}

private func applyOppoUserCommentPatch(
    _ mdatPayload: inout Data,
    mdatDataStart: Int,
    exifEntry: ISOBMFFILocEntry,
    patchedUserComment: String
) -> OppoUserCommentPatch? {
    guard exifEntry.constructionMethod == 0,
          exifEntry.extents.count == 1,
          let extent = exifEntry.extents.first else { return nil }
    let localStart = extent.offset - mdatDataStart
    let localEnd = localStart + extent.length
    guard localStart >= 0, localEnd <= mdatPayload.count else { return nil }
    var exifPayload = mdatPayload.subdata(in: localStart..<localEnd)

    guard exifPayload.count >= 12 else { return nil }
    let tiffStart = 4 + readUInt32BEUnchecked(exifPayload, at: 0)
    guard tiffStart >= 4, tiffStart + 8 <= exifPayload.count else { return nil }
    let isLittleEndian: Bool
    if exifPayload[tiffStart] == UInt8(ascii: "I"), exifPayload[tiffStart + 1] == UInt8(ascii: "I") {
        isLittleEndian = true
    } else if exifPayload[tiffStart] == UInt8(ascii: "M"), exifPayload[tiffStart + 1] == UInt8(ascii: "M") {
        isLittleEndian = false
    } else {
        return nil
    }

    func read16(_ offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= exifPayload.count else { return nil }
        if isLittleEndian {
            return Int(exifPayload[offset]) | (Int(exifPayload[offset + 1]) << 8)
        }
        return (Int(exifPayload[offset]) << 8) | Int(exifPayload[offset + 1])
    }
    func read32(_ offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= exifPayload.count else { return nil }
        if isLittleEndian {
            return Int(exifPayload[offset])
                | (Int(exifPayload[offset + 1]) << 8)
                | (Int(exifPayload[offset + 2]) << 16)
                | (Int(exifPayload[offset + 3]) << 24)
        }
        return (Int(exifPayload[offset]) << 24)
            | (Int(exifPayload[offset + 1]) << 16)
            | (Int(exifPayload[offset + 2]) << 8)
            | Int(exifPayload[offset + 3])
    }
    func write32(_ value: Int, at offset: Int) -> Bool {
        guard value >= 0, value <= Int(UInt32.max), offset >= 0, offset + 4 <= exifPayload.count else { return false }
        if isLittleEndian {
            exifPayload[offset] = UInt8(value & 0xff)
            exifPayload[offset + 1] = UInt8((value >> 8) & 0xff)
            exifPayload[offset + 2] = UInt8((value >> 16) & 0xff)
            exifPayload[offset + 3] = UInt8((value >> 24) & 0xff)
        } else {
            exifPayload[offset] = UInt8((value >> 24) & 0xff)
            exifPayload[offset + 1] = UInt8((value >> 16) & 0xff)
            exifPayload[offset + 2] = UInt8((value >> 8) & 0xff)
            exifPayload[offset + 3] = UInt8(value & 0xff)
        }
        return true
    }

    guard read16(tiffStart + 2) == 42,
          let firstIFDOffset = read32(tiffStart + 4) else { return nil }
    var pendingIFDs = [firstIFDOffset]
    var visitedIFDs = Set<Int>()
    var userCommentEntryOffset: Int?
    while let relativeIFD = pendingIFDs.popLast(), userCommentEntryOffset == nil {
        guard visitedIFDs.insert(relativeIFD).inserted else { continue }
        let ifd = tiffStart + relativeIFD
        guard let count = read16(ifd), count <= 4096 else { return nil }
        for index in 0..<count {
            let entry = ifd + 2 + index * 12
            guard let tag = read16(entry), entry + 12 <= exifPayload.count else { return nil }
            if tag == 0x9286 {
                userCommentEntryOffset = entry
                break
            }
            if tag == 0x8769 || tag == 0x8825,
               let childOffset = read32(entry + 8) {
                pendingIFDs.append(childOffset)
            }
        }
    }

    guard let entry = userCommentEntryOffset,
          let fieldType = read16(entry + 2), fieldType == 7,
          let oldCount = read32(entry + 4), oldCount > 0,
          let oldValueOffset = read32(entry + 8) else { return nil }
    let oldValueStart = oldCount <= 4 ? entry + 8 : tiffStart + oldValueOffset
    let oldValueEnd = oldValueStart + oldCount
    guard oldValueStart >= 0, oldValueEnd <= exifPayload.count else { return nil }
    var newValue = exifPayload.subdata(in: oldValueStart..<oldValueEnd)

    var sourceCommentRange: Range<Int>?
    for prefix in oppoTagFlagPrefixes {
        let prefixData = Data(prefix.utf8)
        guard let range = newValue.range(of: prefixData) else { continue }
        var digitEnd = range.upperBound
        while digitEnd < newValue.count, (48...57).contains(newValue[digitEnd]) {
            digitEnd += 1
        }
        guard digitEnd > range.upperBound else { continue }
        sourceCommentRange = range.lowerBound..<digitEnd
        break
    }
    guard let sourceCommentRange else { return nil }
    newValue.replaceSubrange(sourceCommentRange, with: Data(patchedUserComment.utf8))

    while exifPayload.count % 4 != 0 { exifPayload.append(0) }
    let newValueOffset = exifPayload.count - tiffStart
    exifPayload.append(newValue)
    guard write32(newValue.count, at: entry + 4),
          write32(newValueOffset, at: entry + 8) else { return nil }

    mdatPayload.replaceSubrange(localStart..<localEnd, with: exifPayload)
    return OppoUserCommentPatch(
        sourceRange: extent.offset..<(extent.offset + extent.length),
        delta: exifPayload.count - extent.length
    )
}

private func adjustedExtentForOppoUserCommentPatch(
    _ extent: (offset: Int, length: Int),
    patch: OppoUserCommentPatch?
) -> (offset: Int, length: Int)? {
    guard let patch, patch.delta != 0 else { return extent }
    let extentRange = extent.offset..<extent.offset + extent.length
    if extentRange.upperBound <= patch.sourceRange.lowerBound {
        return extent
    }
    if extentRange.lowerBound >= patch.sourceRange.upperBound {
        return (extent.offset + patch.delta, extent.length)
    }
    guard extentRange.lowerBound <= patch.sourceRange.lowerBound,
          extentRange.upperBound >= patch.sourceRange.upperBound else {
        return nil
    }
    return (extent.offset, extent.length + patch.delta)
}

private func valueOrRepeated(_ values: [Double], index: Int, fallback: Double) -> Double {
    guard !values.isEmpty else { return fallback }
    return index < values.count ? values[index] : values[0]
}

private func positiveValueOrFallback(_ values: [Double], index: Int, fallback: Double) -> Double {
    let value = valueOrRepeated(values, index: index, fallback: fallback)
    guard value.isFinite, value > 0 else { return fallback }
    return value
}

private let isoAuxCBox = Data([
    0x00, 0x00, 0x00, 0x28, 0x61, 0x75, 0x78, 0x43,
    0x00, 0x00, 0x00, 0x00, 0x75, 0x72, 0x6e, 0x3a,
    0x69, 0x73, 0x6f, 0x3a, 0x73, 0x74, 0x64, 0x3a,
    0x69, 0x73, 0x6f, 0x3a, 0x74, 0x73, 0x3a, 0x32,
    0x31, 0x34, 0x39, 0x36, 0x3a, 0x2d, 0x31, 0x00,
])
private let isoDinfBox = Data([
    0x00, 0x00, 0x00, 0x24, 0x64, 0x69, 0x6e, 0x66,
    0x00, 0x00, 0x00, 0x1c, 0x64, 0x72, 0x65, 0x66,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    0x00, 0x00, 0x00, 0x0c, 0x75, 0x72, 0x6c, 0x20,
    0x00, 0x00, 0x00, 0x01,
])
private let isoIrotBox = Data([0x00, 0x00, 0x00, 0x09, 0x69, 0x72, 0x6f, 0x74, 0x00])
private let isoColrSRGBBox = Data([
    0x00, 0x00, 0x00, 0x13, 0x63, 0x6f, 0x6c, 0x72,
    0x6e, 0x63, 0x6c, 0x78, 0x00, 0x02, 0x00, 0x02,
    0x00, 0x02, 0x80,
])
private let isoColrBT2020PQBox = Data([
    0x00, 0x00, 0x00, 0x13, 0x63, 0x6f, 0x6c, 0x72,
    0x6e, 0x63, 0x6c, 0x78, 0x00, 0x09, 0x00, 0x10,
    0x00, 0x09, 0x80,
])
private let isoPixiRGB8Box = Data([
    0x00, 0x00, 0x00, 0x10, 0x70, 0x69, 0x78, 0x69,
    0x00, 0x00, 0x00, 0x00, 0x03, 0x08, 0x08, 0x08,
])
private let isoPixiRGB10Box = Data([
    0x00, 0x00, 0x00, 0x10, 0x70, 0x69, 0x78, 0x69,
    0x00, 0x00, 0x00, 0x00, 0x03, 0x0a, 0x0a, 0x0a,
])

private func readUInt16BEUnchecked(_ data: Data, at offset: Int) -> Int {
    (Int(data[offset]) << 8) | Int(data[offset + 1])
}

private func readUInt32BEUnchecked(_ data: Data, at offset: Int) -> Int {
    (Int(data[offset]) << 24)
        | (Int(data[offset + 1]) << 16)
        | (Int(data[offset + 2]) << 8)
        | Int(data[offset + 3])
}

private func appendUInt16BE(_ value: Int, to data: inout Data) {
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

private func appendUInt32BE(_ value: Int, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

private func appendUInt32LE(_ value: Int, to data: inout Data) {
    var little = UInt32(value).littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
}

private func appendInt32BE(_ value: Int32, to data: inout Data) {
    appendUInt32BE(Int(UInt32(bitPattern: value)), to: &data)
}

private func makeBox(_ type: String, payload: Data) -> Data {
    var out = Data()
    appendUInt32BE(payload.count + 8, to: &out)
    out.append(type.data(using: .ascii)!)
    out.append(payload)
    return out
}

private func isobmffBoxes(in data: Data, start: Int, end: Int) -> [ISOBMFFBox] {
    var result: [ISOBMFFBox] = []
    var pos = start
    while pos + 8 <= end {
        var size = readUInt32BEUnchecked(data, at: pos)
        let typeData = data.subdata(in: pos + 4..<pos + 8)
        let type = String(data: typeData, encoding: .isoLatin1) ?? "????"
        var header = 8
        if size == 1 {
            if pos + 16 > end { break }
            size = Int(UInt64(readUInt32BEUnchecked(data, at: pos + 8)) << 32 | UInt64(readUInt32BEUnchecked(data, at: pos + 12)))
            header = 16
        } else if size == 0 {
            size = end - pos
        }
        if size < header || pos + size > end { break }
        result.append(ISOBMFFBox(type: type, dataStart: pos + header, dataEnd: pos + size, boxStart: pos, size: size))
        pos += size
    }
    return result
}

private func parseISOBMFFILoc(_ data: Data, _ box: ISOBMFFBox) throws -> [ISOBMFFILocEntry] {
    let version = data[box.dataStart]
    var pos = box.dataStart + 4
    let sizes0 = data[pos]; pos += 1
    let sizes1 = data[pos]; pos += 1
    let offsetSize = Int((sizes0 >> 4) & 0x0f)
    let lengthSize = Int(sizes0 & 0x0f)
    let baseOffsetSize = Int((sizes1 >> 4) & 0x0f)
    let indexSize = version == 1 || version == 2 ? Int(sizes1 & 0x0f) : 0
    let count: Int
    if version >= 2 {
        count = readUInt32BEUnchecked(data, at: pos); pos += 4
    } else {
        count = readUInt16BEUnchecked(data, at: pos); pos += 2
    }

    func read(_ size: Int, _ pos: inout Int) -> Int {
        var value = 0
        for _ in 0..<size {
            value = (value << 8) | Int(data[pos])
            pos += 1
        }
        return value
    }

    var entries: [ISOBMFFILocEntry] = []
    for _ in 0..<count {
        let itemID: Int
        if version >= 2 {
            itemID = readUInt32BEUnchecked(data, at: pos); pos += 4
        } else {
            itemID = readUInt16BEUnchecked(data, at: pos); pos += 2
        }
        var constructionMethod = 0
        if version == 1 || version == 2 {
            constructionMethod = readUInt16BEUnchecked(data, at: pos) & 0x0f
            pos += 2
        }
        let dataReferenceIndex = readUInt16BEUnchecked(data, at: pos); pos += 2
        let baseOffset = read(baseOffsetSize, &pos)
        let extentCount = readUInt16BEUnchecked(data, at: pos); pos += 2
        var extents: [(offset: Int, length: Int)] = []
        for _ in 0..<extentCount {
            if indexSize > 0 { _ = read(indexSize, &pos) }
            let offset = read(offsetSize, &pos)
            let length = read(lengthSize, &pos)
            extents.append((baseOffset + offset, length))
        }
        entries.append(ISOBMFFILocEntry(itemID: itemID, constructionMethod: constructionMethod, dataReferenceIndex: dataReferenceIndex, extents: extents))
    }
    return entries
}

private func parseISOBMFFIInf(_ data: Data, _ box: ISOBMFFBox) -> (version: UInt8, entries: [Int: String], rawInfe: [Int: Data]) {
    let version = data[box.dataStart]
    var pos = box.dataStart + 4
    if version >= 1 {
        pos += 4
    } else {
        pos += 2
    }
    var entries: [Int: String] = [:]
    var raw: [Int: Data] = [:]
    for child in isobmffBoxes(in: data, start: pos, end: box.dataEnd) where child.type == "infe" {
        let v = data[child.dataStart]
        var p = child.dataStart + 4
        if v >= 2 {
            let typeAtU16 = String(data: data.subdata(in: p + 4..<p + 8), encoding: .ascii) ?? ""
            let itemID: Int
            if ["hvc1", "grid", "Exif", "mime", "tmap", "jpeg"].contains(typeAtU16) {
                itemID = readUInt16BEUnchecked(data, at: p); p += 2
            } else {
                itemID = readUInt32BEUnchecked(data, at: p); p += 4
            }
            p += 2
            let type = String(data: data.subdata(in: p..<p + 4), encoding: .isoLatin1) ?? "????"
            entries[itemID] = type
            raw[itemID] = data.subdata(in: child.boxStart..<child.boxStart + child.size)
        }
    }
    return (version, entries, raw)
}

private func parseISOBMFFPITM(_ data: Data, _ box: ISOBMFFBox) -> Int {
    let version = data[box.dataStart]
    let pos = box.dataStart + 4
    return version == 0 ? readUInt16BEUnchecked(data, at: pos) : readUInt32BEUnchecked(data, at: pos)
}

private func parseISOBMFFIPMA(_ data: Data, _ box: ISOBMFFBox) -> (flags: Int, entries: [ISOBMFFIPMAEntry]) {
    let flags = (Int(data[box.dataStart + 1]) << 16) | (Int(data[box.dataStart + 2]) << 8) | Int(data[box.dataStart + 3])
    var pos = box.dataStart + 4
    let count = readUInt32BEUnchecked(data, at: pos); pos += 4
    var entries: [ISOBMFFIPMAEntry] = []
    for _ in 0..<count {
        let itemID: Int
        if flags & 1 != 0 {
            itemID = readUInt32BEUnchecked(data, at: pos); pos += 4
        } else {
            itemID = readUInt16BEUnchecked(data, at: pos); pos += 2
        }
        let associationCount = Int(data[pos]); pos += 1
        var associations: [Int] = []
        for _ in 0..<associationCount {
            if flags & 1 != 0 {
                associations.append(readUInt16BEUnchecked(data, at: pos)); pos += 2
            } else {
                associations.append(Int(data[pos])); pos += 1
            }
        }
        entries.append(ISOBMFFIPMAEntry(itemID: itemID, associations: associations))
    }
    return (flags, entries)
}

private func parseISOBMFFIRefVersion(_ data: Data, _ box: ISOBMFFBox?) -> UInt8 {
    guard let box else { return 0 }
    return data[box.dataStart]
}

private func parseISOBMFFIPCOProps(_ data: Data, _ iprp: ISOBMFFBox) throws -> (box: ISOBMFFBox, types: [Int: String], sizes: [Int: (Int, Int)]) {
    guard let ipco = isobmffBoxes(in: data, start: iprp.dataStart, end: iprp.dataEnd).first(where: { $0.type == "ipco" }) else {
        throw CLIError.invalidContainer("ipco missing")
    }
    var types: [Int: String] = [:]
    var sizes: [Int: (Int, Int)] = [:]
    var index = 1
    for prop in isobmffBoxes(in: data, start: ipco.dataStart, end: ipco.dataEnd) {
        types[index] = prop.type
        if prop.type == "ispe", prop.dataEnd - prop.dataStart >= 12 {
            sizes[index] = (readUInt32BEUnchecked(data, at: prop.dataStart + 4), readUInt32BEUnchecked(data, at: prop.dataStart + 8))
        }
        index += 1
    }
    return (ipco, types, sizes)
}

private func parseISOBMFFItemInfos(_ data: Data, _ box: ISOBMFFBox) -> (version: UInt8, items: [ISOBMFFItemInfo]) {
    let version = data[box.dataStart]
    var pos = box.dataStart + 4
    if version >= 1 {
        pos += 4
    } else {
        pos += 2
    }

    var items: [ISOBMFFItemInfo] = []
    for child in isobmffBoxes(in: data, start: pos, end: box.dataEnd) where child.type == "infe" {
        let itemInfoVersion = data[child.dataStart]
        guard itemInfoVersion >= 2 else { continue }
        let flags = (Int(data[child.dataStart + 1]) << 16)
            | (Int(data[child.dataStart + 2]) << 8)
            | Int(data[child.dataStart + 3])
        var p = child.dataStart + 4
        let itemID: Int
        if itemInfoVersion >= 3 {
            itemID = readUInt32BEUnchecked(data, at: p)
            p += 4
        } else {
            itemID = readUInt16BEUnchecked(data, at: p)
            p += 2
        }
        p += 2
        guard p + 4 <= child.dataEnd else { continue }
        let type = String(data: data.subdata(in: p..<p + 4), encoding: .isoLatin1) ?? "????"
        let raw = data.subdata(in: child.boxStart..<child.boxStart + child.size)
        items.append(ISOBMFFItemInfo(itemID: itemID, type: type, flags: flags, rawInfe: raw))
    }
    return (version, items)
}

private func parseISOBMFFIRefs(_ data: Data, _ box: ISOBMFFBox?) -> (version: UInt8, refs: [ISOBMFFIRefEntry]) {
    guard let box else { return (0, []) }
    let version = data[box.dataStart]
    let idSize = version >= 1 ? 4 : 2
    var refs: [ISOBMFFIRefEntry] = []
    for child in isobmffBoxes(in: data, start: box.dataStart + 4, end: box.dataEnd) {
        var pos = child.dataStart
        guard pos + idSize + 2 <= child.dataEnd else { continue }
        let from: Int
        if idSize == 4 {
            from = readUInt32BEUnchecked(data, at: pos)
            pos += 4
        } else {
            from = readUInt16BEUnchecked(data, at: pos)
            pos += 2
        }
        let count = readUInt16BEUnchecked(data, at: pos)
        pos += 2
        var to: [Int] = []
        for _ in 0..<count where pos + idSize <= child.dataEnd {
            if idSize == 4 {
                to.append(readUInt32BEUnchecked(data, at: pos))
                pos += 4
            } else {
                to.append(readUInt16BEUnchecked(data, at: pos))
                pos += 2
            }
        }
        refs.append(ISOBMFFIRefEntry(type: child.type, from: from, to: to))
    }
    return (version, refs)
}

private func parseISOBMFFIPCOPropertyInfos(_ data: Data, _ iprp: ISOBMFFBox) throws -> [ISOBMFFPropertyInfo] {
    guard let ipco = isobmffBoxes(in: data, start: iprp.dataStart, end: iprp.dataEnd).first(where: { $0.type == "ipco" }) else {
        throw CLIError.invalidContainer("ipco missing")
    }
    return isobmffBoxes(in: data, start: ipco.dataStart, end: ipco.dataEnd).enumerated().map { offset, prop in
        ISOBMFFPropertyInfo(
            index: offset + 1,
            type: prop.type,
            rawBox: data.subdata(in: prop.boxStart..<prop.boxStart + prop.size)
        )
    }
}

private func assocPropertyIndex(_ value: Int, flags: Int) -> Int {
    value & (flags & 1 != 0 ? 0x7fff : 0x7f)
}

private func assocIsEssential(_ value: Int, flags: Int) -> Bool {
    value & (flags & 1 != 0 ? 0x8000 : 0x80) != 0
}

private func assocPairs(_ values: [Int], flags: Int) -> [(Int, Bool)] {
    values.map { (assocPropertyIndex($0, flags: flags), assocIsEssential($0, flags: flags)) }
}

private func makePitmBox(version: UInt8, primaryID: Int) -> Data {
    var payload = Data([version, 0, 0, 0])
    if version >= 1 {
        appendUInt32BE(primaryID, to: &payload)
    } else {
        appendUInt16BE(primaryID, to: &payload)
    }
    return makeBox("pitm", payload: payload)
}

private func makeIinfBox(version: UInt8, rawInfes: [Data]) -> Data {
    var payload = Data([version, 0, 0, 0])
    if version >= 1 {
        appendUInt32BE(rawInfes.count, to: &payload)
    } else {
        appendUInt16BE(rawInfes.count, to: &payload)
    }
    for raw in rawInfes {
        payload.append(raw)
    }
    return makeBox("iinf", payload: payload)
}

private func makeIlocV1Box(entries: [ISOBMFFILocEntry]) -> Data {
    var payload = Data([1, 0, 0, 0, 0x44, 0x00])
    appendUInt16BE(entries.count, to: &payload)
    for entry in entries {
        appendUInt16BE(entry.itemID, to: &payload)
        appendUInt16BE(entry.constructionMethod, to: &payload)
        appendUInt16BE(entry.dataReferenceIndex, to: &payload)
        appendUInt16BE(entry.extents.count, to: &payload)
        for extent in entry.extents {
            appendUInt32BE(extent.offset, to: &payload)
            appendUInt32BE(extent.length, to: &payload)
        }
    }
    return makeBox("iloc", payload: payload)
}

private func makeIrefFullBox(version: UInt8, refs: [ISOBMFFIRefEntry]) -> Data {
    var payload = Data([version, 0, 0, 0])
    for ref in refs {
        payload.append(makeIrefBox(type: ref.type, from: ref.from, to: ref.to, version: version))
    }
    return makeBox("iref", payload: payload)
}

private func makeGrplAltrBox(groupID: Int, tmapID: Int, primaryID: Int) -> Data {
    makeBox("grpl", payload: makeAltrEntityGroupBox(groupID: groupID, tmapID: tmapID, primaryID: primaryID))
}

private func makeAltrEntityGroupBox(groupID: Int, tmapID: Int, primaryID: Int) -> Data {
    var altrPayload = Data([0, 0, 0, 0])
    appendUInt32BE(groupID, to: &altrPayload)
    appendUInt32BE(2, to: &altrPayload)
    appendUInt32BE(tmapID, to: &altrPayload)
    appendUInt32BE(primaryID, to: &altrPayload)
    return makeBox("altr", payload: altrPayload)
}

private func preservedEntityGroupChildren(
    in data: Data,
    grpl: ISOBMFFBox,
    dropping itemIDs: Set<Int>
) -> (payload: Data, groupIDs: [Int]) {
    var payload = Data()
    var groupIDs: [Int] = []
    for child in isobmffBoxes(in: data, start: grpl.dataStart, end: grpl.dataEnd) {
        let raw = data.subdata(in: child.boxStart..<child.boxStart + child.size)
        guard child.dataEnd - child.dataStart >= 12 else {
            payload.append(raw)
            continue
        }
        let groupID = readUInt32BEUnchecked(data, at: child.dataStart + 4)
        let entityCount = readUInt32BEUnchecked(data, at: child.dataStart + 8)
        groupIDs.append(groupID)
        var pos = child.dataStart + 12
        var entities: [Int] = []
        for _ in 0..<entityCount where pos + 4 <= child.dataEnd {
            entities.append(readUInt32BEUnchecked(data, at: pos))
            pos += 4
        }
        if itemIDs.isDisjoint(with: entities) {
            payload.append(raw)
        }
    }
    return (payload, groupIDs)
}

private func itemPayload(in data: Data, entry: ISOBMFFILocEntry, idat: ISOBMFFBox?) throws -> Data {
    var out = Data()
    for extent in entry.extents {
        let start: Int
        switch entry.constructionMethod {
        case 0:
            start = extent.offset
        case 1:
            guard let idat else {
                throw CLIError.invalidContainer("item \(entry.itemID) uses idat construction but idat is missing")
            }
            start = idat.dataStart + extent.offset
        default:
            throw CLIError.invalidContainer("unsupported construction_method \(entry.constructionMethod) for item \(entry.itemID)")
        }
        let end = start + extent.length
        guard start >= 0, end <= data.count else {
            throw CLIError.invalidContainer("item \(entry.itemID) extent is out of bounds")
        }
        out.append(data.subdata(in: start..<end))
    }
    return out
}

private func jpegImageSize(_ jpeg: Data) throws -> (Int, Int) {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = props[kCGImagePropertyPixelWidth] as? Int,
          let height = props[kCGImagePropertyPixelHeight] as? Int else {
        throw CLIError.invalidContainer("cannot read private gain map JPEG dimensions")
    }
    return (width, height)
}

private func makeInfeBox(itemID: Int, type: String, flags: Int = 0) -> Data {
    var payload = Data([2, UInt8((flags >> 16) & 0xff), UInt8((flags >> 8) & 0xff), UInt8(flags & 0xff)])
    appendUInt16BE(itemID, to: &payload)
    appendUInt16BE(0, to: &payload)
    payload.append(type.data(using: .ascii)!)
    payload.append(0)
    return makeBox("infe", payload: payload)
}

private func makeMimeInfeBox(itemID: Int, flags: Int = 0) -> Data {
    var payload = Data([2, UInt8((flags >> 16) & 0xff), UInt8((flags >> 8) & 0xff), UInt8(flags & 0xff)])
    appendUInt16BE(itemID, to: &payload)
    appendUInt16BE(0, to: &payload)
    payload.append(Data("mime".utf8))
    payload.append(Data("hdrgm-xmp".utf8)); payload.append(0)
    payload.append(Data("application/rdf+xml".utf8)); payload.append(0)
    payload.append(0)
    return makeBox("infe", payload: payload)
}

private func makeIspeBox(width: Int, height: Int) -> Data {
    var payload = Data([0, 0, 0, 0])
    appendUInt32BE(width, to: &payload)
    appendUInt32BE(height, to: &payload)
    return makeBox("ispe", payload: payload)
}

private func makeIrefBox(type: String, from: Int, to: [Int], version: UInt8) -> Data {
    let idSize = version >= 1 ? 4 : 2
    var payload = Data()
    if idSize == 4 { appendUInt32BE(from, to: &payload) } else { appendUInt16BE(from, to: &payload) }
    appendUInt16BE(to.count, to: &payload)
    for item in to {
        if idSize == 4 { appendUInt32BE(item, to: &payload) } else { appendUInt16BE(item, to: &payload) }
    }
    return makeBox(type, payload: payload)
}

private func makeIPMAEntry(_ itemID: Int, _ assocs: [(Int, Bool)], flags: Int) throws -> Data {
    if flags & 1 == 0, assocs.contains(where: { $0.0 > 0x7f }) {
        throw CLIError.invalidContainer("ipma property index exceeds 7-bit association limit")
    }
    var out = Data()
    if flags & 1 != 0 { appendUInt32BE(itemID, to: &out) } else { appendUInt16BE(itemID, to: &out) }
    out.append(UInt8(assocs.count))
    for (index, essential) in assocs {
        if flags & 1 != 0 {
            appendUInt16BE((essential ? 0x8000 : 0) | index, to: &out)
        } else {
            out.append(UInt8((essential ? 0x80 : 0) | index))
        }
    }
    return out
}

/// Generate the 142-byte ImageIO-native tmap payload observed in OPPO-recognized CoreImage output.
/// This compatibility form is intentionally distinct from strict ISO 21496-1's padded 145-byte check.
private func makeImageIONativeTmapPayload(infoFloats f: [Double]) -> Data {
    let rationalDen = 100_000
    func appendRational(_ value: Double, to data: inout Data) {
        appendUInt32BE(Int(max(0, (value * Double(rationalDen)).rounded())), to: &data)
        appendUInt32BE(rationalDen, to: &data)
    }
    func appendSignedRational(_ value: Double, to data: inout Data) {
        appendInt32BE(Int32((value * Double(rationalDen)).rounded()), to: &data)
        appendUInt32BE(rationalDen, to: &data)
    }

    // Use the same values as makeAppleTmapPayload for all 3 channels.
    // f[0]=gain_min, f[4]=gain_max, f[7]=gamma, f[10]=base_offset, f[13]=alt_offset,
    // f[16]=cap_min, f[17]=cap_max.  Per-channel variants at f[1-2],f[5-6],f[8-9],
    // f[11-12],f[14-15] are unused here to match the proven 62B payload behavior.
    let gainMin = max(log2(max(f[0], 1.0)), 0.0)
    let gainMax = log2(max(f[4], 1.0))
    let gamma = f[7]
    let baseOffset = f[10]
    let altOffset = f[13]
    let capMin = max(log2(max(f[16], 1.0)), 0.0)
    let capMax = log2(max(f[17], 1.0))

    var out = Data()

    // Version byte
    out.append(0x00)

    // Common header (21 bytes)
    appendUInt16BE(0, to: &out)  // minimum_version
    appendUInt16BE(0, to: &out)  // writer_version
    out.append(0xC0)             // flags: multichannel=1, use_base_colour_space=1
    appendRational(capMin, to: &out)   // base_hdr_headroom
    appendRational(capMax, to: &out)   // alternate_hdr_headroom

    // 3 channels × 40 bytes (same values for all channels, matching 62B payload)
    for _ in 0..<3 {
        appendSignedRational(gainMin, to: &out)      // gain_map_min
        appendSignedRational(gainMax, to: &out)      // gain_map_max
        appendRational(gamma, to: &out)              // gamma
        appendSignedRational(baseOffset, to: &out)   // base_offset (single rational)
        appendSignedRational(altOffset, to: &out)    // alternate_offset (single rational)
    }

    return out  // 1 + 21 + 120 = 142 bytes
}

private func makeAppleTmapPayload(infoFloats f: [Double]) -> Data {
    func fixed(_ value: Double) -> Int32 {
        Int32((value * 100_000.0).rounded())
    }
    let values: [Double] = [
        max(log2(max(f[16], 1.0)), 0.0), 1.0,
        log2(max(f[17], 1.0)), 1.0,
        max(log2(max(f[0], 1.0)), 0.0), 1.0,
        log2(max(f[4], 1.0)), 1.0,
        f[7], 1.0,
        f[10], 1.0,
        f[13], 1.0,
    ]
    var out = Data([0, 0, 0, 0, 0, 0x40])
    for value in values {
        appendInt32BE(fixed(value), to: &out)
    }
    return out
}

private func makeHdrgmXMP(infoFloats f: [Double]) -> Data {
    func safeLog2(_ value: Double) -> Double { value > 0 ? log2(value) : 0.0 }
    func fmt(_ values: [Double]) -> String { values.map { String(format: "%.6f", $0) }.joined(separator: " ") }
    let gainMin = [safeLog2(f[0]), safeLog2(f[1]), safeLog2(f[2])]
    let gainMax = [safeLog2(f[4]), safeLog2(f[5]), safeLog2(f[6])]
    let gamma = [f[7], f[8], f[9]]
    let offsetSdr = [f[10], f[11], f[12]]
    let offsetHdr = [f[13], f[14], f[15]]
    let capMin = max(safeLog2(f[16]), 0.0)
    let capMax = safeLog2(f[17])
    let xml = """
    <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 6.0.0">
       <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
                xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/"
                xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
             <hdrgm:Version>1.0</hdrgm:Version>
             <hdrgm:GainMapMin>\(fmt(gainMin))</hdrgm:GainMapMin>
             <hdrgm:GainMapMax>\(fmt(gainMax))</hdrgm:GainMapMax>
             <hdrgm:Gamma>\(fmt(gamma))</hdrgm:Gamma>
             <hdrgm:OffsetSDR>\(fmt(offsetSdr))</hdrgm:OffsetSDR>
             <hdrgm:OffsetHDR>\(fmt(offsetHdr))</hdrgm:OffsetHDR>
             <hdrgm:HDRCapacityMin>\(String(format: "%.6f", capMin))</hdrgm:HDRCapacityMin>
             <hdrgm:HDRCapacityMax>\(String(format: "%.6f", capMax))</hdrgm:HDRCapacityMax>
             <hdrgm:BaseRenditionIsHDR>False</hdrgm:BaseRenditionIsHDR>
          </rdf:Description>
       </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """
    return Data(xml.utf8)
}

private func writeHybridPrimaryPassthrough(
    sourceURL: URL,
    preservedURL: URL,
    outputURL: URL,
    patchedUserComment: String?,
    preserveTmapColor: Bool = false,
    strictISO21496Tmap: Bool = false,
    fallbackXMPPayload: Data? = nil
) throws {
    let source = try Data(contentsOf: sourceURL)
    let preserved = try Data(contentsOf: preservedURL)

    let sourceTop = isobmffBoxes(in: source, start: 0, end: source.count)
    let preservedTop = isobmffBoxes(in: preserved, start: 0, end: preserved.count)
    guard let sourceFtyp = sourceTop.first(where: { $0.type == "ftyp" }),
          let sourceMeta = sourceTop.first(where: { $0.type == "meta" }),
          let sourceMdat = sourceTop.first(where: { $0.type == "mdat" }),
          let preservedMeta = preservedTop.first(where: { $0.type == "meta" }) else {
        throw CLIError.invalidContainer("hybrid graft requires ftyp/meta/mdat in source and meta in preserve output")
    }

    let sourceMetaChildren = isobmffBoxes(in: source, start: sourceMeta.dataStart + 4, end: sourceMeta.dataEnd)
    let preservedMetaChildren = isobmffBoxes(in: preserved, start: preservedMeta.dataStart + 4, end: preservedMeta.dataEnd)
    func sourceChild(_ type: String) throws -> ISOBMFFBox {
        guard let box = sourceMetaChildren.first(where: { $0.type == type }) else {
            throw CLIError.invalidContainer("source meta/\(type) missing")
        }
        return box
    }
    func preservedChild(_ type: String) throws -> ISOBMFFBox {
        guard let box = preservedMetaChildren.first(where: { $0.type == type }) else {
            throw CLIError.invalidContainer("preserve meta/\(type) missing")
        }
        return box
    }

    let sourceIinf = try sourceChild("iinf")
    let sourceIloc = try sourceChild("iloc")
    let sourcePitm = try sourceChild("pitm")
    let sourceIprp = try sourceChild("iprp")
    let sourceIDAT = sourceMetaChildren.first(where: { $0.type == "idat" })
    let sourceIref = sourceMetaChildren.first(where: { $0.type == "iref" })
    let sourcePrimaryID = parseISOBMFFPITM(source, sourcePitm)
    let sourceItemInfo = parseISOBMFFItemInfos(source, sourceIinf)
    let sourceIlocEntries = try parseISOBMFFILoc(source, sourceIloc)
    let sourceRefsInfo = parseISOBMFFIRefs(source, sourceIref)
    let sourceProps = try parseISOBMFFIPCOPropertyInfos(source, sourceIprp)
    let sourcePropsByIndex = Dictionary(uniqueKeysWithValues: sourceProps.map { ($0.index, $0) })
    guard let sourceIPMABox = isobmffBoxes(in: source, start: sourceIprp.dataStart, end: sourceIprp.dataEnd).first(where: { $0.type == "ipma" }) else {
        throw CLIError.invalidContainer("source ipma missing")
    }
    let sourceIPMA = parseISOBMFFIPMA(source, sourceIPMABox)

    let preservedIinf = try preservedChild("iinf")
    let preservedIloc = try preservedChild("iloc")
    let preservedPitm = try preservedChild("pitm")
    let preservedIprp = try preservedChild("iprp")
    let preservedIDAT = preservedMetaChildren.first(where: { $0.type == "idat" })
    let preservedIref = preservedMetaChildren.first(where: { $0.type == "iref" })
    let preservedPrimaryID = parseISOBMFFPITM(preserved, preservedPitm)
    let preservedItemInfo = parseISOBMFFItemInfos(preserved, preservedIinf)
    let preservedItemsByID = Dictionary(uniqueKeysWithValues: preservedItemInfo.items.map { ($0.itemID, $0) })
    let preservedIlocEntries = try parseISOBMFFILoc(preserved, preservedIloc)
    let preservedIlocByID = Dictionary(uniqueKeysWithValues: preservedIlocEntries.map { ($0.itemID, $0) })
    let preservedRefsInfo = parseISOBMFFIRefs(preserved, preservedIref)
    let preservedProps = try parseISOBMFFIPCOPropertyInfos(preserved, preservedIprp)
    let preservedPropsByIndex = Dictionary(uniqueKeysWithValues: preservedProps.map { ($0.index, $0) })
    guard let preservedIPMABox = isobmffBoxes(in: preserved, start: preservedIprp.dataStart, end: preservedIprp.dataEnd).first(where: { $0.type == "ipma" }) else {
        throw CLIError.invalidContainer("preserve ipma missing")
    }
    let preservedIPMA = parseISOBMFFIPMA(preserved, preservedIPMABox)

    let preservedDimgRefs = Dictionary(
        uniqueKeysWithValues: preservedRefsInfo.refs
            .filter { $0.type == "dimg" }
            .map { ($0.from, $0.to) }
    )
    guard let preservedTmapID = preservedItemInfo.items.first(where: { $0.type == "tmap" })?.itemID,
          let tmapTargets = preservedDimgRefs[preservedTmapID] else {
        throw CLIError.invalidContainer("preserve output has no tmap dimg reference")
    }
    let preservedGainGridID = tmapTargets.first {
        $0 != preservedPrimaryID && preservedItemsByID[$0]?.type == "grid"
    } ?? tmapTargets.dropFirst().first
    guard let preservedGainGridID,
          preservedItemsByID[preservedGainGridID]?.type == "grid",
          let preservedGainTileIDs = preservedDimgRefs[preservedGainGridID],
          !preservedGainTileIDs.isEmpty else {
        throw CLIError.invalidContainer("preserve output has no HEVC gain-map grid")
    }
    let preservedXMPID = preservedRefsInfo.refs.first {
        $0.type == "cdsc" && $0.to.contains(preservedTmapID) && preservedItemsByID[$0.from]?.type == "mime"
    }?.from

    let sourceTmapIDs = Set(sourceItemInfo.items.compactMap { item -> Int? in
        guard item.type == "tmap",
              sourceRefsInfo.refs.contains(where: {
                  $0.type == "dimg" && $0.from == item.itemID && $0.to.contains(sourcePrimaryID)
              }) else { return nil }
        return item.itemID
    })
    let sourceGainRootIDs = Set(sourceRefsInfo.refs
        .filter { $0.type == "dimg" && sourceTmapIDs.contains($0.from) }
        .flatMap(\.to)
        .filter { $0 != sourcePrimaryID })
    var dropSourceIDs = sourceTmapIDs
    let generatedHDRGMName = Data("hdrgm-xmp\u{0}".utf8)
    let sourceGeneratedHDRGMXMPIDs = Set(sourceItemInfo.items.compactMap { item -> Int? in
        guard item.type == "mime",
              item.rawInfe.range(of: generatedHDRGMName) != nil,
              sourceRefsInfo.refs.contains(where: {
                  $0.type == "cdsc" && $0.from == item.itemID && !Set($0.to).isDisjoint(with: sourceTmapIDs)
              }) else { return nil }
        return item.itemID
    })
    dropSourceIDs.formUnion(sourceGeneratedHDRGMXMPIDs)
    var pendingHDRInputs = Array(sourceGainRootIDs)
    while let itemID = pendingHDRInputs.popLast() {
        guard itemID != sourcePrimaryID, !dropSourceIDs.contains(itemID) else { continue }
        dropSourceIDs.insert(itemID)
        for ref in sourceRefsInfo.refs where ref.type == "dimg" && ref.from == itemID {
            pendingHDRInputs.append(contentsOf: ref.to.filter { $0 != sourcePrimaryID })
        }
    }

    let keptSourceItems = sourceItemInfo.items.filter { !dropSourceIDs.contains($0.itemID) }
    let keptSourceIDs = Set(keptSourceItems.map(\.itemID))
    let keptSourceIlocEntries = sourceIlocEntries.filter { keptSourceIDs.contains($0.itemID) }
    guard keptSourceIDs.contains(sourcePrimaryID) else {
        throw CLIError.invalidContainer("hybrid graft would drop primary item")
    }
    var sourceMdatPayload = source.subdata(in: sourceMdat.dataStart..<sourceMdat.dataEnd)
    let sourceExifID = keptSourceItems.first(where: { $0.type == "Exif" })?.itemID
    let userCommentPatch: OppoUserCommentPatch?
    if let patchedUserComment {
        guard let sourceExifID,
              let sourceExifEntry = keptSourceIlocEntries.first(where: { $0.itemID == sourceExifID }) else {
            throw CLIError.invalidContainer("unable to locate source Exif item for OPPO UserComment patch")
        }
        guard let patch = applyOppoUserCommentPatch(
            &sourceMdatPayload,
            mdatDataStart: sourceMdat.dataStart,
            exifEntry: sourceExifEntry,
            patchedUserComment: patchedUserComment
        ) else {
            throw CLIError.invalidContainer("unable to patch OPPO UserComment in hybrid output")
        }
        userCommentPatch = patch
    } else {
        userCommentPatch = nil
    }

    let maxSourceID = keptSourceItems.map(\.itemID).max() ?? sourcePrimaryID
    let hasOutputXMP = preservedXMPID != nil || fallbackXMPPayload != nil
    let copiedItemCount = preservedGainTileIDs.count + 2 + (hasOutputXMP ? 1 : 0)
    guard maxSourceID + copiedItemCount < 0xffff else {
        throw CLIError.invalidContainer("hybrid graft currently requires 16-bit item IDs")
    }
    var nextItemID = maxSourceID + 1
    var gainTileIDMap: [Int: Int] = [:]
    for oldID in preservedGainTileIDs {
        gainTileIDMap[oldID] = nextItemID
        nextItemID += 1
    }
    let outputGainGridID = nextItemID
    nextItemID += 1
    let outputTmapID = nextItemID
    nextItemID += 1
    let outputXMPID: Int?
    if hasOutputXMP {
        outputXMPID = nextItemID
        nextItemID += 1
    } else {
        outputXMPID = nil
    }

    let gainTilePayloads: [(oldID: Int, newID: Int, payload: Data)] = try preservedGainTileIDs.map { oldID in
        guard let entry = preservedIlocByID[oldID], let newID = gainTileIDMap[oldID] else {
            throw CLIError.invalidContainer("preserve gain tile \(oldID) has no iloc entry")
        }
        return (oldID, newID, try itemPayload(in: preserved, entry: entry, idat: preservedIDAT))
    }
    guard let gainGridEntry = preservedIlocByID[preservedGainGridID],
          let tmapEntry = preservedIlocByID[preservedTmapID] else {
        throw CLIError.invalidContainer("preserve gain grid/tmap has no iloc entry")
    }
    let gainGridPayload = try itemPayload(in: preserved, entry: gainGridEntry, idat: preservedIDAT)
    let preservedTmapPayload = try itemPayload(in: preserved, entry: tmapEntry, idat: preservedIDAT)
    let tmapPayload: Data
    if strictISO21496Tmap, preservedTmapPayload.count == 62 || preservedTmapPayload.count == 142 {
        // ImageIO omits the three reserved GainMapMetadata bytes. Restore them
        // after the flags byte so one/three-channel ISO payloads are 65/145 B.
        tmapPayload = preservedTmapPayload.prefix(6)
            + Data([0x00, 0x00, 0x00])
            + preservedTmapPayload.dropFirst(6)
    } else {
        tmapPayload = preservedTmapPayload
    }
    let xmpPayload: Data?
    if let preservedXMPID {
        guard let xmpEntry = preservedIlocByID[preservedXMPID] else {
            throw CLIError.invalidContainer("preserve XMP item has no iloc entry")
        }
        xmpPayload = try itemPayload(in: preserved, entry: xmpEntry, idat: preservedIDAT)
    } else {
        xmpPayload = fallbackXMPPayload
    }

    var ipcoPayload = Data()
    for prop in sourceProps {
        ipcoPayload.append(prop.rawBox)
    }
    var propertyIndexMap: [Int: Int] = [:]
    func mapPreservedProperty(_ index: Int) throws -> Int {
        if let mapped = propertyIndexMap[index] { return mapped }
        guard let prop = preservedPropsByIndex[index] else {
            throw CLIError.invalidContainer("preserve property \(index) missing")
        }
        let mapped = sourceProps.count + propertyIndexMap.count + 1
        propertyIndexMap[index] = mapped
        ipcoPayload.append(prop.rawBox)
        return mapped
    }
    func remapPreservedAssocs(_ values: [Int]) throws -> [(Int, Bool)] {
        try values.map { value in
            let index = assocPropertyIndex(value, flags: preservedIPMA.flags)
            return (try mapPreservedProperty(index), assocIsEssential(value, flags: preservedIPMA.flags))
        }
    }
    func propertyType(_ assoc: (Int, Bool), in props: [Int: ISOBMFFPropertyInfo]) -> String? {
        props[assoc.0]?.type
    }

    let sourceIPMAByID = Dictionary(uniqueKeysWithValues: sourceIPMA.entries.map { ($0.itemID, $0) })
    let preservedIPMAByID = Dictionary(uniqueKeysWithValues: preservedIPMA.entries.map { ($0.itemID, $0) })
    let sourcePrimaryColorAssoc = assocPairs(sourceIPMAByID[sourcePrimaryID]?.associations ?? [], flags: sourceIPMA.flags)
        .first { propertyType($0, in: sourcePropsByIndex) == "colr" }
    var primaryAssocs = assocPairs(sourceIPMAByID[sourcePrimaryID]?.associations ?? [], flags: sourceIPMA.flags)
    if primaryAssocs.isEmpty,
       let firstIspe = sourceProps.first(where: { $0.type == "ispe" })?.index {
        primaryAssocs.append((firstIspe, true))
    }
    func primaryHasPropertyType(_ type: String) -> Bool {
        primaryAssocs.contains { propertyType($0, in: sourcePropsByIndex) == type }
    }
    func sourceItemColorAssoc(_ itemID: Int) -> (Int, Bool)? {
        assocPairs(sourceIPMAByID[itemID]?.associations ?? [], flags: sourceIPMA.flags)
            .first { propertyType($0, in: sourcePropsByIndex) == "colr" }
    }
    let sourceBaselineTileID = sourceRefsInfo.refs.first {
        $0.type == "dimg" && $0.from == sourcePrimaryID
    }?.to.first
    let sourceBaselineColorAssoc = sourcePrimaryColorAssoc
        ?? sourceBaselineTileID.flatMap(sourceItemColorAssoc)
    if !primaryHasPropertyType("colr"), let sourceBaselineColorAssoc {
        // Associate the source tile's existing color property with the source
        // grid. This adds the ISO-required base color declaration without
        // importing a newly normalized ImageIO profile.
        primaryAssocs.append(sourceBaselineColorAssoc)
    }
    if !primaryHasPropertyType("irot") {
        let irotOutputIndex = sourceProps.count + propertyIndexMap.count + 1
        propertyIndexMap[-2] = irotOutputIndex
        ipcoPayload.append(isoIrotBox)
        primaryAssocs.append((irotOutputIndex, true))
    }

    var ipmaEntries = Data()
    var ipmaEntryCount = 0
    for entry in sourceIPMA.entries where keptSourceIDs.contains(entry.itemID) {
        let assocs: [(Int, Bool)]
        if entry.itemID == sourcePrimaryID {
            assocs = primaryAssocs
        } else {
            assocs = assocPairs(entry.associations, flags: sourceIPMA.flags)
        }
        ipmaEntries.append(try makeIPMAEntry(entry.itemID, assocs, flags: sourceIPMA.flags))
        ipmaEntryCount += 1
    }
    if sourceIPMAByID[sourcePrimaryID] == nil {
        ipmaEntries.append(try makeIPMAEntry(sourcePrimaryID, primaryAssocs, flags: sourceIPMA.flags))
        ipmaEntryCount += 1
    }
    for tile in gainTilePayloads {
        guard let preservedEntry = preservedIPMAByID[tile.oldID] else {
            throw CLIError.invalidContainer("preserve gain tile \(tile.oldID) has no ipma entry")
        }
        ipmaEntries.append(try makeIPMAEntry(tile.newID, try remapPreservedAssocs(preservedEntry.associations), flags: sourceIPMA.flags))
        ipmaEntryCount += 1
    }
    guard let preservedGainGridIPMA = preservedIPMAByID[preservedGainGridID],
          let preservedTmapIPMA = preservedIPMAByID[preservedTmapID] else {
        throw CLIError.invalidContainer("preserve gain grid/tmap has no ipma entry")
    }
    var gainGridAssocs = try remapPreservedAssocs(preservedGainGridIPMA.associations)
    let gainGridHasAuxC = gainGridAssocs.contains { assoc in
        if let mapped = propertyIndexMap.first(where: { $1 == assoc.0 })?.key {
            return preservedPropsByIndex[mapped]?.type == "auxC"
        }
        return sourcePropsByIndex[assoc.0]?.type == "auxC"
    }
    if !gainGridHasAuxC {
        // ImageIO re-encode drops auxC; add it explicitly for ISO gain map recognition
        let auxCOutputIndex = sourceProps.count + propertyIndexMap.count + 1
        propertyIndexMap[-1] = auxCOutputIndex  // reserve slot so subsequent mapPreservedProperty uses correct index
        ipcoPayload.append(isoAuxCBox)
        gainGridAssocs.append((auxCOutputIndex, true))
    }
    ipmaEntries.append(try makeIPMAEntry(outputGainGridID, gainGridAssocs, flags: sourceIPMA.flags))
    ipmaEntryCount += 1
    let preservedTmapAssocPairs = assocPairs(preservedTmapIPMA.associations, flags: preservedIPMA.flags)
    let preservedTmapColorAssoc = preservedTmapAssocPairs.first { propertyType($0, in: preservedPropsByIndex) == "colr" }
    var tmapAssocs = try preservedTmapAssocPairs
        .filter { propertyType($0, in: preservedPropsByIndex) != "colr" }
        .map { (try mapPreservedProperty($0.0), $0.1) }
    if preserveTmapColor, let preservedTmapColorAssoc {
        tmapAssocs.insert((try mapPreservedProperty(preservedTmapColorAssoc.0), preservedTmapColorAssoc.1), at: 0)
    } else if let sourceBaselineColorAssoc {
        tmapAssocs.insert(sourceBaselineColorAssoc, at: 0)
    } else if let firstSourceColor = sourceProps.first(where: { $0.type == "colr" })?.index {
        tmapAssocs.insert((firstSourceColor, true), at: 0)
    } else if let preservedTmapColorAssoc {
        tmapAssocs.insert((try mapPreservedProperty(preservedTmapColorAssoc.0), preservedTmapColorAssoc.1), at: 0)
    }
    ipmaEntries.append(try makeIPMAEntry(outputTmapID, tmapAssocs, flags: sourceIPMA.flags))
    ipmaEntryCount += 1

    var ipmaPayload = source.subdata(in: sourceIPMABox.dataStart..<sourceIPMABox.dataStart + 4)
    appendUInt32BE(ipmaEntryCount, to: &ipmaPayload)
    ipmaPayload.append(ipmaEntries)
    var iprpPayload = Data()
    iprpPayload.append(makeBox("ipco", payload: ipcoPayload))
    iprpPayload.append(makeBox("ipma", payload: ipmaPayload))
    let iprpPart = makeBox("iprp", payload: iprpPayload)

    var rawInfes = keptSourceItems.map(\.rawInfe)
    for tile in gainTilePayloads {
        rawInfes.append(makeInfeBox(itemID: tile.newID, type: preservedItemsByID[tile.oldID]?.type ?? "hvc1", flags: preservedItemsByID[tile.oldID]?.flags ?? 1))
    }
    rawInfes.append(makeInfeBox(itemID: outputGainGridID, type: "grid", flags: preservedItemsByID[preservedGainGridID]?.flags ?? 1))
    rawInfes.append(makeInfeBox(itemID: outputTmapID, type: "tmap", flags: preservedItemsByID[preservedTmapID]?.flags ?? 0))
    if let outputXMPID {
        let flags = preservedXMPID.flatMap { preservedItemsByID[$0]?.flags } ?? 1
        rawInfes.append(makeMimeInfeBox(itemID: outputXMPID, flags: flags))
    }

    let sourceIDATPayload = sourceIDAT.map { source.subdata(in: $0.dataStart..<$0.dataEnd) } ?? Data()
    var appendedIDATPayload = Data()
    let gainGridIDATOffset = sourceIDATPayload.count
    appendedIDATPayload.append(gainGridPayload)
    let tmapIDATOffset = sourceIDATPayload.count + appendedIDATPayload.count
    appendedIDATPayload.append(tmapPayload)
    let xmpIDATOffset = sourceIDATPayload.count + appendedIDATPayload.count
    if let xmpPayload {
        appendedIDATPayload.append(xmpPayload)
    }

    var outputRefs: [ISOBMFFIRefEntry] = []
    var updatedSourceCdsc = false
    for ref in sourceRefsInfo.refs where !dropSourceIDs.contains(ref.from) {
        var replacedTmapTarget = false
        var rewrittenTargets: [Int] = []
        for target in ref.to {
            let rewritten: Int?
            if sourceTmapIDs.contains(target) {
                rewritten = outputTmapID
                replacedTmapTarget = true
            } else if sourceGainRootIDs.contains(target) {
                rewritten = outputGainGridID
            } else if dropSourceIDs.contains(target) {
                rewritten = nil
            } else {
                rewritten = target
            }
            if let rewritten, !rewrittenTargets.contains(rewritten) {
                rewrittenTargets.append(rewritten)
            }
        }
        guard !rewrittenTargets.isEmpty else { continue }
        if ref.type == "cdsc",
           ref.from == sourceExifID,
           rewrittenTargets.contains(sourcePrimaryID),
           !rewrittenTargets.contains(outputTmapID) {
            rewrittenTargets.append(outputTmapID)
            updatedSourceCdsc = true
        }
        outputRefs.append(ISOBMFFIRefEntry(type: ref.type, from: ref.from, to: rewrittenTargets))
        if ref.type == "cdsc", replacedTmapTarget {
            updatedSourceCdsc = true
        }
    }
    if !updatedSourceCdsc,
       let exifID = sourceExifID {
        outputRefs.append(ISOBMFFIRefEntry(type: "cdsc", from: exifID, to: [sourcePrimaryID, outputTmapID]))
    }
    outputRefs.append(ISOBMFFIRefEntry(type: "dimg", from: outputGainGridID, to: gainTilePayloads.map(\.newID)))
    outputRefs.append(ISOBMFFIRefEntry(type: "dimg", from: outputTmapID, to: [sourcePrimaryID, outputGainGridID]))
    outputRefs.append(ISOBMFFIRefEntry(type: "auxl", from: outputGainGridID, to: [sourcePrimaryID, outputTmapID]))
    if let outputXMPID {
        outputRefs.append(ISOBMFFIRefEntry(type: "cdsc", from: outputXMPID, to: [sourcePrimaryID, outputTmapID]))
    }
    let irefVersion: UInt8 = (outputRefs.flatMap { [$0.from] + $0.to }.max() ?? 0) > 0xffff ? 1 : sourceRefsInfo.version

    var placeholderIlocEntries = keptSourceIlocEntries.map { entry in
        ISOBMFFILocEntry(
            itemID: entry.itemID,
            constructionMethod: entry.constructionMethod,
            dataReferenceIndex: entry.dataReferenceIndex,
            extents: entry.extents.map { (offset: 0, length: $0.length) }
        )
    }
    for tile in gainTilePayloads {
        placeholderIlocEntries.append(ISOBMFFILocEntry(itemID: tile.newID, constructionMethod: 0, dataReferenceIndex: 0, extents: [(0, tile.payload.count)]))
    }
    placeholderIlocEntries.append(ISOBMFFILocEntry(itemID: outputGainGridID, constructionMethod: 1, dataReferenceIndex: 0, extents: [(gainGridIDATOffset, gainGridPayload.count)]))
    placeholderIlocEntries.append(ISOBMFFILocEntry(itemID: outputTmapID, constructionMethod: 1, dataReferenceIndex: 0, extents: [(tmapIDATOffset, tmapPayload.count)]))
    if let outputXMPID, let xmpPayload {
        placeholderIlocEntries.append(ISOBMFFILocEntry(itemID: outputXMPID, constructionMethod: 1, dataReferenceIndex: 0, extents: [(xmpIDATOffset, xmpPayload.count)]))
    }

    var preservedGroupPayload = Data()
    var sourceGroupIDs: [Int] = []
    for groupBox in sourceMetaChildren where groupBox.type == "grpl" {
        let preserved = preservedEntityGroupChildren(in: source, grpl: groupBox, dropping: dropSourceIDs)
        preservedGroupPayload.append(preserved.payload)
        sourceGroupIDs.append(contentsOf: preserved.groupIDs)
    }

    var metaParts: [Data] = []
    for part in sourceMetaChildren {
        switch part.type {
        case "hdlr":
            metaParts.append(source.subdata(in: part.boxStart..<part.boxStart + part.size))
            if !sourceMetaChildren.contains(where: { $0.type == "dinf" }) {
                metaParts.append(isoDinfBox)
            }
        case "pitm":
            metaParts.append(makePitmBox(version: source[sourcePitm.dataStart], primaryID: sourcePrimaryID))
        case "iinf":
            metaParts.append(makeIinfBox(version: sourceItemInfo.version, rawInfes: rawInfes))
        case "iloc":
            metaParts.append(makeIlocV1Box(entries: placeholderIlocEntries))
        case "iprp":
            metaParts.append(iprpPart)
        case "iref":
            metaParts.append(makeIrefFullBox(version: irefVersion, refs: outputRefs))
        case "idat":
            metaParts.append(makeBox("idat", payload: sourceIDATPayload + appendedIDATPayload))
        case "grpl":
            continue
        default:
            metaParts.append(source.subdata(in: part.boxStart..<part.boxStart + part.size))
        }
    }
    if sourceIref == nil {
        metaParts.append(makeIrefFullBox(version: irefVersion, refs: outputRefs))
    }
    if sourceIDAT == nil {
        metaParts.append(makeBox("idat", payload: appendedIDATPayload))
    }
    let groupID = max(max(nextItemID, outputTmapID), sourceGroupIDs.max() ?? 0) + 1
    preservedGroupPayload.append(makeAltrEntityGroupBox(groupID: groupID, tmapID: outputTmapID, primaryID: sourcePrimaryID))
    metaParts.append(makeBox("grpl", payload: preservedGroupPayload))

    var ftypPayload = source.subdata(in: sourceFtyp.dataStart..<sourceFtyp.dataEnd)
    var existingBrands = Set(stride(from: sourceFtyp.dataStart + 8, to: sourceFtyp.dataEnd, by: 4).compactMap { pos -> String? in
        guard pos + 4 <= sourceFtyp.dataEnd else { return nil }
        return String(data: source.subdata(in: pos..<pos + 4), encoding: .ascii)
    })
    for brand in ["tmap", "MiHE", "miaf", "MiHB"] where !existingBrands.contains(brand) {
        ftypPayload.append(Data(brand.utf8))
        existingBrands.insert(brand)
    }
    let ftypPart = makeBox("ftyp", payload: ftypPayload)
    var preliminaryMetaPayload = source.subdata(in: sourceMeta.dataStart..<sourceMeta.dataStart + 4)
    for part in metaParts {
        preliminaryMetaPayload.append(part)
    }
    let preliminaryMetaPart = makeBox("meta", payload: preliminaryMetaPayload)
    let betweenMetaAndMdat = source.subdata(in: sourceMeta.boxStart + sourceMeta.size..<sourceMdat.boxStart)
    let newMdatDataStart = ftypPart.count + preliminaryMetaPart.count + betweenMetaAndMdat.count + 8
    let fileDelta = newMdatDataStart - sourceMdat.dataStart

    var finalIlocEntries: [ISOBMFFILocEntry] = []
    for entry in keptSourceIlocEntries {
        let extents = try entry.extents.map { extent -> (offset: Int, length: Int) in
            if entry.constructionMethod == 0 {
                guard let adjusted = adjustedExtentForOppoUserCommentPatch(extent, patch: userCommentPatch) else {
                    throw CLIError.invalidContainer("OPPO UserComment patch crosses item extent boundary")
                }
                return (adjusted.offset + fileDelta, adjusted.length)
            }
            return extent
        }
        finalIlocEntries.append(ISOBMFFILocEntry(itemID: entry.itemID, constructionMethod: entry.constructionMethod, dataReferenceIndex: entry.dataReferenceIndex, extents: extents))
    }
    var appendedMdatPayload = Data()
    for tile in gainTilePayloads {
        let offset = newMdatDataStart + sourceMdatPayload.count + appendedMdatPayload.count
        appendedMdatPayload.append(tile.payload)
        finalIlocEntries.append(ISOBMFFILocEntry(itemID: tile.newID, constructionMethod: 0, dataReferenceIndex: 0, extents: [(offset, tile.payload.count)]))
    }
    finalIlocEntries.append(ISOBMFFILocEntry(itemID: outputGainGridID, constructionMethod: 1, dataReferenceIndex: 0, extents: [(gainGridIDATOffset, gainGridPayload.count)]))
    finalIlocEntries.append(ISOBMFFILocEntry(itemID: outputTmapID, constructionMethod: 1, dataReferenceIndex: 0, extents: [(tmapIDATOffset, tmapPayload.count)]))
    if let outputXMPID, let xmpPayload {
        finalIlocEntries.append(ISOBMFFILocEntry(itemID: outputXMPID, constructionMethod: 1, dataReferenceIndex: 0, extents: [(xmpIDATOffset, xmpPayload.count)]))
    }
    let finalIlocPart = makeIlocV1Box(entries: finalIlocEntries)
    let finalMetaParts = metaParts.map { part -> Data in
        if part.count >= 8, String(data: part.subdata(in: 4..<8), encoding: .ascii) == "iloc" {
            return finalIlocPart
        }
        return part
    }
    var finalMetaPayload = source.subdata(in: sourceMeta.dataStart..<sourceMeta.dataStart + 4)
    for part in finalMetaParts {
        finalMetaPayload.append(part)
    }
    let finalMetaPart = makeBox("meta", payload: finalMetaPayload)

    var mdatPayload = sourceMdatPayload
    mdatPayload.append(appendedMdatPayload)
    let mdatPart = makeBox("mdat", payload: mdatPayload)

    var out = Data()
    out.append(ftypPart)
    out.append(finalMetaPart)
    out.append(betweenMetaAndMdat)
    out.append(mdatPart)
    try out.write(to: outputURL)
}

private func writePrivateJPEGPassthroughOutput(
    inputURL: URL,
    outputURL: URL,
    infoFloats: [Double],
    gainMapJPEG: Data,
    patchedUserComment: String? = nil,
    tmapPayload: Data? = nil,
    tmapColorBox: Data? = nil
) throws -> (primaryID: Int, gainMapID: Int) {
    guard infoFloats.count >= 20 else {
        throw CLIError.invalidLHDR("local.uhdr.gainmap.info must contain at least 20 float32 values")
    }
    guard gainMapJPEG.starts(with: Data([0xff, 0xd8])) else {
        throw CLIError.invalidContainer("local.uhdr.gainmap.data is not a JPEG payload")
    }

    let src = try Data(contentsOf: inputURL)
    let top = isobmffBoxes(in: src, start: 0, end: src.count)
    guard let ftyp = top.first(where: { $0.type == "ftyp" }),
          let meta = top.first(where: { $0.type == "meta" }),
          let mdat = top.first(where: { $0.type == "mdat" }) else {
        throw CLIError.invalidContainer("missing ftyp/meta/mdat")
    }
    let metaChildren = isobmffBoxes(in: src, start: meta.dataStart + 4, end: meta.dataEnd)
    func child(_ type: String) throws -> ISOBMFFBox {
        guard let box = metaChildren.first(where: { $0.type == type }) else {
            throw CLIError.invalidContainer("meta/\(type) missing")
        }
        return box
    }

    let iinf = try child("iinf")
    let iloc = try child("iloc")
    let pitm = try child("pitm")
    let iprp = try child("iprp")
    let idat = try child("idat")
    let iref = metaChildren.first(where: { $0.type == "iref" })
    let primaryID = parseISOBMFFPITM(src, pitm)
    let iinfData = parseISOBMFFIInf(src, iinf)
    let ilocEntries = try parseISOBMFFILoc(src, iloc)
    let ipco = try parseISOBMFFIPCOProps(src, iprp)
    guard let ipmaBox = isobmffBoxes(in: src, start: iprp.dataStart, end: iprp.dataEnd).first(where: { $0.type == "ipma" }) else {
        throw CLIError.invalidContainer("ipma missing")
    }
    let ipma = parseISOBMFFIPMA(src, ipmaBox)
    let propMask = ipma.flags & 1 != 0 ? 0x7fff : 0x7f
    let primaryAssocs = ipma.entries.first(where: { $0.itemID == primaryID })?.associations ?? []
    let primaryPropIndices = primaryAssocs.map { $0 & propMask }
    guard let primaryIspeIndex = primaryPropIndices.first(where: { ipco.types[$0] == "ispe" }),
          ipco.sizes[primaryIspeIndex] != nil else {
        throw CLIError.invalidContainer("primary item has no ispe")
    }
    let primaryColrIndex = primaryPropIndices.first(where: { ipco.types[$0] == "colr" })
        ?? ipco.types.first(where: { $0.value == "colr" })?.key

    let gainMapSize = try jpegImageSize(gainMapJPEG)
    let maxItemID = iinfData.entries.keys.max() ?? primaryID
    let gainMapID = maxItemID + 1
    let tmapID = gainMapID + 1
    let xmpID = gainMapID + 2

    let oldPropCount = ipco.types.count
    let auxCIndex = oldPropCount + 1
    let irotIndex = oldPropCount + 2
    let srgbIndex = oldPropCount + 3
    let gmPixiIndex = oldPropCount + 4
    let tmapPixiIndex = oldPropCount + 5
    let gmIspeIndex = oldPropCount + 6
    let tmapOverrideColrIndex = tmapColorBox == nil ? nil : oldPropCount + 7
    let tmapColrIndex = tmapOverrideColrIndex ?? primaryColrIndex ?? srgbIndex
    let oldIDATSize = idat.size - 8
    let tmapPayload = tmapPayload ?? makeAppleTmapPayload(infoFloats: infoFloats)
    let xmpPayload = makeHdrgmXMP(infoFloats: infoFloats)
    var sourceMdatPayload = src.subdata(in: mdat.dataStart..<mdat.dataEnd)
    let userCommentPatch: OppoUserCommentPatch?
    if let patchedUserComment {
        guard let exifID = iinfData.entries.first(where: { $0.value == "Exif" })?.key,
              let exifEntry = ilocEntries.first(where: { $0.itemID == exifID }) else {
            throw CLIError.invalidContainer("unable to locate source Exif item for OPPO UserComment patch")
        }
        guard let patch = applyOppoUserCommentPatch(
            &sourceMdatPayload,
            mdatDataStart: mdat.dataStart,
            exifEntry: exifEntry,
            patchedUserComment: patchedUserComment
        ) else {
            throw CLIError.invalidContainer("unable to patch OPPO UserComment in UHDR pass-through output")
        }
        userCommentPatch = patch
    } else {
        userCommentPatch = nil
    }

    var metaParts: [Data] = []
    for part in metaChildren {
        switch part.type {
        case "hdlr":
            metaParts.append(src.subdata(in: part.boxStart..<part.boxStart + part.size))
            if !metaChildren.contains(where: { $0.type == "dinf" }) {
                metaParts.append(isoDinfBox)
            }
        case "pitm":
            var payload = Data([0, 0, 0, 0])
            appendUInt16BE(primaryID, to: &payload)
            metaParts.append(makeBox("pitm", payload: payload))
        case "iinf":
            var payload = Data([iinfData.version, 0, 0, 0])
            if iinfData.version >= 1 {
                appendUInt32BE(iinfData.rawInfe.count + 3, to: &payload)
            } else {
                appendUInt16BE(iinfData.rawInfe.count + 3, to: &payload)
            }
            for raw in iinfData.rawInfe.sorted(by: { $0.key < $1.key }).map(\.value) {
                payload.append(raw)
            }
            payload.append(makeInfeBox(itemID: gainMapID, type: "jpeg", flags: 1))
            payload.append(makeInfeBox(itemID: tmapID, type: "tmap"))
            payload.append(makeMimeInfeBox(itemID: xmpID))
            metaParts.append(makeBox("iinf", payload: payload))
        case "iloc":
            var payload = Data([1, 0, 0, 0, 0x44, 0x00])
            appendUInt16BE(ilocEntries.count + 3, to: &payload)
            for entry in ilocEntries {
                appendUInt16BE(entry.itemID, to: &payload)
                appendUInt16BE(entry.constructionMethod, to: &payload)
                appendUInt16BE(entry.dataReferenceIndex, to: &payload)
                appendUInt16BE(entry.extents.count, to: &payload)
                for extent in entry.extents {
                    appendUInt32BE(extent.offset, to: &payload)
                    appendUInt32BE(extent.length, to: &payload)
                }
            }
            appendUInt16BE(gainMapID, to: &payload); appendUInt16BE(0, to: &payload); appendUInt16BE(0, to: &payload); appendUInt16BE(1, to: &payload)
            appendUInt32BE(0, to: &payload); appendUInt32BE(gainMapJPEG.count, to: &payload)
            appendUInt16BE(tmapID, to: &payload); appendUInt16BE(1, to: &payload); appendUInt16BE(0, to: &payload); appendUInt16BE(1, to: &payload)
            appendUInt32BE(oldIDATSize, to: &payload); appendUInt32BE(tmapPayload.count, to: &payload)
            appendUInt16BE(xmpID, to: &payload); appendUInt16BE(1, to: &payload); appendUInt16BE(0, to: &payload); appendUInt16BE(1, to: &payload)
            appendUInt32BE(oldIDATSize + tmapPayload.count, to: &payload); appendUInt32BE(xmpPayload.count, to: &payload)
            metaParts.append(makeBox("iloc", payload: payload))
        case "iprp":
            var ipcoPayload = src.subdata(in: ipco.box.dataStart..<ipco.box.dataEnd)
            ipcoPayload.append(isoAuxCBox)
            ipcoPayload.append(isoIrotBox)
            ipcoPayload.append(isoColrSRGBBox)
            ipcoPayload.append(isoPixiRGB8Box)
            ipcoPayload.append(isoPixiRGB10Box)
            ipcoPayload.append(makeIspeBox(width: gainMapSize.0, height: gainMapSize.1))
            if let tmapColorBox {
                ipcoPayload.append(tmapColorBox)
            }
            let ipcoPart = makeBox("ipco", payload: ipcoPayload)

            var ipmaPayload = src.subdata(in: ipmaBox.dataStart..<ipmaBox.dataStart + 4)
            appendUInt32BE(ipma.entries.count + 2, to: &ipmaPayload)
            for entry in ipma.entries {
                if ipma.flags & 1 != 0 { appendUInt32BE(entry.itemID, to: &ipmaPayload) } else { appendUInt16BE(entry.itemID, to: &ipmaPayload) }
                var associations = entry.associations
                if entry.itemID == primaryID {
                    let rawIrot = (ipma.flags & 1 != 0 ? 0x8000 : 0x80) | irotIndex
                    if !associations.contains(where: { ($0 & propMask) == irotIndex }) {
                        associations.append(rawIrot)
                    }
                    if let primaryColrIndex,
                       !associations.contains(where: { ($0 & propMask) == primaryColrIndex }) {
                        let rawColr = (ipma.flags & 1 != 0 ? 0x8000 : 0x80) | primaryColrIndex
                        associations.append(rawColr)
                    }
                }
                ipmaPayload.append(UInt8(associations.count))
                for assoc in associations {
                    if ipma.flags & 1 != 0 { appendUInt16BE(assoc, to: &ipmaPayload) } else { ipmaPayload.append(UInt8(assoc)) }
                }
            }
            ipmaPayload.append(try makeIPMAEntry(gainMapID, [(gmIspeIndex, true), (gmPixiIndex, true), (srgbIndex, true), (irotIndex, true), (auxCIndex, true)], flags: ipma.flags))
            ipmaPayload.append(try makeIPMAEntry(tmapID, [(primaryIspeIndex, true), (tmapPixiIndex, true), (tmapColrIndex, true)], flags: ipma.flags))
            let ipmaPart = makeBox("ipma", payload: ipmaPayload)
            var iprpPayload = Data()
            iprpPayload.append(ipcoPart)
            iprpPayload.append(ipmaPart)
            metaParts.append(makeBox("iprp", payload: iprpPayload))
        case "iref":
            var payload = src.subdata(in: part.dataStart..<part.dataEnd)
            let version = parseISOBMFFIRefVersion(src, iref)
            payload.append(makeIrefBox(type: "dimg", from: tmapID, to: [primaryID, gainMapID], version: version))
            payload.append(makeIrefBox(type: "auxl", from: gainMapID, to: [primaryID, tmapID], version: version))
            payload.append(makeIrefBox(type: "cdsc", from: xmpID, to: [primaryID, tmapID], version: version))
            metaParts.append(makeBox("iref", payload: payload))
        case "idat":
            var payload = src.subdata(in: part.dataStart..<part.dataEnd)
            payload.append(tmapPayload)
            payload.append(xmpPayload)
            metaParts.append(makeBox("idat", payload: payload))
        default:
            metaParts.append(src.subdata(in: part.boxStart..<part.boxStart + part.size))
        }
    }

    if iref == nil {
        var payload = Data([0, 0, 0, 0])
        payload.append(makeIrefBox(type: "dimg", from: tmapID, to: [primaryID, gainMapID], version: 0))
        payload.append(makeIrefBox(type: "auxl", from: gainMapID, to: [primaryID, tmapID], version: 0))
        payload.append(makeIrefBox(type: "cdsc", from: xmpID, to: [primaryID, tmapID], version: 0))
        metaParts.append(makeBox("iref", payload: payload))
    }

    var grplPayload = Data()
    var altrPayload = Data([0, 0, 0, 0])
    appendUInt32BE(max(tmapID, xmpID) + 1, to: &altrPayload)
    appendUInt32BE(2, to: &altrPayload)
    appendUInt32BE(tmapID, to: &altrPayload)
    appendUInt32BE(primaryID, to: &altrPayload)
    grplPayload.append(makeBox("altr", payload: altrPayload))
    metaParts.append(makeBox("grpl", payload: grplPayload))

    var ftypPayload = src.subdata(in: ftyp.dataStart..<ftyp.dataEnd)
    let existingBrands = Set(stride(from: ftyp.dataStart + 8, to: ftyp.dataEnd, by: 4).compactMap { pos -> String? in
        guard pos + 4 <= ftyp.dataEnd else { return nil }
        return String(data: src.subdata(in: pos..<pos + 4), encoding: .ascii)
    })
    for brand in ["tmap", "MiHE", "MiHB"] where !existingBrands.contains(brand) {
        ftypPayload.append(Data(brand.utf8))
    }
    let ftypPart = makeBox("ftyp", payload: ftypPayload)
    var metaPayload = src.subdata(in: meta.dataStart..<meta.dataStart + 4)
    for part in metaParts { metaPayload.append(part) }
    let metaPart = makeBox("meta", payload: metaPayload)
    let betweenMetaAndMdat = src.subdata(in: meta.boxStart + meta.size..<mdat.boxStart)
    let newMdatDataStart = ftypPart.count + metaPart.count + betweenMetaAndMdat.count + 8
    let fileDelta = newMdatDataStart - mdat.dataStart
    let gainMapOffset = newMdatDataStart + sourceMdatPayload.count

    var ilocPayload = Data([1, 0, 0, 0, 0x44, 0x00])
    appendUInt16BE(ilocEntries.count + 3, to: &ilocPayload)
    for entry in ilocEntries {
        appendUInt16BE(entry.itemID, to: &ilocPayload)
        appendUInt16BE(entry.constructionMethod, to: &ilocPayload)
        appendUInt16BE(entry.dataReferenceIndex, to: &ilocPayload)
        appendUInt16BE(entry.extents.count, to: &ilocPayload)
        for extent in entry.extents {
            if entry.constructionMethod == 0 {
                guard let adjusted = adjustedExtentForOppoUserCommentPatch(extent, patch: userCommentPatch) else {
                    throw CLIError.invalidContainer("OPPO UserComment patch crosses item extent boundary")
                }
                appendUInt32BE(adjusted.offset + fileDelta, to: &ilocPayload)
                appendUInt32BE(adjusted.length, to: &ilocPayload)
            } else {
                appendUInt32BE(extent.offset, to: &ilocPayload)
                appendUInt32BE(extent.length, to: &ilocPayload)
            }
        }
    }
    appendUInt16BE(gainMapID, to: &ilocPayload); appendUInt16BE(0, to: &ilocPayload); appendUInt16BE(0, to: &ilocPayload); appendUInt16BE(1, to: &ilocPayload)
    appendUInt32BE(gainMapOffset, to: &ilocPayload); appendUInt32BE(gainMapJPEG.count, to: &ilocPayload)
    appendUInt16BE(tmapID, to: &ilocPayload); appendUInt16BE(1, to: &ilocPayload); appendUInt16BE(0, to: &ilocPayload); appendUInt16BE(1, to: &ilocPayload)
    appendUInt32BE(oldIDATSize, to: &ilocPayload); appendUInt32BE(tmapPayload.count, to: &ilocPayload)
    appendUInt16BE(xmpID, to: &ilocPayload); appendUInt16BE(1, to: &ilocPayload); appendUInt16BE(0, to: &ilocPayload); appendUInt16BE(1, to: &ilocPayload)
    appendUInt32BE(oldIDATSize + tmapPayload.count, to: &ilocPayload); appendUInt32BE(xmpPayload.count, to: &ilocPayload)
    let finalILoc = makeBox("iloc", payload: ilocPayload)
    let finalMetaParts = metaParts.map { part -> Data in
        if part.count >= 8, String(data: part.subdata(in: 4..<8), encoding: .ascii) == "iloc" {
            return finalILoc
        }
        return part
    }
    var finalMetaPayload = src.subdata(in: meta.dataStart..<meta.dataStart + 4)
    for part in finalMetaParts { finalMetaPayload.append(part) }
    let finalMetaPart = makeBox("meta", payload: finalMetaPayload)

    var mdatPayload = sourceMdatPayload
    mdatPayload.append(gainMapJPEG)
    let mdatPart = makeBox("mdat", payload: mdatPayload)
    var out = Data()
    out.append(ftypPart)
    out.append(finalMetaPart)
    out.append(betweenMetaAndMdat)
    out.append(mdatPart)
    try out.write(to: outputURL)
    return (primaryID, gainMapID)
}

private func makePrivateGainMapInfoFloats(scale: ResolvedScale) -> [Double] {
    var floats: [Float] = []
    for channel in 0..<3 {
        let gainMapMin = valueOrRepeated(scale.perChannelGainMapMin, index: channel, fallback: scale.gainMapMin)
        floats.append(Float(pow(2.0, gainMapMin)))
    }
    floats.append(1.0)
    for channel in 0..<3 {
        let gainMapMax = positiveValueOrFallback(scale.perChannelGainMapMax, index: channel, fallback: scale.gainMapMax)
        floats.append(Float(pow(2.0, gainMapMax)))
    }
    for channel in 0..<3 {
        floats.append(Float(valueOrRepeated(scale.perChannelGamma, index: channel, fallback: scale.gamma)))
    }
    for channel in 0..<3 {
        floats.append(Float(valueOrRepeated(scale.perChannelBaseOffset, index: channel, fallback: scale.epsilonSdr)))
    }
    for channel in 0..<3 {
        floats.append(Float(valueOrRepeated(scale.perChannelAlternateOffset, index: channel, fallback: scale.epsilonHdr)))
    }
    floats.append(Float(scale.displayRatioSdr))
    floats.append(Float(scale.displayRatioHdr))
    floats.append(Float(scale.scale))
    floats.append(0.0)

    return floats.map(Double.init)
}

private func ensureDirectory(_ url: URL, fileManager: FileManager) throws {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
            throw CLIError.outputParentIsNotDirectory(url)
        }
        return
    }
    do {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
        throw CLIError.unableToCreateDirectory(url)
    }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func clamp<T: Comparable>(_ value: T, min lower: T, max upper: T) -> T {
    Swift.min(Swift.max(value, lower), upper)
}

private func alignUp(_ value: Int, toMultipleOf multiple: Int) -> Int {
    guard multiple > 0 else { return value }
    let remainder = value % multiple
    return remainder == 0 ? value : value + (multiple - remainder)
}

private func round(_ value: Double, digits: Int) -> Double {
    let scale = pow(10.0, Double(digits))
    return (value * scale).rounded() / scale
}

private func safeLog2(_ value: Double) -> Double {
    guard value.isFinite, value > 0 else { return 0.0 }
    return log2(value)
}

private func buildFloatAudits(_ floats: [Double]) -> [FloatAuditEntry] {
    floats.enumerated().map { index, value in
        FloatAuditEntry(
            index: index,
            value: round(value, digits: 7),
            naturalLog: optionalLog(value).map { round($0, digits: 7) },
            log2: optionalLog2(value).map { round($0, digits: 7) },
            log10: optionalLog10(value).map { round($0, digits: 7) },
            square: round(value * value, digits: 7),
            sqrt: optionalSqrt(value).map { round($0, digits: 7) },
            reciprocal: optionalReciprocal(value).map { round($0, digits: 7) },
            exp: optionalExp(value).map { round($0, digits: 7) },
            exp2: optionalExp2(value).map { round($0, digits: 7) },
            cube: round(value * value * value, digits: 7),
            cubeRoot: round(realCubeRoot(value), digits: 7)
        )
    }
}

private func optionalLog(_ value: Double) -> Double? {
    guard value.isFinite, value > 0 else { return nil }
    return log(value)
}

private func optionalLog2(_ value: Double) -> Double? {
    guard value.isFinite, value > 0 else { return nil }
    return log2(value)
}

private func optionalLog10(_ value: Double) -> Double? {
    guard value.isFinite, value > 0 else { return nil }
    return log10(value)
}

private func optionalSqrt(_ value: Double) -> Double? {
    guard value.isFinite, value >= 0 else { return nil }
    return sqrt(value)
}

private func optionalReciprocal(_ value: Double) -> Double? {
    guard value.isFinite, value != 0 else { return nil }
    return 1.0 / value
}

private func optionalExp(_ value: Double) -> Double? {
    guard value.isFinite, value <= 700.0 else { return nil }
    return exp(value)
}

private func optionalExp2(_ value: Double) -> Double? {
    guard value.isFinite, value <= 1023.0 else { return nil }
    return exp2(value)
}

private func realCubeRoot(_ value: Double) -> Double {
    if value == 0 { return 0 }
    let magnitude = pow(abs(value), 1.0 / 3.0)
    return value < 0 ? -magnitude : magnitude
}

private func formatFloat(_ value: Double, digits: Int) -> String {
    String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value)
}

private func readUInt32BE(from data: Data, at offset: Int) throws -> UInt32 {
    guard offset >= 0, offset + 4 <= data.count else {
        throw CLIError.invalidLHDR("out-of-range uint32 read at \(offset)")
    }
    var value: UInt32 = 0
    _ = withUnsafeMutableBytes(of: &value) { buffer in
        data.subdata(in: offset..<(offset + 4)).copyBytes(to: buffer)
    }
    return UInt32(bigEndian: value)
}

private func unpack36FloatLE(_ data: Data) throws -> [Double] {
    try unpackFloatArrayLE(data, count: 36)
}

private func unpackFloatArrayLE(_ data: Data, count: Int) throws -> [Double] {
    guard data.count >= count * 4 else {
        throw CLIError.invalidLHDR("float payload shorter than expected \(count * 4) bytes")
    }

    var values: [Double] = []
    values.reserveCapacity(count)
    for index in 0..<count {
        let start = index * 4
        var bits: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &bits) { buffer in
            data.subdata(in: start..<(start + 4)).copyBytes(to: buffer)
        }
        bits = UInt32(littleEndian: bits)
        values.append(Double(Float(bitPattern: bits)))
    }
    return values
}

private func firstIndex(of needle: Data, in haystack: Data, startingAt start: Int = 0) -> Int? {
    guard !needle.isEmpty, start < haystack.count else { return nil }
    return haystack.range(of: needle, options: [], in: start..<haystack.count)?.lowerBound
}

private func firstIndex(of byte: UInt8, in haystack: Data, startingAt start: Int = 0) -> Int? {
    guard start < haystack.count else { return nil }
    return haystack[start..<haystack.count].firstIndex(of: byte)
}

private func lastIndex(of needle: Data, in haystack: Data) -> Int? {
    guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
    return haystack.range(of: needle, options: [.backwards], in: 0..<haystack.count)?.lowerBound
}

private struct PortraitFocusRegion {
    let rawX: Double
    let rawY: Double
    let rawWidth: Double
    let rawHeight: Double
}

private struct PortraitCameraCalibration {
    let profileName: String
    let renderingParametersBase64: String
    let physicalFocalLengthMM: Double
    let opticalEquivalentFocalLengthMM: Double
    let digitalZoomRatio: Double
    let referenceWidth: Int
    let referenceHeight: Int
    let focalLengthPixels: Double
    let effectiveFocalLengthPixels: Double
    let principalPointX: Double
    let principalPointY: Double
    let distortionCenterX: Double
    let distortionCenterY: Double
    let pixelSizeMM: Double
    let distortionCoefficients: [Double]
    let inverseDistortionCoefficients: [Double]

    var intrinsicMatrix: [Double] {
        [
            focalLengthPixels, 0, 0,
            0, focalLengthPixels, 0,
            principalPointX, principalPointY, 1,
        ]
    }
}

private struct PortraitAppleLensProfile {
    let name: String
    let anchorEquivalentFocalLengthMM: Double
    let maximumValidatedEquivalentFocalLengthMM: Double
    let referenceWidth: Int
    let referenceHeight: Int
    let focalLengthPixels: Double
    let principalPointX: Double
    let principalPointY: Double
    let distortionCenterX: Double
    let distortionCenterY: Double
    let pixelSizeMM: Double
    let distortionCoefficients: [Double]
    let inverseDistortionCoefficients: [Double]
    let renderingParametersBase64: String
}

private struct PortraitDepthHeader {
    let width: Int
    let height: Int
    let rankDisparityScale: Double
    let focalLengthPixels: Double
    let stereoBaseline: Double
}

private struct OPPODepthPlanes {
    let ranks: Data
    let hair: Data?
    let portrait: Data?
    let pet: Data?

    var subject: Data? {
        let candidates = [portrait, pet].compactMap { plane in
            plane.flatMap { $0.contains(where: { $0 != 0 }) ? $0 : nil }
        }
        guard var fused = candidates.first else { return nil }
        let pixelCount = fused.count
        for plane in candidates.dropFirst() {
            fused.withUnsafeMutableBytes { output in
                plane.withUnsafeBytes { input in
                    guard let outputBase = output.bindMemory(to: UInt8.self).baseAddress,
                          let inputBase = input.bindMemory(to: UInt8.self).baseAddress else { return }
                    for index in 0..<pixelCount {
                        outputBase[index] = max(outputBase[index], inputBase[index])
                    }
                }
            }
        }
        return fused
    }

    var validHair: Data? {
        hair.flatMap { $0.contains(where: { $0 != 0 }) ? $0 : nil }
    }
}

private enum PortraitConversionPipeline {
    static func isConvertibleInput(_ inputURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: inputURL.path),
              let inputData = try? Data(contentsOf: inputURL),
              let blocks = try? LHDRExtractor.portraitBlocks(from: inputData),
              let srcImage = blocks["src.image"],
              blocks["rear.depth"] != nil,
              blocks["rear.depth.config"] != nil,
              let firstEOI = srcImage.range(of: Data([0xff, 0xd9])),
              firstEOI.upperBound + 3 <= srcImage.count,
              srcImage[firstEOI.upperBound..<(firstEOI.upperBound + 3)] == Data([0xff, 0xd8, 0xff]),
              (try? resolveGainInfoFloats(
                  privateInfo: blocks["local.uhdr.gainmap.info"],
                  inputURL: inputURL
              )) != nil else {
            return false
        }
        return true
    }

    static func isValidOutput(_ outputURL: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
              CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                  source,
                  0,
                  kCGImageAuxiliaryDataTypeISOGainMap
              ) != nil,
              CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                  source,
                  0,
                  kCGImageAuxiliaryDataTypeDisparity
              ) != nil,
              CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                  source,
                  0,
                  kCGImageAuxiliaryDataTypePortraitEffectsMatte
              ) != nil else {
            return false
        }
        return true
    }

    static func convertIfNeeded(
        inputURL: URL,
        outputURL: URL,
        mode: PortraitMode
    ) throws -> Bool {
        guard mode != .off else { return false }
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw CLIError.inputNotFound(inputURL)
        }
        let inputData = try Data(contentsOf: inputURL)
        let hasPortraitUserComment = portraitUserCommentFlag(in: inputURL)
        let blocks: [String: Data]
        do {
            blocks = try LHDRExtractor.portraitBlocks(from: inputData)
        } catch {
            throw CLIError.invalidContainer(
                "--apple-portrait requires an OPPO private tail containing rear.depth"
            )
        }
        guard
              let srcImage = blocks["src.image"],
              let rearDepthConfig = blocks["rear.depth.config"],
              let compressedDepth = blocks["rear.depth"] else {
            throw CLIError.invalidContainer(
                "--apple-portrait requires OPPO portrait UserComment, src.image, and rear.depth"
            )
        }
        if !hasPortraitUserComment {
            print(
                "warning: portrait UserComment flag is absent; recovering from "
                    + "rear.depth + rear.depth.config + src.image"
            )
        }
        let infoFloats = try resolveGainInfoFloats(
            privateInfo: blocks["local.uhdr.gainmap.info"],
            inputURL: inputURL
        )
        guard let firstEOI = srcImage.range(of: Data([0xff, 0xd9])),
              firstEOI.upperBound + 3 <= srcImage.count,
              srcImage[firstEOI.upperBound..<(firstEOI.upperBound + 3)] == Data([0xff, 0xd8, 0xff]) else {
            throw CLIError.invalidContainer("portrait src.image does not contain adjacent base/gain JPEGs")
        }
        let baseJPEG = srcImage.subdata(in: 0..<firstEOI.upperBound)
        let gainJPEG = srcImage.subdata(in: firstEOI.upperBound..<srcImage.count)
        guard let baseSource = CGImageSourceCreateWithData(baseJPEG as CFData, nil),
              let baseImage = CGImageSourceCreateImageAtIndex(
                  baseSource,
                  0,
                  [kCGImageSourceShouldCache: true] as CFDictionary
              ) else {
            throw CLIError.invalidContainer("unable to decode portrait src.image base JPEG")
        }
        let baseProperties = CGImageSourceCopyPropertiesAtIndex(baseSource, 0, nil) as? [CFString: Any]
        let inputSource = CGImageSourceCreateWithURL(inputURL as CFURL, nil)
        let inputProperties = inputSource.flatMap {
            CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
        }
        let simulatedAperture = resolveSimulatedAperture(
            rearDepthConfig: rearDepthConfig,
            inputProperties: inputProperties,
            baseProperties: baseProperties
        )
        let afMeasuredDepth = readUInt32LE(rearDepthConfig, at: 296).flatMap { value in
            (1...100_000).contains(value) ? Int(value) : nil
        }
        if let afMeasuredDepth {
            print("portrait AF measured depth source=rear.depth.config distance=\(afMeasuredDepth)")
        }
        let inputOrientation = (inputProperties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
        let baseOrientation = (baseProperties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
        let inputWidth = (inputProperties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let inputHeight = (inputProperties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        let orientationRaw = resolvedBaseOrientation(
            inputWidth: inputWidth,
            inputHeight: inputHeight,
            inputOrientation: inputOrientation,
            baseWidth: baseImage.width,
            baseHeight: baseImage.height,
            baseOrientation: baseOrientation
        )
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up
        let decodedDepth = try decompressZstd(compressedDepth)
        let depthHeader = try parseDepthHeader(decodedDepth)
        let depthWidth = depthHeader.width
        let depthHeight = depthHeader.height
        let depthPlanes = try parseDepthPlanes(decodedDepth, header: depthHeader)
        let depthRanks = depthPlanes.ranks
        let focus = try makeFocusRegion(
            image: baseImage,
            orientation: orientation,
            orientationRaw: orientationRaw,
            rearDepthConfig: rearDepthConfig
        )
        let focusRank = robustFocusRank(
            ranks: depthRanks,
            subject: depthPlanes.subject,
            width: depthWidth,
            height: depthHeight,
            rawX: focus.rawX,
            rawY: focus.rawY
        )
        let effectiveDepthFocalLengthPixels = depthHeader.focalLengthPixels
            * Double(baseImage.width) / Double(depthWidth)
        let cameraCalibration = try makeCameraCalibration(
            inputProperties: inputProperties,
            baseProperties: baseProperties,
            baseWidth: baseImage.width,
            baseHeight: baseImage.height,
            effectiveFocalLengthPixels: effectiveDepthFocalLengthPixels
        )
        // rear.depth stores a relative rank map. Its header gives the disparity
        // delta per rank, so focal length must not be multiplied into the
        // disparity range a second time. Normalize rank 255 to zero; Photos
        // samples the disparity at the Focus XMP region as the relative anchor.
        let disparityFar = 0.0
        let disparityScale = depthHeader.rankDisparityScale
        let disparitySpan = 255.0 * disparityScale
        let disparityNear = disparityFar + disparitySpan
        let focusDisparity = disparityFar + (255.0 - focusRank) * disparityScale
        print(String(
            format: "portrait disparity header=%dx%d fxDepth=%.3f effectiveFx=%.3f rankScale=%.7f baseline=%.3f focusRank=%.3f focusDisparity=%.6f range=%.6f...%.6f fullSpan=%.6f",
            depthHeader.width,
            depthHeader.height,
            depthHeader.focalLengthPixels,
            effectiveDepthFocalLengthPixels,
            depthHeader.rankDisparityScale,
            depthHeader.stereoBaseline,
            focusRank,
            focusDisparity,
            disparityFar,
            disparityNear,
            disparitySpan
        ))

        let parent = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let stem = outputURL.deletingPathExtension().lastPathComponent
        let carrier = parent.appendingPathComponent(".\(stem).portrait-carrier-\(UUID().uuidString).heic")
        let privateIntermediate = parent.appendingPathComponent(".\(stem).portrait-private-\(UUID().uuidString).heic")
        let firstAssembly = parent.appendingPathComponent(".\(stem).portrait-first-\(UUID().uuidString).heic")
        let scaffold = parent.appendingPathComponent(".\(stem).portrait-scaffold-\(UUID().uuidString).heic")
        defer {
            for url in [carrier, privateIntermediate, firstAssembly, scaffold] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        guard let carrierDestination = CGImageDestinationCreateWithURL(
            carrier as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw CLIError.unableToCreateDestination(carrier)
        }
        CGImageDestinationAddImageFromSource(
            carrierDestination,
            baseSource,
            0,
            [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary
        )
        guard CGImageDestinationFinalize(carrierDestination) else {
            throw CLIError.unableToFinalizeDestination(carrier)
        }
        _ = try writePrivateJPEGPassthroughOutput(
            inputURL: carrier,
            outputURL: privateIntermediate,
            infoFloats: infoFloats,
            gainMapJPEG: gainJPEG,
            patchedUserComment: nil
        )
        try ISOHDRWriter.writeWithPreserveReencode(
            intermediateURL: privateIntermediate,
            outputURL: firstAssembly
        )

        guard let firstSource = CGImageSourceCreateWithURL(firstAssembly as CFURL, nil),
              CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                  firstSource,
                  0,
                  kCGImageAuxiliaryDataTypeISOGainMap
              ) != nil else {
            throw CLIError.outputVerificationFailed(firstAssembly)
        }
        let depthDictionary = try makeDepthDictionary(
            ranks: depthRanks,
            width: depthWidth,
            height: depthHeight,
            orientation: orientationRaw,
            far: Float(disparityFar),
            near: Float(disparityNear),
            calibration: cameraCalibration,
            simulatedAperture: simulatedAperture.value
        )
        let mattes = try makePortraitEffectsMattes(
            image: baseImage,
            orientation: orientation,
            orientationRaw: orientationRaw,
            depthPlanes: depthPlanes,
            planeWidth: depthWidth,
            planeHeight: depthHeight
        )
        try writeBlankPortraitScaffold(
            sourceMetadataURL: inputURL,
            baseWidth: baseImage.width,
            baseHeight: baseImage.height,
            baseColorSpace: baseImage.colorSpace,
            orientation: orientationRaw,
            focus: focus,
            afMeasuredDepth: afMeasuredDepth,
            captureDate: captureDateString(sourceURL: inputURL),
            gainJPEG: gainJPEG,
            infoFloats: infoFloats,
            depthDictionary: depthDictionary,
            matteDictionary: mattes.portrait,
            hairDictionary: mattes.hair,
            outputURL: scaffold
        )
        try transplantPortraitBaseAndGainPayloads(
            payloadSourceURL: firstAssembly,
            scaffoldURL: scaffold,
            outputURL: outputURL
        )
        return true
    }

    private static let portraitRenderingParametersTemplateBase64 = """
    UkVORAcAAABIBQAAAQAAAGQAAgAAAAAAZQACAAIAAABmAAEAj8L1PGcAAQDNzMw9aAABAArXIz1pAAEAMzOzP2oAAQDNzEw9awABAJqZmT5sAAEAzczMP20AAQAAAABAbgACABQAAABvAAEAzcxMPXAAAQBYOTQ8cQABAArXIzxyAAEAzczMPXMAAQAK1yM9dAABAAAAgD91AAEAAABAP3YAAQBmZmY/dwABAJqZmT94AAEAAAAAQHkAAQDNzMw+egABAM3MzD17AAEAAACAP3wAAQAAAABAfQABAAAAAEF+AAEAF7fROH8AAgAyAAAAgAABAAAAgD/IAAEAPQoXP8kAAQAAAEA/ygABAPfMEjksAQEACtcjPC0BAQAXSJI5LgEBADVeuj0vAQEAMzOzPzABAQDgLRA7MQEBAFoMQzoyAQEAAACAPzMBAQAAAIA/kAECABkAAACRAQEAz3P8PZIBAQDbVr1AkwEBAM9z/D2UAQEAQmBlO5UBAQCZuxY8lgEBAGZmZj+XAQEAAACAP5gBAQAAAAAAmQEBAM3MTD7CAQEAz3N8QMMBAQBhyB1BxAEBALB4lz7FAQEADM6PQMYBAQAzM5tA8gECAAkAAADzAQIADAAAAPQBAgAJAAAA9QEBAAAAekT2AQEAmpkZPvcBAQBSuJ4++AEBAAAAAED5AQEAAMAPRfoBAQDNzEw9+wEBADMzsz78AQIAAgAAAP0BAQCamZk+/gEBAAAAoD//AQEAZmZmPwACAgAGAAAAAQIBAAAAgD8CAgEAAAAAAFgCAQAzMzNAWQIBADMzsz9aAgEAAACAQVsCAQB02qA/vAIBAAAAAAC9AgEAAAAAACADAgADAAAAIQMBAM3MTL0iAwEACtejPCMDAQDNzEy9JAMBAI/C9T2EAwEAzcxMP4UDAQAAAIA/hgMBAAAAAACHAwEAAAAAAIgDAQDNzMw+iQMBAOAtkDroAwEAmpmZPukDAQAAAKBA6gMBAJqZmT7rAwEAzcxMP+wDAQAAAAAA7QMBAAAAgD/uAwEAMzMzv+8DAQBmZmY/8AMBAI/C9TzxAwEAbxKDOvIDAQAAAAAA8wMCAIcAAAD0AwEAzczMPvUDAQAAAIA/9gMCABQAAAD3AwEAzczMPvgDAQAAAAAA+QMBAM3MTD/6AwEAAACAP/sDAQAAAAAA/AMBAM3MTD79AwEAAAAAAP4DAQAAAAAA/wMBAM3MzD8ABAIAAgAAAAEEAQAAAAAAAgQBAG8SAzoDBAEAmplZPwQEAQAAAAAABQQBAAAAgD8GBAEAzcxMPwcEAQCamZk+CAQBAAAAAEAJBAEAexQuPgoEAQAzM7M+CwQBAAAAgD8MBAEAAAAAAA0EAQCamZk+DgQBAM3MzD0PBAEAzcxMPkwEAQBmZuY+TQQBAAAAAABOBAEAAAAAAE8EAQDNzMw9UAQBAGZmZj+wBAIACQAAALEEAgAEAAAAsgQCAAwAAACzBAEAAACAP7QEAQAAAIA/tQQBANej8D62BAEAFK5HP7cEAQAAAADAuAQBAAAAAAC5BAEAAACAv7oEAQCamRk+uwQBAM3MzD28BAEAmpmZP70EAQBcj8I+vgQCAAQAAAAUBQEAAACAPhUFAQC/fV0+FgUBAArXIzwXBQEAj8L1PBgFAQAzM3M/GQUBAKabRD0aBQEAF7fRORsFAQBfKUs7HAUBAPYoHD8dBQEACtejPB4FAQAK1yM8HwUBAGZmJkAgBQEAAABAPyEFAQBsCfk6IgUBAI/C9TwjBQEAZmZmPyQFAQCamZk+JQUBAAAAwD8=
    """.trimmingCharacters(in: .whitespacesAndNewlines)

    private static let portraitRenderingParameters2xBase64 = """
    UkVORAcAAABIBQAAAQAAAGQAAgAAAAAAZQACAAIAAABmAAEAj8L1PGcAAQDNzMw9aAABAArXIz1pAAEAMzOzP2oAAQDNzEw9awABAJqZmT5sAAEAAADAP20AAQBiEChAbgACABQAAABvAAEAzcxMPXAAAQDNzMw8cQABAArXIzxyAAEAzczMPXMAAQDNzMw9dAABAAAAgD91AAEAAABAP3YAAQBmZmY/dwABAJqZmT94AAEAAAAAQHkAAQDNzMw+egABAM3MzD17AAEAAACAP3wAAQAAAABAfQABAAAAAEF+AAEAF7fROH8AAgAyAAAAgAABAAAAgD/IAAEA7FG4PckAAQCamVk/ygABABe3UTksAQEACtcjPC0BAQAXSJI5LgEBADVeuj0vAQEAMzOzPzABAQDgLRA7MQEBAFoMQzoyAQEAAACAPzMBAQAAAIA/kAECABUAAACRAQEAd+jVPZIBAQBZbqBAkwEBAF8gKz2UAQEACtcjO5UBAQCPwvU7lgEBAGZmZj+XAQEAAACAP5gBAQAAAAAAmQEBAM3MTD7CAQEALH8ZQMMBAQDPptxAxAEBAD3lVj7FAQEAg7M3QMYBAQAAADBB8gECAAkAAADzAQIADAAAAPQBAgAJAAAA9QEBAAAAekT2AQEAAAAAAPcBAQBSuJ4++AEBAAAAAED5AQEAAACWQ/oBAQDNzEw9+wEBAM3MzD78AQIAAgAAAP0BAQAAAIA+/gEBAAAAwD//AQEAMzNzPwACAgAHAAAAAQIBAAAAgD8CAgEAAAAAAFgCAQAAAJBAWQIBADMzsz9aAgEAAACAQVsCAQAAAIA/vAIBAAAAAAC9AgEAAAAAACADAgADAAAAIQMBAM3MTL0iAwEACtejPCMDAQDNzEy9JAMBAI/C9T2EAwEAzcxMP4UDAQAAAIA/hgMBAAAAAACHAwEAAAAAAIgDAQDNzMw+iQMBAAAAAADoAwEAmpmZPukDAQAAAKBA6gMBAJqZmT7rAwEAzcxMP+wDAQAAAAAA7QMBAAAAgD/uAwEAMzMzv+8DAQBmZmY/8AMBAAAAAADxAwEAAAAAAPIDAQAAAAAA8wMCAFoAAAD0AwEAzczMPvUDAQDNzEw+9gMCABQAAAD3AwEAzczMPvgDAQAAAAAA+QMBAM3MTD/6AwEAAACAP/sDAQAAAAAA/AMBAM3MTD79AwEAAAAAAP4DAQAAAAAA/wMBAJqZmT4ABAIAAgAAAAEEAQAAAAAAAgQBAG8SAzoDBAEAAACAPwQEAQAAAAAABQQBAAAAgD8GBAEAzcxMPwcEAQCamZk+CAQBAAAAIEAJBAEAzczMPQoEAQAzM7M+CwQBAAAAgD8MBAEAAAAAAA0EAQCamZk+DgQBAM3MzD0PBAEAmpkZPkwEAQAAAAA/TQQBAAAAAABOBAEAAAAAAE8EAQDNzEw+UAQBAM3MTD+wBAIACQAAALEEAgAEAAAAsgQCAAwAAACzBAEAAACAP7QEAQAAAIA/tQQBAAAAAD+2BAEAzcxMP7cEAQAAAADAuAQBAAAAAAC5BAEAAACAv7oEAQCamRk+uwQBAM3MTD68BAEAmpmZP70EAQCamRk/vgQCAAEAAAAUBQEAzcxMPhUFAQDsUTg+FgUBAArXIz0XBQEAcT2KPhgFAQBmZmY/GQUBAI/C9TwaBQEAbxKDOhsFAQAXt9E4HAUBAM3MDD8dBQEAJUmSOx4FAQAAAIA+HwUBAGZmJkAgBQEAAABAPyEFAQBvEoM6IgUBAAAAAAAjBQEAZmZmPyQFAQDD9ag+JQUBAAAAwD8=
    """.trimmingCharacters(in: .whitespacesAndNewlines)

    private static let portraitRenderingParameters3xBase64 = """
    UkVORAcAAABIBQAAAQAAAGQAAgAAAAAAZQACAAIAAABmAAEAj8L1PGcAAQDn+6k9aAABAM3MTD1pAAEAMzOzP2oAAQDNzEw9awABAJqZmT5sAAEAAAAAP20AAQAAAChAbgACABQAAABvAAEAzcxMPXAAAQDNzMw8cQABAArXIzxyAAEAzczMPXMAAQDNzMw9dAABAM3MzD51AAEAAABAP3YAAQBmZmY/dwABAJqZmT94AAEAAAAAQHkAAQDNzMw+egABAM3MzD17AAEAAACAP3wAAQAAAABAfQABAAAAAEF+AAEAF7fROH8AAgAyAAAAgAABAAAAgD/IAAEAKVyPPckAAQCamVk/ygABABe3UTksAQEACtcjPC0BAQAXSJI5LgEBADVeuj0vAQEAMzOzPzABAQDgLRA7MQEBAFoMQzoyAQEAAACAPzMBAQAAAIA/kAECADIAAACRAQEAAACAPpIBAQAAAEBBkwEBAM3MzD2UAQEACtcjO5UBAQCPwvU7lgEBAGZmZj+XAQEAAACAP5gBAQAAAAAAmQEBAM3MTD7CAQEAL7DJQMMBAQCi9pBBxAEBAIcuDT/FAQEAL7BJQMYBAQAAACBB8gECAAkAAADzAQIADAAAAPQBAgAJAAAA9QEBAAAAekT2AQEAAAAAAPcBAQBSuJ4++AEBAAAAAED5AQEAAACWQ/oBAQDNzEw9+wEBAM3MzD78AQIAAgAAAP0BAQAAAIA+/gEBAAAAwD//AQEAZmZmPwACAgAHAAAAAQIBAAAAgD8CAgEAAAAAAFgCAQAAAJBAWQIBADMzsz9aAgEAAACAQVsCAQCTGIQ/vAIBAAAAAAC9AgEAAAAAACADAgADAAAAIQMBAM3MTL0iAwEACtejPCMDAQDNzEy9JAMBAI/C9T2EAwEAzcxMP4UDAQAAAIA/hgMBAAAAAACHAwEAAAAAAIgDAQDNzMw+iQMBAAAAAADoAwEAmpmZPukDAQAAAKBA6gMBAJqZmT7rAwEAzcxMP+wDAQAAAIA/7QMBAAAAgD/uAwEAMzMzv+8DAQBmZmY/8AMBAG8SgzrxAwEAAAAAAPIDAQAAAAAA8wMCAMgAAAD0AwEAzczMPvUDAQAAAIA/9gMCABQAAAD3AwEAzczMPvgDAQAAAAAA+QMBAM3MTD/6AwEAAACAP/sDAQAAAAAA/AMBAM3MTD79AwEAAAAAAP4DAQAAAAAA/wMBAJqZmT4ABAIAAgAAAAEEAQAAAAAAAgQBAG8SAzoDBAEAAACAPwQEAQAAAAAABQQBAAAAgD8GBAEAzcxMPwcEAQCamZk+CAQBAM3MDEAJBAEAzczMPQoEAQBcjwI/CwQBAAAAgD8MBAEAzcxMPg0EAQDNzEw+DgQBAM3MTD4PBAEAAAAAP0wEAQAAAAA/TQQBAAAAAABOBAEAAAAAAE8EAQDNzEw+UAQBAM3MTD+wBAIACQAAALEEAgAEAAAAsgQCAAwAAACzBAEAAACAP7QEAQAAAIA/tQQBAJqZGT+2BAEAPQpXP7cEAQAAAADAuAQBAAAAAAC5BAEAAACAv7oEAQC4HgU+uwQBAPLSTT68BAEAmpmZP70EAQAAAAAAvgQCAAAAAAAUBQEAKVyPPhUFAQApXI8+FgUBAClcDz0XBQEACtejPBgFAQAzM3M/GQUBAClcDz0aBQEApptEOxsFAQAxDMM6HAUBAM3MzD4dBQEAJUmSOx4FAQAK1yM9HwUBAAAAQEAgBQEA16MwPyEFAQAgCAI7IgUBAAAAAAAjBQEAj8I1PyQFAQDD9ag+JQUBAAAAwD8=
    """.trimmingCharacters(in: .whitespacesAndNewlines)

    private static let portraitRenderingParameters5xBase64 = """
    UkVORAcAAABIBQAAAQAAAGQAAgAAAAAAZQACAAIAAABmAAEAj8L1PGcAAQDn+6k9aAABAM3MTD1pAAEAMzOzP2oAAQDNzEw9awABAJqZmT5sAAEAAAAAP20AAQAAAChAbgACABQAAABvAAEAzcxMPXAAAQDNzMw8cQABAArXIzxyAAEAzczMPXMAAQDNzMw9dAABAM3MzD51AAEAAABAP3YAAQBmZmY/dwABAJqZmT94AAEAAAAAQHkAAQDNzMw+egABAM3MzD17AAEAAACAP3wAAQAAAABAfQABAAAAAEF+AAEAF7fROH8AAgAyAAAAgAABAAAAgD/IAAEAKVyPPckAAQCamVk/ygABABe3UTksAQEACtcjPC0BAQAXSJI5LgEBADVeuj0vAQEAMzOzPzABAQDgLRA7MQEBAFoMQzoyAQEAAACAPzMBAQAAAIA/kAECABAAAACRAQEA32WjPZIBAQDOGHVAkwEBAOa3Aj2UAQEACtcjO5UBAQCPwvU7lgEBAGZmZj+XAQEAAACAP5gBAQAAAAAAmQEBAM3MTD7CAQEA7Z3rP8MBAQCCWalAxAEBAIzuJD7FAQEA35I4QMYBAQAAACBB8gECAAkAAADzAQIADAAAAPQBAgAJAAAA9QEBAAAAekT2AQEAAAAAAPcBAQBSuJ4++AEBAAAAAED5AQEAAACWQ/oBAQDNzEw9+wEBAM3MzD78AQIAAgAAAP0BAQApXI8+/gEBAAAAwD//AQEAZmZmPwACAgAHAAAAAQIBAAAAgD8CAgEAAAAAAFgCAQAAAJBAWQIBADMzsz9aAgEAAACAQVsCAQC4HoU/vAIBAAAAAAC9AgEAAAAAACADAgADAAAAIQMBAM3MTL0iAwEACtejPCMDAQDNzEy9JAMBAI/C9T2EAwEAzcxMP4UDAQAAAIA/hgMBAArXIzyHAwEAAAAAAIgDAQDNzMw+iQMBAFg5NDzoAwEAmpmZPukDAQAAAKBA6gMBAJqZmT7rAwEAzcxMP+wDAQAAAIA/7QMBAAAAgD/uAwEAMzMzv+8DAQBmZmY/8AMBAFg5NDzxAwEAAAAAAPIDAQAAAAAA8wMCAMgAAAD0AwEAmpkZP/UDAQCamZk/9gMCABQAAAD3AwEAzczMPvgDAQAAAAAA+QMBAM3MTD/6AwEAAACAP/sDAQAAAAAA/AMBAM3MTD79AwEAAAAAAP4DAQAAAAAA/wMBAJqZmT4ABAIAAgAAAAEEAQAAAAAAAgQBAG8SAzoDBAEAAACAPwQEAQAAAAAABQQBAAAAgD8GBAEAexRuPwcEAQDNzMw+CAQBAGZmBkAJBAEAmpkZPgoEAQDNzAw/CwQBAAAAgD8MBAEAAACAPg0EAQDNzEw+DgQBAM3MzD0PBAEAMzOzPkwEAQAAAAA/TQQBAAAAAABOBAEAAAAAAE8EAQDNzEw+UAQBAM3MTD+wBAIACQAAALEEAgAEAAAAsgQCAAwAAACzBAEAAACAP7QEAQAAAIA/tQQBAJqZGT+2BAEAPQpXP7cEAQAAAADAuAQBAAAAAAC5BAEAAACAv7oEAQC4HgU+uwQBAPLSTT68BAEAmpmZP70EAQAAAAAAvgQCAAAAAAAUBQEAexSuPhUFAQDwp4Y+FgUBAG8SAz0XBQEACtcjPBgFAQAfhWs/GQUBAG8SAz0aBQEAbxKDOhsFAQAxDMM6HAUBADMzsz4dBQEAF7fROx4FAQCPwnU9HwUBAJqZeUAgBQEAhetRPyEFAQCmm0Q7IgUBAAAAAAAjBQEA4XoUPyQFAQDD9ag+JQUBAAAAwD8=
    """.trimmingCharacters(in: .whitespacesAndNewlines)

    private static func validatedRenderingParametersBase64(_ encoded: String) throws -> String {
        guard let data = Data(base64Encoded: encoded),
              data.count >= 24,
              data.prefix(4) == Data("REND".utf8) else {
            throw CLIError.invalidContainer("invalid portrait REND compatibility template")
        }
        // REND is a lens-coupled compatibility profile. The current aperture is
        // carried by depthBlurEffect:SimulatedAperture and Photos adjustment
        // data; record 0x012f is not the per-edit aperture control.
        return data.base64EncodedString()
    }

    private static func portraitUserCommentFlag(in url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let comment = exif[kCGImagePropertyExifUserComment] as? String,
              let underscore = comment.lastIndex(of: "_"),
              let value = UInt64(comment[comment.index(after: underscore)...]) else {
            return false
        }
        return value & 65_536 != 0
    }

    private static func decompressZstd(_ data: Data) throws -> Data {
        let directory = FileManager.default.temporaryDirectory
        let input = directory.appendingPathComponent("xdremux-depth-\(UUID().uuidString).zst")
        defer { try? FileManager.default.removeItem(at: input) }
        try data.write(to: input, options: .atomic)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["zstd", "-d", "-q", "-c", input.path]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch {
            throw CLIError.invalidContainer("--apple-portrait requires the zstd command-line tool")
        }
        let decoded = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "zstd failed"
            throw CLIError.invalidContainer(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return decoded
    }

    private static func registerMetadataNamespace(
        _ metadata: CGMutableImageMetadata,
        namespace: String,
        prefix: String
    ) throws {
        var error: Unmanaged<CFError>?
        guard CGImageMetadataRegisterNamespaceForPrefix(
            metadata,
            namespace as CFString,
            prefix as CFString,
            &error
        ) else {
            if let error { throw error.takeRetainedValue() as Error }
            throw CLIError.invalidContainer("unable to register metadata namespace \(prefix)")
        }
    }

    private static func setMetadata(
        _ metadata: CGMutableImageMetadata,
        path: String,
        value: String
    ) throws {
        try setMetadataValue(metadata, path: path, value: value as CFString)
    }

    private static func setMetadataValue(
        _ metadata: CGMutableImageMetadata,
        path: String,
        value: CFTypeRef
    ) throws {
        guard CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value) else {
            throw CLIError.invalidContainer("unable to set metadata \(path)")
        }
    }

    private static func makeFocusMetadata(
        width: Int,
        height: Int,
        focus: PortraitFocusRegion,
        captureDate: String?
    ) throws -> CGImageMetadata {
        let date = captureDate ?? "1970-01-01T00:00:00"
        let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XDRemux">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:mwg-rs="http://www.metadataworkinggroup.com/schemas/regions/" xmlns:stArea="http://ns.adobe.com/xmp/sType/Area#" xmlns:stDim="http://ns.adobe.com/xap/1.0/sType/Dimensions#">
              <mwg-rs:Regions rdf:parseType="Resource"><mwg-rs:AppliedToDimensions rdf:parseType="Resource"><stDim:h>\(height)</stDim:h><stDim:unit>pixel</stDim:unit><stDim:w>\(width)</stDim:w></mwg-rs:AppliedToDimensions><mwg-rs:RegionList><rdf:Bag><rdf:li rdf:parseType="Resource"><mwg-rs:Area rdf:parseType="Resource"><stArea:h>\(focus.rawHeight)</stArea:h><stArea:unit>normalized</stArea:unit><stArea:w>\(focus.rawWidth)</stArea:w><stArea:x>\(focus.rawX)</stArea:x><stArea:y>\(focus.rawY)</stArea:y></mwg-rs:Area><mwg-rs:Type>Focus</mwg-rs:Type></rdf:li></rdf:Bag></mwg-rs:RegionList></mwg-rs:Regions>
            </rdf:Description>
            <rdf:Description rdf:about="" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"><photoshop:DateCreated>\(date)</photoshop:DateCreated></rdf:Description>
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"><xmp:CreateDate>\(date)</xmp:CreateDate><xmp:CreatorTool>XDRemux</xmp:CreatorTool><xmp:ModifyDate>\(date)</xmp:ModifyDate></rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        guard let metadata = CGImageMetadataCreateFromXMPData(Data(xmp.utf8) as CFData) else {
            throw CLIError.invalidContainer("unable to create Focus XMP metadata")
        }
        return metadata
    }

    private static func portraitMakerAppleDictionary(
        afMeasuredDepth: Int?
    ) -> [String: Any] {
        let makerData = Data(base64Encoded: "ywG5Ap4DpQAaADIALQA1AHEAmgDXAA4ACQAJAA4AOwDMABgBkQFqAEMANQApAB4AEgCJAHIACwAJAAkAHQBBAGoByAEfAnYASQBZAJUAnwBcAJMAFgAJAAkADAAzAEUAUAGbAdIBngCgAKMAnADKAFcAsAARAAoACQAQAE8AVwCnAdgBGQIuAuQBRAHYANMAZgB0ABwACwALACUAcABvACwCKwJuAoMCjQJZAdAAKQIIApYB7wBEABcAVQCYAJEAgwKAAskC0QLBAnwCwAEdAZQABQKCAawAjgC4ANIAvwB6AskCHAMLA90CGQKaAuIBiwAWAQ4B7AAJATMBIQH6AFkCyAI6A+sC9AH4APMBzQFfAa8AbAGeAEwBmwFyATsBDwI9AXcCHQELAQ8BiQFcAnoB+ADTAVMBgwEdAswBbQFPATwB5gEPAQoBJwFCAc0CTAG7AO0BKgHtAOsCTQJ3AegBvwE7AyQC3ABEAQ8BiQJ5AccAlQH5AJoA2wH2AGQADQILA0MDHQNlAWMBHgEHAXwBSAGsAQ0BPgHrACEACwDTAf0CSgMBA9ACYAHGAFwArABjAbQBAgE9AggBFAALAGwCMQNiA9MCugI7AZsAbADqADkByAGPAbwBfQL/Ad4AMwOaA8QDzALhAgUBmgDEAJ8A7QA7Ai8CfQEuAvMBEQE=") ?? Data()
        let captureTime = CMTime(
            value: 411_546_020_942_750,
            timescale: 1_000_000_000,
            flags: .valid,
            epoch: 0
        )
        var dictionary: [String: Any] = [
            "1": 17, "2": makerData, "3": NSValue(time: captureTime), "4": 0,
            "5": 184, "6": 174, "7": 1,
            "8": [-0.0013844214845448732, -0.8983764052391052, -0.45038747787475586],
            "12": [1.91015625, 0.4296875], "13": 1, "14": 0, "16": 1,
            "20": 12, "23": 8_595_224_612, "25": 139_298, "26": "q750n",
            "29": 0.012993750162422657, "31": 1,
            "32": "6197861E-6AE0-4B35-93B3-DA292CE0554D", "33": 1.0099999904632568,
            "35": [44, 268_435_504], "37": 11_538_574, "38": 3,
            "39": 41.253238677978516, "43": "C227536D-2A43-4CA3-97CC-083900DFCD56",
            "45": 3800, "46": 1, "47": 111, "48": 0.4457031190395355,
            "54": 784, "55": 8, "56": 38, "57": 2, "58": 128, "59": 0,
            "60": 4, "61": 66, "63": 0,
            "64": ["0": 1, "1": 0, "2": 0, "3": 0],
            "65": 0, "66": 0, "67": 0, "68": 0, "69": 0, "70": 0,
            "72": 0, "73": 0, "74": 2, "77": 32.507781982421875,
            "78": ["1": 3, "2": [["2.1": 2001.9581298828125, "2.2": 309], ["2.1": 0, "2.2": 70]]],
            "79": 0, "82": 0, "83": 2, "85": 0, "88": 2051,
            "96": 4037, "97": 24,
        ]
        if let afMeasuredDepth {
            // Apple MakerNote tag 56 is AFMeasuredDepth. Controlled matched
            // 2x/3x captures show it tracks OPPO rear.depth.config.distance in
            // the same scene-distance domain; keep the Apple trigger graph but
            // replace the fixed donor value with the source capture value.
            dictionary["56"] = afMeasuredDepth
        }
        return dictionary
    }

    private static func appleLensProfile(
        physicalFocalLengthMM: Double,
        equivalentFocalLengthMM: Double
    ) -> PortraitAppleLensProfile {
        if physicalFocalLengthMM <= 11 {
            // Apple keeps its 1x main-camera profile through the intermediate
            // crop range, then changes to the 2x/Fusion renderer near 48mm.
            if equivalentFocalLengthMM < 45 {
                return PortraitAppleLensProfile(
                    name: "Apple-1x-main-24mm",
                    anchorEquivalentFocalLengthMM: 24,
                    maximumValidatedEquivalentFocalLengthMM: 44,
                    referenceWidth: 4032,
                    referenceHeight: 3024,
                    focalLengthPixels: 2860.37890625,
                    principalPointX: 2010.31103515625,
                    principalPointY: 1525.0140380859375,
                    distortionCenterX: 2017.552734375,
                    distortionCenterY: 1523.492919921875,
                    pixelSizeMM: 0.002440,
                    distortionCoefficients: [
                        0, -0.5552194714546204, 0.053949449211359024,
                        -0.0018901334842666984, -0.000004621016614692053,
                        0.0000019594019704527454, -0.0000000451839099468998,
                        0.00000000031430857916348032,
                    ],
                    inverseDistortionCoefficients: [
                        0, 0.5448748469352722, -0.05080728605389595,
                        0.0016805990599095821, 0.000007370583261945285,
                        -0.0000017933325580088422, 0.00000003959269534448139,
                        -0.0000000002689144740219973,
                    ],
                    renderingParametersBase64: portraitRenderingParametersTemplateBase64
                )
            }
            return PortraitAppleLensProfile(
                name: "Apple-2x-fusion-48mm",
                anchorEquivalentFocalLengthMM: 48,
                maximumValidatedEquivalentFocalLengthMM: 59,
                referenceWidth: 4032,
                referenceHeight: 3024,
                focalLengthPixels: 5666.13037109375,
                principalPointX: 2001.7744140625,
                principalPointY: 1543.74609375,
                distortionCenterX: 2008.567138671875,
                distortionCenterY: 1553.952880859375,
                pixelSizeMM: 0.0012199999764561653,
                distortionCoefficients: [
                    0, -0.5692305564880371, 0.05308981239795685,
                    -0.0018655891763046384, -0.000004458999683265574,
                    0.0000019504550436977297, -0.000000044818150968239934,
                    0.0000000003053474695313696,
                ],
                inverseDistortionCoefficients: [
                    0, 0.5576314330101013, -0.04986516013741493,
                    0.0016566345002502203, 0.0000071098988883022685,
                    -0.0000017824544329414493, 0.000000039320074307624964,
                    -0.00000000026318897061727853,
                ],
                renderingParametersBase64: portraitRenderingParameters2xBase64
            )
        }
        if physicalFocalLengthMM < 28 {
            return PortraitAppleLensProfile(
                name: "Apple-3x-tele-77mm",
                anchorEquivalentFocalLengthMM: 77,
                maximumValidatedEquivalentFocalLengthMM: 134,
                referenceWidth: 4032,
                referenceHeight: 3024,
                focalLengthPixels: 9169.1298828125,
                principalPointX: 2023.2255859375,
                principalPointY: 1536.47265625,
                distortionCenterX: 2066.8583984375,
                distortionCenterY: 1557.3045654296875,
                pixelSizeMM: 0.0010000000474974513,
                distortionCoefficients: [
                    0, 1.3263592720031738, -0.7996886372566223,
                    0.18687580525875092, -0.016688073053956032,
                    -0.0014819741481915116, 0.0004676870012190193,
                    -0.000029682618333026767,
                ],
                inverseDistortionCoefficients: [
                    0, -1.3037974834442139, 0.7811512351036072,
                    -0.17724691331386566, 0.013979822397232056,
                    0.0017448276048526168, -0.0004529204161372036,
                    0.00002691301233426202,
                ],
                renderingParametersBase64: portraitRenderingParameters3xBase64
            )
        }
        return PortraitAppleLensProfile(
            name: "Apple-5x-tetraprism-120mm",
            anchorEquivalentFocalLengthMM: 120,
            maximumValidatedEquivalentFocalLengthMM: 120,
            referenceWidth: 4032,
            referenceHeight: 3024,
            focalLengthPixels: 14235.533203125,
            principalPointX: 2012.30908203125,
            principalPointY: 1589.007568359375,
            distortionCenterX: 2027.13818359375,
            distortionCenterY: 1567.1475830078125,
            pixelSizeMM: 0.001120000029914081,
            distortionCoefficients: [
                0, -0.09882805496454239, 0.000012278825124667492,
                0, 0, 0, 0, 0,
            ],
            inverseDistortionCoefficients: [
                0, 0.10229571908712387, -0.0005449775489978492,
                0, 0, 0, 0, 0,
            ],
            renderingParametersBase64: portraitRenderingParameters5xBase64
        )
    }

    private static func makeCameraCalibration(
        inputProperties: [CFString: Any]?,
        baseProperties: [CFString: Any]?,
        baseWidth: Int,
        baseHeight: Int,
        effectiveFocalLengthPixels: Double
    ) throws -> PortraitCameraCalibration {
        let inputExif = inputProperties?[kCGImagePropertyExifDictionary] as? NSDictionary
        let baseExif = baseProperties?[kCGImagePropertyExifDictionary] as? NSDictionary

        func number(_ key: CFString) -> Double? {
            for dictionary in [inputExif, baseExif] {
                if let value = dictionary?[key] as? NSNumber {
                    let result = value.doubleValue
                    if result.isFinite, result > 0 { return result }
                }
            }
            return nil
        }

        func string(_ key: CFString) -> String? {
            for dictionary in [inputExif, baseExif] {
                if let value = dictionary?[key] as? String, !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        guard let physicalFocalLength = number(kCGImagePropertyExifFocalLength) else {
            throw CLIError.invalidContainer(
                "--apple-portrait requires EXIF FocalLength to derive OPPO camera calibration"
            )
        }
        guard let equivalentFocalLength = number(kCGImagePropertyExifFocalLenIn35mmFilm) else {
            throw CLIError.invalidContainer(
                "--apple-portrait requires EXIF FocalLengthIn35mmFormat to derive OPPO camera calibration"
            )
        }

        let exifZoom = number(kCGImagePropertyExifDigitalZoomRatio) ?? 1.0
        let lensModel = string(kCGImagePropertyExifLensModel)
        let lensAnchor = lensModel.flatMap(opticalEquivalentFocalLengthFromLensModel)
        let fallbackAnchor = equivalentFocalLength / max(exifZoom, 1.0)
        let opticalEquivalentFocalLength = lensAnchor ?? fallbackAnchor
        guard opticalEquivalentFocalLength.isFinite, opticalEquivalentFocalLength > 0 else {
            throw CLIError.invalidContainer("unable to derive OPPO optical focal-length anchor")
        }

        let equivalentZoom = equivalentFocalLength / opticalEquivalentFocalLength
        let digitalZoom: Double
        if exifZoom.isFinite,
           exifZoom >= 1.0,
           abs(exifZoom - equivalentZoom) <= max(0.08, equivalentZoom * 0.05) {
            digitalZoom = exifZoom
        } else {
            digitalZoom = max(1.0, equivalentZoom)
        }

        guard effectiveFocalLengthPixels.isFinite, effectiveFocalLengthPixels > 0 else {
            throw CLIError.invalidContainer("OPPO depth-header focal length is invalid")
        }

        // REND and auxiliary calibration are a lens-coupled Apple profile.
        // Within one physical profile Apple keeps intrinsic fx approximately
        // constant while the reference crop and PixelSize scale inversely with
        // equivalent focal length. Reproduce that observed representation for
        // OPPO digital focal lengths instead of multiplying disparity itself.
        let profile = appleLensProfile(
            physicalFocalLengthMM: physicalFocalLength,
            equivalentFocalLengthMM: equivalentFocalLength
        )
        // Apple has no 10x/230mm portrait renderer profile. Keep the source
        // focal length in primary EXIF, but never extrapolate a private Apple
        // calibration/REND chart beyond the range measured for that profile.
        // Longer OPPO captures remain in the nearest validated Apple render
        // domain; disparity and scene controls carry depth, not a fabricated
        // auxiliary focal-length multiplier.
        let renderEquivalentFocalLength = min(
            equivalentFocalLength,
            profile.maximumValidatedEquivalentFocalLengthMM
        )
        let cropScale = profile.anchorEquivalentFocalLengthMM / renderEquivalentFocalLength
        func roundedMultipleOf4(_ value: Double) -> Int {
            max(4, Int((value / 4).rounded()) * 4)
        }
        let referenceWidth = roundedMultipleOf4(Double(profile.referenceWidth) * cropScale)
        let referenceHeight = roundedMultipleOf4(Double(profile.referenceHeight) * cropScale)
        let cropOffsetX = (Double(profile.referenceWidth) - Double(referenceWidth)) / 2
        let cropOffsetY = (Double(profile.referenceHeight) - Double(referenceHeight)) / 2
        let focalLengthPixels = profile.focalLengthPixels
        let renderEffectiveFocalLengthPixels = focalLengthPixels
            * Double(baseWidth) / Double(referenceWidth)
        let principalPointX = profile.principalPointX - cropOffsetX
        let principalPointY = profile.principalPointY - cropOffsetY
        let pixelSizeMM = profile.pixelSizeMM * cropScale

        let calibration = PortraitCameraCalibration(
            profileName: profile.name,
            renderingParametersBase64: try validatedRenderingParametersBase64(
                profile.renderingParametersBase64
            ),
            physicalFocalLengthMM: physicalFocalLength,
            opticalEquivalentFocalLengthMM: opticalEquivalentFocalLength,
            digitalZoomRatio: digitalZoom,
            referenceWidth: referenceWidth,
            referenceHeight: referenceHeight,
            focalLengthPixels: focalLengthPixels,
            effectiveFocalLengthPixels: renderEffectiveFocalLengthPixels,
            principalPointX: principalPointX,
            principalPointY: principalPointY,
            distortionCenterX: profile.distortionCenterX - cropOffsetX,
            distortionCenterY: profile.distortionCenterY - cropOffsetY,
            pixelSizeMM: pixelSizeMM,
            distortionCoefficients: profile.distortionCoefficients,
            inverseDistortionCoefficients: profile.inverseDistortionCoefficients
        )
        print(String(
            format: "portrait render profile=%@ sourcePhysical=%.3fmm sourceOptical=%.2fmm sourceEquivalent=%.2fmm renderEquivalent=%.2fmm sourceZoom=%.4fx sourceDepthFx=%.3f cropScale=%.5f ref=%dx%d fx=%.3f pixel=%.9fmm",
            calibration.profileName,
            calibration.physicalFocalLengthMM,
            calibration.opticalEquivalentFocalLengthMM,
            equivalentFocalLength,
            renderEquivalentFocalLength,
            calibration.digitalZoomRatio,
            effectiveFocalLengthPixels,
            cropScale,
            calibration.referenceWidth,
            calibration.referenceHeight,
            calibration.focalLengthPixels,
            calibration.pixelSizeMM
        ))
        return calibration
    }

    private static func parseDepthHeader(_ decodedDepth: Data) throws -> PortraitDepthHeader {
        let headerSize = 768
        guard decodedDepth.count >= headerSize else {
            throw CLIError.invalidContainer("decoded rear.depth is shorter than its 768-byte header")
        }
        guard let widthRaw = readUInt32LE(decodedDepth, at: 0),
              let heightRaw = readUInt32LE(decodedDepth, at: 4),
              widthRaw > 0,
              heightRaw > 0,
              widthRaw <= 16_384,
              heightRaw <= 16_384 else {
            throw CLIError.invalidContainer("decoded rear.depth header dimensions are invalid")
        }
        guard let rankDisparityScale = readFloat32LE(decodedDepth, at: 0x18),
              let focalLength = readFloat32LE(decodedDepth, at: 0x1c),
              let stereoBaseline = readFloat32LE(decodedDepth, at: 0x20),
              rankDisparityScale.isFinite,
              rankDisparityScale > 0,
              focalLength.isFinite,
              focalLength > 0,
              stereoBaseline.isFinite,
              stereoBaseline > 0 else {
            throw CLIError.invalidContainer("decoded rear.depth calibration header is invalid")
        }
        let width = Int(widthRaw)
        let height = Int(heightRaw)
        guard decodedDepth.count >= headerSize + width * height else {
            throw CLIError.invalidContainer("decoded rear.depth rank plane is truncated")
        }
        return PortraitDepthHeader(
            width: width,
            height: height,
            rankDisparityScale: Double(rankDisparityScale),
            focalLengthPixels: Double(focalLength),
            stereoBaseline: Double(stereoBaseline)
        )
    }

    private static func parseDepthPlanes(
        _ decodedDepth: Data,
        header: PortraitDepthHeader
    ) throws -> OPPODepthPlanes {
        let headerSize = 0x300
        let planeSize = header.width * header.height
        guard decodedDepth.count >= headerSize + planeSize else {
            throw CLIError.invalidContainer("decoded rear.depth rank plane is truncated")
        }
        let ranks = decodedDepth.subdata(in: headerSize..<(headerSize + planeSize))
        var cursor = headerSize + planeSize
        func consumePlane(flagOffset: Int, name: String) throws -> Data? {
            guard decodedDepth[flagOffset] != 0 else { return nil }
            guard cursor + planeSize <= decodedDepth.count else {
                throw CLIError.invalidContainer(
                    "decoded rear.depth is too short for flagged \(name) plane"
                )
            }
            defer { cursor += planeSize }
            return decodedDepth.subdata(in: cursor..<(cursor + planeSize))
        }
        // Same-size firmware order after rank: hair, portrait, pet. Later
        // independent-size YUV/NV21 auxiliaries are not Apple matte sources.
        return OPPODepthPlanes(
            ranks: ranks,
            hair: try consumePlane(flagOffset: 0x24, name: "hair"),
            portrait: try consumePlane(flagOffset: 0x25, name: "portrait"),
            pet: try consumePlane(flagOffset: 0x26, name: "pet")
        )
    }

    private static func resolveGainInfoFloats(
        privateInfo: Data?,
        inputURL: URL
    ) throws -> [Double] {
        if let privateInfo {
            guard privateInfo.count == 80 else {
                throw CLIError.invalidLHDR("portrait gain info must be exactly 80 bytes")
            }
            return try unpackFloatArrayLE(privateInfo, count: 20)
        }

        guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
              let dictionary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                  source,
                  0,
              kCGImageAuxiliaryDataTypeISOGainMap
              ) as? [CFString: Any],
              let rawMetadata = dictionary[kCGImageAuxiliaryDataInfoMetadata],
              CFGetTypeID(rawMetadata as CFTypeRef) == CGImageMetadataGetTypeID() else {
            throw CLIError.invalidLHDR(
                "portrait requires private gain info or an existing ISO gain-map metadata graph"
            )
        }
        let metadata = unsafeBitCast(rawMetadata as AnyObject, to: CGImageMetadata.self)

        func value(_ path: String) throws -> Double {
            guard let tag = CGImageMetadataCopyTagWithPath(
                metadata,
                nil,
                path as CFString
            ), let raw = CGImageMetadataTagCopyValue(tag) else {
                throw CLIError.invalidLHDR("ISO gain-map metadata is missing \(path)")
            }
            if let number = raw as? NSNumber {
                return number.doubleValue
            }
            if let text = raw as? String, let parsed = Double(text) {
                return parsed
            }
            throw CLIError.invalidLHDR("ISO gain-map metadata has an invalid \(path)")
        }

        var values: [Double] = []
        let gainMapMin = try (0..<3).map {
            try value("HDRToneMap:ChannelMetadata[\($0)].GainMapMin")
        }
        let gainMapMax = try (0..<3).map {
            try value("HDRToneMap:ChannelMetadata[\($0)].GainMapMax")
        }
        values.append(contentsOf: gainMapMin.map { pow(2.0, $0) })
        values.append(1.0)
        values.append(contentsOf: gainMapMax.map { pow(2.0, $0) })
        for field in ["Gamma", "BaseOffset", "AlternateOffset"] {
            values.append(contentsOf: try (0..<3).map {
                try value("HDRToneMap:ChannelMetadata[\($0)].\(field)")
            })
        }
        let baseRatio = pow(2.0, try value("HDRToneMap:BaseHeadroom"))
        let alternateRatio = pow(2.0, try value("HDRToneMap:AlternateHeadroom"))
        values.append(baseRatio)
        values.append(alternateRatio)
        values.append(alternateRatio)
        values.append(0.0)
        guard values.count == 20, values.allSatisfy(\.isFinite) else {
            throw CLIError.invalidLHDR("unable to reconstruct portrait gain metadata")
        }
        print("portrait gain info source=existing ISO HDRToneMap metadata")
        return values
    }

    private static func resolveSimulatedAperture(
        rearDepthConfig: Data?,
        inputProperties: [CFString: Any]?,
        baseProperties: [CFString: Any]?
    ) -> (value: Double, source: String) {
        // OPPO RearDepthStruct v4 stores the portrait editor's f-number at
        // byte offset 292. This is the simulated bokeh setting, not the lens's
        // physical capture aperture, so it maps directly to Apple's
        // depthBlurEffect:SimulatedAperture.
        if let config = rearDepthConfig,
           let version = readFloat32LE(config, at: 0),
           abs(version - 4.0) < 0.001,
           let fNumber = readFloat32LE(config, at: 292),
           fNumber.isFinite,
           (1.0...32.0).contains(fNumber) {
            let value = Double(fNumber)
            print(String(format: "portrait aperture f/%.1f source=rear.depth.config-v%.1f", value, version))
            return (value, "rear.depth.config")
        }

        for properties in [inputProperties, baseProperties] {
            guard
                let exif = properties?[kCGImagePropertyExifDictionary] as? NSDictionary,
                let number = exif[kCGImagePropertyExifFNumber] as? NSNumber
            else { continue }
            let value = number.doubleValue
            if value.isFinite, (1.0...32.0).contains(value) {
                print(String(format: "portrait aperture f/%.1f source=EXIF", value))
                return (value, "EXIF FNumber")
            }
        }

        print("portrait aperture f/1.4 source=compatibility-fallback")
        return (1.4, "compatibility fallback")
    }

    private static func readFloat32LE(_ data: Data, at offset: Int) -> Float? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let bits = UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
        return Float(bitPattern: bits)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func opticalEquivalentFocalLengthFromLensModel(_ lensModel: String) -> Double? {
        let pattern = #"camera\s+([0-9]+(?:\.[0-9]+)?)mm\b"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(lensModel.startIndex..<lensModel.endIndex, in: lensModel)
        guard let match = expression.firstMatch(in: lensModel, options: [], range: range),
              match.numberOfRanges > 1,
              let focalRange = Range(match.range(at: 1), in: lensModel),
              let focalLength = Double(lensModel[focalRange]),
              focalLength.isFinite,
              focalLength > 0 else {
            return nil
        }
        return focalLength
    }

    private static func resolvedBaseOrientation(
        inputWidth: Int?,
        inputHeight: Int?,
        inputOrientation: UInt32?,
        baseWidth: Int,
        baseHeight: Int,
        baseOrientation: UInt32?
    ) -> UInt32 {
        func swapsAxes(_ orientation: UInt32) -> Bool {
            (5...8).contains(orientation)
        }

        func displayedIsPortrait(width: Int, height: Int, orientation: UInt32) -> Bool {
            let displayedWidth = swapsAxes(orientation) ? height : width
            let displayedHeight = swapsAxes(orientation) ? width : height
            return displayedHeight > displayedWidth
        }

        let normalizedInputOrientation = inputOrientation.flatMap {
            (1...8).contains($0) ? $0 : nil
        } ?? 1
        let targetIsPortrait: Bool
        if let inputWidth, let inputHeight, inputWidth != inputHeight {
            targetIsPortrait = displayedIsPortrait(
                width: inputWidth,
                height: inputHeight,
                orientation: normalizedInputOrientation
            )
        } else {
            targetIsPortrait = displayedIsPortrait(
                width: baseWidth,
                height: baseHeight,
                orientation: baseOrientation ?? normalizedInputOrientation
            )
        }

        if let baseOrientation,
           (1...8).contains(baseOrientation),
           displayedIsPortrait(
               width: baseWidth,
               height: baseHeight,
               orientation: baseOrientation
           ) == targetIsPortrait {
            return baseOrientation
        }

        let baseStoredIsPortrait = baseHeight > baseWidth
        if baseStoredIsPortrait == targetIsPortrait {
            return 1
        }
        // OPPO portrait src.image JPEGs observed so far use clockwise rotation.
        // The source JPEG orientation wins whenever available; this is only the
        // metadata-missing fallback for a stored/display aspect mismatch.
        return 6
    }

    private static func makeDepthDictionary(
        ranks: Data,
        width: Int,
        height: Int,
        orientation: UInt32,
        far: Float,
        near: Float,
        calibration: PortraitCameraCalibration,
        simulatedAperture: Double
    ) throws -> CFDictionary {
        let output = NSMutableDictionary()
        let description = NSMutableDictionary()
        var disparity = Data(capacity: width * height * 2)
        let span = near - far
        for rank in ranks {
            let value = near - Float(rank) / 255.0 * span
            var bits = Float16(value).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { disparity.append(contentsOf: $0) }
        }
        description[kCGImagePropertyWidth as String] = width
        description[kCGImagePropertyHeight as String] = height
        description[kCGImagePropertyBytesPerRow as String] = width * 2
        description[kCGImagePropertyPixelFormat as String] = NSNumber(value: kCVPixelFormatType_DisparityFloat16)
        description[kCGImagePropertyOrientation as String] = NSNumber(value: orientation)
        output[kCGImageAuxiliaryDataInfoData as String] = disparity
        output[kCGImageAuxiliaryDataInfoDataDescription as String] = description
        let metadata = CGImageMetadataCreateMutable()
        try registerMetadataNamespace(
            metadata,
            namespace: "http://ns.apple.com/depthData/1.0/",
            prefix: "depthData"
        )
        try registerMetadataNamespace(
            metadata,
            namespace: "http://ns.apple.com/depthBlurEffect/1.0/",
            prefix: "depthBlurEffect"
        )
        try registerMetadataNamespace(
            metadata,
            namespace: "http://ns.apple.com/portraitLightingEffect/1.0/",
            prefix: "portraitLightingEffect"
        )
        try setMetadata(metadata, path: "depthData:Quality", value: "high")
        try setMetadata(metadata, path: "depthData:Accuracy", value: "relative")
        try setMetadata(metadata, path: "depthData:Filtered", value: "True")
        try setMetadata(metadata, path: "depthData:DepthDataVersion", value: "65541")
        try setMetadata(
            metadata,
            path: "depthData:IntrinsicMatrixReferenceWidth",
            value: String(calibration.referenceWidth)
        )
        try setMetadata(
            metadata,
            path: "depthData:IntrinsicMatrixReferenceHeight",
            value: String(calibration.referenceHeight)
        )
        try setMetadata(
            metadata,
            path: "depthData:LensDistortionCenterOffsetX",
            value: String(format: "%.12f", calibration.distortionCenterX)
        )
        try setMetadata(
            metadata,
            path: "depthData:LensDistortionCenterOffsetY",
            value: String(format: "%.12f", calibration.distortionCenterY)
        )
        try setMetadata(
            metadata,
            path: "depthData:PixelSize",
            value: String(format: "%.12f", calibration.pixelSizeMM)
        )
        try setMetadataValue(
            metadata,
            path: "depthData:IntrinsicMatrix",
            value: calibration.intrinsicMatrix as CFArray
        )
        try setMetadataValue(
            metadata,
            path: "depthData:ExtrinsicMatrix",
            value: [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0] as CFArray
        )
        try setMetadataValue(
            metadata,
            path: "depthData:LensDistortionCoefficients",
            value: calibration.distortionCoefficients as CFArray
        )
        try setMetadataValue(
            metadata,
            path: "depthData:InverseLensDistortionCoefficients",
            value: calibration.inverseDistortionCoefficients as CFArray
        )
        try setMetadata(
            metadata,
            path: "depthBlurEffect:RenderingParameters",
            value: calibration.renderingParametersBase64
        )
        try setMetadata(
            metadata,
            path: "depthBlurEffect:SimulatedAperture",
            value: String(format: "%.6f", simulatedAperture)
        )
        try setMetadata(metadata, path: "portraitLightingEffect:EffectStrength", value: "0.500000")
        output[kCGImageAuxiliaryDataInfoMetadata as String] = metadata
        return output as CFDictionary
    }

    private static func makeL8Buffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            attributes as CFDictionary,
            &buffer
        ) == kCVReturnSuccess, let buffer else {
            throw CLIError.invalidContainer("unable to allocate L008 matte buffer")
        }
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_Linear,
            .shouldPropagate
        )
        return buffer
    }

    private static func makePlaneBuffer(
        _ plane: Data,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        guard plane.count == width * height else {
            throw CLIError.invalidContainer("OPPO matte plane size does not match its geometry")
        }
        let buffer = try makeL8Buffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw CLIError.invalidContainer("OPPO matte plane has no writable storage")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        plane.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            for row in 0..<height {
                memcpy(
                    baseAddress.advanced(by: row * bytesPerRow),
                    sourceBase.advanced(by: row * width),
                    width
                )
            }
        }
        return buffer
    }

    private static func renderL8(
        _ image: CIImage,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        let buffer = try makeL8Buffer(width: width, height: height)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        CIContext(options: [.useSoftwareRenderer: false]).render(
            image.cropped(to: bounds),
            to: buffer,
            bounds: bounds,
            colorSpace: CGColorSpaceCreateDeviceGray()
        )
        return buffer
    }

    private static func maximum(_ foreground: CIImage, _ background: CIImage) -> CIImage {
        foreground.applyingFilter(
            "CIMaximumCompositing",
            parameters: [kCIInputBackgroundImageKey: background]
        )
    }

    private static func minimum(_ foreground: CIImage, _ background: CIImage) -> CIImage {
        foreground.applyingFilter(
            "CIMinimumCompositing",
            parameters: [kCIInputBackgroundImageKey: background]
        )
    }

    private static func scaled(
        _ image: CIImage,
        width: Int,
        height: Int
    ) -> CIImage {
        image.transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / image.extent.width,
            y: CGFloat(height) / image.extent.height
        ))
    }

    private static func makeRGBGuidedOPPOMatte(
        image: CGImage,
        subject: Data,
        hair: Data?,
        planeWidth: Int,
        planeHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) throws -> (portrait: CVPixelBuffer, hair: CVPixelBuffer?) {
        let bounds = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        let subjectBuffer = try makePlaneBuffer(subject, width: planeWidth, height: planeHeight)
        let smallSubject = CIImage(cvPixelBuffer: subjectBuffer)
        let topology = scaled(smallSubject, width: targetWidth, height: targetHeight)
            .cropped(to: bounds)
        let guide = scaled(CIImage(cgImage: image), width: targetWidth, height: targetHeight)
            .cropped(to: bounds)

        let guided: CIImage
        if let filter = CIFilter(name: "CIEdgePreserveUpsampleFilter") {
            filter.setValue(guide, forKey: kCIInputImageKey)
            filter.setValue(smallSubject, forKey: "inputSmallImage")
            filter.setValue(3.0, forKey: "inputSpatialSigma")
            filter.setValue(0.15, forKey: "inputLumaSigma")
            guided = (filter.outputImage ?? topology).cropped(to: bounds)
        } else {
            guided = topology
        }

        let inwardSupport = topology
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 1.5])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.0])
            .cropped(to: bounds)
        let subjectCore = topology
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 3.0])
            .cropped(to: bounds)
        let guidedBoundary = minimum(guided, inwardSupport).cropped(to: bounds)
        var fused = maximum(guidedBoundary, subjectCore).cropped(to: bounds)

        var hairBuffer: CVPixelBuffer?
        if let hair {
            let lowResolutionHair = try makePlaneBuffer(hair, width: planeWidth, height: planeHeight)
            let hairImage = scaled(
                CIImage(cvPixelBuffer: lowResolutionHair),
                width: targetWidth,
                height: targetHeight
            ).cropped(to: bounds)
            fused = maximum(fused, hairImage).cropped(to: bounds)
            hairBuffer = try renderL8(hairImage, width: targetWidth, height: targetHeight)
        }
        return (
            portrait: try renderL8(fused, width: targetWidth, height: targetHeight),
            hair: hairBuffer
        )
    }

    private static func makeVisionFallbackMatte(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        orientationRaw: UInt32,
        targetWidth: Int,
        targetHeight: Int,
        hair: Data?,
        planeWidth: Int,
        planeHeight: Int
    ) throws -> (portrait: CVPixelBuffer, hair: CVPixelBuffer?) {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]).perform([request])
        guard let observation = request.results?.first else {
            throw CLIError.invalidContainer("Vision returned no person segmentation mask")
        }
        let displayMask = CIImage(cvPixelBuffer: observation.pixelBuffer)
        let storedMask: CIImage
        switch orientationRaw {
        case 3: storedMask = displayMask.oriented(.down)
        case 6: storedMask = displayMask.oriented(.left)
        case 8: storedMask = displayMask.oriented(.right)
        default: storedMask = displayMask
        }
        let bounds = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        var fused = scaled(storedMask, width: targetWidth, height: targetHeight).cropped(to: bounds)
        var hairBuffer: CVPixelBuffer?
        if let hair {
            let lowResolutionHair = try makePlaneBuffer(hair, width: planeWidth, height: planeHeight)
            let hairImage = scaled(
                CIImage(cvPixelBuffer: lowResolutionHair),
                width: targetWidth,
                height: targetHeight
            ).cropped(to: bounds)
            fused = maximum(fused, hairImage).cropped(to: bounds)
            hairBuffer = try renderL8(hairImage, width: targetWidth, height: targetHeight)
        }
        return (
            portrait: try renderL8(fused, width: targetWidth, height: targetHeight),
            hair: hairBuffer
        )
    }

    private static func makeMatteMetadata(
        namespace: String,
        prefix: String,
        versionPath: String,
        version: String
    ) throws -> CGImageMetadata {
        let metadata = CGImageMetadataCreateMutable()
        try registerMetadataNamespace(metadata, namespace: namespace, prefix: prefix)
        try setMetadata(metadata, path: versionPath, value: version)
        return metadata
    }

    private static func makeL8AuxiliaryDictionary(
        buffer: CVPixelBuffer,
        metadata: CGImageMetadata
    ) throws -> CFDictionary {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw CLIError.invalidContainer("matte buffer has no readable storage")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var pixels = Data(count: width * height)
        pixels.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            for row in 0..<height {
                memcpy(
                    destinationBase.advanced(by: row * width),
                    baseAddress.advanced(by: row * bytesPerRow),
                    width
                )
            }
        }
        let description: [CFString: Any] = [
            kCGImagePropertyWidth: width,
            kCGImagePropertyHeight: height,
            kCGImagePropertyBytesPerRow: width,
            kCGImagePropertyPixelFormat: NSNumber(value: kCVPixelFormatType_OneComponent8),
        ]
        return [
            kCGImageAuxiliaryDataInfoData: pixels,
            kCGImageAuxiliaryDataInfoDataDescription: description,
            kCGImageAuxiliaryDataInfoMetadata: metadata,
        ] as CFDictionary
    }

    private static func makePortraitEffectsMattes(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        orientationRaw: UInt32,
        depthPlanes: OPPODepthPlanes,
        planeWidth: Int,
        planeHeight: Int
    ) throws -> (portrait: CFDictionary, hair: CFDictionary?) {
        let targetWidth = image.width / 2
        let targetHeight = image.height / 2
        let rendered: (portrait: CVPixelBuffer, hair: CVPixelBuffer?)
        if let subject = depthPlanes.subject {
            rendered = try makeRGBGuidedOPPOMatte(
                image: image,
                subject: subject,
                hair: depthPlanes.validHair,
                planeWidth: planeWidth,
                planeHeight: planeHeight,
                targetWidth: targetWidth,
                targetHeight: targetHeight
            )
        } else {
            rendered = try makeVisionFallbackMatte(
                image: image,
                orientation: orientation,
                orientationRaw: orientationRaw,
                targetWidth: targetWidth,
                targetHeight: targetHeight,
                hair: depthPlanes.validHair,
                planeWidth: planeWidth,
                planeHeight: planeHeight
            )
        }
        let portraitMetadata = try makeMatteMetadata(
            namespace: "http://ns.apple.com/portraitEffectsMatte/1.0/",
            prefix: "portraitEffectsMatte",
            versionPath: "portraitEffectsMatte:PortraitEffectsMatteVersion",
            version: "65537"
        )
        let portrait = try makeL8AuxiliaryDictionary(
            buffer: rendered.portrait,
            metadata: portraitMetadata
        )
        guard let hairBuffer = rendered.hair else { return (portrait, nil) }
        let hairMetadata = try makeMatteMetadata(
            namespace: "http://ns.apple.com/semanticSegmentationMatte/1.0/",
            prefix: "semanticSegmentationMatte",
            versionPath: "semanticSegmentationMatte:SemanticSegmentationMatteVersion",
            version: "65536"
        )
        return (
            portrait,
            try makeL8AuxiliaryDictionary(buffer: hairBuffer, metadata: hairMetadata)
        )
    }

    private static func makeFocusRegion(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        orientationRaw: UInt32,
        rearDepthConfig: Data?
    ) throws -> PortraitFocusRegion {
        // RearDepthStruct stores the tap-to-focus point in src.image storage
        // coordinates, not in its declared 900x1200 processing dimensions.
        if let rearDepthConfig,
           let focusX = readUInt32LE(rearDepthConfig, at: 12),
           let focusY = readUInt32LE(rearDepthConfig, at: 16),
           focusX < image.width,
           focusY < image.height {
            let rawX = Double(focusX) / Double(image.width)
            let rawY = Double(focusY) / Double(image.height)
            print(String(
                format: "portrait focus source=rear.depth.config raw=(%.6f,%.6f) pixel=(%u,%u)",
                rawX,
                rawY,
                focusX,
                focusY
            ))
            return PortraitFocusRegion(
                rawX: rawX,
                rawY: rawY,
                rawWidth: 0.12,
                rawHeight: 0.12
            )
        }

        let attention = VNGenerateAttentionBasedSaliencyImageRequest()
        let faces = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]).perform([attention, faces])
        let faceResults = faces.results ?? []
        let saliencyBuffer = attention.results?.first?.pixelBuffer
        let selectedFace = faceResults.max {
            faceAttentionScore($0, saliency: saliencyBuffer)
                < faceAttentionScore($1, saliency: saliencyBuffer)
        }
        let displayX: Double
        let displayY: Double
        let displayWidth: Double
        let displayHeight: Double
        if let face = selectedFace {
            let box = face.boundingBox
            let leftEye = face.landmarks?.leftEye.flatMap { landmarkCenter($0, face: face) }
            let rightEye = face.landmarks?.rightEye.flatMap { landmarkCenter($0, face: face) }
            if let leftEye, let rightEye {
                displayX = (leftEye.x + rightEye.x) / 2
                displayY = (leftEye.y + rightEye.y) / 2
            } else {
                displayX = box.midX
                displayY = 1 - box.midY
            }
            displayWidth = box.width
            displayHeight = box.height
        } else if let observation = attention.results?.first {
            let point = try attentionCentroid(observation.pixelBuffer)
            displayX = point.x
            displayY = point.y
            displayWidth = 0.12
            displayHeight = 0.12
        } else {
            throw CLIError.invalidContainer("Vision returned no Focus candidate")
        }
        let raw = rawFocusRect(
            x: displayX,
            y: displayY,
            width: displayWidth,
            height: displayHeight,
            orientation: orientationRaw
        )
        return PortraitFocusRegion(
            rawX: raw.x,
            rawY: raw.y,
            rawWidth: raw.width,
            rawHeight: raw.height
        )
    }

    private static func robustFocusRank(
        ranks: Data,
        subject: Data?,
        width: Int,
        height: Int,
        rawX: Double,
        rawY: Double
    ) -> Double {
        let centerX = max(0, min(width - 1, Int(round(rawX * Double(width - 1)))))
        let centerY = max(0, min(height - 1, Int(round(rawY * Double(height - 1)))))
        let radius = 10
        let validSubject = subject.flatMap { $0.count == ranks.count ? $0 : nil }
        var local: [UInt8] = []
        var subjectLocal: [UInt8] = []
        for y in max(0, centerY - radius)...min(height - 1, centerY + radius) {
            for x in max(0, centerX - radius)...min(width - 1, centerX + radius) {
                let index = y * width + x
                local.append(ranks[index])
                if let validSubject, validSubject[index] != 0 {
                    subjectLocal.append(ranks[index])
                }
            }
        }
        var candidates = subjectLocal.count >= 9 ? subjectLocal : local
        candidates.sort()
        let middle = candidates.count / 2
        let median: Double
        if candidates.count.isMultiple(of: 2) {
            median = (Double(candidates[middle - 1]) + Double(candidates[middle])) / 2.0
        } else {
            median = Double(candidates[middle])
        }
        print(String(
            format: "portrait focus rank source=%@ depth=(%d,%d) samples=%d median=%.3f",
            subjectLocal.count >= 9 ? "subject-gated" : "local",
            centerX,
            centerY,
            candidates.count,
            median
        ))
        return median
    }

    private static func landmarkCenter(
        _ region: VNFaceLandmarkRegion2D,
        face: VNFaceObservation
    ) -> (x: Double, y: Double)? {
        guard region.pointCount > 0 else { return nil }
        var x = 0.0
        var y = 0.0
        for point in region.normalizedPoints {
            x += face.boundingBox.minX + CGFloat(point.x) * face.boundingBox.width
            y += face.boundingBox.minY + CGFloat(point.y) * face.boundingBox.height
        }
        return (x / Double(region.pointCount), 1 - y / Double(region.pointCount))
    }

    private static func faceAttentionScore(
        _ face: VNFaceObservation,
        saliency: CVPixelBuffer?
    ) -> Double {
        guard let saliency,
              CVPixelBufferGetPixelFormatType(saliency) == kCVPixelFormatType_OneComponent32Float else {
            return Double(face.boundingBox.width * face.boundingBox.height) * Double(face.confidence)
        }
        CVPixelBufferLockBaseAddress(saliency, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(saliency, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(saliency) else { return 0 }
        let width = CVPixelBufferGetWidth(saliency)
        let height = CVPixelBufferGetHeight(saliency)
        let stride = CVPixelBufferGetBytesPerRow(saliency) / MemoryLayout<Float>.stride
        let values = base.assumingMemoryBound(to: Float.self)
        let box = face.boundingBox
        let minX = max(0, min(width - 1, Int(box.minX * CGFloat(width))))
        let maxX = max(minX, min(width - 1, Int(box.maxX * CGFloat(width))))
        let top = 1 - box.maxY
        let bottom = 1 - box.minY
        let minY = max(0, min(height - 1, Int(top * CGFloat(height))))
        let maxY = max(minY, min(height - 1, Int(bottom * CGFloat(height))))
        var sum = 0.0
        var count = 0
        for y in minY...maxY { for x in minX...maxX {
            let value = values[y * stride + x]
            if value.isFinite {
                sum += Double(value)
                count += 1
            }
        }}
        let mean = count > 0 ? sum / Double(count) : 0
        return mean * Double(face.confidence)
    }

    private static func attentionCentroid(_ buffer: CVPixelBuffer) throws -> (x: Double, y: Double) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float,
              let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw CLIError.invalidContainer("unexpected Vision saliency buffer")
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.stride
        let values = base.assumingMemoryBound(to: Float.self)
        var finite: [Float] = []
        finite.reserveCapacity(width * height)
        for y in 0..<height { for x in 0..<width where values[y * stride + x].isFinite {
            finite.append(values[y * stride + x])
        }}
        guard !finite.isEmpty else { throw CLIError.invalidContainer("empty Vision saliency map") }
        finite.sort()
        let threshold = finite[Int(Double(finite.count - 1) * 0.9)]
        var sum = 0.0
        var weightedX = 0.0
        var weightedY = 0.0
        for y in 0..<height { for x in 0..<width {
            let value = values[y * stride + x]
            guard value.isFinite, value >= threshold, value > 0 else { continue }
            let weight = Double(value)
            sum += weight
            weightedX += (Double(x) + 0.5) / Double(width) * weight
            weightedY += (Double(y) + 0.5) / Double(height) * weight
        }}
        guard sum > 0 else { throw CLIError.invalidContainer("Vision saliency has no positive response") }
        return (weightedX / sum, weightedY / sum)
    }

    private static func rawFocusRect(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        orientation: UInt32
    ) -> (x: Double, y: Double, width: Double, height: Double) {
        switch orientation {
        case 2: return (1 - x, y, width, height)
        case 3: return (1 - x, 1 - y, width, height)
        case 4: return (x, 1 - y, width, height)
        case 5: return (y, x, height, width)
        case 6: return (y, 1 - x, height, width)
        case 7: return (1 - y, 1 - x, height, width)
        case 8: return (1 - y, x, height, width)
        default: return (x, y, width, height)
        }
    }

    private static func writeBlankPortraitScaffold(
        sourceMetadataURL: URL,
        baseWidth: Int,
        baseHeight: Int,
        baseColorSpace: CGColorSpace?,
        orientation: UInt32,
        focus: PortraitFocusRegion,
        afMeasuredDepth: Int?,
        captureDate: String?,
        gainJPEG: Data,
        infoFloats: [Double],
        depthDictionary: CFDictionary,
        matteDictionary: CFDictionary,
        hairDictionary: CFDictionary?,
        outputURL: URL
    ) throws {
        let parent = outputURL.deletingLastPathComponent()
        let token = UUID().uuidString
        let gainCarrierURL = parent.appendingPathComponent(".\(outputURL.lastPathComponent).blank-\(token).heic")
        let gainPrivateURL = parent.appendingPathComponent(".\(outputURL.lastPathComponent).blank-private-\(token).heic")
        let gainISOURL = parent.appendingPathComponent(".\(outputURL.lastPathComponent).blank-iso-\(token).heic")
        defer {
            for url in [gainCarrierURL, gainPrivateURL, gainISOURL] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        guard let colorSpace = baseColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: baseWidth,
                  height: baseHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: baseWidth * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ),
              let blank = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  gainCarrierURL as CFURL,
                  UTType.heic.identifier as CFString,
                  1,
                  nil
              ) else {
            throw CLIError.unableToCreateDestination(outputURL)
        }
        guard let source = CGImageSourceCreateWithURL(sourceMetadataURL as CFURL, nil) else {
            throw CLIError.unableToLoadBaseImage(sourceMetadataURL)
        }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        properties[kCGImagePropertyMakerAppleDictionary] = portraitMakerAppleDictionary(
            afMeasuredDepth: afMeasuredDepth
        )
        var exif = (properties[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        exif[kCGImagePropertyExifCustomRendered] = 9
        exif[kCGImagePropertyExifPixelXDimension] = baseWidth
        exif[kCGImagePropertyExifPixelYDimension] = baseHeight
        properties[kCGImagePropertyExifDictionary] = exif
        properties[kCGImagePropertyOrientation] = orientation
        let metadata = try makeFocusMetadata(
            width: baseWidth,
            height: baseHeight,
            focus: focus,
            captureDate: captureDate
        )
        CGImageDestinationAddImageAndMetadata(destination, blank, metadata, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CLIError.unableToFinalizeDestination(gainCarrierURL)
        }
        _ = try writePrivateJPEGPassthroughOutput(
            inputURL: gainCarrierURL,
            outputURL: gainPrivateURL,
            infoFloats: infoFloats,
            gainMapJPEG: gainJPEG
        )
        try ISOHDRWriter.writeWithPreserveReencode(
            intermediateURL: gainPrivateURL,
            outputURL: gainISOURL
        )
        guard let gainCarrier = CGImageSourceCreateWithURL(gainISOURL as CFURL, nil),
              let scaffoldDestination = CGImageDestinationCreateWithURL(
                  outputURL as CFURL,
                  UTType.heic.identifier as CFString,
                  1,
                  nil
              ) else {
            throw CLIError.unableToFinalizeDestination(gainCarrierURL)
        }
        CGImageDestinationAddImageFromSource(
            scaffoldDestination,
            gainCarrier,
            0,
            [
                kCGImageDestinationPreserveGainMap: true,
                kCGImagePropertyOrientation: NSNumber(value: orientation),
            ] as CFDictionary
        )
        CGImageDestinationAddAuxiliaryDataInfo(
            scaffoldDestination,
            kCGImageAuxiliaryDataTypeDisparity,
            depthDictionary
        )
        CGImageDestinationAddAuxiliaryDataInfo(
            scaffoldDestination,
            kCGImageAuxiliaryDataTypePortraitEffectsMatte,
            matteDictionary
        )
        if let hairDictionary {
            CGImageDestinationAddAuxiliaryDataInfo(
                scaffoldDestination,
                kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
                hairDictionary
            )
        }
        guard CGImageDestinationFinalize(scaffoldDestination) else {
            throw CLIError.unableToFinalizeDestination(outputURL)
        }
    }

    private static func captureDateString(sourceURL: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String else {
            return nil
        }
        return raw.replacingOccurrences(of: ":", with: "-", options: [], range: raw.startIndex..<raw.index(raw.startIndex, offsetBy: min(10, raw.count)))
            .replacingOccurrences(of: " ", with: "T")
    }
}

private func transplantPortraitBaseAndGainPayloads(
    payloadSourceURL: URL,
    scaffoldURL: URL,
    outputURL: URL
) throws {
    struct Graph {
        let mdat: ISOBMFFBox
        let iloc: ISOBMFFBox
        let idat: ISOBMFFBox?
        let locations: [Int: ISOBMFFILocEntry]
        let baseTiles: [Int]
        let gainTiles: [Int]
        let hvcCByItem: [Int: Data]
    }
    func graph(_ data: Data, owner: String) throws -> Graph {
        let top = isobmffBoxes(in: data, start: 0, end: data.count)
        guard let meta = top.first(where: { $0.type == "meta" }),
              let mdat = top.first(where: { $0.type == "mdat" }) else {
            throw CLIError.invalidContainer("\(owner) has no meta/mdat")
        }
        let children = isobmffBoxes(in: data, start: meta.dataStart + 4, end: meta.dataEnd)
        guard let pitm = children.first(where: { $0.type == "pitm" }),
              let iinf = children.first(where: { $0.type == "iinf" }),
              let iloc = children.first(where: { $0.type == "iloc" }),
              let iref = children.first(where: { $0.type == "iref" }),
              let iprp = children.first(where: { $0.type == "iprp" }) else {
            throw CLIError.invalidContainer("\(owner) item graph is incomplete")
        }
        let primary = parseISOBMFFPITM(data, pitm)
        let infos = parseISOBMFFItemInfos(data, iinf).items
        guard let tmap = infos.first(where: { $0.type == "tmap" })?.itemID else {
            throw CLIError.invalidContainer("\(owner) has no tmap")
        }
        let refs = parseISOBMFFIRefs(data, iref).refs
        guard let baseTiles = refs.first(where: { $0.type == "dimg" && $0.from == primary })?.to,
              let gainGrid = refs.first(where: { $0.type == "dimg" && $0.from == tmap })?.to.first(where: { $0 != primary }),
              let gainTiles = refs.first(where: { $0.type == "dimg" && $0.from == gainGrid })?.to else {
            throw CLIError.invalidContainer("\(owner) base/gain grid graph is incomplete")
        }
        let locations = Dictionary(uniqueKeysWithValues: try parseISOBMFFILoc(data, iloc).map { ($0.itemID, $0) })
        let properties = try parseISOBMFFIPCOPropertyInfos(data, iprp)
        let propertyByIndex = Dictionary(uniqueKeysWithValues: properties.map { ($0.index, $0) })
        guard let ipmaBox = isobmffBoxes(in: data, start: iprp.dataStart, end: iprp.dataEnd).first(where: { $0.type == "ipma" }) else {
            throw CLIError.invalidContainer("\(owner) has no ipma")
        }
        let ipma = parseISOBMFFIPMA(data, ipmaBox)
        var hvcCByItem: [Int: Data] = [:]
        for entry in ipma.entries {
            for association in entry.associations {
                let index = assocPropertyIndex(association, flags: ipma.flags)
                if let property = propertyByIndex[index], property.type == "hvcC" {
                    hvcCByItem[entry.itemID] = property.rawBox
                }
            }
        }
        return Graph(
            mdat: mdat,
            iloc: iloc,
            idat: children.first(where: { $0.type == "idat" }),
            locations: locations,
            baseTiles: baseTiles,
            gainTiles: gainTiles,
            hvcCByItem: hvcCByItem
        )
    }

    let sourceData = try Data(contentsOf: payloadSourceURL)
    var scaffoldData = try Data(contentsOf: scaffoldURL)
    let source = try graph(sourceData, owner: "first assembly")
    let scaffold = try graph(scaffoldData, owner: "portrait scaffold")
    guard source.baseTiles.count == scaffold.baseTiles.count,
          source.gainTiles.count == scaffold.gainTiles.count,
          let sourceBaseFirst = source.baseTiles.first,
          let scaffoldBaseFirst = scaffold.baseTiles.first,
          let sourceGainFirst = source.gainTiles.first,
          let scaffoldGainFirst = scaffold.gainTiles.first,
          source.hvcCByItem[sourceBaseFirst] == scaffold.hvcCByItem[scaffoldBaseFirst],
          source.hvcCByItem[sourceGainFirst] == scaffold.hvcCByItem[scaffoldGainFirst] else {
        throw CLIError.invalidContainer("first assembly/scaffold tile codec graph differs")
    }
    struct Replacement {
        let itemID: Int
        let offset: Int
        let length: Int
        let payload: Data
        var delta: Int { payload.count - length }
    }
    let pairs = Array(zip(source.baseTiles, scaffold.baseTiles))
        + Array(zip(source.gainTiles, scaffold.gainTiles))
    var replacements: [Replacement] = []
    for (sourceID, scaffoldID) in pairs {
        guard let sourceLocation = source.locations[sourceID],
              let scaffoldLocation = scaffold.locations[scaffoldID],
              scaffoldLocation.constructionMethod == 0,
              scaffoldLocation.extents.count == 1 else {
            throw CLIError.invalidContainer("portrait tile does not have one file extent")
        }
        replacements.append(Replacement(
            itemID: scaffoldID,
            offset: scaffoldLocation.extents[0].offset,
            length: scaffoldLocation.extents[0].length,
            payload: try itemPayload(in: sourceData, entry: sourceLocation, idat: source.idat)
        ))
    }
    let replacementByID = Dictionary(uniqueKeysWithValues: replacements.map { ($0.itemID, $0) })
    let iloc = scaffold.iloc
    let version = scaffoldData[iloc.dataStart]
    let sizeField = scaffoldData[iloc.dataStart + 4]
    let sizeField2 = scaffoldData[iloc.dataStart + 5]
    let offsetSize = Int(sizeField >> 4)
    let lengthSize = Int(sizeField & 0x0f)
    let baseOffsetSize = Int(sizeField2 >> 4)
    let indexSize = (version == 1 || version == 2) ? Int(sizeField2 & 0x0f) : 0
    guard offsetSize == 4, lengthSize == 4, baseOffsetSize == 0 else {
        throw CLIError.invalidContainer("unsupported portrait scaffold iloc")
    }
    var position = iloc.dataStart + 6
    let itemCount: Int
    if version < 2 { itemCount = readUInt16BEUnchecked(scaffoldData, at: position); position += 2 }
    else { itemCount = readUInt32BEUnchecked(scaffoldData, at: position); position += 4 }
    var fields: [(itemID: Int, offsetPosition: Int, lengthPosition: Int)] = []
    for _ in 0..<itemCount {
        let itemID: Int
        if version < 2 { itemID = readUInt16BEUnchecked(scaffoldData, at: position); position += 2 }
        else { itemID = readUInt32BEUnchecked(scaffoldData, at: position); position += 4 }
        var constructionMethod = 0
        if version == 1 || version == 2 {
            constructionMethod = readUInt16BEUnchecked(scaffoldData, at: position) & 0x0f
            position += 2
        }
        position += 2 + baseOffsetSize
        let extentCount = readUInt16BEUnchecked(scaffoldData, at: position); position += 2
        for _ in 0..<extentCount {
            position += indexSize
            let offsetPosition = position; position += offsetSize
            let lengthPosition = position; position += lengthSize
            if constructionMethod == 0 { fields.append((itemID, offsetPosition, lengthPosition)) }
        }
    }
    func patchUInt32(_ value: Int, at position: Int) {
        var replacement = Data()
        appendUInt32BE(value, to: &replacement)
        scaffoldData.replaceSubrange(position..<(position + 4), with: replacement)
    }
    for field in fields {
        let oldOffset = readUInt32BEUnchecked(scaffoldData, at: field.offsetPosition)
        let shift = replacements.filter { $0.offset < oldOffset }.reduce(0) { $0 + $1.delta }
        patchUInt32(oldOffset + shift, at: field.offsetPosition)
        if let replacement = replacementByID[field.itemID] {
            patchUInt32(replacement.payload.count, at: field.lengthPosition)
        }
    }
    patchUInt32(
        scaffold.mdat.size + replacements.reduce(0) { $0 + $1.delta },
        at: scaffold.mdat.boxStart
    )
    for replacement in replacements.sorted(by: { $0.offset > $1.offset }) {
        scaffoldData.replaceSubrange(
            replacement.offset..<(replacement.offset + replacement.length),
            with: replacement.payload
        )
    }
    try scaffoldData.write(to: outputURL, options: .atomic)
}

LHDRToISOHDRCLI.main()
