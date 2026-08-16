import Foundation
import XDRemuxCore

public enum AppleFeatureConversionEngine {
    public static func convert(_ request: ConversionRequest) throws -> ConversionResult {
        let configuration = request.configuration
        guard configuration.appleFeaturesEnabled else {
            return try ConversionEngine.convert(request)
        }
        guard !configuration.oppoCompatibility.wantsOppoCompat else {
            throw XDRemuxError.invalidValue(
                option: configuration.applePhotographicStyles
                    ? "--apple-photographic-styles"
                    : "--apple-portrait",
                value: "cannot be combined with OPPO-compatible output"
            )
        }

        if configuration.applePhotographicStyles {
            try ApplePhotographicStylesPipeline.convert(
                inputURL: request.input.url,
                outputURL: request.output.url,
                configuration: configuration
            )
        } else {
            _ = try PortraitConversionPipeline.convertIfNeeded(
                inputURL: request.input.url,
                outputURL: request.output.url,
                mode: configuration.applePortrait ? .on : .off,
                eventHandler: configuration.eventHandler
            )
        }
        return ConversionResult(input: request.input, output: request.output)
    }

    public static func convert(
        inputURL: URL,
        outputURL: URL,
        configuration: ConversionConfiguration
    ) throws {
        _ = try convert(
            ConversionRequest(
                input: InputSource(url: inputURL),
                output: OutputDestination(url: outputURL),
                configuration: configuration
            )
        )
    }

    public static func isValidOutput(
        _ outputURL: URL,
        options: AppleFeatureOptions
    ) -> Bool {
        if options.photographicStyles {
            return ApplePhotographicStylesPipeline.isValidOutput(
                outputURL,
                expectsPortrait: options.portrait
            )
        }
        return options.portrait
            ? PortraitConversionPipeline.isValidOutput(outputURL)
            : ConversionEngine.isValidISOGainMapOutput(outputURL)
    }

    public static func validationReport(
        for outputURL: URL,
        expectsPortrait: Bool
    ) throws -> [String: Any] {
        try ApplePhotographicStylesPipeline.validateExistingOutput(
            outputURL,
            expectsPortrait: expectsPortrait
        )
    }

    public static func portraitValidationReport(for outputURL: URL) throws -> [String: Any] {
        try PortraitConversionPipeline.validationReport(outputURL)
    }

    public static func portraitSelfTestReport() throws -> [String: Any] {
        try PortraitConversionPipeline.coreSelfTestReport()
    }

    public static func isConvertiblePortraitInput(_ inputURL: URL) -> Bool {
        PortraitConversionPipeline.isConvertibleInput(inputURL)
    }

    public static func hasValidISOGainMap(_ inputURL: URL) -> Bool {
        PortraitConversionPipeline.hasValidISOGainMap(inputURL)
    }
}
