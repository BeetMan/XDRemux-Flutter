import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// Result of a GitHub Releases update check.
class UpdateInfo {
  final String latestVersion;
  final String releaseUrl;
  final String releaseName;

  const UpdateInfo({
    required this.latestVersion,
    required this.releaseUrl,
    required this.releaseName,
  });
}

/// Checks GitHub Releases for a newer app version.
class UpdateService {
  UpdateService._();

  static const _repo = 'BeetMan/XDRemux-Flutter';
  static const _apiUrl = 'https://api.github.com/repos/$_repo/releases/latest';

  /// Returns [UpdateInfo] when a newer version than the running app exists,
  /// or null when up-to-date / on any error (offline, rate-limited, no
  /// releases yet). Never throws.
  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final current = info.version;

      final response = await http
          .get(Uri.parse(_apiUrl), headers: {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final tag = (json['tag_name'] as String? ?? '').replaceFirst(RegExp(r'^[vV]'), '');
      if (tag.isEmpty) return null;

      if (_isNewer(tag, current)) {
        return UpdateInfo(
          latestVersion: tag,
          releaseUrl: json['html_url'] as String? ?? 'https://github.com/$_repo/releases/latest',
          releaseName: json['name'] as String? ?? 'v$tag',
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Compares dotted versions numerically segment by segment.
  /// Returns true when [latest] is strictly newer than [current].
  static bool _isNewer(String latest, String current) {
    final latestParts = latest.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final currentParts = current.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final len = latestParts.length > currentParts.length ? latestParts.length : currentParts.length;
    for (var i = 0; i < len; i++) {
      final l = i < latestParts.length ? latestParts[i] : 0;
      final c = i < currentParts.length ? currentParts[i] : 0;
      if (l > c) return true;
      if (l < c) return false;
    }
    return false;
  }
}
