// The cases of the Python app's tests/test_hud_renderer.py that need no
// pixels and that no other Dart test covers: element bounds and defaults,
// badge lines and states, the bundled pages' variants. Each test carries
// the name of the Python test it ports. The pixel cases are in
// test/hud/hud_renderer_pixels_test.dart, which lists where the rest are.
//
// Covered by the designer fixture in hud_designer_test.dart and so not
// here: test_tank_icon_bounds_include_the_drawn_outline (its "odd" cases
// have a tank icon with and without draw_outline, bounds from Python) and
// test_tank_icon_segments_bounds_span_all_segments_and_nose (the default
// segments icon and a changed one, with the default outline gap and width
// this test sets).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/hud/hud_designer.dart';
import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/hud_geometry.dart';
import 'package:uwmedia_app/core/hud/hud_ops.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/hud_text.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

final _rules = HudRules(
  jsonDecode(File('assets/hud_rules.json').readAsStringSync())
      as Map<String, dynamic>,
);
final _fonts = TtfFonts(
  (file) => File('assets/fonts/$file').readAsBytesSync(),
  inkTables: InkTables.parse(
    File('assets/fonts/ink_tables.bin').readAsBytesSync(),
  ),
);
final _designer = HudDesigner(HudRenderer(_fonts, _rules));
final _t0 = naive(2026, 1, 1, 10);

Waypoint _wp({
  double? depth,
  int? diveTime,
  double? decoStopDepth,
  double? nextStopDepth,
  int? nextStopTime,
}) => Waypoint(
  timestamp: _t0,
  timeSinceStart: 0,
  depth: depth,
  diveTime: diveTime,
  decoStopDepth: decoStopDepth,
  nextStopDepth: nextStopDepth,
  nextStopTime: nextStopTime,
);

const _templates = 'assets/overlays/templates';

Map<String, dynamic> _layoutFile(String path) =>
    loadLayoutFile(path, (f) => File(f).readAsStringSync());

List<Map<String, dynamic>> _elements(Map<String, dynamic> layout) => [
  for (final e
      in (layout['hud_skin'] as Map<String, dynamic>)['linked_elements']
          as List<dynamic>)
    e as Map<String, dynamic>,
];

