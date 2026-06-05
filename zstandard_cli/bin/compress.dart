import 'dart:io';

import 'package:zstandard_cli/src/utils/constants.dart';
import 'package:zstandard_cli/src/utils/size_utils.dart';
import 'package:zstandard_cli/zstandard_cli.dart';

void main(List<String> args) async {
  print('===================== 📦 zstandard_cli =====================\n');

  final cli = ZstandardCLI();
  print('Running on: ${await cli.getPlatformVersion()}\n');

  final filePath = args.firstOrNull;

  int compressionLevel = 3;
  if (args.length > 1) {
    String cl = args[1] as String? ?? '3';
    compressionLevel = int.tryParse(cl) ?? 3;
  }

  if (filePath == null) {
    print('Path not found: $filePath');
    return;
  }
  final file = File(filePath);
  if (!file.existsSync()) {
    print('File not found: $filePath');
    return;
  }

  final inputBytes = file.readAsBytesSync();
  print('Compressing ${file.path} ${formatByteSize(inputBytes.length)}');

  final compressed = await cli.compress(
    inputBytes,
    compressionLevel: compressionLevel,
  );
  if (compressed == null) {
    print('Error compressing: $filePath');
    return;
  }

  final compressedFilePath = '$filePath$extension';
  final compressedFile = File(compressedFilePath);
  compressedFile.writeAsBytesSync(compressed);
  if (!compressedFile.existsSync()) {
    print('Compressed file not found: $compressedFilePath');
    return;
  }

  print(
      'Compressed ${compressedFile.path} ${formatByteSize(compressed.length)} \n');
}
