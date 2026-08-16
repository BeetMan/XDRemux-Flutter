import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import XDRemuxCore

package enum PortraitMode: String {
    case on
    case off
}

package struct PortraitFocusRegion {
    let rawX: Double
    let rawY: Double
    let rawWidth: Double
    let rawHeight: Double
}

package struct PortraitCameraCalibration {
    let profileName: String
    let renderingParametersBase64: String
    let profileAnchorEquivalentFocalLengthMM: Double
    let profileMaximumValidatedEquivalentFocalLengthMM: Double
    let physicalFocalLengthMM: Double
    let opticalEquivalentFocalLengthMM: Double
    let digitalZoomRatio: Double
    let referenceWidth: Int
    let referenceHeight: Int
    let focalLengthPixels: Double
    let effectiveFocalLengthPixels: Double
    let principalPointX: Double
    let principalPointY: Double
    let distortionCenterX: Double
    let distortionCenterY: Double
    let pixelSizeMM: Double
    let distortionCoefficients: [Double]
    let inverseDistortionCoefficients: [Double]

    var intrinsicMatrix: [Double] {
        [
            focalLengthPixels, 0, 0,
            0, focalLengthPixels, 0,
            principalPointX, principalPointY, 1,
        ]
    }
}

package struct PortraitAppleLensProfile {
    let name: String
    let anchorEquivalentFocalLengthMM: Double
    let maximumValidatedEquivalentFocalLengthMM: Double
    let referenceWidth: Int
    let referenceHeight: Int
    let focalLengthPixels: Double
    let principalPointX: Double
    let principalPointY: Double
    let distortionCenterX: Double
    let distortionCenterY: Double
    let pixelSizeMM: Double
    let distortionCoefficients: [Double]
    let inverseDistortionCoefficients: [Double]
    let renderingParametersBase64: String
}

package enum PortraitEvidence: String, Codable, Sendable {
    case oppoProducerExact = "oppo_producer_exact"
    case appleProducerExact = "apple_producer_exact"
    case appleConsumerExact = "apple_consumer_exact"
    case consumerCalibrated = "consumer_calibrated"
    case controlledCorpusFit = "controlled_corpus_fit"
    case compatibilityFallback = "compatibility_fallback"
}

package enum OPPOPortraitFocusBranch: String, Codable, Sendable {
    case tappedFace = "tapped_face"
    case portraitFace = "portrait_face"
    case portraitWithoutFace = "portrait_without_face"
    case petFace = "pet_face"
    case petRegion = "pet_region"
    case nearObject = "near_object"
    case tappedRegion = "tapped_region"
    case centerRegion = "center_region"
    case disparityHistogram = "disparity_histogram"
}

package struct OPPOPortraitFace: Codable, Sendable {
    let rectangle: [Int]
    let angle: Int
    let keyPointX: [Int]
    let keyPointY: [Int]
    let keyPointConfidence: [Int]
}

package struct OPPOPortraitConfig: Codable, Sendable {
    let version: Double
    let declaredProcessingCanvasWidth: Int
    let declaredProcessingCanvasHeight: Int
    let focusX: Int
    let focusY: Int
    let blurApertures: [Double]
    let blurValues: [Double]
    let currentBlurStrength: Int
    let cameraRoll: Int
    let spotlightWidth: Int?
    let spotlightHeight: Int?
    let currentFNumber: Double?
    let objectDistance: Int?
    let teleMaster: Bool?
    let focusRectangle: [Int]?
    let focusRectangleIsValid: Bool
    let mirrorEnabled: Bool?
    let refocusMode: Int?
    let foregroundBlurScale: Int?
    let bigFaceEnabled: Bool?
    let petsEnabled: Bool?
    let multiSemanticSegmentationEnabled: Bool?
    let bokehVersion: Int?
    let iso: Int?
    let zoomRatio: Int?
    let focusROIType: Int?
    let shutter: Double?
    let aecLuxIndex: Double?
    let faces: [OPPOPortraitFace]
    let evidence: PortraitEvidence
}

