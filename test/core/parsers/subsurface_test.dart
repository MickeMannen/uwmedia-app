// The Subsurface XML parser against the Python app: the cases of its
// tests/test_subsurface_parsing.py and tests/test_subsurface.py on the same
// file texts (kept in the fixture under the test's name), then every parsed
// field against the fixture made by
// tool/python_reference/subsurface_fixture.py.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/core/parsers/subsurface.dart';
import 'package:uwmedia_app/core/parsers/subsurface_text.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

import '../../helpers/dive_parity.dart';
import '../../helpers/python_reference.dart';

final Map<String, dynamic> _reference = pythonReference(
  'dives/subsurface.json',
);
final List<Map<String, dynamic>> _cases = jsonObjects(_reference['parse']);

Map<String, dynamic> _case(String name) =>
    _cases.singleWhere((c) => c['name'] == name);

Uint8List _bytesOf(Map<String, dynamic> c) =>
    base64Decode(c['bytes_base64'] as String);

TankConfig _tanksOf(Map<String, dynamic> c) => TankConfig({
  for (final entry
      in (c['tank_config'] as Map<String, dynamic>? ?? const {}).entries)
    entry.key: entry.value as String,
});

/// The dives of the fixture file called [name].
List<Dive> _parse(String name) {
  final c = _case(name);
  return parseSubsurface(
    _bytesOf(c),
    '/logs/${c['file_name']}',
    tanks: _tanksOf(c),
  );
}

int _ttsAtBottom(String? decoModel) =>
    _parse('deco model: ${decoModel ?? 'None'}').single.waypoints[25].tts!;

const _oddCase =
    'semi-closed, events out of order and of one second, a switch to oxygen, '
    'a zero setpoint, a cylinder out of range';

