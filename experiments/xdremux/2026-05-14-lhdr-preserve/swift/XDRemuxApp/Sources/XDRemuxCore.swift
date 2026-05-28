

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

enum XDRemuxError: Error, CustomStringConvertible {
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
        }
    }
}

enum Family: String {
    case auto
    case x6
    case x7
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

struct ResolvedScale {
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

struct GainMapParams {
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
            note: "If >= 1.0, native code uses this directly instead of computing EDR."
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

struct SampleReport {
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

        if let infoEntry = manifestInfo.entries.first(where: { $0.name == "local.uhdr.gainmap.info" }),
           let dataEntry = manifestInfo.entries.first(where: { $0.name == "local.uhdr.gainmap.data" }) {
            
            let infoStart = dataBase + infoEntry.start
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
            
            let dataStart = dataBase + dataEntry.start
            let dataEnd = dataStart + dataEntry.length
            guard dataStart >= 0, dataEnd <= data.count else { throw XDRemuxError.invalidLHDR("Out of bounds UHDR data block") }
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

        let metaBytes = try extractMeta(from: data, manifestInfo: manifestInfo, dataBase: dataBase)
        let localHDRInfo = try decodeLocalHDRInfo(from: metaBytes)
        let maskJPEGData = try extractMask(from: data, manifestInfo: manifestInfo, dataBase: dataBase)
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

    private static func locateManifest(in data: Data) throws -> ManifestInfo {
        let extensionStart = try findExtensionStart(in: data)
        guard let manifestArray = parseManifest(in: data) else {
            throw XDRemuxError.manifestNotFound
        }

        guard let jsonStart = lastIndex(of: Data("[{".utf8), in: data),
              let jsonEndBase = firstIndex(of: UInt8(ascii: "]"), in: data, startingAt: jsonStart) else {
            throw XDRemuxError.manifestNotFound
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
        throw XDRemuxError.qtiMarkerNotFound
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

    /// On-demand block extraction: only copies data when actually needed.
    private static func extractBlock(
        named name: String,
        from data: Data,
        manifestInfo: ManifestInfo,
        dataBase: Int
    ) -> Data? {
        guard let entry = manifestInfo.entries.first(where: { $0.name == name }) else { return nil }
        let start = dataBase + entry.start
        let end = start + entry.length
        guard start >= 0, end <= data.count else { return nil }
        return data.subdata(in: start..<end)
    }

    private static func extractMeta(
        from data: Data,
        manifestInfo: ManifestInfo,
        dataBase: Int
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

        // On-demand extraction: only copy this specific block when needed
        if let block = extractBlock(named: "local.hdr.meta.data", from: data, manifestInfo: manifestInfo, dataBase: dataBase),
           block.count >= 144 {
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
            throw XDRemuxError.invalidLHDR("failed to locate plausible 144-byte local.hdr.meta.data block")
        }
        return best.chunk
    }

    private static func extractMask(
        from data: Data,
        manifestInfo: ManifestInfo,
        dataBase: Int
    ) throws -> Data {
        // On-demand extraction: only copy the mask block
        if let mask = extractBlock(named: "local.hdr.linear.mask", from: data, manifestInfo: manifestInfo, dataBase: dataBase),
           mask.starts(with: Data([0xFF, 0xD8])) {
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
            throw XDRemuxError.invalidLHDR("failed to locate local.hdr.linear.mask JPEG")
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
            throw XDRemuxError.unableToDecodeMask(sourceURL)
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw XDRemuxError.unableToDecodeMask(sourceURL)
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
                throw XDRemuxError.unableToDecodeMask(sourceURL)
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
                throw XDRemuxError.unableToDecodeMask(sourceURL)
            }

            return GainMapRaster(width: width, height: height, bytesPerRow: bytesPerRow, channelCount: 1, data: raster)
        }
    }
}

private enum EDRScaleResolver {
    static func resolve(metaFloats: [Double], mode: ExtractionMode) throws -> ResolvedScale {
        if mode == .uhdr {
            guard metaFloats.count >= 18 else {
                throw XDRemuxError.invalidLHDR("local.uhdr.gainmap.info must contain at least 20 float32 values")
            }
            let ratioMin = metaFloats[0]
            let ratioMax = metaFloats[3]
            let gamma = metaFloats[6]
            let epsilonSdr = metaFloats[9]
            let epsilonHdr = metaFloats[12]
            let displayRatioSdr = metaFloats[15]
            let displayRatioHdr = metaFloats[16]
            let scaleVal = metaFloats[17]
            
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
                perChannelGainMapMax: [safeLog2(metaFloats[3]), safeLog2(metaFloats[4]), safeLog2(metaFloats[5])],
                perChannelGamma: [metaFloats[6], metaFloats[7], metaFloats[8]],
                perChannelBaseOffset: [metaFloats[9], metaFloats[10], metaFloats[11]],
                perChannelAlternateOffset: [metaFloats[12], metaFloats[13], metaFloats[14]]
            )
        }

        guard metaFloats.count == 36 else {
            throw XDRemuxError.invalidLHDR("local.hdr.meta.data must contain exactly 36 float32 values")
        }

        return resolvedScale(
            edrScale: edrScaleCalculator(metaFloats),
            source: "empirical_edrScaleCalculator"
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

    /// Compute Reinhard tone-mapping knee point from EDR scale factor
    /// Calculation based on empirical EDR curve analysis and tone-mapping models.
    /// Constants derived from HDR standard gamma (1/2.2) and SDR scaling factors.
    static func getKneePoint(_ edr: Double) -> Double {
        let invGamma = 1.0 / 2.2  // 0x3EE8BA2E = 0.454545
        let edrScaled = edr * 100.0  // 0x42C80000
        let t = 1.0 / edrScaled
        let k = 1.0 - t

        // Three-stage power chain for curve fitting
        let p1 = pow(edr, invGamma)
        let div1 = 1.0 / p1
        let xNorm = (0.98 - t) / k        // 0x3F7AE148
        let p2 = pow(xNorm, invGamma)
        let y = (div1 - p2 * 1.00394) / (1.0 - div1)
        let p3 = pow(y, invGamma)

        // Reinhard knee point discretization and rounding
        let kneeRaw = p3 * 255.0 - 254.0
        let kneeAdj = kneeRaw / (p3 - 1.0)
        var result = kneeAdj.rounded(.toNearestOrAwayFromZero)
        if result <= 0.0 { result = kneeRaw }
        return result / 255.0
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

        // Simplified trace using current empirical model
        let preCorrectionEDR = scale.edrScale
        let finalEDR = scale.edrScale
        let faceCorrectionApplied = f.count > 24 ? f[24] > 0.0 : false
        let sqrtCorrectionApplied = f.count > 34 ? (Int(f[34]) == 1 || (f[24] > 0.0)) : false

        return CalibrationTrace(
            familyDetected: familyDetected.rawValue,
            familyUsed: familyUsed.rawValue,
            floatAudits: floatAudits,
            basePath: CalibrationTrace.BasePath(
                branch: "empirical_edrScaleCalculator",
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

        // Zero-copy read: access mask.data via withUnsafeBytes instead of copying to [UInt8]
        mask.data.withUnsafeBytes { maskBuffer in
            let maskBytes = maskBuffer.bindMemory(to: UInt8.self)
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
            knee = EDRScaleResolver.getKneePoint(scale.edrScale)
            kneeSource = "edr_lt3_reinhard_knee"
        }

        let kneeRange = 1.0 - knee
        guard knee.isFinite, kneeRange.isFinite, kneeRange > 0 else {
            throw XDRemuxError.invalidLHDR("non-finite gain map params: knee=\(knee), kneeRange=\(kneeRange)")
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
        sourceData: Data? = nil
    ) throws {
        let source = try makeImageSource(url: baseImageURL)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]

        // Extract patched UserComment from source file bytes (bypasses ImageIO typing issues).
        // Reuse caller-provided sourceData to avoid redundant file I/O.
        var patchedUserComment: String?
        if oppoCompat {
            let fileData = try sourceData ?? Data(contentsOf: baseImageURL)
            if let range = fileData.range(of: Data("oplus_".utf8)) {
                var digitEnd = range.upperBound
                while digitEnd < fileData.count, (48...57).contains(fileData[digitEnd]) { digitEnd += 1 }
                if let flagStr = String(data: fileData.subdata(in: range.upperBound..<digitEnd), encoding: .utf8),
                   let flags = Int(flagStr) {
                    patchedUserComment = "oplus_\(flags | 0x20000000)"
                }
            }
        }

        let metadata = try makeHDRToneMapMetadata(style: style)
        let auxInfo = try makeAuxiliaryDataInfo(gainMap: gainMap, metadata: metadata)
        let primaryMetadata = try makeUltraHDRXMPMetadata(style: style)
        try writeHEIC(source: source, originalProperties: properties, auxiliaryDataInfo: auxInfo, primaryMetadata: primaryMetadata, patchedUserComment: patchedUserComment, outputURL: outputURL)
        try verifyOutput(outputURL)
    }

    private static func makeImageSource(url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw XDRemuxError.unableToLoadBaseImage(url)
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
            throw XDRemuxError.unableToLoadBaseImage(url)
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
            throw XDRemuxError.unableToCreateMetadata
        }

        func set(_ path: String, _ value: CFTypeRef) throws {
            guard CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value) else {
                throw XDRemuxError.unableToCreateMetadata
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
            throw XDRemuxError.unableToCreateMetadata
        }

        func set(_ path: String, _ value: CFTypeRef) throws {
            guard CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value) else {
                throw XDRemuxError.unableToCreateMetadata
            }
        }

        try set("hdrgm:Version", "1.0" as CFString)
        try set("hdrgm:GainMapMin", formatFloat(style.gainMapMin, digits: 6) as CFString)
        try set("hdrgm:GainMapMax", formatFloat(style.gainMapMax, digits: 6) as CFString)
        try set("hdrgm:Gamma", formatFloat(style.gamma, digits: 6) as CFString)
        try set("hdrgm:OffsetSDR", formatFloat(style.baseOffset, digits: 6) as CFString)
        try set("hdrgm:OffsetHDR", formatFloat(style.alternateOffset, digits: 6) as CFString)
        try set("hdrgm:HDRCapacityMin", formatFloat(style.gainMapMin, digits: 6) as CFString)
        try set("hdrgm:HDRCapacityMax", formatFloat(style.gainMapMax, digits: 6) as CFString)
        try set("hdrgm:BaseRenditionIsHDR", "False" as CFString)

        return metadata
    }

    private static func makeAuxiliaryDataInfo(gainMap: GainMapRaster, metadata: CGImageMetadata) throws -> CFDictionary {
        let pixelFormat: UInt32 = gainMap.channelCount == 3 ? fourCC("BGRA") : fourCC("L008")

        let description: [CFString: Any] = [
            kCGImagePropertyWidth: NSNumber(value: gainMap.width),
            kCGImagePropertyHeight: NSNumber(value: gainMap.height),
            kCGImagePropertyBytesPerRow: NSNumber(value: gainMap.bytesPerRow),
            kCGImagePropertyPixelFormat: NSNumber(value: pixelFormat)
        ]

        let info: [CFString: Any] = [
            kCGImageAuxiliaryDataInfoData: gainMap.data,
            kCGImageAuxiliaryDataInfoDataDescription: description,
            kCGImageAuxiliaryDataInfoMetadata: metadata
        ]
        return info as CFDictionary
    }

    private static func writeHEIC(source: CGImageSource, originalProperties: [CFString: Any]?, auxiliaryDataInfo: CFDictionary, primaryMetadata: CGImageMetadata, patchedUserComment: String?, outputURL: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw XDRemuxError.unableToCreateDestination(outputURL)
        }

        var requestOptions: [CFString: Any] = [
            kCGImageDestinationEncodeBaseIsSDR: true,
            kCGImageDestinationLossyCompressionQuality: 1.0
        ]
        if #available(macOS 26.0, *) {
            requestOptions[kCGImageDestinationEncodeGainMapSubsampleFactor] = 1
        }

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
            imageOptions[kCGImagePropertyExifDictionary as CFString] = [
                kCGImagePropertyExifUserComment: patchedUserComment
            ] as CFDictionary
        }

        CGImageDestinationAddImageFromSource(destination, source, 0, imageOptions as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeISOGainMap, auxiliaryDataInfo)

        guard CGImageDestinationFinalize(destination) else {
            throw XDRemuxError.unableToFinalizeDestination(outputURL)
        }
    }

