// The desktop's Color batch and Resize run on a Mac with the runner's
// media engine writing the videos (docs/design/macos-remove-ffmpeg.md, step 1),
// beside the same runs by ffmpeg: both give a video of the clip's size
// and frame count with the same dates and camera, and how long each took
// is printed. Needs ffmpeg, ffprobe and exiftool on the Mac. Run:
//   flutter test integration_test/native_desktop_test.dart -d macos \
//     --dart-define=CLIP=/path/clip.mp4 [--dart-define=OUT=/folder]
// Without OUT the results are removed.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/hud_kit.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/color/color_profiles.dart';
import 'package:uwmedia_app/core/hud/dummy_telemetry.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/watermark/watermark.dart';
import 'package:uwmedia_app/engine/desktop/color_batch.dart';
import 'package:uwmedia_app/engine/desktop/convert_run.dart';
import 'package:uwmedia_app/engine/desktop/exiftool.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/telemetry_run.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';
import 'package:uwmedia_app/engine/mobile_engine.dart';
import 'package:uwmedia_app/engine/mobile_video_run.dart';
import 'package:uwmedia_app/engine/native_tools.dart';
import 'package:uwmedia_app/engine/watermark_store.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';

const _clip = String.fromEnvironment('CLIP');
const _out = String.fromEnvironment('OUT');

class _Quiet implements ColorBatchListener {
  final messages = <String>[];

  @override
  void started(int total) {}

  @override
  void active(String file) {}

  @override
  void finished(int done, int total, FileResult result) {}

  @override
  void progress(String file, double percent) {}

  @override
  void message(String line) => messages.add(line);
}

