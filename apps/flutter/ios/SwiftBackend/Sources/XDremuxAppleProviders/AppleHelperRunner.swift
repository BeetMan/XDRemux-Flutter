import Foundation

#if canImport(UIKit)
import XDremuxAppleFeatures
import XDRemuxCore

/// Dispatches the pipeline's helper invocations to in-process
/// implementations on iOS.
///
/// On macOS, `AppleNativeToolchain` compiles helper executables at runtime
/// and runs them as child processes. iOS cannot spawn processes, so
/// `AppleNativeToolStrategy`'s iOS branch routes every `run()` to the hook
/// installed here. Each implementation receives the exact `argv` the macOS
/// helper would have received (sans argv[0]) and answers with the helper's
/// stdout / stderr / exit status, so the pipeline call sites and their
/// file-based interfaces (JSON manifests, .l8 mask dumps, HEVC annex-B
/// files, ...) stay byte-for-byte compatible across platforms.
///
/// Helpers without an installed implementation report status 127
/// ("helper not available in-process") - mirroring a missing executable on
/// macOS - so capability probes fail closed.
public enum AppleHelperRunner {

    package typealias Helper = (_ arguments: [String]) throws -> AppleNativeToolchain.Result

    static var helpers: [String: Helper] = [:]

    /// Registers every in-process implementation compiled into this
    /// module. Idempotent. Call once at app startup (before any Apple
    /// feature pipeline runs).
    public static func install() {
        AppleNativeToolchain.inProcessRunner = { helper, arguments, timeout in
            guard let implementation = helpers[helper] else {
                return AppleNativeToolchain.Result(
                    status: 127,
                    stdout: Data(),
                    stderr: Data(
                        "iOS in-process helper \(helper) is not available".utf8),
                    timedOut: false)
            }
            return try implementation(arguments)
        }
        helpers["apple-vision-semantic-mattes"] = AppleVisionSemanticMattes.run
        helpers["apple-semantic-style-properties-probe"] =
            AppleSemanticStylePropertiesValidator.run
        helpers["apple-vt-hevc-encoder"] = AppleVTHevcEncoderInProcess.run

        // The gain-map encoder hook in XDremuxCore takes the in-memory
        // raster bridge instead of file paths. Adapt it to the file-based
        // VT provider so both call chains converge on one implementation.
        DirectTiledHEVCGainMapEncoder.inProcessEncoder = { imageData, _, _, channelCount, tileSize, quality in
            try Self.encodeGainMapViaVT(
                imageData: imageData,
                channelCount: channelCount,
                tileSize: tileSize,
                quality: quality)
        }
    }

    /// Mirrors the macOS helper invocation in
    /// `DirectTiledHEVCGainMapEncoder.encode(imageData:...)`: write the PNG
    /// (1ch) / JPEG (3ch) bridge image to a scratch file, run the VT tile
    /// encoder with the same argument vector, read back annex-B + hvcC.
    private static func encodeGainMapViaVT(
        imageData: Data,
        channelCount: Int,
        tileSize: Int,
        quality: Double
    ) throws -> (annexB: Data, hvcC: Data) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xdremux-gainmap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent(
            "input.\(channelCount == 1 ? "png" : "jpg")")
        let annexBURL = directory.appendingPathComponent("output.hevc")
        let hvccURL = directory.appendingPathComponent("output.hvcc")
        try imageData.write(to: imageURL, options: .atomic)
        let mode = channelCount == 1 ? "mono8tile" : "rgb4448tile"
        let result = AppleVTHevcEncoderInProcess.run(arguments: [
            imageURL.path,
            annexBURL.path,
            String(format: "%.6f", quality),
            mode,
            hvccURL.path,
            String(tileSize),
        ])
        guard result.status == 0 else {
            let diagnostic = String(data: result.stderr + result.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw RunnerError.helperFailed("apple-vt-hevc-encoder: \(diagnostic)")
        }
        return (
            try Data(contentsOf: annexBURL),
            try Data(contentsOf: hvccURL)
        )
    }

    private enum RunnerError: Error {
        case helperFailed(String)
    }

    /// Test hook: forget everything install() registered.
    static func reset() {
        helpers = [:]
        AppleNativeToolchain.inProcessRunner = nil
    }
}
#endif