package struct PortraitDepthHeader: Codable, Sendable {
    let width: Int
    let height: Int
    let rankDisparityScale: Double
    let focalLengthPixels: Double
    let stereoBaseline: Double
    let hairPlanePresent: Bool
    let portraitPlanePresent: Bool
    let petPlanePresent: Bool
    let nearObjectDetected: Bool
    let nearObjectConfidence: Double?
    let plantObjectState: Int
    let disparityMinimum: UInt16
    let disparityMaximum: UInt16
    let disparityExponentiation: Int
    let auxiliaryWidth: Int?
    let auxiliaryHeight: Int?
    let modelOutputPresent: Bool
    let sceneClass: Int?
    let objectDistance: Int?
    let aecLuxIndex: Double?
    let appZoomRatio: Double?
    let evidence: PortraitEvidence

    func internalDisparity(forRank rank: Double) -> Double? {
        guard (1...2).contains(disparityExponentiation), rank.isFinite else { return nil }
        let minimum = Double(disparityMinimum)
        let maximum = Double(disparityMaximum)
        guard maximum > minimum else { return nil }
        let normalized = pow(min(max(rank / 255.0, 0), 1), Double(disparityExponentiation))
        // This remains explicitly in OPPO's producer domain. The firmware
        // quantizes 65535 - internalDisp16 and does not establish Apple units.
        return 65_535.0 - (minimum + normalized * (maximum - minimum))
    }

    func nativeFloatDepth(forRank rank: Double) -> Double? {
        guard let internalDisparity = internalDisparity(forRank: rank),
              internalDisparity.isFinite,
              internalDisparity >= 0 else { return nil }
        // GetBlurmapEngine::getBlurmap reconstructs the float_image_t passed
        // to CalFocusDepthEngine with this producer formula, including the
        // 1e-5 denominator floor and 140000 depth cap.
        let denominator = max(internalDisparity * rankDisparityScale, 0.00001)
        return min(focalLengthPixels * stereoBaseline / denominator, 140_000.0)
    }

    func rank(forNativeFloatDepth depth: Double) -> Double? {
        guard depth.isFinite,
              depth > 0,
              rankDisparityScale > 0,
              focalLengthPixels > 0,
              stereoBaseline > 0 else { return nil }
        let minimum = Double(disparityMinimum)
        let maximum = Double(disparityMaximum)
        guard maximum > minimum else { return nil }
        let internalDisparity = (focalLengthPixels * stereoBaseline / depth) / rankDisparityScale
        let normalized = (65_535.0 - internalDisparity - minimum) / (maximum - minimum)
        let clamped = min(max(normalized, 0), 1)
        return 255.0 * pow(clamped, 1.0 / Double(disparityExponentiation))
    }
}

package struct ApplePortraitRenderProfile: Codable, Sendable {
    let identifier: String
    let physicalLensFamily: String
    let validatedEquivalentFocalRange: [Double]
    let staticRecordIdentifiers: [String]
    let evidence: PortraitEvidence
}

package struct AppleXHLRBControlConfig: Codable, Sendable {
    let mode: Int
    let exposureScoreT0: Double
    let exposureScoreT1: Double
    let clippedPixelsT0: Double
    let clippedPixelsT1: Double
    let recoveryScoreT: Double
    let maxColourDiffusionIterations: Int
    let maxPreFilterGain: Double
    let maxWeightGain: Double
    let maxIntensityGain: Double
    let maxObscenePreFilterGain: Double
    let maxObsceneWeightGain: Double
    let maxObsceneIntensityGain: Double
    let maxBGBlur: Double
    let blurRadiusT0: Double
    let blurRadiusT1: Double
    let maxIntensityT0: Double
    let maxIntensityT1: Double
    let minIntensityT0: Double
    let minIntensityT1: Double

    static let firmwareDefault = AppleXHLRBControlConfig(
        mode: 0,
        exposureScoreT0: 1.0,
        exposureScoreT1: 5.0,
        clippedPixelsT0: 0.1,
        clippedPixelsT1: 1.0,
        recoveryScoreT: 0.5,
        maxColourDiffusionIterations: 50,
        maxPreFilterGain: 0.0,
        maxWeightGain: 0.0,
        maxIntensityGain: 0.0,
        maxObscenePreFilterGain: 0.0,
        maxObsceneWeightGain: 0.0,
        maxObsceneIntensityGain: 0.0,
        maxBGBlur: 0.03,
        blurRadiusT0: 0.0025,
        blurRadiusT1: 0.0075,
        maxIntensityT0: 0.9,
        maxIntensityT1: 1.0,
        minIntensityT0: 0.0,
        minIntensityT1: 1.0
    )
}

package struct AppleSimpleLensModelConfig: Codable, Sendable {
    let fallbackFocusROI: [Double]
    let zeroShiftPercentile: Double
    let simulatedFocalLength: Double
    let simulatedAperture: Double
    let minimumSimulatedAperture: Double
    let maximumSimulatedAperture: Double
    let frameNormalizedFocalLength: Double
    let maxFGBlur: Double
    let maxBGBlur: Double
    let shiftDeadZone: Double
    let disparityScalingFactor: Double

    static let firmwareDefault = AppleSimpleLensModelConfig(
        fallbackFocusROI: [0.45, 0.45, 0.1, 0.1],
        zeroShiftPercentile: 0.67,
        simulatedFocalLength: 50.0,
        simulatedAperture: 5.6,
        minimumSimulatedAperture: 0.0,
        maximumSimulatedAperture: 0.0,
        frameNormalizedFocalLength: 6_600.0,
        maxFGBlur: 0.005,
        maxBGBlur: 0.03,
        shiftDeadZone: Double(Float(bitPattern: 0x3e560419)),
        disparityScalingFactor: 1.0
    )
}

