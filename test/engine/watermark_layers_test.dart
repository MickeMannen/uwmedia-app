// A watermark through the runs' own drawing: on a photo without a dive,
// and as a video layer that is one picture the whole clip through
// (lib/core/watermark/watermark.dart, HudLayerSource.always).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/engine/hud_layers.dart';
import 'package:uwmedia_app/core/hud/hud_designer.dart';
import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/watermark/watermark.dart';
import 'package:uwmedia_app/engine/photo_run.dart';
import 'package:uwmedia_app/engine/watermark_store.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';
import 'package:uwmedia_app/pages/shared/watermark_editor.dart';

const _w = 400;
const _h = 300;

Future<ui.Image> _solid(int width, int height, List<int> rgba) => hudSkinImage(
  Uint8List.fromList([for (var i = 0; i < width * height; i++) ...rgba]),
  width,
  height,
);

Future<Uint8List> _png(ui.Image image) async =>
    (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
        .asUint8List();

Future<Uint8List> _pixels(ui.Image image) async =>
    (await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer
        .asUint8List();

List<int> _at(Uint8List rgba, int x, int y, [int width = _w]) =>
    rgba.sublist((y * width + x) * 4, (y * width + x) * 4 + 3);

void main() {
  late TtfFonts fonts;
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
    fonts = TtfFonts(
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

  test('layers that need no dive are the only ones without one', () {
    const overlay = HudLayerSource({});
    const mark = HudLayerSource({}, always: true);
    expect(layersToDraw([overlay, mark], matched: true), [overlay, mark]);
    expect(layersToDraw([overlay, mark], matched: false), [mark]);
  });

  test(
    'a picture on a photo with no dive: its corner, size, opacity',
    () async {
      final logo = await _png(await _solid(60, 30, [255, 0, 0, 255]));
      final layout = watermarkLayout(
        const Watermark(name: 'Logo', picture: 'logo.png', opacity: 0.5),
        pictureSize: (60, 30),
      )!;
      // A grey JPEG-less photo: the run's own path from bytes to bytes.
      final grey = await _png(await _solid(_w, _h, [100, 100, 100, 255]));
      final out = await run.process(
        grey,
        format: PhotoFormat.png,
        colorCorrect: false,
        layers: [HudLayerSource(layout, skinBytes: logo, always: true)],
      );
      final codec = await ui.instantiateImageCodec(out);
      final rgba = await _pixels((await codec.getNextFrame()).image);

      // 15 % of 400 is 60 wide (30 high), 2 pixels in from the corner
      // (0.5 % of the width, spec §10.103): x 338 to 398, y 268 to 298.
      // Half red over the grey inside it.
      final inside = _at(rgba, 362, 277);
      expect(inside[0], inInclusiveRange(170, 185));
      expect(inside[1], inInclusiveRange(45, 55));
      expect(_at(rgba, 399, 299), [100, 100, 100], reason: 'the margin');
      expect(_at(rgba, 331, 277), [100, 100, 100], reason: 'left of it');
      expect(_at(rgba, 362, 261), [100, 100, 100], reason: 'above it');
      expect(_at(rgba, 10, 10), [100, 100, 100]);
    },
  );

  test('a text at the top left stays in its corner', () async {
    final layout = watermarkLayout(
      const Watermark(
        name: 'Name',
        text: 'DIVER',
        anchor: 'TOP_LEFT',
        size: 0.05,
      ),
    )!;
    final base = await _solid(_w, _h, [100, 100, 100, 255]);
    final composed = await run.overlaid(
      base,
      [HudLayerSource(layout, always: true)],
      // No sample is needed; the run hands a made-up one.
      (await _noDive()),
      null,
    );
    final rgba = await _pixels(composed);
    var changed = 0;
    var minX = _w, maxX = 0, minY = _h, maxY = 0;
    for (var y = 0; y < _h; y++) {
      for (var x = 0; x < _w; x++) {
        final px = _at(rgba, x, y);
        if (px[0] != 100 || px[1] != 100 || px[2] != 100) {
          changed++;
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    expect(changed, greaterThan(100), reason: 'the text is drawn');
    // 2 pixels in from the corner (the outline a pixel out, the letters'
    // own top a few in), letters 20 high.
    expect(minX, inInclusiveRange(0, 4));
    expect(minY, inInclusiveRange(0, 8));
    expect(maxY, lessThan(40));
    expect(maxX, lessThan(_w ~/ 2));
  });

  // The box of what [layers] changed on a grey frame of [w] by [h].
  Future<(int, int, int, int)> changedBox(
    List<HudLayerSource> layers,
    int w,
    int h,
  ) async {
    final base = await _solid(w, h, [100, 100, 100, 255]);
    final rgba = await _pixels(
      await run.overlaid(base, layers, await _noDive(), null),
    );
    var minX = w, maxX = -1, minY = h, maxY = -1;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final px = _at(rgba, x, y, w);
        if (px[0] != 100 || px[1] != 100 || px[2] != 100) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    return (minX, minY, maxX, maxY);
  }

  test('a picture between the nine places, and its own place on a portrait '
      'frame (spec §10.63)', () async {
    final logo = await _png(await _solid(60, 30, [255, 0, 0, 255]));
    final layer = watermarkLayer(
      const Watermark(
        name: 'Logo',
        picture: 'logo.png',
        size: 0.25,
        opacity: 1,
        place: (x: 0.25, y: 0.75),
        placePortrait: (x: 1, y: 0),
      ),
      pictureBytes: logo,
    )!;
    expect(layer.always, isTrue);
    // Landscape, 400 x 300: 100 x 50 with a margin of 2; a quarter of the
    // way across the room of 296, three quarters down the room of 246.
    final (x0, y0, x1, y1) = await changedBox([layer], 400, 300);
    expect(x0, closeTo(76, 1));
    expect(y0, closeTo(186.5, 1.5));
    expect(x1 - x0 + 1, closeTo(100, 1));
    expect(y1 - y0 + 1, closeTo(50, 1));
    // Portrait, 300 x 400: 75 x 37.5 against the top right margin (1.5).
    final (px0, py0, px1, py1) = await changedBox([layer], 300, 400);
    expect(px1, closeTo(297.5, 1));
    expect(py0, closeTo(1.5, 1));
    expect(px1 - px0 + 1, closeTo(75, 1));
    expect(py1 - py0 + 1, closeTo(37.5, 1.5));
    // The layer for a frame is a plain one: asked again, it is itself.
    final upright = layer.on(300, 400);
    expect(upright.on(1920, 1080), same(upright));
    expect((upright.layout['hud_skin'] as Map)['anchor'], 'TOP_RIGHT');
  });

  test('a measured text lies where its place puts its box, both ways and at '
      'the edges', () async {
    const text = Watermark(name: 'Name', text: 'DIVER', size: 0.05);
    final box = measuredTextBox(
      HudDesigner(HudRenderer(fonts, HudRules(const {}))),
      text,
    )!;
    // Five bold capitals: a few letter heights wide, under one high.
    expect(box.$1, inInclusiveRange(2.5, 4.5));
    expect(box.$2, inInclusiveRange(0.6, 0.9));
    final measured = text.copyWith(textBox: box);
    final w = box.$1 * 0.05 * _w;
    final h = box.$2 * 0.05 * _w;
    for (final place in const [
      (x: 0.0, y: 0.0),
      (x: 1.0, y: 1.0),
      (x: 0.5, y: 0.5),
      (x: 0.3, y: 0.8),
    ]) {
      final layer = watermarkLayer(measured.copyWith(place: place))!;
      final (x0, y0, x1, y1) = await changedBox([layer], _w, _h);
      // The ink with its outline, a pixel or two around the box.
      final left = 2 + place.x * (_w - 4 - w);
      final top = 2 + place.y * (_h - 4 - h);
      expect(x0, closeTo(left, 3.5), reason: '$place');
      expect(x1, closeTo(left + w, 3.5), reason: '$place');
      expect(y0, closeTo(top, 3.5), reason: '$place');
      expect(y1, closeTo(top + h, 3.5), reason: '$place');
      expect(x0, greaterThanOrEqualTo(1), reason: 'inside the frame');
      expect(x1, lessThan(_w - 1));
    }
    // Two watermarks on one frame: each where it belongs.
    final both = await changedBox(
      [
        watermarkLayer(measured.copyWith(place: (x: 0.0, y: 0.0)))!,
        watermarkLayer(measured.copyWith(place: (x: 1.0, y: 1.0)))!,
      ],
      _w,
      _h,
    );
    expect(both.$1, lessThan(12));
    expect(both.$3, greaterThan(_w - 13));
  });

  test('on a video: one picture for the whole clip, by its corner', () async {
    final tmp = Directory.systemTemp.createTempSync('uwmedia_watermark_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final logo = await _png(await _solid(60, 30, [255, 0, 0, 255]));
    final layout = watermarkLayout(
      const Watermark(name: 'Logo', picture: 'logo.png', anchor: 'TOP_RIGHT'),
      pictureSize: (60, 30),
    )!;
    const List<HudSegment> whole = [(null, 0, 50)];
    final pictures =
        await HudLayerWriter(
          HudRenderer(fonts, HudRules(const {})),
          HudPainter(fonts),
          frameW: 1280,
          frameH: 720,
        ).pictures(
          HudLayerSource(layout, skinBytes: logo, always: true),
          whole,
          const [],
          tmp,
          0,
          fps: 25,
        );
    expect(pictures, isNotNull);
    final (path, frames) = pictures!.entries.single;
    expect(frames, 50);
    final codec = await ui.instantiateImageCodec(File(path).readAsBytesSync());
    final image = (await codec.getNextFrame()).image;
    final rgba = await _pixels(image);
    // 15 % of 1280 is 192 wide, 96 high; 25 pixels (2 %) in from the top
    // right: x 1063 to 1255, y 25 to 121 on the frame.
    final x = 1063 + 96 - pictures.x;
    final y = 25 + 48 - pictures.y;
    expect(_at(rgba, x, y, image.width).sublist(0, 2), [255, 0]);
    expect(
      rgba[((25 + 48 - pictures.y) * image.width + (1050 - pictures.x)) * 4 +
          3],
      0,
      reason: 'clear left of the picture',
    );
  });
}

Future<Waypoint> _noDive() async =>
    Waypoint(timestamp: naive(2000, 1, 1), timeSinceStart: 0, depth: 0);
