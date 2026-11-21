// The Dive Profile Builder's UDDF and Subsurface logs and the plan in
// them against the Python app: the parity fixture made by
// tool/python_reference/writers_fixture.py holds ten dives as Python
// wrote them; the port's text has to be the same, character for
// character, and the app's own parsers have to read it back.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/parsers/subsurface.dart';
import 'package:uwmedia_app/core/parsers/uddf.dart';
import 'package:uwmedia_app/core/plan/dive_plan.dart';
import 'package:uwmedia_app/core/plan/dive_plan_engine.dart';
import 'package:uwmedia_app/core/plan/log_writers.dart';
import 'package:uwmedia_app/core/plan/plan_embed.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';

import '../../helpers/python_reference.dart';

Map<String, dynamic> _unzip(String name) => jsonDecode(
  utf8.decode(
    gzip.decode(
      File('test/fixtures/python_reference/plan/$name').readAsBytesSync(),
    ),
  ),
) as Map<String, dynamic>;

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  final reference = _unzip('writers_cases.json.gz');
  final plans = {
    for (final p in jsonObjects(_unzip('plan_cases.json.gz')['plans']))
      p['name'] as String: p['plan'] as Map<String, dynamic>,
  };
  final now = pyFromIsoformatNaive(reference['now'] as String)!;

  test('the constants', () {
    expect({
      'plan_format': planFormat,
      'plan_format_version': planFormatVersion,
      'generator_name': generatorName,
      'notes_mark': subsurfaceNotesMark,
      'plan_key': subsurfacePlanKey,
      'uddf_ns': uddfNamespace,
      'ndl_cap_sec': ndlCapSec,
      'ccr_o2_mix_id': ccrO2MixId,
      'gaschange_event_type': gasChangeEventType,
    }, reference['constants']);
  });

  final cases = jsonObjects(reference['cases']);
  test('ten dives', () => expect(cases.length, 10));
  for (final (i, c) in cases.indexed) {
    test('dive $i (${c['plan_name']}): both files as Python writes them', () {
      final plan = DiveProfilePlan.fromJson({
        ...jsonDecode(jsonEncode(plans[c['plan_name']]))
            as Map<String, dynamic>,
        ...c['changes'] as Map<String, dynamic>,
      });
      if (c['with_ascent'] as bool) {
        plan.waypoints.addAll(planAscent(plan).$1);
      }
      expect(plan.toJson(), c['plan']);
      expect(planToJson(plan), c['plan_json']);
      expect(planFromJson(planToJson(plan))!.toJson(), plan.toJson());

      final (samples, _) = simulate(
        plan,
        resolutionSec: c['resolution'] as int,
      );
      final start = c['start'] == null
          ? null
          : pyFromIsoformatNaive(c['start'] as String);
      expect(
        formatNaive(logStartTime(plan, startTime: start, now: now)),
        c['local_start'],
      );
      final uddf = uddfText(
        plan,
        samples,
        startTime: start,
        now: now,
        utcOffsetMinutes: c['utc_offset_minutes'] as int,
      );
      expect(uddf.length, (c['uddf'] as String).length);
      expect(uddf, c['uddf']);
      final subsurface = subsurfaceText(
        plan,
        samples,
        startTime: start,
        now: now,
      );
      expect(subsurface, c['subsurface']);

      // The origin of each, as Python reads it from its own file.
      for (final (suffix, text) in [('.uddf', uddf), ('.ssrf', subsurface)]) {
        final want =
            (c['origins'] as Map<String, dynamic>)[suffix]
                as Map<String, dynamic>;
        final origin = readLogOrigin('dive$suffix', _bytes(text));
        expect(origin.createdByUwmedia, want['created_by_uwmedia']);
        expect(origin.plan?.toJson(), want['plan']);
      }
    });
  }

  test('files that are not the builder\'s, or only partly', () {
    final cases = jsonObjects(reference['origins']);
    expect(cases.length, 10);
    for (final c in cases) {
      final origin = readLogOrigin(
        c['name'] as String,
        _bytes(c['text'] as String),
      );
      expect(
        origin.createdByUwmedia,
        c['created_by_uwmedia'],
        reason: '${c['name']}',
      );
      expect(origin.plan?.toJson(), c['plan'], reason: '${c['name']}');
    }
  });

  test('planFromJson', () {
    for (final [text, want]
        in (reference['plan_from_json'] as List<dynamic>)
            .cast<List<dynamic>>()) {
      expect(planFromJson(text as String?)?.toJson(), want, reason: '$text');
    }
  });

  test('the app\'s parsers read the written logs back', () {
    // tests/test_log_writers.py test_round_trip_profile_start_and_tanks
    // and test_round_trip_names_the_chosen_computer, for the text formats.
    for (final (name, tankCount) in [
      ('simple', 1),
      ('sidemount', 2),
      ('ccr', 3),
    ]) {
      final plan = DiveProfilePlan.fromJson({
        ...jsonDecode(jsonEncode(plans[name])) as Map<String, dynamic>,
        'start_time': '2026-05-02T10:06:59',
        'computer': 'Shearwater Perdix 2',
      });
      final (samples, _) = simulate(plan, resolutionSec: 10);
      final deepest = samples.map((s) => s.depthM).reduce(pyMax);
      for (final dives in [
        parseUddf(
          _bytes(uddfText(plan, samples, now: now, utcOffsetMinutes: 480)),
          'dive.uddf',
        ),
        parseSubsurface(
          _bytes(subsurfaceText(plan, samples, now: now)),
          'dive.ssrf',
        ),
      ]) {
        final dive = dives.single;
        final reason = '$name ${dive.logFormat}';
        expect(dive.waypoints.length, samples.length, reason: reason);
        expect(formatNaive(dive.startTime), '2026-05-02T10:06:59');
        expect(dive.device, contains('Perdix 2'), reason: reason);
        expect(
          dive.waypoints.map((w) => w.depth ?? 0).reduce(pyMax),
          closeTo(deepest, 0.01),
          reason: reason,
        );
        expect(dive.waypoints.last.tanks.length, tankCount, reason: reason);
        expect(dive.isCcr, name == 'ccr', reason: reason);
      }
    }
  });

  test('no samples, nothing to write', () {
    final plan = DiveProfilePlan();
    expect(
      () => uddfText(plan, [], now: now, utcOffsetMinutes: 0),
      throwsArgumentError,
    );
    expect(() => subsurfaceText(plan, [], now: now), throwsArgumentError);
  });
}
