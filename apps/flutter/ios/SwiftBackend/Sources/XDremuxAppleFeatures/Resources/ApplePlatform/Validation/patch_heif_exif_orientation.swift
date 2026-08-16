#!/usr/bin/env swift

import Foundation

enum PatchError: Error, CustomStringConvertible {
    case usage
    case exifToolFailed(String)
    case orientationOffsetMissing
    case invalidOrientation(Int)
    case invalidOffset(Int)

    var description: String {
        switch self {
        case .usage:
            return "usage: patch_heif_exif_orientation.swift input.heic output.heic 1|3|6|8"
        case .exifToolFailed(let message):
            return "exiftool failed: \(message)"
        case .orientationOffsetMissing:
            return "could not locate the primary HEIF Exif orientation value"
        case .invalidOrientation(let value):
            return "unsupported test orientation: \(value)"
        case .invalidOffset(let value):
            return "Exif orientation offset is outside the file: \(value)"
        }
    }
}

func orientationOffset(in input: URL) throws -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [
        "-c",
        "/opt/homebrew/bin/exiftool -v3 \"$1\" 2>&1 | /usr/bin/awk '/Orientation =/{getline; getline; print; exit}'",
        "xdremux-orientation-offset",
        input.path,
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw PatchError.exifToolFailed(text)
    }
    if let colon = text.firstIndex(of: ":") {
        let prefix = text[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        if let token = prefix.split(whereSeparator: { $0.isWhitespace }).last,
           let offset = Int(token, radix: 16) { return offset }
    }
    throw PatchError.orientationOffsetMissing
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 3, let orientation = Int(arguments[2]) else {
        throw PatchError.usage
    }
    guard [1, 3, 6, 8].contains(orientation) else {
        throw PatchError.invalidOrientation(orientation)
    }
    let input = URL(fileURLWithPath: arguments[0])
    let output = URL(fileURLWithPath: arguments[1])
    let offset = try orientationOffset(in: input)
    var data = try Data(contentsOf: input)
    guard offset >= 0, offset + 2 <= data.count else {
        throw PatchError.invalidOffset(offset)
    }
    // OPPO HEIF samples use little-endian TIFF. Only mutate the two-byte value;
    // every item offset and the vendor tail remain byte-for-byte stable.
    data[offset] = UInt8(orientation)
    data[offset + 1] = 0
    try data.write(to: output, options: .atomic)
    print("patched orientation=\(orientation) offset=0x\(String(offset, radix: 16)) output=\(output.path)")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
