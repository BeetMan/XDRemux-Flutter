import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/services/license_notices.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled GPL-3.0 text matches the repository LICENSE', () {
    final asset = File('assets/licenses/XDRemux-GPL-3.0.txt').readAsStringSync();
    final root = File('../../LICENSE').readAsStringSync();
    expect(asset, root, reason: 'copy LICENSE to assets/licenses/XDRemux-GPL-3.0.txt');
    expect(asset, contains('GNU GENERAL PUBLIC LICENSE'));
    expect(asset, contains('Version 3, 29 June 2007'));
  });

  test('x265 license asset is GPL-2.0', () {
    final text = File('assets/licenses/x265-GPL-2.0.txt').readAsStringSync();
    expect(text, contains('Version 2, June 1991'));
  });

  test('LocalSend license asset matches the vendored copy', () {
    final asset = File('assets/licenses/LocalSend-Apache-2.0.txt').readAsStringSync();
    final vendored = File('../../crates/xdremux-transfer/vendor/localsend/LICENSE').readAsStringSync();
    expect(asset, vendored, reason: 'copy the vendored LocalSend LICENSE to the asset');
    expect(asset, contains('Version 2.0, January 2004'));
  });

  test('registry lists XDRemux, x265 and LocalSend licenses', () async {
    resetAppLicensesForTest();
    registerAppLicenses();
    final packages = <String>{};
    await for (final entry in LicenseRegistry.licenses) {
      packages.addAll(entry.packages);
    }
    expect(packages, containsAll(<String>['XDRemux', 'x265', 'LocalSend']));
  });

  test('legalese names the license and the source URL', () {
    for (final english in [true, false]) {
      final text = appLegalese(english: english);
      expect(text, contains('GPL-3.0-only'));
      expect(text, contains(sourceCodeUrl));
    }
  });
}
