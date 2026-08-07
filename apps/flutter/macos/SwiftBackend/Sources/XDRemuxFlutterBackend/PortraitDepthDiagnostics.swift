import Foundation

/// Read-only macOS diagnostics for OPPO rear Portrait depth variants.
///
/// This target is macOS-only and may use a locally installed zstd executable
/// for analysis. It is deliberately separate from the conversion path: a
/// report can identify a producer variant without making that variant eligible
/// for Apple Portrait output.
public enum PortraitDepthDiagnostics {
    public static let schema = "xdremux-portrait-depth-diagnostic-v1"

    public static var zstdExecutablePath: String? {
        zstdURL()?.path
    }

    public static var isAvailable: Bool {
        zstdURL() != nil
    }

    public static func report(for inputURL: URL) throws -> [String: Any] {
        let names = try AppleWatermarkTailBridge.tailEntryNames(sourceURL: inputURL)
        var report: [String: Any] = [
            "schema": schema,
            "inputPath": inputURL.path,
            "available": false,
            "safeToTransform": false,
            "classification": "missing-rear-depth",
            "resources": names,
        ]

        guard let compressedDepth = try AppleWatermarkTailBridge.tailPayload(
            named: "rear.depth",
            sourceURL: inputURL
        ) else {
            return report
        }

        var resourceLengths: [String: Int] = ["rear.depth": compressedDepth.count]
        for name in ["rear.depth.config", "src.image", "front.depth", "front.segment", "front.hair.mask"] {
            if let payload = try AppleWatermarkTailBridge.tailPayload(named: name, sourceURL: inputURL) {
                resourceLengths[name] = payload.count
            }
        }
        report["resources"] = resourceLengths

        guard let zstdURL = zstdURL() else {
            report["classification"] = "rear-depth-zstd-unavailable"
            report["zstd"] = ["available": false]
            return report
        }

        let decodedDepth = try decompressZstd(compressedDepth, executableURL: zstdURL)
        let parsed = try parseDepth(decodedDepth)
        report["available"] = true
        report["zstd"] = [
            "available": true,
            "executable": zstdURL.path,
        ]
        report["decodedBytes"] = decodedDepth.count
        report["header"] = parsed.header
        report["planes"] = parsed.planes
        report["calibration"] = parsed.calibration
        report["classification"] = parsed.calibration["classification"] ?? "unknown"
        report["safeToTransform"] = parsed.calibration["safeToTransform"] ?? false
        return report
    }

    private struct ParsedDepth {
        let header: [String: Any]
        let planes: [String: Any]
        let calibration: [String: Any]
    }

    private struct ByteStatistics {
        let minimum: Int
        let maximum: Int
        let zeroCount: Int
        let nonZeroCount: Int
        let mean: Double

        var dictionary: [String: Any] {
            [
                "min": minimum,
                "max": maximum,
                "zeroCount": zeroCount,
                "nonZeroCount": nonZeroCount,
                "mean": mean,
            ]
        }
    }

