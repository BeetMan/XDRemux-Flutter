import 'dart:io';

/// True when writing [output] would write over [input]: the same path, a
/// symbolic link to the same file, or the same file under another spelling
/// (letter case on a case-insensitive volume including network mounts whose
/// inodes follow the path, or an output folder that links to the source
/// folder). Deleting or replacing [output] would then destroy the original.
bool outputWouldOverwriteInput(String input, String output) {
  if (File(input).absolute.path == File(output).absolute.path) return true;
  try {
    if (!File(input).existsSync() || !File(output).existsSync()) return false;
    if (FileSystemEntity.identicalSync(input, output)) return true;
    final realInput = File(input).resolveSymbolicLinksSync();
    final realOutput = File(output).resolveSymbolicLinksSync();
    if (realInput == realOutput) return true;
    if (FileSystemEntity.identicalSync(realInput, realOutput)) return true;
    return _sameCaseInsensitiveFile(realInput, realOutput);
  } on FileSystemException {
    return false;
  }
}

bool _sameCaseInsensitiveFile(String realInput, String realOutput) {
  final parent = File(realInput).parent.path;
  if (parent != File(realOutput).parent.path) return false;
  final inSegs = File(realInput).uri.pathSegments.where((s) => s.isNotEmpty);
  final outSegs = File(realOutput).uri.pathSegments.where((s) => s.isNotEmpty);
  if (inSegs.isEmpty || outSegs.isEmpty) return false;
  final inName = inSegs.last;
  final outName = outSegs.last;
  if (inName == outName) return true;
  if (inName.toLowerCase() != outName.toLowerCase()) return false;

  final variant = _thirdAsciiCaseVariant(inName, outName);
  if (variant != null) {
    return File('$parent${Platform.pathSeparator}$variant').existsSync();
  }
  final inStat = File(realInput).statSync();
  final outStat = File(realOutput).statSync();
  return inStat.size == outStat.size && inStat.modified == outStat.modified;
}

String? _thirdAsciiCaseVariant(String a, String b) {
  final units = a.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final c = units[i];
    final int? flipped = (c >= 65 && c <= 90)
        ? c + 32
        : (c >= 97 && c <= 122)
        ? c - 32
        : null;
    if (flipped == null) continue;
    final candidate =
        a.substring(0, i) + String.fromCharCode(flipped) + a.substring(i + 1);
    if (candidate != a && candidate != b) return candidate;
  }
  return null;
}
