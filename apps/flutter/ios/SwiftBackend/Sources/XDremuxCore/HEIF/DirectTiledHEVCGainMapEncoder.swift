import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

package struct DirectTiledHEVCGainMap: Sendable {
    package let width: Int
    package let height: Int
    package let tileWidth: Int
    package let tileHeight: Int
    package let tilePayloads: [Data]
    package let tileSizes: [(width: Int, height: Int)]
    package let hvcC: Data
    package let channelCount: Int
}

package enum DirectTiledHEVCGainMapEncoder {
    #if canImport(UIKit)
    /// iOS: the macOS build compiles and runs the `apple_vt_hevc_encoder`
    /// helper executable (Process + xcrun swiftc), which cannot exist on
    /// iOS. The host app instead installs an in-process VideoToolbox
    /// encoder here. It receives the PNG (1ch) / JPEG (3ch) bridge image
    /// and encode parameters, and returns the full Annex-B IDR stream plus
    /// hvcC - the same contract as the helper's file outputs. The IDR tile
    /// splitting and tile-count validation below are reused unchanged.
    package typealias InProcessGainMapEncoder = (
        _ imageData: Data,
        _ width: Int,
        _ height: Int,
        _ channelCount: Int,
        _ tileSize: Int,
        _ quality: Double
    ) throws -> (annexB: Data, hvcC: Data)

    package static var inProcessEncoder: InProcessGainMapEncoder?
    #endif

    #if !canImport(UIKit)
    private struct ProcessResult {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    private static let compileLock = NSLock()

    package static func helperExecutable() throws -> URL {
        try encoderExecutable()
    }
    #endif

    package static func encode(
        imageData: Data,
        width: Int,
        height: Int,
        channelCount: Int,
        scratchBaseURL: URL
    ) throws -> DirectTiledHEVCGainMap {
        guard width > 0, height > 0, channelCount == 1 || channelCount == 3 else {
            throw CLIError.invalidContainer("direct Gain Map encoder received invalid raster geometry")
        }
        let tileSize = EncodingQualityPolicy.integer(
            environmentKey: "XDREMUX_GAIN_MAP_TILE_SIZE",
            defaultValue: 512,
            allowedValues: [256, 512, 1024]
        )
        let tileWidth = tileSize
        let tileHeight = tileSize
        let imageURL = siblingURL(
            for: scratchBaseURL,
            label: "direct-gain",
            pathExtension: channelCount == 1 ? "png" : "jpg"
        )
        let annexBURL = siblingURL(for: scratchBaseURL, label: "direct-gain", pathExtension: "hevc")
        let hvcCURL = siblingURL(for: scratchBaseURL, label: "direct-gain", pathExtension: "hvcc")
        defer {
            let environment = ProcessInfo.processInfo.environment
            if environment["XDREMUX_KEEP_GAIN_SCRATCH"] != "1"
                && environment["XDREMUX_KEEP_PORTRAIT_SCRATCH"] != "1" {
                for url in [imageURL, annexBURL, hvcCURL] {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        try imageData.write(to: imageURL, options: .atomic)
        let mode = channelCount == 1 ? "mono8tile" : "rgb4448tile"
        let quality = EncodingQualityPolicy.value(
            environmentKey: "XDREMUX_GAIN_MAP_QUALITY",
            defaultValue: 0.9
        )
        let tilePayloads: [Data]
        let hvcC: Data
        #if canImport(UIKit)
        guard let encoder = inProcessEncoder else {
            throw CLIError.invalidContainer(
                "iOS build has no in-process Gain Map encoder installed")
        }
        let encoded = try encoder(imageData, width, height, channelCount, tileSize, quality)
        tilePayloads = try idrTilePayloads(from: encoded.annexB)
        hvcC = encoded.hvcC
        let columns = (width + tileWidth - 1) / tileWidth
        let rows = (height + tileHeight - 1) / tileHeight
        guard tilePayloads.count == rows * columns else {
            throw CLIError.invalidContainer(
                "private tile encoder returned \(tilePayloads.count) samples; expected \(rows * columns)"
            )
        }
        #else
        let executable = try encoderExecutable()
        let result = try run(
            executable,
            arguments: [
                imageURL.path,
                annexBURL.path,
                String(format: "%.6f", quality),
                mode,
                hvcCURL.path,
                String(tileSize),
            ]
        )
        guard result.status == 0 else {
            let diagnostic = String(data: result.stderr + result.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw CLIError.invalidContainer("private tile encoder failed: \(diagnostic)")
        }
        tilePayloads = try idrTilePayloads(from: Data(contentsOf: annexBURL))
        hvcC = try Data(contentsOf: hvcCURL)
        let columns = (width + tileWidth - 1) / tileWidth
        let rows = (height + tileHeight - 1) / tileHeight
        guard tilePayloads.count == rows * columns else {
            throw CLIError.invalidContainer(
                "private tile encoder returned \(tilePayloads.count) samples; expected \(rows * columns)"
            )
        }
        #endif
        return DirectTiledHEVCGainMap(
            width: width,
            height: height,
            tileWidth: tileWidth,
            tileHeight: tileHeight,
            tilePayloads: tilePayloads,
            tileSizes: Array(repeating: (tileWidth, tileHeight), count: tilePayloads.count),
            hvcC: hvcC,
            channelCount: channelCount
        )
    }

    package static func encode(
        raster: GainMapRaster,
        scratchBaseURL: URL
    ) throws -> DirectTiledHEVCGainMap {
        let isColor = raster.channelCount == 3
        guard let provider = CGDataProvider(data: raster.data as CFData),
              let image = CGImage(
                  width: raster.width,
                  height: raster.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: isColor ? 32 : 8,
                  bytesPerRow: raster.bytesPerRow,
                  space: isColor ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(
                      rawValue: isColor
                          ? CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
                          : CGImageAlphaInfo.none.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw CLIError.invalidContainer("cannot materialize direct Gain Map raster")
        }
        let imageData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            imageData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CLIError.invalidContainer("cannot create direct Gain Map PNG bridge")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CLIError.invalidContainer("cannot finalize direct Gain Map PNG bridge")
        }
        return try encode(
            imageData: imageData as Data,
            width: raster.width,
            height: raster.height,
            channelCount: raster.channelCount,
            scratchBaseURL: scratchBaseURL
        )
    }

    private static func idrTilePayloads(from annexB: Data) throws -> [Data] {
        let bytes = [UInt8](annexB)
        var starts: [(offset: Int, length: Int)] = []
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1 {
                starts.append((index, 4))
                index += 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index, 3))
                index += 3
            } else {
                index += 1
            }
        }
        var payloads: [Data] = []
        for position in starts.indices {
            let start = starts[position].offset + starts[position].length
            let end = position + 1 < starts.count ? starts[position + 1].offset : bytes.count
            guard start < end else { continue }
            let type = (bytes[start] >> 1) & 0x3f
            guard type == 19 || type == 20 else { continue }
            var payload = Data()
            appendUInt32BE(end - start, to: &payload)
            payload.append(contentsOf: bytes[start..<end])
            payloads.append(payload)
        }
        guard !payloads.isEmpty else {
            throw CLIError.invalidContainer("private tile encoder emitted no HEVC IDR samples")
        }
        return payloads
    }

    private static func siblingURL(for base: URL, label: String, pathExtension: String) -> URL {
        base.deletingLastPathComponent().appendingPathComponent(
            ".xdremux-\(label)-\(UUID().uuidString).\(pathExtension)"
        )
    }

    #if !canImport(UIKit)
    private static func encoderExecutable() throws -> URL {
        let source = try resourceURL(name: "apple_vt_hevc_encoder.swift")
        let sourceData = try Data(contentsOf: source, options: [.mappedIfSafe])
        var cacheIdentity = sourceData
        cacheIdentity.append(contentsOf: "swiftc\u{0}-O\u{0}<source>".utf8)
        let sourceHash = sha256Hex(cacheIdentity)
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw CLIError.invalidContainer("cannot resolve the user cache directory")
        }
        let directory = caches
            .appendingPathComponent("com.proxdr.XDRemux", isDirectory: true)
            .appendingPathComponent("AppleNativeTools", isDirectory: true)
            .appendingPathComponent(sourceHash, isDirectory: true)
        let executable = directory.appendingPathComponent("apple-vt-hevc-encoder")

        compileLock.lock()
        defer { compileLock.unlock() }
        if FileManager.default.isExecutableFile(atPath: executable.path) {
            return executable
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try run(
            URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swiftc", "-O", source.path, "-o", executable.path]
        )
        guard result.status == 0, FileManager.default.isExecutableFile(atPath: executable.path) else {
            let diagnostic = String(data: result.stderr, encoding: .utf8) ?? "unknown compiler error"
            throw CLIError.invalidContainer(
                "cannot build apple-vt-hevc-encoder: "
                    + diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return executable
    }

    private static func resourceURL(name: String) throws -> URL {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["XDREMUX_CORE_NATIVE_ROOT"] {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent(name))
        }
        if let override = ProcessInfo.processInfo.environment["XDREMUX_APPLE_PLATFORM_ROOT"] {
            candidates.append(
                URL(fileURLWithPath: override, isDirectory: true)
                    .appendingPathComponent("Native", isDirectory: true)
                    .appendingPathComponent(name)
            )
        }
        if let resources = Bundle.module.resourceURL {
            candidates.append(
                resources.appendingPathComponent("Native", isDirectory: true).appendingPathComponent(name)
            )
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(
                resources.appendingPathComponent("Native", isDirectory: true).appendingPathComponent(name)
            )
        }
        if let match = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return match
        }
        throw CLIError.invalidContainer("missing XDRemux native Gain Map encoder resource \(name)")
    }

    private static func run(_ executableURL: URL, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw CLIError.invalidContainer(
                "cannot launch Gain Map helper \(executableURL.lastPathComponent): \(error)"
            )
        }
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }    #endif

}
