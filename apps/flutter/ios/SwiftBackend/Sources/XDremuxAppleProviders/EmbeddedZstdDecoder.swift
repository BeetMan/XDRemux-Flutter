import Foundation

#if canImport(UIKit)

/// Compatibility surface for the legacy Swift research bridge.
///
/// Rust now embeds the zstd decoder used by the product Apple Portrait path.
/// Keeping this Swift surface as an explicit unavailable implementation avoids
/// linking a second copy of zstd into the iOS app (which conflicts with the
/// Rust static library). Swift Apple feature conversion remains capability-
/// gated on iOS and does not use this research-only bridge.
public enum EmbeddedZstdDecoder {
    public enum DecodeError: Error, LocalizedError {
        case unavailable

        public var errorDescription: String? {
            "embedded Swift zstd bridge is unavailable; use the Rust Portrait path"
        }
    }

    public static func decode(_ data: Data) throws -> Data {
        throw DecodeError.unavailable
    }

    public static func encode(_ data: Data) throws -> Data {
        throw DecodeError.unavailable
    }
}
#endif
