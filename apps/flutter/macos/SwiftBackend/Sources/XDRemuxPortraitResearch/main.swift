import Foundation
import XDRemuxFlutterBackend

private enum CLIError: LocalizedError {
    case usage(String)

    var errorDescription: String? {
        switch self {
        case let .usage(message): return message
        }
    }
}

private func printUsage() {
    print("""
    Usage:
      XDREMUX_ENABLE_PORTRAIT_RESEARCH=1 PATH=/opt/homebrew/bin:$PATH \\
        swift run xdremux-portrait-research \\
        --input sample.heic --output-dir /tmp/xdremux-portrait-research

    Options:
      --input <file>          Repeatable HEIC input path.
      --input-dir <directory> Add all .heic files in a directory.
      --output-dir <dir>     Output directory (required).
      --variants <list>      Comma list: p20,p50,p80,uniform:0.005
    """)
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--help") || arguments.isEmpty {
        printUsage()
        if arguments.isEmpty {
            throw CLIError.usage("missing arguments")
        }
        exit(0)
    }

    var inputs: [URL] = []
    var inputDirectories: [URL] = []
    var outputDirectory: URL?
    var variantSpecs = PortraitCalibrationResearch.defaultVariantSpecs
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--input", "--input-dir", "--output-dir", "--variants":
            index += 1
            guard index < arguments.count else {
                throw CLIError.usage("missing value for \(argument)")
            }
            let value = arguments[index]
            switch argument {
            case "--input":
                inputs.append(URL(fileURLWithPath: value))
            case "--input-dir":
                inputDirectories.append(URL(fileURLWithPath: value, isDirectory: true))
            case "--output-dir":
                outputDirectory = URL(fileURLWithPath: value, isDirectory: true)
            case "--variants":
                variantSpecs = value.split(separator: ",").map(String.init)
            default:
                break
            }
        default:
            throw CLIError.usage("unknown argument \(argument)")
        }
        index += 1
    }

    for directory in inputDirectories {
        let directoryInputs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        inputs.append(contentsOf: directoryInputs.filter {
            $0.pathExtension.lowercased() == "heic"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent })
    }
    guard !inputs.isEmpty else {
        throw CLIError.usage("at least one --input or --input-dir is required")
    }
    guard let outputDirectory else {
        throw CLIError.usage("--output-dir is required")
    }

    let manifest = try PortraitCalibrationResearch.run(
        inputs: inputs,
        outputDirectory: outputDirectory,
        variantSpecs: variantSpecs
    )
    let samples = manifest["samples"] as? [[String: Any]] ?? []
    let successCount = samples.filter { $0["success"] as? Bool == true }.count
    print("research manifest: \(outputDirectory.appendingPathComponent("manifest.json").path)")
    print("samples: \(successCount)/\(samples.count) completed")
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    printUsage()
    exit(1)
}
