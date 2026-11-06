import CoreMedia
import CoreVideo
import Foundation
import OSLog
import VideoToolbox
import XDRemuxCoreC
import XDRemuxModel

/// HEVC intra encoder for the gain-map tiles of the hardware path
/// (`xdremux_prepare_tiles` → one keyframe per tile → `xdremux_assemble_tiles`).
///
/// Tiles are 8-bit packed I420 (Y, then U, then V) at the size the core
/// chose, 512×512 today. Each comes back as an Annex-B byte stream with
/// 4-byte start codes; VPS/SPS/PPS are prepended to every stream, the core
/// keeps the first set for `hvcC` and strips the rest.
/// (`docs/formats/hevc-hevc-conventions.md` §tiles)
public final class VideoToolboxTileEncoder {
    public enum Failure: Error, Equatable {
        case sessionUnavailable(OSStatus)
        case pixelBuffer(CVReturn)
        case encode(OSStatus)
        case noOutput
        case badTile
    }

    public let width: Int
    public let height: Int
    private let session: VTCompressionSession
    private var frameIndex: Int64 = 0

    /// Whether a hardware HEVC encoder answers for one tile. Cached: the
    /// probe creates a session, which costs a few milliseconds.
    public static let isAvailable: Bool = {
        (try? VideoToolboxTileEncoder(width: 512, height: 512)) != nil
    }()

    public init(width: Int, height: Int) throws {
        self.width = width
        self.height = height
        var spec: [CFString: Any] = [:]
        #if os(macOS)
        // On macOS a software HEVC encoder also exists; the point of this
        // path is the hardware one.
        spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true
        #endif
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let session = created else { throw Failure.sessionUnavailable(status) }
        self.session = session
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main_AutoLevel,
            kVTCompressionPropertyKey_RealTime: false,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 1,
            kVTCompressionPropertyKey_Quality: 0.9,
        ]
        VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
        let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepared == noErr else {
            VTCompressionSessionInvalidate(session)
            throw Failure.sessionUnavailable(prepared)
        }
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// Encodes one packed I420 tile (`width*height*3/2` bytes) as a single
    /// IDR picture and returns the Annex-B stream with parameter sets.
    public func encode(_ tile: UnsafeRawBufferPointer) throws -> Data {
        guard tile.count == width * height * 3 / 2 else { throw Failure.badTile }
        let pixelBuffer = try makePixelBuffer(tile)
        let pts = CMTime(value: frameIndex, timescale: 1)
        frameIndex += 1
        let frameProperties: [CFString: Any] = [kVTEncodeFrameOptionKey_ForceKeyFrame: true]
        var output: Data?
        var failure: OSStatus = noErr
        let done = DispatchSemaphore(value: 0)
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: 1),
            frameProperties: frameProperties as CFDictionary, infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            defer { done.signal() }
            guard status == noErr else { failure = status; return }
            if let sampleBuffer { output = Self.annexB(sampleBuffer) }
        }
        guard status == noErr else { throw Failure.encode(status) }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: pts)
        done.wait()
        guard failure == noErr else { throw Failure.encode(failure) }
        guard let output, !output.isEmpty else { throw Failure.noOutput }
        return output
    }

    private func makePixelBuffer(_ tile: UnsafeRawBufferPointer) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        // Full range, like the x265 path; limited range would rescale the gain.
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                         nil, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw Failure.pixelBuffer(status) }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let src = tile.bindMemory(to: UInt8.self).baseAddress!
        let chromaWidth = width / 2, chromaHeight = height / 2
        // Y plane.
        let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<height {
            memcpy(y + row * yStride, src + row * width, width)
        }
        // Interleaved CbCr from the packed U and V planes.
        let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let u = src + width * height
        let v = u + chromaWidth * chromaHeight
        for row in 0..<chromaHeight {
            let dst = uv + row * uvStride
            let uRow = u + row * chromaWidth
            let vRow = v + row * chromaWidth
            for col in 0..<chromaWidth {
                dst[2 * col] = uRow[col]
                dst[2 * col + 1] = vRow[col]
            }
        }
        return buffer
    }

    private static let startCode = Data([0, 0, 0, 1])

    /// Parameter sets from the format description, then every NAL of the
    /// sample with its length prefix replaced by a start code.
    static func annexB(_ sample: CMSampleBuffer) -> Data? {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var out = Data()
        var count = 0
        var nalLengthSize: Int32 = 4
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                 parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                                 nalUnitHeaderLengthOut: &nalLengthSize) == noErr else { return nil }
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
            out += startCode
            out += Data(bytes: pointer, count: size)
        }
        var length = 0
        var base: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &base) == noErr, let base else { return nil }
        let bytes = UnsafeRawBufferPointer(start: base, count: length)
        var cursor = 0
        let prefix = Int(nalLengthSize)
        while cursor + prefix <= length {
            var nalLength = 0
            for i in 0..<prefix { nalLength = nalLength << 8 | Int(bytes[cursor + i]) }
            cursor += prefix
            guard nalLength > 0, cursor + nalLength <= length else { return nil }
            out += startCode
            out += Data(bytes[cursor..<(cursor + nalLength)])
            cursor += nalLength
        }
        return out
    }
}

/// Hardware tile path of the conversion pipeline.
extension XDRemuxEngine {
    private static let log = Logger(subsystem: "io.github.beetman.xdremux", category: "hardware-encode")

