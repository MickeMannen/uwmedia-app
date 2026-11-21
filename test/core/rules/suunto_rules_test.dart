// Suunto's rules in hud_rules.json (EON Core / EON Steel Black at the brand
// level, the Nautic as a model block): the rules-engine and notice cases of
// the Python app's tests/test_suunto_rules.py (0.8.0), one test per case.
// The renderer's texts are here too (the safety_stop_depth field, uppercase,
// the m'ss timer); its pixel cases (segment bars taking the brand's ascent
// bands, the baseline small suffix, the Nautic's horizontal tank bar and
// NDL "0′") are in test/hud/hud_renderer_pixels_test.dart.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/hud/hud_text.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/rules/hud_notices.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

final HudRules rules = HudRules(
  jsonDecode(File('assets/hud_rules.json').readAsStringSync())
      as Map<String, dynamic>,
);
final _start = naive(2026, 1, 1, 10);

/// The `_wp` of tests/test_suunto_rules.py. Python's `max_depth` keyword
/// (`max(depth, max_depth)`) is left out: no ported case passes one.
Waypoint _wp(
  int t,
  double depth, {
  double? po2,
  int? cns,
  double? nextStopDepth,
  double? decoStopDepth,
  double? ceiling,
  List<String>? diveAlerts,
  Map<String, TankData>? tanks,
}) => Waypoint(
  timestamp: _start.add(Duration(seconds: t)),
  timeSinceStart: t,
  diveTime: t,
  depth: depth,
  maxDepth: depth,
  po2: po2,
  cns: cns,
  nextStopDepth: nextStopDepth,
  decoStopDepth: decoStopDepth,
  ceiling: ceiling,
  diveAlerts: diveAlerts,
  tanks: tanks,
);

