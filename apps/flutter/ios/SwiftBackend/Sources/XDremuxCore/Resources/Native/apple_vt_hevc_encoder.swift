#!/usr/bin/env swift
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import VideoToolbox

final class EncoderState {
    var annexB = Data()
    var hvcc = Data()
    var wroteParameterSets = false
    var error: String?
}

enum PixelMode: String {
    case rgb10
    case rgb4448
    case rgb4448tile
    case mono8
    case mono8tile
}

struct SourceFrame {
    let pixelBuffer: CVPixelBuffer
    let width: Int
    let height: Int
}

final class TileEncoderState {
    let lock = NSLock()
    var samples: [Data?]
    var parameterSets = Data()
    var hvcc = Data()
    var error: String?

    init(tileCount: Int) {
        samples = Array(repeating: nil, count: tileCount)
    }
}

typealias VTTileCompressionOutputCallback = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer?,
    CMVideoDimensions,
    CMVideoDimensions,
    OSStatus,
    UInt32,
    CMSampleBuffer?
) -> Void

// These exported VideoToolbox entry points are undocumented and research-only.
typealias VTTileCompressionSessionCreateFunction = @convention(c) (
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

typealias VTTileCompressionSessionSetPropertiesFunction = @convention(c) (
    CFTypeRef,
    CFDictionary
) -> OSStatus

typealias VTTileCompressionSessionPrepareFunction = @convention(c) (
    CFTypeRef,
    UInt32,
    UnsafeMutablePointer<CFTypeRef?>?
) -> OSStatus

typealias VTTileCompressionSessionEncodeTileFunction = @convention(c) (
    CFTypeRef,
    CVPixelBuffer,
    CMVideoDimensions,
    CMVideoDimensions,
    CFDictionary?,
    UnsafeMutableRawPointer?,
    UnsafeMutablePointer<UInt32>?
) -> OSStatus

typealias VTTileCompressionSessionCompleteFunction = @convention(c) (CFTypeRef) -> OSStatus
typealias VTTileCompressionSessionInvalidateFunction = @convention(c) (CFTypeRef) -> Void

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func check(_ status: OSStatus, _ message: String) {
    if status != noErr {
        fail("\(message): OSStatus \(status)")
    }
}

func loadImage(_ path: String) -> CGImage {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("Could not load image: \(path)")
    }
    return image
}

func makePixelBuffer(
    from image: CGImage,
    mode: PixelMode,
    targetWidth: Int? = nil,
    targetHeight: Int? = nil
) -> CVPixelBuffer {
    let width = targetWidth ?? image.width
    let height = targetHeight ?? image.height
    let pixelFormat = mode == .mono8 || mode == .mono8tile
        ? kCVPixelFormatType_OneComponent8
        : kCVPixelFormatType_32BGRA
    let attrs: CFDictionary = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:]
    ] as CFDictionary

    var pixelBuffer: CVPixelBuffer?
    check(
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attrs,
            &pixelBuffer
        ),
        "CVPixelBufferCreate failed"
    )
    guard let buffer = pixelBuffer else {
        fail("CVPixelBufferCreate returned nil")
    }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
        fail("Pixel buffer has no base address")
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let colorSpace = mode == .mono8 || mode == .mono8tile
        ? CGColorSpaceCreateDeviceGray()
        : CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = mode == .mono8 || mode == .mono8tile
        ? CGBitmapInfo(rawValue: 0)
        : CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
    guard let context = CGContext(
        data: baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue
    ) else {
        fail("Could not create CGContext for pixel buffer")
    }
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    // HEIF grids crop padded tiles from the top-left raster origin. Quartz bitmap
    // contexts use a bottom-left drawing origin, so bottom-aligning a short final
    // tile puts the padding at the top and shifts the decoded image downward.
    // Move the source up by the vertical padding so the cropped grid starts at
    // the first source row; horizontal origins already agree.
    context.draw(
        image,
        in: CGRect(
            x: 0,
            y: height - image.height,
            width: image.width,
            height: image.height
        )
    )
    return buffer
}

