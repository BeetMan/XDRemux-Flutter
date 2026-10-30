import Foundation

/// What the model needs from the Rust core. `XDRemuxKit.XDRemuxEngine`
/// conforms; tests inject fakes.
public protocol ConversionBackend: Sendable {
    /// Writes `output` from `input`. Returns the core's report; a thrown error
    /// means the call itself could not be made.
    func convert(input: String, output: String, config: RustConvertConfig,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> ConversionOutcome
    /// Decodes and structure-checks a produced file.
    func verifyOutput(path: String) async throws -> Bool
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
    /// Rust reported success but `verifyOutput` rejected the file.
    case verificationFailed
    /// Rust reported success but wrote nothing at the temporary path.
    case missingOutput
    /// Input and output would be the same file.
    case samePath
}

/// A published, verified conversion.
public struct ConversionProduct: Equatable, Sendable {
    public let inputURL: URL
    public let outputURL: URL
    public let outcome: ConversionOutcome
    public let config: ConversionConfig

    public init(inputURL: URL, outputURL: URL, outcome: ConversionOutcome, config: ConversionConfig) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.outcome = outcome
        self.config = config
    }
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
    public func run(input: URL, sourceName: String? = nil, config: ConversionConfig,
                    progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ConversionProduct {
        let name = sourceName ?? input.lastPathComponent
        let temp = OutputPlanner.temporaryURL(forInput: name, config: config, scratchRoot: scratchRoot)
        var published = OutputPlanner.publishedURL(forInput: name, config: config, outputRoot: outputRoot)
        if published.standardizedFileURL == input.standardizedFileURL { throw ConversionJobError.samePath }

        try fileSystem.createDirectory(temp.deletingLastPathComponent())
        defer { try? fileSystem.removeItem(temp.deletingLastPathComponent()) }

        let outcome = try await backend.convert(input: input.path, output: temp.path,
                                                config: config.rustConfig, progress: progress)
        guard outcome.success else { throw ConversionJobError.coreFailed(outcome.errorMessage) }
        guard fileSystem.fileExists(temp) else { throw ConversionJobError.missingOutput }
        guard try await backend.verifyOutput(path: temp.path) else { throw ConversionJobError.verificationFailed }

        try fileSystem.createDirectory(published.deletingLastPathComponent())
        if !config.skipExisting {
            published = OutputPlanner.uniqueURL(published, exists: fileSystem.fileExists)
        } else if fileSystem.fileExists(published) {
            try fileSystem.removeItem(published)
        }
        try fileSystem.moveItem(from: temp, to: published)
        progress(1)
        return ConversionProduct(inputURL: input, outputURL: published, outcome: outcome, config: config)
    }
}