package struct AppleXHLRBProducerState: Codable, Sendable {
    let isoSpeedRating: Double?
    let exposureTimeRaw: Double?
    let exposureProductRaw: Double?
    let gainMapHeadroom: Double
    let sceneActivation: Double
    let firmwareDefaultControlConfig: AppleXHLRBControlConfig
    let firmwareDefaultSimpleLensModelConfig: AppleSimpleLensModelConfig
    let metadataKeysEvidence: PortraitEvidence
    let controlFormulaEvidence: PortraitEvidence
    let firmwareDefaultConfigEvidence: PortraitEvidence
    let activeRenderingOverrideEvidence: PortraitEvidence
    let tuningMaximaEvidence: PortraitEvidence
    let sceneActivationEvidence: PortraitEvidence
}

package struct AppleXHLRBControlOutput: Sendable {
    let dynamicValues: [UInt16: Double]

    static func make(
        profileIsOneX: Bool,
        sceneActivation: Double,
        gainMapHeadroom: Double
    ) -> AppleXHLRBControlOutput {
        // Recovered from ControlLogicForXHLRB in iOS 26.5 build 23F84.
        // The maxima are the native tuning values exposed by saturated
        // controlled captures. The only input that remains calibrated rather
        // than producer-exact is sceneActivation (exposure score × clipped
        // pixel recovery score).
        let activation = clamp(sceneActivation, min: 0.0, max: 1.0)
        let headroom = max(gainMapHeadroom, 0.0)
        let headroomFactor = min(headroom, 4.0) / 4.0
        let maximumIntensityGain = profileIsOneX ? 0.25 : 0.10
        let maximumObsceneWeightGain = profileIsOneX ? 20.0 : 23.0
        let maximumObsceneIntensityGain = profileIsOneX ? 0.60 : 0.70
        let secondaryActivation = activation * headroomFactor
        return AppleXHLRBControlOutput(dynamicValues: [
            0x0190: Double(Int((50.0 * activation).rounded(.toNearestOrAwayFromZero))),
            0x0191: 0.25 * activation,
            0x0192: 12.0 * activation,
            0x0193: maximumIntensityGain * activation,
            0x0194: 0,
            0x0195: 0,
            0x0196: 0,
            0x0197: 0,
            0x0198: 0,
            0x0199: 0,
            0x01c2: 8.0 * secondaryActivation,
            0x01c3: maximumObsceneWeightGain * secondaryActivation,
            0x01c4: maximumObsceneIntensityGain * secondaryActivation,
            0x01c5: headroom,
        ])
    }
}

package struct ApplePortraitRenderSceneState: Codable, Sendable {
    let focusBranch: OPPOPortraitFocusBranch
    let focusDisparity: Double
    let measuredDepth: Double?
    let nearObjectState: OPPONearObjectState
    let foregroundState: Double
    let backgroundState: Double
    let xhlrbProducerState: AppleXHLRBProducerState
    let dynamicRecords: [String: Double]
    let evidence: PortraitEvidence
}

package struct PortraitTranslationManifest: Codable, Sendable {
    let schema: String
    let inputSHA256: String
    let oppoFirmwareBuild: String
    let appleFirmwareBuild: String
    let config: OPPOPortraitConfig
    let depthHeader: PortraitDepthHeader
    let focus: OPPOPortraitFocusSelection
    let blurResponse: OPPOPortraitBlurResponse
    let appleProfile: ApplePortraitRenderProfile
    let appleSceneState: ApplePortraitRenderSceneState
    let appleWrittenDisparityRange: [Double]
    let finalRENDSHA256: String
    let staticRENDRecords: [String]
    let dynamicRENDRecords: [String: Double]
    let nativeGenerator: String
    let fallbacks: [String]
    let warnings: [String]
}

package struct SourceDerivedRENDResult: Sendable {
    let base64: String
    let rawData: Data
    let staticRecordIdentifiers: [String]
    let dynamicRecords: [String: Double]
    let sceneState: ApplePortraitRenderSceneState
    let nativeGenerator: String
    let warnings: [String]
}

package struct OPPOPortraitFocusSelection: Codable, Sendable {
    let branch: OPPOPortraitFocusBranch
    let branchEvidence: PortraitEvidence
    let sourceROI: [Double]
    let depthROI: [Double]
    let roiEvidence: PortraitEvidence
    let selectedRank: Double
    let internalDisparity: Double?
    let configDistance: Double?
    let confidence: Double
    let sampleCount: Int
    let rejectedSampleCount: Int
    let statisticEvidence: PortraitEvidence
    let evidence: PortraitEvidence
}

