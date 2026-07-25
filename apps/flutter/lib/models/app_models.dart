/// Dart model equivalents of the macOS SwiftUI data types for XDRemux.
library;

import 'dart:io';

// ---------------------------------------------------------------------------
// Enums (mirror Swift Family / OppoCompatibility / InputProcessingBranch)
// ---------------------------------------------------------------------------

enum Family {
  auto,
  x6,
  x7;

  String get appTitle {
    switch (this) {
      case Family.auto:
        return 'Auto';
      case Family.x6:
        return 'X6';
      case Family.x7:
        return 'X7';
    }
  }
}

enum OppoCompatMode {
  auto,
  on,
  tail,
  iso,
  isoNoLocal,
  isoGraph,
  off;

  String get appTitle {
    switch (this) {
      case OppoCompatMode.auto:
        return 'Auto';
      case OppoCompatMode.on:
        return 'On';
      case OppoCompatMode.tail:
        return 'Tail';
      case OppoCompatMode.iso:
        return 'ISO';
      case OppoCompatMode.isoNoLocal:
        return 'ISO no local';
      case OppoCompatMode.isoGraph:
        return 'ISO graph';
      case OppoCompatMode.off:
        return 'Off';
    }
  }

  String get appHelp {
    switch (this) {
      case OppoCompatMode.auto:
        return 'Preserve source routing flags with OPPO-compatible gain-map output.';
      case OppoCompatMode.on:
        return 'Set OPPO UHDR routing flag for Gallery recognition.';
      case OppoCompatMode.tail:
        return 'Set OPPO routing and retain the complete camera metadata tail.';
      case OppoCompatMode.iso:
        return 'Clear the OPPO routing flag and set the ISO UHDR routing flag.';
      case OppoCompatMode.isoNoLocal:
        return 'ISO routing with the local HDR routing flag removed.';
      case OppoCompatMode.isoGraph:
        return 'Clear OPPO and ISO routing flags while retaining the metadata graph.';
      case OppoCompatMode.off:
        return 'No UserComment patch. Clean Apple/ISO output.';
    }
  }

  /// Maps to Rust: 0=off, 1=auto, 2=on, 3=tail, 4=iso,
  /// 5=iso-no-local, 6=iso-graph.
  int get rustValue {
    switch (this) {
      case OppoCompatMode.auto:
        return 1;
      case OppoCompatMode.on:
        return 2;
      case OppoCompatMode.tail:
        return 3;
      case OppoCompatMode.iso:
        return 4;
      case OppoCompatMode.isoNoLocal:
        return 5;
      case OppoCompatMode.isoGraph:
        return 6;
      case OppoCompatMode.off:
        return 0;
    }
  }
}

/// Controls how much OPPO camera metadata is retained after conversion.
enum OppoCameraTailMode {
  automatic,
  off,
  watermark,
  compact,
  preserve,
  preserveWithoutPortrait,
  preserveWithoutPortraitOrPrivateHdr,
  preserveWithoutPrivateUhdr,
  preserveWithoutPrivateHdr,
  preserveNoUhdr,
  preserveNoHdr;

  String get appTitle {
    switch (this) {
      case OppoCameraTailMode.automatic:
        return '自动';
      case OppoCameraTailMode.off:
        return '不保留';
      case OppoCameraTailMode.watermark:
        return '仅水印';
      case OppoCameraTailMode.compact:
        return '紧凑（含人像编辑）';
      case OppoCameraTailMode.preserve:
        return '完整保留';
      case OppoCameraTailMode.preserveWithoutPortrait:
        return '保留（移除人像编辑）';
      case OppoCameraTailMode.preserveWithoutPortraitOrPrivateHdr:
        return '保留（移除人像/私有 HDR）';
      case OppoCameraTailMode.preserveWithoutPrivateUhdr:
        return '保留（移除私有 UHDR）';
      case OppoCameraTailMode.preserveWithoutPrivateHdr:
        return '保留（移除私有 HDR）';
      case OppoCameraTailMode.preserveNoUhdr:
        return '保留并中和 UHDR';
      case OppoCameraTailMode.preserveNoHdr:
        return '保留并中和 HDR';
    }
  }

