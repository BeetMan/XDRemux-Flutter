import Foundation

enum ConversionSmokeError: Error, CustomStringConvertible {
    case usage
    case invalidBranch(String)

    var description: String {
        switch self {
        case .usage:
            return "Usage: XDRemuxAppConversionSmoke <input.heic> <output.heic> [--input-processing system|system-decoded|hybrid|passthrough] [--tmap-format strict|imageio] [--oppo-compat] [--oppo-compat-mode auto|iso|iso-no-local|iso-graph|on|tail|off] [--oppo-camera-tail preserve|preserve-without-portrait|preserve-without-private-uhdr|preserve-without-private-hdr|preserve-no-uhdr|preserve-no-hdr|watermark|compact|off]"
        case .invalidBranch(let value):
            return "invalid input processing branch: \(value)"
        }
    }
}

@main
struct XDRemuxAppConversionSmoke {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else {
            throw ConversionSmokeError.usage
        }

        let inputURL = URL(fileURLWithPath: args[0])
        let outputURL = URL(fileURLWithPath: args[1])
        var config = ConversionConfig()

        var index = 2
        while index < args.count {
            let option = args[index]
            index += 1
            switch option {
            case "--input-processing":
                guard index < args.count else { throw ConversionSmokeError.usage }
                let value = args[index]
                index += 1
                guard let branch = InputProcessingBranch(rawValue: value) else {
                    throw ConversionSmokeError.invalidBranch(value)
                }
                config.inputProcessingBranch = branch
            case "--oppo-compat":
                config.oppoCompatibility = .on
            case "--tmap-format":
                guard index < args.count else { throw ConversionSmokeError.usage }
                let value = args[index]
                index += 1
                guard let format = TmapFormat(rawValue: value) else {
                    throw ConversionSmokeError.usage
                }
                config.tmapFormat = format
            case "--oppo-compat-mode":
                guard index < args.count else { throw ConversionSmokeError.usage }
                let value = args[index]
                index += 1
                guard let mode = OppoCompatibility(rawValue: value) else {
                    throw ConversionSmokeError.usage
                }
                config.oppoCompatibility = mode
            case "--oppo-camera-tail":
                guard index < args.count else { throw ConversionSmokeError.usage }
                let value = args[index]
                index += 1
                guard let mode = OppoCameraTail(rawValue: value) else {
                    throw ConversionSmokeError.usage
                }
                config.oppoCameraTail = mode
            default:
                throw ConversionSmokeError.usage
            }
        }

        try XDRemuxCore.convert(inputURL: inputURL, outputURL: outputURL, config: config)
        print(outputURL.path)
    }
}
