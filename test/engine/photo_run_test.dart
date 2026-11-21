// A photo through the app (lib/engine/photo_run.dart): colour, overlays
// and the save with the source's JPEG tables, on stills made at run time
// in a temporary folder, with real ffmpeg and exiftool for making them
// and for the metadata. Without the tools the test skips itself.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

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
import 'package:uwmedia_app/core/image/jpeg_encoder.dart';
import 'package:uwmedia_app/core/image/jpeg_tables.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/engine/desktop/exiftool.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';
import 'package:uwmedia_app/engine/photo_run.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

import '../helpers/tools.dart';

const _template = 'assets/overlays/templates/garmin/mk3i/main';

void main() {
  final skip = !(hasTool('ffmpeg') && hasTool('exiftool'));

  test('the format a name asks for', () {
    expect(photoFormatOf('/a/b.JPG'), PhotoFormat.jpeg);
    expect(photoFormatOf('b.jpeg'), PhotoFormat.jpeg);
    expect(photoFormatOf('b.png'), PhotoFormat.png);
    expect(photoFormatOf('b.tiff'), isNull);
  });

  testWidgets('colour, overlays and the save', (tester) async {
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
      final profiles = mergedColorProfiles(
        File('assets/color.yaml').readAsStringSync(),
        null,
      );
      final run = PhotoRun(
        renderer: HudRenderer(
          fonts,
          HudRules(
            jsonDecode(File('assets/hud_rules.json').readAsStringSync())
                as Map<String, dynamic>,
          ),
        ),
        painter: HudPainter(fonts),
        engine: ColorEngine(
          ColorProfile.fromMap(profiles['default']!.cast<String, dynamic>()),
        ),
      );
      final layer = HudLayerSource(
        loadLayoutFile(
          '$_template/normal.json',
          (path) => File(path).readAsStringSync(),
        ),
        skinBytes: File('$_template/normal.png').readAsBytesSync(),
      );
      final dive = buildDummyDive();
      final taken = dive.startTime.add(const Duration(minutes: 12));

      final tmp = Directory.systemTemp.createTempSync('uwmedia_photo_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final found = await ToolFinder.forThisMachine().findAll(const {});
      final exiftool = Exiftool(found[toolExiftool]!);

      // A still with a blue-green cast.
      final source = p.join(tmp.path, 'DSC01.JPG');
      final made = await runCapture(found[toolFfmpeg]!, [
        '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', //
        'smptebars=s=1280x720,colorchannelmixer=rr=0.25:gg=0.8:bb=0.9',
        '-frames:v', '1', '-q:v', '2', source,
      ]);
      expect(made?.exitCode, 0, reason: made?.stderr);
      Future<(int, int, Uint8List)> pixels(Uint8List file) async {
        final codec = await ui.instantiateImageCodec(file);
        final image = (await codec.getNextFrame()).image;
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        ))!.buffer.asUint8List();
        final size = (image.width, image.height, data);
        image.dispose();
        return size;
      }

      // ffmpeg's still, saved again with tables and a subsampling a writer
      // would not pick by itself (ffmpeg's own JPEGs name their sampling
      // in a way Pillow, and so the port, reads as "unknown").
      final (rawW, rawH, raw) = await pixels(File(source).readAsBytesSync());
      final rgb = Uint8List(rawW * rawH * 3);
      for (var i = 0, o = 0; i < raw.length; i += 4) {
        rgb[o++] = raw[i];
        rgb[o++] = raw[i + 1];
        rgb[o++] = raw[i + 2];
      }
      File(source).writeAsBytesSync(
        encodeJpeg(
          rgb,
          rawW,
          rawH,
          quantTables: [List.filled(64, 5), List.filled(64, 9)],
          sampling: JpegSampling.s444,
        ),
      );
      await exiftool.setTags(source, {
        'EXIF:DateTimeOriginal': '2026:05:21 06:58:22',
        'EXIF:Make': 'SONY',
      });
      final sourceBytes = File(source).readAsBytesSync();
      final sourceTables = readJpegTables(sourceBytes)!;
      expect(sourceTables.sampling, JpegSampling.s444);

      List<double> means(Uint8List rgba, int width, int x0, int y0) {
        final sums = [0, 0, 0];
        for (var y = y0; y < y0 + 40; y++) {
          for (var x = x0; x < x0 + 40; x++) {
            for (var c = 0; c < 3; c++) {
              sums[c] += rgba[(y * width + x) * 4 + c];
            }
          }
        }
        return [for (final s in sums) s / 1600];
      }

      // --- colour and an overlay, to a file, with the metadata -----------
      final target = p.join(tmp.path, 'out', 'DSC01_color.jpg');
      Directory(p.dirname(target)).createSync();
      await run.processFile(
        source,
        target,
        layers: [layer],
        dive: dive,
        matchDate: taken,
        exiftool: exiftool,
      );
      final outBytes = File(target).readAsBytesSync();
      final outTables = readJpegTables(outBytes)!;
      // Saved as the source was.
      expect(outTables.quantization, sourceTables.quantization);
      expect(outTables.sampling, JpegSampling.s444);
      final meta = (await exiftool.metadata(target))!;
      expect(meta['EXIF:DateTimeOriginal'], '2026:05:21 06:58:22');
      expect(meta['EXIF:Make'], 'SONY');

      final (w, h, before) = await pixels(sourceBytes);
      final (ow, oh, after) = await pixels(outBytes);
      expect((ow, oh), (w, h));
      // Red comes back against blue over the top half, where no overlay
      // is ...
      List<double> top(Uint8List rgba) {
        final sums = [0, 0, 0];
        for (var i = 0; i < w * (h ~/ 2) * 4; i += 4 * 13) {
          for (var c = 0; c < 3; c++) {
            sums[c] += rgba[i + c];
          }
        }
        return [for (final s in sums) s.toDouble()];
      }

      final a = top(before);
      final b = top(after);
      expect(b[0] / b[2], greaterThan(a[0] / a[2] * 1.3));
      // ... and the watch is at the bottom left, dark on the bars.
      final watch = means(after, w, 60, 440);
      expect(watch.reduce((m, v) => m > v ? m : v), lessThan(90));

      // --- neither: the picture comes through the save alone -------------
      final plain = await run.process(
        sourceBytes,
        format: PhotoFormat.jpeg,
        colorCorrect: false,
      );
      final (_, _, same) = await pixels(plain);
      var worst = 0;
      for (var i = 0; i < same.length; i += 97) {
        final d = (same[i] - before[i]).abs();
        worst = d > worst ? d : worst;
      }
      expect(worst, lessThan(40));
      expect(readJpegTables(plain)!.quantization, sourceTables.quantization);

      // Without a dive there is no overlay, and still a picture.
      final noDive = await run.process(
        sourceBytes,
        format: PhotoFormat.jpeg,
        colorCorrect: false,
        layers: [layer],
        matchDate: taken,
      );
      expect(noDive, plain);

      // --- a window cut out of it (spec §10.77): at its own pixels -------
      final (fullW, fullH, _) = await pixels(plain);
      final square = await run.process(
        sourceBytes,
        format: PhotoFormat.jpeg,
        colorCorrect: false,
        cut: const PictureCut(shape: ShareShape.squareCropped),
      );
      final (cutW, cutH, _) = await pixels(square);
      final side = fullW < fullH ? fullW : fullH;
      expect((cutW, cutH), (side - side % 2, side - side % 2));
      final zoomed = await run.process(
        sourceBytes,
        format: PhotoFormat.jpeg,
        colorCorrect: false,
        cut: const PictureCut(size: 0.5),
      );
      final (halfW, _, _) = await pixels(zoomed);
      expect(halfW, closeTo(fullW / 2, 2));

      // Half an hour before the dive (on the boat): the overlay is there,
      // with "--" for its values, not the first sample's (spec §10.10).
      final early = taken.subtract(const Duration(minutes: 30));
      final boat = await run.process(
        sourceBytes,
        format: PhotoFormat.jpeg,
        colorCorrect: false,
        layers: [layer],
        dive: dive,
        matchDate: early,
      );
      expect(boat, isNot(plain));
      final first = await run.process(
        sourceBytes,
        format: PhotoFormat.jpeg,
        colorCorrect: false,
        layers: [layer],
        dive: dive,
        matchDate: dive.waypoints.first.timestamp,
      );
      expect(boat, isNot(first));

      // --- a PNG source: a JPEG at the finest tables, or a PNG -----------
      final png = await run.process(
        sourceBytes,
        format: PhotoFormat.png,
        colorCorrect: false,
      );
      expect(png.sublist(1, 4), ascii.encode('PNG'));
      final fromPng = await run.process(
        png,
        format: PhotoFormat.jpeg,
        colorCorrect: false,
      );
      final finest = readJpegTables(fromPng)!;
      expect(finest.quantization[0], everyElement(1));
      expect(finest.sampling, JpegSampling.s420);

      // --- a photo taken on its side --------------------------------------
      final turned = p.join(tmp.path, 'turned.jpg');
      File(source).copySync(turned);
      await exiftool.setTags(turned, {'Orientation': 6});
      final upright = p.join(tmp.path, 'upright.jpg');
      await run.processFile(
        turned,
        upright,
        colorCorrect: false,
        exiftool: exiftool,
      );
      final (tw, th, _) = await pixels(File(upright).readAsBytesSync());
      // The pixels are turned, and the tag no longer asks for a turn.
      expect((tw, th), (720, 1280));
      expect(
        (await exiftool.tags(upright, ['Orientation']))['Orientation'],
        '1',
      );

      // --- the overlay alone ----------------------------------------------
      final alpha = await run.telemetryPhoto(
        layer,
        overlayFormat: overlayFormatProres,
        format: PhotoFormat.jpeg,
        matchDate: taken,
        dive: dive,
      );
      final (aw, ah, overlay) = await pixels(alpha);
      expect((aw, ah), (346, 462));
      expect(overlay[3], 0);
      final onBlack = await run.telemetryPhoto(
        layer,
        overlayFormat: overlayFormatHevc,
        format: PhotoFormat.jpeg,
        matchDate: taken,
        sourceBytes: sourceBytes,
        fullFrame: true,
      );
      final black = readJpegTables(onBlack)!;
      expect(black.quantization, sourceTables.quantization);
      final (bw, bh, frame) = await pixels(onBlack);
      expect((bw, bh), (1920, 1080));
      expect(
        means(frame, bw, 1700, 100).reduce((m, v) => m > v ? m : v),
        lessThan(8),
      );

      // --- what is no picture, and a name the app cannot write ------------
      await expectLater(
        run.process(utf8.encode('not a picture'), format: PhotoFormat.jpeg),
        throwsA(isA<EngineException>()),
      );
      await expectLater(
        run.processFile(source, p.join(tmp.path, 'a.tiff')),
        throwsA(isA<EngineException>()),
      );
    });
  }, skip: skip);
}
