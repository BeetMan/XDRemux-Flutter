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
}
