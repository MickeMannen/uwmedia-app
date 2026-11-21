// The Suunto app JSON export parser against the Python app: the cases of
// its tests/test_suunto.py on the same export texts (kept in the fixture),
// then every parsed field, the registry's detection and the Dive Profile
// Builder's gases and switches against the fixture made by
// tool/python_reference/suunto_fixture.py.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/core/parsers/suunto.dart';
import 'package:uwmedia_app/core/plan/dive_plan.dart';
import 'package:uwmedia_app/core/plan/dive_plan_import.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

import '../../helpers/dive_parity.dart';
import '../../helpers/python_reference.dart';

final Map<String, dynamic> _reference = pythonReference('dives/suunto.json');
final List<Map<String, dynamic>> _cases = jsonObjects(_reference['parse']);

Map<String, dynamic> _case(String name) =>
    _cases.singleWhere((c) => (c['name'] as String).startsWith(name));

Uint8List _bytesOf(Map<String, dynamic> c) =>
    base64Decode(c['bytes_base64'] as String);

String _pathOf(Map<String, dynamic> c) => '/logs/${c['file_name']}';

List<Dive>? _parse(String name) {
  final c = _case(name);
  return parseLogFile(_pathOf(c), _bytesOf(c));
}

Uint8List _head(Uint8List bytes) => bytes.length > logHeadSize
    ? Uint8List.sublistView(bytes, 0, logHeadSize)
    : bytes;