package struct OPPONearObjectState: Codable, Sendable {
    let detected: Bool
    let confidence: Double?
    let region: [Double]?
    let nativeFocusContribution: Double?
    let evidence: PortraitEvidence
}

package struct OPPOPortraitBlurResponse: Codable, Sendable {
    let apertures: [Double]
    let blurValues: [Double]
    let selectedAperture: Double
    let selectedBlurValue: Double
    let foregroundBlurScale: Double
    let zoomRegion: String
    let evidence: PortraitEvidence
}

package struct AppleRENDRecord: Equatable, Codable, Sendable {
    let identifier: UInt16
    let valueType: UInt16
    let rawValue: UInt32

    var floatValue: Float? {
        valueType == 1 ? Float(bitPattern: rawValue) : nil
    }
}

package struct AppleRENDDocument: Equatable, Sendable {
    let version: UInt32
    let sectionVersion: UInt32
    let records: [AppleRENDRecord]

    static func parse(_ data: Data) throws -> AppleRENDDocument {
        guard data.count >= 16, data.prefix(4) == Data("REND".utf8) else {
            throw CLIError.invalidContainer("REND is missing its 16-byte header")
        }
        func u16(_ offset: Int) -> UInt16 {
            UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(data[offset])
                | UInt32(data[offset + 1]) << 8
                | UInt32(data[offset + 2]) << 16
                | UInt32(data[offset + 3]) << 24
        }
        let declaredLength = Int(u32(8))
        guard declaredLength == data.count,
              declaredLength >= 16,
              (declaredLength - 16).isMultiple(of: 8) else {
            throw CLIError.invalidContainer("REND declared length or record alignment is invalid")
        }
        var records: [AppleRENDRecord] = []
        var identifiers = Set<UInt16>()
        var cursor = 16
        while cursor < declaredLength {
            let identifier = u16(cursor)
            let type = u16(cursor + 2)
            guard (1...4).contains(type) else {
                throw CLIError.invalidContainer(
                    String(format: "REND record 0x%04x uses unsupported type %u", identifier, type)
                )
            }
            guard identifiers.insert(identifier).inserted else {
                // The producer builder is dictionary-backed: setting one ID
                // replaces its prior value, and encoded output cannot contain
                // duplicates. Reject them instead of silently choosing a value.
                throw CLIError.invalidContainer(
                    String(format: "REND contains duplicate record 0x%04x", identifier)
                )
            }
            records.append(AppleRENDRecord(
                identifier: identifier,
                valueType: type,
                rawValue: u32(cursor + 4)
            ))
            cursor += 8
        }
        return AppleRENDDocument(
            version: u32(4),
            sectionVersion: u32(12),
            records: records
        )
    }

    func serialized(sorted: Bool = false) -> Data {
        let outputRecords = sorted ? records.sorted { lhs, rhs in
            Int16(bitPattern: lhs.identifier) < Int16(bitPattern: rhs.identifier)
        } : records
        var output = Data("REND".utf8)
        func append(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { output.append(contentsOf: $0) }
        }
        func append(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { output.append(contentsOf: $0) }
        }
        append(version)
        append(UInt32(16 + outputRecords.count * 8))
        append(sectionVersion)
        for record in outputRecords {
            append(record.identifier)
            append(record.valueType)
            append(record.rawValue)
        }
        return output
    }

    func replacing(_ replacements: [UInt16: AppleRENDRecord]) -> AppleRENDDocument {
        var emitted = Set<UInt16>()
        var updated: [AppleRENDRecord] = records.compactMap { record in
            if let replacement = replacements[record.identifier] {
                emitted.insert(record.identifier)
                return replacement
            }
            return record
        }
        updated.append(contentsOf: replacements.values.filter { !emitted.contains($0.identifier) })
        return AppleRENDDocument(version: version, sectionVersion: sectionVersion, records: updated)
    }
}

package struct OPPODepthPlanes {
    let width: Int
    let height: Int
    let ranks: Data
    let hair: Data?
    let portrait: Data?
    let pet: Data?

    var subject: Data? {
        let candidates = [portrait, pet].compactMap { plane in
            plane.flatMap { $0.contains(where: { $0 != 0 }) ? $0 : nil }
        }
        guard var fused = candidates.first else { return nil }
        let pixelCount = fused.count
        for plane in candidates.dropFirst() {
            fused.withUnsafeMutableBytes { output in
                plane.withUnsafeBytes { input in
                    guard let outputBase = output.bindMemory(to: UInt8.self).baseAddress,
                          let inputBase = input.bindMemory(to: UInt8.self).baseAddress else { return }
                    for index in 0..<pixelCount {
                        outputBase[index] = max(outputBase[index], inputBase[index])
                    }
                }
            }
        }
        return fused
    }

    var validHair: Data? {
        hair.flatMap { $0.contains(where: { $0 != 0 }) ? $0 : nil }
    }
}
