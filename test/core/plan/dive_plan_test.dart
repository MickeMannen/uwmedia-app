// The Dive Profile Builder's model and engine against the Python app:
// cases of its tests/test_dive_plan_engine.py, then the parity fixture
// made by tool/python_reference/plan_fixture.py (30 plans through the
// model's questions, the expansion, the simulation, the planned ascent,
// the ascent from seven moments and the deco timeline).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/plan/dive_computers.dart';
import 'package:uwmedia_app/core/plan/dive_plan.dart';
import 'package:uwmedia_app/core/plan/dive_plan_engine.dart';

import '../../helpers/python_reference.dart';

/// Compares JSON-like values: whole numbers and everything else exactly,
/// other numbers to nine digits (the same operations in the same order as
/// Python; the slack is for another platform's maths library).
void expectNear(Object? got, Object? want, String reason) {
  if (want is Map<String, dynamic>) {
    expect(got, isA<Map<String, dynamic>>(), reason: reason);
    final map = got! as Map<String, dynamic>;
    expect(map.keys.toSet(), want.keys.toSet(), reason: reason);
    for (final key in want.keys) {
      expectNear(map[key], want[key], '$reason.$key');
    }
  } else if (want is List<dynamic>) {
    expect(got, isA<List<dynamic>>(), reason: reason);
    final list = got! as List<dynamic>;
    expect(list.length, want.length, reason: '$reason (length)');
    for (var i = 0; i < want.length; i++) {
      expectNear(list[i], want[i], '$reason[$i]');
    }
  } else if (want is double && got is num) {
    expect(got, closeTo(want, 1e-9 * (1 + want.abs())), reason: reason);
  } else {
    expect(got, want, reason: reason);
  }
}

DiveProfilePlan fresh(Object? data) => DiveProfilePlan.fromJson(
  jsonDecode(jsonEncode(data)) as Map<String, dynamic>,
);

/// `["ok", value]` or `["raise", message]`, as the fixture records a call.
List<Object?> call(Object? Function() run) {
  try {
    return ['ok', run()];
  } on PlanError catch (e) {
    return ['raise', e.message];
  }
}

List<List<Object?>> stopsOf(List<PlanStop> stops) => [
  for (final (depth, seconds, gas) in stops) [depth, seconds, gas],
];

Map<String, Object?> modelFacts(DiveProfilePlan plan) => {
  'dump': plan.toJson(),
  'sorted': [for (final w in plan.sortedWaypoints()) w.runtimeSec],
  'is_ccr': plan.isCcr,
  'diluent': plan.diluentGas()?.id,
  'sidemount_tanks': switch (plan.sidemountTanks()) {
    (final left, final right) => [left.id, right.id],
    null => null,
  },
  'sidemount_error': plan.sidemountError(),
  'breathed_gases': [for (final g in plan.breathedGases()) g.id],
  'tank_specs': [for (final t in plan.tankSpecs()) t.toJson()],
  'setpoints': [
    for (final current in [null, 0.7, 1.3])
      for (final depth in [0.0, 1.9, 2.0, 5.0, 8.0, 8.1, 40.0])
        [current, depth, plan.nextSetpoint(current, depth)],
  ],
  'gases': [
    for (final g in plan.gases)
      {
        'id': g.id,
        'f_o2': g.fO2,
        'f_he': g.fHe,
        'mod_m': g.modM,
        'has_depth_range': g.hasDepthRange,
        'covers': [
          for (final d in [0.0, 6.0, 6.1, 21.0, 30.0, 60.0]) g.coversDepth(d),
        ],
        'on_loop': plan.onLoop(g),
        'breathed': plan.breathedGas(g).id,
        'breathed_id': plan.breathedGasId(g.id),
        'tank_refs': plan.tankRefsFor(g),
        'for_tank': plan.gasForTank(g.tankRef)?.id,
        'sac': plan.sacFor(g),
        'mod': [
          for (final p in ['descent', 'ascent']) plan.gasModM(g, p),
        ],
        'display_mod': plan.gasDisplayModM(g),
        'usable': [
          for (final d in [3.0, 6.0, 21.0, 22.0, 40.0, 57.0])
            for (final p in ['descent', 'ascent'])
              [d, p, plan.gasUsableAt(g, d, p)],
        ],
        'deepest': [
          for (final p in ['descent', 'ascent'])
            switch (plan.gasDeepestUseM(g, p)) {
              double.infinity => null,
              final depth => depth,
            },
        ],
        'auto': [
          for (final d in [3.0, 6.0, 21.0, 40.0])
            for (final p in ['descent', 'ascent'])
              [d, p, autoGasForWaypoint(plan, d, p)?.id],
        ],
      },
  ],
  'unknown_gas_id': plan.breathedGasId('nope'),
  'max_po2': [
    for (final p in ['descent', 'ascent', 'other']) plan.maxPo2For(p),
  ],
};

