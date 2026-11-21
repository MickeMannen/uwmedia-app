// The desktop's Color batch and Resize run with the runner's media engine
// writing the videos in ffmpeg's place (a Mac; docs/design/macos-remove-ffmpeg.md):
// what the engine is asked for, one video at a time, and what ffmpeg and
// exiftool still do. The engine here is the fake one of the phone runs'
// tests (it "encodes" by copying the source); the real one is tried by
// integration_test/media_engine_test.dart on a Mac.
// Needs ffmpeg, ffprobe and exiftool on the PATH; without them the tests
// skip themselves.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/color/color_profiles.dart';
import 'package:uwmedia_app/core/engine/share_sizes.dart';
import 'package:uwmedia_app/core/hud/dummy_telemetry.dart';
import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/engine/desktop/color_batch.dart';
import 'package:uwmedia_app/engine/desktop/convert_run.dart';
import 'package:uwmedia_app/engine/desktop/exiftool.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/telemetry_run.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';
import 'package:uwmedia_app/engine/mobile_engine.dart';
import 'package:uwmedia_app/engine/mobile_video_run.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

import '../../helpers/tools.dart';
import '../mobile_video_run_test.dart' show FakeEngine;

/// The fake engine, which refuses a second encode while one is going, as
/// the runner's does.
class OneAtATime extends FakeEngine {
  OneAtATime(super.clip);

  bool _busy = false;
  var most = 0;

  @override
  Future<EncodeResult> encode(
    EncodeJob job, {
    void Function(double percent)? onProgress,
    void Function()? onRestart,
  }) async {
    if (_busy) {
      throw const EngineException('Another video is being written');
    }
    _busy = true;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return await super.encode(
        job,
        onProgress: onProgress,
        onRestart: onRestart,
      );
    } finally {
      _busy = false;
    }
  }
}

class Heard implements ColorBatchListener {
  final messages = <String>[];
  final percents = <String, double>{};

  @override
  void started(int total) {}

  @override
  void active(String file) {}

  @override
  void finished(int done, int total, FileResult result) {}

  @override
  void progress(String file, double percent) => percents[file] = percent;

  @override
  void message(String line) => messages.add(line);
}

