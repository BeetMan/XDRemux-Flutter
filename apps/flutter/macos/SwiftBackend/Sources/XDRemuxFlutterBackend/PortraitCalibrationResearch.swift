import Foundation
import XDRemuxAppleFeatures
import XDRemuxCore

/// Explicitly gated, macOS-only Portrait calibration runner.
///
/// This is a research tool, not a conversion backend capability. It patches
/// only a scratch copy of `rear.depth`, calls the pinned upstream Swift
/// Library directly, and writes separate outputs for Photos verification.
/// The normal `convert` path and `swiftPortrait` capability never use this
/// type.
public enum PortraitCalibrationResearch {
    public static let schema = "xdremux-portrait-calibration-research-v1"
    public static let defaultVariantSpecs = ["p20", "p50", "p80", "uniform:0.005"]

    private struct Variant {
        let name: String
        let source: String
        let scale: Double
    }

    public static func run(
        inputs: [URL],
        outputDirectory: URL,
        variantSpecs: [String] = defaultVariantSpecs
    ) throws -> [String: Any] {
        try runInternal(
            inputs: inputs,
            outputDirectory: outputDirectory,
            variantSpecs: variantSpecs,
            requireExplicitGate: true
        )
    }

    /// Embedded macOS app entry point. The Flutter page is still marked
    /// experimental, but does not depend on a shell environment variable.
    public static func runEmbedded(
        inputs: [URL],
        outputDirectory: URL,
        variantSpecs: [String] = defaultVariantSpecs
    ) throws -> [String: Any] {
        try runInternal(
            inputs: inputs,
            outputDirectory: outputDirectory,
            variantSpecs: variantSpecs,
            requireExplicitGate: false
        )
    }

    private static func runInternal(
        inputs: [URL],
        outputDirectory: URL,
        variantSpecs: [String],
        requireExplicitGate: Bool
    ) throws -> [String: Any] {
        if requireExplicitGate,
           ProcessInfo.processInfo.environment["XDREMUX_ENABLE_PORTRAIT_RESEARCH"] != "1" {
            throw ResearchError.gateClosed
        }
        guard !inputs.isEmpty else {
            throw ResearchError.invalidArgument("at least one input is required")
        }
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        var samples: [[String: Any]] = []
        for inputURL in inputs {
            do {
                samples.append(
                    try runOne(
                        inputURL: inputURL.standardizedFileURL,
                        outputDirectory: outputDirectory,
                        variantSpecs: variantSpecs
                    )
                )
            } catch {
                samples.append([
                    "input": inputURL.path,
                    "success": false,
                    "error": String(describing: error),
                ])
            }
        }

        let manifest: [String: Any] = [
            "schema": schema,
            "researchOnly": true,
            "safeToTransform": false,
            "warning": "Outputs are calibration candidates only; do not treat them as stable Apple Portrait support.",
            "variantSpecs": variantSpecs,
            "samples": samples,
        ]
        let manifestURL = outputDirectory.appendingPathComponent("manifest.json")
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        try manifestData.write(to: manifestURL, options: [.atomic])
        return manifest
    }

    private static func runOne(
        inputURL: URL,
        outputDirectory: URL,
        variantSpecs: [String]
    ) throws -> [String: Any] {
        let diagnostic = XDRemuxSwiftBackend.diagnosePortrait(inputURL.path)
        guard diagnostic["available"] as? Bool == true else {
            throw ResearchError.invalidInput(
                diagnostic["error"] as? String ?? "Portrait diagnostic is unavailable"
            )
        }
        guard diagnostic["safeToTransform"] as? Bool == false else {
            throw ResearchError.invalidInput(
                "research runner only accepts the zero-quantization variant"
            )
        }
        guard let header = diagnostic["header"] as? [String: Any],
              let width = header["width"] as? Int,
              let height = header["height"] as? Int,
              let planes = diagnostic["planes"] as? [String: Any],
              let rank = planes["rank"] as? [String: Any],
              let rankMaximum = rank["max"] as? Int,
              rankMaximum > 0,
              rankMaximum <= Int(UInt16.max),
              let candidates = diagnostic["calibration"] as? [String: Any],
              let candidateMap = candidates["configDistanceScaleCandidates"] as? [String: Any] else {
            throw ResearchError.invalidInput(
                "diagnostic does not contain config-distance scale candidates"
            )
        }
        let variants = try resolveVariants(
            specs: variantSpecs,
            candidates: candidateMap
        )
        guard !variants.isEmpty else {
            throw ResearchError.invalidArgument("no valid research variants were requested")
        }
        guard let rearDepth = try AppleWatermarkTailBridge.tailPayload(
            named: "rear.depth",
            sourceURL: inputURL
        ) else {
            throw ResearchError.invalidInput("rear.depth is missing")
        }
        guard let zstdPath = PortraitDepthDiagnostics.zstdExecutablePath else {
            throw ResearchError.invalidInput("zstd executable is unavailable")
        }
        let decodedDepth = try runZstd(
            rearDepth,
            executableURL: URL(fileURLWithPath: zstdPath),
            decompress: true
        )

        var outputs: [[String: Any]] = []
        for variant in variants {
            let outputURL = outputURL(
                inputURL: inputURL,
                outputDirectory: outputDirectory,
                variantName: variant.name
            )
            try? FileManager.default.removeItem(at: outputURL)

            do {
                let patchedDepth = try patchedDepth(
                    decodedDepth,
                    width: width,
                    height: height,
                    rankMaximum: rankMaximum,
                    scale: variant.scale
                )
                let patchedCompressedDepth = try runZstd(
                    patchedDepth,
                    executableURL: URL(fileURLWithPath: zstdPath),
                    decompress: false
                )
                guard let scratchURL = try AppleWatermarkTailBridge.makeResearchInput(
                    sourceURL: inputURL,
                    replacing: ["rear.depth": patchedCompressedDepth],
                    label: "portrait-research-\(variant.name)"
                ) else {
                    throw ResearchError.invalidInput("could not create scratch input")
                }
                defer { try? FileManager.default.removeItem(at: scratchURL) }

                let configuration = ConversionConfiguration(
                    family: .auto,
                    oppoCompatibility: .off,
                    inputProcessingBranch: .hybrid,
                    oppoCameraTail: .off,
                    tmapFormat: .imageIO,
                    applePhotographicStyles: false,
                    applePortrait: true,
                    eventHandler: { _ in }
                )
                let request = ConversionRequest(
                    input: InputSource(url: scratchURL),
                    output: OutputDestination(url: outputURL),
                    configuration: configuration
                )
                _ = try AppleFeatureConversionEngine.convert(request)
                let valid = AppleFeatureConversionEngine.isValidOutput(
                    outputURL,
                    options: AppleFeatureOptions(
                        photographicStyles: false,
                        portrait: true
                    )
                )
                outputs.append([
                    "variant": variant.name,
                    "source": variant.source,
                    "scale": variant.scale,
                    "quantization": [
                        "minimum": 0,
                        "maximum": rankMaximum,
                        "exponentiation": 1,
                    ],
                    "output": outputURL.path,
                    "bytes": (try? FileManager.default.attributesOfItem(
                        atPath: outputURL.path
                    )[.size] as? Int) ?? 0,
                    "valid": valid,
                    "success": valid,
                ])
            } catch {
                outputs.append([
                    "variant": variant.name,
                    "source": variant.source,
                    "scale": variant.scale,
                    "output": outputURL.path,
                    "success": false,
                    "error": String(describing: error),
                ])
            }
        }

        return [
            "input": inputURL.path,
            "sourceDimensions": ["width": width, "height": height],
            "rankMaximum": rankMaximum,
            "diagnostic": diagnostic,
            "outputs": outputs,
            "success": outputs.contains { $0["success"] as? Bool == true },
        ]
    }

