import 'dart:ffi';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ffi/ffi.dart';

import 'native_library.dart';

final class ConversionResult extends Struct {
  @Bool() external bool success;
  external Pointer<Utf8> mode;
  external Pointer<Utf8> family;
  @Double() external double edrScale;
  @Double() external double gainMapMax;
  external Pointer<Utf8> errorMessage;
}

// Resolved once: the loader does not search the Cargo target directory, so the
// path is probed explicitly (see native_library.dart).
final String _libraryPath = nativeCoreLibraryPath();

void main() {
  test('packaged core exports every runtime symbol used by Flutter', () {
    final lib = DynamicLibrary.open(_libraryPath);
    final source = File('lib/ffi/xdremux_ffi.dart').readAsStringSync();
    final symbols = RegExp(r"'((?:xdremux_)[a-z_]+)'")
        .allMatches(source).map((match) => match.group(1)!).toSet();
    for (final symbol in symbols) {
      expect(lib.providesSymbol(symbol), isTrue, reason: 'Missing $symbol');
    }
  });

  test('version returns non-null', () {
    final lib = DynamicLibrary.open(_libraryPath);
    final versionFn = lib.lookupFunction<
        Pointer<Utf8> Function(),
        Pointer<Utf8> Function()>('xdremux_version');
    final ptr = versionFn();
    expect(ptr, isNot(nullptr));
    final ver = ptr.toDartString();
    debugPrint('xdremux version: $ver');
    final freeFn = lib.lookupFunction<
        Void Function(Pointer<Utf8>),
        void Function(Pointer<Utf8>)>('xdremux_free_string');
    freeFn(ptr);
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final appVersion = RegExp(r'^version: ([^+\s]+)', multiLine: true)
        .firstMatch(pubspec)!.group(1);
    expect(ver, appVersion, reason: 'Packaged core and Flutter versions must match');
  });

  test('verify junk data returns false', () {
    final lib = DynamicLibrary.open(_libraryPath);
    final verifyFn = lib.lookupFunction<
        Bool Function(Pointer<Utf8>),
        bool Function(Pointer<Utf8>)>('xdremux_verify_output');
    final path = ''.toNativeUtf8();
    final result = verifyFn(path);
    calloc.free(path);
    expect(result, false);
  });
}
