// The Convertion run (lib/engine/desktop/convert_run.dart) end to end with
// a real ffmpeg and exiftool, on a clip made at run time in a temporary
// folder: the files and their names, their size, the date carried over,
// the steps reported, a second run beside the first, and Stop.
// Needs ffmpeg, ffprobe and exiftool on the PATH; without them the tests
// skip themselves.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/engine/share_sizes.dart';
import 'package:uwmedia_app/engine/desktop/convert_run.dart';
import 'package:uwmedia_app/engine/desktop/exiftool.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';

import '../../helpers/tools.dart';

void main() {
  final skip = hasTool('ffmpeg') && hasTool('ffprobe') && hasTool('exiftool')
      ? null
      : 'needs ffmpeg, ffprobe and exiftool on the PATH';

  group('with ffmpeg and exiftool', () {
    late Directory tmp;
    late FfmpegTools ffmpeg;
    late Exiftool exiftool;
    late ConvertRun run;
    late String clip;
    late Map<String, String> found;

    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('uwmedia_convert_');
      found = await ToolFinder.forThisMachine().findAll(const {});
      ffmpeg = FfmpegTools(
        ffmpeg: found[toolFfmpeg]!,
        ffprobe: found[toolFfprobe],
        os: currentEngineOs(),
      );
      exiftool = Exiftool(found[toolExiftool]!);
      run = ConvertRun(ffmpeg: ffmpeg, exiftool: exiftool);
      clip = p.join(tmp.path, 'Reef 720p.MP4');
      final made = await Process.run(found[toolFfmpeg]!, [
        '-v', 'error', '-f', 'lavfi', //
        '-i', 'testsrc2=size=1280x720:rate=25:duration=2',
        '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
        '-metadata', 'creation_time=2026-03-14T09:30:00Z', clip,
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');
      // A camera writes the local time with its offset beside the UTC one.
      await exiftool.setTags(clip, {
        'QuickTime:CreationDate': '2026:03:14 11:30:00+02:00',
      });
    });

    tearDownAll(() {
      if (tmp.existsSync()) {
        tmp.deleteSync(recursive: true);
      }
    });

    test('two resolutions, then the same again beside them', () async {
      final out = p.join(tmp.path, 'out');
      final steps = <ConvertStep>[];
      final percents = <double>[];
      final result = await run.convert(
        source: clip,
        outputDir: out,
        resolutions: ['480p', '360p'],
        hwAccel: false,
        onStep: steps.add,
        onProgress: percents.add,
      );
      expect(result.failed, isEmpty, reason: result.messages.join('\n'));
      expect(steps, [
        (done: 0, total: 2, target: null),
        (done: 0, total: 2, target: 'Reef 480p.mp4'),
        (done: 1, total: 2, target: 'Reef 480p.mp4'),
        (done: 1, total: 2, target: 'Reef 360p.mp4'),
        (done: 2, total: 2, target: null),
      ]);
      expect(percents, isNotEmpty);
      expect(percents.last, 100);
      expect(await ffmpeg.dimensions(p.join(out, 'Reef 480p.mp4')), (854, 480));
      expect(await ffmpeg.dimensions(p.join(out, 'Reef 360p.mp4')), (640, 360));
      // The output is stamped with the source's local time and offset.
      final tags = await exiftool.tags(p.join(out, 'Reef 480p.mp4'), [
        'QuickTime:CreationDate',
        'QuickTime:CreateDate',
      ]);
      expect(tags['QuickTime:CreationDate'], '2026:03:14 11:30:00+02:00');
      expect(tags['QuickTime:CreateDate'], '2026:03:14 09:30:00');

      final again = await run.convert(
        source: clip,
        outputDir: out,
        resolutions: ['360p'],
        hwAccel: false,
      );
      expect(again.failed, isEmpty);
      expect(File(p.join(out, 'Reef 360p_1.mp4')).existsSync(), isTrue);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('copies for sharing: H.264, cropped to portrait, with bars', () async {
      final out = p.join(tmp.path, 'share');
      final steps = <ConvertStep>[];
      final result = await run.convert(
        source: clip,
        outputDir: out,
        resolutions: const [],
        shares: const [
          ShareCopy(shareWhatsApp, ShareShape.asShot),
          ShareCopy(shareInstagram, ShareShape.portraitCropped, cropAt: 0),
          ShareCopy(shareWhatsApp, ShareShape.portraitBars),
        ],
        hwAccel: false,
        onStep: steps.add,
      );
      expect(result.failed, isEmpty, reason: result.messages.join('\n'));
      expect(steps.last, (done: 3, total: 3, target: null));
      final asShot = p.join(out, 'Reef WhatsApp.mp4');
      final cropped = p.join(out, 'Reef Instagram portrait.mp4');
      final bars = p.join(out, 'Reef WhatsApp portrait.mp4');
      expect(await ffmpeg.dimensions(asShot), (1280, 720));
      // 720 * 9 / 16 = 405, even 404: the source has no more to give.
      expect(await ffmpeg.dimensions(cropped), (404, 720));
      expect(await ffmpeg.dimensions(bars), (720, 1280));
      for (final file in [asShot, cropped, bars]) {
        final codec = await Process.run(found[toolFfprobe]!, [
          '-v', 'error', '-select_streams', 'v:0', //
          '-show_entries', 'stream=codec_name', '-of', 'csv=p=0', file,
        ]);
        expect('${codec.stdout}'.trim(), 'h264', reason: file);
      }
      final tags = await exiftool.tags(cropped, ['QuickTime:CreationDate']);
      expect(tags['QuickTime:CreationDate'], '2026:03:14 11:30:00+02:00');

      // The crop took the left end of the picture: its top-left pixel is
      // the source's, and the bars' copy is black at the top.
      final source = await ffmpeg.frameAt(clip, 0, width: 1280, height: 720);
      final left = await ffmpeg.frameAt(cropped, 0, width: 404, height: 720);
      final barred = await ffmpeg.frameAt(bars, 0, width: 720, height: 1280);
      int at(RgbImage image, int x, int y, int c) =>
          image.rgb[(y * image.width + x) * 3 + c];
      for (var c = 0; c < 3; c++) {
        expect(
          at(left!, 200, 360, c),
          closeTo(at(source!, 200, 360, c), 40),
          reason: 'channel $c',
        );
        expect(at(barred!, 360, 100, c), lessThan(30));
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a phone\'s upright video (stored lying down, turned)', () async {
      final upright = p.join(tmp.path, 'Upright.mp4');
      final made = await Process.run(found[toolFfmpeg]!, [
        '-v', 'error', '-display_rotation', '90', '-i', clip, //
        '-c', 'copy', upright,
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');
      expect(await ffmpeg.dimensions(upright), (1280, 720));
      expect(await ffmpeg.displayDimensions(upright), (720, 1280));
      expect(await ffmpeg.displayDimensions(clip), (1280, 720));

      final out = p.join(tmp.path, 'upright');
      final result = await run.convert(
        source: upright,
        outputDir: out,
        resolutions: const [],
        shares: const [
          ShareCopy(shareWhatsApp, ShareShape.asShot),
          ShareCopy(shareInstagram, ShareShape.portraitCropped),
        ],
        hwAccel: false,
      );
      expect(result.failed, isEmpty, reason: result.messages.join('\n'));
      // Portrait already: no bars, no crop, and not turned a second time.
      for (final name in [
        'Upright WhatsApp.mp4',
        'Upright Instagram portrait.mp4',
      ]) {
        expect(await ffmpeg.displayDimensions(p.join(out, name)), (
          720,
          1280,
        ), reason: name);
        expect(await ffmpeg.dimensions(p.join(out, name)), (720, 1280));
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Stop ends the encode and the run', () async {
      final control = RunControl();
      final steps = <ConvertStep>[];
      final going = run.convert(
        source: clip,
        outputDir: p.join(tmp.path, 'stopped'),
        resolutions: ['480p', '360p'],
        hwAccel: false,
        control: control,
        onStep: (step) {
          steps.add(step);
          if (step.target != null) {
            control.stop();
          }
        },
      );
      await expectLater(going, throwsA(isA<RunStopped>()));
      // The second resolution was never started.
      expect(steps.where((s) => s.target == 'Reef 360p.mp4'), isEmpty);

      // Stopped while ffmpeg writes: the half-written file does not stay.
      final midway = RunControl();
      final out = p.join(tmp.path, 'midway');
      await expectLater(
        run.convert(
          source: clip,
          outputDir: out,
          resolutions: ['480p'],
          hwAccel: false,
          control: midway,
          onProgress: (_) => midway.stop(),
        ),
        throwsA(isA<RunStopped>()),
      );
      expect(Directory(out).listSync(), isEmpty);
    });

    test('a file that is no video, a video that cannot be read', () async {
      expect(
        () => run.convert(
          source: p.join(tmp.path, 'photo.jpg'),
          outputDir: tmp.path,
          resolutions: ['480p'],
          hwAccel: false,
        ),
        throwsFormatException,
      );
      final broken = File(p.join(tmp.path, 'broken.mp4'))
        ..writeAsStringSync('not a video');
      final result = await run.convert(
        source: broken.path,
        outputDir: p.join(tmp.path, 'broken'),
        resolutions: ['480p'],
        hwAccel: false,
      );
      expect(result.failed, ['480p']);
      expect(result.messages.single, startsWith('Error converting to 480p'));
    });
  }, skip: skip);
}
