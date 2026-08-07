import Foundation

/// Experimental post-writer patch for Apple Photographic Styles.
///
/// The upstream v1.3.1 writer stores key `1` of the styleMetadata binary
/// plist as 864 (12 x 9 x 8) polynomial blocks. The current producer repeats
/// one global block, so this prototype replaces the candidate bottom spatial
/// rows with complete-identity blocks. It is deliberately opt-in and fails
/// closed when the container or plist shape differs.
enum AppleStylesWatermarkMaskBridge {
    struct Report {
        let patchedBlocks: Int
        let bottomRows: Int
        let spatialColumns: Int
        let spatialRows: Int
        let subtileCount: Int
    }

    private struct Box {
        let start: Int
        let size: Int
        let type: String

        var headerSize: Int { size >= 16 && type == "uuid" ? 16 : 8 }
        var dataStart: Int { start + 8 }
        var dataEnd: Int { start + size }
    }

    private struct IlocEntry {
        let itemID: Int
        let constructionMethod: Int
        let extents: [(offset: Int, length: Int)]
    }

    private static let spatialColumns = 12
    private static let spatialRows = 9
    private static let subtileCount = 8
    private static let polynomialBlockBytes = 10 * 3 * 2
    private static let styleDataBytes = spatialColumns
        * spatialRows
        * subtileCount
        * polynomialBlockBytes

    static func neutralizeBottomWatermarkRows(
        outputURL: URL,
        bottomRows: Int = 2
    ) throws -> Report {
        guard (1...spatialRows).contains(bottomRows) else {
            throw BridgeError.invalidStyleData("bottom row count is outside 1...9")
        }

        let mappedOutput = try Data(contentsOf: outputURL, options: [.mappedIfSafe])
        var output = Data()
        output.reserveCapacity(mappedOutput.count)
        output.append(mappedOutput)
        let topLevel = boxes(in: output, start: 0, end: output.count)
        guard let meta = topLevel.first(where: { $0.type == "meta" }) else {
            throw BridgeError.invalidContainer("meta box is missing")
        }
        let metaChildren = boxes(in: output, start: meta.dataStart + 4, end: meta.dataEnd)
        guard let iinf = metaChildren.first(where: { $0.type == "iinf" }),
              let iloc = metaChildren.first(where: { $0.type == "iloc" }),
              let idat = metaChildren.first(where: { $0.type == "idat" }) else {
            throw BridgeError.invalidContainer("styleMetadata requires iinf, iloc and idat")
        }

        guard let styleItemID = styleMetadataItemID(in: output, iinf: iinf) else {
            throw BridgeError.invalidStyleData("styleMetadata item is missing")
        }
        let locations = try parseIloc(in: output, box: iloc)
        guard let location = locations.first(where: { $0.itemID == styleItemID }),
              location.constructionMethod == 1,
              location.extents.count == 1 else {
            throw BridgeError.invalidStyleData("styleMetadata iloc shape is unsupported")
        }

        let extent = location.extents[0]
        let payloadStart = idat.dataStart + extent.offset
        let payloadEnd = payloadStart + extent.length
        guard payloadStart >= idat.dataStart,
              payloadEnd <= idat.dataEnd,
              payloadEnd <= output.count else {
            throw BridgeError.invalidContainer("styleMetadata payload is out of bounds")
        }

        var propertyListData = Data()
        propertyListData.reserveCapacity(payloadEnd - payloadStart)
        propertyListData.append(output.subdata(in: payloadStart..<payloadEnd))
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: propertyListData,
            options: [],
            format: nil
        ) as? [String: Any],
              let styleData = propertyList["1"] as? Data,
              styleData.count == styleDataBytes else {
            throw BridgeError.invalidStyleData(
                "styleMetadata key 1 is not the expected \(styleDataBytes)-byte Data"
            )
        }

