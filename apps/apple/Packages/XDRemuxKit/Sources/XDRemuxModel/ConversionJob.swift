import Foundation

/// What the model needs from the Rust core. `XDRemuxKit.XDRemuxEngine`
/// conforms; tests inject fakes.
public protocol ConversionBackend: Sendable {
    /// Writes `output` from `input`. Returns the core's report; a thrown error
    /// means the call itself could not be made.
    func convert(input: String, output: String, config: RustConvertConfig,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> ConversionOutcome
    /// Decodes and structure-checks a produced file. `styles` / `portrait`
    /// add the Apple Photographic Styles / Portrait structure checks, as the
    /// Flutter backend does (`conversion_backend.dart`).
    func verifyOutput(path: String, styles: Bool, portrait: Bool) async throws -> Bool
}

extension ConversionBackend {
    public func verifyOutput(path: String) async throws -> Bool {
        try await verifyOutput(path: path, styles: false, portrait: false)
    }
}

/// The core's one-call pipeline (`xdremux_convert_pipeline`): convert,
/// verify with the option-aware checks, and the Styles 3 post-process in
/// Rust, so every front-end runs the same policy. When a backend conforms,
/// `ConversionJob` prefers it over the convert / verify / inject trio.
public protocol PipelineBackend: Sendable {
    func runPipeline(input: String, output: String, config: ConversionConfig,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> PipelineOutcome
}

/// Backend-neutral copy of the pipeline report.
public struct PipelineOutcome: Equatable, Sendable {
    public var success: Bool
    /// "convert" | "verify" | "styles3" | "done" | "config".
    public var stage: String
    public var cancelled: Bool
    public var errorMessage: String?
    public var outcome: ConversionOutcome
    public var outputValid: Bool?
    public var styles3Applied: Bool

    public init(success: Bool, stage: String, cancelled: Bool = false, errorMessage: String? = nil,
                outcome: ConversionOutcome, outputValid: Bool? = nil, styles3Applied: Bool = false) {
        self.success = success
        self.stage = stage
        self.cancelled = cancelled
        self.errorMessage = errorMessage
        self.outcome = outcome
        self.outputValid = outputValid
        self.styles3Applied = styles3Applied
    }
}

/// Photographic Styles 3 post-processing (`xdremux_inject_texture_styles` +
/// `xdremux_inject_semantic_mattes`); optional on a backend.
public protocol Styles3Backend: Sendable {
    /// Rewrites `path` in place. Throws when either injection fails.
    func injectStyles3(path: String, grainSeed: UInt64) async throws
}

/// Motion Photo support the model needs from the core; optional on a backend.
public protocol MotionPhotoBackend: Sendable {
    /// `nil` when the file is not a Motion Photo.
    func motionPhotoInfo(path: String) async throws -> MotionPhotoInfo?
    /// Writes `<stem>.heic` + `<stem>.mov` into `outputDirectory` from the
    /// original Motion Photo (`source`) and the converted still (`still`).
    func makeLivePhoto(source: String, still: String, outputDirectory: String) async throws -> LivePhotoFiles
    func livePhotoPairIsValid(still: String, video: String) async throws -> Bool
    /// Splits the Motion Photo's embedded video(s) into `outputDirectory`.
    func splitMotionPhotoVideos(path: String, outputDirectory: String) async throws -> [String]
}

/// Backend-neutral summary of `xdremux_motion_photo_inspect`.
public struct MotionPhotoInfo: Codable, Equatable, Sendable {
    public var sourceKind: String
    public var isDualStream: Bool
    public var durationMs: Int?
    public var videoWidth: Int?
    public var videoHeight: Int?
    public var hasAudio: Bool?

    public init(sourceKind: String, isDualStream: Bool = false, durationMs: Int? = nil,
                videoWidth: Int? = nil, videoHeight: Int? = nil, hasAudio: Bool? = nil) {
        self.sourceKind = sourceKind
        self.isDualStream = isDualStream
        self.durationMs = durationMs
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.hasAudio = hasAudio
    }

    public var durationText: String? {
        durationMs.map { String(format: "%.1f s", Double($0) / 1000) }
    }
}

public struct LivePhotoFiles: Equatable, Sendable {
    public var stillPath: String
    public var videoPath: String
    public var contentIdentifier: String?

    public init(stillPath: String, videoPath: String, contentIdentifier: String? = nil) {
        self.stillPath = stillPath
        self.videoPath = videoPath
        self.contentIdentifier = contentIdentifier
    }
}

/// Backend-neutral copy of the core's conversion report.
public struct ConversionOutcome: Codable, Equatable, Sendable {
    public var success: Bool
    public var mode: String?
    public var family: String?
    public var edrScale: Double
    public var gainMapMax: Double
    public var errorMessage: String?