    private static func resolveVariants(
        specs: [String],
        candidates: [String: Any]
    ) throws -> [Variant] {
        try specs.map { spec in
            switch spec {
            case "p20", "p50", "p80":
                let key = "scaleFor\(spec.uppercased())"
                guard let scale = candidates[key] as? Double, scale.isFinite, scale > 0 else {
                    throw ResearchError.invalidArgument("missing diagnostic candidate \(spec)")
                }
                return Variant(name: spec, source: spec, scale: scale)
            default:
                let prefix = "uniform:"
                guard spec.hasPrefix(prefix),
                      let scale = Double(spec.dropFirst(prefix.count)),
                      scale.isFinite,
                      scale > 0 else {
                    throw ResearchError.invalidArgument(
                        "unsupported variant \(spec); use p20, p50, p80, or uniform:<scale>"
                    )
                }
                let name = "uniform-" + spec.dropFirst(prefix.count)
                    .replacingOccurrences(of: ".", with: "p")
                return Variant(name: name, source: spec, scale: scale)
            }
        }
    }

    private static func patchedDepth(
        _ data: Data,
        width: Int,
        height: Int,
        rankMaximum: Int,
        scale: Double
    ) throws -> Data {
        let headerSize = 768
        guard data.count >= headerSize + width * height,
              scale <= Double(Float.greatestFiniteMagnitude) else {
            throw ResearchError.invalidInput("rear.depth payload is truncated")
        }
        var patched = data
        writeFloat32LE(Float(scale), at: 0x18, in: &patched)
        writeUInt16LE(0, at: 0x2e, in: &patched)
        writeUInt16LE(UInt16(rankMaximum), at: 0x30, in: &patched)
        patched[0x32] = 1
        return patched
    }

    private static func runZstd(
        _ data: Data,
        executableURL: URL,
        decompress: Bool
    ) throws -> Data {
        let suffix = decompress ? "zst" : "raw"
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xdremux-portrait-research-\(UUID().uuidString).\(suffix)")
        defer { try? FileManager.default.removeItem(at: inputURL) }
        try data.write(to: inputURL, options: [.atomic])

        let process = Process()
        process.executableURL = executableURL
        process.arguments = decompress
            ? ["-d", "-q", "-c", inputURL.path]
            : ["-q", "-c", inputURL.path]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "zstd failed"
            throw ResearchError.invalidInput(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    private static func outputURL(
        inputURL: URL,
        outputDirectory: URL,
        variantName: String
    ) -> URL {
        outputDirectory.appendingPathComponent(
            "\(inputURL.deletingPathExtension().lastPathComponent).portrait-research-\(variantName).heic"
        )
    }

    private static func writeUInt16LE(_ value: UInt16, at offset: Int, in data: inout Data) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
    }

    private static func writeFloat32LE(_ value: Float, at offset: Int, in data: inout Data) {
        writeUInt32LE(value.bitPattern, at: offset, in: &data)
    }

    private static func writeUInt32LE(_ value: UInt32, at offset: Int, in data: inout Data) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
        data[offset + 2] = UInt8((value >> 16) & 0xff)
        data[offset + 3] = UInt8((value >> 24) & 0xff)
    }
}

private enum ResearchError: LocalizedError {
    case gateClosed
    case invalidArgument(String)
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .gateClosed:
            return "set XDREMUX_ENABLE_PORTRAIT_RESEARCH=1 to run the isolated research converter"
        case let .invalidArgument(message), let .invalidInput(message):
            return message
        }
    }
}
