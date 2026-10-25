import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'transfer_models.dart';

final _receiptId = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

Future<void> _directory(Directory dir) async {
  final type = await FileSystemEntity.type(dir.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    await dir.create();
  } else if (type != FileSystemEntityType.directory) {
    throw const TransferException('unsafe_storage');
  }
}

bool transferSafeName(String name) =>
    name.isNotEmpty &&
    utf8.encode(name).length <= 240 &&
    !RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]').hasMatch(name) &&
    !name.endsWith('.') &&
    !name.endsWith(' ') &&
    name != '..' &&
    !RegExp(
      r'^(CON|PRN|AUX|NUL|CLOCK\$|COM[0-9]|LPT[0-9])(?:\.|$)',
      caseSensitive: false,
    ).hasMatch(name);

Future<String> _hash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<Map<String, dynamic>> _readMarker(File marker) async {
  if (await FileSystemEntity.type(marker.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await marker.length() > 16384) {
    throw const TransferException('unsafe_storage');
  }
  try {
    return jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
  } catch (_) {
    throw const TransferException('unsafe_storage');
  }
}

Future<void> _recoverStaging(Directory inputs) async {
  await for (final entry in inputs.list(followLinks: false)) {
    final name = entry.path.split(RegExp(r'[/\\]')).last;
    if (!RegExp(r'^transfer-staging-[A-Za-z0-9_-]+$').hasMatch(name)) continue;
    if (entry is! Directory) throw const TransferException('unsafe_storage');
    final children = await entry.list(followLinks: false).toList();
    if (children.length > 2 ||
        children.any(
          (c) =>
              c is! File ||
              !(c.path.split(RegExp(r'[/\\]')).last == 'receipt.json' ||
                  transferImageName(c.path)),
        )) {
      throw const TransferException('unsafe_storage');
    }
    for (final child in children) {
      await child.delete();
    }
    await entry.delete();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest value) {
    digest = value;
  }

  @override
  void close() {}
}

/// Runs in the worker. Caller holds the native read lease throughout this call.
Future<Map<String, dynamic>> copyTransferInput(
  String supportRoot,
  Map<String, dynamic> lease,
) async {
  final receipt = Map<String, dynamic>.from(lease['receipt'] as Map);
  final id = receipt['id'] as String;
  final name = receipt['name'] as String;
  final size = receipt['size'] as int;
  final hash = receipt['sha256'] as String;
  if (!_receiptId.hasMatch(id) ||
      !transferSafeName(name) ||
      size < 0 ||
      !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash)) {
    throw const TransferException('unsafe_storage');
  }
  if (!transferImageName(name)) throw const TransferException('unsupported');
  final support = Directory(supportRoot);
  await _directory(support);
  final inputs = Directory(
    '$supportRoot${Platform.pathSeparator}xdremux_checkpoint_inputs',
  );
  await _directory(inputs);
  await _recoverStaging(inputs);
  final bucket = Directory(
    '${inputs.path}${Platform.pathSeparator}transfer-$id',
  );
  final destination = File('${bucket.path}${Platform.pathSeparator}$name');
  final outputBase = Directory(
    '$supportRoot${Platform.pathSeparator}xdremux_transfer_outputs',
  );
  await _directory(outputBase);
  final output = Directory('${outputBase.path}${Platform.pathSeparator}$id');
  await _directory(output);
  final source = File(lease['path'] as String);
  if (await FileSystemEntity.type(source.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const TransferException('unsafe_storage');
  }
  // Cheap content gate; final admission still belongs to the existing classifier.
  final reader = await source.open();
  late List<int> header;
  try {
    header = await reader.read(64);
  } finally {
    await reader.close();
  }
  final jpeg =
      header.length >= 3 &&
      header[0] == 255 &&
      header[1] == 216 &&
      header[2] == 255;
  final heif =
      header.length >= 12 &&
      ascii.decode(header.sublist(4, 8), allowInvalid: true) == 'ftyp' &&
      [
        'heic',
        'heix',
        'hevc',
        'hevx',
        'mif1',
        'msf1',
      ].contains(ascii.decode(header.sublist(8, 12), allowInvalid: true));
  if (!(name.toLowerCase().endsWith('.jpg') ||
          name.toLowerCase().endsWith('.jpeg')
      ? jpeg
      : heif)) {
    throw const TransferException('unsupported');
  }
  if (await FileSystemEntity.type(bucket.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    await _directory(bucket);
    final recorded = await _readMarker(
      File('${bucket.path}${Platform.pathSeparator}receipt.json'),
    );
    if (recorded['id'] != id ||
        recorded['name'] != name ||
        recorded['size'] != size ||
        recorded['sha256'].toString().toLowerCase() != hash.toLowerCase()) {
      throw const TransferException('unsafe_storage');
    }
    if (await FileSystemEntity.type(destination.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await destination.length() != size ||
        await _hash(destination) != hash.toLowerCase()) {
      throw const TransferException('unsafe_storage');
    }
  } else {
    final staging = await inputs.createTemp('transfer-staging-');
    try {
      final target = File('${staging.path}${Platform.pathSeparator}$name');
      final sink = _DigestSink();
      final digest = sha256.startChunkedConversion(sink);
      final file = await target.open(mode: FileMode.writeOnly);
      var written = 0;
      try {
        await for (final chunk in source.openRead()) {
          written += chunk.length;
          if (written > size) {
            throw const TransferException('checksum_mismatch');
          }
          digest.add(chunk);
          await file.writeFrom(chunk);
        }
        digest.close();
        if (written != size || sink.digest.toString() != hash.toLowerCase()) {
          throw const TransferException('checksum_mismatch');
        }
        await file.flush();
      } finally {
        await file.close();
      }
      await File(
        '${staging.path}${Platform.pathSeparator}receipt.json',
      ).writeAsString(
        jsonEncode({
          'id': id,
          'name': name,
          'size': size,
          'sha256': hash,
          'state': 'prepared',
        }),
        flush: true,
      );
      await staging.rename(bucket.path);
    } finally {
      if (await staging.exists()) {
        // Only files created by this attempt; never recursively traverse a link.
        for (final child in await staging.list(followLinks: false).toList()) {
          if (child is File) await child.delete();
        }
        await staging.delete();
      }
    }
  }
  return {
    'receiptId': id,
    'path': destination.path,
    'outputDirectory': output.path,
    'name': name,
  };
}

Future<void> persistTransferAck(String inputPath, TransferIntakeAck ack) async {
  final bucket = File(inputPath).parent;
  await _directory(bucket);
  final marker = File('${bucket.path}${Platform.pathSeparator}receipt.json');
  if (await FileSystemEntity.type(marker.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const TransferException('unsafe_storage');
  }
  final data = await _readMarker(marker);
  data['state'] = ack.status.name;
  data['queueId'] = ack.queueId;
  final temp = File('${marker.path}.tmp');
  if (await FileSystemEntity.type(temp.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    final abandoned = await _readMarker(temp);
    if (abandoned['id'] != data['id'] ||
        abandoned['name'] != data['name'] ||
        abandoned['size'] != data['size'] ||
        abandoned['sha256'] != data['sha256']) {
      throw const TransferException('unsafe_storage');
    }
    await temp.delete();
  }
  try {
    await temp.writeAsString(jsonEncode(data), flush: true);
    await temp.rename(marker.path);
  } finally {
    if (await temp.exists()) await temp.delete();
  }
}
