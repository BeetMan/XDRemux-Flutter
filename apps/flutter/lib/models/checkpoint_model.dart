/// Checkpoint model for batch conversion resume support (M6).
///
/// Uses JSONL format: first line is header, subsequent lines are per-file items.
library;

import 'dart:convert';

// ---------------------------------------------------------------------------
// CheckpointHeader
// ---------------------------------------------------------------------------

class CheckpointHeader {
  final String configHash;
  final int totalJobs;
  final DateTime startedAt;
  final String appVersion;

  CheckpointHeader({
    required this.configHash,
    required this.totalJobs,
    required this.startedAt,
    required this.appVersion,
  });

  Map<String, dynamic> toJson() => {
        'type': 'header',
        'configHash': configHash,
        'totalJobs': totalJobs,
        'startedAt': startedAt.toIso8601String(),
        'appVersion': appVersion,
      };

  factory CheckpointHeader.fromJson(Map<String, dynamic> json) {
    return CheckpointHeader(
      configHash: json['configHash'] as String? ?? '',
      totalJobs: json['totalJobs'] as int? ?? 0,
      startedAt: DateTime.tryParse(json['startedAt'] as String? ?? '') ??
          DateTime.now(),
      appVersion: json['appVersion'] as String? ?? '',
    );
  }
}

// ---------------------------------------------------------------------------
// CheckpointItemStatus
// ---------------------------------------------------------------------------

enum CheckpointItemStatus {
  pending,
  converted,
  skippedExisting,
  failed;

  String get wire => name;

  static CheckpointItemStatus fromWire(String? s) {
    return CheckpointItemStatus.values.firstWhere(
      (e) => e.name == s,
      orElse: () => CheckpointItemStatus.pending,
    );
  }
}

// ---------------------------------------------------------------------------
// CheckpointItem
// ---------------------------------------------------------------------------

class CheckpointItem {
  final String inputPath;
  final String outputPath;
  CheckpointItemStatus status;
  final int inputSize;
  final int inputMtimeMs;
  String? error;
  DateTime? finishedAt;

  CheckpointItem({
    required this.inputPath,
    required this.outputPath,
    this.status = CheckpointItemStatus.pending,
    this.inputSize = 0,
    this.inputMtimeMs = 0,
    this.error,
    this.finishedAt,
  });

  Map<String, dynamic> toJson() => {
        'type': 'item',
        'inputPath': inputPath,
        'outputPath': outputPath,
        'status': status.wire,
        'inputSize': inputSize,
        'inputMtimeMs': inputMtimeMs,
        if (error != null) 'error': error,
        if (finishedAt != null) 'finishedAt': finishedAt!.toIso8601String(),
      };

  factory CheckpointItem.fromJson(Map<String, dynamic> json) {
    return CheckpointItem(
      inputPath: json['inputPath'] as String? ?? '',
      outputPath: json['outputPath'] as String? ?? '',
      status: CheckpointItemStatus.fromWire(json['status'] as String?),
      inputSize: json['inputSize'] as int? ?? 0,
      inputMtimeMs: json['inputMtimeMs'] as int? ?? 0,
      error: json['error'] as String?,
      finishedAt: json['finishedAt'] != null
          ? DateTime.tryParse(json['finishedAt'] as String)
          : null,
    );
  }

  /// Whether this item represents a successfully completed conversion.
  bool get isDone =>
      status == CheckpointItemStatus.converted ||
      status == CheckpointItemStatus.skippedExisting;
}

// ---------------------------------------------------------------------------
// Checkpoint (aggregate)
// ---------------------------------------------------------------------------

class Checkpoint {
  final CheckpointHeader header;
  final List<CheckpointItem> items;

  Checkpoint({required this.header, required this.items});

  /// Serialize to JSONL string (header on first line, items on subsequent lines).
  String toJsonl() {
    final buffer = StringBuffer();
    buffer.writeln(jsonEncode(header.toJson()));
    for (final item in items) {
      buffer.writeln(jsonEncode(item.toJson()));
    }
    return buffer.toString();
  }

  /// Parse from JSONL string.
  static Checkpoint? fromJsonl(String content) {
    final lines = content.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return null;

    try {
      final headerJson = jsonDecode(lines.first) as Map<String, dynamic>;
      if (headerJson['type'] != 'header') return null;
      final header = CheckpointHeader.fromJson(headerJson);

      final items = <CheckpointItem>[];
      for (int i = 1; i < lines.length; i++) {
        final itemJson = jsonDecode(lines[i]) as Map<String, dynamic>;
        if (itemJson['type'] == 'item') {
          items.add(CheckpointItem.fromJson(itemJson));
        }
      }

      return Checkpoint(header: header, items: items);
    } catch (_) {
      return null;
    }
  }

  /// Number of successfully completed items.
  int get completedCount => items.where((i) => i.isDone).length;

  /// Number of failed items.
  int get failedCount =>
      items.where((i) => i.status == CheckpointItemStatus.failed).length;

  /// Number of pending (not yet attempted) items.
  int get pendingCount =>
      items.where((i) => i.status == CheckpointItemStatus.pending).length;

  /// Whether all items are done with zero failures.
  bool get allSuccess =>
      items.isNotEmpty &&
      items.every((i) => i.isDone);

  /// Whether the checkpoint has any failures.
  bool get hasFailures => failedCount > 0;
}
