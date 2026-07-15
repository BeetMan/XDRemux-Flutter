import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ffi/ffi.dart';

final class ConversionResult extends Struct {
  @Bool() external bool success;
  external Pointer<Utf8> mode;
  external Pointer<Utf8> family;
  @Double() external double edrScale;
  @Double() external double gainMapMax;
  external Pointer<Utf8> errorMessage;
}

void main() {
  test('version returns non-null', () {
    final lib = DynamicLibrary.open('libxdremux_core.dylib');
    final versionFn = lib.lookupFunction<
        Pointer<Utf8> Function(),
        Pointer<Utf8> Function()>('xdremux_version');
    final ptr = versionFn();
    expect(ptr, isNot(nullptr));
    final ver = ptr.toDartString();
    print('xdremux version: $ver');
    final freeFn = lib.lookupFunction<
        Void Function(Pointer<Utf8>),
        void Function(Pointer<Utf8>)>('xdremux_free_string');
    freeFn(ptr);
    expect(ver.contains('.'), true);
  });

  test('verify junk data returns false', () {
    final lib = DynamicLibrary.open('libxdremux_core.dylib');
    final verifyFn = lib.lookupFunction<
        Bool Function(Pointer<Utf8>),
        bool Function(Pointer<Utf8>)>('xdremux_verify_output');
    final path = ''.toNativeUtf8();
    final result = verifyFn(path);
    calloc.free(path);
    expect(result, false);
  });
}
