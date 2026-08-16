import Foundation
import XDRemuxCore

package struct AppleStyleDataRequest {
    let sourceURL: URL
    let renderedTargetURL: URL
    let outputDirectory: URL
    let sourceDomain: String
    let targetDomain: String
}

package struct AppleStyleDataResult {
    let styleData: Data
    let styleDataSHA256: String
    let polynomialCount: Int
    let blockValueCount: Int
    let tileCount: Int
    let producer: String
    let producerVersion: String
    let sourceSHA256: String
    let targetSHA256: String
    let sourceDomain: String
    let targetDomain: String
    let learnBufferKind: String?
    let solverKind: String?
    let evidence: AppleEvidenceClass
    let sceneMatched: Bool
    let identityFallback: Bool
    let fallbackKind: String?
    let reconstructionMetrics: [String: Any]
    let warnings: [String]

    var key1IncrementEligible: Bool {
        sceneMatched && !identityFallback && fallbackKind == nil
    }

    // key 1 admission cannot establish the correctness of the shared scene
    // payload.  A final HEIC becomes production-eligible only through the
    // separate full-scene + counterexample + structural + Photos receipt.
    var productionEligible: Bool { false }

    var manifest: [String: Any] {
        [
            "byteCount": styleData.count,
            "sha256": styleDataSHA256,
            "producer": producer,
            "producerVersion": producerVersion,
            "sourceSHA256": sourceSHA256,
            "targetSHA256": targetSHA256,
            "sourceDomain": sourceDomain,
            "targetDomain": targetDomain,
            "learnBufferKind": learnBufferKind.map { $0 as Any } ?? NSNull(),
            "solverKind": solverKind.map { $0 as Any } ?? NSNull(),
            "evidence": evidence.rawValue,
            "sceneMatched": sceneMatched,
            "key1IncrementEligible": key1IncrementEligible,
            "productionEligible": productionEligible,
            "productionEligibilityBoundary": "key 1 neutral and increment checks are necessary but not sufficient; direct full-scene and real Photos acceptance remain separate",
            "identityFallback": identityFallback,
            "fallbackKind": fallbackKind.map { $0 as Any } ?? NSNull(),
            "polynomialCount": polynomialCount,
            "blockValueCount": blockValueCount,
            "tileCount": tileCount,
            "reconstructionMetrics": reconstructionMetrics,
            "warnings": warnings,
        ]
    }
}

package protocol AppleStyleDataProducing {
    func makeStyleData(request: AppleStyleDataRequest) throws -> AppleStyleDataResult
}

package enum AppleStyleDataLayout {
    static let polynomialCount = 10
    static let channelCount = 3
    static let blockValueCount = polynomialCount * channelCount
    static let tileCount = 12 * 9 * 8
    static let byteCount = blockValueCount * tileCount * 2
    static let identityIndices = Set([3, 7, 11])
    static let identitySHA256 =
        "43e0ae73508cc10684d4be708fa1d19f3b55b8de15cb8e3544ef16300db91dbe"

    static func basis(red: Float, green: Float, blue: Float) throws -> [Float] {
        guard red.isFinite, green.isFinite, blue.isFinite else {
            throw CLIError.invalidContainer(
                "Apple style polynomial basis input contains NaN or Inf"
            )
        }
        return [
            1, red, green, blue,
            red * red, red * green, red * blue,
            green * green, green * blue, blue * blue,
        ]
    }

    private static let completeIdentityResult: Result<Data, Error> = Result {
        var block = Data()
        block.reserveCapacity(blockValueCount * 2)
        for index in 0..<blockValueCount {
            var bits = Float16(identityIndices.contains(index) ? 1 : 0)
                .bitPattern
                .littleEndian
            withUnsafeBytes(of: &bits) { block.append(contentsOf: $0) }
        }
        var result = Data()
        result.reserveCapacity(byteCount)
        for _ in 0..<tileCount {
            result.append(block)
        }
        guard result.count == byteCount, sha256Hex(result) == identitySHA256 else {
            throw CLIError.invalidContainer(
                "generated complete identity key 1 does not match the verified CMImaging coefficient layout"
            )
        }
        return result
    }

    static func completeIdentity() throws -> Data {
        try completeIdentityResult.get()
    }

    static func validate(_ data: Data) throws -> [String: Any] {
        guard data.count == byteCount else {
            throw CLIError.invalidContainer(
                "Apple style data has \(data.count) bytes; expected \(byteCount)"
            )
        }
        var minimum = Float.infinity
        var maximum = -Float.infinity
        var nonfiniteCount = 0
        var identitySquaredError = 0.0
        var maximumIdentityError = 0.0
        for valueIndex in 0..<(data.count / 2) {
            let offset = valueIndex * 2
            let bits = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            let value = Float(Float16(bitPattern: bits))
            if !value.isFinite {
                nonfiniteCount += 1
                continue
            }
            minimum = min(minimum, value)
            maximum = max(maximum, value)
            let localIndex = valueIndex % blockValueCount
            let expected: Float = identityIndices.contains(localIndex) ? 1 : 0
            let error = Double(value - expected)
            identitySquaredError += error * error
            maximumIdentityError = max(maximumIdentityError, abs(error))
        }
        guard nonfiniteCount == 0 else {
            throw CLIError.invalidContainer(
                "Apple style data contains \(nonfiniteCount) non-finite Float16 values"
            )
        }
        return [
            "finite": true,
            "valueCount": data.count / 2,
            "minimum": minimum,
            "maximum": maximum,
            "identityResidualRMSE": sqrt(identitySquaredError / Double(data.count / 2)),
            "identityResidualMaximumAbsolute": maximumIdentityError,
            "completeIdentity": sha256Hex(data) == identitySHA256,
        ]
    }
}

