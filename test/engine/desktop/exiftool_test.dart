// exiftool as a process (lib/engine/desktop/exiftool.dart) on a test
// pattern and a still made at run time in a temporary folder. Needs
// exiftool and ffmpeg on the PATH; without them the tests skip
// themselves.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/engine/desktop/exiftool.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';

import '../../helpers/tools.dart';

void main() {
  final skip = hasTool('exiftool') && hasTool('ffmpeg')
      ? null
      : 'needs exiftool and ffmpeg on the PATH';

  test('an exiftool that is not there', () async {
    final missing = Exiftool('/nowhere/exiftool');
    expect(await missing.metadata('a.mp4'), isNull);
    expect(await missing.tags('a.mp4', ['Make']), {'Make': ''});
    await expectLater(
      missing.setTags('a.mp4', {'Make': 'x'}),
      throwsA(
        isA<EngineException>().having(
          (e) => e.message,
          'message',
          exiftoolMissingMessage,
        ),
      ),
    );
    await missing.setTags('a.mp4', const {});
  });

  group('with exiftool', () {
    late Directory tmp;
    late Exiftool exiftool;
    late String clip;
    late String still;

    setUpAll(() async {
      // A folder and file names outside ASCII, with a space.
      tmp = Directory.systemTemp.createTempSync('uwmedia_exif_ö ');
      final found = await ToolFinder.forThisMachine().findAll(const {});
      exiftool = Exiftool(found[toolExiftool]!);
      clip = p.join(tmp.path, 'källa 1.mp4');
      still = p.join(tmp.path, 'bild.jpg');
      for (final args in [
        [
          '-f', 'lavfi', '-i', 'testsrc2=s=160x90:r=25:d=1', //
          '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
          '-metadata', 'creation_time=2025-10-19T02:21:31Z', clip,
        ],
        ['-f', 'lavfi', '-i', 'testsrc2=s=160x90', '-frames:v', '1', still],
      ]) {
        final made = await runCapture(found[toolFfmpeg]!, [
          '-y',
          '-loglevel',
          'error',
          ...args,
        ]);
        expect(made?.exitCode, 0, reason: made?.stderr);
      }
    });
    tearDownAll(() => tmp.deleteSync(recursive: true));

    test('reading a file', () async {
      final meta = (await exiftool.metadata(clip))!;
      // On Windows exiftool says the path with forward slashes.
      expect(p.equals(meta['SourceFile'] as String, clip), isTrue);
      expect(meta['QuickTime:CreateDate'], '2025:10:19 02:21:31');
      expect(meta['QuickTime:ImageWidth'], 160);
      expect(standardizedCreationDate(meta), naive(2025, 10, 19, 2, 21, 31));
      expect(
        await exiftool.tags(clip, [
          'QuickTime:CreateDate',
          'CreateDate',
          'Nope',
        ]),
        {
          'QuickTime:CreateDate': '2025:10:19 02:21:31',
          'CreateDate': '2025:10:19 02:21:31',
          'Nope': '',
        },
      );
      expect(await exiftool.metadata(p.join(tmp.path, 'missing.mp4')), isNull);
      expect(await exiftool.tags(p.join(tmp.path, 'missing.mp4'), ['Make']), {
        'Make': '',
      });
    });

    test('writing tags', () async {
      final copy = p.join(tmp.path, 'skriv.mp4');
      File(clip).copySync(copy);
      await exiftool.setTags(copy, {
        'QuickTime:CreationDate': '2025:10:19 10:21:31+08:00',
        'QuickTime:Make': 'Kamera Ö',
      });
      final meta = (await exiftool.metadata(copy))!;
      expect(meta['QuickTime:CreationDate'], '2025:10:19 10:21:31+08:00');
      expect(meta['QuickTime:Make'], 'Kamera Ö');
      expect(timezoneOffsetMinutes(meta), 480);
      expect(localCreationDate(meta), naive(2025, 10, 19, 10, 21, 31));
      // No backup beside the file.
      expect(File('${copy}_original').existsSync(), isFalse);

      await expectLater(
        exiftool.setTags(p.join(tmp.path, 'missing.mp4'), {'Make': 'x'}),
        throwsA(isA<EngineException>()),
      );
      await expectLater(
        exiftool.setTags(copy, {'Make': 'two\nlines'}),
        throwsA(isA<EngineException>()),
      );
    });

    test('carrying a source\'s metadata over to its output', () async {
      final source = p.join(tmp.path, 'original.mp4');
      File(clip).copySync(source);
      await exiftool.setTags(source, {
        'QuickTime:CreationDate': '2025:10:19 10:21:31+08:00',
        'QuickTime:Make': 'Sony',
        'QuickTime:Model': 'ILCE-6700',
      });
      // An output as ffmpeg leaves it: the pictures, none of the tags.
      final dest = p.join(tmp.path, 'utdata.mp4');
      File(clip).copySync(dest);
      await exiftool.setTags(dest, {
        'QuickTime:CreateDate': '2001:01:01 00:00:00',
      });

      final messages = await exiftool.copyAll(
        source,
        dest,
        customTags: ['QuickTime:Software=UWMedia'],
      );
      final meta = (await exiftool.metadata(dest))!;
      expect(meta['QuickTime:CreateDate'], '2025:10:19 02:21:31');
      expect(meta['QuickTime:CreationDate'], '2025:10:19 10:21:31+08:00');
      expect(meta['QuickTime:Make'], 'Sony');
      expect(meta['QuickTime:Model'], 'ILCE-6700');
      expect(meta['QuickTime:Software'], 'UWMedia');
      // exiftool has no QuickTime:Timezone to write (spec §10.23a) and
      // says so; the rest is written.
      expect(messages.join('\n'), contains('TimeZone'));

      // Another timezone than the source's own.
      await exiftool.copyAll(source, dest, forcedTzMinutes: -210);
      expect(
        (await exiftool.metadata(dest))!['QuickTime:CreationDate'],
        '2025:10:19 10:21:31-03:30',
      );
    });

    test('a photo keeps its tags', () async {
      final source = p.join(tmp.path, 'foto.jpg');
      File(still).copySync(source);
      await exiftool.setTags(source, {
        'EXIF:DateTimeOriginal': '2026:05:21 06:58:22',
        'EXIF:OffsetTimeOriginal': '+08:00',
        'EXIF:Make': 'SONY',
      });
      final dest = p.join(tmp.path, 'foto ut.jpg');
      File(still).copySync(dest);
      await exiftool.copyAll(source, dest);
      final meta = (await exiftool.metadata(dest))!;
      expect(meta['EXIF:DateTimeOriginal'], '2026:05:21 06:58:22');
      expect(meta['EXIF:Make'], 'SONY');
      expect(localCreationDate(meta), naive(2026, 5, 21, 6, 58, 22));
    });
  }, skip: skip);
}
