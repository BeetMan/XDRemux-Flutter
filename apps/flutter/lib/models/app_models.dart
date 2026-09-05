/// Dart model equivalents of the macOS SwiftUI data types for XDRemux.
library;

import 'dart:io';

import '../l10n/l10n.dart';

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
        return t('自动', 'Auto');
      case Family.x6:
        return 'X6';
      case Family.x7:
        return 'X7';
    }
  }
}

/// Conversion implementation selected by the user.
///
/// Rust remains the cross-platform default. Swift is only exposed on Apple
/// platforms, where it will eventually provide the Apple-specific library
/// path without launching a CLI subprocess.
enum ConversionBackend {
  rust,
  swift;

  String get appTitle {
    switch (this) {
      case ConversionBackend.rust:
        return t('Rust（推荐）', 'Rust (recommended)');
      case ConversionBackend.swift:
        return 'Swift';
    }
  }
}

/// High-level output target. This is independent from the implementation
/// backend: Rust can still produce the default OPPO-compatible output, while
/// Swift can produce Apple output with the experimental Apple features.
enum OutputMode {
  oppo,
  apple;

  String get appTitle {
    switch (this) {
      case OutputMode.oppo:
        return t('OPPO 兼容', 'OPPO Compatible');
      case OutputMode.apple:
        return t('Apple 标准', 'Apple Standard');
    }
  }

  String get appHelp {
    switch (this) {
      case OutputMode.oppo:
        return t(
          '兼容 OPPO/一加相册的标准文件格式，保留兼容信息和相机附加信息，便于继续编辑。',
          'Standard format compatible with OPPO/OnePlus Gallery. Keeps compatibility metadata and camera extras for further editing.',
        );
      case OutputMode.apple:
        return t(
          '面向 Apple 照片的兼容文件格式，支持继续调节摄影风格。',
          'Apple Photos-compatible format that supports further Photographic Styles adjustments.',
        );
    }
  }
}

/// Watermark handling for the Apple/OPPO round-trip workflow.
///
/// `isolate` currently keeps the visible raster watermark but prevents the
/// recognized OPPO watermark metadata from entering the Apple Styles path.
/// Full raster removal remains an experimental follow-up.
enum AppleWatermarkPolicy {
  preserve,
  isolate;

  String get appTitle {
    switch (this) {
      case AppleWatermarkPolicy.preserve:
        return t('保留水印', 'Preserve watermark');
      case AppleWatermarkPolicy.isolate:
        return t('隔离水印元数据（实验性）', 'Isolate watermark metadata (experimental)');
    }
  }

  String get appHelp {
    switch (this) {
      case AppleWatermarkPolicy.preserve:
        return t(
          'Apple 照片编辑副本保留当前水印；回传后仍可按设置恢复 OPPO 原始照片中的原机水印。',
          'The Apple Photos edit copy keeps the current watermark; after round-trip the original watermark can still be restored from the OPPO source.',
        );
      case AppleWatermarkPolicy.isolate:
        return t(
          '不把 OPPO 水印私有元数据写入 Apple 照片摄影风格；已经烘焙进画面的水印暂不会被擦除。',
          'Do not write OPPO private watermark metadata into Apple Photographic Styles; watermarks already baked into pixels are not removed yet.',
        );
    }
  }
}

/// Runtime capability snapshot for the conversion backends.
///
/// Visibility and availability are deliberately separate: the Swift option
/// is visible on macOS/iOS while the native bridge is being integrated. Its
/// availability is controlled by the platform capability probe.
class BackendCapabilities {
  final bool rustAvailable;
  final bool swiftVisible;
  final bool swiftAvailable;
  final bool swiftStandardHdr;
  final bool swiftAppleFeatures;
  final bool swiftPhotographicStyles;
  final bool swiftPortrait;
  final bool swiftPortraitResearch;
  final String swiftUnavailableReason;
  final String swiftAppleFeaturesUnavailableReason;

  const BackendCapabilities({
    required this.rustAvailable,
    required this.swiftVisible,
    required this.swiftAvailable,
    required this.swiftStandardHdr,
    required this.swiftAppleFeatures,
    this.swiftPhotographicStyles = false,
    this.swiftPortrait = false,
    this.swiftPortraitResearch = false,
    required this.swiftUnavailableReason,
    this.swiftAppleFeaturesUnavailableReason = '',
  });

