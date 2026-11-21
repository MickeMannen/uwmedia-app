// The painter against the Python app's golden images
// (test/fixtures/python_reference/overlay_golden/): every bundled page and
// variant in the states of the Python golden test, drawn by the port's
// renderer and painter on a black 1920x1080 frame, cropped to the overlay's
// own pixels and halved, as the Python test does it.
//
// The geometry is already compared exactly elsewhere
// (test/core/hud/hud_renderer_parity_test.dart); what differs here is the
// rasteriser (Flutter's, not Pillow's and OpenCV's: glyphs without hinting
// and about 5 % heavier, shape edges a little different) and, for the
// pages set in "Arial", the font: the goldens were made with the Mac's
// Arial, the port draws Liberation Sans on every platform (spec §5.6).
//
// So the Python test's own limits (a mean difference of 2.0 and 0.5 % of
// the pixels off by more than 40) are not met by most images, and the
// limits here are the port's own, set from the first full run (2026-11-13,
// macOS: mean of the means 1.95, worst image 4.28 and 3.0 %) with some
// room: they catch an element that moves, changes colour or goes missing,
// not a glyph edge. Nothing shifts: moving the port's image by a pixel in
// any direction makes every difference several times larger.
//
// The two generic/depth_temp pages are text alone on an invisible skin, so
// the crop is the ink of the text itself and follows the font: with
// Liberation Sans it comes out a pixel smaller than with Arial and the
// images no longer lie on each other. For them only the size is checked.
//
// HUD_GOLDEN_ONLY=<part of a file name> draws just those images and writes
// golden | port | difference x3 side by side into build/hud_golden/, as it
// does for every image over a limit.
@Tags(['golden'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/image_resize.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

import '../helpers/renderer_reference.dart';

const _goldenDir = 'test/fixtures/python_reference/overlay_golden';
const _states = {
  'normal',
  'ndl_low',
  'deco_at_stop',
  'deco_violation',
  'clear',
  'safety_stop',
  'safety_paused',
  'fast_ascent',
  'critical_gas',
};

/// The limits per image: the mean absolute difference over the crop, and
/// the share of pixels that differ by more than 40; and the limit on the
/// mean of all images' means.
const _meanLimit = 5.0;
const _changedLimit = 0.04;
const _overallLimit = 2.5;

/// Text alone on an invisible skin: see the comment at the top.
bool _textOnly(String name) => name.startsWith('generic__depth_temp__');

class _Pixels {
  _Pixels(this.width, this.height, this.rgba);

  final int width;
  final int height;
  final Uint8List rgba;
}

Future<_Pixels> _pixelsOf(ui.Image image) async {
  final data = await image.toByteData();
  return _Pixels(image.width, image.height, data!.buffer.asUint8List());
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  return (await codec.getNextFrame()).image;
}

/// The overlay's own pixels (everything not black), halved by area
/// averaging, as `cv2.resize(crop, (w // 2, h // 2), INTER_AREA)`.
_Pixels _cropAndHalve(_Pixels frame) {
  var x0 = frame.width;
  var y0 = frame.height;
  var x1 = -1;
  var y1 = -1;
  for (var y = 0; y < frame.height; y++) {
    for (var x = 0; x < frame.width; x++) {
      final i = 4 * (y * frame.width + x);
      if (frame.rgba[i] != 0 ||
          frame.rgba[i + 1] != 0 ||
          frame.rgba[i + 2] != 0) {
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
  }
  if (x1 < 0) {
    return _Pixels(1, 1, Uint8List(4));
  }
  final w = x1 - x0 + 1;
  final h = y1 - y0 + 1;
  final crop = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    final from = 4 * ((y0 + y) * frame.width + x0);
    crop.setRange(4 * y * w, 4 * (y + 1) * w, frame.rgba, from);
  }
  final outW = w ~/ 2 < 1 ? 1 : w ~/ 2;
  final outH = h ~/ 2 < 1 ? 1 : h ~/ 2;
  return _Pixels(outW, outH, areaResize(crop, w, h, outW, outH));
}

/// An image from straight (not premultiplied) RGBA bytes.
Future<ui.Image> _imageOf(Uint8List rgba, int width, int height) async {
  final premultiplied = Uint8List.fromList(rgba);
  for (var i = 0; i < premultiplied.length; i += 4) {
    final a = premultiplied[i + 3];
    if (a != 255) {
      premultiplied[i] = premultiplied[i] * a ~/ 255;
      premultiplied[i + 1] = premultiplied[i + 1] * a ~/ 255;
      premultiplied[i + 2] = premultiplied[i + 2] * a ~/ 255;
    }
  }
  final descriptor = ui.ImageDescriptor.raw(
    await ui.ImmutableBuffer.fromUint8List(premultiplied),
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  return (await (await descriptor.instantiateCodec()).getNextFrame()).image;
}

/// (mean absolute difference, share of pixels differing by more than 40)
/// over the area both images have.
(double, double) _difference(_Pixels a, _Pixels b) {
  final w = a.width < b.width ? a.width : b.width;
  final h = a.height < b.height ? a.height : b.height;
  var sum = 0;
  var changed = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = 4 * (y * a.width + x);
      final j = 4 * (y * b.width + x);
      var worst = 0;
      for (var c = 0; c < 3; c++) {
        final d = (a.rgba[i + c] - b.rgba[j + c]).abs();
        sum += d;
        if (d > worst) worst = d;
      }
      if (worst > 40) changed++;
    }
  }
  return (sum / (w * h * 3), changed / (w * h));
}

Future<void> _writeComparison(String name, _Pixels port, _Pixels golden) async {
  final w = port.width > golden.width ? port.width : golden.width;
  final h = port.height > golden.height ? port.height : golden.height;
  final out = Uint8List(3 * w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final px = <int>[0, 0, 0];
      final gx = <int>[0, 0, 0];
      if (x < port.width && y < port.height) {
        final i = 4 * (y * port.width + x);
        px.setAll(0, port.rgba.sublist(i, i + 3));
      }
      if (x < golden.width && y < golden.height) {
        final i = 4 * (y * golden.width + x);
        gx.setAll(0, golden.rgba.sublist(i, i + 3));
      }
      for (var c = 0; c < 3; c++) {
        out[4 * (y * 3 * w + x) + c] = gx[c];
        out[4 * (y * 3 * w + w + x) + c] = px[c];
        final d = (px[c] - gx[c]).abs() * 3;
        out[4 * (y * 3 * w + 2 * w + x) + c] = d > 255 ? 255 : d;
      }
      for (var k = 0; k < 3; k++) {
        out[4 * (y * 3 * w + k * w + x) + 3] = 255;
      }
    }
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(out);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: 3 * w,
    height: h,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final image =
      (await (await descriptor.instantiateCodec()).getNextFrame()).image;
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('build/hud_golden/$name');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(png!.buffer.asUint8List());
}

void main() {
  testWidgets('the painter draws the golden images', (tester) async {
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
      final reference = RendererReference.load();
      final rules = HudRules(
        jsonDecode(File('assets/hud_rules.json').readAsStringSync())
            as Map<String, dynamic>,
      );
      final fonts = TtfFonts(
        (file) => File('assets/fonts/$file').readAsBytesSync(),
        inkTables: InkTables.parse(
          File('assets/fonts/ink_tables.bin').readAsBytesSync(),
        ),
      );
      final renderer = HudRenderer(fonts, rules);
      final painter = HudPainter(fonts);
      final skins = <String, ui.Image>{};
      final natives = <String, _Pixels>{};
      final only = Platform.environment['HUD_GOLDEN_ONLY'];

      final results = <(String, double, double, String)>[];
      final failures = <String>[];
      for (final c in reference.cases) {
        final situation = c['situation'] as String;
        if (c.containsKey('size') ||
            c.containsKey('render_log') ||
            c.containsKey('placed') ||
            c.containsKey('changed') ||
            !(_states.contains(situation) || situation.startsWith('ccr@'))) {
          continue;
        }
        final template = c['template'] as List<dynamic>;
        final name =
            '${[...template.whereType<String>(), situation].join('__')}'
            '${c['units'] == null ? '' : '__${c['units']}'}.png';
        if (only != null && !name.contains(only)) {
          continue;
        }
        final goldenFile = File('$_goldenDir/$name');
        if (!goldenFile.existsSync()) {
          results.add((name, double.infinity, 1, 'no golden image'));
          continue;
        }
        final layout = reference.layout(template);
        final hudSkin = layout['hud_skin'] as Map<String, dynamic>;
        ui.Image? skin;
        (int, int)? skinSize;
        if (hudSkin['type'] != 'shape') {
          final path =
              '${File(RendererReference.templatePath(template)).parent.path}/'
              '${hudSkin['path']}';
          final native = natives[path] ??= await () async {
            final image = await _decode(File(path).readAsBytesSync());
            final data = await image.toByteData(
              format: ui.ImageByteFormat.rawStraightRgba,
            );
            return _Pixels(
              image.width,
              image.height,
              data!.buffer.asUint8List(),
            );
          }();
          skinSize = (native.width, native.height);
          // The skin at the size it is drawn at, by area averaging, as
          // the Python app prepares it.
          final scale = (hudSkin['scale'] as num?) ?? 1.0;
          final w = (native.width * scale * 1.0).truncate();
          final h = (native.height * scale * 1.0).truncate();
          skin = skins['$path@$w'] ??= await _imageOf(
            areaResize(native.rgba, native.width, native.height, w, h),
            w,
            h,
          );
        }
        final (waypoint, history) = reference.situation(c);
        final ops = renderer.drawHud(
          frameWidth: 1920,
          frameHeight: 1080,
          layout: layout,
          waypoint: waypoint,
          waypoints: history,
          skinSize: skinSize,
          units: normalizeUnits(c['units']),
        );
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder)
          ..drawRect(
            const ui.Rect.fromLTWH(0, 0, 1920, 1080),
            ui.Paint()..color = const ui.Color(0xFF000000),
          );
        painter.paint(
          canvas,
          ops,
          skin: skin,
          skinOpacity: ((hudSkin['opacity'] as num?) ?? 1.0).toDouble(),
        );
        final frame = await recorder.endRecording().toImage(1920, 1080);
        final port = _cropAndHalve(await _pixelsOf(frame));
        frame.dispose();
        final goldenImage = await _decode(goldenFile.readAsBytesSync());
        final golden = await _pixelsOf(goldenImage);
        goldenImage.dispose();
        final (mean, changed) = _difference(port, golden);
        final sizes = port.width == golden.width && port.height == golden.height
            ? ''
            : '${port.width}x${port.height}, golden '
                  '${golden.width}x${golden.height}';
        final failed = _textOnly(name)
            ? (port.width - golden.width).abs() > 1 ||
                  (port.height - golden.height).abs() > 1
            : sizes.isNotEmpty || mean > _meanLimit || changed > _changedLimit;
        results.add((name, mean, changed, sizes));
        if (failed) {
          failures.add(
            '$name: mean ${mean.toStringAsFixed(2)}, '
            '${(100 * changed).toStringAsFixed(2)} % of the pixels'
            '${sizes.isEmpty ? '' : ', $sizes'}',
          );
        }
        if (only != null || failed) {
          await _writeComparison(name, port, golden);
        }
      }

      if (only != null) {
        for (final r in results) {
          // ignore: avoid_print
          print(
            '${r.$1}: mean ${r.$2.toStringAsFixed(2)}, '
            '${(100 * r.$3).toStringAsFixed(2)} % ${r.$4}',
          );
        }
        return;
      }
      expect(results.length, 1445);
      // Every golden image was drawn: a stale renderer fixture would skip
      // the pages it lacks.
      expect(
        {for (final r in results) r.$1},
        {
          for (final f in Directory(_goldenDir).listSync())
            if (f.path.endsWith('.png')) f.uri.pathSegments.last,
        },
      );
      expect(
        failures,
        isEmpty,
        reason: 'golden | port | difference in build/hud_golden/',
      );
      final compared = results.where((r) => !_textOnly(r.$1)).toList();
      expect(
        compared.fold(0.0, (s, r) => s + r.$2) / compared.length,
        lessThan(_overallLimit),
      );
    });
  }, timeout: const Timeout(Duration(minutes: 30)));
}
