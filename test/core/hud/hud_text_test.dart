// What the overlay elements say, against the Python app: the cases of its
// tests/test_hud_renderer.py (and tests/test_fonts.py) that need no pixels.
// The drawing itself is compared in hud_renderer_parity_test.dart.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/hud/dummy_telemetry.dart';
import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/hud_geometry.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/hud_text.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

import '../../helpers/renderer_reference.dart';

final HudRules rules = HudRules(
  jsonDecode(File('assets/hud_rules.json').readAsStringSync())
      as Map<String, dynamic>,
);
final _start = naive(2026, 1, 1, 10);

HudContext _ctx(String brand, String? model, [UnitSystem? units]) =>
    HudContext(rules, brand, model, units ?? UnitSystem.metric);

Waypoint _wp({
  int t = 0,
  double? depth,
  double maxDepth = 0.0,
  double? decoStopDepth,
  double? nextStopDepth,
  int? nextStopTime,
  double? ceiling,
  int? ndl,
  int? diveTime,
  List<String>? diveAlerts,
  Map<String, TankData>? tanks,
  DateTime? timestamp,
}) => Waypoint(
  timestamp: timestamp ?? _start.add(Duration(seconds: t)),
  timeSinceStart: t,
  diveTime: diveTime,
  depth: depth,
  maxDepth: maxDepth,
  decoStopDepth: decoStopDepth,
  nextStopDepth: nextStopDepth,
  nextStopTime: nextStopTime,
  ceiling: ceiling,
  ndl: ndl,
  diveAlerts: diveAlerts,
  tanks: tanks,
);

const _badge = <String, dynamic>{
  'field': 'state_badge',
  'type': 'badge',
  'rel_x': 0,
  'rel_y': 0,
};
const _badgeM = <String, dynamic>{..._badge, 'depth_unit': 'm'};

List<String> _texts(List<BadgeLine>? lines) => [for (final l in lines!) l.$1];