void main() {
  final skip = hasTool('ffmpeg') && hasTool('ffprobe') && hasTool('exiftool')
      ? null
      : 'needs ffmpeg, ffprobe and exiftool on the PATH';

  group('the engine in ffmpeg\'s place', () {
    late Directory tmp;
    late ({FfmpegTools ffmpeg, Exiftool exiftool}) tools;
    late String media;
    const stamp = '2026:03:14 11:30:00+02:00';
    const clipInfo = ClipInfo(
      width: 320,
      height: 240,
      durationSeconds: 1,
      frames: 25,
      fps: 25,
      bitrate: 400000,
    );

    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('uwmedia_native_');
      final found = await ToolFinder.forThisMachine().findAll(const {});
      tools = (
        ffmpeg: FfmpegTools(
          ffmpeg: found[toolFfmpeg]!,
          ffprobe: found[toolFfprobe],
          os: currentEngineOs(),
        ),
        exiftool: Exiftool(found[toolExiftool]!),
      );
      media = (Directory(p.join(tmp.path, 'media'))..createSync()).path;
      for (final name in ['A.MP4', 'B.MP4', 'C.MP4']) {
        final clip = p.join(media, name);
        final made = await Process.run(found[toolFfmpeg]!, [
          '-v', 'error', '-f', 'lavfi', //
          '-i', 'testsrc2=size=320x240:rate=25:duration=1',
          '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
          '-metadata', 'creation_time=2026-03-14T09:30:00Z', clip,
        ]);
        expect(made.exitCode, 0, reason: '${made.stderr}');
        await tools.exiftool.setTags(clip, {
          'QuickTime:CreationDate': stamp,
          'QuickTime:Model': 'TestCam',
        });
      }
    });

    tearDownAll(() {
      if (tmp.existsSync()) {
        tmp.deleteSync(recursive: true);
      }
    });

    ColorBatch batch(MobileMediaEngine? native) {
      final fonts = TtfFonts(
        (file) => File('assets/fonts/$file').readAsBytesSync(),
        inkTables: InkTables.parse(
          File('assets/fonts/ink_tables.bin').readAsBytesSync(),
        ),
      );
      return ColorBatch(
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
        native: native,
      );
    }

    test('Color: each video through the engine, one at a time, and the '
        'metadata by exiftool', () async {
      final engine = OneAtATime(clipInfo);
      final out = p.join(tmp.path, 'color');
      final profiles = mergedColorProfiles(
        File('assets/color.yaml').readAsStringSync(),
        null,
      );
      final heard = Heard();
      final results = await batch(engine).run(
        ColorBatchSettings(
          source: media,
          output: out,
          colorProfileName: 'default',
          colorProfile: ColorProfile.fromMap(
            profiles['default']!.cast<String, dynamic>(),
          ),
          hwAccel: false,
        ),
        heard,
      );
      expect(
        results.map((r) => r.status),
        everyElement(FileStatus.done),
        reason: '$results ${heard.messages}',
      );
      // Three files side by side, and the engine never asked for two.
      expect(engine.jobs, hasLength(3));
      for (final job in engine.jobs) {
        expect(job.luts, isNotEmpty);
        expect(job.fit, isNull);
        expect(job.bitrate, 400000);
        expect(p.dirname(job.output), out);
      }
      expect(heard.percents.values, everyElement(100));
      // The source's tags, the camera's model among them, on the result.
      final tags = await tools.exiftool.tags(p.join(out, 'A.mp4'), [
        'QuickTime:CreationDate',
        'QuickTime:Model',
      ]);
      expect(tags['QuickTime:CreationDate'], stamp);
      expect(tags['QuickTime:Model'], 'TestCam');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Color: an output size goes to the engine; a video with nothing '
        'to change is the engine\'s copy, or ffmpeg\'s', () async {
      final engine = OneAtATime(clipInfo);
      final sized = p.join(tmp.path, 'sized');
      var results = await batch(engine).run(
        ColorBatchSettings(
          source: p.join(media, 'A.MP4'),
          output: sized,
          outputSize: OutputSize.share(
            const ShareCopy(shareWhatsApp, ShareShape.asShot),
          ),
          hwAccel: false,
        ),
        Heard(),
      );
      expect(results.single.status, FileStatus.done);
      final job = engine.jobs.single;
      expect(job.h264, isTrue);
      expect(job.luts, isEmpty);
      expect(job.fit, isNotNull);

      final plain = p.join(tmp.path, 'plain');
      results = await batch(engine).run(
        ColorBatchSettings(
          source: p.join(media, 'B.MP4'),
          output: plain,
          hwAccel: false,
        ),
        Heard(),
      );
      expect(results.single.status, FileStatus.done);
      // No encode: the engine's copy, and the tags by exiftool.
      expect(engine.jobs, hasLength(1));
      expect(engine.copies.single, (
        p.join(media, 'B.MP4'),
        p.join(plain, 'B.mp4'),
      ));
      expect(
        (await tools.exiftool.tags(p.join(plain, 'B.mp4'), [
          'QuickTime:CreationDate',
        ])).values,
        [stamp],
      );

      // An engine that cannot: ffmpeg's copy, and the run says so.
      engine.noCopy = true;
      final heard = Heard();
      results = await batch(engine).run(
        ColorBatchSettings(
          source: p.join(media, 'C.MP4'),
          output: plain,
          hwAccel: false,
        ),
        heard,
      );
      expect(results.single.status, FileStatus.done);
      expect(engine.copies, hasLength(1));
      expect(heard.messages.join(), contains('copied by FFmpeg'));
      expect(await tools.ffmpeg.dimensions(p.join(plain, 'C.mp4')), (320, 240));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Resize: a resolution and a copy for sharing through the engine, '
        'the metadata by exiftool', () async {
      final engine = OneAtATime(clipInfo);
      final out = p.join(tmp.path, 'resize');
      final result =
          await ConvertRun(
            ffmpeg: tools.ffmpeg,
            exiftool: tools.exiftool,
            native: MobileVideoRun(
              engine: engine,
              tempDir: (prefix) => tmp.createTempSync(prefix),
            ),
          ).convert(
            source: p.join(media, 'C.MP4'),
            outputDir: out,
            resolutions: ['360p'],
            shares: const [ShareCopy(shareWhatsApp, ShareShape.asShot)],
            hwAccel: true,
          );
      expect(result.failed, isEmpty, reason: result.messages.join('\n'));
      expect(engine.jobs, hasLength(2));
      expect(engine.jobs.first.fit, (640, 360));
      expect(engine.jobs.first.h264, isFalse);
      expect(engine.jobs.first.bitrate, isNotNull);
      expect(engine.jobs.last.h264, isTrue);
      final target = p.join(out, 'C 360p.mp4');
      expect(File(target).existsSync(), isTrue);
      expect(
        (await tools.exiftool.tags(target, ['QuickTime:CreationDate'])).values,
        [stamp],
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test(
      'Overlay Generator: the drawn pictures to the engine\'s frame '
      'writer, each for its frames; a PNG sequence needs no engine',
      () async {
        final engine = OneAtATime(clipInfo);
        final fonts = TtfFonts(
          (file) => File('assets/fonts/$file').readAsBytesSync(),
          inkTables: InkTables.parse(
            File('assets/fonts/ink_tables.bin').readAsBytesSync(),
          ),
        );
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
        final run = TelemetryRun(
          tools: tools.ffmpeg,
          renderer: HudRenderer(
            fonts,
            HudRules(
              jsonDecode(File('assets/hud_rules.json').readAsStringSync())
                  as Map<String, dynamic>,
            ),
          ),
          painter: HudPainter(fonts),
          native: engine,
        );
        const template = 'assets/overlays/templates/garmin/mk3i/main';
        final source = HudLayerSource(
          loadLayoutFile(
            '$template/single_tank/normal.json',
            (path) => File(path).readAsStringSync(),
          ),
          skinBytes: File('$template/normal.png').readAsBytesSync(),
        );
        final dive = buildDummyDive();
        final start = dive.startTime.add(const Duration(minutes: 12));
        final mov = p.join(tmp.path, 'overlay.mov');
        final percents = <double>[];
        final stats = await run.render(
          source: source,
          dive: dive,
          start: start,
          fps: 30,
          totalFrames: 750,
          format: overlayFormatProres,
          target: mov,
          onProgress: percents.add,
        );
        final opened = engine.framesOpened.single;
        expect(opened.output, mov);
        expect(opened.prores, isTrue);
        expect((opened.width, opened.height), (stats.width, stats.height));
        // One picture a dive sample, its frames counted.
        expect(engine.framesAdded.length, stats.pictures);
        expect(engine.framesAdded.reduce((a, b) => a + b), 750);
        expect(engine.framesClosed, 1);
        expect(engine.framesCancelled, 0);
        expect(percents.last, 100);

        await run.render(
          source: source,
          dive: dive,
          start: start,
          fps: 30,
          totalFrames: 30,
          format: overlayFormatHevc,
          target: p.join(tmp.path, 'overlay.mp4'),
        );
        expect(engine.framesOpened.last.prores, isFalse);

        final folder = p.join(tmp.path, 'overlay_png');
        await run.render(
          source: source,
          dive: dive,
          start: start,
          fps: 30,
          totalFrames: 3,
          format: overlayFormatPng,
          target: folder,
        );
        expect(engine.framesOpened, hasLength(2));
        expect(Directory(folder).listSync(), hasLength(3));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }, skip: skip);
}
