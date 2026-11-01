/// Redacted transfer errors. Never stringify native requests or file paths.
class TransferException implements Exception {
  const TransferException(this.code, {this.operationId});
  final String code;
  final int? operationId;
  @override
  String toString() => 'TransferException($code)';
}

class TransferAvailability {
  const TransferAvailability(this.available, [this.reason]);
  final bool available;
  final String? reason;
}

enum TransferIntakeStatus { added, duplicate, unsupported, rejected, failed }

/// The queue callback must persist its checkpoint before returning added/duplicate.
/// It must deduplicate by receipt ID or the deterministic input path on recovery.
class TransferIntakeAck {
  const TransferIntakeAck(this.status, {this.queueId});
  final TransferIntakeStatus status;
  final String? queueId;
}

class TransferInput {
  const TransferInput({
    required this.receiptId,
    required this.path,
    required this.outputDirectory,
    required this.name,
  });
  final String receiptId;
  final String path;
  final String outputDirectory;
  final String name;
}

typedef TransferQueueIntake =
    Future<TransferIntakeAck> Function(TransferInput input);

bool transferImageName(String name) {
  final lower = name.toLowerCase();
  return ['.heic', '.heif', '.jpg', '.jpeg'].any(lower.endsWith);
}