    private static func verifyOutput(_ outputURL: URL) throws {
        guard let source = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
              CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil else {
            throw XDRemuxError.outputVerificationFailed(outputURL)
        }
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
            throw XDRemuxError.unableToWriteDebugAsset(url)
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
            throw XDRemuxError.unableToWriteDebugAsset(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw XDRemuxError.unableToWriteDebugAsset(url)
        }
    }
}


/// Patch `oplus_<digits>` in a String to include OPLUS_ULTRA_HDR (0x20000000).
private func patchOplusTagFlags(in s: String) -> String {
    let prefix = "oplus_"
    guard let start = s.range(of: prefix)?.upperBound else { return s }
    let suffix = s[start...]
    guard let digitEnd = suffix.firstIndex(where: { !$0.isNumber }),
          let flags = Int(s[start..<digitEnd]) else { return s }
    var patched = s
    patched.replaceSubrange(start..<digitEnd, with: String(flags | 0x20000000))
    return patched
}

/// Patch `oplus_<digits>` in binary Data (EXIF UNDEFINED type).
private func patchOplusTagFlags(in data: Data) -> Data {
    let prefix = Data("oplus_".utf8)
    guard let range = data.range(of: prefix) else { return data }
    var digitEnd = range.upperBound
    while digitEnd < data.count, (48...57).contains(data[digitEnd]) { digitEnd += 1 }
    guard digitEnd > range.upperBound,
          let flagStr = String(data: data.subdata(in: range.upperBound..<digitEnd), encoding: .utf8),
          let flags = Int(flagStr) else { return data }
    var patched = data
    patched.replaceSubrange(range.upperBound..<digitEnd, with: Data(String(flags | 0x20000000).utf8))
    return patched
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
            throw XDRemuxError.outputParentIsNotDirectory(url)
        }
        return
    }
    do {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
        throw XDRemuxError.unableToCreateDirectory(url)
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
        throw XDRemuxError.invalidLHDR("out-of-range uint32 read at \(offset)")
    }
    // Zero-copy: read directly from Data's backing buffer (loadUnaligned handles arbitrary offsets)
    let value: UInt32 = data.withUnsafeBytes { buffer in
        buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
    }
    return UInt32(bigEndian: value)
}

private func unpack36FloatLE(_ data: Data) throws -> [Double] {
    try unpackFloatArrayLE(data, count: 36)
}

private func unpackFloatArrayLE(_ data: Data, count: Int) throws -> [Double] {
    guard data.count >= count * 4 else {
        throw XDRemuxError.invalidLHDR("float payload shorter than expected \(count * 4) bytes")
    }

    // Zero-copy: read all floats directly from Data's backing buffer
    var values: [Double] = []
    values.reserveCapacity(count)
    data.withUnsafeBytes { buffer in
        for index in 0..<count {
            let bits = buffer.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
            values.append(Double(Float(bitPattern: UInt32(littleEndian: bits))))
        }
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




enum XDRemuxCore {
    private static let fileManager = FileManager.default

    static func convert(
        inputURL: URL,
        outputURL: URL,
        familyPreference: Family,
        debugRootURL: URL?,
        oppoCompat: Bool = false
    ) throws -> SampleReport {
        guard fileManager.fileExists(atPath: inputURL.path) else {
            throw XDRemuxError.inputNotFound(inputURL)
        }

        let parentURL = outputURL.deletingLastPathComponent()
        try ensureDirectory(parentURL, fileManager: fileManager)

        let data: Data
        do {
            data = try Data(contentsOf: inputURL, options: [.mappedIfSafe])
        } catch {
            throw XDRemuxError.unableToRead(inputURL)
        }

        let extracted = try LHDRExtractor.extract(from: data)
        let detectedFamily: Family
        if extracted.mode == .uhdr {
            detectedFamily = .x7 // Force X7/newer branch conceptually
        } else {
            detectedFamily = extracted.metaFloats[0] >= 3.0 ? .x7 : .x6
        }
        let effectiveFamily = familyPreference == .auto ? detectedFamily : familyPreference

        let scale = try EDRScaleResolver.resolve(metaFloats: extracted.metaFloats, mode: extracted.mode)
        let decoderChannels = extracted.mode == .uhdr ? 3 : 1
        let maskRaster = try MaskDecoder.decodeMaskJPEG(extracted.maskJPEGData, sourceURL: inputURL, channelCount: decoderChannels)
        
        let gainMapRaster: GainMapRaster
        let params: GainMapParams
        if extracted.mode == .uhdr {
            gainMapRaster = maskRaster
            params = GainMapParams(family: effectiveFamily, knee: 0, kneeRange: 1, headroomScale: 0, maxBoost: 0, log2Scale: 0, kneeSource: "uhdr_precomputed_skip_reconstruction")
        } else {
            let reconstructed = try GainMapReconstructor.reconstruct(mask: maskRaster, family: effectiveFamily, scale: scale, metaFloats: extracted.metaFloats)
            gainMapRaster = reconstructed.raster
            params = reconstructed.params
        }
        let style = HDRToneMapStyle(
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

        let debugDirURL: URL?
        if let debugRootURL {
            let dir = debugRootURL.appendingPathComponent(inputURL.deletingPathExtension().lastPathComponent, isDirectory: true)
            try DebugWriter.writeArtifacts(
                extracted: extracted,
                inputURL: inputURL,
                debugDirURL: dir,
                familyDetected: detectedFamily,
                familyUsed: effectiveFamily,
                maskRaster: maskRaster,
                gainMapRaster: gainMapRaster,
                scale: scale,
                params: params,
                style: style
            )
            debugDirURL = dir
        } else {
            debugDirURL = nil
        }

        try ISOHDRWriter.write(baseImageURL: inputURL, gainMap: gainMapRaster, style: style, outputURL: outputURL, oppoCompat: oppoCompat, sourceData: data)

        // Append OPPO trailing payload with UHDR-format extension blocks.
        // Replaces LHDR blocks (local.hdr.meta.data, local.hdr.linear.mask)
        // with UHDR blocks (local.uhdr.gainmap.info, local.uhdr.gainmap.data)
        // so OPPO Gallery can read the gain map via OPLUS_ULTRA_HDR decoder path.
        if oppoCompat && extracted.dataBase >= 0 && extracted.dataBase < data.count {
            let namesToSkip: Set<String> = ["local.hdr.meta.data", "local.hdr.linear.mask"]
            var repackedData = Data()
            var newEntries: [[String: Any]] = []
            var currentOffset = 0

            for entry in extracted.manifestInfo.entries {
                if namesToSkip.contains(entry.name) { continue }
                let startPos = extracted.dataBase + entry.start
                let endPos = extracted.dataBase + entry.end
                if startPos >= 0 && endPos <= data.count {
                    let chunk = data.subdata(in: startPos..<endPos)
                    repackedData.append(chunk)
                    currentOffset += entry.length
                    newEntries.append([
                        "name": entry.name, "length": entry.length,
                        "offset": currentOffset, "version": entry.version ?? 1
                    ])
                }
            }

            // local.uhdr.gainmap.info: 80 bytes = 20 float32 LE
            let rm = Float(scale.ratioMax)
            let drh = Float(scale.displayRatioHdr)
            let sc = Float(scale.scale)
            let infoFloats: [Float] = [
                0, 0, 1, 1, 1, rm, rm, rm, 1, 1, 1,
                0, 0, 0, 0, 0, 0, Float(scale.displayRatioSdr), drh, sc
            ]
            var info = Data()
            for f in infoFloats { var bits = f.bitPattern.littleEndian; info.append(Data(bytes: &bits, count: 4)) }
            repackedData.append(info)
            currentOffset += info.count
            newEntries.append(["name": "local.uhdr.gainmap.info", "length": info.count, "offset": currentOffset, "version": 1])

            // local.uhdr.gainmap.data: JPEG of gain map
            if let gmJpeg = gainMapRasterToJPEG(gainMapRaster) {
                repackedData.append(gmJpeg)
                currentOffset += gmJpeg.count
                newEntries.append(["name": "local.uhdr.gainmap.data", "length": gmJpeg.count, "offset": currentOffset, "version": 1])
            }

            if !newEntries.isEmpty {
                var finalPayload = Data()
                finalPayload.append(repackedData)
                if let jsonData = try? JSONSerialization.data(withJSONObject: newEntries, options: []) {
                    finalPayload.append(jsonData)
                }
                let fileHandle = try FileHandle(forWritingTo: outputURL)
                try fileHandle.seekToEnd()
                try fileHandle.write(contentsOf: finalPayload)
                try fileHandle.close()
            }
        }

        return SampleReport(
            inputURL: inputURL,
            outputURL: outputURL,
            family: effectiveFamily,
            scale: scale,
            gainMapParams: params,
            debugDirURL: debugDirURL
        )
    }
}
