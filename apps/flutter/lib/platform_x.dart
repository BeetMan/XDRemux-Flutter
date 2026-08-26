import 'dart:io';

/// OHOS-aware platform helpers.
///
/// The CPF-Flutter OpenHarmony fork reports `Platform.operatingSystem ==
/// 'ohos'`; stock Flutter never does. Use these helpers instead of raw
/// `Platform.isX` gates so OHOS lands in the intended bucket (mobile-like).
class PlatformX {
  PlatformX._();

  /// True only on the OpenHarmony fork runtime.
  static final bool isOhos = Platform.operatingSystem == 'ohos';

  /// Android / iOS / OHOS — sandboxed mobile-style platforms (SAF-like file
  /// access, no raw directory recursion, foreground-service model).
  static bool get isMobile => Platform.isAndroid || Platform.isIOS || isOhos;

  /// Windows / macOS / Linux desktop platforms.
  static bool get isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// Platforms where the native MethodChannel thumbnail decode exists
  /// (ImageIO / ImageDecoder / WIC). OHOS has no such channel yet.
  static bool get hasNativeThumbnail =>
      Platform.isMacOS || Platform.isIOS || Platform.isAndroid || Platform.isWindows;
}
