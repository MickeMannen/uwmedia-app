// The box the Color page draws around an overlay (overlayPixelBox) and
// where the overlay is drawn (PhotoRun.overlaid): the same place, on a
// frame of any size (owner, 2026-11-19: the box was off the overlay on a
// zoomed picture).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/engine/photo_run.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

void main() {
  late PhotoRun run;

  setUpAll(() async {
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
    run = PhotoRun(
      renderer: HudRenderer(fonts, HudRules(const {})),
      painter: HudPainter(fonts),
    );
  });

  final layout = jsonDecode(
    File('assets/overlays/templates/generic/depth_temp/standard/normal.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;

  for (final (w, h) in [
    (1280, 720),
    (1066, 600),
    (720, 1280),
    (853, 1280),
    (1280, 853),
    (1066, 711),
    (1280, 960),
    (1000, 1000),
  ]) {
    test('depth and temperature on $w x $h', () async {
      const x = 0.6, y = 0.4, scale = 1.0;
      final base = await hudSkinImage(
        Uint8List.fromList([
          for (var i = 0; i < w * h; i++) ...[200, 200, 200, 255],
        ]),
        w,
        h,
      );
      final composed = await run.overlaid(
        base,
        [HudLayerSource(layout, placement: (x: x, y: y, scale: scale))],
        Waypoint(
          timestamp: naive(2026, 1, 1, 10),
          timeSinceStart: 0,
          depth: 10.5,
          temp: 22.0,
        ),
        null,
      );
      final rgba = (await composed.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      ))!.buffer.asUint8List();
      var minX = w, maxX = -1, minY = h, maxY = -1;
      for (var py = 0; py < h; py++) {
        for (var px = 0; px < w; px++) {
          if (rgba[(py * w + px) * 4] != 200) {
            if (px < minX) minX = px;
            if (px > maxX) maxX = px;
            if (py < minY) minY = py;
            if (py > maxY) maxY = py;
          }
        }
      }
      final box = overlayPixelBox(layout, x, y, scale, w, h);
      final (x0, y0, x1, y1) = box;
      expect(minX, closeTo(x0, 2));
      expect(minY, closeTo(y0, 2));
      expect(maxX + 1, closeTo(x1, 2));
      expect(maxY + 1, closeTo(y1, 2));
    });
  }
}
