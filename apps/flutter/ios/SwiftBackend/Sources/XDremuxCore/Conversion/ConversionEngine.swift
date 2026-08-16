import Foundation
import CoreGraphics
import CoreVideo
import Darwin
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

package enum XDRemuxProductCore {
    private static let fileManager = FileManager.default

    package static func convert(
        inputURL: URL,
        outputURL: URL,
        familyPreference: Family,
        debugRootURL: URL?,
        oppoCompatibility: OppoCompatibility = .off,
        inputProcessingBranch: InputProcessingBranch = .hybrid,
        oppoCameraTail: OppoCameraTail = .preserveWithoutPrivateHDR,
        tmapFormat: TmapFormat = .imageIO,
        eventHandler: ConversionEventHandler? = nil
    ) throws -> SampleReport {
        guard fileManager.fileExists(atPath: inputURL.path) else {
            throw CLIError.inputNotFound(inputURL)
        }

        let parentURL = outputURL.deletingLastPathComponent()
        try ensureDirectory(parentURL, fileManager: fileManager)

        let sourceData: Data
        do {
            sourceData = try Data(contentsOf: inputURL, options: [.mappedIfSafe])
        } catch {
            throw CLIError.unableToRead(inputURL)
        }

        try rejectLossyGainMapPromotion(inputURL: inputURL, compatibility: oppoCompatibility)
        let productInput = try prepareProductInput(
            inputURL: inputURL,
            sourceData: sourceData,
            familyPreference: familyPreference
        )
        let debugDirURL = try writeDiagnosticsIfRequested(
            debugRootURL: debugRootURL,
            inputURL: inputURL,
            productInput: productInput
        )
        let actualOutputURL = temporaryOutputURLIfNeeded(inputURL: inputURL, outputURL: outputURL)
        let writesInPlace = actualOutputURL != outputURL
        defer {
            if writesInPlace {
                try? fileManager.removeItem(at: actualOutputURL)
            }
        }

        // OPPO metadata preservation requires the source-primary graft path. ImageIO's
        // direct writer and the experimental passthrough writer may normalize or omit
        // non-HDR HEIF items before the selected camera tail is restored.
        let effectiveInputProcessingBranch: InputProcessingBranch = (
            oppoCameraTail == .preserve
                || oppoCameraTail == .preserveWithoutPortrait
                || oppoCameraTail == .preserveWithoutPortraitOrPrivateHDR
                || oppoCameraTail == .preserveWithoutPrivateUHDR
                || oppoCameraTail == .preserveWithoutPrivateHDR
                || tmapFormat == .strict
        )
            ? .hybrid
            : inputProcessingBranch
        try ProductGainMapWriter.write(
            inputURL: inputURL,
            outputURL: actualOutputURL,
            sourceData: sourceData,
            productInput: productInput,
            oppoCompatibility: oppoCompatibility,
            inputProcessingBranch: effectiveInputProcessingBranch,
            strictISO21496: tmapFormat == .strict,
            eventHandler: eventHandler
        )
        try restoreOppoUserCommentFromSource(
            outputURL: actualOutputURL,
            sourceData: sourceData,
            compatibility: oppoCompatibility
        )
        try appendOppoCameraTailIfNeeded(
            outputURL: actualOutputURL,
            sourceData: sourceData,
            extracted: productInput.extracted,
            mode: oppoCameraTail
        )
        guard gainMapEncodingMatchesTarget(at: actualOutputURL, compatibility: oppoCompatibility) else {
            throw CLIError.invalidContainer("output Gain Map encoding does not match the selected compatibility target")
        }

        if writesInPlace {
            _ = try fileManager.replaceItemAt(outputURL, withItemAt: actualOutputURL)
        }

        return SampleReport(
            inputURL: inputURL,
            outputURL: outputURL,
            family: productInput.effectiveFamily,
            scale: productInput.scale,
            gainMapParams: productInput.params,
            debugDirURL: debugDirURL
        )
    }

    struct ProductInput {
        let extracted: ExtractedLHDR
        let detectedFamily: Family
        let effectiveFamily: Family
        let scale: ResolvedScale
        let maskRaster: GainMapRaster
        let gainMapRaster: GainMapRaster
        let params: GainMapParams
        let style: HDRToneMapStyle
    }

    private static func prepareProductInput(
        inputURL: URL,
        sourceData: Data,
        familyPreference: Family
    ) throws -> ProductInput {
        let extracted = try LHDRExtractor.extract(from: sourceData)
        let detectedFamily = detectFamily(from: extracted)
        let effectiveFamily = familyPreference == .auto ? detectedFamily : familyPreference
        let scale = try EDRScaleResolver.resolve(metaFloats: extracted.metaFloats, mode: extracted.mode)
        let decoderChannels = extracted.mode == .uhdr ? 3 : 1
        let maskRaster = try MaskDecoder.decodeMaskJPEG(
            extracted.maskJPEGData,
            sourceURL: inputURL,
            channelCount: decoderChannels
        )
        let gainMap = try buildProductGainMap(
            extracted: extracted,
            maskRaster: maskRaster,
            family: effectiveFamily,
            scale: scale
        )

        return ProductInput(
            extracted: extracted,
            detectedFamily: detectedFamily,
            effectiveFamily: effectiveFamily,
            scale: scale,
            maskRaster: maskRaster,
            gainMapRaster: gainMap.raster,
            params: gainMap.params,
            style: makeHDRToneMapStyle(from: scale)
        )
    }

    private static func detectFamily(from extracted: ExtractedLHDR) -> Family {
        if extracted.mode == .uhdr {
            return .x7
        }
        return extracted.metaFloats[0] >= 3.0 ? .x7 : .x6
    }

    private static func buildProductGainMap(
        extracted: ExtractedLHDR,
        maskRaster: GainMapRaster,
        family: Family,
        scale: ResolvedScale
    ) throws -> (raster: GainMapRaster, params: GainMapParams) {
        if extracted.mode == .uhdr {
            return (
                maskRaster,
                GainMapParams(
                    family: family,
                    knee: 0,
                    kneeRange: 1,
                    headroomScale: 0,
                    maxBoost: 0,
                    log2Scale: 0,
                    kneeSource: "uhdr_precomputed_skip_reconstruction"
                )
            )
        }
        return try GainMapReconstructor.reconstruct(
            mask: maskRaster,
            family: family,
            scale: scale,
            metaFloats: extracted.metaFloats
        )
    }

    private static func makeHDRToneMapStyle(from scale: ResolvedScale) -> HDRToneMapStyle {
        HDRToneMapStyle(
            version: 1,
            baseHeadroom: scale.baseHeadroom,
            alternateHeadroom: scale.alternateHeadroom,
            baseColorIsWorkingColor: false,
            gainMapMin: scale.gainMapMin,
            gainMapMax: scale.gainMapMax,
            gamma: scale.gamma,
            baseOffset: scale.epsilonSdr,
            alternateOffset: scale.epsilonHdr,
            channelCount: scale.channelCount,
            perChannelGainMapMin: scale.perChannelGainMapMin,
            perChannelGainMapMax: scale.perChannelGainMapMax,
            perChannelGamma: scale.perChannelGamma,
            perChannelBaseOffset: scale.perChannelBaseOffset,
            perChannelAlternateOffset: scale.perChannelAlternateOffset
        )
    }

    private static func writeDiagnosticsIfRequested(
        debugRootURL: URL?,
        inputURL: URL,
        productInput: ProductInput
    ) throws -> URL? {
        guard let debugRootURL else { return nil }
        let dir = debugRootURL.appendingPathComponent(inputURL.deletingPathExtension().lastPathComponent, isDirectory: true)
        try DebugWriter.writeArtifacts(
            extracted: productInput.extracted,
            inputURL: inputURL,
            debugDirURL: dir,
            familyDetected: productInput.detectedFamily,
            familyUsed: productInput.effectiveFamily,
            maskRaster: productInput.maskRaster,
            gainMapRaster: productInput.gainMapRaster,
            scale: productInput.scale,
            params: productInput.params,
            style: productInput.style
        )
        return dir
    }

    private static func temporaryOutputURLIfNeeded(inputURL: URL, outputURL: URL) -> URL {
        guard inputURL.standardizedFileURL.path == outputURL.standardizedFileURL.path else {
            return outputURL
        }
        return outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).xdremux-\(UUID().uuidString)")
    }
}

