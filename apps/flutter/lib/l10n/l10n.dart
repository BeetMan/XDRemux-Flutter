/// App-wide UI language plus the tiny `t()` localization helper.
///
/// The app is bilingual (Chinese primary, English secondary). UI strings are
/// written inline as `t('中文', 'English')` and resolved against [uiLanguage].
/// Language changes only happen through the settings sheet, which rebuilds the
/// home page afterwards, so a plain global (rather than an InheritedWidget) is
/// enough for the current widget tree.
library;

/// UI language shown by the app. Mirrors `ConversionConfig.language`.
enum AppLanguage {
  chinese,
  english;

  String get appTitle => this == AppLanguage.chinese ? '中文' : 'English';
}

/// Active UI language. Updated when the persisted config loads and whenever
/// the user changes the language in settings.
AppLanguage uiLanguage = AppLanguage.chinese;

/// Resolve a zh/en string pair against the active language.
String t(String chinese, String english) =>
    uiLanguage == AppLanguage.english ? english : chinese;

/// Change the active language. Callers are responsible for triggering a
/// widget rebuild afterwards.
void setUiLanguage(AppLanguage value) {
  uiLanguage = value;
}
