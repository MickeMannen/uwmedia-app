// The Garmin FIT parser against the Python app: the cases of its
// tests/test_garmin_parsing.py on the same decoded messages (kept in the
// fixture under the test's name), every parsed field against the fixture
// made by tool/python_reference/garmin_fixture.py, and the FIT reader
// against what the Python FIT SDK decodes from the same files.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/parsers/fit_reader.dart';
import 'package:uwmedia_app/core/parsers/garmin.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

import '../../helpers/dive_parity.dart';
import '../../helpers/python_reference.dart';

final Map<String, dynamic> _reference = pythonReference('dives/garmin.json');
final List<Map<String, dynamic>> _cases = jsonObjects(_reference['messages']);

/// What Python's parser sets to 0 when a record has none, and the port
/// leaves null (spec §10.8).
const zeroDefaults = {
  'depth',
  'temp',
  'deco_stop_depth',
  'next_stop_depth',
  'next_stop_time',
  'tts',
  'air_remaining',
  'ascent_rate',
  'n2_tissue_load',
  'pressure_sac',
  'volume_sac',
  'rmv',
  'heart_rate',
  'cns',
};

/// A fixture value as the parser gets it: `{"$utc": ...}` is a UTC instant.
Object? _value(Object? json) => switch (json) {
  {r'$utc': final String text} => DateTime.parse('${text}Z'),
  final Map<String, dynamic> map => {
    for (final entry in map.entries) entry.key: _value(entry.value),
  },
  final List<dynamic> list => [for (final item in list) _value(item)],
  _ => json,
};

FitMessages _messages(Object? json) => {
  for (final entry in (json! as Map<String, dynamic>).entries)
    entry.key: [
      for (final mesg in entry.value as List<dynamic>)
        (_value(mesg)! as Map<String, Object?>),
    ],
};

TankConfig _tanksOf(Map<String, dynamic> c) => TankConfig({
  for (final entry
      in (c['tank_config'] as Map<String, dynamic>? ?? const {}).entries)
    entry.key: entry.value as String,
});

Map<String, dynamic> _case(String name) =>
    _cases.singleWhere((c) => c['name'] == name);

/// The dives of the fixture case called [name].
List<Dive> _parse(String name) {
  final c = _case(name);
  return parseGarminMessages(
    _messages(c['messages']),
    '/logs/dive.fit',
    tanks: _tanksOf(c),
  );
}

void _expectMatchesPython(
  List<Dive> dives,
  List<Map<String, dynamic>> expected, {
  Set<String> ignoreDiveFields = const {},
}) {
  expect(dives, hasLength(expected.length));
  for (var i = 0; i < dives.length; i++) {
    final dive = dives[i];
    final want = Map<String, dynamic>.of(expected[i]);
    expect(dive.maxDepth, nearly(want.remove('max_depth_property') as num));
    expect(dive.isCcr, want.remove('is_ccr'));
    expect([
      for (final wp in dive.waypoints) wp.circuit,
    ], want.remove('circuits'));
    expect([
      for (final wp in dive.waypoints) wp.gasmix,
    ], want.remove('gasmixes'));
    expectDiveMatchesPython(
      dive,
      want,
      reason: 'dive $i',
      ignoreDiveFields: ignoreDiveFields,
      nullWherePythonHasZero: zeroDefaults,
    );
  }
}

