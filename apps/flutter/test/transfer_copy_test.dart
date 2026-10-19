import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xdremux/models/app_models.dart';
import 'package:xdremux/models/checkpoint_model.dart';
import 'package:xdremux/services/checkpoint_service.dart';
import 'package:xdremux/services/transfer/transfer_copy.dart';
import 'package:xdremux/services/transfer/transfer_intake.dart';
import 'package:xdremux/services/transfer/transfer_models.dart';
import 'package:xdremux/services/transfer/transfer_queue.dart';
import 'package:xdremux/services/transfer/transfer_service.dart';

const firstId = '11111111-1111-4111-8111-111111111111';
const secondId = '22222222-2222-4222-8222-222222222222';
final jpeg = [255, 216, 255, ...List<int>.generate(128 * 1024, (i) => i % 256)];

class _Inputs extends TransferService {
  _Inputs(this.root, this.lease);
  final String root;
  final Map<String, dynamic> lease;
  int preparations = 0;
  @override
  Future<TransferInput> prepareInput(String receiptId) async {
    preparations++;
    final copied = await copyTransferInput(root, lease);
    return TransferInput(
      receiptId: copied['receiptId'] as String,
      path: copied['path'] as String,
      outputDirectory: copied['outputDirectory'] as String,
      name: copied['name'] as String,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late Map<String, dynamic> lease;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('xdremux-transfer-copy-');
    final source = File('${temp.path}/inbox-data');
    await source.writeAsBytes(jpeg);
    lease = {
      'lease_id': 1,
      'path': source.path,
      'receipt': {
        'id': firstId,
        'name': '照片😀.jpg',
        'size': jpeg.length,
        'sha256': sha256.convert(jpeg).toString(),
      },
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => temp.path,
        );
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test(
    'strict checkpoint ACK fails if the atomic save cannot publish',
    () async {
      final blocked = Directory('${temp.path}/xdremux_checkpoint.jsonl');
      await blocked.create();
      await File('${blocked.path}/sentinel').writeAsString('keep');
      final checkpoint = Checkpoint(
        header: CheckpointHeader(
          configHash: 'test',
          totalJobs: 0,
          startedAt: DateTime.now(),
          appVersion: 'test',
        ),
        items: [],
      );
      await expectLater(
        CheckpointService.save(checkpoint, requirePersistence: true),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File('${blocked.path}/sentinel').readAsString(), 'keep');
    },
  );

  test(
    'independent verified copies preserve names and isolate same-name receipts',
    () async {
      final first = await copyTransferInput(temp.path, lease);
      final same = await copyTransferInput(temp.path, lease);
      expect(first['path'], same['path']);
      final second = await copyTransferInput(temp.path, {
        ...lease,
        'receipt': {...lease['receipt'] as Map, 'id': secondId},
      });
      expect(first['path'], isNot(second['path']));
      expect(File(first['path'] as String).uri.pathSegments.last, '照片😀.jpg');
      expect(await File(first['path'] as String).readAsBytes(), jpeg);
      await File(lease['path'] as String).delete();
      expect(await File(first['path'] as String).length(), jpeg.length);
      final output = ConversionConfig().outputPathFor(first['path'] as String);
      expect(output, startsWith(first['outputDirectory'] as String));
      expect(
        output,
        isNot(startsWith(File(first['path'] as String).parent.path)),
      );
    },
  );

  test(
    'bad hash, unsupported magic, path attacks and tampered copies fail closed',
    () async {
      final badHash = {
        ...lease,
        'receipt': {...lease['receipt'] as Map, 'sha256': '0' * 64},
      };
      await expectLater(
        copyTransferInput(temp.path, badHash),
        throwsA(
          isA<TransferException>().having(
            (e) => e.code,
            'code',
            'checksum_mismatch',
          ),
        ),
      );
      final inputs = Directory('${temp.path}/xdremux_checkpoint_inputs');
      expect(await inputs.list().toList(), isEmpty);
      await expectLater(
        copyTransferInput(temp.path, {
          ...lease,
          'receipt': {...lease['receipt'] as Map, 'name': '../photo.jpg'},
        }),
        throwsA(isA<TransferException>()),
      );
      await File(
        lease['path'] as String,
      ).writeAsBytes(List<int>.filled(jpeg.length, 0));
      await expectLater(
        copyTransferInput(temp.path, lease),
        throwsA(
          isA<TransferException>().having((e) => e.code, 'code', 'unsupported'),
        ),
      );
      await File(lease['path'] as String).writeAsBytes(jpeg);
      final copy = await copyTransferInput(temp.path, lease);
      await File(copy['path'] as String).writeAsBytes([1, 2]);
      await expectLater(
        copyTransferInput(temp.path, lease),
        throwsA(
          isA<TransferException>().having(
            (e) => e.code,
            'code',
            'unsafe_storage',
          ),
        ),
      );
      expect(await File(copy['path'] as String).readAsBytes(), [1, 2]);
    },
  );

  test(
    'retry after queue ACK loss reuses copy and records explicit duplicate ACK',
    () async {
      final service = _Inputs(temp.path, lease);
      addTearDown(service.dispose);
      final queued = <String>{};
      var first = true;
      final intake = TransferIntake(service, (input) async {
        final duplicate = !queued.add(input.path);
        if (first) {
          first = false;
          throw const TransferException('io');
        }
        return TransferIntakeAck(
          duplicate
              ? TransferIntakeStatus.duplicate
              : TransferIntakeStatus.added,
          queueId: 'queue-1',
        );
      });
      await expectLater(
        intake.importReceipt(firstId),
        throwsA(isA<TransferException>()),
      );
      expect(TransferQueue.importing, isFalse);
      final ack = await intake.importReceipt(firstId);
      expect(ack.status, TransferIntakeStatus.duplicate);
      expect(queued.length, 1);
      final marker = File('${File(queued.single).parent.path}/receipt.json');
      final json = jsonDecode(await marker.readAsString()) as Map;
      expect(json['state'], 'duplicate');
      expect(json['queueId'], 'queue-1');
    },
  );

  test('concurrent clicks coalesce and cleanup waits for queue ACK', () async {
    final service = _Inputs(temp.path, lease);
    addTearDown(service.dispose);
    final entered = Completer<TransferInput>();
    final accept = Completer<void>();
    final intake = TransferIntake(service, (input) async {
      entered.complete(input);
      await accept.future;
      return const TransferIntakeAck(TransferIntakeStatus.added, queueId: 'q');
    });
    final importTask = intake.importReceipt(firstId);
    final concurrent = intake.importReceipt(firstId);
    expect(identical(importTask, concurrent), isTrue);
    final input = await entered.future;
    var cleaned = false;
    final cleanup = CheckpointService.cleanupSingleMaterializedInput(
      input.path,
    ).then((_) => cleaned = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(cleaned, isFalse);
    expect(await File(input.path).exists(), isTrue);
    accept.complete();
    await importTask;
    await cleanup;
    expect(service.preparations, 1);
    expect(await File(input.path).exists(), isFalse);
    expect(await File(lease['path'] as String).exists(), isTrue);
    // Specific queue cleanup removes the receipt marker, so later reimport works.
    await copyTransferInput(temp.path, lease);
  });

  test(
    'picker bulk cleanup preserves transfer buckets and crash recovery keeps originals',
    () async {
      final copy = await copyTransferInput(temp.path, lease);
      final picker = Directory(
        '${temp.path}/xdremux_checkpoint_inputs/picker-1',
      );
      await picker.create();
      await File('${picker.path}/photo.jpg').writeAsBytes([1]);
      await CheckpointService.cleanupAllMaterializedInputs();
      expect(await File(copy['path'] as String).exists(), isTrue);
      expect(await picker.exists(), isFalse);
      final abandoned = Directory(
        '${temp.path}/xdremux_checkpoint_inputs/transfer-staging-owned1',
      );
      await abandoned.create();
      await File('${abandoned.path}/partial.jpg').writeAsBytes([1]);
      final marker = File(
        '${File(copy['path'] as String).parent.path}/receipt.json',
      );
      await File(
        '${marker.path}.tmp',
      ).writeAsString(await marker.readAsString());
      await copyTransferInput(temp.path, lease);
      await persistTransferAck(
        copy['path'] as String,
        const TransferIntakeAck(TransferIntakeStatus.added, queueId: 'q'),
      );
      expect(await abandoned.exists(), isFalse);
      expect(await File('${marker.path}.tmp').exists(), isFalse);
      expect(await File(lease['path'] as String).readAsBytes(), jpeg);
    },
  );
}
