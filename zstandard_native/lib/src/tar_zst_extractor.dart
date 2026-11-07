import 'dart:async';
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
  /// The zstd decoder is starting.
  decompressing,

  /// Decompressed tar entries are being extracted to disk.
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

  /// Number of tar bytes produced by the zstd decoder.
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

  /// Number of tar bytes produced by the zstd decoder.
  final int tarBytesWritten;
}

/// Extracts a .tar.zst file without writing an intermediate tar. Stage the
/// entries on the destination filesystem so a late frame error cannot replace
/// existing files, and publishing each file requires only a rename.
/// [temporaryDirectoryPath] is retained for compatibility with existing callers.
Future<ZstandardNativeTarExtractionResult> extractTarZstArchive({
  required ZstandardNativeBindings bindings,
  required String archivePath,
  required String outputDirectoryPath,
  String? temporaryDirectoryPath,
  bool overwrite = false,
  void Function(ZstandardNativeTarExtractionProgress progress)? onProgress,
}) async {
  final source = File(archivePath);
  final progress = _Progress(
    onProgress == null ? null : await _tryFileLength(source),
    onProgress,
  );
  final destination = Directory(outputDirectoryPath);
  await destination.create(recursive: true);
  final staged = await destination.createTemp('.zstandard-');
  try {
    final reader = _TarInput(_decompress(bindings, source, progress));
    try {
      await _extractEntries(reader, staged.absolute.path, overwrite, progress);
      // Tar can end before the frame checksum, padding or subsequent frames.
      await reader.drain();
    } finally {
      await reader.close();
    }
    await _publish(staged, destination, staged.absolute.path, overwrite);
    progress.report(ZstandardNativeTarExtractionStage.completed);
    return ZstandardNativeTarExtractionResult(
      outputDirectoryPath: destination.path,
      entriesExtracted: progress.entries,
      compressedBytesRead: progress.compressedBytes,
      tarBytesWritten: progress.tarBytes,
    );
  } finally {
    await staged.delete(recursive: true);
  }
}

class _Progress {
  _Progress(this.total, this.callback);

  final int? total;
  final void Function(ZstandardNativeTarExtractionProgress)? callback;
  int compressedBytes = 0;
  int tarBytes = 0;
  int entries = 0;
  String? entry;

  void report(ZstandardNativeTarExtractionStage stage) {
    final complete = stage == ZstandardNativeTarExtractionStage.completed;
    callback?.call(ZstandardNativeTarExtractionProgress(
      stage: stage,
      progress: complete ? 1 : _ratio(compressedBytes, total ?? 0),
      compressedBytesRead: compressedBytes,
      totalCompressedBytes: complete ? compressedBytes : total,
      tarBytesWritten: tarBytes,
      entriesExtracted: entries,
      currentEntry:
          stage == ZstandardNativeTarExtractionStage.extracting ? entry : null,
    ));
  }
}

Stream<Uint8List> _decompress(
  ZstandardNativeBindings bindings,
  File source,
  _Progress progress,
) async* {
  final dstream = bindings.ZSTD_createDStream();
  if (dstream == ffi.nullptr) {
    throw const FormatException('Failed to create zstd decompression stream');
  }
  final inputSize = bindings.ZSTD_DStreamInSize();
  final outputSize = bindings.ZSTD_DStreamOutSize();
  final inBytes = malloc<ffi.Uint8>(inputSize);
  final outBytes = malloc<ffi.Uint8>(outputSize);
  final input = malloc<ZSTD_inBuffer>();
  final output = malloc<ZSTD_outBuffer>();
  try {
    var remaining = bindings.ZSTD_initDStream(dstream);
    _checkZstdResult(bindings, remaining);
    progress.report(ZstandardNativeTarExtractionStage.decompressing);
    final reader = await source.open();
    try {
      while (true) {
        final chunk = await reader.read(inputSize);
        if (chunk.isEmpty) break;
        inBytes.asTypedList(chunk.length).setAll(0, chunk);
        input.ref
          ..src = inBytes.cast()
          ..size = chunk.length
          ..pos = 0;
        do {
          output.ref
            ..dst = outBytes.cast()
            ..size = outputSize
            ..pos = 0;
          final before = input.ref.pos;
          remaining = bindings.ZSTD_decompressStream(dstream, output, input);
          _checkZstdResult(bindings, remaining);
          progress.compressedBytes += input.ref.pos - before;
          progress.tarBytes += output.ref.pos;
          if (output.ref.pos > 0) {
            yield Uint8List.fromList(outBytes.asTypedList(output.ref.pos));
          }
        } while (input.ref.pos < chunk.length ||
            (remaining != 0 && output.ref.pos == outputSize));
        progress.report(ZstandardNativeTarExtractionStage.extracting);
      }
      if (remaining != 0) throw const FormatException('Incomplete zstd frame');
    } finally {
      await reader.close();
    }
  } finally {
    bindings.ZSTD_freeDStream(dstream);
    malloc.free(input);
    malloc.free(output);
    malloc.free(inBytes);
    malloc.free(outBytes);
  }
}

/// Reads headers and metadata across chunk boundaries. File payloads are
/// written a slice at a time, with at most one write in flight.
class _TarInput {
  _TarInput(Stream<Uint8List> chunks) : _chunks = StreamIterator(chunks);
  final StreamIterator<Uint8List> _chunks;
  Uint8List _chunk = Uint8List(0);
  int _offset = 0;
  bool _ended = false;