  String get appHelp {
    switch (this) {
      case OppoCameraTailMode.automatic:
        return '兼容模式开启时完整保留；纯 ISO 输出时移除私有 HDR。';
      case OppoCameraTailMode.off:
        return '不复制 OPPO 相机尾部元数据。';
      case OppoCameraTailMode.watermark:
        return '仅保留水印及其辅助元数据。';
      case OppoCameraTailMode.compact:
        return '保留水印、人像编辑及必要的 HDR 变换条目。';
      case OppoCameraTailMode.preserve:
        return '原样保留完整相机尾部。';
      case OppoCameraTailMode.preserveWithoutPortrait:
        return '删除景深、分割和人像编辑条目。';
      case OppoCameraTailMode.preserveWithoutPortraitOrPrivateHdr:
        return '同时删除人像编辑和私有 HDR 条目。';
      case OppoCameraTailMode.preserveWithoutPrivateUhdr:
        return '仅删除私有 UHDR gain map 条目。';
      case OppoCameraTailMode.preserveWithoutPrivateHdr:
        return '删除所有私有 HDR 条目。';
      case OppoCameraTailMode.preserveNoUhdr:
        return '保留结构，但中和私有 UHDR 条目名。';
      case OppoCameraTailMode.preserveNoHdr:
        return '保留结构，但中和所有私有 HDR 条目名。';
    }
  }

  /// Rust values 0..9 mirror upstream; 255 asks Rust to choose automatically.
  int get rustValue {
    switch (this) {
      case OppoCameraTailMode.automatic:
        return 255;
      case OppoCameraTailMode.off:
        return 0;
      case OppoCameraTailMode.watermark:
        return 1;
      case OppoCameraTailMode.compact:
        return 2;
      case OppoCameraTailMode.preserve:
        return 3;
      case OppoCameraTailMode.preserveWithoutPortrait:
        return 4;
      case OppoCameraTailMode.preserveWithoutPortraitOrPrivateHdr:
        return 5;
      case OppoCameraTailMode.preserveWithoutPrivateUhdr:
        return 6;
      case OppoCameraTailMode.preserveWithoutPrivateHdr:
        return 7;
      case OppoCameraTailMode.preserveNoUhdr:
        return 8;
      case OppoCameraTailMode.preserveNoHdr:
        return 9;
    }
  }
}

enum QueueItemStatus {
  pending,
  running,
  converted,
  skippedExisting,
  failed,
  cancelled;

  bool get isRunnable => this == QueueItemStatus.pending;

  bool get isTerminal =>
      this == QueueItemStatus.converted ||
      this == QueueItemStatus.skippedExisting ||
      this == QueueItemStatus.failed ||
      this == QueueItemStatus.cancelled;

  bool get isSuccessful =>
      this == QueueItemStatus.converted ||
      this == QueueItemStatus.skippedExisting;

  String get displayName {
    switch (this) {
      case QueueItemStatus.pending:
        return '待处理';
      case QueueItemStatus.running:
        return '转换中';
      case QueueItemStatus.converted:
        return '已转换';
      case QueueItemStatus.skippedExisting:
        return '已跳过';
      case QueueItemStatus.failed:
        return '失败';
      case QueueItemStatus.cancelled:
        return '已取消';
    }
  }
}

enum OutputPlanStatus {
  ready,
  willOverwriteExisting,
  skipsExistingValidOutput,
  duplicateOutput,
  inputMissing,
  outputParentIsFile;

  bool get blocksConversion =>
      this == OutputPlanStatus.duplicateOutput ||
      this == OutputPlanStatus.inputMissing ||
      this == OutputPlanStatus.outputParentIsFile;

  String get displayName {
    switch (this) {
      case OutputPlanStatus.ready:
        return '就绪';
      case OutputPlanStatus.willOverwriteExisting:
        return '将覆盖';
      case OutputPlanStatus.skipsExistingValidOutput:
        return '跳过(有效)';
      case OutputPlanStatus.duplicateOutput:
        return '重复输出';
      case OutputPlanStatus.inputMissing:
        return '输入缺失';
      case OutputPlanStatus.outputParentIsFile:
        return '输出路径冲突';
    }
  }
}

// ---------------------------------------------------------------------------
// ConversionConfig
// ---------------------------------------------------------------------------

class ConversionConfig {
  Family family;
  String? outputDirectory;
  OppoCompatMode oppoCompatibility;
  OppoCameraTailMode oppoCameraTail;
  bool strictTmap;
  bool skipExisting;
  int maxConcurrentJobs;
  String fileNameSuffix;
  bool categorizeOutputByMode;

  ConversionConfig({
    this.family = Family.auto,
    this.outputDirectory,
    this.oppoCompatibility = OppoCompatMode.off,
    this.oppoCameraTail = OppoCameraTailMode.automatic,
    this.strictTmap = false,
    this.skipExisting = true,
    this.maxConcurrentJobs = 4,
    this.fileNameSuffix = '_iso',
    this.categorizeOutputByMode = false,
  });

  /// Persist to SharedPreferences.
  Map<String, dynamic> toJson() => {
        'family': family.name,
        'outputDirectory': outputDirectory,
        'oppoCompatibility': oppoCompatibility.name,
        'oppoCameraTail': oppoCameraTail.name,
        'strictTmap': strictTmap,
        'skipExisting': skipExisting,
        'maxConcurrentJobs': maxConcurrentJobs,
        'fileNameSuffix': fileNameSuffix,
        'categorizeOutputByMode': categorizeOutputByMode,
      };

