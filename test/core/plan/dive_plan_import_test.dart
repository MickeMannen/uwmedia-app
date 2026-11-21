// A plan rebuilt from a log against the Python app: the parity fixture
// made by tool/python_reference/import_fixture.py runs plan_from_log on
// the synthetic logs of the parser fixtures and on the logs of the
// writers fixture, each parsed as the builder's Open log does.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/core/plan/dive_plan.dart';
import 'package:uwmedia_app/core/plan/dive_plan_import.dart';

import '../../helpers/python_reference.dart';

Map<String, dynamic> _unzip(String path) => jsonDecode(
  utf8.decode(
    gzip.decode(File('test/fixtures/python_reference/$path').readAsBytesSync()),
  ),
) as Map<String, dynamic>;

void main() {
  final reference = _unzip('plan/import_cases.json.gz');
  final bases = reference['bases'] as Map<String, dynamic>;

  test('names, times and tank pairs', () {
    expect(profileToleranceM, reference['tolerance_m']);
    expect(maxProfileWaypoints, reference['max_waypoints']);
    for (final [o2 as num, he as num, name, type]
        in (reference['mix_names'] as List<dynamic>).cast<List<dynamic>>()) {
      expect(mixName(o2.toDouble(), he.toDouble()), name);
      expect(gasTypeFor(o2.toDouble(), he.toDouble()), type);
    }
    for (final [text as String, want]
        in (reference['mmss'] as List<dynamic>).cast<List<dynamic>>()) {
      expect(mmssSeconds(text), want, reason: '"$text"');
    }
    for (final [refs, mixes, want]
        in (reference['pair_up'] as List<dynamic>).cast<List<dynamic>>()) {
      expect(
        [
          for (final (ref, right, pair) in pairUp(
            (refs as List<dynamic>).cast<String>(),
            mixes as List<dynamic>?,
          ))
            [ref, right, pair],
        ],
        want,
        reason: '$refs $mixes',
      );
    }
  });

  test('thinning a profile', () {
    for (final [name, points, tolerance as num, want]
        in (reference['simplify'] as List<dynamic>).cast<List<dynamic>>()) {
      final got = simplifyProfile([
        for (final p in (points as List<dynamic>).cast<List<dynamic>>())
          ((p[0] as num).toDouble(), (p[1] as num).toDouble()),
      ], toleranceM: tolerance.toDouble());
      expect(
        [
          for (final (t, d) in got) [t, d],
        ],
        want,
        reason: '$name at $tolerance',
      );
    }
  });

  test('a plan from every synthetic log', () {
    final sources = <String, List<Map<String, dynamic>>>{};
    List<Map<String, dynamic>> casesOf(String source) => sources.putIfAbsent(
      source,
      () => source.endsWith('.gz')
          ? jsonObjects(_unzip(source)['cases'])
          : jsonObjects(pythonReference(source)['parse']),
    );
    final logs = jsonObjects(reference['logs']);
    expect(logs.length, 167);
    var rebuilt = 0;
    var refused = 0;
    var depthless = 0;
    for (final log in logs) {
      final source = log['source'] as String;
      final original = casesOf(source)[log['index'] as int];
      final written = source.endsWith('.gz');
      final name =
          (written ? log['file_name'] : original['file_name']) as String;
      final bytes = written
          ? Uint8List.fromList(utf8.encode(original[log['name']] as String))
          : base64.decode(original['bytes_base64'] as String);
      final reason = '$source ${log['index']} ${log['name']}';
      final path = '/logs/$name';

      List<Dive>? dives;
      try {
        dives = parseLogFile(path, bytes);
      } on Object {
        dives = null;
      }
      if (log.containsKey('parse')) {
        // Python found no dive in the file, or could not read it.
        expect(dives ?? const [], isEmpty, reason: reason);
        continue;
      }
      expect(dives, isNotEmpty, reason: reason);
      if (dives!.first.waypoints.any((wp) => wp.depth == null)) {
        // A sample without a depth is 0 m in Python and no sample of the
        // profile here (spec §10.8), so the waypoints differ.
        depthless++;
        continue;
      }
      (log['plans'] as Map<String, dynamic>).forEach((baseName, result) {
        final [status, want] = result as List<dynamic>;
        DiveProfilePlan run() => planFromLog(
          path,
          bytes,
          dives!.first,
          base: DiveProfilePlan.fromJson(
            jsonDecode(jsonEncode(bases[baseName])) as Map<String, dynamic>,
          ),
        );
        if (status == 'raise') {
          expect(run, throwsA(anything), reason: '$reason ($baseName)');
          refused++;
        } else {
          expect(run().toJson(), want, reason: '$reason ($baseName)');
          rebuilt++;
        }
      });
    }
    expect((rebuilt, refused, depthless), (262, 12, 4));
  });

  test('a file that is no log', () {
    // A FIT file without a message says nothing (fit_writer_test.dart has
    // the FIT logs).
    final empty = loggedPlanParts('dive.fit', Uint8List.fromList([14, 0x10]));
    expect(empty.gases, isEmpty);
    expect(empty.switches, isEmpty);
    expect(empty.diveType, 'oc');
    expect(
      () => loggedPlanParts('notes.txt', Uint8List(0)),
      throwsFormatException,
    );
  });
}
