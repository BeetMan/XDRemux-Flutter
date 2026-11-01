import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Source of the GPL-3.0-only distribution (see LICENSING.md).
const String sourceCodeUrl = 'https://github.com/BeetMan/XDRemux-Flutter';

const String _xdremuxLicenseAsset = 'assets/licenses/XDRemux-GPL-3.0.txt';
const String _x265LicenseAsset = 'assets/licenses/x265-GPL-2.0.txt';
const String _localSendLicenseAsset = 'assets/licenses/LocalSend-Apache-2.0.txt';

/// Adds the app's own license, the statically linked x265 core and the
/// vendored LocalSend transfer core to the [LicenseRegistry], next to the
/// Dart/Flutter package licenses Flutter collects on its own. Safe to call
/// more than once.
void registerAppLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const <String>['XDRemux'],
      await rootBundle.loadString(_xdremuxLicenseAsset),
    );
    yield LicenseEntryWithLineBreaks(
      const <String>['x265'],
      await rootBundle.loadString(_x265LicenseAsset),
    );
    yield LicenseEntryWithLineBreaks(
      const <String>['LocalSend'],
      await rootBundle.loadString(_localSendLicenseAsset),
    );
  });
}

bool _registered = false;

@visibleForTesting
void resetAppLicensesForTest() => _registered = false;

/// Text shown above the license list: the project license and where the
/// corresponding source lives.
String appLegalese({required bool english}) => english
    ? 'XDRemux is free software licensed under GPL-3.0-only. '
        'Source code, history and the licensing of upstream-derived code and '
        'third-party components: $sourceCodeUrl'
    : 'XDRemux 是自由软件，按 GPL-3.0-only 授权。源代码、历史版本说明，'
        '以及移植自上游的代码与第三方组件的许可：$sourceCodeUrl';

/// Opens Flutter's license page with the app's legalese.
void showAppLicenses(BuildContext context, {required bool english, String? version}) {
  registerAppLicenses();
  showLicensePage(
    context: context,
    applicationName: 'XDRemux',
    applicationVersion: version,
    applicationLegalese: appLegalese(english: english),
  );
}
