import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;

import '../zstandard_native_bindings.dart';

/// Native extraction phase for a `.tar.zst` archive.
enum ZstandardNativeTarExtractionStage {
  /// The zstd stream is being decompressed into a temporary tar file.
  decompressing,

  /// The temporary tar file is being extracted to disk.
  extracting,

  /// Extraction has completed.
  completed,
}

/// Progress event emitted while extracting a `.tar.zst` archive.
class ZstandardNativeTarExtractionProgress {
  /// Creates a native progress event.
  const ZstandardNativeTarExtractionProgress({
    required this.stage,
    required this.progress,
    required this.compressedBytesRead,
    required this.tarBytesWritten,
    required this.entriesExtracted,
    this.totalCompressedBytes,
    this.currentEntry,
  });

  /// Current extraction phase.
  final ZstandardNativeTarExtractionStage stage;

  /// Overall progress in the range 0.0 to 1.0.
  final double progress;

  /// Number of compressed input bytes consumed.
  final int compressedBytesRead;

  /// Total compressed input bytes, when known.
  final int? totalCompressedBytes;

  /// Number of decompressed tar bytes written.
  final int tarBytesWritten;

  /// Number of tar entries extracted so far.
  final int entriesExtracted;

  /// Current tar entry name, when extracting.
  final String? currentEntry;
}

/// Result returned after extracting a `.tar.zst` archive.
class ZstandardNativeTarExtractionResult {
  /// Creates a native extraction result.
  const ZstandardNativeTarExtractionResult({
    required this.outputDirectoryPath,
    required this.entriesExtracted,
    required this.compressedBytesRead,
    required this.tarBytesWritten,
  });

  /// Directory that received the extracted tar entries.
  final String outputDirectoryPath;

  /// Number of extracted tar entries.
  final int entriesExtracted;

  /// Number of compressed input bytes consumed.
  final int compressedBytesRead;

  /// Number of decompressed tar bytes written.
  final int tarBytesWritten;
}

/// Extracts [archivePath] as a `.tar.zst` archive into [outputDirectoryPath].
///
/// This avoids materializing the full compressed archive or decompressed tar in
/// Dart memory. The zstd stream is decompressed into a temporary tar file, and
/// that tar file is then extracted with asynchronous chunked file I/O.
Future<ZstandardNativeTarExtractionResult> extractTarZstArchive({
  required ZstandardNativeBindings bindings,
  required String archivePath,
  required String outputDirectoryPath,
  String? temporaryDirectoryPath,
  bool overwrite = false,
  void Function(ZstandardNativeTarExtractionProgress progress)? onProgress,
}) async {
  final archiveFile = File(archivePath);
  final totalCompressedBytes =
      onProgress == null ? null : await _tryFileLength(archiveFile);
  final outputDirectory = Directory(outputDirectoryPath);
  await outputDirectory.create(recursive: true);

  final tempParent = temporaryDirectoryPath == null
      ? Directory.systemTemp
      : Directory(temporaryDirectoryPath);
  await tempParent.create(recursive: true);
  final tempRoot = await tempParent.createTemp('zstandard_tar_zst_');
  final tempTar = File(path.join(tempRoot.path, 'archive.tar'));

  try {
    final decompressed = await _decompressZstdFileToTar(
      bindings: bindings,
      source: archiveFile,
      target: tempTar,
      totalCompressedBytes: totalCompressedBytes,
      onProgress: onProgress,
    );
    final entriesExtracted = await _extractTarFile(
      tarFile: tempTar,
      outputDirectory: outputDirectory,
      overwrite: overwrite,
      compressedBytesRead: decompressed.compressedBytesRead,
      tarBytesWritten: decompressed.tarBytesWritten,
      onProgress: onProgress,
    );
    final result = ZstandardNativeTarExtractionResult(
      outputDirectoryPath: outputDirectory.path,
      entriesExtracted: entriesExtracted,
      compressedBytesRead: decompressed.compressedBytesRead,
      tarBytesWritten: decompressed.tarBytesWritten,
    );
    onProgress?.call(
      ZstandardNativeTarExtractionProgress(
        stage: ZstandardNativeTarExtractionStage.completed,
        progress: 1,
        compressedBytesRead: decompressed.compressedBytesRead,
        totalCompressedBytes: decompressed.compressedBytesRead,
        tarBytesWritten: decompressed.tarBytesWritten,
        entriesExtracted: entriesExtracted,
      ),
    );
    return result;
  } finally {
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {
      // Temporary extraction cleanup is best-effort.
    }
  }
}

