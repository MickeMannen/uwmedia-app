// The overlay rules engine against the Python app: the cases of its
// tests/test_hud_rules.py (and the rules cases of tests/test_ccr.py and
// tests/test_info_fields.py), then the parity fixture made by
// tool/python_reference/rules_fixture.py. The rules are the app's own
// assets/hud_rules.json, a copy of the Python app's file.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

import '../../helpers/dive_parity.dart';
import '../../helpers/python_reference.dart';

final _rulesFile = File('assets/hud_rules.json');
final HudRules rules = HudRules(
  jsonDecode(_rulesFile.readAsStringSync()) as Map<String, dynamic>,
);
final _start = naive(2026, 1, 1, 10);

/// A waypoint with the defaults of the Python tests' `_wp` (no alerts, no
/// deco stop, at the surface).
Waypoint _wp({
  int timeSinceStart = 0,
  double? depth = 0.0,
  double maxDepth = 0.0,
  double? decoStopDepth = 0.0,
  double? nextStopDepth,
  int? nextStopTime,
  int? ndl,
  List<String>? diveAlerts,
  Map<String, TankData>? tanks,
}) => Waypoint(
  timestamp: _start.add(Duration(seconds: timeSinceStart)),
  timeSinceStart: timeSinceStart,
  depth: depth,
  maxDepth: maxDepth,
  decoStopDepth: decoStopDepth,
  nextStopDepth: nextStopDepth,
  nextStopTime: nextStopTime,
  ndl: ndl,
  diveAlerts: diveAlerts,
  tanks: tanks,
);

/// Per-second waypoints on straight lines through (time, depth) points.
List<Waypoint> _profile(List<(int, double)> points) {
  final wps = <Waypoint>[];
  var maxDepth = 0.0;
  for (var i = 0; i + 1 < points.length; i++) {
    final (t0, d0) = points[i];
    final (t1, d1) = points[i + 1];
    for (var t = t0; t < t1; t++) {
      final depth = d0 + (d1 - d0) * (t - t0) / (t1 - t0);
      if (depth > maxDepth) {
        maxDepth = depth;
      }
      wps.add(_wp(timeSinceStart: t, depth: depth, maxDepth: maxDepth));
    }
  }
  return wps;
}

Map<int, Waypoint> _byTime(List<Waypoint> wps) => {
  for (final w in wps) w.timeSinceStart: w,
};

/// A fixture column of [value, count] runs, expanded.
List<dynamic> _expand(Object? runs) => [
  for (final run in runs! as List<dynamic>)
    for (var i = 0; i < ((run as List<dynamic>)[1] as int); i++) run[0],
];

