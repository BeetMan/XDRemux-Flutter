import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Android foreground service that keeps the process alive during batch
/// conversion, so the OS doesn't freeze the Dart isolates doing HEVC encode.
/// Shows a persistent notification with live progress.
///
/// No-op on non-Android platforms.
class ForegroundService {
  ForegroundService._();

  static bool _initialized = false;

  /// Initialize the foreground task options. Must be called before
  /// [start]. Safe to call on every startup.
  static void init() {
    if (_initialized || !Platform.isAndroid) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'xdremux_conversion_v2',
        channelName: '转换进度',
        channelDescription: '批量转换进行时显示的前台服务通知',
        // DEFAULT importance: ColorOS kills foreground services whose
        // notification is IMPORTANCE_LOW (folded as "unimportant").
        channelImportance: NotificationChannelImportance.DEFAULT,
        priority: NotificationPriority.DEFAULT,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
    _initialized = true;
  }

  /// Start the foreground service with an initial notification.
  static Future<void> start() async {
    if (!_initialized || !Platform.isAndroid) return;
    try {
      if (await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.startService(
        serviceId: 256,
        notificationTitle: 'XDRemux',
        notificationText: '正在转换…',
      );
    } catch (e) {
      debugPrint('[XDRemux][fg] start failed: $e');
    }
  }

  /// Update the persistent notification text with live progress.
  static Future<void> updateProgress(String text) async {
    if (!_initialized || !Platform.isAndroid) return;
    try {
      if (!await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.updateService(
        notificationTitle: 'XDRemux',
        notificationText: text,
      );
    } catch (e) {
      debugPrint('[XDRemux][fg] update failed: $e');
    }
  }

  /// Stop the foreground service (batch finished or cancelled).
  static Future<void> stop() async {
    if (!_initialized || !Platform.isAndroid) return;
    try {
      if (!await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.stopService();
    } catch (e) {
      debugPrint('[XDRemux][fg] stop failed: $e');
    }
  }
}
