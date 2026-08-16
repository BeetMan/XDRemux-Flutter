import Foundation

package enum EncodingQualityPolicy {
    package static func value(
        environmentKey: String,
        defaultValue: Double,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Double {
        override(environmentKey: environmentKey, environment: environment) ?? defaultValue
    }

    package static func override(
        environmentKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Double? {
        guard let raw = environment[environmentKey],
              let value = Double(raw),
              value.isFinite,
              value > 0,
              value <= 1 else {
            return nil
        }
        return value
    }

    package static func integer(
        environmentKey: String,
        defaultValue: Int,
        allowedValues: Set<Int>,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let raw = environment[environmentKey],
              let value = Int(raw),
              allowedValues.contains(value) else {
            return defaultValue
        }
        return value
    }
}
