import Foundation

#if canImport(UIKit)
import CZstdDecompress

/// Zstandard frame decompression backed by the vendored zstd 1.5.7
/// decompression sources (`Sources/CZstdDecompress`).
///
/// The macOS build shells out to the `zstd` CLI for OPPO portrait payload
/// decompression; iOS cannot spawn processes, so this in-process decoder
/// is installed as `PortraitConversionPipeline.zstdDecoder`. Implemented
/// as a streaming decode so frames without a declared content size work.
enum EmbeddedZstdDecoder {
    enum DecodeError: Error, LocalizedError {
        case emptyInput
        case outputTooLarge
        case zstdFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyInput:
                return "embedded zstd decoder received an empty frame"
            case .outputTooLarge:
                return "embedded zstd decoder: decoded size exceeds the safety limit"
            case .zstdFailed(let name):
                return "embedded zstd decoder failed: \(name)"
            }
        }
    }

    /// Portrait payloads are a handful of megabytes compressed; cap the
    /// decoded size so a hostile/corrupt frame cannot exhaust memory.
    private static let maxOutputSize = 256 * 1024 * 1024

    private static let chunkSize = 1 << 20  // 1 MiB

    static func decode(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw DecodeError.emptyInput }

        let dctx = ZSTD_createDCtx()
        defer { ZSTD_freeDCtx(dctx) }

        var output = Data()
        let inputChunkSize = ZSTD_DStreamInSize()
        let outputChunkSize = ZSTD_DStreamOutSize()

        return try data.withUnsafeBytes { (rawInput: UnsafeRawBufferPointer) throws -> Data in
            var input = ZSTD_inBuffer(
                src: rawInput.baseAddress,
                size: rawInput.count,
                pos: 0)
            let outputBuffer = UnsafeMutableRawPointer.allocate(
                byteCount: max(Int(outputChunkSize), 1), alignment: 8)
            defer { outputBuffer.deallocate() }

            while input.pos < input.size {
                var out = ZSTD_outBuffer(
                    dst: outputBuffer,
                    size: max(Int(outputChunkSize), 1),
                    pos: 0)
                let remaining = ZSTD_decompressStream(dctx, &out, &input)
                if ZSTD_isError(remaining) != 0 {
                    throw DecodeError.zstdFailed(
                        String(cString: ZSTD_getErrorName(remaining)))
                }
                if out.pos > 0 {
                    guard output.count + out.pos <= maxOutputSize else {
                        throw DecodeError.outputTooLarge
                    }
                    output.append(
                        outputBuffer.assumingMemoryBound(to: UInt8.self), count: out.pos)
                }
                // remaining == 0 means the frame is fully decoded; anything
                // left in the input is trailing garbage or another frame -
                // the portrait payload is a single frame, so stop there.
                if remaining == 0 { break }
            }
            return output
        }
    }
}
#endif