  factory BackendCapabilities.forCurrentPlatform() {
    final apple = Platform.isMacOS || Platform.isIOS;
    return BackendCapabilities(
      rustAvailable: true,
      swiftVisible: apple,
      swiftAvailable: false,
      swiftStandardHdr: false,
      swiftAppleFeatures: false,
      swiftPhotographicStyles: false,
      swiftPortrait: false,
      swiftPortraitResearch: false,
      swiftUnavailableReason: apple
          ? t(
              '当前构建未通过 Swift Core capability 验证；当前版本不会启动 Swift CLI。',
              'This build did not pass the Swift Core capability probe; the Swift CLI is not launched in this version.',
            )
          : t('Swift 后端仅支持 macOS/iOS。', 'The Swift backend is only available on macOS/iOS.'),
      swiftAppleFeaturesUnavailableReason: t(
        'Apple 功能仍需 macOS 原生工具链和样例验证；当前版本保持关闭。',
        'Apple features still need the macOS native toolchain and sample validation; disabled in this version.',
      ),
    );
  }

  bool isVisible(ConversionBackend backend) {
    return backend == ConversionBackend.rust || swiftVisible;
  }

  bool isAvailable(ConversionBackend backend) {
    return backend == ConversionBackend.rust ? rustAvailable : swiftAvailable;
  }

  String statusFor(ConversionBackend backend) {
    if (isAvailable(backend)) return t('可用', 'Available');
    return backend == ConversionBackend.swift
        ? swiftUnavailableReason
        : t('Rust 核心不可用', 'Rust core unavailable');
  }

