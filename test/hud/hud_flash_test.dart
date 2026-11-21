// A video's flashing values by the video's own time (spec §10 issue 9,
// owner 2026-11-19): the layer writer draws a flashing sample twice, its
// flashing colour and its own, and shows the two in turn half a second
// each; a sample that does not flash stays one picture.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

void main() {
  late HudLayerWriter writer;

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
    final rules = HudRules(
      jsonDecode(File('assets/hud_rules.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    writer = HudLayerWriter(
      HudRenderer(fonts, rules),
      HudPainter(fonts),
      frameW: 1280,
      frameH: 720,
    );
  });

  // A Garmin's depth, which flashes red above a broken deco ceiling.
  const layout = <String, dynamic>{
    'manufacturer': 'Garmin',
    'model': 'mk3i',
    'design_width': 1920,
    'hud_skin': <String, dynamic>{
      'type': 'shape',
      'width': 400,
      'height': 200,
      'linked_elements': [
        <String, dynamic>{'field': 'depth', 'rel_x': 0.1, 'rel_y': 0.1},
      ],
    },
  };
  Waypoint at(double depth) => Waypoint(
    timestamp: naive(2026, 1, 1, 10),
    timeSinceStart: 0,
    depth: depth,
    diveTime: 0,
    decoStopDepth: 6.0,
    nextStopDepth: 6.0,
    nextStopTime: 60,
  );

  Future<List<(String, int)>> entries(Waypoint wp) async {
    final tmp = Directory.systemTemp.createTempSync('uwmedia_flash_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final drawn = await writer.pictures(
      const HudLayerSource(layout, placement: (x: 0.1, y: 0.1, scale: 1.0)),
      [(wp, 0, 50)],
      const [],
      tmp,
      0,
      fps: 25,
    );
    // Only the pictures the entries name were written.
    expect(
      tmp.listSync().map((f) => f.path).toSet(),
      drawn!.entries.map((e) => e.$1).toSet(),
    );
    return drawn.entries;
  }

  test('a broken ceiling: two pictures in turn, by the half second', () async {
    final shown = await entries(at(5.0));
    // 25 fps: half seconds of 13 and 12 frames, from the clip's start.
    expect([for (final e in shown) e.$2], [13, 12, 13, 12]);
    final (red, own) = (shown[0].$1, shown[1].$1);
    expect(red, isNot(own));
    expect([for (final e in shown) e.$1], [red, own, red, own]);
  });

  test('nothing flashing: one picture the whole sample through', () async {
    expect([for (final e in await entries(at(5.5))) e.$2], [50]);
  });
}