        guard let styleDataRange = propertyListData.range(of: styleData) else {
            throw BridgeError.invalidStyleData("key 1 bytes are not found in the binary plist")
        }
        var patchedStyleData = Data()
        patchedStyleData.reserveCapacity(styleData.count)
        patchedStyleData.append(styleData)
        let identityBlock = makeIdentityBlock()
        var patchedBlocks = 0
        for row in (spatialRows - bottomRows)..<spatialRows {
            for column in 0..<spatialColumns {
                for subtile in 0..<subtileCount {
                    let blockIndex = ((row * spatialColumns) + column) * subtileCount + subtile
                    let blockStart = blockIndex * polynomialBlockBytes
                    patchedStyleData.replaceSubrange(
                        blockStart..<(blockStart + polynomialBlockBytes),
                        with: identityBlock
                    )
                    patchedBlocks += 1
                }
            }
        }
        propertyListData.replaceSubrange(styleDataRange, with: patchedStyleData)
        guard propertyListData.count == extent.length,
              let patchedPropertyList = try? PropertyListSerialization.propertyList(
                  from: propertyListData,
                  options: [],
                  format: nil
              ) as? [String: Any],
              let readback = patchedPropertyList["1"] as? Data,
              readback == patchedStyleData else {
            throw BridgeError.invalidStyleData("patched styleMetadata plist failed readback")
        }

