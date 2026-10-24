import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

import '../l10n/l10n.dart';

// Raw FFI declarations instead of package:win32: the OHOS vendored plugin set
// pins win32 v5 while mainline uses v6, and our needs (three User32 calls)
// are tiny. IntPtr handles keep this version-agnostic.
typedef _FindWindowNative = IntPtr Function(
  Pointer<Utf16> lpClassName,
  Pointer<Utf16> lpWindowName,
);
typedef _FindWindowDart = int Function(
  Pointer<Utf16> lpClassName,
  Pointer<Utf16> lpWindowName,
);
typedef _ShowWindowNative = Int32 Function(IntPtr hWnd, Int32 nCmdShow);
typedef _ShowWindowDart = int Function(int hWnd, int nCmdShow);
typedef _SetForegroundWindowNative = Int32 Function(IntPtr hWnd);
typedef _SetForegroundWindowDart = int Function(int hWnd);

// User32 is opened lazily and only on Windows. Doing this at import time
// throws on Linux/macOS ("user32.dll" cannot be loaded), which would crash
// app startup as soon as main.dart imports this service.
class _User32 {
  _User32._(DynamicLibrary library)
    : findWindow = library.lookupFunction<_FindWindowNative, _FindWindowDart>(
        'FindWindowW',
      ),
      showWindow = library.lookupFunction<_ShowWindowNative, _ShowWindowDart>(
        'ShowWindow',
      ),
      setForegroundWindow = library
          .lookupFunction<
            _SetForegroundWindowNative,
            _SetForegroundWindowDart
          >('SetForegroundWindow');

  static _User32? _instance;

  /// Only call on Windows; TrayService's initialized flag gates every caller.
  static _User32 get instance =>
      _instance ??= _User32._(DynamicLibrary.open('user32.dll'));

  final _FindWindowDart findWindow;
  final _ShowWindowDart showWindow;
  final _SetForegroundWindowDart setForegroundWindow;
}

const int _swHide = 0;
const int _swRestore = 9;

/// Windows system tray: lets the app hide to the tray during long batch
/// conversions instead of occupying the taskbar.
///
/// No-op on non-Windows platforms and when the tray icon cannot be created
/// (e.g. widget tests, where the native runner window doesn't exist).
class TrayService {
  TrayService._();

  static bool _initialized = false;
  static bool _hidden = false;

  static bool get isHidden => _hidden;

  /// Create the tray icon and context menu. Safe to call on every startup.
  static Future<void> init({
    required void Function() onShowWindow,
    required void Function() onExit,
  }) async {
    if (_initialized || !Platform.isWindows) return;
    try {
      final iconPath =
          '${File(Platform.resolvedExecutable).parent.path}\\data\\flutter_assets\\app_icon.ico';
      // Fall back to the exe icon when no asset icon exists.
      await trayManager.setIcon(
        File(iconPath).existsSync() ? iconPath : Platform.resolvedExecutable,
      );
      await trayManager.setToolTip('XDRemux');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(
              key: 'show',
              label: t('显示窗口', 'Show window'),
              onClick: (_) => onShowWindow(),
            ),
            MenuItem.separator(),
            MenuItem(
              key: 'exit',
              label: t('退出', 'Exit'),
              onClick: (_) => onExit(),
            ),
          ],
        ),
      );
      _initialized = true;
    } catch (e) {
      debugPrint('[XDRemux][tray] init failed, tray disabled: $e');
    }
  }

  /// Update the tray tooltip (e.g. live batch progress).
  static Future<void> setToolTip(String text) async {
    if (!_initialized) return;
    try {
      await trayManager.setToolTip(text);
    } catch (_) {}
  }

  /// Hide the main window: remove it from the taskbar, keep the tray icon.
  static void hideWindow() {
    if (!Platform.isWindows || !_initialized || _hidden) return;
    final hwnd = _findMainWindow();
    if (hwnd != 0) {
      _User32.instance.showWindow(hwnd, _swHide);
      _hidden = true;
    }
  }

  /// Restore the main window from the tray.
  static void showWindow() {
    if (!Platform.isWindows || !_initialized || !_hidden) return;
    final hwnd = _findMainWindow();
    if (hwnd != 0) {
      _User32.instance.showWindow(hwnd, _swRestore);
      _User32.instance.setForegroundWindow(hwnd);
      _hidden = false;
    }
  }

  /// The runner registers the window class FLUTTER_RUNNER_WIN32_WINDOW with
  /// the app title "XDRemux"; matching on the class name avoids colliding
  /// with any other window that happens to share the title.
  static int _findMainWindow() {
    final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    try {
      return _User32.instance.findWindow(className, nullptr);
    } finally {
      malloc.free(className);
    }
  }
}