  BackendCapabilities copyWith({
    bool? rustAvailable,
    bool? swiftVisible,
    bool? swiftAvailable,
    bool? swiftStandardHdr,
    bool? swiftAppleFeatures,
    bool? swiftPhotographicStyles,
    bool? swiftPortrait,
    bool? swiftPortraitResearch,
    String? swiftUnavailableReason,
    String? swiftAppleFeaturesUnavailableReason,
  }) {
    return BackendCapabilities(
      rustAvailable: rustAvailable ?? this.rustAvailable,
      swiftVisible: swiftVisible ?? this.swiftVisible,
      swiftAvailable: swiftAvailable ?? this.swiftAvailable,
      swiftStandardHdr: swiftStandardHdr ?? this.swiftStandardHdr,
      swiftAppleFeatures: swiftAppleFeatures ?? this.swiftAppleFeatures,
      swiftPhotographicStyles:
          swiftPhotographicStyles ?? this.swiftPhotographicStyles,
      swiftPortrait: swiftPortrait ?? this.swiftPortrait,
      swiftPortraitResearch:
          swiftPortraitResearch ?? this.swiftPortraitResearch,
      swiftUnavailableReason:
          swiftUnavailableReason ?? this.swiftUnavailableReason,
      swiftAppleFeaturesUnavailableReason:
          swiftAppleFeaturesUnavailableReason ??
          this.swiftAppleFeaturesUnavailableReason,
    );
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
        return t('自动', 'Auto');
      case OppoCompatMode.on:
        return t('OPPO 兼容', 'OPPO Compatible');
      case OppoCompatMode.tail:
        return t('OPPO 兼容 + 完整附加信息', 'OPPO Compatible + full extras');
      case OppoCompatMode.iso:
        return t('标准 ISO', 'Standard ISO');
      case OppoCompatMode.isoNoLocal:
        return t('标准 ISO（无本地标记）', 'Standard ISO (no local marker)');
      case OppoCompatMode.isoGraph:
        return t('标准 ISO（保留元数据图）', 'Standard ISO (keep metadata graph)');
      case OppoCompatMode.off:
        return t('关闭', 'Off');
    }
  }

  String get appHelp {
    switch (this) {
      case OppoCompatMode.auto:
        return t('根据原图标记自动选择；适合大多数照片。', 'Chosen automatically from source markers; suits most photos.');
      case OppoCompatMode.on:
        return t('写入 OPPO 兼容标记，优先保证 OPPO 相册识别。', 'Writes OPPO-compatible markers to prioritize OPPO Gallery recognition.');
      case OppoCompatMode.tail:
        return t('写入 OPPO 兼容标记，并完整保留相机附加信息。', 'Writes OPPO-compatible markers and keeps the full camera extras.');
      case OppoCompatMode.iso:
        return t('移除 OPPO 标记，写入标准 ISO HDR 标记。', 'Removes OPPO markers and writes standard ISO HDR markers.');
      case OppoCompatMode.isoNoLocal:
        return t('标准 ISO HDR，并移除本地 HDR 标记。', 'Standard ISO HDR, and removes the local HDR marker.');
      case OppoCompatMode.isoGraph:
        return t('清除路由标记，但保留原始元数据关系图。', 'Clears routing markers but keeps the original metadata relationship graph.');
      case OppoCompatMode.off:
        return t('不修改路由标记；适合 Apple 照片/纯 ISO 输出。', 'Does not modify routing markers; suits Apple Photos / pure ISO output.');
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
        return t('自动', 'Auto');
      case OppoCameraTailMode.off:
        return t('不保留', 'None');
      case OppoCameraTailMode.watermark:
        return t('仅水印', 'Watermark only');
      case OppoCameraTailMode.compact:
        return t('紧凑（含人像编辑）', 'Compact (incl. portrait edits)');
      case OppoCameraTailMode.preserve:
        return t('完整保留', 'Preserve all');
      case OppoCameraTailMode.preserveWithoutPortrait:
        return t('保留（移除人像编辑）', 'Preserve (drop portrait edits)');
      case OppoCameraTailMode.preserveWithoutPortraitOrPrivateHdr:
        return t('保留（移除人像/私有 HDR）', 'Preserve (drop portrait/private HDR)');
      case OppoCameraTailMode.preserveWithoutPrivateUhdr:
        return t('保留（移除私有 UHDR）', 'Preserve (drop private UHDR)');
      case OppoCameraTailMode.preserveWithoutPrivateHdr:
        return t('保留（移除私有 HDR）', 'Preserve (drop private HDR)');
      case OppoCameraTailMode.preserveNoUhdr:
        return t('保留并中和 UHDR', 'Preserve & neutralize UHDR');
      case OppoCameraTailMode.preserveNoHdr:
        return t('保留并中和 HDR', 'Preserve & neutralize HDR');
    }
  }

  String get appHelp {
    switch (this) {
      case OppoCameraTailMode.automatic:
        return t('兼容模式开启时完整保留；纯 ISO 输出时移除私有 HDR。', 'Fully preserved when compatibility mode is on; private HDR removed for pure ISO output.');
      case OppoCameraTailMode.off:
        return t('不复制 OPPO 相机尾部元数据。', 'Does not copy OPPO camera tail metadata.');
      case OppoCameraTailMode.watermark:
        return t('仅保留水印及其辅助元数据。', 'Keeps only the watermark and its auxiliary metadata.');
      case OppoCameraTailMode.compact:
        return t('保留水印、人像编辑及必要的 HDR 变换条目。', 'Keeps watermark, portrait edits and required HDR transform entries.');
      case OppoCameraTailMode.preserve:
        return t('原样保留完整相机尾部。', 'Keeps the full camera tail unchanged.');
      case OppoCameraTailMode.preserveWithoutPortrait:
        return t('删除景深、分割和人像编辑条目。', 'Removes depth, segmentation and portrait edit entries.');
      case OppoCameraTailMode.preserveWithoutPortraitOrPrivateHdr:
        return t('同时删除人像编辑和私有 HDR 条目。', 'Removes portrait edits and private HDR entries.');
      case OppoCameraTailMode.preserveWithoutPrivateUhdr:
        return t('仅删除私有 UHDR gain map 条目。', 'Removes only private UHDR gain-map entries.');
      case OppoCameraTailMode.preserveWithoutPrivateHdr:
        return t('删除所有私有 HDR 条目。', 'Removes all private HDR entries.');
      case OppoCameraTailMode.preserveNoUhdr:
        return t('保留结构，但中和私有 UHDR 条目名。', 'Keeps structure but neutralizes private UHDR entry names.');
      case OppoCameraTailMode.preserveNoHdr:
        return t('保留结构，但中和所有私有 HDR 条目名。', 'Keeps structure but neutralizes all private HDR entry names.');
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
  skippedPolicy,
  failed,
  cancelled;

  bool get isRunnable => this == QueueItemStatus.pending;

  bool get isTerminal =>
      this == QueueItemStatus.converted ||
      this == QueueItemStatus.skippedExisting ||
      this == QueueItemStatus.skippedPolicy ||
      this == QueueItemStatus.failed ||
      this == QueueItemStatus.cancelled;

  bool get isSuccessful =>
      this == QueueItemStatus.converted ||
      this == QueueItemStatus.skippedExisting ||
      this == QueueItemStatus.skippedPolicy;

  String get displayName {
    switch (this) {
      case QueueItemStatus.pending:
        return t('待处理', 'Pending');
      case QueueItemStatus.running:
        return t('转换中', 'Converting');
      case QueueItemStatus.converted:
        return t('已转换', 'Converted');
      case QueueItemStatus.skippedExisting:
        return t('已跳过', 'Skipped');
      case QueueItemStatus.skippedPolicy:
        return t('按策略跳过', 'Skipped by policy');
      case QueueItemStatus.failed:
        return t('失败', 'Failed');
      case QueueItemStatus.cancelled:
        return t('已取消', 'Cancelled');
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
        return t('就绪', 'Ready');
      case OutputPlanStatus.willOverwriteExisting:
        return t('将覆盖', 'Will overwrite');
      case OutputPlanStatus.skipsExistingValidOutput:
        return t('跳过(有效)', 'Skip (valid)');
      case OutputPlanStatus.duplicateOutput:
        return t('重复输出', 'Duplicate output');
      case OutputPlanStatus.inputMissing:
        return t('输入缺失', 'Input missing');
      case OutputPlanStatus.outputParentIsFile:
        return t('输出路径冲突', 'Output path conflict');
    }
  }
}

// ---------------------------------------------------------------------------
// ConversionConfig
// ---------------------------------------------------------------------------

class ConversionConfig {
  AppLanguage language;
  Family family;
  ConversionBackend backend;
  OutputMode outputMode;
  String? outputDirectory;
  OppoCompatMode oppoCompatibility;
  OppoCameraTailMode oppoCameraTail;
  bool strictTmap;
  bool applePhotographicStyles;
  bool applePortrait;
  bool skipExisting;
  int maxConcurrentJobs;
  String fileNameSuffix;
  bool categorizeOutputByMode;
  bool autoSaveToGallery;
  bool hardwareEncode;

  /// Default per-card handling for Motion Photos (per-card choice overrides).
  MotionPhotoMode motionPhotoDefaultMode;

  ConversionConfig({
    this.language = AppLanguage.chinese,
    this.family = Family.auto,
    this.backend = ConversionBackend.rust,
    this.outputMode = OutputMode.oppo,
    this.outputDirectory,
    this.oppoCompatibility = OppoCompatMode.on,
    this.oppoCameraTail = OppoCameraTailMode.automatic,
    this.strictTmap = false,
    this.applePhotographicStyles = false,
    this.applePortrait = false,
    this.skipExisting = true,
    this.maxConcurrentJobs = 4,
    this.fileNameSuffix = '_iso',
    this.categorizeOutputByMode = false,
    this.autoSaveToGallery = false,
    this.hardwareEncode = false,
    this.motionPhotoDefaultMode = MotionPhotoMode.skip,
  });

  /// Persist to SharedPreferences.
  Map<String, dynamic> toJson() => {
    'language': language.name,
    'family': family.name,
    'backend': backend.name,
    'outputMode': outputMode.name,
    'outputDirectory': outputDirectory,
    'oppoCompatibility': oppoCompatibility.name,
    'oppoCameraTail': oppoCameraTail.name,
    'strictTmap': strictTmap,
    'applePhotographicStyles': applePhotographicStyles,
    'applePortrait': applePortrait,
    'skipExisting': skipExisting,
    'maxConcurrentJobs': maxConcurrentJobs,
    'fileNameSuffix': fileNameSuffix,
    'categorizeOutputByMode': categorizeOutputByMode,
    'autoSaveToGallery': autoSaveToGallery,
    'hardwareEncode': hardwareEncode,
    'motionPhotoDefaultMode': motionPhotoDefaultMode.name,
  };

  factory ConversionConfig.fromJson(Map<String, dynamic> json) {
    return ConversionConfig(
      language: AppLanguage.values.firstWhere(
        (e) => e.name == json['language'],
        orElse: () => AppLanguage.chinese,
      ),
      family: Family.values.firstWhere(
        (e) => e.name == json['family'],
        orElse: () => Family.auto,
      ),
      backend: ConversionBackend.values.firstWhere(
        (e) => e.name == json['backend'],
        orElse: () => ConversionBackend.rust,
      ),
      outputMode: OutputMode.values.firstWhere(
        (e) => e.name == json['outputMode'],
        orElse: () => OutputMode.oppo,
      ),
      outputDirectory: json['outputDirectory'] as String?,
      oppoCompatibility: OppoCompatMode.values.firstWhere(
        (e) => e.name == json['oppoCompatibility'],
        orElse: () => OppoCompatMode.on,
      ),
      oppoCameraTail: OppoCameraTailMode.values.firstWhere(
        (e) => e.name == json['oppoCameraTail'],
        orElse: () => OppoCameraTailMode.automatic,
      ),
      strictTmap: json['strictTmap'] as bool? ?? false,
      applePhotographicStyles:
          json['applePhotographicStyles'] as bool? ?? false,
      applePortrait: json['applePortrait'] as bool? ?? false,
      skipExisting: json['skipExisting'] as bool? ?? true,
      maxConcurrentJobs: json['maxConcurrentJobs'] as int? ?? 4,
      fileNameSuffix: json['fileNameSuffix'] as String? ?? '_iso',
      categorizeOutputByMode: json['categorizeOutputByMode'] as bool? ?? false,
      autoSaveToGallery: json['autoSaveToGallery'] as bool? ?? false,
      hardwareEncode: json['hardwareEncode'] as bool? ?? false,
      motionPhotoDefaultMode: MotionPhotoMode.values.firstWhere(
        (e) => e.name == json['motionPhotoDefaultMode'],
        orElse: () => MotionPhotoMode.skip,
      ),
    );
  }

  ConversionConfig copy() => ConversionConfig(
    language: language,
    family: family,
    backend: backend,
    outputMode: outputMode,
    outputDirectory: outputDirectory,
    oppoCompatibility: oppoCompatibility,
    oppoCameraTail: oppoCameraTail,
    strictTmap: strictTmap,
    applePhotographicStyles: applePhotographicStyles,
    applePortrait: applePortrait,
    skipExisting: skipExisting,
    maxConcurrentJobs: maxConcurrentJobs,
    fileNameSuffix: fileNameSuffix,
    categorizeOutputByMode: categorizeOutputByMode,
    autoSaveToGallery: autoSaveToGallery,
    hardwareEncode: hardwareEncode,
    motionPhotoDefaultMode: motionPhotoDefaultMode,
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
    // Android: capture-mode subdirectories are handled by the gallery album
    // (Pictures/<mode>), not the file system. Desktop: use subdirectories.
    final useSubdir =
        categorizeOutputByMode &&
        captureModeFolderName != null &&
        captureModeFolderName.isNotEmpty &&
        !Platform.isAndroid;
    final dir = useSubdir
        ? '$baseDirectory${Platform.pathSeparator}$captureModeFolderName'
        : baseDirectory;
    final stem = input.uri.pathSegments.last.replaceAll(
      RegExp(r'\.heic$', caseSensitive: false),
      '',
    );
    return '$dir${Platform.pathSeparator}$stem$fileNameSuffix.heic';
  }
}

// ---------------------------------------------------------------------------
// QueueItem
// ---------------------------------------------------------------------------

/// How a Motion Photo queue item is handled at conversion time.
enum MotionPhotoMode {
  /// Do not convert; mark the item as skipped.
  skip,

  /// Convert the still image only (identical to a static photo).
  still,

  /// Convert the still image and also export the video stream(s) next to
  /// the converted output.
  stillAndVideo,

  /// Compose an Apple Live Photo pair: the converted still gains the Apple
  /// MakerNote content identifier and the video is rewritten as a paired MOV
  /// (still-image-time marker). Both files land next to the output; import
  /// them together into Apple Photos to get the Live Photo.
  livePhotoPair;

  String get displayName {
    switch (this) {
      case MotionPhotoMode.skip:
        return t('跳过', 'Skip');
      case MotionPhotoMode.still:
        return t('仅静帧', 'Still only');
      case MotionPhotoMode.stillAndVideo:
        return t('静帧+视频', 'Still + video');
      case MotionPhotoMode.livePhotoPair:
        return 'Live Photo';
    }
  }
}

/// Parsed Motion Photo summary attached to a queue item.
class MotionPhotoSummary {
  /// "androidMotionPhotoV1" | "androidHeifMotionPhotoV1" |
  /// "legacyMicroVideoV1b" | "oppoLivePhoto"
  final String kind;
  final int stillBytes;
  final int videoBytes;
  final int streamCount;

  const MotionPhotoSummary({
    required this.kind,
    required this.stillBytes,
    required this.videoBytes,
    required this.streamCount,
  });

  bool get isDualStream => streamCount >= 2;

  String get videoSizeLabel {
    final mb = videoBytes / (1024 * 1024);
    return mb >= 1 ? '${mb.toStringAsFixed(1)}MB' : '${(videoBytes / 1024).round()}KB';
  }
}

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

  /// "lhdr" or "uhdr" (from the source container), null when not ProXDR.
  String? hdrKind;

  /// "x6" or "x7" family, null when unknown.
  String? family;

  /// Non-null when the input is a Motion Photo (Android V1 / MicroVideo /
  /// HEIF mpvd / OPPO Live Photo). Filled asynchronously after ingest.
  MotionPhotoSummary? motionPhoto;

  /// Per-card handling for Motion Photos. Defaults from the configured
  /// default policy (skip) at ingest time.
  MotionPhotoMode motionPhotoMode;

  /// Backend captured when this item starts, so progress/cancellation remain
  /// tied to the request even if settings change for a later batch.
  ConversionBackend backend;
  DateTime? startedAt;
  DateTime? finishedAt;

  /// Per-file progress within conversion, e.g. (stage: 3, current: 12, total: 48)
  /// meaning HEVC tile 12 / 48 is being encoded. Null when idle or done.
  ({int stage, int current, int total})? progress;

  /// Rust progress handle bound to this item's in-flight conversion (from
  /// `XdRemuxFFI.progressBegin`). Lets the poll loop read this item's real
  /// tile progress even while sibling conversions run concurrently.
  /// 0 when no conversion is running for this item.
  int progressHandle = 0;

  /// Human-readable progress label derived from [progress].
  String get progressLabel {
    final p = progress;
    if (p == null || p.stage == 0) return '';
    return switch (p.stage) {
      1 => t('解析元数据…', 'Parsing metadata…'),
      2 => t('解码JPEG…', 'Decoding JPEG…'),
      3 => t('编码 HEVC ${p.current}/${p.total}', 'Encoding HEVC ${p.current}/${p.total}'),
      4 => t('组装输出…', 'Assembling output…'),
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
    this.hdrKind,
    this.family,
    this.motionPhoto,
    this.motionPhotoMode = MotionPhotoMode.skip,
    this.backend = ConversionBackend.rust,
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
        return t('无拍摄模式', 'No capture mode');
      case 'malformed-user-comment':
        return t('拍摄模式格式异常', 'Malformed capture mode');
      case 'unknown-flags':
        return t('未知拍摄模式', 'Unknown capture mode');
      case 'unreadable-image':
        return t('无法读取拍摄模式', 'Unreadable capture mode');
      default:
        return captureModeFolderName ?? t('未分类', 'Uncategorized');
    }
  }

  bool get isSuccessful => status.isSuccessful;

  Duration? get duration {
    if (startedAt == null || finishedAt == null) return null;
    return finishedAt!.difference(startedAt!);
  }
}