        output.replaceSubrange(payloadStart..<payloadEnd, with: propertyListData)
        try output.write(to: outputURL, options: [.atomic])
        return Report(
            patchedBlocks: patchedBlocks,
            bottomRows: bottomRows,
            spatialColumns: spatialColumns,
            spatialRows: spatialRows,
            subtileCount: subtileCount
        )
    }

    private static func makeIdentityBlock() -> Data {
        let identityIndices: Set<Int> = [3, 7, 11]
        var block = Data(capacity: polynomialBlockBytes)
        for index in 0..<30 {
            let value: UInt16 = identityIndices.contains(index) ? 0x3c00 : 0
            block.append(UInt8(value & 0xff))
            block.append(UInt8(value >> 8))
        }
        return block
    }

    private static func styleMetadataItemID(in data: Data, iinf: Box) -> Int? {
        let version = data[iinf.dataStart]
        var position = iinf.dataStart + 4
        if version >= 1 {
            position += 4
        } else {
            position += 2
        }
        for child in boxes(in: data, start: position, end: iinf.dataEnd)
            where child.type == "infe" {
            let itemVersion = data[child.dataStart]
            guard itemVersion >= 2 else { continue }
            var cursor = child.dataStart + 4
            let itemID: Int
            if itemVersion >= 3 {
                guard cursor + 4 <= child.dataEnd else { continue }
                itemID = Int(readUInt32BE(data, at: cursor))
                cursor += 4
            } else {
                guard cursor + 2 <= child.dataEnd else { continue }
                itemID = Int(readUInt16BE(data, at: cursor))
                cursor += 2
            }
            guard cursor + 2 + 4 <= child.dataEnd else { continue }
            cursor += 2
            let type = String(
                bytes: data[cursor..<(cursor + 4)],
                encoding: .ascii
            ) ?? ""
            cursor += 4
            guard type == "uri " else { continue }
            guard let name = readCString(data, from: &cursor, end: child.dataEnd) else {
                continue
            }
            if name == "styleMetadata" {
                return itemID
            }
        }
        return nil
    }

    private static func parseIloc(in data: Data, box: Box) throws -> [IlocEntry] {
        let version = data[box.dataStart]
        var position = box.dataStart + 4
        guard position + 2 <= box.dataEnd else {
            throw BridgeError.invalidContainer("iloc header is truncated")
        }
        let sizes0 = data[position]
        let sizes1 = data[position + 1]
        position += 2
        let offsetSize = Int((sizes0 >> 4) & 0x0f)
        let lengthSize = Int(sizes0 & 0x0f)
        let baseOffsetSize = Int((sizes1 >> 4) & 0x0f)
        let indexSize = version == 1 || version == 2 ? Int(sizes1 & 0x0f) : 0
        let count: Int
        if version >= 2 {
            guard position + 4 <= box.dataEnd else {
                throw BridgeError.invalidContainer("iloc item count is truncated")
            }
            count = Int(readUInt32BE(data, at: position))
            position += 4
        } else {
            guard position + 2 <= box.dataEnd else {
                throw BridgeError.invalidContainer("iloc item count is truncated")
            }
            count = Int(readUInt16BE(data, at: position))
            position += 2
        }

        func readSized(_ size: Int) throws -> Int {
            guard size <= 8, position + size <= box.dataEnd else {
                throw BridgeError.invalidContainer("iloc integer is truncated")
            }
            var value = 0
            for _ in 0..<size {
                if value > (Int.max >> 8) {
                    throw BridgeError.invalidContainer("iloc integer overflows Int")
                }
                value = (value << 8) | Int(data[position])
                position += 1
            }
            return value
        }

        var result: [IlocEntry] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            let itemID = try readSized(version >= 2 ? 4 : 2)
            let constructionMethod: Int
            if version == 1 || version == 2 {
                guard position + 2 <= box.dataEnd else {
                    throw BridgeError.invalidContainer("iloc construction method is truncated")
                }
                constructionMethod = Int(readUInt16BE(data, at: position) & 0x0f)
                position += 2
            } else {
                constructionMethod = 0
            }
            _ = try readSized(2)
            let baseOffset = try readSized(baseOffsetSize)
            let extentCount = try readSized(2)
            var extents: [(offset: Int, length: Int)] = []
            extents.reserveCapacity(extentCount)
            for _ in 0..<extentCount {
                if indexSize > 0 { _ = try readSized(indexSize) }
                let offset = try readSized(offsetSize)
                let length = try readSized(lengthSize)
                guard baseOffset <= Int.max - offset else {
                    throw BridgeError.invalidContainer("iloc extent offset overflows Int")
                }
                extents.append((baseOffset + offset, length))
            }
            result.append(IlocEntry(
                itemID: itemID,
                constructionMethod: constructionMethod,
                extents: extents
            ))
        }
        return result
    }

    private static func boxes(in data: Data, start: Int, end: Int) -> [Box] {
        var result: [Box] = []
        var position = start
        while position + 8 <= end {
            let size32 = readUInt32BE(data, at: position)
            let type = String(
                bytes: data[(position + 4)..<(position + 8)],
                encoding: .ascii
            ) ?? ""
            let headerSize: Int
            let size: Int
            if size32 == 1 {
                guard position + 16 <= end else { break }
                let extended = readUInt64BE(data, at: position + 8)
                guard extended >= 16, extended <= UInt64(Int.max) else { break }
                headerSize = 16
                size = Int(extended)
            } else if size32 == 0 {
                headerSize = 8
                size = end - position
            } else {
                headerSize = 8
                size = Int(size32)
            }
            guard size >= headerSize, position + size <= end else { break }
            result.append(Box(start: position, size: size, type: type))
            position += size
        }
        return result
    }

    private static func readCString(
        _ data: Data,
        from position: inout Int,
        end: Int
    ) -> String? {
        let start = position
        while position < end, data[position] != 0 {
            position += 1
        }
        guard position < end else { return nil }
        let result = String(bytes: data[start..<position], encoding: .utf8)
        position += 1
        return result
    }

    private static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
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

    private enum BridgeError: LocalizedError {
        case invalidContainer(String)
        case invalidStyleData(String)

        var errorDescription: String? {
            switch self {
            case .invalidContainer(let message):
                return "Styles watermark mask container invalid: \(message)"
            case .invalidStyleData(let message):
                return "Styles watermark mask styleMetadata invalid: \(message)"
            }
        }
    }
}
