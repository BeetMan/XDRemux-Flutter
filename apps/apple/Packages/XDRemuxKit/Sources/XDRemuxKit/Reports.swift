import Foundation
import XDRemuxCoreC

/// Errors surfaced by the Swift wrapper. Rust never panics across the ABI;
/// failures arrive as `success:false` reports and are translated here.
public enum XDRemuxError: Error, Equatable, Sendable {
    /// Rust reported failure; `message` is its `errorMessage` when present.
    case coreFailure(message: String?)
    /// A JSON report could not be decoded.
    case malformedReport(String)
    /// Rust returned a null string (allocation failure).
    case nullResult
}

/// Swift copy of `ClassificationResult`; the Rust struct is freed before this
/// value is returned.
public struct Classification: Codable, Equatable, Sendable {
    public let modeKey: String?
    public let folderName: String?
    public let status: String?
    public let rawUserComment: String?
    public let hasTagFlags: Bool
    public let tagFlags: UInt64
    public let unknownFlags: UInt64
    /// "lhdr" or "uhdr", nil when the input is not a ProXDR file.
    public let hdrKind: String?
    /// "x6" or "x7", nil when unknown.
    public let family: String?

    /// Memberwise: for the app's inspection cache and for tests.
    public init(modeKey: String?, folderName: String?, status: String?, rawUserComment: String? = nil,
                hasTagFlags: Bool = false, tagFlags: UInt64 = 0, unknownFlags: UInt64 = 0,
                hdrKind: String?, family: String?) {
        self.modeKey = modeKey
        self.folderName = folderName
        self.status = status
        self.rawUserComment = rawUserComment
        self.hasTagFlags = hasTagFlags
        self.tagFlags = tagFlags
        self.unknownFlags = unknownFlags
        self.hdrKind = hdrKind
        self.family = family
    }

    init(consuming result: ClassificationResult) {
        defer { xdremux_free_classification_result(result) }
        modeKey = borrowedString(result.mode_key)
        folderName = borrowedString(result.folder_name)
        status = borrowedString(result.status)
        rawUserComment = borrowedString(result.raw_user_comment)
        hasTagFlags = result.has_tag_flags
        tagFlags = result.tag_flags
        unknownFlags = result.unknown_flags
        hdrKind = borrowedString(result.hdr_kind)
        family = borrowedString(result.family)
    }
}

/// Swift copy of `ConversionResult` (returned by `xdremux_inspect`,
/// `xdremux_convert*`). The Rust struct is freed before this value is returned.
public struct ConversionReport: Codable, Equatable, Sendable {
    public let success: Bool
    public let mode: String?
    public let family: String?
    public let edrScale: Double
    public let gainMapMax: Double
    public let errorMessage: String?

    public init(success: Bool, mode: String?, family: String?, edrScale: Double, gainMapMax: Double, errorMessage: String?) {
        self.success = success
        self.mode = mode
        self.family = family
        self.edrScale = edrScale
        self.gainMapMax = gainMapMax
        self.errorMessage = errorMessage
    }

    init(consuming result: ConversionResult) {
        defer { xdremux_free_result(result) }
        success = result.success
        mode = borrowedString(result.mode)
        family = borrowedString(result.family)
        edrScale = result.edr_scale
        gainMapMax = result.gain_map_max
        errorMessage = borrowedString(result.error_message)
    }

    /// Throws `XDRemuxError.coreFailure` when `success` is false.
    @discardableResult
    public func checked() throws -> ConversionReport {
        guard success else { throw XDRemuxError.coreFailure(message: errorMessage) }
        return self
    }
}

/// A JSON report string from Rust (`xdremux_codec_capabilities`,
/// `xdremux_inspect_photo_details`, motion photo, writeback, …).
public struct JSONReport: Sendable {
    public let raw: String

    init(consuming string: RustString) throws {
        guard let raw = string.consume() else { throw XDRemuxError.nullResult }
        self.raw = raw
    }

    /// Decodes into a `Decodable` type; keys follow the Rust camelCase contract.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(raw.utf8))
        } catch {
            throw XDRemuxError.malformedReport(String(describing: error))
        }
    }

    /// The generic `success` / `errorMessage` envelope every report carries.
    /// Throws `coreFailure` when `success` is not true.
    @discardableResult
    public func checked() throws -> JSONReport {
        struct Envelope: Decodable { let success: Bool?; let errorMessage: String? }
        let env: Envelope = try decode()
        guard env.success == true else { throw XDRemuxError.coreFailure(message: env.errorMessage) }
        return self
    }
}

/// Snapshot of a progress handle: `stage` is the Rust-defined stage index
/// (0 idle, 1 extract, 2 decode, 3 encode tiles, 4 assemble).
public struct ConversionProgress: Equatable, Sendable {
    public let stage: UInt32
    public let current: UInt32
    public let total: UInt32

    public init(stage: UInt32, current: UInt32, total: UInt32) {
        self.stage = stage
        self.current = current
        self.total = total
    }

    /// What the bar should show: each stage owns a band of the bar, so the
    /// early stages (which report no counts) still move it, tile encoding
    /// fills the bulk, and assembly sits just short of done. Stage 0 maps
    /// to 0 (callers keep the previous value if they want monotonic bars).
    public var fraction: Double {
        switch stage {
        case 1: return Phase.extract.band.lowerBound
        case 2: return Phase.decode.band.lowerBound
        case 3:
            let band = Phase.encode.band
            let ratio = total == 0 ? 0 : min(1, Double(current) / Double(total))
            return band.lowerBound + (band.upperBound - band.lowerBound) * ratio
        case 4: return Phase.assemble.band.lowerBound
        default: return 0
        }
    }

    /// Plain tile ratio, without the stage banding.
    public var tileRatio: Double {
        total == 0 ? 0 : Double(current) / Double(total)
    }

    public enum Phase: Equatable, Sendable, CaseIterable {
        case extract, decode, encode, assemble

        public var band: ClosedRange<Double> {
            switch self {
            case .extract: return 0.04...0.10
            case .decode: return 0.12...0.20
            case .encode: return 0.20...0.95
            case .assemble: return 0.97...1.0
            }
        }

        /// The phase a banded `fraction` came from.
        public init(fraction: Double) {
            self = Phase.allCases.last { fraction >= $0.band.lowerBound } ?? .extract
        }
    }
}