void main() {
  group('tests/test_suunto.py', () {
    test('test_detect_suunto_json_only', () {
      final eon = _case('EON Core');
      expect(
        detectLogFormat(_pathOf(eon), _head(_bytesOf(eon))),
        suuntoJsonFormat,
      );
      final other = _case('another JSON file: settings');
      expect(detectLogFormat(_pathOf(other), _head(_bytesOf(other))), isNull);
      expect(parseLogFile(_pathOf(other), _bytesOf(other)), isNull);
    });

    test('test_eon_units_and_values', () {
      final dive = _parse('EON Core')!.single;
      expect(dive.logFormat, suuntoJsonFormat);
      expect(dive.device, 'EON Core');
      expect(dive.manufactor, 'Suunto');
      expect(dive.startTime, naive(2026, 5, 2, 10));
      expect(dive.timezone, 'UTC+07:00');
      expect(
        [for (final wp in dive.waypoints) wp.timeSinceStart],
        [10, 20, 30, 50, 90],
      );

      final first = dive.waypoints[0];
      expect(first.temp, closeTo(20.0, 1e-9));
      expect(first.ndl, 6000);
      expect(first.tts, 60);
      expect(first.ceiling, 0.0);
      expect(first.airRemaining, 3000);
      expect(first.rmv, closeTo(12.0, 1e-9));
      expect(first.tanks['T1']!.pressureBar, closeTo(195.0, 1e-9));
      expect(first.tanks['T1']!.o2Percent, 32.0);
      expect(first.gasmix, 'Nx32');

      final deco = dive.waypoints[2];
      // The 30.4 s record falls in the same second: the first is kept.
      expect(deco.depth, 30.0);
      expect(deco.ndl, 0);
      expect(deco.ceiling, 6.0);
      expect(deco.decoStopDepth, 6.0);
      // The logged ceiling is the stop, not rounded up to the next 3 m.
      expect(deco.nextStopDepth, 6.0);
      expect(deco.temp, closeTo(20.0, 1e-9)); // carried forward
      expect(deco.tanks['T1']!.pressureBar, closeTo(180.0, 1e-9));
    });

    test('test_eon_events_and_gas_switch', () {
      final wps = _parse('EON Core')!.single.waypoints;
      final at6m = wps[3];
      expect(at6m.diveAlerts, ['deco_ceiling_broken', 'suunto:Ceiling Broken']);
      expect(at6m.gasO2Percent, 50.0);
      expect(at6m.gasmix, 'Nx50');
      expect(at6m.ndl, isNull); // -1: no value
      expect(wps.last.tts, greaterThan(0)); // 0 is no value: the deco pass
      expect(wps.take(3).every((wp) => wp.diveAlerts.isEmpty), isTrue);
    });

    test('test_nautic_shape', () {
      final dive = _parse('Nautic, tests')!.single;
      expect(dive.device, 'Nautic');
      final wps = dive.waypoints;
      // The 150 s surface reading is after DiveTime.
      expect([for (final wp in wps) wp.timeSinceStart], [5, 20, 60]);
      expect(
        {for (final e in wps[0].tanks.entries) e.key: e.value.pressureBar},
        {'T1': 200.0, 'T2': 190.0},
      );
      expect(wps[0].airRemaining, 1200);
      expect(wps[0].rmv, closeTo(15.0, 1e-9));
      expect(wps[0].gasO2Percent, isNull); // no gas list: the mix is unknown
      expect(wps[1].temp, closeTo(27.0, 1e-9));
      expect(wps[1].diveAlerts, ['po2_crit_high', 'suunto:PO2 High']);
      expect(wps.last.secondaryTankPressure, closeTo(140.0, 1e-9));
    });

    test('test_not_a_dive_and_empty', () {
      final run = _case('not a dive: a run');
      expect(
        detectLogFormat(_pathOf(run), _head(_bytesOf(run))),
        suuntoJsonFormat,
      );
      expect(parseLogFile(_pathOf(run), _bytesOf(run)), isEmpty);
      final empty = _case('no samples');
      expect(parseSuunto(_bytesOf(empty), _pathOf(empty)), isEmpty);
    });

    test('test_builder_import', () {
      final c = _case('EON Core');
      final dive = parseLogFile(_pathOf(c), _bytesOf(c))!.first;
      final parts = loggedPlanParts(_pathOf(c), _bytesOf(c), dive);
      expect(
        [
          for (final g in parts.gases)
            (g.name, g.tankRef, g.tankSizeL, g.startPressureBar),
        ],
        [('EAN32', 'T1', 12.0, 200.0), ('EAN50', 'T2', 5.7, null)],
      );
      expect(parts.switches, [(0, 'EAN32'), (40, 'EAN50')]);
      expect(parts.waterTempC, closeTo(20.0, 1e-9));
    });
  });

  test('isSuuntoJson', () {
    for (final item in _reference['is_suunto_json'] as List<dynamic>) {
      final [head, want] = item as List<dynamic>;
      expect(isSuuntoJson(head as String), want, reason: head);
    }
  });

  group('every export against Python', () {
    for (final c in _cases) {
      final name = c['name'] as String;
      test(name, () {
        final path = _pathOf(c);
        final bytes = _bytesOf(c);
        expect(detectLogFormat(path, _head(bytes)), c['format']);
        if (c.containsKey('raise')) {
          // Python's TypeError for a time with and one without a zone.
          expect(() => parseLogFile(path, bytes), throwsFormatException);
          return;
        }
        final dives = parseLogFile(path, bytes);
        final want = c['dives'] as List<dynamic>?;
        if (want == null) {
          expect(dives, isNull);
          return;
        }
        expect(dives, hasLength(want.length));
        for (final (i, dive) in dives!.indexed) {
          final expected = Map<String, dynamic>.of(
            want[i] as Map<String, dynamic>,
          );
          expect(dive.logFormat, suuntoJsonFormat);
          expect(dive.logPath, path);
          expect(
            dive.maxDepth,
            nearly(expected.remove('max_depth_property') as num),
          );
          final gasmix = expected.remove('gasmix') as List<dynamic>;
          final gasPercent = expected.remove('gas_percent') as List<dynamic>;
          expect([for (final wp in dive.waypoints) wp.gasmix], gasmix);
          expect([for (final wp in dive.waypoints) wp.gasPercent], gasPercent);
          // SurfGF: set by the port's one shared deco pass, left out by
          // Python's deco_pass.py (spec §10.16).
          expectDiveMatchesPython(
            dive,
            expected,
            reason: name,
            portOnlyWaypointFields: {'surf_gf'},
          );
        }

        if (dives.isEmpty) {
          return;
        }
        final parts = loggedPlanParts(path, bytes, dives.first);
        final wantParts = c['parts'] as Map<String, dynamic>;
        expect({
          'gases': [
            for (final g in parts.gases)
              {
                'name': g.name,
                'o2_percent': g.o2Percent,
                'he_percent': g.hePercent,
                'tank_ref': g.tankRef,
                'tank_size_l': g.tankSizeL,
                'start_pressure_bar': g.startPressureBar,
                'sidemount_pair': g.sidemountPair,
                'right_tank_ref': g.rightTankRef,
                'diluent': g.diluent,
              },
          ],
          'switches': [
            for (final (s, n) in parts.switches) [s, n],
          ],
          'dive_type': parts.diveType,
          'gf_low': parts.gfLow,
          'gf_high': parts.gfHigh,
          'max_po2_bottom': parts.maxPo2Bottom,
          'max_po2_deco': parts.maxPo2Deco,
          'ccr_o2_tank_size_l': parts.ccrO2TankSizeL,
          'ccr_o2_start_pressure_bar': parts.ccrO2StartPressureBar,
          'water_temp_c': parts.waterTempC,
        }, wantParts);

        final [status, wantPlan] = c['plan'] as List<dynamic>;
        DiveProfilePlan run() =>
            planFromLog(path, bytes, dives.first, base: DiveProfilePlan());
        if (status == 'raise') {
          expect(run, throwsA(anything));
        } else {
          expect(run().toJson(), wantPlan);
        }
      });
    }
  });
}
