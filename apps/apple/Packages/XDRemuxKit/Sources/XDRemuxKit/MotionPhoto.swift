import Foundation
import XDRemuxCoreC
import XDRemuxModel

/// Decoded `xdremux_motion_photo_inspect` report (keys from
/// `xdremux/rust/src/motion_photo.rs`). Only the fields the app shows are
/// modelled; `raw` keeps the full report for diagnostics.
public struct MotionPhotoReport: Decodable, Equatable, Sendable {
    public var isMotionPhoto: Bool
    public var errorMessage: String?
    public var sourceKind: String?
    public var isDualStream: Bool?
    public var stillStart: Int?
    public var stillEnd: Int?
    public var videoStart: Int?
    public var videoEnd: Int?
    public var presentationTimestampUs: Int?
    public var videoWidth: Int?
    public var videoHeight: Int?
    public var durationMs: Int?
    public var fps: Double?
    public var frameCount: Int?
    public var videoCodec: String?
    public var hasAudio: Bool?
    public var audioCodec: String?

    public var videoBytes: Int? {
        guard let videoStart, let videoEnd else { return nil }
        return videoEnd - videoStart
    }

    var info: MotionPhotoInfo? {
        guard isMotionPhoto else { return nil }
        return MotionPhotoInfo(sourceKind: sourceKind ?? "motionPhoto", isDualStream: isDualStream ?? false,
                               durationMs: durationMs, videoWidth: videoWidth, videoHeight: videoHeight, hasAudio: hasAudio)
    }
}

struct LivePhotoReport: Decodable {
    var success: Bool
    var errorMessage: String?
    var stillPath: String?
    var videoPath: String?
    var contentIdentifier: String?
}

struct SplitReport: Decodable {
    var success: Bool
    var errorMessage: String?
    var stillPath: String?
    var videoPath: String?
    var primaryVideoPath: String?
}

extension XDRemuxEngine {
    /// `xdremux_motion_photo_inspect`.
    public func motionPhotoReport(path: String) async throws -> MotionPhotoReport {
        try await photoReport(path: path, xdremux_motion_photo_inspect).decode()
    }

    /// `xdremux_make_live_photo`: `<stem>.heic` + `<stem>.mov` into `outputDirectory`.
    public func makeLivePhotoFiles(source: String, still: String, outputDirectory: String) async throws -> LivePhotoFiles {
        let report: LivePhotoReport = try await withCPaths(source, still, outputDirectory) { s, t, o in
            try JSONReport(consuming: RustString(taking: xdremux_make_live_photo(s, t, o)))
        }.decode()
        guard report.success, let stillPath = report.stillPath, let videoPath = report.videoPath else {
            throw XDRemuxError.coreFailure(message: report.errorMessage)
        }
        return LivePhotoFiles(stillPath: stillPath, videoPath: videoPath, contentIdentifier: report.contentIdentifier)
    }

    /// `xdremux_live_photo_pair_valid`.
    public func livePhotoPairValid(still: String, video: String) async throws -> Bool {
        try await runOnQueue {
            withCPath(still) { s in withCPath(video) { v in xdremux_live_photo_pair_valid(s, v) != 0 } }
        }
    }

    /// `xdremux_motion_photo_split`: returns the exported video paths
    /// (`<stem>.video.mp4`, plus `<stem>.primary.mp4` for dual-stream sources).
    public func splitMotionPhoto(path: String, outputDirectory: String) async throws -> [String] {
        let report: SplitReport = try await withCPaths(path, outputDirectory, outputDirectory) { p, o, _ in
            try JSONReport(consuming: RustString(taking: xdremux_motion_photo_split(p, o)))
        }.decode()
        guard report.success else { throw XDRemuxError.coreFailure(message: report.errorMessage) }
        return [report.videoPath, report.primaryVideoPath].compactMap { $0 }
    }

    // MARK: helpers

    private func photoReport(path: String, _ fn: @escaping @Sendable (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?) async throws -> JSONReport {
        try await runOnQueue { try withCPath(path) { try JSONReport(consuming: RustString(taking: fn($0))) } }
    }

    private func withCPaths<R: Sendable>(_ a: String, _ b: String, _ c: String,
                                         _ body: @escaping @Sendable (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>) throws -> R) async throws -> R {
        try await runOnQueue {
            try withCPath(a) { pa in try withCPath(b) { pb in try withCPath(c) { pc in try body(pa, pb, pc) } } }
        }
    }
}

extension XDRemuxEngine: MotionPhotoBackend {
    public func motionPhotoInfo(path: String) async throws -> MotionPhotoInfo? {
        try await motionPhotoReport(path: path).info
    }

    public func makeLivePhoto(source: String, still: String, outputDirectory: String) async throws -> LivePhotoFiles {
        try await makeLivePhotoFiles(source: source, still: still, outputDirectory: outputDirectory)
    }

    public func livePhotoPairIsValid(still: String, video: String) async throws -> Bool {
        try await livePhotoPairValid(still: still, video: video)
    }

    public func splitMotionPhotoVideos(path: String, outputDirectory: String) async throws -> [String] {
        try await splitMotionPhoto(path: path, outputDirectory: outputDirectory)
    }
}
