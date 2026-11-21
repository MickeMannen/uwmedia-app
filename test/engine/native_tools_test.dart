// ffmpeg's and exiftool's places taken by the media engine and the app's
// own readers (lib/engine/native_tools.dart), for the build without them
// (spec §10.74): what they answer, what they write, and a Color batch and
// a Resize run with nothing else. No tool is started here.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/color/color_profiles.dart';
import 'package:uwmedia_app/core/engine/ffmpeg_commands.dart';
import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/engine/desktop/color_batch.dart';
import 'package:uwmedia_app/engine/desktop/convert_run.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/file_picks.dart';
import 'package:uwmedia_app/engine/media_file_dates.dart';
import 'package:uwmedia_app/engine/mobile_engine.dart';
import 'package:uwmedia_app/engine/mobile_video_run.dart';
import 'package:uwmedia_app/engine/native_tools.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

import '../helpers/sony_mp4.dart';
import 'desktop/native_video_test.dart' show Heard;
import 'mobile_video_run_test.dart' show FakeEngine;

const _photo = 'test/fixtures/media/photo/jpeg_3x2_2mp.jpg';

void main() {
  late Directory tmp;
  late String clip;
  // 2026-03-14 09:30:00 UTC in seconds from 1904, the clock two hours
  // east.
  final created =
      DateTime.utc(2026, 3, 14, 9, 30).millisecondsSinceEpoch ~/ 1000 +
      2082844800;
  const info = ClipInfo(
    width: 1280,
    height: 720,
    durationSeconds: 10,
    frames: 250,
    fps: 25,
    bitrate: 8000000,
  );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('uwmedia_native_tools_');
    clip = p.join(tmp.path, 'Reef.MP4');
    File(clip).writeAsBytesSync(sonyMp4(created: created, zoneMinutes: 120));
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('ffmpeg\'s answers from the engine', () async {
    final engine = FakeEngine(info);
    final tools = NativeFfmpegTools(engine, os: EngineOs.macos);
    expect(await tools.duration(clip), 10);
    expect(await tools.bitrate(clip), 8000000);
    expect(await tools.dimensions(clip), (1280, 720));
    expect(await tools.displayDimensions(clip), (1280, 720));
    expect(await tools.frameCount(clip), 250);
    expect(await tools.fps(clip), 25);
    expect(await tools.isHwDecodable(clip), isFalse);
    final frame = await tools.frameAt(clip, 4, width: 64, height: 36);
    expect((frame!.width, frame.height), (64, 36));
    expect(engine.asked, [4.0]);

    // A copy is the engine's, with the source's dates; a size its
    // conversion; what only ffmpeg could do is said.
    final copy = p.join(tmp.path, 'copy.mp4');
    await tools.processVideo(
      input: clip,
      output: copy,
      creationDate: naive(2026, 3, 14, 11, 30),
      hwAccel: true,
    );
    expect(engine.copies.single, (clip, copy));
    final small = p.join(tmp.path, 'small.mp4');
    await tools.processVideo(
      input: clip,
      output: small,
      creationDate: naive(2026, 3, 14, 11, 30),
      hwAccel: true,
      targetResolution: (640, 360),
      bitrate: '2M',
    );
    expect(engine.jobs.single.fit, (640, 360));
    expect(engine.jobs.single.bitrate, 2000000);
    expect(
      () => tools.run(const ['-version']),
      throwsA(
        isA<EngineException>().having(
          (e) => e.message,
          'message',
          noFfmpegMessage,
        ),
      ),
    );
  });

  test('exiftool\'s answers from the app\'s own readers and writers', () async {
    final exiftool = NativeExiftool();
    final meta = await exiftool.metadata(clip);
    expect(meta!['QuickTime:CreateDate'], '2026:03:14 09:30:00');
    expect(meta['QuickTime:TimeZone'], '+02:00');
    expect((await exiftool.metadata(_photo))!['EXIF:Model'], 'ILCE-6700');
    // A kind the readers do not read: no tags, and nothing thrown.
    final other = File(p.join(tmp.path, 'notes.txt'))..writeAsStringSync('x');
    expect(await exiftool.metadata(other.path), isNull);
    expect(await exiftool.tags(other.path, ['Orientation']), {
      'Orientation': '',
    });
    expect(
      (await exiftool.tags(clip, ['QuickTime:CreateDate'])).values.single,
      '2026:03:14 09:30:00',
    );

    // Dates are written where the file lies; other tags passed over.
    await exiftool.setTags(clip, {
      'QuickTime:CreateDate': '2026:03:15 10:00:00',
      'XMP:Title': 'not written',
    });
    expect(readFileDates(clip)['QuickTime:CreateDate'], '2026:03:15 10:00:00');
    expect(Directory(tmp.path).listSync(), hasLength(2));

    // A result gets its source's dates: a video's with the timezone, a
    // JPEG's EXIF ones.
    final out = p.join(tmp.path, 'out.mp4');
    File(out).writeAsBytesSync(sonyMp4(created: 1000, zoneMinutes: 0));
    expect(await exiftool.copyAll(clip, out), isEmpty);
    final copied = readFileDates(out);
    expect(copied['QuickTime:CreateDate'], '2026:03:15 10:00:00');
    expect(copied['QuickTime:CreationDate'], '2026:03:15 12:00:00+02:00');
  });

  test('a Color batch and a Resize run with neither tool', () async {
    for (final family in fontRegistry.values) {
      for (final file in family.values) {
        await (FontLoader(fontFamilyOf(file))..addFont(
              Future.value(
                ByteData.sublistView(
                  File('assets/fonts/$file').readAsBytesSync(),
                ),
              ),
            ))
            .load();
      }
    }
    final fonts = TtfFonts(
      (file) => File('assets/fonts/$file').readAsBytesSync(),
      inkTables: InkTables.parse(
        File('assets/fonts/ink_tables.bin').readAsBytesSync(),
      ),
    );
    final engine = FakeEngine(info);
    final tools = storeDesktopTools(engine, EngineOs.macos);
    final media = Directory(p.join(tmp.path, 'media'))..createSync();
    File(clip).renameSync(p.join(media.path, 'Reef.MP4'));
    File(_photo).copySync(p.join(media.path, 'Fish.jpg'));
    final out = p.join(tmp.path, 'out');
    final profiles = mergedColorProfiles(
      File('assets/color.yaml').readAsStringSync(),
      null,
    );
    final heard = Heard();
    final results =
        await ColorBatch(
          tools: tools,
          renderer: HudRenderer(
            fonts,
            HudRules(
              jsonDecode(File('assets/hud_rules.json').readAsStringSync())
                  as Map<String, dynamic>,
            ),
          ),
          painter: HudPainter(fonts),
          tempDir: (prefix) => tmp.createTempSync(prefix),
          native: engine,
        ).run(
          ColorBatchSettings(
            source: media.path,
            output: out,
            colorProfileName: 'default',
            colorProfile: ColorProfile.fromMap(
              profiles['default']!.cast<String, dynamic>(),
            ),
          ),
          heard,
        );
    expect(
      {for (final r in results) r.file: r.status},
      {'Fish.jpg': FileStatus.done, 'Reef.MP4': FileStatus.done},
      reason: '$results ${heard.messages}',
    );
    expect(engine.jobs.single.luts, isNotEmpty);
    // The video's dates, and the photo's, on the results.
    expect(
      readFileDates(p.join(out, 'Reef.mp4'))['QuickTime:CreationDate'],
      '2026:03:14 11:30:00+02:00',
    );
    expect(
      readFileDates(p.join(out, 'Fish.jpg'))['EXIF:DateTimeOriginal'],
      readFileDates(_photo)['EXIF:DateTimeOriginal'],
    );

    engine.jobs.clear();
    final resized =
        await ConvertRun(
          ffmpeg: tools.ffmpeg,
          exiftool: tools.exiftool,
          native: MobileVideoRun(
            engine: engine,
            tempDir: (prefix) => tmp.createTempSync(prefix),
          ),
        ).convert(
          source: p.join(media.path, 'Reef.MP4'),
          outputDir: p.join(tmp.path, 'sizes'),
          resolutions: ['360p'],
          hwAccel: true,
        );
    expect(resized.failed, isEmpty, reason: resized.messages.join('\n'));
    expect(engine.jobs.single.fit, (640, 360));
  });

  test('a sandboxed app\'s picks: remembered, opened again, forgotten when '
      'gone', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('uwmedia/file_access');
    final resolved = <String>[];
    var gone = '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = (call.arguments as Map).cast<String, Object?>();
          if (call.method == 'bookmark') {
            return Uint8List.fromList(utf8.encode(args['path']! as String));
          }
          final path = utf8.decode(args['bookmark']! as Uint8List);
          if (path == gone) {
            throw PlatformException(code: 'access', message: 'gone');
          }
          resolved.add(path);
          return {'path': path};
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final access = FileAccess(File(p.join(tmp.path, 'config', 'b.json')));
    expect(await access.restore(), 0);
    await access.remember('/Volumes/Card/DCIM');
    await access.remember('/Users/d/Out');
    await access.remember('/Volumes/Card/DCIM');
    expect(await FileAccess(access.file).restore(), 2);
    expect(resolved, ['/Users/d/Out', '/Volumes/Card/DCIM']);
    gone = '/Volumes/Card/DCIM';
    expect(await access.restore(), 1);
    expect(access.file.readAsStringSync(), isNot(contains('DCIM')));
  });
}
