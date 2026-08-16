import Foundation
import CryptoKit

package func ensureDirectory(_ url: URL, fileManager: FileManager) throws {
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

package func siblingScratchURL(for outputURL: URL, label: String, pathExtension: String) -> URL {
    outputURL.deletingLastPathComponent().appendingPathComponent(
        ".xdremux-\(label)-\(UUID().uuidString).\(pathExtension)"
    )
}

package func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

package func clamp<T: Comparable>(_ value: T, min lower: T, max upper: T) -> T {
    Swift.min(Swift.max(value, lower), upper)
}

package func alignUp(_ value: Int, toMultipleOf multiple: Int) -> Int {
    guard multiple > 0 else { return value }
    let remainder = value % multiple
    return remainder == 0 ? value : value + (multiple - remainder)
}

package func round(_ value: Double, digits: Int) -> Double {
    let scale = pow(10.0, Double(digits))
    return (value * scale).rounded() / scale
}

package func safeLog2(_ value: Double) -> Double {
    guard value.isFinite, value > 0 else { return 0.0 }
    return log2(value)
}

package func buildFloatAudits(_ floats: [Double]) -> [FloatAuditEntry] {
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

package func optionalLog(_ value: Double) -> Double? {
    guard value.isFinite, value > 0 else { return nil }
    return log(value)
}

package func optionalLog2(_ value: Double) -> Double? {
    guard value.isFinite, value > 0 else { return nil }
    return log2(value)
}

package func optionalLog10(_ value: Double) -> Double? {
    guard value.isFinite, value > 0 else { return nil }
    return log10(value)
}

package func optionalSqrt(_ value: Double) -> Double? {
    guard value.isFinite, value >= 0 else { return nil }
    return sqrt(value)
}

package func optionalReciprocal(_ value: Double) -> Double? {
    guard value.isFinite, value != 0 else { return nil }
    return 1.0 / value
}

package func optionalExp(_ value: Double) -> Double? {
    guard value.isFinite, value <= 700.0 else { return nil }
    return exp(value)
}

package func optionalExp2(_ value: Double) -> Double? {
    guard value.isFinite, value <= 1023.0 else { return nil }
    return exp2(value)
}

package func realCubeRoot(_ value: Double) -> Double {
    if value == 0 { return 0 }
    let magnitude = pow(abs(value), 1.0 / 3.0)
    return value < 0 ? -magnitude : magnitude
}

package func formatFloat(_ value: Double, digits: Int) -> String {
    String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value)
}

package func readUInt32BE(from data: Data, at offset: Int) throws -> UInt32 {
    guard offset >= 0, offset + 4 <= data.count else {
        throw CLIError.invalidLHDR("out-of-range uint32 read at \(offset)")
    }
    var value: UInt32 = 0
    _ = withUnsafeMutableBytes(of: &value) { buffer in
        data.subdata(in: offset..<(offset + 4)).copyBytes(to: buffer)
    }
    return UInt32(bigEndian: value)
}

package func unpack36FloatLE(_ data: Data) throws -> [Double] {
    try unpackFloatArrayLE(data, count: 36)
}

package func unpackFloatArrayLE(_ data: Data, count: Int) throws -> [Double] {
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

package func firstIndex(of needle: Data, in haystack: Data, startingAt start: Int = 0) -> Int? {
    guard !needle.isEmpty, start < haystack.count else { return nil }
    return haystack.range(of: needle, options: [], in: start..<haystack.count)?.lowerBound
}

package func firstIndex(of byte: UInt8, in haystack: Data, startingAt start: Int = 0) -> Int? {
    guard start < haystack.count else { return nil }
    return haystack[start..<haystack.count].firstIndex(of: byte)
}

package func lastIndex(of needle: Data, in haystack: Data) -> Int? {
    guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
    return haystack.range(of: needle, options: [.backwards], in: 0..<haystack.count)?.lowerBound
}
