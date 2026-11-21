// The Shearwater Cloud export parser against the Python app: the cases of
// its tests/test_shearwater_parsing.py and the synthetic Shearwater ones of
// tests/test_alternative_formats.py, on the same export texts (kept in the
// fixture), then every parsed field against the fixture made by
// tool/python_reference/shearwater_fixture.py.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/core/parsers/shearwater.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

import '../../helpers/python_reference.dart';

Matcher _near(num expected) =>
    closeTo(expected, expected.abs() * 1e-12 + 1e-12);

final List<Map<String, dynamic>> _cases = jsonObjects(
  pythonReference('dives/shearwater.json')['parse'],
);

Map<String, dynamic> _case(String name) =>
    _cases.singleWhere((c) => c['name'] == name);

Uint8List _bytesOf(Map<String, dynamic> c) =>
    base64Decode(c['bytes_base64'] as String);

/// The dives of the fixture export called [name].
List<Dive> _parse(String name) {
  final c = _case(name);
  return parseShearwater(_bytesOf(c), '/logs/${c['file_name']}');
}

/// A map without its null values, recursively: the fixture leaves them out.
Object? _withoutNulls(Object? value) => switch (value) {
  final Map<String, dynamic> map => {
    for (final entry in map.entries)
      if (entry.value != null) entry.key: _withoutNulls(entry.value),
  },
  final List<dynamic> list => [for (final item in list) _withoutNulls(item)],
  _ => value,
};

