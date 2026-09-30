import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS dead-strip retention covers every Dart FFI lookup', () {
    final dart = File('lib/ffi/xdremux_ffi.dart').readAsStringSync();
    final podfile = File('ios/Podfile').readAsStringSync();
    final symbols = RegExp(r"'((?:xdremux_)[a-z_]+)'")
        .allMatches(dart).map((match) => match.group(1)!).toSet();
    final retained = RegExp(r'_xdremux_[a-z_]+')
        .allMatches(podfile).map((match) => match.group(0)!.substring(1)).toSet();
    expect(symbols, isNotEmpty);
    expect(symbols.difference(retained), isEmpty,
        reason: 'DynamicLibrary.process needs -u retention on iOS');
  });

  test('all iOS Runner configurations preserve global symbols when stripping', () {
    final project = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    final configs = RegExp(r'OTHER_LDFLAGS = "\$\(inherited\) -Wl,-u,_xdremux_[^;]+;\s+STRIP_STYLE = "non-global";')
        .allMatches(project);
    expect(configs.length, 3, reason: 'Debug/Profile/Release must preserve runtime FFI exports');
  });
}
