// The Subsurface CSV parser and the format detection against the Python
// app: the cases of its tests/test_subsurface_csv_parsing.py and the
// synthetic ones of tests/test_alternative_formats.py, then the parity
// fixture made by tool/python_reference/subsurface_csv_fixture.py.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/core/parsers/subsurface_csv.dart';
import 'package:uwmedia_app/core/parsers/subsurface_text.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

import '../../helpers/python_reference.dart';

const _header =
    '"dive number","date","time","sample time (min)","sample depth (m)",'
    '"sample temperature (C)","sample pressure (bar)","sample heartrate"\n';

List<Dive> _parse(String text, {String name = 'profile.csv'}) =>
    parseSubsurfaceCsv(text, '/tmp/$name');

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

Matcher _near(num expected) =>
    closeTo(expected, expected.abs() * 1e-12 + 1e-12);

void main() {
  group('tests/test_subsurface_csv_parsing.py', () {
    test('test_metric_export_values_and_carry_forward', () {
      final dive = _parse(
        '$_header'
        '"5","2026-04-05","08:15:00","0:00","0.0","28.0","210.0","70"\n'
        '"5","2026-04-05","08:15:00","1:00","12.4",,,\n'
        '"5","2026-04-05","08:15:00","2:00","18.0","27.0","190.5",""\n'
        '"5","2026-04-05","08:15:00","3:00","-0.2",,"0",\n'
        // A spurious trailing sample.
        '"5","2026-04-05","08:15:00","0:01","0.0",,,\n',
      ).single;
      expect(dive.startTime, naive(2026, 4, 5, 8, 15));
      expect(dive.endTime, naive(2026, 4, 5, 8, 18));
      expect(dive.durationSeconds, 180);
      expect(dive.logFilename, 'profile.csv');
      final wps = dive.waypoints;
      expect([for (final wp in wps) wp.timeSinceStart], [0, 60, 120, 180]);
      // A negative depth reads as the surface.
      expect([for (final wp in wps) wp.depth], [0.0, 12.4, 18.0, 0.0]);
      expect([for (final wp in wps) wp.maxDepth], [0.0, 12.4, 18.0, 18.0]);
      expect([for (final wp in wps) wp.temp], [28.0, 28.0, 27.0, 27.0]);
      // A pressure of 0 is no reading.
      expect(
        [for (final wp in wps) wp.tanks['1']!.pressureBar],
        [210.0, 210.0, 190.5, 190.5],
      );
      expect([for (final wp in wps) wp.heartRate], [70, null, null, null]);
      // The deco recompute ran.
      expect(wps[2].tts, isNotNull);
      expect(wps[2].ceiling, isNotNull);
    });

    test('test_minimal_columns_and_rows_without_a_time', () {
      final dive = _parse(
        '"dive number","date","time","sample time (min)","sample depth (ft)"\n'
        '"1","2026-04-05","10:00:00","0:00","0"\n'
        '"1","2026-04-05","10:00:00","","50"\n'
        '"1","2026-04-05","10:00:00","0:30","33"\n',
      ).single;
      expect([for (final wp in dive.waypoints) wp.timeSinceStart], [0, 30]);
      expect(dive.maxDepth, closeTo(33 * 0.3048, 1e-9));
      for (final wp in dive.waypoints) {
        expect(wp.temp, isNull);
        expect(wp.heartRate, isNull);
        expect(wp.tanks, isEmpty);
      }
    });

    test('test_dives_with_bad_dates_or_no_samples_are_skipped', () {
      final dives = _parse(
        '$_header'
        '"1","05/04/2026","08:00:00","0:10","5",,,\n'
        '"2","2026-04-05","10:00:00","",,,,\n'
        '"3","2026-04-05","12:00:00","0:10","7",,,\n',
      );
      expect([for (final d in dives) d.startTime], [naive(2026, 4, 5, 12)]);
    });

    for (final header in [
      '"dive number","date","time","sample depth (m)"\n',
      '"dive number","date","time","sample time (min)"\n',
      '',
    ]) {
      test('test_without_time_or_depth_columns_there_is_no_dive: '
          '${header.trim()}', () {
        expect(_parse('$header"1","2026-04-05","08:00:00","5"\n'), isEmpty);
      });
    }

    // test_missing_file_returns_no_dives: reading the file is not the
    // parser's job in the port; the caller that reads it handles a missing
    // one.

    test('test_is_subsurface_profile_header', () {
      expect(isSubsurfaceProfileHeader(_header), isTrue);
      expect(
        isSubsurfaceProfileHeader('"Sample Time (min)","Sample Depth (ft)"'),
        isTrue,
      );
      expect(isSubsurfaceProfileHeader('"sample time (min)","depth"'), isFalse);
      expect(isSubsurfaceProfileHeader('Dive Number,Start Date'), isFalse);
    });
  });

  group('tests/test_alternative_formats.py', () {
    test('test_detect_other_csv_and_xml', () {
      final other = _bytes('a,b,c\n1,2,3\n');
      expect(detectLogFormat('/tmp/budget.csv', other), isNull);
      expect(parseLogFile('/tmp/budget.csv', other), isNull);
      expect(
        detectLogFormat(
          '/tmp/dive.xml',
          _bytes(
            "<divelog program='subsurface' version='3'><dives/></divelog>",
          ),
        ),
        subsurfaceXmlFormat,
      );
    });

    test('test_subsurface_csv_groups_dives_and_converts_units', () {
      final dives = parseLogFile(
        '/tmp/two.csv',
        _bytes(
          '"dive number","date","time","sample time (min)","sample depth (ft)",'
          '"sample temperature (F)","sample pressure (psi)","sample heartrate"\n'
          '"1","2026-01-01","09:00:00","0:10","10","50","3000","80"\n'
          '"1","2026-01-01","09:00:00","0:20","20",,,\n'
          '"2","2026-01-01","11:00:00","0:10","5",,,\n',
        ),
      )!;
      final [first, second] = dives;
      expect(first.waypoints[1].depth, closeTo(20 * 0.3048, 1e-9));
      expect(first.waypoints[1].temp, closeTo(10.0, 1e-9));
      expect(first.waypoints[1].tanks['1']!.pressureBar, closeTo(206.8, 0.1));
      expect(first.waypoints[0].heartRate, 80);
      expect(second.startTime, naive(2026, 1, 1, 11));
    });
  });

  final reference = pythonReference('dives/subsurface_csv.json');

  group('parity with the Python parser', () {
    for (final c in jsonObjects(reference['parse'])) {
      test(c['name'] as String, () {
        final bytes = base64Decode(c['bytes_base64'] as String);
        final path = '/logs/${c['file_name']}';
        final dives = parseSubsurfaceCsv(decodeUtf8Sig(bytes), path);
        final expected = jsonObjects(c['dives']);
        expect(dives, hasLength(expected.length));
        var depthless = 0;

        for (var i = 0; i < dives.length; i++) {
          final dive = dives[i];
          final want = Map<String, dynamic>.of(expected[i]);
          final got = dive.toJson()..remove('log_path');
          expect(dive.logPath, path);
          expect(
            dive.maxDepth,
            _near(want.remove('max_depth_property') as num),
          );

          final wantWaypoints = jsonObjects(want.remove('waypoints'));
          final gotWaypoints = jsonObjects(got.remove('waypoints'));
          expect(got, want, reason: 'dive $i');
          expect(gotWaypoints, hasLength(wantWaypoints.length));
          for (var w = 0; w < gotWaypoints.length; w++) {
            final gotWp = gotWaypoints[w];
            final wantWp = Map<String, dynamic>.of(wantWaypoints[w]);
            final at = 'dive $i waypoint $w';
            // The port's one shared deco pass sets SurfGF where Python's
            // deco_pass.py leaves it out (spec §10.16).
            expect(wantWp.remove('surf_gf'), isNull);
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
            expect(gotWp, wantWp, reason: at);
          }
        }

        expect(
          depthless,
          c['name'].toString().startsWith('rows of two dives interleaved')
              ? 1
              : 0,
          reason: 'samples without a readable depth',
        );

        // Through the registry: the same dives, tagged with the format.
        expect(detectLogFormat(path, bytes), c['format']);
        final formats = c['registry_log_formats'] as List<dynamic>?;
        final viaRegistry = parseLogFile(path, bytes);
        expect(
          viaRegistry == null
              ? null
              : [for (final d in viaRegistry) d.logFormat],
          formats,
        );
      });
    }
  });

  group('parity with the Python registry and helpers', () {
    test('detectLogFormat', () {
      for (final c in jsonObjects(reference['detect'])) {
        final name = c['file_name'] as String;
        expect(
          detectLogFormat(
            '/logs/$name',
            base64Decode(c['bytes_base64'] as String),
          ),
          c['format'],
          reason: name,
        );
      }
    });

    test('parseTimeStr', () {
      for (final c in jsonObjects(reference['parse_time_str'])) {
        expect(parseTimeStr(c['text'] as String), c['expected'], reason: '$c');
      }
    });

    test('isSubsurfaceProfileHeader', () {
      for (final c in jsonObjects(reference['is_subsurface_profile_header'])) {
        expect(
          isSubsurfaceProfileHeader(c['line'] as String),
          c['expected'],
          reason: '$c',
        );
      }
    });

    test('a format key the registry does not know is refused', () {
      expect(
        () => parseLogFile('/logs/dive.fit', _bytes('x'), logFormat: 'gpx'),
        throwsUnsupportedError,
      );
    });
  });
}
