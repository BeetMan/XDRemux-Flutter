import Foundation
import XDRemuxCoreC
import XDRemuxModel

/// Swift façade over the Rust C ABI.
///
/// All Rust calls are synchronous and CPU-bound (x265 spins its own thread
/// pool), so they run on a private queue, never on the main actor. P0 keeps
/// the queue serial, mirroring the HarmonyOS bridge's single core mutex; a
/// configurable concurrency level is a P2 item (docs/plans/apple-native.md).
public final class XDRemuxEngine: Sendable {
    public static let shared = XDRemuxEngine()

    private let queue = DispatchQueue(label: "io.github.beetman.xdremux.core", qos: .userInitiated)

    public init() {}

    // MARK: - Synchronous, cheap

    /// Core version from `Cargo.toml` (the single version source).
    public static func coreVersion() -> String {
        RustString(taking: xdremux_version()).consume() ?? "unknown"
    }

    // MARK: - Background calls

    private func run<T: Sendable>(_ body: @Sendable @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    /// `xdremux_codec_capabilities`: which encoder paths this build carries.
    public func codecCapabilities() async throws -> JSONReport {
        try await run { try JSONReport(consuming: RustString(taking: xdremux_codec_capabilities())) }
    }

    /// `xdremux_classify`: capture-mode classification. Never throws for an
    /// unreadable file; inspect `status` instead.
    public func classify(path: String) async throws -> Classification {
        try await run { withCPath(path) { Classification(consuming: xdremux_classify($0)) } }
    }

    /// `xdremux_inspect`: ProXDR structure check without writing output.
    public func inspect(path: String) async throws -> ConversionReport {
        try await run { withCPath(path) { ConversionReport(consuming: xdremux_inspect($0)) } }
    }

    /// `xdremux_inspect_photo_details`: EXIF / HDR / Apple editing metadata
    /// summary as JSON (`success`, `errorMessage`, `make`, `model`, …).
    public func photoDetails(path: String) async throws -> JSONReport {
        try await run {
            try withCPath(path) { try JSONReport(consuming: RustString(taking: xdremux_inspect_photo_details($0))) }
        }
    }

    /// `xdremux_convert_with_progress`. `progress`, when given, is polled on
    /// the caller's task every `pollInterval` until the call returns.
    ///
    /// The output path must differ from the input; Rust refuses in-place
    /// writes. Callers should pass a task-private temporary path and publish
    /// only after `xdremux_verify_output` succeeds (plan §3 P1).
    public func convert(
        input: String,
        output: String,
        config: RustConvertConfig,
        pollInterval: Duration = .milliseconds(100),
        progress: (@Sendable (ConversionProgress) -> Void)? = nil
    ) async throws -> ConversionReport {
        let handle = xdremux_progress_begin()
        defer { xdremux_progress_end(handle) }

        let poller: Task<Void, Never>? = progress.map { report in
            Task.detached {
                while !Task.isCancelled {
                    report(Self.readProgress(handle))
                    try? await Task.sleep(for: pollInterval)
                }
            }
        }
        defer { poller?.cancel() }

        return try await run {
            var c = ConvertConfig(
                oppo_compat: config.oppoCompat,
                oppo_camera_tail: config.oppoCameraTail,
                strict_tmap: config.strictTmap,
                apple_photographic_styles: config.applePhotographicStyles,
                apple_portrait: config.applePortrait)
            return withCPath(input) { cin in
                withCPath(output) { cout in
                    ConversionReport(consuming: xdremux_convert_with_progress(cin, cout, &c, handle))
                }
            }
        }
    }

    /// `xdremux_verify_output`: decodes and structure-checks a produced file.
    public func verifyOutput(path: String) async throws -> Bool {
        try await run { withCPath(path) { xdremux_verify_output($0) } }
    }

    // MARK: - Progress

    static func readProgress(_ handle: UInt32) -> ConversionProgress {
        var buf = [UInt32](repeating: 0, count: 4)
        xdremux_read_progress_for(handle, &buf)
        return ConversionProgress(stage: buf[0], current: buf[1], total: buf[2])
    }
}
