import 'transfer_models.dart';

/// One application queue owner; registration has no network or native side effects.
class TransferQueue {
  static Object? _owner;
  static TransferQueueIntake? _intake;
  static Set<String> Function()? _retainedInputs;
  static Set<String> get retainedInputPaths =>
      Set.of(_retainedInputs?.call() ?? {});
  static int imports = 0;
  static bool get importing => imports > 0;
  static int _admissions = 0;
  static bool get admitting => _admissions > 0;
  static Future<T> withAdmission<T>(Future<T> Function() action) async {
    _admissions++;
    try {
      return await action();
    } finally {
      _admissions--;
    }
  }

  static Future<void> _inputWork = Future<void>.value();
  static Future<T> withInputAccess<T>(Future<T> Function() work) {
    final result = _inputWork.then((_) => work());
    _inputWork = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  static void register(
    Object owner,
    TransferQueueIntake intake, {
    Set<String> Function()? retainedInputs,
  }) {
    _owner = owner;
    _intake = intake;
    _retainedInputs = retainedInputs;
  }

  static void unregister(Object owner) {
    if (identical(owner, _owner)) {
      _owner = null;
      _intake = null;
      _retainedInputs = null;
    }
  }

  static Future<TransferIntakeAck> enqueue(TransferInput input) async =>
      _intake == null
      ? const TransferIntakeAck(TransferIntakeStatus.rejected)
      : await _intake!(input);
}