  factory ConversionConfig.fromJson(Map<String, dynamic> json) {
    return ConversionConfig(
      family: Family.values.firstWhere(
        (e) => e.name == json['family'],
        orElse: () => Family.auto,
      ),
      outputDirectory: json['outputDirectory'] as String?,
      oppoCompatibility: OppoCompatMode.values.firstWhere(
        (e) => e.name == json['oppoCompatibility'],
        orElse: () => OppoCompatMode.off,
      ),
      oppoCameraTail: OppoCameraTailMode.values.firstWhere(
        (e) => e.name == json['oppoCameraTail'],
        orElse: () => OppoCameraTailMode.automatic,
      ),
      strictTmap: json['strictTmap'] as bool? ?? false,
      skipExisting: json['skipExisting'] as bool? ?? true,
      maxConcurrentJobs: json['maxConcurrentJobs'] as int? ?? 4,
      fileNameSuffix: json['fileNameSuffix'] as String? ?? '_iso',
      categorizeOutputByMode:
          json['categorizeOutputByMode'] as bool? ?? false,
    );
  }

  ConversionConfig copy() => ConversionConfig(
        family: family,
        outputDirectory: outputDirectory,
        oppoCompatibility: oppoCompatibility,
        oppoCameraTail: oppoCameraTail,
        strictTmap: strictTmap,
        skipExisting: skipExisting,
        maxConcurrentJobs: maxConcurrentJobs,
        fileNameSuffix: fileNameSuffix,
        categorizeOutputByMode: categorizeOutputByMode,
      );

  /// Compute output path for a given input file.
  ///
  /// [fallbackDir] is used when [outputDirectory] is null and the platform
  /// requires an app-specific writable directory (e.g. Android scoped storage).
  String outputPathFor(
    String inputPath, {
    String? fallbackDir,
    String? captureModeFolderName,
  }) {
    final input = File(inputPath);
    final baseDirectory = outputDirectory ?? fallbackDir ?? input.parent.path;
    final dir = categorizeOutputByMode &&
            captureModeFolderName != null &&
            captureModeFolderName.isNotEmpty
        ? '$baseDirectory${Platform.pathSeparator}$captureModeFolderName'
        : baseDirectory;
    final stem = input.uri.pathSegments.last.replaceAll(RegExp(r'\.heic$', caseSensitive: false), '');
    return '$dir${Platform.pathSeparator}$stem$fileNameSuffix.heic';
  }
}

// ---------------------------------------------------------------------------
// QueueItem
// ---------------------------------------------------------------------------

class QueueItem {
  final String id; // UUID string
  final String inputPath;
  String outputPath;
  QueueItemStatus status;
  OutputPlanStatus outputPlanStatus;
  String? errorMessage;
  String? captureModeKey;
  String? captureModeFolderName;
  String? classificationStatus;
  DateTime? startedAt;
  DateTime? finishedAt;

  /// Per-file progress within conversion, e.g. (stage: 3, current: 12, total: 48)
  /// meaning HEVC tile 12 / 48 is being encoded. Null when idle or done.
  ({int stage, int current, int total})? progress;

  /// Human-readable progress label derived from [progress].
  String get progressLabel {
    final p = progress;
    if (p == null || p.stage == 0) return '';
    return switch (p.stage) {
      1 => '解析元数据…',
      2 => '解码JPEG…',
      3 => '编码 HEVC ${p.current}/${p.total}',
      4 => '组装输出…',
      _ => '',
    };
  }

  QueueItem({
    required this.id,
    required this.inputPath,
    required this.outputPath,
    this.status = QueueItemStatus.pending,
    this.outputPlanStatus = OutputPlanStatus.ready,
    this.errorMessage,
    this.captureModeKey,
    this.captureModeFolderName,
    this.classificationStatus,
    this.startedAt,
    this.finishedAt,
    this.progress,
  });

  String get fileName {
    final uri = Uri.parse(inputPath);
    return uri.pathSegments.isNotEmpty ? uri.pathSegments.last : inputPath;
  }

  String? get captureModeLabel => captureModeFolderName;

  String get classificationLabel {
    switch (classificationStatus) {
      case 'missing-user-comment':
        return '无拍摄模式';
      case 'malformed-user-comment':
        return '拍摄模式格式异常';
      case 'unknown-flags':
        return '未知拍摄模式';
      case 'unreadable-image':
        return '无法读取拍摄模式';
      default:
        return captureModeFolderName ?? '未分类';
    }
  }

  bool get isSuccessful => status.isSuccessful;

  Duration? get duration {
    if (startedAt == null || finishedAt == null) return null;
    return finishedAt!.difference(startedAt!);
  }
}
