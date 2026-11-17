import 'dart:io';

/// True when writing [output] would write over [input]: the same path, or
/// the same file under another spelling (letter case on a case-insensitive
/// volume, an output folder that links to the source folder). Deleting or
/// replacing [output] would then destroy the original.
bool outputWouldOverwriteInput(String input, String output) {
  if (File(input).absolute.path == File(output).absolute.path) return true;
  try {
    return File(input).existsSync() &&
        File(output).existsSync() &&
        FileSystemEntity.identicalSync(input, output);
  } on FileSystemException {
    return false;
  }
}
