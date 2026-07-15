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
  off;

  String get appTitle {
    switch (this) {
      case OppoCompatMode.auto:
        return 'Auto';
      case OppoCompatMode.on:
        return 'On';
      case OppoCompatMode.tail:
        return 'Tail';
      case OppoCompatMode.off:
        return 'Off';
    }
  }

  String get appHelp {
    switch (this) {
      case OppoCompatMode.auto:
        return 'Clear private HDR branch bits (diagnostic ISO-only output).';
      case OppoCompatMode.on:
        return 'Set OPPO UHDR routing flag for Gallery recognition.';
      case OppoCompatMode.tail:
        return 'Alias for On — same activation behaviour.';
      case OppoCompatMode.off:
        return 'No UserComment patch. Clean Apple/ISO output.';
    }
  }

  /// Maps to the Rust ConvertConfig.oppo_compat: 0=off, 1=auto, 2=on, 3=tail.
  int get rustValue {
    switch (this) {
      case OppoCompatMode.auto:
        return 1;
      case OppoCompatMode.on:
        return 2;
      case OppoCompatMode.tail:
        return 3;
      case OppoCompatMode.off:
        return 0;
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
  bool skipExisting;
  int maxConcurrentJobs;
  String fileNameSuffix;

  ConversionConfig({
    this.family = Family.auto,
    this.outputDirectory,
    this.oppoCompatibility = OppoCompatMode.off,
    this.skipExisting = true,
    this.maxConcurrentJobs = 4,
    this.fileNameSuffix = '_iso',
  });

  /// Persist to SharedPreferences.
  Map<String, dynamic> toJson() => {
        'family': family.name,
        'outputDirectory': outputDirectory,
        'oppoCompatibility': oppoCompatibility.name,
        'skipExisting': skipExisting,
        'maxConcurrentJobs': maxConcurrentJobs,
        'fileNameSuffix': fileNameSuffix,
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
      skipExisting: json['skipExisting'] as bool? ?? true,
      maxConcurrentJobs: json['maxConcurrentJobs'] as int? ?? 4,
      fileNameSuffix: json['fileNameSuffix'] as String? ?? '_iso',
    );
  }

  ConversionConfig copy() => ConversionConfig(
        family: family,
        outputDirectory: outputDirectory,
        oppoCompatibility: oppoCompatibility,
        skipExisting: skipExisting,
        maxConcurrentJobs: maxConcurrentJobs,
        fileNameSuffix: fileNameSuffix,
      );

  /// Compute output path for a given input file.
  String outputPathFor(String inputPath) {
    final input = File(inputPath);
    final dir = outputDirectory ?? input.parent.path;
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
  DateTime? startedAt;
  DateTime? finishedAt;

  QueueItem({
    required this.id,
    required this.inputPath,
    required this.outputPath,
    this.status = QueueItemStatus.pending,
    this.outputPlanStatus = OutputPlanStatus.ready,
    this.errorMessage,
    this.startedAt,
    this.finishedAt,
  });

  String get fileName {
    final uri = Uri.parse(inputPath);
    return uri.pathSegments.isNotEmpty ? uri.pathSegments.last : inputPath;
  }

  bool get isSuccessful => status.isSuccessful;

  Duration? get duration {
    if (startedAt == null || finishedAt == null) return null;
    return finishedAt!.difference(startedAt!);
  }
}