package struct IdentityStyleDataProducer: AppleStyleDataProducing {
    package func makeStyleData(
        request: AppleStyleDataRequest
    ) throws -> AppleStyleDataResult {
        try FileManager.default.createDirectory(
            at: request.outputDirectory,
            withIntermediateDirectories: true
        )
        let styleData = try AppleStyleDataLayout.completeIdentity()
        let output = request.outputDirectory
            .appendingPathComponent("identity-fallback-style-data.f16.bin")
        try styleData.write(to: output, options: .atomic)
        return AppleStyleDataResult(
            styleData: styleData,
            styleDataSHA256: sha256Hex(styleData),
            polynomialCount: AppleStyleDataLayout.polynomialCount,
            blockValueCount: AppleStyleDataLayout.blockValueCount,
            tileCount: AppleStyleDataLayout.tileCount,
            producer: "identityFallback",
            producerVersion: "identity-fallback-v1",
            sourceSHA256: sha256Hex(
                try Data(contentsOf: request.sourceURL, options: [.mappedIfSafe])
            ),
            targetSHA256: sha256Hex(
                try Data(contentsOf: request.renderedTargetURL, options: [.mappedIfSafe])
            ),
            sourceDomain: request.sourceDomain,
            targetDomain: request.targetDomain,
            learnBufferKind: nil,
            solverKind: nil,
            evidence: .privateFrameworkIdentity,
            sceneMatched: false,
            identityFallback: true,
            fallbackKind: "complete-identity",
            reconstructionMetrics: [
                "status": "not_learned",
                "layout": try AppleStyleDataLayout.validate(styleData),
            ],
            warnings: [
                "Explicit identity fallback selected; key 1 is not scene-matched."
            ]
        )
    }
}

