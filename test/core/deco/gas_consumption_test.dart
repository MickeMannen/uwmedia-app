// SAC and gas time against the Python app: the cases of its
// tests/test_gas_consumption.py, then the parity fixture made by
// tool/python_reference/deco_fixture.py.
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/deco/gas_consumption.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

import '../../helpers/python_reference.dart';

/// A steady dive at [depthM] burning [barPerMin] of tank pressure (not
/// surface-normalised) per tank.
List<Waypoint> _dive(
  double depthM, {
  required double barPerMin,
  int seconds = 600,
  int tanks = 1,
  double startBar = 200.0,
}) {
  final t0 = naive(2026);
  return [
    for (var t = 0; t <= seconds; t += 10)
      Waypoint(
        timestamp: t0.add(Duration(seconds: t)),
        depth: depthM,
        timeSinceStart: t,
        tanks: {
          for (var i = 0; i < tanks; i++)
            'T${i + 1}': TankData(
              pressureBar: startBar - barPerMin * t / 60.0,
              o2Percent: 21.0,
            ),
        },
      ),
  ];
}

void main() {
  group('tests/test_gas_consumption.py', () {
    test(
      'test_sac_is_the_two_minute_pressure_rate_at_the_surface_equivalent',
      () {
        // 3 bar/min at 3 ata = 1.0 bar/min SAC.
        final wps = _dive(20.0, barPerMin: 3.0);
        fillSacAndGtr(wps);
        // The first 30 s: nothing yet ("wait").
        expect(wps[3].pressureSac, isNull);
        // Less than half the window collected.
        expect(wps[6].pressureSac, isNull);
        expect(wps.last.pressureSac, closeTo(1.0, 0.02));
      },
    );

    test('test_gtr_counts_reserve_and_the_ascent_at_10m_per_min', () {
      final wps = _dive(20.0, barPerMin: 3.0, seconds: 300);
      fillSacAndGtr(wps, reserveBar: 50.0);
      final wp = wps.last;
      final pressure = wp.tanks['T1']!.pressureBar; // 185 bar
      const ascentMin = 2.0; // 20 m at 10 m/min
      const pAscent = 1.0 * ascentMin * 2.0; // SAC x minutes x 2 ata
      final expectedMin = (pressure! - 50.0 - pAscent) / (1.0 * 3.0);
      expect(wp.airRemaining! / 60.0, closeTo(expectedMin, 0.5));
    });

    test('test_sidemount_pair_sums_both_tanks_and_keeps_a_reserve_in_each', () {
      // 2 bar/min total at 2 ata = 1.0 SAC.
      final wps = _dive(10.0, barPerMin: 1.0, seconds: 300, tanks: 2);
      fillSacAndGtr(wps, reserveBar: 50.0);
      final wp = wps.last;
      expect(wp.pressureSac, closeTo(1.0, 0.02));
      final total = wp.tanks.values.fold(0.0, (sum, t) => sum + t.pressureBar!);
      final expectedMin = (total - 100.0 - 1.0 * 1.0 * 1.5) / (1.0 * 2.0);
      expect(wp.airRemaining! / 60.0, closeTo(expectedMin, 0.5));
    });

    test('test_logged_values_are_left_alone', () {
      final wps = _dive(20.0, barPerMin: 3.0, seconds: 300);
      wps.last.pressureSac = 9.9;
      wps.last.airRemaining = 42;
      fillSacAndGtr(wps);
      expect((wps.last.pressureSac, wps.last.airRemaining), (9.9, 42));
      expect(wps[wps.length - 2].pressureSac, isNotNull);
    });
  });

  group('parity with the Python fill', () {
    final cases = jsonObjects(
      pythonReference('deco/deco_cases.json')['sac_gtr'],
    );
    for (final c in cases) {
      test(c['name'] as String, () {
        final waypoints = [
          for (final w in jsonObjects(c['waypoints'])) Waypoint.fromJson(w),
        ];
        final args = c['args'] as Map<String, dynamic>;
        fillSacAndGtr(
          waypoints,
          reserveBar:
              (args['reserve_bar'] as num?)?.toDouble() ?? defaultReserveBar,
          windowSec: args['window_sec'] as int? ?? sacWindowSec,
          warmupSec: args['warmup_sec'] as int? ?? sacWarmupSec,
        );
        // Rounded to two decimals and to whole seconds in both, so exact.
        expect([for (final wp in waypoints) wp.pressureSac], c['pressure_sac']);
        expect([
          for (final wp in waypoints) wp.airRemaining,
        ], c['air_remaining']);
      });
    }
  });

  test('pySum is the compensated sum Python uses', () {
    // Left to right these give 0.0 and 0.30000000000000004.
    expect(pySum([1e100, 1.0, -1e100]), 1.0);
    expect(pySum([0.1, 0.1, 0.1]), 0.30000000000000004);
    expect(pySum([0.1, 0.2, 0.3, -0.6]), 2.7755575615628914e-17);
    expect(pySum([]), 0.0);
  });

  group('VSAC from the tank sizes (spec §10.54)', () {
    test('the gas used in two minutes at the surface equivalent', () {
      // 3 bar/min at 3 ata from an 11.1 l tank: 1.0 bar/min, 11.1 l/min.
      final wps = _dive(20.0, barPerMin: 3.0);
      fillVolumeSac(wps, {'T1': 11.1});
      expect(wps[3].volumeSac, isNull);
      expect(wps[6].volumeSac, isNull);
      expect(wps.last.volumeSac, closeTo(11.1, 0.01));
    });

    test('two tanks of their own sizes add up', () {
      // Each drains 3 bar/min at 3 ata: (11.1 + 7) / 3 per minute.
      final wps = _dive(20.0, barPerMin: 3.0, tanks: 2);
      fillVolumeSac(wps, {'T1': 11.1, 'T2': 7.0});
      expect(wps.last.volumeSac, closeTo(18.1, 0.01));
    });

    test('nothing without every size, or when the log has VSAC', () {
      final unsized = _dive(20.0, barPerMin: 3.0, tanks: 2);
      fillVolumeSac(unsized, {'T1': 11.1});
      expect(unsized.map((wp) => wp.volumeSac), everyElement(isNull));

      final none = _dive(20.0, barPerMin: 3.0);
      fillVolumeSac(none, {});
      expect(none.map((wp) => wp.volumeSac), everyElement(isNull));

      final logged = _dive(20.0, barPerMin: 3.0);
      logged[40].volumeSac = 15.0;
      fillVolumeSac(logged, {'T1': 11.1});
      expect(logged.last.volumeSac, isNull);
      expect(logged[40].volumeSac, 15.0);
    });
  });
}
