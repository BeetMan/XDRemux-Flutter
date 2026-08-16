import Foundation
import ImageIO

package func verifyImageIOISOGainMap(_ outputURL: URL) throws {
    guard let source = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
          CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil else {
        throw CLIError.outputVerificationFailed(outputURL)
    }
}

package func isoGainMapPixelFormat(at url: URL) -> UInt32? {
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

package func isSubsampledGainMapPixelFormat(_ pixelFormat: UInt32) -> Bool {
    pixelFormat == pixelFormatFourCC("420f")
        || pixelFormat == pixelFormatFourCC("420v")
        || pixelFormat == pixelFormatFourCC("x420")
}

package func gainMapEncodingMatchesTarget(at url: URL, compatibility: OppoCompatibility) -> Bool {
    guard let pixelFormat = isoGainMapPixelFormat(at: url) else { return false }
    if compatibility.wantsOppoCompat {
        return isSubsampledGainMapPixelFormat(pixelFormat)
    }
    return pixelFormat == pixelFormatFourCC("444f")
        || pixelFormat == pixelFormatFourCC("L008")
}

package func pixelFormatFourCC(_ value: String) -> UInt32 {
    value.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

package func rejectLossyGainMapPromotion(inputURL: URL, compatibility: OppoCompatibility) throws {
    guard !compatibility.wantsOppoCompat,
          let pixelFormat = isoGainMapPixelFormat(at: inputURL),
          isSubsampledGainMapPixelFormat(pixelFormat) else { return }
    throw CLIError.invalidContainer(
        "cannot promote an existing 4:2:0 Gain Map to high-spec 4:4:4 because chroma information has already been discarded"
    )
}

package let oppoCameraWatermarkAuxiliaryEntryNames: Set<String> = [
    "color.space",
    "gr.effect.info",
    "master.mode.preset.info",
    "private.emptyspace"
]

package let oppoCameraPortraitEditingEntryNames: Set<String> = [
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

package let oppoCameraCompactPortraitTailEntryNames: Set<String> =
    oppoCameraPortraitEditingEntryNames.union(["hdr.transform.data", "src.local.hdr.linear.mask"])

package func shouldPreserveOppoCameraTailEntry(_ name: String, mode: OppoCameraTail) -> Bool {
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
    case .preserveWithoutPortraitOrPrivateHDR:
        return !oppoCameraPortraitEditingEntryNames.contains(name) && !isOppoPrivateHDRTailEntry(name)
    case .preserveWithoutPrivateUHDR:
        return !oppoPrivateUHDRTailEntryNames.contains(name)
    case .preserveWithoutPrivateHDR:
        return !isOppoPrivateHDRTailEntry(name)
    case .preserve, .preserveNoUHDR, .preserveNoHDR:
        return true
    }
}

package let oppoPrivateUHDRTailEntryNames: Set<String> = [
    "local.uhdr.gainmap.data",
    "local.uhdr.gainmap.info"
]

package func isOppoPrivateHDRTailEntry(_ name: String) -> Bool {
    oppoPrivateUHDRTailEntryNames.contains(name)
        || name.hasPrefix("hdr.")
        || name.hasPrefix("local.hdr.")
        || name.hasPrefix("src.local.hdr.")
}

package func shouldNeutralizeOppoCameraTailEntry(_ name: String, mode: OppoCameraTail) -> Bool {
    switch mode {
    case .preserveNoUHDR:
        return oppoPrivateUHDRTailEntryNames.contains(name)
    case .preserveNoHDR:
        return isOppoPrivateHDRTailEntry(name)
    case .off, .watermark, .compact, .preserve, .preserveWithoutPortrait, .preserveWithoutPortraitOrPrivateHDR, .preserveWithoutPrivateUHDR, .preserveWithoutPrivateHDR:
        return false
    }
}

package func removeExistingPostMdatTail(from outputURL: URL) throws {
    var outputData = try Data(contentsOf: outputURL, options: [.mappedIfSafe])
    guard let outputMdat = isobmffBoxes(in: outputData, start: 0, end: outputData.count)
        .first(where: { $0.type == "mdat" }) else {
        throw CLIError.invalidContainer("output mdat missing while filtering OPPO metadata tail")
    }
    let tailStart = outputMdat.boxStart + outputMdat.size
    guard tailStart < outputData.count else { return }
    outputData.removeSubrange(tailStart..<outputData.count)
    try outputData.write(to: outputURL, options: [.atomic])
}

package func appendCompleteSourceTail(
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

package struct PackedOppoCameraTailEntry {
    let entry: ManifestEntry
    let payloadStart: Int
}

package struct OppoCameraTailManifestRecord: Encodable {
    let length: Int
    let name: String
    let offset: Int
    let version: Int
}

package func oppoCameraTailTag(in sourceData: Data) -> Data {
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

package func appendOppoCameraTailIfNeeded(
    outputURL: URL,
    sourceData: Data,
    extracted: ExtractedLHDR,
    mode: OppoCameraTail
) throws {
    if mode == .preserve {
        try appendCompleteSourceTail(
            outputURL: outputURL,
            sourceData: sourceData,
            manifestInfo: extracted.manifestInfo,
            mode: mode
        )
        return
    }

    // Writers may copy an already-ISO input byte-for-byte, including its old
    // vendor tail. Remove that tail before applying any filtered policy.
    try removeExistingPostMdatTail(from: outputURL)
    guard mode != .off else { return }

    if mode == .preserveNoUHDR || mode == .preserveNoHDR {
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

package func isValidProductOutput(
    _ outputURL: URL,
    oppoCameraTail: OppoCameraTail,
    oppoCompatibility: OppoCompatibility
) -> Bool {
    guard gainMapEncodingMatchesTarget(at: outputURL, compatibility: oppoCompatibility) else { return false }
    switch oppoCameraTail {
    case .off:
        return true
    case .watermark, .compact, .preserve, .preserveWithoutPortrait, .preserveWithoutPortraitOrPrivateHDR, .preserveWithoutPrivateUHDR, .preserveWithoutPrivateHDR, .preserveNoUHDR, .preserveNoHDR:
        return hasValidCompactOppoCameraTail(outputURL, mode: oppoCameraTail)
    }
}

package func hasValidCompactOppoCameraTail(_ outputURL: URL, mode: OppoCameraTail) -> Bool {
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

package func manifestVersion(_ value: Any?) -> Int {
    if let number = value as? NSNumber {
        return number.intValue
    }
    if let string = value as? String, let parsed = Int(string) {
        return parsed
    }
    return 1
}