Map<String, Object?> engineFacts(Map<String, dynamic> data) {
  final out = <String, Object?>{};
  var plan = fresh(data);
  out['phases'] = waypointPhases(plan.sortedWaypoints());
  plan = fresh(data);
  out['auto_warnings'] = applyAutoGases(plan);
  out['auto_gases'] = [for (final w in plan.sortedWaypoints()) w.gasId];
  out['expand'] = call(() {
    final (timeline, warnings) = expandPlan(fresh(data));
    return {
      'length': timeline.length,
      'warnings': warnings,
      'every_7th': [
        for (var i = 0; i < timeline.length; i += 7)
          [timeline[i].$1, timeline[i].$2, timeline[i].$3],
      ],
      'last': timeline.isEmpty
          ? null
          : [timeline.last.$1, timeline.last.$2, timeline.last.$3],
    };
  });
  out['simulate_15'] = call(() {
    final (samples, warnings) = simulate(fresh(data), resolutionSec: 15);
    return {
      'warnings': warnings,
      'samples': [for (final s in samples) s.toJson()],
    };
  });
  out['simulate_1_count'] = call(() => simulate(fresh(data)).$1.length);
  out['plan_ascent'] = call(() {
    final plan = fresh(data);
    final (waypoints, deco, stops) = planAscent(plan);
    return {
      'waypoints': [for (final w in waypoints) w.toJson()],
      'deco': deco,
      'stops': stopsOf(stops),
      'gases_after': [for (final w in plan.sortedWaypoints()) w.gasId],
    };
  });
  final last = [
    for (final w in data['waypoints'] as List<dynamic>? ?? const [])
      (w as Map<String, dynamic>)['runtime_sec'] as int,
  ].fold(0, (a, b) => b > a ? b : a);
  out['ascent_from_time'] = [
    for (final num t in [0, 90, 600.5, last ~/ 2, last - 1, last, last + 500])
      [
        t,
        call(() {
          final (deco, stops, tts) = ascentFromTime(fresh(data), t);
          return {'deco': deco, 'stops': stopsOf(stops), 'tts': tts};
        }),
      ],
  ];
  out['deco_timeline'] = call(
    () => [
      for (final (t, stops) in decoScheduleTimeline(
        fresh(data),
        intervalSec: 240,
      ))
        [t, stopsOf(stops)],
    ],
  );
  return out;
}