func makeYUV444Frame(
    from image: CGImage,
    padToTileGrid: Bool = false,
    tileSize: Int = 512
) -> SourceFrame {
    let width = padToTileGrid ? ((image.width + tileSize - 1) / tileSize) * tileSize : image.width
    let height = padToTileGrid ? ((image.height + tileSize - 1) / tileSize) * tileSize : image.height
    let source = makePixelBuffer(
        from: image,
        mode: .rgb10,
        targetWidth: width,
        targetHeight: height
    )
    let attrs: CFDictionary = [
        kCVPixelBufferIOSurfacePropertiesKey: [:]
    ] as CFDictionary
    var pixelBuffer: CVPixelBuffer?
    check(
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
            attrs,
            &pixelBuffer
        ),
        "8-bit YUV444 CVPixelBufferCreate failed"
    )
    guard let destination = pixelBuffer else {
        fail("8-bit YUV444 CVPixelBufferCreate returned nil")
    }
    CVBufferSetAttachment(
        destination,
        kCVImageBufferYCbCrMatrixKey,
        kCVImageBufferYCbCrMatrix_ITU_R_601_4,
        .shouldPropagate
    )
    var transferSession: VTPixelTransferSession?
    check(
        VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault,
            pixelTransferSessionOut: &transferSession
        ),
        "VTPixelTransferSessionCreate failed"
    )
    guard let transferSession else {
        fail("VTPixelTransferSessionCreate returned nil")
    }
    check(
        VTPixelTransferSessionTransferImage(transferSession, from: source, to: destination),
        "BGRA to YUV444 pixel transfer failed"
    )
    VTPixelTransferSessionInvalidate(transferSession)
    return SourceFrame(pixelBuffer: destination, width: width, height: height)
}

func makeSourceFrame(path: String, mode: PixelMode, tileSize: Int = 512) -> SourceFrame {
    let image = loadImage(path)
    if mode == .rgb4448 || mode == .rgb4448tile {
        return makeYUV444Frame(
            from: image,
            padToTileGrid: mode == .rgb4448tile,
            tileSize: tileSize
        )
    }
    if mode == .mono8tile {
        let width = ((image.width + tileSize - 1) / tileSize) * tileSize
        let height = ((image.height + tileSize - 1) / tileSize) * tileSize
        return SourceFrame(
            pixelBuffer: makePixelBuffer(
                from: image,
                mode: mode,
                targetWidth: width,
                targetHeight: height
            ),
            width: width,
            height: height
        )
    }
    return SourceFrame(
        pixelBuffer: makePixelBuffer(from: image, mode: mode),
        width: image.width,
        height: image.height
    )
}

func appendStartCode(_ data: inout Data) {
    data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
}

func appendParameterSets(from formatDescription: CMFormatDescription, to data: inout Data) throws -> Int32 {
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
        nalUnitHeaderLengthOut: &nalUnitHeaderLength
    )
    if firstStatus != noErr {
        throw NSError(domain: "AppleVTEncoder", code: Int(firstStatus), userInfo: [NSLocalizedDescriptionKey: "Could not read HEVC parameter sets"])
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
                nalUnitHeaderLengthOut: &headerLength
            )
            if status != noErr {
                throw NSError(domain: "AppleVTEncoder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not read HEVC parameter set \(index)"])
            }
            if let ptr = pointer, size > 0 {
                appendStartCode(&data)
                data.append(ptr, count: size)
            }
        }
    }
    return nalUnitHeaderLength
}