    public init(success: Bool, mode: String? = nil, family: String? = nil,
                edrScale: Double = 0, gainMapMax: Double = 0, errorMessage: String? = nil) {
        self.success = success
        self.mode = mode
        self.family = family
        self.edrScale = edrScale
        self.gainMapMax = gainMapMax
        self.errorMessage = errorMessage
    }
}

/// Minimal file-system surface so the job is testable without touching disk.
public protocol ConversionFileSystem: Sendable {
    func fileExists(_ url: URL) -> Bool
    func createDirectory(_ url: URL) throws
    func moveItem(from: URL, to: URL) throws
    func removeItem(_ url: URL) throws
}

public struct DefaultConversionFileSystem: ConversionFileSystem {
    public init() {}
    public func fileExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    public func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    public func moveItem(from: URL, to: URL) throws { try FileManager.default.moveItem(at: from, to: to) }
    public func removeItem(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
}

public enum ConversionJobError: Error, Equatable, Sendable {
    /// Rust reported failure (`errorMessage` when available).
    case coreFailed(String?)
    /// Live Photo composition failed or the pair did not validate.
    case livePhotoFailed(String?)
    /// Rust reported success but `verifyOutput` rejected the file.
    case verificationFailed
    /// Photographic Styles 3 post-processing failed; nothing was published.
    case styles3Failed(String?)
    /// Rust reported success but wrote nothing at the temporary path.
    case missingOutput
    /// Input and output would be the same file.
    case samePath
}

/// A published, verified conversion. `pairedVideoURL` is the Live Photo MOV
/// next to `outputURL` when the source was a Motion Photo converted in
/// `.livePhotoPair` mode; `extraVideoURLs` are exported clips in
/// `.stillAndVideo` mode.
public struct ConversionProduct: Codable, Equatable, Sendable {
    public let inputURL: URL
    public let outputURL: URL
    public let outcome: ConversionOutcome
    public let config: ConversionConfig
    public var pairedVideoURL: URL?
    public var extraVideoURLs: [URL]

    public init(inputURL: URL, outputURL: URL, outcome: ConversionOutcome, config: ConversionConfig,
                pairedVideoURL: URL? = nil, extraVideoURLs: [URL] = []) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.outcome = outcome
        self.config = config
        self.pairedVideoURL = pairedVideoURL
        self.extraVideoURLs = extraVideoURLs
    }

    public var isLivePhoto: Bool { pairedVideoURL != nil }

    /// Every file the user should receive together.
    public var allFiles: [URL] { [outputURL] + (pairedVideoURL.map { [$0] } ?? []) + extraVideoURLs }
}

/// One input → one verified output. The output is written to a task-private
/// temporary path, verified, then moved to its published location; failure
/// leaves no file behind and never touches the input (plan §3 P1).
public struct ConversionJob: Sendable {
    public var backend: ConversionBackend
    public var fileSystem: ConversionFileSystem
    public var scratchRoot: URL
    public var outputRoot: URL

    public init(backend: ConversionBackend, scratchRoot: URL, outputRoot: URL,
                fileSystem: ConversionFileSystem = DefaultConversionFileSystem()) {
        self.backend = backend
        self.fileSystem = fileSystem
        self.scratchRoot = scratchRoot
        self.outputRoot = outputRoot
    }

