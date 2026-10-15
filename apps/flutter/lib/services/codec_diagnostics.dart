import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:package_info_plus/package_info_plus.dart';
import '../ffi/xdremux_ffi.dart';

/// Classification is a hint based on known error strings, not a native ABI code.
enum CodecErrorKind {
  dependency,
  codec,
  chroma,
  malformed,
  styles,
  io,
  resource,
  hdr,
  cancelled,
  unknown,
}

class CodecDiagnostics {
  static final Map<CodecErrorKind, int> _failures = {};
  static CodecErrorKind classify(String raw) {
    final s = raw.toLowerCase();
    final fallback = s.lastIndexOf('libheif fallback failed:');
    if (fallback >= 0) {
      final native = classify(
        s.substring(fallback + 'libheif fallback failed:'.length),
      );
      if (native != CodecErrorKind.unknown) return native;
    }
    if (s.contains('failed to load dynamic library') ||
        s.contains('126') && s.contains('load') ||
        s.contains('failed to lookup symbol') ||
        s.contains('runtime version is too old')) {
      return CodecErrorKind.dependency;
    }
    if (s.contains('no decoding plugin') || s.contains('unsupported codec')) {
      return CodecErrorKind.codec;
    }
    if (s.contains('cancelled') || s.contains('canceled')) {
      return CodecErrorKind.cancelled;
    }
    if (s.contains('makernote') ||
        s.contains('maker note') ||
        s.contains('styles scaffold')) {
      return CodecErrorKind.styles;
    }
    if (s.contains('resource limit') ||
        s.contains('exceeds') && s.contains('limit') ||
        s.contains('cannot allocate') ||
        s.contains('out of memory')) {
      return CodecErrorKind.resource;
    }
    if (s.contains('pq/hlg') || s.contains('hdr-aware')) {
      return CodecErrorKind.hdr;
    }
    if (s.contains('only 4:2:0') || s.contains('unsupported chroma')) {
      return CodecErrorKind.chroma;
    }
    if (s.contains('permission denied') ||
        s.contains('access is denied') ||
        s.contains('os error') ||
        s.contains('no such file')) {
      return CodecErrorKind.io;
    }
    if (s.contains('truncated') ||
        s.contains('invalid') ||
        s.contains('malformed') ||
        s.contains('corrupt')) {
      return CodecErrorKind.malformed;
    }
    return CodecErrorKind.unknown;
  }

  static String hint(CodecErrorKind kind, {bool english = false}) {
    final hints = <CodecErrorKind, (String, String)>{
      CodecErrorKind.dependency: (
        '核心库或依赖缺失/不匹配；请解压完整测试包后运行，不要只复制 exe。',
        'Missing or incompatible core/dependencies. Extract the complete package; do not copy only the exe.',
      ),
      CodecErrorKind.codec: (
        '没有可用的对应解码器；检查诊断中的 decoder 能力。',
        'No decoder for this codec. Check the decoder capability report.',
      ),
      CodecErrorKind.chroma: (
        '当前解码器不支持此色度格式；检查 libheif 兜底是否启用。',
        'Unsupported chroma. Check whether the libheif fallback is enabled.',
      ),
      CodecErrorKind.malformed: (
        '输入或元数据可能损坏；请保留原图并尝试另一张样片。',
        'Input or metadata may be malformed. Keep the original and try another sample.',
      ),
      CodecErrorKind.styles: (
        '无法安全扩展 Apple 元数据；可关闭摄影风格重试，原图不会被修改。',
        'Apple metadata cannot be safely extended. Retry with Styles off; the original is not modified.',
      ),
      CodecErrorKind.io: (
        '检查文件是否存在、输出目录权限及文件是否被占用。',
        'Check file existence, output permissions and whether files are locked.',
      ),
      CodecErrorKind.resource: (
        '超出安全资源限制；尝试更小样片或减少并发。',
        'Resource limit exceeded. Try a smaller sample or reduce concurrency.',
      ),
      CodecErrorKind.hdr: (
        '此兜底只处理 SDR，不会将 PQ/HLG 直接降为 SDR。',
        'This fallback is SDR-only; it does not tone-map PQ/HLG.',
      ),
      CodecErrorKind.cancelled: (
        '任务已取消，可以重新开始。',
        'Conversion cancelled; you can retry.',
      ),
      CodecErrorKind.unknown: (
        '暂未识别原因；可导出 codec 诊断，并另行提供这条错误。',
        'Unclassified failure. Export codec diagnostics and share this error separately.',
      ),
    };
    final pair = hints[kind]!;
    return english ? pair.$2 : pair.$1;
  }

  static String describe(String raw, {bool english = false}) {
    final kind = classify(raw);
    _failures.update(kind, (v) => v + 1, ifAbsent: () => 1);
    return '[${kind.name}] ${hint(kind, english: english)}\n$raw';
  }

  static Future<Map<String, dynamic>> capabilities() async {
    var appVersion = 'unknown';
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = '${info.version}+${info.buildNumber}';
    } catch (_) {}
    try {
      return {
        ...await Isolate.run(XdRemuxFFI.codecCapabilities),
        'appVersion': appVersion,
      };
    } catch (e) {
      // No exception text: it may include user directory paths.
      return {
        'schemaVersion': 1,
        'appVersion': appVersion,
        'probeAvailable': false,
        'probeError': classify('$e').name,
      };
    }
  }

  /// Strict allowlist: no filenames, paths, EXIF, pixels, GPS or raw errors.
  static String report(Map<String, dynamic> facts) {
    final safe = <String, dynamic>{};
    for (final key in [
      'schemaVersion',
      'coreVersion',
      'rustHeif',
      'primaryPreview',
      'previewMaxSide',
      'previewMaxInputMiB',
      'previewMaxPixels',
      'fallbackScope',
      'hdrJpegMetadata',
      'probeAvailable',
      'probeError',
    ]) {
      if (facts.containsKey(key)) safe[key] = facts[key];
    }
    final native = facts['libheif'];
    if (native is Map) {
      safe['libheif'] = {
        for (final key in [
          'compiled',
          'runtimeVersion',
          'hevcDecoderAvailable',
          'decoder',
        ])
          if (native.containsKey(key)) key: native[key],
      };
    }
    return const JsonEncoder.withIndent('  ').convert({
      'diagnosticSchema': 1,
      'appVersion': facts['appVersion'] ?? 'unknown',
      'platform': Platform.operatingSystem,
      'codec': safe,
      'failureCategories': {
        for (final entry in _failures.entries) entry.key.name: entry.value,
      },
      'counterScope': 'error presentations in this process, not unique files',
      'classification': 'string-based hint, not definitive root cause',
      'privacy': 'no photos, EXIF, GPS, file paths or raw errors',
    });
  }
}
