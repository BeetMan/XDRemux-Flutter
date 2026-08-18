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

package enum PortraitConversionPipeline {
    struct ConversionOutcome {
        let written: Bool
        let semanticFusion: [String: Any]?
        let semanticAnalysis: AppleSemanticSceneAnalysis?
        let manifestURL: URL?
    }

    private struct PortraitSourceGainMap {
        let pixelFormat: UInt32
        let width: Int
        let height: Int
    }

    private struct ParsedPortraitSourceImage {
        let baseJPEG: Data
        let gainMapJPEG: Data
        let gainMap: PortraitSourceGainMap
    }

    static func isSupportedPortraitSourceGainMapPixelFormat(_ pixelFormat: UInt32) -> Bool {
        pixelFormat == pixelFormatFourCC("444f")
            || pixelFormat == pixelFormatFourCC("L008")
    }

    static func isConvertibleInput(_ inputURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: inputURL.path),
              let inputData = try? Data(contentsOf: inputURL),
              let blocks = try? LHDRExtractor.portraitBlocks(from: inputData),
              let srcImage = blocks["src.image"],
              blocks["rear.depth"] != nil,
              blocks["rear.depth.config"] != nil,
              (try? parsePortraitSourceImage(srcImage)) != nil,
              (try? resolvePortraitGainInfoFloats(
                  privateInfo: blocks["local.uhdr.gainmap.info"],
                  inputURL: inputURL,
                  sourceImageData: srcImage
              )) != nil else {
            return false
        }
        return true
    }

    static func isValidOutput(_ outputURL: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
              CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                  source,
                  0,
                  kCGImageAuxiliaryDataTypeISOGainMap
              ) != nil,
              CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                  source,
                  0,
                  kCGImageAuxiliaryDataTypeDisparity
              ) != nil,
              CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                  source,
                  0,
                  kCGImageAuxiliaryDataTypePortraitEffectsMatte
              ) != nil,
              CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                  source,
                  0,
                  kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte
              ) != nil,
              CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                  source,
                  0,
                  kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte
              ) != nil,
              CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                  source,
                  0,
                  kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte
              ) != nil,
              CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                  source,
                  0,
                  kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte
              ) != nil else {
            return false
        }
        return true
    }

    private static func parsePortraitSourceImage(_ sourceImage: Data) throws -> ParsedPortraitSourceImage {
        guard sourceImage.starts(with: Data([0xff, 0xd8])),
              let firstEOI = sourceImage.range(of: Data([0xff, 0xd9])),
              firstEOI.upperBound + 3 <= sourceImage.count,
              sourceImage[firstEOI.upperBound..<(firstEOI.upperBound + 3)] == Data([0xff, 0xd8, 0xff]) else {
            throw CLIError.invalidContainer("portrait src.image does not contain adjacent base/gain JPEGs")
        }
        let baseJPEG = sourceImage.subdata(in: 0..<firstEOI.upperBound)
        let gainMapJPEG = sourceImage.subdata(in: firstEOI.upperBound..<sourceImage.count)
        guard let baseSource = CGImageSourceCreateWithData(baseJPEG as CFData, nil),
              CGImageSourceCreateImageAtIndex(baseSource, 0, nil) != nil,
              let gainSource = CGImageSourceCreateWithData(gainMapJPEG as CFData, nil),
              CGImageSourceCreateImageAtIndex(gainSource, 0, nil) != nil else {
            throw CLIError.invalidContainer("portrait src.image base/gain JPEG cannot be decoded")
        }
        let gainMap = try portraitSourceGainMap(from: sourceImage)
        let gainSize = try jpegImageSize(gainMapJPEG)
        guard gainMap.width == gainSize.0, gainMap.height == gainSize.1 else {
            throw CLIError.invalidContainer("portrait src.image Gain Map geometry does not match its JPEG")
        }
        return ParsedPortraitSourceImage(
            baseJPEG: baseJPEG,
            gainMapJPEG: gainMapJPEG,
            gainMap: gainMap
        )
    }

    private static func portraitSourceGainMap(from sourceData: Data) throws -> PortraitSourceGainMap {
        try withPortraitSourceURL(sourceData) { sourceURL in
            guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                  let auxiliary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                      source,
                      0,
                      kCGImageAuxiliaryDataTypeISOGainMap
                  ) as? [CFString: Any],
                  let description = auxiliary[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any],
                  let pixelFormat = portraitPixelFormat(description[kCGImagePropertyPixelFormat]),
                  let width = (description[kCGImagePropertyWidth] as? NSNumber)?.intValue,
                  let height = (description[kCGImagePropertyHeight] as? NSNumber)?.intValue,
                  width > 0,
                  height > 0 else {
                throw CLIError.invalidContainer(
                    "portrait src.image is not an ImageIO-readable ISO Gain Map"
                )
            }
            guard isSupportedPortraitSourceGainMapPixelFormat(pixelFormat) else {
                throw CLIError.invalidContainer(
                    "portrait src.image has unsupported Gain Map pixel format (\(portraitFourCC(pixelFormat)))"
                )
            }
            return PortraitSourceGainMap(pixelFormat: pixelFormat, width: width, height: height)
        }
    }

    private static func withPortraitSourceURL<T>(
        _ sourceData: Data,
        body: (URL) throws -> T
    ) throws -> T {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xdremux-portrait-src-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try sourceData.write(to: sourceURL, options: .atomic)
        return try body(sourceURL)
    }

    private static func resolvePortraitGainInfoFloats(
        privateInfo: Data?,
        inputURL: URL,
        sourceImageData: Data
    ) throws -> [Double] {
        if privateInfo != nil {
            return try resolveGainInfoFloats(privateInfo: privateInfo, inputURL: inputURL)
        }
        return try withPortraitSourceURL(sourceImageData) { sourceURL in
            try resolveGainInfoFloats(privateInfo: nil, inputURL: sourceURL)
        }
    }

    private static func portraitPixelFormat(_ value: Any?) -> UInt32? {
        if let number = value as? NSNumber {
            return number.uint32Value
        }
        if let string = value as? String, string.utf8.count == 4 {
            return pixelFormatFourCC(string)
        }
        return nil
    }

    private static func portraitFourCC(_ value: UInt32) -> String {
        String(bytes: [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ], encoding: .ascii) ?? String(format: "0x%08x", value)
    }

    private static func verifyPortraitGainMapOutput(
        _ outputURL: URL,
        expectedGainMap: PortraitSourceGainMap
    ) throws {
        guard let source = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
              let auxiliary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                  source,
                  0,
                  kCGImageAuxiliaryDataTypeISOGainMap
              ) as? [CFString: Any],
              let description = auxiliary[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any],
              let actualPixelFormat = portraitPixelFormat(description[kCGImagePropertyPixelFormat]),
              let width = (description[kCGImagePropertyWidth] as? NSNumber)?.intValue,
              let height = (description[kCGImagePropertyHeight] as? NSNumber)?.intValue else {
            throw CLIError.outputVerificationFailed(outputURL)
        }
        guard actualPixelFormat == expectedGainMap.pixelFormat else {
            throw CLIError.invalidContainer(
                "Portrait ImageIO bridge changed Gain Map pixel format from "
                    + "\(portraitFourCC(expectedGainMap.pixelFormat)) to \(portraitFourCC(actualPixelFormat))"
            )
        }
        guard width == expectedGainMap.width, height == expectedGainMap.height else {
            throw CLIError.invalidContainer("Portrait ImageIO bridge changed Gain Map geometry")
        }
    }

    static func validationReport(_ outputURL: URL) throws -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw CLIError.invalidContainer("Portrait validation cannot decode the primary image")
        }
        func auxiliary(_ type: CFString) -> [String: Any]? {
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [String: Any]
        }
        guard let gain = auxiliary(kCGImageAuxiliaryDataTypeISOGainMap),
              let disparity = auxiliary(kCGImageAuxiliaryDataTypeDisparity),
              auxiliary(kCGImageAuxiliaryDataTypePortraitEffectsMatte) != nil,
              auxiliary(kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte) != nil,
              auxiliary(kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte) != nil,
              auxiliary(kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte) != nil,
              auxiliary(kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte) != nil else {
            throw CLIError.invalidContainer("Portrait validation is missing required auxiliary images")
        }
        guard let rawMetadata = disparity[kCGImageAuxiliaryDataInfoMetadata as String],
              CFGetTypeID(rawMetadata as CFTypeRef) == CGImageMetadataGetTypeID() else {
            throw CLIError.invalidContainer("Portrait disparity has no ImageIO metadata")
        }
        let metadata = unsafeBitCast(rawMetadata as AnyObject, to: CGImageMetadata.self)
        func metadataString(_ path: String) -> String? {
            guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString),
                  let value = CGImageMetadataTagCopyValue(tag) else { return nil }
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }
        guard let encodedREND = metadataString("depthBlurEffect:RenderingParameters"),
              let rendData = Data(base64Encoded: encodedREND),
              let apertureText = metadataString("depthBlurEffect:SimulatedAperture"),
              let simulatedAperture = Double(apertureText) else {
            throw CLIError.invalidContainer("Portrait disparity is missing REND or SimulatedAperture")
        }
        let rend = try AppleRENDDocument.parse(rendData)
        guard rend.serialized() == rendData else {
            throw CLIError.invalidContainer("Portrait REND parse/serialize is not byte-identical")
        }
        func floatRecord(_ identifier: UInt16) -> Double? {
            rend.records.first(where: { $0.identifier == identifier })?.floatValue.map(Double.init)
        }
        func intRecord(_ identifier: UInt16) -> Int32? {
            guard let record = rend.records.first(where: { $0.identifier == identifier }),
                  record.valueType == 2 else { return nil }
            return Int32(bitPattern: record.rawValue)
        }
        guard let p190 = intRecord(0x0190),
              let p191 = floatRecord(0x0191),
              let p192 = floatRecord(0x0192),
              let p193 = floatRecord(0x0193),
              let c2 = floatRecord(0x01c2),
              let c3 = floatRecord(0x01c3),
              let c4 = floatRecord(0x01c4),
              let c5 = floatRecord(0x01c5),
              abs(p192 - 48 * p191) <= 1e-4,
              p191 > 0,
              c2 > 0,
              c5 >= 0 else {
            throw CLIError.invalidContainer("Portrait REND dynamic records violate producer constraints")
        }
        guard let rawGainMetadata = gain[kCGImageAuxiliaryDataInfoMetadata as String],
              CFGetTypeID(rawGainMetadata as CFTypeRef) == CGImageMetadataGetTypeID() else {
            throw CLIError.invalidContainer("Portrait gain map has no ImageIO metadata")
        }
        let gainMetadata = unsafeBitCast(rawGainMetadata as AnyObject, to: CGImageMetadata.self)
        guard let gainHeadroomTag = CGImageMetadataCopyTagWithPath(
            gainMetadata,
            nil,
            "HDRToneMap:AlternateHeadroom" as CFString
        ), let rawGainHeadroom = CGImageMetadataTagCopyValue(gainHeadroomTag) else {
            throw CLIError.invalidContainer("Portrait gain map is missing AlternateHeadroom")
        }
        let gainMapHeadroom: Double?
        if let number = rawGainHeadroom as? NSNumber {
            gainMapHeadroom = number.doubleValue
        } else if let text = rawGainHeadroom as? String {
            gainMapHeadroom = Double(text)
        } else {
            gainMapHeadroom = nil
        }
        guard let gainMapHeadroom,
              gainMapHeadroom.isFinite,
              abs(c5 - gainMapHeadroom) <= 1e-4 else {
            throw CLIError.invalidContainer("Portrait REND 0x01c5 does not match GainMapHeadroom")
        }
        let sceneActivation = p191 / 0.25
        let expectedP190 = Int32((50 * sceneActivation).rounded(.toNearestOrAwayFromZero))
        let expectedC2 = 8 * sceneActivation * min(gainMapHeadroom, 4) / 4
        guard sceneActivation > 0,
              sceneActivation <= 1.0001,
              p190 == expectedP190,
              abs(c2 - expectedC2) <= 1e-4 else {
            throw CLIError.invalidContainer("Portrait REND diverges from recovered XHLRB control scaling")
        }
        let profile0193Ratio = p193 / p191
        let profileC3Ratio = c3 / c2
        let profileC4Ratio = c4 / c2
        guard min(abs(profile0193Ratio - 1), abs(profile0193Ratio - 0.4)) <= 1e-4,
              min(abs(profileC3Ratio - 2.5), abs(profileC3Ratio - 2.875)) <= 1e-4,
              min(abs(profileC4Ratio - 0.075), abs(profileC4Ratio - 0.0875)) <= 1e-4 else {
            throw CLIError.invalidContainer("Portrait REND physical-profile ratios are invalid")
        }
        let primaryMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        let primaryXMP = primaryMetadata.flatMap { CGImageMetadataCreateXMPData($0, nil) } as Data?
        let hasFocus = primaryXMP?.range(of: Data("<mwg-rs:Type>Focus</mwg-rs:Type>".utf8)) != nil
        guard hasFocus else {
            throw CLIError.invalidContainer("Portrait primary metadata is missing Focus XMP")
        }
        let disparityDescription = disparity[kCGImageAuxiliaryDataInfoDataDescription as String] as? [String: Any]
        let gainDescription = gain[kCGImageAuxiliaryDataInfoDataDescription as String] as? [String: Any]
        let contamination = try ApplePhotographicStylesPipeline.donorContaminationReport(for: outputURL)
        guard contamination["passed"] as? Bool == true else {
            throw CLIError.invalidContainer("Portrait output contains known donor payload")
        }
        return [
            "schema": "xdremux-portrait-validation-v2",
            "passed": true,
            "outputSHA256": sha256Hex(try Data(contentsOf: outputURL, options: [.mappedIfSafe])),
            "gainMap": gainDescription ?? [:],
            "disparity": disparityDescription ?? [:],
            "focusXMP": true,
            "simulatedAperture": simulatedAperture,
            "rend": [
                "sha256": sha256Hex(rendData),
                "version": rend.version,
                "sectionVersion": rend.sectionVersion,
                "recordCount": rend.records.count,
                "byteStableRoundTrip": true,
                "dynamicRelations": [
                    "sceneActivation": sceneActivation,
                    "gainMapHeadroom": gainMapHeadroom,
                    "0190": p190,
                    "0192_over_0191": p192 / p191,
                    "0193_over_0191": profile0193Ratio,
                    "01c3_over_01c2": profileC3Ratio,
                    "01c4_over_01c2": profileC4Ratio,
                ],
            ],
            "donorContamination": contamination,
        ]
    }

    static func coreSelfTestReport() throws -> [String: Any] {
        guard let staticData = Data(base64Encoded: portraitStaticRenderingProfile3xBase64) else {
            throw CLIError.invalidContainer("self-test cannot decode the static 3x profile")
        }
        let profile = try AppleRENDDocument.parse(staticData)
        guard profile.serialized() == staticData else {
            throw CLIError.invalidContainer("self-test static profile is not byte-stable")
        }
        let dynamicIdentifiers = Set(
            Array(0x0190...0x0199).map(UInt16.init)
                + Array(0x01c2...0x01c5).map(UInt16.init)
        )
        guard profile.records.count == 153,
              profile.records.allSatisfy({ !dynamicIdentifiers.contains($0.identifier) }) else {
            throw CLIError.invalidContainer("self-test found donor scene records in a static profile")
        }
        func record(_ identifier: UInt16, _ value: Double) -> AppleRENDRecord {
            if identifier == 0x0190 {
                return AppleRENDRecord(
                    identifier: identifier,
                    valueType: 2,
                    rawValue: UInt32(bitPattern: Int32(value.rounded()))
                )
            }
            return AppleRENDRecord(
                identifier: identifier,
                valueType: 1,
                rawValue: Float(value).bitPattern
            )
        }
        func built(seed: Double) throws -> Data {
            let values = AppleXHLRBControlOutput.make(
                profileIsOneX: false,
                sceneActivation: seed,
                gainMapHeadroom: 2.0 + seed
            ).dynamicValues
            let replacements = Dictionary(uniqueKeysWithValues: values.map {
                ($0.key, record($0.key, $0.value))
            })
            let data = profile.replacing(replacements).serialized(sorted: true)
            let parsed = try AppleRENDDocument.parse(data)
            guard parsed.serialized(sorted: true) == data,
                  parsed.records.count == 167 else {
                throw CLIError.invalidContainer("self-test source-derived REND did not round-trip")
            }
            return data
        }
        let near = try built(seed: 0.12)
        let far = try built(seed: 0.21)
        guard near != far else {
            throw CLIError.invalidContainer("self-test produced identical REND for different scenes")
        }

        // IMG_7309 is a saturated 3x native capture. It exposes all eight
        // ControlLogicForXHLRB maxima and is therefore an exact regression
        // vector for the recovered CPU scaler, not a visual approximation.
        let nativeHeadroom = 3.4669768810272217
        let nativeVector = AppleXHLRBControlOutput.make(
            profileIsOneX: false,
            sceneActivation: 1.0,
            gainMapHeadroom: nativeHeadroom
        ).dynamicValues
        func approximately(_ identifier: UInt16, _ expected: Double, tolerance: Double = 1e-6) -> Bool {
            guard let actual = nativeVector[identifier] else { return false }
            return abs(actual - expected) <= tolerance
        }
        guard approximately(0x0190, 50),
              approximately(0x0191, 0.25),
              approximately(0x0192, 12),
              approximately(0x0193, 0.1),
              approximately(0x01c2, 6.933953762054443),
              approximately(0x01c3, 19.935117721557617),
              approximately(0x01c4, 0.6067209243774414),
              approximately(0x01c5, nativeHeadroom) else {
            throw CLIError.invalidContainer("self-test XHLRB scaler diverged from native IMG_7309")
        }
        let defaultControl = AppleXHLRBControlConfig.firmwareDefault
        let defaultSLM = AppleSimpleLensModelConfig.firmwareDefault
        guard defaultControl.mode == 0,
              Float(defaultControl.exposureScoreT0).bitPattern == 0x3f800000,
              Float(defaultControl.exposureScoreT1).bitPattern == 0x40a00000,
              Float(defaultControl.clippedPixelsT0).bitPattern == 0x3dcccccd,
              Float(defaultControl.clippedPixelsT1).bitPattern == 0x3f800000,
              defaultControl.maxColourDiffusionIterations == 50,
              Float(defaultControl.blurRadiusT0).bitPattern == 0x3b23d70a,
              Float(defaultControl.blurRadiusT1).bitPattern == 0x3bf5c28f,
              Float(defaultSLM.zeroShiftPercentile).bitPattern == 0x3f2b851f,
              Float(defaultSLM.shiftDeadZone).bitPattern == 0x3e560419,
              Float(defaultSLM.disparityScalingFactor).bitPattern == 0x3f800000 else {
            throw CLIError.invalidContainer("self-test XHLRB/SLM firmware defaults diverged")
        }

        let focusDispatchVectors: [(Bool, Int, Int, Bool, Bool, Bool, OPPOPortraitFocusBranch)] = [
            (false, 3, 1, true, true, false, .tappedFace),
            (false, 3, 1, false, true, false, .portraitFace),
            (false, 3, 1, false, false, false, .portraitWithoutFace),
            (false, 3, 2, false, true, false, .centerRegion),
            (false, 3, 3, false, true, true, .petRegion),
            (false, 3, 3, false, true, false, .portraitWithoutFace),
            (false, 3, 0, false, false, false, .disparityHistogram),
            (true, 0, 1, true, true, false, .nearObject),
            (true, 2, 3, false, true, true, .petRegion),
            (true, 2, 2, false, true, false, .centerRegion),
            (true, 1, 3, false, true, true, .centerRegion),
        ]
        guard focusDispatchVectors.allSatisfy({ vector in
            firmwareFocusBranch(
                nearObjectDetected: vector.0,
                sceneClass: vector.1,
                focusROIType: vector.2,
                focusedFaceAvailable: vector.3,
                portraitPlaneAvailable: vector.4,
                petPlaneAvailable: vector.5
            ) == vector.6
        }) else {
            throw CLIError.invalidContainer("self-test CalFocusDepthEngine dispatch vectors diverged")
        }

        func quantizationHeader(exponentiation: Int) -> PortraitDepthHeader {
            PortraitDepthHeader(
                width: 16,
                height: 16,
                rankDisparityScale: 0.0034504199866205454,
                focalLengthPixels: 4098.0234375,
                stereoBaseline: 38.84452438354492,
                hairPlanePresent: false,
                portraitPlanePresent: true,
                petPlanePresent: false,
                nearObjectDetected: false,
                nearObjectConfidence: nil,
                plantObjectState: 0,
                disparityMinimum: 11_560,
                disparityMaximum: 38_858,
                disparityExponentiation: exponentiation,
                auxiliaryWidth: nil,
                auxiliaryHeight: nil,
                modelOutputPresent: false,
                sceneClass: 3,
                objectDistance: 102,
                aecLuxIndex: 324.5449523925781,
                appZoomRatio: 6,
                evidence: .oppoProducerExact
            )
        }
        for exponentiation in [1, 2] {
            let header = quantizationHeader(exponentiation: exponentiation)
            for rank in [0.0, 1.0, 63.5, 127.0, 191.5, 254.0, 255.0] {
                guard let depth = header.nativeFloatDepth(forRank: rank),
                      let reconstructed = header.rank(forNativeFloatDepth: depth),
                      abs(reconstructed - rank) <= 1e-6 else {
                    throw CLIError.invalidContainer("self-test OPPO rank/float-depth round trip diverged")
                }
            }
        }
        let histogramHeader = quantizationHeader(exponentiation: 1)
        let noRectPetValues = [UInt8](repeating: 0, count: 3)
            + [UInt8](repeating: 255, count: 97)
        let petFallbackRank = producerShapedFocusHistogram(
            noRectPetValues,
            header: histogramHeader,
            targetFraction: 0.02
        )
        let portraitRank = producerShapedFocusHistogram(
            noRectPetValues,
            header: histogramHeader,
            targetFraction: 0.20
        )
        guard petFallbackRank < 1.0, portraitRank > petFallbackRank + 1.0 else {
            throw CLIError.invalidContainer("self-test PetScene 2% histogram fallback diverged")
        }

        var malformedLength = staticData
        malformedLength[8] ^= 0x01
        var malformedLengthRejected = false
        do {
            _ = try AppleRENDDocument.parse(malformedLength)
        } catch CLIError.invalidContainer {
            malformedLengthRejected = true
        }
        guard malformedLengthRejected else {
            throw CLIError.invalidContainer("self-test accepted a malformed REND length")
        }
        var duplicate = staticData
        duplicate.append(staticData.subdata(in: 16..<24))
        var duplicateLength = UInt32(duplicate.count).littleEndian
        withUnsafeBytes(of: &duplicateLength) { duplicate.replaceSubrange(8..<12, with: $0) }
        var duplicateRecordRejected = false
        do {
            _ = try AppleRENDDocument.parse(duplicate)
        } catch CLIError.invalidContainer {
            duplicateRecordRejected = true
        }
        guard duplicateRecordRejected else {
            throw CLIError.invalidContainer("self-test accepted a duplicate REND record")
        }
        let deliberatelyLongOutput = URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 240) + ".heic")
        let scratch = siblingScratchURL(
            for: deliberatelyLongOutput,
            label: "portrait-private",
            pathExtension: "heic"
        )
        guard scratch.lastPathComponent.utf8.count < 255 else {
            throw CLIError.invalidContainer("self-test produced an overlong scratch file name")
        }
        return [
            "schema": "xdremux-portrait-core-self-test-v1",
            "passed": true,
            "staticRecordCount": profile.records.count,
            "dynamicRecordCount": dynamicIdentifiers.count,
            "staticProfileContainsDynamicRecords": false,
            "nearRENDSHA256": sha256Hex(near),
            "farRENDSHA256": sha256Hex(far),
            "perSceneRENDIsDistinct": true,
            "nativeXHLRBVectorMatched": true,
            "nativeXHLRBDefaultsMatched": true,
            "focusDispatchVectorsMatched": true,
            "petNoRectHistogramFractionMatched": true,
            "nativeDepthRoundTripMatched": true,
            "byteStableRoundTrip": true,
            "malformedLengthRejected": true,
            "duplicateRecordRejected": true,
            "scratchFileNameLength": scratch.lastPathComponent.utf8.count,
            "scratchFileNameIsBounded": true,
        ]
    }

    static func hasValidISOGainMap(_ outputURL: URL) -> Bool {
        (try? verifyImageIOISOGainMap(outputURL)) != nil
    }

    static func convertIfNeeded(
        inputURL: URL,
        outputURL: URL,
        mode: PortraitMode,
        photoIdentifier: String? = nil,
        includesPhotographicStylesSemantics: Bool = false,
        semanticOutputDirectory: URL? = nil,
        writeSemanticPNGEvidence: Bool = false,
        eventHandler: ConversionEventHandler? = nil
    ) throws -> Bool {
        try convertWithOutcome(
            inputURL: inputURL,
            outputURL: outputURL,
            mode: mode,
            photoIdentifier: photoIdentifier,
            includesPhotographicStylesSemantics: includesPhotographicStylesSemantics,
            semanticOutputDirectory: semanticOutputDirectory,
            writeSemanticPNGEvidence: writeSemanticPNGEvidence,
            eventHandler: eventHandler
        ).written
    }

    static func convertWithOutcome(
        inputURL: URL,
        outputURL: URL,
        mode: PortraitMode,
        photoIdentifier: String? = nil,
        includesPhotographicStylesSemantics: Bool = false,
        semanticOutputDirectory: URL? = nil,
        writeSemanticPNGEvidence: Bool = false,
        eventHandler: ConversionEventHandler? = nil
    ) throws -> ConversionOutcome {
        guard mode != .off else {
            return ConversionOutcome(
                written: false,
                semanticFusion: nil,
                semanticAnalysis: nil,
                manifestURL: nil
            )
        }
        let conversionStartedAt = CFAbsoluteTimeGetCurrent()
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw CLIError.inputNotFound(inputURL)
        }
        let inputData = try Data(contentsOf: inputURL)
        let resolvedPhotoIdentifier = photoIdentifier ?? UUID().uuidString.uppercased()
        let hasPortraitUserComment = portraitUserCommentFlag(in: inputURL)
        let blocks: [String: Data]
        do {
            blocks = try LHDRExtractor.portraitBlocks(from: inputData)
        } catch {
            throw CLIError.invalidContainer(
                "--apple-portrait requires an OPPO private tail containing rear.depth"
            )
        }
        guard
              let srcImage = blocks["src.image"],
              let rearDepthConfig = blocks["rear.depth.config"],
              let compressedDepth = blocks["rear.depth"] else {
            throw CLIError.invalidContainer(
                "--apple-portrait requires OPPO portrait UserComment, src.image, and rear.depth"
            )
        }
        if !hasPortraitUserComment {
            print(
                "warning: portrait UserComment flag is absent; recovering from "
                    + "rear.depth + rear.depth.config + src.image"
            )
        }
        let infoFloats = try resolvePortraitGainInfoFloats(
            privateInfo: blocks["local.uhdr.gainmap.info"],
            inputURL: inputURL,
            sourceImageData: srcImage
        )
        let parsedSourceImage = try parsePortraitSourceImage(srcImage)
        let baseJPEG = parsedSourceImage.baseJPEG
        let srcImageGainJPEG = parsedSourceImage.gainMapJPEG
        guard let baseSource = CGImageSourceCreateWithData(baseJPEG as CFData, nil),
              let baseImage = CGImageSourceCreateImageAtIndex(
                  baseSource,
                  0,
                  [kCGImageSourceShouldCache: true] as CFDictionary
              ) else {
            throw CLIError.invalidContainer("unable to decode portrait src.image base JPEG")
        }
        let baseProperties = CGImageSourceCopyPropertiesAtIndex(baseSource, 0, nil) as? [CFString: Any]
        let inputSource = CGImageSourceCreateWithURL(inputURL as CFURL, nil)
        let inputProperties = inputSource.flatMap {
            CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
        }
        let portraitConfig = try parsePortraitConfig(rearDepthConfig)
        let simulatedAperture: (value: Double, source: String)
        if let fNumber = portraitConfig.currentFNumber {
            simulatedAperture = (fNumber, "rear.depth.config")
            print(String(format: "portrait aperture f/%.1f source=rear.depth.config-v%.1f", fNumber, portraitConfig.version))
        } else {
            simulatedAperture = resolveSimulatedAperture(
                rearDepthConfig: nil,
                inputProperties: inputProperties,
                baseProperties: baseProperties
            )
        }
        let afMeasuredDepth = portraitConfig.objectDistance
        if let afMeasuredDepth {
            print("portrait AF measured depth source=rear.depth.config distance=\(afMeasuredDepth)")
        }
        let inputOrientation = (inputProperties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
        let baseOrientation = (baseProperties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
        let inputWidth = (inputProperties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let inputHeight = (inputProperties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        let gainJPEG = srcImageGainJPEG
        let gainSize = try jpegImageSize(gainJPEG)
        print("portrait Gain Map source=src.image geometry=\(gainSize.0)x\(gainSize.1)")
        let orientationRaw = resolvedBaseOrientation(
            inputWidth: inputWidth,
            inputHeight: inputHeight,
            inputOrientation: inputOrientation,
            baseWidth: baseImage.width,
            baseHeight: baseImage.height,
            baseOrientation: baseOrientation
        )
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up
        let decodedDepth = try decompressZstd(compressedDepth)
        let depthHeader = try parseDepthHeader(decodedDepth)
        let depthWidth = depthHeader.width
        let depthHeight = depthHeader.height
        let depthPlanes = try parseDepthPlanes(decodedDepth, header: depthHeader)
        let depthRanks = depthPlanes.ranks
        let focus = try makeFocusRegion(
            image: baseImage,
            orientation: orientation,
            orientationRaw: orientationRaw,
            config: portraitConfig
        )
        let focusSelection = selectPortraitFocus(
            ranks: depthRanks,
            planes: depthPlanes,
            header: depthHeader,
            config: portraitConfig,
            sourceWidth: baseImage.width,
            sourceHeight: baseImage.height,
            width: depthWidth,
            height: depthHeight,
            focus: focus
        )
        let focusRank = focusSelection.selectedRank
        let effectiveDepthFocalLengthPixels = depthHeader.focalLengthPixels
            * Double(baseImage.width) / Double(depthWidth)
        let cameraCalibration = try makeCameraCalibration(
            inputProperties: inputProperties,
            baseProperties: baseProperties,
            baseWidth: baseImage.width,
            baseHeight: baseImage.height,
            effectiveFocalLengthPixels: effectiveDepthFocalLengthPixels
        )
        // The auxiliary is explicitly tagged relative. Its zero offset is
        // therefore a gauge choice, while the nonlinear distance between ranks
        // comes from the OPPO producer's min/max/exponent quantizer. Focal
        // length is not multiplied into this range a second time.
        let disparityFar = 0.0
        let disparityScale = depthHeader.rankDisparityScale
        let disparitySpan = 255.0 * disparityScale
        let disparityNear = disparityFar + disparitySpan
        let normalizedFocusRank = pow(
            min(max(focusRank / 255.0, 0), 1),
            Double(depthHeader.disparityExponentiation)
        )
        let focusDisparity = disparityFar + (1.0 - normalizedFocusRank) * disparitySpan
        print(String(
            format: "portrait disparity header=%dx%d fxDepth=%.3f effectiveFx=%.3f rankScale=%.7f baseline=%.3f focusRank=%.3f focusDisparity=%.6f range=%.6f...%.6f fullSpan=%.6f",
            depthHeader.width,
            depthHeader.height,
            depthHeader.focalLengthPixels,
            effectiveDepthFocalLengthPixels,
            depthHeader.rankDisparityScale,
            depthHeader.stereoBaseline,
            focusRank,
            focusDisparity,
            disparityFar,
            disparityNear,
            disparitySpan
        ))
        let blurResponse = try makeBlurResponse(config: portraitConfig, header: depthHeader)
        let rend = try makeSourceDerivedREND(
            templateBase64: cameraCalibration.renderingParametersBase64,
            profileName: cameraCalibration.profileName,
            focus: focusSelection,
            focusDisparity: focusDisparity,
            disparitySpan: disparitySpan,
            config: portraitConfig,
            header: depthHeader,
            blurResponse: blurResponse,
            gainInfoFloats: infoFloats
        )
        print(
            "portrait REND source=per-photo-source-derived sha256=\(sha256Hex(rend.rawData)) "
                + "dynamic=\(rend.dynamicRecords.keys.sorted().joined(separator: ","))"
        )

        let parent = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let carrier = siblingScratchURL(for: outputURL, label: "portrait-carrier", pathExtension: "heic")
        let firstAssembly = siblingScratchURL(for: outputURL, label: "portrait-first", pathExtension: "heic")
        let scaffold = siblingScratchURL(for: outputURL, label: "portrait-scaffold", pathExtension: "heic")
        defer {
            if ProcessInfo.processInfo.environment["XDREMUX_KEEP_PORTRAIT_SCRATCH"] != "1" {
                for url in [carrier, firstAssembly, scaffold] {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        guard let carrierDestination = CGImageDestinationCreateWithURL(
            carrier as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw CLIError.unableToCreateDestination(carrier)
        }
        let portraitBaseQuality = EncodingQualityPolicy.value(
            environmentKey: "XDREMUX_PORTRAIT_BASE_QUALITY",
            defaultValue: 0.9
        )
        CGImageDestinationAddImageFromSource(
            carrierDestination,
            baseSource,
            0,
            // Quality 1.0 makes ImageIO choose a 4:4:4 RExt Base that its own
            // ISO Gain Map reader rejects. The 0.9 Main Still Picture tier is
            // the measured size/quality knee across low, medium, and high-detail
            // portrait sources.
            [kCGImageDestinationLossyCompressionQuality: portraitBaseQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(carrierDestination) else {
            throw CLIError.unableToFinalizeDestination(carrier)
        }

        try writeSrcImagePreserveBridge(
            sourceImageData: srcImage,
            metadataSourceURL: carrier,
            outputURL: firstAssembly,
            expectedGainMap: parsedSourceImage.gainMap,
            eventHandler: eventHandler
        )

        guard let firstSource = CGImageSourceCreateWithURL(firstAssembly as CFURL, nil),
              CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                  firstSource,
                  0,
                  kCGImageAuxiliaryDataTypeISOGainMap
              ) != nil else {
            throw CLIError.outputVerificationFailed(firstAssembly)
        }
        let depthDictionary = try makeDepthDictionary(
            ranks: depthRanks,
            width: depthWidth,
            height: depthHeight,
            orientation: orientationRaw,
            far: Float(disparityFar),
            near: Float(disparityNear),
            disparityExponentiation: depthHeader.disparityExponentiation,
            calibration: cameraCalibration,
            renderingParametersBase64: rend.base64,
            simulatedAperture: simulatedAperture.value
        )
        let mattes = try makePortraitEffectsMattes(
            imageURL: firstAssembly,
            orientationRaw: orientationRaw,
            depthPlanes: depthPlanes,
            targetWidth: baseImage.width / 2,
            targetHeight: baseImage.height / 2,
            semanticOutputDirectory: semanticOutputDirectory,
            includesPhotographicStylesSemantics: includesPhotographicStylesSemantics,
            writeSemanticPNGEvidence: writeSemanticPNGEvidence
        )
        try writeBlankPortraitScaffold(
            sourceMetadataURL: inputURL,
            baseWidth: baseImage.width,
            baseHeight: baseImage.height,
            baseColorSpace: baseImage.colorSpace,
            orientation: orientationRaw,
            focus: focus,
            afMeasuredDepth: afMeasuredDepth,
            photoIdentifier: resolvedPhotoIdentifier,
            captureDate: captureDateString(sourceURL: inputURL),
            sourceImageData: srcImage,
            sourceGainMap: parsedSourceImage.gainMap,
            depthDictionary: depthDictionary,
            matteDictionary: mattes.portrait,
            skinDictionary: mattes.skin,
            hairDictionary: mattes.hair,
            teethDictionary: mattes.teeth,
            glassesDictionary: mattes.glasses,
            skyDictionary: includesPhotographicStylesSemantics ? mattes.sky : nil,
            outputURL: scaffold,
            eventHandler: eventHandler
        )
        try transplantPortraitBaseAndGainPayloads(
            payloadSourceURL: firstAssembly,
            scaffoldURL: scaffold,
            outputURL: outputURL
        )
        try verifyPortraitGainMapOutput(
            outputURL,
            expectedGainMap: parsedSourceImage.gainMap
        )
        let sourceEquivalentFocalLength = cameraCalibration.opticalEquivalentFocalLengthMM
            * cameraCalibration.digitalZoomRatio
        let profileSaturated = sourceEquivalentFocalLength
            > cameraCalibration.profileMaximumValidatedEquivalentFocalLengthMM + 0.001
        let appleProfile = ApplePortraitRenderProfile(
            identifier: cameraCalibration.profileName,
            physicalLensFamily: cameraCalibration.profileName,
            validatedEquivalentFocalRange: [
                cameraCalibration.profileAnchorEquivalentFocalLengthMM,
                cameraCalibration.profileMaximumValidatedEquivalentFocalLengthMM,
            ],
            staticRecordIdentifiers: rend.staticRecordIdentifiers,
            evidence: .consumerCalibrated
        )
        var warnings = rend.warnings
        if profileSaturated {
            warnings.append(String(
                format: "source equivalent focal length %.2fmm saturates at validated Apple profile limit %.2fmm; source EXIF is unchanged",
                sourceEquivalentFocalLength,
                cameraCalibration.profileMaximumValidatedEquivalentFocalLengthMM
            ))
        }
        var manifestFallbacks = [
            "Apple XHLRB exposure/clipped-pixel scene activation: controlled_corpus_fit",
        ]
        if focusSelection.roiEvidence == .compatibilityFallback
            || focusSelection.statisticEvidence == .compatibilityFallback {
            manifestFallbacks.insert(
                "focus ROI/statistic: compatibility_fallback; branch dispatch, LTWH geometry, rank-to-float-depth conversion, center 5x5 mean, generic 5% histogram, and no-rect PetScene 2% histogram are producer-exact",
                at: 0
            )
        }
        let manifest = PortraitTranslationManifest(
            schema: "xdremux-portrait-translation-v2",
            inputSHA256: sha256Hex(inputData),
            oppoFirmwareBuild: "PMA110_11.A.60_0600_202606282013",
            appleFirmwareBuild: "iPhone18,1 iOS 26.5.2 23F84",
            config: portraitConfig,
            depthHeader: depthHeader,
            focus: focusSelection,
            blurResponse: blurResponse,
            appleProfile: appleProfile,
            appleSceneState: rend.sceneState,
            appleWrittenDisparityRange: [disparityFar, disparityNear],
            finalRENDSHA256: sha256Hex(rend.rawData),
            staticRENDRecords: rend.staticRecordIdentifiers,
            dynamicRENDRecords: rend.dynamicRecords,
            nativeGenerator: rend.nativeGenerator,
            fallbacks: manifestFallbacks,
            warnings: warnings
        )
        let manifestStem = outputURL.deletingPathExtension().lastPathComponent
        let manifestURL = parent.appendingPathComponent("\(manifestStem).portrait-manifest.json")
        let manifestEncoder = JSONEncoder()
        manifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try manifestEncoder.encode(manifest).write(to: manifestURL, options: .atomic)
        print("portrait manifest=\(manifestURL.path)")
        print(String(
            format: "portrait pipeline elapsed=%.3fs",
            CFAbsoluteTimeGetCurrent() - conversionStartedAt
        ))
        return ConversionOutcome(
            written: true,
            semanticFusion: mattes.fusionReport,
            semanticAnalysis: mattes.semanticAnalysis,
            manifestURL: manifestURL
        )
    }

    private static func writeSrcImagePreserveBridge(
        sourceImageData: Data,
        metadataSourceURL: URL?,
        outputURL: URL,
        expectedGainMap: PortraitSourceGainMap,
        eventHandler: ConversionEventHandler? = nil
    ) throws {
        try withPortraitSourceURL(sourceImageData) { sourceURL in
            guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                  let destination = CGImageDestinationCreateWithURL(
                      outputURL as CFURL,
                      UTType.heic.identifier as CFString,
                      1,
                      nil
                  ) else {
                throw CLIError.unableToCreateDestination(outputURL)
            }

            var imageOptions: [CFString: Any] = [
                kCGImageDestinationPreserveGainMap: true,
            ]
            if let metadataSourceURL,
               let metadataSource = CGImageSourceCreateWithURL(metadataSourceURL as CFURL, nil) {
                if let properties = CGImageSourceCopyPropertiesAtIndex(metadataSource, 0, nil) as? [CFString: Any] {
                    for (key, value) in properties {
                        imageOptions[key] = value
                    }
                }
                if let metadata = CGImageSourceCopyMetadataAtIndex(metadataSource, 0, nil) {
                    imageOptions[kCGImageDestinationMergeMetadata] = metadata
                }
            }
            CGImageDestinationAddImageFromSource(
                destination,
                source,
                0,
                imageOptions as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else {
                throw CLIError.unableToFinalizeDestination(outputURL)
            }
            try verifyPortraitGainMapOutput(outputURL, expectedGainMap: expectedGainMap)
        }
        eventHandler?(.diagnostic(
            "[portrait] ImageIO preserved src.image Gain Map (\(portraitFourCC(expectedGainMap.pixelFormat))) "
                + "\(expectedGainMap.width)x\(expectedGainMap.height)"
        ))
    }

    // These blobs contain only profile-invariant records. All records emitted
    // by ControlLogicForXHLRB are absent and are added per photo below.
    private static let portraitStaticRenderingProfile1xBase64 = """
    UkVORAcAAADYBAAAAQAAAGQAAgAAAAAAZQACAAIAAABmAAEAj8L1PGcAAQDNzMw9aAABAArXIz1pAAEAMzOzP2oAAQDNzEw9awABAJqZmT5sAAEAzczMP20AAQAAAABAbgACABQAAABvAAEAzcxMPXAAAQBYOTQ8cQABAArXIzxyAAEAzczMPXMAAQAK1yM9dAABAAAAgD91AAEAAABAP3YAAQBmZmY/dwABAJqZmT94AAEAAAAAQHkAAQDNzMw+egABAM3MzD17AAEAAACAP3wAAQAAAABAfQABAAAAAEF+AAEAF7fROH8AAgAyAAAAgAABAAAAgD/IAAEAPQoXP8kAAQAAAEA/ygABAPfMEjksAQEACtcjPC0BAQAXSJI5LgEBADVeuj0vAQEAMzOzPzABAQDgLRA7MQEBAFoMQzoyAQEAAACAPzMBAQAAAIA/xgEBADMzm0DyAQIACQAAAPMBAgAMAAAA9AECAAkAAAD1AQEAAAB6RPYBAQCamRk+9wEBAFK4nj74AQEAAAAAQPkBAQAAwA9F+gEBAM3MTD37AQEAMzOzPvwBAgACAAAA/QEBAJqZmT7+AQEAAACgP/8BAQBmZmY/AAICAAYAAAABAgEAAACAPwICAQAAAAAAWAIBADMzM0BZAgEAMzOzP1oCAQAAAIBBWwIBAHTaoD+8AgEAAAAAAL0CAQAAAAAAIAMCAAMAAAAhAwEAzcxMvSIDAQAK16M8IwMBAM3MTL0kAwEAj8L1PYQDAQDNzEw/hQMBAAAAgD+GAwEAAAAAAIcDAQAAAAAAiAMBAM3MzD6JAwEA4C2QOugDAQCamZk+6QMBAAAAoEDqAwEAmpmZPusDAQDNzEw/7AMBAAAAAADtAwEAAACAP+4DAQAzMzO/7wMBAGZmZj/wAwEAj8L1PPEDAQBvEoM68gMBAAAAAADzAwIAhwAAAPQDAQDNzMw+9QMBAAAAgD/2AwIAFAAAAPcDAQDNzMw++AMBAAAAAAD5AwEAzcxMP/oDAQAAAIA/+wMBAAAAAAD8AwEAzcxMPv0DAQAAAAAA/gMBAAAAAAD/AwEAzczMPwAEAgACAAAAAQQBAAAAAAACBAEAbxIDOgMEAQCamVk/BAQBAAAAAAAFBAEAAACAPwYEAQDNzEw/BwQBAJqZmT4IBAEAAAAAQAkEAQB7FC4+CgQBADMzsz4LBAEAAACAPwwEAQAAAAAADQQBAJqZmT4OBAEAzczMPQ8EAQDNzEw+TAQBAGZm5j5NBAEAAAAAAE4EAQAAAAAATwQBAM3MzD1QBAEAZmZmP7AEAgAJAAAAsQQCAAQAAACyBAIADAAAALMEAQAAAIA/tAQBAAAAgD+1BAEA16PwPrYEAQAUrkc/twQBAAAAAMC4BAEAAAAAALkEAQAAAIC/ugQBAJqZGT67BAEAzczMPbwEAQCamZk/vQQBAFyPwj6+BAIABAAAABQFAQAAAIA+FQUBAL99XT4WBQEACtcjPBcFAQCPwvU8GAUBADMzcz8ZBQEApptEPRoFAQAXt9E5GwUBAF8pSzscBQEA9igcPx0FAQAK16M8HgUBAArXIzwfBQEAZmYmQCAFAQAAAEA/IQUBAGwJ+ToiBQEAj8L1PCMFAQBmZmY/JAUBAJqZmT4lBQEAAADAPw==
    """.trimmingCharacters(in: .whitespacesAndNewlines)

    private static let portraitStaticRenderingProfile2xBase64 = """
    UkVORAcAAADYBAAAAQAAAGQAAgAAAAAAZQACAAIAAABmAAEAj8L1PGcAAQDNzMw9aAABAArXIz1pAAEAMzOzP2oAAQDNzEw9awABAJqZmT5sAAEAAADAP20AAQBiEChAbgACABQAAABvAAEAzcxMPXAAAQDNzMw8cQABAArXIzxyAAEAzczMPXMAAQDNzMw9dAABAAAAgD91AAEAAABAP3YAAQBmZmY/dwABAJqZmT94AAEAAAAAQHkAAQDNzMw+egABAM3MzD17AAEAAACAP3wAAQAAAABAfQABAAAAAEF+AAEAF7fROH8AAgAyAAAAgAABAAAAgD/IAAEA7FG4PckAAQCamVk/ygABABe3UTksAQEACtcjPC0BAQAXSJI5LgEBADVeuj0vAQEAMzOzPzABAQDgLRA7MQEBAFoMQzoyAQEAAACAPzMBAQAAAIA/xgEBAAAAMEHyAQIACQAAAPMBAgAMAAAA9AECAAkAAAD1AQEAAAB6RPYBAQAAAAAA9wEBAFK4nj74AQEAAAAAQPkBAQAAAJZD+gEBAM3MTD37AQEAzczMPvwBAgACAAAA/QEBAAAAgD7+AQEAAADAP/8BAQAzM3M/AAICAAcAAAABAgEAAACAPwICAQAAAAAAWAIBAAAAkEBZAgEAMzOzP1oCAQAAAIBBWwIBAAAAgD+8AgEAAAAAAL0CAQAAAAAAIAMCAAMAAAAhAwEAzcxMvSIDAQAK16M8IwMBAM3MTL0kAwEAj8L1PYQDAQDNzEw/hQMBAAAAgD+GAwEAAAAAAIcDAQAAAAAAiAMBAM3MzD6JAwEAAAAAAOgDAQCamZk+6QMBAAAAoEDqAwEAmpmZPusDAQDNzEw/7AMBAAAAAADtAwEAAACAP+4DAQAzMzO/7wMBAGZmZj/wAwEAAAAAAPEDAQAAAAAA8gMBAAAAAADzAwIAWgAAAPQDAQDNzMw+9QMBAM3MTD72AwIAFAAAAPcDAQDNzMw++AMBAAAAAAD5AwEAzcxMP/oDAQAAAIA/+wMBAAAAAAD8AwEAzcxMPv0DAQAAAAAA/gMBAAAAAAD/AwEAmpmZPgAEAgACAAAAAQQBAAAAAAACBAEAbxIDOgMEAQAAAIA/BAQBAAAAAAAFBAEAAACAPwYEAQDNzEw/BwQBAJqZmT4IBAEAAAAgQAkEAQDNzMw9CgQBADMzsz4LBAEAAACAPwwEAQAAAAAADQQBAJqZmT4OBAEAzczMPQ8EAQCamRk+TAQBAAAAAD9NBAEAAAAAAE4EAQAAAAAATwQBAM3MTD5QBAEAzcxMP7AEAgAJAAAAsQQCAAQAAACyBAIADAAAALMEAQAAAIA/tAQBAAAAgD+1BAEAAAAAP7YEAQDNzEw/twQBAAAAAMC4BAEAAAAAALkEAQAAAIC/ugQBAJqZGT67BAEAzcxMPrwEAQCamZk/vQQBAJqZGT++BAIAAQAAABQFAQDNzEw+FQUBAOxROD4WBQEACtcjPRcFAQBxPYo+GAUBAGZmZj8ZBQEAj8L1PBoFAQBvEoM6GwUBABe30TgcBQEAzcwMPx0FAQAlSZI7HgUBAAAAgD4fBQEAZmYmQCAFAQAAAEA/IQUBAG8SgzoiBQEAAAAAACMFAQBmZmY/JAUBAMP1qD4lBQEAAADAPw==
    """.trimmingCharacters(in: .whitespacesAndNewlines)

    private static let portraitStaticRenderingProfile3xBase64 = """
    UkVORAcAAADYBAAAAQAAAGQAAgAAAAAAZQACAAIAAABmAAEAj8L1PGcAAQDn+6k9aAABAM3MTD1pAAEAMzOzP2oAAQDNzEw9awABAJqZmT5sAAEAAAAAP20AAQAAAChAbgACABQAAABvAAEAzcxMPXAAAQDNzMw8cQABAArXIzxyAAEAzczMPXMAAQDNzMw9dAABAM3MzD51AAEAAABAP3YAAQBmZmY/dwABAJqZmT94AAEAAAAAQHkAAQDNzMw+egABAM3MzD17AAEAAACAP3wAAQAAAABAfQABAAAAAEF+AAEAF7fROH8AAgAyAAAAgAABAAAAgD/IAAEAKVyPPckAAQCamVk/ygABABe3UTksAQEACtcjPC0BAQAXSJI5LgEBADVeuj0vAQEAMzOzPzABAQDgLRA7MQEBAFoMQzoyAQEAAACAPzMBAQAAAIA/xgEBAAAAIEHyAQIACQAAAPMBAgAMAAAA9AECAAkAAAD1AQEAAAB6RPYBAQAAAAAA9wEBAFK4nj74AQEAAAAAQPkBAQAAAJZD+gEBAM3MTD37AQEAzczMPvwBAgACAAAA/QEBAAAAgD7+AQEAAADAP/8BAQBmZmY/AAICAAcAAAABAgEAAACAPwICAQAAAAAAWAIBAAAAkEBZAgEAMzOzP1oCAQAAAIBBWwIBAJMYhD+8AgEAAAAAAL0CAQAAAAAAIAMCAAMAAAAhAwEAzcxMvSIDAQAK16M8IwMBAM3MTL0kAwEAj8L1PYQDAQDNzEw/hQMBAAAAgD+GAwEAAAAAAIcDAQAAAAAAiAMBAM3MzD6JAwEAAAAAAOgDAQCamZk+6QMBAAAAoEDqAwEAmpmZPusDAQDNzEw/7AMBAAAAgD/tAwEAAACAP+4DAQAzMzO/7wMBAGZmZj/wAwEAbxKDOvEDAQAAAAAA8gMBAAAAAADzAwIAyAAAAPQDAQDNzMw+9QMBAAAAgD/2AwIAFAAAAPcDAQDNzMw++AMBAAAAAAD5AwEAzcxMP/oDAQAAAIA/+wMBAAAAAAD8AwEAzcxMPv0DAQAAAAAA/gMBAAAAAAD/AwEAmpmZPgAEAgACAAAAAQQBAAAAAAACBAEAbxIDOgMEAQAAAIA/BAQBAAAAAAAFBAEAAACAPwYEAQDNzEw/BwQBAJqZmT4IBAEAzcwMQAkEAQDNzMw9CgQBAFyPAj8LBAEAAACAPwwEAQDNzEw+DQQBAM3MTD4OBAEAzcxMPg8EAQAAAAA/TAQBAAAAAD9NBAEAAAAAAE4EAQAAAAAATwQBAM3MTD5QBAEAzcxMP7AEAgAJAAAAsQQCAAQAAACyBAIADAAAALMEAQAAAIA/tAQBAAAAgD+1BAEAmpkZP7YEAQA9Clc/twQBAAAAAMC4BAEAAAAAALkEAQAAAIC/ugQBALgeBT67BAEA8tJNPrwEAQCamZk/vQQBAAAAAAC+BAIAAAAAABQFAQApXI8+FQUBAClcjz4WBQEAKVwPPRcFAQAK16M8GAUBADMzcz8ZBQEAKVwPPRoFAQCmm0Q7GwUBADEMwzocBQEAzczMPh0FAQAlSZI7HgUBAArXIz0fBQEAAABAQCAFAQDXozA/IQUBACAIAjsiBQEAAAAAACMFAQCPwjU/JAUBAMP1qD4lBQEAAADAPw==
    """.trimmingCharacters(in: .whitespacesAndNewlines)

    private static let portraitStaticRenderingProfile5xBase64 = """
    UkVORAcAAADYBAAAAQAAAGQAAgAAAAAAZQACAAIAAABmAAEAj8L1PGcAAQDn+6k9aAABAM3MTD1pAAEAMzOzP2oAAQDNzEw9awABAJqZmT5sAAEAAAAAP20AAQAAAChAbgACABQAAABvAAEAzcxMPXAAAQDNzMw8cQABAArXIzxyAAEAzczMPXMAAQDNzMw9dAABAM3MzD51AAEAAABAP3YAAQBmZmY/dwABAJqZmT94AAEAAAAAQHkAAQDNzMw+egABAM3MzD17AAEAAACAP3wAAQAAAABAfQABAAAAAEF+AAEAF7fROH8AAgAyAAAAgAABAAAAgD/IAAEAKVyPPckAAQCamVk/ygABABe3UTksAQEACtcjPC0BAQAXSJI5LgEBADVeuj0vAQEAMzOzPzABAQDgLRA7MQEBAFoMQzoyAQEAAACAPzMBAQAAAIA/xgEBAAAAIEHyAQIACQAAAPMBAgAMAAAA9AECAAkAAAD1AQEAAAB6RPYBAQAAAAAA9wEBAFK4nj74AQEAAAAAQPkBAQAAAJZD+gEBAM3MTD37AQEAzczMPvwBAgACAAAA/QEBAClcjz7+AQEAAADAP/8BAQBmZmY/AAICAAcAAAABAgEAAACAPwICAQAAAAAAWAIBAAAAkEBZAgEAMzOzP1oCAQAAAIBBWwIBALgehT+8AgEAAAAAAL0CAQAAAAAAIAMCAAMAAAAhAwEAzcxMvSIDAQAK16M8IwMBAM3MTL0kAwEAj8L1PYQDAQDNzEw/hQMBAAAAgD+GAwEACtcjPIcDAQAAAAAAiAMBAM3MzD6JAwEAWDk0POgDAQCamZk+6QMBAAAAoEDqAwEAmpmZPusDAQDNzEw/7AMBAAAAgD/tAwEAAACAP+4DAQAzMzO/7wMBAGZmZj/wAwEAWDk0PPEDAQAAAAAA8gMBAAAAAADzAwIAyAAAAPQDAQCamRk/9QMBAJqZmT/2AwIAFAAAAPcDAQDNzMw++AMBAAAAAAD5AwEAzcxMP/oDAQAAAIA/+wMBAAAAAAD8AwEAzcxMPv0DAQAAAAAA/gMBAAAAAAD/AwEAmpmZPgAEAgACAAAAAQQBAAAAAAACBAEAbxIDOgMEAQAAAIA/BAQBAAAAAAAFBAEAAACAPwYEAQB7FG4/BwQBAM3MzD4IBAEAZmYGQAkEAQCamRk+CgQBAM3MDD8LBAEAAACAPwwEAQAAAIA+DQQBAM3MTD4OBAEAzczMPQ8EAQAzM7M+TAQBAAAAAD9NBAEAAAAAAE4EAQAAAAAATwQBAM3MTD5QBAEAzcxMP7AEAgAJAAAAsQQCAAQAAACyBAIADAAAALMEAQAAAIA/tAQBAAAAgD+1BAEAmpkZP7YEAQA9Clc/twQBAAAAAMC4BAEAAAAAALkEAQAAAIC/ugQBALgeBT67BAEA8tJNPrwEAQCamZk/vQQBAAAAAAC+BAIAAAAAABQFAQB7FK4+FQUBAPCnhj4WBQEAbxIDPRcFAQAK1yM8GAUBAB+Faz8ZBQEAbxIDPRoFAQBvEoM6GwUBADEMwzocBQEAMzOzPh0FAQAXt9E7HgUBAI/CdT0fBQEAmpl5QCAFAQCF61E/IQUBAKabRDsiBQEAAAAAACMFAQDhehQ/JAUBAMP1qD4lBQEAAADAPw==
    """.trimmingCharacters(in: .whitespacesAndNewlines)

    private static func validatedRenderingParametersBase64(_ encoded: String) throws -> String {
        guard let data = Data(base64Encoded: encoded),
              data.count >= 24,
              data.prefix(4) == Data("REND".utf8) else {
            throw CLIError.invalidContainer("invalid portrait REND compatibility template")
        }
        // REND is a lens-coupled compatibility profile. The current aperture is
        // carried by depthBlurEffect:SimulatedAperture and Photos adjustment
        // data; record 0x012f is not the per-edit aperture control.
        return data.base64EncodedString()
    }

    private static func portraitUserCommentFlag(in url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let comment = exif[kCGImagePropertyExifUserComment] as? String,
              let underscore = comment.lastIndex(of: "_"),
              let value = UInt64(comment[comment.index(after: underscore)...]) else {
            return false
        }
        return value & 65_536 != 0
    }

    private static func decompressZstd(_ data: Data) throws -> Data {
        #if canImport(UIKit)
        // iOS: no subprocesses. The host app installs an embedded zstd
        // decoder here (Phase 2); until then portrait payload decoding is
        // unavailable.
        guard let decoder = zstdDecoder else {
            throw CLIError.invalidContainer(
                "iOS build has no embedded zstd decoder installed")
        }
        return try decoder(data)
        #else
        let directory = FileManager.default.temporaryDirectory
        let input = directory.appendingPathComponent("xdremux-depth-\(UUID().uuidString).zst")
        defer { try? FileManager.default.removeItem(at: input) }
        try data.write(to: input, options: .atomic)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["zstd", "-d", "-q", "-c", input.path]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch {
            throw CLIError.invalidContainer("--apple-portrait requires the zstd command-line tool")
        }
        let decoded = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "zstd failed"
            throw CLIError.invalidContainer(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return decoded
        #endif
    }

    #if canImport(UIKit)
    /// iOS: embedded zstd decoder installed by the host app (the macOS
    /// build shells out to the `zstd` CLI, which does not exist on iOS).
    static package var zstdDecoder: ((Data) throws -> Data)?
    #endif

    private static func registerMetadataNamespace(
        _ metadata: CGMutableImageMetadata,
        namespace: String,
        prefix: String
    ) throws {
        var error: Unmanaged<CFError>?
        guard CGImageMetadataRegisterNamespaceForPrefix(
            metadata,
            namespace as CFString,
            prefix as CFString,
            &error
        ) else {
            if let error { throw error.takeRetainedValue() as Error }
            throw CLIError.invalidContainer("unable to register metadata namespace \(prefix)")
        }
    }

    private static func setMetadata(
        _ metadata: CGMutableImageMetadata,
        path: String,
        value: String
    ) throws {
        try setMetadataValue(metadata, path: path, value: value as CFString)
    }

    private static func setMetadataValue(
        _ metadata: CGMutableImageMetadata,
        path: String,
        value: CFTypeRef
    ) throws {
        guard CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value) else {
            throw CLIError.invalidContainer("unable to set metadata \(path)")
        }
    }

    private static func makeFocusMetadata(
        width: Int,
        height: Int,
        focus: PortraitFocusRegion,
        captureDate: String?
    ) throws -> CGImageMetadata {
        let date = captureDate ?? "1970-01-01T00:00:00"
        let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XDRemux">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:mwg-rs="http://www.metadataworkinggroup.com/schemas/regions/" xmlns:stArea="http://ns.adobe.com/xmp/sType/Area#" xmlns:stDim="http://ns.adobe.com/xap/1.0/sType/Dimensions#">
              <mwg-rs:Regions rdf:parseType="Resource"><mwg-rs:AppliedToDimensions rdf:parseType="Resource"><stDim:h>\(height)</stDim:h><stDim:unit>pixel</stDim:unit><stDim:w>\(width)</stDim:w></mwg-rs:AppliedToDimensions><mwg-rs:RegionList><rdf:Bag><rdf:li rdf:parseType="Resource"><mwg-rs:Area rdf:parseType="Resource"><stArea:h>\(focus.rawHeight)</stArea:h><stArea:unit>normalized</stArea:unit><stArea:w>\(focus.rawWidth)</stArea:w><stArea:x>\(focus.rawX)</stArea:x><stArea:y>\(focus.rawY)</stArea:y></mwg-rs:Area><mwg-rs:Type>Focus</mwg-rs:Type></rdf:li></rdf:Bag></mwg-rs:RegionList></mwg-rs:Regions>
            </rdf:Description>
            <rdf:Description rdf:about="" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"><photoshop:DateCreated>\(date)</photoshop:DateCreated></rdf:Description>
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"><xmp:CreateDate>\(date)</xmp:CreateDate><xmp:CreatorTool>XDRemux</xmp:CreatorTool><xmp:ModifyDate>\(date)</xmp:ModifyDate></rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        guard let metadata = CGImageMetadataCreateFromXMPData(Data(xmp.utf8) as CFData) else {
            throw CLIError.invalidContainer("unable to create Focus XMP metadata")
        }
        return metadata
    }

    private static func portraitMakerAppleDictionary(
        afMeasuredDepth: Int?,
        photoIdentifier: String
    ) -> [String: Any] {
        let makerData = Data(base64Encoded: "ywG5Ap4DpQAaADIALQA1AHEAmgDXAA4ACQAJAA4AOwDMABgBkQFqAEMANQApAB4AEgCJAHIACwAJAAkAHQBBAGoByAEfAnYASQBZAJUAnwBcAJMAFgAJAAkADAAzAEUAUAGbAdIBngCgAKMAnADKAFcAsAARAAoACQAQAE8AVwCnAdgBGQIuAuQBRAHYANMAZgB0ABwACwALACUAcABvACwCKwJuAoMCjQJZAdAAKQIIApYB7wBEABcAVQCYAJEAgwKAAskC0QLBAnwCwAEdAZQABQKCAawAjgC4ANIAvwB6AskCHAMLA90CGQKaAuIBiwAWAQ4B7AAJATMBIQH6AFkCyAI6A+sC9AH4APMBzQFfAa8AbAGeAEwBmwFyATsBDwI9AXcCHQELAQ8BiQFcAnoB+ADTAVMBgwEdAswBbQFPATwB5gEPAQoBJwFCAc0CTAG7AO0BKgHtAOsCTQJ3AegBvwE7AyQC3ABEAQ8BiQJ5AccAlQH5AJoA2wH2AGQADQILA0MDHQNlAWMBHgEHAXwBSAGsAQ0BPgHrACEACwDTAf0CSgMBA9ACYAHGAFwArABjAbQBAgE9AggBFAALAGwCMQNiA9MCugI7AZsAbADqADkByAGPAbwBfQL/Ad4AMwOaA8QDzALhAgUBmgDEAJ8A7QA7Ai8CfQEuAvMBEQE=") ?? Data()
        let captureTime = CMTime(
            value: 411_546_020_942_750,
            timescale: 1_000_000_000,
            flags: .valid,
            epoch: 0
        )
        var dictionary: [String: Any] = [
            "1": 17, "2": makerData, "3": NSValue(time: captureTime), "4": 0,
            "5": 184, "6": 174, "7": 1,
            "8": [-0.0013844214845448732, -0.8983764052391052, -0.45038747787475586],
            "12": [1.91015625, 0.4296875], "13": 1, "14": 0, "16": 1,
            "20": 12, "23": 8_595_224_612, "25": 139_298, "26": "q750n",
            "29": 0.012993750162422657, "31": 1,
            "32": photoIdentifier, "33": 1.0099999904632568,
            "35": [44, 268_435_504], "37": 11_538_574, "38": 3,
            "39": 41.253238677978516, "43": photoIdentifier,
            "45": 3800, "46": 1, "47": 111, "48": 0.4457031190395355,
            "54": 784, "55": 8, "56": 38, "57": 2, "58": 128, "59": 0,
            "60": 4, "61": 66, "63": 0,
            "64": ["0": 1, "1": 0, "2": 0, "3": 0],
            "65": 0, "66": 0, "67": 0, "68": 0, "69": 0, "70": 0,
            "72": 0, "73": 0, "74": 2, "77": 32.507781982421875,
            "78": ["1": 3, "2": [["2.1": 2001.9581298828125, "2.2": 309], ["2.1": 0, "2.2": 70]]],
            "84": ["0": 1, "1": 0, "2": 0, "3": 1, "4": 1, "5": 1, "6": 4, "7": 0],
            "79": 0, "82": 0, "83": 2, "85": 0, "88": 2051,
            "96": 4037, "97": 24,
        ]
        if let afMeasuredDepth {
            // Apple MakerNote tag 56 is AFMeasuredDepth. Controlled matched
            // 2x/3x captures show it tracks OPPO rear.depth.config.distance in
            // the same scene-distance domain; keep the Apple trigger graph but
            // replace the fixed donor value with the source capture value.
            dictionary["56"] = afMeasuredDepth
        }
        return dictionary
    }

    private static func appleLensProfile(
        physicalFocalLengthMM: Double,
        equivalentFocalLengthMM: Double
    ) -> PortraitAppleLensProfile {
        if physicalFocalLengthMM <= 11 {
            // Apple keeps its 1x main-camera profile through the intermediate
            // crop range, then changes to the 2x/Fusion renderer near 48mm.
            if equivalentFocalLengthMM < 45 {
                return PortraitAppleLensProfile(
                    name: "Apple-1x-main-24mm",
                    anchorEquivalentFocalLengthMM: 24,
                    maximumValidatedEquivalentFocalLengthMM: 44,
                    referenceWidth: 4032,
                    referenceHeight: 3024,
                    focalLengthPixels: 2860.37890625,
                    principalPointX: 2010.31103515625,
                    principalPointY: 1525.0140380859375,
                    distortionCenterX: 2017.552734375,
                    distortionCenterY: 1523.492919921875,
                    pixelSizeMM: 0.002440,
                    distortionCoefficients: [
                        0, -0.5552194714546204, 0.053949449211359024,
                        -0.0018901334842666984, -0.000004621016614692053,
                        0.0000019594019704527454, -0.0000000451839099468998,
                        0.00000000031430857916348032,
                    ],
                    inverseDistortionCoefficients: [
                        0, 0.5448748469352722, -0.05080728605389595,
                        0.0016805990599095821, 0.000007370583261945285,
                        -0.0000017933325580088422, 0.00000003959269534448139,
                        -0.0000000002689144740219973,
                    ],
                    renderingParametersBase64: portraitStaticRenderingProfile1xBase64
                )
            }
            return PortraitAppleLensProfile(
                name: "Apple-2x-fusion-48mm",
                anchorEquivalentFocalLengthMM: 48,
                maximumValidatedEquivalentFocalLengthMM: 59,
                referenceWidth: 4032,
                referenceHeight: 3024,
                focalLengthPixels: 5666.13037109375,
                principalPointX: 2001.7744140625,
                principalPointY: 1543.74609375,
                distortionCenterX: 2008.567138671875,
                distortionCenterY: 1553.952880859375,
                pixelSizeMM: 0.0012199999764561653,
                distortionCoefficients: [
                    0, -0.5692305564880371, 0.05308981239795685,
                    -0.0018655891763046384, -0.000004458999683265574,
                    0.0000019504550436977297, -0.000000044818150968239934,
                    0.0000000003053474695313696,
                ],
                inverseDistortionCoefficients: [
                    0, 0.5576314330101013, -0.04986516013741493,
                    0.0016566345002502203, 0.0000071098988883022685,
                    -0.0000017824544329414493, 0.000000039320074307624964,
                    -0.00000000026318897061727853,
                ],
                renderingParametersBase64: portraitStaticRenderingProfile2xBase64
            )
        }
        if physicalFocalLengthMM < 28 {
            return PortraitAppleLensProfile(
                name: "Apple-3x-tele-77mm",
                anchorEquivalentFocalLengthMM: 77,
                maximumValidatedEquivalentFocalLengthMM: 134,
                referenceWidth: 4032,
                referenceHeight: 3024,
                focalLengthPixels: 9169.1298828125,
                principalPointX: 2023.2255859375,
                principalPointY: 1536.47265625,
                distortionCenterX: 2066.8583984375,
                distortionCenterY: 1557.3045654296875,
                pixelSizeMM: 0.0010000000474974513,
                distortionCoefficients: [
                    0, 1.3263592720031738, -0.7996886372566223,
                    0.18687580525875092, -0.016688073053956032,
                    -0.0014819741481915116, 0.0004676870012190193,
                    -0.000029682618333026767,
                ],
                inverseDistortionCoefficients: [
                    0, -1.3037974834442139, 0.7811512351036072,
                    -0.17724691331386566, 0.013979822397232056,
                    0.0017448276048526168, -0.0004529204161372036,
                    0.00002691301233426202,
                ],
                renderingParametersBase64: portraitStaticRenderingProfile3xBase64
            )
        }
        return PortraitAppleLensProfile(
            name: "Apple-5x-tetraprism-120mm",
            anchorEquivalentFocalLengthMM: 120,
            maximumValidatedEquivalentFocalLengthMM: 120,
            referenceWidth: 4032,
            referenceHeight: 3024,
            focalLengthPixels: 14235.533203125,
            principalPointX: 2012.30908203125,
            principalPointY: 1589.007568359375,
            distortionCenterX: 2027.13818359375,
            distortionCenterY: 1567.1475830078125,
            pixelSizeMM: 0.001120000029914081,
            distortionCoefficients: [
                0, -0.09882805496454239, 0.000012278825124667492,
                0, 0, 0, 0, 0,
            ],
            inverseDistortionCoefficients: [
                0, 0.10229571908712387, -0.0005449775489978492,
                0, 0, 0, 0, 0,
            ],
            renderingParametersBase64: portraitStaticRenderingProfile5xBase64
        )
    }

    private static func makeCameraCalibration(
        inputProperties: [CFString: Any]?,
        baseProperties: [CFString: Any]?,
        baseWidth: Int,
        baseHeight: Int,
        effectiveFocalLengthPixels: Double
    ) throws -> PortraitCameraCalibration {
        let inputExif = inputProperties?[kCGImagePropertyExifDictionary] as? NSDictionary
        let baseExif = baseProperties?[kCGImagePropertyExifDictionary] as? NSDictionary

        func number(_ key: CFString) -> Double? {
            for dictionary in [inputExif, baseExif] {
                if let value = dictionary?[key] as? NSNumber {
                    let result = value.doubleValue
                    if result.isFinite, result > 0 { return result }
                }
            }
            return nil
        }

        func string(_ key: CFString) -> String? {
            for dictionary in [inputExif, baseExif] {
                if let value = dictionary?[key] as? String, !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        guard let physicalFocalLength = number(kCGImagePropertyExifFocalLength) else {
            throw CLIError.invalidContainer(
                "--apple-portrait requires EXIF FocalLength to derive OPPO camera calibration"
            )
        }
        guard let equivalentFocalLength = number(kCGImagePropertyExifFocalLenIn35mmFilm) else {
            throw CLIError.invalidContainer(
                "--apple-portrait requires EXIF FocalLengthIn35mmFormat to derive OPPO camera calibration"
            )
        }

        let exifZoom = number(kCGImagePropertyExifDigitalZoomRatio) ?? 1.0
        let lensModel = string(kCGImagePropertyExifLensModel)
        let lensAnchor = lensModel.flatMap(opticalEquivalentFocalLengthFromLensModel)
        let fallbackAnchor = equivalentFocalLength / max(exifZoom, 1.0)
        let opticalEquivalentFocalLength = lensAnchor ?? fallbackAnchor
        guard opticalEquivalentFocalLength.isFinite, opticalEquivalentFocalLength > 0 else {
            throw CLIError.invalidContainer("unable to derive OPPO optical focal-length anchor")
        }

        let equivalentZoom = equivalentFocalLength / opticalEquivalentFocalLength
        let digitalZoom: Double
        if exifZoom.isFinite,
           exifZoom >= 1.0,
           abs(exifZoom - equivalentZoom) <= max(0.08, equivalentZoom * 0.05) {
            digitalZoom = exifZoom
        } else {
            digitalZoom = max(1.0, equivalentZoom)
        }

        guard effectiveFocalLengthPixels.isFinite, effectiveFocalLengthPixels > 0 else {
            throw CLIError.invalidContainer("OPPO depth-header focal length is invalid")
        }

        // REND and auxiliary calibration are a lens-coupled Apple profile.
        // Within one physical profile Apple keeps intrinsic fx approximately
        // constant while the reference crop and PixelSize scale inversely with
        // equivalent focal length. Reproduce that observed representation for
        // OPPO digital focal lengths instead of multiplying disparity itself.
        let profile = appleLensProfile(
            physicalFocalLengthMM: physicalFocalLength,
            equivalentFocalLengthMM: equivalentFocalLength
        )
        // Apple has no 10x/230mm portrait renderer profile. Keep the source
        // focal length in primary EXIF, but never extrapolate a private Apple
        // calibration/REND chart beyond the range measured for that profile.
        // Longer OPPO captures remain in the nearest validated Apple render
        // domain; disparity and scene controls carry depth, not a fabricated
        // auxiliary focal-length multiplier.
        let renderEquivalentFocalLength = min(
            equivalentFocalLength,
            profile.maximumValidatedEquivalentFocalLengthMM
        )
        let cropScale = profile.anchorEquivalentFocalLengthMM / renderEquivalentFocalLength
        func roundedMultipleOf4(_ value: Double) -> Int {
            max(4, Int((value / 4).rounded()) * 4)
        }
        let referenceWidth = roundedMultipleOf4(Double(profile.referenceWidth) * cropScale)
        let referenceHeight = roundedMultipleOf4(Double(profile.referenceHeight) * cropScale)
        let cropOffsetX = (Double(profile.referenceWidth) - Double(referenceWidth)) / 2
        let cropOffsetY = (Double(profile.referenceHeight) - Double(referenceHeight)) / 2
        let focalLengthPixels = profile.focalLengthPixels
        let renderEffectiveFocalLengthPixels = focalLengthPixels
            * Double(baseWidth) / Double(referenceWidth)
        let principalPointX = profile.principalPointX - cropOffsetX
        let principalPointY = profile.principalPointY - cropOffsetY
        let pixelSizeMM = profile.pixelSizeMM * cropScale

        let calibration = PortraitCameraCalibration(
            profileName: profile.name,
            renderingParametersBase64: try validatedRenderingParametersBase64(
                profile.renderingParametersBase64
            ),
            profileAnchorEquivalentFocalLengthMM: profile.anchorEquivalentFocalLengthMM,
            profileMaximumValidatedEquivalentFocalLengthMM: profile.maximumValidatedEquivalentFocalLengthMM,
            physicalFocalLengthMM: physicalFocalLength,
            opticalEquivalentFocalLengthMM: opticalEquivalentFocalLength,
            digitalZoomRatio: digitalZoom,
            referenceWidth: referenceWidth,
            referenceHeight: referenceHeight,
            focalLengthPixels: focalLengthPixels,
            effectiveFocalLengthPixels: renderEffectiveFocalLengthPixels,
            principalPointX: principalPointX,
            principalPointY: principalPointY,
            distortionCenterX: profile.distortionCenterX - cropOffsetX,
            distortionCenterY: profile.distortionCenterY - cropOffsetY,
            pixelSizeMM: pixelSizeMM,
            distortionCoefficients: profile.distortionCoefficients,
            inverseDistortionCoefficients: profile.inverseDistortionCoefficients
        )
        print(String(
            format: "portrait render profile=%@ sourcePhysical=%.3fmm sourceOptical=%.2fmm sourceEquivalent=%.2fmm renderEquivalent=%.2fmm sourceZoom=%.4fx sourceDepthFx=%.3f cropScale=%.5f ref=%dx%d fx=%.3f pixel=%.9fmm",
            calibration.profileName,
            calibration.physicalFocalLengthMM,
            calibration.opticalEquivalentFocalLengthMM,
            equivalentFocalLength,
            renderEquivalentFocalLength,
            calibration.digitalZoomRatio,
            effectiveFocalLengthPixels,
            cropScale,
            calibration.referenceWidth,
            calibration.referenceHeight,
            calibration.focalLengthPixels,
            calibration.pixelSizeMM
        ))
        return calibration
    }

    private static func parsePortraitConfig(_ data: Data) throws -> OPPOPortraitConfig {
        guard let versionRaw = readFloat32LE(data, at: 0),
              versionRaw.isFinite,
              versionRaw >= 1,
              versionRaw <= 4 else {
            throw CLIError.invalidContainer("rear.depth.config version is invalid")
        }
        let version = Double(versionRaw)
        func requiredInt(_ offset: Int, _ name: String) throws -> Int {
            guard let value = readInt32LE(data, at: offset) else {
                throw CLIError.invalidContainer("rear.depth.config is truncated at \(name)")
            }
            return Int(value)
        }
        func requiredFloat(_ offset: Int, _ name: String) throws -> Double {
            guard let value = readFloat32LE(data, at: offset), value.isFinite else {
                throw CLIError.invalidContainer("rear.depth.config has invalid \(name)")
            }
            return Double(value)
        }
        let declaredWidth = try requiredInt(4, "depth width")
        let declaredHeight = try requiredInt(8, "depth height")
        guard (1...16_384).contains(declaredWidth), (1...16_384).contains(declaredHeight) else {
            throw CLIError.invalidContainer("rear.depth.config dimensions are invalid")
        }
        let apertures = try (0..<32).map { try requiredFloat(20 + $0 * 4, "blur aperture") }
        let blurValues = try (0..<32).map { try requiredFloat(148 + $0 * 4, "blur value") }

        var spotlightWidth: Int?
        var spotlightHeight: Int?
        var currentFNumber: Double?
        var objectDistance: Int?
        var teleMaster: Bool?
        var focusRectangle: [Int]?
        var focusRectangleIsValid = false
        var mirrorEnabled: Bool?
        var refocusMode: Int?
        var foregroundBlurScale: Int?
        var bigFaceEnabled: Bool?
        var petsEnabled: Bool?
        var multiSemanticEnabled: Bool?
        var bokehVersion: Int?
        var iso: Int?
        var zoomRatio: Int?
        var focusROIType: Int?
        var shutter: Double?
        var aecLuxIndex: Double?
        var faces: [OPPOPortraitFace] = []

        if version >= 2.0 {
            spotlightWidth = try requiredInt(284, "spotlight width")
            spotlightHeight = try requiredInt(288, "spotlight height")
            let aperture = try requiredFloat(292, "current f-number")
            currentFNumber = (1...64).contains(aperture) ? aperture : nil
            let distance = try requiredInt(296, "object distance")
            objectDistance = distance > 0 ? distance : nil
            guard data.count > 300 else {
                throw CLIError.invalidContainer("rear.depth.config is truncated at tele-master flag")
            }
            teleMaster = data[300] != 0
            _ = try requiredInt(304, "reference EV")
            _ = try requiredInt(308, "minimum EV")
            _ = try requiredInt(312, "scene mode")
        }
        if version >= 2.2 {
            focusRectangle = try (0..<4).map { try requiredInt(316 + $0 * 4, "focus rectangle") }
            guard data.count > 332 else {
                throw CLIError.invalidContainer("rear.depth.config is truncated at focus rectangle validity")
            }
            focusRectangleIsValid = data[332] != 0
        }
        if version >= 2.3 {
            mirrorEnabled = try requiredInt(336, "mirror flag") != 0
        }
        if version >= 2.4 {
            refocusMode = try requiredInt(340, "refocus mode")
            _ = try requiredInt(344, "light spot strength")
            _ = try requiredInt(348, "bright spot trigger")
            _ = try requiredFloat(352, "curve value")
            _ = try requiredInt(356, "shine threshold")
            _ = try requiredInt(360, "shine level")
            _ = try requiredInt(364, "spot sharpen amount")
            _ = try requiredInt(368, "spot sharpen radius")
            foregroundBlurScale = try requiredInt(372, "foreground blur scale")
            _ = try requiredInt(376, "master type")
        }
        if version >= 2.5 {
            bigFaceEnabled = try requiredInt(380, "big-face flag") != 0
            petsEnabled = try requiredInt(384, "pet flag") != 0
            multiSemanticEnabled = try requiredInt(388, "multi-semantic flag") != 0
        }
        if version >= 4.0 {
            bokehVersion = try requiredInt(392, "bokeh version")
            iso = try requiredInt(396, "ISO")
            zoomRatio = try requiredInt(400, "zoom ratio")
            focusROIType = try requiredInt(404, "focus ROI type")
            shutter = try requiredFloat(408, "shutter")
            aecLuxIndex = try requiredFloat(412, "AEC lux index")
            let faceCount = try requiredInt(416, "face count")
            guard (0...10).contains(faceCount), data.count >= 27_260 else {
                throw CLIError.invalidContainer("rear.depth.config v4 face table is invalid or truncated")
            }
            for faceIndex in 0..<faceCount {
                let rectangle = try (0..<4).map {
                    try requiredInt(420 + (faceIndex * 4 + $0) * 4, "face rectangle")
                }
                let angle = try requiredInt(580 + faceIndex * 4, "face angle")
                let keyPointX = try (0..<296).map {
                    try requiredInt(620 + (faceIndex * 296 + $0) * 4, "face keypoint X")
                }
                let keyPointY = try (0..<296).map {
                    try requiredInt(12_460 + (faceIndex * 296 + $0) * 4, "face keypoint Y")
                }
                let confidenceBase = 24_300 + faceIndex * 296
                let confidence = (0..<296).map { Int(Int8(bitPattern: data[confidenceBase + $0])) }
                faces.append(OPPOPortraitFace(
                    rectangle: rectangle,
                    angle: angle,
                    keyPointX: keyPointX,
                    keyPointY: keyPointY,
                    keyPointConfidence: confidence
                ))
            }
        }
        return OPPOPortraitConfig(
            version: version,
            declaredProcessingCanvasWidth: declaredWidth,
            declaredProcessingCanvasHeight: declaredHeight,
            focusX: try requiredInt(12, "focus X"),
            focusY: try requiredInt(16, "focus Y"),
            blurApertures: apertures,
            blurValues: blurValues,
            currentBlurStrength: try requiredInt(276, "current blur strength"),
            cameraRoll: try requiredInt(280, "camera roll"),
            spotlightWidth: spotlightWidth,
            spotlightHeight: spotlightHeight,
            currentFNumber: currentFNumber,
            objectDistance: objectDistance,
            teleMaster: teleMaster,
            focusRectangle: focusRectangle,
            focusRectangleIsValid: focusRectangleIsValid,
            mirrorEnabled: mirrorEnabled,
            refocusMode: refocusMode,
            foregroundBlurScale: foregroundBlurScale,
            bigFaceEnabled: bigFaceEnabled,
            petsEnabled: petsEnabled,
            multiSemanticSegmentationEnabled: multiSemanticEnabled,
            bokehVersion: bokehVersion,
            iso: iso,
            zoomRatio: zoomRatio,
            focusROIType: focusROIType,
            shutter: shutter,
            aecLuxIndex: aecLuxIndex,
            faces: faces,
            evidence: .oppoProducerExact
        )
    }

    private static func parseDepthHeader(_ decodedDepth: Data) throws -> PortraitDepthHeader {
        let headerSize = 768
        guard decodedDepth.count >= headerSize else {
            throw CLIError.invalidContainer("decoded rear.depth is shorter than its 768-byte header")
        }
        guard let widthRaw = readUInt32LE(decodedDepth, at: 0),
              let heightRaw = readUInt32LE(decodedDepth, at: 4),
              widthRaw > 0,
              heightRaw > 0,
              widthRaw <= 16_384,
              heightRaw <= 16_384 else {
            throw CLIError.invalidContainer("decoded rear.depth header dimensions are invalid")
        }
        guard let rankDisparityScale = readFloat32LE(decodedDepth, at: 0x18),
              let focalLength = readFloat32LE(decodedDepth, at: 0x1c),
              let stereoBaseline = readFloat32LE(decodedDepth, at: 0x20),
              rankDisparityScale.isFinite,
              rankDisparityScale > 0,
              focalLength.isFinite,
              focalLength > 0,
              stereoBaseline.isFinite,
              stereoBaseline > 0 else {
            throw CLIError.invalidContainer("decoded rear.depth calibration header is invalid")
        }
        let width = Int(widthRaw)
        let height = Int(heightRaw)
        guard decodedDepth.count >= headerSize + width * height else {
            throw CLIError.invalidContainer("decoded rear.depth rank plane is truncated")
        }
        guard let disparityMinimum = readUInt16LE(decodedDepth, at: 0x2e),
              let disparityMaximum = readUInt16LE(decodedDepth, at: 0x30) else {
            throw CLIError.invalidContainer("decoded rear.depth quantization header is truncated")
        }
        let exponentiation = Int(decodedDepth[0x32])
        guard (1...2).contains(exponentiation), disparityMaximum > disparityMinimum else {
            throw CLIError.invalidContainer("decoded rear.depth quantization range is invalid")
        }
        let nearConfidence = readFloat32LE(decodedDepth, at: 0x28).flatMap { value in
            value.isFinite ? Double(value) : nil
        }
        let auxWidth = readUInt32LE(decodedDepth, at: 0x188).flatMap { $0 > 0 ? Int($0) : nil }
        let auxHeight = readUInt32LE(decodedDepth, at: 0x18c).flatMap { $0 > 0 ? Int($0) : nil }
        let objectDistance = readInt32LE(decodedDepth, at: 0x1b4).flatMap { $0 > 0 ? Int($0) : nil }
        let aecLux = readFloat32LE(decodedDepth, at: 0x1b8).flatMap { value in
            value.isFinite ? Double(value) : nil
        }
        let appZoom = readFloat32LE(decodedDepth, at: 0x1bc).flatMap { value in
            value.isFinite && value > 0 ? Double(value) : nil
        }
        return PortraitDepthHeader(
            width: width,
            height: height,
            rankDisparityScale: Double(rankDisparityScale),
            focalLengthPixels: Double(focalLength),
            stereoBaseline: Double(stereoBaseline),
            hairPlanePresent: decodedDepth[0x24] != 0,
            portraitPlanePresent: decodedDepth[0x25] != 0,
            petPlanePresent: decodedDepth[0x26] != 0,
            nearObjectDetected: decodedDepth[0x27] != 0,
            nearObjectConfidence: nearConfidence,
            plantObjectState: Int(decodedDepth[0x2c]),
            disparityMinimum: disparityMinimum,
            disparityMaximum: disparityMaximum,
            disparityExponentiation: exponentiation,
            auxiliaryWidth: auxWidth,
            auxiliaryHeight: auxHeight,
            modelOutputPresent: decodedDepth[0x190] != 0,
            sceneClass: readInt32LE(decodedDepth, at: 0x1b0).map(Int.init),
            objectDistance: objectDistance,
            aecLuxIndex: aecLux,
            appZoomRatio: appZoom,
            evidence: .oppoProducerExact
        )
    }

    private static func parseDepthPlanes(
        _ decodedDepth: Data,
        header: PortraitDepthHeader
    ) throws -> OPPODepthPlanes {
        let headerSize = 0x300
        let planeSize = header.width * header.height
        guard decodedDepth.count >= headerSize + planeSize else {
            throw CLIError.invalidContainer("decoded rear.depth rank plane is truncated")
        }
        let ranks = decodedDepth.subdata(in: headerSize..<(headerSize + planeSize))
        var cursor = headerSize + planeSize
        func consumePlane(flagOffset: Int, name: String) throws -> Data? {
            guard decodedDepth[flagOffset] != 0 else { return nil }
            guard cursor + planeSize <= decodedDepth.count else {
                throw CLIError.invalidContainer(
                    "decoded rear.depth is too short for flagged \(name) plane"
                )
            }
            defer { cursor += planeSize }
            return decodedDepth.subdata(in: cursor..<(cursor + planeSize))
        }
        // Same-size firmware order after rank: hair, portrait, pet. Later
        // independent-size YUV/NV21 auxiliaries are not Apple matte sources.
        return OPPODepthPlanes(
            width: header.width,
            height: header.height,
            ranks: ranks,
            hair: try consumePlane(flagOffset: 0x24, name: "hair"),
            portrait: try consumePlane(flagOffset: 0x25, name: "portrait"),
            pet: try consumePlane(flagOffset: 0x26, name: "pet")
        )
    }

    static func resolveGainInfoFloats(
        privateInfo: Data?,
        inputURL: URL
    ) throws -> [Double] {
        if let privateInfo {
            guard privateInfo.count == 80 else {
                throw CLIError.invalidLHDR("portrait gain info must be exactly 80 bytes")
            }
            return try unpackFloatArrayLE(privateInfo, count: 20)
        }

        guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
              let dictionary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                  source,
                  0,
              kCGImageAuxiliaryDataTypeISOGainMap
              ) as? [CFString: Any],
              let rawMetadata = dictionary[kCGImageAuxiliaryDataInfoMetadata],
              CFGetTypeID(rawMetadata as CFTypeRef) == CGImageMetadataGetTypeID() else {
            throw CLIError.invalidLHDR(
                "portrait requires private gain info or an existing ISO gain-map metadata graph"
            )
        }
        let metadata = unsafeBitCast(rawMetadata as AnyObject, to: CGImageMetadata.self)

        func optionalValue(_ path: String) throws -> Double? {
            guard let tag = CGImageMetadataCopyTagWithPath(
                metadata,
                nil,
                path as CFString
            ) else { return nil }
            guard let raw = CGImageMetadataTagCopyValue(tag) else {
                throw CLIError.invalidLHDR("ISO gain-map metadata has an invalid \(path)")
            }
            if let number = raw as? NSNumber {
                return number.doubleValue
            }
            if let text = raw as? String, let parsed = Double(text) {
                return parsed
            }
            throw CLIError.invalidLHDR("ISO gain-map metadata has an invalid \(path)")
        }

        func value(_ path: String) throws -> Double {
            guard let result = try optionalValue(path) else {
                throw CLIError.invalidLHDR("ISO gain-map metadata is missing \(path)")
            }
            return result
        }

        let secondChannel = try optionalValue("HDRToneMap:ChannelMetadata[1].GainMapMin")
        let thirdChannel = try optionalValue("HDRToneMap:ChannelMetadata[2].GainMapMin")
        guard (secondChannel == nil) == (thirdChannel == nil) else {
            throw CLIError.invalidLHDR("ISO gain-map metadata has an incomplete channel set")
        }
        // ISO/TS 21496-1 may describe an RGB 4:4:4 Gain Map with one shared
        // parameter record when all three raster channels use the same curve.
        let usesSharedChannelMetadata = secondChannel == nil

        func channelValues(_ field: String) throws -> [Double] {
            let first = try value("HDRToneMap:ChannelMetadata[0].\(field)")
            if usesSharedChannelMetadata {
                return [first, first, first]
            }
            return try (0..<3).map {
                try value("HDRToneMap:ChannelMetadata[\($0)].\(field)")
            }
        }

        var values: [Double] = []
        let gainMapMin = try channelValues("GainMapMin")
        let gainMapMax = try channelValues("GainMapMax")
        values.append(contentsOf: gainMapMin.map { pow(2.0, $0) })
        values.append(1.0)
        values.append(contentsOf: gainMapMax.map { pow(2.0, $0) })
        for field in ["Gamma", "BaseOffset", "AlternateOffset"] {
            values.append(contentsOf: try channelValues(field))
        }
        let baseRatio = pow(2.0, try value("HDRToneMap:BaseHeadroom"))
        let alternateRatio = pow(2.0, try value("HDRToneMap:AlternateHeadroom"))
        values.append(baseRatio)
        values.append(alternateRatio)
        values.append(alternateRatio)
        values.append(0.0)
        guard values.count == 20, values.allSatisfy(\.isFinite) else {
            throw CLIError.invalidLHDR("unable to reconstruct portrait gain metadata")
        }
        print("portrait gain info source=existing ISO HDRToneMap metadata")
        return values
    }

    private static func resolveSimulatedAperture(
        rearDepthConfig: Data?,
        inputProperties: [CFString: Any]?,
        baseProperties: [CFString: Any]?
    ) -> (value: Double, source: String) {
        // OPPO RearDepthStruct v4 stores the portrait editor's f-number at
        // byte offset 292. This is the simulated bokeh setting, not the lens's
        // physical capture aperture, so it maps directly to Apple's
        // depthBlurEffect:SimulatedAperture.
        if let config = rearDepthConfig,
           let version = readFloat32LE(config, at: 0),
           abs(version - 4.0) < 0.001,
           let fNumber = readFloat32LE(config, at: 292),
           fNumber.isFinite,
           (1.0...32.0).contains(fNumber) {
            let value = Double(fNumber)
            print(String(format: "portrait aperture f/%.1f source=rear.depth.config-v%.1f", value, version))
            return (value, "rear.depth.config")
        }

        for properties in [inputProperties, baseProperties] {
            guard
                let exif = properties?[kCGImagePropertyExifDictionary] as? NSDictionary,
                let number = exif[kCGImagePropertyExifFNumber] as? NSNumber
            else { continue }
            let value = number.doubleValue
            if value.isFinite, (1.0...32.0).contains(value) {
                print(String(format: "portrait aperture f/%.1f source=EXIF", value))
                return (value, "EXIF FNumber")
            }
        }

        print("portrait aperture f/1.4 source=compatibility-fallback")
        return (1.4, "compatibility fallback")
    }

    private static func readFloat32LE(_ data: Data, at offset: Int) -> Float? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let bits = UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
        return Float(bitPattern: bits)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func readInt32LE(_ data: Data, at offset: Int) -> Int32? {
        readUInt32LE(data, at: offset).map { Int32(bitPattern: $0) }
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func makeBlurResponse(
        config: OPPOPortraitConfig,
        header: PortraitDepthHeader
    ) throws -> OPPOPortraitBlurResponse {
        let pairs = zip(config.blurApertures, config.blurValues).filter { pair in
            pair.0.isFinite && pair.1.isFinite && pair.0 > 0 && pair.1 >= 0
        }
        guard !pairs.isEmpty else {
            throw CLIError.invalidContainer("rear.depth.config has no valid aperture/blur curve")
        }
        let selectedAperture = config.currentFNumber ?? pairs[0].0
        let zoom = header.appZoomRatio ?? Double(config.zoomRatio ?? 100) / 100.0
        let zoomRegion: String
        switch zoom {
        case ..<2: zoomRegion = "1x_to_below_2x"
        case ..<3: zoomRegion = "2x_to_below_3x"
        case ..<6: zoomRegion = "3x_to_below_6x"
        default: zoomRegion = "6x_to_10x"
        }
        return OPPOPortraitBlurResponse(
            apertures: pairs.map(\.0),
            blurValues: pairs.map(\.1),
            selectedAperture: selectedAperture,
            selectedBlurValue: Double(config.currentBlurStrength),
            foregroundBlurScale: Double(config.foregroundBlurScale ?? 100),
            zoomRegion: zoomRegion,
            evidence: .oppoProducerExact
        )
    }

    private static func makeSourceDerivedREND(
        templateBase64: String,
        profileName: String,
        focus: OPPOPortraitFocusSelection,
        focusDisparity: Double,
        disparitySpan: Double,
        config: OPPOPortraitConfig,
        header: PortraitDepthHeader,
        blurResponse: OPPOPortraitBlurResponse,
        gainInfoFloats: [Double]
    ) throws -> SourceDerivedRENDResult {
        guard let templateData = Data(base64Encoded: templateBase64) else {
            throw CLIError.invalidContainer("Apple portrait profile has invalid Base64 REND")
        }
        let document = try AppleRENDDocument.parse(templateData)
        guard document.serialized() == templateData else {
            throw CLIError.invalidContainer("Apple portrait REND parser is not byte-stable")
        }

        // iOS 26.5 generates these fields in SDOFRenderingV5 by passing the
        // current sample buffer, focus window, shift/disparity buffers and
        // physical SimpleLensModel through ControlLogicForXHLRB. The ObjC
        // wrapper is not present on macOS, but the producer's final CPU scaler,
        // REND mapping and Metal bindings are recovered exactly. Only the
        // activation that precedes the scaler remains a calibrated estimate.
        let nativeClasses = [
            "FigSDOFRenderingTuningParameters",
            "FigSDOFRendering",
            "FigSDOFEffectRendering",
            "ControlLogicForXHLRB",
            "SimpleLensModel",
        ]
        let availableNativeClasses = nativeClasses.filter { NSClassFromString($0) != nil }
        let nativeGenerator = availableNativeClasses.isEmpty
            ? "not invoked: iOS ObjC wrapper is absent; recovered XHLRB CPU scaler is implemented in-tree"
            : "unusable ABI: found \(availableNativeClasses.joined(separator: ",")) without a public sample-buffer builder contract"

        let focusNormalized = disparitySpan > 0
            ? min(max(focusDisparity / disparitySpan, 0), 1)
            : 0
        // The private 20-float layout stores alternate HDR headroom as a
        // linear ratio at index 17. Apple producer input
        // kFigCaptureSampleBufferMetadata_GainMapHeadroom is in stops and is
        // copied verbatim into REND 0x01c5.
        let gainMapHeadroom = gainInfoFloats.count > 17
            ? max(log2(max(gainInfoFloats[17], 1.0)), 0.0)
            : 0.0
        let headroomNormalized = min(gainMapHeadroom / 4.0, 1.0)
        let luxNormalized = config.aecLuxIndex.map { min(max(log1p(max($0, 0)) / log(4097), 0), 1) } ?? 0.5
        let nearBoost = header.nearObjectDetected ? 1.15 : 1.0
        let fittedPrimaryGain = min(max(
            (0.02 + 0.17 * focusNormalized + 0.04 * headroomNormalized + 0.02 * luxNormalized) * nearBoost,
            0.005
        ), 0.25)
        let sceneActivation = fittedPrimaryGain / 0.25
        let profileIsOneX = profileName.localizedCaseInsensitiveContains("1x")
        let foreground = min(max(blurResponse.foregroundBlurScale / 100.0, 0), 4)
        let background = min(max(blurResponse.selectedBlurValue / 150.0, 0), 2)
        let xhlrbOutput = AppleXHLRBControlOutput.make(
            profileIsOneX: profileIsOneX,
            sceneActivation: sceneActivation,
            gainMapHeadroom: gainMapHeadroom
        )
        let dynamicValues = xhlrbOutput.dynamicValues
        var replacements: [UInt16: AppleRENDRecord] = [:]
        for (identifier, value) in dynamicValues {
            let existingType = document.records.first(where: { $0.identifier == identifier })?.valueType
                ?? (identifier == 0x0190 ? 2 : 1)
            let raw: UInt32
            switch existingType {
            case 1:
                raw = Float(value).bitPattern
            case 2:
                raw = UInt32(bitPattern: Int32(value.rounded()))
            case 3, 4:
                raw = UInt32(max(0, value.rounded()))
            default:
                throw CLIError.invalidContainer("unsupported dynamic REND record type")
            }
            replacements[identifier] = AppleRENDRecord(
                identifier: identifier,
                valueType: existingType,
                rawValue: raw
            )
        }
        let rebuilt = document.replacing(replacements)
        let raw = rebuilt.serialized(sorted: true)
        let roundTrip = try AppleRENDDocument.parse(raw).serialized(sorted: true)
        guard roundTrip == raw else {
            throw CLIError.invalidContainer("source-derived REND failed byte-stable round trip")
        }
        let dynamicRecordStrings = Dictionary(uniqueKeysWithValues: dynamicValues.map {
            (String(format: "0x%04x", $0.key), $0.value)
        })
        let staticIdentifiers = document.records
            .map(\.identifier)
            .filter { dynamicValues[$0] == nil }
            .map { String(format: "0x%04x", $0) }
        let nearState = OPPONearObjectState(
            detected: header.nearObjectDetected,
            confidence: header.nearObjectConfidence,
            region: header.nearObjectDetected ? focus.depthROI : nil,
            nativeFocusContribution: header.nearObjectDetected ? focus.selectedRank : nil,
            evidence: .oppoProducerExact
        )
        let sceneState = ApplePortraitRenderSceneState(
            focusBranch: focus.branch,
            focusDisparity: focusDisparity,
            measuredDepth: config.objectDistance.map(Double.init),
            nearObjectState: nearState,
            foregroundState: foreground,
            backgroundState: background,
            xhlrbProducerState: AppleXHLRBProducerState(
                isoSpeedRating: config.iso.map(Double.init),
                exposureTimeRaw: config.shutter,
                exposureProductRaw: config.iso.flatMap { iso in
                    config.shutter.map { Double(iso) * $0 }
                },
                gainMapHeadroom: gainMapHeadroom,
                sceneActivation: sceneActivation,
                firmwareDefaultControlConfig: .firmwareDefault,
                firmwareDefaultSimpleLensModelConfig: .firmwareDefault,
                metadataKeysEvidence: .appleProducerExact,
                controlFormulaEvidence: .appleProducerExact,
                firmwareDefaultConfigEvidence: .appleProducerExact,
                activeRenderingOverrideEvidence: .controlledCorpusFit,
                tuningMaximaEvidence: .controlledCorpusFit,
                sceneActivationEvidence: .controlledCorpusFit
            ),
            dynamicRecords: dynamicRecordStrings,
            evidence: .controlledCorpusFit
        )
        return SourceDerivedRENDResult(
            base64: raw.base64EncodedString(),
            rawData: raw,
            staticRecordIdentifiers: staticIdentifiers,
            dynamicRecords: dynamicRecordStrings,
            sceneState: sceneState,
            nativeGenerator: nativeGenerator,
            warnings: [
                "0x0190...0x0199 and 0x01c2...0x01c5 are regenerated for this source; no donor scene values survive",
                "ControlLogicForXHLRB CPU scaling, GainMapHeadroom mapping, and firmware default configs are apple_producer_exact; active RenderingV overrides and exposure/clipped-pixel scene activation are controlled_corpus_fit",
                "0x0194...0x0199 are emitted as neutral zero because their private producer semantics remain unresolved",
            ]
        )
    }

    private static func opticalEquivalentFocalLengthFromLensModel(_ lensModel: String) -> Double? {
        let pattern = #"camera\s+([0-9]+(?:\.[0-9]+)?)mm\b"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(lensModel.startIndex..<lensModel.endIndex, in: lensModel)
        guard let match = expression.firstMatch(in: lensModel, options: [], range: range),
              match.numberOfRanges > 1,
              let focalRange = Range(match.range(at: 1), in: lensModel),
              let focalLength = Double(lensModel[focalRange]),
              focalLength.isFinite,
              focalLength > 0 else {
            return nil
        }
        return focalLength
    }

    private static func resolvedBaseOrientation(
        inputWidth: Int?,
        inputHeight: Int?,
        inputOrientation: UInt32?,
        baseWidth: Int,
        baseHeight: Int,
        baseOrientation: UInt32?
    ) -> UInt32 {
        func swapsAxes(_ orientation: UInt32) -> Bool {
            (5...8).contains(orientation)
        }

        func displayedIsPortrait(width: Int, height: Int, orientation: UInt32) -> Bool {
            let displayedWidth = swapsAxes(orientation) ? height : width
            let displayedHeight = swapsAxes(orientation) ? width : height
            return displayedHeight > displayedWidth
        }

        let normalizedInputOrientation = inputOrientation.flatMap {
            (1...8).contains($0) ? $0 : nil
        } ?? 1
        let targetIsPortrait: Bool
        if let inputWidth, let inputHeight, inputWidth != inputHeight {
            targetIsPortrait = displayedIsPortrait(
                width: inputWidth,
                height: inputHeight,
                orientation: normalizedInputOrientation
            )
        } else {
            targetIsPortrait = displayedIsPortrait(
                width: baseWidth,
                height: baseHeight,
                orientation: baseOrientation ?? normalizedInputOrientation
            )
        }

        if let baseOrientation,
           (1...8).contains(baseOrientation),
           displayedIsPortrait(
               width: baseWidth,
               height: baseHeight,
               orientation: baseOrientation
           ) == targetIsPortrait {
            return baseOrientation
        }

        let baseStoredIsPortrait = baseHeight > baseWidth
        if baseStoredIsPortrait == targetIsPortrait {
            return 1
        }
        // OPPO portrait src.image JPEGs observed so far use clockwise rotation.
        // The source JPEG orientation wins whenever available; this is only the
        // metadata-missing fallback for a stored/display aspect mismatch.
        return 6
    }

    private static func makeDepthDictionary(
        ranks: Data,
        width: Int,
        height: Int,
        orientation: UInt32,
        far: Float,
        near: Float,
        disparityExponentiation: Int,
        calibration: PortraitCameraCalibration,
        renderingParametersBase64: String,
        simulatedAperture: Double
    ) throws -> CFDictionary {
        let output = NSMutableDictionary()
        let description = NSMutableDictionary()
        var disparity = Data(capacity: width * height * 2)
        let span = near - far
        for rank in ranks {
            let normalizedRank = pow(Float(rank) / 255.0, Float(disparityExponentiation))
            let value = near - normalizedRank * span
            var bits = XDRemuxHalf.encode(value).littleEndian
            withUnsafeBytes(of: &bits) { disparity.append(contentsOf: $0) }
        }
        description[kCGImagePropertyWidth as String] = width
        description[kCGImagePropertyHeight as String] = height
        description[kCGImagePropertyBytesPerRow as String] = width * 2
        description[kCGImagePropertyPixelFormat as String] = NSNumber(value: kCVPixelFormatType_DisparityFloat16)
        description[kCGImagePropertyOrientation as String] = NSNumber(value: orientation)
        output[kCGImageAuxiliaryDataInfoData as String] = disparity
        output[kCGImageAuxiliaryDataInfoDataDescription as String] = description
        let metadata = CGImageMetadataCreateMutable()
        try registerMetadataNamespace(
            metadata,
            namespace: "http://ns.apple.com/depthData/1.0/",
            prefix: "depthData"
        )
        try registerMetadataNamespace(
            metadata,
            namespace: "http://ns.apple.com/depthBlurEffect/1.0/",
            prefix: "depthBlurEffect"
        )
        try registerMetadataNamespace(
            metadata,
            namespace: "http://ns.apple.com/portraitLightingEffect/1.0/",
            prefix: "portraitLightingEffect"
        )
        try setMetadata(metadata, path: "depthData:Quality", value: "high")
        try setMetadata(metadata, path: "depthData:Accuracy", value: "relative")
        try setMetadata(metadata, path: "depthData:Filtered", value: "True")
        try setMetadata(metadata, path: "depthData:DepthDataVersion", value: "65541")
        try setMetadata(
            metadata,
            path: "depthData:IntrinsicMatrixReferenceWidth",
            value: String(calibration.referenceWidth)
        )
        try setMetadata(
            metadata,
            path: "depthData:IntrinsicMatrixReferenceHeight",
            value: String(calibration.referenceHeight)
        )
        try setMetadata(
            metadata,
            path: "depthData:LensDistortionCenterOffsetX",
            value: String(format: "%.12f", calibration.distortionCenterX)
        )
        try setMetadata(
            metadata,
            path: "depthData:LensDistortionCenterOffsetY",
            value: String(format: "%.12f", calibration.distortionCenterY)
        )
        try setMetadata(
            metadata,
            path: "depthData:PixelSize",
            value: String(format: "%.12f", calibration.pixelSizeMM)
        )
        try setMetadataValue(
            metadata,
            path: "depthData:IntrinsicMatrix",
            value: calibration.intrinsicMatrix as CFArray
        )
        try setMetadataValue(
            metadata,
            path: "depthData:ExtrinsicMatrix",
            value: [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0] as CFArray
        )
        try setMetadataValue(
            metadata,
            path: "depthData:LensDistortionCoefficients",
            value: calibration.distortionCoefficients as CFArray
        )
        try setMetadataValue(
            metadata,
            path: "depthData:InverseLensDistortionCoefficients",
            value: calibration.inverseDistortionCoefficients as CFArray
        )
        try setMetadata(
            metadata,
            path: "depthBlurEffect:RenderingParameters",
            value: renderingParametersBase64
        )
        try setMetadata(
            metadata,
            path: "depthBlurEffect:SimulatedAperture",
            value: String(format: "%.6f", simulatedAperture)
        )
        try setMetadata(metadata, path: "portraitLightingEffect:EffectStrength", value: "0.500000")
        output[kCGImageAuxiliaryDataInfoMetadata as String] = metadata
        return output as CFDictionary
    }

    private static func makeL8Buffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            attributes as CFDictionary,
            &buffer
        ) == kCVReturnSuccess, let buffer else {
            throw CLIError.invalidContainer("unable to allocate L008 matte buffer")
        }
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_Linear,
            .shouldPropagate
        )
        return buffer
    }

    private static func makePlaneBuffer(
        _ plane: Data,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        guard plane.count == width * height else {
            throw CLIError.invalidContainer("OPPO matte plane size does not match its geometry")
        }
        let buffer = try makeL8Buffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw CLIError.invalidContainer("OPPO matte plane has no writable storage")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        plane.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            for row in 0..<height {
                memcpy(
                    baseAddress.advanced(by: row * bytesPerRow),
                    sourceBase.advanced(by: row * width),
                    width
                )
            }
        }
        return buffer
    }

    private static func renderL8(
        _ image: CIImage,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        let buffer = try makeL8Buffer(width: width, height: height)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        CIContext(options: [.useSoftwareRenderer: false]).render(
            image.cropped(to: bounds),
            to: buffer,
            bounds: bounds,
            colorSpace: CGColorSpaceCreateDeviceGray()
        )
        return buffer
    }

    private static func maximum(_ foreground: CIImage, _ background: CIImage) -> CIImage {
        foreground.applyingFilter(
            "CIMaximumCompositing",
            parameters: [kCIInputBackgroundImageKey: background]
        )
    }

    private static func minimum(_ foreground: CIImage, _ background: CIImage) -> CIImage {
        foreground.applyingFilter(
            "CIMinimumCompositing",
            parameters: [kCIInputBackgroundImageKey: background]
        )
    }

    private static func scaled(
        _ image: CIImage,
        width: Int,
        height: Int
    ) -> CIImage {
        image.transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / image.extent.width,
            y: CGFloat(height) / image.extent.height
        ))
    }

    private static func makeRGBGuidedOPPOMatte(
        image: CGImage,
        subject: Data,
        hair: Data?,
        planeWidth: Int,
        planeHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) throws -> (portrait: CVPixelBuffer, hair: CVPixelBuffer?) {
        let bounds = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        let subjectBuffer = try makePlaneBuffer(subject, width: planeWidth, height: planeHeight)
        let smallSubject = CIImage(cvPixelBuffer: subjectBuffer)
        let topology = scaled(smallSubject, width: targetWidth, height: targetHeight)
            .cropped(to: bounds)
        let guide = scaled(CIImage(cgImage: image), width: targetWidth, height: targetHeight)
            .cropped(to: bounds)

        let guided: CIImage
        if let filter = CIFilter(name: "CIEdgePreserveUpsampleFilter") {
            filter.setValue(guide, forKey: kCIInputImageKey)
            filter.setValue(smallSubject, forKey: "inputSmallImage")
            filter.setValue(3.0, forKey: "inputSpatialSigma")
            filter.setValue(0.15, forKey: "inputLumaSigma")
            guided = (filter.outputImage ?? topology).cropped(to: bounds)
        } else {
            guided = topology
        }

        let inwardSupport = topology
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 1.5])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.0])
            .cropped(to: bounds)
        let subjectCore = topology
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 3.0])
            .cropped(to: bounds)
        let guidedBoundary = minimum(guided, inwardSupport).cropped(to: bounds)
        var fused = maximum(guidedBoundary, subjectCore).cropped(to: bounds)

        var hairBuffer: CVPixelBuffer?
        if let hair {
            let lowResolutionHair = try makePlaneBuffer(hair, width: planeWidth, height: planeHeight)
            let hairImage = scaled(
                CIImage(cvPixelBuffer: lowResolutionHair),
                width: targetWidth,
                height: targetHeight
            ).cropped(to: bounds)
            fused = maximum(fused, hairImage).cropped(to: bounds)
            hairBuffer = try renderL8(hairImage, width: targetWidth, height: targetHeight)
        }
        return (
            portrait: try renderL8(fused, width: targetWidth, height: targetHeight),
            hair: hairBuffer
        )
    }

    private static func makeVisionFallbackMatte(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        orientationRaw: UInt32,
        targetWidth: Int,
        targetHeight: Int,
        hair: Data?,
        planeWidth: Int,
        planeHeight: Int
    ) throws -> (portrait: CVPixelBuffer, hair: CVPixelBuffer?) {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]).perform([request])
        guard let observation = request.results?.first else {
            throw CLIError.invalidContainer("Vision returned no person segmentation mask")
        }
        let displayMask = CIImage(cvPixelBuffer: observation.pixelBuffer)
        let storedMask: CIImage
        switch orientationRaw {
        case 3: storedMask = displayMask.oriented(.down)
        case 6: storedMask = displayMask.oriented(.left)
        case 8: storedMask = displayMask.oriented(.right)
        default: storedMask = displayMask
        }
        let bounds = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        var fused = scaled(storedMask, width: targetWidth, height: targetHeight).cropped(to: bounds)
        var hairBuffer: CVPixelBuffer?
        if let hair {
            let lowResolutionHair = try makePlaneBuffer(hair, width: planeWidth, height: planeHeight)
            let hairImage = scaled(
                CIImage(cvPixelBuffer: lowResolutionHair),
                width: targetWidth,
                height: targetHeight
            ).cropped(to: bounds)
            fused = maximum(fused, hairImage).cropped(to: bounds)
            hairBuffer = try renderL8(hairImage, width: targetWidth, height: targetHeight)
        }
        return (
            portrait: try renderL8(fused, width: targetWidth, height: targetHeight),
            hair: hairBuffer
        )
    }

    private static func makeMatteMetadata(
        namespace: String,
        prefix: String,
        versionPath: String,
        version: String
    ) throws -> CGImageMetadata {
        let metadata = CGImageMetadataCreateMutable()
        try registerMetadataNamespace(metadata, namespace: namespace, prefix: prefix)
        try setMetadata(metadata, path: versionPath, value: version)
        return metadata
    }

    private static func makeL8AuxiliaryDictionary(
        buffer: CVPixelBuffer,
        metadata: CGImageMetadata
    ) throws -> CFDictionary {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw CLIError.invalidContainer("matte buffer has no readable storage")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var pixels = Data(count: width * height)
        pixels.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            for row in 0..<height {
                memcpy(
                    destinationBase.advanced(by: row * width),
                    baseAddress.advanced(by: row * bytesPerRow),
                    width
                )
            }
        }
        let description: [CFString: Any] = [
            kCGImagePropertyWidth: width,
            kCGImagePropertyHeight: height,
            kCGImagePropertyBytesPerRow: width,
            kCGImagePropertyPixelFormat: NSNumber(value: kCVPixelFormatType_OneComponent8),
        ]
        return [
            kCGImageAuxiliaryDataInfoData: pixels,
            kCGImageAuxiliaryDataInfoDataDescription: description,
            kCGImageAuxiliaryDataInfoMetadata: metadata,
        ] as CFDictionary
    }

    private struct PortraitMatteDictionaries {
        let portrait: CFDictionary
        let skin: CFDictionary
        let hair: CFDictionary
        let teeth: CFDictionary
        let glasses: CFDictionary
        let sky: CFDictionary?
        let fusionReport: [String: Any]
        let semanticAnalysis: AppleSemanticSceneAnalysis
    }

    private static func storedOrientation(
        _ image: CIImage,
        orientationRaw: UInt32
    ) -> CIImage {
        switch orientationRaw {
        case 2: return image.oriented(.upMirrored)
        case 3: return image.oriented(.down)
        case 4: return image.oriented(.downMirrored)
        case 5: return image.oriented(.leftMirrored)
        case 6: return image.oriented(.left)
        case 7: return image.oriented(.rightMirrored)
        case 8: return image.oriented(.right)
        default: return image
        }
    }

    private static func renderSemanticMatte(
        _ matte: AppleSemanticMatte,
        orientationRaw: UInt32,
        targetWidth: Int,
        targetHeight: Int
    ) throws -> CVPixelBuffer {
        let sourceBuffer = try makePlaneBuffer(
            matte.pixels,
            width: matte.width,
            height: matte.height
        )
        let stored = storedOrientation(
            CIImage(cvPixelBuffer: sourceBuffer),
            orientationRaw: orientationRaw
        )
        let targetBounds = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        let originNormalized = stored.transformed(by: CGAffineTransform(
            translationX: -stored.extent.origin.x,
            y: -stored.extent.origin.y
        ))
        let resized = scaled(originNormalized, width: targetWidth, height: targetHeight)
            .cropped(to: targetBounds)
        return try renderL8(resized, width: targetWidth, height: targetHeight)
    }

    private static func pixelData(from buffer: CVPixelBuffer) throws -> Data {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let source = CVPixelBufferGetBaseAddress(buffer) else {
            throw CLIError.invalidContainer("semantic fusion buffer has no readable storage")
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var pixels = Data(count: width * height)
        pixels.withUnsafeMutableBytes { raw in
            guard let destination = raw.baseAddress else { return }
            for row in 0..<height {
                memcpy(
                    destination.advanced(by: row * width),
                    source.advanced(by: row * stride),
                    width
                )
            }
        }
        return pixels
    }

    private static func edgeGuidedOPPOPrior(
        image: CGImage,
        plane: Data,
        planeWidth: Int,
        planeHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) throws -> CVPixelBuffer {
        let smallBuffer = try makePlaneBuffer(plane, width: planeWidth, height: planeHeight)
        let small = CIImage(cvPixelBuffer: smallBuffer)
        let bounds = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        let guide = scaled(CIImage(cgImage: image), width: targetWidth, height: targetHeight)
            .cropped(to: bounds)
        let topology = scaled(small, width: targetWidth, height: targetHeight).cropped(to: bounds)
        guard let filter = CIFilter(name: "CIEdgePreserveUpsampleFilter") else {
            return try renderL8(topology, width: targetWidth, height: targetHeight)
        }
        filter.setValue(guide, forKey: kCIInputImageKey)
        filter.setValue(small, forKey: "inputSmallImage")
        filter.setValue(3.0, forKey: "inputSpatialSigma")
        filter.setValue(0.15, forKey: "inputLumaSigma")
        return try renderL8(
            (filter.outputImage ?? topology).cropped(to: bounds),
            width: targetWidth,
            height: targetHeight
        )
    }

    private static func fusionMetrics(
        vision: Data,
        prior: Data?,
        final: Data,
        accepted: Bool,
        reason: String
    ) -> [String: Any] {
        func count(_ pixels: Data, threshold: UInt8 = 128) -> Int {
            pixels.reduce(into: 0) { if $1 >= threshold { $0 += 1 } }
        }
        let pixelCount = max(1, vision.count)
        let visionCount = count(vision)
        let priorCount = prior.map { count($0) } ?? 0
        let finalCount = count(final)
        var intersection = 0
        var union = 0
        if let prior, prior.count == vision.count {
            for index in vision.indices {
                let left = vision[index] >= 128
                let right = prior[index] >= 128
                if left && right { intersection += 1 }
                if left || right { union += 1 }
            }
        }
        return [
            "accepted": accepted,
            "reason": reason,
            "threshold": 128,
            "visionCoverage": Double(visionCount) / Double(pixelCount),
            "oppoCoverage": Double(priorCount) / Double(pixelCount),
            "finalCoverage": Double(finalCount) / Double(pixelCount),
            "intersectionOverUnion": union > 0 ? Double(intersection) / Double(union) : 0,
            "addedHighConfidencePixels": max(0, finalCount - visionCount),
            "visionSHA256": sha256Hex(vision),
            "oppoPriorSHA256": prior.map { sha256Hex($0) } ?? NSNull(),
            "finalSHA256": sha256Hex(final),
        ]
    }

    private static func fusePortraitPrior(
        vision: CVPixelBuffer,
        prior: CVPixelBuffer?
    ) throws -> (buffer: CVPixelBuffer, report: [String: Any]) {
        let visionPixels = try pixelData(from: vision)
        guard let prior else {
            return (
                vision,
                fusionMetrics(
                    vision: visionPixels,
                    prior: nil,
                    final: visionPixels,
                    accepted: false,
                    reason: "OPPO subject plane unavailable or empty; Vision-only"
                )
            )
        }
        let priorPixels = try pixelData(from: prior)
        let overlap = zip(visionPixels, priorPixels).reduce(into: 0) { count, pair in
            if pair.0 >= 64 && pair.1 >= 64 { count += 1 }
        }
        let priorSupport = priorPixels.reduce(into: 0) { if $1 >= 64 { $0 += 1 } }
        guard overlap >= 16, priorSupport > 0 else {
            return (
                vision,
                fusionMetrics(
                    vision: visionPixels,
                    prior: priorPixels,
                    final: visionPixels,
                    accepted: false,
                    reason: "OPPO subject prior did not overlap the Vision person topology"
                )
            )
        }
        let width = CVPixelBufferGetWidth(vision)
        let height = CVPixelBufferGetHeight(vision)
        let radius = max(2.0, Double(min(width, height)) / 256.0)
        let visionImage = CIImage(cvPixelBuffer: vision)
        let priorImage = CIImage(cvPixelBuffer: prior)
        let support = visionImage.applyingFilter(
            "CIMorphologyMaximum",
            parameters: [kCIInputRadiusKey: radius]
        ).cropped(to: visionImage.extent)
        let supplement = minimum(priorImage, support).cropped(to: visionImage.extent)
        let fusedImage = maximum(visionImage, supplement).cropped(to: visionImage.extent)
        let fused = try renderL8(fusedImage, width: width, height: height)
        let finalPixels = try pixelData(from: fused)
        return (
            fused,
            fusionMetrics(
                vision: visionPixels,
                prior: priorPixels,
                final: finalPixels,
                accepted: true,
                reason: "Vision boundary with edge-guided OPPO subject topology support"
            )
        )
    }

    private static func fuseHairPrior(
        vision: CVPixelBuffer,
        prior: CVPixelBuffer?,
        person: CVPixelBuffer
    ) throws -> (buffer: CVPixelBuffer, report: [String: Any]) {
        let visionPixels = try pixelData(from: vision)
        guard let prior else {
            return (
                vision,
                fusionMetrics(
                    vision: visionPixels,
                    prior: nil,
                    final: visionPixels,
                    accepted: false,
                    reason: "OPPO hair plane unavailable or empty; Vision-only"
                )
            )
        }
        let priorPixels = try pixelData(from: prior)
        let width = CVPixelBufferGetWidth(vision)
        let height = CVPixelBufferGetHeight(vision)
        let priorInsidePerson = minimum(
            CIImage(cvPixelBuffer: prior),
            CIImage(cvPixelBuffer: person)
        ).cropped(to: CIImage(cvPixelBuffer: vision).extent)
        let fusedImage = maximum(
            CIImage(cvPixelBuffer: vision),
            priorInsidePerson
        ).cropped(to: CIImage(cvPixelBuffer: vision).extent)
        let fused = try renderL8(fusedImage, width: width, height: height)
        let finalPixels = try pixelData(from: fused)
        let added = zip(visionPixels, finalPixels).reduce(into: 0) { count, pair in
            if pair.0 < 128 && pair.1 >= 128 { count += 1 }
        }
        return (
            fused,
            fusionMetrics(
                vision: visionPixels,
                prior: priorPixels,
                final: finalPixels,
                accepted: added > 0,
                reason: added > 0
                    ? "Vision hair boundary with OPPO hair support gated by fused person matte"
                    : "OPPO hair prior added no supported high-confidence pixels"
            )
        )
    }

    private static func makePortraitEffectsMattes(
        imageURL: URL,
        orientationRaw: UInt32,
        depthPlanes: OPPODepthPlanes,
        targetWidth: Int,
        targetHeight: Int,
        semanticOutputDirectory: URL? = nil,
        includesPhotographicStylesSemantics: Bool,
        writeSemanticPNGEvidence: Bool
    ) throws -> PortraitMatteDictionaries {
        let ownsSemanticDirectory = semanticOutputDirectory == nil
        let semanticDirectory = semanticOutputDirectory
            ?? imageURL.deletingLastPathComponent()
                .appendingPathComponent(".xdremux-vision-\(UUID().uuidString)", isDirectory: true)
        defer {
            if ownsSemanticDirectory {
                try? FileManager.default.removeItem(at: semanticDirectory)
            }
        }
        let analysis = try AppleSemanticSceneAnalyzer.analyze(
            imageURL: imageURL,
            outputDirectory: semanticDirectory,
            orientationOverride: orientationRaw,
            profile: includesPhotographicStylesSemantics ? .portraitAndStyles : .portrait,
            writePNGEvidence: writeSemanticPNGEvidence
        )
        guard let person = analysis.person,
              let skin = analysis.skin,
              let hair = analysis.hair,
              let teeth = analysis.teeth,
              let glasses = analysis.glasses else {
            throw CLIError.invalidContainer("Vision semantic analysis is incomplete")
        }
        if includesPhotographicStylesSemantics, analysis.sky == nil {
            throw CLIError.invalidContainer("Vision semantic analysis is missing the Styles sky matte")
        }
        guard analysis.hasCrediblePerson else {
            throw CLIError.invalidContainer(
                "Apple Portrait unavailable: Vision returned no credible person foreground"
            )
        }

        if let subject = depthPlanes.subject {
            let nonzero = subject.reduce(into: 0) { if $1 > 0 { $0 += 1 } }
            print(
                "portrait OPPO subject plane available as topology prior "
                    + "coverage=\(Double(nonzero) / Double(max(1, subject.count)))"
            )
        }
        if depthPlanes.validHair != nil {
            print("portrait OPPO hair plane available as topology prior; Vision supplies the high-resolution boundary")
        }

        let visionPortrait = try renderSemanticMatte(
            person,
            orientationRaw: orientationRaw,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )
        let renderedSkin = try renderSemanticMatte(
            skin,
            orientationRaw: orientationRaw,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )
        let visionHair = try renderSemanticMatte(
            hair,
            orientationRaw: orientationRaw,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )
        let renderedTeeth = try renderSemanticMatte(
            teeth,
            orientationRaw: orientationRaw,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )
        let renderedGlasses = try renderSemanticMatte(
            glasses,
            orientationRaw: orientationRaw,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )
        let renderedSky = try analysis.sky.map { sky in
            try renderSemanticMatte(
                sky,
                orientationRaw: orientationRaw,
                targetWidth: targetWidth,
                targetHeight: targetHeight
            )
        }
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CLIError.unableToLoadBaseImage(imageURL)
        }
        let oppoSubjectPrior = try depthPlanes.subject.map { plane in
            try edgeGuidedOPPOPrior(
                image: image,
                plane: plane,
                planeWidth: depthPlanes.width,
                planeHeight: depthPlanes.height,
                targetWidth: targetWidth,
                targetHeight: targetHeight
            )
        }
        let personFusion = try fusePortraitPrior(
            vision: visionPortrait,
            prior: oppoSubjectPrior
        )
        let oppoHairPrior = try depthPlanes.validHair.map { plane in
            try edgeGuidedOPPOPrior(
                image: image,
                plane: plane,
                planeWidth: depthPlanes.width,
                planeHeight: depthPlanes.height,
                targetWidth: targetWidth,
                targetHeight: targetHeight
            )
        }
        let hairFusion = try fuseHairPrior(
            vision: visionHair,
            prior: oppoHairPrior,
            person: personFusion.buffer
        )
        let fusionReport: [String: Any] = [
            "schema": "xdremux-oppo-vision-semantic-fusion-v1",
            "policy": "Vision high-resolution producer; OPPO subject/hair planes are edge-guided, geometry-aligned topology priors",
            "person": personFusion.report,
            "hair": hairFusion.report,
            "skinTeethGlassesPolicy": "Vision-only; OPPO person/hair planes are not reused for unrelated semantics",
            "facialHairPolicy": "not requested; no production consumer or evidenced HEIF auxiliary role",
        ]
        let portraitMetadata = try makeMatteMetadata(
            namespace: "http://ns.apple.com/portraitEffectsMatte/1.0/",
            prefix: "portraitEffectsMatte",
            versionPath: "portraitEffectsMatte:PortraitEffectsMatteVersion",
            version: "65537"
        )
        let portrait = try makeL8AuxiliaryDictionary(
            buffer: personFusion.buffer,
            metadata: portraitMetadata
        )
        let semanticMetadata = try makeMatteMetadata(
            namespace: "http://ns.apple.com/semanticSegmentationMatte/1.0/",
            prefix: "semanticSegmentationMatte",
            versionPath: "semanticSegmentationMatte:SemanticSegmentationMatteVersion",
            version: "65536"
        )
        return PortraitMatteDictionaries(
            portrait: portrait,
            skin: try makeL8AuxiliaryDictionary(
                buffer: renderedSkin,
                metadata: semanticMetadata
            ),
            hair: try makeL8AuxiliaryDictionary(
                buffer: hairFusion.buffer,
                metadata: semanticMetadata
            ),
            teeth: try makeL8AuxiliaryDictionary(
                buffer: renderedTeeth,
                metadata: semanticMetadata
            ),
            glasses: try makeL8AuxiliaryDictionary(
                buffer: renderedGlasses,
                metadata: semanticMetadata
            ),
            sky: try renderedSky.map {
                try makeL8AuxiliaryDictionary(buffer: $0, metadata: semanticMetadata)
            },
            fusionReport: fusionReport,
            semanticAnalysis: analysis
        )
    }

    private static func makeFocusRegion(
        image: CGImage,
        orientation: CGImagePropertyOrientation,
        orientationRaw: UInt32,
        config: OPPOPortraitConfig?
    ) throws -> PortraitFocusRegion {
        // RearDepthStruct stores the tap-to-focus point in src.image storage
        // coordinates, not in its declared 900x1200 processing dimensions.
        if let config,
           config.focusX >= 0,
           config.focusY >= 0,
           config.focusX < image.width,
           config.focusY < image.height {
            let focusX = config.focusX
            let focusY = config.focusY
            let rawX = Double(focusX) / Double(image.width)
            let rawY = Double(focusY) / Double(image.height)
            let rectangle = config.focusRectangleIsValid ? config.focusRectangle : nil
            let rawWidth = rectangle.flatMap { values in
                values.count == 4 ? Double(abs(values[2] - values[0])) / Double(image.width) : nil
            } ?? 0.12
            let rawHeight = rectangle.flatMap { values in
                values.count == 4 ? Double(abs(values[3] - values[1])) / Double(image.height) : nil
            } ?? 0.12
            print(String(
                format: "portrait focus source=rear.depth.config raw=(%.6f,%.6f) pixel=(%d,%d)",
                rawX,
                rawY,
                focusX,
                focusY
            ))
            return PortraitFocusRegion(
                rawX: rawX,
                rawY: rawY,
                rawWidth: min(max(rawWidth, 0.02), 1),
                rawHeight: min(max(rawHeight, 0.02), 1)
            )
        }

        let attention = VNGenerateAttentionBasedSaliencyImageRequest()
        let faces = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]).perform([attention, faces])
        let faceResults = faces.results ?? []
        let saliencyBuffer = attention.results?.first?.pixelBuffer
        let selectedFace = faceResults.max {
            faceAttentionScore($0, saliency: saliencyBuffer)
                < faceAttentionScore($1, saliency: saliencyBuffer)
        }
        let displayX: Double
        let displayY: Double
        let displayWidth: Double
        let displayHeight: Double
        if let face = selectedFace {
            let box = face.boundingBox
            let leftEye = face.landmarks?.leftEye.flatMap { landmarkCenter($0, face: face) }
            let rightEye = face.landmarks?.rightEye.flatMap { landmarkCenter($0, face: face) }
            if let leftEye, let rightEye {
                displayX = (leftEye.x + rightEye.x) / 2
                displayY = (leftEye.y + rightEye.y) / 2
            } else {
                displayX = box.midX
                displayY = 1 - box.midY
            }
            displayWidth = box.width
            displayHeight = box.height
        } else if let observation = attention.results?.first {
            let point = try attentionCentroid(observation.pixelBuffer)
            displayX = point.x
            displayY = point.y
            displayWidth = 0.12
            displayHeight = 0.12
        } else {
            throw CLIError.invalidContainer("Vision returned no Focus candidate")
        }
        let raw = rawFocusRect(
            x: displayX,
            y: displayY,
            width: displayWidth,
            height: displayHeight,
            orientation: orientationRaw
        )
        return PortraitFocusRegion(
            rawX: raw.x,
            rawY: raw.y,
            rawWidth: raw.width,
            rawHeight: raw.height
        )
    }

    private static func firmwareFocusBranch(
        nearObjectDetected: Bool,
        sceneClass: Int,
        focusROIType: Int,
        focusedFaceAvailable: Bool,
        portraitPlaneAvailable: Bool,
        petPlaneAvailable: Bool
    ) -> OPPOPortraitFocusBranch {
        if nearObjectDetected {
            if sceneClass == 0 { return .nearObject }
            if sceneClass == 2, focusROIType == 3 { return .petRegion }
            return .centerRegion
        }
        switch focusROIType {
        case 1:
            if focusedFaceAvailable { return .tappedFace }
            return portraitPlaneAvailable ? .portraitFace : .portraitWithoutFace
        case 2:
            return .centerRegion
        case 3:
            return petPlaneAvailable ? .petRegion : .portraitWithoutFace
        default:
            return portraitPlaneAvailable ? .portraitWithoutFace : .disparityHistogram
        }
    }

    private static func producerShapedFocusHistogram(
        _ values: [UInt8],
        header: PortraitDepthHeader,
        targetFraction: Double
    ) -> Double {
        let depths = values.compactMap { header.nativeFloatDepth(forRank: Double($0)) }
        guard !values.isEmpty,
              let rawMinimum = depths.min(),
              let rawMaximum = depths.max() else {
            return 0
        }
        let minimum = rawMinimum
        let maximum = min(rawMaximum, 15_000.0)
        guard maximum > minimum else {
            return header.rank(forNativeFloatDepth: minimum)
                ?? Double(values[values.count / 2])
        }
        var counts = [Int](repeating: 0, count: 20)
        var sums = [Double](repeating: 0, count: 20)
        let span = maximum - minimum
        for depth in depths {
            let delta = depth - minimum
            let normalized = (min(max(delta, 0), span) / span) * 20.0
            let bin = max(0, min(19, Int(normalized.rounded(.down))))
            counts[bin] += 1
            sums[bin] += delta
        }
        let target = max(0, Int((Double(depths.count) * targetFraction).rounded(.down)))
        var cumulative = 0
        for index in counts.indices {
            cumulative += counts[index]
            if cumulative > target {
                let selectedDepth = counts[index] > 0
                    ? sums[index] / Double(counts[index]) + minimum
                    : minimum
                return header.rank(forNativeFloatDepth: selectedDepth)
                    ?? Double(values[values.count / 2])
            }
        }
        return header.rank(forNativeFloatDepth: maximum) ?? Double(values.last ?? 0)
    }

    private static func selectPortraitFocus(
        ranks: Data,
        planes: OPPODepthPlanes,
        header: PortraitDepthHeader,
        config: OPPOPortraitConfig,
        sourceWidth: Int,
        sourceHeight: Int,
        width: Int,
        height: Int,
        focus: PortraitFocusRegion
    ) -> OPPOPortraitFocusSelection {
        // The producer stores both focusRect and face rectangles as LTWH in
        // raw src.image JPEG coordinates. Treating the last two integers as
        // opposite corners silently moved the ROI for every v4 face sample.
        func normalizedLTWH(_ rectangle: [Int]) -> [Double]? {
            guard rectangle.count == 4, sourceWidth > 0, sourceHeight > 0 else { return nil }
            guard rectangle[2] > 0, rectangle[3] > 0 else { return nil }
            let x0 = max(0, min(sourceWidth, rectangle[0]))
            let y0 = max(0, min(sourceHeight, rectangle[1]))
            let x1 = max(x0, min(sourceWidth, rectangle[0] + rectangle[2]))
            let y1 = max(y0, min(sourceHeight, rectangle[1] + rectangle[3]))
            guard x1 > x0, y1 > y0 else { return nil }
            return [
                Double(x0) / Double(sourceWidth),
                Double(y0) / Double(sourceHeight),
                Double(x1 - x0) / Double(sourceWidth),
                Double(y1 - y0) / Double(sourceHeight),
            ]
        }
        func containsFocus(_ rectangle: [Int]) -> Bool {
            guard rectangle.count == 4, rectangle[2] > 0, rectangle[3] > 0 else { return false }
            return config.focusX >= rectangle[0]
                && config.focusX < rectangle[0] + rectangle[2]
                && config.focusY >= rectangle[1]
                && config.focusY < rectangle[1] + rectangle[3]
        }
        let focusedFace = config.faces.first(where: { containsFocus($0.rectangle) })
        let focusDepthX = max(0, min(width - 1, Int((focus.rawX * Double(width)).rounded(.down))))
        let focusDepthY = max(0, min(height - 1, Int((focus.rawY * Double(height)).rounded(.down))))
        let hasPortrait = planes.portrait?.contains(where: { $0 >= 127 }) ?? false
        let hasPet = planes.pet?.contains(where: { $0 >= 127 }) ?? false

        // CalFocusDepthEngine::calcFocusDepth dispatch recovered from
        // libOPAlgoCamCaptureDualPortrait.so. +0x24 is nearObject.Flag,
        // +0xa0 is sceneClass, and +0x18 is focusRoiType. This branch order is
        // producer-exact even where the downstream ROI statistic is still an
        // explicitly marked compatibility reconstruction.
        let branch = firmwareFocusBranch(
            nearObjectDetected: header.nearObjectDetected,
            sceneClass: header.sceneClass ?? 0,
            focusROIType: config.focusROIType ?? 0,
            focusedFaceAvailable: focusedFace != nil,
            portraitPlaneAvailable: hasPortrait,
            petPlaneAvailable: hasPet
        )
        // PetScene calls verifyPetRect first. With no saved landmark table the
        // validator cannot produce a pet rectangle, so the producer takes its
        // full-image Hist(..., 0.02) fallback. The generic no-mask branch uses
        // the same full-image histogram with a 0.05 target.
        let exactPetHistogramFallback = branch == .petRegion && config.faces.isEmpty
        let exactFullImageHistogram = branch == .disparityHistogram || exactPetHistogramFallback

        var sourceROI: [Double]
        if branch == .centerRegion {
            let x0 = max(0, focusDepthX - 2)
            let y0 = max(0, focusDepthY - 2)
            let x1 = min(width, focusDepthX + 3)
            let y1 = min(height, focusDepthY + 3)
            sourceROI = [
                Double(x0) / Double(width),
                Double(y0) / Double(height),
                Double(x1 - x0) / Double(width),
                Double(y1 - y0) / Double(height),
            ]
        } else if exactFullImageHistogram {
            sourceROI = [0, 0, 1, 1]
        } else if let focusedFace,
           [.tappedFace, .portraitFace, .petFace].contains(branch),
           let faceROI = normalizedLTWH(focusedFace.rectangle) {
            sourceROI = faceROI
        } else if config.focusRectangleIsValid,
                  let rectangle = config.focusRectangle,
                  let configROI = normalizedLTWH(rectangle) {
            sourceROI = configROI
        } else {
            sourceROI = [
                max(0, focus.rawX - focus.rawWidth / 2),
                max(0, focus.rawY - focus.rawHeight / 2),
                min(1, focus.rawWidth),
                min(1, focus.rawHeight),
            ]
        }
        sourceROI[2] = min(sourceROI[2], 1 - sourceROI[0])
        sourceROI[3] = min(sourceROI[3], 1 - sourceROI[1])
        let depthROI = sourceROI
        let minX = max(0, min(width - 1, Int((depthROI[0] * Double(width)).rounded(.down))))
        let minY = max(0, min(height - 1, Int((depthROI[1] * Double(height)).rounded(.down))))
        let maxX = max(minX, min(width - 1, Int(((depthROI[0] + depthROI[2]) * Double(width)).rounded(.up)) - 1))
        let maxY = max(minY, min(height - 1, Int(((depthROI[1] + depthROI[3]) * Double(height)).rounded(.up)) - 1))
        let mask: Data? = {
            if exactFullImageHistogram { return nil }
            switch branch {
            case .tappedFace, .portraitFace, .portraitWithoutFace:
                return planes.portrait
            case .petFace, .petRegion:
                return planes.pet
            default:
                return nil
            }
        }()
        var candidates: [UInt8] = []
        var rejected = 0
        let sampleStep = branch == .centerRegion ? 1 : 2
        for y in stride(from: minY, through: maxY, by: sampleStep) {
            for x in stride(from: minX, through: maxX, by: sampleStep) {
                let index = y * width + x
                // The native portrait path uses signed-byte tests and the
                // no-face verifier uses >126. Preserve that 127/128 semantic
                // boundary rather than accepting every non-zero mask value.
                if let mask, mask.count == ranks.count, mask[index] < 127 {
                    rejected += 1
                    continue
                }
                candidates.append(ranks[index])
            }
        }
        if candidates.count < 9 {
            rejected += candidates.count
            candidates.removeAll(keepingCapacity: true)
            let radius = max(3, min(width, height) / 64)
            for y in max(0, focusDepthY - radius)...min(height - 1, focusDepthY + radius) {
                for x in max(0, focusDepthX - radius)...min(width - 1, focusDepthX + radius) {
                    candidates.append(ranks[y * width + x])
                }
            }
        }
        candidates.sort()

        let selectedRank: Double
        switch branch {
        case .centerRegion:
            // The native center routine averages a clipped 5x5 window.
            var depthSum = 0.0
            var count = 0
            for y in max(0, focusDepthY - 2)...min(height - 1, focusDepthY + 2) {
                for x in max(0, focusDepthX - 2)...min(width - 1, focusDepthX + 2) {
                    if let depth = header.nativeFloatDepth(forRank: Double(ranks[y * width + x])) {
                        depthSum += depth
                        count += 1
                    }
                }
            }
            selectedRank = count > 0
                ? header.rank(forNativeFloatDepth: depthSum / Double(count))
                    ?? Double(candidates[candidates.count / 2])
                : Double(candidates[candidates.count / 2])
        case .nearObject, .disparityHistogram:
            // Native calcFocusDepthUsingHist uses 20 equal-width bins and a
            // 5% cumulative threshold in this path (30% when its boolean
            // override is set). Values enter the recovered producer
            // float-depth domain before the selected mean maps back to rank.
            selectedRank = producerShapedFocusHistogram(
                candidates,
                header: header,
                targetFraction: 0.05
            )
        case .petRegion where exactPetHistogramFallback:
            selectedRank = producerShapedFocusHistogram(
                candidates,
                header: header,
                targetFraction: 0.02
            )
        case .portraitFace, .portraitWithoutFace, .tappedFace, .petFace, .petRegion:
            selectedRank = producerShapedFocusHistogram(
                candidates,
                header: header,
                targetFraction: 0.20
            )
        case .tappedRegion:
            let lower = candidates.count / 10
            let upper = max(lower + 1, candidates.count - lower)
            let trimmed = candidates[lower..<upper]
            selectedRank = Double(trimmed[trimmed.index(trimmed.startIndex, offsetBy: trimmed.count / 2)])
        }
        let deviations = candidates.map { abs(Double($0) - selectedRank) }.sorted()
        let mad = deviations[deviations.count / 2]
        let confidence = max(0, min(1, (Double(candidates.count) / Double(max(1, candidates.count + rejected))) * (1 - mad / 128)))
        let roiEvidence: PortraitEvidence = branch == .centerRegion || exactFullImageHistogram
            ? .oppoProducerExact
            : .compatibilityFallback
        let statisticEvidence: PortraitEvidence = branch == .centerRegion || exactFullImageHistogram
            ? .oppoProducerExact
            : .compatibilityFallback
        print(String(
            format: "portrait focus branch=%@ depthROI=(%d,%d)-(%d,%d) samples=%d rejected=%d rank=%.3f confidence=%.3f",
            branch.rawValue,
            minX,
            minY,
            maxX,
            maxY,
            candidates.count,
            rejected,
            selectedRank,
            confidence
        ))
        return OPPOPortraitFocusSelection(
            branch: branch,
            branchEvidence: .oppoProducerExact,
            sourceROI: sourceROI,
            depthROI: depthROI,
            roiEvidence: roiEvidence,
            selectedRank: selectedRank,
            internalDisparity: header.internalDisparity(forRank: selectedRank),
            configDistance: config.objectDistance.map(Double.init),
            confidence: confidence,
            sampleCount: candidates.count,
            rejectedSampleCount: rejected,
            statisticEvidence: statisticEvidence,
            evidence: statisticEvidence
        )
    }

    private static func landmarkCenter(
        _ region: VNFaceLandmarkRegion2D,
        face: VNFaceObservation
    ) -> (x: Double, y: Double)? {
        guard region.pointCount > 0 else { return nil }
        var x = 0.0
        var y = 0.0
        for point in region.normalizedPoints {
            x += face.boundingBox.minX + CGFloat(point.x) * face.boundingBox.width
            y += face.boundingBox.minY + CGFloat(point.y) * face.boundingBox.height
        }
        return (x / Double(region.pointCount), 1 - y / Double(region.pointCount))
    }

    private static func faceAttentionScore(
        _ face: VNFaceObservation,
        saliency: CVPixelBuffer?
    ) -> Double {
        guard let saliency,
              CVPixelBufferGetPixelFormatType(saliency) == kCVPixelFormatType_OneComponent32Float else {
            return Double(face.boundingBox.width * face.boundingBox.height) * Double(face.confidence)
        }
        CVPixelBufferLockBaseAddress(saliency, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(saliency, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(saliency) else { return 0 }
        let width = CVPixelBufferGetWidth(saliency)
        let height = CVPixelBufferGetHeight(saliency)
        let stride = CVPixelBufferGetBytesPerRow(saliency) / MemoryLayout<Float>.stride
        let values = base.assumingMemoryBound(to: Float.self)
        let box = face.boundingBox
        let minX = max(0, min(width - 1, Int(box.minX * CGFloat(width))))
        let maxX = max(minX, min(width - 1, Int(box.maxX * CGFloat(width))))
        let top = 1 - box.maxY
        let bottom = 1 - box.minY
        let minY = max(0, min(height - 1, Int(top * CGFloat(height))))
        let maxY = max(minY, min(height - 1, Int(bottom * CGFloat(height))))
        var sum = 0.0
        var count = 0
        for y in minY...maxY { for x in minX...maxX {
            let value = values[y * stride + x]
            if value.isFinite {
                sum += Double(value)
                count += 1
            }
        }}
        let mean = count > 0 ? sum / Double(count) : 0
        return mean * Double(face.confidence)
    }

    private static func attentionCentroid(_ buffer: CVPixelBuffer) throws -> (x: Double, y: Double) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float,
              let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw CLIError.invalidContainer("unexpected Vision saliency buffer")
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.stride
        let values = base.assumingMemoryBound(to: Float.self)
        var finite: [Float] = []
        finite.reserveCapacity(width * height)
        for y in 0..<height { for x in 0..<width where values[y * stride + x].isFinite {
            finite.append(values[y * stride + x])
        }}
        guard !finite.isEmpty else { throw CLIError.invalidContainer("empty Vision saliency map") }
        finite.sort()
        let threshold = finite[Int(Double(finite.count - 1) * 0.9)]
        var sum = 0.0
        var weightedX = 0.0
        var weightedY = 0.0
        for y in 0..<height { for x in 0..<width {
            let value = values[y * stride + x]
            guard value.isFinite, value >= threshold, value > 0 else { continue }
            let weight = Double(value)
            sum += weight
            weightedX += (Double(x) + 0.5) / Double(width) * weight
            weightedY += (Double(y) + 0.5) / Double(height) * weight
        }}
        guard sum > 0 else { throw CLIError.invalidContainer("Vision saliency has no positive response") }
        return (weightedX / sum, weightedY / sum)
    }

    private static func rawFocusRect(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        orientation: UInt32
    ) -> (x: Double, y: Double, width: Double, height: Double) {
        switch orientation {
        case 2: return (1 - x, y, width, height)
        case 3: return (1 - x, 1 - y, width, height)
        case 4: return (x, 1 - y, width, height)
        case 5: return (y, x, height, width)
        case 6: return (y, 1 - x, height, width)
        case 7: return (1 - y, 1 - x, height, width)
        case 8: return (1 - y, x, height, width)
        default: return (x, y, width, height)
        }
    }

    private static func writeBlankPortraitScaffold(
        sourceMetadataURL: URL,
        baseWidth: Int,
        baseHeight: Int,
        baseColorSpace: CGColorSpace?,
        orientation: UInt32,
        focus: PortraitFocusRegion,
        afMeasuredDepth: Int?,
        photoIdentifier: String,
        captureDate: String?,
        sourceImageData: Data,
        sourceGainMap: PortraitSourceGainMap,
        depthDictionary: CFDictionary,
        matteDictionary: CFDictionary,
        skinDictionary: CFDictionary,
        hairDictionary: CFDictionary,
        teethDictionary: CFDictionary,
        glassesDictionary: CFDictionary,
        skyDictionary: CFDictionary?,
        outputURL: URL,
        eventHandler: ConversionEventHandler? = nil
    ) throws {
        let gainCarrierURL = siblingScratchURL(for: outputURL, label: "portrait-blank", pathExtension: "heic")
        let gainISOURL = siblingScratchURL(for: outputURL, label: "portrait-blank-iso", pathExtension: "heic")
        defer {
            for url in [gainCarrierURL, gainISOURL] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        guard let colorSpace = baseColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: baseWidth,
                  height: baseHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: baseWidth * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ),
              let blank = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  gainCarrierURL as CFURL,
                  UTType.heic.identifier as CFString,
                  1,
                  nil
              ) else {
            throw CLIError.unableToCreateDestination(outputURL)
        }
        guard let source = CGImageSourceCreateWithURL(sourceMetadataURL as CFURL, nil) else {
            throw CLIError.unableToLoadBaseImage(sourceMetadataURL)
        }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        properties[kCGImagePropertyMakerAppleDictionary] = portraitMakerAppleDictionary(
            afMeasuredDepth: afMeasuredDepth,
            photoIdentifier: photoIdentifier
        )
        var exif = (properties[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        exif[kCGImagePropertyExifCustomRendered] = 9
        exif[kCGImagePropertyExifPixelXDimension] = baseWidth
        exif[kCGImagePropertyExifPixelYDimension] = baseHeight
        properties[kCGImagePropertyExifDictionary] = exif
        properties[kCGImagePropertyOrientation] = orientation
        let metadata = try makeFocusMetadata(
            width: baseWidth,
            height: baseHeight,
            focus: focus,
            captureDate: captureDate
        )
        CGImageDestinationAddImageAndMetadata(destination, blank, metadata, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CLIError.unableToFinalizeDestination(gainCarrierURL)
        }
        try writeSrcImagePreserveBridge(
            sourceImageData: sourceImageData,
            metadataSourceURL: gainCarrierURL,
            outputURL: gainISOURL,
            expectedGainMap: sourceGainMap,
            eventHandler: eventHandler
        )
        guard let gainCarrier = CGImageSourceCreateWithURL(gainISOURL as CFURL, nil),
              let scaffoldDestination = CGImageDestinationCreateWithURL(
                  outputURL as CFURL,
                  UTType.heic.identifier as CFString,
                  1,
                  nil
              ) else {
            throw CLIError.unableToFinalizeDestination(gainCarrierURL)
        }
        let scaffoldImageOptions: [CFString: Any] = [
            kCGImageDestinationPreserveGainMap: true,
            kCGImagePropertyOrientation: NSNumber(value: orientation),
        ]
        var auditEntries: [(name: String, dictionary: CFDictionary)] = [
            ("disparity", depthDictionary),
            ("portrait", matteDictionary),
            ("skin", skinDictionary),
            ("hair", hairDictionary),
            ("teeth", teethDictionary),
            ("glasses", glassesDictionary),
        ]
        if let skyDictionary {
            auditEntries.append(("sky", skyDictionary))
        }
        try AppleEncodingAudit.writeAuxiliaryReferencesIfRequested(
            prefix: "portrait",
            entries: auditEntries
        )
        CGImageDestinationAddImageFromSource(
            scaffoldDestination,
            gainCarrier,
            0,
            scaffoldImageOptions as CFDictionary
        )
        CGImageDestinationAddAuxiliaryDataInfo(
            scaffoldDestination,
            kCGImageAuxiliaryDataTypeDisparity,
            depthDictionary
        )
        CGImageDestinationAddAuxiliaryDataInfo(
            scaffoldDestination,
            kCGImageAuxiliaryDataTypePortraitEffectsMatte,
            matteDictionary
        )
        // ImageIO authors this semantic family in one finalize operation so
        // mattes that share a monochrome hvcC cannot be partially replaced.
        CGImageDestinationAddAuxiliaryDataInfo(
            scaffoldDestination,
            kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
            skinDictionary
        )
        CGImageDestinationAddAuxiliaryDataInfo(
            scaffoldDestination,
            kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
            hairDictionary
        )
        CGImageDestinationAddAuxiliaryDataInfo(
            scaffoldDestination,
            kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
            teethDictionary
        )
        CGImageDestinationAddAuxiliaryDataInfo(
            scaffoldDestination,
            kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte,
            glassesDictionary
        )
        if let skyDictionary {
            CGImageDestinationAddAuxiliaryDataInfo(
                scaffoldDestination,
                kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte,
                skyDictionary
            )
        }
        guard CGImageDestinationFinalize(scaffoldDestination) else {
            throw CLIError.unableToFinalizeDestination(outputURL)
        }
    }

    private static func captureDateString(sourceURL: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String else {
            return nil
        }
        return raw.replacingOccurrences(of: ":", with: "-", options: [], range: raw.startIndex..<raw.index(raw.startIndex, offsetBy: min(10, raw.count)))
            .replacingOccurrences(of: " ", with: "T")
    }
}

package func transplantPortraitBaseAndGainPayloads(
    payloadSourceURL: URL,
    scaffoldURL: URL,
    outputURL: URL
) throws {
    struct Graph {
        let meta: ISOBMFFBox
        let mdat: ISOBMFFBox
        let iloc: ISOBMFFBox
        let iprp: ISOBMFFBox
        let ipco: ISOBMFFBox
        let idat: ISOBMFFBox?
        let locations: [Int: ISOBMFFILocEntry]
        let baseTiles: [Int]
        let gainTiles: [Int]
        let hvcCPropertyByItem: [Int: ISOBMFFPropertyInfo]
    }
    func graph(_ data: Data, owner: String) throws -> Graph {
        let top = isobmffBoxes(in: data, start: 0, end: data.count)
        guard let meta = top.first(where: { $0.type == "meta" }),
              let mdat = top.first(where: { $0.type == "mdat" }) else {
            throw CLIError.invalidContainer("\(owner) has no meta/mdat")
        }
        let children = isobmffBoxes(in: data, start: meta.dataStart + 4, end: meta.dataEnd)
        guard let pitm = children.first(where: { $0.type == "pitm" }),
              let iinf = children.first(where: { $0.type == "iinf" }),
              let iloc = children.first(where: { $0.type == "iloc" }),
              let iref = children.first(where: { $0.type == "iref" }),
              let iprp = children.first(where: { $0.type == "iprp" }) else {
            throw CLIError.invalidContainer("\(owner) item graph is incomplete")
        }
        let primary = parseISOBMFFPITM(data, pitm)
        let infos = parseISOBMFFItemInfos(data, iinf).items
        guard let tmap = infos.first(where: { $0.type == "tmap" })?.itemID else {
            throw CLIError.invalidContainer("\(owner) has no tmap")
        }
        let refs = parseISOBMFFIRefs(data, iref).refs
        guard let baseTiles = refs.first(where: { $0.type == "dimg" && $0.from == primary })?.to,
              let gainGrid = refs.first(where: { $0.type == "dimg" && $0.from == tmap })?.to.first(where: { $0 != primary }),
              let gainTiles = refs.first(where: { $0.type == "dimg" && $0.from == gainGrid })?.to else {
            throw CLIError.invalidContainer("\(owner) base/gain grid graph is incomplete")
        }
        let locations = Dictionary(uniqueKeysWithValues: try parseISOBMFFILoc(data, iloc).map { ($0.itemID, $0) })
        let properties = try parseISOBMFFIPCOPropertyInfos(data, iprp)
        let propertyByIndex = Dictionary(uniqueKeysWithValues: properties.map { ($0.index, $0) })
        guard let ipco = isobmffBoxes(
            in: data,
            start: iprp.dataStart,
            end: iprp.dataEnd
        ).first(where: { $0.type == "ipco" }) else {
            throw CLIError.invalidContainer("\(owner) has no ipco")
        }
        guard let ipmaBox = isobmffBoxes(in: data, start: iprp.dataStart, end: iprp.dataEnd).first(where: { $0.type == "ipma" }) else {
            throw CLIError.invalidContainer("\(owner) has no ipma")
        }
        let ipma = parseISOBMFFIPMA(data, ipmaBox)
        var hvcCPropertyByItem: [Int: ISOBMFFPropertyInfo] = [:]
        for entry in ipma.entries {
            for association in entry.associations {
                let index = assocPropertyIndex(association, flags: ipma.flags)
                if let property = propertyByIndex[index], property.type == "hvcC" {
                    hvcCPropertyByItem[entry.itemID] = property
                }
            }
        }
        return Graph(
            meta: meta,
            mdat: mdat,
            iloc: iloc,
            iprp: iprp,
            ipco: ipco,
            idat: children.first(where: { $0.type == "idat" }),
            locations: locations,
            baseTiles: baseTiles,
            gainTiles: gainTiles,
            hvcCPropertyByItem: hvcCPropertyByItem
        )
    }

    let sourceData = try Data(contentsOf: payloadSourceURL)
    var scaffoldData = try Data(contentsOf: scaffoldURL)
    let source = try graph(sourceData, owner: "first assembly")
    let scaffold = try graph(scaffoldData, owner: "portrait scaffold")
    guard source.baseTiles.count == scaffold.baseTiles.count,
          source.gainTiles.count == scaffold.gainTiles.count,
          !source.baseTiles.isEmpty,
          !source.gainTiles.isEmpty else {
        throw CLIError.invalidContainer("first assembly/scaffold tile graph differs")
    }
    struct Replacement {
        let itemID: Int
        let offset: Int
        let length: Int
        let payload: Data
        var delta: Int { payload.count - length }
    }
    let pairs = Array(zip(source.baseTiles, scaffold.baseTiles))
        + Array(zip(source.gainTiles, scaffold.gainTiles))
    struct CodecReplacement {
        let offset: Int
        let length: Int
        let payload: Data
        var delta: Int { payload.count - length }
    }
    var codecReplacementByOffset: [Int: CodecReplacement] = [:]
    for (sourceID, scaffoldID) in pairs {
        guard let sourceProperty = source.hvcCPropertyByItem[sourceID],
              let scaffoldProperty = scaffold.hvcCPropertyByItem[scaffoldID] else {
            throw CLIError.invalidContainer("portrait tile is missing hvcC")
        }
        guard scaffoldProperty.boxStart >= scaffold.ipco.dataStart,
              scaffoldProperty.boxStart + scaffoldProperty.boxSize <= scaffold.ipco.dataEnd else {
            throw CLIError.invalidContainer("portrait hvcC is outside the replaceable ipco region")
        }
        guard sourceProperty.rawBox != scaffoldProperty.rawBox else { continue }
        let candidate = CodecReplacement(
            offset: scaffoldProperty.boxStart,
            length: scaffoldProperty.boxSize,
            payload: sourceProperty.rawBox
        )
        if let existing = codecReplacementByOffset[candidate.offset],
           existing.payload != candidate.payload {
            throw CLIError.invalidContainer(
                "one portrait scaffold hvcC maps to incompatible source codecs"
            )
        }
        codecReplacementByOffset[candidate.offset] = candidate
    }
    let codecReplacements = codecReplacementByOffset.values.sorted { $0.offset > $1.offset }
    let metadataDelta = codecReplacements.reduce(0) { $0 + $1.delta }
    var replacements: [Replacement] = []
    for (sourceID, scaffoldID) in pairs {
        guard let sourceLocation = source.locations[sourceID],
              let scaffoldLocation = scaffold.locations[scaffoldID],
              scaffoldLocation.constructionMethod == 0,
              scaffoldLocation.extents.count == 1 else {
            throw CLIError.invalidContainer("portrait tile does not have one file extent")
        }
        replacements.append(Replacement(
            itemID: scaffoldID,
            offset: scaffoldLocation.extents[0].offset,
            length: scaffoldLocation.extents[0].length,
            payload: try itemPayload(in: sourceData, entry: sourceLocation, idat: source.idat)
        ))
    }
    let replacementByID = Dictionary(uniqueKeysWithValues: replacements.map { ($0.itemID, $0) })
    let iloc = scaffold.iloc
    let version = scaffoldData[iloc.dataStart]
    let sizeField = scaffoldData[iloc.dataStart + 4]
    let sizeField2 = scaffoldData[iloc.dataStart + 5]
    let offsetSize = Int(sizeField >> 4)
    let lengthSize = Int(sizeField & 0x0f)
    let baseOffsetSize = Int(sizeField2 >> 4)
    let indexSize = (version == 1 || version == 2) ? Int(sizeField2 & 0x0f) : 0
    guard offsetSize == 4, lengthSize == 4, baseOffsetSize == 0 else {
        throw CLIError.invalidContainer("unsupported portrait scaffold iloc")
    }
    var position = iloc.dataStart + 6
    let itemCount: Int
    if version < 2 { itemCount = readUInt16BEUnchecked(scaffoldData, at: position); position += 2 }
    else { itemCount = readUInt32BEUnchecked(scaffoldData, at: position); position += 4 }
    var fields: [(itemID: Int, offsetPosition: Int, lengthPosition: Int)] = []
    for _ in 0..<itemCount {
        let itemID: Int
        if version < 2 { itemID = readUInt16BEUnchecked(scaffoldData, at: position); position += 2 }
        else { itemID = readUInt32BEUnchecked(scaffoldData, at: position); position += 4 }
        var constructionMethod = 0
        if version == 1 || version == 2 {
            constructionMethod = readUInt16BEUnchecked(scaffoldData, at: position) & 0x0f
            position += 2
        }
        position += 2 + baseOffsetSize
        let extentCount = readUInt16BEUnchecked(scaffoldData, at: position); position += 2
        for _ in 0..<extentCount {
            position += indexSize
            let offsetPosition = position; position += offsetSize
            let lengthPosition = position; position += lengthSize
            if constructionMethod == 0 { fields.append((itemID, offsetPosition, lengthPosition)) }
        }
    }
    func patchUInt32(_ value: Int, at position: Int) {
        var replacement = Data()
        appendUInt32BE(value, to: &replacement)
        scaffoldData.replaceSubrange(position..<(position + 4), with: replacement)
    }
    if metadataDelta != 0 {
        patchUInt32(scaffold.meta.size + metadataDelta, at: scaffold.meta.boxStart)
        patchUInt32(scaffold.iprp.size + metadataDelta, at: scaffold.iprp.boxStart)
        patchUInt32(scaffold.ipco.size + metadataDelta, at: scaffold.ipco.boxStart)
    }
    for field in fields {
        let oldOffset = readUInt32BEUnchecked(scaffoldData, at: field.offsetPosition)
        let shift = replacements.filter { $0.offset < oldOffset }.reduce(0) { $0 + $1.delta }
        patchUInt32(oldOffset + metadataDelta + shift, at: field.offsetPosition)
        if let replacement = replacementByID[field.itemID] {
            patchUInt32(replacement.payload.count, at: field.lengthPosition)
        }
    }
    patchUInt32(
        scaffold.mdat.size + replacements.reduce(0) { $0 + $1.delta },
        at: scaffold.mdat.boxStart
    )
    for replacement in codecReplacements {
        scaffoldData.replaceSubrange(
            replacement.offset..<(replacement.offset + replacement.length),
            with: replacement.payload
        )
    }
    for replacement in replacements.sorted(by: { $0.offset > $1.offset }) {
        let adjustedOffset = replacement.offset + metadataDelta
        scaffoldData.replaceSubrange(
            adjustedOffset..<(adjustedOffset + replacement.length),
            with: replacement.payload
        )
    }
    let output = try graph(scaffoldData, owner: "payload-transplanted output")
    let verificationPairs = Array(zip(source.baseTiles, output.baseTiles))
        + Array(zip(source.gainTiles, output.gainTiles))
    guard verificationPairs.count == pairs.count else {
        throw CLIError.invalidContainer("payload-transplanted output tile graph differs")
    }
    for (sourceID, outputID) in verificationPairs {
        guard let sourceLocation = source.locations[sourceID],
              let outputLocation = output.locations[outputID] else {
            throw CLIError.invalidContainer("payload-transplanted output tile location missing")
        }
        let sourcePayload = try itemPayload(in: sourceData, entry: sourceLocation, idat: source.idat)
        let outputPayload = try itemPayload(in: scaffoldData, entry: outputLocation, idat: output.idat)
        guard sourcePayload == outputPayload else {
            throw CLIError.invalidContainer("base/HDR Gain Map payload changed during portrait transplant")
        }
    }
    try scaffoldData.write(to: outputURL, options: .atomic)
}
