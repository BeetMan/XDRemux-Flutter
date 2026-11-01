import Foundation
import XDRemuxModel

/// `XDRemuxEngine` as the model's `ConversionBackend`.
extension XDRemuxEngine: ConversionBackend {
    public func convert(input: String, output: String, config: RustConvertConfig,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> ConversionOutcome {
        let report = try await convert(input: input, output: output, config: config) { p in
            progress(p.fraction)
        }
        return ConversionOutcome(success: report.success, mode: report.mode, family: report.family,
                                 edrScale: report.edrScale, gainMapMax: report.gainMapMax,
                                 errorMessage: report.errorMessage)
    }

    public func verifyOutput(path: String, styles: Bool, portrait: Bool) async throws -> Bool {
        guard try await verifyOutput(path: path) else { return false }
        if styles, !(try await verifyStylesOutput(path: path)) { return false }
        if portrait, !(try await verifyPortraitOutput(path: path)) { return false }
        return true
    }
}

extension XDRemuxEngine: Styles3Backend {}

/// Decoded `xdremux_inspect_photo_details` report. Keys follow
/// `xdremux/rust/src/photo_details.rs`; all fields are optional because Rust
/// omits what it could not read.
public struct PhotoDetails: Decodable, Equatable, Sendable {
    public var success: Bool
    public var errorMessage: String?
    public var make: String?
    public var model: String?
    public var dateTime: String?
    public var exposureTime: String?
    public var fNumber: String?
    public var iso: String?
    public var focalLength: String?
    public var focalLength35mm: String?
    public var exposureBias: String?
    public var width: Int?
    public var height: Int?
    public var hdrKind: String?
    public var hdrParseError: String?
    public var edrScale: Double?
    public var gainMapMax: Double?
    public var applePhotographicStyles: Bool?
    public var applePortrait: Bool?

    public var dimensionsText: String? {
        guard let width, let height else { return nil }
        return "\(width) × \(height)"
    }

    /// "58.7 MP" for the list, where the exact pixel counts are noise; one
    /// decimal below 10 MP ("2.1 MP"), whole numbers above ("50 MP").
    public var megapixelsText: String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        let mp = Double(width) * Double(height) / 1_000_000
        return mp < 10 ? String(format: "%.1f MP", mp) : String(format: "%.0f MP", mp)
    }

    /// "f/1.8 · 1/120 s · ISO 100 · 5.6mm" from whatever EXIF is present.
    /// Rust already formats each value with its unit or prefix.
    public var exposureSummary: String? {
        let parts = [fNumber, exposureTime, iso, focalLength].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension XDRemuxEngine {
    /// `photoDetails(path:)` decoded into `PhotoDetails`.
    public func decodedPhotoDetails(path: String) async throws -> PhotoDetails {
        try await photoDetails(path: path).decode()
    }
}
