import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../platform_x.dart';

import '../l10n/l10n.dart';

/// System notification shown when a batch conversion finishes, so the user
/// can leave the app in the background during long batches.
///
/// No-op on platforms without an initialized plugin (macOS/iOS are not
/// wired up yet) and in widget tests, where the method channel is missing.
class NotificationService {
  NotificationService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  /// Initialize the platform plugin. Safe to call on every startup; failures
  /// (e.g. missing channel in tests) are swallowed and disable notifications.
  // OHOS drives the vendored fork's channel directly: its Dart wrapper needs
  // OhosInitializationSettings, which hosted flutter_local_notifications
  // (v19, stock platforms) doesn't have.
  static const _ohosChannel =
      MethodChannel('dexterous.com/flutter/local_notifications');

  static Future<void> init() async {
    if (_initialized) return;
    if (PlatformX.isOhos) {
      await _initOhos();
      return;
    }
    if (!(Platform.isAndroid || Platform.isWindows)) return;
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher_xdremux'),
        windows: WindowsInitializationSettings(
          appName: 'XDRemux',
          appUserModelId: 'BeetMan.XDRemux',
          // Arbitrary stable GUID for the notification activation callback.
          guid: '7E9F2A41-3B6D-4E8A-9C2F-1D5B8A0E6F3C',
        ),
      );
      final ok = await _plugin.initialize(
        settings,
        // Tapping the notification brings the app forward (Android) or
        // focuses/launches it (Windows toast activation). No deep link needed.
        onDidReceiveNotificationResponse: (_) {},
      );
      _initialized = ok ?? false;
      if (_initialized && Platform.isAndroid) {
        await _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission();
      }
    } catch (e) {
      debugPrint('[XDRemux][notify] init failed, notifications disabled: $e');
    }
  }

  static Future<void> _initOhos() async {
    try {
      final ok = await _ohosChannel
          .invokeMethod<bool>('initialize', {'defaultIcon': 'app_icon'});
      _initialized = ok ?? false;
      if (_initialized) {
        await _ohosChannel.invokeMethod<bool>('requestNotificationsPermission');
      }
    } catch (e) {
      debugPrint('[XDRemux][notify] ohos init failed, notifications disabled: $e');
    }
  }

  /// Post a "batch finished" summary notification.
  static Future<void> notifyBatchComplete({
    required int converted,
    required int skipped,
    required int failed,
    int failedUnsupported = 0,
  }) async {
    if (!_initialized) return;
    final body = StringBuffer(t('成功 $converted 个', 'Succeeded: $converted'));
    if (skipped > 0) body.write(t('，跳过 $skipped 个', ', skipped $skipped'));
    if (failed > 0) {
      body.write(
        failedUnsupported > 0 && failedUnsupported < failed
            ? t(
                '，失败 $failed 个（其中 $failedUnsupported 个格式不支持）',
                ', failed $failed ($failedUnsupported unsupported format)',
              )
            : t('，失败 $failed 个', ', failed $failed'),
      );
    }
    try {
      if (PlatformX.isOhos) {
        await _ohosChannel.invokeMethod<void>('show', {
          'id': 0,
          'title': t('XDRemux 转换完成', 'XDRemux conversion complete'),
          'body': body.toString(),
        });
        return;
      }
      await _plugin.show(
        0,
        t('XDRemux 转换完成', 'XDRemux conversion complete'),
        body.toString(),
        NotificationDetails(
          android: AndroidNotificationDetails(
            'conversion',
            t('转换完成', 'Conversion complete'),
            channelDescription: t(
              '批量转换完成时的结果摘要',
              'Summary of the batch conversion result',
            ),
            importance: Importance.defaultImportance,
          ),
          // No `windows:` → plugin generates toast XML without the
          // useButtonStyle attribute that silently breaks display.
        ),
      );
    } catch (e) {
      debugPrint('[XDRemux][notify] show failed: $e');
    }
  }
}
