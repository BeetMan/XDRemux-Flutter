import Compression
import Foundation

/// A minimal read-only ZIP reader: central directory, stored and deflate
/// entries, no encryption, no zip64. Enough for the `.pvt.zip` bundles the
/// Flutter app sends (stored) and for hand-zipped folders (deflate).
public struct ZipArchive {
    public enum Failure: Error, Equatable {
        case notZip, truncated, unsupportedMethod(UInt16), zip64, corrupt
    }

    public struct Entry: Hashable, Sendable {
        public var name: String
        public var isDirectory: Bool { name.hasSuffix("/") }
        public var size: UInt32
        var compressedSize: UInt32
        var method: UInt16
        var localHeaderOffset: UInt32
    }

    public let entries: [Entry]
    private let data: Data

    public init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        self.data = data
        // End of central directory: scan backwards over the comment.
        let eocdSignature: UInt32 = 0x0605_4b50
        guard data.count >= 22 else { throw Failure.notZip }
        var eocd = -1
        var i = data.count - 22
        let floor = max(0, data.count - 22 - 0xFFFF)
        while i >= floor {
            if data.u32(at: i) == eocdSignature { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw Failure.notZip }
        let count = Int(data.u16(at: eocd + 10))
        let directorySize = Int(data.u32(at: eocd + 12))
        let directoryOffset = Int(data.u32(at: eocd + 16))
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF { throw Failure.zip64 }
        guard directoryOffset + directorySize <= data.count else { throw Failure.truncated }

        var entries: [Entry] = []
        var cursor = directoryOffset
        for _ in 0..<count {
            guard cursor + 46 <= data.count, data.u32(at: cursor) == 0x0201_4b50 else { throw Failure.corrupt }
            let method = data.u16(at: cursor + 10)
            let compressedSize = data.u32(at: cursor + 20)
            let size = data.u32(at: cursor + 24)
            let nameLength = Int(data.u16(at: cursor + 28))
            let extraLength = Int(data.u16(at: cursor + 30))
            let commentLength = Int(data.u16(at: cursor + 32))
            let localHeaderOffset = data.u32(at: cursor + 42)
            guard cursor + 46 + nameLength <= data.count else { throw Failure.truncated }
            let name = String(decoding: data[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            if size == 0xFFFF_FFFF || compressedSize == 0xFFFF_FFFF || localHeaderOffset == 0xFFFF_FFFF { throw Failure.zip64 }
            entries.append(Entry(name: name, size: size, compressedSize: compressedSize,
                                 method: method, localHeaderOffset: localHeaderOffset))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    /// The entry's bytes, inflated when needed.
    public func contents(of entry: Entry) throws -> Data {
        let header = Int(entry.localHeaderOffset)
        guard header + 30 <= data.count, data.u32(at: header) == 0x0403_4b50 else { throw Failure.corrupt }
        let nameLength = Int(data.u16(at: header + 26))
        let extraLength = Int(data.u16(at: header + 28))
        let start = header + 30 + nameLength + extraLength
        let end = start + Int(entry.compressedSize)
        guard end <= data.count else { throw Failure.truncated }
        let raw = data[start..<end]
        switch entry.method {
        case 0:
            return Data(raw)
        case 8:
            return try Self.inflate(raw, size: Int(entry.size))
        case let other:
            throw Failure.unsupportedMethod(other)
        }
    }

    /// Writes the entry to `url` (streams through memory; entries are a few MB).
    public func extract(_ entry: Entry, to url: URL) throws {
        try contents(of: entry).write(to: url, options: .atomic)
    }

    private static func inflate(_ raw: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            raw.withUnsafeBytes { src -> Int in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw Failure.corrupt }
        return out
    }
}

private extension Data {
    func u16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }
    func u32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
