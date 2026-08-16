import CoreGraphics
import CoreImage
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import Vision

#if canImport(UIKit)
import XDremuxAppleFeatures

/// In-process port of the upstream `apple_vision_semantic_mattes.swift`
/// helper (Sources/XDremuxAppleFeatures/Resources/ApplePlatform/Native).
///
/// Interface parity with the macOS helper: argv[0] = input image path,
/// argv[1] = output directory, then the same options
/// (`--orientation 1...8`, `--roles ...`, `--raw-only`). Writes the same
/// `.l8` mask dumps / PNG evidence / `manifest.json` contract and prints
/// the same JSON document to "stdout".
enum AppleVisionSemanticMattes {

    static func run(arguments: [String]) throws -> AppleNativeToolchain.Result {
        do {
            let manifest = try invoke(arguments: arguments)
            let stdout = try JSONSerialization.data(
                withJSONObject: manifest, options: [.sortedKeys])
            return AppleNativeToolchain.Result(
                status: 0, stdout: stdout, stderr: Data(), timedOut: false)
        } catch {
            // The macOS helper emits {"ok": false, ...} and exits 1.
            let payload: [String: Any] = [
                "ok": false,
                "error": String(describing: error),
            ]
            let stdout = (try? JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys])) ?? Data()
            return AppleNativeToolchain.Result(
                status: 1, stdout: stdout,
                stderr: Data(String(describing: error).utf8), timedOut: false)
        }
    }

    private static func invoke(arguments: [String]) throws -> [String: Any] {
        guard arguments.count >= 2 else {
            throw HelperError.usage(
                "usage: apple-vision-semantic-mattes <input-image> <output-directory> "
                    + "[--orientation 1...8] [--roles role,...] [--raw-only]")
        }
        let inputURL = URL(fileURLWithPath: arguments[0])
        let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw HelperError.usage("input image not found: \(inputURL.path)")
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let inputData = try Data(contentsOf: inputURL, options: [.mappedIfSafe])
        let inputSHA256 = SHA256.hash(data: inputData)
            .map { String(format: "%02x", $0) }.joined()
        guard let imageSource = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
              let sourceImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw HelperError.usage("cannot decode the selected base image")
        }
        let sourceProperties =
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let metadataOrientationRaw =
            (sourceProperties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1

        let supportedRoles: Set<String> = ["portrait", "skin", "hair", "teeth", "glasses", "sky"]
        var selectedRoles = supportedRoles
        var orientationRaw = metadataOrientationRaw
        var writePNG = true
        var argumentIndex = 2
        while argumentIndex < arguments.count {
            switch arguments[argumentIndex] {
            case "--orientation":
                guard argumentIndex + 1 < arguments.count,
                      let override = UInt32(arguments[argumentIndex + 1]),
                      (1...8).contains(override) else {
                    throw HelperError.usage("--orientation must be an integer from 1 through 8")
                }
                orientationRaw = override
                argumentIndex += 2
            case "--roles":
                guard argumentIndex + 1 < arguments.count else {
                    throw HelperError.usage("--roles requires a comma-separated value")
                }
                selectedRoles = Set(
                    arguments[argumentIndex + 1].split(separator: ",").map(String.init))
                guard !selectedRoles.isEmpty, selectedRoles.isSubset(of: supportedRoles) else {
                    throw HelperError.usage("--roles contains an unsupported or empty semantic role")
                }
                argumentIndex += 2
            case "--raw-only":
                writePNG = false
                argumentIndex += 1
            default:
                throw HelperError.usage("unknown option: \(arguments[argumentIndex])")
            }
        }
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up

        let needsHumanAttributes = !selectedRoles.isDisjoint(with: ["skin", "hair", "teeth"])
        let humanAttributesRequest: VNRequest? = needsHumanAttributes
            ? (NSClassFromString("VNGenerateHumanAttributesSegmentationRequest") as? VNRequest.Type)?.init()
            : nil
        if needsHumanAttributes && humanAttributesRequest == nil {
            throw HelperError.usage(
                "VNGenerateHumanAttributesSegmentationRequest is unavailable on this OS")
        }
        let personRequest: VNGeneratePersonSegmentationRequest? = selectedRoles.contains("portrait")
            ? VNGeneratePersonSegmentationRequest()
            : nil
        personRequest?.qualityLevel = .accurate
        personRequest?.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let skyRequest: VNRequest? = selectedRoles.contains("sky")
            ? (NSClassFromString("VNGenerateSkySegmentationRequest") as? VNRequest.Type)?.init()
            : nil
        if selectedRoles.contains("sky") && skyRequest == nil {
            throw HelperError.usage("VNGenerateSkySegmentationRequest is unavailable on this OS")
        }
        let glassesRequest: VNRequest? = selectedRoles.contains("glasses")
            ? (NSClassFromString("VNGenerateGlassesSegmentationRequest") as? VNRequest.Type)?.init()
            : nil
        if selectedRoles.contains("glasses") && glassesRequest == nil {
            throw HelperError.usage("VNGenerateGlassesSegmentationRequest is unavailable on this OS")
        }
        let handler = VNImageRequestHandler(cgImage: sourceImage, orientation: orientation, options: [:])
        let requests = [humanAttributesRequest, personRequest, skyRequest, glassesRequest]
            .compactMap { $0 }
        do {
            try handler.perform(requests)
        } catch {
            throw HelperError.usage("Vision semantic segmentation failed: \(error)")
        }

        let humanAttributeObservations = humanAttributesRequest?.results?
            .compactMap({ $0 as? VNPixelBufferObservation }) ?? []
        let humanAttributesByName = Dictionary(
            uniqueKeysWithValues: humanAttributeObservations.compactMap { observation in
                observation.featureName.map { ($0, observation) }
            })

        let context = writePNG ? CIContext(options: [.cacheIntermediates: false]) : nil
        var masks: [[String: Any]] = []
        for (featureName, outputName) in [
            ("human_attribute_skin", "skin"),
            ("human_attribute_hair", "hair"),
            ("human_attribute_teeth", "teeth"),
        ] where selectedRoles.contains(outputName) {
            guard let observation = humanAttributesByName[featureName] else {
                throw HelperError.usage(
                    "Vision human-attributes request returned no \(featureName) observation")
            }
            masks.append(
                try writeMask(
                    observation,
                    name: outputName,
                    requestClass: "VNGenerateHumanAttributesSegmentationRequest",
                    revision: humanAttributesRequest?.revision ?? 0,
                    inputSHA256: inputSHA256,
                    orientation: orientation,
                    outputDirectory: outputDirectory,
                    context: context,
                    writePNG: writePNG))
        }
        if selectedRoles.contains("glasses"),
           let glassesRequest,
           let glassesObservation = glassesRequest.results?.first as? VNPixelBufferObservation {
            masks.append(
                try writeMask(
                    glassesObservation,
                    name: "glasses",
                    requestClass: "VNGenerateGlassesSegmentationRequest",
                    revision: glassesRequest.revision,
                    inputSHA256: inputSHA256,
                    orientation: orientation,
                    outputDirectory: outputDirectory,
                    context: context,
                    writePNG: writePNG))
        } else if selectedRoles.contains("glasses") {
            throw HelperError.usage("Vision glasses segmentation returned no observation")
        }
        if selectedRoles.contains("portrait"),
           let personRequest,
           let personObservation = personRequest.results?.first {
            masks.append(
                try writeMask(
                    personObservation,
                    name: "portrait",
                    requestClass: "VNGeneratePersonSegmentationRequest",
                    revision: personRequest.revision,
                    inputSHA256: inputSHA256,
                    orientation: orientation,
                    outputDirectory: outputDirectory,
                    context: context,
                    writePNG: writePNG))
        } else if selectedRoles.contains("portrait") {
            throw HelperError.usage("Vision person segmentation returned no observation")
        }
        if selectedRoles.contains("sky"),
           let skyRequest,
           let skyObservation = skyRequest.results?.first as? VNPixelBufferObservation {
            masks.append(
                try writeMask(
                    skyObservation,
                    name: "sky",
                    requestClass: "VNGenerateSkySegmentationRequest",
                    revision: skyRequest.revision,
                    inputSHA256: inputSHA256,
                    orientation: orientation,
                    outputDirectory: outputDirectory,
                    context: context,
                    writePNG: writePNG))
        } else if selectedRoles.contains("sky") {
            throw HelperError.usage("Vision sky segmentation returned no observation")
        }
        return [
            "ok": true,
            "input": inputURL.path,
            "input_sha256": inputSHA256,
            "orientation": orientationRaw,
            "orientation_transform": orientationTransform(orientation),
            "masks": masks,
            "request_count": requests.count,
            "selected_roles": selectedRoles.sorted(),
            "png_evidence": writePNG,
            "human_attribute_feature_names": humanAttributesRequest?.results?
                .compactMap({ ($0 as? VNPixelBufferObservation)?.featureName }) ?? [],
            "face_detection": [
                "status": "not_requested",
                "reason": "no production consumer",
            ],
            "api_status": [
                "person": "public Vision API",
                "skin": "private Vision SPI resolved at runtime",
                "hair": "private Vision SPI resolved at runtime",
                "teeth": "private Vision SPI resolved at runtime",
                "glasses": "private Vision SPI resolved at runtime",
                "sky": "private Vision SPI resolved at runtime",
            ],
            "claim_boundary":
                "The helper exports selected Vision masks and does not claim equivalence "
                    + "to Apple's camera-time matte tuning.",
        ]
    }

    private enum HelperError: Error {
        case usage(String)
    }

    private static func fourCC(_ value: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }

    private static func orientationTransform(_ orientation: CGImagePropertyOrientation) -> String {
        switch orientation {
        case .up: return "identity"
        case .upMirrored: return "mirror-x"
        case .down: return "rotate-180"
        case .downMirrored: return "mirror-y"
        case .leftMirrored: return "transpose"
        case .right: return "rotate-90-cw"
        case .rightMirrored: return "transverse"
        case .left: return "rotate-90-ccw"
        }
    }

    private static func writeMask(
        _ observation: VNPixelBufferObservation,
        name: String,
        requestClass: String,
        revision: Int,
        inputSHA256: String,
        orientation: CGImagePropertyOrientation,
        outputDirectory: URL,
        context: CIContext?,
        writePNG: Bool
    ) throws -> [String: Any] {
        let pixelBuffer = observation.pixelBuffer
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_OneComponent8 else {
            throw NSError(
                domain: "XDRemuxAppleSemanticAnalysis",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(name) is not an L008 pixel buffer"])
        }
        let outputURL = outputDirectory.appendingPathComponent("\(name).png")
        if writePNG {
            guard let context else {
                throw NSError(
                    domain: "XDRemuxAppleSemanticAnalysis",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "PNG evidence context is unavailable"])
            }
            try context.writePNGRepresentation(
                of: CIImage(cvPixelBuffer: pixelBuffer),
                to: outputURL,
                format: .L8,
                colorSpace: CGColorSpaceCreateDeviceGray(),
                options: [:])
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw NSError(
                domain: "XDRemuxAppleSemanticAnalysis",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "\(name) has no readable base address"])
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let source = baseAddress.assumingMemoryBound(to: UInt8.self)
        var raw = Data(count: width * height)
        var minimum = UInt8.max
        var maximum = UInt8.min
        var sum: UInt64 = 0
        var covered: UInt64 = 0
        raw.withUnsafeMutableBytes { destinationRaw in
            guard let destination = destinationRaw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<height {
                let sourceRow = source.advanced(by: y * bytesPerRow)
                let destinationRow = destination.advanced(by: y * width)
                destinationRow.update(from: sourceRow, count: width)
                for x in 0..<width {
                    let value = sourceRow[x]
                    minimum = min(minimum, value)
                    maximum = max(maximum, value)
                    sum += UInt64(value)
                    if value > 0 { covered += 1 }
                }
            }
        }
        let rawURL = outputDirectory.appendingPathComponent("\(name).l8")
        try raw.write(to: rawURL, options: .atomic)
        let count = max(1, width * height)
        var manifest: [String: Any] = [
            "name": name,
            "feature_name": observation.featureName ?? NSNull(),
            "request_class": requestClass,
            "revision": revision,
            "input_sha256": inputSHA256,
            "width": width,
            "height": height,
            "pixel_format": fourCC(CVPixelBufferGetPixelFormatType(pixelBuffer)),
            "source_bytes_per_row": bytesPerRow,
            "serialized_bytes_per_row": width,
            "raw_output": rawURL.path,
            "minimum": minimum,
            "maximum": maximum,
            "mean": Double(sum) / Double(count),
            "coverage": Double(covered) / Double(count),
            "orientation": orientation.rawValue,
            "orientation_transform": orientationTransform(orientation),
            "fallback": false,
        ]
        if writePNG {
            manifest["output"] = outputURL.path
        }
        return manifest
    }
}
#endif