public enum ConversionEngine {
    public static func convert(_ request: ConversionRequest) throws -> ConversionResult {
        let config = request.configuration
        guard !config.appleFeaturesEnabled else {
            throw XDRemuxError.invalidValue(
                option: config.applePhotographicStyles
                    ? "--apple-photographic-styles"
                    : "--apple-portrait",
                value: "Apple features must be converted by XDRemuxAppleFeatures"
            )
        }
        _ = try XDRemuxProductCore.convert(
            inputURL: request.input.url,
            outputURL: request.output.url,
            familyPreference: config.family,
            debugRootURL: config.debugDirectory,
            oppoCompatibility: config.oppoCompatibility,
            inputProcessingBranch: config.inputProcessingBranch,
            oppoCameraTail: config.oppoCameraTail,
            tmapFormat: config.tmapFormat,
            eventHandler: config.eventHandler
        )
        return ConversionResult(input: request.input, output: request.output)
    }

    public static func convert(
        inputURL: URL,
        outputURL: URL,
        config: ConversionConfiguration
    ) throws {
        _ = try convert(
            ConversionRequest(
                input: InputSource(url: inputURL),
                output: OutputDestination(url: outputURL),
                configuration: config
            )
        )
    }

    public static func isValidISOGainMapOutput(_ outputURL: URL) -> Bool {
        (try? verifyImageIOISOGainMap(outputURL)) != nil
    }

