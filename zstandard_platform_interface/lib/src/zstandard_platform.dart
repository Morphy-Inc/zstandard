import 'dart:typed_data';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'zstandard_platform_interface_method_channel.dart';

/// Progress phase for [ZstandardPlatform.extractTarZst].
enum ZstandardTarExtractionStage {
  /// The zstd stream is being decompressed into an intermediate tar stream.
  decompressing,

  /// Tar entries are being extracted to disk.
  extracting,

  /// Extraction has completed.
  completed,
}

/// Progress event emitted by [ZstandardPlatform.extractTarZst].
class ZstandardTarExtractionProgress {
  /// Creates a progress event.
  const ZstandardTarExtractionProgress({
    required this.stage,
    required this.progress,
    required this.compressedBytesRead,
    required this.tarBytesWritten,
    required this.entriesExtracted,
    this.totalCompressedBytes,
    this.currentEntry,
  });

  /// Current extraction phase.
  final ZstandardTarExtractionStage stage;

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

/// Result returned by [ZstandardPlatform.extractTarZst].
class ZstandardTarExtractionResult {
  /// Creates an extraction result.
  const ZstandardTarExtractionResult({
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

/// Abstract platform interface for Zstandard compression and decompression.
///
/// All platform implementations (Android, iOS, macOS, Linux, Windows, web)
/// must extend this class and implement [getPlatformVersion], [compress],
/// and [decompress]. They register themselves by setting [instance].
///
/// Application code should use the main [zstandard] package, not this interface.
abstract class ZstandardPlatform extends PlatformInterface {
  /// Constructs a [ZstandardPlatform].
  ZstandardPlatform() : super(token: _token);

  static final Object _token = Object();

  static ZstandardPlatform _instance = MethodChannelZstandardPlatform();

  /// The default instance of [ZstandardPlatform] to use.
  ///
  /// Defaults to [MethodChannelZstandardPlatform]. Platform packages set this
  /// in their registerWith() (or equivalent) so the main plugin uses the
  /// native implementation.
  static ZstandardPlatform get instance => _instance;

  /// Sets the platform implementation.
  ///
  /// Only instances created with the correct token (from this package) can
  /// be set. Platform-specific implementations call this when they register.
  static set instance(ZstandardPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Returns a platform-specific version or identifier string.
  ///
  /// Default implementation throws [UnimplementedError].
  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  /// Compresses [data] at the given [compressionLevel] (1–22).
  ///
  /// Default implementation throws [UnimplementedError].
  Future<Uint8List?> compress(Uint8List data, int compressionLevel) {
    throw UnimplementedError('compress() has not been implemented.');
  }

  /// Decompresses Zstandard-compressed [data].
  ///
  /// Default implementation throws [UnimplementedError].
  Future<Uint8List?> decompress(Uint8List data) {
    throw UnimplementedError('decompress() has not been implemented.');
  }

  /// Extracts a `.tar.zst` archive to [outputDirectoryPath].
  ///
  /// Only platform implementations that override this method support it.
  Future<ZstandardTarExtractionResult> extractTarZst({
    required String archivePath,
    required String outputDirectoryPath,
    String? temporaryDirectoryPath,
    bool overwrite = false,
    void Function(ZstandardTarExtractionProgress progress)? onProgress,
  }) {
    throw UnsupportedError(
        'extractTarZst() is not supported on this platform.');
  }
}
