// The planner against Subsurface's, stop by stop: the reference dives of
// test/fixtures/deco_reference (see its README), as the Python app's
// tests/test_deco_reference.py compares them (scripts/deco_reference.py
// `build_plan`, `our_schedule`, `compare`). A dive with a known gap is
// expected to differ until the gap is fixed.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/plan/dive_plan.dart';
import 'package:uwmedia_app/core/plan/dive_plan_engine.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

const _defaultTolerance = {
  'first_stop_m': 3.0,
  'stop_min': 2.0,
  'runtime_pct': 10.0,
};

/// The reference's bottom as a plan: the first gas for the bottom, each
/// later gas taken on the ascent at Subsurface's switch depth. Subsurface
/// goes in a straight line from one waypoint to the next, so each
/// waypoint's rate is set to cover its whole segment.
DiveProfilePlan buildPlan(Map<String, dynamic> ref) {
  final settings = ref['settings'] as Map<String, dynamic>;
  double setting(String key) => (settings[key] as num).toDouble();
  final gases = [
    for (final (k, g)
        in (ref['gases'] as List<dynamic>).cast<Map<String, dynamic>>().indexed)
      PlannedGas(
        id: g['name'] as String,
        gasType: (g['he_percent'] as num) > 0
            ? 'trimix'
            : (g['o2_percent'] == 21.0 ? 'air' : 'nitrox'),
        o2Percent: (g['o2_percent'] as num).toDouble(),
        hePercent: (g['he_percent'] as num).toDouble(),
        tankRef: 'T${k + 1}',
        useMaxDepthM: (g['switch_depth_m'] as num?)?.toDouble(),
        usePhase: g['switch_depth_m'] == null ? 'any' : 'ascent',
      ),
  ];
  final waypoints = <PlannedWaypoint>[];
  var prevSec = 0;
  var prevDepth = 0.0;
  for (final wp
      in (ref['bottom'] as List<dynamic>).cast<Map<String, dynamic>>()) {
    // Subsurface shows a quick descent as 0 min; a waypoint needs a moment
    // after the start at the surface.
    final rounded = pyRound((wp['runtime_min'] as num) * 60.0);
    final runtime = rounded > prevSec + 1 ? rounded : prevSec + 1;
    final depth = (wp['depth_m'] as num).toDouble();
    final change = (depth - prevDepth).abs();
    waypoints.add(
      PlannedWaypoint(
        runtimeSec: runtime,
        depthM: depth,
        gasId: gases.first.id,
        gasAuto: true,
        rateMPerMin: change == 0 ? null : change / (runtime - prevSec) * 60.0,
      ),
    );
    prevSec = runtime;
    prevDepth = depth;
  }
  return DiveProfilePlan(
    name: ref['name'] as String,
    gfLow: setting('gf_low'),
    gfHigh: setting('gf_high'),
    defaultAscentRate: setting('ascent_rate'),
    defaultDescentRate: setting('descent_rate'),
    gases: gases,
    waypoints: waypoints,
  );
}

Map<double, double> _perDepth(Iterable<(double, double)> stops) {
  final out = <double, double>{};
  for (final (depth, minutes) in stops) {
    out[depth] = (out[depth] ?? 0.0) + minutes;
  }
  return out;
}

/// What differs from the reference by more than its tolerance.
List<String> compare(Map<String, dynamic> ref) {
  final plan = buildPlan(ref);
  final (ascent, _, stops) = planAscent(plan);
  final tolerance = {
    ..._defaultTolerance,
    ...(ref['tolerance'] as Map<String, dynamic>? ?? const {}),
  };
  double tol(String key) => (tolerance[key]! as num).toDouble();
  final expected = ref['expected'] as Map<String, dynamic>;
  final theirs = _perDepth([
    for (final s
        in (expected['stops'] as List<dynamic>).cast<Map<String, dynamic>>())
      ((s['depth_m'] as num).toDouble(), (s['minutes'] as num).toDouble()),
  ]);
  final ours = _perDepth([
    for (final (depth, seconds, _) in stops) (depth, seconds / 60.0),
  ]);
  double deepest(Map<double, double> m) =>
      m.keys.fold(0.0, (a, b) => b > a ? b : a);

  final problems = <String>[];
  if ((deepest(theirs) - deepest(ours)).abs() > tol('first_stop_m')) {
    problems.add(
      'first stop ${deepest(ours)} m, Subsurface ${deepest(theirs)} m',
    );
  }
  for (final depth in {...theirs.keys, ...ours.keys}) {
    final t = theirs[depth] ?? 0.0;
    final o = ours[depth] ?? 0.0;
    if ((o - t).abs() > tol('stop_min')) {
      problems.add('$depth m stop $o min, Subsurface $t min');
    }
  }
  final runtimeTheirs = (expected['runtime_min'] as num).toDouble();
  final runtimeOurs = ascent.isEmpty ? 0.0 : ascent.last.runtimeSec / 60.0;
  final percent = runtimeTheirs == 0
      ? 0.0
      : (runtimeOurs - runtimeTheirs) / runtimeTheirs * 100;
  if (percent.abs() > tol('runtime_pct')) {
    problems.add('runtime $runtimeOurs min, Subsurface $runtimeTheirs min');
  }
  return problems;
}

void main() {
  final references = [
    for (final file
        in Directory('test/fixtures/deco_reference')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
      jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
  ];

  test('there are six reference dives', () {
    expect(references.length, 6);
  });

  for (final ref in references) {
    final gap = ref['known_gap'] as String? ?? '';
    test('test_planner_matches_subsurface[${ref['source']}]', () {
      final problems = compare(ref);
      if (gap.isNotEmpty) {
        // As pytest's xfail: when the dive matches, the known_gap line of
        // its file has to go.
        expect(
          problems,
          isNotEmpty,
          reason: '${ref['source']} matches now - remove its known_gap',
        );
      } else {
        expect(problems, isEmpty);
      }
    });
  }
}
