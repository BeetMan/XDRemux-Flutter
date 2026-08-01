import Foundation
import VideoToolbox
import CoreVideo

/// Hardware HEVC encoding for gain-map tiles via VideoToolbox.
///
/// Each tile is a packed I420 (Y, then U, then V) frame that is wrapped in a
/// CVPixelBuffer and encoded to an Annex-B HEVC byte stream.  A real
/// VTCompressionSession configure attempt is used to probe 4:2:0 support,
/// mirroring the Android MediaCodecHevcEncoder.
enum VideoToolboxHevcEncoder {
    static let tileSize = 512

    /// Tracks whether the next encoded tile is the first of a conversion. The
    /// first tile carries VPS/SPS/PPS (prepended from VideoToolbox's format
    /// description) so Rust can extract the hvcC decoder config; later tiles
    /// are pure IDR slices, which ImageIO's ISO gain-map decoder expects.
    static var isFirstTile = true

    /// Whether this Mac can actually encode 4:2:0 HEVC (a real configure
    /// attempt).  Any failure → false (caller falls back to software path).
    static func canEncode420() -> Bool {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: 64,
            height: 64,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: kCFAllocatorDefault,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session = session else {
            return false
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_HEVC_Main_AutoLevel as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,
                             value: kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(session)
        VTCompressionSessionInvalidate(session)
        return true
    }

    /// Encode one packed I420 frame to an Annex-B HEVC byte stream.
    /// Returns nil on failure so the caller falls back to software encoding.
    static func encodeTile(yuv: Data, width: Int, height: Int) -> Data? {
        final class CallbackRef {
            var data = Data()
        }
        let ref = CallbackRef()
        let refPtr = Unmanaged.passRetained(ref).toOpaque()

        let w = Int32(width)
        let h = Int32(height)

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: w,
            height: h,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: kCFAllocatorDefault,
            outputCallback: { outputCallbackRefCon, _sourceFrameRefCon, status, _flags, sampleBuffer in
                guard status == noErr, let sampleBuffer = sampleBuffer else { return }
                let ctx = Unmanaged<CallbackRef>.fromOpaque(outputCallbackRefCon!).takeUnretainedValue()
                // The first tile of a conversion carries VPS/SPS/PPS (from
                // VideoToolbox's format description) so Rust can build the hvcC
                // decoder config. Later tiles are pure IDR slices.
                let isFirst = VideoToolboxHevcEncoder.isFirstTile
                if isFirst,
                   let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
                   let ext = CMFormatDescriptionGetExtensions(fmt) as? [String: Any],
                   let atoms = ext["SampleDescriptionExtensionAtoms"] as? NSDictionary,
                   let hvcCData = atoms["hvcC"] as? Data {
                    ctx.data.append(VideoToolboxHevcEncoder.hvccToAnnexB(hvcCData))
                }
                if isFirst {
                    VideoToolboxHevcEncoder.isFirstTile = false
                }
                if let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                    var length = 0
                    var dataPtr: UnsafeMutablePointer<Int8>?
                    CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0,
                                                lengthAtOffsetOut: nil, totalLengthOut: &length,
                                                dataPointerOut: &dataPtr)
                    if let dataPtr = dataPtr, length > 0 {
                        // VideoToolbox emits length-prefixed (AVCC) NALs, but
                        // the Rust assembler expects Annex-B start codes (the
                        // same format Android's MediaCodec produces). Rewrite
                        // each NAL as a 4-byte start code prefix.
                        var pos = 0
                        let raw = UnsafeRawPointer(dataPtr).bindMemory(to: UInt8.self, capacity: length)
                        while pos + 4 <= length {
                            let nalSize = Int(raw[pos]) << 24 | Int(raw[pos+1]) << 16 |
                                          Int(raw[pos+2]) << 8 | Int(raw[pos+3])
                            guard nalSize > 0, pos + 4 + nalSize <= length else { break }
                            ctx.data.append(contentsOf: [0, 0, 0, 1])
                            ctx.data.append(raw.advanced(by: pos + 4),
                                            count: nalSize)
                            pos += 4 + nalSize
                        }
                    }
                }
            },
            refcon: refPtr,
            compressionSessionOut: &session
        )
        guard status == noErr, let session = session else {
            Unmanaged.passUnretained(ref).release()
            return nil
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_HEVC_Main_AutoLevel as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,
                             value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: 1 as CFTypeRef)

        let frameSize = width * height
        let chromaW = (width + 1) / 2
        let chromaH = (height + 1) / 2
        let chromaSize = chromaW * chromaH
        guard yuv.count >= frameSize + 2 * chromaSize else {
            VTCompressionSessionInvalidate(session)
            Unmanaged.passUnretained(ref).release()
            return nil
        }

        // Full-range (0–255) YUV, matching x265's "range full". Without this
        // VideoToolbox encodes limited range (420v), shifting decoded gain
        // values and making HDR brightness differ from the x265/Swift outputs.
        // Use the full-range biplanar pixel format so the encoder inherits it.
        let pbFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: NSNumber(value: pbFormat),
            kCVPixelBufferWidthKey: NSNumber(value: w),
            kCVPixelBufferHeightKey: NSNumber(value: h),
            kCVPixelBufferPlaneAlignmentKey: 16 as CFNumber,
        ]
        let pbStatus = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                           pbFormat,
                                           attrs as CFDictionary, &pixelBuffer)
        guard pbStatus == kCVReturnSuccess, let buffer = pixelBuffer else {
            VTCompressionSessionInvalidate(session)
            Unmanaged.passUnretained(ref).release()
            return nil
        }

        // Match the x265 full-range BT.709 encoding so decoded gain values are
        // identical to the software path. Honors VideoToolbox's color-matrix
        // attachment on the source buffer.
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2 as CFTypeRef,
                              .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2 as CFTypeRef,
                              .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2 as CFTypeRef,
                              .shouldPropagate)

        CVPixelBufferLockBaseAddress(buffer, [])
        yuv.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.baseAddress!
            let planeCount = CVPixelBufferGetPlaneCount(buffer)
            if planeCount >= 3 {
                // Planar I420: Y, then U, then V.
                for plane in 0..<3 {
                    let dst = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
                    let dstStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                    let srcPlane = src + (plane > 0 ? frameSize + (plane - 1) * chromaSize : 0)
                    let bytes = plane > 0 ? chromaSize : frameSize
                    let stride = plane > 0 ? chromaW : width
                    let rows = plane > 0 ? chromaH : height
                    if dstStride == stride {
                        memcpy(dst, srcPlane, bytes)
                    } else {
                        for row in 0..<rows {
                            memcpy(dst + row * dstStride, srcPlane + row * stride, stride)
                        }
                    }
                }
            } else {
                // Biplanar NV12 (full range): plane 0 = Y, plane 1 = interleaved
                // U/V. Convert packed I420 (Y,U,V) into NV12 (Y, U/V interleaved).
                let dstY = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
                let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                let dstUV = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
                let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
                // Copy Y.
                if yStride == width {
                    memcpy(dstY, src, frameSize)
                } else {
                    let srcY = src.assumingMemoryBound(to: UInt8.self)
                    let dstYRow = dstY.assumingMemoryBound(to: UInt8.self)
                    for row in 0..<height {
                        memcpy(dstYRow + row * yStride, srcY + row * width, width)
                    }
                }
                // Interleave U/V into NV12.
                let uSrc = (src + frameSize).assumingMemoryBound(to: UInt8.self)
                let vSrc = (src + frameSize + chromaSize).assumingMemoryBound(to: UInt8.self)
                let dstRowBase = dstUV.assumingMemoryBound(to: UInt8.self)
                let uvBytesPerRow = chromaW * 2
                for row in 0..<chromaH {
                    let dstRow = dstRowBase + row * uvStride
                    let uRow = uSrc + row * chromaW
                    let vRow = vSrc + row * chromaW
                    for col in 0..<chromaW {
                        dstRow[col * 2] = uRow[col]
                        dstRow[col * 2 + 1] = vRow[col]
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        // Encode the frame as a keyframe.
        let pts = CMTime(value: 0, timescale: 30)
        let encodeStatus = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: buffer,
            presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: 30),
            frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )

        if encodeStatus == noErr {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        }

        VTCompressionSessionInvalidate(session)
        Unmanaged.passUnretained(ref).release()

        return ref.data.isEmpty ? nil : ref.data
    }

    /// Convert a VideoToolbox hvcC decoder-config record (VPS/SPS/PPS NALs)
    /// into an Annex-B byte stream that Rust's hvcC extractor can parse.
    ///
    /// VideoToolbox's SampleDescriptionExtensionAtoms hvcC does not follow the
    /// standard HEVCDecoderConfigurationRecord layout (numOfArrays is zero);
    /// the VPS/SPS/PPS NALs are stored back-to-back after the header. We detect
    /// the 2-byte NAL headers (VPS=40 01, SPS=42 01, PPS=44 01) and emit them
    /// as an Annex-B stream.
    private static func hvccToAnnexB(_ hvcC: Data) -> Data {
        var out = Data()
        let vpsHeader: [UInt8] = [0x40, 0x01]
        let spsHeader: [UInt8] = [0x42, 0x01]
        let ppsHeader: [UInt8] = [0x44, 0x01]
        var positions: [(Int, [UInt8])] = []
        var i = 0
        while i + 1 < hvcC.count {
            let pair = [hvcC[i], hvcC[i + 1]]
            if pair == vpsHeader || pair == spsHeader || pair == ppsHeader {
                positions.append((i, pair))
                i += 2
                continue
            }
            i += 1
        }
        for (idx, (start, _)) in positions.enumerated() {
            let end = idx + 1 < positions.count ? positions[idx + 1].0 : hvcC.count
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(hvcC[start..<end])
        }
        return out
    }
}