    public static func isValidOutput(
        _ outputURL: URL,
        config: ConversionConfiguration
    ) -> Bool {
        if config.appleFeaturesEnabled { return false }
        return isValidProductOutput(
            outputURL,
            oppoCameraTail: config.oppoCameraTail,
            oppoCompatibility: config.oppoCompatibility
        )
    }
}

package enum ProductGainMapWriter {
    static func write(
        inputURL: URL,
        outputURL: URL,
        sourceData: Data,
        productInput: XDRemuxProductCore.ProductInput,
        oppoCompatibility: OppoCompatibility,
        inputProcessingBranch: InputProcessingBranch,
        strictISO21496: Bool,
        eventHandler: ConversionEventHandler?
    ) throws {
        switch inputProcessingBranch {
        case .system, .systemDecoded:
            let writerInput = gainMapWriterInput(
                productInput: productInput,
                oppoCompatibility: oppoCompatibility
            )
            try ISOHDRWriter.write(
                baseImageURL: inputURL,
                gainMap: writerInput.gainMap,
                style: writerInput.style,
                outputURL: outputURL,
                oppoCompatibility: oppoCompatibility,
                inputProcessingBranch: inputProcessingBranch,
                eventHandler: eventHandler
            )
        case .hybrid:
            try HybridGainMapWriter.write(
                inputURL: inputURL,
                outputURL: outputURL,
                sourceData: sourceData,
                productInput: productInput,
                oppoCompatibility: oppoCompatibility,
                strictISO21496: strictISO21496,
                eventHandler: eventHandler
            )
        case .passthrough:
            try DirectPassthroughGainMapWriter.write(
                inputURL: inputURL,
                outputURL: outputURL,
                sourceData: sourceData,
                productInput: productInput,
                oppoCompatibility: oppoCompatibility,
                eventHandler: eventHandler
            )
        }
    }
}

func gainMapWriterInput(
    productInput: XDRemuxProductCore.ProductInput,
    oppoCompatibility: OppoCompatibility
) -> (gainMap: GainMapRaster, style: HDRToneMapStyle) {
    guard productInput.extracted.mode == .lhdr, oppoCompatibility.wantsOppoCompat else {
        return (productInput.gainMapRaster, productInput.style)
    }
    return (
        productInput.gainMapRaster.replicatingLumaToRGB(),
        productInput.style.replicatingMonochromeToRGB()
    )
}

package enum HybridGainMapWriter {
    static func write(
        inputURL: URL,
        outputURL: URL,
        sourceData: Data,
        productInput: XDRemuxProductCore.ProductInput,
        oppoCompatibility: OppoCompatibility,
        strictISO21496: Bool,
        eventHandler: ConversionEventHandler?
    ) throws {
        try writeImageIOPreservedGainMapPassthrough(
            inputURL: inputURL,
            outputURL: outputURL,
            sourceData: sourceData,
            productInput: productInput,
            oppoCompatibility: oppoCompatibility,
            temporaryLabel: "hybrid",
            strictISO21496: strictISO21496,
            eventHandler: eventHandler
        )
    }
}

