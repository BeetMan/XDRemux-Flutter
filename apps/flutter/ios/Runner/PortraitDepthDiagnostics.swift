import Foundation
import ImageIO
import XDremuxAppleProviders

/// Read-only macOS diagnostics for OPPO rear Portrait depth variants.
///
/// This target is macOS-only and may use a locally installed zstd executable
/// for analysis. It is deliberately separate from the conversion path: a
/// report can identify a producer variant without making that variant eligible
/// for Apple Portrait output.
public enum PortraitDepthDiagnostics {
    public static let schema = "xdremux-portrait-depth-diagnostic-v1"

    /// iOS: no CLI zstd; the vendored embedded decoder is always present
    /// once the providers module is linked.
    public static var zstdExecutablePath: String? {
        "embedded-zstd-1.5.7"
    }

    public static var isAvailable: Bool {
        true
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
        let configData = try AppleWatermarkTailBridge.tailPayload(
            named: "rear.depth.config",
            sourceURL: inputURL
        )
        var sourceImageData: Data?
        for name in ["rear.depth.config", "src.image", "front.depth", "front.segment", "front.hair.mask"] {
            if let payload = try AppleWatermarkTailBridge.tailPayload(named: name, sourceURL: inputURL) {
                resourceLengths[name] = payload.count
                if name == "src.image" {
                    sourceImageData = payload
                }
            }
        }
        report["resources"] = resourceLengths

        guard let zstdURL = zstdURL() else {
            report["classification"] = "rear-depth-zstd-unavailable"
            report["zstd"] = ["available": false]
            return report
        }

        let decodedDepth = try decompressZstd(compressedDepth, executableURL: zstdURL)
        let sourceImageDimensions = sourceImageData.flatMap(imageDimensions)
        let parsed = try parseDepth(
            decodedDepth,
            configData: configData,
            sourceImageDimensions: sourceImageDimensions
        )
        report["available"] = true
        report["zstd"] = [
            "available": true,
            "executable": zstdURL.path,
        ]
        report["decodedBytes"] = decodedDepth.count
        report["sourceImage"] = sourceImageDimensions.map {
            ["width": $0.width, "height": $0.height]
        } ?? NSNull()
        report["config"] = parsed.config
        report["header"] = parsed.header
        report["planes"] = parsed.planes
        report["calibration"] = parsed.calibration
        report["classification"] = parsed.calibration["classification"] ?? "unknown"
        report["safeToTransform"] = parsed.calibration["safeToTransform"] ?? false
        return report
    }

    private struct ParsedDepth {
        let config: [String: Any]?
        let header: [String: Any]
        let planes: [String: Any]
        let calibration: [String: Any]
    }

    private struct PortraitConfigSummary {
        let version: Double
        let canvasWidth: Int
        let canvasHeight: Int
        let focusX: Int
        let focusY: Int
        let currentFNumber: Double?
        let objectDistance: Int?
        let focusROIType: Int?

        var dictionary: [String: Any] {
            [
                "version": version,
                "canvasWidth": canvasWidth,
                "canvasHeight": canvasHeight,
                "focusX": focusX,
                "focusY": focusY,
                "currentFNumber": currentFNumber.map { $0 as Any } ?? NSNull(),
                "objectDistance": objectDistance.map { $0 as Any } ?? NSNull(),
                "focusROIType": focusROIType.map { $0 as Any } ?? NSNull(),
            ]
        }
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

