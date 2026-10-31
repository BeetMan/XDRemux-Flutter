import Foundation

/// Durable record of the library so the app restores it after a restart
/// (plan §3 P2). Mirrors the HarmonyOS queue journal rules: atomic write
/// (temp file + rename), schema check on load, running items never resume
/// on their own, missing inputs become visible failures.
public struct QueueJournal: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public struct Record: Codable, Equatable, Sendable, Identifiable {
        public enum Status: String, Codable, Sendable {
            case pending, running, succeeded, failed
        }

        public var id: UUID
        public var sourceName: String
        public var inputPath: String
        public var status: Status
        public var outputPath: String?
        public var outcome: ConversionOutcome?
        public var config: ConversionConfig?
        public var pairedVideoPath: String?
        public var extraVideoPaths: [String]?
        public var motionMode: MotionPhotoMode?
        public var errorMessage: String?
        public var savedToPhotos: Bool
        public var addedAt: Date

        public init(id: UUID = UUID(), sourceName: String, inputPath: String, status: Status = .pending,
                    outputPath: String? = nil, outcome: ConversionOutcome? = nil, config: ConversionConfig? = nil,
                    pairedVideoPath: String? = nil, extraVideoPaths: [String]? = nil, motionMode: MotionPhotoMode? = nil,
                    errorMessage: String? = nil, savedToPhotos: Bool = false, addedAt: Date = Date()) {
            self.id = id
            self.sourceName = sourceName
            self.inputPath = inputPath
            self.status = status
            self.outputPath = outputPath
            self.outcome = outcome
            self.config = config
            self.pairedVideoPath = pairedVideoPath
            self.extraVideoPaths = extraVideoPaths
            self.motionMode = motionMode
            self.errorMessage = errorMessage
            self.savedToPhotos = savedToPhotos
            self.addedAt = addedAt
        }
    }

    public var schema: Int = QueueJournal.schemaVersion
    public var records: [Record] = []

    public init(records: [Record] = []) {
        self.records = records
    }

    // MARK: Restore rules

    /// Applies the restart rules: a record that was `running` goes back to
    /// `pending` (its temp output is gone), a `succeeded` record whose output
    /// file vanished becomes `failed`, and any record whose input is missing
    /// becomes `failed` with a re-import hint.
    public func restored(fileExists: (String) -> Bool) -> QueueJournal {
        var copy = self
        copy.records = records.map { record in
            var r = record
            if !fileExists(r.inputPath) {
                r.status = .failed
                r.errorMessage = "输入副本已不存在，请重新导入"
                r.outputPath = nil
                return r
            }
            switch r.status {
            case .running:
                r.status = .pending
                r.errorMessage = nil
            case .succeeded:
                let lostStill = r.outputPath.map { !fileExists($0) } ?? true
                let lostVideo = r.pairedVideoPath.map { !fileExists($0) } ?? false
                if lostStill || lostVideo {
                    r.status = .failed
                    r.errorMessage = lostVideo && !lostStill ? "Live Photo 视频已不存在，请重新转换" : "输出文件已不存在，请重新转换"
                    r.outputPath = nil
                    r.pairedVideoPath = nil
                }
            default:
                break
            }
            return r
        }
        return copy
    }
}

public enum QueueJournalError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
}

/// Reads and writes the journal file atomically.
public struct QueueJournalStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `nil` when no journal exists yet. A malformed file is left in place
    /// (renamed `.corrupt-<timestamp>`) and treated as empty so the user
    /// never loses the evidence.
    public func load() throws -> QueueJournal? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        do {
            let journal = try Self.decoder.decode(QueueJournal.self, from: data)
            guard journal.schema <= QueueJournal.schemaVersion else {
                throw QueueJournalError.unsupportedSchema(journal.schema)
            }
            return journal
        } catch let error as QueueJournalError {
            throw error
        } catch {
            let quarantine = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: quarantine)
            return nil
        }
    }

    public func save(_ journal: QueueJournal) throws {
        let data = try Self.encoder.encode(journal)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = fileURL.appendingPathExtension("tmp")
        try data.write(to: temp, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: fileURL)
        }
    }

    public func delete() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
