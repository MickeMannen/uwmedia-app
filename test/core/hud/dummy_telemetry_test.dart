// The Overlay Designer's sample dive against the Python app: the cases of
// its tests/test_dummy_telemetry.py, then the parity fixture made by
// tool/python_reference/dummy_fixture.py (six dives waypoint by waypoint
// with what the rules say at each, and every forced state from several
// moments).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/hud/dummy_telemetry.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/rules/hud_notices.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

import '../../helpers/dive_parity.dart';
import '../../helpers/python_reference.dart';

final HudRules rules = HudRules(
  jsonDecode(File('assets/hud_rules.json').readAsStringSync())
      as Map<String, dynamic>,
);

/// State, phase and notice text for a brand.
List<String?> said(
  (String?, String?) brand,
  Waypoint? wp,
  List<Waypoint>? history,
) {
  final (state, phase, _, _) = rules.stopPhase(brand.$1, brand.$2, wp, history);
  final notice = activeNotice(
    rules,
    brand.$1,
    brand.$2,
    wp,
    waypoints: history,
  );
  return [state, phase, notice?.text];
}

const perdix = ('Shearwater', 'Perdix 2');
const mk3i = ('Garmin', 'mk3i');

// What each forced state reports on a Perdix 2 and on a Descent.
const forcedExpect = <String, List<List<String?>>>{
  'descent': [
    ['normal', null, null],
    ['normal', null, null],
  ],
  'ndl_low': [
    ['safety_stop', 'pending', 'Low NDL Alert'],
    ['normal', null, null],
  ],
  'deco': [
    ['deco', 'far', null],
    ['deco', 'far', null],
  ],
  'deco_approach': [
    ['deco', 'approach', null],
    ['deco', 'approach', null],
  ],
  'deco_at_stop': [
    ['deco', 'at_stop', null],
    ['deco', 'at_stop', null],
  ],
  'deco_violation': [
    ['deco', 'violation', 'MISSED DECO STOP'],
    ['deco', 'at_stop', 'Descend below deco ceiling.'],
  ],
  'deco_ceiling_violation': [
    ['deco', 'ceiling_violation', 'MISSED DECO STOP'],
    ['deco', 'violation', 'Descend below deco ceiling.'],
  ],
  'clear': [
    ['clear', 'clear', null],
    ['clear', 'clear', null],
  ],
  'safety_pending': [
    ['safety_stop', 'pending', null],
    ['normal', null, null],
  ],
  'safety_stop': [
    ['safety_stop', 'counting', null],
    ['safety_stop', 'counting', 'Safety Stop Started'],
  ],
  'safety_paused': [
    ['safety_stop', 'paused', null],
    ['safety_stop', 'warn', null],
  ],
  'safety_done': [
    ['safety_stop', 'complete', null],
    ['normal', null, null],
  ],
  'fast_ascent': [
    ['safety_stop', 'pending', 'FAST ASCENT'],
    ['normal', null, 'Ascending too fast. Slow your ascent.'],
  ],
  'high_ppo2': [
    ['safety_stop', 'pending', 'HIGH PPO2'],
    ['normal', null, null],
  ],
  'high_cns': [
    ['safety_stop', 'pending', 'HIGH CNS'],
    ['normal', null, 'CNS toxicity at 95%. End your dive now.'],
  ],
  'low_gas': [
    ['safety_stop', 'pending', null],
    ['normal', null, null],
  ],
  'critical_gas': [
    ['safety_stop', 'pending', 'T1 CRITICAL PRES'],
    ['normal', null, null],
  ],
  'surfacing': [
    ['safety_stop', 'complete', null],
    ['normal', null, null],
  ],
};

