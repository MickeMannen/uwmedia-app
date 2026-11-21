// The Overlay Designer's geometry against the Python app: the cases of its
// tests/test_hud_designer.py and tests/test_hud_designer_math.py, then the
// parity fixture made by tool/python_reference/designer_fixture.py (every
// bundled page and changed copies of a third of them, in several
// situations, with Pillow's text measurements replayed).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/hud/dummy_telemetry.dart';
import 'package:uwmedia_app/core/hud/hud_designer.dart';
import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/hud_text.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/units/units.dart';

import '../../helpers/python_reference.dart';
import '../../helpers/renderer_reference.dart';

const _templates = 'assets/overlays/templates';

Map<String, dynamic> _copy(Map<String, dynamic> map) =>
    jsonDecode(jsonEncode(map)) as Map<String, dynamic>;

List<double> _list((num, num, num, num) box) => [
  box.$1.toDouble(),
  box.$2.toDouble(),
  box.$3.toDouble(),
  box.$4.toDouble(),
];

Matcher _near(Object? want, [double within = 1e-9]) => want is List
    ? pairwiseCompare<dynamic, dynamic>(
        want,
        (w, got) => ((w as num) - (got as num)).abs() <= within,
        'within $within of',
      )
    : equals(want);

List<BadgeLine>? _lines(Object? lines) => lines == null
    ? null
    : [
        for (final line in (lines as List<dynamic>).cast<List<dynamic>>())
          (line[0] as String, (0, 0, 0), line[2] as bool),
      ];

