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
public struct Classification: Equatable, Sendable {
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
public struct ConversionReport: Equatable, Sendable {
    public let success: Bool
    public let mode: String?
    public let family: String?
    public let edrScale: Double
    public let gainMapMax: Double
    public let errorMessage: String?

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

/// Snapshot of a progress handle: `stage` is the Rust-defined stage index.
public struct ConversionProgress: Equatable, Sendable {
    public let stage: UInt32
    public let current: UInt32
    public let total: UInt32

    public var fraction: Double {
        total == 0 ? 0 : Double(current) / Double(total)
    }
}