Future<({int compressedBytesRead, int tarBytesWritten})>
    _decompressZstdFileToTar({
  required ZstandardNativeBindings bindings,
  required File source,
  required File target,
  required int? totalCompressedBytes,
  required void Function(ZstandardNativeTarExtractionProgress progress)?
      onProgress,
}) async {
  final dstream = bindings.ZSTD_createDStream();
  if (dstream == ffi.nullptr) {
    throw const FormatException('Failed to create zstd decompression stream');
  }

  final inputSize = bindings.ZSTD_DStreamInSize();
  final outputSize = bindings.ZSTD_DStreamOutSize();
  final inputPointer = malloc<ffi.Uint8>(inputSize);
  final outputPointer = malloc<ffi.Uint8>(outputSize);
  final input = malloc<ZSTD_inBuffer>();
  final output = malloc<ZSTD_outBuffer>();

  RandomAccessFile? reader;
  RandomAccessFile? writer;
  var compressedBytesRead = 0;
  var tarBytesWritten = 0;
  var lastResult = bindings.ZSTD_initDStream(dstream);
  _checkZstdResult(bindings, lastResult);

  try {
    reader = await source.open();
    writer = await target.open(mode: FileMode.write);
    while (true) {
      final chunk = await reader.read(inputSize);
      if (chunk.isEmpty) {
        break;
      }
      compressedBytesRead += chunk.length;
      inputPointer.asTypedList(chunk.length).setAll(0, chunk);
      input.ref
        ..src = inputPointer.cast()
        ..size = chunk.length
        ..pos = 0;

      while (input.ref.pos < input.ref.size) {
        output.ref
          ..dst = outputPointer.cast()
          ..size = outputSize
          ..pos = 0;
        lastResult = bindings.ZSTD_decompressStream(dstream, output, input);
        _checkZstdResult(bindings, lastResult);
        if (output.ref.pos > 0) {
          final bytes = Uint8List.fromList(
            outputPointer.asTypedList(output.ref.pos),
          );
          await writer.writeFrom(bytes);
          tarBytesWritten += output.ref.pos;
        }
      }

      onProgress?.call(
        ZstandardNativeTarExtractionProgress(
          stage: ZstandardNativeTarExtractionStage.decompressing,
          progress: _weightedProgress(
            stageStart: 0,
            stageEnd: 0.5,
            stageProgress:
                _ratio(compressedBytesRead, totalCompressedBytes ?? 0),
          ),
          compressedBytesRead: compressedBytesRead,
          totalCompressedBytes: totalCompressedBytes,
          tarBytesWritten: tarBytesWritten,
          entriesExtracted: 0,
        ),
      );
      await Future<void>.delayed(Duration.zero);
    }

    await writer.flush();
    if (lastResult != 0) {
      throw const FormatException('Incomplete zstd frame');
    }
    return (
      compressedBytesRead: compressedBytesRead,
      tarBytesWritten: tarBytesWritten,
    );
  } finally {
    await writer?.close();
    await reader?.close();
    bindings.ZSTD_freeDStream(dstream);
    malloc.free(inputPointer);
    malloc.free(outputPointer);
    malloc.free(input);
    malloc.free(output);
  }
}