void main() {
  group('tests/test_dummy_telemetry.py', () {
    test('test_dummy_dive_is_deterministic', () {
      final a = buildDummyDive();
      final b = buildDummyDive();
      expect(
        [for (final w in a.waypoints) w.toJson()],
        [for (final w in b.waypoints) w.toJson()],
      );
    });

    test('test_dummy_dive_profile_shape', () {
      final dive = buildDummyDive();
      final times = [for (final w in dive.waypoints) w.timeSinceStart];
      expect(times.first, 0);
      expect(times.last, dummyDurationS);
      expect(times, [...times]..sort());
      expect(times.toSet().length, times.length);
      final depths = [for (final w in dive.waypoints) w.depth!];
      expect(depths.first, 0.0);
      expect(depths.last, 0.0);
      expect(depths.reduce((a, b) => a > b ? a : b), 42.0);
      // max_depth is cumulative and never decreases
      final maxDepths = [for (final w in dive.waypoints) w.maxDepth];
      expect(maxDepths, [...maxDepths]..sort());
      // every field a bundled template shows is there mid-dive
      final wp = waypointAt(dive, 12 * 60)!;
      expect(wp.ndl, greaterThan(0));
      expect(wp.tts, greaterThan(0));
      expect(wp.diveTime, 12 * 60);
      expect(wp.depth, 30.0);
      expect(wp.primaryTankPressure, greaterThan(0));
      expect(wp.gasmix, 'Nx32');
      expect(wp.airRemaining, greaterThan(0));
      expect(wp.heartRate, greaterThan(0));
      expect(wp.po2, greaterThan(0));
      expect(wp.gf, isNotNull);
    });

    test('test_dummy_dive_passes_through_every_state_in_order', () {
      final dive = buildDummyDive();
      List<String?> at(int t, [(String, String) brand = perdix]) =>
          said(brand, waypointAt(dive, t), dive.waypoints);

      expect(at(60), ['normal', null, null]);
      expect(waypointAt(dive, 60)!.ascentRate, lessThan(0)); // descent
      // past 11 m a Perdix shows the safety-stop counter (pending)
      expect(at(400), ['safety_stop', 'pending', null]);
      expect(at(680)[2], 'Low NDL Alert');
      expect(waypointAt(dive, 680)!.ndl, lessThanOrEqualTo(300));
      expect(at(900)[2], 'Depth Alert'); // below 40 m
      expect(at(930)[2], 'HIGH PPO2'); // 30 s above the limit at 42 m
      expect(at(1000), ['deco', 'far', null]);
      expect(at(1160), ['deco', 'approach', 'FAST ASCENT']);
      expect(at(1230).sublist(0, 2), ['deco', 'at_stop']);
      expect(at(1280).sublist(0, 2), ['deco', 'ceiling_violation']);
      expect(at(1300)[2], 'MISSED DECO STOP'); // 30 s above the stop
      expect(at(1400).sublist(0, 2), ['deco', 'at_stop']);
      expect(at(1440)[0], 'clear'); // the last stop cleared
      expect(at(1520).sublist(0, 2), ['safety_stop', 'counting']);
      expect(at(1590).sublist(0, 2), ['safety_stop', 'paused']);
      expect(at(1900), ['safety_stop', 'complete', null]);

      // Garmin reads the same dive through its own alerts and margins
      expect(at(510, mk3i)[2], 'Approaching NDL');
      expect(at(840, mk3i).sublist(0, 2), ['deco', 'far']);
      expect(at(840, mk3i)[2], 'NDL exceeded. Decompression now required.');
      expect(at(1150, mk3i)[2], 'Ascending too fast. Slow your ascent.');
      expect(at(1280, mk3i).sublist(0, 2), ['deco', 'violation']);
      expect(at(1270, mk3i)[2], 'Descend below deco ceiling.');
      expect(at(1440, mk3i)[0], 'clear');
      expect(at(1450, mk3i)[2], 'Decompression Cleared');
      // a Descent asks for no safety stop after a deco dive
      expect(at(1530, mk3i)[0], 'normal');
      // the single cylinder reaches the reserve during the safety stop
      expect(waypointAt(dive, 1600)!.primaryTankPressure, lessThan(50));
      expect(waypointAt(dive, 1300)!.primaryTankPressure, greaterThan(50));
    });

    for (final (variant, tanks) in [
      ('single_tank', 1),
      ('sidemount', 2),
      (null, 1),
    ]) {
      test('test_dummy_dive_tank_count_follows_variant[$variant]', () {
        final dive = buildDummyDive(variant: variant);
        expect(dive.waypoints.every((w) => w.tanks.length == tanks), isTrue);
        expect(
          resolveTankVariant(dive),
          tanks == 2 ? 'sidemount' : 'single_tank',
        );
      });
    }

    test('test_dummy_dive_tank_pressure_only_drops', () {
      final pressures = [
        for (final w in buildDummyDive().waypoints) w.primaryTankPressure!,
      ];
      for (var i = 1; i < pressures.length; i++) {
        expect(pressures[i], lessThanOrEqualTo(pressures[i - 1]));
      }
      expect(pressures.first, lessThan(200.0));
      expect(pressures.last, greaterThan(20.0));
    });

    test('test_waypoint_at_nearest_forward_then_last', () {
      final dive = buildDummyDive();
      expect(waypointAt(dive, 0)!.timeSinceStart, 0);
      expect(waypointAt(dive, 95)!.timeSinceStart, 100);
      expect(waypointAt(dive, 1000000)!.timeSinceStart, dummyDurationS);
      expect(waypointAt(null, 10), isNull);
    });

    for (final state in ['normal', 'safety_stop', 'deco', 'clear']) {
      for (final brand in <(String?, String?)>[
        perdix,
        ('Garmin', 'x50i'),
        (null, null),
      ]) {
        test(
          'test_apply_state_resolves_for_every_rule_set[$state, $brand]',
          () {
            final dive = buildDummyDive();
            final base = waypointAt(dive, 12 * 60)!; // "normal": 30 m
            final forced = applyState(base, state);
            expect(rules.resolveState(brand.$1, brand.$2, forced), state);
            // original untouched
            expect(base.decoStopDepth, isNull);
            expect(base.diveAlerts, isEmpty);
            expect(forced.logFilename, 'dummy_telemetry');
          },
        );
      }
    }

    for (final state in stateOptions.skip(2)) {
      test('test_forced_dive_reports_the_state_through_the_timelines'
          '[$state]', () {
        final dive = buildDummyDive();
        final base = waypointAt(dive, 12 * 60)!;
        final (wp, history) = forcedDive(base, state);
        expect(history, isNotEmpty);
        expect(history!.last, same(wp));
        expect(wp!.logFilename, 'dummy_telemetry');
        final times = [for (final w in history) w.timeSinceStart];
        expect(times, [...times]..sort());
        for (final (i, brand) in [perdix, mk3i].indexed) {
          final got = said(brand, wp, history);
          expect(got, forcedExpect[state]![i], reason: '$brand $state');
          expect(
            got[0] == stateOuter[state] ||
                got[0] == 'safety_stop' ||
                (brand.$1 == 'Garmin' &&
                    (state == 'safety_pending' || state == 'safety_done')),
            isTrue,
          );
        }
        if (state == 'low_gas') {
          expect(
            rules.tankPressureState(
              'Shearwater',
              'Perdix 2',
              wp.primaryTankPressure,
            ),
            'reserve',
          );
        }
        // the original is untouched
        expect(base.decoStopDepth, isNull);
        expect(base.diveAlerts, isEmpty);
      });
    }

    test('test_forced_dive_auto_and_normal', () {
      final dive = buildDummyDive();
      final wp = waypointAt(dive, 600)!;
      final (same_, none) = forcedDive(wp, 'auto');
      expect(same_, same(wp));
      expect(none, isNull);
      final (normal, history) = forcedDive(waypointAt(dive, 1530), 'normal');
      expect(history, isNull);
      expect(rules.resolveState('Shearwater', 'Perdix 2', normal), 'normal');
    });

    test('test_apply_state_normal_suppresses_natural_safety_stop', () {
      final dive = buildDummyDive();
      final atStop = waypointAt(dive, 1530)!; // 5 m after a 30 m dive
      expect(
        rules.resolveState('Shearwater', 'Perdix 2', atStop),
        'safety_stop',
      );
      expect(
        rules.resolveState(
          'Shearwater',
          'Perdix 2',
          applyState(atStop, 'normal'),
        ),
        'normal',
      );
    });

    test('test_apply_state_auto_returns_same_waypoint', () {
      final wp = waypointAt(buildDummyDive(), 600)!;
      expect(applyState(wp, 'auto'), same(wp));
      expect(applyState(wp, 'not-a-state'), same(wp));
    });

    test('test_sidemount_tanks_drift_far_enough_apart_to_cue_a_switch', () {
      // The Overlay Designer's dummy sidemount dive passes 35 bar between
      // the cylinders before the first change, so every brand's switch cue
      // shows.
      final dive = buildDummyDive(variant: 'sidemount');
      final gaps = [
        for (final w in dive.waypoints)
          (w.tanks['Left']!.pressureBar! - w.tanks['Right']!.pressureBar!)
              .abs(),
      ];
      expect(gaps.reduce((a, b) => a > b ? a : b), greaterThan(35));
      expect(
        dive.waypoints.any(
          (w) =>
              rules.sidemountSwitchTarget('Garmin', 'x50i', w) == 'secondary',
        ),
        isTrue,
      );
      expect(
        dive.waypoints.any(
          (w) =>
              rules.sidemountSwitchTarget('Shearwater', 'Perdix 2', w) ==
              'secondary',
        ),
        isTrue,
      );
    });
  });

  group('parity with Python', () {
    final reference = jsonDecode(
      utf8.decode(
        gzip.decode(
          File(
            'test/fixtures/python_reference/hud_designer/'
            'dummy_cases.json.gz',
          ).readAsBytesSync(),
        ),
      ),
    ) as Map<String, dynamic>;
    final brands = [
      for (final brand in reference['brands'] as List<dynamic>)
        ((brand as List<dynamic>)[0] as String?, brand[1] as String?),
    ];
    // The port's sample dive has SAC, VSAC and the tank sizes; Python's has
    // none (spec §10.54). Left out here; the rules are compared with them.
    Map<String, dynamic> withoutSac(Map<String, dynamic> wp) => wp
      ..remove('pressure_sac')
      ..remove('volume_sac');
    Object? dump(Waypoint wp) => withoutNulls(withoutSac(wp.toJson()));
    Object? dumpDive(Dive dive) {
      final json = dive.toJson()
        ..remove('log_path')
        ..remove('tank_volumes_l');
      for (final wp in json['waypoints'] as List<dynamic>) {
        withoutSac(wp as Map<String, dynamic>);
      }
      return withoutNulls(json);
    }

    test('the constants', () {
      expect(formatNaive(dummyStart), reference['start']);
      expect(dummyDurationS, reference['duration_s']);
      expect(dummySampleS, reference['sample_s']);
      expect(stateOptions, reference['state_options']);
      expect(stateLabels, reference['state_labels']);
      expect(stateOuter, reference['state_outer']);
    });

    test('the dives, and what the rules say at every waypoint', () {
      final cases = jsonObjects(reference['dives']);
      expect(cases.length, 6);
      for (final c in cases) {
        final reason = '${c['variant']} ccr=${c['ccr']}';
        final dive = buildDummyDive(
          variant: c['variant'] as String?,
          ccr: c['ccr'] as bool,
        );
        expect(dumpDive(dive), c['dive'], reason: reason);
        // Without the port's SAC it is Python's dive as it is.
        expect(
          withoutNulls(
            buildDummyDive(
              variant: c['variant'] as String?,
              ccr: c['ccr'] as bool,
              sac: false,
            ).toJson()..remove('log_path'),
          ),
          c['dive'],
          reason: '$reason, sac: false',
        );
        expect(resolveTankVariant(dive), c['tank_variant'], reason: reason);
        final want = c['said'] as List<dynamic>;
        for (final (i, wp) in dive.waypoints.indexed) {
          expect(
            [for (final brand in brands) said(brand, wp, dive.waypoints)],
            want[i],
            reason: '$reason at ${wp.timeSinceStart} s',
          );
        }
        for (final [t as num, want]
            in (c['waypoint_at'] as List<dynamic>).cast<List<dynamic>>()) {
          expect(waypointAt(dive, t)!.timeSinceStart, want);
        }
      }
    });

    test('every state applied and forced', () {
      final cases = jsonObjects(reference['states']);
      expect(cases.length, 231);
      final dives = <String, Dive>{};
      for (final c in cases) {
        final dive = dives.putIfAbsent(
          '${c['variant']} ${c['ccr']}',
          () => buildDummyDive(
            variant: c['variant'] as String?,
            ccr: c['ccr'] as bool,
          ),
        );
        final state = c['state'] as String;
        final reason = '${c['variant']} ccr=${c['ccr']} ${c['t']} s $state';
        final base = waypointAt(dive, c['t'] as int)!;
        final before = dump(base);

        final applied = applyState(base, state);
        expect(dump(applied), c['applied'], reason: 'applied, $reason');
        expect(identical(applied, base), c['applied_same'], reason: reason);
        expect(
          [for (final b in brands) rules.resolveState(b.$1, b.$2, applied)],
          c['applied_states'],
          reason: reason,
        );

        final (forced, history) = forcedDive(base, state);
        expect(dump(forced!), c['forced'], reason: 'forced, $reason');
        expect(identical(forced, base), c['forced_same'], reason: reason);
        expect(
          history == null ? null : [for (final wp in history) dump(wp)],
          c['history'],
          reason: 'history, $reason',
        );
        expect(
          [for (final brand in brands) said(brand, forced, history)],
          c['said'],
          reason: 'said, $reason',
        );
        expect(dump(base), before, reason: 'the base is untouched, $reason');
      }
    });
  });
}
