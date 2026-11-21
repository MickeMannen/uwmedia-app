// The overlay run of the desktop engine (lib/engine/desktop/
// overlay_run.dart, lib/hud/hud_layer_stream.dart) end to end: a bundled
// template drawn by the app's own painter for the sample dive, and a real
// ffmpeg laying it over colour bars made at run time in a temporary
// folder. Needs ffmpeg and ffprobe on the PATH; without them the tests
// skip themselves.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/color/color_profiles.dart';
import 'package:uwmedia_app/core/engine/ffmpeg_commands.dart';
import 'package:uwmedia_app/core/engine/hud_layers.dart';
import 'package:uwmedia_app/core/hud/dummy_telemetry.dart';
import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/engine/desktop/color_run.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/overlay_run.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

import '../../helpers/tools.dart';

const _template = 'assets/overlays/templates/garmin/mk3i/main';

void main() {
  final skip = hasTool('ffmpeg') && hasTool('ffprobe')
      ? null
      : 'needs ffmpeg and ffprobe on the PATH';

  testWidgets('overlays drawn by the app and laid on by ffmpeg', (
    tester,
  ) async {
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
      final renderer = HudRenderer(
        fonts,
        HudRules(
          jsonDecode(File('assets/hud_rules.json').readAsStringSync())
              as Map<String, dynamic>,
        ),
      );
      final painter = HudPainter(fonts);
      final layout = loadLayoutFile(
        '$_template/normal.json',
        (path) => File(path).readAsStringSync(),
      );
      final skinBytes = File('$_template/normal.png').readAsBytesSync();
      final dive = buildDummyDive();
      // Twelve minutes into the dive: on the bottom, everything shown.
      final start = dive.startTime.add(const Duration(minutes: 12));

      final tmp = Directory.systemTemp.createTempSync('uwmedia_overlay_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final made = <String>[];
      Directory tempDir(String prefix) {
        final fresh = (Directory(
          p.join(tmp.path, 'tmp'),
        )..createSync(recursive: true)).createTempSync(prefix);
        made.add(fresh.path);
        return fresh;
      }

      // --- a layer on its own -------------------------------------------
      const fps = 25.0;
      final segments = hudSegments(dive, start, fps, 250);
      expect(segments.length, greaterThan(1));
      final writer = HudLayerWriter(
        renderer,
        painter,
        frameW: 1280,
        frameH: 720,
      );
      final layerDir = Directory(p.join(tmp.path, 'layer'))..createSync();
      final seen = <int>[];
      final placed = await writer.write(
        HudLayerSource(
          layout,
          skinBytes: skinBytes,
          placement: (x: 0.5, y: 0.25, scale: 0.5),
        ),
        segments,
        dive.waypoints,
        fps,
        layerDir,
        0,
        onSegment: seen.add,
      );
      final (concat, x, y) = placed!;
      expect(seen.last, segments.length - 1);
      // Kept on a canvas around the skin, not the whole frame.
      expect(x, greaterThan(500));
      expect(y, greaterThan(100));
      final lines = File(concat).readAsLinesSync();
      expect(lines.first, 'ffconcat version 1.0');
      final shown = [
        for (final line in lines)
          if (line.startsWith('duration ')) double.parse(line.substring(9)),
      ];
      expect(shown.reduce((a, b) => a + b), closeTo(250 / fps, 1e-4));
      final first = File(p.join(layerDir.path, layerPngName(0, 0)));
      final codec = await ui.instantiateImageCodec(first.readAsBytesSync());
      final picture = (await codec.getNextFrame()).image;
      expect(picture.width, lessThan(1280));
      expect(picture.height, lessThan(720));
      final pixels = (await picture.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      ))!.buffer.asUint8List();
      // Transparent at the corner, opaque somewhere in the middle.
      expect(pixels[3], 0);
      var opaque = 0;
      for (var a = 3; a < pixels.length; a += 4) {
        opaque += pixels[a] == 255 ? 1 : 0;
      }
      expect(opaque, greaterThan(1000));
      picture.dispose();

      // A layer that never draws anything gives no stream.
      final nothing = await writer.write(
        const HudLayerSource({
          'hud_skin': {'type': 'image', 'path': 'gone.png'},
        }),
        segments,
        dive.waypoints,
        fps,
        layerDir,
        1,
      );
      expect(nothing, isNull);

      // Stop is asked before each segment.
      await expectLater(
        writer.write(
          HudLayerSource(layout, skinBytes: skinBytes),
          segments,
          dive.waypoints,
          fps,
          layerDir,
          2,
          stopped: () => true,
        ),
        throwsA(isA<HudLayerStopped>()),
      );

      // --- the whole run ------------------------------------------------
      final found = await ToolFinder.forThisMachine().findAll(const {});
      final tools = FfmpegTools(
        ffmpeg: found[toolFfmpeg]!,
        ffprobe: found[toolFfprobe],
        os: currentEngineOs(),
      );
      // Tagged BT.709 as a camera's clip is: the frame grab reads every
      // clip as BT.601 (as Python's OpenCV), and the outputs are BT.709,
      // so an untagged source would not compare with what is made of it.
      final clip = p.join(tmp.path, 'bars.mp4');
      final source = await runCapture(tools.ffmpeg, [
        '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', //
        'smptebars=s=640x360:r=25:d=4,'
            'colorchannelmixer=rr=0.25:gg=0.8:bb=0.9',
        '-c:v', 'libx264', '-pix_fmt', 'yuv420p', //
        '-color_primaries', '1', '-color_trc', '1', '-colorspace', '1', clip,
      ]);
      expect(source?.exitCode, 0, reason: source?.stderr);

      final profiles = mergedColorProfiles(
        File('assets/color.yaml').readAsStringSync(),
        null,
      );
      final color = ColorRun(
        tools: tools,
        engine: ColorEngine(
          ColorProfile.fromMap(profiles['default']!.cast<String, dynamic>()),
        ),
        tempDir: tempDir,
        hwAccel: false,
      );
      final run = OverlayRun(
        color: color,
        renderer: renderer,
        painter: painter,
      );
      final layers = [
        // By its own anchor (bottom left), then one the user placed.
        HudLayerSource(layout, skinBytes: skinBytes),
        HudLayerSource(
          layout,
          skinBytes: skinBytes,
          placement: (x: 0.55, y: 0.05, scale: 0.6),
        ),
      ];

      Future<List<double>> means(String path, int x0, int y0) async {
        final frame = (await tools.frameAt(
          path,
          2.0,
          width: 640,
          height: 360,
        ))!;
        final sums = [0, 0, 0];
        for (var yy = y0; yy < y0 + 40; yy++) {
          for (var xx = x0; xx < x0 + 40; xx++) {
            for (var c = 0; c < 3; c++) {
              sums[c] += frame.rgb[(yy * 640 + xx) * 3 + c];
            }
          }
        }
        return [for (final s in sums) s / 1600];
      }

      double distance(List<double> a, List<double> b) =>
          [for (var c = 0; c < 3; c++) (a[c] - b[c]).abs()]
              .reduce((m, v) => m > v ? m : v);

      // Colour only, for comparison.
      final plain = p.join(tmp.path, 'plain.mp4');
      await color.processVideoLut(
        input: clip,
        output: plain,
        creationDate: start,
      );

      final out = p.join(tmp.path, 'overlay.mp4');
      final progress = <double>[];
      final stats = await run.processVideo(
        input: clip,
        output: out,
        creationDate: start,
        dive: dive,
        layers: layers,
        tzOffsetMins: 60,
        onProgress: progress.add,
      );
      expect(stats.totalFrames, 100);
      expect(stats.layers, 2);
      expect(stats.samples, 3);
      expect(await tools.dimensions(out), (640, 360));
      expect(await tools.countedFrames(out), 100);
      expect(progress, orderedEquals([...progress]..sort()));
      expect(progress.last, 100.0);
      expect(
        progress.where((v) => v > analysisProgressEnd && v <= hudProgressEnd),
        isNotEmpty,
      );

      if (Platform.environment['UWMEDIA_KEEP'] != null) {
        File(out).copySync(Platform.environment['UWMEDIA_KEEP']!);
      }
      // Where the overlays are, the picture is another; away from them it
      // is the colour-corrected footage (a spot at the top left).
      expect(
        distance(await means(out, 30, 30), await means(plain, 30, 30)),
        lessThan(6),
      );
      // The watch at the bottom left, and the placed one at the top right.
      expect(
        distance(await means(out, 45, 205), await means(plain, 45, 205)),
        greaterThan(25),
      );
      expect(
        distance(await means(out, 365, 45), await means(plain, 365, 45)),
        greaterThan(25),
      );

      // Without the colour correction the footage is the source's.
      final uncorrected = p.join(tmp.path, 'overlay_only.mp4');
      final bare = await run.processVideo(
        input: clip,
        output: uncorrected,
        creationDate: start,
        dive: dive,
        layers: [layers.first],
        colorCorrect: false,
      );
      expect(bare.samples, 0);
      expect(bare.layers, 1);
      expect(
        distance(await means(uncorrected, 30, 30), await means(clip, 30, 30)),
        lessThan(6),
      );

      // Without a dive nothing is drawn, and the clip still comes out.
      final noDive = await run.processVideo(
        input: clip,
        output: p.join(tmp.path, 'no_dive.mp4'),
        creationDate: start,
        layers: layers,
      );
      expect(noDive.layers, 0);
      expect(await tools.countedFrames(p.join(tmp.path, 'no_dive.mp4')), 100);

      // Stopped before it starts.
      final control = RunControl();
      await control.stop();
      await expectLater(
        run.processVideo(
          input: clip,
          output: p.join(tmp.path, 'never.mp4'),
          creationDate: start,
          dive: dive,
          layers: layers,
          control: control,
        ),
        throwsA(isA<RunStopped>()),
      );
      expect(made, isNotEmpty);
      expect(made.any((dir) => Directory(dir).existsSync()), isFalse);
    });
  }, skip: skip != null);
}