func appendSampleData(_ sampleBuffer: CMSampleBuffer, nalUnitHeaderLength: Int32, to data: inout Data) throws {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        throw NSError(domain: "AppleVTEncoder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Sample has no block buffer"])
    }
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    let status = CMBlockBufferGetDataPointer(
        blockBuffer,
        atOffset: 0,
        lengthAtOffsetOut: nil,
        totalLengthOut: &totalLength,
        dataPointerOut: &dataPointer
    )
    if status != noErr {
        throw NSError(domain: "AppleVTEncoder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not access compressed sample data"])
    }
    guard let rawPointer = dataPointer else {
        throw NSError(domain: "AppleVTEncoder", code: -2, userInfo: [NSLocalizedDescriptionKey: "Compressed sample data pointer is nil"])
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
            throw NSError(domain: "AppleVTEncoder", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid NAL length in compressed sample"])
        }
        appendStartCode(&data)
        data.append(bytes + offset, count: nalLength)
        offset += nalLength
    }
}

func videoToolboxSymbol<T>(_ symbolName: String, as type: T.Type) -> T {
    let frameworkPath = "/System/Library/Frameworks/VideoToolbox.framework/Versions/A/VideoToolbox"
    guard let handle = dlopen(frameworkPath, RTLD_LAZY),
          let symbol = dlsym(handle, symbolName) else {
        fail("VideoToolbox symbol is unavailable: \(symbolName)")
    }
    return unsafeBitCast(symbol, to: type)
}

func dynamicallyLoadedProfile(_ symbolName: String) -> CFString {
    let symbol = videoToolboxSymbol(
        symbolName,
        as: UnsafePointer<Optional<CFString>>.self
    )
    guard let value = symbol.pointee else {
        fail("VideoToolbox profile symbol is nil: \(symbolName)")
    }
    return value
}

let tileCallback: VTTileCompressionOutputCallback = {
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
                from: formatDescription,
                to: &state.parameterSets
            )
            if let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [String: Any],
               let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String]
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
                nalUnitHeaderLengthOut: &headerLength
            )
            guard parameterStatus == noErr else {
                throw NSError(
                    domain: "AppleVTTileEncoder",
                    code: Int(parameterStatus),
                    userInfo: [NSLocalizedDescriptionKey: "Could not read tile NAL header length"]
                )
            }
            nalUnitHeaderLength = headerLength
        }
        var sampleData = Data()
        try appendSampleData(
            sampleBuffer,
            nalUnitHeaderLength: nalUnitHeaderLength,
            to: &sampleData
        )
        state.samples[index] = sampleData
    } catch {
        state.error = error.localizedDescription
    }
}

