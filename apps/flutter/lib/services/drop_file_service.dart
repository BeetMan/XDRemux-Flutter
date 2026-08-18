import 'dart:async';

/// Routes native desktop file drops to the currently active screen.
class DropFileService {
  DropFileService._();

  static final StreamController<List<String>> _controller =
      StreamController<List<String>>.broadcast();
  static bool workflowActive = false;

  static Stream<List<String>> get files => _controller.stream;

  static void publish(List<String> paths) {
    if (paths.isNotEmpty) _controller.add(paths);
  }
}
