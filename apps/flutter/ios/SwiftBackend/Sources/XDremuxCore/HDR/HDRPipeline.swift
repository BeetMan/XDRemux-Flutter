import Foundation
import CoreGraphics
import CoreVideo
import Darwin
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

package struct ManifestEntry {
    let name: String
    let offset: Int
    let length: Int
    let version: Any?
    let jsonOrder: Int
    let start: Int
    let end: Int
}

package struct ManifestInfo {
    let extensionStart: Int
    let jsonStart: Int
    let jsonEnd: Int
    let entries: [ManifestEntry]
}

package struct LocalHDRInfo: Encodable {
    let version: Double
    let length: Double
    let metaSize: Double
    let offset: Double
}

package enum ExtractionMode: String, Encodable {
    case lhdr
    case uhdr
}

package struct ExtractedLHDR {
    package let mode: ExtractionMode
    package let metaBytes: Data
    package let metaFloats: [Double]
    package let localHDRInfo: LocalHDRInfo?
    package let maskJPEGData: Data
    package let manifestInfo: ManifestInfo
    package let dataBase: Int
}

package struct GainMapRaster {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let channelCount: Int
    let data: Data
}

package extension GainMapRaster {
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

package struct AuxiliaryGainMapPayload {
    let data: Data
    let bytesPerRow: Int
    let pixelFormat: UInt32
}

package struct ISOBMFFBox {
    package let type: String
    package let dataStart: Int
    package let dataEnd: Int
    package let boxStart: Int
    package let size: Int
}

package struct ISOBMFFILocEntry {
    package let itemID: Int
    package let constructionMethod: Int
    package let dataReferenceIndex: Int
    package let extents: [(offset: Int, length: Int)]

    package init(
        itemID: Int,
        constructionMethod: Int,
        dataReferenceIndex: Int,
        extents: [(offset: Int, length: Int)]
    ) {
        self.itemID = itemID
        self.constructionMethod = constructionMethod
        self.dataReferenceIndex = dataReferenceIndex
        self.extents = extents
    }
}

package struct ISOBMFFIPMAEntry {
    package let itemID: Int
    package let associations: [Int]
}

package struct ISOBMFFItemInfo {
    package let itemID: Int
    package let type: String
    package let flags: Int
    package let rawInfe: Data
}

package struct ISOBMFFIRefEntry {
    package let type: String
    package let from: Int
    package let to: [Int]

    package init(type: String, from: Int, to: [Int]) {
        self.type = type
        self.from = from
        self.to = to
    }
}

package struct ISOBMFFPropertyInfo {
    package let index: Int
    package let type: String
    package let boxStart: Int
    package let boxSize: Int
    package let rawBox: Data
}

package struct ResolvedScale {
    package let edrScale: Double
    package let ratioMin: Double
    package let ratioMax: Double
    package let gamma: Double
    package let epsilonSdr: Double
    package let epsilonHdr: Double
    package let displayRatioSdr: Double
    package let displayRatioHdr: Double
    package let scale: Double
    package let gainMapMin: Double
    package let gainMapMax: Double
    package let baseHeadroom: Double
    package let alternateHeadroom: Double
    package let source: String
    package let channelCount: Int
    package let perChannelGainMapMin: [Double]
    package let perChannelGainMapMax: [Double]
    package let perChannelGamma: [Double]
    package let perChannelBaseOffset: [Double]
    package let perChannelAlternateOffset: [Double]
}

package struct GainMapParams {
    let family: Family
    let knee: Double
    let kneeRange: Double
    let headroomScale: Double
    let maxBoost: Double
    let log2Scale: Double
    let kneeSource: String
}

package struct HDRToneMapStyle: Encodable {
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

package extension HDRToneMapStyle {
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

package struct DebugMeta: Encodable {
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

package struct LHDRSemanticField: Encodable {
    let index: Int
    let value: Double
    let meaning: String
    let confidence: String
    let note: String?
}

package struct FloatAuditEntry: Encodable {
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

package struct CalibrationTrace: Encodable {
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

package func buildLHDRSemanticFields(floats: [Double]) -> [String: LHDRSemanticField] {
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

package struct GainMapMetaProjectionDebug: Encodable {
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

package struct SampleReport {
    let inputURL: URL
    let outputURL: URL
    let family: Family
    let scale: ResolvedScale
    let gainMapParams: GainMapParams
    let debugDirURL: URL?
}

package enum LHDRExtractor {
    private static let qtiMarkers: [Data] = [
        Data("QTI Debug".utf8),
        Data("QTI ".utf8)
    ]

    private static let float144: Data = {
        let value = Float(144.0)
        var little = value.bitPattern.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }()

    package static func extract(from data: Data) throws -> ExtractedLHDR {
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

    package static func portraitBlocks(from data: Data) throws -> [String: Data] {
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
                let boxSize = Int(try readUInt32BE(from: data, at: boxStart))
                let extensionStart = boxStart + boxSize
                // A standard JPEG may contain the text "QTI " in metadata, but
                // the preceding bytes are not an ISOBMFF box size. Do not let a
                // coincidental marker produce an out-of-bounds Data slice.
                guard boxSize >= 8, extensionStart <= data.count else { continue }
                return extensionStart
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

package enum MaskDecoder {
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

package enum EDRScaleResolver {
    package static func resolve(metaFloats: [Double], mode: ExtractionMode) throws -> ResolvedScale {
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

package enum GainMapReconstructor {
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

package enum ISOHDRWriter {
    static func write(
        baseImageURL: URL,
        gainMap: GainMapRaster,
        style: HDRToneMapStyle,
        outputURL: URL,
        oppoCompatibility: OppoCompatibility = .off,
        inputProcessingBranch: InputProcessingBranch = .system,
        eventHandler: ConversionEventHandler? = nil
    ) throws {
        if inputProcessingBranch == .hybrid {
            // Phase 1: write intermediate using existing aux-data path
            let intermediateURL = outputURL.appendingPathExtension("intermediate")
            defer { try? FileManager.default.removeItem(at: intermediateURL) }
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
                oppoCompatibility: oppoCompatibility,
                eventHandler: eventHandler
            )
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

    package static func writeWithPreserveReencode(
        intermediateURL: URL,
        outputURL: URL,
        patchedUserComment: String? = nil,
        oppoCompatibility: OppoCompatibility = .off,
        lossyCompressionQuality: Double? = nil,
        eventHandler: ConversionEventHandler? = nil
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
        if let lossyCompressionQuality {
            imageOptions[kCGImageDestinationLossyCompressionQuality] = lossyCompressionQuality
        }
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
                eventHandler?(.diagnostic(
                    "[preserve] gain map pixel format changed: \(intermediatePFStr) -> \(outputPFStr)"
                ))
            } else {
                eventHandler?(.diagnostic(
                    "[preserve] gain map pixel format preserved: \(outputPFStr)"
                ))
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

package enum DebugWriter {
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