func encodeWithTileSession(
    source: SourceFrame,
    quality: Double,
    mode: PixelMode,
    tileSize: Int
) -> TileEncoderState {
    let tileWidth = tileSize
    let tileHeight = tileSize
    let columns = (source.width + tileWidth - 1) / tileWidth
    let rows = (source.height + tileHeight - 1) / tileHeight
    let state = TileEncoderState(tileCount: columns * rows)
    let create = videoToolboxSymbol(
        "VTTileCompressionSessionCreate",
        as: VTTileCompressionSessionCreateFunction.self
    )
    let setProperties = videoToolboxSymbol(
        "VTTileCompressionSessionSetProperties",
        as: VTTileCompressionSessionSetPropertiesFunction.self
    )
    let prepare = videoToolboxSymbol(
        "VTTileCompressionSessionPrepareToEncodeTiles",
        as: VTTileCompressionSessionPrepareFunction.self
    )
    let encodeTile = videoToolboxSymbol(
        "VTTileCompressionSessionEncodeTile",
        as: VTTileCompressionSessionEncodeTileFunction.self
    )
    let complete = videoToolboxSymbol(
        "VTTileCompressionSessionCompleteTiles",
        as: VTTileCompressionSessionCompleteFunction.self
    )
    let invalidate = videoToolboxSymbol(
        "VTTileCompressionSessionInvalidate",
        as: VTTileCompressionSessionInvalidateFunction.self
    )
    let encoderSpecification: CFDictionary = [
        kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
    ] as CFDictionary
    let imageBufferAttributes: CFDictionary = [
        kCVPixelBufferPixelFormatTypeKey: CVPixelBufferGetPixelFormatType(source.pixelBuffer),
    ] as CFDictionary
    var session: CFTypeRef?
    check(
        create(
            kCFAllocatorDefault,
            CMVideoDimensions(width: Int32(tileWidth), height: Int32(tileHeight)),
            kCMVideoCodecType_HEVC,
            encoderSpecification,
            imageBufferAttributes,
            kCFAllocatorDefault,
            tileCallback,
            Unmanaged.passUnretained(state).toOpaque(),
            &session
        ),
        "VTTileCompressionSessionCreate failed"
    )
    guard let session else {
        fail("VTTileCompressionSessionCreate returned nil")
    }
    let profile: CFString = mode == .mono8tile
        ? kVTProfileLevel_HEVC_Monochrome_AutoLevel
        : dynamicallyLoadedProfile("kVTProfileLevel_HEVC_Main444_AutoLevel")
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
    check(
        setProperties(session, propertyValues as CFDictionary),
        "setting tile compression properties failed"
    )
    check(
        prepare(session, 0, nil),
        "VTTileCompressionSessionPrepareToEncodeTiles failed"
    )
    let frameProperties = [:] as CFDictionary
    for row in 0..<rows {
        for column in 0..<columns {
            let index = row * columns + column
            let tileRefcon = UnsafeMutableRawPointer(bitPattern: index + 1)
            let originX = column * tileWidth
            let originY = row * tileHeight
            check(
                encodeTile(
                    session,
                    source.pixelBuffer,
                    CMVideoDimensions(
                        width: Int32(originX),
                        height: Int32(originY)
                    ),
                    CMVideoDimensions(width: Int32(tileWidth), height: Int32(tileHeight)),
                    frameProperties,
                    tileRefcon,
                    nil
                ),
                "VTTileCompressionSessionEncodeTile failed at tile \(index)"
            )
        }
    }
    check(complete(session), "VTTileCompressionSessionCompleteTiles failed")
    invalidate(session)
    if let error = state.error {
        fail(error)
    }
    if state.samples.contains(where: { $0 == nil }) {
        fail("VTTileCompressionSession did not return every tile")
    }
    return state
}

let callback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
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
       let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [String: Any],
       let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String]
            as? [String: Any],
       let hvcc = atoms["hvcC"] as? Data {
        state.hvcc = hvcc
    }
    do {
        let nalUnitHeaderLength: Int32
        if !state.wroteParameterSets {
            nalUnitHeaderLength = try appendParameterSets(from: formatDescription, to: &state.annexB)
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
                nalUnitHeaderLengthOut: &headerLength
            )
            if psStatus != noErr {
                throw NSError(domain: "AppleVTEncoder", code: Int(psStatus), userInfo: [NSLocalizedDescriptionKey: "Could not read HEVC NAL header length"])
            }
            nalUnitHeaderLength = headerLength
        }
        try appendSampleData(sampleBuffer, nalUnitHeaderLength: nalUnitHeaderLength, to: &state.annexB)
    } catch {
        state.error = error.localizedDescription
    }
}

let args = CommandLine.arguments
if args.count < 3 || args.count > 7 {
    fail(
        "usage: apple_vt_hevc_encoder.swift input output.hevc "
            + "[quality] [rgb10|rgb4448|rgb4448tile|mono8|mono8tile] [output.hvcc] [tile-size]"
    )
}

let quality: Double
if args.count >= 4 {
    guard let parsedQuality = Double(args[3]), parsedQuality > 0.0, parsedQuality <= 1.0 else {
        fail("quality must be in the range (0.0, 1.0]")
    }
    quality = parsedQuality
} else {
    quality = 0.45
}

let mode: PixelMode
if args.count >= 5 {
    guard let parsedMode = PixelMode(rawValue: args[4]) else {
        fail("pixel mode must be rgb10, rgb4448, rgb4448tile, mono8, or mono8tile")
    }
    mode = parsedMode
} else {
    mode = .rgb10
}
let hvccOutputPath = args.count >= 6 ? args[5] : nil
let tileSize: Int
if args.count >= 7 {
    guard let parsedTileSize = Int(args[6]), [256, 512, 1024].contains(parsedTileSize) else {
        fail("tile size must be 256, 512, or 1024")
    }
    tileSize = parsedTileSize
} else {
    tileSize = 512
}