void main() {
  group('tests/test_garmin_parsing.py', () {
    test('test_time_helpers', () {
      expect(
        timezoneOffsetMinutes(
          naive(2026, 1, 1, 12),
          DateTime.utc(2026, 1, 1, 10),
        ),
        120,
      );
      // Rounded to the minute.
      expect(
        timezoneOffsetMinutes(
          naive(2026, 1, 1, 15, 30, 20),
          naive(2026, 1, 1, 10),
        ),
        5 * 60 + 30,
      );
    });

    test('test_activity_timing_device_and_records', () {
      final dive = _parse('test_activity_timing_device_and_records').single;
      // The local wall clock.
      expect(dive.startTime, naive(2026, 5, 2, 10));
      expect(dive.endTime, naive(2026, 5, 2, 10, 2));
      expect(dive.timezone, 'UTC+07:00');
      expect((dive.device, dive.manufactor), ('descent_mk3i', 'garmin'));
      // No session message.
      expect(dive.startLatitude, isNull);
      final wps = dive.waypoints;
      expect(
        [for (final wp in wps) wp.timestamp],
        [for (var m = 0; m < 3; m++) naive(2026, 5, 2, 10, m)],
      );
      expect([for (final wp in wps) wp.timeSinceStart], [0, 60, 120]);
      expect([for (final wp in wps) wp.maxDepth], [0.0, 10.0, 10.0]);
      expect(
        (wps[1].temp, wps[1].ndl, wps[1].tts, wps[1].po2),
        (27.0, 1800, 60, 0.6),
      );
      // Recomputed: FIT logs no ceiling.
      expect(wps[1].ceiling, isNotNull);
    });

    test('test_record_defaults_for_missing_fields', () {
      final dive = _parse('test_record_defaults_for_missing_fields').single;
      expect(dive.waypoints, hasLength(2));
      final wp = dive.waypoints[0];
      // Python: (0.0, 0.0, None, 0, 0, 0). What the record does not carry
      // is null in the port (spec §10.8).
      expect(
        (wp.depth, wp.temp, wp.ndl, wp.tts, wp.cns, wp.heartRate),
        (null, null, null, null, null, null),
      );
      // No logged PO2: air at the surface, no made-up constant.
      expect(wp.po2, 0.21);
      expect(wp.tanks, isEmpty);
      expect(wp.diveAlerts, isEmpty);
      expect((dive.device, dive.manufactor), (null, null));
    });

    test('test_missing_ndl_is_unbounded_and_a_logged_zero_is_deco', () {
      final dive = _parse(
        'test_missing_ndl_is_unbounded_and_a_logged_zero_is_deco',
      ).single;
      expect([for (final wp in dive.waypoints) wp.ndl], [1800, null, 0, 1800]);
    });

    test('test_raw_integer_timestamps_are_fit_epoch_seconds', () {
      final dive = _parse('test_raw_integer_timestamps_are_fit_epoch_seconds')
          .single;
      expect(dive.startTime, naive(2026, 5, 2, 10));
      expect(dive.waypoints[1].timestamp, naive(2026, 5, 2, 10, 1));
      expect(dive.waypoints[0].tanks['111']!.pressureBar, 200.0);
      expect(dive.waypoints[1].diveAlerts, ['ndl_reached']);
    });

    test('test_activity_without_local_time_is_utc', () {
      final dive = _parse('test_activity_without_local_time_is_utc').single;
      expect(dive.startTime, naive(2026, 5, 2, 3));
      expect(dive.timezone, 'UTC');
    });

    for (final asInt in ['False', 'True']) {
      test('test_session_is_the_fallback_without_an_activity[$asInt]', () {
        final dive = _parse(
          'test_session_is_the_fallback_without_an_activity[$asInt]',
        ).single;
        expect(dive.startTime, naive(2026, 5, 1, 22));
        expect(dive.endTime, naive(2026, 5, 1, 22, 5));
        expect(dive.timezone, 'UTC-05:00');
        expect((dive.startLatitude, dive.startLongitude), (90.0, -45.0));
        expect((dive.endLatitude, dive.endLongitude), (0.0, null));
      });
    }

    test('test_session_without_local_time_is_utc', () {
      final dive = _parse('test_session_without_local_time_is_utc').single;
      expect(dive.timezone, 'UTC');
      expect(dive.startTime, naive(2026, 5, 2, 3));
      expect(dive.endTime, dive.startTime);
    });

    test('test_no_timing_messages_gives_no_dive', () {
      expect(_parse('test_no_timing_messages_gives_no_dive'), isEmpty);
    });

    test('test_no_records_gives_no_dive', () {
      expect(_parse('test_no_records_gives_no_dive'), isEmpty);
    });

    test('test_tank_updates_merge_onto_records', () {
      final [w0, w1, w2, w3] = _parse('test_tank_updates_merge_onto_records')
          .single
          .waypoints;
      expect(w0.tanks.keys.toSet(), {'111', '222', '7'});
      // Tank 222 is first heard from at 60 s: before that it shows its
      // first reading.
      expect(
        [
          for (final key in ['111', '222', '7']) w0.tanks[key]!.pressureBar,
        ],
        [210.0, 190.0, 180.0],
      );
      expect(
        (w1.tanks['111']!.pressureBar, w1.tanks['222']!.pressureBar),
        (200.0, 190.0),
      );
      // Carried forward.
      expect(w3.tanks['111']!.pressureBar, 200.0);

      final left = w1.tanks['111']!;
      expect(
        (left.name, left.o2Percent, left.hePercent, left.mode, left.enabled),
        ('Left', 32.0, 0.0, 'open_circuit', true),
      );
      final pod = w1.tanks['222']!;
      expect(
        (pod.name, pod.o2Percent, pod.hePercent, pod.mode, pod.enabled),
        ('Tank Pod', 18.0, 45.0, 'closed_circuit_diluent', false),
      );
      final unknown = w2.tanks['7']!;
      expect(
        (unknown.name, unknown.o2Percent, unknown.enabled),
        (null, 21.0, true),
      );
    });

    test('test_tank_order_follows_the_sensor_names_order', () {
      final dive = _parse('test_tank_order_follows_the_sensor_names_order')
          .single;
      for (final wp in dive.waypoints) {
        expect(wp.tanks.keys, ['Left', 'Right', '333']);
      }
      final last = dive.waypoints.last;
      expect(
        (last.primaryTankPressure, last.secondaryTankPressure),
        (190.0, 200.0),
      );
    });

    test('test_dive_alerts_land_on_the_next_record', () {
      final dive = _parse('test_dive_alerts_land_on_the_next_record').single;
      expect(
        [for (final wp in dive.waypoints) wp.diveAlerts],
        [
          <String>[],
          ['59', 'ndl_reached'],
          ['safety_stop_started'],
        ],
      );
    });

    test('test_unmapped_product_id_is_named', () {
      expect(
        _parse('test_unmapped_product_id_is_named').single.device,
        'descent_x50i',
      );
    });

    // test_a_failed_ceiling_recompute_keeps_the_dive replaces Python's
    // engine with one that raises; the Dart engine has no such failure.

    test('test_unique_tank_serials_of_a_synthetic_fit', () {
      final c = jsonObjects(_reference['files']).first;
      final messages = readFitMessages(
        base64Decode(c['bytes_base64'] as String),
      );
      expect(uniqueTankSerials(messages), ['100001']);
      final dive = parseGarminMessages(messages, '/logs/dive.fit').single;
      expect(dive.waypoints[0].tanks.keys.toSet(), {'100001'});
    });

    test('test_tanks_take_the_gas_switched_to', () {
      final [w0, w1, w2, w3] = _parse('test_tanks_take_the_gas_switched_to')
          .single
          .waypoints;
      expect(
        [w0.gasmix, w1.gasmix, w2.gasmix, w3.gasmix],
        ['Nx31', 'Nx31', 'Nx50', 'Nx50'],
      );
      expect(
        (w1.tanks['111']!.o2Percent, w1.tanks['222']!.o2Percent),
        (31.0, 31.0),
      );
      expect(
        (w2.tanks['111']!.o2Percent, w2.tanks['222']!.o2Percent),
        (50.0, 50.0),
      );
      expect(
        (w2.tanks['111']!.pressureBar, w2.tanks['222']!.pressureBar),
        (210.0, 190.0),
      );
      expect(w0.tanks['111']!.mode, 'open_circuit');
      expect(w0.tanks['111']!.enabled, isTrue);
    });

    test('test_first_listed_gas_when_nothing_was_switched', () {
      expect(
        _parse('test_first_listed_gas_when_nothing_was_switched')
            .single
            .waypoints[0]
            .gasmix,
        'Nx32',
      );
    });

    test('test_po2_without_a_logged_value_is_the_gas_at_depth', () {
      final dive = _parse('test_po2_without_a_logged_value_is_the_gas_at_depth')
          .single;
      expect([for (final wp in dive.waypoints) wp.po2], [0.32, 0.96, 0.32]);
      // An open-circuit dive names no mode.
      expect({for (final wp in dive.waypoints) wp.divemode}, {null});
    });

    test('test_rebreather_setpoints_from_the_switch_alerts_and_bailout', () {
      final wps = _parse(
        'test_rebreather_setpoints_from_the_switch_alerts_and_bailout',
      ).single.waypoints;
      expect([for (final wp in wps) wp.po2], [0.7, 1.3, 1.3, 0.7, 1.0, 0.5]);
      expect(
        [for (final wp in wps) wp.divemode],
        [
          for (var i = 0; i < 4; i++) 'closedcircuit',
          'opencircuit',
          'opencircuit',
        ],
      );
      expect(
        [for (final wp in wps) wp.setpoint],
        [0.7, 1.3, 1.3, 0.7, null, null],
      );
      expect(
        [for (final wp in wps) wp.gasmix],
        ['18/20', '18/20', '18/20', '18/20', 'Nx50', 'Nx50'],
      );
      expect(
        {for (final wp in wps) (wp.diluentO2Percent, wp.diluentHePercent)},
        {(18.0, 20.0)},
      );
      expect(wps[1].diveAlerts, contains('setpoint_switch_auto_high'));
    });

    test('test_no_setpoint_without_a_switch', () {
      final dive = _parse('test_no_setpoint_without_a_switch').single;
      // The diluent at depth, no setpoint invented.
      expect([for (final wp in dive.waypoints) wp.po2], [0.21, 0.63, 0.21]);
    });

    test('test_the_session_start_wins_over_an_activity_stamped_at_the_end', () {
      final dive = _parse(
        'test_the_session_start_wins_over_an_activity_stamped_at_the_end',
      ).single;
      expect(dive.startTime, naive(2026, 5, 2, 10));
      expect(dive.timezone, 'UTC+07:00');
      expect(
        [for (final wp in dive.waypoints) wp.timeSinceStart],
        [0, 60, 120],
      );
    });
  });

  group('parity with the Python parser, from decoded messages', () {
    for (final c in _cases) {
      test(c['name'] as String, () {
        _expectMatchesPython(
          parseGarminMessages(
            _messages(c['messages']),
            '/logs/dive.fit',
            tanks: _tanksOf(c),
          ),
          jsonObjects(c['dives']),
        );
      });
    }

    test('timezoneOffsetMinutes and timezoneName', () {
      for (final c in jsonObjects(_reference['timezone_from_pair'])) {
        final seconds = c['local_minus_utc_seconds'] as int;
        final utc = naive(2026, 1, 1, 12);
        expect(
          timezoneName(
            timezoneOffsetMinutes(utc.add(Duration(seconds: seconds)), utc),
          ),
          c['expected'],
          reason: '$seconds s',
        );
      }
    });

    test('setpointTimeline', () {
      for (final c in jsonObjects(_reference['setpoint_timeline'])) {
        final start = naive(2026);
        final timeline = setpointTimeline(
          [
            for (final s in c['switches'] as List<dynamic>)
              (
                start.add(Duration(seconds: (s as List<dynamic>)[0] as int)),
                s[1] as String,
              ),
          ],
          {
            for (final entry
                in (c['setpoints'] as Map<String, dynamic>).entries)
              entry.key: (entry.value as num?)?.toDouble(),
          },
        );
        expect(
          [
            for (final (time, bar) in timeline)
              [time?.difference(start).inSeconds, bar],
          ],
          c['expected'],
          reason: '$c',
        );
      }
    });
  });

  group('parity with the Python FIT SDK and parser, from FIT files', () {
    for (final c in jsonObjects(_reference['files'])) {
      final name = c['name'] as String;
      final Uint8List bytes = base64Decode(c['bytes_base64'] as String);

      test('$name: the messages the parser reads', () {
        final messages = readFitMessages(bytes);
        final expected = c['messages'] as Map<String, dynamic>;
        final fields = c['read_fields'] as Map<String, dynamic>;
        for (final listName in expected.keys) {
          final want = jsonObjects(expected[listName]);
          final got = messages[listName] ?? const <FitMesg>[];
          expect(got, hasLength(want.length), reason: listName);
          for (var i = 0; i < want.length; i++) {
            for (final field in fields[listName] as List<dynamic>) {
              final wantValue = _value(want[i][field]);
              var gotValue = got[i][field];
              // The Python SDK gives a datetime where the Dart library
              // gives raw FIT seconds; the parser reads both.
              if (wantValue is DateTime && gotValue is int) {
                gotValue = DateTime.fromMillisecondsSinceEpoch(
                  (gotValue + fitEpochS) * 1000,
                  isUtc: true,
                );
              }
              expect(
                gotValue,
                wantValue is double ? nearly(wantValue) : wantValue,
                reason: '$listName[$i].$field',
              );
            }
          }
        }
        expect(uniqueTankSerials(messages)..sort(), c['unique_tank_serials']);
      });

      test('$name: the dive', () {
        final path = '/logs/${c['file_name']}';
        expect(detectLogFormat(path, bytes), 'fit');
        final dives = parseLogFile(path, bytes)!;
        expect([for (final d in dives) d.logFormat], ['fit']);
        expect(dives.single.logPath, path);
        // The registry tags the dive with its format; the fixture's dives
        // come from the parser itself.
        _expectMatchesPython(
          dives,
          jsonObjects(c['dives']),
          ignoreDiveFields: {'log_format'},
        );
      });
    }

    test('fitFieldName', () {
      expect(fitFieldName('NextStopDepth'), 'next_stop_depth');
      expect(fitFieldName('N2Load'), 'n2_load');
      expect(fitFieldName('Po2'), 'po2');
      expect(fitFieldName('CcrLowSetpoint'), 'ccr_low_setpoint');
      expect(fitFieldName('StartPositionLat'), 'start_position_lat');
      expect(fitFieldName('Timestamp'), 'timestamp');
    });

    // From the parity review (2026-11-13): what the Python SDK reads past.
    test('a wrong checksum does not lose the dive', () {
      final c = jsonObjects(_reference['files']).first;
      final bytes = base64Decode(c['bytes_base64'] as String);
      final whole = parseGarmin(bytes, '/logs/x.fit').single;
      final damaged = Uint8List.fromList(bytes);
      damaged[damaged.length - 1] ^= 0x55;
      final dive = parseGarmin(damaged, '/logs/x.fit').single;
      expect(dive.waypoints.length, whole.waypoints.length);
      expect(dive.startTime, whole.startTime);
    });

    test('two FIT files one after the other are read one by one', () {
      final c = jsonObjects(_reference['files']).first;
      final bytes = base64Decode(c['bytes_base64'] as String);
      final one = readFitMessages(bytes);
      final two = readFitMessages(Uint8List.fromList([...bytes, ...bytes]));
      for (final name in one.keys) {
        expect(two[name]!.length, 2 * one[name]!.length, reason: name);
      }
      expect(two.keys.toSet(), one.keys.toSet());
    });

    test('an activity without a timestamp takes the session\'s start, in '
        'UTC', () {
      final start = DateTime.utc(2026, 1, 1, 10);
      final dive = parseGarminMessages({
        'activity_mesgs': [
          {'total_timer_time': 60.0},
        ],
        'session_mesgs': [
          {'start_time': start},
        ],
        'record_mesgs': [
          {'timestamp': start, 'depth': 1.0},
          {'timestamp': start.add(const Duration(seconds: 30)), 'depth': 2.0},
        ],
      }, '/logs/x.fit').single;
      expect(dive.waypoints.length, 2);
      expect(dive.timezone, 'UTC');
      expect(
        () => parseGarminMessages({
          'activity_mesgs': [
            {'total_timer_time': 60.0, 'local_timestamp': 1000000000},
          ],
          'session_mesgs': [
            {'start_time': start},
          ],
        }, '/logs/x.fit'),
        throwsFormatException,
      );
    });

    test('a file that is not FIT has no dive', () {
      expect(
        parseGarmin(utf8.encode('not a fit file at all'), '/logs/x.fit'),
        isEmpty,
      );
      expect(parseGarmin(Uint8List(0), '/logs/x.fit'), isEmpty);
    });
  });
}