void main() {
  group('tests/test_hud_rules.py', () {
    test('test_rules_loading_and_hierarchical_fallback', () {
      expect(
        rules.getRuleConfig('Shearwater', 'Perdix 3', 'badge_states'),
        isNotNull,
      );
      expect(rules.getRuleConfig('Shearwater', 'Perdix 2', 'ndl'), isNotNull);
      expect(
        rules.getRuleConfig('Shearwater', 'UnknownModel', 'tank_pressure'),
        isA<List<dynamic>>(),
      );
      expect(rules.getRuleConfig('UnknownMfg', 'Model', 'ndl'), isNotNull);
      expect(rules.getRuleConfig('Generic', '', 'ndl'), isNotNull);
    });

    test('test_ndl_dynamic_colors', () {
      String color(String brand, String model, int ndl, String fallback) =>
          rules.getDynamicColor(brand, model, 'ndl', ndl, fallback);
      // 0 seconds: in deco. Shearwater has its own "ndl_zero" colour.
      expect(color('Shearwater', 'Perdix 2', 0, '#FFFFFF'), '#FF0000');
      // Without one, NDL 0 takes the colour of the safe tier.
      expect(color('Garmin', 'x50i', 0, '#FFFFFF'), '#FFFFFF');
      // Yellow below 5 minutes, white otherwise.
      expect(color('Shearwater', 'Perdix 2', 2100, '#BLUE'), '#FFFFFF');
      expect(color('Shearwater', 'Perdix 2', 1200, '#BLUE'), '#FFFFFF');
      expect(color('Shearwater', 'Perdix 2', 300, '#BLUE'), '#FFFFFF');
      expect(color('Shearwater', 'Perdix 2', 240, '#BLUE'), '#FFFF00');
    });

    // test_an_unbounded_ndl_reads_99_plus_except_in_deco is the renderer's
    // (resolve_element_text) and comes with it.

    test('test_po2_dynamic_colors', () {
      String color(String field, double po2) => rules.getDynamicColor(
        'Shearwater',
        'Perdix 2',
        field,
        po2,
        '#FFFFFF',
      );
      expect(color('po2', 1.3), '#FFFFFF');
      expect(color('po2', 1.6), '#FFFFFF');
      expect(color('po2', 1.61), '#FF0000');
      expect(color('po2', 1.8), '#FF0000');
      // The same band for each CCR cell.
      for (final cell in cellFields) {
        expect(color(cell, 1.7), '#FF0000');
      }
    });

    test('test_garmin_po2_dynamic_colors_are_two_tier_and_independent_of_'
        'shearwater', () {
      String color(double po2) =>
          rules.getDynamicColor('Garmin', 'x50i', 'po2', po2, '#FFFFFF');
      expect(color(1.3), '#FFFFFF');
      expect(color(1.4), '#FFFF00');
      expect(color(1.5), '#FFFF00');
      expect(color(1.6), '#FF0000');
      expect(color(1.8), '#FF0000');
    });

    test('test_tank_pressure_dynamic_colors', () {
      String color(String model, int bar) => rules.getDynamicColor(
        'Shearwater',
        model,
        'primary_tank_pressure',
        bar,
        '#BLUE',
      );
      expect(color('Perdix 2', 150), '#BLUE');
      expect(color('Perdix 2', 65), '#BLUE');
      expect(color('Perdix 2', 50), '#BLUE');
      expect(color('Perdix 2', 49), '#FFFF00');
      expect(color('Perdix 2', 25), '#FFFF00');
      expect(color('Perdix 2', 24), '#FF0000');
      expect(color('Peregrine TX', 24), '#FF0000');
      expect(color('Petrel', 40), '#FFFF00');
    });

    test('test_secondary_tank_pressure_dynamic_colors', () {
      String color(int bar) => rules.getDynamicColor(
        'Shearwater',
        'Perdix 2',
        'secondary_tank_pressure',
        bar,
        '#BLUE',
      );
      expect(color(150), '#BLUE');
      expect(color(49), '#FFFF00');
      expect(color(20), '#FF0000');
    });

    test('test_tank_reserve_thresholds_follow_the_manuals', () {
      // Shearwater: critical = max(21, reserve / 2).
      expect(rules.tankReserveThresholds('Shearwater', 'Perdix 2'), (
        50.0,
        25.0,
      ));
      expect(
        rules.tankReserveThresholds('Shearwater', 'Perdix 2', reserveBar: 48),
        (48.0, 24.0),
      );
      expect(
        rules.tankReserveThresholds('Shearwater', 'Perdix 2', reserveBar: 27),
        (27.0, 21.0),
      );
      expect(rules.tankPressureState('Shearwater', 'Teric', 47), 'reserve');
      expect(rules.tankPressureState('Shearwater', 'Teric', 23), 'critical');
      expect(rules.tankPressureState('Shearwater', 'Teric', 50), isNull);
      expect(rules.tankPressureState('Shearwater', 'Teric', null), isNull);
      // Garmin: reserve and critical are two settings.
      expect(rules.tankReserveThresholds('Garmin', 'mk3i'), (50.0, 25.0));
      String color(int bar) => rules.getDynamicColor(
        'Garmin',
        'x50i',
        'tank_pressure:T1',
        bar,
        '#FFFFFF',
      );
      expect(color(49), '#FFFF00');
      expect(color(24), '#FF0000');
      expect(color(120), '#FFFFFF');
      // No rule: no thresholds, and the generic bands still apply.
      expect(rules.tankReserveThresholds('UnknownMfg', null), isNull);
      expect(
        rules.getDynamicColor(
          'UnknownMfg',
          null,
          'primary_tank_pressure',
          55,
          '#FFFFFF',
        ),
        '#FF0000',
      );
    });

    test('test_garmin_deco_stop_phases_use_the_descent_margins', () {
      Waypoint at(double depth) =>
          _wp(depth: depth, nextStopDepth: 6.0, decoStopDepth: 6.0);
      String? phase(double depth) =>
          rules.decoStopPhase('Garmin', 'mk3i', at(depth));
      expect(phase(12.0), 'far');
      expect(phase(8.5), 'approach');
      expect(phase(6.5), 'at_stop');
      // 0.5 m above: within the margin.
      expect(phase(5.5), 'at_stop');
      expect(phase(5.3), 'violation');
      expect(
        rules.decoStopPhase('Shearwater', 'Perdix 2', at(5.9)),
        'violation',
      );
    });

    test('test_teric_and_tern_badges_box_the_title_and_say_paused', () {
      for (final model in ['Teric', 'Tern']) {
        final ss = rules.getBadgeConfig('Shearwater', model, 'safety_stop')!;
        expect(ss['paused_label'], 'PAUSED');
        expect(ss['title_box'], isTrue);
        final deco = rules.getBadgeConfig('Shearwater', model, 'deco')!;
        expect(deco['violation_color'], '#FFFF00');
        expect(deco['ceiling_violation_color'], '#FF0000');
      }
      // A Perdix 2 keeps its red violation and plain title.
      expect(
        rules.getBadgeConfig(
          'Shearwater',
          'Perdix 2',
          'deco',
        )!['violation_color'],
        '#FF0000',
      );
      expect(
        rules.getBadgeConfig('Shearwater', 'Perdix 2', 'safety_stop'),
        isNot(contains('title_box')),
      );
    });

    test('test_safety_stop_text', () {
      expect(
        rules.getSafetyStopText(
          'Shearwater',
          'Perdix 2',
          _wp(maxDepth: 5.0, depth: 5.0),
        ),
        '',
      );
      expect(
        rules.getSafetyStopText(
          'Shearwater',
          'Perdix 2',
          _wp(maxDepth: 12.0, depth: 5.0),
        ),
        'SAFETY STOP',
      );
    });

    test('test_resolve_state_priority_and_fallback', () {
      String state(String brand, String model, Waypoint? wp) =>
          rules.resolveState(brand, model, wp);
      // A deco alert wins outright.
      expect(
        state(
          'Garmin',
          'x50i',
          _wp(diveAlerts: ['approaching_first_deco_stop']),
        ),
        'deco',
      );
      expect(
        state('Garmin', 'x50i', _wp(diveAlerts: ['deco_ceiling_broken'])),
        'deco',
      );
      expect(
        state('Garmin', 'x50i', _wp(diveAlerts: ['safety_stop_started'])),
        'safety_stop',
      );
      expect(
        state('Garmin', 'x50i', _wp(diveAlerts: ['safety_stop_complete'])),
        'normal',
      );
      // No alerts: the depth bands.
      expect(state('Garmin', 'x50i', _wp(decoStopDepth: 6.0)), 'deco');
      expect(
        state('Shearwater', 'Perdix 2', _wp(maxDepth: 12.0, depth: 5.0)),
        'safety_stop',
      );
      expect(state('Shearwater', 'Perdix 2', _wp()), 'normal');
      expect(state('Garmin', 'x50i', null), 'normal');
    });

    test('test_resolve_state_garmin_deco_cleared_and_complete_alerts', () {
      String state(List<String> alerts) =>
          rules.resolveState('Garmin', 'x50i', _wp(diveAlerts: alerts));
      expect(state(['deco_stop_cleared']), 'clear');
      expect(state(['deco_complete']), 'normal');
      expect(state(['deco_ceiling_broken', 'deco_stop_cleared']), 'clear');
      // Clearing the last stop fires both: deco_complete wins.
      expect(state(['deco_stop_cleared', 'deco_complete']), 'normal');
    });

    test('test_get_badge_config', () {
      expect(rules.getBadgeConfig('Garmin', 'x50i', 'safety_stop'), {
        'label': 'STOP',
        'color': '#00FF00',
        'warn_color': '#FFFF00',
        'warn_value_color': '#FFFF00',
      });
      expect(rules.getBadgeConfig('Garmin', 'x50i', 'deco'), {
        'label': 'DECO',
        'color': '#FFA500',
      });
      final clear = rules.getBadgeConfig('Shearwater', 'Perdix 2', 'clear')!;
      expect((clear['label'], clear['color']), ('CLEAR', '#00C800'));
      expect(
        rules.getBadgeConfig('UnknownMfg', 'UnknownModel', 'safety_stop'),
        isNotNull,
      );
      expect(rules.getBadgeConfig('Garmin', 'x50i', 'normal'), isNull);
    });

    test('test_resolve_blink_color', () {
      expect(resolveBlinkColor('#00FF00', '#FF0000', 0.0), '#FF0000');
      expect(resolveBlinkColor('#00FF00', '#FF0000', 0.75), '#00FF00');
      expect(resolveBlinkColor('#00FF00', '#FF0000', 2.25), '#FF0000');
      expect(resolveBlinkColor('#00FF00', '#FF0000', null), '#FF0000');
    });

    test('test_resolve_tank_variant', () {
      Dive dive(List<String> tankKeys) => Dive(
        startTime: _start,
        endTime: _start,
        waypoints: [
          _wp(
            tanks: {for (final key in tankKeys) key: TankData(pressureBar: 1)},
          ),
        ],
      );
      expect(resolveTankVariant(dive(['Back'])), 'single_tank');
      expect(resolveTankVariant(dive(['Left', 'Right'])), 'sidemount');
      expect(
        resolveTankVariant(
          Dive(startTime: _start, endTime: _start, waypoints: []),
        ),
        'single_tank',
      );
      expect(resolveTankVariant(null), 'single_tank');
    });

    test('test_get_tank_fill_color', () {
      String? fill(String brand, String model, int? bar) =>
          rules.getTankFillColor(brand, model, bar);
      // No reading yet: no fill at all.
      expect(fill('Garmin', 'x50i', null), isNull);
      expect(fill('Garmin', 'x50i', 40), '#FF0000');
      expect(fill('Garmin', 'x50i', 60), '#FFFF00');
      // The X50i's blue; the Mk3i keeps the green default.
      expect(fill('Garmin', 'x50i', 150), '#00AAFF');
      expect(fill('Garmin', 'mk3i', 150), '#00FF00');
      expect(fill('Garmin', 'x50i', 50), '#FFFF00');
      expect(fill('Garmin', 'x50i', 70), '#00AAFF');
      expect(fill('UnknownMfg', 'UnknownModel', 40), '#FF0000');
    });

    test('test_garmin_safety_stop_timer_counts_down_and_completes', () {
      final wps = _profile([
        (0, 0),
        (60, 20),
        (600, 20),
        (700, 5),
        (1000, 5),
        (1060, 0),
      ]);
      final at = _byTime(wps);
      expect(rules.resolveState('Garmin', 'x50i', at[500], wps), 'normal');
      final status = rules.safetyStopStatus('Garmin', 'x50i', at[750], wps)!;
      expect(status.$1, isTrue);
      expect(status.$2, lessThan(180));
      expect(rules.resolveState('Garmin', 'x50i', at[750], wps), 'safety_stop');
      // Three minutes after reaching the stop band it is done.
      expect(rules.resolveState('Garmin', 'x50i', at[900], wps), 'normal');
    });

    test(
      'test_garmin_safety_stop_resets_below_11m_and_skips_shallow_dives',
      () {
        final wps = _profile([
          (0, 0),
          (60, 20),
          (300, 20),
          (400, 5),
          (460, 5),
          (520, 15),
          (600, 15),
          (700, 5),
          (760, 5),
          (800, 0),
        ]);
        final at = _byTime(wps);
        // Descending below 11 m resets the stop to a full 3:00.
        expect(rules.safetyStopStatus('Garmin', 'x50i', at[600], wps), (
          false,
          180,
        ));
        expect(
          rules.resolveState('Garmin', 'x50i', at[750], wps),
          'safety_stop',
        );
        final shallow = _profile([
          (0, 0),
          (60, 9),
          (600, 9),
          (700, 5),
          (900, 5),
          (960, 0),
        ]);
        expect(
          rules.resolveState('Garmin', 'x50i', shallow[750], shallow),
          'normal',
        );
      },
    );

    test('test_safety_stop_timer_only_for_rules_with_a_duration', () {
      final wps = _profile([(0, 0), (60, 20), (600, 20), (700, 5), (1000, 5)]);
      expect(
        rules.safetyStopTimeline('Shearwater', 'Perdix 2', wps),
        isNotNull,
      );
      expect(rules.safetyStopTimeline('NoSuchBrand', '', wps), isNull);
    });

    test('test_garmin_safety_stop_not_shown_after_a_3m_deco_stop', () {
      final wps = _profile([
        (0, 0),
        (120, 45),
        (1500, 45),
        (1800, 9),
        (2100, 6),
        (2400, 3),
        (3000, 3),
        (3030, 0),
      ]);
      for (final w in wps) {
        if (1700 <= w.timeSinceStart && w.timeSinceStart < 2700) {
          w.decoStopDepth = 3.0;
        }
      }
      final at = _byTime(wps);
      expect(rules.resolveState('Garmin', 'x50i', at[2000], wps), 'deco');
      expect(rules.resolveState('Garmin', 'x50i', at[2800], wps), 'normal');
      expect(
        rules.safetyStopStatus('Garmin', 'x50i', at[2800], wps)!.$1,
        isFalse,
      );
      expect(rules.resolveState('Garmin', 'x50i', at[3020], wps), 'normal');
    });

    test(
      'test_garmin_safety_stop_timeline_follows_the_computers_own_alerts',
      () {
        final wps = _profile([
          (0, 0),
          (60, 20),
          (600, 20),
          (700, 5),
          (1000, 5),
          (1060, 0),
        ]);
        final at = _byTime(wps);
        at[720]!.diveAlerts = ['safety_stop_started'];
        at[800]!.diveAlerts = ['safety_stop_complete'];
        String state(int t) => rules.resolveState('Garmin', 'x50i', at[t], wps);
        expect(state(750), 'safety_stop');
        expect(state(800), 'normal');
        expect(state(850), 'normal');
        expect(state(990), 'normal');
      },
    );

    test('test_garmin_safety_stop_ends_on_surfacing_without_flicker', () {
      final wps = _profile([
        (0, 0),
        (60, 20),
        (600, 20),
        (700, 5),
        (760, 5),
        (800, 1.0),
        (820, 1.4),
        (840, 1.0),
        (900, 1.4),
      ]);
      final at = _byTime(wps);
      expect(rules.resolveState('Garmin', 'x50i', at[750], wps), 'safety_stop');
      for (var t = 801; t < 900; t++) {
        expect(
          rules.resolveState('Garmin', 'x50i', at[t], wps),
          'normal',
          reason: '$t s',
        );
      }
    });

    test('test_deco_stop_phase_follows_the_perdix_margins', () {
      Waypoint stop(double depth) =>
          _wp(decoStopDepth: 6.0, nextStopDepth: 6.0, depth: depth);
      String? phase(double depth) =>
          rules.decoStopPhase('Shearwater', 'Perdix 2', stop(depth));
      // More than 5.1 m below the stop.
      expect(phase(15.0), 'far');
      expect(phase(10.0), 'approach');
      // Up to 1.5 m deeper: green with a check mark.
      expect(phase(7.4), 'at_stop');
      expect(phase(6.0), 'at_stop');
      expect(phase(5.5), 'violation');
      expect(
        rules.decoStopPhase('Shearwater', 'Perdix 2', _wp(depth: 5.0)),
        isNull,
      );
      // A Descent has its own margins (3 m / 0.6 m).
      expect(rules.decoStopPhase('Garmin', 'x50i', stop(7.0)), 'approach');
      expect(rules.decoStopPhase('UnknownMfg', null, stop(7.0)), isNull);
      // Not a state of its own.
      expect(rules.resolveState('Shearwater', 'Perdix 2', stop(5.5)), 'deco');
    });

    test('test_shearwater_safety_stop_counter_appears_at_11m_and_counts_'
        'under_6m', () {
      final wps = _profile([
        (0, 0),
        (60, 20),
        (600, 20),
        (700, 5),
        (1000, 5),
        (1060, 0),
      ]);
      final at = _byTime(wps);
      (String?, int)? phase(int t) =>
          rules.safetyStopPhase('Shearwater', 'Perdix 2', at[t], wps);
      String state(int t) =>
          rules.resolveState('Shearwater', 'Perdix 2', at[t], wps);
      // Not yet past 11 m.
      expect(state(30), 'normal');
      expect(phase(300), ('pending', 180));
      // Shown at depth, planned 3:00.
      expect(state(300), 'safety_stop');
      expect(phase(750)!.$1, 'counting');
      expect(phase(750)!.$2, lessThan(180));
      expect(phase(950), ('complete', 0));
      // Complete still shows, with the check mark.
      expect(state(950), 'safety_stop');
      // A Perdix names no stop depth.
      expect(
        rules.stopPhase('Shearwater', 'Perdix 2', at[750], wps).$4,
        isNull,
      );
    });

    test('test_shearwater_safety_stop_pauses_outside_2_4_to_8_3m_and_adapts_'
        'to_5min', () {
      final wps = _profile([
        (0, 0),
        (60, 20),
        (600, 20),
        (700, 5),
        (760, 5),
        (800, 1.0),
        (860, 1.0),
        (900, 5),
        (1100, 5),
      ]);
      final at = _byTime(wps);
      (String?, int)? phase(int t) =>
          rules.safetyStopPhase('Shearwater', 'Perdix 2', at[t], wps);
      // Shallower than 2.4 m.
      expect(phase(830)!.$1, 'paused');
      // Paused at 1 m: no countdown.
      expect(phase(855)!.$2, phase(805)!.$2);
      expect(phase(950)!.$1, 'counting');
      // 3 min fixed is the default, so a dive past 30 m still plans 3:00.
      final deep = _profile([(0, 0), (60, 32), (300, 32), (600, 5), (1000, 5)]);
      expect(rules.safetyStopPhase('Shearwater', 'Perdix 2', deep[200], deep), (
        'pending',
        180,
      ));
      // Adapt's 5:00 past 30 m (or under 5 min of NDL) applies once a
      // page enables it.
      final adaptRule = Map<String, dynamic>.of(
        rules.getRuleConfig('Shearwater', 'Perdix 2', 'safety_stop')!
            as Map<String, dynamic>,
      );
      adaptRule['adapt'] = {
        ...adaptRule['adapt'] as Map<String, dynamic>,
        'enabled': true,
      };
      final lowNdl = _profile([
        (0, 0),
        (60, 20),
        (600, 20),
        (700, 5),
        (1000, 5),
      ]);
      lowNdl[300].ndl = 240;
      final adapting = rules.withOverrides({'safety_stop': adaptRule});
      expect(
        adapting.safetyStopPhase('Shearwater', 'Perdix 2', deep[200], deep),
        ('pending', 300),
      );
      expect(
        adapting.safetyStopPhase('Shearwater', 'Perdix 2', lowNdl[400], lowNdl),
        ('pending', 300),
      );
      expect(
        rules.safetyStopPhase('Shearwater', 'Perdix 2', lowNdl[400], lowNdl),
        ('pending', 180),
      );
    });

    test('test_shearwater_deco_clear_counts_up_on_a_page_that_asks_for_it', () {
      // The deco clear counter is on in the technical modes only; a Tec
      // page turns it on with a layout rule override.
      final tec = rules.withOverrides({
        'deco_clear': {'count_up': true},
      });
      final wps = _profile([
        (0, 0),
        (120, 40),
        (1500, 40),
        (1700, 6),
        (2000, 6),
        (2100, 3),
        (2400, 3),
        (2430, 0),
      ]);
      for (final w in wps) {
        if (1400 <= w.timeSinceStart && w.timeSinceStart < 2000) {
          w
            ..decoStopDepth = 6.0
            ..nextStopDepth = 6.0
            ..nextStopTime = 2000 - w.timeSinceStart;
        }
      }
      final at = _byTime(wps);
      const brand = 'Shearwater';
      const model = 'Perdix 2';
      expect(tec.resolveState(brand, model, at[1800], wps), 'deco');
      expect(tec.stopPhase(brand, model, at[1800], wps).$2, 'at_stop');
      expect(tec.resolveState(brand, model, at[2000], wps), 'clear');
      expect(tec.decoClearSeconds(brand, model, at[2000], wps), 0);
      expect(tec.decoClearSeconds(brand, model, at[2300], wps), 300);
      expect(tec.stopPhase(brand, model, at[2300], wps), (
        'clear',
        'clear',
        300,
        null,
      ));
      // The safety stop runs after deco too, but on this page the clear
      // counter wins.
      expect(
        tec.safetyStopPhase(brand, model, at[2300], wps)!.$1,
        anyOf('counting', 'complete'),
      );
      // A Descent has no deco-clear counter.
      expect(rules.resolveState('Garmin', 'x50i', at[2300], wps), 'normal');
    });

    test('test_sidemount_switch_target_follows_the_21_bar_threshold', () {
      Waypoint wp(double p1, [double? p2]) => _wp(
        tanks: {
          'T1': TankData(pressureBar: p1, o2Percent: 21.0),
          if (p2 != null) 'T2': TankData(pressureBar: p2, o2Percent: 21.0),
        },
      );
      String? target(String brand, String model, Waypoint w) =>
          rules.sidemountSwitchTarget(brand, model, w);
      // Breathe the fuller T1.
      expect(target('Shearwater', 'Perdix 2', wp(175, 153)), 'primary');
      expect(target('Shearwater', 'Perdix 2', wp(150, 180)), 'secondary');
      // Within 21 bar.
      expect(target('Shearwater', 'Perdix 2', wp(170, 160)), isNull);
      // One tank.
      expect(target('Shearwater', 'Perdix 2', wp(170)), isNull);
      // Descent: 30 bar switch pressure.
      expect(target('Garmin', 'x50i', wp(175, 100)), 'primary');
      expect(target('Garmin', 'x50i', wp(175, 150)), isNull);
      // No such rule.
      expect(target('Generic', 'Custom', wp(175, 100)), isNull);
    });

    test('test_teric_and_tern_badges_override_only_what_differs_from_the_'
        'perdix_family', () {
      for (final model in ['Teric', 'Tern']) {
        final ss = rules.getBadgeConfig('Shearwater', model, 'safety_stop')!;
        expect(ss['label'], 'SAFETY');
        expect(ss, isNot(contains('check_mark')));
        expect(ss['counting_value_color'], '#00C800');
        expect(ss['paused_color'], '#FFFF00');
        expect(ss['complete_value_text'], 'CLEAR');
        // Inherited from the brand entry.
        expect(ss['show_depth'], isFalse);
        expect(ss['timer_format'], 'm:ss');
        final deco = rules.getBadgeConfig('Shearwater', model, 'deco')!;
        expect(deco['label'], 'DECO');
        expect(deco['inline'], isTrue);
        expect(deco, isNot(contains('approach_color')));
      }
      final perdix = rules.getBadgeConfig(
        'Shearwater',
        'Perdix 2',
        'safety_stop',
      )!;
      expect(perdix['label'], 'SAFETY STOP');
      expect(perdix['check_mark'], isTrue);
    });

    test('test_shearwater_safety_stop_resets_when_deeper_than_11m_again', () {
      final wps = _profile([
        (0, 0),
        (60, 20),
        (600, 20),
        (700, 5),
        (760, 5),
        (820, 15),
        (900, 15),
        (1000, 5),
        (1300, 5),
      ]);
      final at = _byTime(wps);
      (String?, int)? phase(int t) =>
          rules.safetyStopPhase('Shearwater', 'Perdix 2', at[t], wps);
      expect(phase(750)!.$1, 'counting');
      // Back below 11 m: the full 3:00 again.
      expect(phase(850), ('pending', 180));
      expect(phase(1050)!.$1, 'counting');
      expect(phase(1050)!.$2, greaterThan(100));
    });

    test('test_perdix_3_badge_is_a_boxed_title_that_replaces_the_ndl', () {
      final ss = rules.getBadgeConfig('Shearwater', 'Perdix 3', 'safety_stop')!;
      expect(ss['label'], 'SAFETY');
      expect(ss['paused_label'], 'PAUSED');
      expect(ss['title_box'], isTrue);
      expect(ss, isNot(contains('check_mark')));
      expect(ss['complete_value_text'], 'CLEAR');
      final deco = rules.getBadgeConfig('Shearwater', 'Perdix 3', 'deco')!;
      expect(deco['label'], 'DECO');
      expect(deco['color'], '#00ADED');
      expect(deco['inline'], isTrue);
      expect(deco, isNot(contains('approach_color')));
    });

    test('test_underscore_keys_in_rules_are_annotations_not_config', () {
      final annotated = HudRules({
        '_source': 'hud_rules_sources.md',
        'Shearwater': {
          '_manual': 'Perdix 2 Recreational manual Rev C',
          'ndl': [
            {'max': 5, 'color': '#FFFF00'},
            {'min': 5, 'color': '#FFFFFF'},
          ],
          '_ndl': 'p.31',
          'badge_states': {
            '_source': 'p.27-28',
            'safety_stop': {
              'label': 'SAFETY STOP',
              'color': '#00ADED',
              '_source': 'p.27',
            },
          },
          'Perdix 2': {
            'tank_pressure': [
              {'max': 60, 'color': '#FF0000'},
            ],
            '_source': 'unverified',
          },
        },
        'default': {
          'ndl': [
            {'max': 10, 'color': '#FF0000'},
          ],
        },
      });
      int firstMax(Object? bands) =>
          ((bands! as List<dynamic>).first as Map<String, dynamic>)['max']
              as int;
      expect(isAnnotationKey('_source'), isTrue);
      expect(isAnnotationKey('ndl'), isFalse);
      expect(
        firstMax(annotated.getRuleConfig('Shearwater', 'Perdix 2', 'ndl')),
        5,
      );
      expect(annotated.getRuleConfig('Shearwater', 'Perdix 2', '_ndl'), isNull);
      // Not a model.
      expect(
        firstMax(annotated.getRuleConfig('Shearwater', '_source', 'ndl')),
        5,
      );
      // Not a brand.
      expect(firstMax(annotated.getRuleConfig('_source', null, 'ndl')), 10);
      expect(
        annotated.getBadgeConfig('Shearwater', 'Perdix 2', 'safety_stop'),
        {'label': 'SAFETY STOP', 'color': '#00ADED'},
      );
      expect(
        annotated.getDynamicColor(
          'Shearwater',
          'Perdix 2',
          'ndl',
          240,
          '#000000',
        ),
        '#FFFF00',
      );
    });

    test('test_shearwater_safety_stop_follows_deco_on_a_recreational_page', () {
      final wps = _profile([
        (0, 0),
        (60, 36),
        (1080, 36),
        (1200, 6),
        (1500, 6),
        (1510, 4.5),
        (1560, 4.5),
        (1600, 1.8),
        (1640, 1.8),
        (1650, 4.5),
        (1900, 4.5),
        (1950, 0),
      ]);
      for (final w in wps) {
        if (1100 <= w.timeSinceStart && w.timeSinceStart <= 1500) {
          w
            ..decoStopDepth = 6.0
            ..nextStopDepth = 6.0
            ..nextStopTime = 60;
        }
      }
      final at = _byTime(wps);
      const brand = 'Shearwater';
      const model = 'Perdix 2';
      (String, String?) phase(int t) {
        final p = rules.stopPhase(brand, model, at[t], wps);
        return (p.$1, p.$2);
      }

      expect(rules.resolveState(brand, model, at[1300], wps), 'deco');
      expect(phase(1530), ('safety_stop', 'counting'));
      expect(phase(1620), ('safety_stop', 'paused'));
      // 3 min fixed by default.
      expect(phase(1880), ('safety_stop', 'complete'));
      expect(rules.decoClearSeconds(brand, model, at[1530], wps), isNull);
    });
  });

  group('tests/test_ccr.py and tests/test_info_fields.py, the rules cases', () {
    Waypoint cc(
      int t,
      double depth, {
      String? divemode,
      double? po2,
      double? po2_1,
      double? po2_2,
      double? po2_3,
      double? diluentO2Percent,
      Map<String, TankData>? tanks,
    }) => Waypoint(
      timestamp: _start.add(Duration(seconds: t)),
      depth: depth,
      timeSinceStart: t,
      diveTime: t,
      divemode: divemode,
      po2: po2,
      po2_1: po2_1,
      po2_2: po2_2,
      po2_3: po2_3,
      diluentO2Percent: diluentO2Percent,
      tanks: tanks,
    );
    Dive dive(List<Waypoint> wps) => Dive(
      startTime: wps.first.timestamp,
      endTime: wps.last.timestamp,
      waypoints: wps,
    );

    test('test_a_ccr_dive_is_not_sidemount', () {
      Map<String, TankData> tanks() => {
        'O2': TankData(pressureBar: 180, o2Percent: 100.0),
        'T1': TankData(pressureBar: 190),
      };
      expect(
        resolveTankVariant(
          dive([cc(0, 10, tanks: tanks(), divemode: 'closedcircuit')]),
        ),
        'single_tank',
      );
      expect(
        resolveTankVariant(dive([cc(0, 10, tanks: tanks())])),
        'sidemount',
      );
    });

    test('test_cell_vote', () {
      expect(failedCells({0: 1.20, 1: 1.25, 2: 0.80}), {2});
      expect(failedCells({0: 1.20, 1: 1.22, 2: 1.18}), isEmpty);
      // Two cells apart: neither can be trusted.
      expect(failedCells({0: 1.2, 1: 0.6}), {0, 1});
      expect(failedCells({0: 0.3}), isEmpty);
    });

    test('test_shearwater_cc_colours', () {
      final wp = cc(
        0,
        20,
        po2: 1.7,
        po2_1: 1.25,
        po2_2: 1.26,
        po2_3: 0.30,
        divemode: 'closedcircuit',
        diluentO2Percent: 21.0,
      );
      Map<String, String>? style(String field, double value, Waypoint w) =>
          rules.ccrStyle(
            'Shearwater',
            'Petrel',
            field,
            w,
            value,
            '#FFFFFF',
            elapsed: 0,
          );
      expect(style('po2', 1.7, wp)!['color'], '#FF0000');
      expect(style('po2', 1.3, wp), isNull);
      expect(style('po2_1', 1.25, wp), isNull);
      // Failed and below 0.4.
      expect(style('po2_3', 0.30, wp)!['color'], '#FF0000');
      wp.po2_3 = 0.9;
      // Failed, in range.
      expect(style('po2_3', 0.9, wp)!['color'], '#FFFF00');
      // 1.7 on open circuit is the OC rules' business, not the loop's.
      expect(style('po2', 1.7, cc(0, 20, divemode: 'opencircuit')), isNull);
      expect(style('diluent_po2', 0.10, wp)!['color'], '#FF0000');
    });

    test('test_running_average_depth_is_time_weighted', () {
      final wps = [cc(0, 0), cc(60, 20), cc(120, 20), cc(180, 0)];
      // Trapezoids: 600 after one minute, 1800 after two, 2400 after three.
      expect(rules.averageDepthAt(wps[0], wps), 0.0);
      expect(rules.averageDepthAt(wps[1], wps), closeTo(10.0, 1e-9));
      expect(rules.averageDepthAt(wps[2], wps), closeTo(15.0, 1e-9));
      expect(rules.averageDepthAt(wps[3], wps), closeTo(2400 / 180, 1e-9));
      expect(rules.averageDepthAt(wps[1], null), 20.0);
      expect(rules.averageDepthAt(null, wps), isNull);
    });
  });

  group('parity with the Python rules engine', () {
    final reference = pythonReference('rules/rules_cases.json');

    test('assets/hud_rules.json is the file the fixture was made from', () {
      expect(
        sha256.convert(_rulesFile.readAsBytesSync()).toString(),
        reference['hud_rules_sha256'],
      );
    });

    test('getRuleConfig: where every lookup lands', () {
      for (final c in jsonObjects(reference['rule_config'])) {
        final brand = c['manufacturer'] as String?;
        final model = c['model'] as String?;
        final sources = c['sources'] as Map<String, dynamic>;
        for (final key in sources.keys) {
          final path = sources[key] as List<dynamic>?;
          final got = rules.getRuleConfig(brand, model, key);
          if (path == null) {
            expect(got, isNull, reason: '$brand/$model $key');
            continue;
          }
          Object? block = rules.rules;
          for (final part in path) {
            block = (block! as Map<String, dynamic>)[part];
          }
          expect(
            identical(got, (block! as Map<String, dynamic>)[key]),
            isTrue,
            reason: '$brand/$model $key from $path',
          );
        }
      }
    });

    test('getDynamicColor', () {
      for (final c in jsonObjects(reference['dynamic_color'])) {
        expect(
          rules.getDynamicColor(
            c['manufacturer'] as String?,
            c['model'] as String?,
            c['field'] as String,
            c['value'],
            '#123456',
          ),
          c['expected'],
          reason: '$c',
        );
      }
    });

    test('tank thresholds, states, fill and ceiling colours', () {
      for (final c in jsonObjects(reference['tank'])) {
        final brand = c['manufacturer'] as String?;
        final model = c['model'] as String?;
        if (c.containsKey('fill')) {
          for (final pair in c['fill'] as List<dynamic>) {
            final [value, expected] = pair as List<dynamic>;
            expect(
              rules.getTankFillColor(brand, model, value),
              expected,
              reason: '$brand/$model fill $value',
            );
          }
          expect(
            rules.ceilingBrokenColor(brand, model),
            c['ceiling_broken_color'],
          );
          continue;
        }
        final reserve = (c['reserve_bar'] as num?)?.toDouble();
        final thresholds = rules.tankReserveThresholds(
          brand,
          model,
          reserveBar: reserve,
        );
        expect(
          thresholds == null ? null : [thresholds.$1, thresholds.$2],
          c['thresholds'],
          reason: '$brand/$model reserve $reserve',
        );
        for (final pair in c['states'] as List<dynamic>) {
          final [value, expected] = pair as List<dynamic>;
          expect(
            rules.tankPressureState(brand, model, value, reserveBar: reserve),
            expected,
            reason: '$brand/$model reserve $reserve at $value',
          );
        }
      }
    });

    test('getBadgeConfig', () {
      for (final c in jsonObjects(reference['badge'])) {
        // A page's own `rules` layer last (Python 0.8.0).
        expect(
          rules
              .withOverrides(c['overrides'])
              .getBadgeConfig(
                c['manufacturer'] as String?,
                c['model'] as String?,
                c['state'] as String,
              ),
          c['expected'],
          reason:
              '${c['manufacturer']}/${c['model']} ${c['state']} '
              '${c['overrides'] ?? ''}',
        );
      }
    });

    test('resolveBlinkColor', () {
      for (final c in jsonObjects(reference['blink'])) {
        expect(
          resolveBlinkColor(
            'base',
            'blink',
            (c['elapsed'] as num?)?.toDouble(),
            period: (c['period'] as num).toDouble(),
          ),
          c['expected'],
          reason: '$c',
        );
      }
    });

    test('failedCells', () {
      for (final c in jsonObjects(reference['failed_cells'])) {
        final values = {
          for (final e in (c['values'] as Map<String, dynamic>).entries)
            int.parse(e.key): (e.value as num).toDouble(),
        };
        expect(
          failedCells(
            values,
            fraction: (c['fraction'] as num).toDouble(),
          ).toList()..sort(),
          c['expected'],
          reason: '$c',
        );
      }
      expect(resolveTankVariant(null), reference['tank_variant_none']);
    });

    for (final c in jsonObjects(reference['dives'])) {
      final name = c['name'] as String;
      test('a dive: $name', () {
        final dive = Dive.fromJson(c['dive'] as Map<String, dynamic>);
        final wps = dive.waypoints;
        expect(resolveTankVariant(dive), c['tank_variant']);
        final alone = c['average_depth_alone'] as List<dynamic>;
        for (var i = 0; i < alone.length; i++) {
          expect(rules.averageDepthAt(wps[i], null), alone[i]);
        }

        for (final r in jsonObjects(c['results'])) {
          final brand = r['manufacturer'] as String?;
          final model = r['model'] as String?;
          final engine = rules.withOverrides(r['overrides']);
          final at = '$brand/$model ${r['overrides'] ?? ''}';
          List<dynamic> column(String name) {
            final values = _expand(r[name]);
            expect(values, hasLength(wps.length), reason: '$at $name');
            return values;
          }

          final state = column('state');
          final stateAlone = column('state_alone');
          final stop = column('stop_phase');
          final decoPhase = column('deco_stop_phase');
          final broken = column('ceiling_broken');
          final sidemount = column('sidemount');
          final safetyPhase = column('safety_phase');
          final safetyStatus = column('safety_status');
          final decoClear = column('deco_clear');
          final ndlBefore = column('ndl_before_clear');
          final safetyText = column('safety_text');
          final average = column('average_depth');
          final ccr = r.containsKey('ccr') ? column('ccr') : null;

          for (var i = 0; i < wps.length; i++) {
            final w = wps[i];
            final where = '$at waypoint $i';
            expect(
              engine.resolveState(brand, model, w, wps),
              state[i],
              reason: '$where state',
            );
            expect(
              engine.resolveState(brand, model, w),
              stateAlone[i],
              reason: '$where state alone',
            );
            final p = engine.stopPhase(brand, model, w, wps);
            expect([p.$1, p.$2, p.$3, p.$4], stop[i], reason: '$where stop');
            expect(
              engine.decoStopPhase(brand, model, w),
              decoPhase[i],
              reason: '$where deco phase',
            );
            expect(
              engine.ceilingBroken(brand, model, w),
              broken[i],
              reason: '$where ceiling broken',
            );
            expect(
              engine.sidemountSwitchTarget(brand, model, w),
              sidemount[i],
              reason: '$where sidemount',
            );
            final sp = engine.safetyStopPhase(brand, model, w, wps);
            expect(
              sp == null ? null : [sp.$1, sp.$2],
              safetyPhase[i],
              reason: '$where safety phase',
            );
            final ss = engine.safetyStopStatus(brand, model, w, wps);
            expect(
              ss == null ? null : [ss.$1, ss.$2],
              safetyStatus[i],
              reason: '$where safety status',
            );
            expect(
              engine.decoClearSeconds(brand, model, w, wps),
              decoClear[i],
              reason: '$where deco clear',
            );
            expect(
              engine.getNdlBeforeClear(brand, model, w, wps),
              ndlBefore[i],
              reason: '$where NDL before clear',
            );
            expect(
              engine.getSafetyStopText(brand, model, w),
              safetyText[i],
              reason: '$where safety text',
            );
            final wantAverage = average[i] as num?;
            expect(
              engine.averageDepthAt(w, wps),
              wantAverage == null ? isNull : nearly(wantAverage),
              reason: '$where average depth',
            );
            if (ccr != null) {
              final values = <String, Object?>{
                'po2': w.po2,
                'diluent_po2': w.diluentPo2,
                'po2_1': w.po2_1,
                'po2_2': w.po2_2,
                'po2_3': w.po2_3,
                'setpoint': w.setpoint,
                'circuit': w.circuit,
                'gasmix': w.gasmix,
                'depth': w.depth,
              };
              final t = w.timeSinceStart;
              final elapsed = t + 0.25 * (t ~/ 10 % 4);
              expect(
                [
                  for (final field in values.keys)
                    engine.ccrStyle(
                      brand,
                      model,
                      field,
                      w,
                      values[field],
                      '#FFFFFF',
                      elapsed: elapsed,
                    ),
                ],
                ccr[i],
                reason: '$where rebreather colours',
              );
            }
          }
        }
      });
    }
  });
}