    /// Whether `config` can take the hardware path at all: the user asked
    /// for it, nothing in the output needs the x265 path (Styles, Styles 3
    /// and Portrait are built by the core's own encoder), and an encoder
    /// answers.
    public static func hardwareTilesApplicable(_ config: ConversionConfig) -> Bool {
        config.hardwareEncode && !config.applePhotographicStyles && !config.applePhotographicStyles3
            && !config.applePortrait && VideoToolboxTileEncoder.isAvailable
    }

    public enum HardwareTilesError: Error, Equatable {
        /// The core could not tile this input (unsupported source); the
        /// caller falls back to the ordinary pipeline.
        case notTiled(String?)
        case assembleFailed(String?)
        case verifyFailed
    }

    /// Converts `input` with the hardware encoder: the core prepares the
    /// gain-map tiles, VideoToolbox encodes each one, the core assembles the
    /// HEIC, and `xdremux_verify_output` checks it. Throws
    /// `HardwareTilesError` when this input cannot take the path or the
    /// result does not verify (the partial output is removed), so the
    /// caller can fall back to `convertPipeline`.
    public func convertHardwareTiles(
        input: String,
        output: String,
        config: ConversionConfig,
        pollInterval: Duration = .milliseconds(100),
        progress: (@Sendable (ConversionProgress) -> Void)? = nil
    ) async throws -> PipelineReport {
        let rust = config.rustConfig
        let handle = xdremux_progress_begin()
        defer { xdremux_progress_end(handle) }
        let poller: Task<Void, Never>? = progress.map { report in
            Task.detached {
                while !Task.isCancelled {
                    report(Self.readProgress(handle))
                    try? await Task.sleep(for: pollInterval)
                }
            }
        }
        defer { poller?.cancel() }
        let cancelled = CancelFlag()
        let report: ConversionReport = try await withTaskCancellationHandler {
            try await runOnQueue {
                try Self.encodeTiles(input: input, output: output, rust: rust, handle: handle, cancelled: cancelled)
            }
        } onCancel: {
            cancelled.set()
            xdremux_progress_cancel(handle)
        }
        if Task.isCancelled || cancelled.isSet { throw CancellationError() }
        guard report.success else {
            try? FileManager.default.removeItem(atPath: output)
            throw HardwareTilesError.assembleFailed(report.errorMessage)
        }
        guard try await verifyOutput(path: output) else {
            try? FileManager.default.removeItem(atPath: output)
            throw HardwareTilesError.verifyFailed
        }
        return PipelineReport(success: true, stage: "done", cancelled: false, errorMessage: nil,
                              mode: report.mode, family: report.family, edrScale: report.edrScale,
                              gainMapMax: report.gainMapMax, outputValid: true, verified: nil,
                              styles3Applied: false, grainSeed: nil)
    }

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func set() { lock.lock(); flag = true; lock.unlock() }
    }

    /// Runs on the core queue: prepare → encode loop → assemble, with the
    /// prepared buffers alive throughout.
    private static func encodeTiles(input: String, output: String, rust: RustConvertConfig,
                                    handle: UInt32, cancelled: CancelFlag) throws -> ConversionReport {
        var c = ConvertConfig(oppo_compat: rust.oppoCompat, oppo_camera_tail: rust.oppoCameraTail,
                              strict_tmap: rust.strictTmap, apple_photographic_styles: rust.applePhotographicStyles,
                              apple_portrait: rust.applePortrait)
        let prepared = withCPath(input) { cin in xdremux_prepare_tiles(cin, &c, handle) }
        defer { xdremux_free_prepared(prepared) }
        guard prepared.success, let data = prepared.tile_data, prepared.tile_count > 0 else {
            let message = prepared.error_message.map { String(cString: $0) }
            throw HardwareTilesError.notTiled(message)
        }
        let tileWidth = Int(prepared.tile_w), tileHeight = Int(prepared.tile_h), count = Int(prepared.tile_count)
        let perTile = tileWidth * tileHeight * 3 / 2
        guard prepared.tile_data_len == perTile * count else { throw HardwareTilesError.notTiled("tile buffer size") }
        let encoder = try VideoToolboxTileEncoder(width: tileWidth, height: tileHeight)
        var streams: [Data] = []
        streams.reserveCapacity(count)
        let start = Date()
        for index in 0..<count {
            if cancelled.isSet { throw CancellationError() }
            let tile = UnsafeRawBufferPointer(start: data + index * perTile, count: perTile)
            streams.append(try encoder.encode(tile))
            xdremux_progress_report(handle, UInt32(index + 1), UInt32(count))
        }
        log.info("encoded \(count) tiles of \(tileWidth)x\(tileHeight) in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")
        if cancelled.isSet { throw CancellationError() }
        return assemble(streams, prepared: prepared, output: output, handle: handle)
    }

    private static func assemble(_ streams: [Data], prepared: PreparedTilesResult, output: String,
                                 handle: UInt32) -> ConversionReport {
        var lengths = streams.map { $0.count }
        // Keep every stream's storage pinned while the core reads them.
        func withPointers(_ index: Int, _ pointers: inout [UnsafePointer<CChar>?], _ body: (inout [UnsafePointer<CChar>?]) -> ConversionReport) -> ConversionReport {
            if index == streams.count { return body(&pointers) }
            return streams[index].withUnsafeBytes { raw in
                pointers.append(raw.bindMemory(to: CChar.self).baseAddress)
                return withPointers(index + 1, &pointers, body)
            }
        }
        var pointers: [UnsafePointer<CChar>?] = []
        pointers.reserveCapacity(streams.count)
        return withPointers(0, &pointers) { pointers in
            withCPath(output) { cout in
                ConversionReport(consuming: xdremux_assemble_tiles(prepared.opaque, &pointers, &lengths, streams.count, cout, handle))
            }
        }
    }
}
