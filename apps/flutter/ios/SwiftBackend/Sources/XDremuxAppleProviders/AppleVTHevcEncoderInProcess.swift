import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import VideoToolbox

#if canImport(UIKit)
import XDremuxAppleFeatures

/// In-process port of the upstream `apple_vt_hevc_encoder.swift` helper
/// (Sources/XDremuxCore/Resources/Native). Interface parity: argv[0] =
/// input image, argv[1] = annex-B output path, then optional quality,
/// pixel mode (rgb10|rgb4448|rgb4448tile|mono8|mono8tile), hvcC output
/// path, tile size - exactly what DirectTiledHEVCGainMapEncoder and the
/// Photographic Styles pipeline pass on macOS.
///
/// Port deltas:
/// - The macOS helper dlopens VideoToolbox at a macOS-style bundle path
///   (`.../Versions/A/VideoToolbox`); iOS has no `Versions` subdir. Try
///   the iOS path first, then the macOS path, then RTLD_DEFAULT (the
///   framework is directly linked on iOS).
/// - `fail()` becomes a thrown error surfaced through the helper Result
///   contract (exit 1 + stderr), instead of terminating the process.
enum AppleVTHevcEncoderInProcess {

    static func run(arguments: [String]) -> AppleNativeToolchain.Result {
        do {
            try invoke(arguments: arguments)
            return AppleNativeToolchain.Result(
                status: 0, stdout: Data(), stderr: Data(), timedOut: false)
        } catch {
            return AppleNativeToolchain.Result(
                status: 1, stdout: Data(),
                stderr: Data((String(describing: error) + "\n").utf8),
                timedOut: false)
        }
    }

    // MARK: argv

    private struct Invocation {
        let inputPath: String
        let outputPath: String
        let quality: Double
        let mode: PixelMode
        let hvccOutputPath: String?
        let tileSize: Int
    }

    private static func parse(arguments: [String]) throws -> Invocation {
        guard arguments.count >= 2, arguments.count <= 6 else {
            throw HelperError.usage(
                "usage: apple-vt-hevc-encoder input output.hevc "
                    + "[quality] [rgb10|rgb4448|rgb4448tile|mono8|mono8tile] "
                    + "[output.hvcc] [tile-size]")
        }
        let quality: Double
        if arguments.count >= 3 {
            guard let parsed = Double(arguments[2]), parsed > 0.0, parsed <= 1.0 else {
                throw HelperError.usage("quality must be in the range (0.0, 1.0]")
            }
            quality = parsed
        } else {
            quality = 0.45
        }
        let mode: PixelMode
        if arguments.count >= 4 {
            guard let parsed = PixelMode(rawValue: arguments[3]) else {
                throw HelperError.usage(
                    "pixel mode must be rgb10, rgb4448, rgb4448tile, mono8, or mono8tile")
            }
            mode = parsed
        } else {
            mode = .rgb10
        }
        let hvccOutputPath = arguments.count >= 5 ? arguments[4] : nil
        let tileSize: Int
        if arguments.count >= 6 {
            guard let parsed = Int(arguments[5]), [256, 512, 1024].contains(parsed) else {
                throw HelperError.usage("tile size must be 256, 512, or 1024")
            }
            tileSize = parsed
        } else {
            tileSize = 512
        }
        return Invocation(
            inputPath: arguments[0],
            outputPath: arguments[1],
            quality: quality,
            mode: mode,
            hvccOutputPath: hvccOutputPath,
            tileSize: tileSize)
    }