  Future<bool> hasBytes() async {
    if (_offset < _chunk.length) return true;
    if (_ended) return false;
    if (!await _chunks.moveNext()) {
      _ended = true;
      return false;
    }
    _chunk = _chunks.current;
    _offset = 0;
    return true;
  }

  Future<Uint8List> read(int size) async {
    final result = Uint8List(size);
    var offset = 0;
    await consume(size, (chunk, start, end) {
      result.setRange(offset, offset + end - start, chunk, start);
      offset += end - start;
    });
    return result;
  }

  Future<void> consume(int size,
      [FutureOr<void> Function(Uint8List, int, int)? write]) async {
    while (size > 0) {
      if (!await hasBytes()) {
        throw const FormatException('Unexpected end of tar');
      }
      final count = math.min(size, _chunk.length - _offset);
      if (write != null) await write(_chunk, _offset, _offset + count);
      _offset += count;
      size -= count;
    }
  }

  Future<void> drain() async {
    while (await hasBytes()) {
      _offset = _chunk.length;
    }
  }

  Future<void> close() => _chunks.cancel();
}

Future<void> _extractEntries(
    _TarInput reader, String root, bool overwrite, _Progress progress) async {
  String? nextName;
  while (await reader.hasBytes()) {
    final header = await reader.read(512);
    if (_isZeroBlock(header)) return;
    final headerName = _parseTarName(header);
    final type = header[156] == 0 ? '0' : String.fromCharCode(header[156]);
    final size = _parseTarOctal(header, 124, 12);
    if (size < 0) throw const FormatException('Negative tar entry size');
    final name = nextName ?? headerName;
    nextName = null;
    if (type == 'L' ||
        headerName == '././@LongLink' ||
        type == 'x' ||
        type == 'X') {
      if (size > 1024 * 1024) {
        throw const FormatException('Tar metadata is too large');
      }
      final bytes = await reader.read(size);
      nextName = type == 'L' || headerName == '././@LongLink'
          ? _stripTrailingNull(utf8.decode(bytes, allowMalformed: true))
          : _parsePaxPath(bytes);
    } else if (type == 'g' || type == 'G') {
      await reader.consume(size);
    } else {
      progress.entry = name;
      switch (type) {
        case '5':
          await _prepareDirectory(name, root);
          await reader.consume(size);
        case '0':
          final output = await _prepareFile(name, root, overwrite: overwrite);
          final writer = await File(output).open(mode: FileMode.write);
          try {
            await reader.consume(size, (bytes, start, end) async {
              await writer.writeFrom(bytes, start, end);
            });
          } finally {
            await writer.close();
          }
        case '1':
        case '2':
          throw FormatException('Refusing to extract link entry: $name');
        default:
          throw FormatException('Unsupported tar entry type "$type": $name');
      }
      progress.entries++;
      progress.report(ZstandardNativeTarExtractionStage.extracting);
    }
    await reader.consume(_tarPadding(size));
  }
}

// Only traverse the private staging tree. Refuse to follow destination links
// when merging into an existing directory.
Future<void> _publish(Directory staged, Directory target, String stageRoot,
    bool overwrite) async {
  await for (final entry in staged.list(followLinks: false)) {
    final dest = path.join(target.absolute.path, path.basename(entry.path));
    if (path.equals(dest, stageRoot)) {
      throw FormatException('Reserved output path: $dest');
    }
    if (entry is Directory) {
      final type = await FileSystemEntity.type(dest, followLinks: false);
      if (type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.notFound) {
        throw FileSystemException('Expected a directory', dest);
      }
      final dir = Directory(dest);
      await dir.create();
      await _publish(entry, dir, stageRoot, overwrite);
    } else if (entry is File) {
      final file = File(dest);
      if (!overwrite) await file.create(exclusive: true);
      try {
        await entry.rename(dest);
      } catch (_) {
        if (!overwrite) await file.delete();
        rethrow;
      }
    }
  }
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

// PAX record lengths are byte counts, even when the path is multibyte UTF-8.
String? _parsePaxPath(Uint8List bytes) {
  String? name;
  var offset = 0;
  while (offset < bytes.length) {
    final space = bytes.indexOf(32, offset);
    if (space < 0) break;
    final length = int.tryParse(String.fromCharCodes(bytes, offset, space));
    if (length == null ||
        length <= space - offset + 1 ||
        offset + length > bytes.length) {
      break;
    }
    final record = utf8.decode(
        Uint8List.sublistView(bytes, space + 1, offset + length),
        allowMalformed: true);
    if (record.startsWith('path=')) {
      name = record.substring(5).replaceFirst(RegExp(r'\n$'), '');
    }
    offset += length;
  }
  return name;
}

String _stripTrailingNull(String value) {
  final index = value.indexOf('\u0000');
  return index == -1 ? value : value.substring(0, index);
}

int _tarPadding(int size) {
  final remainder = size % 512;
  return remainder == 0 ? 0 : 512 - remainder;
}

String _safeOutputPath(String rootPath, String entryName) {
  if (entryName.trim().isEmpty || path.isAbsolute(entryName)) {
    throw FormatException('Unsafe tar entry path: $entryName');
  }
  final outputPath = path.normalize(path.join(rootPath, entryName));
  if (!path.equals(outputPath, rootPath) &&
      !path.isWithin(rootPath, outputPath)) {
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

void _checkZstdResult(ZstandardNativeBindings bindings, int result) {
  if (bindings.ZSTD_isError(result) == 0) {
    return;
  }
  final errorName =
      bindings.ZSTD_getErrorName(result).cast<Utf8>().toDartString();
  throw FormatException('Zstandard decompression failed: $errorName');
}
