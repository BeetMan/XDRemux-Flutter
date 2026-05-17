#!/usr/bin/env swift

import Foundation
import CoreGraphics
import CoreVideo
import Darwin
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

private enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case invalidCommand(String)
    case missingArgument(String)
    case unknownOption(String)
    case invalidValue(option: String, value: String)
    case inputNotFound(URL)
    case noFilesMatched(URL, String)
    case unableToRead(URL)
    case unableToCreateDirectory(URL)
    case outputParentIsNotDirectory(URL)
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
        case .unableToCreateDirectory(let url):
            return "unable to create directory: \(url.path)"
        case .outputParentIsNotDirectory(let url):
            return "output parent is not a directory: \(url.path)"
        case .qtiMarkerNotFound:
            return "QTI extension marker not found"
        case .manifestNotFound:
            return "OPPO manifest not found"
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
            return "written HEIC does not expose ISO HDR auxiliary data: \(url.path)"
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
    case hybrid
    case passthrough
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
    let oppoCompat: Bool
    let inputProcessingBranch: InputProcessingBranch
}

private struct BatchCommand {
    let inputDirURL: URL
    let outputDirURL: URL
    let family: Family
    let glob: String
    let debugRootURL: URL?
    let oppoCompat: Bool
    let inputProcessingBranch: InputProcessingBranch
}

private struct ManifestEntry {
    let name: String
    let offset: Int
    let length: Int
    let version: Any?
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
        let extensionStart = try findExtensionStart(in: data)
        guard let manifestArray = parseManifest(in: data) else {
            throw CLIError.manifestNotFound
        }

        guard let jsonStart = lastIndex(of: Data("[{".utf8), in: data),
              let jsonEndBase = firstIndex(of: UInt8(ascii: "]"), in: data, startingAt: jsonStart) else {
            throw CLIError.manifestNotFound
        }
        let jsonEnd = jsonEndBase + 1

