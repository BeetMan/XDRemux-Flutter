import Foundation

/// "一帧影像，动用两台手机": the OPPO original is converted once into an
/// Apple Photographic Styles edit copy, edited on an iPhone, and the returned
/// file is written back by Rust with the donor's watermark and OPPO metadata.
/// Mirrors `apps/flutter/lib/services/apple_oppo_workflow_service.dart`.
public protocol WritebackBackend: Sendable {
    /// `xdremux_writeback_returned_photo`. `original` may be nil for Apple
    /// output without a donor.
    func writebackReturnedPhoto(original: String?, returned: String, output: String,
                                outputMode: OutputMode, restoreWatermark: Bool) async throws -> WritebackReport
}

/// Decoded writeback JSON report.
public struct WritebackReport: Codable, Equatable, Sendable {
    public var success: Bool
    public var errorMessage: String?
    public var outputValid: Bool?
    public var outputMode: String?
    public var rasterWatermarkRestored: Bool?
    public var requestedRasterWatermark: Bool?
    public var watermarkMetadataPreserved: Bool?
    public var exifGrafted: Bool?
    public var restoredOppoEntries: [String]?
    public var timingsMs: [String: Double]?

    public init(success: Bool, errorMessage: String? = nil, outputValid: Bool? = nil, outputMode: String? = nil,
                rasterWatermarkRestored: Bool? = nil, requestedRasterWatermark: Bool? = nil,
                watermarkMetadataPreserved: Bool? = nil, exifGrafted: Bool? = nil,
                restoredOppoEntries: [String]? = nil, timingsMs: [String: Double]? = nil) {
        self.success = success
        self.errorMessage = errorMessage
        self.outputValid = outputValid
        self.outputMode = outputMode
        self.rasterWatermarkRestored = rasterWatermarkRestored
        self.requestedRasterWatermark = requestedRasterWatermark
        self.watermarkMetadataPreserved = watermarkMetadataPreserved
        self.exifGrafted = exifGrafted
        self.restoredOppoEntries = restoredOppoEntries
        self.timingsMs = timingsMs
    }

    /// The Dart contract: `success != true || outputValid == false` is a failure.
    public var isUsable: Bool { success && outputValid != false }
}

public enum RoundTripError: Error, Equatable, Sendable {
    case donorRequired
    case writebackFailed(String?)
    case outputMissing
}

public enum RoundTrip {
    /// Step 2 output: `<stem>.apple-edit.heic` next to the other outputs.
    public static func editCopyConfig(base: ConversionConfig) -> ConversionConfig {
        var c = base
        c.outputMode = .apple
        c.applePhotographicStyles = true
        c.applePhotographicStyles3 = false
        c.applePortrait = false
        c.fileNameSuffix = ".apple-edit"
        c.categorizeOutputByMode = false
        c.skipExisting = true
        return c
    }

    /// Step 2: single-pass conversion of the OPPO original (also the later
    /// donor) into an Apple Styles edit copy. Never produces an intermediate
    /// OPPO-compatible file (that would duplicate the gain-map graph).
    public static func createEditCopy(donor: URL, sourceName: String? = nil, base: ConversionConfig,
                                      job: ConversionJob,
                                      progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ConversionProduct {
        try await job.run(input: donor, sourceName: sourceName, config: editCopyConfig(base: base),
                          motionMode: .still, progress: progress)
    }

    /// Step 4 output name: `<returned stem>.<mode>-final.heic`.
    public static func finalURL(returnedName: String, outputMode: OutputMode, outputRoot: URL) -> URL {
        let stem = (returnedName as NSString).deletingPathExtension
        return outputRoot.appendingPathComponent("\(stem).\(outputMode.rawValue)-final.heic")
    }

    /// Step 4: writeback. OPPO output needs the donor; Apple output restores
    /// the watermark only when a donor is present. The result is written to a
    /// scratch path first and published only when the report is usable.
    public static func writeback(donor: URL?, returned: URL, returnedName: String? = nil,
                                 outputMode: OutputMode, restoreWatermark: Bool,
                                 outputRoot: URL, scratchRoot: URL,
                                 backend: WritebackBackend,
                                 fileSystem: ConversionFileSystem = DefaultConversionFileSystem()) async throws -> (URL, WritebackReport) {
        if outputMode == .oppo && donor == nil { throw RoundTripError.donorRequired }
        if restoreWatermark && donor == nil { throw RoundTripError.donorRequired }
        let name = returnedName ?? returned.lastPathComponent
        let published = finalURL(returnedName: name, outputMode: outputMode, outputRoot: outputRoot)
        let scratchDir = scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let temp = scratchDir.appendingPathComponent(published.lastPathComponent)
        try fileSystem.createDirectory(scratchDir)
        defer { try? fileSystem.removeItem(scratchDir) }

        let report = try await backend.writebackReturnedPhoto(
            original: donor?.path, returned: returned.path, output: temp.path,
            outputMode: outputMode, restoreWatermark: restoreWatermark)
        guard report.isUsable else { throw RoundTripError.writebackFailed(report.errorMessage ?? (report.outputValid == false ? "输出校验失败" : nil)) }
        guard fileSystem.fileExists(temp) else { throw RoundTripError.outputMissing }
        try fileSystem.createDirectory(published.deletingLastPathComponent())
        if fileSystem.fileExists(published) { try fileSystem.removeItem(published) }
        try fileSystem.moveItem(from: temp, to: published)
        return (published, report)
    }
}
