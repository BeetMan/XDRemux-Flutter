import CoreGraphics
import Foundation

/// Experimental bridge for keeping an OPPO watermark visible without feeding
/// the watermark resource through the Photographic Styles decode path.
///
/// This deliberately lives outside the upstream checkout. The upstream tail
/// format is private/package-scoped, so the prototype parses and rebuilds only
/// the small subset needed by the macOS wrapper.
enum AppleWatermarkTailBridge {
    struct PreparedInput {
        let url: URL
        let watermarkTail: Data
        let entryNames: [String]
    }

    struct RepackedTail {
        let data: Data
        let entryNames: [String]
    }

    private struct ManifestRecord: Codable, Hashable {
        let length: Int
        let name: String
        let offset: Int
        let version: Int
    }

    private struct TailInfo {
        let mdatEnd: Int
        let jsonStart: Int
        let tag: Data
        let records: [ManifestRecord]
    }

    private struct PackedRecord {
        let record: ManifestRecord
        let payloadStart: Int
    }

    private static let watermarkEntryNames: Set<String> = [
        "color.space",
        "gr.effect.info",
        "master.mode.preset.info",
        "private.emptyspace",
    ]

    /// Creates a scratch input with watermark resources removed from the
    /// post-mdat OPPO tail. The original watermark resources are repacked so
    /// they can be appended to the generated Styles output afterwards.
    static func prepare(sourceURL: URL) throws -> PreparedInput? {
        let sourceData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        guard let tailInfo = try parseTail(in: sourceData) else {
            return nil
        }

        let watermarkRecords = tailInfo.records.filter(isWatermarkRecord)
        guard !watermarkRecords.isEmpty else {
            return nil
        }

        let nonWatermarkRecords = tailInfo.records.filter { !isWatermarkRecord($0) }
        let filteredTail = try buildTail(
            from: sourceData,
            info: tailInfo,
            selected: nonWatermarkRecords
        )
        let watermarkTail = try buildTail(
            from: sourceData,
            info: tailInfo,
            selected: watermarkRecords
        )

        let scratchURL = sourceURL.deletingLastPathComponent().appendingPathComponent(
            ".\(sourceURL.lastPathComponent).apple-no-watermark-\(UUID().uuidString).heic"
        )
        var scratchData = Data(sourceData.prefix(tailInfo.mdatEnd))
        scratchData.append(filteredTail)
        try scratchData.write(to: scratchURL, options: [.atomic])

        return PreparedInput(
            url: scratchURL,
            watermarkTail: watermarkTail,
            entryNames: watermarkRecords.map(\.name)
        )
    }

    static func containsRecognizedWatermark(sourceURL: URL) throws -> Bool {
        let sourceData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        guard let tailInfo = try parseTail(in: sourceData) else {
            return false
        }
        return tailInfo.records.contains(where: isWatermarkRecord)
    }

    /// Returns the names in an OPPO post-mdat manifest without exposing the
    /// private manifest model to the rest of the wrapper target.
    static func tailEntryNames(sourceURL: URL) throws -> [String] {
        let sourceData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        guard let tailInfo = try parseTail(in: sourceData) else {
            return []
        }
        return tailInfo.records.map(\.name)
    }

    /// Reads one OPPO tail resource for diagnostics and calibration probes.
    /// This is intentionally read-only; it never rewrites the source file.
    static func tailPayload(named name: String, sourceURL: URL) throws -> Data? {
        let sourceData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        guard let tailInfo = try parseTail(in: sourceData),
              let record = tailInfo.records.first(where: { $0.name == name }) else {
            return nil
        }
        return try payload(for: record, in: sourceData, info: tailInfo)
    }