void main() {
  group('tests/test_hud_renderer.py', () {
    test('test_resolve_element_text_matches_renderer_paths', () {
      final ctx = _ctx('Garmin', 'x50i');
      final wp = _wp(
        timestamp: naive(2026, 1, 1, 14, 5),
        depth: 12.34,
        tanks: {'T1': TankData(pressureBar: 150.4, name: 'Left')},
      );
      expect(resolveElementText(ctx, 'depth', wp), ('12.3', 12.34));
      expect(resolveElementText(ctx, 'custom:BAR', wp), ('BAR', null));
      expect(resolveElementText(ctx, 'time_of_day', wp), ('14:05', null));
      expect(resolveElementText(ctx, 'tank_pressure:T1', wp), ('150', 150.4));
      expect(resolveElementText(ctx, 'tank_name:T1', wp), ('Left', 'Left'));
      // No waypoint never raises.
      expect(resolveElementText(ctx, 'tank_pressure:T1', null).$1, '--');
      expect(resolveElementText(ctx, 'depth', null), ('--', null));
      expect(resolveElementText(ctx, 'time_of_day', null), (null, null));
    });

    test('test_badge_lines_none_for_normal_and_three_lines_for_deco', () {
      final perdix = _ctx('Shearwater', 'Perdix 2');
      expect(badgeLines(perdix, _badge, _wp(depth: 20.0)), isNull);
      expect(badgeLines(perdix, _badge, null), isNull);
      final deco = _wp(
        depth: 12.0,
        decoStopDepth: 6.0,
        nextStopDepth: 6.0,
        nextStopTime: 180,
      );
      // Perdix 2 manual p.28, p.33: "DECO STOP" in red, then "6m 3min" in
      // white on one line.
      final lines = badgeLines(perdix, _badgeM, deco)!;
      expect(_texts(lines), ['DECO STOP', '6m 3min']);
      expect([for (final l in lines) l.$3], [false, true]);
      expect([for (final l in lines) l.$2], [(255, 0, 0), (255, 255, 255)]);
      // Garmin keeps its three lines.
      expect(_texts(badgeLines(_ctx('Garmin', 'x50i'), _badge, deco)), [
        'DECO',
        '↑6',
        '03:00',
      ]);
    });

    test('test_rules_profile_borrows_another_brands_rules', () {
      expect(
        rulesManufacturer(const {
          'manufacturer': 'Custom',
          'rules_profile': 'Shearwater',
        }),
        'Shearwater',
      );
      expect(rulesManufacturer(const {'manufacturer': 'Garmin'}), 'Garmin');
      expect(rulesManufacturer(const {}), 'Shearwater');

      // The page draws the same with the borrowed rules as the brand's own
      // page, and differently without them.
      final renderer = HudRenderer(const FakeFonts(), rules);
      final deco = _wp(
        depth: 12.0,
        decoStopDepth: 6.0,
        nextStopDepth: 6.0,
        nextStopTime: 180,
      );
      String render(Map<String, dynamic> extra) {
        final layout = <String, dynamic>{
          'design_width': 1920,
          'design_height': 1080,
          'model': '',
          'hud_skin': {
            'type': 'shape',
            'width': 400,
            'height': 200,
            'anchor': 'TOP_LEFT',
            'opacity': 0.0,
            'linked_elements': [
              {
                'field': 'state_badge',
                'type': 'badge',
                'rel_x': 0.1,
                'rel_y': 0.1,
                'font_size': 30,
                'value_font_size': 60,
              },
            ],
          },
          ...extra,
        };
        return jsonEncode([
          for (final op in renderer.drawHud(
            frameWidth: 1920,
            frameHeight: 1080,
            layout: layout,
            waypoint: deco,
            renderLog: true,
          ))
            op.toJson(),
        ]);
      }

      final customDefault = render({'manufacturer': 'Custom'});
      final customShearwater = render({
        'manufacturer': 'Custom',
        'rules_profile': 'Shearwater',
      });
      expect(customShearwater, render({'manufacturer': 'Shearwater'}));
      expect(customDefault, isNot(customShearwater));
    });

    test('test_small_suffix_splits_and_renders_smaller_top_aligned_suffix', () {
      expect(splitSmallSuffix('12:34', 'seconds'), ('12', ':34'));
      expect(splitSmallSuffix('24.0', 'decimals'), ('24', '.0'));
      expect(splitSmallSuffix('24.0', 'seconds'), ('24.0', ''));
      expect(splitSmallSuffix('--', 'decimals'), ('--', ''));
      expect(splitSmallSuffix('', 'seconds'), ('', ''));
      expect(textParts('ndl', '99+', const {}), ('99', '+', 0.35));
      expect(
        textParts('dive_time', '12:34', const {
          'small_suffix': 'seconds',
          'small_suffix_scale': 0.33,
        }),
        ('12', ':34', 0.33),
      );
      expect(textParts('dive_time', '12:34', const {}), ('12:34', '', 0.35));
    });

    test('element defaults (test_*_defaults_and_bounds)', () {
      expect(tissueBarGeometry(const {}), (12, 33, 4));
      expect(ascentChevronGeometry(const {}), (16, 47, 4, 1));
      expect(tankSwitchArrowsGeometry(const {}), (23, 44, 13, 2));
      expect(tankOutlineMetrics(const {}), isNull);
      expect(tankOutlineMetrics(const {'draw_outline': true}), (4, 2, 6));
      expect(tankSegmentsGeometry(const {}), (5, 2, 200.0, 3, 2, 14, 5));
    });

    test('test_graph_stop_label_text', () {
      Waypoint wp(
        int t,
        double d, {
        double? stop,
        double? ceiling,
        int? stopTime,
        int? ndl,
      }) => _wp(
        t: t,
        depth: d,
        nextStopDepth: stop,
        ceiling: ceiling,
        nextStopTime: stopTime,
        ndl: ndl,
      );
      final wps = [
        wp(0, 0, ndl: 5940),
        wp(10, 20, ndl: 600),
        wp(20, 20, stop: 3.0, ceiling: 1.0, stopTime: 60),
        wp(30, 20, stop: 6.0, ceiling: 4.0, stopTime: 120),
      ];
      expect(stopDepthOf(wps[3]), 6.0);
      // Out of deco: nothing (no NDL in its place).
      expect(stopDepthOf(wps[1]), 0.0);
      // A stop depth is rounded up to a 3 m level.
      expect(stopDepthOf(_wp(depth: 10, decoStopDepth: 4.2)), 6.0);
    });

    test('test_perdix_badge_phases_from_the_manual', () {
      final perdix = _ctx('Shearwater', 'Perdix 2');
      Waypoint deco(double depth) => _wp(
        depth: depth,
        diveTime: 0,
        decoStopDepth: 6.0,
        nextStopDepth: 6.0,
        nextStopTime: 120,
      );
      final atStop = badgeLines(perdix, _badgeM, deco(6.8))!;
      // A green title at the stop (p.28), the check mark in front of the
      // time.
      expect(atStop[0], ('DECO STOP', (0, 200, 0), false));
      expect(atStop[1].$1, '6m✓ 2min');
      // No arrow far from the stop.
      expect(badgeLines(perdix, _badgeM, deco(20.0))![1].$1, '6m 2min');
      // The "Descend to Deco Stop" figure.
      expect(badgeLines(perdix, _badgeM, deco(5.0))![1].$1, '6m↓ 2min');
      // Yellow while approaching.
      expect(badgeLines(perdix, _badgeM, deco(9.0))![0].$2, (255, 255, 0));
      // The safety stop shows its planned time with no depth line; the
      // Garmin box keeps its ↑5m.
      final counting = _wp(
        depth: 5.0,
        maxDepth: 20.0,
        diveTime: 0,
        diveAlerts: ['safety_stop_started'],
        nextStopDepth: 5.0,
        nextStopTime: 150,
      );
      final sw = badgeLines(perdix, _badgeM, counting)!;
      expect(_texts(sw), ['SAFETY STOP', '✓ 2:30']);
      expect(sw[1].$2, (255, 255, 255));
      // p.27: "the display changes to Complete".
      final reference = RendererReference.load();
      final (done, history) = reference.situation(
        reference.cases.firstWhere((c) => c['situation'] == 'safety_done'),
      );
      final complete = badgeLines(perdix, _badgeM, done, history)!;
      expect(_texts(complete), ['SAFETY STOP', 'Complete']);
      expect([for (final l in complete) l.$2], [(0, 173, 237), (0, 200, 0)]);
      expect(_texts(badgeLines(_ctx('Garmin', 'x50i'), _badgeM, counting)), [
        'STOP',
        '↑5m',
        '02:30',
      ]);
      final cleared = _wp(
        depth: 4.5,
        diveTime: 0,
        decoStopDepth: 0.0,
        nextStopDepth: 0.0,
        nextStopTime: 0,
        diveAlerts: ['deco_stop_cleared'],
      );
      expect(_texts(badgeLines(perdix, _badgeM, cleared)), ['CLEAR', '0:00']);
    });

    test('test_sac_formats_like_the_perdix', () {
      const m = UnitSystem.metric;
      expect(formatTelemetryValue('pressure_sac', null, m), 'wait');
      expect(formatTelemetryValue('pressure_sac', 1.06, m), '1.1');
    });

    test('test_teric_badge_lines_follow_its_manual', () {
      final counting = _wp(
        depth: 5.0,
        maxDepth: 20.0,
        diveTime: 0,
        diveAlerts: ['safety_stop_started'],
        nextStopDepth: 5.0,
        nextStopTime: 202,
      );
      expect(badgeLines(_ctx('Shearwater', 'Teric'), _badgeM, counting), [
        ('SAFETY', (0, 200, 0), false),
        ('3:22', (0, 200, 0), true),
      ]);
      final deco = _wp(
        depth: 20.0,
        diveTime: 0,
        decoStopDepth: 15.0,
        nextStopDepth: 15.0,
        nextStopTime: 120,
      );
      expect(badgeLines(_ctx('Shearwater', 'Tern'), _badgeM, deco), [
        ('DECO', (255, 0, 0), false),
        ('15m↑ 2min', (255, 255, 255), true),
      ]);
    });

    test('test_perdix_3_badge_lines_and_boxed_title', () {
      final perdix3 = _ctx('Shearwater', 'Perdix 3');
      final counting = _wp(
        depth: 5.0,
        maxDepth: 20.0,
        diveTime: 0,
        diveAlerts: ['safety_stop_started'],
        nextStopDepth: 5.0,
        nextStopTime: 202,
      );
      expect(badgeLines(perdix3, _badgeM, counting), [
        ('SAFETY', (0, 200, 0), false),
        ('3:22', (0, 200, 0), true),
      ]);
      final deco = _wp(
        depth: 23.6,
        diveTime: 0,
        decoStopDepth: 18.0,
        nextStopDepth: 18.0,
        nextStopTime: 60,
      );
      expect(badgeLines(perdix3, _badgeM, deco), [
        ('DECO', (0, 173, 237), false),
        ('18m 1min', (255, 255, 255), true),
      ]);
    });

    test('test_shearwater_ascent_arrows_follow_the_perdix_manual', () {
      // Perdix 2 manual p.12: 1 arrow per 3 m/min.
      expect(ascentLitCount(2.0, 6, 3.0), 1);
      expect(ascentLitCount(3.0, 6, 3.0), 1);
      expect(ascentLitCount(8.0, 6, 3.0), 3);
      expect(ascentLitCount(10.0, 6, 3.0), 4);
      expect(ascentLitCount(25.0, 6, 3.0), 6);
    });

    test('test_ndl_shows_the_last_minute_as_00_and_99_plus_only_above_99_'
        'minutes', () {
      const m = UnitSystem.metric;
      // 4 s left before deco: not a red "99+".
      expect(formatTelemetryValue('ndl', 4, m), '00');
      expect(formatTelemetryValue('ndl', 0, m), '00');
      expect(formatTelemetryValue('ndl', 5 * 60 + 30, m), '05');
      expect(formatTelemetryValue('ndl', 100 * 60, m), '99+');
    });

    // Mk3 manual p.35: "Decompression Cleared - the current depth and stop
    // depth flash red". The log's stop fields are already zero at that
    // sample, so the badge takes the depth of the stop it just cleared.
    test('test_garmin_clear_badge_keeps_the_cleared_stops_depth_and_flashes_'
        'it', () {
      final history = [
        for (var t = 0; t < 10; t++)
          _wp(
            t: t,
            depth: 6.0,
            diveTime: t,
            decoStopDepth: 6.0,
            nextStopDepth: 6.0,
            nextStopTime: 10 - t,
          ),
        _wp(
          t: 10,
          depth: 6.0,
          diveTime: 10,
          decoStopDepth: 0.0,
          nextStopDepth: 0.0,
          nextStopTime: 0,
          diveAlerts: ['deco_stop_cleared'],
        ),
      ];
      final cleared = history.last;
      expect(rules.stopPhase('Garmin', 'mk3i', cleared, history), (
        'clear',
        'clear',
        0,
        6.0,
      ));
      const elem = <String, dynamic>{
        'field': 'state_badge',
        'type': 'badge',
        'depth_font': 'label',
        'depth_unit': 'm',
        'timer_format': 'm:ss',
      };
      final lines = badgeLines(_ctx('Garmin', 'mk3i'), elem, cleared, history)!;
      expect(_texts(lines), ['↑6m', '0:00']);
      // The depth line flashes red.
      expect(lines[0].$2, (255, 0, 0));
    });

    test('imperial badges and labels read feet', () {
      final deco = _wp(
        depth: 12.0,
        decoStopDepth: 6.0,
        nextStopDepth: 6.0,
        nextStopTime: 180,
      );
      expect(
        _texts(
          badgeLines(
            _ctx('Shearwater', 'Perdix 2', UnitSystem.imperial),
            _badgeM,
            deco,
          ),
        ),
        ['DECO STOP', '20ft 3min'],
      );
    });
  });

  group('tests/test_hud_renderer.py, Python 0.8.1 and after', () {
    final fonts = TtfFonts(
      (file) => File('assets/fonts/$file').readAsBytesSync(),
      inkTables: InkTables.parse(
        File('assets/fonts/ink_tables.bin').readAsBytesSync(),
      ),
    );
    final renderer = HudRenderer(fonts, rules);

    // The pixel part (line_spacing moves the value up) is in
    // test/hud/hud_renderer_pixels_test.dart.
    test('test_badge_line_spacing_max_width_and_mid_line_check_mark', () {
      // A Peregrine badge: `max_width` shrinks only a line too wide for it
      // (a deco stop's "6m✓ 2min", not the "3:00" timer), and the span
      // counts a check mark inside the line.
      final elem = <String, dynamic>{
        'font_family': 'Roboto Condensed',
        'max_width': 200,
      };
      expect(fittedBadgeLineSize(fonts, elem, '3:00', 100), 100);
      expect(fittedBadgeLineSize(fonts, elem, '6m✓ 2min', 100), lessThan(100));
      expect(fittedBadgeLineSize(fonts, {}, '6m✓ 2min', 100), 100);
      final font = fonts.get(40);
      final plain = badgeTitleInkSpan(fonts, font, '6m 2min', 40);
      final checked = badgeTitleInkSpan(fonts, font, '6m✓ 2min', 40);
      expect(checked.$2 - checked.$1, greaterThan(plain.$2 - plain.$1 + 30));
    });

    test('test_badge_arrow_falls_back_to_a_font_that_has_it', () {
      // Roboto Condensed has no ↑ / ↓: a deco stop's marker is drawn in
      // Roboto.
      final condensed = fonts.get(40, 'Roboto Condensed');
      final runs = badgeFontRuns(fonts, '6m↓ 3min', condensed, 40, null);
      expect([for (final r in runs) r.$1], ['6m', '↓', ' 3min']);
      expect(runs[1].$2.file, isNot(condensed.file));
      expect(runs[1].$2.file, fontFile('Roboto', null));
      expect(runs[0].$2.file, condensed.file);
      final roboto = fonts.get(40, 'Roboto');
      final whole = badgeFontRuns(fonts, '6m↓ 3min', roboto, 40, null);
      expect(whole, hasLength(1));
      expect(whole.single.$1, '6m↓ 3min');
      expect(whole.single.$2, same(roboto));
      expect(whole.single.$3, isFalse);
    });

    test('test_badge_units_draw_small_after_numbers_only', () {
      // `unit_scale` on a badge: "6m 2min" with small m / min (Peregrine
      // p.12, Teric p.11); a word like CLEAR or a timer "3:00" is left
      // alone.
      final font = fonts.get(60, 'Roboto Condensed');
      final runs = badgeFontRuns(fonts, '6m✓ 2min', font, 60, null, 0.5);
      expect(
        [for (final r in runs) (r.$1, r.$3)],
        [('6', false), ('m', true), ('✓ 2', false), ('min', true)],
      );
      expect(runs[1].$2.size, 30);
      expect(
        [
          for (final r in badgeFontRuns(
            fonts,
            '20ft↓ 3min',
            font,
            60,
            null,
            0.5,
          ))
            r.$1,
        ],
        ['20', 'ft', '↓', ' 3', 'min'],
      );
      expect(
        badgeFontRuns(
          fonts,
          'CLEAR 3:00',
          font,
          60,
          null,
          0.5,
        ).every((r) => !r.$3),
        isTrue,
      );
      final full = badgeTitleInkSpan(fonts, font, '6m 2min', 60);
      final small = badgeTitleInkSpan(fonts, font, '6m 2min', 60, 0.5);
      expect(small.$2 - small.$1, lessThan(full.$2 - full.$1));
    });

    test(
      'test_align_unit_puts_a_trailing_unit_inside_the_right_aligned_run',
      () {
        final font = fonts.get(80, 'Roboto Condensed');
        final elem = <String, dynamic>{
          'align_unit': true,
          'unit_suffix': true,
          'unit_scale': 0.33,
        };
        double shift(Map<String, dynamic> e, String unit, String align) =>
            renderer.unitAlignShift(
              e,
              font,
              '45',
              '',
              null,
              80,
              unit,
              align,
              1.0,
            );
        // The run moves left by the gap plus the unit's width (the element
        // names no font, so the unit is measured in the default one).
        final unitW = fonts
            .get((80 * 0.33).truncate(), null, null)
            .getlength('ft');
        expect(
          shift(elem, 'ft', 'right'),
          closeTo(-((80 * 0.08).truncate() + unitW), 1e-9),
        );
        expect(shift(elem, 'ft', 'center'), shift(elem, 'ft', 'right') / 2);
        expect(shift({}, 'ft', 'right'), 0.0);
        expect(shift(elem, '', 'right'), 0.0);
      },
    );

    test('test_stacked_unit_spanning_the_digits_runs_from_their_top_to_the_baseline', () {
      // A Shearwater's B/A/R beside the tank pressure (Perdix 2 manual
      // p.40).
      final font = fonts.get(128, 'Roboto Condensed');
      final elem = <String, dynamic>{
        'unit_orientation': 'stacked',
        'unit_span': 'digits',
        'font_family': 'Roboto Condensed',
      };
      final (x, y, unitFont, unitSize) = renderer.unitSuffixGeometry(
        elem,
        font,
        '157',
        128,
        200.0,
        null,
        1.0,
        'BAR',
      );
      final (_, digitTop, _, digitBottom) = font.getbbox('0');
      expect(y, digitTop);
      expect(x, greaterThan(200));
      final r = unitFont.getbbox('R');
      final lettersBottom =
          y + 2 * (unitSize * stackedLineAdvance).truncate() + r.$4 - r.$2;
      expect((lettersBottom - digitBottom).abs(), lessThanOrEqualTo(3));
      // Without the key the unit keeps its unit_scale size.
      final (_, _, _, plain) = renderer.unitSuffixGeometry(
        {'unit_orientation': 'stacked'},
        font,
        '157',
        128,
        200.0,
        null,
        1.0,
        'BAR',
      );
      expect(plain, (128 * 0.35).truncate());
    });

    test('test_ascent_rate_value_is_the_rate_in_the_units_in_force', () {
      // A Teric writes its ascent rate beside the arrows (manual p.12):
      // m/min or ft/min, 0 when not ascending.
      final dive = buildDummyDive(variant: 'single_tank');
      final (wp, history) = forcedDive(
        waypointAt(dive, 12 * 60),
        'fast_ascent',
      );
      final metric = _ctx('Shearwater', 'Teric');
      final (text, rate) = resolveElementText(
        metric,
        'ascent_rate_value',
        wp,
        history,
      );
      expect(rate! as double, greaterThan(9));
      expect(text, '${pyRound(rate as double)}');
      expect(
        resolveElementText(
          _ctx('Shearwater', 'Teric', UnitSystem.imperial),
          'ascent_rate_value',
          wp,
          history,
        ).$1,
        '${pyRound(rate / 0.3048)}',
      );
      final (level, levelHistory) = forcedDive(
        waypointAt(dive, 12 * 60),
        'normal',
      );
      expect(
        resolveElementText(metric, 'ascent_rate_value', level, levelHistory).$1,
        '0',
      );
      expect(resolveElementText(metric, 'ascent_rate_value', null).$1, '--');
    });

    test('gas_percent is a field the elements can show', () {
      // models/dive.py gas_percent, in the designer's field list
      // (utils/hud_designer.available_telemetry_fields) and read by
      // getattr() in the renderer.
      final wp = _wp(tanks: {'T1': TankData(pressureBar: 200, o2Percent: 32)});
      expect(
        resolveElementText(
          _ctx('Shearwater', 'Perdix 3'),
          'gas_percent',
          wp,
        ).$1,
        '32%',
      );
    });
  });

  group('tests/test_fonts.py', () {
    test('test_registry_lists_arial_first_then_bundled_families_with_both_'
        'weights', () {
      expect(listFontFamilies().first, defaultFontFamily);
      for (final family in const [
        'DejaVu Sans',
        'Liberation Sans',
        'Roboto',
        'Roboto Condensed',
        'Roboto Mono',
        'DSEG7 Classic',
      ]) {
        expect(fontRegistry[family]!.keys.toSet(), {'regular', 'bold'});
      }
      // Every file of the registry is bundled.
      for (final family in fontRegistry.values) {
        for (final file in family.values) {
          expect(File('assets/fonts/$file').existsSync(), isTrue, reason: file);
        }
      }
    });

    test('test_font_path_degrades_gracefully', () {
      final fallback = fontFile(defaultFontFamily, 'regular');
      expect(fontFile(null, null), fallback);
      expect(fontFile('', ''), fallback);
      expect(
        fontFile('No Such Family', 'bold'),
        fontFile(defaultFontFamily, 'bold'),
      );
      expect(fontFile('Roboto', 'weird-weight'), fontFile('Roboto', 'regular'));
      expect(fontFile('DSEG7 Classic', 'bold'), 'DSEG7Classic-Bold.ttf');
    });
  });
}
