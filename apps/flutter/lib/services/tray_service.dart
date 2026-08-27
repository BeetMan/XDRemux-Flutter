import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:win32/win32.dart';

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
            MenuItem(key: 'show', label: '显示窗口', onClick: (_) => onShowWindow()),
            MenuItem.separator(),
            MenuItem(key: 'exit', label: '退出', onClick: (_) => onExit()),
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
    if (!_initialized || _hidden) return;
    final hwnd = _findMainWindow();
    if (hwnd.address != 0) {
      ShowWindow(hwnd, SW_HIDE);
      _hidden = true;
    }
  }

  /// Restore the main window from the tray.
  static void showWindow() {
    if (!_initialized || !_hidden) return;
    final hwnd = _findMainWindow();
    if (hwnd.address != 0) {
      ShowWindow(hwnd, SW_RESTORE);
      SetForegroundWindow(hwnd);
      _hidden = false;
    }
  }

  /// The runner registers the window class FLUTTER_RUNNER_WIN32_WINDOW with
  /// the app title "XDRemux"; matching on the class name avoids colliding
  /// with any other window that happens to share the title.
  static HWND _findMainWindow() {
    final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    try {
      return FindWindow(PCWSTR(className), null).value;
    } finally {
      free(className);
    }
  }
}
