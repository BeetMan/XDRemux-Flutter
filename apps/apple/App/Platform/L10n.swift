import Foundation
import XDRemuxModel

/// In-app language override (Settings → 语言 / Language).
///
/// SwiftUI `Text` follows the `locale` environment the root view sets from
/// `LibraryModel.config.language`. Strings built in model code cannot see
/// that environment, so they go through `L(_:)`, which reads the matching
/// `.lproj` bundle instead of the process locale. `system` means both fall
/// back to the device language.
enum L10n {
    nonisolated(unsafe) private(set) static var bundle: Bundle = .main
    nonisolated(unsafe) private(set) static var locale: Locale = .autoupdatingCurrent

    static func apply(_ language: AppLanguage) {
        if let id = language.localeIdentifier,
           let path = Bundle.main.path(forResource: id, ofType: "lproj"),
           let languageBundle = Bundle(path: path) {
            bundle = languageBundle
            locale = Locale(identifier: id)
        } else {
            bundle = .main
            locale = .autoupdatingCurrent
        }
    }
}

/// `String(localized:)` that honours the in-app language.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: L10n.bundle, locale: L10n.locale)
}
