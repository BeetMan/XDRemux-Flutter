import Foundation
import XDRemuxCoreC
import XDRemuxModel

/// `xdremux_convert_pipeline` report (keys from `xdremux/rust/src/pipeline.rs`).
public struct PipelineReport: Decodable, Equatable, Sendable {
    public var success: Bool
    public var stage: String?
    public var cancelled: Bool?
    public var errorMessage: String?
    public var mode: String?
    public var family: String?
    public var edrScale: Double?
    public var gainMapMax: Double?
    public var outputValid: Bool?
    public var verified: [String]?
    public var styles3Applied: Bool?
    public var grainSeed: UInt64?
}

/// `xdremux_plan_output` report.
public struct OutputPlan: Decodable, Equatable, Sendable {
    public struct ClassificationInfo: Decodable, Equatable, Sendable {
        public var modeKey: String?
        public var folderName: String?
        public var status: String?
        public var hdrKind: String?
        public var family: String?
    }
    /// Mirrors the Huawei inspection the policy was computed from.
    public struct HuaweiInfo: Decodable, Equatable, Sendable {
        public var isHdr: Bool
        public var hasXtstyle: Bool?
        public var portraitReady: Bool?
    }
    public struct Policy: Decodable, Equatable, Sendable {
        public var admitted: Bool
        public var reason: String?
    }
    public struct Output: Decodable, Equatable, Sendable {
        public var fileName: String
        public var captureModeFolder: String?
        public var outputModeFolder: String?
    }

    public var success: Bool
    public var errorMessage: String?
    public var inputName: String?
    public var convertible: Bool?
    public var convertError: String?
    public var classification: ClassificationInfo?
    public var huawei: HuaweiInfo?
    public var isMotionPhoto: Bool?
    public var policy: Policy?
    public var output: Output?
}

extension XDRemuxEngine {
    /// The front-end config as the JSON the core's pipeline reads (the
    /// Dart / Swift `ConversionConfig` keys).
    static func configJSON(_ config: ConversionConfig) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(config), as: UTF8.self)
    }

    /// `xdremux_convert_pipeline`: convert + verify (+ Styles 3) in one core
    /// call. Cancellation works like `convert(input:output:config:)`.
    public func convertPipeline(
        input: String,
        output: String,
        config: ConversionConfig,
        pollInterval: Duration = .milliseconds(100),
        progress: (@Sendable (ConversionProgress) -> Void)? = nil
    ) async throws -> PipelineReport {
        let json = try Self.configJSON(config)
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
        let report: PipelineReport = try await withTaskCancellationHandler {
            try await runOnQueue {
                try withCPath(input) { cin in
                    try withCPath(output) { cout in
                        try withCPath(json) { cfg in
                            try JSONReport(consuming: RustString(taking: xdremux_convert_pipeline(cin, cout, cfg, handle)))
                        }
                    }
                }
            }.decode()
        } onCancel: {
            xdremux_progress_cancel(handle)
        }
        if Task.isCancelled || report.cancelled == true { throw CancellationError() }
        return report
    }

    /// `xdremux_plan_output`: read-only plan for one input.
    public func planOutput(path: String, config: ConversionConfig) async throws -> OutputPlan {
        let json = try Self.configJSON(config)
        return try await runOnQueue {
            try withCPath(path) { p in
                try withCPath(json) { cfg in
                    try JSONReport(consuming: RustString(taking: xdremux_plan_output(p, cfg)))
                }
            }
        }.decode()
    }
}

extension XDRemuxEngine: PipelineBackend {
    public func runPipeline(input: String, output: String, config: ConversionConfig,
                            progress: @escaping @Sendable (Double) -> Void) async throws -> PipelineOutcome {
        let r = try await convertPipeline(input: input, output: output, config: config) { progress($0.fraction) }
        return PipelineOutcome(success: r.success, stage: r.stage ?? "", cancelled: r.cancelled ?? false,
                               errorMessage: r.errorMessage,
                               outcome: ConversionOutcome(success: r.success, mode: r.mode, family: r.family,
                                                          edrScale: r.edrScale ?? 0, gainMapMax: r.gainMapMax ?? 0,
                                                          errorMessage: r.errorMessage),
                               outputValid: r.outputValid, styles3Applied: r.styles3Applied ?? false)
    }
}
