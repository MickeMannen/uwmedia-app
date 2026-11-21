// The values no log records (MOD, a Shearwater's gas time remaining) and
// the notices against the Python app: the cases of its tests/test_hud_gas.py
// and tests/test_hud_notices.py that are not the renderer's, then the
// parity fixture made by tool/python_reference/notices_fixture.py.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/rules/hud_gas.dart';
import 'package:uwmedia_app/core/rules/hud_notices.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

import '../../helpers/dive_parity.dart';
import '../../helpers/python_reference.dart';

final _rulesFile = File('assets/hud_rules.json');
final HudRules rules = HudRules(
  jsonDecode(_rulesFile.readAsStringSync()) as Map<String, dynamic>,
);
final _start = naive(2026, 1, 1, 10);

/// The `_wp` of tests/test_hud_notices.py: no tanks unless given.
Waypoint _wp(
  int t,
  double depth, {
  double? po2,
  int? cns,
  int? ndl,
  double? ascentRate,
  double? decoStopDepth,
  double? nextStopDepth,
  int? nextStopTime,
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
  ndl: ndl,
  ascentRate: ascentRate,
  decoStopDepth: decoStopDepth,
  nextStopDepth: nextStopDepth,
  nextStopTime: nextStopTime,
  diveAlerts: diveAlerts,
  tanks: tanks,
);

/// The `_wp` of tests/test_hud_gas.py: one tank T1.
Waypoint _gasWp(
  int t,
  double depth, {
  double bar = 200.0,
  double o2 = 32.0,
  int? cns,
  double? decoStopDepth,
}) => _wp(
  t,
  depth,
  cns: cns,
  decoStopDepth: decoStopDepth,
  tanks: {'T1': TankData(pressureBar: bar, o2Percent: o2, name: 'T1')},
);

Map<int, Notice?> _timeline(String brand, String model, List<Waypoint> wps) =>
    noticeTimeline(rules, brand, model, wps)!;

Notice? _notice(String brand, String? model, Waypoint wp) =>
    activeNotice(rules, brand, model, wp);

Notice? _persistent(Waypoint wp) =>
    activePersistentNotice(rules, 'Shearwater', 'Perdix 2', wp);

/// A fixture column of [value, count] runs, expanded.
List<dynamic> _expand(Object? runs) => [
  for (final run in runs! as List<dynamic>)
    for (var i = 0; i < ((run as List<dynamic>)[1] as int); i++) run[0],
];

void main() {
  group('tests/test_hud_gas.py', () {
    // The gradient factor and deco pass cases are the deco engine's; the
    // renderer's cases come with the renderer.
    test('test_mod_from_the_gas_and_the_brand_limit', () {
      // Perdix 2 manual p.62: OC MOD PPO2 1.40 -> Nx32 33.75 m, air 56.7 m
      double? mod(Waypoint wp) =>
          modMetres(rules, 'Shearwater', 'Perdix 2', wp);
      expect(mod(_gasWp(0, 20.0)), closeTo(33.75, 0.01));
      expect(mod(_gasWp(0, 20.0, o2: 21.0)), closeTo(56.67, 0.01));
      expect(mod(_wp(0, 20.0)), isNull);
    });

    test('test_persistent_mod_notices_follow_the_depth', () {
      expect(_persistent(_gasWp(0, 20.0)), isNull);
      // Within 1.9 m below the 33.75 m MOD.
      final near = _persistent(_gasWp(0, 32.5))!;
      expect(near.id, 'near_mod');
      expect(near.text, 'MOD\n34m');
      expect(near.color, '#FFFF00');
      final over = _persistent(_gasWp(0, 35.0))!;
      expect(over.id, 'mod_exceeded');
      expect(over.text, 'MOD\n34m\n↑');
      expect(over.color, '#FF0000');
      // Listed first: it outranks the MOD box.
      expect(_persistent(_gasWp(0, 35.0, cns: 101))!.id, 'high_cns_box');
    });

    test('test_shearwater_gtr_from_the_pressure_trend', () {
      // Perdix 2 manual p.44-45: SAC over the last two minutes at 1 ATA;
      // gas after the reserve (50 bar) and a 10 m/min ascent, over SAC x
      // Pamb. 1.4 bar/min at 1 ATA at 20 m (3 ATA): the tank drops 4.2
      // bar/min.
      final wps = [
        for (var t = 0; t <= 300; t += 10)
          _gasWp(t, 20.0, bar: 200.0 - 4.2 * t / 60.0),
      ];
      int? gtr(String brand, String model, Waypoint wp, List<Waypoint> all) =>
          gasTimeRemaining(rules, brand, model, wp, all);
      // 60 s: still "wait"
      expect(gtr('Shearwater', 'Perdix 2', wps[6], wps), isNull);
      const pressure = 200.0 - 4.2 * 5;
      // 2 min of ascent at the mean of 3 and 1 ATA
      const pAscent = 1.4 * 2.0 * 2.0;
      const expected = (pressure - 50.0 - pAscent) / (1.4 * 3.0) * 60;
      expect(
        gtr('Shearwater', 'Perdix 2', wps.last, wps),
        closeTo(expected, 60),
      );
      // Not for a Descent (its ATR is logged), not during deco.
      expect(gtr('Garmin', 'mk3i', wps.last, wps), isNull);
      final deco = [
        for (var t = 0; t <= 300; t += 10)
          _gasWp(t, 20.0, bar: 200.0 - 4.2 * t / 60.0, decoStopDepth: 6.0),
      ];
      expect(gtr('Shearwater', 'Perdix 2', deco.last, deco), isNull);
    });
  });

  group('tests/test_hud_notices.py', () {
    test('test_shearwater_notice_table_is_in_priority_order_and_sourced', () {
      final list = noticeRules(rules, 'Shearwater', 'Perdix 2');
      final ids = [for (final r in list) r['id']];
      // Each PPO2 limit twice: open circuit and on the loop.
      expect(ids.sublist(0, 6), [
        'low_ppo2',
        'low_ppo2_cc',
        'high_ppo2',
        'high_ppo2_cc',
        'missed_stop',
        'fast_ascent',
      ]);
      // Off by default on the device (manual p.24).
      expect(ids, isNot(contains('time_alert')));
      expect(list.every((r) => '${r['_source'] ?? ''}'.isNotEmpty), isTrue);
      final style = noticeStyle(rules, 'Shearwater', 'Perdix 2');
      expect(style['style'], 'text');
      expect(style['confirm_text'], 'Confirm');
      expect(style.containsKey('_source'), isFalse);
    });

    test('test_high_ppo2_needs_thirty_seconds_then_shows_for_show_seconds', () {
      // Perdix 2 manual p.22: HIGH PPO2 once the PPO2 is above the limit
      // for more than 30 s; a log has no button press, so it shows 10 s.
      final wps = [
        for (var t = 0; t < 200; t += 5)
          _wp(t, 30.0, po2: t >= 100 ? 1.8 : 1.2),
      ];
      final tl = _timeline('Shearwater', 'Perdix 2', wps);
      expect(tl[100], isNull);
      expect(tl[125], isNull);
      expect(tl[130]!.text, 'HIGH PPO2');
      expect(tl[130]!.caption, 'Warning');
      expect(tl[130]!.color, '#FFFF00');
      expect(tl[135]!.id, 'high_ppo2');
      expect(tl[140], isNull);
      expect(
        activeNotice(
          rules,
          'Shearwater',
          'Perdix 2',
          wps[26],
          waypoints: wps,
        )!.id,
        'high_ppo2',
      );
    });

    test('test_fast_ascent_is_sustained_and_rearms', () {
      final wps = [
        for (var t = 0; t < 120; t += 2)
          _wp(
            t,
            20.0,
            ascentRate: (20 <= t && t < 40) || (80 <= t && t < 100)
                ? 14.0
                : 2.0,
          ),
      ];
      final tl = _timeline('Shearwater', 'Perdix 2', wps);
      expect(tl[28], isNull);
      expect(tl[30]!.text, 'FAST ASCENT');
      expect(tl[50], isNull);
      // The second episode fires again.
      expect(tl[90]!.text, 'FAST ASCENT');
    });

    test('test_low_ndl_alert_rearms_three_minutes_above_the_value', () {
      // Perdix 2 manual p.24: 5 min alert, resets once the NDL is 8 min.
      final tl = _timeline('Shearwater', 'Perdix 2', [
        _wp(0, 20.0, ndl: 600),
        _wp(10, 20.0, ndl: 290),
        _wp(30, 20.0, ndl: 280),
        _wp(40, 10.0, ndl: 420),
        _wp(50, 15.0, ndl: 280),
        _wp(60, 5.0, ndl: 500),
        _wp(70, 20.0, ndl: 250),
      ]);
      expect(tl[10]!.text, 'Low NDL Alert');
      expect(tl[10]!.caption, 'Alert');
      // Shown 10 s, not re-armed (the NDL never reached 8 min).
      expect(tl[30], isNull);
      expect(tl[50], isNull);
      // Re-armed by the 500 s NDL in between.
      expect(tl[70]!.text, 'Low NDL Alert');
    });

    test('test_critical_pressure_names_the_tank_and_outranks_low_ndl', () {
      final tanks = {'T1': TankData(pressureBar: 24.0, enabled: true)};
      final tl = _timeline('Shearwater', 'Perdix 2', [
        _wp(0, 20.0, ndl: 600),
        _wp(10, 20.0, ndl: 200, tanks: tanks),
      ]);
      // Both trigger at t=10; Low NDL Alert is listed first.
      expect(tl[10]!.text, 'Low NDL Alert');
      expect(
        _notice('Shearwater', 'Perdix 2', _wp(0, 20.0, tanks: tanks))!.text,
        'T1 CRITICAL PRES',
      );
    });

    test('test_single_waypoint_evaluation_for_forced_states', () {
      String? text(String brand, String? model, Waypoint wp) =>
          _notice(brand, model, wp)?.text;
      expect(
        text('Shearwater', 'Perdix 2', _wp(0, 20.0, po2: 0.15)),
        'LOW PPO2',
      );
      expect(text('Shearwater', 'Perdix 2', _wp(0, 20.0, cns: 95)), 'HIGH CNS');
      expect(
        text('Shearwater', 'Perdix 2', _wp(0, 20.0, cns: 160)),
        'VERY HIGH CNS',
      );
      expect(text('Shearwater', 'Perdix 2', _wp(0, 41.0)), 'Depth Alert');
      expect(text('Shearwater', 'Perdix 2', _wp(0, 20.0)), isNull);
      final alert = _wp(0, 20.0, diveAlerts: ['ndl_reached']);
      expect(
        text('Garmin', 'mk3i', alert),
        'NDL exceeded. Decompression now required.',
      );
      // Two lines on the X50i.
      expect(text('Garmin', 'x50i', alert), 'NDL exceeded.\nDeco required.');
      expect(text('UnknownMfg', null, _wp(0, 20.0, po2: 0.1)), isNull);
    });

    test(
      'test_garmin_fit_alerts_drive_the_notices_with_the_manual_wording',
      () {
        final tl = _timeline('Garmin', 'mk3i', [
          _wp(0, 20.0),
          _wp(10, 20.0, diveAlerts: ['approaching_ndl']),
          _wp(15, 20.0),
          _wp(
            30,
            20.0,
            diveAlerts: ['cns_warning', 'ascent_critical'],
            cns: 80,
          ),
          _wp(45, 20.0),
        ]);
        expect(tl[10]!.text, 'Approaching NDL');
        expect(tl[15]!.text, 'Approaching NDL');
        // Listed before the CNS warning.
        expect(tl[30]!.text, 'Ascending too fast. Slow your ascent.');
        expect(tl[45], isNull);
      },
    );

    test('test_teric_info_events_fire_on_state_transitions', () {
      // Teric manual p.26: "Deco Needed" when deco is required, "Deco
      // Clear" once it is over; p.25: "Safety Stop" when the stop counts.
      final tl = _timeline('Shearwater', 'Teric', [
        _wp(0, 30.0, ndl: 300),
        _wp(10, 30.0, ndl: 60),
        _wp(20, 30.0, decoStopDepth: 3.0, nextStopDepth: 3.0, nextStopTime: 60),
        _wp(40, 20.0, decoStopDepth: 3.0, nextStopDepth: 3.0, nextStopTime: 30),
        _wp(60, 5.0, ndl: 600),
      ]);
      expect(tl[20]!.text, 'Deco Needed');
      expect(tl[20]!.caption, 'INFO');
      expect(tl[20]!.color, '#00ADED');
      expect(tl[40], isNull);
      expect(tl[60]!.text, 'Deco Clear');
      expect(tl[60]!.color, '#00C800');
      expect(noticeStyle(rules, 'Shearwater', 'Teric')['style'], 'banner');
    });

    // Mk3 EN-US manual p.24 / p.36, X50i p.13 / p.27: when the two
    // sidemount tanks differ by more than the Switch Pressure, "Breathe
    // from <tank>." appears; nothing while they are within the threshold,
    // and the alert re-arms once they are again.
    test('test_garmin_sidemount_pages_say_which_tank_to_breathe_from', () {
      final rule = rules.getRuleConfig(
        'Garmin',
        'mk3i',
        'sidemount_switch',
      ) as Map<String, dynamic>;
      expect(rule['threshold_bar'], 30.0);
      expect(rule['color'] as String, startsWith('#'));
      Map<String, TankData> pair(double t1, double t2) => {
        'T1': TankData(pressureBar: t1, name: 'T1', enabled: true),
        'T2': TankData(pressureBar: t2, name: 'T2', enabled: true),
      };
      final even = pair(150.0, 140.0);
      final skewed = pair(100.0, 140.0);
      expect(
        rules.sidemountSwitchTarget(
          'Garmin',
          'mk3i',
          _wp(0, 20.0, tanks: even),
        ),
        isNull,
      );
      expect(
        rules.sidemountSwitchTarget(
          'Garmin',
          'x50i',
          _wp(0, 20.0, tanks: skewed),
        ),
        'secondary',
      );
      final wps = [
        _wp(0, 20.0, tanks: even),
        _wp(10, 20.0, tanks: skewed),
        _wp(15, 20.0, tanks: skewed),
        _wp(40, 20.0, tanks: skewed),
        _wp(50, 20.0, tanks: even),
        _wp(60, 20.0, tanks: skewed),
      ];
      final tl = _timeline('Garmin', 'mk3i', wps);
      expect(tl[0], isNull);
      // The side and the transceiver name, as the X50i prints it; the
      // first tank is the left one.
      expect(tl[10]!.text, 'Breathe from Right Tank (T2).');
      expect(tl[15]!.text, 'Breathe from Right Tank (T2).');
      // Shown for show_seconds, then gone although the difference remains.
      expect(tl[40], isNull);
      // Re-armed after the tanks were even again.
      expect(tl[60]!.text, 'Breathe from Right Tank (T2).');
      // The X50i's own notice list has it too.
      expect(
        _timeline('Garmin', 'x50i', wps)[10]!.text,
        'Breathe from Right Tank (T2).',
      );
      final left = _timeline('Garmin', 'x50i', [
        _wp(0, 20.0, tanks: even),
        _wp(10, 20.0, tanks: pair(176.0, 140.0)),
      ]);
      expect(left[10]!.text, 'Breathe from Left Tank (T1).');
      // The X50i's blue border.
      expect(left[10]!.color, '#00AAFF');
    });
  });

  group('the notice timeline is kept per unit system', () {
    // Python caches one timeline per dive whatever the system in force
    // (spec §10.19); here a dive rendered in both gets each its own.
    test('a stop depth in a notice follows the units asked for', () {
      final wps = [
        _wp(0, 30.0),
        _wp(
          10,
          2.0,
          decoStopDepth: 6.0,
          nextStopDepth: 6.0,
          nextStopTime: 60,
          diveAlerts: ['deco_ceiling_broken'],
        ),
      ];
      String? at(UnitSystem units) =>
          noticeTimeline(rules, 'Garmin', 'x50i', wps, units: units)![10]?.text;
      expect(at(UnitSystem.metric), startsWith('DESCEND TO 6 m\n'));
      expect(at(UnitSystem.imperial), startsWith('DESCEND TO 20 ft\n'));
      expect(at(UnitSystem.metric), startsWith('DESCEND TO 6 m\n'));
    });
  });

  group('parity with the Python notices and gas values', () {
    final reference = pythonReference('rules/notices_cases.json');

    test('assets/hud_rules.json is the file the fixture was made from', () {
      expect(
        sha256.convert(_rulesFile.readAsBytesSync()).toString(),
        reference['hud_rules_sha256'],
      );
    });

    test('notice_rules, persistent_notice_rules and notice_style', () {
      for (final c in jsonObjects(reference['notice_rules'])) {
        final brand = c['manufacturer'] as String?;
        final model = c['model'] as String?;
        expect(
          [for (final r in noticeRules(rules, brand, model)) r['id']],
          c['ids'],
          reason: '$brand/$model',
        );
        expect(
          [for (final r in persistentNoticeRules(rules, brand, model)) r['id']],
          c['persistent_ids'],
          reason: '$brand/$model persistent',
        );
        expect(noticeStyle(rules, brand, model), c['style']);
      }
    });

    for (final c in jsonObjects(reference['dives'])) {
      test('${c['name']}', () {
        final dive = Dive.fromJson(c['dive'] as Map<String, dynamic>);
        final wps = dive.waypoints;
        final fractions = _expand(c['gas_o2_fraction']);
        for (var i = 0; i < wps.length; i++) {
          final expected = fractions[i] as num?;
          final got = gasO2Fraction(wps[i]);
          expected == null
              ? expect(got, isNull)
              : expect(got, nearly(expected), reason: 'O2 fraction at $i');
        }
        for (final r in jsonObjects(c['results'])) {
          final brand = r['manufacturer'] as String?;
          final model = r['model'] as String?;
          final units = normalizeUnits(r['units']);
          final where = '$brand/$model ${units.key}';
          final notice = _expand(r['notice']);
          final alone = _expand(r['notice_alone']);
          final persistent = _expand(r['persistent']);
          final gasTime = _expand(r['gas_time']);
          final mod = _expand(r['mod']);
          for (var i = 0; i < wps.length; i++) {
            final wp = wps[i];
            final at = '$where at ${wp.timeSinceStart} s';
            expect(
              activeNotice(
                rules,
                brand,
                model,
                wp,
                waypoints: wps,
                units: units,
              )?.toJson(),
              notice[i],
              reason: 'notice, $at',
            );
            expect(
              activeNotice(rules, brand, model, wp, units: units)?.toJson(),
              alone[i],
              reason: 'notice from the waypoint alone, $at',
            );
            expect(
              activePersistentNotice(
                rules,
                brand,
                model,
                wp,
                waypoints: wps,
                units: units,
              )?.toJson(),
              persistent[i],
              reason: 'persistent notice, $at',
            );
            expect(
              gasTimeRemaining(rules, brand, model, wp, wps),
              gasTime[i],
              reason: 'gas time, $at',
            );
            final expectedMod = mod[i] as num?;
            final gotMod = modMetres(rules, brand, model, wp);
            expectedMod == null
                ? expect(gotMod, isNull, reason: 'MOD, $at')
                : expect(gotMod, nearly(expectedMod), reason: 'MOD, $at');
          }
        }
      });
    }
  });
}
