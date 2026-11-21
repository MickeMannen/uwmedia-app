// The telemetry-only render of the desktop engine (lib/engine/desktop/
// telemetry_run.dart) end to end: a bundled template drawn for the sample
// dive into each of the three formats, read back with a real ffmpeg.
// Needs ffmpeg and ffprobe on the PATH; without them the test skips
// itself.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/hud/dummy_telemetry.dart';
import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/desktop/telemetry_run.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

import '../../helpers/tools.dart';

const _template = 'assets/overlays/templates/garmin/mk3i/main';

void main() {
  final skip = !(hasTool('ffmpeg') && hasTool('ffprobe'));

  testWidgets('the overlay alone as ProRes, PNGs and HEVC', (tester) async {
    await tester.runAsync(() async {
      for (final family in fontRegistry.values) {
        for (final file in family.values) {
          final loader = FontLoader(fontFamilyOf(file))
            ..addFont(
              Future.value(
                ByteData.sublistView(
                  File('assets/fonts/$file').readAsBytesSync(),
                ),
              ),
            );
          await loader.load();
        }
      }
      final fonts = TtfFonts(
        (file) => File('assets/fonts/$file').readAsBytesSync(),
        inkTables: InkTables.parse(
          File('assets/fonts/ink_tables.bin').readAsBytesSync(),
        ),
      );
      final found = await ToolFinder.forThisMachine().findAll(const {});
      final tools = FfmpegTools(
        ffmpeg: found[toolFfmpeg]!,
        ffprobe: found[toolFfprobe],
        os: currentEngineOs(),
      );
      final run = TelemetryRun(
        tools: tools,
        renderer: HudRenderer(
          fonts,
          HudRules(
            jsonDecode(File('assets/hud_rules.json').readAsStringSync())
                as Map<String, dynamic>,
          ),
        ),
        painter: HudPainter(fonts),
        hwAccel: false,
      );
      final source = HudLayerSource(
        loadLayoutFile(
          '$_template/normal.json',
          (path) => File(path).readAsStringSync(),
        ),
        skinBytes: File('$_template/normal.png').readAsBytesSync(),
      );
      final dive = buildDummyDive();
      final start = dive.startTime.add(const Duration(minutes: 12));
      final tmp = Directory.systemTemp.createTempSync('uwmedia_telemetry_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      Future<Map<String, String>> stream(String path) async {
        final result = await runCapture(found[toolFfprobe]!, [
          '-v', 'error', '-select_streams', 'v:0', '-count_frames', //
          '-show_entries',
          'stream=codec_name,pix_fmt,width,height,nb_read_frames',
          '-of', 'default=noprint_wrappers=1', path,
        ]);
        return {
          for (final line in const LineSplitter().convert(result!.stdout))
            if (line.contains('=')) line.split('=').first: line.split('=').last,
        };
      }

      expect(TelemetryRun.logFrames(dive), dummyDurationS * 30);

      // 25 s at 30 frames a second: three samples of the dive.
      const frames = 750;

      // --- ProRes 4444 with alpha: the skin is the frame ----------------
      final mov = outputPathFor(overlayFormatProres, p.join(tmp.path, 'a.mp4'));
      expect(mov, endsWith('a.mov'));
      final seen = <double>[];
      final prores = await run.render(
        source: source,
        dive: dive,
        start: start,
        fps: logRenderFps,
        totalFrames: frames,
        format: overlayFormatProres,
        target: mov,
        onProgress: seen.add,
      );
      // The 692x922 skin at its scale of 0.5.
      expect((prores.width, prores.height), (346, 462));
      expect(prores.frames, frames);
      expect(prores.pictures, inInclusiveRange(3, 4));
      final written = await stream(mov);
      // With alpha (ffprobe names the decoder's format, 10 or 12 bits).
      expect(written.remove('pix_fmt'), startsWith('yuva444p1'));
      expect(written, {
        'codec_name': 'prores',
        'width': '346',
        'height': '462',
        'nb_read_frames': '$frames',
      });
      expect(seen, orderedEquals([...seen]..sort()));
      expect(seen.last, 100.0);

      // --- a PNG sequence, at twice the size ----------------------------
      final folder = outputPathFor(overlayFormatPng, p.join(tmp.path, 'b.mp4'));
      expect(p.basename(folder), 'b');
      final png = await run.render(
        source: source,
        dive: dive,
        start: start,
        fps: logRenderFps,
        totalFrames: 40,
        format: overlayFormatPng,
        target: folder,
        size: '4k',
      );
      expect((png.width, png.height), (692, 922));
      final files = Directory(folder).listSync().map((f) => f.path).toList()
        ..sort();
      expect(files.length, 40);
      expect(p.basename(files.first), 'frame_000001.png');
      expect(p.basename(files.last), 'frame_000040.png');
      // The frames of one sample are the same file's bytes.
      expect(
        File(files[1]).readAsBytesSync(),
        File(files[0]).readAsBytesSync(),
      );
      final codec = await ui.instantiateImageCodec(
        File(files.first).readAsBytesSync(),
      );
      final first = (await codec.getNextFrame()).image;
      expect((first.width, first.height), (692, 922));
      final pixels = (await first.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      ))!.buffer.asUint8List();
      // Transparent beside the watch's strap, opaque on its face.
      expect(pixels[3], 0);
      expect(pixels[(461 * 692 + 346) * 4 + 3], 255);
      first.dispose();

      // --- HEVC on black, the whole design frame ------------------------
      final mp4 = outputPathFor(overlayFormatHevc, p.join(tmp.path, 'c.mp4'));
      final hevc = await run.render(
        source: source,
        dive: null,
        start: start,
        fps: 25,
        totalFrames: 50,
        format: overlayFormatHevc,
        target: mp4,
        fullFrame: true,
      );
      expect((hevc.width, hevc.height), (1920, 1080));
      // No dive: one picture, of a sample of zeros.
      expect(hevc.pictures, 1);
      expect(await stream(mp4), {
        'codec_name': 'hevc',
        'pix_fmt': 'yuv420p',
        'width': '1920',
        'height': '1080',
        'nb_read_frames': '50',
      });
      // Black away from the overlay, the watch at the bottom left.
      final frame = (await tools.frameAt(mp4, 1.0, width: 1920, height: 1080))!;
      int red(int x, int y) => frame.rgb[(y * 1920 + x) * 3];
      expect(red(1800, 100), lessThan(20));
      var lit = 0;
      for (var y = 700; y < 1060; y += 4) {
        for (var x = 20; x < 360; x += 4) {
          lit += red(x, y) > 60 ? 1 : 0;
        }
      }
      expect(lit, greaterThan(200));

      // --- Stop, and what cannot be rendered -----------------------------
      final control = RunControl();
      final stopped = run.render(
        source: source,
        dive: dive,
        start: start,
        fps: logRenderFps,
        totalFrames: 100000,
        format: overlayFormatProres,
        target: p.join(tmp.path, 'd.mov'),
        control: control,
        onProgress: (_) {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      // Listened for before Stop: on Windows the render can end while
      // taskkill is still being waited for.
      final ended = expectLater(stopped, throwsA(isA<RunStopped>()));
      await control.stop();
      await ended;

      await expectLater(
        run.render(
          source: source,
          dive: dive,
          start: start,
          fps: logRenderFps,
          totalFrames: 10,
          format: overlayFormatProres,
          target: p.join(tmp.path, 'no', 'such', 'folder', 'e.mov'),
        ),
        throwsA(isA<EngineException>()),
      );
      await expectLater(
        run.render(
          source: source,
          dive: dive,
          start: start,
          fps: logRenderFps,
          totalFrames: 10,
          format: 'gif',
          target: p.join(tmp.path, 'f.gif'),
        ),
        throwsArgumentError,
      );
    });
  }, skip: skip);
}