void main() {
  final reference = jsonDecode(
    utf8.decode(
      gzip.decode(
        File('test/fixtures/python_reference/plan/plan_cases.json.gz')
            .readAsBytesSync(),
      ),
    ),
  ) as Map<String, dynamic>;

  group('tests/test_dive_plan_engine.py', () {
    PlannedGas air() => PlannedGas(id: 'Air');
    DiveProfilePlan simple() => DiveProfilePlan(
      gases: [air()],
      waypoints: [
        PlannedWaypoint(runtimeSec: 300, depthM: 20.0, gasId: 'Air'),
        PlannedWaypoint(runtimeSec: 1200, depthM: 20.0, gasId: 'Air'),
        PlannedWaypoint(runtimeSec: 1500, depthM: 0.0, gasId: 'Air'),
      ],
    );
    DiveProfilePlan bottom(double depth, int end, [List<PlannedGas>? gases]) {
      final all = gases ?? [air()];
      return DiveProfilePlan(
        gases: all,
        waypoints: [
          for (final t in [180, end])
            PlannedWaypoint(
              runtimeSec: t,
              depthM: depth,
              gasId: all.first.id,
              gasAuto: true,
            ),
        ],
      );
    }

    test('test_expand_plan_transit_then_hold', () {
      final (timeline, warnings) = expandPlan(simple());
      expect(warnings, isEmpty);
      expect(timeline.length, 1501);
      expect(timeline.first, (0, 0.0, 'Air'));
      // 20 m at 20 m/min: there after 60 s, then held
      expect(timeline[30].$2, closeTo(10.0, 1e-9));
      expect(timeline[60].$2, 20.0);
      expect(timeline[299].$2, 20.0);
      expect(timeline.last, (1500, 0.0, 'Air'));
    });

    test('test_expand_plan_unknown_gas_raises', () {
      final plan = simple()..waypoints[1].gasId = 'Nope';
      expect(
        () => expandPlan(plan),
        throwsA(
          isA<PlanError>().having(
            (e) => e.message,
            'message',
            contains('unknown gas'),
          ),
        ),
      );
    });

    test('test_simulate_requires_at_least_one_gas', () {
      expect(() => simulate(DiveProfilePlan()), throwsA(isA<PlanError>()));
    });

    test('test_simulate_tank_pressure_drops', () {
      final (samples, _) = simulate(simple(), resolutionSec: 60);
      expect(samples.first.tankPressureBar, lessThanOrEqualTo(207.0));
      expect(
        samples.last.tankPressureBar,
        lessThan(samples.first.tankPressureBar),
      );
    });

    test('test_plan_ascent_no_deco_adds_3m_3min_safety_stop', () {
      final (waypoints, deco, stops) = planAscent(bottom(18, 1200));
      expect(deco, isFalse);
      expect(stops, [(3.0, 180, 'Air')]);
      expect([for (final w in waypoints) w.depthM], [3.0, 0.0]);
      expect(waypoints.every((w) => w.phase == 'ascent'), isTrue);
    });

    test('test_plan_ascent_nothing_to_do_at_surface', () {
      final (waypoints, deco, stops) = planAscent(simple());
      expect(waypoints, isEmpty);
      expect(deco, isFalse);
      expect(stops, isEmpty);
      expect(planAscent(DiveProfilePlan(gases: [air()])).$1, isEmpty);
    });

    test('test_plan_ascent_deco_clears_ceiling_and_switches_gas', () {
      final plan = bottom(45, 1800, [
        air(),
        PlannedGas(
          id: 'EAN50',
          o2Percent: 50,
          useMinDepthM: 0,
          useMaxDepthM: 21,
          usePhase: 'ascent',
          tankRef: 'T2',
        ),
      ]);
      final (waypoints, deco, stops) = planAscent(plan);
      expect(deco, isTrue);
      expect(stops.last.$1, 3.0);
      expect(stops.any((s) => s.$3 == 'EAN50'), isTrue);
      expect(waypoints.last.depthM, 0.0);
      // With the ascent added, the dive ends without a ceiling.
      plan.waypoints.addAll(waypoints);
      final (samples, _) = simulate(plan, resolutionSec: 10);
      expect(samples.last.ceilingM, 0.0);
      for (final s in samples) {
        expect(s.depthM + 0.5, greaterThanOrEqualTo(s.ceilingM));
      }
    });

    test('test_ccr_loop_holds_low_then_high_setpoint', () {
      final plan = DiveProfilePlan(
        diveType: 'ccr',
        gases: [
          PlannedGas(
            id: 'Dil',
            gasType: 'trimix',
            o2Percent: 18,
            hePercent: 45,
            diluent: true,
            tankSizeL: 3,
            tankRef: 'D',
          ),
        ],
        waypoints: [
          PlannedWaypoint(runtimeSec: 180, depthM: 40, gasId: 'Dil'),
          PlannedWaypoint(runtimeSec: 1200, depthM: 40, gasId: 'Dil'),
        ],
      );
      final (samples, _) = simulate(plan, resolutionSec: 10);
      expect(samples[1].setpoint, 0.7);
      expect(samples.last.setpoint, 1.3);
      expect(samples.last.po2, closeTo(1.3, 0.001));
      expect(samples.last.divemode, 'closedcircuit');
      expect(samples.last.cells, hasLength(3));
      expect(samples.last.tankPressures.keys, ['O2', 'D']);
    });

    test('test_sidemount_pair_alternates_tanks_within_the_switch_pressure', () {
      final plan = fresh(
        (reference['plans'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .firstWhere((p) => p['name'] == 'sidemount')['plan'],
      );
      final (samples, _) = simulate(plan, resolutionSec: 5);
      expect({for (final s in samples) s.tankRef}, {'T1', 'T2'});
      for (final s in samples) {
        final gap = (s.tankPressures['T1']! - s.tankPressures['T2']!).abs();
        expect(gap, lessThanOrEqualTo(30.5));
      }
    });
  });

  group('parity with Python', () {
    test('the constants, the defaults and the computers', () {
      expect({
        'SURFACE_PRESSURE_BAR': surfacePressureBar,
        'RECOMPUTE_INTERVAL_SEC': recomputeIntervalSec,
        'CCR_LOOP_LPM': ccrLoopLpm,
        'CCR_METABOLIC_O2_LPM': ccrMetabolicO2Lpm,
        'STOP_INTERVAL_M': stopIntervalM,
        'SAFETY_STOP_DEPTH_M': safetyStopDepthM,
        'SAFETY_STOP_SEC': safetyStopSec,
        'SAFETY_STOP_TRIGGER_M': safetyStopTriggerM,
        'GAS_SWITCH_HOLD_SEC': gasSwitchHoldSec,
        'MAX_ASCENT_PLAN_SEC': maxAscentPlanSec,
        'DECO_SCHEDULE_INTERVAL_SEC': decoScheduleIntervalSec,
      }, reference['constants']);
      expect(ccrO2TankRef, reference['ccr_o2_tank_ref']);
      expect(DiveProfilePlan().toJson(), reference['defaults']);
      expect(DiveProfilePlan.fromJson({}).toJson(), reference['defaults']);
      expect([
        for (final c in diveComputers.values)
          {
            'label': c.label,
            'manufacturer': c.manufacturer,
            'model': c.model,
            'fit_product': c.fitProduct,
            'is_garmin': c.isGarmin,
          },
      ], reference['computers']);
      expect(diveComputers.keys, [
        for (final c in diveComputers.values) c.label,
      ]);
      expect(defaultDiveComputer, reference['default_computer']);
      expect(legacyComputerLabels, reference['legacy_labels']);
      for (final [label as String, now, computer]
          in (reference['computer_lookups'] as List<dynamic>)
              .cast<List<dynamic>>()) {
        expect(computerLabel(label), now);
        expect(diveComputer(label).label, computer);
      }
    });

    test('the cells and the sidemount pair of older plans', () {
      for (final [po2 as num, t as int, want]
          in (reference['cells'] as List<dynamic>).cast<List<dynamic>>()) {
        expect(simulatedCells(po2.toDouble(), t), want);
      }
      for (final [gas, taken, first, rightRef, want]
          in (reference['split_pairs'] as List<dynamic>)
              .cast<List<dynamic>>()) {
        expect(
          splitSidemountPair(
            gas as Map<String, dynamic>,
            (taken as List<dynamic>).cast<String>(),
            first: first as bool,
            rightRef: rightRef as String?,
          ),
          want,
        );
      }
    });

    test('values outside their range are refused', () {
      final cases = (reference['invalid'] as List<dynamic>)
          .cast<List<dynamic>>();
      expect(cases.length, 24);
      for (final [data, valid] in cases) {
        expect(valid, isFalse);
        expect(
          () => DiveProfilePlan.fromJson(data as Map<String, dynamic>),
          throwsFormatException,
          reason: '$data',
        );
      }
    });

    final plans = jsonObjects(reference['plans']);
    test('thirty plans', () => expect(plans.length, 30));
    for (final c in plans) {
      final name = c['name'] as String;
      final data = c['plan'] as Map<String, dynamic>;
      test('$name: the model', () {
        expectNear(modelFacts(fresh(data)), c['model'], name);
        // What the model writes reads back as the same plan.
        final plan = fresh(data);
        expect(fresh(plan.toJson()).toJson(), plan.toJson());
      });
      test('$name: the engine', () {
        expectNear(engineFacts(data), c['engine'], name);
      });
    }
  });
}