void main() {
  group('tests/test_hud_renderer.py', () {
    test('test_small_suffix_bounds_include_the_suffix', () {
      const elem = <String, dynamic>{
        'field': 'dive_time',
        'rel_x': 0.1,
        'rel_y': 0.1,
        'font_size': 60,
        'scale': 1.0,
      };
      final (x0, y0, x1, _) = _designer.elementNativeBounds(
        elem,
        600,
        200,
        text: '12:34',
      );
      final (sx0, sy0, sx1, _) = _designer.elementNativeBounds(
        {...elem, 'small_suffix': 'seconds'},
        600,
        200,
        text: '12:34',
      );
      expect((sx0, sy0), (x0, y0));
      // Narrower than a full-size "12:34", wider than "12" alone.
      expect(x1, greaterThan(sx1));
      expect(sx1, greaterThan(x0 + 30));
    });

    test('test_tissue_bar_bounds_and_defaults', () {
      final elem = elementDefaults('tissue_bar', 'n2_tissue_load');
      expect(elementKind(elem), 'tissue_bar');
      expect((elem['type'], elem['field']), ('tissue_bar', 'n2_tissue_load'));
      expect(
        _designer.elementNativeBounds(
          {...elem, 'rel_x': 0.5, 'rel_y': 0.5},
          200,
          200,
        ),
        (96.0, 100.0, 112.0, 137.0),
      );
      final parsed = parseLayoutElements({
        'linked_elements': [
          {
            'field': 'n2_tissue_load',
            'type': 'tissue_bar',
            'rel_x': 0.1,
            'rel_y': 0.1,
          },
        ],
      });
      expect(
        (parsed[0]['width'], parsed[0]['height'], parsed[0]['marker_size']),
        (12, 33, 4),
      );
    });

    test('test_ascent_chevron_defaults_and_bounds', () {
      final elem = elementDefaults('ascent_chevrons', 'ascent_rate');
      expect(elementKind(elem), 'ascent_chevrons');
      expect(elem['field'], 'ascent_rate');
      expect(elem['up_count'], 4);
      expect(
        _designer.elementNativeBounds(
          {...elem, 'rel_x': 0.5, 'rel_y': 0.5},
          200,
          200,
        ),
        (100.0, 100.0, 116.0, 147.0),
      );
      final parsed = parseLayoutElements({
        'linked_elements': [
          {
            'field': 'ascent_rate',
            'type': 'ascent_chevrons',
            'rel_x': 0.1,
            'rel_y': 0.1,
          },
        ],
      });
      expect(
        (
          parsed[0]['width'],
          parsed[0]['height'],
          parsed[0]['up_count'],
          parsed[0]['down_count'],
        ),
        (16, 47, 4, 1),
      );
    });

    test('test_mk3i_badge_is_label_less_ceiling_over_short_timer', () {
      // Descent Mk3 manual p.10: "↑ceiling" small over the stop timer as
      // 2:33, no STOP/DECO word, white text.
      const elem = <String, dynamic>{
        'field': 'state_badge',
        'type': 'badge',
        'rel_x': 0,
        'rel_y': 0,
        'depth_font': 'label',
        'depth_unit': 'm',
        'timer_format': 'm:ss',
      };
      final deco = _wp(
        depth: 6.2,
        decoStopDepth: 6.0,
        nextStopDepth: 6.0,
        nextStopTime: 153,
      );
      final lines = badgeLines(
        HudContext(_rules, 'Garmin', 'mk3i', UnitSystem.metric),
        elem,
        deco,
      )!;
      expect([for (final l in lines) l.$1], ['↑6m', '2:33']);
      expect([for (final l in lines) l.$3], [false, true]);
      expect([for (final l in lines) l.$2], everyElement((255, 255, 255)));
    });

    test('test_ceiling_broken_flashes_depth_line_red_on_garmin_only', () {
      const elem = <String, dynamic>{
        'field': 'state_badge',
        'type': 'badge',
        'rel_x': 0,
        'rel_y': 0,
      };
      Waypoint at(double depth) => _wp(
        depth: depth,
        diveTime: 0,
        decoStopDepth: 6.0,
        nextStopDepth: 6.0,
        nextStopTime: 60,
      );
      final within = at(5.5);
      final above = at(5.0);
      expect(_rules.ceilingBroken('Garmin', 'mk3i', within), isFalse);
      expect(_rules.ceilingBroken('Garmin', 'mk3i', above), isTrue);
      // No such rule there.
      expect(_rules.ceilingBroken('Shearwater', 'Perdix 2', above), isFalse);
      // A dive time of 0 is the first half of the blink: the red phase.
      final mk3i = HudContext(_rules, 'Garmin', 'mk3i', UnitSystem.metric);
      expect(badgeLines(mk3i, elem, above)![0].$2, (255, 0, 0));
      expect(badgeLines(mk3i, elem, within)![0].$2, (255, 255, 255));
    });

    // Spec §10 issue 9 (owner, 2026-11-19): a video's flashing values
    // follow the video's own time, half a second red and half not; a
    // photo (no time given) keeps the red.
    test('a video flashes by its own time, a photo stays red', () {
      const elem = <String, dynamic>{
        'field': 'state_badge',
        'type': 'badge',
        'rel_x': 0,
        'rel_y': 0,
      };
      final above = _wp(
        depth: 5.0,
        diveTime: 0,
        decoStopDepth: 6.0,
        nextStopDepth: 6.0,
        nextStopTime: 60,
      );
      Rgb depthLine(double? flashAt) => badgeLines(
        HudContext(
          _rules,
          'Garmin',
          'mk3i',
          UnitSystem.metric,
          flashAt: flashAt,
        ),
        elem,
        above,
      )![0].$2;
      expect(depthLine(null), (255, 0, 0));
      expect(depthLine(0.0), (255, 0, 0));
      expect(depthLine(0.49), (255, 0, 0));
      expect(depthLine(0.5), (255, 255, 255));
      expect(depthLine(1.2), (255, 0, 0));
      expect(depthLine(61.75), (255, 255, 255));

      // The whole drawing: the depth value too, and only while the
      // ceiling is broken.
      final layout = <String, dynamic>{
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
      String drawn(Waypoint wp, double? flashAt) => jsonEncode([
        for (final op in HudRenderer(_fonts, _rules).drawHud(
          frameWidth: 1920,
          frameHeight: 1080,
          layout: layout,
          waypoint: wp,
          flashAt: flashAt,
        ))
          op.toJson(),
      ]);
      expect(drawn(above, 0.0), isNot(drawn(above, 0.5)));
      expect(drawn(above, null), drawn(above, 0.0));
      final within = _wp(
        depth: 5.5,
        diveTime: 0,
        decoStopDepth: 6.0,
        nextStopDepth: 6.0,
        nextStopTime: 60,
      );
      expect(drawn(within, 0.0), drawn(within, 0.5));
    });

    // Spec §10.83, not in Python: its icons reach below the digits.
    test(
      'a Descent X50i\'s tank icons stand on the pressure digits\' foot',
      () {
        final renderer = HudRenderer(_fonts, _rules);
        for (final page in ['main/single_tank', 'main/sidemount', 'cc']) {
          final file = '$_templates/garmin/x50i/$page/normal.json';
          final layout = stripVariantMarkers(_layoutFile(file));
          final skin = layout['hud_skin'] as Map<String, dynamic>;
          // The skin image's size, from its PNG header.
          final png = ByteData.sublistView(
            File('${File(file).parent.path}/${skin['path']}').readAsBytesSync(),
          );
          for (final (width, height, slack) in [
            (1920, 1080, 0),
            (3840, 2160, 1),
            (1280, 720, 1),
          ]) {
            final ops = renderer.drawHud(
              frameWidth: width,
              frameHeight: height,
              layout: layout,
              waypoint: Waypoint(
                timestamp: _t0,
                timeSinceStart: 754,
                depth: 18.4,
                diveTime: 754,
                tanks: {
                  'T1': TankData(pressureBar: 142, name: 'T1'),
                  'T2': TankData(pressureBar: 138, name: 'T2'),
                },
              ),
              skinSize: (png.getUint32(16), png.getUint32(20)),
            );
            final digits = ops.whereType<TextOp>().firstWhere(
              (op) => op.text == '142',
            );
            final foot =
                digits.y +
                _fonts.font(digits.size, digits.fontFile).getbbox('142').$4 -
                1;
            final icons = [
              for (final op in ops.whereType<RoundedRectOp>())
                if (op.outline != null && op.y1 - op.y0 > op.x1 - op.x0) op.y1,
            ];
            expect(icons, hasLength(page == 'main/sidemount' ? 2 : 1));
            for (final bottom in icons) {
              expect(
                bottom,
                closeTo(foot, slack),
                reason: '$page on $width x $height',
              );
            }
          }
        }
      },
    );

    test('test_petrel_main_variants_share_a_base_like_the_perdix', () {
      const page = '$_templates/shearwater/petrel/main';
      expect(
        (jsonDecode(File('$page/single_tank/normal.json').readAsStringSync())
            as Map<String, dynamic>)['base'],
        '../normal.json',
      );
      final row = [
        for (final e in _elements(_layoutFile('$page/sidemount/normal.json')))
          if (e[elementOriginKey] == 'variant') e['field'],
      ];
      expect(
        row,
        containsAll([
          'pressure_sac',
          'custom:SM',
          'secondary_tank_pressure',
          'primary_tank_pressure',
        ]),
      );
      expect(File('$page/normal.png').existsSync(), isTrue);
      expect(File('$page/sidemount/normal.png').existsSync(), isFalse);
    });

    for (final page in ['main', 'standard', 'tec']) {
      test('test_perdix_3_pages_hide_the_ndl_while_a_stop_shows[$page]', () {
        // Single tank, as Python's _load_perdix3_layout for these pages.
        final elems = _elements(
          stripVariantMarkers(
            _layoutFile(
              '$_templates/shearwater/perdix_3/$page/single_tank/normal.json',
            ),
          ),
        );
        expect(elems.any((e) => e['type'] == 'badge'), isTrue);
        for (final field in ['ndl', 'custom:NDL']) {
          expect(
            (elems.firstWhere((e) => e['field'] == field)['hide_in_states']
                    as List<dynamic>)
                .toSet(),
            {'safety_stop', 'deco', 'clear'},
          );
        }
      });
    }

    test('test_vertical_text_bounds_match_the_ink_in_the_designer', () {
      final font = _fonts.font(40, fontFile(null, null));
      for (final orientation in ['stacked', 'up', 'down']) {
        final (dx, dy, w, h) = orientedTextGeometry(
          font,
          'SAFETY',
          orientation,
          40,
        );
        expect(h, greaterThan(w), reason: orientation);
        expect((dx, dy), (0.0, 0.0), reason: orientation);
        final (cdx, cdy, _, _) = orientedTextGeometry(
          font,
          'SAFETY',
          orientation,
          40,
          'center',
          'middle',
        );
        expect((cdx, cdy), (-w / 2, -h / 2), reason: orientation);
      }
    });

    test('test_arc_fills_from_its_start_in_proportion_to_the_value '
        '(geometry; the pixels are in hud_renderer_pixels_test.dart)', () {
      expect(arcGeometry({'type': 'arc'}), (120.0, 120.0, 12.0));
      expect(
        gaugeFraction({'range_max': 250}, 125, arcDefaults),
        closeTo(0.5, 1e-12),
      );
      expect(gaugeFraction({'range_max': 250}, 400, arcDefaults), 1.0);
      expect(gaugeFraction({}, null, arcDefaults), 0.0);
    });

    test('test_segment_bar_lights_whole_segments_from_the_bottom '
        '(geometry)', () {
      expect(segmentBarGeometry({'type': 'segment_bar'}), (12.0, 60.0, 5, 2.0));
    });

    test('test_suunto_minute_formats_and_text_box (formats)', () {
      String? format(Map<String, dynamic> elem, Object raw) =>
          applyValueFormat(elem, 'x', raw, UnitSystem.metric);
      expect(
        format({'field': 'ndl', 'value_format': 'minutes_prime'}, 45 * 60),
        '45′',
      );
      expect(
        format({'field': 'ndl', 'value_format': 'minutes_prime'}, 6000),
        '>99′',
      );
      expect(
        format({'field': 'tts', 'value_format': 'minutes_prime'}, 6000),
        '100′',
      );
      expect(
        format({'field': 'dive_time', 'value_format': "m'ss"}, 170),
        '2′50',
      );
    });

    test('test_gauge_bounds_and_defaults', () {
      final arc = elementDefaults('arc', 'ndl');
      expect(elementKind(arc), 'arc');
      expect(arc['field'], 'ndl');
      expect(arc['range_max'], 6000);
      // The drawn band only: a 270-degree arc open at the bottom ends ~42
      // px short of the full circle's foot.
      final (x0, y0, x1, y1) = _designer.elementNativeBounds(
        {...arc, 'rel_x': 0.5, 'rel_y': 0.5},
        200,
        200,
      );
      expect((x0.round(), y0.round(), x1.round()), (100, 100, 220));
      expect(y1, inExclusiveRange(200, 205));
      final (fx0, fy0, fx1, fy1) = _designer.elementNativeBounds(
        {...arc, 'rel_x': 0.5, 'rel_y': 0.5, 'start_angle': 0, 'sweep': 360},
        200,
        200,
      );
      expect(
        (fx0.round(), fy0.round(), fx1.round(), fy1.round()),
        (100, 100, 220, 220),
      );
      final bar = elementDefaults('segment_bar', 'ascent_rate');
      expect(elementKind(bar), 'segment_bar');
      expect(bar['field'], 'ascent_rate');
      expect(bar['segments'], 5);
      expect(
        _designer.elementNativeBounds(
          {...bar, 'rel_x': 0.0, 'rel_y': 0.0},
          200,
          200,
        ),
        (0.0, 0.0, 12.0, 60.0),
      );
      final parsed = parseLayoutElements({
        'linked_elements': [
          {'type': 'arc', 'rel_x': 0.1, 'rel_y': 0.1},
          {'type': 'segment_bar', 'rel_x': 0.2, 'rel_y': 0.2},
        ],
      });
      expect(parsed[0]['field'], 'ndl');
      expect(parsed[0]['sweep'], 270);
      expect(parsed[1]['field'], 'ascent_rate');
      expect(parsed[1]['range_max'], 10);
    });
  });
}
