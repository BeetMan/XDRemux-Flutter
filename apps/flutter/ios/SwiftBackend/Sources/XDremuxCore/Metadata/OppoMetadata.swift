import Foundation
import ImageIO

package let oppoUltraHDRFlag = 0x20000000
package let isoUltraHDRFlag = 0x00200000
package let localHDRFlag = 0x00040000
package let oppoTagFlagPrefixes = [
    "ASCIIOplus_",
    "ASCIIoppo_",
    "Oplus_",
    "oplus_",
    "oppo_"
]

package func targetOppoTagFlags(_ sourceFlags: Int, compatibility: OppoCompatibility) -> Int {
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
package func adjustedOppoUserComment(in data: Data, compatibility: OppoCompatibility) -> String? {
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

package func restoreOppoUserCommentFromSource(
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

package func oppoUserComment(in data: Data) -> String? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
          let value = exif[kCGImagePropertyExifUserComment] else {
        return nil
    }
    if let string = value as? String { return string }
    if let bytes = value as? Data {
        let payload = bytes.count >= 8 ? bytes.dropFirst(8) : bytes[...]
        return String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
    }
    return nil
}

package func oppoTagFlags(from userComment: String) -> (prefix: String, digitCount: Int, flags: Int)? {
    for prefix in oppoTagFlagPrefixes {
        guard userComment.hasPrefix(prefix) else { continue }
        let digits = String(userComment.dropFirst(prefix.count).prefix { $0.isNumber })
        guard !digits.isEmpty, let flags = Int(digits) else { return nil }
        return (prefix, digits.count, flags)
    }
    return nil
}

package struct OppoUserCommentPatch {
    let sourceRange: Range<Int>
    let delta: Int
}

package func applyOppoUserCommentPatch(
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

package func adjustedExtentForOppoUserCommentPatch(
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

package func valueOrRepeated(_ values: [Double], index: Int, fallback: Double) -> Double {
    guard !values.isEmpty else { return fallback }
    return index < values.count ? values[index] : values[0]
}

package func positiveValueOrFallback(_ values: [Double], index: Int, fallback: Double) -> Double {
    let value = valueOrRepeated(values, index: index, fallback: fallback)
    guard value.isFinite, value > 0 else { return fallback }
    return value
}

package let isoAuxCBox = Data([
    0x00, 0x00, 0x00, 0x28, 0x61, 0x75, 0x78, 0x43,
    0x00, 0x00, 0x00, 0x00, 0x75, 0x72, 0x6e, 0x3a,
    0x69, 0x73, 0x6f, 0x3a, 0x73, 0x74, 0x64, 0x3a,
    0x69, 0x73, 0x6f, 0x3a, 0x74, 0x73, 0x3a, 0x32,
    0x31, 0x34, 0x39, 0x36, 0x3a, 0x2d, 0x31, 0x00,
])
package let isoDinfBox = Data([
    0x00, 0x00, 0x00, 0x24, 0x64, 0x69, 0x6e, 0x66,
    0x00, 0x00, 0x00, 0x1c, 0x64, 0x72, 0x65, 0x66,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    0x00, 0x00, 0x00, 0x0c, 0x75, 0x72, 0x6c, 0x20,
    0x00, 0x00, 0x00, 0x01,
])
package func exifOrientation(at url: URL) -> UInt32 {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        return 1
    }
    return (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
}

package func isoIrotBox(exifOrientation: UInt32) -> Data {
    // HEIF irot stores counter-clockwise quarter turns. Exif 6 is 90 degrees
    // clockwise and therefore maps to irot=3; Exif 8 maps to irot=1.
    let quarterTurnsCCW: UInt8
    switch exifOrientation {
    case 3: quarterTurnsCCW = 2
    case 6: quarterTurnsCCW = 3
    case 8: quarterTurnsCCW = 1
    default: quarterTurnsCCW = 0
    }
    return Data([0x00, 0x00, 0x00, 0x09, 0x69, 0x72, 0x6f, 0x74, quarterTurnsCCW])
}
package let isoColrSRGBBox = Data([
    0x00, 0x00, 0x00, 0x13, 0x63, 0x6f, 0x6c, 0x72,
    0x6e, 0x63, 0x6c, 0x78, 0x00, 0x02, 0x00, 0x02,
    0x00, 0x02, 0x80,
])
package let isoColrUnspecifiedBT601Box = Data([
    0x00, 0x00, 0x00, 0x13, 0x63, 0x6f, 0x6c, 0x72,
    0x6e, 0x63, 0x6c, 0x78, 0x00, 0x02, 0x00, 0x02,
    0x00, 0x06, 0x80,
])
package let isoColrBT2020PQBox = Data([
    0x00, 0x00, 0x00, 0x13, 0x63, 0x6f, 0x6c, 0x72,
    0x6e, 0x63, 0x6c, 0x78, 0x00, 0x09, 0x00, 0x10,
    0x00, 0x09, 0x80,
])
package let isoPixiRGB8Box = Data([
    0x00, 0x00, 0x00, 0x10, 0x70, 0x69, 0x78, 0x69,
    0x00, 0x00, 0x00, 0x00, 0x03, 0x08, 0x08, 0x08,
])
package let isoPixiMono8Box = Data([
    0x00, 0x00, 0x00, 0x0e, 0x70, 0x69, 0x78, 0x69,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x08,
])
package let isoPixiRGB10Box = Data([
    0x00, 0x00, 0x00, 0x10, 0x70, 0x69, 0x78, 0x69,
    0x00, 0x00, 0x00, 0x00, 0x03, 0x0a, 0x0a, 0x0a,
])