void main() {
  group('tests/test_subsurface_parsing.py', () {
    test('test_parse_time_str', () {
      for (final (text, seconds) in [
        ('45:20 min', 45 * 60 + 20),
        ('1:02:03', 3723),
        ('1.5 min', 90),
        ('30 s', 30),
        ('42', 42),
        (' 7.9 ', 7),
        ('soon', 0),
        // Neither mm:ss nor h:mm:ss.
        ('1:2:3:4', 0),
      ]) {
        expect(parseTimeStr(text), seconds, reason: text);
      }
    });

    test('test_parse_depth_str', () {
      for (final (text, metres) in [
        ('12.5 m', 12.5),
        ('33 ft', 33 * 0.3048),
        ('7', 7.0),
        ('deep', 0.0),
      ]) {
        expect(parseDepthStr(text), closeTo(metres, 1e-9), reason: text);
      }
    });

    test('test_parse_temp_str', () {
      for (final (text, celsius) in [
        ('28.5 C', 28.5),
        ('50 F', 10.0),
        ('300.15 K', 27.0),
        ('21', 21.0),
        ('cold', 0.0),
      ]) {
        expect(parseTempStr(text), closeTo(celsius, 1e-9), reason: text);
      }
    });

    test('test_parse_pressure_str', () {
      for (final (text, bar) in [
        ('200.0 bar', 200.0),
        ('3000 psi', 3000 * 0.0689476),
        ('150', 150.0),
        ('full', 0.0),
      ]) {
        expect(parsePressureStr(text), closeTo(bar, 1e-9), reason: text);
      }
    });

    test('test_parse_gas_percent', () {
      for (final (text, fallback, percent) in [
        ('32.0%', 21.0, 32.0),
        ('0.32', 21.0, 32.0),
        ('50', 21.0, 50.0),
        (null, 21.0, 21.0),
        ('', 0.0, 0.0),
        ('rich', 21.0, 21.0),
      ]) {
        expect(
          parseGasPercent(text, fallback),
          closeTo(percent, 1e-9),
          reason: '$text',
        );
      }
    });

    test('test_dive_metadata_site_and_duration', () {
      final [first, second, third] = _parse(
        'test_dive_metadata_site_and_duration',
      );
      expect(first.startTime, naive(2026, 1, 1, 9, 30));
      expect(first.endTime, naive(2026, 1, 1, 9, 34));
      // The dive's own duration attribute.
      expect(first.durationSeconds, 300);
      expect((first.startLatitude, first.startLongitude), (12.3456, 98.7654));
      expect(
        (first.device, first.manufactor),
        ('Shearwater Perdix 2', 'Shearwater'),
      );
      expect(first.maxDepth, 10.0);

      // From the samples when not given.
      expect(second.durationSeconds, 300);
      expect((second.startLatitude, second.startLongitude), (null, null));
      expect(
        (second.device, second.manufactor),
        ('Garmin Descent Mk3i', 'Garmin'),
      );
      expect(second.maxDepth, 20.0);

      expect(third.manufactor, isNull);
      expect(third.startLatitude, isNull);
    });

    for (final gps in ['north east', '1.0', '1.0 2.0 3.0']) {
      test('test_unreadable_site_gps_is_ignored[$gps]', () {
        final dive = _parse('test_unreadable_site_gps_is_ignored[$gps]').single;
        expect((dive.startLatitude, dive.startLongitude), (null, null));
      });
    }

    for (var i = 0; i < 4; i++) {
      test('test_dives_without_a_usable_start_are_skipped[$i]', () {
        final dive = _parse('test_dives_without_a_usable_start_are_skipped[$i]')
            .single;
        expect(dive.startTime, naive(2026, 1, 3, 7));
        expect(dive.maxDepth, 8.0);
      });
    }

    test('test_dives_without_a_dive_computer_or_samples_are_skipped', () {
      expect(
        _parse('test_dives_without_a_dive_computer_or_samples_are_skipped'),
        isEmpty,
      );
    });

    test('test_samples_units_temperature_and_po2', () {
      final dive = _parse('test_samples_units_temperature_and_po2').single;
      final wps = dive.waypoints;
      expect([for (final wp in wps) wp.timeSinceStart], [0, 60, 120, 180]);
      expect(wps[1].depth, closeTo(66 * 0.3048, 1e-9));
      expect(dive.maxDepth, closeTo(66 * 0.3048, 1e-9));
      final temps = [for (final wp in wps) wp.temp!];
      for (final (i, expected) in [25.0, 25.0, 26.0, 26.0].indexed) {
        expect(temps[i], closeTo(expected, 1e-9));
      }
      // A bad value keeps the last.
      expect([for (final wp in wps) wp.po2], [1.25, 1.25, 1.25, 1.25]);
    });

    test('test_water_temperature_from_the_dive_computer_header', () {
      final dive = _parse(
        'test_water_temperature_from_the_dive_computer_header',
      ).single;
      expect(dive.waypoints.every((wp) => wp.temp == 27.5), isTrue);
    });

    test('test_non_monotonic_trailing_sample_is_dropped', () {
      final dive = _parse('test_non_monotonic_trailing_sample_is_dropped')
          .single;
      expect(dive.waypoints.last.timeSinceStart, 240);
      expect(dive.endTime, naive(2026, 1, 1, 10, 4));
    });

    test('test_ndl_tts_gf_battery_and_no_invented_stop', () {
      final wp = _parse('test_ndl_tts_gf_battery_and_no_invented_stop')
          .single
          .waypoints[1];
      expect((wp.ndl, wp.tts, wp.gf, wp.battery), (1200, 90, 35.5, 3.9));
      expect(
        (wp.decoStopDepth, wp.nextStopTime, wp.nextStopDepth),
        (0.0, 0, 0.0),
      );
    });

    test('test_cylinders_live_pressures_and_sensor_names', () {
      final dive = _parse('test_cylinders_live_pressures_and_sensor_names')
          .single;
      final [w0, w1, w2] = dive.waypoints;
      // Tank keys: the sensor id for cylinder 1, the description otherwise,
      // else the 1-based index.
      expect(w0.tanks.keys.toSet(), {'0000001', '2', '3'});
      final t1 = w1.tanks['0000001']!;
      expect(t1.pressureBar, closeTo(2900 * 0.0689476, 1e-9));
      expect((t1.o2Percent, t1.hePercent, t1.name), (32.0, 0.0, 'AL80'));
      final t2 = w2.tanks['2']!;
      expect(t2.pressureBar, 190.0);
      expect((t2.o2Percent, t2.hePercent, t2.name), (18.0, 45.0, 'Mix 2'));
      // Carried forward.
      expect(w1.tanks['2']!.pressureBar, 200.0);
      // Only a start pressure and no live readings: stays at the start.
      expect(
        [for (final wp in dive.waypoints) wp.tanks['3']!.pressureBar],
        [200.0, 200.0, 200.0],
      );
    });

    test('test_cylinder_description_is_the_tank_key_without_a_sensor', () {
      final dive = _parse(
        'test_cylinder_description_is_the_tank_key_without_a_sensor',
      ).single;
      final pressures = [
        for (final wp in dive.waypoints) wp.tanks['Left']!.pressureBar!,
      ];
      for (final (i, expected) in [200.0, 150.0, 100.0].indexed) {
        expect(pressures[i], closeTo(expected, 1e-9));
      }
    });

    test('test_the_files_own_gradient_factors_drive_the_recompute', () {
      final standard = _ttsAtBottom(null);
      expect(standard, greaterThan(0));
      expect(_ttsAtBottom('Buhlmann ZHL-16C GF 30/70'), standard);
      expect(_ttsAtBottom('GF 100/100'), lessThan(standard));
      expect(_ttsAtBottom('GF 20 / 50'), greaterThan(standard));
      // Low above high: ignored.
      expect(_ttsAtBottom('GF 85/40'), standard);
      expect(_ttsAtBottom('VPM-B +3'), standard);
    });

    test('test_no_cylinders_recomputes_on_air', () {
      final wp = _parse('test_no_cylinders_recomputes_on_air')
          .single
          .waypoints[2];
      expect(wp.tts, isNotNull);
      expect(wp.ceiling, isNotNull);
      expect(wp.po2, closeTo(0.21 * 3.01, 0.02));
      expect(wp.tanks, isEmpty);
    });

    test('test_a_failed_recompute_still_returns_the_dive', () {
      // An O2 of 0 % cannot give a MOD: the recompute is skipped, the
      // samples stay.
      final dive = _parse('test_a_failed_recompute_still_returns_the_dive')
          .single;
      expect(dive.maxDepth, 10.0);
      expect(dive.waypoints.every((wp) => wp.ceiling == null), isTrue);
      expect(dive.waypoints.last.tanks['1']!.pressureBar, closeTo(150.0, 1e-9));
    });

    test('test_unreadable_values_with_a_unit_fall_back', () {
      expect(parseTimeStr('ab:cd min'), 0);
      expect(parseDepthStr('abc m'), 0.0);
      expect(parseDepthStr('x ft'), 0.0);
      expect(parseTempStr('x C'), 0.0);
      expect(parsePressureStr('x bar'), 0.0);
      expect(parseGasPercent('x%', 21.0), 21.0);
    });

    test('test_an_unreadable_gf_or_battery_is_empty_not_fatal', () {
      final wp = _parse('test_an_unreadable_gf_or_battery_is_empty_not_fatal')
          .single
          .waypoints[1];
      expect((wp.depth, wp.battery), (10.0, null));
      // Empty, so the recompute fills it in: GF99 is 0 one minute into a
      // 10 m dive, and SurfGF comes along with it.
      expect(wp.gf, 0.0);
      expect(wp.surfGf, isNotNull);
    });

    test('test_rebreather_cells_are_held_between_samples', () {
      final dive = _parse('test_rebreather_cells_are_held_between_samples')
          .single;
      expect(
        [for (final wp in dive.waypoints) (wp.po2_1, wp.po2_2, wp.po2_3)],
        [(0.7, 0.71, 0.69), (0.7, 1.3, 0.69), (0.7, 1.3, 0.69)],
      );
    });

    test('test_rebreather_loop_bailout_setpoint_and_gases', () {
      final [w0, w1, w2, _] = _parse(
        'test_rebreather_loop_bailout_setpoint_and_gases',
      ).single.waypoints;
      expect([w0.circuit, w1.circuit, w2.circuit], ['CC', 'CC', 'BO']);
      expect((w0.setpoint, w0.po2, w1.setpoint), (0.7, 0.68, 1.3));
      expect((w2.setpoint, w2.po2), (null, 1.0));
      expect((w1.gasmix, w2.gasmix), ('18/45', 'Nx50'));
      // Kept for DilPO2 after the bailout.
      expect((w2.diluentO2Percent, w2.diluentHePercent), (18.0, 45.0));
      expect(w1.tanks['Oxy']!.o2Percent, 100.0);
    });

    test('test_rebreather_modechange_events_set_the_circuit', () {
      final wps = _parse('test_rebreather_modechange_events_set_the_circuit')
          .single
          .waypoints;
      expect([for (final w in wps) w.circuit], ['CC', 'BO', 'CC', 'CC']);
    });

    test('test_open_circuit_gas_changes_and_two_cylinders_with_one_name', () {
      final wps = _parse(
        'test_open_circuit_gas_changes_and_two_cylinders_with_one_name',
      ).single.waypoints;
      expect([for (final w in wps) w.gasmix], ['AIR', 'Nx50', 'Nx50']);
      expect([for (final w in wps) w.circuit], ['OC', 'OC', 'OC']);
      expect(wps[0].tanks.keys.toSet(), {'AL80', 'AL80 (2)'});
    });
  });

  group('tests/test_subsurface.py', () {
    // test_missing_file: reading the file is the caller's job in the port.

    test('test_deco_stop_prefers_logged_value_over_recompute', () {
      final dive = _parse('tests/test_subsurface.py deco and summary pressure')
          .single;
      final wp = dive.waypoints.firstWhere((wp) => wp.timeSinceStart == 300);
      expect(wp.decoStopDepth, 6.0);
      expect(wp.nextStopTime, 120);
    });

    test('test_cylinder_pressure_interpolates_when_no_live_samples', () {
      final waypoints = _parse(
        'tests/test_subsurface.py deco and summary pressure',
      ).single.waypoints;
      final key = waypoints.first.tanks.keys.first;
      expect(waypoints.first.tanks[key]!.pressureBar, closeTo(200.0, 1e-9));
      expect(waypoints.last.tanks[key]!.pressureBar, closeTo(120.0, 1e-9));
      final mid = waypoints.firstWhere((wp) => wp.timeSinceStart == 300);
      expect(mid.tanks[key]!.pressureBar, closeTo(160.0, 1e-9));
    });
  });

  group('parity with the Python parser', () {
    for (final c in _cases) {
      final name = c['name'] as String;
      test(name, () {
        final bytes = _bytesOf(c);
        final path = '/logs/${c['file_name']}';
        final tanks = _tanksOf(c);
        final dives = parseSubsurface(bytes, path, tanks: tanks);
        final expected = jsonObjects(c['dives']);
        expect(dives, hasLength(expected.length));
        expect(detectLogFormat(path, bytes), c['format']);
        expect(
          [
            for (final d in parseLogFile(path, bytes, tanks: tanks)!)
              d.logFormat,
          ],
          [for (final _ in expected) 'subsurface_xml'],
        );

        var depthless = 0;
        var templess = 0;
        var pressureless = 0;
        for (var i = 0; i < dives.length; i++) {
          final dive = dives[i];
          final want = Map<String, dynamic>.of(expected[i]);
          if (name == _oddCase && i == 0) {
            // tts='soon': Python reads 0 and keeps it; the port reads no
            // TTS and takes the recompute's (spec §10.8).
            final waypoints = [
              for (final w in jsonObjects(want['waypoints']))
                Map<String, dynamic>.of(w),
            ];
            expect(waypoints[2]['tts'], 0);
            expect(dive.waypoints[2].tts, greaterThan(0));
            waypoints[2]['tts'] = dive.waypoints[2].tts;
            want['waypoints'] = waypoints;
          }
          expect(dive.logPath, path);
          expect(
            dive.maxDepth,
            nearly(want.remove('max_depth_property') as num),
          );
          expect(dive.isCcr, want.remove('is_ccr'));
          expect([
            for (final wp in dive.waypoints) wp.circuit,
          ], want.remove('circuits'));
          expect([
            for (final wp in dive.waypoints) wp.gasmix,
          ], want.remove('gasmixes'));
          final counts = expectDiveMatchesPython(dive, want, reason: 'dive $i');
          depthless += counts.depthless;
          templess += counts.templess;
          pressureless += counts.pressureless;
        }
        // What is null in the port and 0 in Python (spec §10.8): only the
        // odd file has samples without a readable depth or temperature
        // ('x m', no depth at all, 'cold', a header of 'x'); a cylinder
        // without a start pressure is in several.
        expect(depthless, name == _oddCase ? 2 : 0, reason: 'depth');
        expect(templess, name == _oddCase ? 2 : 0, reason: 'temperature');
        if (name == _oddCase) {
          expect(pressureless, greaterThan(0));
        }
      });
    }
  });

  group('parity with the Python helpers', () {
    test('the unit parsers', () {
      for (final c in jsonObjects(_reference['parse_time_str'])) {
        expect(parseTimeStr(c['text'] as String), c['expected'], reason: '$c');
      }
      for (final c in jsonObjects(_reference['parse_depth_str'])) {
        expect(
          parseDepthStr(c['text'] as String),
          nearly(c['expected'] as num),
          reason: '$c',
        );
      }
      for (final c in jsonObjects(_reference['parse_temp_str'])) {
        expect(
          parseTempStr(c['text'] as String),
          nearly(c['expected'] as num),
          reason: '$c',
        );
      }
      for (final c in jsonObjects(_reference['parse_pressure_str'])) {
        expect(
          parsePressureStr(c['text'] as String),
          nearly(c['expected'] as num),
          reason: '$c',
        );
      }
      for (final c in jsonObjects(_reference['parse_gas_percent'])) {
        expect(
          parseGasPercent(
            c['text'] as String?,
            (c['default'] as num).toDouble(),
          ),
          nearly(c['expected'] as num),
          reason: '$c',
        );
      }
    });

    test('the tank configuration (utils/config.py)', () {
      final c = _reference['tank_config'] as Map<String, dynamic>;
      final config = TankConfig({
        for (final entry in (c['tanks'] as Map<String, dynamic>).entries)
          entry.key: entry.value as String,
      });
      for (final entry
          in (c['map_tank_name'] as Map<String, dynamic>).entries) {
        expect(config.mapTankName(entry.key), entry.value, reason: entry.key);
      }
      for (final o in jsonObjects(c['order_tanks'])) {
        expect(
          config.orderTanks([
            for (final k in o['keys'] as List<dynamic>) k as String,
          ]),
          o['expected'],
          reason: '$o',
        );
      }
    });
  });

  group('tests/test_config.py, the mapping itself', () {
    test('test_nothing_to_load', () {
      final config = TankConfig();
      expect(config.tanks, isEmpty);
      expect(config.mapTankName('123'), '123');
    });

    test('test_save_adds_new_serials_and_keeps_names', () {
      final config = TankConfig({'200': 'Left'})
          .withSerials(['300', '200', '100']);
      expect(config.tanks, {
        '100': 'Tank 100',
        '200': 'Left',
        '300': 'Tank 300',
      });
      // The tank order is kept, new serials go last.
      expect(config.tanks.keys, ['200', '100', '300']);
    });

    test('test_tank_order_is_the_mapping_order', () {
      final config = TankConfig({'222': 'Left', '111': 'Right', '333': 'Left'});
      expect(config.tanks.entries.map((e) => (e.key, e.value)), [
        ('222', 'Left'),
        ('111', 'Right'),
        ('333', 'Left'),
      ]);
      // By name; unlisted tanks last, as they came.
      expect(config.orderTanks(['9', 'Right', '5', 'Left']), [
        'Left',
        'Right',
        '9',
        '5',
      ]);
      expect(config.orderTanks([]), isEmpty);
    });

    test('test_rename_and_remove_write_through', () {
      var config = TankConfig().withTankName('555', 'Stage');
      expect(config.tanks, {'555': 'Stage'});
      config = config.withoutTank('555').withoutTank('never-there');
      expect(config.tanks, isEmpty);
    });
  });

  test('a cylinder without a reading has no pressure, not zero', () {
    final dive = parseSubsurface(
      utf8.encode(
        "<divelog><dives><dive date='2026-01-01' time='10:00:00'>"
        "<cylinder description='A' /><cylinder description='B' start='0 bar' />"
        "<divecomputer><sample time='0:00 min' depth='1 m' pressure1='x' />"
        '</divecomputer></dive></dives></divelog>',
      ),
      '/logs/a.ssrf',
    ).single;
    final tanks = dive.waypoints.single.tanks;
    expect(tanks['A']!.pressureBar, isNull);
    // An unreadable live reading replaces the start pressure with none.
    expect(tanks['B']!.pressureBar, isNull);
    expect(dive.waypoints.single.primaryTankPressure, isNull);
  });
}