    private static func invoke(arguments: [String]) throws {
        let invocation = try parse(arguments: arguments)
        let source = try makeSourceFrame(
            path: invocation.inputPath,
            mode: invocation.mode,
            tileSize: invocation.tileSize)
        if invocation.mode == .rgb4448tile || invocation.mode == .mono8tile {
            let tileState = try encodeWithTileSession(
                source: source,
                quality: invocation.quality,
                mode: invocation.mode,
                tileSize: invocation.tileSize)
            var annexB = tileState.parameterSets
            for sample in tileState.samples {
                annexB.append(sample!)
            }
            if annexB.isEmpty {
                throw HelperError.encoding("VTTileCompressionSession produced no HEVC data")
            }
            try annexB.write(to: URL(fileURLWithPath: invocation.outputPath))
            if let hvccOutputPath = invocation.hvccOutputPath {
                if tileState.hvcc.isEmpty {
                    throw HelperError.encoding(
                        "VTTileCompressionSession format description did not expose an hvcC atom")
                }
                try tileState.hvcc.write(to: URL(fileURLWithPath: hvccOutputPath))
            }
            return
        }

        let state = EncoderState()
        let imageBufferAttributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: CVPixelBufferGetPixelFormatType(source.pixelBuffer),
            kCVPixelBufferWidthKey: source.width,
            kCVPixelBufferHeightKey: source.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ] as CFDictionary
        var session: VTCompressionSession?
        try check(
            VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(source.width),
                height: Int32(source.height),
                codecType: kCMVideoCodecType_HEVC,
                encoderSpecification: nil,
                imageBufferAttributes: imageBufferAttributes,
                compressedDataAllocator: nil,
                outputCallback: frameCallback,
                refcon: UnsafeMutableRawPointer(
                    Unmanaged.passUnretained(state).toOpaque()),
                compressionSessionOut: &session),
            "VTCompressionSessionCreate failed")
        guard let session else {
            throw HelperError.encoding("VTCompressionSessionCreate returned nil")
        }
        let profile: CFString
        switch invocation.mode {
        case .mono8, .mono8tile:
            profile = kVTProfileLevel_HEVC_Monochrome_AutoLevel
        case .rgb4448, .rgb4448tile:
            profile = try dynamicallyLoadedProfile("kVTProfileLevel_HEVC_Main444_AutoLevel")
        case .rgb10:
            profile = kVTProfileLevel_HEVC_Main10_AutoLevel
        }
        try check(
            VTSessionSetProperty(
                session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile),
            "setting HEVC profile failed")
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_AllowFrameReordering,
            value: kCFBooleanFalse)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: 1 as CFTypeRef)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: 1 as CFTypeRef)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_Quality,
            value: invocation.quality as CFTypeRef)
        if invocation.mode == .rgb4448 {
            try check(
                VTSessionSetProperty(
                    session,
                    key: "QuantizationScalingMatrixPreset" as CFString,
                    value: 1 as CFTypeRef),
                "setting HEVC 4:4:4 quantization matrix failed")
        }
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_ColorPrimaries,
            value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_TransferFunction,
            value: kCVImageBufferTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_YCbCrMatrix,
            value: kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        try check(
            VTCompressionSessionPrepareToEncodeFrames(session),
            "VTCompressionSessionPrepareToEncodeFrames failed")
        let frameProperties: CFDictionary =
            [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        try check(
            VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: source.pixelBuffer,
                presentationTimeStamp: CMTime(value: 0, timescale: 1),
                duration: CMTime(value: 1, timescale: 1),
                frameProperties: frameProperties,
                sourceFrameRefcon: nil,
                infoFlagsOut: nil),
            "VTCompressionSessionEncodeFrame failed")
        try check(
            VTCompressionSessionCompleteFrames(
                session, untilPresentationTimeStamp: .invalid),
            "VTCompressionSessionCompleteFrames failed")
        VTCompressionSessionInvalidate(session)

        if let error = state.error {
            throw HelperError.encoding(error)
        }
        if state.annexB.isEmpty {
            throw HelperError.encoding("VideoToolbox produced no HEVC data")
        }
        try state.annexB.write(to: URL(fileURLWithPath: invocation.outputPath))
        if let hvccOutputPath = invocation.hvccOutputPath {
            if state.hvcc.isEmpty {
                throw HelperError.encoding(
                    "VideoToolbox format description did not expose an hvcC atom")
            }
            try state.hvcc.write(to: URL(fileURLWithPath: hvccOutputPath))
        }
    }

    private enum HelperError: Error {
        case usage(String)
        case encoding(String)
    }

    private static func check(_ status: OSStatus, _ message: String) throws {
        if status != noErr {
            throw HelperError.encoding("\(message): OSStatus \(status)")
        }
    }

    // MARK: shared types (upstream parity)

    private final class EncoderState {
        var annexB = Data()
        var hvcc = Data()
        var wroteParameterSets = false
        var error: String?
    }

    private enum PixelMode: String {
        case rgb10
        case rgb4448
        case rgb4448tile
        case mono8
        case mono8tile
    }

    private struct SourceFrame {
        let pixelBuffer: CVPixelBuffer
        let width: Int
        let height: Int
    }

    private final class TileEncoderState {
        let lock = NSLock()
        var samples: [Data?]
        var parameterSets = Data()
        var hvcc = Data()
        var error: String?

        init(tileCount: Int) {
            samples = Array(repeating: nil, count: tileCount)
        }
    }

    // MARK: image loading (upstream parity)

    private static func loadImage(_ path: String) throws -> CGImage {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw HelperError.encoding("Could not load image: \(path)")
        }
        return image
    }

    private static func makePixelBuffer(
        from image: CGImage,
        mode: PixelMode,
        targetWidth: Int? = nil,
        targetHeight: Int? = nil
    ) throws -> CVPixelBuffer {
        let width = targetWidth ?? image.width
        let height = targetHeight ?? image.height
        let pixelFormat = mode == .mono8 || mode == .mono8tile
            ? kCVPixelFormatType_OneComponent8
            : kCVPixelFormatType_32BGRA
        let attrs: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ] as CFDictionary
        var pixelBuffer: CVPixelBuffer?
        try check(
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, pixelFormat, attrs, &pixelBuffer),
            "CVPixelBufferCreate failed")
        guard let buffer = pixelBuffer else {
            throw HelperError.encoding("CVPixelBufferCreate returned nil")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw HelperError.encoding("Pixel buffer has no base address")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = mode == .mono8 || mode == .mono8tile
            ? CGColorSpaceCreateDeviceGray()
            : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = mode == .mono8 || mode == .mono8tile
            ? CGBitmapInfo(rawValue: 0)
            : CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue) else {
            throw HelperError.encoding("Could not create CGContext for pixel buffer")
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        // HEIF grids crop padded tiles from the top-left raster origin.
        // Quartz bitmap contexts use a bottom-left drawing origin, so
        // bottom-aligning a short final tile puts the padding at the top
        // and shifts the decoded image downward. Move the source up by
        // the vertical padding so the cropped grid starts at the first
        // source row; horizontal origins already agree.
        context.draw(
            image,
            in: CGRect(
                x: 0, y: height - image.height,
                width: image.width, height: image.height))
        return buffer
    }

    @available(iOS 16.0, *)
    private static func makeYUV444Frame(
        from image: CGImage,
        padToTileGrid: Bool = false,
        tileSize: Int = 512
    ) throws -> SourceFrame {
        let width =
            padToTileGrid ? ((image.width + tileSize - 1) / tileSize) * tileSize : image.width
        let height =
            padToTileGrid ? ((image.height + tileSize - 1) / tileSize) * tileSize : image.height
        let source = try makePixelBuffer(
            from: image, mode: .rgb10, targetWidth: width, targetHeight: height)
        let attrs: CFDictionary = [
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        var pixelBuffer: CVPixelBuffer?
        try check(
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height,
                kCVPixelFormatType_444YpCbCr8BiPlanarFullRange, attrs, &pixelBuffer),
            "8-bit YUV444 CVPixelBufferCreate failed")
        guard let destination = pixelBuffer else {
            throw HelperError.encoding("8-bit YUV444 CVPixelBufferCreate returned nil")
        }
        CVBufferSetAttachment(
            destination,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_601_4,
            .shouldPropagate)
        var transferSession: VTPixelTransferSession?
        try check(
            VTPixelTransferSessionCreate(
                allocator: kCFAllocatorDefault,
                pixelTransferSessionOut: &transferSession),
            "VTPixelTransferSessionCreate failed")
        guard let transferSession else {
            throw HelperError.encoding("VTPixelTransferSessionCreate returned nil")
        }
        try check(
            VTPixelTransferSessionTransferImage(transferSession, from: source, to: destination),
            "BGRA to YUV444 pixel transfer failed")
        VTPixelTransferSessionInvalidate(transferSession)
        return SourceFrame(pixelBuffer: destination, width: width, height: height)
    }

    private static func makeSourceFrame(path: String, mode: PixelMode, tileSize: Int = 512)
        throws -> SourceFrame
    {
        let image = try loadImage(path)
        if mode == .rgb4448 || mode == .rgb4448tile {
            guard #available(iOS 16.0, *) else {
                throw HelperError.usage(
                    "rgb4448 modes require iOS 16+ (VTPixelTransferSession)")
            }
            return try makeYUV444Frame(
                from: image,
                padToTileGrid: mode == .rgb4448tile,
                tileSize: tileSize)
        }
        if mode == .mono8tile {
            let width = ((image.width + tileSize - 1) / tileSize) * tileSize
            let height = ((image.height + tileSize - 1) / tileSize) * tileSize
            return SourceFrame(
                pixelBuffer: try makePixelBuffer(
                    from: image, mode: mode, targetWidth: width, targetHeight: height),
                width: width,
                height: height)
        }
        return SourceFrame(
            pixelBuffer: try makePixelBuffer(from: image, mode: mode),
            width: image.width,
            height: image.height)
    }

    // MARK: NAL utilities (upstream parity)

    private static func appendStartCode(_ data: inout Data) {
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
    }

    private static func appendParameterSets(
        from formatDescription: CMFormatDescription, to data: inout Data
    ) throws -> Int32 {
        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 0
        var firstPointer: UnsafePointer<UInt8>?
        var firstSize = 0
        let firstStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &firstPointer,
            parameterSetSizeOut: &firstSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength)
        if firstStatus != noErr {
            throw NSError(
                domain: "AppleVTEncoder", code: Int(firstStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: "Could not read HEVC parameter sets"
                ])
        }
        if let ptr = firstPointer, firstSize > 0 {
            appendStartCode(&data)
            data.append(ptr, count: firstSize)
        }
        if parameterSetCount > 1 {
            for index in 1..<parameterSetCount {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                var count = 0
                var headerLength: Int32 = 0
                let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDescription,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: &headerLength)
                if status != noErr {
                    throw NSError(
                        domain: "AppleVTEncoder", code: Int(status),
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Could not read HEVC parameter set \(index)"
                        ])
                }
                if let ptr = pointer, size > 0 {
                    appendStartCode(&data)
                    data.append(ptr, count: size)
                }
            }
        }
        return nalUnitHeaderLength
    }

    private static func appendSampleData(
        _ sampleBuffer: CMSampleBuffer, nalUnitHeaderLength: Int32, to data: inout Data
    ) throws {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw NSError(
                domain: "AppleVTEncoder", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Sample has no block buffer"])
        }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer)
        if status != noErr {
            throw NSError(
                domain: "AppleVTEncoder", code: Int(status),
                userInfo: [
                    NSLocalizedDescriptionKey: "Could not access compressed sample data"
                ])
        }
        guard let rawPointer = dataPointer else {
            throw NSError(
                domain: "AppleVTEncoder", code: -2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Compressed sample data pointer is nil"
                ])
        }
        let bytes = UnsafeRawPointer(rawPointer).assumingMemoryBound(to: UInt8.self)
        let headerLength = Int(nalUnitHeaderLength)
        var offset = 0
        while offset + headerLength <= totalLength {
            var nalLength = 0
            for idx in 0..<headerLength {
                nalLength = (nalLength << 8) | Int(bytes[offset + idx])
            }
            offset += headerLength
            if nalLength <= 0 || offset + nalLength > totalLength {
                throw NSError(
                    domain: "AppleVTEncoder", code: -3,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Invalid NAL length in compressed sample"
                    ])
            }
            appendStartCode(&data)
            data.append(bytes + offset, count: nalLength)
            offset += nalLength
        }
    }

    // MARK: dynamic VideoToolbox symbols (upstream parity; iOS paths)

    private static func videoToolboxSymbol<T>(_ symbolName: String, as type: T.Type) throws -> T {
        let handles: [UnsafeMutableRawPointer?] = [
            dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox", RTLD_LAZY),
            dlopen(
                "/System/Library/Frameworks/VideoToolbox.framework/Versions/A/VideoToolbox",
                RTLD_LAZY),
            dlopen(nil, RTLD_LAZY),  // RTLD_DEFAULT: search already-linked images
        ]
        for handle in handles {
            if let handle, let symbol = dlsym(handle, symbolName) {
                return unsafeBitCast(symbol, to: type)
            }
        }
        throw HelperError.encoding("VideoToolbox symbol is unavailable: \(symbolName)")
    }

    private static func dynamicallyLoadedProfile(_ symbolName: String) throws -> CFString {
        let symbol = try videoToolboxSymbol(
            symbolName, as: UnsafePointer<Optional<CFString>>.self)
        guard let value = symbol.pointee else {
            throw HelperError.encoding("VideoToolbox profile symbol is nil: \(symbolName)")
        }
        return value
    }

    // MARK: tile session (undocumented VideoToolbox entry points)

    private typealias VTTileCompressionOutputCallback = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?,
        CMVideoDimensions,
        CMVideoDimensions,
        OSStatus,
        UInt32,
        CMSampleBuffer?
    ) -> Void

    private typealias VTTileCompressionSessionCreateFunction = @convention(c) (
        CFAllocator?,
        CMVideoDimensions,
        CMVideoCodecType,
        CFDictionary?,
        CFDictionary?,
        CFAllocator?,
        VTTileCompressionOutputCallback?,
        UnsafeMutableRawPointer?,
        UnsafeMutablePointer<CFTypeRef?>
    ) -> OSStatus

    private typealias VTTileCompressionSessionSetPropertiesFunction = @convention(c) (
        CFTypeRef,
        CFDictionary
    ) -> OSStatus

    private typealias VTTileCompressionSessionPrepareFunction = @convention(c) (
        CFTypeRef,
        UInt32,
        UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus

    private typealias VTTileCompressionSessionEncodeTileFunction = @convention(c) (
        CFTypeRef,
        CVPixelBuffer,
        CMVideoDimensions,
        CMVideoDimensions,
        CFDictionary?,
        UnsafeMutableRawPointer?,
        UnsafeMutablePointer<UInt32>?
    ) -> OSStatus

    private typealias VTTileCompressionSessionCompleteFunction =
        @convention(c) (CFTypeRef) -> OSStatus
    private typealias VTTileCompressionSessionInvalidateFunction =
        @convention(c) (CFTypeRef) -> Void

    private static let tileCallback: VTTileCompressionOutputCallback = {
        refcon, tileRefcon, _, _, status, infoFlags, sampleBuffer in
        guard let refcon else { return }
        let state = Unmanaged<TileEncoderState>.fromOpaque(refcon).takeUnretainedValue()
        state.lock.lock()
        defer { state.lock.unlock() }
        if status != noErr {
            state.error = "Tile compression callback status \(status)"
            return
        }
        if (infoFlags & VTEncodeInfoFlags.frameDropped.rawValue) != 0 {
            state.error = "Tile compression callback dropped a tile"
            return
        }
        guard let tileRefcon,
              let sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            state.error = "Tile compression callback returned an incomplete sample"
            return
        }
        let index = Int(bitPattern: tileRefcon) - 1
        guard state.samples.indices.contains(index) else {
            state.error = "Tile compression callback returned invalid tile index \(index)"
            return
        }
        do {
            let nalUnitHeaderLength: Int32
            if state.parameterSets.isEmpty {
                nalUnitHeaderLength = try appendParameterSets(
                    from: formatDescription, to: &state.parameterSets)
                if let extensions =
                    CMFormatDescriptionGetExtensions(formatDescription) as? [String: Any],
                   let atoms =
                    extensions[
                        kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String]
                        as? [String: Any],
                   let hvcc = atoms["hvcC"] as? Data {
                    state.hvcc = hvcc
                }
            } else {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                var count = 0
                var headerLength: Int32 = 0
                let parameterStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDescription,
                    parameterSetIndex: 0,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: &headerLength)
                guard parameterStatus == noErr else {
                    throw NSError(
                        domain: "AppleVTTileEncoder", code: Int(parameterStatus),
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Could not read tile NAL header length"
                        ])
                }
                nalUnitHeaderLength = headerLength
            }
            var sampleData = Data()
            try appendSampleData(
                sampleBuffer, nalUnitHeaderLength: nalUnitHeaderLength, to: &sampleData)
            state.samples[index] = sampleData
        } catch {
            state.error = error.localizedDescription
        }
    }

    private static func encodeWithTileSession(
        source: SourceFrame,
        quality: Double,
        mode: PixelMode,
        tileSize: Int
    ) throws -> TileEncoderState {
        let tileWidth = tileSize
        let tileHeight = tileSize
        let columns = (source.width + tileWidth - 1) / tileWidth
        let rows = (source.height + tileHeight - 1) / tileHeight
        let state = TileEncoderState(tileCount: columns * rows)
        let create = try videoToolboxSymbol(
            "VTTileCompressionSessionCreate",
            as: VTTileCompressionSessionCreateFunction.self)
        let setProperties = try videoToolboxSymbol(
            "VTTileCompressionSessionSetProperties",
            as: VTTileCompressionSessionSetPropertiesFunction.self)
        let prepare = try videoToolboxSymbol(
            "VTTileCompressionSessionPrepareToEncodeTiles",
            as: VTTileCompressionSessionPrepareFunction.self)
        let encodeTile = try videoToolboxSymbol(
            "VTTileCompressionSessionEncodeTile",
            as: VTTileCompressionSessionEncodeTileFunction.self)
        let complete = try videoToolboxSymbol(
            "VTTileCompressionSessionCompleteTiles",
            as: VTTileCompressionSessionCompleteFunction.self)
        let invalidate = try videoToolboxSymbol(
            "VTTileCompressionSessionInvalidate",
            as: VTTileCompressionSessionInvalidateFunction.self)
        // The hw-accel specification key is iOS 17.4+ in the Swift surface;
        // its runtime value is "EnableHardwareAcceleratedVideoEncoder"
        // (verified on macOS 27). On older iOS this resolves to an unknown
        // key and VideoToolbox picks its default (software) encoder.
        let hwAccelKey = "EnableHardwareAcceleratedVideoEncoder" as CFString
        let encoderSpecification: CFDictionary = [
            hwAccelKey: true,
        ] as CFDictionary
        let imageBufferAttributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey:
                CVPixelBufferGetPixelFormatType(source.pixelBuffer),
        ] as CFDictionary
        var session: CFTypeRef?
        try check(
            create(
                kCFAllocatorDefault,
                CMVideoDimensions(width: Int32(tileWidth), height: Int32(tileHeight)),
                kCMVideoCodecType_HEVC,
                encoderSpecification,
                imageBufferAttributes,
                kCFAllocatorDefault,
                tileCallback,
                Unmanaged.passUnretained(state).toOpaque(),
                &session),
            "VTTileCompressionSessionCreate failed")
        guard let session else {
            throw HelperError.encoding("VTTileCompressionSessionCreate returned nil")
        }
        let profile: CFString = mode == .mono8tile
            ? kVTProfileLevel_HEVC_Monochrome_AutoLevel
            : try dynamicallyLoadedProfile("kVTProfileLevel_HEVC_Main444_AutoLevel")
        var propertyValues: [CFString: Any] = [
            kVTCompressionPropertyKey_ProfileLevel: profile,
            kVTCompressionPropertyKey_Quality: quality,
            kVTCompressionPropertyKey_AllowTemporalCompression: false,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            "SourceFrameCount" as CFString: columns * rows,
            "AllowPixelTransfer" as CFString: true,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4,
        ]
        if mode == .rgb4448tile {
            propertyValues["QuantizationScalingMatrixPreset" as CFString] = 1
        }
        try check(
            setProperties(session, propertyValues as CFDictionary),
            "setting tile compression properties failed")
        try check(
            prepare(session, 0, nil),
            "VTTileCompressionSessionPrepareToEncodeTiles failed")
        let frameProperties = [:] as CFDictionary
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                let tileRefcon = UnsafeMutableRawPointer(bitPattern: index + 1)
                let originX = column * tileWidth
                let originY = row * tileHeight
                try check(
                    encodeTile(
                        session,
                        source.pixelBuffer,
                        CMVideoDimensions(width: Int32(originX), height: Int32(originY)),
                        CMVideoDimensions(
                            width: Int32(tileWidth), height: Int32(tileHeight)),
                        frameProperties,
                        tileRefcon,
                        nil),
                    "VTTileCompressionSessionEncodeTile failed at tile \(index)")
            }
        }
        try check(complete(session), "VTTileCompressionSessionCompleteTiles failed")
        invalidate(session)
        if let error = state.error {
            throw HelperError.encoding(error)
        }
        if state.samples.contains(where: { $0 == nil }) {
            throw HelperError.encoding("VTTileCompressionSession did not return every tile")
        }
        return state
    }

    // MARK: whole-frame session

    private static let frameCallback: VTCompressionOutputCallback = {
        refcon, _, status, _, sampleBuffer in
        guard let refcon else { return }
        let state = Unmanaged<EncoderState>.fromOpaque(refcon).takeUnretainedValue()
        if status != noErr {
            state.error = "Compression callback status \(status)"
            return
        }
        guard let sampleBuffer else {
            state.error = "Compression callback did not provide a sample buffer"
            return
        }
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            state.error = "Compressed sample buffer is not ready"
            return
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            state.error = "Compressed sample has no format description"
            return
        }
        if state.hvcc.isEmpty,
           let extensions =
            CMFormatDescriptionGetExtensions(formatDescription) as? [String: Any],
           let atoms =
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String]
                as? [String: Any],
           let hvcc = atoms["hvcC"] as? Data {
            state.hvcc = hvcc
        }
        do {
            let nalUnitHeaderLength: Int32
            if !state.wroteParameterSets {
                nalUnitHeaderLength = try appendParameterSets(
                    from: formatDescription, to: &state.annexB)
                state.wroteParameterSets = true
            } else {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                var count = 0
                var headerLength: Int32 = 0
                let psStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDescription,
                    parameterSetIndex: 0,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: &headerLength)
                if psStatus != noErr {
                    throw NSError(
                        domain: "AppleVTEncoder", code: Int(psStatus),
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Could not read HEVC NAL header length"
                        ])
                }
                nalUnitHeaderLength = headerLength
            }
            try appendSampleData(
                sampleBuffer, nalUnitHeaderLength: nalUnitHeaderLength, to: &state.annexB)
        } catch {
            state.error = error.localizedDescription
        }
    }
}
#endif
