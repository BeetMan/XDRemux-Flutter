import Foundation
import CoreGraphics
import ImageIO

package func readUInt16BEUnchecked(_ data: Data, at offset: Int) -> Int {
    (Int(data[offset]) << 8) | Int(data[offset + 1])
}

package func readUInt32BEUnchecked(_ data: Data, at offset: Int) -> Int {
    (Int(data[offset]) << 24)
        | (Int(data[offset + 1]) << 16)
        | (Int(data[offset + 2]) << 8)
        | Int(data[offset + 3])
}

package func appendUInt16BE(_ value: Int, to data: inout Data) {
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

package func appendUInt32BE(_ value: Int, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

package func appendUInt32LE(_ value: Int, to data: inout Data) {
    var little = UInt32(value).littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
}

package func appendInt32BE(_ value: Int32, to data: inout Data) {
    appendUInt32BE(Int(UInt32(bitPattern: value)), to: &data)
}

package func makeBox(_ type: String, payload: Data) -> Data {
    var out = Data()
    appendUInt32BE(payload.count + 8, to: &out)
    out.append(type.data(using: .ascii)!)
    out.append(payload)
    return out
}

package func isobmffBoxes(in data: Data, start: Int, end: Int) -> [ISOBMFFBox] {
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

package func parseISOBMFFILoc(_ data: Data, _ box: ISOBMFFBox) throws -> [ISOBMFFILocEntry] {
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

package func parseISOBMFFIInf(_ data: Data, _ box: ISOBMFFBox) -> (version: UInt8, entries: [Int: String], rawInfe: [Int: Data]) {
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
            let itemID: Int
            if v >= 3 {
                itemID = readUInt32BEUnchecked(data, at: p); p += 4
            } else {
                itemID = readUInt16BEUnchecked(data, at: p); p += 2
            }
            p += 2
            let type = String(data: data.subdata(in: p..<p + 4), encoding: .isoLatin1) ?? "????"
            entries[itemID] = type
            raw[itemID] = data.subdata(in: child.boxStart..<child.boxStart + child.size)
        }
    }
    return (version, entries, raw)
}

package func parseISOBMFFPITM(_ data: Data, _ box: ISOBMFFBox) -> Int {
    let version = data[box.dataStart]
    let pos = box.dataStart + 4
    return version == 0 ? readUInt16BEUnchecked(data, at: pos) : readUInt32BEUnchecked(data, at: pos)
}

package func parseISOBMFFIPMA(
    _ data: Data,
    _ box: ISOBMFFBox
) -> (version: UInt8, flags: Int, entries: [ISOBMFFIPMAEntry]) {
    let version = data[box.dataStart]
    let flags = (Int(data[box.dataStart + 1]) << 16) | (Int(data[box.dataStart + 2]) << 8) | Int(data[box.dataStart + 3])
    var pos = box.dataStart + 4
    let count = readUInt32BEUnchecked(data, at: pos); pos += 4
    var entries: [ISOBMFFIPMAEntry] = []
    for _ in 0..<count {
        let itemID: Int
        if version >= 1 {
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
    return (version, flags, entries)
}

package func parseISOBMFFIRefVersion(_ data: Data, _ box: ISOBMFFBox?) -> UInt8 {
    guard let box else { return 0 }
    return data[box.dataStart]
}

package func parseISOBMFFIPCOProps(_ data: Data, _ iprp: ISOBMFFBox) throws -> (box: ISOBMFFBox, types: [Int: String], sizes: [Int: (Int, Int)]) {
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

package func parseISOBMFFItemInfos(_ data: Data, _ box: ISOBMFFBox) -> (version: UInt8, items: [ISOBMFFItemInfo]) {
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

package func parseISOBMFFIRefs(_ data: Data, _ box: ISOBMFFBox?) -> (version: UInt8, refs: [ISOBMFFIRefEntry]) {
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

package func parseISOBMFFIPCOPropertyInfos(_ data: Data, _ iprp: ISOBMFFBox) throws -> [ISOBMFFPropertyInfo] {
    guard let ipco = isobmffBoxes(in: data, start: iprp.dataStart, end: iprp.dataEnd).first(where: { $0.type == "ipco" }) else {
        throw CLIError.invalidContainer("ipco missing")
    }
    return isobmffBoxes(in: data, start: ipco.dataStart, end: ipco.dataEnd).enumerated().map { offset, prop in
        ISOBMFFPropertyInfo(
            index: offset + 1,
            type: prop.type,
            boxStart: prop.boxStart,
            boxSize: prop.size,
            rawBox: data.subdata(in: prop.boxStart..<prop.boxStart + prop.size)
        )
    }
}

package func assocPropertyIndex(_ value: Int, flags: Int) -> Int {
    value & (flags & 1 != 0 ? 0x7fff : 0x7f)
}

package func assocIsEssential(_ value: Int, flags: Int) -> Bool {
    value & (flags & 1 != 0 ? 0x8000 : 0x80) != 0
}

package func assocPairs(_ values: [Int], flags: Int) -> [(Int, Bool)] {
    values.map { (assocPropertyIndex($0, flags: flags), assocIsEssential($0, flags: flags)) }
}

package func makePitmBox(version: UInt8, primaryID: Int) -> Data {
    var payload = Data([version, 0, 0, 0])
    if version >= 1 {
        appendUInt32BE(primaryID, to: &payload)
    } else {
        appendUInt16BE(primaryID, to: &payload)
    }
    return makeBox("pitm", payload: payload)
}

package func makeIinfBox(version: UInt8, rawInfes: [Data]) -> Data {
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

package func makeIlocV1Box(entries: [ISOBMFFILocEntry]) -> Data {
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

package func makeIrefFullBox(version: UInt8, refs: [ISOBMFFIRefEntry]) -> Data {
    var payload = Data([version, 0, 0, 0])
    for ref in refs {
        payload.append(makeIrefBox(type: ref.type, from: ref.from, to: ref.to, version: version))
    }
    return makeBox("iref", payload: payload)
}

package func makeGrplAltrBox(groupID: Int, tmapID: Int, primaryID: Int) -> Data {
    makeBox("grpl", payload: makeAltrEntityGroupBox(groupID: groupID, tmapID: tmapID, primaryID: primaryID))
}

package func makeAltrEntityGroupBox(groupID: Int, tmapID: Int, primaryID: Int) -> Data {
    var altrPayload = Data([0, 0, 0, 0])
    appendUInt32BE(groupID, to: &altrPayload)
    appendUInt32BE(2, to: &altrPayload)
    appendUInt32BE(tmapID, to: &altrPayload)
    appendUInt32BE(primaryID, to: &altrPayload)
    return makeBox("altr", payload: altrPayload)
}

package func preservedEntityGroupChildren(
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

package func itemPayload(in data: Data, entry: ISOBMFFILocEntry, idat: ISOBMFFBox?) throws -> Data {
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

package func jpegImageSize(_ jpeg: Data) throws -> (Int, Int) {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = props[kCGImagePropertyPixelWidth] as? Int,
          let height = props[kCGImagePropertyPixelHeight] as? Int else {
        throw CLIError.invalidContainer("cannot read private gain map JPEG dimensions")
    }
    return (width, height)
}

package func makeInfeBox(itemID: Int, type: String, flags: Int = 0) -> Data {
    var payload = Data([2, UInt8((flags >> 16) & 0xff), UInt8((flags >> 8) & 0xff), UInt8(flags & 0xff)])
    appendUInt16BE(itemID, to: &payload)
    appendUInt16BE(0, to: &payload)
    payload.append(type.data(using: .ascii)!)
    payload.append(0)
    return makeBox("infe", payload: payload)
}

package func makeMimeInfeBox(itemID: Int, flags: Int = 0) -> Data {
    var payload = Data([2, UInt8((flags >> 16) & 0xff), UInt8((flags >> 8) & 0xff), UInt8(flags & 0xff)])
    appendUInt16BE(itemID, to: &payload)
    appendUInt16BE(0, to: &payload)
    payload.append(Data("mime".utf8))
    payload.append(Data("hdrgm-xmp".utf8)); payload.append(0)
    payload.append(Data("application/rdf+xml".utf8)); payload.append(0)
    payload.append(0)
    return makeBox("infe", payload: payload)
}

package func makeURIInfeBox(
    itemID: Int,
    name: String,
    uri: String,
    flags: Int = 1
) -> Data {
    var payload = Data([2, UInt8((flags >> 16) & 0xff), UInt8((flags >> 8) & 0xff), UInt8(flags & 0xff)])
    appendUInt16BE(itemID, to: &payload)
    appendUInt16BE(0, to: &payload)
    payload.append(Data("uri ".utf8))
    payload.append(Data(name.utf8)); payload.append(0)
    payload.append(Data(uri.utf8)); payload.append(0)
    return makeBox("infe", payload: payload)
}

package func remapInfeItemID(_ rawBox: Data, to itemID: Int) throws -> Data {
    guard rawBox.count >= 14,
          String(data: rawBox.subdata(in: 4..<8), encoding: .ascii) == "infe" else {
        throw CLIError.invalidContainer("cannot remap malformed infe box")
    }
    var output = rawBox
    let version = output[8]
    if version >= 3 {
        guard output.count >= 16 else {
            throw CLIError.invalidContainer("cannot remap truncated infe v3 box")
        }
        output[12] = UInt8((itemID >> 24) & 0xff)
        output[13] = UInt8((itemID >> 16) & 0xff)
        output[14] = UInt8((itemID >> 8) & 0xff)
        output[15] = UInt8(itemID & 0xff)
    } else {
        guard itemID <= 65_535 else {
            throw CLIError.invalidContainer("infe v2 item ID exceeds UInt16")
        }
        output[12] = UInt8((itemID >> 8) & 0xff)
        output[13] = UInt8(itemID & 0xff)
    }
    return output
}

package func makePixiBox(bits: [UInt8]) -> Data {
    makeBox("pixi", payload: Data([0, 0, 0, 0, UInt8(bits.count)] + bits))
}

package func makeAuxCBox(_ urn: String) -> Data {
    var payload = Data([0, 0, 0, 0])
    payload.append(Data(urn.utf8)); payload.append(0)
    return makeBox("auxC", payload: payload)
}

package func makeIrotBox(_ quarterTurnsCounterclockwise: UInt8 = 0) -> Data {
    makeBox("irot", payload: Data([quarterTurnsCounterclockwise & 0x03]))
}

package func makeICCColorBox(_ colorSpace: CGColorSpace) throws -> Data {
    guard let profile = colorSpace.copyICCData() else {
        throw CLIError.invalidContainer("cannot serialize Apple auxiliary ICC profile")
    }
    var payload = Data("prof".utf8)
    payload.append(profile as Data)
    return makeBox("colr", payload: payload)
}

package func makeGridPayload(
    rows: Int,
    columns: Int,
    width: Int,
    height: Int
) throws -> Data {
    guard (1...256).contains(rows), (1...256).contains(columns),
          width > 0, height > 0 else {
        throw CLIError.invalidContainer("invalid HEIF grid geometry")
    }
    let large = width > 65_535 || height > 65_535
    var payload = Data([0, large ? 1 : 0, UInt8(rows - 1), UInt8(columns - 1)])
    if large {
        appendUInt32BE(width, to: &payload)
        appendUInt32BE(height, to: &payload)
    } else {
        appendUInt16BE(width, to: &payload)
        appendUInt16BE(height, to: &payload)
    }
    return payload
}

package func makeIspeBox(width: Int, height: Int) -> Data {
    var payload = Data([0, 0, 0, 0])
    appendUInt32BE(width, to: &payload)
    appendUInt32BE(height, to: &payload)
    return makeBox("ispe", payload: payload)
}

package func makeImageIOCanonicalTmapIspeBox(
    primaryIspe: Data,
    irot: Data
) throws -> Data {
    guard primaryIspe.count >= 20,
          String(data: primaryIspe.subdata(in: 4..<8), encoding: .ascii) == "ispe",
          irot.count >= 9,
          String(data: irot.subdata(in: 4..<8), encoding: .ascii) == "irot" else {
        throw CLIError.invalidContainer("cannot derive oriented tmap geometry")
    }
    let width = readUInt32BEUnchecked(primaryIspe, at: 12)
    let height = readUInt32BEUnchecked(primaryIspe, at: 16)
    let quarterTurns = Int(irot[8] & 0x03)
    return quarterTurns.isMultiple(of: 2)
        ? makeIspeBox(width: width, height: height)
        : makeIspeBox(width: height, height: width)
}

package func makeIrefBox(type: String, from: Int, to: [Int], version: UInt8) -> Data {
    let idSize = version >= 1 ? 4 : 2
    var payload = Data()
    if idSize == 4 { appendUInt32BE(from, to: &payload) } else { appendUInt16BE(from, to: &payload) }
    appendUInt16BE(to.count, to: &payload)
    for item in to {
        if idSize == 4 { appendUInt32BE(item, to: &payload) } else { appendUInt16BE(item, to: &payload) }
    }
    return makeBox(type, payload: payload)
}

package func makeIPMAEntry(
    _ itemID: Int,
    _ assocs: [(Int, Bool)],
    flags: Int,
    version: UInt8 = 0
) throws -> Data {
    if flags & 1 == 0, assocs.contains(where: { $0.0 > 0x7f }) {
        throw CLIError.invalidContainer("ipma property index exceeds 7-bit association limit")
    }
    var out = Data()
    if version >= 1 { appendUInt32BE(itemID, to: &out) } else { appendUInt16BE(itemID, to: &out) }
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
package func makeImageIONativeTmapPayload(infoFloats f: [Double]) -> Data {
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

package func makeAppleTmapPayload(infoFloats f: [Double]) -> Data {
    func appendImageIORational(_ value: Double, to data: inout Data) {
        // ImageIO canonicalizes exact integers and otherwise serializes this
        // compact Apple tmap form with a 22-bit fixed-point denominator. The
        // numeric value alone is insufficient: ImageIO rejects an otherwise
        // equivalent 100000-based representation when reading ISO Gain Maps.
        let rounded = value.rounded()
        if abs(value - rounded) < 1e-12 {
            appendInt32BE(Int32(rounded), to: &data)
            appendInt32BE(1, to: &data)
            return
        }
        let denominator: Int32 = 1 << 22
        let imageIOValue = (value * 100_000.0).rounded() / 100_000.0
        appendInt32BE(Int32((imageIOValue * Double(denominator)).rounded()), to: &data)
        appendInt32BE(denominator, to: &data)
    }
    let values: [Double] = [
        max(log2(max(f[16], 1.0)), 0.0),
        log2(max(f[17], 1.0)),
        max(log2(max(f[0], 1.0)), 0.0),
        log2(max(f[4], 1.0)),
        f[7],
        f[10],
        f[13],
    ]
    var out = Data([0, 0, 0, 0, 0, 0x40])
    for value in values {
        appendImageIORational(value, to: &out)
    }
    return out
}

package func makeHdrgmXMP(infoFloats f: [Double]) -> Data {
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

package func writeHybridPrimaryPassthrough(
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
    let sourceOrientation = exifOrientation(at: sourceURL)

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
        ipcoPayload.append(isoIrotBox(exifOrientation: sourceOrientation))
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
        ipmaEntries.append(try makeIPMAEntry(entry.itemID, assocs, flags: sourceIPMA.flags, version: sourceIPMA.version))
        ipmaEntryCount += 1
    }
    if sourceIPMAByID[sourcePrimaryID] == nil {
        ipmaEntries.append(try makeIPMAEntry(sourcePrimaryID, primaryAssocs, flags: sourceIPMA.flags, version: sourceIPMA.version))
        ipmaEntryCount += 1
    }
    for tile in gainTilePayloads {
        guard let preservedEntry = preservedIPMAByID[tile.oldID] else {
            throw CLIError.invalidContainer("preserve gain tile \(tile.oldID) has no ipma entry")
        }
        ipmaEntries.append(try makeIPMAEntry(tile.newID, try remapPreservedAssocs(preservedEntry.associations), flags: sourceIPMA.flags, version: sourceIPMA.version))
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
    ipmaEntries.append(try makeIPMAEntry(outputGainGridID, gainGridAssocs, flags: sourceIPMA.flags, version: sourceIPMA.version))
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
    ipmaEntries.append(try makeIPMAEntry(outputTmapID, tmapAssocs, flags: sourceIPMA.flags, version: sourceIPMA.version))
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

package func writePrivateJPEGPassthroughOutput(
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
    let primaryHasIrot = primaryPropIndices.contains { ipco.types[$0] == "irot" }
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
            ipcoPayload.append(isoIrotBox(exifOrientation: exifOrientation(at: inputURL)))
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
                    if !primaryHasIrot {
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
            ipmaPayload.append(try makeIPMAEntry(gainMapID, [(gmIspeIndex, true), (gmPixiIndex, true), (srgbIndex, true), (irotIndex, true), (auxCIndex, true)], flags: ipma.flags, version: ipma.version))
            ipmaPayload.append(try makeIPMAEntry(tmapID, [(primaryIspeIndex, true), (tmapPixiIndex, true), (tmapColrIndex, true)], flags: ipma.flags, version: ipma.version))
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

/// Replaces the JPEG Gain Map appended by `writePrivateJPEGPassthroughOutput`
/// with an HEVC tiled grid while retaining every pre-existing source item and
/// compressed primary payload byte. The caller supplies already encoded HEVC
/// samples; this function only authors the corresponding HEIF item graph.
package func replacePrivateJPEGGainMapWithHEVCTiles(
    inputURL: URL,
    outputURL: URL,
    gainMapWidth: Int,
    gainMapHeight: Int,
    tileWidth: Int,
    tileHeight: Int,
    tilePayloads: [Data],
    tileSizes: [(width: Int, height: Int)],
    hvcC: Data,
    channelCount: Int = 3
) throws {
    guard gainMapWidth > 0, gainMapHeight > 0,
          tileWidth > 0, tileHeight > 0,
          channelCount == 1 || channelCount == 3 else {
        throw CLIError.invalidContainer("direct HEVC Gain Map has unsupported tile geometry")
    }
    let columns = (gainMapWidth + tileWidth - 1) / tileWidth
    let rows = (gainMapHeight + tileHeight - 1) / tileHeight
    guard tilePayloads.count == rows * columns,
          tileSizes.count == tilePayloads.count,
          !tilePayloads.isEmpty,
          tilePayloads.allSatisfy({ !$0.isEmpty }) else {
        throw CLIError.invalidContainer("direct HEVC Gain Map tile count does not match its geometry")
    }
    for row in 0..<rows {
        for column in 0..<columns {
            let index = row * columns + column
            let expected = (
                min(tileWidth, gainMapWidth - column * tileWidth),
                min(tileHeight, gainMapHeight - row * tileHeight)
            )
            let isLogicalEdgeSize = tileSizes[index].width == expected.0
                && tileSizes[index].height == expected.1
            let isPaddedFullTile = tileSizes[index].width == tileWidth
                && tileSizes[index].height == tileHeight
            guard isLogicalEdgeSize || isPaddedFullTile else {
                throw CLIError.invalidContainer("direct HEVC Gain Map edge tile geometry is inconsistent")
            }
        }
    }
    guard hvcC.count > 18,
          hvcC[0] == 1,
          hvcC[1] & 0x1f == 4,
          hvcC[16] & 0x03 == (channelCount == 1 ? 0 : 3),
          (hvcC[17] & 0x07) + 8 == 8,
          (hvcC[18] & 0x07) + 8 == 8 else {
        throw CLIError.invalidContainer("direct HEVC Gain Map codec does not match its channel layout")
    }

    let source = try Data(contentsOf: inputURL)
    let top = isobmffBoxes(in: source, start: 0, end: source.count)
    guard let ftyp = top.first(where: { $0.type == "ftyp" }),
          let meta = top.first(where: { $0.type == "meta" }),
          let mdat = top.first(where: { $0.type == "mdat" }) else {
        throw CLIError.invalidContainer("direct HEVC Gain Map replacement requires ftyp/meta/mdat")
    }
    let metaChildren = isobmffBoxes(in: source, start: meta.dataStart + 4, end: meta.dataEnd)
    func child(_ type: String) throws -> ISOBMFFBox {
        guard let box = metaChildren.first(where: { $0.type == type }) else {
            throw CLIError.invalidContainer("direct HEVC Gain Map source meta/\(type) missing")
        }
        return box
    }

    let iinf = try child("iinf")
    let iloc = try child("iloc")
    let pitm = try child("pitm")
    let iprp = try child("iprp")
    let idat = try child("idat")
    let iref = try child("iref")
    let primaryID = parseISOBMFFPITM(source, pitm)
    let itemInfo = parseISOBMFFItemInfos(source, iinf)
    let itemByID = Dictionary(uniqueKeysWithValues: itemInfo.items.map { ($0.itemID, $0) })
    let refsInfo = parseISOBMFFIRefs(source, iref)
    guard let tmapID = itemInfo.items.first(where: { item in
        item.type == "tmap" && refsInfo.refs.contains(where: {
            $0.type == "dimg" && $0.from == item.itemID && $0.to.contains(primaryID)
        })
    })?.itemID,
    let gainMapID = refsInfo.refs.first(where: {
        $0.type == "dimg" && $0.from == tmapID
    })?.to.first(where: {
        $0 != primaryID && itemByID[$0]?.type == "jpeg"
    }) else {
        throw CLIError.invalidContainer("private JPEG Gain Map graph is missing")
    }

    let ilocEntries = try parseISOBMFFILoc(source, iloc)
    let ilocByID = Dictionary(uniqueKeysWithValues: ilocEntries.map { ($0.itemID, $0) })
    guard let jpegEntry = ilocByID[gainMapID],
          jpegEntry.constructionMethod == 0,
          jpegEntry.extents.count == 1 else {
        throw CLIError.invalidContainer("private JPEG Gain Map does not have one file extent")
    }
    let jpegExtent = jpegEntry.extents[0]
    guard jpegExtent.offset >= mdat.dataStart,
          jpegExtent.offset + jpegExtent.length == mdat.dataEnd else {
        throw CLIError.invalidContainer("private JPEG Gain Map is not the final mdat payload")
    }

    let properties = try parseISOBMFFIPCOPropertyInfos(source, iprp)
    guard let ipmaBox = isobmffBoxes(in: source, start: iprp.dataStart, end: iprp.dataEnd)
        .first(where: { $0.type == "ipma" }) else {
        throw CLIError.invalidContainer("private JPEG Gain Map source ipco/ipma missing")
    }
    let ipma = parseISOBMFFIPMA(source, ipmaBox)

    let appendedGraphIDs = Set([gainMapID, tmapID] + itemInfo.items.compactMap { item in
        guard item.type == "mime",
              refsInfo.refs.contains(where: {
                  $0.type == "cdsc" && $0.from == item.itemID && $0.to.contains(tmapID)
              }) else { return nil }
        return item.itemID
    })
    guard let originalMaximumItemID = itemInfo.items
        .filter({ !appendedGraphIDs.contains($0.itemID) })
        .map(\.itemID)
        .max() else {
        throw CLIError.invalidContainer("direct HEVC Gain Map source has no original items")
    }
    let tileIDs = (1...tilePayloads.count).map { originalMaximumItemID + $0 }
    let outputGainMapID = originalMaximumItemID + tilePayloads.count + 1
    let outputTmapID = outputGainMapID + 1
    let xmpID = appendedGraphIDs.first(where: { $0 != gainMapID && $0 != tmapID })
    guard outputTmapID < 0xffff else {
        throw CLIError.invalidContainer("direct HEVC Gain Map requires 16-bit item IDs")
    }
    let remappedItemIDs = [gainMapID: outputGainMapID, tmapID: outputTmapID]
    func outputItemID(_ itemID: Int) -> Int { remappedItemIDs[itemID] ?? itemID }
    let propertyByIndex = Dictionary(uniqueKeysWithValues: properties.map { ($0.index, $0) })
    var uniqueTileSizes: [(width: Int, height: Int)] = []
    for size in tileSizes where !uniqueTileSizes.contains(where: {
        $0.width == size.width && $0.height == size.height
    }) {
        uniqueTileSizes.append(size)
    }
    let originalIPMAEntries = ipma.entries.filter { !appendedGraphIDs.contains($0.itemID) }
    let originalPropertyIndices = Set(originalIPMAEntries.flatMap { entry in
        entry.associations.map { assocPropertyIndex($0, flags: ipma.flags) }
    })
    let originalProperties = properties.filter { originalPropertyIndices.contains($0.index) }
    let originalNonCodecProperties = originalProperties.filter { $0.type != "hvcC" }
    let originalCodecProperties = originalProperties.filter { $0.type == "hvcC" }
    guard !originalCodecProperties.isEmpty else {
        throw CLIError.invalidContainer("direct HEVC Gain Map source Base has no hvcC")
    }

    var ipcoPayload = Data()
    var remappedPropertyIndices: [Int: Int] = [:]
    var nextPropertyIndex = 1
    for property in originalNonCodecProperties {
        remappedPropertyIndices[property.index] = nextPropertyIndex
        ipcoPayload.append(property.rawBox)
        nextPropertyIndex += 1
    }
    func appendProperty(_ rawBox: Data) -> Int {
        let index = nextPropertyIndex
        ipcoPayload.append(rawBox)
        nextPropertyIndex += 1
        return index
    }
    let gainColrIndex = appendProperty(
        channelCount == 1 ? isoColrSRGBBox : isoColrUnspecifiedBT601Box
    )
    let gainGridIspeIndex = appendProperty(makeIspeBox(width: gainMapWidth, height: gainMapHeight))
    let tmapAssociationIndices = ipma.entries.first(where: { $0.itemID == tmapID })?
        .associations
        .map { assocPropertyIndex($0, flags: ipma.flags) } ?? []
    guard let tmapColorProperty = tmapAssociationIndices
        .compactMap({ propertyByIndex[$0] })
        .first(where: { $0.type == "colr" }),
          let tmapPixiProperty = tmapAssociationIndices
        .compactMap({ propertyByIndex[$0] })
        .first(where: { $0.type == "pixi" }) else {
        throw CLIError.invalidContainer("direct HEVC Gain Map tmap properties are incomplete")
    }
    let tmapColorIndex = appendProperty(tmapColorProperty.rawBox)
    let tmapPixiIndex = appendProperty(tmapPixiProperty.rawBox)
    let gainPixiIndex: Int
    if channelCount == 1 {
        gainPixiIndex = appendProperty(isoPixiMono8Box)
    } else {
        let gainPixiOldIndex = originalNonCodecProperties.first(where: {
            $0.rawBox == isoPixiRGB8Box
        })?.index
        if let gainPixiOldIndex, let mapped = remappedPropertyIndices[gainPixiOldIndex] {
            gainPixiIndex = mapped
        } else {
            gainPixiIndex = appendProperty(isoPixiRGB8Box)
        }
    }

    var tileIspeIndexByKey: [String: Int] = [:]
    for size in uniqueTileSizes {
        let rawIspe = makeIspeBox(width: size.width, height: size.height)
        if let existing = originalNonCodecProperties.first(where: { $0.rawBox == rawIspe }),
           let mapped = remappedPropertyIndices[existing.index] {
            tileIspeIndexByKey["\(size.width)x\(size.height)"] = mapped
        } else {
            tileIspeIndexByKey["\(size.width)x\(size.height)"] = appendProperty(rawIspe)
        }
    }
    let primaryAssociationIndices = ipma.entries.first(where: { $0.itemID == primaryID })?
        .associations
        .map { assocPropertyIndex($0, flags: ipma.flags) } ?? []
    guard let primaryIspeOldIndex = primaryAssociationIndices.first(where: {
        propertyByIndex[$0]?.type == "ispe"
    }),
          let primaryIspeProperty = propertyByIndex[primaryIspeOldIndex],
          let primaryIspeIndex = remappedPropertyIndices[primaryIspeOldIndex],
          let irotOldIndex = primaryAssociationIndices.first(where: {
              propertyByIndex[$0]?.type == "irot"
          }) ?? originalNonCodecProperties.first(where: { $0.type == "irot" })?.index,
          let irotProperty = propertyByIndex[irotOldIndex],
          let irotIndex = remappedPropertyIndices[irotOldIndex] else {
        throw CLIError.invalidContainer("direct HEVC Gain Map Base properties lack ispe/irot")
    }
    let tmapIspeBox = try makeImageIOCanonicalTmapIspeBox(
        primaryIspe: primaryIspeProperty.rawBox,
        irot: irotProperty.rawBox
    )
    let tmapIspeIndex: Int
    if tmapIspeBox == primaryIspeProperty.rawBox {
        tmapIspeIndex = primaryIspeIndex
    } else {
        tmapIspeIndex = appendProperty(tmapIspeBox)
    }
    for property in originalCodecProperties {
        remappedPropertyIndices[property.index] = nextPropertyIndex
        ipcoPayload.append(property.rawBox)
        nextPropertyIndex += 1
    }
    let tileHvcCIndex = appendProperty(makeBox("hvcC", payload: hvcC))

    func mappedOriginalAssociations(_ entry: ISOBMFFIPMAEntry) throws -> [(Int, Bool)] {
        try entry.associations.map { association in
            let oldIndex = assocPropertyIndex(association, flags: ipma.flags)
            guard let newIndex = remappedPropertyIndices[oldIndex] else {
                throw CLIError.invalidContainer("direct HEVC Gain Map cannot remap Base property \(oldIndex)")
            }
            return (newIndex, assocIsEssential(association, flags: ipma.flags))
        }
    }
    var ipmaEntries = Data()
    var ipmaCount = 0
    for entry in originalIPMAEntries {
        ipmaEntries.append(try makeIPMAEntry(
            entry.itemID,
            mappedOriginalAssociations(entry),
            flags: ipma.flags,
            version: ipma.version
        ))
        ipmaCount += 1
    }
    for (tileID, size) in zip(tileIDs, tileSizes) {
        guard let tileIspeIndex = tileIspeIndexByKey["\(size.width)x\(size.height)"] else {
            throw CLIError.invalidContainer("direct HEVC Gain Map tile ispe mapping is missing")
        }
        ipmaEntries.append(try makeIPMAEntry(
            tileID,
            [(tileIspeIndex, true), (gainColrIndex, true), (tileHvcCIndex, true)],
            flags: ipma.flags,
            version: ipma.version
        ))
        ipmaCount += 1
    }
    ipmaEntries.append(try makeIPMAEntry(
        outputGainMapID,
        [(gainColrIndex, true), (gainGridIspeIndex, false), (gainPixiIndex, false), (irotIndex, true)],
        flags: ipma.flags,
        version: ipma.version
    ))
    ipmaCount += 1
    ipmaEntries.append(try makeIPMAEntry(
        outputTmapID,
        [(tmapColorIndex, true), (tmapIspeIndex, false), (tmapPixiIndex, false), (irotIndex, true)],
        flags: ipma.flags,
        version: ipma.version
    ))
    ipmaCount += 1
    var ipmaPayload = source.subdata(in: ipmaBox.dataStart..<ipmaBox.dataStart + 4)
    appendUInt32BE(ipmaCount, to: &ipmaPayload)
    ipmaPayload.append(ipmaEntries)
    var iprpPayload = Data()
    iprpPayload.append(makeBox("ipco", payload: ipcoPayload))
    iprpPayload.append(makeBox("ipma", payload: ipmaPayload))
    let iprpPart = makeBox("iprp", payload: iprpPayload)

    var rawInfes = itemInfo.items
        .filter { !appendedGraphIDs.contains($0.itemID) }
        .map(\.rawInfe)
    for tileID in tileIDs {
        rawInfes.append(makeInfeBox(itemID: tileID, type: "hvc1", flags: 1))
    }
    rawInfes.append(makeInfeBox(
        itemID: outputGainMapID,
        type: "grid",
        flags: itemByID[gainMapID]?.flags ?? 1
    ))
    rawInfes.append(makeInfeBox(
        itemID: outputTmapID,
        type: "tmap",
        flags: itemByID[tmapID]?.flags ?? 0
    ))
    let iinfPart = makeIinfBox(version: itemInfo.version, rawInfes: rawInfes)

    guard let tmapEntry = ilocByID[tmapID],
          tmapEntry.constructionMethod == 1,
          tmapEntry.extents.count == 1 else {
        throw CLIError.invalidContainer("private JPEG Gain Map tmap does not have one idat extent")
    }
    let oldTmapExtent = tmapEntry.extents[0]
    let sourceIDATPayload = source.subdata(in: idat.dataStart..<idat.dataEnd)
    guard oldTmapExtent.offset >= 0,
          oldTmapExtent.offset + oldTmapExtent.length <= sourceIDATPayload.count else {
        throw CLIError.invalidContainer("private JPEG Gain Map tmap extent is outside idat")
    }
    let retainedIDATPayload = sourceIDATPayload.prefix(oldTmapExtent.offset)
    let tmapPayload = sourceIDATPayload.subdata(
        in: oldTmapExtent.offset..<(oldTmapExtent.offset + oldTmapExtent.length)
    )
    let gridPayload = try makeGridPayload(
        rows: rows,
        columns: columns,
        width: gainMapWidth,
        height: gainMapHeight
    )
    let gridIDATOffset = retainedIDATPayload.count
    let tmapIDATOffset = gridIDATOffset + gridPayload.count
    let idatPart = makeBox("idat", payload: Data(retainedIDATPayload) + gridPayload + tmapPayload)

    var outputRefs = refsInfo.refs.compactMap { ref -> ISOBMFFIRefEntry? in
        guard !(ref.type == "dimg" && ref.from == gainMapID),
              !(ref.type == "dimg" && ref.from == tmapID),
              ref.type != "auxl",
              ref.from != xmpID else { return nil }
        let mappedFrom = outputItemID(ref.from)
        var mappedTargets = ref.to.map(outputItemID)
        if ref.type == "cdsc",
           itemByID[ref.from]?.type == "Exif",
           ref.to.contains(primaryID),
           !ref.to.contains(tmapID) {
            mappedTargets.append(outputTmapID)
        }
        return ISOBMFFIRefEntry(type: ref.type, from: mappedFrom, to: mappedTargets)
    }
    outputRefs.append(ISOBMFFIRefEntry(type: "dimg", from: outputGainMapID, to: tileIDs))
    outputRefs.append(ISOBMFFIRefEntry(
        type: "dimg",
        from: outputTmapID,
        to: [primaryID, outputGainMapID]
    ))
    let irefVersion: UInt8 = (outputRefs.flatMap { [$0.from] + $0.to }.max() ?? 0) > 0xffff
        ? 1
        : refsInfo.version
    let irefPart = makeIrefFullBox(version: irefVersion, refs: outputRefs)

    var placeholderLocations = ilocEntries
        .filter { !appendedGraphIDs.contains($0.itemID) || $0.itemID == tmapID }
        .map { entry in
            ISOBMFFILocEntry(
                itemID: outputItemID(entry.itemID),
                constructionMethod: entry.constructionMethod,
                dataReferenceIndex: entry.dataReferenceIndex,
                extents: entry.itemID == tmapID
                    ? [(offset: tmapIDATOffset, length: tmapPayload.count)]
                    : entry.extents.map { (offset: 0, length: $0.length) }
            )
        }
    placeholderLocations.append(ISOBMFFILocEntry(
        itemID: outputGainMapID,
        constructionMethod: 1,
        dataReferenceIndex: 0,
        extents: [(gridIDATOffset, gridPayload.count)]
    ))
    for (tileID, payload) in zip(tileIDs, tilePayloads) {
        placeholderLocations.append(ISOBMFFILocEntry(
            itemID: tileID,
            constructionMethod: 0,
            dataReferenceIndex: 0,
            extents: [(0, payload.count)]
        ))
    }
    placeholderLocations.sort { $0.itemID < $1.itemID }

    var altrPayload = Data([0, 0, 0, 0])
    appendUInt32BE(outputTmapID + 1, to: &altrPayload)
    appendUInt32BE(2, to: &altrPayload)
    appendUInt32BE(outputTmapID, to: &altrPayload)
    appendUInt32BE(primaryID, to: &altrPayload)
    let grplPart = makeBox("grpl", payload: makeBox("altr", payload: altrPayload))

    var metaParts: [Data] = []
    for part in metaChildren {
        switch part.type {
        case "iinf": metaParts.append(iinfPart)
        case "iloc": metaParts.append(makeIlocV1Box(entries: placeholderLocations))
        case "iprp": metaParts.append(iprpPart)
        case "iref": metaParts.append(irefPart)
        case "idat": metaParts.append(idatPart)
        case "grpl": metaParts.append(grplPart)
        default: metaParts.append(source.subdata(in: part.boxStart..<part.boxStart + part.size))
        }
    }

    let sourceBrandOrder = stride(from: ftyp.dataStart + 8, to: ftyp.dataEnd, by: 4).compactMap {
        position -> String? in
        guard position + 4 <= ftyp.dataEnd else { return nil }
        return String(data: source.subdata(in: position..<position + 4), encoding: .ascii)
    }
    let preferredBrands = ["mif1", "tmap", "MiHE", "miaf", "MiHB", "heic"]
    var orderedBrands = preferredBrands
    for brand in sourceBrandOrder where !orderedBrands.contains(brand) {
        orderedBrands.append(brand)
    }
    var ftypPayload = source.subdata(in: ftyp.dataStart..<ftyp.dataStart + 8)
    for brand in orderedBrands {
        ftypPayload.append(Data(brand.utf8))
    }
    let ftypPart = makeBox("ftyp", payload: ftypPayload)
    var preliminaryMetaPayload = source.subdata(in: meta.dataStart..<meta.dataStart + 4)
    for part in metaParts { preliminaryMetaPayload.append(part) }
    let preliminaryMetaPart = makeBox("meta", payload: preliminaryMetaPayload)
    let betweenMetaAndMdat = source.subdata(in: meta.boxStart + meta.size..<mdat.boxStart)
    let newMdatDataStart = ftypPart.count + preliminaryMetaPart.count + betweenMetaAndMdat.count + 8
    let fileDelta = newMdatDataStart - mdat.dataStart

    var finalLocations: [ISOBMFFILocEntry] = []
    for entry in ilocEntries where !appendedGraphIDs.contains(entry.itemID) || entry.itemID == tmapID {
        finalLocations.append(ISOBMFFILocEntry(
            itemID: outputItemID(entry.itemID),
            constructionMethod: entry.constructionMethod,
            dataReferenceIndex: entry.dataReferenceIndex,
            extents: entry.itemID == tmapID
                ? [(offset: tmapIDATOffset, length: tmapPayload.count)]
                : entry.extents.map { extent in
                if entry.constructionMethod == 0 {
                    return (extent.offset + fileDelta, extent.length)
                }
                return extent
            }
        ))
    }
    finalLocations.append(ISOBMFFILocEntry(
        itemID: outputGainMapID,
        constructionMethod: 1,
        dataReferenceIndex: 0,
        extents: [(gridIDATOffset, gridPayload.count)]
    ))
    let sourceMdatPayload = source.subdata(in: mdat.dataStart..<jpegExtent.offset)
    var appendedTiles = Data()
    for (tileID, payload) in zip(tileIDs, tilePayloads) {
        let offset = newMdatDataStart + sourceMdatPayload.count + appendedTiles.count
        appendedTiles.append(payload)
        finalLocations.append(ISOBMFFILocEntry(
            itemID: tileID,
            constructionMethod: 0,
            dataReferenceIndex: 0,
            extents: [(offset, payload.count)]
        ))
    }
    finalLocations.sort { $0.itemID < $1.itemID }
    let finalIlocPart = makeIlocV1Box(entries: finalLocations)
    let finalMetaParts = metaParts.map { part -> Data in
        guard part.count >= 8,
              String(data: part.subdata(in: 4..<8), encoding: .ascii) == "iloc" else {
            return part
        }
        return finalIlocPart
    }
    var finalMetaPayload = source.subdata(in: meta.dataStart..<meta.dataStart + 4)
    for part in finalMetaParts { finalMetaPayload.append(part) }
    let finalMetaPart = makeBox("meta", payload: finalMetaPayload)
    let finalMdatPart = makeBox("mdat", payload: sourceMdatPayload + appendedTiles)

    var output = Data()
    output.append(ftypPart)
    output.append(finalMetaPart)
    output.append(betweenMetaAndMdat)
    output.append(finalMdatPart)
    try output.write(to: outputURL, options: .atomic)
}

package func makePrivateGainMapInfoFloats(scale: ResolvedScale) -> [Double] {
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
