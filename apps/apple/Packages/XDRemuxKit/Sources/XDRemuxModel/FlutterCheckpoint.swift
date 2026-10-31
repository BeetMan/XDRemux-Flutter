import Foundation

/// The Flutter app's batch checkpoint (`xdremux_checkpoint.jsonl`,
/// `apps/flutter/lib/models/checkpoint_model.dart`): one JSON object per
/// line, a `type: header` line first, then `type: item` lines. Read here so
/// a queue started in the Flutter app can continue in the native one, and
/// written so the reverse works. Unknown keys are dropped on re-encode
/// (`huaweiPortrait`, `motionPhoto` maps), which Flutter tolerates.
public struct FlutterCheckpoint: Equatable, Sendable {
    public struct Header: Codable, Equatable, Sendable {
        public var configHash: String
        public var totalJobs: Int
        public var startedAt: Date
        public var appVersion: String

        public init(configHash: String, totalJobs: Int, startedAt: Date, appVersion: String) {
            self.configHash = configHash
            self.totalJobs = totalJobs
            self.startedAt = startedAt
            self.appVersion = appVersion
        }
    }

    public enum Status: String, Codable, Sendable {
        case pending, converted, skippedExisting, skippedPolicy, failed
    }

    public struct Item: Codable, Equatable, Sendable {
        public var inputPath: String
        public var outputPath: String
        public var status: Status
        public var inputSize: Int
        public var inputMtimeMs: Int
        public var error: String?
        public var policyReason: String?
        public var finishedAt: Date?
        public var captureModeKey: String?
        public var captureModeFolderName: String?
        public var classificationStatus: String?
        public var hdrKind: String?
        public var family: String?
        public var huaweiHdr: Bool?
        public var huaweiHasXtstyle: Bool?
        public var motionPhotoMode: String?

        public init(inputPath: String, outputPath: String, status: Status = .pending, inputSize: Int = 0,
                    inputMtimeMs: Int = 0, error: String? = nil, policyReason: String? = nil, finishedAt: Date? = nil,
                    captureModeKey: String? = nil, captureModeFolderName: String? = nil, classificationStatus: String? = nil,
                    hdrKind: String? = nil, family: String? = nil, huaweiHdr: Bool? = nil, huaweiHasXtstyle: Bool? = nil,
                    motionPhotoMode: String? = nil) {
            self.inputPath = inputPath
            self.outputPath = outputPath
            self.status = status
            self.inputSize = inputSize
            self.inputMtimeMs = inputMtimeMs
            self.error = error
            self.policyReason = policyReason
            self.finishedAt = finishedAt
            self.captureModeKey = captureModeKey
            self.captureModeFolderName = captureModeFolderName
            self.classificationStatus = classificationStatus
            self.hdrKind = hdrKind
            self.family = family
            self.huaweiHdr = huaweiHdr
            self.huaweiHasXtstyle = huaweiHasXtstyle
            self.motionPhotoMode = motionPhotoMode
        }

        /// Flutter's `isDone`.
        public var isDone: Bool { status == .converted || status == .skippedExisting }
    }

    public var header: Header
    public var items: [Item]

    public init(header: Header, items: [Item]) {
        self.header = header
        self.items = items
    }

    public static let fileName = "xdremux_checkpoint.jsonl"

    // MARK: JSONL

