import Foundation

/// Persists `ConversionConfig` as one JSON record, the way the Flutter app
/// keeps it in SharedPreferences. Same keys, so a record written by either
/// front-end decodes in the other.
public struct SettingsStore: Sendable {
    public static let defaultsKey = "xdremux.conversionConfig"

    private let read: @Sendable () -> Data?
    private let write: @Sendable (Data) -> Void

    public init(read: @escaping @Sendable () -> Data?, write: @escaping @Sendable (Data) -> Void) {
        self.read = read
        self.write = write
    }

    /// `suiteName == nil` uses `UserDefaults.standard`. The instance is
    /// resolved inside each closure so the store stays `Sendable`.
    public static func userDefaults(suiteName: String? = nil) -> SettingsStore {
        SettingsStore(
            read: { (suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard).data(forKey: defaultsKey) },
            write: { (suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard).set($0, forKey: defaultsKey) })
    }

    /// Malformed data falls back to defaults rather than failing the app.
    public func load() -> ConversionConfig {
        guard let data = read(),
              let config = try? JSONDecoder().decode(ConversionConfig.self, from: data) else {
            return ConversionConfig()
        }
        return config
    }

    public func save(_ config: ConversionConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        write(try encoder.encode(config))
    }
}
