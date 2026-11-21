// The UDDF parser against the Python app: the cases of its
// tests/test_uddf_parsing.py and tests/test_uddf.py on the same file texts
// (kept in the fixture under the test's name), then every parsed field
// against the fixture made by tool/python_reference/uddf_fixture.py.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/core/parsers/uddf.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

import '../../helpers/dive_parity.dart';
import '../../helpers/python_reference.dart';

final List<Map<String, dynamic>> _cases = jsonObjects(
  pythonReference('dives/uddf.json')['parse'],
);

Map<String, dynamic> _case(String name) =>
    _cases.singleWhere((c) => c['name'] == name);

Uint8List _bytesOf(Map<String, dynamic> c) =>
    base64Decode(c['bytes_base64'] as String);

/// The dives of the fixture file called [name].
List<Dive> _parse(String name) {
  final c = _case(name);
  return parseUddf(_bytesOf(c), '/logs/${c['file_name']}');
}

int _ttsAtBottom(String gradientFactors) =>
    _parse('gradient factors: $gradientFactors').single.waypoints[25].tts!;

void main() {
  group('tests/test_uddf_parsing.py', () {
    test('test_header_metadata_and_basic_samples', () {
      final dive = _parse('test_header_metadata_and_basic_samples').single;
      expect(dive.device, 'Acme One');
      expect(dive.manufactor, 'Acme Diving');
      expect(dive.timezone, isNull);
      expect(dive.logFilename, 'dive.uddf');
      expect(dive.startTime, naive(2026, 1, 1, 10));
      expect(dive.endTime, naive(2026, 1, 1, 10, 4));
      expect(
        [for (final wp in dive.waypoints) wp.timeSinceStart],
        [0, 60, 120, 180, 240],
      );
      expect(
        [for (final wp in dive.waypoints) wp.maxDepth],
        [0.0, 12.0, 12.0, 12.0, 12.0],
      );
      expect(dive.maxDepth, 12.0);
    });

    for (final stamp in [
      '2026-03-04T05:06:07Z',
      '2026-03-04T05:06:07+08:00',
      '2026-03-04T05:06:07-05:30',
      '2026-03-04T05:06:07',
    ]) {
      test('test_datetime_keeps_the_logged_wall_clock_time[$stamp]', () {
        final dive = _parse(
          'test_datetime_keeps_the_logged_wall_clock_time[$stamp]',
        ).single;
        expect(dive.startTime, naive(2026, 3, 4, 5, 6, 7));
      });
    }

    test(
      'test_legacy_date_fields_are_used_when_datetime_is_missing_or_bad',
      () {
        final dives = _parse(
          'test_legacy_date_fields_are_used_when_datetime_is_missing_or_bad',
        );
        expect(
          [for (final d in dives) d.startTime],
          [naive(2025, 7, 9, 14, 30), naive(2025, 7, 9, 14, 30)],
        );
      },
    );

    for (var i = 0; i < 4; i++) {
      test('test_dive_without_a_usable_start_time_is_skipped[$i]', () {
        final dive = _parse(
          'test_dive_without_a_usable_start_time_is_skipped[$i]',
        ).single;
        expect(dive.startTime, naive(2026, 2, 2, 8));
        expect(dive.maxDepth, 7.0);
      });
    }

    test('test_several_dives_per_file_and_dives_without_samples', () {
      final dives = _parse(
        'test_several_dives_per_file_and_dives_without_samples',
      );
      expect([for (final d in dives) d.startTime.hour], [9, 14]);
      expect([for (final d in dives) d.maxDepth], [10.0, 20.0]);
      expect([for (final d in dives) d.timezone], [null, '-300']);
      expect(dives[1].endTime, naive(2026, 1, 1, 14, 4));
    });

    // test_update_timezone_adds_the_tag_once and
    // test_update_timezone_without_a_namespace: update_timezone rewrites the
    // user's log and is not ported (spec §10.11).

    test('test_temperature_kelvin_and_celsius', () {
      final temps = [
        for (final wp in _parse(
          'test_temperature_kelvin_and_celsius',
        ).single.waypoints)
          wp.temp,
      ];
      expect(temps[0], closeTo(28.0, 1e-9));
      expect(temps[1], closeTo(24.5, 1e-9));
      // An unreadable or missing temperature: 0.0 in Python, null in the
      // port (spec §10.8).
      expect(temps.sublist(2), [null, null]);
    });

    test('test_bad_or_missing_divetime_samples_are_skipped', () {
      final dive = _parse('test_bad_or_missing_divetime_samples_are_skipped')
          .single;
      expect(
        [for (final wp in dive.waypoints) wp.timeSinceStart],
        [0, 60, 120],
      );
      expect(dive.maxDepth, 6.0);
    });

    test('test_logged_per_sample_values_are_read', () {
      final wp = _parse('test_logged_per_sample_values_are_read')
          .single
          .waypoints[1];
      expect(wp.ndl, 1200);
      expect(wp.tts, 90);
      expect(wp.gf, 42.5);
      expect(wp.battery, 87.0);
      expect(wp.po2, 1.23);
      // The file's NDL says no stop is owed: the recompute invents none.
      expect(wp.decoStopDepth, 0.0);
      expect(wp.nextStopTime, 0);
      expect(wp.nextStopDepth, 0.0);
    });

    test('test_logged_cns_wins_over_the_recompute', () {
      final dive = _parse('test_logged_cns_wins_over_the_recompute').single;
      expect([for (final wp in dive.waypoints) wp.cns], [37, 38, 38]);
    });

    test('test_po2_persists_and_a_bad_value_keeps_the_last_one', () {
      final dive = _parse(
        'test_po2_persists_and_a_bad_value_keeps_the_last_one',
      ).single;
      expect([for (final wp in dive.waypoints) wp.po2], [1.3, 1.3, 1.3, 0.7]);
    });

    test('test_divemode_as_text', () {
      final dive = _parse('test_divemode_as_text').single;
      expect(
        [for (final wp in dive.waypoints) wp.divemode],
        ['opencircuit', 'opencircuit', 'opencircuit'],
      );
    });

    test('test_decostop_with_bad_attributes_falls_back_to_the_recompute', () {
      final wp = _parse(
        'test_decostop_with_bad_attributes_falls_back_to_the_recompute',
      ).single.waypoints[1];
      expect(wp.decoStopDepth, wp.ceiling);
      expect(wp.nextStopTime, 0);
    });

    test('test_a_file_that_logs_stops_gets_direct_ascent_tts_where_it_logs_none', () {
      final [_, w1, w2, _] = _parse(
        'test_a_file_that_logs_stops_gets_direct_ascent_tts_where_it_logs_none',
      ).single.waypoints;
      expect(
        (w1.decoStopDepth, w1.nextStopTime, w1.nextStopDepth),
        (3.0, 60, 3.0),
      );
      expect((w2.decoStopDepth, w2.nextStopTime), (0.0, 0));
      // 9 m at 9 m/min, no stop.
      expect(w2.tts, 60);
    });

    test('test_tank_pressures_pascal_bar_bad_and_unreferenced', () {
      final dive = _parse('test_tank_pressures_pascal_bar_bad_and_unreferenced')
          .single;
      final first = dive.waypoints[0].tanks;
      // The unreadable T3 is dropped.
      expect(first.keys.toSet(), {'T1', 'T2'});
      expect(first['T1']!.pressureBar, closeTo(200.0, 1e-9));
      expect(first['T2']!.pressureBar, closeTo(199.5, 1e-9));
      expect(
        (first['T1']!.o2Percent, first['T1']!.hePercent, first['T1']!.name),
        (18.0, 45.0, 'Tx 18/45'),
      );
      final second = dive.waypoints[1].tanks;
      // No ref: keyed by position.
      expect(second.keys.toSet(), {'1'});
      expect(second['1']!.pressureBar, closeTo(180.0, 1e-9));
      expect(dive.waypoints[2].tanks, isEmpty);
    });

    test('test_tank_gas_defaults_to_air_before_any_switch', () {
      final tank = _parse('test_tank_gas_defaults_to_air_before_any_switch')
          .single
          .waypoints[0]
          .tanks['T1']!;
      expect((tank.o2Percent, tank.hePercent, tank.name), (21.0, 0.0, 'AIR'));
    });

    test('test_mix_defaults_name_and_fractions', () {
      final [w0, w1, _] = _parse('test_mix_defaults_name_and_fractions')
          .single
          .waypoints;
      final t0 = w0.tanks['T1']!;
      expect((t0.name, t0.o2Percent, t0.hePercent), ('m1', 21.0, 0.0));
      expect((w1.tanks['T1']!.name, w1.tanks['T1']!.o2Percent), ('m2', 32.0));
    });

    test('test_no_gas_definitions_recomputes_on_air', () {
      final wp = _parse('test_no_gas_definitions_recomputes_on_air')
          .single
          .waypoints[2];
      expect(wp.ceiling, isNotNull);
      expect(wp.tts, isNotNull);
      expect(wp.po2, closeTo(0.21 * 3.01, 0.02));
    });

    test('test_a_failed_recompute_still_returns_the_dive', () {
      // An O2 fraction of 0 cannot give a MOD: the recompute is skipped,
      // the samples stay.
      final dive = _parse('test_a_failed_recompute_still_returns_the_dive')
          .single;
      expect(dive.maxDepth, 10.0);
      for (final wp in dive.waypoints) {
        expect(wp.ceiling, isNull);
        expect(wp.tts, isNull);
      }
    });

    test('test_the_files_own_gradient_factors_drive_the_recompute', () {
      final standard = _ttsAtBottom('none');
      expect(standard, greaterThan(0));
      // 30/70 is the default.
      expect(_ttsAtBottom('30/70'), standard);
      expect(_ttsAtBottom('100/100'), lessThan(standard));
      expect(_ttsAtBottom('20/50'), greaterThan(standard));
    });

    for (final gf in ['abc/70', '80/40', '0/70', '30/120']) {
      test('test_unusable_gradient_factors_fall_back_to_the_default[$gf]', () {
        expect(_ttsAtBottom(gf), _ttsAtBottom('none'));
      });
    }

    test('test_not_xml_returns_no_dives', () {
      expect(_parse('test_not_xml_returns_no_dives'), isEmpty);
    });

    test('test_an_unreadable_number_is_skipped_not_fatal', () {
      final dive = _parse('test_an_unreadable_number_is_skipped_not_fatal')
          .single;
      expect(
        [for (final wp in dive.waypoints) wp.timeSinceStart],
        [0, 60, 180, 240],
      );
      expect(dive.waypoints[1].depth, 10.0);
      expect(dive.waypoints[2].battery, isNull);
    });

    test('test_shearwater_app_status_and_zero_pressures_are_no_reading', () {
      final [w0, w1, w2] = _parse(
        'test_shearwater_app_status_and_zero_pressures_are_no_reading',
      ).single.waypoints;
      expect(w0.tanks.keys, ['T1']);
      expect(w1.tanks.keys, ['T1']);
      expect(w2.tanks.keys, ['T1', 'T4']);
      expect(w2.tanks['T4']!.pressureBar, 150.0);
      // Another program's 0 bar is kept as it was.
      final other = _parse("another program's zero pressure is kept")
          .single
          .waypoints;
      expect(other[1].tanks['T4']!.pressureBar, 0.0);
    });

    test('test_po2_in_pascal_or_bar', () {
      final dive = _parse('test_po2_in_pascal_or_bar').single;
      expect([for (final wp in dive.waypoints) wp.po2], [0.7, 1.2, 1.2]);
    });

    test('test_measured_cells_and_the_loop_po2', () {
      final [w0, w1, w2, _] = _parse('test_measured_cells_and_the_loop_po2')
          .single
          .waypoints;
      expect((w0.po2_1, w0.po2), (null, 1.3));
      expect((w1.po2_1, w1.po2_2, w1.po2_3, w1.po2), (1.28, 1.31, 1.3, 1.3));
      // Held until the next reading.
      expect(w2.po2_1, 1.28);
    });

    test('test_apd_ppo2_refs_are_the_first_controllers_cells', () {
      final w1 = _parse('test_apd_ppo2_refs_are_the_first_controllers_cells')
          .single
          .waypoints[1];
      expect((w1.po2_1, w1.po2_2, w1.po2_3), (1.28, 1.31, 1.3));
    });

    test('test_rebreather_setpoint_diluent_and_a_tanks_own_mix', () {
      final [w0, w1, w2, _] = _parse(
        'test_rebreather_setpoint_diluent_and_a_tanks_own_mix',
      ).single.waypoints;
      expect([w0.circuit, w1.circuit, w2.circuit], ['CC', 'CC', 'BO']);
      expect((w0.setpoint, w1.setpoint, w2.setpoint), (0.7, 1.3, null));
      expect((w1.po2, w1.gasmix, w2.gasmix), (1.3, '18/45', 'AIR'));
      expect((w2.diluentO2Percent, w2.diluentHePercent), (18.0, 45.0));
      expect(
        (w0.tanks['T1']!.o2Percent, w0.tanks['T2']!.o2Percent),
        (100.0, 18.0),
      );
    });
  });

  group('tests/test_uddf.py', () {
    // test_missing_file: reading the file is the caller's job in the port.

    test('test_decostop_prefers_logged_value_over_recompute', () {
      final wp0 = _parse('tests/test_uddf.py decostop and divemode')
          .single
          .waypoints[0];
      expect(wp0.decoStopDepth, 6.0);
      expect(wp0.nextStopTime, 120);
    });

    test('test_divemode_persists_across_samples_without_one', () {
      final waypoints = _parse('tests/test_uddf.py decostop and divemode')
          .single
          .waypoints;
      expect(waypoints[0].divemode, 'closedcircuit');
      expect(waypoints[1].divemode, 'closedcircuit');
    });

    test('test_parse_sidemount_reads_both_tank_pressures', () {
      final wp = _parse('tests/test_uddf.py multi tank').single.waypoints[0];
      expect(wp.tanks.keys.toSet(), {'T1', 'T2'});
      expect(wp.tanks['T1']!.pressureBar, closeTo(150.0, 1e-9));
      expect(wp.tanks['T2']!.pressureBar, closeTo(145.0, 1e-9));
      expect(wp.primaryTankPressure, closeTo(150.0, 1e-9));
      expect(wp.secondaryTankPressure, closeTo(145.0, 1e-9));
    });
  });

  group('parity with the Python parser', () {
    for (final c in _cases) {
      final name = c['name'] as String;
      test(name, () {
        final bytes = _bytesOf(c);
        final path = '/logs/${c['file_name']}';
        final dives = parseUddf(bytes, path);
        final expected = jsonObjects(c['dives']);
        expect(dives, hasLength(expected.length));
        expect(detectLogFormat(path, bytes), c['format']);
        expect(
          [for (final d in parseLogFile(path, bytes)!) d.logFormat],
          [for (final _ in expected) 'uddf'],
        );

        var depthless = 0;
        for (var i = 0; i < dives.length; i++) {
          final dive = dives[i];
          final want = Map<String, dynamic>.of(expected[i]);
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
          depthless += expectDiveMatchesPython(
            dive,
            want,
            reason: 'dive $i',
          ).depthless;
        }
        // A sample without a <depth>: null in the port, 0.0 in Python
        // (spec §10.8). A missing temperature is likewise null, in most
        // of these files on every sample.
        expect(depthless, name.startsWith('no namespace, CDATA') ? 1 : 0);
      });
    }
  });

  test('a logged temperature of zero is zero, not missing', () {
    Uint8List file(String temperature) => utf8.encode(
      '<uddf><dive><datetime>2026-01-01T10:00:00</datetime><waypoint>'
      '<divetime>0</divetime><depth>5</depth>'
      '<temperature>$temperature</temperature></waypoint></dive></uddf>',
    );
    expect(
      parseUddf(file('0.0'), '/logs/a.uddf').single.waypoints[0].temp,
      0.0,
    );
    expect(
      parseUddf(file('273.15'), '/logs/a.uddf').single.waypoints[0].temp,
      0.0,
    );
    expect(
      parseUddf(file('-1.5'), '/logs/a.uddf').single.waypoints[0].temp,
      -1.5,
    );
  });

  test('a gas mix whose fraction is not a number is an error', () {
    // Python lets the ValueError out of the parser.
    expect(
      () => parseUddf(
        utf8.encode('<uddf><mix id="a"><o2>much</o2></mix></uddf>'),
        '/logs/a.uddf',
      ),
      throwsFormatException,
    );
  });
}