void main() {
  group('tests/test_suunto_rules.py', () {
    test('test_every_suunto_rule_and_notice_is_sourced', () {
      for (final model in ['EON Core', 'EON Steel Black', 'Nautic']) {
        final list = noticeRules(rules, 'Suunto', model);
        expect(list, isNotEmpty, reason: model);
        for (final rule in list) {
          expect(rule['_source'], isA<String>(), reason: '$model $rule');
          expect(rule['_source'], isNotEmpty, reason: '$model $rule');
        }
      }
    });

    test('test_eon_colours', () {
      String color(String model, String field, Object value, String base) =>
          rules.getDynamicColor('Suunto', model, field, value, base);
      expect(color('EON Core', 'ndl', 40 * 60, '#FFFFFF'), '#B1CB45');
      expect(color('EON Core', 'ndl', 6000, '#FFFFFF'), '#B1CB45');
      expect(color('EON Steel Black', 'po2', 1.7, '#FFFFFF'), '#FF0000');
      expect(color('EON Core', 'po2', 1.4, '#FFFFFF'), '#FFFFFF');
      // yellow below the diver's own alarm (70 bar assumed), red below the
      // built-in 50
      expect(rules.tankPressureState('Suunto', 'EON Core', 60), 'reserve');
      expect(rules.tankPressureState('Suunto', 'EON Core', 45), 'critical');
      expect(
        color('EON Core', 'primary_tank_pressure', 45, '#79C8DF'),
        '#FF0000',
      );
    });

    test('test_nautic_overrides', () {
      String color(String field, Object value) =>
          rules.getDynamicColor('Suunto', 'Nautic', field, value, '#FFFFFF');
      expect(color('ndl', 4 * 60), '#FEF01D');
      expect(color('ndl', 40 * 60), '#FFFFFF');
      expect(color('po2', 1.5), '#FEF01D');
      final gf =
          rules.getRuleConfig('Suunto', 'Nautic', 'gf_colors')!
              as Map<String, dynamic>;
      expect(gf['gf_high_default'], 85);
      expect(noticeStyle(rules, 'Suunto', 'Nautic')['style'], 'banner');
      expect(noticeStyle(rules, 'Suunto', 'EON Core')['style'], 'box');
    });

    test('test_safety_stop_counts_between_2_4_and_6_m', () {
      final wps = [
        _wp(0, 20.0),
        _wp(60, 12.0),
        _wp(70, 7.0),
        _wp(80, 5.0),
        _wp(140, 5.0),
        _wp(150, 7.5),
        _wp(160, 4.0),
        _wp(300, 4.0),
      ];
      final tl = rules.safetyStopTimeline('Suunto', 'EON Core', wps)!;
      // shown before it counts, deeper than 6 m
      expect(tl[70], ('pending', 180));
      // from t=70, the step in which it entered the window
      expect(tl[140], ('counting', 110));
      // deeper than 6 m: the timer stops
      expect(tl[150]!.$1, 'paused');
      expect(tl[300], ('complete', 0));
      expect(rules.safetyStopTimeline('Suunto', 'Nautic', wps)![140], (
        'counting',
        110,
      ));
    });

    test('test_deco_window_and_violation_follow_the_logged_ceiling', () {
      Waypoint at(double depth) =>
          _wp(0, depth, nextStopDepth: 6.3, decoStopDepth: 6.3, ceiling: 6.3);
      // inside the 3 m window
      expect(rules.decoStopPhase('Suunto', 'EON Core', at(8.0)), 'at_stop');
      // within the 0.6 m safe margin
      expect(rules.decoStopPhase('Suunto', 'EON Core', at(5.9)), 'at_stop');
      expect(rules.decoStopPhase('Suunto', 'EON Core', at(5.5)), 'violation');
    });

    test('test_notices', () {
      Notice? notice(String model, Waypoint wp) =>
          activeNotice(rules, 'Suunto', model, wp);
      final high = notice('EON Core', _wp(0, 30.0, po2: 1.7));
      expect(high, isNotNull);
      expect(high!.text, 'pO2 high');
      expect(high.color, '#FF0000');
      expect(notice('EON Core', _wp(0, 20.0, cns: 85))!.text, 'CNS 80%');
      final tank = notice(
        'EON Core',
        _wp(0, 20.0, tanks: {'T1': TankData(pressureBar: 40)}),
      );
      expect(tank!.text, 'Tank pressure');
      final gas = notice(
        'EON Core',
        _wp(0, 21.0, diveAlerts: ['suunto:Gas Available']),
      );
      expect(gas!.text, 'Change gas');
      expect(gas.color, '#FFFF00');
      expect(notice('Nautic', _wp(0, 30.0, po2: 1.7))!.text, 'PO2 HIGH');
      final switchGas = notice(
        'Nautic',
        _wp(0, 21.0, diveAlerts: ['suunto:Gas Switch']),
      );
      expect(switchGas!.text, 'SWITCH GAS');
      expect(switchGas.color, '#3FEBDF');
    });

    test('test_fast_ascent_needs_five_seconds', () {
      // 12 m/min from t=60
      final samples = [
        for (var t = 0; t < 90; t++)
          _wp(t, 30.0 - (t - 60 > 0 ? t - 60 : 0) * 0.2),
      ];
      final tl = noticeTimeline(rules, 'Suunto', 'EON Core', samples)!;
      expect(tl[62], isNull);
      expect(
        [for (var t = 64; t < 70; t++) tl[t]?.text].contains('Ascent speed'),
        isTrue,
      );
    });

    test('test_safety_stop_depth_field_follows_the_units', () {
      final wp = _wp(0, 5.0);
      expect(
        resolveElementText(
          HudContext(rules, 'Suunto', 'EON Core', UnitSystem.metric),
          'safety_stop_depth',
          wp,
        ),
        ('3.0', 3.0),
      );
      expect(
        resolveElementText(
          HudContext(rules, 'Suunto', 'EON Core', UnitSystem.imperial),
          'safety_stop_depth',
          wp,
        ).$1,
        '10',
      );
    });

    test('test_uppercase_baseline_suffix_and_prime_timer (texts; the '
        'baseline is in test/hud/hud_renderer_pixels_test.dart)', () {
      expect(
        applyValueFormat({'uppercase': true}, 'Nx32', null, UnitSystem.metric),
        'NX32',
      );
      expect(formatStopTimer(170, "m'ss"), '2′50');
    });

    test('test_page_badge_override_layers_over_the_brand', () {
      expect(
        rules.getBadgeConfig('Suunto', 'EON Core', 'safety_stop')!['label'],
        'SAFETY STOP',
      );
      final page = rules.withOverrides({
        'badge_states': {
          'safety_stop': {'label': '', 'timer_format': "m'ss"},
        },
      });
      final cfg = page.getBadgeConfig('Suunto', 'EON Core', 'safety_stop')!;
      expect(cfg['label'], '');
      expect(cfg['timer_format'], "m'ss");
      expect(cfg['color'], '#FFFF00');
    });

    test('test_horizontal_segment_bar_and_ndl_zero_in_the_page_format '
        '(the rules part)', () {
      // In deco the Nautic's NDL reads 0 in white; the drawing is the
      // renderer's.
      expect(rules.getRuleConfig('Suunto', 'Nautic', 'ndl_zero'), '#FFFFFF');
    });
  });
}