package struct AppleLearnNodeStyleDataProducer: AppleStyleDataProducing {
    private static let producerVersion = "apple-learnnode-base-to-base-diagnostic-v3"

    package func makeStyleData(
        request: AppleStyleDataRequest
    ) throws -> AppleStyleDataResult {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: request.outputDirectory,
            withIntermediateDirectories: true
        )
        let helperOutput = request.outputDirectory
            .appendingPathComponent("learnnode", isDirectory: true)
        try fileManager.createDirectory(at: helperOutput, withIntermediateDirectories: true)
        let executable = try AppleNativeToolchain.learnExecutable()
        let process = try AppleNativeToolchain.run(
            executable,
            arguments: [
                request.sourceURL.path,
                request.renderedTargetURL.path,
                helperOutput.path,
            ],
            timeout: 180
        )
        guard !process.timedOut, process.status == 0 else {
            let stderr = String(data: process.stderr, encoding: .utf8) ?? ""
            throw CLIError.invalidContainer(
                "Apple LearnNode style-data producer failed: "
                    + (process.timedOut ? "helper exceeded 180 seconds; " : "")
                    + stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let rawURL = helperOutput.appendingPathComponent("learned_style.f16.bin")
        let probeURL = helperOutput.appendingPathComponent("probe.json")
        guard fileManager.fileExists(atPath: rawURL.path),
              fileManager.fileExists(atPath: probeURL.path) else {
            throw CLIError.invalidContainer(
                "Apple LearnNode did not emit style data and probe diagnostics"
            )
        }
        let styleData = try Data(contentsOf: rawURL, options: [.mappedIfSafe])
        let layout = try AppleStyleDataLayout.validate(styleData)
        let probe = try Self.probeObject(at: probeURL)
        try Self.validateProbe(probe)
        let metrics = try Self.reconstructionMetrics(
            helperOutput: helperOutput,
            probe: probe,
            layout: layout
        )
        let identityRMSE = metrics["identityBaselineRMSE"] as? Double ?? 0
        let learnedRMSE = metrics["learnedApplyRMSE"] as? Double ?? .infinity
        if identityRMSE <= 0.000_1 {
            guard learnedRMSE <= 0.000_1 else {
                throw CLIError.invalidContainer(
                    String(
                        format: "Apple LearnNode changed an already-matched target (identity %.8f, learned %.8f)",
                        identityRMSE,
                        learnedRMSE
                    )
                )
            }
        } else if learnedRMSE >= identityRMSE * 0.98 {
            throw CLIError.invalidContainer(
                String(
                    format: "Apple LearnNode candidate did not improve target reconstruction (identity %.8f, learned %.8f)",
                    identityRMSE,
                    learnedRMSE
                )
            )
        }
        guard layout["completeIdentity"] as? Bool != true else {
            throw CLIError.invalidContainer(
                "Apple LearnNode returned complete identity instead of photo-specific style data"
            )
        }
        let output = request.outputDirectory
            .appendingPathComponent("learnnode-near-identity-fallback.f16.bin")
        try styleData.write(to: output, options: .atomic)
        return AppleStyleDataResult(
            styleData: styleData,
            styleDataSHA256: sha256Hex(styleData),
            polynomialCount: AppleStyleDataLayout.polynomialCount,
            blockValueCount: AppleStyleDataLayout.blockValueCount,
            tileCount: AppleStyleDataLayout.tileCount,
            producer: "learnNodeNeutralDiagnostic",
            producerVersion: Self.producerVersion,
            sourceSHA256: sha256Hex(
                try Data(contentsOf: request.sourceURL, options: [.mappedIfSafe])
            ),
            targetSHA256: sha256Hex(
                try Data(contentsOf: request.renderedTargetURL, options: [.mappedIfSafe])
            ),
            sourceDomain: request.sourceDomain,
            targetDomain: request.targetDomain,
            learnBufferKind: "learned CIImage raw 160x162 kCIFormatRh Float16",
            solverKind: nil,
            evidence: .privateFrameworkNearIdentityFallback,
            sceneMatched: false,
            identityFallback: false,
            fallbackKind: "base-to-base-near-identity",
            reconstructionMetrics: metrics,
            warnings: [
                "Diagnostic Base-to-Base LearnNode output selected. This is a content-dependent near-identity fallback, not a scene-matched reverse style transform."
            ]
        )
    }

    private static func probeObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError.invalidContainer("Apple LearnNode probe JSON is malformed")
        }
        return object
    }

    private static func validateProbe(_ probe: [String: Any]) throws {
        guard probe["mode"] as? String == "direct",
              probe["hooksRestored"] as? Bool == true,
              let direction = probe["learnDirection"] as? [String: Any],
              direction["swapped"] as? Bool == false,
              let output = probe["rawOutput"] as? [String: Any],
              (output["length"] as? NSNumber)?.intValue == AppleStyleDataLayout.byteCount,
              output["format"] as? String == "kCIFormatRh" else {
            throw CLIError.invalidContainer(
                "Apple LearnNode probe did not return the verified normal raw Float16 contract"
            )
        }
    }

    private static func reconstructionMetrics(
        helperOutput: URL,
        probe: [String: Any],
        layout: [String: Any]
    ) throws -> [String: Any] {
        let source = try halfRGB(
            at: helperOutput.appendingPathComponent("input_thumbnail.rgba16f.bin")
        )
        let target = try halfRGB(
            at: helperOutput.appendingPathComponent("target_thumbnail.rgba16f.bin")
        )
        let applied = try halfRGB(
            at: helperOutput.appendingPathComponent("learned_applied_thumbnail.rgba16f.bin")
        )
        guard source.count == target.count, target.count == applied.count else {
            throw CLIError.invalidContainer(
                "Apple LearnNode reconstruction captures have different dimensions"
            )
        }
        let identityRMSE = rmse(source, target)
        let learnedRMSE = rmse(applied, target)
        let improvement = identityRMSE == 0 ? 0 : 1 - learnedRMSE / identityRMSE
        return [
            "status": "measured",
            "evidence": "private _NUStyleTransferApplyProcessor diagnostic",
            "identityBaselineRMSE": identityRMSE,
            "learnedApplyRMSE": learnedRMSE,
            "rmseImprovementFraction": improvement,
            "sampleCount": source.count / 3,
            "styleDataLayout": layout,
            "probeSchema": probe["schema"] as? String ?? "unknown",
        ]
    }

    private static func halfRGB(at url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count > 0, data.count.isMultiple(of: 8) else {
            throw CLIError.invalidContainer(
                "Apple LearnNode RGBA16F capture has invalid length \(data.count)"
            )
        }
        var result: [Float] = []
        result.reserveCapacity(data.count / 8 * 3)
        for pixelOffset in stride(from: 0, to: data.count, by: 8) {
            for channelOffset in stride(from: 0, through: 4, by: 2) {
                let offset = pixelOffset + channelOffset
                let bits = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
                let value = Float(Float16(bitPattern: bits))
                guard value.isFinite else {
                    throw CLIError.invalidContainer(
                        "Apple LearnNode RGBA16F capture contains NaN or Inf"
                    )
                }
                result.append(value)
            }
        }
        return result
    }

    private static func rmse(_ left: [Float], _ right: [Float]) -> Double {
        var squaredError = 0.0
        for index in left.indices {
            let difference = Double(left[index] - right[index])
            squaredError += difference * difference
        }
        return sqrt(squaredError / Double(left.count))
    }
}