package enum DirectPassthroughGainMapWriter {
    static func write(
        inputURL: URL,
        outputURL: URL,
        sourceData: Data,
        productInput: XDRemuxProductCore.ProductInput,
        oppoCompatibility: OppoCompatibility,
        eventHandler: ConversionEventHandler?
    ) throws {
        if oppoCompatibility.wantsOppoCompat && productInput.extracted.mode != .uhdr {
            try writeImageIOPreservedGainMapPassthrough(
                inputURL: inputURL,
                outputURL: outputURL,
                sourceData: sourceData,
                productInput: productInput,
                oppoCompatibility: oppoCompatibility,
                temporaryLabel: "passthrough-oppo",
                eventHandler: eventHandler
            )
            return
        }

        let patchedUserComment = adjustedOppoUserComment(in: sourceData, compatibility: oppoCompatibility)
        let tmapPayload: Data? = oppoCompatibility.wantsOppoCompat && productInput.extracted.mode == .uhdr
            ? makeImageIONativeTmapPayload(infoFloats: productInput.extracted.metaFloats)
            : nil
        let tmapColorBox: Data? = tmapPayload == nil ? nil : isoColrBT2020PQBox
        _ = try writePrivateJPEGPassthroughOutput(
            inputURL: inputURL,
            outputURL: outputURL,
            infoFloats: privateGainMapInfoFloats(for: productInput),
            gainMapJPEG: productInput.extracted.maskJPEGData,
            patchedUserComment: patchedUserComment,
            tmapPayload: tmapPayload,
            tmapColorBox: tmapColorBox
        )
        try verifyImageIOISOGainMap(outputURL)
    }

}

private func privateGainMapInfoFloats(
    for productInput: XDRemuxProductCore.ProductInput
) -> [Double] {
    if productInput.extracted.mode == .uhdr {
        return productInput.extracted.metaFloats
    }
    return makePrivateGainMapInfoFloats(scale: productInput.scale)
}

private func writeDirectNativeGainMapPreservingPrimary(
    inputURL: URL,
    outputURL: URL,
    sourceData: Data,
    productInput: XDRemuxProductCore.ProductInput,
    eventHandler: ConversionEventHandler?
) throws {
    let parent = outputURL.deletingLastPathComponent()
    let stem = outputURL.deletingPathExtension().lastPathComponent
    let jpegGraphURL = parent.appendingPathComponent(
        ".\(stem).direct-jpeg-graph-\(UUID().uuidString).heic"
    )
    defer { try? FileManager.default.removeItem(at: jpegGraphURL) }

    let encoded: DirectTiledHEVCGainMap
    switch productInput.extracted.mode {
    case .uhdr:
        let size = try jpegImageSize(productInput.extracted.maskJPEGData)
        encoded = try DirectTiledHEVCGainMapEncoder.encode(
            imageData: productInput.extracted.maskJPEGData,
            width: size.0,
            height: size.1,
            channelCount: 3,
            scratchBaseURL: outputURL
        )
    case .lhdr:
        encoded = try DirectTiledHEVCGainMapEncoder.encode(
            raster: productInput.gainMapRaster,
            scratchBaseURL: outputURL
        )
    }
    _ = try writePrivateJPEGPassthroughOutput(
        inputURL: inputURL,
        outputURL: jpegGraphURL,
        infoFloats: privateGainMapInfoFloats(for: productInput),
        gainMapJPEG: productInput.extracted.maskJPEGData,
        patchedUserComment: adjustedOppoUserComment(in: sourceData, compatibility: .off)
    )
    try replacePrivateJPEGGainMapWithHEVCTiles(
        inputURL: jpegGraphURL,
        outputURL: outputURL,
        gainMapWidth: encoded.width,
        gainMapHeight: encoded.height,
        tileWidth: encoded.tileWidth,
        tileHeight: encoded.tileHeight,
        tilePayloads: encoded.tilePayloads,
        tileSizes: encoded.tileSizes,
        hvcC: encoded.hvcC,
        channelCount: encoded.channelCount
    )
    try verifyImageIOISOGainMap(outputURL)
    let gainQuality = EncodingQualityPolicy.value(
        environmentKey: "XDREMUX_GAIN_MAP_QUALITY",
        defaultValue: 0.9
    )
    eventHandler?(.diagnostic(
        "[direct-gain] preserved compressed Base; encoded \(encoded.tilePayloads.count) Gain Map tiles once "
            + "quality=\(String(format: "%.2f", gainQuality)) "
            + "tile=\(encoded.tileWidth)x\(encoded.tileHeight)"
    ))
}

