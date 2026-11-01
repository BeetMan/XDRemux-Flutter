import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/models/checkpoint_model.dart';

void main() {
  test('saved header counts the items actually written', () {
    // Resuming appends items without rebuilding the header.
    final checkpoint = Checkpoint(
      header: CheckpointHeader(
        configHash: 'h',
        totalJobs: 1,
        startedAt: DateTime.parse('2026-10-28T08:00:00Z'),
        appVersion: '0.4.5',
      ),
      items: [
        CheckpointItem(inputPath: '/in/a.heic', outputPath: '/out/a.heic'),
        CheckpointItem(inputPath: '/in/b.heic', outputPath: '/out/b.heic'),
      ],
    );
    final lines = const LineSplitter().convert(checkpoint.toJsonl());
    expect(jsonDecode(lines.first)['totalJobs'], 2);
    expect(lines.skip(1), hasLength(2));
  });
}
