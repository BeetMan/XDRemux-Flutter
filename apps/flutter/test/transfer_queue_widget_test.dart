import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xdremux/main.dart';
import 'package:xdremux/services/checkpoint_service.dart';
import 'package:xdremux/services/transfer/transfer_copy.dart';
import 'package:xdremux/services/transfer/transfer_intake.dart';
import 'package:xdremux/services/transfer/transfer_models.dart';
import 'package:xdremux/services/transfer/transfer_service.dart';

class _ReceivedInput extends TransferService {
  _ReceivedInput(this.root, this.lease);
  final String root;
  final Map<String, dynamic> lease;
  @override
  Future<TransferInput> prepareInput(String id) async {
    final result = await copyTransferInput(root, lease);
    return TransferInput(
      receiptId: result['receiptId'] as String,
      path: result['path'] as String,
      outputDirectory: result['outputDirectory'] as String,
      name: result['name'] as String,
    );
  }
}

void main() {
  final fixture = Platform.environment['XDREMUX_TRANSFER_QUEUE_FIXTURE'];
  testWidgets(
    'real classifier and home queue persist explicit transfer ACK',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'skipExisting': false,
        'applePortrait': false,
      });
      ReceiveSharingIntent.setMockValues(
        initialMedia: const [],
        mediaStream: const Stream.empty(),
      );
      final root = await tester.runAsync(
        () => Directory.systemTemp.createTemp('xdremux-queue-integration-'),
      );
      final temp = root!;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => temp.path,
          );
      late _ReceivedInput service;
      try {
        await tester.pumpWidget(const XdRemuxApp());
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
        final ack = await tester.runAsync(() async {
          final source = await File(fixture!).copy('${temp.path}/inbox-data');
          final hash = (await sha256.bind(source.openRead()).first).toString();
          const id = '33333333-3333-4333-8333-333333333333';
          service = _ReceivedInput(temp.path, {
            'path': source.path,
            'receipt': {
              'id': id,
              'name': '接收照片.heic',
              'size': await source.length(),
              'sha256': hash,
            },
          });
          final intake = TransferIntake(service);
          final ack = await intake.importReceipt(id);
          expect(ack.status, TransferIntakeStatus.added);
          final checkpoint = await CheckpointService.load();
          expect(checkpoint, isNotNull);
          expect(checkpoint!.items.length, 1);
          final input = File(checkpoint.items.single.inputPath);
          expect(await input.exists(), isTrue);
          expect((await sha256.bind(input.openRead()).first).toString(), hash);
          expect(
            checkpoint.items.single.outputPath,
            isNot(startsWith(input.parent.path)),
          );
          expect(
            (await intake.importReceipt(id)).status,
            TransferIntakeStatus.duplicate,
          );
          await source.delete();
          expect(await input.exists(), isTrue);
          return ack;
        });
        expect(ack!.queueId, isNotEmpty);
        await tester.pump();
        expect(find.textContaining('接收照片.heic'), findsWidgets);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(service.dispose);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => temp.delete(recursive: true));
      }
    },
    skip: fixture == null || !File(fixture).existsSync(),
  );
}