let source = makeSourceFrame(path: args[1], mode: mode, tileSize: tileSize)
let pixelBuffer = source.pixelBuffer
if mode == .rgb4448tile || mode == .mono8tile {
    let tileState = encodeWithTileSession(
        source: source,
        quality: quality,
        mode: mode,
        tileSize: tileSize
    )
    var annexB = tileState.parameterSets
    for sample in tileState.samples {
        annexB.append(sample!)
    }
    if annexB.isEmpty {
        fail("VTTileCompressionSession produced no HEVC data")
    }
    try annexB.write(to: URL(fileURLWithPath: args[2]))
    if let hvccOutputPath {
        if tileState.hvcc.isEmpty {
            fail("VTTileCompressionSession format description did not expose an hvcC atom")
        }
        try tileState.hvcc.write(to: URL(fileURLWithPath: hvccOutputPath))
    }
    exit(0)
}
let state = EncoderState()

let imageBufferAttributes: CFDictionary = [
    kCVPixelBufferPixelFormatTypeKey: CVPixelBufferGetPixelFormatType(pixelBuffer),
    kCVPixelBufferWidthKey: source.width,
    kCVPixelBufferHeightKey: source.height,
    kCVPixelBufferIOSurfacePropertiesKey: [:],
] as CFDictionary

var session: VTCompressionSession?
check(
    VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        width: Int32(source.width),
        height: Int32(source.height),
        codecType: kCMVideoCodecType_HEVC,
        encoderSpecification: nil,
        imageBufferAttributes: imageBufferAttributes,
        compressedDataAllocator: nil,
        outputCallback: callback,
        refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(state).toOpaque()),
        compressionSessionOut: &session
    ),
    "VTCompressionSessionCreate failed"
)
guard let session else {
    fail("VTCompressionSessionCreate returned nil")
}

let profile: CFString
switch mode {
case .mono8, .mono8tile:
    profile = kVTProfileLevel_HEVC_Monochrome_AutoLevel
case .rgb4448, .rgb4448tile:
    profile = dynamicallyLoadedProfile("kVTProfileLevel_HEVC_Main444_AutoLevel")
case .rgb10:
    profile = kVTProfileLevel_HEVC_Main10_AutoLevel
}
check(
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile),
    "setting HEVC profile failed"
)
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 1 as CFTypeRef)
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1 as CFTypeRef)
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: quality as CFTypeRef)
if mode == .rgb4448 {
    check(
        VTSessionSetProperty(
            session,
            key: "QuantizationScalingMatrixPreset" as CFString,
            value: 1 as CFTypeRef
        ),
        "setting HEVC 4:4:4 quantization matrix failed"
    )
}
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_601_4)

check(VTCompressionSessionPrepareToEncodeFrames(session), "VTCompressionSessionPrepareToEncodeFrames failed")
let frameProperties: CFDictionary = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
check(
    VTCompressionSessionEncodeFrame(
        session,
        imageBuffer: pixelBuffer,
        presentationTimeStamp: CMTime(value: 0, timescale: 1),
        duration: CMTime(value: 1, timescale: 1),
        frameProperties: frameProperties,
        sourceFrameRefcon: nil,
        infoFlagsOut: nil
    ),
    "VTCompressionSessionEncodeFrame failed"
)
check(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), "VTCompressionSessionCompleteFrames failed")
VTCompressionSessionInvalidate(session)

if let error = state.error {
    fail(error)
}
if state.annexB.isEmpty {
    fail("VideoToolbox produced no HEVC data")
}
try state.annexB.write(to: URL(fileURLWithPath: args[2]))
if let hvccOutputPath {
    if state.hvcc.isEmpty {
        fail("VideoToolbox format description did not expose an hvcC atom")
    }
    try state.hvcc.write(to: URL(fileURLWithPath: hvccOutputPath))
}
