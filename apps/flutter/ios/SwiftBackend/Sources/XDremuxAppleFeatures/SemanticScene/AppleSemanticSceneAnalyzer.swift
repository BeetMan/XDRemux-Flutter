import Foundation
import XDRemuxCore

package enum AppleSemanticSceneAnalyzer {
    static func copyEvidence(from sourceDirectory: URL, to outputDirectory: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceDirectory.path) else {
            throw CLIError.invalidContainer("shared Vision semantic evidence is unavailable")
        }
        if fileManager.fileExists(atPath: outputDirectory.path) {
            try fileManager.removeItem(at: outputDirectory)
        }
        try fileManager.copyItem(at: sourceDirectory, to: outputDirectory)

        let manifestURL = outputDirectory.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: manifestURL)
        ) as? [String: Any],
              let rows = manifest["masks"] as? [[String: Any]] else {
            throw CLIError.invalidContainer("shared Vision semantic manifest is invalid")
        }
        manifest["masks"] = rows.map { row in
            var relocated = row
            for key in ["raw_output", "output"] {
                guard let oldPath = row[key] as? String else { continue }
                relocated[key] = outputDirectory
                    .appendingPathComponent(URL(fileURLWithPath: oldPath).lastPathComponent)
                    .path
            }
            return relocated
        }
        try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys]
        ).write(to: manifestURL, options: .atomic)
    }

    static func analyze(
        imageURL: URL,
        outputDirectory: URL,
        orientationOverride: UInt32? = nil,
        profile: AppleSemanticWriteProfile = .portraitAndStyles,
        writePNGEvidence: Bool = false
    ) throws -> AppleSemanticSceneAnalysis {
        let startedAt = CFAbsoluteTimeGetCurrent()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let executable = try AppleNativeToolchain.semanticExecutable()
        var arguments = [imageURL.path, outputDirectory.path]
        if let orientationOverride {
            arguments += ["--orientation", String(orientationOverride)]
        }
        let helperRoles = profile.orderedRoles.map { role in
            role == .person ? "portrait" : role.rawValue
        }
        arguments += ["--roles", helperRoles.joined(separator: ",")]
        if !writePNGEvidence {
            arguments.append("--raw-only")
        }
        let result = try AppleNativeToolchain.run(executable, arguments: arguments)
        guard result.status == 0 else {
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
            throw CLIError.invalidContainer(
                "Apple semantic capability unavailable: \([stderr, stdout].filter { !$0.isEmpty }.joined(separator: " "))"
            )
        }
        try result.stdout.write(
            to: outputDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        guard let object = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              object["ok"] as? Bool == true,
              let requestCount = (object["request_count"] as? NSNumber)?.intValue,
              let maskRows = object["masks"] as? [[String: Any]] else {
            throw CLIError.invalidContainer("Apple semantic helper returned an invalid manifest")
        }
        var mattes: [String: AppleSemanticMatte] = [:]
        for row in maskRows {
            guard let name = row["name"] as? String,
                  let rawPath = row["raw_output"] as? String,
                  let width = (row["width"] as? NSNumber)?.intValue,
                  let height = (row["height"] as? NSNumber)?.intValue,
                  let serializedBytesPerRow = (row["serialized_bytes_per_row"] as? NSNumber)?.intValue,
                  let minimum = (row["minimum"] as? NSNumber)?.uint8Value,
                  let maximum = (row["maximum"] as? NSNumber)?.uint8Value,
                  let mean = (row["mean"] as? NSNumber)?.doubleValue,
                  let coverage = (row["coverage"] as? NSNumber)?.doubleValue,
                  let requestClass = row["request_class"] as? String,
                  let revision = (row["revision"] as? NSNumber)?.intValue,
                  let inputSHA256 = row["input_sha256"] as? String,
                  let pixelFormat = row["pixel_format"] as? String,
                  let orientation = (row["orientation"] as? NSNumber)?.uint32Value,
                  let orientationTransform = row["orientation_transform"] as? String,
                  let fallback = row["fallback"] as? Bool else {
                throw CLIError.invalidContainer("incomplete semantic manifest row")
            }
            let attributeName = row["feature_name"] as? String ?? name
            let pixels = try Data(contentsOf: URL(fileURLWithPath: rawPath))
            guard serializedBytesPerRow == width, pixels.count == width * height else {
                throw CLIError.invalidContainer(
                    "\(name) semantic matte has invalid L008 geometry or data length"
                )
            }
            mattes[name] = AppleSemanticMatte(
                pixels: pixels,
                width: width,
                height: height,
                bytesPerRow: serializedBytesPerRow,
                statistics: SemanticStatistics(
                    minimum: minimum,
                    maximum: maximum,
                    mean: mean,
                    coverage: coverage
                ),
                provenance: SemanticProvenance(
                    requestClass: requestClass,
                    attributeName: attributeName,
                    revision: revision,
                    inputSHA256: inputSHA256,
                    width: width,
                    height: height,
                    pixelFormat: pixelFormat,
                    orientation: orientation,
                    orientationTransform: orientationTransform,
                    fallback: fallback
                )
            )
        }
        let requiredMasks = profile.orderedRoles.map { role in
            role == .person ? "portrait" : role.rawValue
        }
        for required in requiredMasks {
            guard mattes[required] != nil else {
                throw CLIError.invalidContainer("Vision returned no \(required) semantic resource")
            }
        }
        print(String(
            format: "Vision semantic request batch profile=%@ requests=%d masks=%d pngEvidence=%@ elapsed=%.3fs",
            profile.kind.rawValue,
            requestCount,
            mattes.count,
            writePNGEvidence.description,
            CFAbsoluteTimeGetCurrent() - startedAt
        ))
        return AppleSemanticSceneAnalysis(
            person: mattes["portrait"],
            skin: mattes["skin"],
            hair: mattes["hair"],
            teeth: mattes["teeth"],
            glasses: mattes["glasses"],
            sky: mattes["sky"]
        )
    }
}