void main() {
  group('tests/test_shearwater_parsing.py', () {
    test('test_xml_export_values', () {
      final dive = _parse('XML values').single;
      expect(dive.startTime, naive(2026, 2, 3, 10, 20, 30));
      expect(dive.endTime, naive(2026, 2, 3, 10, 23, 30));
      expect(dive.durationSeconds, 180);
      // From the file name: <product> is a number.
      expect(dive.device, 'Perdix 2');
      expect(dive.manufactor, 'Shearwater Research, Inc');
      expect(dive.maxDepth, 21.0);

      final [w0, w1, w2, w3] = dive.waypoints;
      expect(
        [for (final wp in dive.waypoints) wp.timeSinceStart],
        [0, 60, 120, 180],
      );
      // NDL 0 and no stop: not diving yet.
      expect(w0.ndl, isNull);
      expect(w0.tanks['T1']!.pressureBar, closeTo(3000 * 0.0689476, 1e-9));
      expect(w0.tanks.keys, ['T1']);
      expect(w0.tanks['T1']!.o2Percent, closeTo(32.0, 1e-9));
      expect(w0.tanks['T1']!.hePercent, closeTo(0.0, 1e-9));
      expect(w0.divemode, 'opencircuit');
      expect(w0.airRemaining, isNull);

      expect((w1.depth, w1.temp, w1.ndl, w1.tts), (18.5, 27.0, 25 * 60, 120));
      expect(w1.po2, 0.91);
      expect(w1.battery, 1.52);
      expect(w1.airRemaining, 40 * 60);
      expect(w1.pressureSac, closeTo(16.0 * 0.0689476, 0.01));
      expect((w1.decoStopDepth, w1.nextStopTime), (0.0, 0));

      expect(
        (w2.decoStopDepth, w2.nextStopTime, w2.nextStopDepth),
        (6.0, 120, 6.0),
      );
      // In deco.
      expect(w2.ndl, 0);
      expect(w2.tts, 300);
      expect(w3.ndl, 99 * 60);
    });

    test('test_xml_imperial_units', () {
      final [w0, w1, _] = _parse('XML imperial units').single.waypoints;
      expect(w0.temp, closeTo(30.0, 1e-9));
      expect(w1.depth, closeTo(66 * 0.3048, 1e-9));
      expect(w1.temp, closeTo(25.0, 1e-9));
      expect(w1.decoStopDepth, closeTo(20 * 0.3048, 1e-9));
      expect(w1.nextStopTime, 60);
    });

    test('test_xml_really_in_utf16', () {
      final bytes = _bytesOf(_case('XML really in UTF-16'));
      expect(bytes[0] * 256 + bytes[1], anyOf(0xfffe, 0xfeff));
      final dive = _parse('XML really in UTF-16').single;
      expect(dive.maxDepth, 5.0);
      expect(dive.startTime, naive(2026, 2, 3, 10, 20, 30));
    });

    test('test_xml_skips_repeated_and_timeless_records', () {
      final dive = _parse('XML repeated, timeless and backwards records')
          .single;
      expect(
        [for (final wp in dive.waypoints) (wp.timeSinceStart, wp.depth)],
        [(0, 0.0), (10, 5.0), (20, 3.0)],
      );
    });

    test('test_xml_without_a_dive_log_or_samples', () {
      expect(_parse('XML without a dive log'), isEmpty);
      final empty = _case('XML with an empty root');
      final tables = readShearwaterTables(_bytesOf(empty), '/logs/b.xml');
      expect(tables.header, isEmpty);
      expect(tables.rows, isEmpty);
      expect(_parse('XML without records'), isEmpty);
      expect(_parse('XML records without a time'), isEmpty);
    });

    test('test_broken_xml_returns_no_dives', () {
      expect(_parse('XML broken'), isEmpty);
    });

    const name = 'Perdix 2[00000000]#7 2026-02-03 10-20-30';
    for (final (start, fileName, expected) in [
      // Month/day and day/month both parse: the file name's date picks.
      ('03/02/2026 10:20:30', name, naive(2026, 2, 3, 10, 20, 30)),
      ('02/03/2026 10:20:30', name, naive(2026, 2, 3, 10, 20, 30)),
      ('03.02.2026 10:20:30', name, naive(2026, 2, 3, 10, 20, 30)),
      ('2026-02-03T10:20:30', name, naive(2026, 2, 3, 10, 20, 30)),
      // No date in the file name: the first reading (month first) wins.
      ('03/02/2026 10:20:30', 'export', naive(2026, 3, 2, 10, 20, 30)),
      // The file name disagrees with every reading: still the first one.
      ('05/06/2026 10:20:30', name, naive(2026, 5, 6, 10, 20, 30)),
      // No readable start date: the file name's own date and time.
      ('', name, naive(2026, 2, 3, 10, 20, 30)),
      ('yesterday', name, naive(2026, 2, 3, 10, 20, 30)),
    ]) {
      test('test_start_date_against_the_file_name: "$start" in $fileName', () {
        final dives = parseShearwater(
          utf8.encode(
            'Dive Number,Start Date\n7,$start\nTime (sec),Depth\n0,0\n10,5\n',
          ),
          '/logs/$fileName.csv',
        );
        expect(dives.single.startTime, expected);
      });
    }

    test('test_no_start_date_anywhere_gives_no_dive', () {
      expect(_parse('CSV no start date anywhere'), isEmpty);
    });

    test('test_device_from_the_header_product', () {
      expect(
        _parse('CSV device from the Product column').single.device,
        'Petrel 3',
      );
      expect(_parse('CSV no device anywhere').single.device, isNull);
    });

    test('test_csv_repeated_header_column_blank_rows_and_gas', () {
      final c = _case('CSV repeated header column, blank row, gas');
      final tables = readShearwaterTables(
        _bytesOf(c),
        '/logs/${c['file_name']}',
      );
      // The first of a repeated name.
      expect(tables.header['Computer Firmware Version'], '64');
      expect([for (final row in tables.rows) row.seconds], [0.0, 10.0, 20.0]);
      final [w0, w1, w2] = _parse(c['name'] as String).single.waypoints;
      expect(w0.divemode, 'opencircuit');
      expect(w1.divemode, 'closedcircuit');
      expect(w2.divemode, isNull);
      expect(w0.tanks.keys, ['T2']);
      expect(w0.tanks['T2']!.o2Percent, closeTo(18.0, 1e-9));
      expect(w0.tanks['T2']!.hePercent, closeTo(45.0, 1e-9));
      // 0 psi: no reading.
      expect(w2.tanks, isEmpty);
      // Recomputed where the export left it blank.
      expect(w2.po2, isNotNull);
    });

    test('test_csv_without_samples', () {
      expect(_parse('CSV empty'), isEmpty);
      expect(_parse('CSV header line only'), isEmpty);
    });

    test('test_csv_with_a_header_but_no_sample_table', () {
      final c = _case('CSV header without a sample table');
      final tables = readShearwaterTables(
        _bytesOf(c),
        '/logs/${c['file_name']}',
      );
      expect(tables.header, {
        'Dive Number': '7',
        'Start Date': '2026-02-03 10:20:30',
      });
      expect(tables.rows, isEmpty);
      expect(_parse(c['name'] as String), isEmpty);
    });

    test('test_divemode', () {
      for (final (value, mode) in [
        ('OC/BO', 'opencircuit'),
        ('oc/bo', 'opencircuit'),
        ('CC/BO', 'closedcircuit'),
        ('SC/BO', 'closedcircuit'),
        ('1', 'opencircuit'),
        ('0', 'closedcircuit'),
        ('', null),
        (null, null),
        ('2', null),
        ('Gauge', null),
      ]) {
        expect(shearwaterDivemode(value), mode, reason: '$value');
      }
    });

    test('test_a_transmitter_status_is_no_reading', () {
      final [w0, w1, _] = _parse('XML transmitter status words')
          .single
          .waypoints;
      expect(w0.tanks.keys, ['T1']);
      expect(w1.tanks.keys, ['T1', 'T4']);
    });
  });

  group('tests/test_alternative_formats.py', () {
    test('test_shearwater_csv_imperial_units', () {
      final c = _case('CSV imperial units');
      final dive = parseLogFile('/logs/${c['file_name']}', _bytesOf(c))!.single;
      expect(dive.startTime, naive(2025, 1, 2, 10));
      expect(dive.device, 'Teric');
      final wp = dive.waypoints[1];
      expect(wp.depth, closeTo(33 * 0.3048, 1e-9));
      expect(wp.temp, closeTo(10.0, 1e-9));
      expect(wp.ndl, 50 * 60);
      expect(wp.tanks, isEmpty);
      // NDL 0 with no stop: not diving yet.
      expect(dive.waypoints[0].ndl, isNull);
      expect(dive.waypoints[0].tanks['T1']!.pressureBar, closeTo(206.8, 0.1));
      expect(dive.waypoints[0].gasmix, 'Nx32');
    });

    test('test_shearwater_start_date_in_day_month_locale', () {
      final c = _case('CSV day/month locale');
      final dive = parseLogFile('/logs/${c['file_name']}', _bytesOf(c))!.single;
      expect(dive.startTime, naive(2025, 10, 3, 9, 15));
    });
  });

  group('parity with the Python parser', () {
    for (final c in _cases) {
      final name = c['name'] as String;
      final path = '/logs/${c['file_name']}';

      test('$name: tables', () {
        final expected = c['tables'] as Map<String, dynamic>?;
        if (expected == null) {
          return;
        }
        if (expected.containsKey('error')) {
          expect(
            () => readShearwaterTables(_bytesOf(c), path),
            throwsA(anything),
          );
          return;
        }
        final tables = readShearwaterTables(_bytesOf(c), path);
        expect(tables.header, expected['header']);
        final rows = jsonObjects(expected['rows']);
        expect(tables.rows, hasLength(rows.length));
        for (var i = 0; i < rows.length; i++) {
          expect(tables.rows[i].seconds, rows[i]['seconds'], reason: 'row $i');
          // Python keeps the seconds under "Time (sec)" in the row itself.
          final fields = Map<String, String>.of(tables.rows[i].fields)
            ..remove('Time (sec)');
          expect(fields, rows[i]['fields'], reason: 'row $i');
        }
      });

      test('$name: dives', () {
        final bytes = _bytesOf(c);
        final dives = parseShearwater(bytes, path);
        final expected = jsonObjects(c['dives']);
        expect(dives, hasLength(expected.length));
        var depthless = 0;
        expect(detectLogFormat(path, bytes), c['format']);

        for (var i = 0; i < dives.length; i++) {
          final dive = dives[i];
          final want = Map<String, dynamic>.of(expected[i]);
          final got = _withoutNulls(dive.toJson())! as Map<String, dynamic>
            ..remove('log_path');
          expect(dive.logPath, path);
          expect(
            dive.maxDepth,
            _near(want.remove('max_depth_property') as num),
          );
          // The port keeps the file's gradient factors on the dive; Python
          // drops them (spec §10.16). The fixture has them as the UDDF
          // parser would store them.
          final gfLow = got.remove('gf_low') as int?;
          final gfHigh = got.remove('gf_high') as int?;
          final gf = c['gf_percent'] as List<dynamic>?;
          expect([gfLow, gfHigh], gf ?? [null, null]);

          final wantWaypoints = jsonObjects(want.remove('waypoints'));
          final gotWaypoints = jsonObjects(got.remove('waypoints'));
          expect(got, want, reason: 'dive $i');
          expect(gotWaypoints, hasLength(wantWaypoints.length));
          for (var w = 0; w < gotWaypoints.length; w++) {
            final gotWp = gotWaypoints[w];
            final wantWp = Map<String, dynamic>.of(wantWaypoints[w]);
            final at = 'dive $i waypoint $w';
            // SurfGF: set by the port's one shared deco pass, left out by
            // Python's deco_pass.py (spec §10.16).
            expect(wantWp.containsKey('surf_gf'), isFalse);
            expect(gotWp.remove('surf_gf'), isNotNull, reason: at);
            // Sums and products in Python's order: equal to the last bits
            // on one machine; the tolerance is for another platform.
            for (final name in [
              'ceiling',
              'deco_stop_depth',
              'depth',
              'max_depth',
              'temp',
            ]) {
              final wantValue = wantWp.remove(name) as num?;
              final gotValue = gotWp.remove(name);
              if (name == 'depth' && gotValue == null && wantValue == 0.0) {
                // No readable depth: null in the port, 0.0 in Python
                // (spec §10.8).
                depthless += 1;
                continue;
              }
              expect(
                gotValue,
                wantValue == null ? isNull : _near(wantValue),
                reason: '$at $name',
              );
            }
            final wantTanks = wantWp.remove('tanks') as Map<String, dynamic>;
            final gotTanks = gotWp.remove('tanks') as Map<String, dynamic>;
            expect(gotTanks.keys, wantTanks.keys, reason: '$at tanks');
            for (final key in wantTanks.keys) {
              final wantTank = wantTanks[key] as Map<String, dynamic>;
              final gotTank = gotTanks[key] as Map<String, dynamic>;
              expect(gotTank.keys, wantTank.keys, reason: '$at tank $key');
              for (final field in wantTank.keys) {
                expect(
                  gotTank[field],
                  _near(wantTank[field] as num),
                  reason: '$at tank $key $field',
                );
              }
            }
            expect(gotWp, wantWp, reason: at);
          }
        }
        expect(
          depthless,
          name.startsWith('XML repeated tags') ? 1 : 0,
          reason: 'samples without a readable depth',
        );
      });
    }

    test('shearwaterDivemode', () {
      final cases = jsonObjects(
        pythonReference('dives/shearwater.json')['divemode'],
      );
      for (final c in cases) {
        expect(
          shearwaterDivemode(c['value'] as String?),
          c['expected'],
          reason: '$c',
        );
      }
    });
  });

  test('a date in the file name that does not exist is an error', () {
    // Python's datetime() raises and the parser lets it out.
    expect(
      () => parseShearwater(
        utf8.encode('Dive Number,Start Date\n7,\nTime (sec),Depth\n0,0\n'),
        '/logs/x 2026-02-30 10-20-30.csv',
      ),
      throwsFormatException,
    );
  });
}
