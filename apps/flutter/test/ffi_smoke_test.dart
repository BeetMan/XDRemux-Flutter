import 'dart:ffi' as ffi;
import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/ffi/xdremux_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Rust version returns non-empty string', () {
    final v = XdRemuxFFI.version();
    expect(v, isNotEmpty);
    expect(v, '0.1.0');
  });

  test('inspect rejects empty path', () {
    final result = XdRemuxFFI.inspect('');
    expect(result.success, isFalse);
    expect(result.errorMessage, isNot(ffi.nullptr));
    XdRemuxFFI.freeResult(result);
  });

  test('inspect rejects nonexistent file', () {
    final result = XdRemuxFFI.inspect('nonexistent_12345.heic');
    expect(result.success, isFalse);
    expect(result.errorMessage, isNot(ffi.nullptr));
    XdRemuxFFI.freeResult(result);
  });

  test('convert reports not-implemented for nonexistent file', () {
    final result = XdRemuxFFI.convert('nonexistent_9999.heic', 'out.heic');
    expect(result.success, isFalse);
    expect(result.errorMessage, isNot(ffi.nullptr));
    XdRemuxFFI.freeResult(result);
  });

  test('verifyOutput returns false for skeleton', () {
    expect(XdRemuxFFI.verifyOutput('any.heic'), isFalse);
  });
}