    /// Creates an explicitly research-only scratch input with selected OPPO
    /// tail payloads replaced. The original file is never modified. This is
    /// used by the Portrait calibration runner to inject candidate depth
    /// headers before calling the upstream Swift Library directly.
    static func makeResearchInput(
        sourceURL: URL,
        replacing payloads: [String: Data],
        label: String
    ) throws -> URL? {
        let sourceData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        guard let tailInfo = try parseTail(in: sourceData) else {
            return nil
        }
        let names = Set(tailInfo.records.map(\.name))
        guard !payloads.isEmpty, Set(payloads.keys).isSubset(of: names) else {
            throw BridgeError.invalidTail("research replacement names are not present in OPPO tail")
        }
        let tail = try buildTail(
            from: sourceData,
            info: tailInfo,
            selected: tailInfo.records,
            overrides: payloads
        )
        let scratchURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            ".\(sourceURL.lastPathComponent).\(label)-\(UUID().uuidString).heic"
        )
        var scratchData = Data(sourceData.prefix(tailInfo.mdatEnd))
        scratchData.append(tail)
        try scratchData.write(to: scratchURL, options: [.atomic])
        return scratchURL
    }

    /// Removes a recognized OPPO post-mdat footer from an Apple-mode output.
    /// Apple Features may preserve the source footer while rebuilding the
    /// Photos metadata, so output-mode selection alone is not sufficient.
    @discardableResult
    static func stripRecognizedOppoTail(from outputURL: URL) throws -> Bool {
        let outputData = try Data(contentsOf: outputURL, options: [.mappedIfSafe])
        guard let tailInfo = try parseTail(in: outputData) else {
            return false
        }
        guard tailInfo.records.contains(where: isRecognizedOppoRecord) else {
            return false
        }

        let rebuilt = Data(outputData.prefix(tailInfo.mdatEnd))
        try rebuilt.write(to: outputURL, options: [.atomic])
        return true
    }

    /// Rebuilds the complete OPPO footer from the donor file. The payloads are
    /// copied byte-for-byte; only manifest offsets and the footer length are
    /// recalculated for the new location.
    static func repackedCompleteTail(sourceURL: URL) throws -> RepackedTail? {
        let sourceData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        guard let tailInfo = try parseTail(in: sourceData) else {
            return nil
        }
        return RepackedTail(
            data: try buildTail(
                from: sourceData,
                info: tailInfo,
                selected: tailInfo.records
            ),
            entryNames: tailInfo.records.map(\.name)
        )
    }

    /// Calculates the full bottom canvas that OPPO reserves for the watermark.
    /// For the Find X7 Ultra sample the PNG is 3688x218, the side inset is 204
    /// and the top/bottom inset is 111, yielding a 4096x440 canvas. The white
    /// background is part of the primary image, so restoring only the PNG
    /// would leave the Styles-tinted background behind it.
    static func watermarkCanvasRect(
        sourceURL: URL,
        imageWidth: Int,
        imageHeight: Int
    ) throws -> CGRect? {
        let sourceData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        guard let tailInfo = try parseTail(in: sourceData),
              let watermarkRecord = tailInfo.records.first(where: { $0.name == "watermark" }),
              let configRecord = tailInfo.records.first(where: { $0.name == "watermark.config" }) else {
            return nil
        }

        let watermark = try payload(for: watermarkRecord, in: sourceData, info: tailInfo)
        let config = try payload(for: configRecord, in: sourceData, info: tailInfo)
        guard config.count >= 20,
              let watermarkSize = pngSize(watermark) else {
            throw BridgeError.invalidTail("watermark config or PNG header is truncated")
        }

        let configuredWidth = Int(readUInt32LE(config, at: 4))
        let configuredHeight = Int(readUInt32LE(config, at: 8))
        let sideInset = Int(readUInt32LE(config, at: 12))
        let verticalInset = Int(readUInt32LE(config, at: 16))
        guard configuredWidth == watermarkSize.width,
              configuredHeight == watermarkSize.height,
              configuredWidth + sideInset * 2 == imageWidth,
              configuredHeight + verticalInset * 2 <= imageHeight else {
            throw BridgeError.invalidTail(
                "watermark geometry does not match (imageWidth)x(imageHeight)"
            )
        }

        let canvasHeight = configuredHeight + verticalInset * 2
        return CGRect(
            x: 0,
            y: imageHeight - canvasHeight,
            width: imageWidth,
            height: canvasHeight
        )
    }

    /// Replaces any post-mdat bytes in the generated output with the
    /// watermark-only tail. Styles currently writes a complete ISO container
    /// without an OPPO tail, but failing closed here avoids producing a file
    /// with two competing footer manifests if that changes upstream.
    static func appendWatermarkTail(_ tail: Data, to outputURL: URL) throws {
        let outputData = try Data(contentsOf: outputURL, options: [.mappedIfSafe])
        let mdatEnd = try findMdatEnd(in: outputData)
        guard outputData.count == mdatEnd else {
            throw BridgeError.unexpectedOutputTail
        }

        var rebuilt = Data(outputData.prefix(mdatEnd))
        rebuilt.append(tail)
        try rebuilt.write(to: outputURL, options: [.atomic])
    }

    /// Appends all donor OPPO resources after the generated ISO container.
    /// This is intentionally separate from the older watermark-only path: a
    /// returned iPhone photo may already contain an ISO gain map, while the
    /// donor footer contains OPPO's private HDR and device metadata.
    static func appendCompleteTail(_ tail: RepackedTail, to outputURL: URL) throws {
        let outputData = try Data(contentsOf: outputURL, options: [.mappedIfSafe])
        let mdatEnd = try findMdatEnd(in: outputData)
        guard outputData.count == mdatEnd else {
            throw BridgeError.unexpectedOutputTail
        }

        var rebuilt = Data(outputData.prefix(mdatEnd))
        rebuilt.append(tail.data)
        try rebuilt.write(to: outputURL, options: [.atomic])
    }

    private static func isWatermarkRecord(_ record: ManifestRecord) -> Bool {
        record.name == "watermark"
            || record.name.hasPrefix("watermark.")
            || watermarkEntryNames.contains(record.name)
    }

    private static func isRecognizedOppoRecord(_ record: ManifestRecord) -> Bool {
        isWatermarkRecord(record)
            || record.name.hasPrefix("local.")
            || record.name == "hdr.transform.data"
            || record.name == "master.mode.preset.info"
    }

    private static func parseTail(in data: Data) throws -> TailInfo? {
        let mdatEnd = try findMdatEnd(in: data)
        guard data.count >= 9, data[data.count - 9] == 0 else {
            return nil
        }

        let tagStart = data.count - 8
        let tag = data.subdata(in: tagStart..<(tagStart + 4))
        guard tag.allSatisfy({ (32...126).contains($0) }) else {
            throw BridgeError.invalidTail("OPPO tail tag is not printable")
        }

        let footerLength = Int(readUInt32LE(data, at: data.count - 4))
        guard footerLength >= 9, footerLength <= data.count else {
            throw BridgeError.invalidTail("OPPO tail footer length is out of bounds")
        }
        let jsonStart = data.count - footerLength
        let jsonEnd = data.count - 9
        guard jsonStart >= mdatEnd, jsonStart < jsonEnd else {
            throw BridgeError.invalidTail("OPPO tail manifest range is invalid")
        }

        let manifestData = data.subdata(in: jsonStart..<jsonEnd)
        let records: [ManifestRecord]
        do {
            records = try JSONDecoder().decode([ManifestRecord].self, from: manifestData)
        } catch {
            throw BridgeError.invalidTail("OPPO tail manifest is not a supported array: \(error)")
        }
        guard !records.isEmpty else {
            throw BridgeError.invalidTail("OPPO tail manifest is empty")
        }

        for record in records {
            guard record.length >= 0, record.offset >= 0 else {
                throw BridgeError.invalidTail("OPPO tail entry has a negative range")
            }
            let sourceStart = jsonStart - record.offset
            let sourceEnd = sourceStart + record.length
            guard sourceStart >= mdatEnd,
                  sourceEnd >= sourceStart,
                  sourceEnd <= jsonStart else {
                throw BridgeError.invalidTail(
                    "OPPO tail entry \(record.name) is outside the source tail"
                )
            }
        }

        return TailInfo(
            mdatEnd: mdatEnd,
            jsonStart: jsonStart,
            tag: tag,
            records: records
        )
    }

    private static func buildTail(
        from sourceData: Data,
        info: TailInfo,
        selected: [ManifestRecord],
        overrides: [String: Data] = [:]
    ) throws -> Data {
        guard !selected.isEmpty else {
            return Data()
        }

        var payload = Data()
        var packedRecords: [PackedRecord] = []
        for record in selected {
            let sourceStart = info.jsonStart - record.offset
            let sourceEnd = sourceStart + record.length
            guard sourceStart >= info.mdatEnd,
                  sourceEnd <= info.jsonStart else {
                throw BridgeError.invalidTail(
                    "OPPO tail entry \(record.name) is outside the source tail"
                )
            }
            let payloadStart = payload.count
            payload.append(
                overrides[record.name]
                    ?? sourceData.subdata(in: sourceStart..<sourceEnd)
            )
            packedRecords.append(PackedRecord(
                record: ManifestRecord(
                    length: overrides[record.name]?.count ?? record.length,
                    name: record.name,
                    offset: record.offset,
                    version: record.version
                ),
                payloadStart: payloadStart
            ))
        }

        let payloadLength = payload.count
        var packedByName: [String: PackedRecord] = [:]
        for packed in packedRecords {
            packedByName[packed.record.name] = packed
        }
        let manifestRecords = selected.compactMap { record -> ManifestRecord? in
            guard let packed = packedByName[record.name] else { return nil }
            return ManifestRecord(
                length: packed.record.length,
                name: record.name,
                offset: payloadLength - packed.payloadStart,
                version: record.version
            )
        }
        guard manifestRecords.count == selected.count else {
            throw BridgeError.invalidTail("OPPO tail manifest could not be rebuilt")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestData = try encoder.encode(manifestRecords)
        var tail = Data()
        tail.append(payload)
        tail.append(manifestData)
        tail.append(0)
        tail.append(info.tag)
        appendUInt32LE(manifestData.count + 1 + 4 + 4, to: &tail)
        return tail
    }

    private static func payload(
        for record: ManifestRecord,
        in sourceData: Data,
        info: TailInfo
    ) throws -> Data {
        let sourceStart = info.jsonStart - record.offset
        let sourceEnd = sourceStart + record.length
        guard sourceStart >= info.mdatEnd,
              sourceEnd >= sourceStart,
              sourceEnd <= info.jsonStart else {
            throw BridgeError.invalidTail(
                "OPPO tail entry \(record.name) is outside the source tail"
            )
        }
        return sourceData.subdata(in: sourceStart..<sourceEnd)
    }

    private static func pngSize(_ data: Data) -> (width: Int, height: Int)? {
        let signature = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        guard data.count >= 24,
              data.prefix(8) == signature,
              String(bytes: data[12..<16], encoding: .ascii) == "IHDR" else {
            return nil
        }
        return (
            Int(readUInt32BE(data, at: 16)),
            Int(readUInt32BE(data, at: 20))
        )
    }

    private static func findMdatEnd(in data: Data) throws -> Int {
        var offset = 0
        while offset + 8 <= data.count {
            let size32 = readUInt32BE(data, at: offset)
            let type = String(
                bytes: data[(offset + 4)..<(offset + 8)],
                encoding: .ascii
            )
            let headerLength: Int
            let boxLength: Int
            if size32 == 1 {
                guard offset + 16 <= data.count else {
                    throw BridgeError.invalidContainer("ISO box has a truncated 64-bit size")
                }
                let extendedSize = readUInt64BE(data, at: offset + 8)
                guard extendedSize >= 16, extendedSize <= UInt64(Int.max) else {
                    throw BridgeError.invalidContainer("ISO box has an invalid extended size")
                }
                headerLength = 16
                boxLength = Int(extendedSize)
            } else if size32 == 0 {
                headerLength = 8
                boxLength = data.count - offset
            } else {
                headerLength = 8
                boxLength = Int(size32)
            }

            guard boxLength >= headerLength,
                  offset + boxLength <= data.count else {
                throw BridgeError.invalidContainer("ISO box extends past the file")
            }
            if type == "mdat" {
                return offset + boxLength
            }
            offset += boxLength
        }
        throw BridgeError.invalidContainer("ISO mdat box is missing")
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    private static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(data[offset + index])
        }
        return value
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func appendUInt32LE(_ value: Int, to data: inout Data) {
        let value = UInt32(truncatingIfNeeded: value)
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    private enum BridgeError: LocalizedError {
        case invalidContainer(String)
        case invalidTail(String)
        case unexpectedOutputTail

        var errorDescription: String? {
            switch self {
            case .invalidContainer(let message):
                return "watermark isolation input container invalid: \(message)"
            case .invalidTail(let message):
                return "watermark isolation OPPO tail invalid: \(message)"
            case .unexpectedOutputTail:
                return "watermark isolation output already contains an unexpected post-mdat tail"
            }
        }
    }
}
