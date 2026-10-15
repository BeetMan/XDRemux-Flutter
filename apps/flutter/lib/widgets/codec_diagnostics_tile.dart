import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/codec_diagnostics.dart';

class CodecDiagnosticsTile extends StatefulWidget {
  final bool english;
  final Future<Map<String, dynamic>> Function()? probe;
  const CodecDiagnosticsTile({super.key, this.english = false, this.probe});
  @override
  State<CodecDiagnosticsTile> createState() => _CodecDiagnosticsTileState();
}

class _CodecDiagnosticsTileState extends State<CodecDiagnosticsTile> {
  late final Future<Map<String, dynamic>> _facts =
      (widget.probe ?? CodecDiagnostics.capabilities)();
  String t(String zh, String en) => widget.english ? en : zh;
  Future<void> _show(Map<String, dynamic> facts) async {
    final report = CodecDiagnostics.report(facts);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('Codec 诊断', 'Codec diagnostics')),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t(
                    '不含照片、文件路径、EXIF 或 GPS；错误分类仅作排查提示。',
                    'No photos, paths, EXIF or GPS. Error categories are diagnostic hints.',
                  ),
                ),
                const SizedBox(height: 12),
                SelectableText(report),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: report));
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text(t('已复制诊断', 'Diagnostics copied'))),
                );
              }
            },
            child: Text(t('复制', 'Copy')),
          ),
          TextButton(
            onPressed: () async {
              try {
                final path = await FilePicker.saveFile(
                  dialogTitle: t('导出 Codec 诊断', 'Export codec diagnostics'),
                  fileName: 'xdremux-codec-diagnostics.json',
                  type: FileType.custom,
                  allowedExtensions: ['json'],
                  bytes: Uint8List.fromList(utf8.encode(report)),
                );
                if (path != null && ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text(t('诊断已导出', 'Diagnostics exported'))),
                  );
                }
              } catch (_) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(
                      content: Text(t('导出失败，请使用复制', 'Export failed; use Copy')),
                    ),
                  );
                }
              }
            },
            child: Text(t('导出 JSON', 'Export JSON')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t('关闭', 'Close')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
    future: _facts,
    builder: (context, snapshot) {
      final facts = snapshot.data;
      final native = facts?['libheif'];
      final enabled =
          native is Map &&
          native['compiled'] == true &&
          native['hevcDecoderAvailable'] == true;
      final subtitle = facts == null
          ? t('读取中…', 'Loading…')
          : facts['probeAvailable'] == false
          ? t('核心能力接口不可用', 'Core capability probe unavailable')
          : 'Rust ${facts['coreVersion']} · libheif ${enabled ? native['runtimeVersion'] : t('未启用', 'off')}';
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.bug_report_outlined),
        title: Text(t('Codec 能力与诊断', 'Codec capabilities & diagnostics')),
        subtitle: Text(subtitle),
        onTap: facts == null ? null : () => _show(facts),
      );
    },
  );
}