void main() {
  final reference = jsonDecode(
    utf8.decode(
      gzip.decode(
        File(
          'test/fixtures/python_reference/hud_designer/'
          'designer_cases.json.gz',
        ).readAsBytesSync(),
      ),
    ),
  ) as Map<String, dynamic>;
  final rules = HudRules(
    jsonDecode(File('assets/hud_rules.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  final replay = HudDesigner(
    HudRenderer(
      ReplayFonts(
        reference['measures'] as Map<String, dynamic>,
        glyphs: reference['glyphs'] as Map<String, dynamic>? ?? const {},
      ),
      rules,
    ),
  );
  final own = HudDesigner(
    HudRenderer(
      TtfFonts(
        (file) => File('assets/fonts/$file').readAsBytesSync(),
        inkTables: InkTables.parse(
          File('assets/fonts/ink_tables.bin').readAsBytesSync(),
        ),
      ),
      rules,
    ),
  );

  group('tests/test_hud_designer.py and test_hud_designer_math.py', () {
    const viewW = 1920.0;
    const viewH = 1080.0;
    const skinW = 400.0;
    const skinH = 200.0;

    test('test_resolve_anchor_position_per_anchor', () {
      expect(
        resolveAnchorPosition(
          'TOP_LEFT',
          10.0,
          20.0,
          viewW,
          viewH,
          skinW,
          skinH,
        ),
        (10.0, 20.0),
      );
      expect(
        resolveAnchorPosition('CENTER', 10.0, 20.0, viewW, viewH, skinW, skinH),
        (viewW / 2 + 10 - skinW / 2, 20.0),
      );
      expect(
        resolveAnchorPosition(
          'BOTTOM_RIGHT',
          10.0,
          20.0,
          viewW,
          viewH,
          skinW,
          skinH,
        ),
        (viewW + 10 - skinW, viewH + 20 - skinH),
      );
      expect(
        resolveAnchorPosition(
          'MIDDLE_LEFT',
          10.0,
          20.0,
          viewW,
          viewH,
          skinW,
          skinH,
        ),
        (10.0, viewH / 2 + 20 - skinH / 2),
      );
    });

    test('test_resolve_skin_position_uses_anchor_offset_or_legacy_percent', () {
      expect(
        resolveSkinPosition(
          {
            'anchor': 'BOTTOM_RIGHT',
            'ref_offset_x': -5.0,
            'ref_offset_y': -7.0,
          },
          skinW,
          skinH,
          viewW,
          viewH,
        ),
        (viewW - 5 - skinW, viewH - 7 - skinH),
      );
      // anchor defaults to TOP_LEFT
      expect(
        resolveSkinPosition(
          {'ref_offset_x': 3, 'ref_offset_y': 4},
          skinW,
          skinH,
          viewW,
          viewH,
        ),
        (3.0, 4.0),
      );
      // only one offset present: the older percentages
      expect(
        resolveSkinPosition(
          {'ref_offset_x': 3, 'x_pct': 0.25, 'y_pct': 0.5},
          skinW,
          skinH,
          viewW,
          viewH,
        ),
        (480.0, 540.0),
      );
      expect(resolveSkinPosition({}, skinW, skinH, viewW, viewH), (0.0, 0.0));
    });

    test('test_skin_pixel_size_for_shape_and_image', () {
      expect(skinPixelSize({'type': 'shape'}), (400.0, 200.0));
      expect(skinPixelSize({'type': 'shape', 'width': 50, 'height': 60}), (
        50.0,
        60.0,
      ));
      expect(
        skinPixelSize({'native_width': 100, 'native_height': 40, 'scale': 1.5}),
        (150.0, 60.0),
      );
      expect(skinPixelSize({'native_width': null, 'native_height': null}), (
        0.0,
        0.0,
      ));
    });

    test('test_parse_layout_elements_fills_missing_fields_per_kind', () {
      final parsed = parseLayoutElements({
        'linked_elements': [
          for (final type in [
            'graph',
            'badge',
            'tank_icon',
            'tissue_bar',
            'ascent_chevrons',
          ])
            {'type': type, 'rel_x': 0, 'rel_y': 0},
          {'rel_x': 0.3, 'rel_y': 0.4},
        ],
      });
      final [graph, badge, tank, tissue, chevrons, text] = parsed;
      expect(graph['field'], 'depth_graph');
      expect(graph['marker_size'], 6);
      expect(badge['field'], 'state_badge');
      expect(tank['field'], 'primary_tank_pressure');
      expect(tank['corner_radius'], 4);
      expect(tissue['field'], 'n2_tissue_load');
      expect(tissue['height'], 33);
      expect(chevrons['field'], 'ascent_rate');
      expect(chevrons['down_count'], 1);
      expect(text['field'], '');
      expect(text['color'], '#FFFFFF');
      expect(parseLayoutElements({}), isEmpty);
      expect(
        () => parseLayoutElements({
          'linked_elements': [
            {'field': 'depth'},
          ],
        }),
        throwsArgumentError,
      );
    });

    test('test_element_defaults_per_kind_are_centred_and_renderable', () {
      for (final kind in ['text', 'badge', 'tank_icon', 'graph']) {
        final elem = elementDefaults(kind, 'depth');
        expect((elem['rel_x'], elem['rel_y']), (0.5, 0.5));
        expect(elementKind(elem), kind);
      }
      expect(elementDefaults('text', 'depth').containsKey('type'), isFalse);
      expect(
        elementDefaults('graph', 'depth_graph')['ceiling_color'],
        '#808080',
      );
      final tissue = elementDefaults('tissue_bar', 'depth');
      expect(
        (tissue['field'], tissue['type']),
        ('n2_tissue_load', 'tissue_bar'),
      );
      final chevrons = elementDefaults('ascent_chevrons', 'depth');
      expect((chevrons['field'], chevrons['up_count']), ('ascent_rate', 4));
      expect(elementKind({'type': 'unknown'}), 'text');
    });

    test('test_available_telemetry_fields_without_and_with_dive', () {
      final base = availableTelemetryFields();
      expect(base, [...base]..sort());
      expect(base, isNot(contains('tanks')));
      expect(
        base,
        containsAll([
          'depth',
          'gasmix',
          'time_of_day',
          'primary_tank_pressure',
        ]),
      );
      final fields = availableTelemetryFields(
        buildDummyDive(variant: 'sidemount'),
      );
      expect(fields.sublist(0, base.length), base);
      expect(fields.sublist(base.length), [
        'tank_pressure:Left',
        'tank_name:Left',
        'tank_pressure:Right',
        'tank_name:Right',
      ]);
    });

    test('test_hit_test_bounds_topmost_with_slack', () {
      const bounds = <(num, num, num, num)>[
        (0, 0, 100, 100),
        (50, 50, 150, 150),
      ];
      expect(hitTestBounds(75, 75, bounds), 1); // later-drawn wins
      expect(hitTestBounds(10, 10, bounds), 0);
      expect(hitTestBounds(151, 151, bounds), 1);
      expect(hitTestBounds(160, 160, bounds), isNull);
      expect(hitTestBounds(10, 10, []), isNull);
    });

    test('test_text_bounds_follow_align_and_font_size', () {
      final elem = {
        'field': 'depth',
        'rel_x': 0.5,
        'rel_y': 0.5,
        'font_size': 60,
        'scale': 1.0,
      };
      final (x0, y0, x1, y1) = own.elementNativeBounds(
        elem,
        400,
        200,
        text: '24.0',
      );
      final (left, top, right, bottom) = own.renderer.fonts
          .get(60)
          .getbbox('24.0');
      expect(
        (x0, y0, x1, y1),
        (200.0 + left, 100.0 + top, 200.0 + right, 100.0 + bottom),
      );

      final (rx0, ry0, rx1, ry1) = own.elementNativeBounds(
        {...elem, 'align': 'right', 'valign': 'bottom'},
        400,
        200,
        text: '24.0',
      );
      // the ink's right and bottom edges are on the anchor
      expect(rx1, closeTo(200, 0.01));
      expect(ry1, closeTo(100, 0.01));
      expect((rx1 - rx0, ry1 - ry0), (x1 - x0, y1 - y0)); // same size

      final (sx0, _, sx1, _) = own.elementNativeBounds(
        {...elem, 'scale': 2.0},
        400,
        200,
        text: '24.0',
      );
      expect(sx1 - sx0, greaterThan(x1 - x0));
    });

    test('test_badge_bounds_use_lines_and_fall_back_to_placeholder', () {
      final elem = {
        'field': 'state_badge',
        'type': 'badge',
        'rel_x': 0.0,
        'rel_y': 0.0,
        'font_size': 20,
        'value_font_size': 40,
      };
      const red = (255, 0, 0);
      final (x0, y0, x1, y1) = own.elementNativeBounds(
        elem,
        500,
        500,
        badgeLines: [
          ('DECO', red, false),
          ('↑6', red, true),
          ('03:00', red, true),
        ],
      );
      expect(y0, 0.0);
      expect(y1, 24 + 2 * 48);
      expect(x1, greaterThan(x0));
      expect(x0, greaterThan(-5));
      // no lines: the placeholder label
      final (px0, py0, px1, py1) = own.elementNativeBounds(elem, 500, 500);
      expect(py1 - py0, 24);
      expect(px1, greaterThan(px0));
    });

    test('test_measure_element_box_uses_given_text', () {
      final elem = {'field': 'depth', 'font_size': 40, 'scale': 1.0};
      final (shortW, _) = own.measureElementBox(elem, {
        'type': 'shape',
      }, text: '1');
      final (longW, _) = own.measureElementBox(elem, {
        'type': 'shape',
      }, text: '123.4');
      expect(longW, greaterThan(shortW));
      expect(own.measureElementBox({'type': 'graph', 'field': 'x'}, {}), (
        300.0,
        150.0,
      ));
    });

    test('test_align_elements_noops', () {
      final elements = [
        {'field': 'depth', 'rel_x': 0.1, 'rel_y': 0.2},
        {'field': 'ndl', 'rel_x': 0.3, 'rel_y': 0.4},
      ];
      final before = _copy({'e': elements});
      // one element, or a skin without a size
      own.alignElements(elements, [0], {'type': 'shape'}, 'h_top');
      own.alignElements(elements, [0, 1], {'native_width': 0}, 'h_top');
      expect({'e': elements}, before);
      own.alignElements(elements, [0, 1], {'type': 'shape'}, 'h_top');
      expect(elements[1]['rel_y'], 0.2);
    });
  });

  group('parity with Python', () {
    test('anchors, skin positions and sizes', () {
      final geometry = reference['geometry'] as Map<String, dynamic>;
      for (final [anchor, rx, ry, vw, vh, sw, sh, want]
          in (geometry['anchors'] as List<dynamic>).cast<List<dynamic>>()) {
        final (x, y) = resolveAnchorPosition(
          anchor as String,
          rx as num,
          ry as num,
          vw as num,
          vh as num,
          sw as num,
          sh as num,
        );
        expect([x, y], want, reason: anchor);
      }
      for (final [skin, want]
          in (geometry['skin_positions'] as List<dynamic>)
              .cast<List<dynamic>>()) {
        final (x, y) = resolveSkinPosition(
          skin as Map<String, dynamic>,
          400.0,
          200.0,
          1920,
          1080,
        );
        expect([x, y], want, reason: '$skin');
      }
      for (final [skin, want]
          in (geometry['skin_sizes'] as List<dynamic>).cast<List<dynamic>>()) {
        final (w, h) = skinPixelSize(skin as Map<String, dynamic>);
        expect([w, h], want, reason: '$skin');
      }
    });

    test('kinds, defaults, parsing, names and fields', () {
      final e = reference['elements'] as Map<String, dynamic>;
      expect(anchors, e['anchors']);
      expect(markerStyles, e['marker_styles']);
      expect(elementKinds, e['element_kinds']);
      for (final [elem, kind]
          in (e['kinds'] as List<dynamic>).cast<List<dynamic>>()) {
        expect(
          elementKind(elem as Map<String, dynamic>),
          kind,
          reason: '$elem',
        );
      }
      for (final [kind, field, want]
          in (e['defaults'] as List<dynamic>).cast<List<dynamic>>()) {
        expect(elementDefaults(kind as String, field as String), want);
      }
      for (final [skin, want]
          in (e['parse'] as List<dynamic>).cast<List<dynamic>>()) {
        expect(parseLayoutElements(skin as Map<String, dynamic>), want);
      }
      for (final [name, want]
          in (e['names'] as List<dynamic>).cast<List<dynamic>>()) {
        expect(elementDisplayName(name as String), want);
      }
      expect(availableTelemetryFields(), e['fields']);
      expect(availableTelemetryFields(buildDummyDive()), e['fields_single']);
      expect(
        availableTelemetryFields(buildDummyDive(variant: 'sidemount')),
        e['fields_sidemount'],
      );
      expect(
        availableTelemetryFields(buildDummyDive(ccr: true)),
        e['fields_ccr'],
      );
    });

    test('hit testing', () {
      final hit = reference['hit'] as Map<String, dynamic>;
      final bounds = [
        for (final b in (hit['bounds'] as List<dynamic>).cast<List<dynamic>>())
          (b[0] as num, b[1] as num, b[2] as num, b[3] as num),
      ];
      for (final [x, y, slack, want]
          in (hit['hits'] as List<dynamic>).cast<List<dynamic>>()) {
        expect(
          hitTestBounds(
            x as num,
            y as num,
            x == 10 && y == 10 && want == null ? [] : bounds,
            slack: slack as num,
          ),
          want,
          reason: '$x, $y slack $slack',
        );
      }
    });

    test('every bundled page: elements, bounds, boxes and alignment', () {
      final pages = jsonObjects(reference['pages']);
      expect(pages.length, 232);
      var boxes = 0;
      var offByOne = 0;
      for (final page in pages) {
        final [brand, computer, id, variant] = page['page'] as List<dynamic>;
        final reason = '$brand/$computer/$id/$variant ${page['changed']}';
        var layout = page['layout'] as Map<String, dynamic>?;
        if (layout == null) {
          final path = [
            _templates,
            brand,
            computer,
            id,
            ?variant,
            'normal.json',
          ].join('/');
          layout = asPython(
            [brand, computer, id, ?variant].join('/'),
            stripVariantMarkers(
              loadLayoutFile(path, (file) => File(file).readAsStringSync()),
            ),
          );
        }
        final skin = layout['hud_skin'] as Map<String, dynamic>;
        final elements = parseLayoutElements(skin);
        expect(elements, page['elements'], reason: reason);
        final [w as num, h as num] = page['size'] as List<dynamic>;

        (page['bounds'] as Map<String, dynamic>).forEach((situation, wanted) {
          final units = situation.endsWith('imperial')
              ? UnitSystem.imperial
              : UnitSystem.metric;
          for (final (i, want) in jsonObjects(wanted).indexed) {
            final at =
                '$reason, $situation, element $i (${elements[i]['field']})';
            final text = want['text'] as String?;
            final lines = _lines(want['lines']);
            final bounds = replay.elementNativeBounds(
              elements[i],
              w,
              h,
              text: text,
              badgeLines: lines,
              units: units,
            );
            expect(_list(bounds), _near(want['bounds']), reason: at);
            final (bw, bh) = replay.measureElementBox(
              elements[i],
              skin,
              text: text,
            );
            expect([bw, bh], want['box'], reason: 'box, $at');
            boxes++;

            // The port's own font reader: the same, but for a pixel at
            // the sides in the fonts without hinting instructions.
            final mine = own.elementNativeBounds(
              elements[i],
              w,
              h,
              text: text,
              badgeLines: lines,
              units: units,
            );
            expect(_list(mine), _near(want['bounds'], 1.0), reason: 'own, $at');
            if (_list(mine).toString() != _list(bounds).toString()) {
              offByOne++;
            }
          }
        });

        for (final [indices, mode, want]
            in (page['align'] as List<dynamic>? ?? const [])
                .cast<List<dynamic>>()) {
          final copy = parseLayoutElements(_copy(skin));
          replay.alignElements(
            copy,
            (indices as List<dynamic>).cast<int>(),
            skin,
            mode as String,
          );
          final got = [
            for (final e in copy) ...[e['rel_x'] as num, e['rel_y'] as num],
          ];
          final flat = [
            for (final pair in (want as List<dynamic>).cast<List<dynamic>>())
              ...pair,
          ];
          expect(
            got,
            _near(flat, 1e-12),
            reason: '$reason align $mode $indices',
          );
        }
      }
      expect(boxes, greaterThan(9000));
      // How often the port's own measuring differs at all.
      expect(offByOne / boxes, lessThan(0.02));
    });

    test('elements the bundled pages do not have', () {
      final cases = jsonObjects(reference['odd']);
      expect(cases.length, 292);
      final skins = jsonObjects(reference['skins']);
      for (final c in cases) {
        final elem = c['elem'] as Map<String, dynamic>;
        final units = c['units'] == 'imperial'
            ? UnitSystem.imperial
            : UnitSystem.metric;
        final text = c['text'] as String?;
        final reason = '$elem "$text" ${c['lines']} ${c['units']}';
        expect(
          _list(
            replay.elementNativeBounds(
              elem,
              400,
              200,
              text: text,
              badgeLines: _lines(c['lines']),
              units: units,
            ),
          ),
          _near(c['bounds']),
          reason: reason,
        );
        for (final (i, want) in (c['boxes'] as List<dynamic>).indexed) {
          if (want is String) {
            // Python: KeyError, no field to name the element by.
            expect(
              () => replay.measureElementBox(elem, skins[i], text: text),
              throwsArgumentError,
              reason: reason,
            );
          } else {
            final (w, h) = replay.measureElementBox(elem, skins[i], text: text);
            expect([w, h], want, reason: 'box in ${skins[i]}, $reason');
          }
        }
      }
    });
  });
}