func writeImageIOPreservedGainMapPassthrough(
    inputURL: URL,
    outputURL: URL,
    sourceData: Data,
    productInput: XDRemuxProductCore.ProductInput,
    oppoCompatibility: OppoCompatibility,
    temporaryLabel: String,
    strictISO21496: Bool = false,
    eventHandler: ConversionEventHandler? = nil
) throws {
    if ProcessInfo.processInfo.environment["XDREMUX_DISABLE_DIRECT_GAIN"] != "1",
       !oppoCompatibility.wantsOppoCompat,
       !strictISO21496,
       !gainMapEncodingMatchesTarget(at: inputURL, compatibility: oppoCompatibility) {
        do {
            try writeDirectNativeGainMapPreservingPrimary(
                inputURL: inputURL,
                outputURL: outputURL,
                sourceData: sourceData,
                productInput: productInput,
                eventHandler: eventHandler
            )
            return
        } catch {
            eventHandler?(.diagnostic(
                "[direct-gain] unavailable; falling back to ImageIO preserve path: \(error)"
            ))
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    let parent = outputURL.deletingLastPathComponent()
    let stem = outputURL.deletingPathExtension().lastPathComponent
    let privateIntermediateURL = parent.appendingPathComponent(".\(stem).\(temporaryLabel)-private-\(UUID().uuidString).heic")
    let preservedURL = parent.appendingPathComponent(".\(stem).\(temporaryLabel)-preserve-\(UUID().uuidString).heic")
    defer {
        try? FileManager.default.removeItem(at: privateIntermediateURL)
        try? FileManager.default.removeItem(at: preservedURL)
    }

    let patchedUserComment = adjustedOppoUserComment(in: sourceData, compatibility: oppoCompatibility)
    switch productInput.extracted.mode {
    case .uhdr:
        if oppoCompatibility.wantsOppoCompat {
            try ISOHDRWriter.write(
                baseImageURL: inputURL,
                gainMap: productInput.gainMapRaster,
                style: productInput.style,
                outputURL: preservedURL,
                oppoCompatibility: oppoCompatibility,
                inputProcessingBranch: .system,
                eventHandler: eventHandler
            )
        } else if gainMapEncodingMatchesTarget(at: inputURL, compatibility: oppoCompatibility) {
            // The input already has the requested high-spec ISO Gain Map. Reusing
            // that graph avoids appending a second temporary JPEG/tmap graph,
            // which ImageIO rejects as ambiguous during preserve re-encoding.
            try FileManager.default.copyItem(at: inputURL, to: preservedURL)
        } else {
            _ = try writePrivateJPEGPassthroughOutput(
                inputURL: inputURL,
                outputURL: privateIntermediateURL,
                infoFloats: productInput.extracted.metaFloats,
                gainMapJPEG: productInput.extracted.maskJPEGData,
                patchedUserComment: patchedUserComment,
                tmapPayload: nil,
                tmapColorBox: nil
            )
            try ISOHDRWriter.writeWithPreserveReencode(
                intermediateURL: privateIntermediateURL,
                outputURL: preservedURL,
                patchedUserComment: patchedUserComment,
                eventHandler: eventHandler
            )
        }
    case .lhdr:
        let writerInput = gainMapWriterInput(
            productInput: productInput,
            oppoCompatibility: oppoCompatibility
        )
        let branch: InputProcessingBranch = oppoCompatibility.wantsOppoCompat ? .system : .hybrid
        try ISOHDRWriter.write(
            baseImageURL: inputURL,
            gainMap: writerInput.gainMap,
            style: writerInput.style,
            outputURL: preservedURL,
            oppoCompatibility: oppoCompatibility,
            inputProcessingBranch: branch,
            eventHandler: eventHandler
        )
    }

    try writeHybridPrimaryPassthrough(
        sourceURL: inputURL,
        preservedURL: preservedURL,
        outputURL: outputURL,
        patchedUserComment: patchedUserComment,
        preserveTmapColor: oppoCompatibility.wantsOppoCompat,
        strictISO21496Tmap: strictISO21496,
        fallbackXMPPayload: makeHdrgmXMP(infoFloats: productInput.extracted.metaFloats)
    )
}
