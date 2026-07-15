import 'dart:ffi';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:ffi/ffi.dart';

void main() => runApp(const DebugApp());

class DebugApp extends StatelessWidget {
  const DebugApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(home: DebugPage());
}

class DebugPage extends StatefulWidget {
  const DebugPage({super.key});
  @override
  State<DebugPage> createState() => _DebugPageState();
}

class _DebugPageState extends State<DebugPage> {
  String _status = "loading...";

  @override
  void initState() {
    super.initState();
    _testDylib();
  }

  Future<void> _testDylib() async {
    try {
      final lib = DynamicLibrary.open('libxdremux_core.dylib');
      final v = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('xdremux_version')();
      final ver = v.toDartString();
      setState(() => _status = "OK: version=$ver (dylib at ${Platform.resolvedExecutable})");
    } catch (e) {
      // Try alternative paths
      final paths = [
        'libxdremux_core.dylib',
        '${Platform.resolvedExecutable}/../Frameworks/libxdremux_core.dylib',
      ];
      final msgs = <String>[];
      for (final p in paths) {
        try {
          final lib = DynamicLibrary.open(p);
          final v = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('xdremux_version')();
          msgs.add("SUCCESS at $p: ${v.toDartString()}");
        } catch (e2) {
          msgs.add("$p: ${e2.toString().split('\n').first}");
        }
      }
      setState(() => _status = msgs.join('\n'));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(child: Text(_status, style: const TextStyle(fontSize: 14, fontFamily: 'monospace'))),
  );
}
