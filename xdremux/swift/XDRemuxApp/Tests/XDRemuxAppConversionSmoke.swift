import Foundation

enum ConversionSmokeError: Error, CustomStringConvertible {
    case usage
    case invalidBranch(String)

    var description: String {
        switch self {
        case .usage:
            return "Usage: XDRemuxAppConversionSmoke <input.heic> <output.heic> [--input-processing system|hybrid|passthrough] [--oppo-compat]"
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
                config.oppoCompat = true
            default:
                throw ConversionSmokeError.usage
            }
        }

        try XDRemuxCore.convert(inputURL: inputURL, outputURL: outputURL, config: config)
        print(outputURL.path)
    }
}
