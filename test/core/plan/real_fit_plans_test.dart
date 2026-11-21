// A plan rebuilt from each of the owner's real Garmin logs, against what
// the Python app's plan_from_log and read_log_origin make of the same
// files. Neither the logs nor the reference are in git: they are under
// test_data/ (see CONTRIBUTING.md), and the reference is made by
// `tool/python_reference/fit_writer_fixture.py --real`. Without them the
// test skips itself.
@Tags(['requires_media'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/core/plan/dive_plan.dart';
import 'package:uwmedia_app/core/plan/dive_plan_import.dart';
import 'package:uwmedia_app/core/plan/plan_embed.dart';

import '../../helpers/test_data.dart';

void main() {
  const referencePath = 'python_reference/fit_plans.json';
  final skip = skipIfNoTestData(referencePath) ?? skipIfNoTestData('logs/fit');

  test('every real FIT log gives Python\'s plan', () {
    final reference = jsonDecode(
      File('${testDataDir().path}/$referencePath').readAsStringSync(),
    ) as Map<String, dynamic>;
    final bases = reference['bases'] as Map<String, dynamic>;
    final logs = reference['logs'] as Map<String, dynamic>;
    expect(logs, isNotEmpty);
    var rebuilt = 0;
    var depthless = 0;
    logs.forEach((name, value) {
      final log = value as Map<String, dynamic>;
      final file = File('${testDataDir().path}/logs/fit/$name');
      if (!file.existsSync()) {
        return;
      }
      final bytes = file.readAsBytesSync();
      final origin = readLogOrigin(name, bytes, inflate: zlib.decode);
      final wantOrigin = log['origin'] as Map<String, dynamic>;
      expect(origin.createdByUwmedia, wantOrigin['created_by_uwmedia']);
      expect(origin.plan?.toJson(), wantOrigin['plan'], reason: name);
      if (log.containsKey('parse')) {
        return;
      }
      final dive = parseLogFile(file.path, bytes)!.first;
      if (dive.waypoints.any((wp) => wp.depth == null)) {
        // A record without a depth is 0 m in Python and no sample of the
        // profile here (spec §10.8), so the waypoints differ.
        depthless++;
        return;
      }
      (log['plans'] as Map<String, dynamic>).forEach((baseName, result) {
        final [status, want] = result as List<dynamic>;
        DiveProfilePlan run() => planFromLog(
          file.path,
          bytes,
          dive,
          base: DiveProfilePlan.fromJson(
            jsonDecode(jsonEncode(bases[baseName])) as Map<String, dynamic>,
          ),
        );
        if (status == 'raise') {
          expect(run, throwsA(anything), reason: '$name ($baseName)');
        } else {
          expect(run().toJson(), want, reason: '$name ($baseName)');
          rebuilt++;
        }
      });
    });
    printOnFailure('$rebuilt plans, $depthless logs with depthless records');
    expect(rebuilt, greaterThan(0));
  }, skip: skip);
}