    private static func parseDepth(
        _ data: Data,
        configData: Data?,
        sourceImageDimensions: (width: Int, height: Int)?
    ) throws -> ParsedDepth {
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
        let config = parseConfig(configData)
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
        var calibration: [String: Any] = [
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
        if let config,
           let objectDistance = config.objectDistance,
           objectDistance > 0,
           focalLength > 0,
           stereoBaseline > 0,
           let candidates = estimateScaleCandidates(
               data: data,
               headerSize: headerSize,
               width: width,
               height: height,
               sourceImageDimensions: sourceImageDimensions,
               rankMaximum: rankStats.maximum,
               focalLength: Double(focalLength),
               stereoBaseline: Double(stereoBaseline),
               config: config,
               objectDistance: Double(objectDistance)
           ) {
            calibration["configDistanceScaleCandidates"] = candidates
            calibration["calibrationMethod"] =
                "match OPPO rear.depth.config objectDistance against a focus-window rank percentile"
            calibration["calibrationWarning"] =
                "Candidate scales are research evidence only; quantization and Apple disparity units remain unresolved."
        }
        return ParsedDepth(
            config: config?.dictionary,
            header: header,
            planes: planeReports,
            calibration: calibration
        )
    }

    private static func parseConfig(_ data: Data?) -> PortraitConfigSummary? {
        guard let data,
              let versionRaw = readFloat32LE(data, at: 0),
              versionRaw.isFinite,
              versionRaw >= 1,
              versionRaw <= 4,
              let canvasWidth = readInt32LE(data, at: 4),
              let canvasHeight = readInt32LE(data, at: 8),
              let focusX = readInt32LE(data, at: 12),
              let focusY = readInt32LE(data, at: 16) else {
            return nil
        }
        let currentFNumber = readFloat32LE(data, at: 292).flatMap { value in
            value.isFinite && (1...64).contains(value) ? Double(value) : nil
        }
        let objectDistance = readInt32LE(data, at: 296).flatMap { value in
            value > 0 ? Int(value) : nil
        }
        let focusROIType = readInt32LE(data, at: 404).map(Int.init)
        return PortraitConfigSummary(
            version: Double(versionRaw),
            canvasWidth: Int(canvasWidth),
            canvasHeight: Int(canvasHeight),
            focusX: Int(focusX),
            focusY: Int(focusY),
            currentFNumber: currentFNumber,
            objectDistance: objectDistance,
            focusROIType: focusROIType
        )
    }

    private static func estimateScaleCandidates(
        data: Data,
        headerSize: Int,
        width: Int,
        height: Int,
        sourceImageDimensions: (width: Int, height: Int)?,
        rankMaximum: Int,
        focalLength: Double,
        stereoBaseline: Double,
        config: PortraitConfigSummary,
        objectDistance: Double
    ) -> [String: Any]? {
        guard rankMaximum > 0,
              config.canvasWidth > 0,
              config.canvasHeight > 0,
              objectDistance > 0,
              let sourceImageDimensions,
              sourceImageDimensions.width > 0,
              sourceImageDimensions.height > 0,
              config.focusX >= 0,
              config.focusY >= 0,
              config.focusX < sourceImageDimensions.width,
              config.focusY < sourceImageDimensions.height else {
            return nil
        }
        let normalizedX = min(
            max(Double(config.focusX) / Double(sourceImageDimensions.width), 0),
            1
        )
        let normalizedY = min(
            max(Double(config.focusY) / Double(sourceImageDimensions.height), 0),
            1
        )
        let centerX = min(max(Int((normalizedX * Double(width)).rounded(.down)), 0), width - 1)
        let centerY = min(max(Int((normalizedY * Double(height)).rounded(.down)), 0), height - 1)
        let radiusX = max(4, width / 20)
        let radiusY = max(4, height / 20)
        let minX = max(0, centerX - radiusX)
        let maxX = min(width - 1, centerX + radiusX)
        let minY = max(0, centerY - radiusY)
        let maxY = min(height - 1, centerY + radiusY)
        var ranks: [Int] = []
        ranks.reserveCapacity((maxX - minX + 1) * (maxY - minY + 1))
        for y in minY...maxY {
            for x in minX...maxX {
                ranks.append(Int(data[headerSize + y * width + x]))
            }
        }
        guard !ranks.isEmpty else { return nil }
        ranks.sort()

        func percentile(_ fraction: Double) -> Double {
            let index = min(
                ranks.count - 1,
                max(0, Int((Double(ranks.count - 1) * fraction).rounded()))
            )
            return Double(ranks[index])
        }
        func scale(forRank rank: Double) -> Double {
            let normalized = min(max(rank / 255.0, 0), 1)
            let internalDisparity = 65_535.0 - normalized * Double(rankMaximum)
            return focalLength * stereoBaseline / (internalDisparity * objectDistance)
        }

        let p20 = percentile(0.20)
        let p50 = percentile(0.50)
        let p80 = percentile(0.80)
        return [
            "focusWindow": [
                "sourceImageWidth": sourceImageDimensions.width,
                "sourceImageHeight": sourceImageDimensions.height,
                "centerX": centerX,
                "centerY": centerY,
                "minX": minX,
                "maxX": maxX,
                "minY": minY,
                "maxY": maxY,
                "sampleCount": ranks.count,
            ],
            "objectDistance": objectDistance,
            "rankPercentiles": [
                "p20": p20,
                "p50": p50,
                "p80": p80,
            ],
            "scaleForP20": scale(forRank: p20),
            "scaleForP50": scale(forRank: p50),
            "scaleForP80": scale(forRank: p80),
            "fullSpanForP50": scale(forRank: p50) * 255.0,
        ]
    }

    private static func imageDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return (image.width, image.height)
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
        try EmbeddedZstdDecoder.decode(data)
    }

    private static func zstdURL() -> URL? {
        // iOS: no CLI zstd; the sentinel URL keeps the report schema
        // unchanged while decompressZstd ignores it and uses the embedded
        // decoder (EmbeddedZstdDecoder, vendored zstd 1.5.7).
        URL(fileURLWithPath: "/usr/libexec/xdremux/embedded-zstd-1.5.7")
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