    /// `sourceName` is the user-facing file name when `input` is a sandbox
    /// copy with a generated prefix; it decides the published file name.
    /// `motionMode` applies only when `input` is a Motion Photo and the
    /// backend also conforms to `MotionPhotoBackend`; `.livePhotoPair`
    /// replaces the still with the Live-Photo-tagged one and adds a MOV,
    /// `.stillAndVideo` exports the clip(s) next to the still.
    public func run(input: URL, sourceName: String? = nil, config: ConversionConfig,
                    motionMode: MotionPhotoMode? = nil,
                    progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ConversionProduct {
        let name = sourceName ?? input.lastPathComponent
        let temp = OutputPlanner.temporaryURL(forInput: name, config: config, scratchRoot: scratchRoot)
        let scratchDir = temp.deletingLastPathComponent()
        var published = OutputPlanner.publishedURL(forInput: name, config: config, outputRoot: outputRoot)
        if published.standardizedFileURL == input.standardizedFileURL { throw ConversionJobError.samePath }

        try fileSystem.createDirectory(scratchDir)
        defer { try? fileSystem.removeItem(scratchDir) }

        let outcome: ConversionOutcome
        if let pipeline = backend as? PipelineBackend {
            // One core call does convert + verify + Styles 3 (pipeline.rs).
            let result = try await pipeline.runPipeline(input: input.path, output: temp.path,
                                                        config: config, progress: progress)
            // A cancelled conversion leaves a partial file in scratch; the
            // defer above removes it and nothing reaches the output folder.
            if result.cancelled { throw CancellationError() }
            try Task.checkCancellation()
            guard result.success else {
                switch result.stage {
                case "verify": throw ConversionJobError.verificationFailed
                case "styles3": throw ConversionJobError.styles3Failed(result.errorMessage)
                default: throw ConversionJobError.coreFailed(result.errorMessage)
                }
            }
            guard fileSystem.fileExists(temp) else { throw ConversionJobError.missingOutput }
            outcome = result.outcome
        } else {
            let rust = config.rustConfig
            outcome = try await backend.convert(input: input.path, output: temp.path,
                                                config: rust, progress: progress)
            try Task.checkCancellation()
            guard outcome.success else { throw ConversionJobError.coreFailed(outcome.errorMessage) }
            guard fileSystem.fileExists(temp) else { throw ConversionJobError.missingOutput }
            guard try await backend.verifyOutput(path: temp.path, styles: rust.applePhotographicStyles != 0,
                                                 portrait: rust.applePortrait != 0) else {
                throw ConversionJobError.verificationFailed
            }
            // Photographic Styles 3: add the texture/grain item and the 12
            // semantic part-matte placeholders so Photos offers texture editing.
            if rust.applePhotographicStyles != 0, config.applePhotographicStyles3,
               let styles = backend as? Styles3Backend {
                do {
                    try await styles.injectStyles3(path: temp.path, grainSeed: Self.grainSeed(for: name))
                } catch {
                    throw ConversionJobError.styles3Failed(String(describing: error))
                }
                try Task.checkCancellation()
            }
        }

        // Motion Photo handling on the verified still, still inside scratch.
        var still = temp
        var pairedVideo: URL?
        var extraVideos: [URL] = []
        if let motion = backend as? MotionPhotoBackend, let mode = motionMode,
           try await motion.motionPhotoInfo(path: input.path) != nil {
            switch mode {
            case .still:
                break
            case .livePhotoPair:
                let liveDir = scratchDir.appendingPathComponent("live", isDirectory: true)
                let files = try await motion.makeLivePhoto(source: input.path, still: temp.path, outputDirectory: liveDir.path)
                let liveStill = URL(fileURLWithPath: files.stillPath)
                let liveMov = URL(fileURLWithPath: files.videoPath)
                guard fileSystem.fileExists(liveStill), fileSystem.fileExists(liveMov),
                      try await motion.livePhotoPairIsValid(still: liveStill.path, video: liveMov.path) else {
                    throw ConversionJobError.livePhotoFailed("Live Photo pair is missing or invalid")
                }
                still = liveStill
                pairedVideo = liveMov
            case .stillAndVideo:
                let splitDir = scratchDir.appendingPathComponent("split", isDirectory: true)
                extraVideos = try await motion.splitMotionPhotoVideos(path: input.path, outputDirectory: splitDir.path)
                    .map(URL.init(fileURLWithPath:))
                    .filter(fileSystem.fileExists)
            }
        }

        try fileSystem.createDirectory(published.deletingLastPathComponent())
        if !config.skipExisting {
            published = OutputPlanner.uniqueURL(published, exists: fileSystem.fileExists)
        } else if fileSystem.fileExists(published) {
            try fileSystem.removeItem(published)
        }
        try fileSystem.moveItem(from: still, to: published)

        var publishedVideo: URL?
        if let pairedVideo {
            let target = published.deletingPathExtension().appendingPathExtension("mov")
            if fileSystem.fileExists(target) { try fileSystem.removeItem(target) }
            try fileSystem.moveItem(from: pairedVideo, to: target)
            publishedVideo = target
        }
        var publishedExtras: [URL] = []
        for clip in extraVideos {
            // "<stem>.video.mp4" → "<published stem>.motion.mp4", "<stem>.primary.mp4" → "<published stem>.primary.mp4"
            let kind = clip.lastPathComponent.contains(".primary.") ? "primary" : "motion"
            var target = published.deletingPathExtension().appendingPathExtension("\(kind).mp4")
            target = OutputPlanner.uniqueURL(target, exists: fileSystem.fileExists)
            try fileSystem.moveItem(from: clip, to: target)
            publishedExtras.append(target)
        }
        progress(1)
        return ConversionProduct(inputURL: input, outputURL: published, outcome: outcome, config: config,
                                 pairedVideoURL: publishedVideo, extraVideoURLs: publishedExtras)
    }

    /// Same hash as the Flutter backend (`_grainSeedFor`): Java-style string
    /// hash over UTF-16 code units, masked to 31 bits, so the same file name
    /// yields the same grain pattern on every platform.
    public static func grainSeed(for name: String) -> UInt64 {
        var h: UInt64 = 0
        for unit in name.utf16 { h = (h &* 31 &+ UInt64(unit)) & 0x7fff_ffff }
        return h
    }
}
