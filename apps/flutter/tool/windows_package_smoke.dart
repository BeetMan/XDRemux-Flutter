// Run using the app's locked package configuration; no Flutter UI/profile writes.
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:xdremux/ffi/xdremux_ffi.dart';

String digest(File file) => sha256.convert(file.readAsBytesSync()).toString();

void main(List<String> args) {
  if (!Platform.isWindows || args.length < 3) {
    throw ArgumentError(
      'Windows only: <bundle-directory> <NEW-report-directory> <input>...',
    );
  }
  final bundle = Directory(args[0]).absolute;
  final output = Directory(args[1]).absolute;
  final inputs = args.skip(2).map((path) => File(path).absolute).toList();
  if (output.existsSync() || inputs.any((file) => !file.existsSync())) {
    throw ArgumentError(
      'Report directory must be new; every input must exist.',
    );
  }
  for (final name in [
    'xdremux.exe',
    'xdremux_core.dll',
    'heif.dll',
    'libde265.dll',
  ]) {
    if (!File('${bundle.path}/$name').existsSync()) {
      throw StateError('Missing packaged file: $name');
    }
  }
  output.createSync(recursive: true);
  // The Flutter EXE normally supplies this DLL search directory. The Dart test
  // host lives elsewhere, so set only its process-local package directory;
  // never add a compiler/dependency prefix to PATH or fall back to cargo output.
  final setDllDirectory = ffi.DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<Utf16>),
        int Function(ffi.Pointer<Utf16>)
      >('SetDllDirectoryW');
  final directory = bundle.path.toNativeUtf16();
  try {
    if (setDllDirectory(directory) == 0) {
      throw StateError('Cannot configure package-local DLL search.');
    }
  } finally {
    calloc.free(directory);
  }
  final previousDirectory = Directory.current;
  Directory.current = bundle;
  try {
    // Load the absolute package DLL before resolving existing app bindings by
    // basename. Windows reuses this loaded module; no source-tree DLL is used.
    ffi.DynamicLibrary.open('${bundle.path}/xdremux_core.dll');
    final cases = <Map<String, Object?>>[];
    final report = <String, Object?>{
      'bundle': bundle.path,
      'dllSha256': digest(File('${bundle.path}/xdremux_core.dll')),
      'coreVersion': XdRemuxFFI.version(),
      'usesAppDartBindings': true,
      'cases': cases,
    };
    var allPassed = true;
    for (var i = 0; i < inputs.length; i++) {
      final input = inputs[i];
      final before = digest(input);
      final destination = '${output.path}/case-$i.heic';
      final styles =
          !input.path.toLowerCase().endsWith('.jpg') ||
          input.uri.pathSegments.last.toLowerCase() == 'sdr.jpg';
      final result = XdRemuxFFI.convert(
        input.path,
        destination,
        oppoCameraTail: 0,
        strictTmap: true,
        applePhotographicStyles: styles,
      );
      late final bool success;
      late final String? error;
      try {
        success = result.success;
        error = result.errorMessage.toDartStringOrNull();
      } finally {
        XdRemuxFFI.freeResult(result);
      }
      final verified = success && XdRemuxFFI.verifyOutput(destination);
      final stylesVerified =
          !styles || (success && XdRemuxFFI.verifyStylesOutput(destination));
      final unchanged = before == digest(input);
      final entry = <String, Object?>{
        'input': input.path,
        'output': destination,
        'stylesRequested': styles,
        'success': success,
        'error': error,
        'outputVerified': verified,
        'stylesVerified': stylesVerified,
        'sourceSha256': before,
        'sourceUnchanged': unchanged,
      };
      cases.add(entry);
      File(
        '${output.path}/report.json',
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
      stdout.writeln(jsonEncode(entry));
      allPassed =
          allPassed && success && verified && stylesVerified && unchanged;
    }
    if (!allPassed) exitCode = 1;
  } finally {
    Directory.current = previousDirectory;
    setDllDirectory(ffi.nullptr);
  }
}