const _dateTags = [
  'QuickTime:CreationDate',
  'QuickTime:CreateDate',
  'QuickTime:ModifyDate',
  'QuickTime:MediaCreateDate',
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the Overlay Generator: ProRes 4444 and HEVC by ffmpeg and by '
      'the engine, the same pictures', (tester) async {
    await tester.runAsync(() async {
      final found = await ToolFinder.forThisMachine().findAll(const {});
      final tools = FfmpegTools(
        ffmpeg: found[toolFfmpeg]!,
        ffprobe: found[toolFfprobe],
        os: currentEngineOs(),
      );
      final work = _out.isEmpty
          ? Directory.systemTemp.createTempSync('uwmedia_native_overlay_')
          : (Directory(_out)..createSync(recursive: true));
      final kit = await HudKit.load();
      const template = 'assets/overlays/templates/garmin/mk3i/main';
      final texts = {
        for (final file in [
          '$template/single_tank/normal.json',
          '$template/normal.json',
        ])
          file: await rootBundle.loadString(file),
      };
      final source = HudLayerSource(
        loadLayoutFile(
          '$template/single_tank/normal.json',
          (path) => texts[path]!,
        ),
        skinBytes: (await rootBundle.load('$template/normal.png')).buffer
            .asUint8List(),
      );
      final dive = buildDummyDive();
      final start = dive.startTime.add(const Duration(minutes: 12));
      const frames = 150;
      for (final format in [overlayFormatProres, overlayFormatHevc]) {
        final made = <String, String>{};
        for (final (name, native) in [
          ('ffmpeg', null),
          ('engine', const PlatformMediaEngine() as MobileMediaEngine?),
        ]) {
          final target = outputPathFor(
            format,
            p.join(work.path, 'overlay_${format}_$name.mp4'),
          );
          final watch = Stopwatch()..start();
          final stats =
              await TelemetryRun(
                tools: tools,
                renderer: kit.renderer,
                painter: kit.painter,
                native: native,
              ).render(
                source: source,
                dive: dive,
                start: start,
                fps: 30,
                totalFrames: frames,
                format: format,
                target: target,
              );
          debugPrint(
            '$format by $name: ${watch.elapsedMilliseconds} ms, '
            '${stats.width}x${stats.height}, ${File(target).lengthSync()} '
            'bytes',
          );
          expect(stats.frames, frames);
          expect(await tools.frameCount(target), frames, reason: name);
          expect(await tools.dimensions(target), (
            stats.width,
            stats.height,
          ), reason: name);
          made[name] = target;
        }
        // The same picture from both, its transparency too: a frame of
        // each, the values a little apart at most.
        final a = await _frameRgba(tools.ffmpeg, made['ffmpeg']!, 100);
        final b = await _frameRgba(tools.ffmpeg, made['engine']!, 100);
        expect(b.length, a.length);
        var apart = 0.0;
        var clear = 0;
        var solid = 0;
        var alphaApart = 0.0;
        for (var i = 0; i < a.length; i += 4) {
          for (var c = 0; c < 3; c++) {
            apart += (a[i + c] - b[i + c]).abs();
          }
          alphaApart += (a[i + 3] - b[i + 3]).abs();
          if (b[i + 3] == 0) clear++;
          if (b[i + 3] == 255) solid++;
        }
        final pixels = a.length / 4;
        debugPrint(
          '$format: colours ${(apart / pixels / 3).toStringAsFixed(2)} apart '
          'on average, alpha ${(alphaApart / pixels).toStringAsFixed(2)}; '
          'engine clear $clear, solid $solid of ${pixels.round()}',
        );
        expect(apart / pixels / 3, lessThan(4), reason: format);
        expect(alphaApart / pixels, lessThan(2), reason: format);
      }
      if (_out.isEmpty) {
        work.deleteSync(recursive: true);
      }
    });
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('Color and Resize: ffmpeg and the engine, side by side', (
    tester,
  ) async {
    expect(_clip, isNotEmpty, reason: 'pass --dart-define=CLIP=');
    await tester.runAsync(() async {
      final found = await ToolFinder.forThisMachine().findAll(const {});
      final tools = (
        ffmpeg: FfmpegTools(
          ffmpeg: found[toolFfmpeg]!,
          ffprobe: found[toolFfprobe],
          os: currentEngineOs(),
        ),
        exiftool: Exiftool(found[toolExiftool]!),
      );
      final work = _out.isEmpty
          ? Directory.systemTemp.createTempSync('uwmedia_native_desktop_')
          : (Directory(_out)..createSync(recursive: true));
      final kit = await HudKit.load();
      final profiles = mergedColorProfiles(
        await rootBundle.loadString('assets/color.yaml'),
        null,
      );
      final (width, height) = await tools.ffmpeg.displayDimensions(_clip);
      final frames = await tools.ffmpeg.frameCount(_clip);
      final sourceTags = await tools.exiftool.tags(_clip, _dateTags);
      debugPrint('clip ${width}x$height, $frames frames, tags $sourceTags');
      const engine = PlatformMediaEngine();
      final mark = watermarkLayer(
        const Watermark(name: 'Name', text: '© Diver'),
      )!;

      Map<String, String>? colorTags;
      Map<String, String>? resizeTags;
      Map<String, String>? sameTags;
      // Third: the build without ffmpeg and exiftool (spec §10.74), the
      // engine and the app's own readers in the tools' place. What it
      // made is looked at with the real tools.
      final own = storeDesktopTools(engine, currentEngineOs());
      for (final (name, native, runTools) in [
        ('ffmpeg', null, tools),
        ('engine', engine as MobileMediaEngine?, tools),
        ('store', engine as MobileMediaEngine?, own),
      ]) {
        // Color: corrected, with a watermark.
        final out = p.join(work.path, 'color_$name');
        final heard = _Quiet();
        var watch = Stopwatch()..start();
        final results =
            await ColorBatch(
              tools: runTools,
              renderer: kit.renderer,
              painter: kit.painter,
              tempDir: (prefix) => work.createTempSync(prefix),
              native: native,
            ).run(
              ColorBatchSettings(
                source: _clip,
                output: out,
                colorProfileName: 'default',
                colorProfile: ColorProfile.fromMap(
                  profiles['default']!.cast<String, dynamic>(),
                ),
                watermarks: [mark],
              ),
              heard,
            );
        expect(
          results.single.status,
          FileStatus.done,
          reason: '$name: $results ${heard.messages}',
        );
        final made = Directory(out).listSync().whereType<File>().single.path;
        debugPrint(
          'Color by $name: ${watch.elapsedMilliseconds} ms, '
          '${File(made).lengthSync()} bytes, ${heard.messages}',
        );
        expect(await tools.ffmpeg.displayDimensions(made), (width, height));
        expect(
          (await tools.ffmpeg.frameCount(made) - frames).abs(),
          lessThanOrEqualTo(1),
          reason: name,
        );
        final tags = await tools.exiftool.tags(made, _dateTags);
        debugPrint('  tags $tags');
        // The engine's result carries what ffmpeg's does.
        expect(tags, colorTags ??= tags, reason: name);

        // Nothing to change: the video copied as it is.
        final plain = p.join(work.path, 'copy_$name');
        final copyHeard = _Quiet();
        watch = Stopwatch()..start();
        final copied = await ColorBatch(
          tools: runTools,
          renderer: kit.renderer,
          painter: kit.painter,
          tempDir: (prefix) => work.createTempSync(prefix),
          native: native,
        ).run(ColorBatchSettings(source: _clip, output: plain), copyHeard);
        expect(
          copied.single.status,
          FileStatus.done,
          reason: '$name: $copied ${copyHeard.messages}',
        );
        final same = Directory(plain).listSync().whereType<File>().single.path;
        debugPrint(
          'Copy by $name: ${watch.elapsedMilliseconds} ms, '
          '${File(same).lengthSync()} bytes, ${copyHeard.messages}',
        );
        expect(
          copyHeard.messages.where((m) => m.contains('copied by FFmpeg')),
          isEmpty,
        );
        expect(await tools.ffmpeg.frameCount(same), frames, reason: name);
        final copyTags = await tools.exiftool.tags(same, _dateTags);
        expect(copyTags, sameTags ??= copyTags, reason: name);

        // Resize: one resolution.
        final sized = p.join(work.path, 'resize_$name');
        watch = Stopwatch()..start();
        final result =
            await ConvertRun(
              ffmpeg: runTools.ffmpeg,
              exiftool: runTools.exiftool,
              native: native == null
                  ? null
                  : MobileVideoRun(
                      engine: native,
                      tempDir: (prefix) => work.createTempSync(prefix),
                    ),
            ).convert(
              source: _clip,
              outputDir: sized,
              resolutions: ['720p'],
              hwAccel: true,
            );
        expect(result.failed, isEmpty, reason: '$name: ${result.messages}');
        final small = Directory(sized).listSync().whereType<File>().single.path;
        debugPrint(
          'Resize by $name: ${watch.elapsedMilliseconds} ms, '
          '${File(small).lengthSync()} bytes, ${result.messages}',
        );
        expect(await tools.ffmpeg.displayDimensions(small), (1280, 720));
        final smallTags = await tools.exiftool.tags(small, _dateTags);
        debugPrint('  tags $smallTags');
        expect(smallTags, resizeTags ??= smallTags, reason: name);
      }
      if (_out.isEmpty) {
        work.deleteSync(recursive: true);
      }
    });
  }, timeout: const Timeout(Duration(minutes: 30)));
}

/// One frame of [video] as RGBA bytes, by ffmpeg.
Future<Uint8List> _frameRgba(String ffmpeg, String video, int frame) async {
  final result = await Process.run(ffmpeg, [
    '-v', 'error', '-i', video, '-vf', 'select=eq(n\\,$frame)', //
    '-frames:v', '1', '-pix_fmt', 'rgba', '-f', 'rawvideo', '-',
  ], stdoutEncoding: null);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return Uint8List.fromList(result.stdout as List<int>);
}
