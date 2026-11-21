// The parsers' deco pass. Python has three copies of it; the port has one
// with the UDDF copy's rules (spec §10.16). Two parity fixtures, both made
// by tool/python_reference/deco_fixture.py:
// - `uddf_rules`: the UDDF parser's inline block run from its own source,
//   which is the oracle for the port's pass;
// - `deco_pass`: parsers/deco_pass.py on dives where its rules give the
//   same as the UDDF ones, except SurfGF, which it leaves out.
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/deco/deco_engine.dart';
import 'package:uwmedia_app/core/deco/deco_pass.dart';
import 'package:uwmedia_app/core/model/dive.dart';

import '../../helpers/python_reference.dart';

Matcher _near(num expected) =>
    closeTo(expected, expected.abs() * 1e-12 + 1e-12);

/// Runs the pass on a fixture case and checks every field it can change,
/// except `surf_gf` when [surfGf] is false.
List<Waypoint> _runAndCheck(Map<String, dynamic> c, {required bool surfGf}) {
  final waypoints = [
    for (final w in jsonObjects(c['waypoints'])) Waypoint.fromJson(w),
  ];
  final gases = [
    for (final g in jsonObjects(c['gases']))
      GasDefinition(
        g['name'] as String,
        (g['f_o2'] as num).toDouble(),
        (g['f_he'] as num).toDouble(),
        (g['mod_meters'] as num).toDouble(),
      ),
  ];
  final gf = c['file_gf'] as List<dynamic>?;
  applyDecoAndGas(
    waypoints,
    gases,
    fileGf: gf == null
        ? null
        : ((gf[0] as num).toDouble(), (gf[1] as num).toDouble()),
    fileLogsStops: c['file_logs_stops'] as bool? ?? false,
  );

  final after = c['after'] as Map<String, dynamic>;
  List<dynamic> column(String name) => after[name] as List<dynamic>;
  // Whole numbers, and values rounded in both: exact.
  expect([for (final wp in waypoints) wp.tts], column('tts'));
  expect([for (final wp in waypoints) wp.cns], column('cns'));
  expect([
    for (final wp in waypoints) wp.nextStopTime,
  ], column('next_stop_time'));
  expect([
    for (final wp in waypoints) wp.airRemaining,
  ], column('air_remaining'));
  expect([for (final wp in waypoints) wp.po2], column('po2'));
  expect([for (final wp in waypoints) wp.gf], column('gf'));
  expect([for (final wp in waypoints) wp.pressureSac], column('pressure_sac'));
  expect([
    for (final wp in waypoints) wp.nextStopDepth,
  ], column('next_stop_depth'));
  if (surfGf) {
    expect([for (final wp in waypoints) wp.surfGf], column('surf_gf'));
  }
  for (var i = 0; i < waypoints.length; i++) {
    for (final (name, value) in [
      ('ceiling', waypoints[i].ceiling),
      ('deco_stop_depth', waypoints[i].decoStopDepth),
    ]) {
      final expected = column(name)[i] as num?;
      expect(
        value,
        expected == null ? isNull : _near(expected),
        reason: '$name of waypoint $i',
      );
    }
  }
  return waypoints;
}

void main() {
  final reference = pythonReference('deco/deco_cases.json');

  group('parity with the UDDF parser\'s block (parsers/uddf.py)', () {
    for (final c in jsonObjects(reference['uddf_rules'])) {
      test(c['name'] as String, () {
        _runAndCheck(c, surfGf: true);
      });
    }
  });

  group('parity with parsers/deco_pass.py', () {
    for (final c in jsonObjects(reference['deco_pass'])) {
      test(c['name'] as String, () {
        final waypoints = _runAndCheck(c, surfGf: false);
        // deco_pass.py leaves SurfGF out; the port sets it from the engine,
        // as the UDDF and Subsurface copies do.
        final after = c['after'] as Map<String, dynamic>;
        expect(
          (after['surf_gf'] as List<dynamic>).every((v) => v == null),
          isTrue,
        );
        expect([for (final wp in waypoints) wp.surfGf], c['surf_gf']);
      });
    }

    test('parseGf', () {
      for (final c in jsonObjects(reference['parse_gf'])) {
        final gf = parseGf(
          (c['low'] as num?)?.toDouble(),
          (c['high'] as num?)?.toDouble(),
        );
        final expected = c['expected'] as List<dynamic>?;
        expect(gf == null ? null : [gf.$1, gf.$2], expected, reason: '$c');
      }
    });

    test('decoGas', () {
      for (final c in jsonObjects(reference['deco_gas'])) {
        final gas = decoGas(
          c['name'] as String,
          (c['o2_percent'] as num).toDouble(),
          (c['he_percent'] as num).toDouble(),
        );
        final expected = c['expected'] as Map<String, dynamic>;
        expect(gas.name, expected['name']);
        expect(gas.fO2, expected['f_o2']);
        expect(gas.fHe, expected['f_he']);
        expect(gas.modMeters, _near(expected['mod_meters'] as num));
      }
    });
  });
}
