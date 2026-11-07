import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zstandard/zstandard.dart';

// Three checksummed zstd frames split inside the first tar header and between
// the two tar end markers. The archive contains a directory, a GNU long-name
// file (131073 "x" bytes), a UTF-8 PAX path ("ok"), and an empty file.
const _fixture =
    'KLUv/QRY9QAAqGNvbnRlbnQvADAwMDA2NDQwMDAAMAIAK4LBCRwBz2CRUii1L/0EWEwEAPLE'
    'EBeAJ+oAbMQnRohfzEKd1RLb/A3AnZBXyYevmMw55h8R03+ztAS0ZMe6IlKqRDLfQQpWINkq'
    'CimkdwSjFQxFV0RH3Q8YAHH4uFz4A2QKhBYi8YYZh5tErUhwXrwWQAqLQL0Flx5/gKAAOiAR'
    'M23nAmDpCsX5IgCGa8Ck6IDiAJfySw9gsQWwvQQAtAN4AFBheEhlYWRlcjIyNjEwMjE1ACB4'
    'ADAwMTUwIHBhdGg97ZWc6riACj8AMTQ3MzVvZW1wdHkwMDQyNhwA/TkV7gMSIgUSSAl0B06g'
    '2jV1gEwEaU6Fwm8Qp7sPkKmQBhDEVAcYxA7QwgCCeAMgOnDD+uu1CGnMHxd1d0oqDAbie+iA'
    'GgakHMhjgnQDCKIA+0A9xH/ABhHtyMgotS/9BFhNAAAQAAABAPsqwAJ8uMPo';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  group('mobile tar extraction', () {
    late Directory root;
    late File input;
    late Directory output;
    final longName = 'n' * 105;
    final paxName = '한글' * 22;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('zstandard-test-');
      input = File('${root.path}/input.tar.zst');
      output = Directory('${root.path}/output');
      await input.writeAsBytes(base64Decode(_fixture));
    });
    tearDown(() => root.delete(recursive: true));

    test(
      'streams split headers, metadata and payloads across zstd frames',
      () async {
        final events = <ZstandardTarExtractionProgress>[];
        final result = await Zstandard().extractTarZst(
          archivePath: input.path,
          outputDirectoryPath: output.path,
          onProgress: events.add,
        );
        expect(result.entriesExtracted, 4);
        expect(result.tarBytesWritten, 137216);
        expect(result.compressedBytesRead, await input.length());
        expect(events.first.stage, ZstandardTarExtractionStage.decompressing);
        expect(events.last.stage, ZstandardTarExtractionStage.completed);
        expect(events.last.progress, 1);
        for (var i = 1; i < events.length; i++) {
          expect(
            events[i].progress,
            greaterThanOrEqualTo(events[i - 1].progress),
          );
        }
        final content = Directory('${output.path}/content');
        expect(
          await File('${content.path}/$longName').readAsString(),
          'x' * 131073,
        );
        expect(await File('${content.path}/$paxName').readAsString(), 'ok');
        expect(await File('${content.path}/empty').length(), 0);
        expect(await output.list().length, 1);
      },
    );

    test(
      'a late zstd failure preserves existing files and permits retry',
      () async {
        final content = Directory('${output.path}/content');
        await content.create(recursive: true);
        final existing = File('${content.path}/$longName');
        await existing.writeAsString('original');
        final valid = base64Decode(_fixture);
        final corrupt = Uint8List.fromList(valid);
        corrupt[corrupt.length - 1] ^= 1;
        Future<ZstandardTarExtractionResult> extract(bool overwrite) =>
            Zstandard().extractTarZst(
              archivePath: input.path,
              outputDirectoryPath: output.path,
              overwrite: overwrite,
            );

        for (final damaged in [valid.sublist(0, valid.length - 1), corrupt]) {
          await input.writeAsBytes(damaged);
          await expectLater(extract(true), throwsFormatException);
          expect(await existing.readAsString(), 'original');
          expect(await content.list().length, 1);
          expect(await output.list().length, 1);
        }
        await input.writeAsBytes(valid);
        await expectLater(extract(false), throwsA(isA<FileSystemException>()));
        expect(await existing.readAsString(), 'original');
        await extract(true);
        expect(await existing.readAsString(), 'x' * 131073);
      },
    );
  }, skip: !Platform.isAndroid && !Platform.isIOS);
}
