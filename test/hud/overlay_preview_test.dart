// A look at a bundled computer's overlays while they are made: every page
// and variant of one computer drawn in the Overlay Designer's forced
// states, each as a PNG in build/overlay_preview/.
//
//   OVERLAY_PREVIEW=tusa/tc1 flutter test test/hud/overlay_preview_test.dart
//
// With OVERLAY_PREVIEW_UNITS=imperial in feet and Fahrenheit. Without
// OVERLAY_PREVIEW nothing is drawn and the test passes: it checks nothing,
// the pictures are for a person's eyes (the checks of a new computer's
// pages are in test/core/hud/).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/hud/dummy_telemetry.dart';
import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/hud/template_tree.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

import '../core/hud/template_tree_test.dart' show bundledFolder;

const _assets = 'assets/overlays/templates';

/// The frame the overlays are drawn on: twice the design's size, so that
/// a skin shows at its own pixels.
const _width = 3840;
const _height = 2160;

/// The forced states drawn, and a few moments of the sample dive.
const _states = [
  'normal',
  'descent',
  'ndl_low',
  'deco',
  'deco_at_stop',
  'deco_violation',
  'clear',
  'safety_stop',
  'safety_paused',
  'safety_done',
  'fast_ascent',
  'high_ppo2',
];

void main() {
  final which = Platform.environment['OVERLAY_PREVIEW'];
  testWidgets('the overlays of OVERLAY_PREVIEW, drawn', (tester) async {
    if (which == null || !which.contains('/')) {
      return;
    }
    final [brand, computer] = which.split('/');
    final units = normalizeUnits(Platform.environment['OVERLAY_PREVIEW_UNITS']);
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
      final tree = TemplateTree(bundled: bundledFolder());
      final manifest = tree.brands[brand]![computer]!;
      final out = Directory('build/overlay_preview')
        ..createSync(recursive: true);
      final dive = buildDummyDive();

      for (final page
          in (manifest['pages'] as List<dynamic>)
              .cast<Map<String, dynamic>>()) {
        final variants = (page['variants'] as List<dynamic>? ?? const [])
            .cast<String>();
        for (final variant in variants.isEmpty ? <String?>[null] : variants) {
          final path = tree.resolveState(
            brand,
            computer,
            page['id'] as String,
            variant: variant,
          )!;
          final file = path.replaceFirst('bundled/', '$_assets/');
          final layout = stripVariantMarkers(
            loadLayoutFile(file, (f) => File(f).readAsStringSync()),
          );
          final hudSkin = layout['hud_skin'] as Map<String, dynamic>;
          ui.Image? skin;
          (int, int)? skinSize;
          if (hudSkin['type'] != 'shape') {
            final codec = await ui.instantiateImageCodec(
              File('${File(file).parent.path}/${hudSkin['path']}')
                  .readAsBytesSync(),
            );
            skin = (await codec.getNextFrame()).image;
            skinSize = (skin.width, skin.height);
          }
          for (final state in _states) {
            final (waypoint, history) = forcedDive(
              waypointAt(dive, 600),
              state,
            );
            final ops = renderer.drawHud(
              frameWidth: _width,
              frameHeight: _height,
              layout: layout,
              waypoint: waypoint,
              waypoints: history,
              skinSize: skinSize,
              units: units,
            );
            final recorder = ui.PictureRecorder();
            final canvas = ui.Canvas(recorder)
              ..drawRect(
                ui.Rect.fromLTWH(0, 0, _width.toDouble(), _height.toDouble()),
                ui.Paint()..color = const ui.Color(0xFF2A5F7A),
              );
            painter.paint(
              canvas,
              ops,
              skin: skin,
              skinOpacity: ((hudSkin['opacity'] as num?) ?? 1.0).toDouble(),
            );
            final frame = await recorder.endRecording().toImage(
              _width,
              _height,
            );
            final png = await frame.toByteData(format: ui.ImageByteFormat.png);
            frame.dispose();
            final name = [
              brand,
              computer,
              page['id'],
              ?variant,
              state,
            ].join('__');
            File('${out.path}/$name.png')
                .writeAsBytesSync(png!.buffer.asUint8List());
          }
        }
      }
    });
  });
}