    private static func parseDepth(_ data: Data) throws -> ParsedDepth {
        let headerSize = 768
        guard data.count >= headerSize else {
            throw DiagnosticError.invalidDepth("decoded rear.depth is shorter than its 768-byte header")
        }
        guard let widthRaw = readUInt32LE(data, at: 0),
              let heightRaw = readUInt32LE(data, at: 4),
              widthRaw > 0,
              heightRaw > 0,
              widthRaw <= 16_384,
              heightRaw <= 16_384 else {
            throw DiagnosticError.invalidDepth("decoded rear.depth dimensions are invalid")
        }

        let width = Int(widthRaw)
        let height = Int(heightRaw)
        let planeSize = try checkedMultiply(width, height)
        guard data.count >= headerSize + planeSize else {
            throw DiagnosticError.invalidDepth("decoded rear.depth rank plane is truncated")
        }

        guard let rawScale = readUInt32LE(data, at: 0x18),
              let focalLength = readFloat32LE(data, at: 0x1c),
              let stereoBaseline = readFloat32LE(data, at: 0x20),
              let nearConfidence = readFloat32LE(data, at: 0x28),
              let disparityMinimum = readUInt16LE(data, at: 0x2e),
              let disparityMaximum = readUInt16LE(data, at: 0x30),
              let auxiliaryWidth = readUInt32LE(data, at: 0x188),
              let auxiliaryHeight = readUInt32LE(data, at: 0x18c),
              let sceneClass = readInt32LE(data, at: 0x1b0) else {
            throw DiagnosticError.invalidDepth("decoded rear.depth header is truncated")
        }

        var cursor = headerSize
        var planeReports: [String: Any] = [
            "rank": planeStatistics(data, offset: cursor, count: planeSize).dictionary,
        ]
        cursor += planeSize
        let hairPresent = data[0x24] != 0
        let portraitPresent = data[0x25] != 0
        let petPresent = data[0x26] != 0
        if hairPresent {
            guard data.count >= cursor + planeSize else {
                throw DiagnosticError.invalidDepth("decoded rear.depth hair plane is truncated")
            }
            planeReports["hair"] = planeStatistics(data, offset: cursor, count: planeSize).dictionary
            cursor += planeSize
        }
        if portraitPresent {
            guard data.count >= cursor + planeSize else {
                throw DiagnosticError.invalidDepth("decoded rear.depth portrait plane is truncated")
            }
            planeReports["portrait"] = planeStatistics(data, offset: cursor, count: planeSize).dictionary
            cursor += planeSize
        }
        if petPresent {
            guard data.count >= cursor + planeSize else {
                throw DiagnosticError.invalidDepth("decoded rear.depth pet plane is truncated")
            }
            planeReports["pet"] = planeStatistics(data, offset: cursor, count: planeSize).dictionary
        }

        let rankStats = planeStatistics(data, offset: headerSize, count: planeSize)
        let exponentiation = Int(data[0x32])
        let quantizationValid = disparityMaximum > disparityMinimum
            && (1...2).contains(exponentiation)
        let zeroQuantization = disparityMinimum == 0
            && disparityMaximum == 0
            && exponentiation == 0
        let classification: String
        let calibrationStatus: String
        if zeroQuantization && rankStats.maximum > 0 {
            classification = "rear-v4-zero-quantization"
            calibrationStatus = "requires-scale-calibration"
        } else if quantizationValid {
            classification = "rear-v4-validated-quantization"
            calibrationStatus = "producer-quantization-present"
        } else {
            classification = "rear-depth-invalid-quantization"
            calibrationStatus = "invalid"
        }

        let rankScaleFloat = Float(bitPattern: rawScale)
        let header: [String: Any] = [
            "width": width,
            "height": height,
            "rawScaleUInt32": rawScale,
            "rawScaleFloat32": Double(rankScaleFloat),
            "focalLengthPixels": Double(focalLength),
            "stereoBaseline": Double(stereoBaseline),
            "hairPlanePresent": hairPresent,
            "portraitPlanePresent": portraitPresent,
            "petPlanePresent": petPresent,
            "nearObjectDetected": data[0x27] != 0,
            "nearObjectConfidence": Double(nearConfidence),
            "plantObjectState": Int(data[0x2c]),
            "disparityMinimum": disparityMinimum,
            "disparityMaximum": disparityMaximum,
            "disparityExponentiation": exponentiation,
            "auxiliaryWidth": auxiliaryWidth,
            "auxiliaryHeight": auxiliaryHeight,
            "modelOutputPresent": data[0x190] != 0,
            "sceneClass": sceneClass,
        ]
        let calibration: [String: Any] = [
            "classification": classification,
            "status": calibrationStatus,
            "producerQuantizationValid": quantizationValid,
            "safeToTransform": quantizationValid,
            "rankScaleInterpretations": [
                "float32": Double(rankScaleFloat),
                "uint32": rawScale,
            ],
            "warning": quantizationValid
                ? "Producer quantization is present; Apple disparity calibration is still separate."
                : "No production disparity fallback is applied by this diagnostic.",
        ]
        return ParsedDepth(header: header, planes: planeReports, calibration: calibration)
    }

    private static func planeStatistics(_ data: Data, offset: Int, count: Int) -> ByteStatistics {
        var minimum = 255
        var maximum = 0
        var zeroCount = 0
        var sum: Int64 = 0
        for byte in data[offset..<(offset + count)] {
            let value = Int(byte)
            minimum = min(minimum, value)
            maximum = max(maximum, value)
            if value == 0 { zeroCount += 1 }
            sum += Int64(value)
        }
        return ByteStatistics(
            minimum: minimum,
            maximum: maximum,
            zeroCount: zeroCount,
            nonZeroCount: count - zeroCount,
            mean: Double(sum) / Double(count)
        )
    }

    private static func decompressZstd(_ data: Data, executableURL: URL) throws -> Data {
        let input = FileManager.default.temporaryDirectory
            .appendingPathComponent("xdremux-depth-\(UUID().uuidString).zst")
        defer { try? FileManager.default.removeItem(at: input) }
        try data.write(to: input, options: .atomic)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-d", "-q", "-c", input.path]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw DiagnosticError.zstdUnavailable
        }
        let decoded = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "zstd failed"
            throw DiagnosticError.invalidDepth(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return decoded
    }

    private static func zstdURL() -> URL? {
        let candidates = [
            "/usr/bin/zstd",
            "/opt/homebrew/bin/zstd",
            "/usr/local/bin/zstd",
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private static func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw DiagnosticError.invalidDepth("depth plane size overflows") }
        return result
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func readInt32LE(_ data: Data, at offset: Int) -> Int32? {
        readUInt32LE(data, at: offset).map { Int32(bitPattern: $0) }
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readFloat32LE(_ data: Data, at offset: Int) -> Float? {
        readUInt32LE(data, at: offset).map(Float.init(bitPattern:))
    }

    private enum DiagnosticError: LocalizedError {
        case invalidDepth(String)
        case zstdUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidDepth(let message): return message
            case .zstdUnavailable: return "portrait diagnostic requires a zstd executable"
            }
        }
    }
}
