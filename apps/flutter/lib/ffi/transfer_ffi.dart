import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import '../services/transfer/transfer_models.dart';

typedef _CreateN = Int32 Function(Pointer<Uint8>, Size, Pointer<Uint64>);
typedef _CreateD = int Function(Pointer<Uint8>, int, Pointer<Uint64>);
typedef _SubmitN =
    Int32 Function(Uint64, Pointer<Uint8>, Size, Pointer<Uint64>);
typedef _SubmitD = int Function(int, Pointer<Uint8>, int, Pointer<Uint64>);
typedef _PollN = Int32 Function(Uint64, Uint32, Uint32, Pointer<Pointer<Utf8>>);
typedef _PollD = int Function(int, int, int, Pointer<Pointer<Utf8>>);
typedef _HandleN = Int32 Function(Uint64);
typedef _HandleD = int Function(int);

/// Construct only inside the persistent worker isolate; no image FFI dependency.
class TransferBindings {
  TransferBindings(String? overridePath) {
    if (overridePath == null && !Platform.isWindows && !Platform.isAndroid) {
      throw const TransferException('unsupported_platform');
    }
    try {
      final path =
          overridePath ??
          (Platform.isWindows
              ? '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}xdremux_transfer.dll'
              : 'libxdremux_transfer.so');
      _library = DynamicLibrary.open(path);
    } catch (_) {
      throw const TransferException('library_missing');
    }
    try {
      final version = _library
          .lookupFunction<Uint32 Function(), int Function()>(
            'xdremux_transfer_abi_version',
          )();
      if (version >> 16 != 1 || (version & 0xffff) < 2) {
        throw const TransferException('abi_mismatch');
      }
      _create = _library.lookupFunction<_CreateN, _CreateD>(
        'xdremux_transfer_create',
      );
      _submit = _library.lookupFunction<_SubmitN, _SubmitD>(
        'xdremux_transfer_submit',
      );
      _poll = _library.lookupFunction<_PollN, _PollD>('xdremux_transfer_poll');
      _stop = _library.lookupFunction<_HandleN, _HandleD>(
        'xdremux_transfer_stop',
      );
      _release = _library.lookupFunction<_HandleN, _HandleD>(
        'xdremux_transfer_release',
      );
      _free = _library
          .lookupFunction<
            Int32 Function(Pointer<Utf8>),
            int Function(Pointer<Utf8>)
          >('xdremux_transfer_free_string');
    } on TransferException {
      rethrow;
    } catch (_) {
      throw const TransferException('abi_mismatch');
    }
  }
  late final DynamicLibrary _library;
  late final _CreateD _create;
  late final _SubmitD _submit;
  late final _PollD _poll;
  late final _HandleD _stop, _release;
  late final int Function(Pointer<Utf8>) _free;

  static void check(int status) {
    if (status == 0) return;
    const codes = [
      'ok',
      'invalid_input',
      'invalid_handle',
      'busy',
      'closed',
      'too_small',
      'internal',
    ];
    throw TransferException(
      status < codes.length && status >= 0 ? codes[status] : 'internal',
    );
  }

  int _jsonId(Map<String, dynamic> json, int? handle) {
    final bytes = utf8.encode(jsonEncode(json));
    if (bytes.isEmpty || bytes.length > 65536) {
      throw const TransferException('invalid_input');
    }
    final input = calloc<Uint8>(bytes.length);
    final out = calloc<Uint64>();
    try {
      input.asTypedList(bytes.length).setAll(0, bytes);
      check(
        handle == null
            ? _create(input, bytes.length, out)
            : _submit(handle, input, bytes.length, out),
      );
      return out.value;
    } finally {
      calloc.free(input);
      calloc.free(out);
    }
  }

  int create(Map<String, dynamic> config) => _jsonId(config, null);
  int submit(int handle, Map<String, dynamic> command) =>
      _jsonId(command, handle);
  Map<String, dynamic> poll(int handle) {
    final out = calloc<Pointer<Utf8>>();
    try {
      check(_poll(handle, 128, 2097152, out));
      try {
        return jsonDecode(out.value.toDartString()) as Map<String, dynamic>;
      } finally {
        check(_free(out.value));
      }
    } finally {
      calloc.free(out);
    }
  }

  void stop(int handle) => check(_stop(handle));
  void release(int handle) => check(_release(handle));
}