Future<int> _extractTarFile({
  required File tarFile,
  required Directory outputDirectory,
  required bool overwrite,
  required int compressedBytesRead,
  required int tarBytesWritten,
  required void Function(ZstandardNativeTarExtractionProgress progress)?
      onProgress,
}) async {
  final rootPath = path.normalize(outputDirectory.absolute.path);
  final tarLength = tarBytesWritten;
  final reader = await tarFile.open();
  var entriesExtracted = 0;
  var tarBytesRead = 0;
  String? nextName;

  try {
    while (tarBytesRead < tarLength) {
      final header = await reader.read(512);
      if (header.isEmpty) {
        break;
      }
      if (header.length != 512) {
        throw const FormatException('Invalid tar header');
      }
      tarBytesRead += 512;
      if (_isZeroBlock(header)) {
        break;
      }

      final headerName = _parseTarName(header);
      final typeFlag =
          header[156] == 0 ? '0' : String.fromCharCode(header[156]);
      final size = _parseTarOctal(header, 124, 12);
      final entryName = nextName ?? headerName;
      nextName = null;

      if (headerName == '././@LongLink' || typeFlag == 'L') {
        nextName = _stripTrailingNull(
          await _readTarMetadata(reader, size, 'GNU long name'),
        );
        tarBytesRead += _tarStoredSize(size);
        continue;
      }

      if (typeFlag == 'x' || typeFlag == 'X') {
        final records = await _readTarMetadata(reader, size, 'PAX header');
        final pax = _parsePaxRecords(records);
        nextName = pax['path'];
        tarBytesRead += _tarStoredSize(size);
        continue;
      }

      if (typeFlag == 'g' || typeFlag == 'G') {
        await _skipTarEntryContent(reader, size);
        tarBytesRead += _tarStoredSize(size);
        continue;
      }

      if (typeFlag == '1' || typeFlag == '2') {
        throw FormatException('Refusing to extract link entry: $entryName');
      }

      if (typeFlag == '5') {
        await _prepareDirectory(entryName, rootPath);
        if (size > 0) {
          await _skipTarEntryContent(reader, size);
          tarBytesRead += _tarStoredSize(size);
        }
        entriesExtracted += 1;
      } else if (typeFlag == '0') {
        tarBytesRead = await _extractTarFileEntry(
          reader: reader,
          entryName: entryName,
          size: size,
          rootPath: rootPath,
          overwrite: overwrite,
          tarBytesRead: tarBytesRead,
          tarLength: tarLength,
          compressedBytesRead: compressedBytesRead,
          tarBytesWritten: tarBytesWritten,
          entriesExtracted: entriesExtracted,
          onProgress: onProgress,
        );
        entriesExtracted += 1;
      } else {
        throw FormatException(
            'Unsupported tar entry type "$typeFlag": $entryName');
      }

      onProgress?.call(
        ZstandardNativeTarExtractionProgress(
          stage: ZstandardNativeTarExtractionStage.extracting,
          progress: _weightedProgress(
            stageStart: 0.5,
            stageEnd: 1,
            stageProgress: _ratio(tarBytesRead, tarLength),
          ),
          compressedBytesRead: compressedBytesRead,
          totalCompressedBytes: compressedBytesRead,
          tarBytesWritten: tarBytesWritten,
          entriesExtracted: entriesExtracted,
          currentEntry: entryName,
        ),
      );
      await Future<void>.delayed(Duration.zero);
    }
    return entriesExtracted;
  } finally {
    await reader.close();
  }
}

Future<int> _extractTarFileEntry({
  required RandomAccessFile reader,
  required String entryName,
  required int size,
  required String rootPath,
  required bool overwrite,
  required int tarBytesRead,
  required int tarLength,
  required int compressedBytesRead,
  required int tarBytesWritten,
  required int entriesExtracted,
  required void Function(ZstandardNativeTarExtractionProgress progress)?
      onProgress,
}) async {
  final outputPath = await _prepareFile(
    entryName,
    rootPath,
    overwrite: overwrite,
  );
  final writer = await File(outputPath).open(mode: FileMode.write);
  var remaining = size;
  try {
    while (remaining > 0) {
      final chunkSize = math.min(1024 * 1024, remaining);
      final chunk = await reader.read(chunkSize);
      if (chunk.isEmpty) {
        throw FormatException('Unexpected end of tar entry: $entryName');
      }
      await writer.writeFrom(chunk);
      remaining -= chunk.length;
      tarBytesRead += chunk.length;
      onProgress?.call(
        ZstandardNativeTarExtractionProgress(
          stage: ZstandardNativeTarExtractionStage.extracting,
          progress: _weightedProgress(
            stageStart: 0.5,
            stageEnd: 1,
            stageProgress: _ratio(tarBytesRead, tarLength),
          ),
          compressedBytesRead: compressedBytesRead,
          totalCompressedBytes: compressedBytesRead,
          tarBytesWritten: tarBytesWritten,
          entriesExtracted: entriesExtracted,
          currentEntry: entryName,
        ),
      );
      await Future<void>.delayed(Duration.zero);
    }
  } finally {
    await writer.close();
  }
  final padding = _tarPadding(size);
  if (padding > 0) {
    await reader.setPosition(await reader.position() + padding);
    tarBytesRead += padding;
  }
  return tarBytesRead;
}

Future<void> _prepareDirectory(String entryName, String rootPath) async {
  final outputPath = _safeOutputPath(rootPath, entryName);
  final entityType = await FileSystemEntity.type(outputPath);
  if (entityType == FileSystemEntityType.file) {
    throw FileSystemException(
        'Directory path already exists as a file', outputPath);
  }
  await Directory(outputPath).create(recursive: true);
}

