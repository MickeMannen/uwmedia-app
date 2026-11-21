// The deco engine against the Python app: the pytest cases that cover
// utils/deco_engine.py (in tests/test_hud_gas.py, tests/test_ccr.py and
// tests/test_dive_plan_engine.py), then the parity fixture made by
// tool/python_reference/deco_fixture.py.
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/deco/deco_engine.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

import '../../helpers/python_reference.dart';

// Tissue pressures, ceilings and the like are sums and products of the same
// doubles in the same order as in Python, so they agree to the last bits on
// one machine; the tolerance leaves room for another platform's exp().
const _relative = 1e-12;

Matcher _near(num expected) =>
    closeTo(expected, expected.abs() * _relative + 1e-12);

final _start = naive(2026, 1, 1, 10);

DecoWaypoint _wp(
  int t,
  double depth, {
  double? setpoint,
  double? diluentO2Percent,
  double? diluentHePercent,
}) => DecoWaypoint(
  divetime: t,
  depth: depth,
  datetime: _start.add(Duration(seconds: t)),
  setpoint: setpoint,
  diluentO2Percent: diluentO2Percent,
  diluentHePercent: diluentHePercent,
);

const _air = [GasDefinition('AIR', 0.21, 0.0, 56.0)];

void main() {
  group('tests/test_hud_gas.py', () {
    test('test_gradient_factor_is_zero_fresh_and_grows_with_loading', () {
      final e = BuhlmannEngine();
      // Saturated at the surface: tissue tension equals ambient.
      expect(e.gradientFactor(e.surfacePressure), 0.0);
      e.update(30.0, 20 * 60, 0.21, 0.0);
      final gf99 = e.gradientFactor(e.surfacePressure + 3.0);
      final surf = e.gradientFactor(e.surfacePressure);
      // At depth the tissues are still below ambient: on-gassing.
      expect(gf99, 0.0);
      expect(surf, inExclusiveRange(60, 130));
      // A safety stop lowers SurfGF.
      e.update(5.0, 3 * 60, 0.21, 0.0);
      expect(e.gradientFactor(e.surfacePressure), lessThan(surf));
    });

    test(
      'test_deco_pass_fills_gf99_and_surf_gf_instead_of_the_placeholder',
      () {
        final wps = [
          for (var t = 0; t < 1800; t += 10)
            _wp(t, 60 <= t && t <= 1500 ? 30.0 : 0.0),
        ];
        final res = DiveDecompressor(simulationInterval: 10)
            .processWaypoints(wps, _air);
        final bottom = res[1200]!;
        expect(bottom.gfCurrent, 0.0);
        expect(bottom.surfGf, greaterThan(50));
        final surface = res[1790]!;
        expect(surface.gfCurrent, greaterThan(0));
        // At the surface the two coincide.
        expect((surface.gfCurrent - surface.surfGf).abs(), lessThan(0.2));
      },
    );
  });

  group('tests/test_ccr.py', () {
    test('test_the_deco_recompute_follows_the_loop', () {
      double depthAt(int t) => 120 <= t && t <= 1800
          ? 30.0
          : t == 0
          ? 0.0
          : 15.0;
      const times = [0, 120, 1800, 1900];
      final oc = DiveDecompressor().processWaypoints([
        for (final t in times) _wp(t, depthAt(t)),
      ], _air);
      final cc = DiveDecompressor().processWaypoints([
        for (final t in times)
          _wp(
            t,
            depthAt(t),
            setpoint: 1.3,
            diluentO2Percent: 21.0,
            diluentHePercent: 0.0,
          ),
      ], _air);
      expect(cc[1800]!.po2, 1.3);
      expect(cc[1800]!.ceilingMeters, lessThan(oc[1800]!.ceilingMeters));
      expect(cc[1800]!.ttsSeconds, lessThan(oc[1800]!.ttsSeconds));
    });
  });

  group('tests/test_dive_plan_engine.py', () {
    test('test_mod_meters_air', () {
      expect(modMeters(0.21), closeTo(56.6, 0.2));
    });

    test('test_ccr_effective_fractions_holds_setpoint', () {
      final (fO2, fHe) = ccrEffectiveFractions(1.3, 4.0, 0.18, 0.35);
      expect(fO2, closeTo(1.3 / 4.0, 1e-9));
      const dilInert = 1.0 - 0.18;
      expect(fHe, closeTo((1.0 - fO2) * (0.35 / dilInert), 1e-9));
    });

    test('test_compute_ndl_seconds_air_18m_in_expected_range', () {
      final ndl = BuhlmannEngine().computeNdlSeconds(
        depthMeters: 18.0,
        fO2: 0.21,
        fHe: 0.0,
        gf: 0.85,
      );
      expect(ndl, isNotNull);
      expect(ndl, inInclusiveRange(30 * 60, 80 * 60));
    });

    // test_compute_ndl_seconds_zero_at_surface asserts nothing in Python
    // ("is None or True"); the fixture below pins the value (null).
  });

  group('parity with the Python engine', () {
    final reference = pythonReference('deco/deco_cases.json');

    for (final c in jsonObjects(reference['engine'])) {
      test('tissues, ceilings and gradient factors: ${c['name']}', () {
        final surface = (c['surface_pressure'] as num?)?.toDouble();
        final engine = surface == null
            ? BuhlmannEngine()
            : BuhlmannEngine(surfacePressureBar: surface);
        final states = jsonObjects(c['states']);
        final steps = c['steps'] as List<dynamic>;

        void check(Map<String, dynamic> state, String at) {
          final pN2 = state['p_n2'] as List<dynamic>;
          final pHe = state['p_he'] as List<dynamic>;
          for (var i = 0; i < 16; i++) {
            expect(engine.pN2[i], _near(pN2[i] as num), reason: '$at N2 $i');
            expect(engine.pHe[i], _near(pHe[i] as num), reason: '$at He $i');
          }
          expect(engine.cns, _near(state['cns'] as num), reason: '$at cns');
          final ceilings = state['ceilings'] as Map<String, dynamic>;
          for (final gf in ceilings.keys) {
            expect(
              engine.getCeiling(double.parse(gf)),
              _near(ceilings[gf] as num),
              reason: '$at ceiling at GF $gf',
            );
          }
          final factors = state['gradient_factors'] as Map<String, dynamic>;
          for (final extra in factors.keys) {
            expect(
              engine.gradientFactor(
                engine.surfacePressure + double.parse(extra),
              ),
              _near(factors[extra] as num),
              reason: '$at gradient factor at surface + $extra bar',
            );
          }
        }

        check(states.first, 'fresh');
        for (var i = 0; i < steps.length; i++) {
          final step = [
            for (final v in steps[i] as List<dynamic>) (v as num).toDouble(),
          ];
          engine.update(step[0], step[1], step[2], step[3]);
          check(states[i + 1], 'after step ${i + 1}');
        }
      });
    }

    test('cnsIncrement', () {
      for (final c in jsonObjects(reference['cns_increment'])) {
        expect(
          cnsIncrement(
            (c['po2'] as num).toDouble(),
            (c['seconds'] as num).toDouble(),
          ),
          _near(c['expected'] as num),
          reason: '$c',
        );
      }
    });

    test('ccrEffectiveFractions', () {
      for (final c in jsonObjects(reference['ccr_effective_fractions'])) {
        final (fO2, fHe) = ccrEffectiveFractions(
          (c['setpoint'] as num).toDouble(),
          (c['ambient'] as num).toDouble(),
          (c['dil_o2'] as num).toDouble(),
          (c['dil_he'] as num).toDouble(),
        );
        final expected = c['expected'] as List<dynamic>;
        expect(fO2, _near(expected[0] as num), reason: '$c');
        expect(fHe, _near(expected[1] as num), reason: '$c');
      }
    });

    test('modMeters', () {
      for (final c in jsonObjects(reference['mod_meters'])) {
        final fO2 = (c['f_o2'] as num).toDouble();
        final maxPo2 = (c['max_po2'] as num?)?.toDouble();
        expect(
          maxPo2 == null ? modMeters(fO2) : modMeters(fO2, maxPo2: maxPo2),
          _near(c['expected'] as num),
          reason: '$c',
        );
      }
    });

    for (final c in jsonObjects(reference['ndl'])) {
      test('computeNdlSeconds: ${c['name']}', () {
        final engine = BuhlmannEngine();
        for (final raw in c['steps'] as List<dynamic>) {
          final step = [
            for (final v in raw as List<dynamic>) (v as num).toDouble(),
          ];
          engine.update(step[0], step[1], step[2], step[3]);
        }
        final args = c['args'] as Map<String, dynamic>;
        final before = List<double>.of(engine.pN2);
        final ndl = engine.computeNdlSeconds(
          depthMeters: (args['depth_meters'] as num).toDouble(),
          fO2: (args['f_o2'] as num).toDouble(),
          fHe: (args['f_he'] as num).toDouble(),
          gf: (args['gf'] as num).toDouble(),
          stepSeconds: (args['step_seconds'] as num?)?.toDouble() ?? 10.0,
          capSeconds: args['cap_seconds'] as int? ?? 99 * 60,
        );
        expect(ndl, c['expected']);
        expect(engine.pN2, before, reason: 'the look-ahead works on a copy');
      });
    }

    for (final c in jsonObjects(reference['process_waypoints'])) {
      test('processWaypoints: ${c['name']}', () {
        final args = c['decompressor'] as Map<String, dynamic>;
        final decompressor = DiveDecompressor(
          gfLow: (args['gf_low'] as num?)?.toDouble() ?? 0.30,
          gfHigh: (args['gf_high'] as num?)?.toDouble() ?? 0.70,
          simulationInterval: args['simulation_interval'] as int? ?? 10,
        );
        final gases = [
          for (final g in jsonObjects(c['gases']))
            GasDefinition(
              g['name'] as String,
              (g['f_o2'] as num).toDouble(),
              (g['f_he'] as num).toDouble(),
              (g['mod_meters'] as num).toDouble(),
            ),
        ];
        final runs = c['runs'] as List<dynamic>;
        final expectedRuns = jsonObjects(c['results']);

        for (var run = 0; run < runs.length; run++) {
          final results = decompressor.processWaypoints([
            for (final w in jsonObjects(runs[run]))
              DecoWaypoint(
                divetime: w['divetime'] as int,
                depth: (w['depth'] as num).toDouble(),
                datetime: parseNaive(w['datetime'] as String),
                setpoint: (w['setpoint'] as num?)?.toDouble(),
                diluentO2Percent: (w['diluent_o2_percent'] as num?)?.toDouble(),
                diluentHePercent: (w['diluent_he_percent'] as num?)?.toDouble(),
              ),
          ], gases);
          final expected = expectedRuns[run];
          final count = expected['count'] as int;
          expect(results.keys, [
            for (var s = 0; s < count; s++) s,
          ], reason: 'run $run: one result per second, in order');
          expect(
            [for (var s = 0; s < count; s++) results[s]!.ttsSeconds],
            expected['tts_seconds'],
            reason: 'run $run: TTS for every second',
          );

          final every = expected['sample_every'] as int;
          final samples = expected['samples'] as Map<String, dynamic>;
          List<dynamic> column(String name) => samples[name] as List<dynamic>;
          var i = 0;
          for (var s = 0; s < count; s += every, i++) {
            final r = results[s]!;
            final at = 'run $run, second $s';
            expect(
              formatNaive(r.timestamp),
              column('timestamp')[i],
              reason: at,
            );
            expect(r.activeGas, column('active_gas')[i], reason: at);
            expect(r.depth, _near(column('depth')[i] as num), reason: at);
            expect(
              r.ceilingMeters,
              _near(column('ceiling_meters')[i] as num),
              reason: '$at ceiling',
            );
            // Rounded to one decimal in both, so exact.
            expect(r.gfCurrent, column('gf_current')[i], reason: '$at GF99');
            expect(r.surfGf, column('surf_gf')[i], reason: '$at SurfGF');
            expect(r.cns, _near(column('cns')[i] as num), reason: '$at CNS');
            expect(r.po2, _near(column('po2')[i] as num), reason: '$at PO2');
          }
          expect(i, column('depth').length, reason: 'run $run: all samples');
        }
      });
    }
  });
}
