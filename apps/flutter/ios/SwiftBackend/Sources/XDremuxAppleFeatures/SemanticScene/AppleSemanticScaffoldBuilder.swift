import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import XDRemuxCore

package enum AppleSemanticScaffoldBuilder {
    private static func makeMetadata(
        namespace: String,
        prefix: String,
        versionPath: String,
        version: String
    ) throws -> CGImageMetadata {
        let metadata = CGImageMetadataCreateMutable()
        var registrationError: Unmanaged<CFError>?
        guard CGImageMetadataRegisterNamespaceForPrefix(
            metadata,
            namespace as CFString,
            prefix as CFString,
            &registrationError
        ) else {
            if let registrationError { throw registrationError.takeRetainedValue() as Error }
            throw CLIError.invalidContainer("cannot register \(prefix) metadata namespace")
        }
        guard CGImageMetadataSetValueWithPath(
            metadata,
            nil,
            versionPath as CFString,
            version as CFString
        ) else {
            throw CLIError.invalidContainer("cannot author \(prefix) metadata version")
        }
        return metadata
    }

    private static func fitWithin(width: Int, height: Int, maximum: Int) -> (Int, Int) {
        let scale = min(1.0, Double(maximum) / Double(max(width, height)))
        let fittedWidth = max(2, Int((Double(width) * scale / 2.0).rounded()) * 2)
        let fittedHeight = max(2, Int((Double(height) * scale / 2.0).rounded()) * 2)
        return (min(fittedWidth, maximum), min(fittedHeight, maximum))
    }

    private static func auxiliaryDictionary(
        matte: AppleSemanticMatte,
        width: Int,
        height: Int,
        metadata: CGImageMetadata
    ) throws -> CFDictionary {
        var sourceBuffer: CVPixelBuffer?
        let attributes: CFDictionary = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            matte.width,
            matte.height,
            kCVPixelFormatType_OneComponent8,
            attributes,
            &sourceBuffer
        ) == kCVReturnSuccess, let sourceBuffer else {
            throw CLIError.invalidContainer("cannot allocate semantic source pixel buffer")
        }
        CVPixelBufferLockBaseAddress(sourceBuffer, [])
        if let destination = CVPixelBufferGetBaseAddress(sourceBuffer) {
            let destinationStride = CVPixelBufferGetBytesPerRow(sourceBuffer)
            matte.pixels.withUnsafeBytes { raw in
                guard let source = raw.baseAddress else { return }
                for row in 0..<matte.height {
                    memcpy(
                        destination.advanced(by: row * destinationStride),
                        source.advanced(by: row * matte.bytesPerRow),
                        matte.width
                    )
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(sourceBuffer, [])

        var targetBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            attributes,
            &targetBuffer
        ) == kCVReturnSuccess, let targetBuffer else {
            throw CLIError.invalidContainer("cannot allocate semantic output pixel buffer")
        }
        let sourceImage = CIImage(cvPixelBuffer: sourceBuffer)
        let normalized = sourceImage.transformed(by: CGAffineTransform(
            translationX: -sourceImage.extent.origin.x,
            y: -sourceImage.extent.origin.y
        ))
        let resized = normalized.transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / normalized.extent.width,
            y: CGFloat(height) / normalized.extent.height
        )).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        CIContext(options: [.cacheIntermediates: false]).render(
            resized,
            to: targetBuffer,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpaceCreateDeviceGray()
        )

        CVPixelBufferLockBaseAddress(targetBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(targetBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(targetBuffer) else {
            throw CLIError.invalidContainer("semantic output has no readable storage")
        }
        let stride = CVPixelBufferGetBytesPerRow(targetBuffer)
        var pixels = Data(count: width * height)
        pixels.withUnsafeMutableBytes { raw in
            guard let destination = raw.baseAddress else { return }
            for row in 0..<height {
                memcpy(
                    destination.advanced(by: row * width),
                    base.advanced(by: row * stride),
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

    static func write(
        sourceHDRURL: URL,
        outputURL: URL,
        analysis: AppleSemanticSceneAnalysis,
        profile: AppleSemanticWriteProfile,
        photoIdentifier: String,
        preserveOriginalBaseAndGain: Bool = true
    ) throws {
        guard let source = CGImageSourceCreateWithURL(sourceHDRURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw CLIError.invalidContainer("cannot author an incomplete semantic scaffold")
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let displayWidth = [5, 6, 7, 8].contains(orientation) ? pixelHeight : pixelWidth
        let displayHeight = [5, 6, 7, 8].contains(orientation) ? pixelWidth : pixelHeight
        let dimensions = fitWithin(width: displayWidth, height: displayHeight, maximum: 2016)
        let portraitMetadata = try makeMetadata(
            namespace: "http://ns.apple.com/portraitEffectsMatte/1.0/",
            prefix: "portraitEffectsMatte",
            versionPath: "portraitEffectsMatte:PortraitEffectsMatteVersion",
            version: "65537"
        )
        let semanticMetadata = try makeMetadata(
            namespace: "http://ns.apple.com/semanticSegmentationMatte/1.0/",
            prefix: "semanticSegmentationMatte",
            versionPath: "semanticSegmentationMatte:SemanticSegmentationMatteVersion",
            version: "65536"
        )
        var dictionaries: [(AppleSemanticRole, CFString, CFDictionary)] = []
        for role in profile.orderedRoles {
            let matte: AppleSemanticMatte?
            let type: CFString
            switch role {
            case .person:
                matte = analysis.person
                type = kCGImageAuxiliaryDataTypePortraitEffectsMatte
            case .skin:
                matte = analysis.skin
                type = kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte
            case .hair:
                matte = analysis.hair
                type = kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte
            case .teeth:
                matte = analysis.teeth
                type = kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte
            case .glasses:
                matte = analysis.glasses
                type = kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte
            case .sky:
                matte = analysis.sky
                type = kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte
            }
            guard let matte else {
                throw CLIError.invalidContainer(
                    "semantic profile \(profile.kind.rawValue) is missing \(role.rawValue)"
                )
            }
            dictionaries.append((role, type, try auxiliaryDictionary(
                matte: matte,
                width: dimensions.0,
                height: dimensions.1,
                metadata: role == .person ? portraitMetadata : semanticMetadata
            )))
        }
        guard dictionaries.count == profile.roles.count else {
            throw CLIError.invalidContainer("semantic profile \(profile.kind.rawValue) is incomplete")
        }

        let scaffoldURL = siblingScratchURL(
            for: outputURL,
            label: "semantic-scaffold",
            pathExtension: "heic"
        )
        defer { try? FileManager.default.removeItem(at: scaffoldURL) }
        guard let destination = CGImageDestinationCreateWithURL(
            scaffoldURL as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw CLIError.unableToCreateDestination(scaffoldURL)
        }
        var imageOptions: [CFString: Any] = [
            kCGImageDestinationPreserveGainMap: true,
            kCGImagePropertyOrientation: NSNumber(value: orientation),
        ]
        var makerApple: [String: Any] = [:]
        if let existing = properties[kCGImagePropertyMakerAppleDictionary] as? NSDictionary {
            for (key, value) in existing {
                makerApple[String(describing: key)] = value
            }
        }
        makerApple["43"] = photoIdentifier
        makerApple["84"] = [
            "0": 1, "1": 0, "2": 0, "3": 1,
            "4": 1, "5": 1, "6": 4, "7": 0,
        ]
        imageOptions[kCGImagePropertyMakerAppleDictionary] = makerApple
        try AppleEncodingAudit.writeAuxiliaryReferencesIfRequested(
            prefix: "semantic-scaffold",
            entries: dictionaries.map { (name: $0.0.rawValue, dictionary: $0.2) }
        )
        CGImageDestinationAddImageFromSource(destination, source, 0, imageOptions as CFDictionary)
        if let disparity = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source, 0, kCGImageAuxiliaryDataTypeDisparity
        ) {
            CGImageDestinationAddAuxiliaryDataInfo(
                destination,
                kCGImageAuxiliaryDataTypeDisparity,
                disparity
            )
        }
        for (_, type, dictionary) in dictionaries {
            CGImageDestinationAddAuxiliaryDataInfo(destination, type, dictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw CLIError.unableToFinalizeDestination(scaffoldURL)
        }
        if preserveOriginalBaseAndGain {
            try transplantPortraitBaseAndGainPayloads(
                payloadSourceURL: sourceHDRURL,
                scaffoldURL: scaffoldURL,
                outputURL: outputURL
            )
        } else {
            try FileManager.default.copyItem(at: scaffoldURL, to: outputURL)
        }
    }
}