Future<String> _prepareFile(
  String entryName,
  String rootPath, {
  required bool overwrite,
}) async {
  final outputPath = _safeOutputPath(rootPath, entryName);
  final entityType = await FileSystemEntity.type(outputPath);
  if (entityType == FileSystemEntityType.directory) {
    throw FileSystemException(
        'File path already exists as a directory', outputPath);
  }
  if (entityType != FileSystemEntityType.notFound && !overwrite) {
    throw FileSystemException('File already exists', outputPath);
  }
  await Directory(path.dirname(outputPath)).create(recursive: true);
  if (entityType != FileSystemEntityType.notFound) {
    await File(outputPath).delete();
  }
  return outputPath;
}

Future<int?> _tryFileLength(File file) async {
  try {
    return await file.length();
  } on FileSystemException {
    return null;
  }
}

bool _isZeroBlock(Uint8List bytes) => bytes.every((byte) => byte == 0);

String _parseTarName(Uint8List header) {
  final name = _parseTarString(header, 0, 100);
  final prefix = _parseTarString(header, 345, 155);
  if (prefix.isEmpty) {
    return name;
  }
  return '$prefix/$name';
}

String _parseTarString(Uint8List bytes, int offset, int length) {
  final end = math.min(offset + length, bytes.length);
  var terminator = offset;
  while (terminator < end && bytes[terminator] != 0) {
    terminator += 1;
  }
  return utf8.decode(bytes.sublist(offset, terminator), allowMalformed: true);
}

int _parseTarOctal(Uint8List header, int offset, int length) {
  final raw = _parseTarString(header, offset, length).trim();
  if (raw.isEmpty) {
    return 0;
  }
  return int.parse(raw, radix: 8);
}

Future<String> _readTarMetadata(
  RandomAccessFile reader,
  int size,
  String label,
) async {
  const maxMetadataSize = 1024 * 1024;
  if (size > maxMetadataSize) {
    throw FormatException('$label is too large');
  }
  final bytes = await reader.read(size);
  if (bytes.length != size) {
    throw FormatException('Unexpected end of $label');
  }
  final padding = _tarPadding(size);
  if (padding > 0) {
    await reader.setPosition(await reader.position() + padding);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

Future<void> _skipTarEntryContent(RandomAccessFile reader, int size) async {
  await reader.setPosition(await reader.position() + _tarStoredSize(size));
}

Map<String, String> _parsePaxRecords(String records) {
  final values = <String, String>{};
  var offset = 0;
  while (offset < records.length) {
    final space = records.indexOf(' ', offset);
    if (space == -1) {
      break;
    }
    final length = int.tryParse(records.substring(offset, space));
    if (length == null || length <= 0 || offset + length > records.length) {
      break;
    }
    final record = records.substring(space + 1, offset + length).trimRight();
    final equals = record.indexOf('=');
    if (equals > 0) {
      values[record.substring(0, equals)] = record.substring(equals + 1);
    }
    offset += length;
  }
  return values;
}

String _stripTrailingNull(String value) {
  final index = value.indexOf('\u0000');
  return index == -1 ? value : value.substring(0, index);
}

int _tarStoredSize(int size) => size + _tarPadding(size);

int _tarPadding(int size) {
  final remainder = size % 512;
  return remainder == 0 ? 0 : 512 - remainder;
}

String _safeOutputPath(String rootPath, String entryName) {
  if (entryName.trim().isEmpty || path.isAbsolute(entryName)) {
    throw FormatException('Unsafe tar entry path: $entryName');
  }
  final outputPath = path.normalize(path.join(rootPath, entryName));
  if (outputPath != rootPath && !path.isWithin(rootPath, outputPath)) {
    throw FormatException('Unsafe tar entry path: $entryName');
  }
  return outputPath;
}

double _ratio(int value, int total) {
  if (total <= 0) {
    return 0;
  }
  return (value / total).clamp(0.0, 1.0);
}

double _weightedProgress({
  required double stageStart,
  required double stageEnd,
  required double stageProgress,
}) {
  return (stageStart + (stageEnd - stageStart) * stageProgress).clamp(0.0, 1.0);
}

void _checkZstdResult(ZstandardNativeBindings bindings, int result) {
  if (bindings.ZSTD_isError(result) == 0) {
    return;
  }
  final errorName =
      bindings.ZSTD_getErrorName(result).cast<Utf8>().toDartString();
  throw FormatException('Zstandard decompression failed: $errorName');
}
