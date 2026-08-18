import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Darwin
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Vision
import XDRemuxCore

package enum ApplePhotographicStylesPipeline {
    private enum ResearchSemanticGraphMode: String {
        case zeroPerson = "zero-person"
        case zeroSkin = "zero-skin"
        case zeroHuman = "zero-human"
        case skyOnly = "sky-only"
    }

    private struct ResearchSemanticGraphOverride {
        let mode: ResearchSemanticGraphMode
        let analysis: AppleSemanticSceneAnalysis
        let writeProfile: AppleSemanticWriteProfile
    }

    private struct PhotoDerivedStyleSceneBundle {
        let width: Int
        let height: Int
        let codedLinearEncodedRGB8: Data
        let toneRGBAHalf: Data
        let rendererLinearRGBA16: Data
        let styleEngineWidth: Int
        let styleEngineHeight: Int
        let styleEngineToneRGBAHalf: Data
        let styleEngineRendererLinearRGBA16: Data
        let baseLinearP3RGB: [Float]
        let hdrLinearP3RGB: [Float]
        let logGainRGB: [Float]
        let baseLuminance: [Float]
        let hdrLuminance: [Float]
        let codedLinearLuminance: [Float]
        let rendererLinearLuminance: [Float]
        let gtcMappedLuminance: [Float]
        let globalToneCurve: Data
        let globalToneCurveLinearSamples: [Float]
        let globalToneCurveFitRMSE: Double
        let globalToneCurvePopulatedBins: Int
        let globalToneCurveSourceFeature: Float
        let globalToneCurveClampedSourceFeature: Float
        let contentHeadroom: Float
        let baselineExposure: Float
        let baselineExposureUnclamped: Float
        let baselineHighlightCompressionRatio: Float
        let linearBaseGain: Float
        let linearEncodingGain: Float
        let rendererLinearRangeMin: Float
        let rendererLinearRangeMax: Float
        let researchLinearInputScale: Float
        let researchScalarOverrides: [String: Float]
        let gainMapMaximumStops: Float
        let rawLinearThumbnailInputRGBA16: Data?
        let rawProvenance: [String: Any]
    }

    private struct EncodedHEVCResource {
        let itemPayload: Data
        let hvcC: Data
        let sourcePNGURL: URL
        let annexBSHA256: String
        let itemPayloadSHA256: String
        let hvcCSHA256: String
    }

    private struct GraphWriteResult {
        let primaryItemID: Int
        let gainMapItemID: Int
        let toneMapItemID: Int
        let styleDeltaItemID: Int
        let linearThumbnailItemID: Int
        let styleMetadataItemID: Int
        let originalMdatPayloadSHA256: String
        let outputOriginalMdatPrefixSHA256: String
        let itemCount: Int
        let propertyCount: Int
    }

    private static func zeroedSemanticMatte(
        _ matte: AppleSemanticMatte?
    ) -> AppleSemanticMatte? {
        guard let matte else { return nil }
        return AppleSemanticMatte(
            pixels: Data(repeating: 0, count: matte.width * matte.height),
            width: matte.width,
            height: matte.height,
            bytesPerRow: matte.width,
            statistics: SemanticStatistics(
                minimum: 0,
                maximum: 0,
                mean: 0,
                coverage: 0
            ),
            provenance: matte.provenance
        )
    }

    private static func researchSemanticGraphOverride(
        analysis: AppleSemanticSceneAnalysis,
        normalWriteProfile: AppleSemanticWriteProfile,
        portraitWritten: Bool
    ) throws -> ResearchSemanticGraphOverride? {
        guard let rawValue = ProcessInfo.processInfo.environment[
            "XDREMUX_RESEARCH_STYLES_SEMANTIC_GRAPH_MODE"
        ], !rawValue.isEmpty else {
            return nil
        }
        guard let mode = ResearchSemanticGraphMode(rawValue: rawValue.lowercased()) else {
            throw CLIError.invalidContainer(
                "unknown XDREMUX_RESEARCH_STYLES_SEMANTIC_GRAPH_MODE: \(rawValue)"
            )
        }
        guard !portraitWritten else {
            throw CLIError.invalidContainer(
                "research semantic graph overrides are styles-only and cannot rewrite a combined Portrait graph"
            )
        }
        let graphAnalysis: AppleSemanticSceneAnalysis
        let graphProfile: AppleSemanticWriteProfile
        switch mode {
        case .zeroPerson:
            graphAnalysis = AppleSemanticSceneAnalysis(
                person: zeroedSemanticMatte(analysis.person),
                skin: analysis.skin,
                hair: analysis.hair,
                teeth: analysis.teeth,
                glasses: analysis.glasses,
                sky: analysis.sky
            )
            graphProfile = normalWriteProfile
        case .zeroSkin:
            graphAnalysis = AppleSemanticSceneAnalysis(
                person: analysis.person,
                skin: zeroedSemanticMatte(analysis.skin),
                hair: analysis.hair,
                teeth: analysis.teeth,
                glasses: analysis.glasses,
                sky: analysis.sky
            )
            graphProfile = normalWriteProfile
        case .zeroHuman:
            graphAnalysis = AppleSemanticSceneAnalysis(
                person: zeroedSemanticMatte(analysis.person),
                skin: zeroedSemanticMatte(analysis.skin),
                hair: analysis.hair,
                teeth: analysis.teeth,
                glasses: analysis.glasses,
                sky: analysis.sky
            )
            graphProfile = normalWriteProfile
        case .skyOnly:
            graphAnalysis = analysis
            graphProfile = .styleSkyOnly
        }
        return ResearchSemanticGraphOverride(
            mode: mode,
            analysis: graphAnalysis,
            writeProfile: graphProfile
        )
    }

    private struct Options {
        let family: Family
        let debugRootURL: URL?
        let oppoCompatibility: OppoCompatibility
        let inputProcessingBranch: InputProcessingBranch
        let oppoCameraTail: OppoCameraTail
        let tmapFormat: TmapFormat
        let features: AppleFeatureFlags
        let rawDNGURL: URL?
        let styleDataProducer: AppleStyleDataProducerMode
        let eventHandler: ConversionEventHandler?
    }

    static func convert(
        inputURL: URL,
        outputURL: URL,
        configuration: ConversionConfiguration
    ) throws {
        try convert(
            inputURL: inputURL,
            outputURL: outputURL,
            options: Options(
                family: configuration.family,
                debugRootURL: configuration.debugDirectory,
                oppoCompatibility: configuration.oppoCompatibility,
                inputProcessingBranch: configuration.inputProcessingBranch,
                oppoCameraTail: configuration.oppoCameraTail,
                tmapFormat: configuration.tmapFormat,
                features: configuration.appleFeatureOptions,
                rawDNGURL: configuration.appleStylesRawDNGURL,
                styleDataProducer: configuration.appleStyleDataProducer
                    .resolvedForPhotographicStyles,
                eventHandler: configuration.eventHandler
            )
        )
    }

    static func isValidOutput(_ outputURL: URL, expectsPortrait: Bool) -> Bool {
        guard PortraitConversionPipeline.hasValidISOGainMap(outputURL) else { return false }
        return (try? validatePhotographicStylesOutput(outputURL, expectsPortrait: expectsPortrait)) != nil
    }

    static func validateExistingOutput(
        _ outputURL: URL,
        expectsPortrait: Bool
    ) throws -> [String: Any] {
        let validation = try validatePhotographicStylesOutput(
            outputURL,
            expectsPortrait: expectsPortrait
        )
        return [
            "schema": "xdremux-apple-output-validation-v1",
            "passed": true,
            "output": outputURL.path,
            "outputSHA256": sha256Hex(validation.outputData),
            "expectsPortrait": expectsPortrait,
            "isoGainMap": true,
            "semanticStyleProperties": true,
            "styleDataLength": 51_840,
            "donorContamination": validation.contaminationReport,
        ]
    }

    private static func sourceScale(
        sourceURL: URL,
        portraitWritten: Bool
    ) throws -> ResolvedScale {
        let sourceData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        if portraitWritten,
           let blocks = try? LHDRExtractor.portraitBlocks(from: sourceData),
           let info = try? PortraitConversionPipeline.resolveGainInfoFloats(
               privateInfo: blocks["local.uhdr.gainmap.info"],
               inputURL: sourceURL
           ) {
            return try EDRScaleResolver.resolve(metaFloats: info, mode: .uhdr)
        }
        do {
            let extracted = try LHDRExtractor.extract(from: sourceData)
            return try EDRScaleResolver.resolve(
                metaFloats: extracted.metaFloats,
                mode: extracted.mode
            )
        } catch {
            // Existing ISO Gain Map HEIC research fixtures do not have the
            // Local HDR/QTI extension, but their HDRToneMap metadata carries
            // the same per-channel scale needed by the scene bundle.
            let info = try PortraitConversionPipeline.resolveGainInfoFloats(
                privateInfo: nil,
                inputURL: sourceURL
            )
            return try EDRScaleResolver.resolve(metaFloats: info, mode: .uhdr)
        }
    }

    private static func rawEmbeddedPreviewSceneInput(
        rawDNGURL: URL,
        sourceURL: URL,
        outputURL: URL
    ) throws -> [String: Any] {
        let preview = try CoreImageRAW.extractEmbeddedPreview(from: rawDNGURL)
        guard let source = CGImageSourceCreateWithData(preview.data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  nil
              ) as? [CFString: Any],
              let sourceAuxiliary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                  source,
                  0,
                  kCGImageAuxiliaryDataTypeISOGainMap
              ) as? [CFString: Any],
              let metadata = sourceAuxiliary[kCGImageAuxiliaryDataInfoMetadata],
              let gainImage = CIImage(
                  data: preview.data,
                  options: [
                      .auxiliaryHDRGainMap: true,
                      .applyOrientationProperty: false,
                      .colorSpace: NSNull(),
                  ]
              ) else {
            throw CLIError.invalidContainer(
                "RAW embedded PreviewImage does not contain an ImageIO-readable ISO Gain Map"
            )
        }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
            ?? preview.dngOrientation
        guard (1...8).contains(orientation) else {
            throw CLIError.invalidContainer(
                "RAW embedded PreviewImage has unsupported EXIF orientation (orientation)"
            )
        }
        let sourceWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
            ?? preview.width
        let sourceHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
            ?? preview.height
        let gainStorageWidth = Int(gainImage.extent.width.rounded())
        let gainStorageHeight = Int(gainImage.extent.height.rounded())
        guard sourceWidth == gainStorageWidth * 2,
              sourceHeight == gainStorageHeight * 2 else {
            throw CLIError.invalidContainer(
                "RAW embedded ISO Gain Map is not half-resolution in primary storage geometry: "
                    + "primary=(sourceWidth)x(sourceHeight) gain=(gainStorageWidth)x(gainStorageHeight)"
            )
        }

        let orientedGain = gainImage.oriented(forExifOrientation: Int32(orientation))
        let extent = orientedGain.extent
        let gainWidth = Int(extent.width.rounded())
        let gainHeight = Int(extent.height.rounded())
        let expectedPresentationSize = [5, 6, 7, 8].contains(orientation)
            ? [sourceHeight / 2, sourceWidth / 2]
            : [sourceWidth / 2, sourceHeight / 2]
        guard [gainWidth, gainHeight] == expectedPresentationSize else {
            throw CLIError.invalidContainer(
                "RAW embedded ISO Gain Map orientation produced unexpected geometry: "
                    + "got=(gainWidth)x(gainHeight) expected=(expectedPresentationSize[0])x(expectedPresentationSize[1])"
            )
        }

        guard let sourceImage = CIImage(
            contentsOf: sourceURL,
            options: [.applyOrientationProperty: true]
        ) else {
            throw CLIError.invalidContainer(
                "RAW embedded PreviewImage cannot be paired because the source image is unreadable"
            )
        }
        let sourceImageWidth = max(1, Int(sourceImage.extent.width.rounded()))
        let sourceImageHeight = max(1, Int(sourceImage.extent.height.rounded()))
        let sourcePairSize = fittedSize(
            sourceWidth: sourceImageWidth,
            sourceHeight: sourceImageHeight,
            maximumWidth: 1024,
            maximumHeight: 1024
        )
        let sourcePair = try CoreImageRAW.validateEmbeddedPreview(
            preview,
            against: sourceImage,
            targetWidth: sourcePairSize.0,
            targetHeight: sourcePairSize.1
        )
        guard sourcePair.validated else {
            throw CLIError.invalidContainer(
                "RAW embedded PreviewImage does not match the source image: "
                    + "directCorrelation=\(sourcePair.correlation) "
                    + "toneInvariantCorrelation=\(sourcePair.toneInvariantCorrelation)"
            )
        }

        let bytesPerRow = gainWidth * 4
        var gainData = Data(count: bytesPerRow * gainHeight)
        let context = CIContext(options: [
            .cacheIntermediates: false,
            .useSoftwareRenderer: true,
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
        ])
        gainData.withUnsafeMutableBytes { raw in
            guard let baseAddress = raw.baseAddress else { return }
            context.render(
                orientedGain,
                toBitmap: baseAddress,
                rowBytes: bytesPerRow,
                bounds: extent,
                format: .BGRA8,
                colorSpace: nil
            )
        }

        let fourCC: UInt32 = "BGRA".utf8.reduce(0) { ($0 << 8) | UInt32($1) }
        let description: [CFString: Any] = [
            kCGImagePropertyWidth: gainWidth,
            kCGImagePropertyHeight: gainHeight,
            kCGImagePropertyBytesPerRow: bytesPerRow,
            kCGImagePropertyPixelFormat: fourCC,
        ]
        let auxiliary: [CFString: Any] = [
            kCGImageAuxiliaryDataInfoData: gainData,
            kCGImageAuxiliaryDataInfoDataDescription: description as CFDictionary,
            kCGImageAuxiliaryDataInfoMetadata: metadata,
        ]

        guard let displayP3 = CGColorSpace(name: CGColorSpace.displayP3),
              let baseImage = CIImage(
                  data: preview.data,
                  options: [
                      .applyOrientationProperty: true,
                      .colorSpace: displayP3,
                  ]
              ) else {
            throw CLIError.invalidContainer(
                "RAW embedded PreviewImage cannot be materialized in Display P3 presentation coordinates"
            )
        }
        let baseContext = CIContext(options: [
            .cacheIntermediates: false,
            .useSoftwareRenderer: true,
            .workingColorSpace: displayP3,
            .outputColorSpace: displayP3,
        ])
        guard let orientedBase = baseContext.createCGImage(baseImage, from: baseImage.extent) else {
            throw CLIError.invalidContainer(
                "RAW embedded PreviewImage presentation base could not be rasterized"
            )
        }

        try? FileManager.default.removeItem(at: outputURL)
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw CLIError.unableToCreateDestination(outputURL)
        }
        var imageOptions = properties
        imageOptions[kCGImagePropertyOrientation] = 1
        if var tiff = imageOptions[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            imageOptions[kCGImagePropertyTIFFDictionary] = tiff as CFDictionary
        }
        imageOptions[kCGImageDestinationEncodeRequest] = kCGImageDestinationEncodeToISOGainmap
        imageOptions[kCGImageDestinationEncodeRequestOptions] = [
            kCGImageDestinationEncodeBaseIsSDR: true,
            kCGImageDestinationLossyCompressionQuality: 1.0,
        ] as CFDictionary
        CGImageDestinationAddImage(destination, orientedBase, imageOptions as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(
            destination,
            kCGImageAuxiliaryDataTypeISOGainMap,
            auxiliary as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw CLIError.unableToFinalizeDestination(outputURL)
        }

        guard let verificationSource = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
              let verificationProperties = CGImageSourceCopyPropertiesAtIndex(
                  verificationSource,
                  0,
                  nil
              ) as? [CFString: Any],
              let verificationAuxiliary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                  verificationSource,
                  0,
                  kCGImageAuxiliaryDataTypeISOGainMap
              ) as? [CFString: Any],
              let verificationDescription = verificationAuxiliary[
                  kCGImageAuxiliaryDataInfoDataDescription
              ] as? [CFString: Any],
              let verificationWidth = (verificationDescription[kCGImagePropertyWidth] as? NSNumber)?.intValue,
              let verificationHeight = (verificationDescription[kCGImagePropertyHeight] as? NSNumber)?.intValue,
              verificationWidth == gainWidth,
              verificationHeight == gainHeight else {
            throw CLIError.invalidContainer(
                "RAW-derived HEIC lost or changed the oriented ISO Gain Map"
            )
        }

        return [
            "source": "DNG PreviewImage MPF ISO Gain Map",
            "dngSHA256": sha256Hex(try Data(contentsOf: rawDNGURL, options: [.mappedIfSafe])),
            "embeddedPreviewSHA256": preview.sha256,
            "exifOrientation": orientation,
            "primaryStorageSize": [sourceWidth, sourceHeight],
            "gainMapStorageSize": [gainStorageWidth, gainStorageHeight],
            "gainMapPresentationSize": [gainWidth, gainHeight],
            "transform": orientation == 1
                ? "identity"
                : "storage-to-presentation-exif-" + String(orientation),
            "pixelFormat": fourCC,
            "outputPath": outputURL.path,
            "sourcePairValidation": sourcePair.dictionary,
            "outputOrientation": (verificationProperties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
                ?? NSNull(),
        ]
    }

    private static func fittedSize(
        sourceWidth: Int,
        sourceHeight: Int,
        maximumWidth: Int,
        maximumHeight: Int
    ) -> (Int, Int) {
        let scale = min(
            1.0,
            Double(maximumWidth) / Double(sourceWidth),
            Double(maximumHeight) / Double(sourceHeight)
        )
        let width = max(2, Int((Double(sourceWidth) * scale / 2).rounded()) * 2)
        let height = max(2, Int((Double(sourceHeight) * scale / 2).rounded()) * 2)
        return (min(width, maximumWidth), min(height, maximumHeight))
    }

    // CIContext construction sets up a Metal pipeline each time; contexts are
    // cached per exact option set (working/output color space), which does not
    // change render results.
    private static let renderedRGBAFloatContextLock = NSLock()
    private static var renderedRGBAFloatContexts: [String: CIContext] = [:]

    private static func renderedRGBAFloatContext(colorSpace: CGColorSpace?) -> CIContext {
        let contextColorSpace: Any = colorSpace ?? NSNull()
        let key: String
        switch (colorSpace, colorSpace?.name) {
        case (nil, _):
            key = "<nil>"
        case (_, .some(let name)):
            key = name as String
        case (.some, nil):
            // Unnamed (e.g. ICC-based) spaces cannot be keyed reliably; render
            // with a fresh context exactly as before.
            return CIContext(options: [
                .cacheIntermediates: false,
                .workingColorSpace: contextColorSpace,
                .outputColorSpace: contextColorSpace,
            ])
        }
        renderedRGBAFloatContextLock.lock()
        defer { renderedRGBAFloatContextLock.unlock() }
        if let cached = renderedRGBAFloatContexts[key] {
            return cached
        }
        let context = CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: contextColorSpace,
            .outputColorSpace: contextColorSpace,
        ])
        renderedRGBAFloatContexts[key] = context
        return context
    }

    private static func renderedRGBAFloat(
        image: CIImage,
        width: Int,
        height: Int,
        colorSpace: CGColorSpace?
    ) -> [Float] {
        let normalized = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.origin.x,
            y: -image.extent.origin.y
        ))
        let resized = normalized.transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / normalized.extent.width,
            y: CGFloat(height) / normalized.extent.height
        )).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        var pixels = Array(repeating: Float(0), count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            renderedRGBAFloatContext(colorSpace: colorSpace).render(
                resized,
                toBitmap: base,
                rowBytes: width * 4 * MemoryLayout<Float>.size,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBAf,
                colorSpace: colorSpace
            )
        }
        return pixels
    }

    private static func halfRounded(_ value: Float) -> Float {
        XDRemuxHalf.decode(XDRemuxHalf.encode(value))
    }

    // appleEncodeLinear quantizes its input to Float16 first, so the result is
    // a pure function of the 16-bit pattern; tabulating all 65536 entries with
    // the original function keeps every output bit-identical.
    private static let appleEncodeLinearTable: [Float] = {
        var table = [Float](repeating: 0, count: 65_536)
        for pattern in 0..<65_536 {
            table[pattern] = appleEncodeLinear(
                XDRemuxHalf.decode(UInt16(pattern))
            )
        }
        return table
    }()

    private static func appleEncodeLinearTabulated(_ input: Float) -> Float {
        appleEncodeLinearTable[Int(XDRemuxHalf.encode(input))]
    }

    private static func appleEncodeLinear(_ input: Float) -> Float {
        let x = halfRounded(input)
        let highThreshold = XDRemuxHalf.decode(0x211f)
        let lowThreshold = XDRemuxHalf.decode(0xab38)
        if x >= highThreshold {
            let logInput = halfRounded(x + XDRemuxHalf.decode(0x20f0))
            let logged = halfRounded(log2f(logInput))
            return halfRounded(
                halfRounded(logged * XDRemuxHalf.decode(0x2d79))
                    + XDRemuxHalf.decode(0x398c)
            )
        }
        if x > lowThreshold {
            let toe = halfRounded(x + XDRemuxHalf.decode(0x2b38))
            return halfRounded(
                halfRounded(toe * toe) * XDRemuxHalf.decode(0x51e9)
            )
        }
        return 0
    }

    private static func sRGBEncode(_ linear: Double) -> Double {
        linear <= 0.0031308
            ? linear * 12.92
            : 1.055 * pow(linear, 1 / 2.4) - 0.055
    }

    // Native 23F84 producer evidence proves key 4 is 4 * LTMDigitalGain, but
    // that capture metadata is not retained in arbitrary third-party HEICs.
    // The corpus calibration below is deliberately small and auditable: it
    // normalizes the same-photo HDR/Base p98 compression ratio and preserves
    // the native 1/65 quantization. It is a behavioral proxy, not a claim that
    // OPPO metadata contains Apple's LTMDigitalGain.
    private static let baselineHighlightCompressionCalibration = Float(0.40126406)
    // The two-feature native-corpus proxy is materially more stable than the
    // Gain Map maximum alone (8-scene leave-one-out RMSE 0.04026 vs 0.06807).
    // Including same-photo HDR/Base highlight compression also prevents a
    // family of OPPO files with identical Gain Map metadata maxima from
    // collapsing to one scene-independent h/i value.
    private static let linearBaseGainIntercept = Float(1.51271843)
    private static let linearBaseGainPerGainMapStop = Float(0.15670632)
    private static let linearBaseGainPerHighlightCompression = Float(0.14766724)
    // All 8/8 native reference payloads use positive Float16 c/d samples with
    // these protocol-domain floors and ceilings.  Preserve the unbounded
    // SceneBundle values through resampling, then clamp only at this verified
    // serialized-resource boundary.
    private static let toneLightMapMinimum = Float(0.040740966796875)
    private static let toneLightMapMaximum = Float(0.76123046875)
    private static let linearLightMapMinimum = Float(0.040740966796875)
    private static let linearLightMapMaximum = Float(0.75830078125)

    private static func photoDerivedLinearMetadata(
        baseLuminance: [Float],
        hdrLuminance: [Float],
        gainMapMaximumStops: Float
    ) throws -> (
        baselineExposure: Float,
        baselineExposureUnclamped: Float,
        highlightCompressionRatio: Float,
        baseGain: Float,
        encodingGain: Float
    ) {
        let baseP98 = Float(distribution(baseLuminance)["p98"] ?? 0)
        let hdrP98 = Float(distribution(hdrLuminance)["p98"] ?? 0)
        guard baseP98.isFinite, hdrP98.isFinite, baseP98 > 1 / 4096, hdrP98 > 0 else {
            throw CLIError.invalidContainer(
                "cannot derive per-photo Styles exposure metadata from finite HDR/Base highlights"
            )
        }
        let highlightCompressionRatio = hdrP98 / baseP98
        let baselineUnclamped = highlightCompressionRatio
            / baselineHighlightCompressionCalibration
        let baselineClamped = min(max(baselineUnclamped, 4), 10.4)
        let baselineExposure = (baselineClamped * 65).rounded() / 65
        let baseGain = min(max(
            linearBaseGainIntercept
                + linearBaseGainPerGainMapStop * gainMapMaximumStops
                + linearBaseGainPerHighlightCompression * highlightCompressionRatio,
            0.5
        ), 2.5)
        return (
            baselineExposure,
            baselineUnclamped,
            highlightCompressionRatio,
            baseGain,
            4 * baseGain
        )
    }

    private static func monotonicGlobalToneCurve(
        inputLuminance: [Float],
        outputLuminance: [Float],
        researchIdentityBlend: Float = 0
    ) -> (
        data: Data,
        linearSamples: [Float],
        rmse: Double,
        populatedBins: Int,
        sourceFeature: Float,
        clampedSourceFeature: Float
    ) {
        precondition(inputLuminance.count == outputLuminance.count)
        let sampleCount = 256
        // Key 3 is sampled over a normalized 0...1 texture coordinate.  A
        // direct fit between absolute coded-linear HDR and Base luminance
        // confounds exposure normalization with curve shape: on the 019f8511
        // counterexample it reached 0.934 by input 0.40, while all 84 native
        // curves remain in a compact, near-identity family.  Normalize both
        // same-photo domains by their robust white before fitting so key 3
        // represents only the per-photo global tone shape.  Absolute range is
        // carried separately by key 4 and i.Gain.
        let inputWhite = max(Float(distribution(inputLuminance)["highKey"] ?? 0), 1 / 4096)
        let outputWhite = max(Float(distribution(outputLuminance)["highKey"] ?? 0), 1 / 4096)
        var sums = Array(repeating: Double(0), count: sampleCount)
        var counts = Array(repeating: Double(0), count: sampleCount)
        for (input, output) in zip(inputLuminance, outputLuminance) {
            guard input.isFinite, output.isFinite else { continue }
            let x = min(max(Double(input / inputWhite), 0), 1)
            let y = min(max(Double(output / outputWhite), 0), 1)
            let index = min(sampleCount - 1, max(0, Int((x * 255).rounded())))
            sums[index] += y
            counts[index] += 1
        }
        let populated = counts.reduce(into: 0) { result, value in
            if value > 0 { result += 1 }
        }
        var values = Array(repeating: Double(0), count: sampleCount)
        let populatedIndices = counts.indices.filter { counts[$0] > 0 }
        if populatedIndices.isEmpty {
            values = (0..<sampleCount).map { Double($0) / 255 }
        } else {
            for index in 0..<sampleCount {
                if counts[index] > 0 {
                    values[index] = sums[index] / counts[index]
                    continue
                }
                let lower = populatedIndices.last(where: { $0 < index })
                let upper = populatedIndices.first(where: { $0 > index })
                switch (lower, upper) {
                case let (.some(left), .some(right)):
                    let fraction = Double(index - left) / Double(right - left)
                    let leftValue = sums[left] / counts[left]
                    let rightValue = sums[right] / counts[right]
                    values[index] = leftValue * (1 - fraction) + rightValue * fraction
                case let (.some(left), .none):
                    values[index] = sums[left] / counts[left]
                case let (.none, .some(right)):
                    values[index] = sums[right] / counts[right]
                case (.none, .none):
                    values[index] = Double(index) / 255
                }
            }
        }

        struct IsotonicBlock {
            var lower: Int
            var upper: Int
            var weight: Double
            var weightedValue: Double

            var mean: Double { weightedValue / max(weight, .leastNonzeroMagnitude) }
        }
        let observationCount = max(counts.reduce(0, +), 1)
        counts[0] += observationCount
        sums[0] += 0
        values[0] = 0
        counts[sampleCount - 1] += observationCount
        sums[sampleCount - 1] += observationCount
        values[sampleCount - 1] = 1
        var blocks: [IsotonicBlock] = []
        blocks.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let weight = max(counts[index], 1 / 1024)
            let value = counts[index] > 0 ? sums[index] / counts[index] : values[index]
            blocks.append(IsotonicBlock(
                lower: index,
                upper: index,
                weight: weight,
                weightedValue: weight * min(max(value, 0), 1)
            ))
            while blocks.count >= 2,
                  blocks[blocks.count - 2].mean > blocks[blocks.count - 1].mean {
                let right = blocks.removeLast()
                var left = blocks.removeLast()
                left.upper = right.upper
                left.weight += right.weight
                left.weightedValue += right.weightedValue
                blocks.append(left)
            }
        }
        var sourceShape = Array(repeating: Float(0), count: sampleCount)
        for block in blocks {
            let value = Float(min(max(block.mean, 0), 1))
            for index in block.lower...block.upper {
                sourceShape[index] = value
            }
        }
        sourceShape[0] = 0
        sourceShape[sampleCount - 1] = 1
        for index in 1..<sampleCount where sourceShape[index] < sourceShape[index - 1] {
            sourceShape[index] = sourceShape[index - 1]
        }

        // The Apple camera GTC is an upstream ISP product and is not retained
        // in an arbitrary OPPO HEIC.  Direct absolute HDR->Base regression was
        // falsified by the 019f8511 response counterexample.  The bounded
        // system-identification model below instead maps one robust,
        // same-photo shape observation into the compact native curve family.
        //
        // Calibration: 84 native GTCs decoded using the 23F84 consumer's
        // 256-sample contract; the applicable h>=1 regime contains 71 photos.
        // The source feature is the p95-normalized paired HDR/Base curve at
        // index 8.  Ten endpoint-preserving polynomial coefficients were fit
        // against that feature.  Leave-one-out curve RMSE is 0.002697 mean,
        // 0.007052 p95, and 0.015014 maximum.  The model produces a unique
        // curve for every distinct source feature and contains no donor curve
        // selection or scene-dependent identity fallback.
        let sourceFeature = sourceShape[8]
        let clampedSourceFeature = min(max(sourceFeature, 0.036004916), 0.083503760)
        let intercept: [Float] = [
            -0.084157526, -0.470446978, 0.214894906, -0.094378520,
            -1.243283963, 1.129283384, 1.872334583, -2.067420023,
            -1.213296907, 1.064446621,
        ]
        let slope: [Float] = [
            -0.102652002, -0.406791328, -0.148726014, 0.719434204,
            -1.434380301, -2.721594413, 3.446946499, 4.109380580,
            -3.075442484, -2.993801587,
        ]
        let coefficients = zip(intercept, slope).map {
            $0.0 + clampedSourceFeature * $0.1
        }
        var fitted = Array(repeating: Float(0), count: sampleCount)
        for index in 0..<sampleCount {
            let x = Float(index) / Float(sampleCount - 1)
            let t = 1 - 2 * x
            let endpointBasis = x * (1 - x)
            var tPower = Float(1)
            var value = x
            for coefficient in coefficients {
                value += coefficient * endpointBasis * tPower
                tPower *= t
            }
            fitted[index] = min(max(value, 0), 1)
            if index > 0 {
                fitted[index] = max(fitted[index], fitted[index - 1])
            }
        }
        fitted[0] = 0
        fitted[sampleCount - 1] = 1
        if researchIdentityBlend > 0 {
            for index in 1..<(sampleCount - 1) {
                let identity = Float(index) / Float(sampleCount - 1)
                fitted[index] = fitted[index] * (1 - researchIdentityBlend)
                    + identity * researchIdentityBlend
            }
        }

        var squaredError = Double(0)
        var finiteCount = 0
        for (input, output) in zip(inputLuminance, outputLuminance) {
            guard input.isFinite, output.isFinite else { continue }
            let position = min(max(Double(input / inputWhite), 0), 1) * 255
            let lower = min(255, max(0, Int(floor(position))))
            let upper = min(255, lower + 1)
            let fraction = position - Double(lower)
            let predicted = Double(sourceShape[lower]) * (1 - fraction)
                + Double(sourceShape[upper]) * fraction
            let error = predicted - min(max(Double(output / outputWhite), 0), 1)
            squaredError += error * error
            finiteCount += 1
        }

        var payload = Data()
        var countWord = UInt16(257).littleEndian
        withUnsafeBytes(of: &countWord) { payload.append(contentsOf: $0) }
        for linear in fitted {
            let encoded = min(max(sRGBEncode(Double(linear)), 0), 1)
            var value = UInt16(
                min(65_534, max(0, Int((encoded * 65_534).rounded())))
            ).littleEndian
            withUnsafeBytes(of: &value) { payload.append(contentsOf: $0) }
        }
        var terminal = UInt16(65_534).littleEndian
        withUnsafeBytes(of: &terminal) { payload.append(contentsOf: $0) }
        return (
            payload,
            fitted,
            finiteCount > 0 ? sqrt(squaredError / Double(finiteCount)) : .infinity,
            populated,
            sourceFeature,
            clampedSourceFeature
        )
    }

    private static func applyGlobalToneCurve(
        _ luminance: [Float],
        samples: [Float]
    ) -> [Float] {
        luminance.map { value in
            let position = min(max(value, 0), 1) * 255
            let lower = min(255, max(0, Int(floor(position))))
            let upper = min(255, lower + 1)
            let fraction = position - Float(lower)
            return samples[lower] * (1 - fraction) + samples[upper] * fraction
        }
    }

    private static func styleEngineDimensions(width: Int, height: Int) -> (Int, Int) {
        if width > height {
            return fittedSize(
                sourceWidth: width,
                sourceHeight: height,
                maximumWidth: 256,
                maximumHeight: 192
            )
        }
        if height > width {
            return fittedSize(
                sourceWidth: width,
                sourceHeight: height,
                maximumWidth: 192,
                maximumHeight: 256
            )
        }
        return fittedSize(
            sourceWidth: width,
            sourceHeight: height,
            maximumWidth: 256,
            maximumHeight: 256
        )
    }

    private static func areaResampledRGBAHalf(
        rgb: [Float],
        width: Int,
        height: Int,
        targetWidth: Int,
        targetHeight: Int
    ) -> Data {
        var result = Data(count: targetWidth * targetHeight * 8)
        result.withUnsafeMutableBytes { raw in
            guard let destination = raw.bindMemory(to: UInt16.self).baseAddress else { return }
            for targetY in 0..<targetHeight {
                let y0 = targetY * height / targetHeight
                let y1 = max(y0 + 1, (targetY + 1) * height / targetHeight)
                for targetX in 0..<targetWidth {
                    let x0 = targetX * width / targetWidth
                    let x1 = max(x0 + 1, (targetX + 1) * width / targetWidth)
                    let count = Float(max(1, (x1 - x0) * (y1 - y0)))
                    var sums = [Float](repeating: 0, count: 3)
                    for y in y0..<min(y1, height) {
                        for x in x0..<min(x1, width) {
                            let source = (y * width + x) * 3
                            sums[0] += rgb[source]
                            sums[1] += rgb[source + 1]
                            sums[2] += rgb[source + 2]
                        }
                    }
                    let target = (targetY * targetWidth + targetX) * 4
                    for component in 0..<3 {
                        let value = sums[component] / count
                        destination[target + component] = XDRemuxHalf.encode(
                            value.isFinite ? value : 0
                        ).littleEndian
                    }
                    destination[target + 3] = XDRemuxHalf.encode(1).littleEndian
                }
            }
        }
        return result
    }

    private static func areaResampledRGBA16UNorm(
        rgb: [Float],
        normalizationGain: Float,
        width: Int,
        height: Int,
        targetWidth: Int,
        targetHeight: Int
    ) -> Data {
        var result = Data(count: targetWidth * targetHeight * 8)
        result.withUnsafeMutableBytes { raw in
            guard let destination = raw.bindMemory(to: UInt16.self).baseAddress else { return }
            for targetY in 0..<targetHeight {
                let y0 = targetY * height / targetHeight
                let y1 = max(y0 + 1, (targetY + 1) * height / targetHeight)
                for targetX in 0..<targetWidth {
                    let x0 = targetX * width / targetWidth
                    let x1 = max(x0 + 1, (targetX + 1) * width / targetWidth)
                    let count = Float(max(1, (x1 - x0) * (y1 - y0)))
                    var sums = [Float](repeating: 0, count: 3)
                    for y in y0..<min(y1, height) {
                        for x in x0..<min(x1, width) {
                            let source = (y * width + x) * 3
                            sums[0] += rgb[source]
                            sums[1] += rgb[source + 1]
                            sums[2] += rgb[source + 2]
                        }
                    }
                    let target = (targetY * targetWidth + targetX) * 4
                    for component in 0..<3 {
                        let value = min(
                            max((sums[component] / count) / normalizationGain, 0),
                            1
                        )
                        destination[target + component] = UInt16(
                            min(65_535, max(0, Int((value * 65_535).rounded())))
                        ).littleEndian
                    }
                    destination[target + 3] = UInt16.max.littleEndian
                }
            }
        }
        return result
    }

    private static func photoDerivedStyleSceneBundle(
        standardHDRURL: URL,
        scale: ResolvedScale,
        rawDNGURL: URL?
    ) throws -> PhotoDerivedStyleSceneBundle {
        guard let primary = CIImage(
            contentsOf: standardHDRURL,
            options: [.applyOrientationProperty: true]
        ), let gain = CIImage(
            contentsOf: standardHDRURL,
            options: [
                .auxiliaryHDRGainMap: true,
                .applyOrientationProperty: true,
                .colorSpace: NSNull(),
            ]
        ) else {
            throw CLIError.invalidContainer("Core Image cannot decode the coherent base/gain bundle")
        }
        let sourceWidth = max(1, Int(primary.extent.width.rounded()))
        let sourceHeight = max(1, Int(primary.extent.height.rounded()))
        let size = fittedSize(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            maximumWidth: 1024,
            maximumHeight: 1024
        )
        guard let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
            throw CLIError.invalidContainer("required linear Display P3 color space is unavailable")
        }
        let basePixels = renderedRGBAFloat(
            image: primary,
            width: size.0,
            height: size.1,
            colorSpace: linearP3
        )
        let gainPixels = renderedRGBAFloat(
            image: gain,
            width: size.0,
            height: size.1,
            colorSpace: nil
        )
        let pixelCount = size.0 * size.1
        var baseRGB = Array(repeating: Float(0), count: pixelCount * 3)
        var hdrRGB = Array(repeating: Float(0), count: pixelCount * 3)
        var logGainRGB = Array(repeating: Float(0), count: pixelCount * 3)
        var baseLuminance = Array(repeating: Float(0), count: pixelCount)
        var hdrLuminance = Array(repeating: Float(0), count: pixelCount)
        let channelCount = max(1, scale.channelCount)
        func channel(_ values: [Double], _ index: Int, _ fallback: Double) -> Float {
            Float(values[min(index, values.count - 1)] as Double? ?? fallback)
        }
        // All five decode parameters depend only on the component index, so
        // they are resolved once instead of per pixel.
        var gammaByComponent = [Float](repeating: 0, count: 3)
        var minimumByComponent = [Float](repeating: 0, count: 3)
        var maximumByComponent = [Float](repeating: 0, count: 3)
        var baseOffsetByComponent = [Float](repeating: 0, count: 3)
        var alternateOffsetByComponent = [Float](repeating: 0, count: 3)
        for component in 0..<3 {
            let parameterIndex = channelCount == 1 ? 0 : component
            gammaByComponent[component] = channel(scale.perChannelGamma, parameterIndex, scale.gamma)
            minimumByComponent[component] = channel(scale.perChannelGainMapMin, parameterIndex, scale.gainMapMin)
            maximumByComponent[component] = channel(scale.perChannelGainMapMax, parameterIndex, scale.gainMapMax)
            baseOffsetByComponent[component] = channel(
                scale.perChannelBaseOffset,
                parameterIndex,
                scale.epsilonSdr
            )
            alternateOffsetByComponent[component] = channel(
                scale.perChannelAlternateOffset,
                parameterIndex,
                scale.epsilonHdr
            )
        }
        var baseChannels = [Float](repeating: 0, count: 3)
        var hdrChannels = [Float](repeating: 0, count: 3)
        for pixel in 0..<pixelCount {
            for component in 0..<3 {
                let base = basePixels[pixel * 4 + component]
                let code = min(max(gainPixels[pixel * 4 + component], 0), 1)
                let gamma = gammaByComponent[component]
                let minimum = minimumByComponent[component]
                let maximum = maximumByComponent[component]
                let baseOffset = baseOffsetByComponent[component]
                let alternateOffset = alternateOffsetByComponent[component]
                let weight = powf(code, gamma)
                let logGain = minimum + weight * (maximum - minimum)
                let reconstructed = max(base + baseOffset, 0) * exp2f(logGain)
                    - alternateOffset
                baseChannels[component] = base
                hdrChannels[component] = reconstructed
                baseRGB[pixel * 3 + component] = base
                hdrRGB[pixel * 3 + component] = reconstructed
                logGainRGB[pixel * 3 + component] = logGain
            }
            // Display P3 RGB to XYZ D65 Y. These are not the Rec.709/sRGB
            // coefficients previously (and incorrectly) used for P3 pixels.
            baseLuminance[pixel] = 0.22897456 * baseChannels[0]
                + 0.69173852 * baseChannels[1]
                + 0.07928691 * baseChannels[2]
            hdrLuminance[pixel] = 0.22897456 * hdrChannels[0]
                + 0.69173852 * hdrChannels[1]
                + 0.07928691 * hdrChannels[2]
        }
        let gainMapMaximumStops = Float(max(
            scale.gainMapMax,
            scale.perChannelGainMapMax.max() ?? scale.gainMapMax
        ))
        let linearMetadata = try photoDerivedLinearMetadata(
            baseLuminance: baseLuminance,
            hdrLuminance: hdrLuminance,
            gainMapMaximumStops: gainMapMaximumStops
        )
        func researchOverride(
            _ name: String,
            range: ClosedRange<Float>
        ) throws -> Float? {
            guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
            guard let parsed = Float(raw), parsed.isFinite, range.contains(parsed) else {
                throw CLIError.invalidContainer(
                    "\(name) must be finite in \(range.lowerBound)...\(range.upperBound)"
                )
            }
            return parsed
        }
        let baselineExposureOverride = try researchOverride(
            "XDREMUX_RESEARCH_STYLES_BASELINE_EXPOSURE",
            range: 2...12
        )
        let baseGainOverride = try researchOverride(
            "XDREMUX_RESEARCH_STYLES_BASE_GAIN",
            range: 0.5...3
        )
        let gtcIdentityBlendOverride = try researchOverride(
            "XDREMUX_RESEARCH_STYLES_GTC_IDENTITY_BLEND",
            range: 0...1
        )
        let baselineExposure = baselineExposureOverride
            ?? linearMetadata.baselineExposure
        let baseGain = baseGainOverride ?? linearMetadata.baseGain
        let encodingGain = 4 * baseGain
        var researchScalarOverrides: [String: Float] = [:]
        if let baselineExposureOverride {
            researchScalarOverrides["baselineExposure"] = baselineExposureOverride
        }
        if let baseGainOverride {
            researchScalarOverrides["baseGain"] = baseGainOverride
        }
        if let gtcIdentityBlendOverride {
            researchScalarOverrides["gtcIdentityBlend"] = gtcIdentityBlendOverride
        }
        let researchLinearInputScale: Float
        if let rawScale = ProcessInfo.processInfo.environment[
            "XDREMUX_RESEARCH_STYLES_LINEAR_INPUT_SCALE"
        ] {
            guard let parsedScale = Float(rawScale),
                  parsedScale.isFinite,
                  (0.125...16).contains(parsedScale) else {
                throw CLIError.invalidContainer(
                    "XDREMUX_RESEARCH_STYLES_LINEAR_INPUT_SCALE must be finite in 0.125...16"
                )
            }
            researchLinearInputScale = parsedScale
        } else {
            researchLinearInputScale = 1
        }
        // Stage C1: Linear Thumbnail proxy variant.  "gain-normalized" is the
        // existing default; "seam-min-ratio" implements the 23F84
        // smartStyleCreateLinearThumbnail seam semantics
        // post-LTM RGB * min(Ypre/Ypost, 1) as a behavior-equivalent proxy.
        // Plan: docs/plans/active/
        // apple-styles-editor-response-optimization-20260726.md section 4.
        let linearThumbnailMode = ProcessInfo.processInfo.environment[
            "XDREMUX_STYLES_LINEAR_THUMBNAIL_MODE"
        ] ?? "gain-normalized"
        guard ["gain-normalized", "seam-min-ratio"].contains(linearThumbnailMode) else {
            throw CLIError.invalidContainer(
                "XDREMUX_STYLES_LINEAR_THUMBNAIL_MODE must be gain-normalized or seam-min-ratio"
            )
        }
        let seamThumbnail = linearThumbnailMode == "seam-min-ratio"
        if seamThumbnail {
            researchScalarOverrides["linearThumbnailModeSeam"] = 1
        }
        var seamCodedLinearRGB: [Float]?
        let codedLinearLuminance: [Float]
        if seamThumbnail {
            var seamRGB = Array(repeating: Float(0), count: pixelCount * 3)
            var seamLuminance = Array(repeating: Float(0), count: pixelCount)
            for pixel in 0..<pixelCount {
                let preLuminance = hdrLuminance[pixel] / baselineExposure
                let postLuminance = baseLuminance[pixel]
                let ratio = min(preLuminance / max(postLuminance, 1.0 / 65_536), 1)
                for component in 0..<3 {
                    seamRGB[pixel * 3 + component] =
                        baseRGB[pixel * 3 + component] * ratio
                }
                seamLuminance[pixel] = postLuminance * ratio
            }
            seamCodedLinearRGB = seamRGB
            codedLinearLuminance = seamLuminance
        } else {
            codedLinearLuminance = hdrLuminance.map { $0 / baselineExposure }
        }
        // The private renderer consumes the normalized Linear Thumbnail input
        // domain, while inputLinearMetadata.Gain carries the inverse scale
        // needed to encode the paired output resource.  A bounded 2D response
        // ablation (Linear scale x GTC) rejected the pre-encoding 0.448 range:
        // with native-family GTC it created two early Tone reversals and a
        // skin/background direction split.  The default therefore remains the
        // gain-normalized domain; the explicitly named research-only scale is
        // used for a bounded intermediate response sweep and disqualifies the
        // resulting HEIC from production admission.
        let rendererLinearLuminance = codedLinearLuminance.map {
            ($0 / encodingGain) * researchLinearInputScale
        }
        let gtc = monotonicGlobalToneCurve(
            inputLuminance: codedLinearLuminance,
            outputLuminance: baseLuminance,
            researchIdentityBlend: gtcIdentityBlendOverride ?? 0
        )
        let gtcMappedLuminance = applyGlobalToneCurve(
            codedLinearLuminance,
            samples: gtc.linearSamples
        )
        var encoded = Data(count: pixelCount * 3)
        var toneRGBAHalf = Data(count: pixelCount * 8)
        var rendererLinearRGBA16 = Data(count: pixelCount * 8)
        var rendererLinearMinimum = Float.infinity
        var rendererLinearMaximum = -Float.infinity
        encoded.withUnsafeMutableBytes { encodedRaw in
            toneRGBAHalf.withUnsafeMutableBytes { toneRaw in
                rendererLinearRGBA16.withUnsafeMutableBytes { linearRaw in
                    guard let encodedDestination = encodedRaw.bindMemory(to: UInt8.self).baseAddress,
                          let tone = toneRaw.bindMemory(to: UInt16.self).baseAddress,
                          let linear = linearRaw.bindMemory(to: UInt16.self).baseAddress else { return }
                    for pixel in 0..<pixelCount {
                        for component in 0..<3 {
                            let baseValue = baseRGB[pixel * 3 + component]
                            let codedLinear = seamCodedLinearRGB
                                .map { $0[pixel * 3 + component] }
                                ?? (hdrRGB[pixel * 3 + component] / baselineExposure)
                            let rendererLinear = (codedLinear / encodingGain)
                                * researchLinearInputScale
                            let serializedRendererLinear = min(max(rendererLinear, 0), 1)
                            let encodedValue = min(max(appleEncodeLinearTabulated(codedLinear), 0), 1)
                            encodedDestination[pixel * 3 + component] = UInt8(
                                min(255, max(0, Int((encodedValue * 255).rounded())))
                            )
                            tone[pixel * 4 + component] = XDRemuxHalf.encode(baseValue).littleEndian
                            linear[pixel * 4 + component] = UInt16(
                                min(65_535, max(0, Int((serializedRendererLinear * 65_535).rounded())))
                            ).littleEndian
                            rendererLinearMinimum = min(rendererLinearMinimum, rendererLinear)
                            rendererLinearMaximum = max(rendererLinearMaximum, rendererLinear)
                        }
                        tone[pixel * 4 + 3] = XDRemuxHalf.encode(1).littleEndian
                        linear[pixel * 4 + 3] = UInt16.max.littleEndian
                    }
                }
            }
        }
        let styleEngineSize = styleEngineDimensions(width: size.0, height: size.1)
        let styleEngineToneRGBAHalf = areaResampledRGBAHalf(
            rgb: baseRGB,
            width: size.0,
            height: size.1,
            targetWidth: styleEngineSize.0,
            targetHeight: styleEngineSize.1
        )
        let styleEngineRendererLinearRGBA16: Data
        if let seamCodedLinearRGB {
            styleEngineRendererLinearRGBA16 = areaResampledRGBA16UNorm(
                rgb: seamCodedLinearRGB,
                normalizationGain: encodingGain / researchLinearInputScale,
                width: size.0,
                height: size.1,
                targetWidth: styleEngineSize.0,
                targetHeight: styleEngineSize.1
            )
        } else {
            styleEngineRendererLinearRGBA16 = areaResampledRGBA16UNorm(
                rgb: hdrRGB,
                normalizationGain: (baselineExposure * encodingGain)
                    / researchLinearInputScale,
                width: size.0,
                height: size.1,
                targetWidth: styleEngineSize.0,
                targetHeight: styleEngineSize.1
            )
        }
        var rawLinearThumbnailInputRGBA16: Data?
        var rawProvenance: [String: Any] = [
            "linearThumbnailSource": "final-HEIC-proxy",
            "linearThumbnailVariant": linearThumbnailMode,
            "dngDecodeMode": "not-used",
            "rawIsProcessedRemosaic": false,
            "sceneLinearConfidence": "unavailable",
            "remosaicAwareReconstruction": false,
            "cameraProducerExact": false,
            "consumerExactForProvidedLinearInput": false,
            "behaviorEquivalentLinearInputValidated": false,
            "productionEligible": false,
            "fallbackReason": rawDNGURL == nil ? "raw-dng-not-provided" : "raw-dng-not-evaluated",
        ]
        if let rawDNGURL {
            do {
                let storageOrientation = Int(exifOrientation(at: rawDNGURL))
                let rawStorageSize = [5, 6, 7, 8].contains(storageOrientation)
                    ? (size.1, size.0)
                    : size
                let decoded = try CoreImageRAW.decode(
                    dngURL: rawDNGURL,
                    targetWidth: rawStorageSize.0,
                    targetHeight: rawStorageSize.1
                )
                let sourcePair = try CoreImageRAW.validateEmbeddedPreview(
                    decoded.embeddedPreview,
                    against: primary,
                    targetWidth: size.0,
                    targetHeight: size.1
                )
                let internalPairValidated = decoded.pairValidation?.validated == true
                let pairValidated = internalPairValidated && sourcePair.validated
                let calibrationValidated = decoded.calibrationConfidence >= 0.35
                var enrichedProvenance = decoded.provenance.merging([
                    "rawPreviewReferencePairValidated": sourcePair.validated,
                    "rawPreviewReferencePair": sourcePair.dictionary,
                ]) { _, new in new }
                guard pairValidated, calibrationValidated, decoded.rawStatistics.finite else {
                    enrichedProvenance["fallbackReason"] = !internalPairValidated
                        ? "embedded-preview-internal-pair-failed"
                        : (!sourcePair.validated
                            ? "embedded-preview-does-not-match-source-image"
                            : "raw-calibration-confidence-insufficient")
                    rawProvenance = enrichedProvenance
                    throw CLIError.invalidContainer("RAW-assisted preview pairing or calibration confidence was insufficient")
                }
                let oriented = try CoreImageRAW.orientedRGBA16(
                    decoded.normalizedRGBA16,
                    width: decoded.width,
                    height: decoded.height,
                    orientation: storageOrientation
                )
                guard oriented.width == size.0, oriented.height == size.1 else {
                    rawProvenance = enrichedProvenance.merging([
                        "fallbackReason": "raw-orientation-size-mismatch",
                    ]) { _, new in new }
                    throw CLIError.invalidContainer("RAW-assisted orientation did not match the SceneBundle dimensions")
                }
                rawLinearThumbnailInputRGBA16 = oriented.data
                rawProvenance = enrichedProvenance.merging([
                    "rawDNGOrientation": storageOrientation,
                    "rawPresentationSize": [oriented.width, oriented.height],
                    "fallbackReason": NSNull(),
                ]) { _, new in new }
            } catch {
                if rawLinearThumbnailInputRGBA16 == nil {
                    if rawProvenance["fallbackReason"] as? String == "raw-dng-not-evaluated" {
                        rawProvenance["fallbackReason"] = String(describing: error)
                    }
                }
                // An explicitly supplied DNG is a selected scene input, not an
                // optional hint. Keep this path fail-closed instead of emitting
                // a structurally valid but unrelated final-HEIC proxy.
                throw error
            }
        }
        return PhotoDerivedStyleSceneBundle(
            width: size.0,
            height: size.1,
            codedLinearEncodedRGB8: encoded,
            toneRGBAHalf: toneRGBAHalf,
            rendererLinearRGBA16: rendererLinearRGBA16,
            styleEngineWidth: styleEngineSize.0,
            styleEngineHeight: styleEngineSize.1,
            styleEngineToneRGBAHalf: styleEngineToneRGBAHalf,
            styleEngineRendererLinearRGBA16: styleEngineRendererLinearRGBA16,
            baseLinearP3RGB: baseRGB,
            hdrLinearP3RGB: hdrRGB,
            logGainRGB: logGainRGB,
            baseLuminance: baseLuminance,
            hdrLuminance: hdrLuminance,
            codedLinearLuminance: codedLinearLuminance,
            rendererLinearLuminance: rendererLinearLuminance,
            gtcMappedLuminance: gtcMappedLuminance,
            globalToneCurve: gtc.data,
            globalToneCurveLinearSamples: gtc.linearSamples,
            globalToneCurveFitRMSE: gtc.rmse,
            globalToneCurvePopulatedBins: gtc.populatedBins,
            globalToneCurveSourceFeature: gtc.sourceFeature,
            globalToneCurveClampedSourceFeature: gtc.clampedSourceFeature,
            contentHeadroom: max(1, hdrLuminance.max() ?? 1),
            baselineExposure: baselineExposure,
            baselineExposureUnclamped: linearMetadata.baselineExposureUnclamped,
            baselineHighlightCompressionRatio: linearMetadata.highlightCompressionRatio,
            linearBaseGain: baseGain,
            linearEncodingGain: encodingGain,
            rendererLinearRangeMin: rendererLinearMinimum.isFinite ? rendererLinearMinimum : 0,
            rendererLinearRangeMax: rendererLinearMaximum.isFinite ? rendererLinearMaximum : 0,
            researchLinearInputScale: researchLinearInputScale,
            researchScalarOverrides: researchScalarOverrides,
            gainMapMaximumStops: gainMapMaximumStops,
            rawLinearThumbnailInputRGBA16: rawLinearThumbnailInputRGBA16,
            rawProvenance: rawProvenance
        )
    }

    private static func writeRGBPNG(
        pixels: Data,
        width: Int,
        height: Int,
        outputURL: URL,
        colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()
    ) throws {
        guard pixels.count == width * height * 3,
              let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 24,
                  bytesPerRow: width * 3,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                  outputURL as CFURL,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              ) else {
            throw CLIError.invalidContainer("cannot create Apple auxiliary PNG writer input")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CLIError.invalidContainer("cannot finalize Apple auxiliary PNG writer input")
        }
    }

    private static func singleIDRPayload(from annexB: Data) throws -> Data {
        let bytes = [UInt8](annexB)
        var starts: [(offset: Int, length: Int)] = []
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1 {
                starts.append((index, 4)); index += 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index, 3)); index += 3
            } else {
                index += 1
            }
        }
        for position in starts.indices {
            let start = starts[position].offset + starts[position].length
            let end = position + 1 < starts.count ? starts[position + 1].offset : bytes.count
            guard start < end else { continue }
            let type = (bytes[start] >> 1) & 0x3f
            guard type == 19 || type == 20 else { continue }
            var result = Data()
            appendUInt32BE(end - start, to: &result)
            result.append(contentsOf: bytes[start..<end])
            return result
        }
        throw CLIError.invalidContainer("VideoToolbox emitted no HEVC IDR NAL")
    }

    private static func encodeHEVC(
        rgbPNGURL: URL,
        outputDirectory: URL,
        stem: String,
        quality: Double
    ) throws -> EncodedHEVCResource {
        let annexBURL = outputDirectory.appendingPathComponent("\(stem).hevc")
        let hvcCURL = outputDirectory.appendingPathComponent("\(stem).hvcc")
        let executable = try AppleNativeToolchain.hevcEncoderExecutable()
        let result = try AppleNativeToolchain.run(
            executable,
            arguments: [
                rgbPNGURL.path,
                annexBURL.path,
                String(format: "%.6f", quality),
                "rgb10",
                hvcCURL.path,
            ],
            timeout: 120
        )
        guard !result.timedOut, result.status == 0 else {
            let error = String(data: result.stderr, encoding: .utf8) ?? ""
            let timeout = result.timedOut ? "helper exceeded 120 seconds; " : ""
            throw CLIError.invalidContainer(
                "VideoToolbox auxiliary encoding failed: \(timeout)\(error)"
            )
        }
        let annexB = try Data(contentsOf: annexBURL)
        let hvcC = try Data(contentsOf: hvcCURL)
        let itemPayload = try singleIDRPayload(from: annexB)
        return EncodedHEVCResource(
            itemPayload: itemPayload,
            hvcC: hvcC,
            sourcePNGURL: rgbPNGURL,
            annexBSHA256: sha256Hex(annexB),
            itemPayloadSHA256: sha256Hex(itemPayload),
            hvcCSHA256: sha256Hex(hvcC)
        )
    }

    private static let neutralStyleDeltaAnnexBBase64 =
        "AAAAAUABDAH//wIgAAADALAAAAMAAAMAWhcCQAAAAAFCAQECIAAAAwCwAAADAAADAFqgBAIAgE2IF7kWVTUBAQYAgAAAAAFEAcBhYYKZIAAAAAFOAQUyR1ZK3FxMQz+U78URPNFDqAEAAAMAAwMAAAMAAQIADX//CwAAAwAAAwAACTgMA4kkAQ3/////gAAAAAEoAa+ECZVTMO7uzMzQ9ZgeLxZ1R1aDVgAB05uHr95rEzAAB4S4kDhbGcAAAAMBS2qCe6vPUAAAJCPAB5gdpAAAAwGoNAPFcBgAACpegAVc0/AAAOQeCCHz4AAEO1AKH14AABnCgAqiAAADADpXDf6vAACtUg/LMwAA2MQTG4YAA7CwFfqGAARh0BYf2AALhUAAAAMAAAS8"
    private static let neutralStyleDeltaHVCCBase64 =
        "AQIgAAAAsAAAAAAAWvAA/P36+gAACwOgAAEAGEABDAH//wIgAAADALAAAAMAAAMAWhcCQKEAAQAjQgEBAiAAAAMAsAAAAwAAAwBaoAQCAIBNiBe5FlU1AQEGAICiAAEACEQBwGFhgpkg"
    private static let neutralStyleDeltaAnnexBSHA256 =
        "d02017d9f516dbe7ef156bb92000311180cd4a1ff0aab1b3753bc2cc71ca8846"
    private static let neutralStyleDeltaItemSHA256 =
        "14b04fcde02476f24f83a893d245b4d06728954e8ad004f416b6e3a956eba216"
    private static let neutralStyleDeltaHVCCSHA256 =
        "35ecc004d07192f4e9c8a44c0a9edb598599b7a6d0c59b8165a5fb433f5746a5"

    private static func defaultNeutralStyleDeltaHEVC(
        sourcePNGURL: URL,
        outputDirectory: URL
    ) throws -> EncodedHEVCResource {
        guard let annexB = Data(base64Encoded: neutralStyleDeltaAnnexBBase64),
              let hvcC = Data(base64Encoded: neutralStyleDeltaHVCCBase64) else {
            throw CLIError.invalidContainer("bundled neutral Style Delta HEVC is malformed")
        }
        let itemPayload = try singleIDRPayload(from: annexB)
        guard sha256Hex(annexB) == neutralStyleDeltaAnnexBSHA256,
              sha256Hex(itemPayload) == neutralStyleDeltaItemSHA256,
              sha256Hex(hvcC) == neutralStyleDeltaHVCCSHA256 else {
            throw CLIError.invalidContainer("bundled neutral Style Delta HEVC failed integrity validation")
        }
        try annexB.write(
            to: outputDirectory.appendingPathComponent("style-delta-neutral-tile.hevc"),
            options: .atomic
        )
        try hvcC.write(
            to: outputDirectory.appendingPathComponent("style-delta-neutral-tile.hvcc"),
            options: .atomic
        )
        return EncodedHEVCResource(
            itemPayload: itemPayload,
            hvcC: hvcC,
            sourcePNGURL: sourcePNGURL,
            annexBSHA256: neutralStyleDeltaAnnexBSHA256,
            itemPayloadSHA256: neutralStyleDeltaItemSHA256,
            hvcCSHA256: neutralStyleDeltaHVCCSHA256
        )
    }

    package static func neutralStyleDeltaProtocolResourceHashes() throws -> [String: String] {
        guard let annexB = Data(base64Encoded: neutralStyleDeltaAnnexBBase64),
              let hvcC = Data(base64Encoded: neutralStyleDeltaHVCCBase64) else {
            throw CLIError.invalidContainer("bundled neutral Style Delta HEVC is malformed")
        }
        let itemPayload = try singleIDRPayload(from: annexB)
        return [
            "annexB": sha256Hex(annexB),
            "itemPayload": sha256Hex(itemPayload),
            "hvcC": sha256Hex(hvcC),
        ]
    }

    private static func percentile(_ sortedValues: [Double], _ percent: Double) -> Double {
        let values = sortedValues
        guard !values.isEmpty else { return 0 }
        let position = min(max(percent, 0), 100) / 100 * Double(values.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        guard lower != upper else { return values[lower] }
        let fraction = position - Double(lower)
        return values[lower] * (1 - fraction) + values[upper] * fraction
    }

    package static func distribution(_ values: [Float]) -> [String: Double] {
        let sorted = values.lazy.filter(\.isFinite).map(Double.init).sorted()
        guard !sorted.isEmpty else {
            return [
                "blackPoint": 0, "highKey": 1, "p02": 0, "p10": 0,
                "p25": 0, "p50": 0, "p75": 0, "p98": 0, "whitePoint": 0,
            ]
        }
        let names = ["blackPoint", "highKey", "p02", "p10", "p25", "p50", "p75", "p98", "whitePoint"]
        let percents = [0.5, 95, 2, 10, 25, 50, 75, 98, 99.5]
        return Dictionary(uniqueKeysWithValues: zip(names, percents.map { percentile(sorted, $0) }))
    }

    private static func maskValue(
        _ matte: AppleSemanticMatte?,
        x: Int,
        y: Int,
        rasterWidth: Int,
        rasterHeight: Int
    ) -> Float {
        guard let matte, matte.width > 0, matte.height > 0 else { return 0 }
        let sourceX = min(matte.width - 1, max(0, Int((Double(x) + 0.5) * Double(matte.width) / Double(rasterWidth))))
        let sourceY = min(matte.height - 1, max(0, Int((Double(y) + 0.5) * Double(matte.height) / Double(rasterHeight))))
        return Float(matte.pixels[sourceY * matte.bytesPerRow + sourceX]) / 255
    }

    // Stage A (response-v6): rasterize the skin matte onto a fixed normalized
    // presentation-space grid for the constrained solver's editor-response
    // objective.  maskValue keeps this consistent with every other semantic
    // sampling site in this pipeline.
    package static func solverSkinMask(
        _ matte: AppleSemanticMatte?,
        side: Int = 512
    ) -> ConstrainedPolynomialStyleDataProducer.ResponseSkinMask? {
        guard let matte, matte.statistics.coverage > 0, side > 0 else { return nil }
        var samples = [UInt8](repeating: 0, count: side * side)
        var positive = 0
        for y in 0..<side {
            for x in 0..<side {
                let value = maskValue(
                    matte, x: x, y: y, rasterWidth: side, rasterHeight: side
                )
                if value >= 0.5 {
                    samples[y * side + x] = 255
                    positive += 1
                }
            }
        }
        guard positive > 0 else { return nil }
        return ConstrainedPolynomialStyleDataProducer.ResponseSkinMask(
            width: side,
            height: side,
            samples: samples
        )
    }

    package static func selectedStyleSamples(
        toneLuma: [Float],
        hdrLuma: [Float],
        toneLinearRGB: [Float],
        width: Int,
        height: Int,
        person: AppleSemanticMatte?,
        skin: AppleSemanticMatte?
    ) -> [String: [Float]] {
        var personTone: [Float] = []
        var personHDR: [Float] = []
        var skinTone: [Float] = []
        var skinHDR: [Float] = []
        var skinRed: [Float] = []
        var skinGreen: [Float] = []
        var skinBlue: [Float] = []
        let reserve = width * height / 4
        personTone.reserveCapacity(reserve)
        personHDR.reserveCapacity(reserve)
        skinTone.reserveCapacity(reserve)
        skinHDR.reserveCapacity(reserve)
        skinRed.reserveCapacity(reserve / 2)
        skinGreen.reserveCapacity(reserve / 2)
        skinBlue.reserveCapacity(reserve / 2)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = y * width + x
                if maskValue(
                    person, x: x, y: y, rasterWidth: width, rasterHeight: height
                ) >= 0.5 {
                    personTone.append(toneLuma[pixel])
                    personHDR.append(hdrLuma[pixel])
                }
                if maskValue(
                    skin, x: x, y: y, rasterWidth: width, rasterHeight: height
                ) >= 0.5 {
                    skinTone.append(toneLuma[pixel])
                    skinHDR.append(hdrLuma[pixel])
                    skinRed.append(toneLinearRGB[pixel * 3])
                    skinGreen.append(toneLinearRGB[pixel * 3 + 1])
                    skinBlue.append(toneLinearRGB[pixel * 3 + 2])
                }
            }
        }
        return [
            "personTone": personTone,
            "personHDR": personHDR,
            "skinTone": skinTone,
            "skinHDR": skinHDR,
            "skinRed": skinRed,
            "skinGreen": skinGreen,
            "skinBlue": skinBlue,
        ]
    }

    private static func protocolIdentityGTC() -> Data {
        func sRGBEncode(_ linear: Double) -> Double {
            linear <= 0.0031308
                ? linear * 12.92
                : 1.055 * pow(linear, 1 / 2.4) - 0.055
        }
        var samples: [UInt16] = []
        samples.reserveCapacity(257)
        for index in 0..<256 {
            let encoded = min(max(sRGBEncode(Double(index) / 255), 0), 1)
            samples.append(UInt16(min(65_534, max(0, Int((encoded * 65_534).rounded())))))
        }
        samples[0] = 0
        samples[255] = 65_534
        for index in 1..<samples.count where samples[index] < samples[index - 1] {
            samples[index] = samples[index - 1]
        }
        samples.append(65_534)
        var payload = Data()
        var count = UInt16(257).littleEndian
        withUnsafeBytes(of: &count) { payload.append(contentsOf: $0) }
        for sample in samples {
            var value = sample.littleEndian
            withUnsafeBytes(of: &value) { payload.append(contentsOf: $0) }
        }
        return payload
    }

    private static func storageOrderedLightMap(
        _ presentationOrder: Data,
        width: Int,
        height: Int,
        orientation: UInt32
    ) throws -> Data {
        guard width == height, presentationOrder.count == width * height * 2 else {
            throw CLIError.invalidContainer("style light-map orientation requires a square packed Float16 plane")
        }
        let side = width
        var output = Data(count: presentationOrder.count)
        output.withUnsafeMutableBytes { outputRaw in
            presentationOrder.withUnsafeBytes { inputRaw in
                guard let destination = outputRaw.bindMemory(to: UInt16.self).baseAddress,
                      let source = inputRaw.bindMemory(to: UInt16.self).baseAddress else { return }
                for storageY in 0..<side {
                    for storageX in 0..<side {
                        let display: (x: Int, y: Int)
                        switch orientation {
                        case 2: display = (side - 1 - storageX, storageY)
                        case 3: display = (side - 1 - storageX, side - 1 - storageY)
                        case 4: display = (storageX, side - 1 - storageY)
                        case 5: display = (storageY, storageX)
                        case 6: display = (side - 1 - storageY, storageX)
                        case 7: display = (side - 1 - storageY, side - 1 - storageX)
                        case 8: display = (storageY, side - 1 - storageX)
                        default: display = (storageX, storageY)
                        }
                        destination[storageY * side + storageX] = source[display.y * side + display.x]
                    }
                }
            }
        }
        return output
    }

    package static func lightMap(
        _ luma: [Float],
        width: Int,
        height: Int,
        valueScale: Float,
        valueOffset: Float = 0,
        outputMinimum: Float = 0,
        outputMaximum: Float = 1,
        storageOrientation: UInt32
    ) throws -> Data {
        guard width > 0, height > 0, luma.count == width * height,
              valueScale.isFinite, valueOffset.isFinite,
              outputMinimum.isFinite, outputMaximum.isFinite,
              outputMinimum <= outputMaximum else {
            throw CLIError.invalidContainer("invalid source-derived style light-map contract")
        }
        var presentationOrder = Data()
        presentationOrder.reserveCapacity(32 * 32 * 2)
        for targetY in 0..<32 {
            let y0 = targetY * height / 32
            let y1 = max(y0 + 1, (targetY + 1) * height / 32)
            for targetX in 0..<32 {
                let x0 = targetX * width / 32
                let x1 = max(x0 + 1, (targetX + 1) * width / 32)
                var sum = Double(0)
                var count = 0
                for y in y0..<min(y1, height) {
                    for x in x0..<min(x1, width) {
                        let value = luma[y * width + x]
                        guard value.isFinite else { continue }
                        sum += Double(value)
                        count += 1
                    }
                }
                let average = count == 0 ? Float(0) : Float(sum / Double(count))
                let scaled = min(
                    max(average * valueScale + valueOffset, outputMinimum),
                    outputMaximum
                )
                var bits = XDRemuxHalf.encode(scaled).littleEndian
                withUnsafeBytes(of: &bits) { presentationOrder.append(contentsOf: $0) }
            }
        }
        return try storageOrderedLightMap(
            presentationOrder,
            width: 32,
            height: 32,
            orientation: storageOrientation
        )
    }

    private static func styleStatistics(
        bundle: PhotoDerivedStyleSceneBundle,
        semantics: AppleSemanticSceneAnalysis
    ) -> [String: [String: Double]] {
        let samples = selectedStyleSamples(
            toneLuma: bundle.baseLuminance,
            hdrLuma: bundle.rendererLinearLuminance,
            toneLinearRGB: bundle.baseLinearP3RGB,
            width: bundle.width,
            height: bundle.height,
            person: semantics.person,
            skin: semantics.skin
        )
        return [
            "LinearGTCImage": distribution(bundle.gtcMappedLuminance),
            "LinearImage": distribution(bundle.rendererLinearLuminance),
            "LinearImagePersonSegmentBased": distribution(samples["personHDR"] ?? []),
            "LinearImageSkinBased": distribution(samples["skinHDR"] ?? []),
            "ToneMappedImage": distribution(bundle.baseLuminance),
            "ToneMappedImageBlueChannelSkinBased": distribution(samples["skinBlue"] ?? []),
            "ToneMappedImageGreenChannelSkinBased": distribution(samples["skinGreen"] ?? []),
            "ToneMappedImagePersonSegmentBased": distribution(samples["personTone"] ?? []),
            "ToneMappedImageRedChannelSkinBased": distribution(samples["skinRed"] ?? []),
            "ToneMappedImageSkinBased": distribution(samples["skinTone"] ?? []),
        ]
    }

    private struct PhotoDerivedLocalScenePayload {
        let toneLightMap: Data
        let linearLightMap: Data
        let codedLinearMetadata: [String: Double]
        let nativeCodedLinearRGB8: Data?
        let statistics: [String: [String: Double]]?
        let extendedStatistics: [String: Double]?
        let producerManifest: [String: Any]
    }

    private static func rgb8FromNativeCodedLinearRGBAHalf(
        _ rgba: Data,
        width: Int,
        height: Int
    ) throws -> (pixels: Data, minimum: Float, maximum: Float) {
        guard width > 0, height > 0, rgba.count == width * height * 8 else {
            throw CLIError.invalidContainer(
                "native coded-linear raster does not match its declared dimensions"
            )
        }
        var output = Data(count: width * height * 3)
        var minimum = Float.infinity
        var maximum = -Float.infinity
        var finite = true
        output.withUnsafeMutableBytes { outputRaw in
            rgba.withUnsafeBytes { inputRaw in
                guard let destination = outputRaw.bindMemory(to: UInt8.self).baseAddress,
                      let source = inputRaw.bindMemory(to: UInt16.self).baseAddress else {
                    finite = false
                    return
                }
                for pixel in 0..<(width * height) {
                    for component in 0..<3 {
                        let bits = UInt16(littleEndian: source[pixel * 4 + component])
                        let value = XDRemuxHalf.decode(bits)
                        guard value.isFinite else {
                            finite = false
                            continue
                        }
                        minimum = min(minimum, value)
                        maximum = max(maximum, value)
                        destination[pixel * 3 + component] = UInt8(
                            min(255, max(0, Int((min(max(value, 0), 1) * 255).rounded())))
                        )
                    }
                }
            }
        }
        guard finite, minimum.isFinite, maximum.isFinite else {
            throw CLIError.invalidContainer("native coded-linear raster contains non-finite samples")
        }
        return (output, minimum, maximum)
    }

    private static func rasterizedMask(
        _ matte: AppleSemanticMatte?,
        width: Int,
        height: Int
    ) -> Data? {
        guard matte != nil else { return nil }
        var result = Data(count: width * height)
        result.withUnsafeMutableBytes { raw in
            guard let destination = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<height {
                for x in 0..<width {
                    destination[y * width + x] = UInt8(
                        min(255, max(0, Int((maskValue(
                            matte,
                            x: x,
                            y: y,
                            rasterWidth: width,
                            rasterHeight: height
                        ) * 255).rounded())))
                    )
                }
            }
        }
        return result
    }

    private static func behaviorEquivalentPhotoDerivedScenePayload(
        bundle: PhotoDerivedStyleSceneBundle,
        storageOrientation: UInt32
    ) throws -> PhotoDerivedLocalScenePayload {
        // Eight native samples establish that serialized c/d are positive
        // light maps, not signed residual planes. c tracks tone-mapped Base;
        // d tracks the coded-linear image after GTC. The signed local decision
        // is retained by their relationship. Coefficients below are the
        // aggregate native-corpus affine calibration and are intentionally
        // reported as behavior-equivalent rather than camera-producer exact.
        let toneScale = Float(0.71372382)
        let toneOffset = Float(0.02554340)
        let linearScale = Float(0.93942103)
        let linearOffset = Float(0.06494295)
        let toneLightMap = try lightMap(
            bundle.baseLuminance,
            width: bundle.width,
            height: bundle.height,
            valueScale: toneScale,
            valueOffset: toneOffset,
            outputMinimum: toneLightMapMinimum,
            outputMaximum: toneLightMapMaximum,
            storageOrientation: storageOrientation
        )
        let linearLightMap = try lightMap(
            bundle.gtcMappedLuminance,
            width: bundle.width,
            height: bundle.height,
            valueScale: linearScale,
            valueOffset: linearOffset,
            outputMinimum: linearLightMapMinimum,
            outputMaximum: linearLightMapMaximum,
            storageOrientation: storageOrientation
        )
        let signedRelation = zip(bundle.baseLuminance, bundle.gtcMappedLuminance).map {
            $0.0 - $0.1
        }
        let rangeMin = Double(bundle.rendererLinearRangeMin)
        let rangeMax = max(rangeMin, Double(bundle.rendererLinearRangeMax))
        return PhotoDerivedLocalScenePayload(
            toneLightMap: toneLightMap,
            linearLightMap: linearLightMap,
            codedLinearMetadata: [
                "Gain": Double(bundle.linearEncodingGain),
                "OriginalRangeMin": rangeMin,
                "OriginalRangeMax": rangeMax,
            ],
            nativeCodedLinearRGB8: nil,
            statistics: nil,
            extendedStatistics: nil,
            producerManifest: [
                "mode": "source-derived-behavior-equivalent-v1",
                "status": "success",
                "nativeProducerExact": false,
                "fallbackKind": "explicit-cpu-behavioral-proxy",
                "consumerExactForProvidedLinearInput": false,
                "cameraProducerExact": false,
                "captureTimePreLTMInputAvailable": false,
                "behaviorEquivalentLinearInputValidated": false,
                "inputDomain": "single SceneDomainBundle in extended-linear Display-P3",
                "toneMapModel": [
                    "source": "tone-mapped Base luminance",
                    "scale": toneScale,
                    "offset": toneOffset,
                    "serializedMinimum": toneLightMapMinimum,
                    "serializedMaximum": toneLightMapMaximum,
                    "nativeCorpusAggregateCorrelation": 0.96750403,
                    "nativeCorpusAggregateRMSE": 0.04013455,
                ],
                "linearMapModel": [
                    "source": "GTC(coded-linear luminance)",
                    "scale": linearScale,
                    "offset": linearOffset,
                    "serializedMinimum": linearLightMapMinimum,
                    "serializedMaximum": linearLightMapMaximum,
                    "nativeCorpusAggregateCorrelation": 0.94580707,
                    "nativeCorpusAggregateRMSE": 0.06546827,
                ],
                "signedLocalRelation": distribution(signedRelation),
                "negativeSerializedSamplesAllowed": false,
                "coordinateOrder": "primary-item-storage",
                "claimBoundary": "the final HEIC does not retain Apple's capture-time pre-LTM thumbnail; this explicit CPU path is a final-HEIC proxy and has not passed the native full-response envelope",
            ]
        )
    }

    private static func nativePhotoDerivedScenePayload(
        bundle: PhotoDerivedStyleSceneBundle,
        semantics: AppleSemanticSceneAnalysis,
        sceneType: Int,
        faceExposureBoost: Double,
        storageOrientation: UInt32,
        outputDirectory: URL,
        useRawInput: Bool = true
    ) throws -> PhotoDerivedLocalScenePayload {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("xdremux-style-scene-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }
        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let toneURL = temporaryDirectory.appendingPathComponent("tone.rgba16f")
        let thumbnailURL = temporaryDirectory.appendingPathComponent(
            "style-engine-thumbnail.rgba16f"
        )
        let linearURL = temporaryDirectory.appendingPathComponent("linear.rgba16unorm")
        let gtcURL = temporaryDirectory.appendingPathComponent("global-tone-curve.bin")
        try bundle.toneRGBAHalf.write(to: toneURL, options: .atomic)
        try bundle.styleEngineToneRGBAHalf.write(to: thumbnailURL, options: .atomic)
        let rawInput = useRawInput ? bundle.rawLinearThumbnailInputRGBA16 : nil
        let rawProvenance = useRawInput
            ? bundle.rawProvenance
            : bundle.rawProvenance.merging([
                "fallbackReason": "private-consumer-raw-input-failed",
            ]) { _, new in new }
        let linearInputRGBA16 = rawInput
            ?? bundle.rendererLinearRGBA16
        try linearInputRGBA16.write(to: linearURL, options: .atomic)
        try bundle.globalToneCurve.write(to: gtcURL, options: .atomic)

        var request: [String: Any] = [
            "schema": "xdremux-native-photo-derived-style-scene-request-v1",
            "width": bundle.width,
            "height": bundle.height,
            "toneRGBAHalfPath": toneURL.path,
            "thumbnailWidth": bundle.styleEngineWidth,
            "thumbnailHeight": bundle.styleEngineHeight,
            "thumbnailRGBAHalfPath": thumbnailURL.path,
            "normalizedLinearRGBA16Path": linearURL.path,
            "globalToneCurvePath": gtcURL.path,
            "outputDirectory": temporaryDirectory.path,
            "encodingGain": bundle.linearEncodingGain,
            "ltmRelativeBrightness": 1.0,
            "hrGainDownRatioQ12": Int(
                (Double(bundle.linearEncodingGain) * 4096).rounded()
            ),
            "brightnessValue": 0.0,
            "sceneType": sceneType,
            "personMasksValidHint": semantics.hasCrediblePerson ? 1.0 : -1.0,
            "faceBasedGlobalExposureBoostRatio": faceExposureBoost,
            "processingType": 5,
            "linearThumbnailInputSource": rawInput == nil
                ? "final-HEIC-proxy"
                : "CIRAWNeutral-processed-linear-RGB-candidate",
            "rawProvenance": rawProvenance,
        ]
        for (key, matte) in [
            ("personMaskPath", semantics.person),
            ("skinMaskPath", semantics.skin),
            ("skyMaskPath", semantics.sky),
        ] {
            guard let data = rasterizedMask(
                matte,
                width: bundle.width,
                height: bundle.height
            ) else {
                continue
            }
            let url = temporaryDirectory.appendingPathComponent("\(key).l008")
            try data.write(to: url, options: .atomic)
            request[key] = url.path
        }
        let requestURL = temporaryDirectory.appendingPathComponent("request.json")
        let requestJSON = try JSONSerialization.data(
            withJSONObject: request,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try requestJSON.write(to: requestURL, options: .atomic)
        let executable = try AppleNativeToolchain.styleScenePayloadExecutable()
        let result = try AppleNativeToolchain.run(
            executable,
            arguments: ["--produce-photo-derived-scene", requestURL.path],
            timeout: 30
        )
        let persistentReportURL = outputDirectory.appendingPathComponent(
            "native-photo-derived-scene-payload.json"
        )
        try result.stdout.write(to: persistentReportURL, options: .atomic)
        guard !result.timedOut,
              result.status == 0,
              let report = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              report["status"] as? String == "success",
              let outputs = report["outputs"] as? [String: Any],
              let toneMapPath = outputs["smallLightMapPath"] as? String,
              let linearMapPath = outputs["smallLinearLightMapPath"] as? String,
              let codedLinearPath = outputs["codedLinearPath"] as? String,
              let rawStatistics = report["statistics"] as? [String: Any],
              let rawExtendedStatistics = report["extendedStatistics"] as? [String: Any],
              let codedMetadataNumbers = report["codedLinearMetadata"] as? [String: NSNumber] else {
            if useRawInput, bundle.rawLinearThumbnailInputRGBA16 != nil {
                let diagnostic = String(data: result.stderr, encoding: .utf8) ?? ""
                throw CLIError.invalidContainer(
                    "native photo-derived scene producer rejected the supplied RAW input: \(diagnostic)"
                )
            }
            let diagnostic = String(data: result.stderr, encoding: .utf8) ?? ""
            throw CLIError.invalidContainer(
                "native photo-derived style scene producer failed: \(diagnostic)"
            )
        }
        let presentationToneMap = try Data(contentsOf: URL(fileURLWithPath: toneMapPath))
        let presentationLinearMap = try Data(contentsOf: URL(fileURLWithPath: linearMapPath))
        let codedLinearRGBAHalf = try Data(
            contentsOf: URL(fileURLWithPath: codedLinearPath),
            options: [.mappedIfSafe]
        )
        let nativeCodedLinear = try rgb8FromNativeCodedLinearRGBAHalf(
            codedLinearRGBAHalf,
            width: bundle.width,
            height: bundle.height
        )
        guard presentationToneMap.count == 2_048,
              presentationLinearMap.count == 2_048 else {
            throw CLIError.invalidContainer(
                "native photo-derived style scene producer returned non-32x32 light maps"
            )
        }
        let toneMap = try storageOrderedLightMap(
            presentationToneMap,
            width: 32,
            height: 32,
            orientation: storageOrientation
        )
        let linearMap = try storageOrderedLightMap(
            presentationLinearMap,
            width: 32,
            height: 32,
            orientation: storageOrientation
        )
        let codedMetadata = Dictionary(uniqueKeysWithValues: codedMetadataNumbers.map {
            ($0.key, $0.value.doubleValue)
        })
        let requiredStatisticNames = Set([
            "LinearGTCImage",
            "LinearImage",
            "LinearImagePersonSegmentBased",
            "LinearImageSkinBased",
            "ToneMappedImage",
            "ToneMappedImageBlueChannelSkinBased",
            "ToneMappedImageGreenChannelSkinBased",
            "ToneMappedImagePersonSegmentBased",
            "ToneMappedImageRedChannelSkinBased",
            "ToneMappedImageSkinBased",
        ])
        let requiredStatisticFields = Set([
            "blackPoint", "highKey", "p02", "p10", "p25",
            "p50", "p75", "p98", "whitePoint",
        ])
        var nativeStatistics: [String: [String: Double]] = [:]
        for (name, rawDistribution) in rawStatistics {
            guard let numbers = rawDistribution as? [String: NSNumber] else {
                throw CLIError.invalidContainer(
                    "native photo-derived style scene producer returned malformed statistics"
                )
            }
            let distribution = Dictionary(uniqueKeysWithValues: numbers.map {
                ($0.key, $0.value.doubleValue)
            })
            guard Set(distribution.keys) == requiredStatisticFields,
                  distribution.values.allSatisfy(\.isFinite) else {
                throw CLIError.invalidContainer(
                    "native photo-derived style scene producer returned incomplete statistics"
                )
            }
            nativeStatistics[name] = distribution
        }
        guard Set(nativeStatistics.keys) == requiredStatisticNames else {
            throw CLIError.invalidContainer(
                "native photo-derived style scene producer omitted required statistics"
            )
        }
        let nativeExtendedStatistics: [String: Double] = Dictionary(
            uniqueKeysWithValues: rawExtendedStatistics.compactMap { element in
                let (key, value) = element
                guard let number = value as? NSNumber,
                      number.doubleValue.isFinite else { return nil }
                return (key, number.doubleValue)
            }
        )
        guard let nativePeopleRatio = nativeExtendedStatistics["PeopleRatio"],
              let nativeSkinRatio = nativeExtendedStatistics["SkinRatio"],
              (0...1).contains(nativePeopleRatio),
              (0...1).contains(nativeSkinRatio) else {
            throw CLIError.invalidContainer(
                "native photo-derived style scene producer omitted semantic ratios"
            )
        }
        guard let nativeGain = codedMetadata["Gain"],
              abs(nativeGain - Double(bundle.linearEncodingGain)) <= 1 / 256 else {
            throw CLIError.invalidContainer(
                "native Linear Thumbnail gain does not match the SceneBundle normalization gain"
            )
        }
        return PhotoDerivedLocalScenePayload(
            toneLightMap: toneMap,
            linearLightMap: linearMap,
            codedLinearMetadata: codedMetadata,
            nativeCodedLinearRGB8: nativeCodedLinear.pixels,
            statistics: nativeStatistics,
            extendedStatistics: nativeExtendedStatistics,
            producerManifest: [
                "mode": rawInput == nil
                    ? "native-cmimaging-final-heic-proxy-v1"
                    : "native-cmimaging-coreimage-raw-v1",
                "status": report["status"] ?? "unknown",
                "nativeProducerExact": false,
                "consumerExactForProvidedLinearInput": rawInput == nil,
                "cameraProducerExact": false,
                "captureTimePreLTMInputAvailable": false,
                "behaviorEquivalentLinearInputValidated": false,
                "fallbackKind": rawInput == nil
                    ? "missing-capture-time-pre-ltm-input"
                    : NSNull(),
                "negativeSerializedSamplesAllowed": false,
                "coordinateOrder": "primary-item-storage",
                "class": "CMISmartStylePixelBufferRendererV1",
                "processingType": 5,
                "providedLinearInput": rawInput == nil
                    ? "same-photo reconstructed HDR / (source-derived key4 * source-derived i.Gain)"
                    : "CIRAWFilter neutral processed-linear RGB, preview-paired and exposure-calibrated",
                "appleCaptureInput": "SmartStyleV1 smartStyleCreateLinearThumbnail output: capture-time pre-LTM RGB in valid bounds, with post-LTM seam fill outside bounds",
                "claimBoundary": "the private consumer is exact for the supplied buffer, but the supplied final-HEIC proxy is not the Apple camera producer input",
                "rawProvenance": rawProvenance,
                "boundedProxyValidation": [
                    "nativeReferencePhoto": "IMG_2903",
                    "directToneChecks": 472,
                    "nativeControlFailures": 1,
                    "finalBaseProxyFailures": 96,
                    "finalHDROverKey4ProxyFailures": 67,
                    "bestTestedHDROverKey4HSquaredProxyFailures": 13,
                    "heldOutGlobalAffineProxyFailures": 17,
                    "crossPhotoAffineLOORMSEMean": 0.01731073,
                    "conclusion": "no tested final-HEIC proxy is admitted as capture-linear behavior-equivalent",
                ],
                "reportSHA256": sha256Hex(result.stdout),
                "codedLinearMetadata": codedMetadata,
                "codedLinearOutput": [
                    "width": bundle.width,
                    "height": bundle.height,
                    "rgba16fSHA256": sha256Hex(codedLinearRGBAHalf),
                    "rgb8SHA256": sha256Hex(nativeCodedLinear.pixels),
                    "minimum": nativeCodedLinear.minimum,
                    "maximum": nativeCodedLinear.maximum,
                    "encoding": "CMISmartStylePixelBufferRendererV1 outputCodedLinearPixelBuffer; direct finite [0,1] quantization for HEVC input",
                ],
                "statisticsSource": "CMISmartStylePixelBufferRendererV1.outputImageStatistics",
                "extendedStatisticsSource": "CMISmartStylePixelBufferRendererV1.outputImageStatisticsExtended",
            ]
        )
    }

    private static func photoDerivedLocalScenePayload(
        bundle: PhotoDerivedStyleSceneBundle,
        semantics: AppleSemanticSceneAnalysis,
        sceneType: Int,
        faceExposureBoost: Double,
        storageOrientation: UInt32,
        outputDirectory: URL
    ) throws -> PhotoDerivedLocalScenePayload {
        let requested = ProcessInfo.processInfo.environment[
            "XDREMUX_STYLES_SCENE_PRODUCER"
        ]?.lowercased() ?? "native-cmimaging"
        switch requested {
        case "source-derived-behavior-equivalent-v1", "behavior-equivalent", "cpu":
            return try behaviorEquivalentPhotoDerivedScenePayload(
                bundle: bundle,
                storageOrientation: storageOrientation
            )
        case "native-cmimaging", "native":
            // The private consumer is exact for the provided buffer, but the
            // final-HEIC-derived buffer is explicitly a research candidate:
            // Apple's capture-time pre-LTM input is unavailable. Failure is
            // fatal; there is no silent CPU fallback after native was selected.
            return try nativePhotoDerivedScenePayload(
                bundle: bundle,
                semantics: semantics,
                sceneType: sceneType,
                faceExposureBoost: faceExposureBoost,
                storageOrientation: storageOrientation,
                outputDirectory: outputDirectory
            )
        default:
            throw CLIError.invalidContainer(
                "unknown XDREMUX_STYLES_SCENE_PRODUCER mode: \(requested)"
            )
        }
    }

    private struct PhotoDerivedSceneClassification {
        let sceneType: Int
        let sceneDependentFallback: Bool
        let evidence: [String: Any]
    }

    private static func photoDerivedSceneClassification(
        imageURL: URL
    ) throws -> PhotoDerivedSceneClassification {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(url: imageURL)
        try handler.perform([request])
        let observations = request.results ?? []
        let confidenceByIdentifier = Dictionary(
            observations.map { ($0.identifier.lowercased(), Double($0.confidence)) },
            uniquingKeysWith: max
        )
        func maximum(_ identifiers: [String]) -> Double {
            identifiers.map { confidenceByIdentifier[$0] ?? 0 }.max() ?? 0
        }
        let food = maximum(["food", "meal", "dish"])
        let sunset = maximum(["sunset", "sunrise", "dusk"])
        let indoor = maximum(["indoor", "interior", "room"])
        let outdoor = maximum(["outdoor"])

        // iPhone 18,1 camera firmware classifies in this priority order with
        // private confidence cutoffs: food > sunset > indoor > outdoor. The
        // method leaves the zero-initialized sceneType unchanged when none of
        // the four branches fires, so 0 is the native default category rather
        // than an XDRemux identity placeholder. Public Vision scores are not
        // on the private SmartCam calibration; the proxy thresholds below are
        // deliberately recorded as behavioral and are not camera-equivalent.
        let sceneType: Int
        let selectedClass: String
        let nativeDefaultApplied: Bool
        if food >= 0.08 {
            sceneType = 1
            selectedClass = "food"
            nativeDefaultApplied = false
        } else if sunset >= 0.08 {
            sceneType = 3
            selectedClass = "sunset"
            nativeDefaultApplied = false
        } else if indoor >= 0.15 {
            sceneType = 0
            selectedClass = "indoor"
            nativeDefaultApplied = false
        } else if outdoor >= 0.15 {
            sceneType = 2
            selectedClass = "outdoor"
            nativeDefaultApplied = false
        } else {
            sceneType = 0
            selectedClass = "native-default"
            nativeDefaultApplied = true
        }
        return PhotoDerivedSceneClassification(
            sceneType: sceneType,
            sceneDependentFallback: false,
            evidence: [
                "algorithm": "VNClassifyImageRequest behavioral proxy following iPhone18,1 scene-type priority",
                "producerEvidence": [
                    "foodThreshold": 0.77,
                    "sunsetThreshold": 0.88,
                    "indoorThreshold": 0.4,
                    "outdoorThreshold": 0.58,
                    "priority": ["food", "sunset", "indoor", "outdoor"],
                    "source": "-[BWStillImageCaptureMetadata calculateSemanticStyleSceneType] iPhone18,1/23F84",
                ],
                "proxyThresholds": [
                    "food": 0.08,
                    "sunset": 0.08,
                    "indoor": 0.15,
                    "outdoor": 0.15,
                ],
                "scores": [
                    "food": food,
                    "sunset": sunset,
                    "indoor": indoor,
                    "outdoor": outdoor,
                ],
                "selectedClass": selectedClass,
                "sceneType": sceneType,
                "nativeDefaultSceneType": 0,
                "nativeDefaultApplied": nativeDefaultApplied,
                "sceneDependentFallback": false,
                "cameraProducerExact": false,
                "proxyCalibration": "heuristic; not numerically calibrated to private SmartCam scores",
                "claimBoundary": "source-derived behavioral classifier; not Apple camera classifier numerical equivalence",
            ]
        )
    }

    private static func photoDerivedFaceExposureBoost(
        statistics: [String: [String: Double]],
        semantics: AppleSemanticSceneAnalysis
    ) -> (value: Double, evidence: [String: Any]) {
        let globalMedian = statistics["ToneMappedImage"]?["p50"] ?? 0
        let personMedian = statistics["ToneMappedImagePersonSegmentBased"]?["p50"] ?? 0
        let peopleRatio = min(max((semantics.person?.statistics.mean ?? 0) / 255, 0), 1)
        let value: Double
        if semantics.hasCrediblePerson, personMedian > 0, globalMedian > 0 {
            value = min(max(sqrt(globalMedian / personMedian), 1), 2.5)
        } else {
            value = 1
        }
        return (value, [
            "algorithm": "clamp(sqrt(global tone p50 / person tone p50), 1.0, 2.5)",
            "value": value,
            "globalToneP50": globalMedian,
            "personToneP50": personMedian,
            "peopleRatio": peopleRatio,
            "sourceDependent": true,
            "claimBoundary": "source-derived exposure proxy within the native observed range; camera face-AE numerical equivalence is not claimed",
        ])
    }

    private static func makeStylePropertyList(
        styleData: AppleStyleDataResult,
        bundle: PhotoDerivedStyleSceneBundle,
        semantics: AppleSemanticSceneAnalysis,
        sceneClassification: PhotoDerivedSceneClassification,
        storageOrientation: UInt32,
        outputDirectory: URL
    ) throws -> (
        data: Data,
        manifest: [String: Any],
        linearThumbnailSource: String,
        rawProvenance: [String: Any],
        nativeCodedLinearRGB8: Data?
    ) {
        let gtc = bundle.globalToneCurve
        guard gtc.count == 516 else {
            throw CLIError.invalidContainer("generated GTC must be 516 bytes")
        }
        let preliminaryStatistics = styleStatistics(bundle: bundle, semantics: semantics)
        guard preliminaryStatistics["LinearImage"] != nil,
              preliminaryStatistics["ToneMappedImage"] != nil else {
            throw CLIError.invalidContainer("generated style statistics are incomplete")
        }
        let faceBoost = photoDerivedFaceExposureBoost(
            statistics: preliminaryStatistics,
            semantics: semantics
        )
        let localScene = try photoDerivedLocalScenePayload(
            bundle: bundle,
            semantics: semantics,
            sceneType: sceneClassification.sceneType,
            faceExposureBoost: faceBoost.value,
            storageOrientation: storageOrientation,
            outputDirectory: outputDirectory
        )
        let rawInputUsed = localScene.producerManifest["mode"] as? String
            == "native-cmimaging-coreimage-raw-v1"
        let linearThumbnailSource = rawInputUsed
            ? "CIRAWNeutral-processed-linear-RGB-candidate"
            : "final-HEIC-proxy"
        var effectiveRawProvenance = bundle.rawProvenance
        if let producerRawProvenance = localScene.producerManifest["rawProvenance"] as? [String: Any] {
            effectiveRawProvenance = producerRawProvenance
        } else if !rawInputUsed, bundle.rawLinearThumbnailInputRGBA16 != nil {
            effectiveRawProvenance["fallbackReason"] = "selected-scene-producer-did-not-use-raw-input"
        }
        let toneLightMap = localScene.toneLightMap
        let linearLightMap = localScene.linearLightMap
        let statistics = localScene.statistics ?? preliminaryStatistics
        guard toneLightMap.count == 2_048, linearLightMap.count == 2_048 else {
            throw CLIError.invalidContainer("generated style light maps must each be 2,048 bytes")
        }
        let baselineExposure = Double(bundle.baselineExposure)
        let peopleRatio = min(max(
            localScene.extendedStatistics?["PeopleRatio"]
                ?? (semantics.person?.statistics.mean ?? 0) / 255,
            0
        ), 1)
        let skinRatio = min(max(
            localScene.extendedStatistics?["SkinRatio"]
                ?? (semantics.skin?.statistics.mean ?? 0) / 255,
            0
        ), 1)
        let personMasksValidHint = semantics.hasCrediblePerson ? 1.0 : -1.0
        let sceneType = sceneClassification.sceneType
        let baseGain = Double(bundle.linearBaseGain)
        guard let rangeMin = localScene.codedLinearMetadata["OriginalRangeMin"],
              let rangeMax = localScene.codedLinearMetadata["OriginalRangeMax"],
              let encodingGain = localScene.codedLinearMetadata["Gain"] else {
            throw CLIError.invalidContainer(
                "photo-derived scene producer omitted required Linear Thumbnail metadata"
            )
        }
        guard abs(encodingGain - 4 * baseGain) <= 1 / 256 else {
            throw CLIError.invalidContainer(
                "photo-derived Linear Thumbnail metadata violates i.Gain = 4h"
            )
        }
        let object: [String: Any] = [
            "0": 15,
            "1": styleData.styleData,
            "2": true,
            "3": gtc,
            "4": baselineExposure,
            "5": sceneType,
            "6": statistics,
            "7": [
                "PeopleRatio": peopleRatio,
                "PersonMasksValidHint": personMasksValidHint,
                "SkinRatio": skinRatio,
            ],
            "c": toneLightMap,
            "d": linearLightMap,
            "e": 32,
            "f": 32,
            "g": 0x4C303068,
            "h": baseGain,
            "i": [
                "Gain": encodingGain,
                "OriginalRangeMin": rangeMin,
                "OriginalRangeMax": rangeMax,
            ],
            "j": faceBoost.value,
            "k": false,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: object,
            format: .binary,
            options: 0
        )
        guard data.starts(with: Data("bplist00".utf8)),
              let readback = try PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let styleReadback = readback["1"] as? Data,
              styleReadback == styleData.styleData else {
            throw CLIError.invalidContainer("style plist key 1 readback differs from generated style data")
        }
        var styleDataManifest = styleData.manifest
        styleDataManifest["evidence"] = styleData.evidence.rawValue
        return (
            data: data,
            manifest: [
            "schema": "xdremux-apple-photographic-style-payload-v2",
            "styleVersion": 15,
            "styleData": styleDataManifest,
            "sceneDomainBundle": [
                "schema": "xdremux-photo-derived-style-scene-bundle-v1",
                "workingColorSpace": "extended-linear-Display-P3",
                "baseDomain": "ICC-managed primary image converted once to linear Display-P3",
                "gainMapDomain": "unmanaged normalized per-channel code values decoded once with source metadata",
                "hdrDomain": "per-channel reconstructed linear Display-P3",
                "luminanceCoefficients": [0.22897456, 0.69173852, 0.07928691],
                "workingDimensions": ["width": bundle.width, "height": bundle.height],
                "styleEngineDimensions": [
                    "width": bundle.styleEngineWidth,
                    "height": bundle.styleEngineHeight,
                ],
                "presentationOrientationApplied": true,
                "storageOrientation": storageOrientation,
                "baselineExposure": bundle.baselineExposure,
                "baselineExposureUnclamped": bundle.baselineExposureUnclamped,
                "baselineHighlightCompressionRatio": bundle.baselineHighlightCompressionRatio,
                "baselineHighlightCompressionCalibration": baselineHighlightCompressionCalibration,
                "gainMapMaximumStops": bundle.gainMapMaximumStops,
                "linearBaseGain": bundle.linearBaseGain,
                "linearEncodingGain": bundle.linearEncodingGain,
                "contentHeadroom": bundle.contentHeadroom,
                "rendererInputLinearDomain": "reconstructed HDR / (key4 baseline exposure * i.Gain); i.Gain carries the paired inverse encoding scale",
                "rendererInputLinearRange": [
                    "minimum": bundle.rendererLinearRangeMin,
                    "maximum": bundle.rendererLinearRangeMax,
                ],
                "researchLinearInputScale": bundle.researchLinearInputScale,
                "researchScalarOverrides": bundle.researchScalarOverrides,
                "researchOverrideActive": bundle.researchLinearInputScale != 1
                    || !bundle.researchScalarOverrides.isEmpty,
                "negativeLogGainPreserved": (bundle.logGainRGB.min() ?? 0) < 0,
                "logGainRange": [
                    "minimum": bundle.logGainRGB.min() ?? 0,
                    "maximum": bundle.logGainRGB.max() ?? 0,
                ],
                "resourceDecodeCount": 1,
                "linearThumbnailSource": linearThumbnailSource,
                "rawAssistedLinearThumbnail": effectiveRawProvenance,
            ],
            "gtc": [
                "byteCount": gtc.count,
                "sha256": sha256Hex(gtc),
                "algorithm": "per-photo-native-family-gtc-v1",
                "inputDomain": "paired reconstructed HDR and Base luminance, each normalized by its same-photo p95",
                "outputDomain": "native 256-sample normalized global-tone-shape family",
                "sourceShapeFeature": bundle.globalToneCurveSourceFeature,
                "clampedSourceShapeFeature": bundle.globalToneCurveClampedSourceFeature,
                "sourceShapeFeatureIndex": 8,
                "sourceShapeFeatureNativeP01P99": [0.036004916, 0.083503760],
                "sourceShapeFitRMSE": bundle.globalToneCurveFitRMSE,
                "populatedBins": bundle.globalToneCurvePopulatedBins,
                "nativeCalibration": [
                    "sampleCount": 84,
                    "applicableHAtLeastOneSampleCount": 71,
                    "basis": "x + sum(coefficient[k] * x * (1 - x) * (1 - 2x)^k), k=0...9",
                    "leaveOneOutCurveRMSEMean": 0.002697,
                    "leaveOneOutCurveRMSEP95": 0.007052,
                    "leaveOneOutCurveRMSEMaximum": 0.015014,
                    "claimBoundary": "behavior-equivalent native-family calibration; Apple ISP GTC producer equivalence is not claimed",
                ],
                "monotonic": true,
                "fixedProtocolConstant": false,
                "sourceDependent": true,
            ],
            "statistics": statistics,
            "statisticsProducer": localScene.statistics == nil
                ? "explicit CPU behavioral proxy"
                : "CMISmartStylePixelBufferRendererV1",
            "peopleRatio": peopleRatio,
            "skinRatio": skinRatio,
            "personMasksValidHint": personMasksValidHint,
            "sceneType": sceneType,
            "sceneClassification": sceneClassification.evidence,
            "baselineExposure": baselineExposure,
            "baselineExposureProducer": [
                "nativeFormula": "4 * LTMDigitalGain",
                "sourceFieldAvailable": false,
                "behaviorEquivalentFormula": "quantize_1_over_65((HDR_p98 / Base_p98) / 0.40126406)",
                "unclamped": bundle.baselineExposureUnclamped,
                "clamped": bundle.baselineExposure,
                "sourceDependent": true,
            ],
            "baseGain": baseGain,
            "linearEncodingGain": encodingGain,
            "linearMetadataProducer": [
                "nativeEncodingFormula": "(HRGainDownRatio / 4096) / LTMRelativeBrightness",
                "nativeBaseGainFormula": "i.Gain / 4",
                "sourceFieldsAvailable": false,
                "behaviorEquivalentBaseGainFormula": "clamp(1.51271843 + 0.15670632 * GainMapMaxStops + 0.14766724 * (HDR_p98 / Base_p98), 0.5, 2.5)",
                "nativeEightSceneFitRMSE": 0.0261,
                "nativeEightSceneLOORMSE": 0.0403,
                "sourceDependent": true,
                "cameraProducerExact": false,
            ],
            "linearRange": ["minimum": rangeMin, "maximum": rangeMax],
            "faceExposureBoost": faceBoost.evidence,
            "localSceneProducer": localScene.producerManifest,
            "lightMap": [
                "byteCount": toneLightMap.count,
                "sha256": sha256Hex(toneLightMap),
                "coordinateOrder": "primary-item-storage",
                "sourceOrientation": storageOrientation,
                "producer": localScene.producerManifest["mode"] ?? "unknown",
                "inputDomain": "linear Display-P3 Base plus per-photo GTC and semantic masks",
                "fixedProtocolConstant": false,
            ],
            "linearLightMap": [
                "byteCount": linearLightMap.count,
                "sha256": sha256Hex(linearLightMap),
                "coordinateOrder": "primary-item-storage",
                "sourceOrientation": storageOrientation,
                "producer": localScene.producerManifest["mode"] ?? "unknown",
                "inputDomain": "GTC(coded-linear Display-P3 HDR)",
                "linearBaseGainApplied": true,
                "linearEncodingGain": encodingGain,
                "fixedProtocolConstant": false,
            ],
            "stylePropertyList": ["byteCount": data.count, "sha256": sha256Hex(data), "format": "binary plist v1 CF format 200"],
            ],
            linearThumbnailSource: linearThumbnailSource,
            rawProvenance: effectiveRawProvenance,
            nativeCodedLinearRGB8: localScene.nativeCodedLinearRGB8
        )
    }

    private static func validateWithSemanticStyleProperties(
        stylePropertyList: Data,
        expectedStyleData: Data,
        outputDirectory: URL
    ) throws -> [String: Any] {
        let metadataURL = outputDirectory.appendingPathComponent("style-metadata.bplist")
        let readbackURL = outputDirectory.appendingPathComponent("style-data-neutrino-readback.bin")
        let probeURL = outputDirectory.appendingPathComponent("semantic-style-properties-probe.json")
        try stylePropertyList.write(to: metadataURL, options: .atomic)
        let executable = try AppleNativeToolchain.stylePropertiesProbeExecutable()
        let result = try AppleNativeToolchain.run(
            executable,
            arguments: [metadataURL.path, readbackURL.path],
            timeout: 30
        )
        try result.stdout.write(to: probeURL, options: .atomic)
        guard !result.timedOut,
              result.status == 0,
              let readback = try? Data(contentsOf: readbackURL),
              readback == expectedStyleData,
              let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              object["parseSucceeded"] as? Bool == true,
              (object["styleDataLength"] as? NSNumber)?.intValue == 51_840 else {
            let diagnostic = String(data: result.stderr, encoding: .utf8) ?? ""
            throw CLIError.invalidContainer(
                "_NUSemanticStyleProperties rejected generated metadata or changed key 1: \(diagnostic)"
            )
        }
        return [
            "parseSucceeded": true,
            "styleDataLength": readback.count,
            "readbackSHA256": sha256Hex(readback),
            "matchesExpectedStyleData": true,
            "probe": probeURL.path,
        ]
    }

    private static func buildStylePayload(
        sourceURL: URL,
        standardHDRURL: URL,
        rawDNGURL: URL?,
        semantics: AppleSemanticSceneAnalysis,
        portraitWritten: Bool,
        outputDirectory: URL,
        photoIdentifier: String,
        producerMode: AppleStyleDataProducerMode
    ) throws -> ApplePhotographicStylePayload {
        let payloadStartedAt = CFAbsoluteTimeGetCurrent()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let scale = try sourceScale(sourceURL: sourceURL, portraitWritten: portraitWritten)
        let bundle = try photoDerivedStyleSceneBundle(
            standardHDRURL: standardHDRURL,
            scale: scale,
            rawDNGURL: rawDNGURL
        )
        let sceneClassification = try photoDerivedSceneClassification(
            imageURL: standardHDRURL
        )
        let rasterCompletedAt = CFAbsoluteTimeGetCurrent()
        let styleDataDirectory = outputDirectory.appendingPathComponent("style-data")
        let producer: any AppleStyleDataProducing
        let sourceDomain: String
        let targetDomain: String
        switch producerMode {
        case .unspecified:
            throw CLIError.invalidContainer(
                "Apple Photographic Styles writer received an unresolved style-data producer"
            )
        case .learnNodeDiagnostic:
            producer = AppleLearnNodeStyleDataProducer()
            sourceDomain = "current rendered Base appearance; diagnostic same-image Learn source"
            targetDomain = "same current rendered Base appearance; diagnostic same-image Learn target"
        case .identityFallback:
            producer = IdentityStyleDataProducer()
            sourceDomain = "not used by explicit complete-identity fallback"
            targetDomain = "not used by explicit complete-identity fallback"
        case .constrainedSolver:
            throw CLIError.invalidContainer(
                "constrained-solver requires the two-stage complete-Neutrino graph path"
            )
        }
        let styleData = try producer.makeStyleData(
            request: AppleStyleDataRequest(
                sourceURL: standardHDRURL,
                renderedTargetURL: standardHDRURL,
                outputDirectory: styleDataDirectory,
                sourceDomain: sourceDomain,
                targetDomain: targetDomain
            )
        )
        let styleDataCompletedAt = CFAbsoluteTimeGetCurrent()
        let style = try makeStylePropertyList(
            styleData: styleData,
            bundle: bundle,
            semantics: semantics,
            sceneClassification: sceneClassification,
            storageOrientation: exifOrientation(at: standardHDRURL),
            outputDirectory: outputDirectory
        )
        let scenePayloadCompletedAt = CFAbsoluteTimeGetCurrent()
        let linearThumbnailPixels = style.nativeCodedLinearRGB8
            ?? bundle.codedLinearEncodedRGB8
        let linearPNG = outputDirectory.appendingPathComponent("linear-thumbnail.png")
        try writeRGBPNG(
            pixels: linearThumbnailPixels,
            width: bundle.width,
            height: bundle.height,
            outputURL: linearPNG
        )
        let linearQuality = EncodingQualityPolicy.value(
            environmentKey: "XDREMUX_STYLES_LINEAR_QUALITY",
            defaultValue: 0.85
        )
        let linearHEVC = try encodeHEVC(
            rgbPNGURL: linearPNG,
            outputDirectory: outputDirectory,
            stem: "linear-thumbnail",
            quality: linearQuality
        )
        let linearHEVCCompletedAt = CFAbsoluteTimeGetCurrent()

        let researchStyleDeltaRGB = ProcessInfo.processInfo.environment[
            "XDREMUX_RESEARCH_STYLES_DELTA_RGB_CODES"
        ]
        let styleDeltaRGBCodes: [UInt8]
        if let researchStyleDeltaRGB {
            let components = researchStyleDeltaRGB.split(separator: ",")
            guard components.count == 3 else {
                throw CLIError.invalidContainer(
                    "XDREMUX_RESEARCH_STYLES_DELTA_RGB_CODES requires R,G,B UInt8 codes"
                )
            }
            styleDeltaRGBCodes = try components.map { component in
                guard let value = UInt8(component.trimmingCharacters(in: .whitespaces)) else {
                    throw CLIError.invalidContainer(
                        "XDREMUX_RESEARCH_STYLES_DELTA_RGB_CODES contains a non-UInt8 component"
                    )
                }
                return value
            }
        } else {
            styleDeltaRGBCodes = [128, 128, 128]
        }
        var neutralTile = Data(count: 512 * 512 * 3)
        neutralTile.withUnsafeMutableBytes { raw in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for pixel in 0..<(512 * 512) {
                bytes[pixel * 3] = styleDeltaRGBCodes[0]
                bytes[pixel * 3 + 1] = styleDeltaRGBCodes[1]
                bytes[pixel * 3 + 2] = styleDeltaRGBCodes[2]
            }
        }
        let researchStyleDeltaOverride = researchStyleDeltaRGB != nil
        let deltaPNG = outputDirectory.appendingPathComponent("style-delta-neutral-tile.png")
        try writeRGBPNG(pixels: neutralTile, width: 512, height: 512, outputURL: deltaPNG)
        let deltaQuality = EncodingQualityPolicy.value(
            environmentKey: "XDREMUX_STYLES_DELTA_QUALITY",
            defaultValue: 0.3
        )
        let deltaHEVC: EncodedHEVCResource
        let deltaResourceSource: String
        if abs(deltaQuality - 0.3) <= 1e-12, !researchStyleDeltaOverride {
            deltaHEVC = try defaultNeutralStyleDeltaHEVC(
                sourcePNGURL: deltaPNG,
                outputDirectory: outputDirectory
            )
            deltaResourceSource = "bundled-verified-protocol-constant"
        } else {
            deltaHEVC = try encodeHEVC(
                rgbPNGURL: deltaPNG,
                outputDirectory: outputDirectory,
                stem: "style-delta-neutral-tile",
                quality: deltaQuality
            )
            deltaResourceSource = researchStyleDeltaOverride
                ? "runtime-videotoolbox-research-rgb-basis"
                : "runtime-videotoolbox-custom-quality"
        }
        let deltaHEVCCompletedAt = CFAbsoluteTimeGetCurrent()
        guard let primary = CIImage(
            contentsOf: standardHDRURL,
            options: [.applyOrientationProperty: true]
        ) else {
            throw CLIError.invalidContainer("cannot derive Photographic Styles presentation geometry")
        }
        let sourceWidth = max(1, Int(primary.extent.width.rounded()))
        let sourceHeight = max(1, Int(primary.extent.height.rounded()))
        let landscape = sourceWidth >= sourceHeight
        let deltaSize = fittedSize(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            maximumWidth: landscape ? 2880 : 2560,
            maximumHeight: landscape ? 2560 : 2880
        )
        let rows = landscape ? 5 : 6
        let columns = landscape ? 6 : 5
        let semanticStyleValidation = try validateWithSemanticStyleProperties(
            stylePropertyList: style.data,
            expectedStyleData: styleData.styleData,
            outputDirectory: outputDirectory
        )
        let payloadCompletedAt = CFAbsoluteTimeGetCurrent()
        let payloadTimings: [String: Double] = [
            "setupAndRaster": rasterCompletedAt - payloadStartedAt,
            "styleDataLearning": styleDataCompletedAt - rasterCompletedAt,
            "scenePayload": scenePayloadCompletedAt - styleDataCompletedAt,
            "linearHEVC": linearHEVCCompletedAt - scenePayloadCompletedAt,
            "deltaHEVC": deltaHEVCCompletedAt - linearHEVCCompletedAt,
            "metadataAndValidation": payloadCompletedAt - deltaHEVCCompletedAt,
            "total": payloadCompletedAt - payloadStartedAt,
        ]
        print(String(
            format: "styles payload setup+raster=%.3fs styleData=%.3fs scenePayload=%.3fs linearHEVC=%.3fs deltaHEVC=%.3fs metadata+validation=%.3fs total=%.3fs",
            payloadTimings["setupAndRaster"] ?? 0,
            payloadTimings["styleDataLearning"] ?? 0,
            payloadTimings["scenePayload"] ?? 0,
            payloadTimings["linearHEVC"] ?? 0,
            payloadTimings["deltaHEVC"] ?? 0,
            payloadTimings["metadataAndValidation"] ?? 0,
            payloadTimings["total"] ?? 0
        ))
        let inputSHA = sha256Hex(try Data(contentsOf: sourceURL, options: [.mappedIfSafe]))
        let provenance: [String: AppleResourceProvenance] = [
            "styleData": AppleResourceProvenance(
                producer: "XDRemux \(styleData.producerVersion)",
                inputSHA256: inputSHA,
                evidence: styleData.evidence,
                detail: styleData.sceneMatched
                    ? "scene-matched producer; full consumer reconstruction gate passed"
                    : (styleData.identityFallback
                        ? "explicit identity fallback; scene matching was not attempted"
                        : "explicit Base-to-Base LearnNode near-identity fallback; internal Apply passed but the full consumer domain is not closed")
            ),
            "linearThumbnail": AppleResourceProvenance(
                producer: style.linearThumbnailSource == "CIRAWNeutral-processed-linear-RGB-candidate"
                    ? "CMISmartStylePixelBufferRendererV1 over CIRAWFilter neutral processed-linear RGB"
                    : (style.nativeCodedLinearRGB8 == nil
                    ? "XDRemux coherent HDR scene reconstruction + per-photo exposure normalization + Apple encodeLinear"
                    : "CMISmartStylePixelBufferRendererV1 over a final-HEIC linear-input proxy"),
                inputSHA256: inputSHA,
                evidence: .sourceDerivedApproximation,
                detail: style.linearThumbnailSource == "CIRAWNeutral-processed-linear-RGB-candidate"
                    ? "private consumer invoked with a same-photo CIRAWFilter processed-linear candidate; complete native response validation is still pending"
                    : (style.nativeCodedLinearRGB8 == nil
                    ? "same-input Display P3 RGB Gain reconstruction; coded linear is HDR/key4, capture linear is coded/i.Gain, and i.Gain=4h; explicit CPU diagnostic path"
                    : "CMImaging consumes the supplied same-photo bundle coherently, but firmware proves Apple Camera supplies a capture-time pre-LTM thumbnail that an arbitrary final HEIC does not retain; camera-producer equivalence is not claimed"),
            ),
            "styleDelta": AppleResourceProvenance(
                producer: "XDRemux iPhone18,1/23F84 zero-residual profile",
                inputSHA256: inputSHA,
                evidence: .profileExact,
                detail: "pre-HEVC normalized RGB is exactly 0.5; encoder is VideoToolbox Main10 4:2:0"
            ),
            "metadata": AppleResourceProvenance(
                producer: "XDRemux unified SceneBundle plus explicit source-derived local-scene producer",
                inputSHA256: inputSHA,
                evidence: .sourceDerivedApproximation,
                detail: "photo-derived coded-linear-to-Base GTC, statistics, scene classification, face-exposure proxy, positive paired c/d, and jointly normalized h/i; no donor or scene-dependent identity payload"
            ),
        ]
        var manifest = style.manifest
        manifest["semanticStylePropertiesValidation"] = semanticStyleValidation
        manifest["timingsSeconds"] = payloadTimings
        manifest["input"] = ["path": sourceURL.path, "sha256": inputSHA]
        manifest["photoIdentifier"] = photoIdentifier
        manifest["linearThumbnail"] = [
            "width": bundle.width, "height": bundle.height,
            "encodingQuality": linearQuality,
            "itemPayloadSHA256": linearHEVC.itemPayloadSHA256,
            "hvcCSHA256": linearHEVC.hvcCSHA256,
            "evidence": AppleEvidenceClass.sourceDerivedApproximation.rawValue,
            "gainMapDecode": [
                "domain": "raw-normalized-parameter-code-value",
                "colorManagementApplied": false,
                "transferFunctionApplied": false,
            ],
            "inputDomain": style.linearThumbnailSource == "CIRAWNeutral-processed-linear-RGB-candidate"
                ? "CIRAWFilter neutral processed-linear RGB, preview-paired and exposure/WB-calibrated, supplied to CMImaging"
                : "final-HEIC proxy supplied to CMImaging = reconstructed HDR / (per-photo key4 baseline exposure * i.Gain)",
            "appleCameraInputDomain": "capture-time pre-LTM linear RGB plus post-LTM seam-fill inputs; unavailable in an arbitrary final HEIC",
            "captureTimePreLTMInputAvailable": false,
            "behaviorEquivalentLinearInputValidated": false,
            "pairedBaselineExposure": bundle.baselineExposure,
            "pairedLinearBaseGain": bundle.linearBaseGain,
            "pairedLinearEncodingGain": bundle.linearEncodingGain,
            "rendererInputLinearRange": [
                "minimum": bundle.rendererLinearRangeMin,
                "maximum": bundle.rendererLinearRangeMax,
            ],
            "producer": style.linearThumbnailSource == "CIRAWNeutral-processed-linear-RGB-candidate"
                ? "CMISmartStylePixelBufferRendererV1 output for a CIRAWFilter processed-linear candidate"
                : (style.nativeCodedLinearRGB8 == nil
                    ? "explicit CPU behavioral proxy"
                    : "CMISmartStylePixelBufferRendererV1 output for a final-HEIC proxy input"),
            "rawAssistedProvenance": style.rawProvenance,
            "consumerExactForProvidedLinearInput": style.linearThumbnailSource == "final-HEIC-proxy"
                ? (style.nativeCodedLinearRGB8 != nil)
                : false,
            "appleEncodeLinearAppliedAfterGainRestoration": style.linearThumbnailSource == "final-HEIC-proxy"
                && style.nativeCodedLinearRGB8 == nil,
        ]
        let normalizedStyleDeltaRGB: Any = researchStyleDeltaOverride
            ? styleDeltaRGBCodes.map { Double($0) / 255 }
            : 0.5
        manifest["styleDelta"] = [
            "profile": "iPhone18,1/23F84-zero-residual",
            "normalizedRGB": normalizedStyleDeltaRGB,
            "preHEVCRGBCodes": styleDeltaRGBCodes,
            "researchOverrideActive": researchStyleDeltaOverride,
            "encodingQuality": deltaQuality,
            "tile": ["width": 512, "height": 512],
            "grid": ["width": deltaSize.0, "height": deltaSize.1, "rows": rows, "columns": columns],
            "itemPayloadSHA256": deltaHEVC.itemPayloadSHA256,
            "hvcCSHA256": deltaHEVC.hvcCSHA256,
            "encodedResourceSource": deltaResourceSource,
            "fixedProtocolConstant": !researchStyleDeltaOverride,
            "codecEvidenceBoundary": "profile exact before HEVC; VideoToolbox Main10 4:2:0 is behaviorally tested but not byte-identical to Apple camera 4:4:4",
        ]
        manifest["provenance"] = Dictionary(uniqueKeysWithValues: provenance.map { key, value in
            (key, [
                "producer": value.producer,
                "inputSHA256": value.inputSHA256,
                "evidence": value.evidence.rawValue,
                "detail": value.detail,
            ])
        })
        let manifestJSON = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return ApplePhotographicStylePayload(
            styleData: styleData.styleData,
            stylePropertyList: style.data,
            linearThumbnailHEVC: linearHEVC.itemPayload,
            linearThumbnailHVCC: linearHEVC.hvcC,
            linearThumbnailWidth: bundle.width,
            linearThumbnailHeight: bundle.height,
            styleDeltaHEVC: deltaHEVC.itemPayload,
            styleDeltaHVCC: deltaHEVC.hvcC,
            styleDeltaTileWidth: 512,
            styleDeltaTileHeight: 512,
            styleDeltaGridWidth: deltaSize.0,
            styleDeltaGridHeight: deltaSize.1,
            styleDeltaRows: rows,
            styleDeltaColumns: columns,
            photoIdentifier: photoIdentifier,
            manifestJSON: manifestJSON,
            resourceProvenance: provenance
        )
    }

    private static func replacingStyleData(
        in preliminary: ApplePhotographicStylePayload,
        with styleData: AppleStyleDataResult,
        sourceURL: URL,
        outputDirectory: URL
    ) throws -> ApplePhotographicStylePayload {
        guard preliminary.styleData == (try AppleStyleDataLayout.completeIdentity()) else {
            throw CLIError.invalidContainer(
                "constrained-solver preliminary payload is not complete identity"
            )
        }
        _ = try AppleStyleDataLayout.validate(styleData.styleData)
        guard var propertyList = try PropertyListSerialization.propertyList(
            from: preliminary.stylePropertyList,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw CLIError.invalidContainer(
                "constrained-solver preliminary style property list is malformed"
            )
        }
        propertyList["1"] = styleData.styleData
        let finalPropertyList = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .binary,
            options: 0
        )
        guard let readback = try PropertyListSerialization.propertyList(
            from: finalPropertyList,
            options: [],
            format: nil
        ) as? [String: Any],
              readback["1"] as? Data == styleData.styleData else {
            throw CLIError.invalidContainer(
                "constrained-solver final style property list changed key 1"
            )
        }
        let validationDirectory = outputDirectory
            .appendingPathComponent("selected-style-validation", isDirectory: true)
        try FileManager.default.createDirectory(
            at: validationDirectory,
            withIntermediateDirectories: true
        )
        let semanticStyleValidation = try validateWithSemanticStyleProperties(
            stylePropertyList: finalPropertyList,
            expectedStyleData: styleData.styleData,
            outputDirectory: validationDirectory
        )

        guard var manifest = try JSONSerialization.jsonObject(
            with: preliminary.manifestJSON
        ) as? [String: Any] else {
            throw CLIError.invalidContainer(
                "constrained-solver preliminary style manifest is malformed"
            )
        }
        var styleDataManifest = styleData.manifest
        styleDataManifest["evidence"] = styleData.evidence.rawValue
        manifest["styleData"] = styleDataManifest
        manifest["stylePropertyList"] = [
            "byteCount": finalPropertyList.count,
            "sha256": sha256Hex(finalPropertyList),
            "format": "binary plist v1 CF format 200",
        ]
        manifest["semanticStylePropertiesValidation"] = semanticStyleValidation

        let inputSHA = sha256Hex(
            try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        )
        var provenance = preliminary.resourceProvenance
        provenance["styleData"] = AppleResourceProvenance(
            producer: "XDRemux \(styleData.producerVersion)",
            inputSHA256: inputSHA,
            evidence: styleData.evidence,
            detail: "photo-specific bounded polynomial selected by neutral reconstruction through the complete Neutrino composition; no identity fallback"
        )
        manifest["provenance"] = Dictionary(
            uniqueKeysWithValues: provenance.map { key, value in
                (key, [
                    "producer": value.producer,
                    "inputSHA256": value.inputSHA256,
                    "evidence": value.evidence.rawValue,
                    "detail": value.detail,
                ])
            }
        )
        let manifestJSON = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return ApplePhotographicStylePayload(
            styleData: styleData.styleData,
            stylePropertyList: finalPropertyList,
            linearThumbnailHEVC: preliminary.linearThumbnailHEVC,
            linearThumbnailHVCC: preliminary.linearThumbnailHVCC,
            linearThumbnailWidth: preliminary.linearThumbnailWidth,
            linearThumbnailHeight: preliminary.linearThumbnailHeight,
            styleDeltaHEVC: preliminary.styleDeltaHEVC,
            styleDeltaHVCC: preliminary.styleDeltaHVCC,
            styleDeltaTileWidth: preliminary.styleDeltaTileWidth,
            styleDeltaTileHeight: preliminary.styleDeltaTileHeight,
            styleDeltaGridWidth: preliminary.styleDeltaGridWidth,
            styleDeltaGridHeight: preliminary.styleDeltaGridHeight,
            styleDeltaRows: preliminary.styleDeltaRows,
            styleDeltaColumns: preliminary.styleDeltaColumns,
            photoIdentifier: preliminary.photoIdentifier,
            manifestJSON: manifestJSON,
            resourceProvenance: provenance
        )
    }

    private static func mergeSemanticAuxiliaryGraph(
        sourceHDRURL: URL,
        semanticScaffoldURL: URL,
        outputURL: URL,
        profile: AppleSemanticWriteProfile
    ) throws {
        struct ImportRecord {
            let oldID: Int
            let newID: Int
            let info: ISOBMFFItemInfo
            let payload: Data
            let constructionMethod: Int
        }
        struct ParsedFile {
            let data: Data
            let top: [ISOBMFFBox]
            let meta: ISOBMFFBox
            let mdat: ISOBMFFBox
            let children: [ISOBMFFBox]
            let primaryID: Int
            let toneMapID: Int
            let items: [ISOBMFFItemInfo]
            let iinfVersion: UInt8
            let locations: [ISOBMFFILocEntry]
            let refsVersion: UInt8
            let refs: [ISOBMFFIRefEntry]
            let properties: [ISOBMFFPropertyInfo]
            let ipmaVersion: UInt8
            let ipmaFlags: Int
            let ipmaEntries: [ISOBMFFIPMAEntry]
            let idat: ISOBMFFBox?
        }
        func parse(_ url: URL, owner: String) throws -> ParsedFile {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let top = isobmffBoxes(in: data, start: 0, end: data.count)
            guard let meta = top.first(where: { $0.type == "meta" }),
                  let mdat = top.first(where: { $0.type == "mdat" }) else {
                throw CLIError.invalidContainer("\(owner) semantic merge input has no meta/mdat")
            }
            let children = isobmffBoxes(in: data, start: meta.dataStart + 4, end: meta.dataEnd)
            func child(_ type: String) throws -> ISOBMFFBox {
                guard let box = children.first(where: { $0.type == type }) else {
                    throw CLIError.invalidContainer("\(owner) semantic merge input has no \(type)")
                }
                return box
            }
            let iinf = try child("iinf")
            let iloc = try child("iloc")
            let pitm = try child("pitm")
            let iprp = try child("iprp")
            let iref = children.first(where: { $0.type == "iref" })
            let itemInfo = parseISOBMFFItemInfos(data, iinf)
            guard let toneMapID = itemInfo.items.first(where: { $0.type == "tmap" })?.itemID,
                  let ipmaBox = isobmffBoxes(
                      in: data, start: iprp.dataStart, end: iprp.dataEnd
                  ).first(where: { $0.type == "ipma" }) else {
                throw CLIError.invalidContainer("\(owner) semantic merge item graph is incomplete")
            }
            let refs = parseISOBMFFIRefs(data, iref)
            let ipma = parseISOBMFFIPMA(data, ipmaBox)
            return ParsedFile(
                data: data,
                top: top,
                meta: meta,
                mdat: mdat,
                children: children,
                primaryID: parseISOBMFFPITM(data, pitm),
                toneMapID: toneMapID,
                items: itemInfo.items,
                iinfVersion: itemInfo.version,
                locations: try parseISOBMFFILoc(data, iloc),
                refsVersion: refs.version,
                refs: refs.refs,
                properties: try parseISOBMFFIPCOPropertyInfos(data, iprp),
                ipmaVersion: ipma.version,
                ipmaFlags: ipma.flags,
                ipmaEntries: ipma.entries,
                idat: children.first(where: { $0.type == "idat" })
            )
        }

        let source = try parse(sourceHDRURL, owner: "source HDR")
        let scaffold = try parse(semanticScaffoldURL, owner: "semantic scaffold")
        let scaffoldItemsByID = Dictionary(uniqueKeysWithValues: scaffold.items.map { ($0.itemID, $0) })
        let scaffoldLocationsByID = Dictionary(uniqueKeysWithValues: scaffold.locations.map { ($0.itemID, $0) })
        guard let sourceExifID = source.items.first(where: { $0.type == "Exif" })?.itemID,
              let scaffoldExifID = scaffold.items.first(where: { $0.type == "Exif" })?.itemID,
              let scaffoldExifLocation = scaffoldLocationsByID[scaffoldExifID] else {
            throw CLIError.invalidContainer("semantic merge requires source and scaffold Exif items")
        }
        let semanticImageIDs = scaffold.refs.compactMap { ref -> Int? in
            guard ref.type == "auxl",
                  ref.to.contains(scaffold.primaryID),
                  ref.to.contains(scaffold.toneMapID),
                  scaffoldItemsByID[ref.from]?.type == "hvc1" else { return nil }
            return ref.from
        }
        guard semanticImageIDs.count == profile.roles.count else {
            throw CLIError.invalidContainer(
                "semantic scaffold \(profile.kind.rawValue) expected \(profile.roles.count) roles, found \(semanticImageIDs.count)"
            )
        }
        let semanticMetadataIDs = scaffold.refs.compactMap { ref -> Int? in
            guard ref.type == "cdsc", ref.to.count == 1,
                  semanticImageIDs.contains(ref.to[0]),
                  scaffoldItemsByID[ref.from]?.type == "mime" else { return nil }
            return ref.from
        }
        guard semanticMetadataIDs.count == semanticImageIDs.count else {
            throw CLIError.invalidContainer("semantic scaffold metadata/image pairs are incomplete")
        }

        let groupIDs: [Int] = source.children
            .filter { $0.type == "grpl" }
            .flatMap { container in
                isobmffBoxes(
                    in: source.data, start: container.dataStart, end: container.dataEnd
                ).compactMap { group -> Int? in
                    guard group.dataEnd - group.dataStart >= 8 else { return nil }
                    return readUInt32BEUnchecked(source.data, at: group.dataStart + 4)
                }
            }
        var nextID = max(
            source.items.map(\.itemID).max() ?? 0,
            max(source.locations.map(\.itemID).max() ?? 0, groupIDs.max() ?? 0)
        ) + 1
        var itemIDMap: [Int: Int] = [:]
        for oldID in semanticImageIDs + semanticMetadataIDs {
            guard nextID <= 65_535 else {
                throw CLIError.invalidContainer("semantic merge exhausted HEIF UInt16 item IDs")
            }
            itemIDMap[oldID] = nextID
            nextID += 1
        }
        let importIDs = semanticImageIDs + semanticMetadataIDs
        let records: [ImportRecord] = try importIDs.map { oldID in
            guard let newID = itemIDMap[oldID],
                  let info = scaffoldItemsByID[oldID],
                  let location = scaffoldLocationsByID[oldID] else {
                throw CLIError.invalidContainer("semantic import item \(oldID) is incomplete")
            }
            return ImportRecord(
                oldID: oldID,
                newID: newID,
                info: info,
                payload: try itemPayload(in: scaffold.data, entry: location, idat: scaffold.idat),
                constructionMethod: info.type == "mime" ? 1 : 0
            )
        }
        let scaffoldExifPayload = try itemPayload(
            in: scaffold.data, entry: scaffoldExifLocation, idat: scaffold.idat
        )

        var ipcoPayload = Data()
        for property in source.properties { ipcoPayload.append(property.rawBox) }
        let scaffoldPropertiesByIndex = Dictionary(
            uniqueKeysWithValues: scaffold.properties.map { ($0.index, $0) }
        )
        var propertyIndexMap: [Int: Int] = [:]
        func mappedProperty(_ oldIndex: Int) throws -> Int {
            if let current = propertyIndexMap[oldIndex] { return current }
            guard let property = scaffoldPropertiesByIndex[oldIndex] else {
                throw CLIError.invalidContainer("semantic scaffold property \(oldIndex) is missing")
            }
            let newIndex = source.properties.count + propertyIndexMap.count + 1
            propertyIndexMap[oldIndex] = newIndex
            ipcoPayload.append(property.rawBox)
            return newIndex
        }
        let scaffoldIPMAByID = Dictionary(
            uniqueKeysWithValues: scaffold.ipmaEntries.map { ($0.itemID, $0) }
        )
        var importedAssociations: [Int: [(Int, Bool)]] = [:]
        for oldID in semanticImageIDs {
            guard let entry = scaffoldIPMAByID[oldID], let newID = itemIDMap[oldID] else {
                throw CLIError.invalidContainer("semantic image \(oldID) has no property associations")
            }
            importedAssociations[newID] = try assocPairs(
                entry.associations, flags: scaffold.ipmaFlags
            ).map { (try mappedProperty($0.0), $0.1) }
        }
        var ipmaEntries = Data()
        var ipmaCount = 0
        for entry in source.ipmaEntries {
            ipmaEntries.append(try makeIPMAEntry(
                entry.itemID,
                assocPairs(entry.associations, flags: source.ipmaFlags),
                flags: source.ipmaFlags,
                version: source.ipmaVersion
            ))
            ipmaCount += 1
        }
        for newID in importedAssociations.keys.sorted() {
            ipmaEntries.append(try makeIPMAEntry(
                newID,
                importedAssociations[newID] ?? [],
                flags: source.ipmaFlags,
                version: source.ipmaVersion
            ))
            ipmaCount += 1
        }
        var ipmaPayload = Data([
            source.ipmaVersion,
            UInt8((source.ipmaFlags >> 16) & 0xff),
            UInt8((source.ipmaFlags >> 8) & 0xff),
            UInt8(source.ipmaFlags & 0xff),
        ])
        appendUInt32BE(ipmaCount, to: &ipmaPayload)
        ipmaPayload.append(ipmaEntries)
        var iprpPayload = Data()
        iprpPayload.append(makeBox("ipco", payload: ipcoPayload))
        iprpPayload.append(makeBox("ipma", payload: ipmaPayload))
        let outputIPRP = makeBox("iprp", payload: iprpPayload)

        var rawInfes = source.items.map(\.rawInfe)
        for record in records {
            rawInfes.append(try remapInfeItemID(record.info.rawInfe, to: record.newID))
        }
        let outputIINF = makeIinfBox(version: source.iinfVersion, rawInfes: rawInfes)

        var outputRefs = source.refs
        func mappedTarget(_ oldID: Int) throws -> Int {
            if oldID == scaffold.primaryID { return source.primaryID }
            if oldID == scaffold.toneMapID { return source.toneMapID }
            if let mapped = itemIDMap[oldID] { return mapped }
            throw CLIError.invalidContainer("semantic reference target \(oldID) cannot be remapped")
        }
        for ref in scaffold.refs where itemIDMap[ref.from] != nil {
            outputRefs.append(ISOBMFFIRefEntry(
                type: ref.type,
                from: itemIDMap[ref.from]!,
                to: try ref.to.map(mappedTarget)
            ))
        }
        if !outputRefs.contains(where: {
            $0.type == "cdsc" && $0.from == sourceExifID
        }) {
            outputRefs.append(ISOBMFFIRefEntry(
                type: "cdsc", from: sourceExifID, to: [source.primaryID, source.toneMapID]
            ))
        }
        let outputIREF = makeIrefFullBox(version: source.refsVersion, refs: outputRefs)

        var idatPayload = source.idat.map {
            source.data.subdata(in: $0.dataStart..<$0.dataEnd)
        } ?? Data()
        var idatLocations: [Int: (offset: Int, length: Int)] = [:]
        for record in records where record.constructionMethod == 1 {
            let offset = idatPayload.count
            idatPayload.append(record.payload)
            idatLocations[record.newID] = (offset, record.payload.count)
        }
        let outputIDAT = makeBox("idat", payload: idatPayload)

        func buildMeta(_ locations: [ISOBMFFILocEntry]) -> Data {
            let outputILOC = makeIlocV1Box(entries: locations)
            var metaPayload = source.data.subdata(
                in: source.meta.dataStart..<source.meta.dataStart + 4
            )
            var emittedIREF = false
            var emittedIDAT = false
            for child in source.children {
                switch child.type {
                case "iinf": metaPayload.append(outputIINF)
                case "iloc": metaPayload.append(outputILOC)
                case "iref": metaPayload.append(outputIREF); emittedIREF = true
                case "iprp": metaPayload.append(outputIPRP)
                case "idat": metaPayload.append(outputIDAT); emittedIDAT = true
                default:
                    metaPayload.append(source.data.subdata(in: child.boxStart..<child.boxStart + child.size))
                }
            }
            if !emittedIREF { metaPayload.append(outputIREF) }
            if !emittedIDAT { metaPayload.append(outputIDAT) }
            return makeBox("meta", payload: metaPayload)
        }

        var placeholders = source.locations.filter { $0.itemID != sourceExifID }
        placeholders.append(ISOBMFFILocEntry(
            itemID: sourceExifID, constructionMethod: 0, dataReferenceIndex: 0,
            extents: [(0, scaffoldExifPayload.count)]
        ))
        for record in records {
            let extent = record.constructionMethod == 1
                ? idatLocations[record.newID]!
                : (offset: 0, length: record.payload.count)
            placeholders.append(ISOBMFFILocEntry(
                itemID: record.newID,
                constructionMethod: record.constructionMethod,
                dataReferenceIndex: 0,
                extents: [extent]
            ))
        }
        let preliminaryMeta = buildMeta(placeholders)
        var prefixByteCount = 0
        for box in source.top {
            if box.boxStart == source.mdat.boxStart { break }
            prefixByteCount += box.boxStart == source.meta.boxStart ? preliminaryMeta.count : box.size
        }
        let newMdatDataStart = prefixByteCount + 8
        let fileDelta = newMdatDataStart - source.mdat.dataStart
        let sourceMdatPayload = source.data.subdata(in: source.mdat.dataStart..<source.mdat.dataEnd)
        var finalLocations = source.locations.compactMap { entry -> ISOBMFFILocEntry? in
            guard entry.itemID != sourceExifID else { return nil }
            let extents = entry.extents.map { extent -> (offset: Int, length: Int) in
                let shift = entry.constructionMethod == 0
                    && extent.offset >= source.mdat.dataStart
                    && extent.offset < source.mdat.dataEnd
                return (extent.offset + (shift ? fileDelta : 0), extent.length)
            }
            return ISOBMFFILocEntry(
                itemID: entry.itemID,
                constructionMethod: entry.constructionMethod,
                dataReferenceIndex: entry.dataReferenceIndex,
                extents: extents
            )
        }
        var appendedMdat = Data()
        let newExifOffset = newMdatDataStart + sourceMdatPayload.count
        appendedMdat.append(scaffoldExifPayload)
        finalLocations.append(ISOBMFFILocEntry(
            itemID: sourceExifID, constructionMethod: 0, dataReferenceIndex: 0,
            extents: [(newExifOffset, scaffoldExifPayload.count)]
        ))
        for record in records {
            if record.constructionMethod == 0 {
                let offset = newMdatDataStart + sourceMdatPayload.count + appendedMdat.count
                appendedMdat.append(record.payload)
                finalLocations.append(ISOBMFFILocEntry(
                    itemID: record.newID, constructionMethod: 0, dataReferenceIndex: 0,
                    extents: [(offset, record.payload.count)]
                ))
            } else {
                let extent = idatLocations[record.newID]!
                finalLocations.append(ISOBMFFILocEntry(
                    itemID: record.newID, constructionMethod: 1, dataReferenceIndex: 0,
                    extents: [extent]
                ))
            }
        }
        let finalMeta = buildMeta(finalLocations)
        guard finalMeta.count == preliminaryMeta.count else {
            throw CLIError.invalidContainer("semantic merge meta layout was not size stable")
        }
        var finalMdatPayload = sourceMdatPayload
        finalMdatPayload.append(appendedMdat)
        let outputMdat = makeBox("mdat", payload: finalMdatPayload)
        var output = Data()
        for box in source.top {
            if box.boxStart == source.meta.boxStart {
                output.append(finalMeta)
            } else if box.boxStart == source.mdat.boxStart {
                output.append(outputMdat)
            } else {
                output.append(source.data.subdata(in: box.boxStart..<box.boxStart + box.size))
            }
        }
        try output.write(to: outputURL, options: .atomic)
        let written = try Data(contentsOf: outputURL, options: [.mappedIfSafe])
        let writtenTop = isobmffBoxes(in: written, start: 0, end: written.count)
        guard let writtenMdat = writtenTop.first(where: { $0.type == "mdat" }),
              sha256Hex(sourceMdatPayload) == sha256Hex(written.subdata(
                  in: writtenMdat.dataStart..<writtenMdat.dataStart + sourceMdatPayload.count
              )),
              let imageSource = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
              CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                  imageSource, 0, kCGImageAuxiliaryDataTypeISOGainMap
              ) != nil else {
            throw CLIError.invalidContainer("semantic merge changed HDR data or lost its ISO Gain Map")
        }
        func auxiliaryType(for role: AppleSemanticRole) -> CFString {
            switch role {
            case .person: return kCGImageAuxiliaryDataTypePortraitEffectsMatte
            case .skin: return kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte
            case .hair: return kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte
            case .teeth: return kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte
            case .glasses: return kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte
            case .sky: return kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte
            }
        }
        for role in profile.orderedRoles {
            guard CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                imageSource, 0, auxiliaryType(for: role)
            ) != nil else {
                throw CLIError.invalidContainer(
                    "semantic merge did not preserve expected \(role.rawValue) matte"
                )
            }
        }
    }

    private static func writeIncrementalStylesGraph(
        sourceURL: URL,
        outputURL: URL,
        payload: ApplePhotographicStylePayload
    ) throws -> GraphWriteResult {
        let source = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        let top = isobmffBoxes(in: source, start: 0, end: source.count)
        guard let meta = top.first(where: { $0.type == "meta" }),
              let mdat = top.first(where: { $0.type == "mdat" }) else {
            throw CLIError.invalidContainer("Photographic Styles writer requires meta and mdat boxes")
        }
        let children = isobmffBoxes(in: source, start: meta.dataStart + 4, end: meta.dataEnd)
        func required(_ type: String) throws -> ISOBMFFBox {
            guard let box = children.first(where: { $0.type == type }) else {
                throw CLIError.invalidContainer("Photographic Styles writer requires meta/\(type)")
            }
            return box
        }
        let iinf = try required("iinf")
        let iloc = try required("iloc")
        let pitm = try required("pitm")
        let iprp = try required("iprp")
        let sourceIDAT = children.first(where: { $0.type == "idat" })
        let sourceIREF = children.first(where: { $0.type == "iref" })
        let primaryID = parseISOBMFFPITM(source, pitm)
        let itemInfo = parseISOBMFFItemInfos(source, iinf)
        let ilocEntries = try parseISOBMFFILoc(source, iloc)
        let refsInfo = parseISOBMFFIRefs(source, sourceIREF)
        guard let tmapID = itemInfo.items.first(where: { $0.type == "tmap" })?.itemID else {
            throw CLIError.invalidContainer("Photographic Styles writer cannot locate ISO tmap item")
        }
        let gainMapID = refsInfo.refs.first(where: {
            $0.type == "dimg" && $0.from == tmapID
        })?.to.first(where: { $0 != primaryID })
            ?? refsInfo.refs.first(where: {
                $0.type == "auxl" && $0.to.contains(primaryID) && $0.to.contains(tmapID)
            })?.from
        guard let gainMapID else {
            throw CLIError.invalidContainer("Photographic Styles writer cannot locate HDR Gain Map item")
        }
        guard let ipmaBox = isobmffBoxes(
            in: source, start: iprp.dataStart, end: iprp.dataEnd
        ).first(where: { $0.type == "ipma" }) else {
            throw CLIError.invalidContainer("Photographic Styles writer requires ipma")
        }
        let sourceIPMA = parseISOBMFFIPMA(source, ipmaBox)
        let properties = try parseISOBMFFIPCOPropertyInfos(source, iprp)
        let propertyByIndex = Dictionary(uniqueKeysWithValues: properties.map { ($0.index, $0) })
        let primaryColorIndex = sourceIPMA.entries.first(where: { $0.itemID == primaryID })?
            .associations
            .map { assocPropertyIndex($0, flags: sourceIPMA.flags) }
            .first(where: { propertyByIndex[$0]?.type == "colr" })

        let entityGroupIDs: [Int] = children
            .filter { $0.type == "grpl" }
            .flatMap { groupContainer in
                isobmffBoxes(
                    in: source,
                    start: groupContainer.dataStart,
                    end: groupContainer.dataEnd
                ).compactMap { group -> Int? in
                    guard group.dataEnd - group.dataStart >= 8 else { return nil }
                    return readUInt32BEUnchecked(source, at: group.dataStart + 4)
                }
            }
        let existingMaximumID = max(
            primaryID,
            max(
                itemInfo.items.map(\.itemID).max() ?? 0,
                max(ilocEntries.map(\.itemID).max() ?? 0, entityGroupIDs.max() ?? 0)
            )
        )
        let tileCount = payload.styleDeltaRows * payload.styleDeltaColumns
        guard tileCount == 30, existingMaximumID + tileCount + 3 <= 65_535 else {
            throw CLIError.invalidContainer("unsupported Style Delta grid or HEIF item ID range")
        }
        let deltaTileIDs = Array((existingMaximumID + 1)...(existingMaximumID + tileCount))
        let deltaGridID = existingMaximumID + tileCount + 1
        let linearThumbnailID = deltaGridID + 1
        let styleMetadataID = linearThumbnailID + 1

        var ipcoPayload = Data()
        for property in properties { ipcoPayload.append(property.rawBox) }
        func appendProperty(_ box: Data) -> Int {
            ipcoPayload.append(box)
            return properties.count + isobmffBoxes(
                in: ipcoPayload, start: 0, end: ipcoPayload.count
            ).count - properties.count
        }
        // appendProperty's parse count is deliberately based on full raw boxes so each
        // resulting index remains stable even if an ICC profile is large.
        let deltaHVCCIndex = appendProperty(makeBox("hvcC", payload: payload.styleDeltaHVCC))
        let deltaTileISPEIndex = appendProperty(makeIspeBox(
            width: payload.styleDeltaTileWidth,
            height: payload.styleDeltaTileHeight
        ))
        let pixi10Index = appendProperty(makePixiBox(bits: [10, 10, 10]))
        let deltaGridISPEIndex = appendProperty(makeIspeBox(
            width: payload.styleDeltaGridWidth,
            height: payload.styleDeltaGridHeight
        ))
        let deltaAuxCIndex = appendProperty(makeAuxCBox(
            "tag:apple.com,2023:photo:aux:styledeltamap"
        ))
        let identityIrotIndex = appendProperty(makeIrotBox())
        let linearHVCCIndex = appendProperty(makeBox("hvcC", payload: payload.linearThumbnailHVCC))
        let linearISPEIndex = appendProperty(makeIspeBox(
            width: payload.linearThumbnailWidth,
            height: payload.linearThumbnailHeight
        ))
        let linearAuxCIndex = appendProperty(makeAuxCBox(
            "tag:apple.com,2023:photo:aux:linearthumbnail"
        ))
        // Apple native Linear Thumbnail items are intentionally unassociated with
        // a `colr` property. The Style Delta grid still needs a color property;
        // reuse the primary association when available and synthesize its ICC
        // fallback only for source graphs that have no primary color property.
        let deltaColorIndex: Int
        if let primaryColorIndex {
            deltaColorIndex = primaryColorIndex
        } else {
            guard let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
                throw CLIError.invalidContainer("extended linear Display P3 is unavailable")
            }
            deltaColorIndex = appendProperty(try makeICCColorBox(linearP3))
        }

        let outputIPMAFlags = sourceIPMA.flags
        var ipmaEntriesPayload = Data()
        var ipmaEntryCount = 0
        for entry in sourceIPMA.entries {
            let associations = assocPairs(entry.associations, flags: sourceIPMA.flags)
            ipmaEntriesPayload.append(try makeIPMAEntry(
                entry.itemID,
                associations,
                flags: outputIPMAFlags,
                version: sourceIPMA.version
            ))
            ipmaEntryCount += 1
        }
        for tileID in deltaTileIDs {
            ipmaEntriesPayload.append(try makeIPMAEntry(
                tileID,
                [(deltaTileISPEIndex, true), (deltaColorIndex, true), (deltaHVCCIndex, true)],
                flags: outputIPMAFlags,
                version: sourceIPMA.version
            ))
            ipmaEntryCount += 1
        }
        ipmaEntriesPayload.append(try makeIPMAEntry(
            deltaGridID,
            [
                (deltaColorIndex, true), (deltaGridISPEIndex, false), (pixi10Index, false),
                (deltaAuxCIndex, true), (identityIrotIndex, true),
            ],
            flags: outputIPMAFlags,
            version: sourceIPMA.version
        ))
        ipmaEntryCount += 1
        ipmaEntriesPayload.append(try makeIPMAEntry(
            linearThumbnailID,
            [
                (linearISPEIndex, true), (pixi10Index, false),
                (linearHVCCIndex, true), (linearAuxCIndex, true), (identityIrotIndex, true),
            ],
            flags: outputIPMAFlags,
            version: sourceIPMA.version
        ))
        ipmaEntryCount += 1
        var ipmaPayload = Data([
            sourceIPMA.version,
            UInt8((outputIPMAFlags >> 16) & 0xff),
            UInt8((outputIPMAFlags >> 8) & 0xff),
            UInt8(outputIPMAFlags & 0xff),
        ])
        appendUInt32BE(ipmaEntryCount, to: &ipmaPayload)
        ipmaPayload.append(ipmaEntriesPayload)
        var outputIPRPPayload = Data()
        outputIPRPPayload.append(makeBox("ipco", payload: ipcoPayload))
        outputIPRPPayload.append(makeBox("ipma", payload: ipmaPayload))
        for child in isobmffBoxes(in: source, start: iprp.dataStart, end: iprp.dataEnd)
            where child.type != "ipco" && child.type != "ipma" {
            outputIPRPPayload.append(source.subdata(in: child.boxStart..<child.boxStart + child.size))
        }
        let outputIPRP = makeBox("iprp", payload: outputIPRPPayload)

        var rawInfes = itemInfo.items.map(\.rawInfe)
        for tileID in deltaTileIDs {
            rawInfes.append(makeInfeBox(itemID: tileID, type: "hvc1", flags: 1))
        }
        rawInfes.append(makeInfeBox(itemID: deltaGridID, type: "grid", flags: 1))
        rawInfes.append(makeInfeBox(itemID: linearThumbnailID, type: "hvc1", flags: 1))
        rawInfes.append(makeURIInfeBox(
            itemID: styleMetadataID,
            name: "styleMetadata",
            uri: "tag:apple.com,2023:photo:metadata:styles"
        ))
        let outputIINF = makeIinfBox(version: itemInfo.version, rawInfes: rawInfes)

        var refs = refsInfo.refs
        refs.append(ISOBMFFIRefEntry(type: "dimg", from: deltaGridID, to: deltaTileIDs))
        refs.append(ISOBMFFIRefEntry(type: "auxl", from: deltaGridID, to: [primaryID, tmapID]))
        refs.append(ISOBMFFIRefEntry(type: "auxl", from: linearThumbnailID, to: [primaryID, tmapID]))
        refs.append(ISOBMFFIRefEntry(type: "cdsc", from: styleMetadataID, to: [primaryID, tmapID]))
        let outputIREF = makeIrefFullBox(version: refsInfo.version, refs: refs)

        var idatPayload = sourceIDAT.map {
            source.subdata(in: $0.dataStart..<$0.dataEnd)
        } ?? Data()
        let deltaGridOffset = idatPayload.count
        let deltaGridPayload = try makeGridPayload(
            rows: payload.styleDeltaRows,
            columns: payload.styleDeltaColumns,
            width: payload.styleDeltaGridWidth,
            height: payload.styleDeltaGridHeight
        )
        idatPayload.append(deltaGridPayload)
        let styleMetadataOffset = idatPayload.count
        idatPayload.append(payload.stylePropertyList)
        let outputIDAT = makeBox("idat", payload: idatPayload)

        func buildMeta(_ locations: [ISOBMFFILocEntry]) -> Data {
            let outputILOC = makeIlocV1Box(entries: locations)
            var metaPayload = source.subdata(in: meta.dataStart..<meta.dataStart + 4)
            var emittedIREF = false
            var emittedIDAT = false
            for child in children {
                switch child.type {
                case "iinf": metaPayload.append(outputIINF)
                case "iloc": metaPayload.append(outputILOC)
                case "iref": metaPayload.append(outputIREF); emittedIREF = true
                case "iprp": metaPayload.append(outputIPRP)
                case "idat": metaPayload.append(outputIDAT); emittedIDAT = true
                default:
                    metaPayload.append(source.subdata(in: child.boxStart..<child.boxStart + child.size))
                }
            }
            if !emittedIREF { metaPayload.append(outputIREF) }
            if !emittedIDAT { metaPayload.append(outputIDAT) }
            return makeBox("meta", payload: metaPayload)
        }

        var placeholders = ilocEntries
        for tileID in deltaTileIDs {
            placeholders.append(ISOBMFFILocEntry(
                itemID: tileID, constructionMethod: 0, dataReferenceIndex: 0,
                extents: [(0, payload.styleDeltaHEVC.count)]
            ))
        }
        placeholders.append(ISOBMFFILocEntry(
            itemID: deltaGridID, constructionMethod: 1, dataReferenceIndex: 0,
            extents: [(deltaGridOffset, deltaGridPayload.count)]
        ))
        placeholders.append(ISOBMFFILocEntry(
            itemID: linearThumbnailID, constructionMethod: 0, dataReferenceIndex: 0,
            extents: [(0, payload.linearThumbnailHEVC.count)]
        ))
        placeholders.append(ISOBMFFILocEntry(
            itemID: styleMetadataID, constructionMethod: 1, dataReferenceIndex: 0,
            extents: [(styleMetadataOffset, payload.stylePropertyList.count)]
        ))
        let preliminaryMeta = buildMeta(placeholders)
        var prefixByteCount = 0
        for box in top {
            if box.boxStart == mdat.boxStart { break }
            prefixByteCount += box.boxStart == meta.boxStart ? preliminaryMeta.count : box.size
        }
        let newMdatDataStart = prefixByteCount + 8
        let fileDelta = newMdatDataStart - mdat.dataStart
        let sourceMdatPayload = source.subdata(in: mdat.dataStart..<mdat.dataEnd)
        var finalLocations = ilocEntries.map { entry -> ISOBMFFILocEntry in
            let extents = entry.extents.map { extent -> (offset: Int, length: Int) in
                let shouldShift = entry.constructionMethod == 0
                    && extent.offset >= mdat.dataStart
                    && extent.offset < mdat.dataEnd
                return (extent.offset + (shouldShift ? fileDelta : 0), extent.length)
            }
            return ISOBMFFILocEntry(
                itemID: entry.itemID,
                constructionMethod: entry.constructionMethod,
                dataReferenceIndex: entry.dataReferenceIndex,
                extents: extents
            )
        }
        var appendedMdat = Data()
        for tileID in deltaTileIDs {
            let offset = newMdatDataStart + sourceMdatPayload.count + appendedMdat.count
            appendedMdat.append(payload.styleDeltaHEVC)
            finalLocations.append(ISOBMFFILocEntry(
                itemID: tileID, constructionMethod: 0, dataReferenceIndex: 0,
                extents: [(offset, payload.styleDeltaHEVC.count)]
            ))
        }
        finalLocations.append(ISOBMFFILocEntry(
            itemID: deltaGridID, constructionMethod: 1, dataReferenceIndex: 0,
            extents: [(deltaGridOffset, deltaGridPayload.count)]
        ))
        let linearOffset = newMdatDataStart + sourceMdatPayload.count + appendedMdat.count
        appendedMdat.append(payload.linearThumbnailHEVC)
        finalLocations.append(ISOBMFFILocEntry(
            itemID: linearThumbnailID, constructionMethod: 0, dataReferenceIndex: 0,
            extents: [(linearOffset, payload.linearThumbnailHEVC.count)]
        ))
        finalLocations.append(ISOBMFFILocEntry(
            itemID: styleMetadataID, constructionMethod: 1, dataReferenceIndex: 0,
            extents: [(styleMetadataOffset, payload.stylePropertyList.count)]
        ))
        let finalMeta = buildMeta(finalLocations)
        guard finalMeta.count == preliminaryMeta.count else {
            throw CLIError.invalidContainer("Photographic Styles meta layout was not size stable")
        }
        var finalMdatPayload = sourceMdatPayload
        finalMdatPayload.append(appendedMdat)
        let finalMdat = makeBox("mdat", payload: finalMdatPayload)
        var output = Data()
        for box in top {
            if box.boxStart == meta.boxStart {
                output.append(finalMeta)
            } else if box.boxStart == mdat.boxStart {
                output.append(finalMdat)
            } else {
                output.append(source.subdata(in: box.boxStart..<box.boxStart + box.size))
            }
        }
        try output.write(to: outputURL, options: .atomic)
        let outputPrefix = finalMdatPayload.prefix(sourceMdatPayload.count)
        let sourceMdatSHA = sha256Hex(sourceMdatPayload)
        let outputPrefixSHA = sha256Hex(Data(outputPrefix))
        guard sourceMdatSHA == outputPrefixSHA else {
            throw CLIError.invalidContainer("base/HDR Gain Map mdat payload changed while adding Styles")
        }
        return GraphWriteResult(
            primaryItemID: primaryID,
            gainMapItemID: gainMapID,
            toneMapItemID: tmapID,
            styleDeltaItemID: deltaGridID,
            linearThumbnailItemID: linearThumbnailID,
            styleMetadataItemID: styleMetadataID,
            originalMdatPayloadSHA256: sourceMdatSHA,
            outputOriginalMdatPrefixSHA256: outputPrefixSHA,
            itemCount: rawInfes.count,
            propertyCount: isobmffBoxes(in: ipcoPayload, start: 0, end: ipcoPayload.count).count
        )
    }

    private static func convert(inputURL: URL, outputURL: URL, options: Options) throws {
        guard options.features.photographicStyles else {
            throw CLIError.invalidContainer("Photographic Styles pipeline invoked without its capability flag")
        }
        let parent = outputURL.deletingLastPathComponent()
        try ensureDirectory(parent, fileManager: .default)
        let featureInputURL = siblingScratchURL(
            for: outputURL,
            label: "apple-input",
            pathExtension: "heic"
        )
        let sharedSemanticDirectory = outputURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(outputURL.lastPathComponent).shared-semantics-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: featureInputURL) }
        defer { try? FileManager.default.removeItem(at: sharedSemanticDirectory) }

        var portraitUnavailableReason: String?
        var portraitWritten = false
        var portraitSemanticFusion: [String: Any]?
        var portraitSemanticAnalysis: AppleSemanticSceneAnalysis?
        var portraitManifestURL: URL?
        let photoIdentifier = UUID().uuidString.uppercased()
        if options.features.portrait {
            do {
                let outcome = try PortraitConversionPipeline.convertWithOutcome(
                    inputURL: inputURL,
                    outputURL: featureInputURL,
                    mode: .on,
                    photoIdentifier: photoIdentifier,
                    includesPhotographicStylesSemantics: true,
                    semanticOutputDirectory: sharedSemanticDirectory,
                    writeSemanticPNGEvidence: options.debugRootURL != nil,
                    eventHandler: options.eventHandler
                )
                portraitWritten = outcome.written
                portraitSemanticFusion = outcome.semanticFusion
                portraitSemanticAnalysis = outcome.semanticAnalysis
                portraitManifestURL = outcome.manifestURL
                if !portraitWritten {
                    portraitUnavailableReason = "required OPPO portrait depth bundle is unavailable"
                }
            } catch {
                let sourceExtension = inputURL.pathExtension.lowercased()
                if sourceExtension == "jpg" || sourceExtension == "jpeg" {
                    // JPEG enters this product path only through the validated
                    // src.image portrait bridge. Never fall back to the generic
                    // HEIC converter after that bridge fails.
                    throw error
                }
                portraitUnavailableReason = String(describing: error)
            }
        }

        if !portraitWritten {
            var rawSceneInputManifest: [String: Any]?
            if let rawDNGURL = options.rawDNGURL {
                rawSceneInputManifest = try rawEmbeddedPreviewSceneInput(
                    rawDNGURL: rawDNGURL,
                    sourceURL: inputURL,
                    outputURL: featureInputURL
                )
                print(
                    "styles input=RAW embedded PreviewImage MPF; "
                        + "Gain Map transform=\(rawSceneInputManifest?["transform"] ?? "unknown")"
                )
            } else {
                rawSceneInputManifest = nil
            }
            let existingISOInput = rawSceneInputManifest == nil
                && !options.features.portrait
                && PortraitConversionPipeline.hasValidISOGainMap(inputURL)
            if existingISOInput {
                try FileManager.default.copyItem(at: inputURL, to: featureInputURL)
                print("styles input=existing ImageIO-readable ISO Gain Map HEIC; Local HDR conversion bypassed")
            } else if rawSceneInputManifest == nil {
                _ = try XDRemuxProductCore.convert(
                    inputURL: inputURL,
                    outputURL: featureInputURL,
                    familyPreference: options.family,
                    debugRootURL: options.debugRootURL,
                    oppoCompatibility: options.oppoCompatibility,
                    inputProcessingBranch: options.inputProcessingBranch,
                    oppoCameraTail: options.oppoCameraTail,
                    tmapFormat: options.tmapFormat,
                    eventHandler: options.eventHandler
                )
            }
            try augmentPhotographicStyles(
                sourceURL: inputURL,
                standardHDRURL: featureInputURL,
                outputURL: outputURL,
                portraitRequested: options.features.portrait,
                portraitWritten: portraitWritten,
                portraitUnavailableReason: portraitUnavailableReason,
                portraitSemanticFusion: portraitSemanticFusion,
                portraitSemanticAnalysis: portraitSemanticAnalysis,
                portraitSemanticEvidenceDirectory: portraitWritten ? sharedSemanticDirectory : nil,
                preferredPhotoIdentifier: photoIdentifier,
                styleDataProducer: options.styleDataProducer,
                rawDNGURL: options.rawDNGURL,
                rawSceneInputManifest: rawSceneInputManifest,
                debugRootURL: options.debugRootURL
            )
        } else {
            try augmentPhotographicStyles(
                sourceURL: inputURL,
                standardHDRURL: featureInputURL,
                outputURL: outputURL,
                portraitRequested: options.features.portrait,
                portraitWritten: portraitWritten,
                portraitUnavailableReason: portraitUnavailableReason,
                portraitSemanticFusion: portraitSemanticFusion,
                portraitSemanticAnalysis: portraitSemanticAnalysis,
                portraitSemanticEvidenceDirectory: portraitWritten ? sharedSemanticDirectory : nil,
                preferredPhotoIdentifier: photoIdentifier,
                styleDataProducer: options.styleDataProducer,
                rawDNGURL: options.rawDNGURL,
                rawSceneInputManifest: nil,
                debugRootURL: options.debugRootURL
            )
        }
        if let portraitManifestURL, FileManager.default.fileExists(atPath: portraitManifestURL.path) {
            let destination = outputURL.deletingPathExtension()
                .appendingPathExtension("portrait-manifest.json")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: portraitManifestURL, to: destination)
            print("portrait manifest=\(destination.path)")
        }
    }

    private static func augmentPhotographicStyles(
        sourceURL: URL,
        standardHDRURL: URL,
        outputURL: URL,
        portraitRequested: Bool,
        portraitWritten: Bool,
        portraitUnavailableReason: String?,
        portraitSemanticFusion: [String: Any]?,
        portraitSemanticAnalysis: AppleSemanticSceneAnalysis?,
        portraitSemanticEvidenceDirectory: URL?,
        preferredPhotoIdentifier: String,
        styleDataProducer: AppleStyleDataProducerMode,
        rawDNGURL: URL?,
        rawSceneInputManifest: [String: Any]?,
        debugRootURL: URL?
    ) throws {
        let augmentStartedAt = CFAbsoluteTimeGetCurrent()
        let runToken = UUID().uuidString.uppercased()
        let persistEvidence = debugRootURL != nil
        let evidenceContainer: URL
        if let debugRootURL {
            evidenceContainer = debugRootURL
                .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent, isDirectory: true)
                .appendingPathComponent("photographic-styles", isDirectory: true)
        } else {
            evidenceContainer = FileManager.default.temporaryDirectory
                .appendingPathComponent("xdremux-photographic-styles-\(runToken)", isDirectory: true)
        }
        defer {
            if !persistEvidence {
                try? FileManager.default.removeItem(at: evidenceContainer)
            }
        }
        let evidenceDirectory = evidenceContainer
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(runToken, isDirectory: true)
        try FileManager.default.createDirectory(
            at: evidenceDirectory,
            withIntermediateDirectories: true
        )
        if let rawSceneInputManifest {
            let rawSceneInputData = try JSONSerialization.data(
                withJSONObject: rawSceneInputManifest,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try rawSceneInputData.write(
                to: evidenceDirectory.appendingPathComponent("raw-scene-input.json"),
                options: .atomic
            )
        }
        if let portraitSemanticFusion {
            let fusionData = try JSONSerialization.data(
                withJSONObject: portraitSemanticFusion,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try fusionData.write(
                to: evidenceDirectory.appendingPathComponent("portrait-semantic-fusion.json"),
                options: .atomic
            )
        }
        let semanticDirectory = evidenceDirectory.appendingPathComponent("semantics", isDirectory: true)
        try FileManager.default.copyItem(
            at: standardHDRURL,
            to: evidenceDirectory.appendingPathComponent("base-hdr-before-semantics.heic")
        )
        let analysis: AppleSemanticSceneAnalysis
        let semanticAnalysisSource: String
        if portraitWritten,
           let portraitSemanticAnalysis,
           let portraitSemanticEvidenceDirectory {
            try AppleSemanticSceneAnalyzer.copyEvidence(
                from: portraitSemanticEvidenceDirectory,
                to: semanticDirectory
            )
            analysis = portraitSemanticAnalysis
            semanticAnalysisSource = "portrait_shared"
            print("Vision semantic analysis source=portrait-shared; skipped duplicate Styles analysis")
        } else {
            analysis = try AppleSemanticSceneAnalyzer.analyze(
                imageURL: standardHDRURL,
                outputDirectory: semanticDirectory,
                profile: .styleHuman,
                writePNGEvidence: persistEvidence
            )
            semanticAnalysisSource = "styles"
        }
        let semanticStageSeconds = CFAbsoluteTimeGetCurrent() - augmentStartedAt
        let existingPhotoIdentifier: String? = CGImageSourceCreateWithURL(
            standardHDRURL as CFURL, nil
        ).flatMap { source in
            guard let properties = CGImageSourceCopyPropertiesAtIndex(
                source, 0, nil
            ) as? [CFString: Any],
                  let dictionary = properties[
                      kCGImagePropertyMakerAppleDictionary
                  ] as? NSDictionary else { return nil }
            return dictionary["43"] as? String ?? dictionary[43] as? String
        }
        let photoIdentifier = existingPhotoIdentifier ?? preferredPhotoIdentifier
        let scaffoldURL = outputURL.deletingLastPathComponent().appendingPathComponent(
            ".\(outputURL.lastPathComponent).semantic-scaffold-\(runToken).heic"
        )
        let semanticMergedURL = outputURL.deletingLastPathComponent().appendingPathComponent(
            ".\(outputURL.lastPathComponent).semantic-merged-\(runToken).heic"
        )
        defer { try? FileManager.default.removeItem(at: scaffoldURL) }
        defer { try? FileManager.default.removeItem(at: semanticMergedURL) }
        let normalSemanticWriteProfile: AppleSemanticWriteProfile = portraitWritten
            ? .portraitAndStyles
            : analysis.nativeStyleWriteProfile
        let researchSemanticOverride = try researchSemanticGraphOverride(
            analysis: analysis,
            normalWriteProfile: normalSemanticWriteProfile,
            portraitWritten: portraitWritten
        )
        let graphSemanticAnalysis = researchSemanticOverride?.analysis ?? analysis
        let semanticWriteProfile = researchSemanticOverride?.writeProfile
            ?? normalSemanticWriteProfile
        let featureGraphURL: URL
        if portraitWritten {
            // The Portrait writer already authored the same six Vision resources and
            // disparity. Reusing that graph prevents duplicate semantic auxiliaries.
            featureGraphURL = standardHDRURL
        } else {
            try AppleSemanticScaffoldBuilder.write(
                sourceHDRURL: standardHDRURL,
                outputURL: scaffoldURL,
                analysis: graphSemanticAnalysis,
                profile: semanticWriteProfile,
                photoIdentifier: photoIdentifier,
                preserveOriginalBaseAndGain: false
            )
            try FileManager.default.copyItem(
                at: scaffoldURL,
                to: evidenceDirectory.appendingPathComponent("semantic-scaffold-before-styles.heic")
            )
            try mergeSemanticAuxiliaryGraph(
                sourceHDRURL: standardHDRURL,
                semanticScaffoldURL: scaffoldURL,
                outputURL: semanticMergedURL,
                profile: semanticWriteProfile
            )
            try FileManager.default.copyItem(
                at: semanticMergedURL,
                to: evidenceDirectory.appendingPathComponent("semantic-merged-base-gain-preserved.heic")
            )
            featureGraphURL = semanticMergedURL
        }
        let styleDirectory = evidenceDirectory.appendingPathComponent("styles", isDirectory: true)
        let stylePayloadStartedAt = CFAbsoluteTimeGetCurrent()
        let stylePayload: ApplePhotographicStylePayload
        if styleDataProducer == .constrainedSolver {
            let preliminaryPayload = try buildStylePayload(
                sourceURL: sourceURL,
                standardHDRURL: featureGraphURL,
                rawDNGURL: rawDNGURL,
                semantics: analysis,
                portraitWritten: portraitWritten,
                outputDirectory: styleDirectory
                    .appendingPathComponent("preliminary-identity", isDirectory: true),
                photoIdentifier: photoIdentifier,
                producerMode: .identityFallback
            )
            let preliminaryURL = evidenceDirectory.appendingPathComponent(
                "constrained-solver-preliminary-identity.heic"
            )
            _ = try writeIncrementalStylesGraph(
                sourceURL: featureGraphURL,
                outputURL: preliminaryURL,
                payload: preliminaryPayload
            )
            _ = try validatePhotographicStylesOutput(
                preliminaryURL,
                expectsPortrait: portraitWritten,
                prevalidatedStylePropertyList: preliminaryPayload.stylePropertyList
            )
            let solverDirectory = styleDirectory.appendingPathComponent(
                "constrained-solver",
                isDirectory: true
            )
            let selectedStyleData = try ConstrainedPolynomialStyleDataProducer()
                .makeStyleData(
                    preliminaryHEICURL: preliminaryURL,
                    identityStylePropertyList: preliminaryPayload.stylePropertyList,
                    outputDirectory: solverDirectory,
                    skinMask: solverSkinMask(analysis.skin)
                )
            stylePayload = try replacingStyleData(
                in: preliminaryPayload,
                with: selectedStyleData,
                sourceURL: sourceURL,
                outputDirectory: solverDirectory
            )
        } else {
            stylePayload = try buildStylePayload(
                sourceURL: sourceURL,
                standardHDRURL: featureGraphURL,
                rawDNGURL: rawDNGURL,
                semantics: analysis,
                portraitWritten: portraitWritten,
                outputDirectory: styleDirectory,
                photoIdentifier: photoIdentifier,
                producerMode: styleDataProducer
            )
        }
        // Keep one producer-independent final metadata path in every run.
        // The constrained solver validates inside styles/constrained-solver;
        // without this canonical copy, downstream evidence auditors saw only
        // the preliminary identity path and could not inspect the selected
        // key-1 payload after an otherwise successful conversion.
        try stylePayload.stylePropertyList.write(
            to: styleDirectory.appendingPathComponent("style-metadata.bplist"),
            options: .atomic
        )
        let stylePayloadSeconds = CFAbsoluteTimeGetCurrent() - stylePayloadStartedAt
        let graphStartedAt = CFAbsoluteTimeGetCurrent()
        let graph = try writeIncrementalStylesGraph(
            sourceURL: featureGraphURL,
            outputURL: outputURL,
            payload: stylePayload
        )
        let validation = try validatePhotographicStylesOutput(
            outputURL,
            expectsPortrait: portraitWritten,
            prevalidatedStylePropertyList: stylePayload.stylePropertyList
        )
        let graphAndValidationSeconds = CFAbsoluteTimeGetCurrent() - graphStartedAt
        let totalSeconds = CFAbsoluteTimeGetCurrent() - augmentStartedAt
        print(String(
            format: "styles pipeline semanticSource=%@ semantic=%.3fs payload=%.3fs graph+validation=%.3fs total=%.3fs",
            semanticAnalysisSource,
            semanticStageSeconds,
            stylePayloadSeconds,
            graphAndValidationSeconds,
            totalSeconds
        ))

        func matteSummary(_ matte: AppleSemanticMatte?) -> [String: Any] {
            guard let matte else { return ["available": false] }
            return [
                "available": true,
                "requestClass": matte.provenance.requestClass,
                "attributeName": matte.provenance.attributeName,
                "revision": matte.provenance.revision,
                "inputSHA256": matte.provenance.inputSHA256,
                "width": matte.width,
                "height": matte.height,
                "pixelFormat": matte.provenance.pixelFormat,
                "orientation": matte.provenance.orientation,
                "orientationTransform": matte.provenance.orientationTransform,
                "fallback": matte.provenance.fallback,
                "minimum": matte.statistics.minimum,
                "maximum": matte.statistics.maximum,
                "mean": matte.statistics.mean,
                "coverage": matte.statistics.coverage,
                "rawSHA256": sha256Hex(matte.pixels),
            ]
        }
        let outputData = validation.outputData
        let contaminationReport = validation.contaminationReport
        let inputData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        let inputSHA256 = sha256Hex(inputData)
        guard let stylePayloadManifest = try JSONSerialization.jsonObject(
            with: stylePayload.manifestJSON
        ) as? [String: Any],
              let styleDataManifest = stylePayloadManifest["styleData"] as? [String: Any],
              let reconstruction = styleDataManifest["reconstructionMetrics"] as? [String: Any],
              let sceneDomainManifest =
                stylePayloadManifest["sceneDomainBundle"] as? [String: Any],
              let sceneClassificationManifest =
                stylePayloadManifest["sceneClassification"] as? [String: Any],
              let styleDeltaManifest = stylePayloadManifest["styleDelta"] as? [String: Any],
              let localSceneManifest = stylePayloadManifest["localSceneProducer"] as? [String: Any] else {
            throw CLIError.invalidContainer(
                "Styles acceptance cannot audit the generated scene-payload manifest"
            )
        }
        let neutralGatePassed = styleDataManifest["sceneMatched"] as? Bool == true
            && reconstruction["status"] as? String == "neutral_scene_matched"
        let key1EnvelopePassed = (
            reconstruction["responseEnvelope"] as? [String: Any]
        )?["passed"] as? Bool == true
        let key1IncrementGatePassed = styleDataManifest["key1IncrementEligible"] as? Bool == true
            && key1EnvelopePassed
        let captureLinearInputGatePassed =
            localSceneManifest["captureTimePreLTMInputAvailable"] as? Bool == true
            || localSceneManifest["behaviorEquivalentLinearInputValidated"] as? Bool == true
        let noSceneDependentFallbackResources = styleDataManifest["identityFallback"] as? Bool == false
            && styleDataManifest["fallbackKind"] is NSNull
            && sceneClassificationManifest["sceneDependentFallback"] as? Bool == false
            && sceneDomainManifest["researchOverrideActive"] as? Bool == false
            && researchSemanticOverride == nil
            && styleDeltaManifest["fixedProtocolConstant"] as? Bool == true
            && localSceneManifest["status"] as? String == "success"
            && localSceneManifest["mode"] as? String != "fallback"
            && localSceneManifest["fallbackKind"] is NSNull
            && captureLinearInputGatePassed
        let counterexampleSHA256 =
            "80c91c715d89fa636b782301235e3c24f5cf54eb12431d9d95721abe33638beb"
        let acceptanceChecklist: [String: Any] = [
            "schema": "xdremux-apple-styles-production-acceptance-v1",
            "outputSHA256": sha256Hex(outputData),
            "neutralGatePassed": neutralGatePassed,
            "key1IncrementResponseGatePassed": key1IncrementGatePassed,
            "captureLinearInputGatePassed": captureLinearInputGatePassed,
            "fullSceneResponseGatePassed": false,
            "counterexampleGatePassed": false,
            "noSceneDependentFallbackResources": noSceneDependentFallbackResources,
            "structuralValidationPassed": true,
            "photosAcceptancePassed": false,
            "productionCandidateGenerated": neutralGatePassed
                && key1IncrementGatePassed
                && noSceneDependentFallbackResources,
            "productionEligible": false,
            "pendingExternalReceipts": [
                "capture-time pre-LTM input or a held-out full-response-equivalent final-HEIC proxy",
                "direct full-scene native-envelope response gate",
                "fixed IMG20260717130755 counterexample gate",
                "real Photos import, edit, save, exit, and reopen acceptance",
            ],
            "counterexample": [
                "fixtureSHA256": counterexampleSHA256,
                "thisInputIsCounterexample": inputSHA256 == counterexampleSHA256,
                "status": "pending-direct-full-scene-receipt",
            ],
            "eligibilityFormula": "neutral && captureLinearInput && fullScene && key1Increment && counterexample && noSceneDependentFallback && structural && photosAcceptance",
            "claimBoundary": "firmware proves Apple Camera uses a capture-time pre-LTM thumbnail absent from arbitrary final HEICs; writer-time key 1 and structural checks cannot substitute for that input, direct full-scene response, or real Photos persistence",
        ]
        let contaminationReportData = try JSONSerialization.data(
            withJSONObject: contaminationReport,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try contaminationReportData.write(
            to: evidenceDirectory.appendingPathComponent("donor-contamination.json"),
            options: .atomic
        )
        let graphManifest: [String: Any] = [
            "primaryItemID": graph.primaryItemID,
            "gainMapItemID": graph.gainMapItemID,
            "toneMapItemID": graph.toneMapItemID,
            "styleDeltaItemID": graph.styleDeltaItemID,
            "linearThumbnailItemID": graph.linearThumbnailItemID,
            "styleMetadataItemID": graph.styleMetadataItemID,
            "itemCount": graph.itemCount,
            "propertyCount": graph.propertyCount,
            "primaryAndGainEncodedOnce": graph.originalMdatPayloadSHA256 == graph.outputOriginalMdatPrefixSHA256,
            "originalMdatPayloadSHA256": graph.originalMdatPayloadSHA256,
            "outputOriginalMdatPrefixSHA256": graph.outputOriginalMdatPrefixSHA256,
        ]
        let configuration: [String: Any] = [
            "applePhotographicStyles": true,
            "applePortraitRequested": portraitRequested,
            "applePortraitWritten": portraitWritten,
            "applePortraitUnavailableReason": portraitUnavailableReason.map { $0 as Any } ?? NSNull(),
            "styleProfile": "iPhone18,1/23F84-zero-residual",
            "styleDataProducer": styleDataProducer.rawValue,
            "rawDNGURL": rawDNGURL.map { $0.path as Any } ?? NSNull(),
            "rawSceneInput": rawSceneInputManifest ?? NSNull(),
            "researchSemanticGraphMode": researchSemanticOverride?.mode.rawValue as Any? ?? NSNull(),
            "debugRoot": debugRootURL.map { $0.path as Any } ?? NSNull(),
        ]
        let manifest: [String: Any] = [
            "schema": "xdremux-apple-feature-conversion-v1",
            "runIdentifier": runToken,
            "input": [
                "path": sourceURL.path,
                "sha256": inputSHA256,
            ],
            "output": [
                "path": outputURL.path,
                "sha256": sha256Hex(outputData),
                "byteCount": outputData.count,
            ],
            "configuration": configuration,
            "photoIdentifier": photoIdentifier,
            "semanticWriteProfile": [
                "kind": semanticWriteProfile.kind.rawValue,
                "roles": semanticWriteProfile.orderedRoles.map(\.rawValue),
                "nativeEvidence": "style sky-only; style human PEM+skin+sky; portrait family PEM+skin+hair+teeth+glasses",
                "researchOverride": researchSemanticOverride?.mode.rawValue as Any? ?? NSNull(),
            ],
            "semanticAnalysisSource": semanticAnalysisSource,
            "timingsSeconds": [
                "semantic": semanticStageSeconds,
                "stylePayload": stylePayloadSeconds,
                "graphAndValidation": graphAndValidationSeconds,
                "total": totalSeconds,
            ],
            "semantics": [
                "person": matteSummary(analysis.person),
                "skin": matteSummary(analysis.skin),
                "hair": matteSummary(analysis.hair),
                "teeth": matteSummary(analysis.teeth),
                "glasses": matteSummary(analysis.glasses),
                "sky": matteSummary(analysis.sky),
            ],
            "portraitSemanticFusion": portraitSemanticFusion.map { $0 as Any } ?? NSNull(),
            "stylePayloadManifestSHA256": sha256Hex(stylePayload.manifestJSON),
            "heifGraph": graphManifest,
            "donorPolicy": [
                "shellCopied": false,
                "scenePayloadCopied": false,
                "styleDataSource": stylePayload.resourceProvenance["styleData"]?.producer
                    ?? "unknown",
                "linearThumbnailSource": stylePayload.resourceProvenance["linearThumbnail"]?.detail
                    ?? "same-input final-HEIC behavior proxy; Apple capture-time pre-LTM source unavailable",
                "rawAssisted": rawDNGURL != nil,
                "styleDeltaSource": "profile-scoped neutral protocol tuning",
            ],
            "donorContamination": contaminationReport,
            "productionAcceptance": acceptanceChecklist,
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try manifestData.write(
            to: evidenceDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        try stylePayload.manifestJSON.write(
            to: evidenceDirectory.appendingPathComponent("style-payload-manifest.json"),
            options: .atomic
        )
        try JSONSerialization.data(
            withJSONObject: acceptanceChecklist,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ).write(
            to: evidenceDirectory.appendingPathComponent("production-acceptance.json"),
            options: .atomic
        )
        let latest: [String: Any] = [
            "runIdentifier": runToken,
            "manifest": evidenceDirectory.appendingPathComponent("manifest.json").path,
            "outputSHA256": sha256Hex(outputData),
        ]
        if persistEvidence {
            try JSONSerialization.data(
                withJSONObject: latest,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ).write(to: evidenceContainer.appendingPathComponent("latest.json"), options: .atomic)
        }
    }

    private struct StylesValidationResult {
        let outputData: Data
        let contaminationReport: [String: Any]
    }

    private static func validatePhotographicStylesOutput(
        _ outputURL: URL,
        expectsPortrait: Bool,
        prevalidatedStylePropertyList: Data? = nil
    ) throws -> StylesValidationResult {
        let data = try Data(contentsOf: outputURL, options: [.mappedIfSafe])
        let top = isobmffBoxes(in: data, start: 0, end: data.count)
        guard let meta = top.first(where: { $0.type == "meta" }) else {
            throw CLIError.invalidContainer("Styles validation: meta is missing")
        }
        let children = isobmffBoxes(in: data, start: meta.dataStart + 4, end: meta.dataEnd)
        guard let iinf = children.first(where: { $0.type == "iinf" }),
              let iloc = children.first(where: { $0.type == "iloc" }),
              let pitm = children.first(where: { $0.type == "pitm" }),
              let iref = children.first(where: { $0.type == "iref" }) else {
            throw CLIError.invalidContainer("Styles validation: required item graph boxes are missing")
        }
        let idat = children.first(where: { $0.type == "idat" })
        let primaryID = parseISOBMFFPITM(data, pitm)
        let items = parseISOBMFFItemInfos(data, iinf).items
        let locations = try parseISOBMFFILoc(data, iloc)
        let locationByID = Dictionary(uniqueKeysWithValues: locations.map { ($0.itemID, $0) })
        let refs = parseISOBMFFIRefs(data, iref).refs
        guard let tmapID = items.first(where: { $0.type == "tmap" })?.itemID,
              let styleMetadataID = items.first(where: { item in
                  item.type == "uri " && item.rawInfe.range(
                      of: Data("tag:apple.com,2023:photo:metadata:styles".utf8)
                  ) != nil
              })?.itemID,
              let styleLocation = locationByID[styleMetadataID],
              refs.contains(where: {
                  $0.type == "cdsc" && $0.from == styleMetadataID
                      && Set($0.to) == Set([primaryID, tmapID])
              }) else {
            throw CLIError.invalidContainer("Styles validation: style uri item or cdsc reference is missing")
        }
        let styleData = try itemPayload(in: data, entry: styleLocation, idat: idat)
        guard styleData.starts(with: Data("bplist00".utf8)),
              let object = try PropertyListSerialization.propertyList(
                  from: styleData, options: [], format: nil
              ) as? [String: Any],
              (object["0"] as? NSNumber)?.intValue == 15,
              let coefficients = object["1"] as? Data,
              coefficients.count == 51_840,
              object["2"] as? Bool == true,
              (object["3"] as? Data)?.count == 516,
              (object["c"] as? Data)?.count == 2_048,
              (object["d"] as? Data)?.count == 2_048 else {
            throw CLIError.invalidContainer("Styles validation: binary plist contract is incomplete")
        }
        if prevalidatedStylePropertyList != styleData {
            let parserDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("xdremux-style-parser-\(UUID().uuidString)", isDirectory: true)
            try ensureDirectory(parserDirectory, fileManager: .default)
            defer { try? FileManager.default.removeItem(at: parserDirectory) }
            _ = try validateWithSemanticStyleProperties(
                stylePropertyList: styleData,
                expectedStyleData: coefficients,
                outputDirectory: parserDirectory
            )
        }
        let deltaGrid = refs.first(where: { ref in
            ref.type == "dimg" && ref.to.count == 30
                && items.first(where: { $0.itemID == ref.from })?.type == "grid"
        })
        guard let deltaGrid,
              refs.contains(where: {
                  $0.type == "auxl" && $0.from == deltaGrid.from
                      && Set($0.to) == Set([primaryID, tmapID])
              }),
              data.range(of: Data("tag:apple.com,2023:photo:aux:styledeltamap".utf8)) != nil,
              data.range(of: Data("tag:apple.com,2023:photo:aux:linearthumbnail".utf8)) != nil else {
            throw CLIError.invalidContainer("Styles validation: auxiliary item graph is incomplete")
        }
        let linearCandidates = refs.filter { ref in
            ref.type == "auxl" && Set(ref.to) == Set([primaryID, tmapID])
                && items.first(where: { $0.itemID == ref.from })?.type == "hvc1"
        }
        guard !linearCandidates.isEmpty else {
            throw CLIError.invalidContainer("Styles validation: Linear Thumbnail auxl is missing")
        }
        try verifyImageIOISOGainMap(outputURL)
        guard let imageSource = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
              CGImageSourceCreateImageAtIndex(imageSource, 0, nil) != nil,
              CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                  imageSource, 0, kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte
              ) != nil else {
            throw CLIError.invalidContainer(
                "Styles validation: primary or native style sky matte is not decodable"
            )
        }
        if expectsPortrait {
            guard PortraitConversionPipeline.isValidOutput(outputURL) else {
                throw CLIError.invalidContainer("Styles validation: combined Portrait resources are incomplete")
            }
        } else {
            let person = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                imageSource, 0, kCGImageAuxiliaryDataTypePortraitEffectsMatte
            )
            let skin = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                imageSource, 0, kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte
            )
            let hasUnexpectedFullPortraitRole = [
                kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
                kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
                kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte,
            ].contains { type in
                CGImageSourceCopyAuxiliaryDataInfoAtIndex(imageSource, 0, type) != nil
            }
            guard (person == nil) == (skin == nil), !hasUnexpectedFullPortraitRole else {
                throw CLIError.invalidContainer(
                    "Styles validation: styles-only semantics must be sky-only or PEM+skin+sky"
                )
            }
        }
        let contamination = try donorContaminationScan(data: data, items: items, locations: locations, idat: idat)
        guard contamination.matches.isEmpty else {
            throw CLIError.invalidContainer(
                "donor contamination scanner matched: \(contamination.matches.joined(separator: ", "))"
            )
        }
        return StylesValidationResult(
            outputData: data,
            contaminationReport: donorContaminationReport(
                data: data,
                matches: contamination.matches,
                scannedItemCount: contamination.scannedItemCount
            )
        )
    }

    private static func donorContaminationScan(
        data: Data,
        items: [ISOBMFFItemInfo],
        locations: [ISOBMFFILocEntry],
        idat: ISOBMFFBox?
    ) throws -> (matches: [String], scannedItemCount: Int) {
        let knownPayloadSHA256: Set<String> = [
            // Persisted research-corpus donor scene resources. Constants are hashes only;
            // the product never opens or references the donor files themselves.
            "d3d468a711a21a591198aee1ef575309719256acf2b0d66468e621521687c551",
            "7b78d1cd56c175d4bbc0d5cbead9108a95086e8dfd6d3021f3041b6f875ac1ec",
            "ebe6edffebdf31be41591f6d43dad6621ae3103a229039dda2eea91607462787",
            "24288d4bc7c68ff6d75df51948da4d2fe0fa129847b46cd171dc5d818b462ae2",
            "732c0893d0e76e2d67cc15a56f13420ca7b4b050fa7f936e9a6f268c6dc1b983",
            "a0907e4e23ebb919cf817e55ea845a0e2a4c5a19cd617c4adad9b8dfa0162e58",
            "3f82ff9619e55b889bcadb78b8a5705ac87d393c5590d29ee75ebc91c1d98e6e",
            "166af88ec34efa4a188a003201c6afacbc7725a579036e7d9ab1adc5a20b56ed",
            "348f108bd9735c138c5047ddd11170b1fa50c92c899f196a112cf31645623fb8",
        ]
        var matches: [String] = []
        let itemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.itemID, $0) })
        for location in locations {
            let bytes = try itemPayload(in: data, entry: location, idat: idat)
            let digest = sha256Hex(bytes)
            if knownPayloadSHA256.contains(digest) {
                let type = itemByID[location.itemID]?.type ?? "unknown"
                matches.append("item \(location.itemID) \(type) sha256=\(digest)")
            }
            if itemByID[location.itemID]?.type == "uri ",
               let object = try? PropertyListSerialization.propertyList(
                   from: bytes, options: [], format: nil
               ) as? [String: Any] {
                for key in ["1", "3", "c", "d"] {
                    if let blob = object[key] as? Data {
                        let blobDigest = sha256Hex(blob)
                        if knownPayloadSHA256.contains(blobDigest) {
                            matches.append("style key \(key) sha256=\(blobDigest)")
                        }
                    }
                }
            }
        }
        for identifier in [
            "8E9F338B-51CA-4903-888E-6CEAF5EC8C50",
        ] where data.range(of: Data(identifier.utf8)) != nil {
            matches.append("known donor PhotoIdentifier \(identifier)")
        }
        return (matches.sorted(), locations.count)
    }

    static func donorContaminationReport(for outputURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: outputURL, options: [.mappedIfSafe])
        let top = isobmffBoxes(in: data, start: 0, end: data.count)
        guard let meta = top.first(where: { $0.type == "meta" }) else {
            throw CLIError.invalidContainer("donor scanner cannot locate meta")
        }
        let children = isobmffBoxes(in: data, start: meta.dataStart + 4, end: meta.dataEnd)
        guard let iinf = children.first(where: { $0.type == "iinf" }),
              let iloc = children.first(where: { $0.type == "iloc" }) else {
            throw CLIError.invalidContainer("donor scanner cannot locate item tables")
        }
        let result = try donorContaminationScan(
            data: data,
            items: parseISOBMFFItemInfos(data, iinf).items,
            locations: parseISOBMFFILoc(data, iloc),
            idat: children.first(where: { $0.type == "idat" })
        )
        return donorContaminationReport(
            data: data,
            matches: result.matches,
            scannedItemCount: result.scannedItemCount
        )
    }

    private static func donorContaminationReport(
        data: Data,
        matches: [String],
        scannedItemCount: Int
    ) -> [String: Any] {
        [
            "schema": "xdremux-donor-contamination-scan-v1",
            "passed": matches.isEmpty,
            "knownPayloadSHA256Count": 9,
            "knownPhotoIdentifierCount": 1,
            "scannedItemCount": scannedItemCount,
            "matches": matches,
            "outputSHA256": sha256Hex(data),
        ]
    }
}
