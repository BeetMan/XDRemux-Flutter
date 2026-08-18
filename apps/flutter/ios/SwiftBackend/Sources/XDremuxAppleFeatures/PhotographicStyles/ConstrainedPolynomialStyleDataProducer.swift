import CoreGraphics
import Dispatch
import Foundation
import ImageIO
import XDRemuxCore

package struct ConstrainedPolynomialStyleDataProducer {
    private static let solverAdmission = DispatchSemaphore(value: 1)
    private static let directParameterIndices = [0, 1, 2, 3, 7, 11]
    private static let solverRefinementParameterNames = [
        "constantToR", "constantToG", "constantToB",
        "RToR", "RToG", "RToB",
        "GToR", "GToG", "GToB",
        "BToR", "BToG", "BToB",
    ]
    private static let solverRefinementParameterIndices = Array(0..<12)
    private static let basisNames = [
        "constant", "R", "G", "B", "R2", "RG", "RB", "G2", "GB", "B2",
    ]
    private static let outputNames = ["R", "G", "B"]
    private static let epsilon = 1.0 / 32.0
    private static let linearBound = 1.0 / 8.0
    private static let quadraticBound = 1.0 / 16.0
    private static let iterationCount = 2
    private static let lineSearchScales = [1.0, 0.5, 0.25, 0.125]
    private static let analysisMaximumDimension = 1024
    private static let nativeIncrementEnvelopeRMSE8: [String: Double] = [
        "tone": 9.6,
        "color": 8.8,
        "combined": 10.2,
        "intensity": 8.0,
    ]
    private static let nativeIncrementSegmentEnvelopeRMSE8: [String: Double] = [
        "tone": 10.4,
        "color": 7.8,
        "combined": 13.0,
        "intensity": 5.6,
    ]
    private static let nativeIncrementCurvatureEnvelopeRMSE8: [String: Double] = [
        "tone": 18.8,
        "color": 7.0,
        "combined": 23.6,
        "intensity": 3.6,
    ]
    // Stage A (response-v6): native editor-response envelope terms.
    // Constants and provenance: docs/plans/active/
    // apple-styles-editor-response-optimization-20260726.md section 1.
    private static let responseHueLowerBoundDegrees = -1.702725
    private static let responseHueUpperBoundDegrees = 19.16482
    private static let responseRGLowerBound = -0.47665203
    private static let responseRGUpperBound = 0.09553468
    private static let responseHueMarginDegrees = 0.30
    private static let responseRGMargin = 0.005
    package static let responseMinimumROIPixels = 500

    private static func responseEnvironmentDouble(_ name: String, _ fallback: Double) -> Double {
        guard let raw = ProcessInfo.processInfo.environment[name],
              let value = Double(raw), value.isFinite, value >= 0 else { return fallback }
        return value
    }
    private static var responseObjectiveEnabled: Bool {
        ProcessInfo.processInfo.environment["XDREMUX_STYLE_RESPONSE_OBJECTIVE"] != "off"
    }
    private static var responseHueWeight: Double {
        responseEnvironmentDouble("XDREMUX_STYLE_RESPONSE_HUE_WEIGHT", 4.0)
    }
    private static var responseRGWeight: Double {
        responseEnvironmentDouble("XDREMUX_STYLE_RESPONSE_RG_WEIGHT", 10_000)
    }
    private static var responseScoreHueWeight: Double {
        responseEnvironmentDouble("XDREMUX_STYLE_RESPONSE_SCORE_HUE_WEIGHT", 0.6)
    }
    private static var responseScoreRGWeight: Double {
        responseEnvironmentDouble("XDREMUX_STYLE_RESPONSE_SCORE_RG_WEIGHT", 60)
    }

    private struct Raster {
        let width: Int
        let height: Int
        let rgb: [Float]
    }

    private struct Metrics {
        let rmse8: Double
        let mae8: Double
        let maximumAbsolute8: Double

        var dictionary: [String: Any] {
            [
                "rmse8": rmse8,
                "mae8": mae8,
                "maximumAbsolute8": maximumAbsolute8,
            ]
        }
    }

    private struct StyleSetting {
        let tone: Double
        let color: Double
        let intensity: Double
        let cast: String
    }

    private struct ResponsePair {
        let name: String
        let minus: StyleSetting
        let midpoint: StyleSetting
        let plus: StyleSetting
    }

    private static let responseMidSetting = StyleSetting(
        tone: 0, color: 1, intensity: 1, cast: "Standard"
    )
    private static let responsePlusSetting = StyleSetting(
        tone: 1, color: 1, intensity: 1, cast: "Standard"
    )

    package struct ResponseSkinMask {
        let width: Int
        let height: Int
        let samples: [UInt8]

        package init(width: Int, height: Int, samples: [UInt8]) {
            self.width = width
            self.height = height
            self.samples = samples
        }
    }

    package struct ResponseMetricSample {
        package let hueDegrees: Double
        package let rgRatio: Double
        package let roiPixelCount: Int
        package let roiKind: String
    }

    package struct ResponseObjectiveState {
        package let hueDeltaDegrees: Double
        package let rgDelta: Double
        package let hueViolationDegrees: Double
        package let rgViolation: Double
        package let roiKind: String
        package let roiPixelCount: Int

        package var hingeScore: Double { hueViolationDegrees + rgViolation }

        var dictionary: [String: Any] {
            [
                "hueDeltaDegrees": hueDeltaDegrees,
                "rgDelta": rgDelta,
                "hueViolationDegrees": hueViolationDegrees,
                "rgViolation": rgViolation,
                "roiKind": roiKind,
                "roiPixelCount": roiPixelCount,
            ]
        }
    }

    private struct RenderRequest {
        let heicURL: URL
        let outputDirectory: URL
        let label: String
        let enabled: Bool
        let tone: Double
        let color: Double
        let intensity: Double
        let cast: String

        init(
            heicURL: URL,
            outputDirectory: URL,
            label: String,
            enabled: Bool,
            tone: Double = 0,
            color: Double = 0,
            intensity: Double = 1,
            cast: String = "Standard"
        ) {
            self.heicURL = heicURL
            self.outputDirectory = outputDirectory
            self.label = label
            self.enabled = enabled
            self.tone = tone
            self.color = color
            self.intensity = intensity
            self.cast = cast
        }

        var pngURL: URL { outputDirectory.appendingPathComponent("\(label).png") }
        var manifestURL: URL { outputDirectory.appendingPathComponent("\(label).json") }

        var dictionary: [String: Any] {
            [
                "photo": heicURL.path,
                "output": pngURL.path,
                "manifest": manifestURL.path,
                "tone": tone,
                "color": color,
                "intensity": intensity,
                "enabled": enabled,
                "maximumDimension": analysisMaximumDimension,
                "cast": cast,
            ]
        }
    }

    package func makeStyleData(
        preliminaryHEICURL: URL,
        identityStylePropertyList: Data,
        outputDirectory: URL,
        skinMask: ResponseSkinMask? = nil,
        forceResponseTerms: Bool = false
    ) throws -> AppleStyleDataResult {
        let admissionStartedAt = CFAbsoluteTimeGetCurrent()
        Self.solverAdmission.wait()
        let admissionWaitSeconds = CFAbsoluteTimeGetCurrent() - admissionStartedAt
        defer { Self.solverAdmission.signal() }
        let solverStartedAt = CFAbsoluteTimeGetCurrent()
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let executable = try AppleNativeToolchain.learnExecutable()
        let identityCoefficients = Array(
            repeating: 0.0,
            count: AppleStyleDataLayout.blockValueCount
        )
        let initializationDirectory = outputDirectory.appendingPathComponent("initialization")
        let identityHEICURL = try Self.materialize(
            baseHEICURL: preliminaryHEICURL,
            identityStylePropertyList: identityStylePropertyList,
            coefficientDeltas: identityCoefficients,
            outputDirectory: initializationDirectory,
            label: "identity"
        )
        let initialRasters = try Self.render(
            executable: executable,
            requests: [
                RenderRequest(
                    heicURL: preliminaryHEICURL,
                    outputDirectory: outputDirectory.appendingPathComponent("target"),
                    label: "disabled",
                    enabled: false
                ),
                RenderRequest(
                    heicURL: identityHEICURL,
                    outputDirectory: initializationDirectory,
                    label: "identity",
                    enabled: true
                ),
            ]
        )
        guard initialRasters.count == 2 else {
            throw CLIError.invalidContainer("constrained key-1 renderer returned an incomplete initial batch")
        }
        let target = initialRasters[0]
        let identityRender = (heicURL: identityHEICURL, raster: initialRasters[1])
        let identityMetrics = Self.metrics(identityRender.raster, target)

        // Stage A (response-v6): tone@color100 editor-response objective.
        // Native envelope provenance: docs/plans/active/
        // apple-styles-editor-response-optimization-20260726.md section 1.
        let responseSettingPairs: [(side: String, setting: StyleSetting)] = [
            ("resp-mid", Self.responseMidSetting),
            ("resp-plus", Self.responsePlusSetting),
        ]
        func responseRequests(
            heicURL: URL,
            outputDirectory: URL,
            labelPrefix: String
        ) -> [RenderRequest] {
            responseSettingPairs.map { pair in
                RenderRequest(
                    heicURL: heicURL,
                    outputDirectory: outputDirectory,
                    label: "\(labelPrefix)-\(pair.side)",
                    enabled: true,
                    tone: pair.setting.tone,
                    color: pair.setting.color,
                    intensity: pair.setting.intensity,
                    cast: pair.setting.cast
                )
            }
        }
        var responseDisabledReason: String? = Self.responseObjectiveEnabled ? nil : "env-off"
        var identityResponse: ResponseObjectiveState?
        func responseState(mid: Raster, plus: Raster) -> ResponseObjectiveState {
            Self.substitutingVanishedROI(
                Self.responseObjectiveState(
                    plus: Self.responseMetricSample(
                        rgb8: plus.rgb, width: plus.width, height: plus.height, mask: skinMask
                    ),
                    mid: Self.responseMetricSample(
                        rgb8: mid.rgb, width: mid.width, height: mid.height, mask: skinMask
                    )
                ),
                identity: identityResponse
            )
        }
        if Self.responseObjectiveEnabled {
            let identityResponseRasters = try Self.render(
                executable: executable,
                requests: responseRequests(
                    heicURL: identityHEICURL,
                    outputDirectory: initializationDirectory,
                    labelPrefix: "identity"
                )
            )
            guard identityResponseRasters.count == 2 else {
                throw CLIError.invalidContainer(
                    "constrained key-1 renderer returned an incomplete identity response batch"
                )
            }
            let state = responseState(
                mid: identityResponseRasters[0],
                plus: identityResponseRasters[1]
            )
            if state.roiKind == "none" {
                responseDisabledReason = "no-eligible-roi"
            } else {
                identityResponse = state
            }
        }
        let responseMeasured = identityResponse != nil
        // Compliant fast path: renders are GPU-serialized (~0.4-0.5s each), so
        // hinge terms only pay for their per-candidate response renders when
        // the same-photo identity control already violates the native
        // envelope.  Compliant scenes run the v5 flow and verify only the
        // winning candidate; a detected regression escalates once into the
        // full hinge objective.
        let responseActive = responseMeasured
            && (forceResponseTerms || (identityResponse?.hingeScore ?? 0) > 1e-9)

        let analyticCoefficients = try Self.fitGlobalPolynomial(
            sourceRGB8: identityRender.raster.rgb,
            targetRGB8: target.rgb
        )
        var coefficients = identityCoefficients
        var bestCoefficients = identityCoefficients
        var bestMetrics = identityMetrics
        var bestResponse = identityResponse
        var bestScore = Self.responseScore(rmse8: identityMetrics.rmse8, state: identityResponse)
        var iterationRows: [[String: Any]] = []
        var initializationCandidates: [[String: Any]] = []

        var initializationWork: [(
            scale: Double,
            coefficients: [Double],
            requests: [RenderRequest]
        )] = []
        for scale in Self.lineSearchScales {
            let candidate = analyticCoefficients.map { $0 * scale }
            let label = String(format: "global-quadratic-s%03d", Int(scale * 100))
            let heicURL = try Self.materialize(
                baseHEICURL: preliminaryHEICURL,
                identityStylePropertyList: identityStylePropertyList,
                coefficientDeltas: candidate,
                outputDirectory: initializationDirectory,
                label: label
            )
            var requests = [
                RenderRequest(
                    heicURL: heicURL,
                    outputDirectory: initializationDirectory,
                    label: label,
                    enabled: true
                ),
            ]
            if responseActive {
                requests += responseRequests(
                    heicURL: heicURL,
                    outputDirectory: initializationDirectory,
                    labelPrefix: label
                )
            }
            initializationWork.append((
                scale: scale,
                coefficients: candidate,
                requests: requests
            ))
        }
        let initializationRasters = try Self.render(
            executable: executable,
            requests: initializationWork.flatMap(\.requests)
        )
        // The renderer is a pure function of the materialized candidate, so the
        // raster rendered for the currently selected coefficients is carried
        // forward instead of re-materializing and re-rendering it per iteration.
        var latestRendered: (coefficients: [Double], raster: Raster) = (
            identityCoefficients,
            identityRender.raster
        )
        var latestResponse = identityResponse
        var initializationCursor = 0
        for work in initializationWork {
            guard initializationCursor + work.requests.count <= initializationRasters.count else {
                throw CLIError.invalidContainer(
                    "constrained key-1 renderer returned an incomplete initialization batch"
                )
            }
            let raster = initializationRasters[initializationCursor]
            let candidateResponse: ResponseObjectiveState? = responseActive
                ? responseState(
                    mid: initializationRasters[initializationCursor + 1],
                    plus: initializationRasters[initializationCursor + 2]
                )
                : nil
            initializationCursor += work.requests.count
            let candidateMetrics = Self.metrics(raster, target)
            let candidateScore = Self.responseScore(
                rmse8: candidateMetrics.rmse8,
                state: candidateResponse
            )
            var candidateRow: [String: Any] = [
                "scale": work.scale,
                "metrics": candidateMetrics.dictionary,
                "score": candidateScore,
            ]
            if let candidateResponse {
                candidateRow["response"] = candidateResponse.dictionary
            }
            initializationCandidates.append(candidateRow)
            if candidateScore < bestScore {
                bestScore = candidateScore
                bestMetrics = candidateMetrics
                bestCoefficients = work.coefficients
                bestResponse = candidateResponse
                coefficients = work.coefficients
                latestRendered = (work.coefficients, raster)
                latestResponse = candidateResponse
            }
        }
        let initializationCompletedAt = CFAbsoluteTimeGetCurrent()

        var initializationRow: [String: Any] = [
            "stage": "analytic-global-quadratic-initialization",
            "identityMetrics": identityMetrics.dictionary,
            "lineSearchCandidates": initializationCandidates,
            "selectedMetrics": bestMetrics.dictionary,
            "selectedScore": bestScore,
            "accepted": bestMetrics.rmse8 < identityMetrics.rmse8,
            "coefficientDeltas": Self.coefficientDictionary(analyticCoefficients),
            "responseObjectiveActive": responseActive,
        ]
        if let identityResponse {
            initializationRow["identityResponse"] = identityResponse.dictionary
        }
        iterationRows.append(initializationRow)

        for iteration in 0..<Self.iterationCount {
            let iterationDirectory = outputDirectory.appendingPathComponent(
                String(format: "iteration-%02d", iteration),
                isDirectory: true
            )
            let currentRaster: Raster
            var currentResponse = latestResponse
            if latestRendered.coefficients == coefficients {
                currentRaster = latestRendered.raster
            } else {
                let heicURL = try Self.materialize(
                    baseHEICURL: preliminaryHEICURL,
                    identityStylePropertyList: identityStylePropertyList,
                    coefficientDeltas: coefficients,
                    outputDirectory: iterationDirectory,
                    label: "current"
                )
                var requests = [
                    RenderRequest(
                        heicURL: heicURL,
                        outputDirectory: iterationDirectory,
                        label: "current",
                        enabled: true
                    ),
                ]
                if responseActive {
                    requests += responseRequests(
                        heicURL: heicURL,
                        outputDirectory: iterationDirectory,
                        labelPrefix: "current"
                    )
                }
                let rasters = try Self.render(executable: executable, requests: requests)
                guard rasters.count == requests.count else {
                    throw CLIError.invalidContainer(
                        "constrained key-1 renderer returned an incomplete current batch"
                    )
                }
                currentRaster = rasters[0]
                if responseActive {
                    currentResponse = responseState(mid: rasters[1], plus: rasters[2])
                }
            }
            let beforeMetrics = Self.metrics(currentRaster, target)
            let beforeScore = Self.responseScore(rmse8: beforeMetrics.rmse8, state: currentResponse)
            if beforeScore < bestScore {
                bestScore = beforeScore
                bestMetrics = beforeMetrics
                bestCoefficients = coefficients
                bestResponse = currentResponse
            }

            var derivativeWork: [(
                refinementIndex: Int,
                coefficientIndex: Int,
                step: Double,
                requests: [RenderRequest]
            )] = []
            let jacobianDirectory = iterationDirectory.appendingPathComponent(
                "jacobian",
                isDirectory: true
            )
            for (refinementIndex, coefficientIndex) in Self.solverRefinementParameterIndices.enumerated() {
                var perturbed = coefficients
                let bound = Self.bound(forCoefficientIndex: coefficientIndex)
                var step = min(bound, coefficients[coefficientIndex] + Self.epsilon)
                    - coefficients[coefficientIndex]
                if step <= 0 {
                    step = max(-bound, coefficients[coefficientIndex] - Self.epsilon)
                        - coefficients[coefficientIndex]
                }
                perturbed[coefficientIndex] += step
                let label = Self.solverRefinementParameterNames[refinementIndex]
                let heicURL = try Self.materialize(
                    baseHEICURL: preliminaryHEICURL,
                    identityStylePropertyList: identityStylePropertyList,
                    coefficientDeltas: perturbed,
                    outputDirectory: jacobianDirectory,
                    label: label
                )
                var requests = [
                    RenderRequest(
                        heicURL: heicURL,
                        outputDirectory: jacobianDirectory,
                        label: label,
                        enabled: true
                    ),
                ]
                if responseActive {
                    requests += responseRequests(
                        heicURL: heicURL,
                        outputDirectory: jacobianDirectory,
                        labelPrefix: label
                    )
                }
                derivativeWork.append((
                    refinementIndex: refinementIndex,
                    coefficientIndex: coefficientIndex,
                    step: step,
                    requests: requests
                ))
            }
            let derivativeRasters = try Self.render(
                executable: executable,
                requests: derivativeWork.flatMap(\.requests)
            )
            var derivatives: [[Float]] = []
            var derivativeRows: [[String: Any]] = []
            let parameterCount = Self.solverRefinementParameterNames.count
            var hueDerivative = Array(repeating: 0.0, count: parameterCount)
            var rgDerivative = Array(repeating: 0.0, count: parameterCount)
            var derivativeCursor = 0
            for work in derivativeWork {
                guard derivativeCursor + work.requests.count <= derivativeRasters.count else {
                    throw CLIError.invalidContainer(
                        "constrained key-1 renderer returned an incomplete Jacobian batch"
                    )
                }
                let rendered = derivativeRasters[derivativeCursor]
                let perturbedResponse: ResponseObjectiveState? = responseActive
                    ? responseState(
                        mid: derivativeRasters[derivativeCursor + 1],
                        plus: derivativeRasters[derivativeCursor + 2]
                    )
                    : nil
                derivativeCursor += work.requests.count
                guard rendered.rgb.count == currentRaster.rgb.count else {
                    throw CLIError.invalidContainer(
                        "constrained key-1 renderer returned inconsistent raster dimensions"
                    )
                }
                let derivative = zip(rendered.rgb, currentRaster.rgb).map {
                    ($0 - $1) / Float(work.step)
                }
                derivatives.append(derivative)
                let derivativeRMS = sqrt(
                    derivative.reduce(0.0) { $0 + Double($1 * $1) }
                        / Double(max(1, derivative.count))
                )
                var derivativeRow: [String: Any] = [
                    "parameter": Self.solverRefinementParameterNames[work.refinementIndex],
                    "coefficientIndex": work.coefficientIndex,
                    "step": work.step,
                    "derivativeRMS8": derivativeRMS,
                    "metricsAgainstDisabled": Self.metrics(rendered, target).dictionary,
                ]
                if let perturbedResponse, let currentResponse {
                    // A vanished-ROI state carries substituted identity values,
                    // not a measured response; it contributes no derivative.
                    let measurable = perturbedResponse.roiKind != "roi-vanished"
                        && currentResponse.roiKind != "roi-vanished"
                    if measurable {
                        hueDerivative[work.refinementIndex] = Self.wrappedDegrees(
                            perturbedResponse.hueDeltaDegrees - currentResponse.hueDeltaDegrees
                        ) / work.step
                        rgDerivative[work.refinementIndex] =
                            (perturbedResponse.rgDelta - currentResponse.rgDelta) / work.step
                    }
                    derivativeRow["response"] = perturbedResponse.dictionary
                    derivativeRow["responseHueDerivativePerUnit"] = hueDerivative[work.refinementIndex]
                    derivativeRow["responseRGDerivativePerUnit"] = rgDerivative[work.refinementIndex]
                }
                derivativeRows.append(derivativeRow)
            }

            var scalarRows: [(derivative: [Double], residual: Double, weight: Double)] = []
            if let currentResponse, responseActive {
                let hueTargetLower = Self.responseHueLowerBoundDegrees + Self.responseHueMarginDegrees
                let hueTargetUpper = Self.responseHueUpperBoundDegrees - Self.responseHueMarginDegrees
                if currentResponse.hueDeltaDegrees < hueTargetLower {
                    scalarRows.append((
                        hueDerivative,
                        hueTargetLower - currentResponse.hueDeltaDegrees,
                        Self.responseHueWeight
                    ))
                } else if currentResponse.hueDeltaDegrees > hueTargetUpper {
                    scalarRows.append((
                        hueDerivative,
                        hueTargetUpper - currentResponse.hueDeltaDegrees,
                        Self.responseHueWeight
                    ))
                }
                let rgTargetLower = Self.responseRGLowerBound + Self.responseRGMargin
                let rgTargetUpper = Self.responseRGUpperBound - Self.responseRGMargin
                if currentResponse.rgDelta < rgTargetLower {
                    scalarRows.append((
                        rgDerivative,
                        rgTargetLower - currentResponse.rgDelta,
                        Self.responseRGWeight
                    ))
                } else if currentResponse.rgDelta > rgTargetUpper {
                    scalarRows.append((
                        rgDerivative,
                        rgTargetUpper - currentResponse.rgDelta,
                        Self.responseRGWeight
                    ))
                }
            }

            let update = try Self.solveUpdate(
                current: currentRaster,
                target: target,
                derivatives: derivatives,
                scalarRows: scalarRows
            )
            var proposed = coefficients
            var proposedMetrics = beforeMetrics
            var proposedResponse = currentResponse
            var proposedScore = beforeScore
            var selectedScale = 0.0
            var lineSearchRows: [[String: Any]] = []
            var lineSearchWork: [(
                scale: Double,
                coefficients: [Double],
                requests: [RenderRequest]
            )] = []
            for scale in Self.lineSearchScales {
                var candidate = coefficients
                for (refinementIndex, coefficientIndex) in Self.solverRefinementParameterIndices.enumerated() {
                    let bound = Self.bound(forCoefficientIndex: coefficientIndex)
                    candidate[coefficientIndex] = min(
                        bound,
                        max(
                            -bound,
                            coefficients[coefficientIndex] + update[refinementIndex] * scale
                        )
                    )
                }
                let label = String(format: "proposed-s%03d", Int(scale * 100))
                let heicURL = try Self.materialize(
                    baseHEICURL: preliminaryHEICURL,
                    identityStylePropertyList: identityStylePropertyList,
                    coefficientDeltas: candidate,
                    outputDirectory: iterationDirectory,
                    label: label
                )
                var requests = [
                    RenderRequest(
                        heicURL: heicURL,
                        outputDirectory: iterationDirectory,
                        label: label,
                        enabled: true
                    ),
                ]
                if responseActive {
                    requests += responseRequests(
                        heicURL: heicURL,
                        outputDirectory: iterationDirectory,
                        labelPrefix: label
                    )
                }
                lineSearchWork.append((
                    scale: scale,
                    coefficients: candidate,
                    requests: requests
                ))
            }
            let lineSearchRasters = try Self.render(
                executable: executable,
                requests: lineSearchWork.flatMap(\.requests)
            )
            var proposedRaster: Raster?
            var lineSearchCursor = 0
            for work in lineSearchWork {
                guard lineSearchCursor + work.requests.count <= lineSearchRasters.count else {
                    throw CLIError.invalidContainer(
                        "constrained key-1 renderer returned an incomplete line-search batch"
                    )
                }
                let raster = lineSearchRasters[lineSearchCursor]
                let candidateResponse: ResponseObjectiveState? = responseActive
                    ? responseState(
                        mid: lineSearchRasters[lineSearchCursor + 1],
                        plus: lineSearchRasters[lineSearchCursor + 2]
                    )
                    : nil
                lineSearchCursor += work.requests.count
                let candidateMetrics = Self.metrics(raster, target)
                let candidateScore = Self.responseScore(
                    rmse8: candidateMetrics.rmse8,
                    state: candidateResponse
                )
                var lineSearchRow: [String: Any] = [
                    "scale": work.scale,
                    "metrics": candidateMetrics.dictionary,
                    "score": candidateScore,
                ]
                if let candidateResponse {
                    lineSearchRow["response"] = candidateResponse.dictionary
                }
                lineSearchRows.append(lineSearchRow)
                if candidateScore < proposedScore {
                    proposed = work.coefficients
                    proposedMetrics = candidateMetrics
                    proposedResponse = candidateResponse
                    proposedScore = candidateScore
                    selectedScale = work.scale
                    proposedRaster = raster
                }
            }
            let accepted = selectedScale > 0
            var iterationRow: [String: Any] = [
                "iteration": iteration,
                "coefficientDeltasBefore": Self.coefficientDictionary(coefficients),
                "metricsBefore": beforeMetrics.dictionary,
                "scoreBefore": beforeScore,
                "jacobian": derivativeRows,
                "refinementUpdate": Self.refinementDictionary(update),
                "scalarResponseRowCount": scalarRows.count,
                "lineSearchCandidates": lineSearchRows,
                "selectedScale": selectedScale,
                "coefficientDeltasProposed": Self.coefficientDictionary(proposed),
                "metricsProposed": proposedMetrics.dictionary,
                "scoreProposed": proposedScore,
                "accepted": accepted,
            ]
            if let currentResponse {
                iterationRow["responseBefore"] = currentResponse.dictionary
            }
            if let proposedResponse {
                iterationRow["responseProposed"] = proposedResponse.dictionary
            }
            iterationRows.append(iterationRow)
            guard accepted, let proposedRaster else { break }
            coefficients = proposed
            latestRendered = (proposed, proposedRaster)
            latestResponse = proposedResponse
            if proposedScore < bestScore {
                bestScore = proposedScore
                bestMetrics = proposedMetrics
                bestCoefficients = proposed
                bestResponse = proposedResponse
            }
        }
        let refinementCompletedAt = CFAbsoluteTimeGetCurrent()

        // Compliant fast path: the hinge terms were skipped, so measure the
        // winning candidate's response once and escalate into the full
        // objective when it measurably regressed the identity control.
        if responseMeasured, !responseActive, let identityResponse {
            let verificationDirectory = outputDirectory.appendingPathComponent(
                "response-verification",
                isDirectory: true
            )
            let verificationHEICURL = try Self.materialize(
                baseHEICURL: preliminaryHEICURL,
                identityStylePropertyList: identityStylePropertyList,
                coefficientDeltas: bestCoefficients,
                outputDirectory: verificationDirectory,
                label: "selected-response-check"
            )
            let verificationRasters = try Self.render(
                executable: executable,
                requests: responseRequests(
                    heicURL: verificationHEICURL,
                    outputDirectory: verificationDirectory,
                    labelPrefix: "selected-response-check"
                )
            )
            guard verificationRasters.count == 2 else {
                throw CLIError.invalidContainer(
                    "constrained key-1 renderer returned an incomplete response verification batch"
                )
            }
            let verified = responseState(
                mid: verificationRasters[0],
                plus: verificationRasters[1]
            )
            bestResponse = verified
            if verified.hingeScore > identityResponse.hingeScore + 1e-6, !forceResponseTerms {
                return try makeStyleData(
                    preliminaryHEICURL: preliminaryHEICURL,
                    identityStylePropertyList: identityStylePropertyList,
                    outputDirectory: outputDirectory,
                    skinMask: skinMask,
                    forceResponseTerms: true
                )
            }
        }

        let responseObjectiveReport: [String: Any]
        if responseMeasured, let identityResponse, let bestResponse {
            responseObjectiveReport = [
                "enabled": true,
                "mode": responseActive ? "hinge-active" : "verify-only",
                "escalated": forceResponseTerms,
                "settings": [
                    "mid": ["tone": 0, "color": 1],
                    "plus": ["tone": 1, "color": 1],
                ],
                "envelope": [
                    "hueDegrees": [Self.responseHueLowerBoundDegrees, Self.responseHueUpperBoundDegrees],
                    "rgDelta": [Self.responseRGLowerBound, Self.responseRGUpperBound],
                ],
                "margins": [
                    "hueDegrees": Self.responseHueMarginDegrees,
                    "rg": Self.responseRGMargin,
                ],
                "weights": [
                    "normalHue": Self.responseHueWeight,
                    "normalRG": Self.responseRGWeight,
                    "scoreHue": Self.responseScoreHueWeight,
                    "scoreRG": Self.responseScoreRGWeight,
                ],
                "roi": [
                    "kind": bestResponse.roiKind,
                    "pixelCount": bestResponse.roiPixelCount,
                ],
                "identity": identityResponse.dictionary,
                "selected": bestResponse.dictionary,
            ]
        } else {
            responseObjectiveReport = [
                "enabled": false,
                "reason": responseDisabledReason ?? "unknown",
            ]
        }

        guard bestCoefficients.contains(where: { abs($0) > 0 }),
              bestMetrics.rmse8 < identityMetrics.rmse8 * 0.98 else {
            let result: [String: Any] = [
                "schema": "xdremux-constrained-polynomial-key1-v4",
                "status": "rejected_no_improvement",
                "identityMetrics": identityMetrics.dictionary,
                "bestMetrics": bestMetrics.dictionary,
                "responseObjective": responseObjectiveReport,
                "iterations": iterationRows,
            ]
            try Self.writeJSON(
                result,
                to: outputDirectory.appendingPathComponent("solver-result.json")
            )
            throw CLIError.invalidContainer(
                "constrained key-1 producer did not improve the complete-Neutrino neutral reconstruction; no identity fallback was applied"
            )
        }

        // Stage A fail-closed gate: candidates may keep a pre-existing native
        // editor-response violation, but must never make it worse than the
        // same-photo identity control.
        if responseMeasured,
           let identityResponse,
           let bestResponseState = bestResponse,
           bestResponseState.hingeScore > identityResponse.hingeScore + 1e-6 {
            let result: [String: Any] = [
                "schema": "xdremux-constrained-polynomial-key1-v4",
                "status": "rejected_response_regression",
                "identityMetrics": identityMetrics.dictionary,
                "bestMetrics": bestMetrics.dictionary,
                "responseObjective": responseObjectiveReport,
                "iterations": iterationRows,
            ]
            try Self.writeJSON(
                result,
                to: outputDirectory.appendingPathComponent("solver-result.json")
            )
            throw CLIError.invalidContainer(
                "constrained key-1 producer regressed the native editor-response envelope; no identity fallback was applied"
            )
        }

        let styleData = try Self.styleData(coefficientDeltas: bestCoefficients)
        let finalLayout = try AppleStyleDataLayout.validate(styleData)
        let styleDataURL = outputDirectory.appendingPathComponent(
            "constrained-polynomial-style-data.f16.bin"
        )
        try styleData.write(to: styleDataURL, options: .atomic)
        let improvement = 1 - bestMetrics.rmse8 / identityMetrics.rmse8
        let responseEnvelope = try Self.validateResponseEnvelope(
            executable: executable,
            preliminaryHEICURL: preliminaryHEICURL,
            identityStylePropertyList: identityStylePropertyList,
            styleData: styleData,
            outputDirectory: outputDirectory.appendingPathComponent(
                "response-envelope",
                isDirectory: true
            )
        )
        let responseCompletedAt = CFAbsoluteTimeGetCurrent()
        print(String(
            format: "styles solver admissionWait=%.3fs initialization=%.3fs refinement=%.3fs response=%.3fs total=%.3fs",
            admissionWaitSeconds,
            initializationCompletedAt - solverStartedAt,
            refinementCompletedAt - initializationCompletedAt,
            responseCompletedAt - refinementCompletedAt,
            responseCompletedAt - solverStartedAt
        ))
        guard responseEnvelope["passed"] as? Bool == true else {
            let rejectedResult: [String: Any] = [
                "schema": "xdremux-constrained-polynomial-key1-v4",
                "status": "rejected_native_increment_envelope",
                "identityMetrics": identityMetrics.dictionary,
                "bestMetrics": bestMetrics.dictionary,
                "rmseImprovementFraction": improvement,
                "responseObjective": responseObjectiveReport,
                "responseEnvelope": responseEnvelope,
                "iterations": iterationRows,
            ]
            try Self.writeJSON(
                rejectedResult,
                to: outputDirectory.appendingPathComponent("solver-result.json")
            )
            throw CLIError.invalidContainer(
                "constrained key-1 producer exceeded the native key-increment response envelope; no identity fallback was applied"
            )
        }
        let producerVersion = responseMeasured
            ? "full-consumer-global-quadratic-response-v6"
            : "full-consumer-global-quadratic-v5"
        let solverKind = responseMeasured
            ? "global-rgb-quadratic-irls-consumer-linear-matrix-jacobian-native-response-shape-gate-v5+tone-at-color100-skin-hinge"
            : "global-rgb-quadratic-irls-consumer-linear-matrix-jacobian-native-response-shape-gate-v5"
        let solverResult: [String: Any] = [
            "schema": "xdremux-constrained-polynomial-key1-v4",
            "status": "accepted",
            "evidence": "complete Neutrino composition",
            "parameterization": "global 10-term encoded-RGB quadratic polynomial repeated over 12x9x8, followed by twelve-direction complete-Neutrino linear-matrix refinement",
            "analysisMaximumDimension": Self.analysisMaximumDimension,
            "epsilon": Self.epsilon,
            "linearBound": Self.linearBound,
            "quadraticBound": Self.quadraticBound,
            "coefficientDeltas": Self.coefficientDictionary(bestCoefficients),
            "identityMetrics": identityMetrics.dictionary,
            "bestMetrics": bestMetrics.dictionary,
            "rmseImprovementFraction": improvement,
            "styleDataSHA256": sha256Hex(styleData),
            "responseObjective": responseObjectiveReport,
            "responseEnvelope": responseEnvelope,
            "iterations": iterationRows,
        ]
        try Self.writeJSON(
            solverResult,
            to: outputDirectory.appendingPathComponent("solver-result.json")
        )
        let sourceData = try Data(
            contentsOf: preliminaryHEICURL,
            options: [.mappedIfSafe]
        )
        let targetPNG = outputDirectory
            .appendingPathComponent("target")
            .appendingPathComponent("disabled.png")
        return AppleStyleDataResult(
            styleData: styleData,
            styleDataSHA256: sha256Hex(styleData),
            polynomialCount: AppleStyleDataLayout.polynomialCount,
            blockValueCount: AppleStyleDataLayout.blockValueCount,
            tileCount: AppleStyleDataLayout.tileCount,
            producer: "constrainedSolver",
            producerVersion: producerVersion,
            sourceSHA256: sha256Hex(sourceData),
            targetSHA256: sha256Hex(try Data(contentsOf: targetPNG)),
            sourceDomain: "complete Neutrino graph conditioned by this photo's Base, Gain Map, Linear Thumbnail, Style Delta, and semantic resources",
            targetDomain: "same photo rendered by complete Neutrino with SemanticStyle disabled",
            learnBufferKind: nil,
            solverKind: solverKind,
            evidence: .completeNeutrinoConstrainedSolver,
            sceneMatched: true,
            identityFallback: false,
            fallbackKind: nil,
            reconstructionMetrics: [
                "status": "neutral_scene_matched",
                "identity": identityMetrics.dictionary,
                "selected": bestMetrics.dictionary,
                "rmseImprovementFraction": improvement,
                "coefficientDeltas": Self.coefficientDictionary(bestCoefficients),
                "styleDataLayout": finalLayout,
                "responseObjective": responseObjectiveReport,
                "responseEnvelope": responseEnvelope,
            ],
            warnings: [
                "Global quadratic constrained solver selected; 12x9 local residual fitting and device HDR appearance remain separate acceptance gates."
            ]
        )
    }

    private static func materialize(
        baseHEICURL: URL,
        identityStylePropertyList: Data,
        coefficientDeltas: [Double],
        outputDirectory: URL,
        label: String
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let key = try styleData(coefficientDeltas: coefficientDeltas)
        let keyURL = outputDirectory.appendingPathComponent("\(label).f16.bin")
        try key.write(to: keyURL, options: .atomic)
        let heicURL: URL
        if key == (try AppleStyleDataLayout.completeIdentity()) {
            heicURL = baseHEICURL
        } else {
            heicURL = outputDirectory.appendingPathComponent("\(label).heic")
            try injectStyleData(
                key,
                into: baseHEICURL,
                identityStylePropertyList: identityStylePropertyList,
                outputURL: heicURL
            )
        }
        return heicURL
    }

    // Neutrino renders are pure functions of their request (verified: repeated
    // runs are bit-identical), and the helper keeps per-process global state,
    // so concurrency is applied between helper processes, never inside one.
    // Measured on macOS 15/M-series: up to 5 concurrent helper processes render
    // at full speed; at 6+ the Neutrino/CoreImage render path collapses to a
    // ~30x slowdown (renders sit in dispatch waits). Default stays at 4 to keep
    // a margin below that cliff; XDREMUX_STYLE_RENDER_JOBS overrides.
    private static let renderConcurrency: Int = {
        if let raw = ProcessInfo.processInfo.environment["XDREMUX_STYLE_RENDER_JOBS"],
           let value = Int(raw) {
            return min(16, max(1, value))
        }
        return min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
    }()

    private static func render(
        executable: URL,
        requests: [RenderRequest]
    ) throws -> [Raster] {
        guard !requests.isEmpty else { return [] }
        for request in requests {
            try FileManager.default.createDirectory(
                at: request.outputDirectory,
                withIntermediateDirectories: true
            )
        }
        let workerCount = min(renderConcurrency, requests.count)
        guard workerCount > 1 else {
            return try renderChunk(executable: executable, requests: requests)
        }

        var chunks: [[RenderRequest]] = []
        chunks.reserveCapacity(workerCount)
        let baseSize = requests.count / workerCount
        let remainder = requests.count % workerCount
        var start = 0
        for index in 0..<workerCount {
            let size = baseSize + (index < remainder ? 1 : 0)
            chunks.append(Array(requests[start..<(start + size)]))
            start += size
        }

        let lock = NSLock()
        var rastersByChunk: [Int: [Raster]] = [:]
        var firstError: (index: Int, error: Error)?
        DispatchQueue.concurrentPerform(iterations: chunks.count) { index in
            do {
                let rasters = try renderChunk(executable: executable, requests: chunks[index])
                lock.lock()
                rastersByChunk[index] = rasters
                lock.unlock()
            } catch {
                lock.lock()
                if firstError == nil || index < firstError!.index {
                    firstError = (index, error)
                }
                lock.unlock()
            }
        }
        if let firstError {
            throw firstError.error
        }
        let rasters = (0..<chunks.count).flatMap { rastersByChunk[$0] ?? [] }
        guard rasters.count == requests.count else {
            throw CLIError.invalidContainer(
                "complete-Neutrino render chunks returned \(rasters.count) rasters; expected \(requests.count)"
            )
        }
        return rasters
    }

    private static func renderChunk(
        executable: URL,
        requests: [RenderRequest]
    ) throws -> [Raster] {
        let planURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "xdremux-neutrino-style-render-batch-\(UUID().uuidString).json"
        )
        defer { try? FileManager.default.removeItem(at: planURL) }
        let plan: [String: Any] = [
            "schema": "xdremux-neutrino-style-render-batch-v1",
            "requests": requests.map(\.dictionary),
        ]
        let planData = try JSONSerialization.data(
            withJSONObject: plan,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try planData.write(to: planURL, options: .atomic)
        let process = try AppleNativeToolchain.run(
            executable,
            arguments: ["--render-style-batch", planURL.path],
            timeout: 180
        )
        let result = try? JSONSerialization.jsonObject(with: process.stdout) as? [String: Any]
        guard !process.timedOut,
              process.status == 0,
              result?["passed"] as? Bool == true else {
            let stderr = String(data: process.stderr, encoding: .utf8) ?? ""
            let stdout = String(data: process.stdout, encoding: .utf8) ?? ""
            throw CLIError.invalidContainer(
                "complete-Neutrino key-1 calibration render batch failed: "
                    + (process.timedOut ? "renderer exceeded 180 seconds; " : "")
                    + [stderr, stdout]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
            )
        }
        return try requests.map { try decodeRGB8($0.pngURL) }
    }

    private static func decodeRGB8(_ url: URL) throws -> Raster {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CLIError.invalidContainer("cannot decode constrained key-1 render")
        }
        let width = image.width
        let height = image.height
        var rgba = Data(count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)
            ?? CGColorSpaceCreateDeviceRGB()
        let created = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let address = raw.baseAddress,
                  let context = CGContext(
                    data: address,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard created else {
            throw CLIError.invalidContainer("cannot rasterize constrained key-1 render")
        }
        let pixelCount = width * height
        let rgb = [Float](unsafeUninitializedCapacity: pixelCount * 3) { buffer, initializedCount in
            rgba.withUnsafeBytes { raw in
                let source = raw.bindMemory(to: UInt8.self)
                for pixel in 0..<pixelCount {
                    let sourceOffset = pixel * 4
                    let destinationOffset = pixel * 3
                    buffer[destinationOffset] = Float(source[sourceOffset])
                    buffer[destinationOffset + 1] = Float(source[sourceOffset + 1])
                    buffer[destinationOffset + 2] = Float(source[sourceOffset + 2])
                }
            }
            initializedCount = pixelCount * 3
        }
        return Raster(width: width, height: height, rgb: rgb)
    }

    private static func validateResponseEnvelope(
        executable: URL,
        preliminaryHEICURL: URL,
        identityStylePropertyList: Data,
        styleData: Data,
        outputDirectory: URL
    ) throws -> [String: Any] {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let selectedHEICURL = outputDirectory.appendingPathComponent("selected-key.heic")
        try injectStyleData(
            styleData,
            into: preliminaryHEICURL,
            identityStylePropertyList: identityStylePropertyList,
            outputURL: selectedHEICURL
        )
        let standardMinus = StyleSetting(tone: -1, color: 0, intensity: 1, cast: "Standard")
        let standardPlus = StyleSetting(tone: 1, color: 0, intensity: 1, cast: "Standard")
        let pairs = [
            ResponsePair(
                name: "tone",
                minus: standardMinus,
                midpoint: StyleSetting(tone: 0, color: 0, intensity: 1, cast: "Standard"),
                plus: standardPlus
            ),
            ResponsePair(
                name: "color",
                minus: StyleSetting(tone: 0, color: -1, intensity: 1, cast: "Standard"),
                midpoint: StyleSetting(tone: 0, color: 0, intensity: 1, cast: "Standard"),
                plus: StyleSetting(tone: 0, color: 1, intensity: 1, cast: "Standard")
            ),
            ResponsePair(
                name: "combined",
                minus: StyleSetting(tone: -1, color: -1, intensity: 1, cast: "Standard"),
                midpoint: StyleSetting(tone: 0, color: 0, intensity: 1, cast: "Standard"),
                plus: StyleSetting(tone: 1, color: 1, intensity: 1, cast: "Standard")
            ),
            ResponsePair(
                name: "intensity",
                minus: StyleSetting(tone: 0, color: 0, intensity: 0, cast: "Cool"),
                midpoint: StyleSetting(tone: 0, color: 0, intensity: 0.5, cast: "Cool"),
                plus: StyleSetting(tone: 0, color: 0, intensity: 1, cast: "Cool")
            ),
        ]
        var rows: [[String: Any]] = []
        var failures: [String] = []
        var renderCache: [String: Raster] = [:]
        var renderWork: [(cacheKey: String, request: RenderRequest)] = []

        func cacheKey(owner: String, setting: StyleSetting) -> String {
            [
                owner,
                String(setting.tone),
                String(setting.color),
                String(setting.intensity),
                setting.cast,
            ].joined(separator: "|")
        }

        func register(
            _ heicURL: URL,
            owner: String,
            pairName: String,
            side: String,
            setting: StyleSetting
        ) {
            let key = cacheKey(owner: owner, setting: setting)
            guard !renderWork.contains(where: { $0.cacheKey == key }) else { return }
            renderWork.append((
                cacheKey: key,
                request: RenderRequest(
                    heicURL: heicURL,
                    outputDirectory: outputDirectory.appendingPathComponent(owner),
                    label: "\(pairName)-\(side)",
                    enabled: true,
                    tone: setting.tone,
                    color: setting.color,
                    intensity: setting.intensity,
                    cast: setting.cast
                )
            ))
        }

        for pair in pairs {
            for (side, setting) in [
                ("minus", pair.minus),
                ("midpoint", pair.midpoint),
                ("plus", pair.plus),
            ] {
                register(
                    selectedHEICURL,
                    owner: "candidate",
                    pairName: pair.name,
                    side: side,
                    setting: setting
                )
                register(
                    preliminaryHEICURL,
                    owner: "identity",
                    pairName: pair.name,
                    side: side,
                    setting: setting
                )
            }
        }
        let responseRasters = try render(
            executable: executable,
            requests: renderWork.map(\.request)
        )
        for (work, raster) in zip(renderWork, responseRasters) {
            renderCache[work.cacheKey] = raster
        }

        func rendered(
            _ heicURL: URL,
            owner: String,
            pairName: String,
            side: String,
            setting: StyleSetting
        ) throws -> Raster {
            let key = cacheKey(owner: owner, setting: setting)
            guard let cached = renderCache[key] else {
                throw CLIError.invalidContainer(
                    "missing batched native response render \(owner)/\(pairName)-\(side) for \(heicURL.lastPathComponent)"
                )
            }
            return cached
        }

        for pair in pairs {
            let candidateMinus = try rendered(
                selectedHEICURL,
                owner: "candidate",
                pairName: pair.name,
                side: "minus",
                setting: pair.minus
            )
            let candidateMidpoint = try rendered(
                selectedHEICURL,
                owner: "candidate",
                pairName: pair.name,
                side: "midpoint",
                setting: pair.midpoint
            )
            let candidatePlus = try rendered(
                selectedHEICURL,
                owner: "candidate",
                pairName: pair.name,
                side: "plus",
                setting: pair.plus
            )
            let identityMinus = try rendered(
                preliminaryHEICURL,
                owner: "identity",
                pairName: pair.name,
                side: "minus",
                setting: pair.minus
            )
            let identityMidpoint = try rendered(
                preliminaryHEICURL,
                owner: "identity",
                pairName: pair.name,
                side: "midpoint",
                setting: pair.midpoint
            )
            let identityPlus = try rendered(
                preliminaryHEICURL,
                owner: "identity",
                pairName: pair.name,
                side: "plus",
                setting: pair.plus
            )
            let endpointIncrement = try incrementalResponseMetrics(
                candidateMinus: candidateMinus,
                candidatePlus: candidatePlus,
                identityMinus: identityMinus,
                identityPlus: identityPlus
            )
            let lowerSegmentIncrement = try incrementalResponseMetrics(
                candidateMinus: candidateMinus,
                candidatePlus: candidateMidpoint,
                identityMinus: identityMinus,
                identityPlus: identityMidpoint
            )
            let upperSegmentIncrement = try incrementalResponseMetrics(
                candidateMinus: candidateMidpoint,
                candidatePlus: candidatePlus,
                identityMinus: identityMidpoint,
                identityPlus: identityPlus
            )
            let curvatureIncrement = try incrementalCurvatureMetrics(
                candidateMinus: candidateMinus,
                candidateMidpoint: candidateMidpoint,
                candidatePlus: candidatePlus,
                identityMinus: identityMinus,
                identityMidpoint: identityMidpoint,
                identityPlus: identityPlus
            )
            let endpointLimit = nativeIncrementEnvelopeRMSE8[pair.name]!
            let segmentLimit = nativeIncrementSegmentEnvelopeRMSE8[pair.name]!
            let curvatureLimit = nativeIncrementCurvatureEnvelopeRMSE8[pair.name]!
            if endpointIncrement.rmse8 > endpointLimit {
                failures.append(
                    String(
                        format: "%@ key increment RMSE %.4f exceeds native envelope %.4f",
                        pair.name,
                        endpointIncrement.rmse8,
                        endpointLimit
                    )
                )
            }
            for (side, metrics) in [
                ("lower", lowerSegmentIncrement),
                ("upper", upperSegmentIncrement),
            ] where metrics.rmse8 > segmentLimit {
                failures.append(
                    String(
                        format: "%@ %@-segment key increment RMSE %.4f exceeds native envelope %.4f",
                        pair.name,
                        side,
                        metrics.rmse8,
                        segmentLimit
                    )
                )
            }
            if curvatureIncrement.rmse8 > curvatureLimit {
                failures.append(
                    String(
                        format: "%@ key-increment curvature RMSE %.4f exceeds native envelope %.4f",
                        pair.name,
                        curvatureIncrement.rmse8,
                        curvatureLimit
                    )
                )
            }
            let minusHealth = rasterHealth(candidateMinus)
            let midpointHealth = rasterHealth(candidateMidpoint)
            let plusHealth = rasterHealth(candidatePlus)
            let meanLumaDelta8 = (plusHealth["meanLuma8"] as? Double ?? 0)
                - (minusHealth["meanLuma8"] as? Double ?? 0)
            let meanChromaDelta8 = (plusHealth["meanChroma8"] as? Double ?? 0)
                - (minusHealth["meanChroma8"] as? Double ?? 0)
            let directionPassed = responseDirectionPassed(
                name: pair.name,
                meanLumaDelta8: meanLumaDelta8,
                meanChromaDelta8: meanChromaDelta8
            )
            if !directionPassed {
                failures.append(
                    String(
                        format: "%@ has wrong response direction (luma delta %.4f, chroma delta %.4f)",
                        pair.name,
                        meanLumaDelta8,
                        meanChromaDelta8
                    )
                )
            }
            for (side, health) in [
                ("minus", minusHealth),
                ("midpoint", midpointHealth),
                ("plus", plusHealth),
            ] {
                let black = health["blackFraction"] as? Double ?? 1
                let white = health["whiteFraction"] as? Double ?? 1
                let luma = health["meanLuma8"] as? Double ?? 0
                if black > 0.95 || white > 0.95 || luma < 1 || luma > 254 {
                    failures.append("\(pair.name) \(side) endpoint is catastrophically clipped")
                }
            }
            rows.append([
                "name": pair.name,
                "minus": [
                    "tone": pair.minus.tone,
                    "color": pair.minus.color,
                    "intensity": pair.minus.intensity,
                    "cast": pair.minus.cast,
                ],
                "midpoint": [
                    "tone": pair.midpoint.tone,
                    "color": pair.midpoint.color,
                    "intensity": pair.midpoint.intensity,
                    "cast": pair.midpoint.cast,
                ],
                "plus": [
                    "tone": pair.plus.tone,
                    "color": pair.plus.color,
                    "intensity": pair.plus.intensity,
                    "cast": pair.plus.cast,
                ],
                "candidateMinusHealth": minusHealth,
                "candidateMidpointHealth": midpointHealth,
                "candidatePlusHealth": plusHealth,
                "direction": [
                    "meanLumaDelta8": meanLumaDelta8,
                    "meanChromaDelta8": meanChromaDelta8,
                    "criterion": directionCriterion(for: pair.name),
                    "passed": directionPassed,
                ],
                "endpointKeyIncrement": endpointIncrement.dictionary,
                "lowerSegmentKeyIncrement": lowerSegmentIncrement.dictionary,
                "upperSegmentKeyIncrement": upperSegmentIncrement.dictionary,
                "keyIncrementCurvature": curvatureIncrement.dictionary,
                "nativeEndpointEnvelopeRMSE8": endpointLimit,
                "nativeSegmentEnvelopeRMSE8": segmentLimit,
                "nativeCurvatureEnvelopeRMSE8": curvatureLimit,
                "passed": endpointIncrement.rmse8 <= endpointLimit
                    && lowerSegmentIncrement.rmse8 <= segmentLimit
                    && upperSegmentIncrement.rmse8 <= segmentLimit
                    && curvatureIncrement.rmse8 <= curvatureLimit
                    && directionPassed,
            ])
        }
        let result: [String: Any] = [
            "schema": "xdremux-key1-native-increment-response-gate-v2",
            "evidence": "complete Neutrino composition",
            "reference": "two Apple native key-only identity injection controls with a conservative guard band",
            "comparison": "candidate-minus-identity key increment across endpoints, each half segment, and the midpoint second difference",
            "passed": failures.isEmpty,
            "failures": failures,
            "pairs": rows,
        ]
        try writeJSON(
            result,
            to: outputDirectory.appendingPathComponent("response-envelope.json")
        )
        return result
    }

    private static func incrementalResponseMetrics(
        candidateMinus: Raster,
        candidatePlus: Raster,
        identityMinus: Raster,
        identityPlus: Raster
    ) throws -> Metrics {
        let count = candidateMinus.rgb.count
        guard count > 0,
              candidatePlus.rgb.count == count,
              identityMinus.rgb.count == count,
              identityPlus.rgb.count == count else {
            throw CLIError.invalidContainer(
                "native response envelope renders have inconsistent dimensions"
            )
        }
        var squared = 0.0
        var absolute = 0.0
        var maximum = 0.0
        for index in 0..<count {
            let candidateResponse = candidatePlus.rgb[index] - candidateMinus.rgb[index]
            let identityResponse = identityPlus.rgb[index] - identityMinus.rgb[index]
            let difference = Double(candidateResponse - identityResponse)
            squared += difference * difference
            absolute += abs(difference)
            maximum = max(maximum, abs(difference))
        }
        return Metrics(
            rmse8: sqrt(squared / Double(count)),
            mae8: absolute / Double(count),
            maximumAbsolute8: maximum
        )
    }

    private static func incrementalCurvatureMetrics(
        candidateMinus: Raster,
        candidateMidpoint: Raster,
        candidatePlus: Raster,
        identityMinus: Raster,
        identityMidpoint: Raster,
        identityPlus: Raster
    ) throws -> Metrics {
        let count = candidateMinus.rgb.count
        guard count > 0,
              candidateMidpoint.rgb.count == count,
              candidatePlus.rgb.count == count,
              identityMinus.rgb.count == count,
              identityMidpoint.rgb.count == count,
              identityPlus.rgb.count == count else {
            throw CLIError.invalidContainer(
                "native response curvature renders have inconsistent dimensions"
            )
        }
        var squared = 0.0
        var absolute = 0.0
        var maximum = 0.0
        for index in 0..<count {
            let candidateCurvature = candidatePlus.rgb[index]
                - 2 * candidateMidpoint.rgb[index]
                + candidateMinus.rgb[index]
            let identityCurvature = identityPlus.rgb[index]
                - 2 * identityMidpoint.rgb[index]
                + identityMinus.rgb[index]
            let difference = Double(candidateCurvature - identityCurvature)
            squared += difference * difference
            absolute += abs(difference)
            maximum = max(maximum, abs(difference))
        }
        return Metrics(
            rmse8: sqrt(squared / Double(count)),
            mae8: absolute / Double(count),
            maximumAbsolute8: maximum
        )
    }

    package static func incrementalResponseRMSE8(
        candidateMinus: [Float],
        candidatePlus: [Float],
        identityMinus: [Float],
        identityPlus: [Float]
    ) throws -> Double {
        let count = candidateMinus.count
        guard count > 0,
              candidatePlus.count == count,
              identityMinus.count == count,
              identityPlus.count == count,
              candidateMinus.allSatisfy(\.isFinite),
              candidatePlus.allSatisfy(\.isFinite),
              identityMinus.allSatisfy(\.isFinite),
              identityPlus.allSatisfy(\.isFinite) else {
            throw CLIError.invalidContainer("invalid native response envelope vectors")
        }
        var squared = 0.0
        for index in 0..<count {
            let candidateResponse = candidatePlus[index] - candidateMinus[index]
            let identityResponse = identityPlus[index] - identityMinus[index]
            let difference = Double(candidateResponse - identityResponse)
            squared += difference * difference
        }
        return sqrt(squared / Double(count))
    }

    package static func incrementalCurvatureRMSE8(
        candidateMinus: [Float],
        candidateMidpoint: [Float],
        candidatePlus: [Float],
        identityMinus: [Float],
        identityMidpoint: [Float],
        identityPlus: [Float]
    ) throws -> Double {
        let count = candidateMinus.count
        let vectors = [
            candidateMinus,
            candidateMidpoint,
            candidatePlus,
            identityMinus,
            identityMidpoint,
            identityPlus,
        ]
        guard count > 0,
              vectors.allSatisfy({ $0.count == count && $0.allSatisfy(\.isFinite) }) else {
            throw CLIError.invalidContainer("invalid native response curvature vectors")
        }
        var squared = 0.0
        for index in 0..<count {
            let candidateCurvature = candidatePlus[index]
                - 2 * candidateMidpoint[index]
                + candidateMinus[index]
            let identityCurvature = identityPlus[index]
                - 2 * identityMidpoint[index]
                + identityMinus[index]
            let difference = Double(candidateCurvature - identityCurvature)
            squared += difference * difference
        }
        return sqrt(squared / Double(count))
    }

    package static func responseDirectionPassed(
        name: String,
        meanLumaDelta8: Double,
        meanChromaDelta8: Double
    ) -> Bool {
        guard meanLumaDelta8.isFinite, meanChromaDelta8.isFinite else { return false }
        switch name {
        case "tone":
            return meanLumaDelta8 > 0
        case "color":
            return meanChromaDelta8 > 0
        case "combined":
            return meanLumaDelta8 > 0 && meanChromaDelta8 > 0
        case "intensity":
            return true
        default:
            return false
        }
    }

    private static func directionCriterion(for name: String) -> String {
        switch name {
        case "tone":
            return "plus endpoint mean luma must exceed minus endpoint mean luma"
        case "color":
            return "plus endpoint mean chroma must exceed minus endpoint mean chroma"
        case "combined":
            return "plus endpoint mean luma and mean chroma must exceed minus endpoint"
        case "intensity":
            return "no scalar direction criterion; native increment shape only"
        default:
            return "unknown response family"
        }
    }

    private static func rasterHealth(_ raster: Raster) -> [String: Any] {
        var black = 0
        var white = 0
        var luma = 0.0
        var chroma = 0.0
        let pixelCount = raster.rgb.count / 3
        for pixel in 0..<pixelCount {
            let offset = pixel * 3
            let red = Double(raster.rgb[offset])
            let green = Double(raster.rgb[offset + 1])
            let blue = Double(raster.rgb[offset + 2])
            if red <= 1, green <= 1, blue <= 1 { black += 1 }
            if red >= 254, green >= 254, blue >= 254 { white += 1 }
            luma += red * 0.22897456 + green * 0.69173852 + blue * 0.07928691
            chroma += max(red, max(green, blue)) - min(red, min(green, blue))
        }
        let denominator = Double(max(1, pixelCount))
        return [
            "meanLuma8": luma / denominator,
            "meanChroma8": chroma / denominator,
            "blackFraction": Double(black) / denominator,
            "whiteFraction": Double(white) / denominator,
        ]
    }

    package static func wrappedDegrees(_ value: Double) -> Double {
        var wrapped = value.truncatingRemainder(dividingBy: 360)
        if wrapped <= -180 { wrapped += 360 }
        if wrapped > 180 { wrapped -= 360 }
        return wrapped
    }

    // Display P3 (sRGB transfer) 8-bit raster -> ROI mean OKLab hue and linear
    // R/G ratio.  Matrices match scripts/validate_apple_style_full_scene_response.py.
    package static func responseMetricSample(
        rgb8: [Float],
        width: Int,
        height: Int,
        mask: ResponseSkinMask?
    ) -> ResponseMetricSample {
        guard width > 0, height > 0, rgb8.count == width * height * 3 else {
            return ResponseMetricSample(hueDegrees: 0, rgRatio: 0, roiPixelCount: 0, roiKind: "none")
        }
        func linearize(_ code: Float) -> Double {
            let value = Double(min(max(code, 0), 255)) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        struct Accumulator {
            var sumA = 0.0
            var sumB = 0.0
            var sumLinearR = 0.0
            var sumLinearG = 0.0
            var count = 0

            mutating func add(a: Double, b: Double, linearR: Double, linearG: Double) {
                sumA += a
                sumB += b
                sumLinearR += linearR
                sumLinearG += linearG
                count += 1
            }

            func sample(kind: String) -> ResponseMetricSample {
                guard count > 0 else {
                    return ResponseMetricSample(hueDegrees: 0, rgRatio: 0, roiPixelCount: 0, roiKind: "none")
                }
                let denominator = Double(count)
                return ResponseMetricSample(
                    hueDegrees: atan2(sumB / denominator, sumA / denominator) * 180 / .pi,
                    rgRatio: (sumLinearR / denominator) / max(sumLinearG / denominator, 1e-6),
                    roiPixelCount: count,
                    roiKind: kind
                )
            }
        }
        var skinROI = Accumulator()
        var warmROI = Accumulator()
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 3
                let linearR = linearize(rgb8[offset])
                let linearG = linearize(rgb8[offset + 1])
                let linearB = linearize(rgb8[offset + 2])
                let xyzX = 0.48657095 * linearR + 0.26566769 * linearG + 0.19821729 * linearB
                let xyzY = 0.22897456 * linearR + 0.69173852 * linearG + 0.07928691 * linearB
                let xyzZ = 0.00000000 * linearR + 0.04511338 * linearG + 1.04394437 * linearB
                let lms0 = cbrt(max(0.81902244 * xyzX + 0.36190626 * xyzY - 0.12887378 * xyzZ, 0))
                let lms1 = cbrt(max(0.03298367 * xyzX + 0.92928685 * xyzY + 0.03614467 * xyzZ, 0))
                let lms2 = cbrt(max(0.04817720 * xyzX + 0.26423952 * xyzY + 0.63354783 * xyzZ, 0))
                let okL = 0.21045426 * lms0 + 0.79361779 * lms1 - 0.00407205 * lms2
                let okA = 1.97799850 * lms0 - 2.42859221 * lms1 + 0.45059371 * lms2
                let okB = 0.02590404 * lms0 + 0.78277177 * lms1 - 0.80867577 * lms2
                let chroma = (okA * okA + okB * okB).squareRoot()
                guard okL >= 0.15, okL <= 0.97, chroma > 0.02 else { continue }
                if let mask {
                    let maskX = min(mask.width - 1, max(0, x * mask.width / width))
                    let maskY = min(mask.height - 1, max(0, y * mask.height / height))
                    if mask.samples[maskY * mask.width + maskX] >= 128 {
                        skinROI.add(a: okA, b: okB, linearR: linearR, linearG: linearG)
                    }
                }
                let hue = atan2(okB, okA) * 180 / .pi
                if hue >= 5, hue <= 65 {
                    warmROI.add(a: okA, b: okB, linearR: linearR, linearG: linearG)
                }
            }
        }
        if skinROI.count >= responseMinimumROIPixels {
            return skinROI.sample(kind: "skin-mask")
        }
        if warmROI.count >= responseMinimumROIPixels {
            return warmROI.sample(kind: "warm-fallback")
        }
        return ResponseMetricSample(hueDegrees: 0, rgRatio: 0, roiPixelCount: 0, roiKind: "none")
    }

    // A candidate whose render empties the measurement ROI must not earn a
    // zero-hinge score for it: it inherits the identity control's violations
    // ("no free lunch"), keeping degenerate ROI-vanishing candidates from
    // outscoring the identity baseline near the minimum-ROI threshold.
    package static func substitutingVanishedROI(
        _ state: ResponseObjectiveState,
        identity: ResponseObjectiveState?
    ) -> ResponseObjectiveState {
        guard state.roiKind == "none", let identity else { return state }
        return ResponseObjectiveState(
            hueDeltaDegrees: identity.hueDeltaDegrees,
            rgDelta: identity.rgDelta,
            hueViolationDegrees: identity.hueViolationDegrees,
            rgViolation: identity.rgViolation,
            roiKind: "roi-vanished",
            roiPixelCount: 0
        )
    }

    package static func responseObjectiveState(
        plus: ResponseMetricSample,
        mid: ResponseMetricSample
    ) -> ResponseObjectiveState {
        guard plus.roiKind != "none", mid.roiKind != "none" else {
            return ResponseObjectiveState(
                hueDeltaDegrees: 0,
                rgDelta: 0,
                hueViolationDegrees: 0,
                rgViolation: 0,
                roiKind: "none",
                roiPixelCount: 0
            )
        }
        let hueDelta = wrappedDegrees(plus.hueDegrees - mid.hueDegrees)
        let rgDelta = plus.rgRatio - mid.rgRatio
        let hueLower = responseHueLowerBoundDegrees + responseHueMarginDegrees
        let hueUpper = responseHueUpperBoundDegrees - responseHueMarginDegrees
        let rgLower = responseRGLowerBound + responseRGMargin
        let rgUpper = responseRGUpperBound - responseRGMargin
        return ResponseObjectiveState(
            hueDeltaDegrees: hueDelta,
            rgDelta: rgDelta,
            hueViolationDegrees: max(0, hueLower - hueDelta) + max(0, hueDelta - hueUpper),
            rgViolation: max(0, rgLower - rgDelta) + max(0, rgDelta - rgUpper),
            roiKind: plus.roiKind,
            roiPixelCount: min(plus.roiPixelCount, mid.roiPixelCount)
        )
    }

    private static func responseScore(rmse8: Double, state: ResponseObjectiveState?) -> Double {
        guard let state else { return rmse8 }
        return rmse8
            + responseScoreHueWeight * state.hueViolationDegrees
            + responseScoreRGWeight * state.rgViolation
    }

    package static func styleData(parameters: [Double]) throws -> Data {
        guard parameters.count == directParameterIndices.count else {
            throw CLIError.invalidContainer("invalid constrained key-1 parameter vector")
        }
        var coefficientDeltas = Array(
            repeating: 0.0,
            count: AppleStyleDataLayout.blockValueCount
        )
        for (parameterIndex, coefficientIndex) in directParameterIndices.enumerated() {
            coefficientDeltas[coefficientIndex] = parameters[parameterIndex]
        }
        return try styleData(coefficientDeltas: coefficientDeltas)
    }

    package static func styleData(coefficientDeltas: [Double]) throws -> Data {
        guard coefficientDeltas.count == AppleStyleDataLayout.blockValueCount else {
            throw CLIError.invalidContainer("invalid constrained key-1 coefficient vector")
        }
        for index in coefficientDeltas.indices {
            guard coefficientDeltas[index].isFinite,
                  abs(coefficientDeltas[index]) <= bound(forCoefficientIndex: index) + 1e-9 else {
                throw CLIError.invalidContainer("invalid constrained key-1 coefficient vector")
            }
        }
        var block = [Float](repeating: 0, count: AppleStyleDataLayout.blockValueCount)
        for index in AppleStyleDataLayout.identityIndices { block[index] = 1 }
        for index in coefficientDeltas.indices {
            block[index] += Float(coefficientDeltas[index])
        }
        var result = Data()
        result.reserveCapacity(AppleStyleDataLayout.byteCount)
        for _ in 0..<AppleStyleDataLayout.tileCount {
            for value in block {
                var bits = XDRemuxHalf.encode(value).littleEndian
                withUnsafeBytes(of: &bits) { result.append(contentsOf: $0) }
            }
        }
        _ = try AppleStyleDataLayout.validate(result)
        return result
    }

    package static func fitGlobalPolynomial(
        sourceRGB8: [Float],
        targetRGB8: [Float]
    ) throws -> [Double] {
        guard sourceRGB8.count == targetRGB8.count,
              sourceRGB8.count >= 3,
              sourceRGB8.count.isMultiple(of: 3),
              sourceRGB8.allSatisfy(\.isFinite),
              targetRGB8.allSatisfy(\.isFinite) else {
            throw CLIError.invalidContainer(
                "invalid raster pair for constrained global polynomial fit"
            )
        }
        let termCount = AppleStyleDataLayout.polynomialCount
        var coefficients = Array(
            repeating: 0.0,
            count: AppleStyleDataLayout.blockValueCount
        )
        let pixelCount = sourceRGB8.count / 3
        let pixelStride = max(1, pixelCount / 100_000)
        let sampledPixelCount = (pixelCount + pixelStride - 1) / pixelStride
        var basisValues = Array(
            repeating: 0.0,
            count: sampledPixelCount * termCount
        )
        sourceRGB8.withUnsafeBufferPointer { source in
            basisValues.withUnsafeMutableBufferPointer { basis in
                for sampledPixel in 0..<sampledPixelCount {
                    let sourceOffset = sampledPixel * pixelStride * 3
                    let basisOffset = sampledPixel * termCount
                    let red = Double(source[sourceOffset]) / 255.0
                    let green = Double(source[sourceOffset + 1]) / 255.0
                    let blue = Double(source[sourceOffset + 2]) / 255.0
                    basis[basisOffset] = 1
                    basis[basisOffset + 1] = red
                    basis[basisOffset + 2] = green
                    basis[basisOffset + 3] = blue
                    basis[basisOffset + 4] = red * red
                    basis[basisOffset + 5] = red * green
                    basis[basisOffset + 6] = red * blue
                    basis[basisOffset + 7] = green * green
                    basis[basisOffset + 8] = green * blue
                    basis[basisOffset + 9] = blue * blue
                }
            }
        }

        for _ in 0..<3 {
            for output in 0..<3 {
                var normal = Array(repeating: 0.0, count: termCount * termCount)
                var rightHandSide = Array(repeating: 0.0, count: termCount)
                sourceRGB8.withUnsafeBufferPointer { source in
                    targetRGB8.withUnsafeBufferPointer { target in
                        basisValues.withUnsafeBufferPointer { basis in
                            coefficients.withUnsafeBufferPointer { coefficientBuffer in
                                normal.withUnsafeMutableBufferPointer { normalBuffer in
                                    rightHandSide.withUnsafeMutableBufferPointer { rhs in
                                        for sampledPixel in 0..<sampledPixelCount {
                                            let sourceOffset = sampledPixel * pixelStride * 3
                                            let basisOffset = sampledPixel * termCount
                                            let observed = Double(
                                                target[sourceOffset + output]
                                                    - source[sourceOffset + output]
                                            ) / 255.0
                                            var predicted = 0.0
                                            for term in 0..<termCount {
                                                predicted += basis[basisOffset + term]
                                                    * coefficientBuffer[term * 3 + output]
                                            }
                                            let residual = observed - predicted
                                            let huberThreshold = 4.0 / 255.0
                                            var weight = min(
                                                1.0,
                                                huberThreshold / max(huberThreshold, abs(residual))
                                            )
                                            if source[sourceOffset + output] <= 2
                                                || source[sourceOffset + output] >= 253 {
                                                weight *= 0.25
                                            }
                                            for row in 0..<termCount {
                                                let rowValue = basis[basisOffset + row]
                                                rhs[row] += weight * rowValue * observed
                                                let normalRowOffset = row * termCount
                                                for column in row..<termCount {
                                                    normalBuffer[normalRowOffset + column] += weight
                                                        * rowValue * basis[basisOffset + column]
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                for row in 0..<termCount {
                    for column in 0..<row {
                        normal[row * termCount + column] = normal[column * termCount + row]
                    }
                }
                let trace = (0..<termCount).reduce(0.0) {
                    $0 + normal[$1 * termCount + $1]
                }
                let ridge = max(trace / Double(termCount) * 1e-5, 1e-9)
                for term in 0..<termCount {
                    normal[term * termCount + term] += ridge * (term >= 4 ? 10 : 1)
                }
                let normalMatrix = (0..<termCount).map { row in
                    Array(normal[(row * termCount)..<((row + 1) * termCount)])
                }
                let solution = try solveLinearSystem(normalMatrix, rightHandSide)
                for term in 0..<termCount {
                    let coefficientIndex = term * 3 + output
                    let bound = bound(forCoefficientIndex: coefficientIndex)
                    coefficients[coefficientIndex] = min(
                        bound,
                        max(-bound, solution[term])
                    )
                }
            }
        }
        return coefficients
    }

    private static func bound(forCoefficientIndex index: Int) -> Double {
        index / 3 >= 4 ? quadraticBound : linearBound
    }

    private static let plistRangeLock = NSLock()
    private static var cachedPlistRanges: [String: (fileSize: Int, range: Range<Data.Index>)] = [:]

    // The solver injects ~39 candidates into the same immutable preliminary
    // HEIC; the plist location cannot move, so the full-file unique search is
    // done once per base file and revalidated by byte comparison afterwards.
    private static func identityPlistRange(
        in source: Data,
        of heicURL: URL,
        identityStylePropertyList: Data
    ) throws -> Range<Data.Index> {
        let key = heicURL.path
        plistRangeLock.lock()
        let cached = cachedPlistRanges[key]
        plistRangeLock.unlock()
        if let cached,
           cached.fileSize == source.count,
           cached.range.lowerBound >= source.startIndex,
           cached.range.upperBound <= source.endIndex,
           source[cached.range] == identityStylePropertyList {
            return cached.range
        }
        guard let range = uniqueRange(of: identityStylePropertyList, in: source) else {
            throw CLIError.invalidContainer(
                "preliminary style plist does not occur exactly once in the HEIC"
            )
        }
        plistRangeLock.lock()
        if cachedPlistRanges.count > 8 {
            cachedPlistRanges.removeAll(keepingCapacity: true)
        }
        cachedPlistRanges[key] = (source.count, range)
        plistRangeLock.unlock()
        return range
    }

    private static func injectStyleData(
        _ styleData: Data,
        into heicURL: URL,
        identityStylePropertyList: Data,
        outputURL: URL
    ) throws {
        let identity = try AppleStyleDataLayout.completeIdentity()
        guard let identityRange = uniqueRange(of: identity, in: identityStylePropertyList) else {
            throw CLIError.invalidContainer(
                "identity key 1 does not occur exactly once in the preliminary style plist"
            )
        }
        var replacementPropertyList = identityStylePropertyList
        replacementPropertyList.replaceSubrange(identityRange, with: styleData)
        let source = try Data(contentsOf: heicURL, options: [.mappedIfSafe])
        let range = try identityPlistRange(
            in: source,
            of: heicURL,
            identityStylePropertyList: identityStylePropertyList
        )
        var output = source
        output.replaceSubrange(range, with: replacementPropertyList)
        guard output.count == source.count else {
            throw CLIError.invalidContainer("key-1 injection changed HEIC byte length")
        }
        try output.write(to: outputURL, options: .atomic)
    }

    private static func uniqueRange(of needle: Data, in haystack: Data) -> Range<Data.Index>? {
        guard let first = haystack.range(of: needle) else { return nil }
        let remainder = first.upperBound..<haystack.endIndex
        guard haystack.range(of: needle, in: remainder) == nil else { return nil }
        return first
    }

    private static func metrics(_ left: Raster, _ right: Raster) -> Metrics {
        precondition(left.width == right.width && left.height == right.height)
        var squared = 0.0
        var absolute = 0.0
        var maximum = 0.0
        for index in left.rgb.indices {
            let difference = Double(left.rgb[index] - right.rgb[index])
            squared += difference * difference
            absolute += abs(difference)
            maximum = max(maximum, abs(difference))
        }
        let count = Double(max(1, left.rgb.count))
        return Metrics(
            rmse8: sqrt(squared / count),
            mae8: absolute / count,
            maximumAbsolute8: maximum
        )
    }

    private static func solveUpdate(
        current: Raster,
        target: Raster,
        derivatives: [[Float]],
        scalarRows: [(derivative: [Double], residual: Double, weight: Double)] = []
    ) throws -> [Double] {
        let count = solverRefinementParameterNames.count
        guard derivatives.count == count,
              derivatives.allSatisfy({ $0.count == current.rgb.count }),
              target.rgb.count == current.rgb.count,
              scalarRows.allSatisfy({
                  $0.derivative.count == count
                      && $0.derivative.allSatisfy(\.isFinite)
                      && $0.residual.isFinite
                      && $0.weight.isFinite
                      && $0.weight >= 0
              }) else {
            throw CLIError.invalidContainer("invalid constrained key-1 Jacobian")
        }
        var normal = Array(repeating: Array(repeating: 0.0, count: count), count: count)
        var gradient = Array(repeating: 0.0, count: count)
        let stride = max(1, current.rgb.count / (50_000 * 3))
        var sampleCount = 0
        for pixel in Swift.stride(from: 0, to: current.rgb.count / 3, by: stride) {
            for channel in 0..<3 {
                let sample = pixel * 3 + channel
                let residual = Double(target.rgb[sample] - current.rgb[sample])
                let huberWeight = min(1.0, 12.0 / max(12.0, abs(residual)))
                sampleCount += 1
                for row in 0..<count {
                    let rowValue = Double(derivatives[row][sample])
                    gradient[row] += huberWeight * rowValue * residual
                    for column in row..<count {
                        normal[row][column] += huberWeight
                            * rowValue * Double(derivatives[column][sample])
                    }
                }
            }
        }
        // Mean-scale the pixel block so scalar-response rows carry
        // sample-count-independent weights; the pure pixel solution is
        // unchanged because the linear system is scale invariant.
        if sampleCount > 0 {
            let normalization = 1.0 / Double(sampleCount)
            for row in 0..<count {
                gradient[row] *= normalization
                for column in row..<count {
                    normal[row][column] *= normalization
                }
            }
        }
        for scalar in scalarRows {
            for row in 0..<count {
                gradient[row] += scalar.weight * scalar.derivative[row] * scalar.residual
                for column in row..<count {
                    normal[row][column] += scalar.weight
                        * scalar.derivative[row] * scalar.derivative[column]
                }
            }
        }
        for row in 0..<count {
            for column in 0..<row { normal[row][column] = normal[column][row] }
        }
        let trace = (0..<count).reduce(0.0) { $0 + normal[$1][$1] }
        let ridge = max(trace / Double(count) * 1e-6, 1e-9)
        for index in 0..<count { normal[index][index] += ridge }
        var solution = try solveLinearSystem(normal, gradient)
        for index in solution.indices {
            solution[index] = min(epsilon, max(-epsilon, solution[index]))
        }
        return solution
    }

    private static func solveLinearSystem(
        _ matrix: [[Double]],
        _ vector: [Double]
    ) throws -> [Double] {
        let count = vector.count
        var augmented = zip(matrix, vector).map { $0 + [$1] }
        for pivot in 0..<count {
            let best = (pivot..<count).max {
                abs(augmented[$0][pivot]) < abs(augmented[$1][pivot])
            }!
            guard abs(augmented[best][pivot]) > 1e-12 else {
                throw CLIError.invalidContainer("constrained key-1 Jacobian is singular")
            }
            if best != pivot { augmented.swapAt(best, pivot) }
            let divisor = augmented[pivot][pivot]
            for column in pivot...count { augmented[pivot][column] /= divisor }
            for row in 0..<count where row != pivot {
                let factor = augmented[row][pivot]
                for column in pivot...count {
                    augmented[row][column] -= factor * augmented[pivot][column]
                }
            }
        }
        return augmented.map { $0[count] }
    }

    private static func refinementDictionary(_ values: [Double]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: zip(solverRefinementParameterNames, values))
    }

    private static func coefficientDictionary(_ values: [Double]) -> [String: Double] {
        var result: [String: Double] = [:]
        for term in 0..<basisNames.count {
            for output in 0..<outputNames.count {
                result["\(basisNames[term])->\(outputNames[output])"] = values[term * 3 + output]
            }
        }
        return result
    }

    private static func writeJSON(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
    }
}