    /// `nil` for an empty file or one whose first line is not a header; a
    /// malformed item line is skipped like Flutter's `fromJsonl` does for
    /// lines of another type (a truly broken line fails the whole parse there;
    /// here it is skipped so partial checkpoints still restore).
    public static func parse(jsonl: String) -> FlutterCheckpoint? {
        let lines = jsonl.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first, let headerData = first.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              raw["type"] as? String == "header",
              let header = try? decoder.decode(Header.self, from: headerData) else { return nil }
        var items: [Item] = []
        for line in lines.dropFirst() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "item",
                  let item = try? decoder.decode(Item.self, from: data) else { continue }
            items.append(item)
        }
        return FlutterCheckpoint(header: header, items: items)
    }

    public func jsonl() -> String {
        func line<T: Encodable>(_ value: T, type: String) -> String {
            var obj = (try? JSONSerialization.jsonObject(with: Self.encoder.encode(value)) as? [String: Any]) ?? [:]
            obj["type"] = type
            let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        return ([line(header, type: "header")] + items.map { line($0, type: "item") }).joined(separator: "\n") + "\n"
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = parseDate(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(iso8601Fractional.string(from: date))
        }
        return e
    }

    /// Dart's `toIso8601String()` writes microseconds and, for local times,
    /// no zone designator (`2026-10-30T21:00:00.123456`); ISO8601DateFormatter
    /// insists on a zone, so zone-less strings fall back to local time.
    static func parseDate(_ s: String) -> Date? {
        if let date = iso8601Fractional.date(from: s) ?? iso8601.date(from: s) { return date }
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = format
            if let date = f.date(from: s) { return date }
        }
        return nil
    }

    static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: Config hash

    /// Flutter hashes `{family, backend, outputMode, oppoCompatibility,
    /// outputDirectory, fileNameSuffix}` with Dart's `String.hashCode`, which
    /// is not reproducible here. Flutter only compares the hash with its own
    /// current one, so a differing value just means "config changed" there;
    /// this FNV-1a of the same payload gives the native side the same
    /// change-detection property.
    public static func configHash(_ config: ConversionConfig) -> String {
        let payload = "{\"family\":\"\(config.family.rawValue)\",\"backend\":\"rust\",\"outputMode\":\"\(config.outputMode.rawValue)\"," +
            "\"oppoCompatibility\":\"\(config.oppoCompatibility.rawValue)\",\"outputDirectory\":null,\"fileNameSuffix\":\"\(config.fileNameSuffix)\"}"
        var h: UInt32 = 2_166_136_261
        for byte in payload.utf8 { h ^= UInt32(byte); h = h &* 16_777_619 }
        return String(format: "%08x", h)
    }

    // MARK: Journal interop

    /// Native journal records for a Flutter checkpoint. `converted` /
    /// `skippedExisting` become `succeeded` (the output path is kept as-is),
    /// `skippedPolicy` becomes `pending` (the native policy re-evaluates),
    /// `failed` keeps its message.
    public func journalRecords() -> [QueueJournal.Record] {
        items.map { item in
            let name = (item.inputPath as NSString).lastPathComponent
            switch item.status {
            case .converted, .skippedExisting:
                return QueueJournal.Record(sourceName: name, inputPath: item.inputPath, status: .succeeded,
                                           outputPath: item.outputPath, outcome: ConversionOutcome(success: true, family: item.family),
                                           motionMode: item.motionPhotoMode.flatMap(MotionPhotoMode.init(rawValue:)))
            case .failed:
                return QueueJournal.Record(sourceName: name, inputPath: item.inputPath, status: .failed,
                                           motionMode: item.motionPhotoMode.flatMap(MotionPhotoMode.init(rawValue:)),
                                           errorMessage: item.error ?? "failed")
            case .pending, .skippedPolicy:
                return QueueJournal.Record(sourceName: name, inputPath: item.inputPath, status: .pending,
                                           motionMode: item.motionPhotoMode.flatMap(MotionPhotoMode.init(rawValue:)))
            }
        }
    }

    /// A checkpoint describing the native journal, for the Flutter app.
    /// `resolve` maps journal paths to the absolute paths Flutter should see.
    public static func from(journal: QueueJournal, config: ConversionConfig, appVersion: String,
                            startedAt: Date = Date(), resolve: (String) -> String = { $0 }) -> FlutterCheckpoint {
        let items = journal.records.map { r -> Item in
            let status: Status
            switch r.status {
            case .succeeded: status = .converted
            case .failed: status = .failed
            case .pending, .running: status = .pending
            }
            return Item(inputPath: resolve(r.inputPath), outputPath: r.outputPath.map(resolve) ?? "",
                        status: status, error: r.errorMessage, family: r.outcome?.family,
                        motionPhotoMode: r.motionMode?.rawValue)
        }
        return FlutterCheckpoint(header: Header(configHash: configHash(config), totalJobs: items.count,
                                                startedAt: startedAt, appVersion: appVersion), items: items)
    }
}