        var entries: [ManifestEntry] = []
        for raw in manifestArray {
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
                    start: offsetValue - lengthValue,
                    end: offsetValue
                )
            )
        }
        entries.sort { $0.start < $1.start }

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
        oppoCompat: Bool = false,
        inputProcessingBranch: InputProcessingBranch = .system
    ) throws {
        if inputProcessingBranch == .hybrid {
            // Phase 1: write intermediate using existing aux-data path
            let intermediateURL = outputURL.appendingPathExtension("intermediate")
            let source = try makeImageSource(url: baseImageURL)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            var patchedUserComment: String?
            if oppoCompat {
                let sourceData = try Data(contentsOf: baseImageURL)
                patchedUserComment = patchedOppoUserComment(in: sourceData)
            }
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
                inputProcessingBranch: .system
            )

            // Phase 2: re-read intermediate and write with preserve
            try writeWithPreserveReencode(
                intermediateURL: intermediateURL,
                outputURL: outputURL,
                patchedUserComment: patchedUserComment
            )
            try? FileManager.default.removeItem(at: intermediateURL)
        } else {
            let source = try makeImageSource(url: baseImageURL)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]

            // Extract patched UserComment from source file bytes (bypasses ImageIO typing issues).
            var patchedUserComment: String?
            if oppoCompat {
                let sourceData = try Data(contentsOf: baseImageURL)
                patchedUserComment = patchedOppoUserComment(in: sourceData)
            }

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
                inputProcessingBranch: inputProcessingBranch
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
        inputProcessingBranch: InputProcessingBranch
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
        try configureGainMapEncodingOptions(&requestOptions, channelCount: gainMapChannelCount, branch: inputProcessingBranch)

        var imageOptions: [CFString: Any] = [
            kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOGainmap,
            kCGImageDestinationEncodeRequestOptions: requestOptions as CFDictionary,
            kCGImageDestinationMergeMetadata: primaryMetadata
        ]
        
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

        CGImageDestinationAddImageFromSource(destination, source, 0, imageOptions as CFDictionary)
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
        patchedUserComment: String? = nil
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
        case .system, .hybrid, .passthrough:
            return nil
        }
    }

    private static func configureGainMapEncodingOptions(
        _ requestOptions: inout [CFString: Any],
        channelCount: Int,
        branch: InputProcessingBranch
    ) throws {
        switch branch {
        case .system, .hybrid, .passthrough:
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

private enum XDRemuxProductCore {
    private static let fileManager = FileManager.default

    static func convert(
        inputURL: URL,
        outputURL: URL,
        familyPreference: Family,
        debugRootURL: URL?,
        oppoCompat: Bool = false,
        inputProcessingBranch: InputProcessingBranch = .hybrid
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

        try ProductGainMapWriter.write(
            inputURL: inputURL,
            outputURL: actualOutputURL,
            sourceData: sourceData,
            productInput: productInput,
            oppoCompat: oppoCompat,
            inputProcessingBranch: inputProcessingBranch
        )

        if oppoCompat {
            try appendOppoCompatibilityPayload(
                outputURL: actualOutputURL,
                sourceData: sourceData,
                extracted: productInput.extracted,
                scale: productInput.scale,
                gainMapRaster: productInput.gainMapRaster
            )
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
        oppoCompat: Bool,
        inputProcessingBranch: InputProcessingBranch
    ) throws {
        switch inputProcessingBranch {
        case .system:
            try ISOHDRWriter.write(
                baseImageURL: inputURL,
                gainMap: productInput.gainMapRaster,
                style: productInput.style,
                outputURL: outputURL,
                oppoCompat: oppoCompat,
                inputProcessingBranch: .system
            )
        case .hybrid:
            try HybridGainMapWriter.write(
                inputURL: inputURL,
                outputURL: outputURL,
                sourceData: sourceData,
                productInput: productInput,
                oppoCompat: oppoCompat
            )
        case .passthrough:
            try DirectPassthroughGainMapWriter.write(
                inputURL: inputURL,
                outputURL: outputURL,
                sourceData: sourceData,
                productInput: productInput,
                oppoCompat: oppoCompat
            )
        }
    }
}

private enum HybridGainMapWriter {
    static func write(
        inputURL: URL,
        outputURL: URL,
        sourceData: Data,
        productInput: XDRemuxProductCore.ProductInput,
        oppoCompat: Bool
    ) throws {
        let parent = outputURL.deletingLastPathComponent()
        let stem = outputURL.deletingPathExtension().lastPathComponent
        let privateIntermediateURL = parent.appendingPathComponent(".\(stem).hybrid-private-\(UUID().uuidString).heic")
        let preservedURL = parent.appendingPathComponent(".\(stem).hybrid-preserve-\(UUID().uuidString).heic")
        defer {
            try? FileManager.default.removeItem(at: privateIntermediateURL)
            try? FileManager.default.removeItem(at: preservedURL)
        }

        let patchedUserComment = oppoCompat ? patchedOppoUserComment(in: sourceData) : nil
        switch productInput.extracted.mode {
        case .uhdr:
            _ = try writePrivateJPEGPassthroughOutput(
                inputURL: inputURL,
                outputURL: privateIntermediateURL,
                infoFloats: productInput.extracted.metaFloats,
                gainMapJPEG: productInput.extracted.maskJPEGData,
                patchedUserComment: patchedUserComment
            )
            try ISOHDRWriter.writeWithPreserveReencode(
                intermediateURL: privateIntermediateURL,
                outputURL: preservedURL,
                patchedUserComment: patchedUserComment
            )
        case .lhdr:
            try ISOHDRWriter.write(
                baseImageURL: inputURL,
                gainMap: productInput.gainMapRaster,
                style: productInput.style,
                outputURL: preservedURL,
                oppoCompat: false,
                inputProcessingBranch: .hybrid
            )
        }

        try writeHybridPrimaryPassthrough(
            sourceURL: inputURL,
            preservedURL: preservedURL,
            outputURL: outputURL,
            patchedUserComment: patchedUserComment
        )
    }
}

private enum DirectPassthroughGainMapWriter {
    static func write(
        inputURL: URL,
        outputURL: URL,
        sourceData: Data,
        productInput: XDRemuxProductCore.ProductInput,
        oppoCompat: Bool
    ) throws {
        let patchedUserComment = oppoCompat ? patchedOppoUserComment(in: sourceData) : nil
        _ = try writePrivateJPEGPassthroughOutput(
            inputURL: inputURL,
            outputURL: outputURL,
            infoFloats: privateGainMapInfoFloats(for: productInput),
            gainMapJPEG: productInput.extracted.maskJPEGData,
            patchedUserComment: patchedUserComment
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

struct LHDRToISOHDRCLI {
    private static let fileManager = FileManager.default
    private static let usage = """
    Usage:
            XDRemux.swift convert --input <file.heic> [--output <out.heic>] [--debug-dir <dir>] [--oppo-compat] [--input-processing system|hybrid|passthrough]
            XDRemux.swift batch --input-dir <dir> [--output-dir <dir>] [--glob *.heic] [--debug-dir <dir>] [--oppo-compat] [--input-processing system|hybrid|passthrough]

    Notes:
      - Input processing defaults to hybrid.
      - system: ImageIO writes the final HEIC directly.
      - hybrid: ImageIO/Preserve produces HEVC gain map, then XDRemux grafts the original primary subtree.
      - passthrough: experimental direct ISOBMFF rewrite that keeps ImageIO ISO gain-map readability.
      - If --output is omitted, the input file is overwritten in place.
      - If --output-dir is omitted, files are written to the input directory.
      - OPPO Gallery compatibility metadata is off by default; pass --oppo-compat only when targeting OPPO Gallery.
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
            FileHandle.standardError.write(Data("error: \(error)\n\n\(usage)\n".utf8))
            exit(1)
        }
    }

    private static func runConvert(_ cmd: ConvertCommand) throws {
        let report = try XDRemuxProductCore.convert(
            inputURL: cmd.inputURL,
            outputURL: cmd.outputURL,
            familyPreference: cmd.family,
            debugRootURL: cmd.debugRootURL,
            oppoCompat: cmd.oppoCompat,
            inputProcessingBranch: cmd.inputProcessingBranch
        )
        print("converted \(report.inputURL.lastPathComponent) -> \(report.outputURL.path)")
    }

    private static func runBatch(_ cmd: BatchCommand) throws {
        try ensureDirectory(cmd.outputDirURL, fileManager: fileManager)
        let matched = try enumerateInputs(root: cmd.inputDirURL, glob: cmd.glob)
        guard !matched.isEmpty else {
            throw CLIError.noFilesMatched(cmd.inputDirURL, cmd.glob)
        }

        var reports: [SampleReport] = []
        var failures = 0
        for inputURL in matched {
            do {
                let stem = inputURL.deletingPathExtension().lastPathComponent
                let outputURL = cmd.outputDirURL.appendingPathComponent("\(stem).heic")
                let report = try XDRemuxProductCore.convert(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    familyPreference: cmd.family,
                    debugRootURL: cmd.debugRootURL,
                    oppoCompat: cmd.oppoCompat,
                    inputProcessingBranch: cmd.inputProcessingBranch
                )
                reports.append(report)
                print("converted \(inputURL.lastPathComponent)")
            } catch {
                print("skipped \(inputURL.lastPathComponent): \(error)")
                failures += 1
            }
        }

        print("batch complete: converted \(reports.count) files, skipped \(failures) files into \(cmd.outputDirURL.path)")
    }

    private static func parseConvert(_ rawArgs: [String]) throws -> ConvertCommand {
        var inputPath: String?
        var outputPath: String?
        var family = Family.auto
        var debugDirPath: String?
        var oppoCompat = false
        var inputProcessingBranch = InputProcessingBranch.hybrid

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
            case "--oppo-compat":
                oppoCompat = true
            case "--no-oppo-compat":
                oppoCompat = false
            default:
                throw CLIError.unknownOption(option)
            }
        }

        guard let inputPath else { throw CLIError.missingArgument("--input") }

        return ConvertCommand(
            inputURL: URL(fileURLWithPath: inputPath),
            outputURL: URL(fileURLWithPath: outputPath ?? inputPath),
            family: family,
            debugRootURL: debugDirPath.map { URL(fileURLWithPath: $0) },
            oppoCompat: oppoCompat,
            inputProcessingBranch: inputProcessingBranch
        )
    }

    private static func parseBatch(_ rawArgs: [String]) throws -> BatchCommand {
        var inputDirPath: String?
        var outputDirPath: String?
        var family = Family.auto
        var glob = "*.heic"
        var debugDirPath: String?
        var oppoCompat = false
        var inputProcessingBranch = InputProcessingBranch.hybrid

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
            case "--debug-dir":
                debugDirPath = try nextValue(for: option)
            case "--oppo-compat":
                oppoCompat = true
            case "--no-oppo-compat":
                oppoCompat = false
            default:
                throw CLIError.unknownOption(option)
            }
        }

        guard let inputDirPath else { throw CLIError.missingArgument("--input-dir") }

        return BatchCommand(
            inputDirURL: URL(fileURLWithPath: inputDirPath),
            outputDirURL: URL(fileURLWithPath: outputDirPath ?? inputDirPath),
            family: family,
            glob: glob,
            debugRootURL: debugDirPath.map { URL(fileURLWithPath: $0) },
            oppoCompat: oppoCompat,
            inputProcessingBranch: inputProcessingBranch
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
private let oppoTagFlagPrefixes = [
    "ASCIIOplus_",
    "ASCIIoppo_",
    "Oplus_",
    "oplus_",
    "oppo_"
]

/// Extract and patch OPPO tagflags to include OPLUS_ULTRA_HDR.
private func patchedOppoUserComment(in data: Data) -> String? {
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
                return "\(prefix)\(flags | oppoUltraHDRFlag)"
            }
            searchRange = range.upperBound..<data.endIndex
        }
    }
    return nil
}

private func patchOppoUserComment(_ data: inout Data, patchedUserComment: String) -> Bool {
    for prefix in oppoTagFlagPrefixes {
        guard patchedUserComment.hasPrefix(prefix) else { continue }
        let patchedDigits = String(patchedUserComment.dropFirst(prefix.count))
        let prefixData = Data(prefix.utf8)
        var searchRange: Range<Data.Index>? = data.startIndex..<data.endIndex
        while let range = data.range(of: prefixData, options: [], in: searchRange) {
            var digitEnd = range.upperBound
            while digitEnd < data.count, (48...57).contains(data[digitEnd]) {
                digitEnd += 1
            }
            let digitCount = digitEnd - range.upperBound
            guard digitCount > 0, patchedDigits.count <= digitCount else {
                searchRange = range.upperBound..<data.endIndex
                continue
            }

            var replacement = prefixData
            replacement.append(Data(repeating: UInt8(ascii: "0"), count: digitCount - patchedDigits.count))
            replacement.append(Data(patchedDigits.utf8))
            data.replaceSubrange(range.lowerBound..<digitEnd, with: replacement)
            return true
        }
    }
    return false
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
private let isoColrPQBox = Data([
    0x00, 0x00, 0x00, 0x13, 0x63, 0x6f, 0x6c, 0x72,
    0x6e, 0x63, 0x6c, 0x78, 0x00, 0x09, 0x00, 0x10,
    0x00, 0x09, 0x80,
])
private let isoColrSRGBBox = Data([
    0x00, 0x00, 0x00, 0x13, 0x63, 0x6f, 0x6c, 0x72,
    0x6e, 0x63, 0x6c, 0x78, 0x00, 0x02, 0x00, 0x02,
    0x00, 0x02, 0x80,
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
    var altrPayload = Data([0, 0, 0, 0])
    appendUInt32BE(groupID, to: &altrPayload)
    appendUInt32BE(2, to: &altrPayload)
    appendUInt32BE(tmapID, to: &altrPayload)
    appendUInt32BE(primaryID, to: &altrPayload)
    var grplPayload = Data()
    grplPayload.append(makeBox("altr", payload: altrPayload))
    return makeBox("grpl", payload: grplPayload)
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
    patchedUserComment: String?
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

    let sourceTmapIDs = Set(sourceItemInfo.items.filter { $0.type == "tmap" }.map(\.itemID))
    var dropSourceIDs = Set(sourceItemInfo.items.filter { $0.type == "jpeg" }.map(\.itemID))
    dropSourceIDs.formUnion(sourceTmapIDs)
    var changed = true
    while changed {
        changed = false
        for ref in sourceRefsInfo.refs where dropSourceIDs.contains(ref.from) {
            for target in ref.to where target != sourcePrimaryID && !dropSourceIDs.contains(target) {
                dropSourceIDs.insert(target)
                changed = true
            }
        }
        for ref in sourceRefsInfo.refs where ref.type == "cdsc" && !dropSourceIDs.isDisjoint(with: Set(ref.to)) {
            if !dropSourceIDs.contains(ref.from) {
                dropSourceIDs.insert(ref.from)
                changed = true
            }
        }
    }

    let keptSourceItems = sourceItemInfo.items.filter { !dropSourceIDs.contains($0.itemID) }
    let keptSourceIDs = Set(keptSourceItems.map(\.itemID))
    let keptSourceIlocEntries = sourceIlocEntries.filter { keptSourceIDs.contains($0.itemID) }
    guard keptSourceIDs.contains(sourcePrimaryID) else {
        throw CLIError.invalidContainer("hybrid graft would drop primary item")
    }

    let maxSourceID = keptSourceItems.map(\.itemID).max() ?? sourcePrimaryID
    let copiedItemCount = preservedGainTileIDs.count + 2 + (preservedXMPID == nil ? 0 : 1)
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
    if preservedXMPID != nil {
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
    let tmapPayload = try itemPayload(in: preserved, entry: tmapEntry, idat: preservedIDAT)
    let xmpPayload: Data?
    if let preservedXMPID {
        guard let xmpEntry = preservedIlocByID[preservedXMPID] else {
            throw CLIError.invalidContainer("preserve XMP item has no iloc entry")
        }
        xmpPayload = try itemPayload(in: preserved, entry: xmpEntry, idat: preservedIDAT)
    } else {
        xmpPayload = nil
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
    var primaryAssocs = assocPairs(sourceIPMAByID[sourcePrimaryID]?.associations ?? [], flags: sourceIPMA.flags)
    if primaryAssocs.isEmpty,
       let firstIspe = sourceProps.first(where: { $0.type == "ispe" })?.index {
        primaryAssocs.append((firstIspe, true))
    }
    func primaryHasPropertyType(_ type: String) -> Bool {
        primaryAssocs.contains { propertyType($0, in: sourcePropsByIndex) == type }
    }
    if let preservedPrimaryEntry = preservedIPMAByID[preservedPrimaryID] {
        for value in preservedPrimaryEntry.associations {
            let index = assocPropertyIndex(value, flags: preservedIPMA.flags)
            guard let prop = preservedPropsByIndex[index],
                  ["colr", "clli", "pixi", "irot"].contains(prop.type),
                  !primaryHasPropertyType(prop.type) else { continue }
            primaryAssocs.append((try mapPreservedProperty(index), assocIsEssential(value, flags: preservedIPMA.flags)))
        }
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
    ipmaEntries.append(try makeIPMAEntry(outputGainGridID, try remapPreservedAssocs(preservedGainGridIPMA.associations), flags: sourceIPMA.flags))
    ipmaEntryCount += 1
    ipmaEntries.append(try makeIPMAEntry(outputTmapID, try remapPreservedAssocs(preservedTmapIPMA.associations), flags: sourceIPMA.flags))
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
    if let outputXMPID, let preservedXMPID {
        rawInfes.append(makeMimeInfeBox(itemID: outputXMPID, flags: preservedItemsByID[preservedXMPID]?.flags ?? 1))
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

    let sourceRefs = sourceRefsInfo.refs.filter { ref in
        !dropSourceIDs.contains(ref.from) && dropSourceIDs.isDisjoint(with: Set(ref.to))
    }
    var outputRefs: [ISOBMFFIRefEntry] = []
    var updatedSourceCdsc = false
    for ref in sourceRefs {
        if ref.type == "cdsc", ref.to.contains(sourcePrimaryID) {
            outputRefs.append(ISOBMFFIRefEntry(type: ref.type, from: ref.from, to: [sourcePrimaryID, outputTmapID]))
            updatedSourceCdsc = true
        } else {
            outputRefs.append(ref)
        }
    }
    if !updatedSourceCdsc,
       let exifID = keptSourceItems.first(where: { $0.type == "Exif" })?.itemID {
        outputRefs.append(ISOBMFFIRefEntry(type: "cdsc", from: exifID, to: [sourcePrimaryID, outputTmapID]))
    }
    outputRefs.append(ISOBMFFIRefEntry(type: "dimg", from: outputGainGridID, to: gainTilePayloads.map(\.newID)))
    outputRefs.append(ISOBMFFIRefEntry(type: "dimg", from: outputTmapID, to: [sourcePrimaryID, outputGainGridID]))
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
    let groupID = max(nextItemID, outputTmapID) + 1
    metaParts.append(makeGrplAltrBox(groupID: groupID, tmapID: outputTmapID, primaryID: sourcePrimaryID))

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
        let extents = entry.extents.map { extent -> (offset: Int, length: Int) in
            if entry.constructionMethod == 0 {
                return (extent.offset + fileDelta, extent.length)
            }
            return extent
        }
        finalIlocEntries.append(ISOBMFFILocEntry(itemID: entry.itemID, constructionMethod: entry.constructionMethod, dataReferenceIndex: entry.dataReferenceIndex, extents: extents))
    }
    var appendedMdatPayload = Data()
    for tile in gainTilePayloads {
        let offset = newMdatDataStart + (sourceMdat.dataEnd - sourceMdat.dataStart) + appendedMdatPayload.count
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

    var mdatPayload = source.subdata(in: sourceMdat.dataStart..<sourceMdat.dataEnd)
    mdatPayload.append(appendedMdatPayload)
    let mdatPart = makeBox("mdat", payload: mdatPayload)

    var out = Data()
    out.append(ftypPart)
    out.append(finalMetaPart)
    out.append(betweenMetaAndMdat)
    out.append(mdatPart)
    if let patchedUserComment {
        guard patchOppoUserComment(&out, patchedUserComment: patchedUserComment) else {
            throw CLIError.invalidContainer("unable to patch OPPO UserComment in hybrid output")
        }
    }
    try out.write(to: outputURL)
}

private func writePrivateJPEGPassthroughOutput(
    inputURL: URL,
    outputURL: URL,
    infoFloats: [Double],
    gainMapJPEG: Data,
    patchedUserComment: String? = nil
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
    let pqIndex = oldPropCount + 4
    let gmPixiIndex = oldPropCount + 5
    let tmapPixiIndex = oldPropCount + 6
    let gmIspeIndex = oldPropCount + 7
    let oldIDATSize = idat.size - 8
    let tmapPayload = makeAppleTmapPayload(infoFloats: infoFloats)
    let xmpPayload = makeHdrgmXMP(infoFloats: infoFloats)

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
            ipcoPayload.append(isoColrPQBox)
            ipcoPayload.append(isoPixiRGB8Box)
            ipcoPayload.append(isoPixiRGB10Box)
            ipcoPayload.append(makeIspeBox(width: gainMapSize.0, height: gainMapSize.1))
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
            ipmaPayload.append(try makeIPMAEntry(tmapID, [(primaryIspeIndex, true), (tmapPixiIndex, true), (pqIndex, true)], flags: ipma.flags))
            let ipmaPart = makeBox("ipma", payload: ipmaPayload)
            var iprpPayload = Data()
            iprpPayload.append(ipcoPart)
            iprpPayload.append(ipmaPart)
            metaParts.append(makeBox("iprp", payload: iprpPayload))
        case "iref":
            var payload = src.subdata(in: part.dataStart..<part.dataEnd)
            let version = parseISOBMFFIRefVersion(src, iref)
            payload.append(makeIrefBox(type: "dimg", from: tmapID, to: [primaryID, gainMapID], version: version))
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
    let gainMapOffset = newMdatDataStart + (mdat.dataEnd - mdat.dataStart)

    var ilocPayload = Data([1, 0, 0, 0, 0x44, 0x00])
    appendUInt16BE(ilocEntries.count + 3, to: &ilocPayload)
    for entry in ilocEntries {
        appendUInt16BE(entry.itemID, to: &ilocPayload)
        appendUInt16BE(entry.constructionMethod, to: &ilocPayload)
        appendUInt16BE(entry.dataReferenceIndex, to: &ilocPayload)
        appendUInt16BE(entry.extents.count, to: &ilocPayload)
        for extent in entry.extents {
            appendUInt32BE(entry.constructionMethod == 0 ? extent.offset + fileDelta : extent.offset, to: &ilocPayload)
            appendUInt32BE(extent.length, to: &ilocPayload)
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

    var mdatPayload = src.subdata(in: mdat.dataStart..<mdat.dataEnd)
    mdatPayload.append(gainMapJPEG)
    let mdatPart = makeBox("mdat", payload: mdatPayload)
    var out = Data()
    out.append(ftypPart)
    out.append(finalMetaPart)
    out.append(betweenMetaAndMdat)
    out.append(mdatPart)
    if let patchedUserComment {
        guard patchOppoUserComment(&out, patchedUserComment: patchedUserComment) else {
            throw CLIError.invalidContainer("unable to patch OPPO UserComment in UHDR pass-through output")
        }
    }
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

private func makeOppoUhdrInfoData(scale: ResolvedScale) -> Data {
    let floats = makePrivateGainMapInfoFloats(scale: scale).map(Float.init)
    var data = Data()
    for value in floats {
        var bits = value.bitPattern.littleEndian
        data.append(Data(bytes: &bits, count: 4))
    }
    return data
}

private func appendOppoCompatibilityPayload(
    outputURL: URL,
    sourceData: Data,
    extracted: ExtractedLHDR,
    scale: ResolvedScale,
    gainMapRaster: GainMapRaster
) throws {
    guard extracted.dataBase >= 0, extracted.dataBase < sourceData.count else { return }

    if extracted.mode == .lhdr {
        guard extracted.manifestInfo.extensionStart >= 0,
              extracted.manifestInfo.extensionStart < sourceData.count else { return }
        let tail = sourceData.subdata(in: extracted.manifestInfo.extensionStart..<sourceData.count)
        let fileHandle = try FileHandle(forWritingTo: outputURL)
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: tail)
        try fileHandle.close()
        return
    }

    let namesToSkip: Set<String> = [
        "local.hdr.meta.data",
        "local.hdr.linear.mask",
        "local.uhdr.gainmap.info",
        "local.uhdr.gainmap.data"
    ]
    var repackedData = Data()
    var pendingEntries: [[String: Any]] = []

    func appendManifestEntry(name: String, payload: Data, version: Any) {
        let start = repackedData.count
        repackedData.append(payload)
        pendingEntries.append([
            "name": name,
            "length": payload.count,
            "start": start,
            "version": version
        ])
    }

    for entry in extracted.manifestInfo.entries {
        if namesToSkip.contains(entry.name) { continue }

        let startPos = extracted.manifestInfo.jsonStart - entry.offset
        let endPos = startPos + entry.length
        if startPos >= 0 && endPos <= sourceData.count {
            appendManifestEntry(
                name: entry.name,
                payload: sourceData.subdata(in: startPos..<endPos),
                version: entry.version ?? 1
            )
            continue
        }

        let calibratedStart = extracted.dataBase + entry.start
        let calibratedEnd = calibratedStart + entry.length
        if calibratedStart >= 0 && calibratedEnd <= sourceData.count {
            appendManifestEntry(
                name: entry.name,
                payload: sourceData.subdata(in: calibratedStart..<calibratedEnd),
                version: entry.version ?? 1
            )
        }
    }

    if extracted.mode == .uhdr {
        appendManifestEntry(name: "local.uhdr.gainmap.info", payload: extracted.metaBytes, version: 1)
        appendManifestEntry(name: "local.uhdr.gainmap.data", payload: extracted.maskJPEGData, version: 1)
    } else {
        appendManifestEntry(name: "local.uhdr.gainmap.info", payload: makeOppoUhdrInfoData(scale: scale), version: 1)
        if let gmJpeg = gainMapRasterToJPEG(gainMapRaster) {
            appendManifestEntry(name: "local.uhdr.gainmap.data", payload: gmJpeg, version: 1)
        }
    }
    guard !pendingEntries.isEmpty else { return }

    let payloadLength = repackedData.count
    let newEntries: [[String: Any]] = pendingEntries.map { entry in
        var manifestEntry = entry
        let start = manifestEntry.removeValue(forKey: "start") as? Int ?? 0
        manifestEntry["offset"] = payloadLength - start
        return manifestEntry
    }
    let manifestJSON = try JSONSerialization.data(withJSONObject: newEntries, options: [])
    let footerLength = manifestJSON.count + 1 + 8
    let headerSize = 2168
    let totalRegionSize = headerSize + payloadLength + footerLength

    var header = Data(count: headerSize)
    header.withUnsafeMutableBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        base.storeBytes(of: UInt32(totalRegionSize).bigEndian, as: UInt32.self)
        base.advanced(by: 4).storeBytes(of: Float(1.2).bitPattern.littleEndian, as: UInt32.self)
    }
    header[8] = 0xFF
    let deviceName = Data("XDRemux\0".utf8)
    header.replaceSubrange(9..<(9 + deviceName.count), with: deviceName)

    var finalPayload = Data()
    finalPayload.append(header)
    finalPayload.append(repackedData)
    finalPayload.append(manifestJSON)
    finalPayload.append(0)
    finalPayload.append(Data("jxrs".utf8))
    var footerLengthLE = UInt32(footerLength).littleEndian
    finalPayload.append(Data(bytes: &footerLengthLE, count: 4))

    let fileHandle = try FileHandle(forWritingTo: outputURL)
    try fileHandle.seekToEnd()
    try fileHandle.write(contentsOf: finalPayload)
    try fileHandle.close()
}

/// Encode gain map raster as JPEG for OPPO UHDR extension.
private func gainMapRasterToJPEG(_ raster: GainMapRaster) -> Data? {
    let isColor = raster.channelCount == 3
    let bpp = isColor ? 32 : 8
    guard let provider = CGDataProvider(data: raster.data as CFData),
          let image = CGImage(
            width: raster.width, height: raster.height,
            bitsPerComponent: 8, bitsPerPixel: bpp,
            bytesPerRow: raster.bytesPerRow,
            space: isColor ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: isColor
                ? (CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
                : CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
          ) else { return nil }
    let jpegData = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(jpegData as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return jpegData as Data
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

LHDRToISOHDRCLI.main()
