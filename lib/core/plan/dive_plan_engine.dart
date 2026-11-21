/// The Dive Profile Builder's engine (Python `utils/dive_plan_engine.py`):
/// a plan's waypoints as a profile second by second, the Bühlmann
/// simulation along it (ceiling, NDL, stops, tank pressures, a
/// rebreather's setpoint and cells), the gases picked by depth, and the
/// ascent that ends a dive.
library;

import 'dart:math' as math;

import 'package:uwmedia_app/core/deco/deco_engine.dart';
import 'package:uwmedia_app/core/plan/dive_plan.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

const surfacePressureBar = 1.01325;

/// A full look ahead (NDL, stops) is worked out this often; in between the
/// value is counted down by the second.
const recomputeIntervalSec = 10;

/// About what is drawn from the diluent tank while on the loop, in surface
/// L/min scaled by the pressure like a SAC.
const ccrLoopLpm = 1.0;

/// The oxygen the diver uses, drawn from a CCR dive's oxygen cylinder in
/// L/min whatever the depth.
const ccrMetabolicO2Lpm = 1.0;

const stopIntervalM = 3.0;
const safetyStopDepthM = 3.0;
const safetyStopSec = 180;

/// A computer asks for a safety stop after a dive past this depth.
const safetyStopTriggerM = 11.0;
const gasSwitchHoldSec = 60;
const maxAscentPlanSec = 6 * 3600;
const decoScheduleIntervalSec = 60;

/// One second of the expanded plan: time, depth and the gas breathed.
typedef PlanSecond = (int timeSec, double depthM, String gasId);

/// A stop of an ascent: depth, length in seconds and gas.
typedef PlanStop = (double depthM, int durationSec, String gasId);

/// A plan that cannot be simulated; the message is for the user.
class PlanError implements Exception {
  const PlanError(this.message);

  final String message;

  @override
  String toString() => message;
}

class SimulatedSample {
  const SimulatedSample({
    required this.timeSec,
    required this.depthM,
    required this.gasId,
    required this.ceilingM,
    required this.ndlSec,
    required this.ttsSec,
    required this.stopDepthM,
    required this.stopDurationSec,
    required this.cnsPct,
    required this.po2,
    required this.divemode,
    required this.tankPressureBar,
    required this.tankRef,
    required this.tankPressures,
    required this.ceilingGfLowM,
    required this.setpoint,
    required this.cells,
  });

  final int timeSec;
  final double depthM;
  final String gasId;

  /// The ceiling at GF high (may the diver surface?).
  final double ceilingM;
  final int? ndlSec;
  final int ttsSec;
  final double stopDepthM;
  final int stopDurationSec;
  final double cnsPct;
  final double po2;
  final String divemode;

  /// The pressure of the tank breathed from, [tankRef].
  final double tankPressureBar;
  final String tankRef;

  /// Every tank, in the order of the plan's tanks.
  final Map<String, double> tankPressures;

  /// The ceiling at GF low, which places the first stop.
  final double ceilingGfLowM;

  /// A CCR dive's setpoint in force while on the loop.
  final double? setpoint;

  /// A CCR dive's three cell readings while on the loop.
  final List<double> cells;

  Map<String, dynamic> toJson() => {
    'time_sec': timeSec,
    'depth_m': depthM,
    'gas_id': gasId,
    'ceiling_m': ceilingM,
    'ndl_sec': ndlSec,
    'tts_sec': ttsSec,
    'stop_depth_m': stopDepthM,
    'stop_duration_sec': stopDurationSec,
    'cns_pct': cnsPct,
    'po2': po2,
    'divemode': divemode,
    'tank_pressure_bar': tankPressureBar,
    'tank_ref': tankRef,
    'tank_pressures': tankPressures,
    'ceiling_gf_low_m': ceilingGfLowM,
    'setpoint': setpoint,
    'cells': cells,
  };
}

/// Three cell readings around the loop's PO2, as a rebreather's cells read
/// it: each a little off and wandering slowly (within 2 %, so they always
/// pass the vote), and the same every time.
List<double> simulatedCells(double po2, int timeSec) => [
  for (var k = 0; k < 3; k++)
    pyRoundTo(po2 * (1.0 + 0.015 * math.sin(timeSec / 90.0 + k * 2.1)), 2),
];

/// "descent" or "ascent" for each waypoint (sorted by time): everything up
/// to the first visit to the deepest point is the descent and bottom,
/// anything shallower after it the ascent. A waypoint's own phase wins.
List<String> waypointPhases(List<PlannedWaypoint> waypoints) {
  if (waypoints.isEmpty) {
    return [];
  }
  var deepest = waypoints.first.depthM;
  var deepestIndex = 0;
  for (final (i, wp) in waypoints.indexed) {
    if (wp.depthM > deepest) {
      deepest = wp.depthM;
      deepestIndex = i;
    }
  }
  return [
    for (final (i, wp) in waypoints.indexed)
      (wp.phase ?? '').isNotEmpty
          ? wp.phase!
          : (i > deepestIndex && wp.depthM < deepest ? 'ascent' : 'descent'),
  ];
}

/// The gas whose depth range, phase and MOD cover a waypoint. A gas with a
/// range of its own beats one without, a gas for this phase beats an "any"
/// gas, and among equals the richest in oxygen wins. `null` when no gas
/// can be used. A CCR dive stays on the loop: bailout is only picked by
/// hand.
PlannedGas? autoGasForWaypoint(
  DiveProfilePlan plan,
  double depthM,
  String phase,
) {
  final loop = plan.diluentGas();
  if (loop != null) {
    return loop;
  }
  PlannedGas? best;
  int rank(PlannedGas g) =>
      (g.hasDepthRange ? 2 : 0) + (g.usePhase == phase ? 1 : 0);
  for (final gas in plan.breathedGases()) {
    if (!plan.gasUsableAt(gas, depthM, phase)) {
      continue;
    }
    if (best == null ||
        rank(gas) > rank(best) ||
        (rank(gas) == rank(best) && gas.o2Percent > best.o2Percent)) {
      best = gas;
    }
  }
  return best;
}

/// Picks the gas again for every waypoint with an automatic gas, in place.
/// A waypoint no gas covers keeps the gas of the one before it and gets a
/// warning, as does a gas picked by hand that is breathed below its MOD.
/// Returns the warnings.
List<String> applyAutoGases(DiveProfilePlan plan) {
  final warnings = <String>[];
  if (plan.gases.isEmpty) {
    return warnings;
  }
  final wps = plan.sortedWaypoints();
  final phases = waypointPhases(wps);
  var previous = plan.breathedGases().first.id;
  for (final (i, wp) in wps.indexed) {
    final phase = phases[i];
    final when =
        '${wp.runtimeSec ~/ 60}:'
        '${(wp.runtimeSec % 60).toString().padLeft(2, '0')}';
    final limit = pyFormatG(plan.maxPo2For(phase));
    if (wp.gasAuto) {
      final gas = autoGasForWaypoint(plan, wp.depthM, phase);
      if (gas == null) {
        warnings.add(
          'No gas is usable at ${pyFormatG(wp.depthM)}m ($phase, max PO2 '
          '$limit) at $when - staying on $previous',
        );
        wp.gasId = previous;
      } else {
        wp.gasId = gas.id;
      }
    } else {
      final gas = plan.gasById(wp.gasId);
      final mod = gas == null ? null : plan.gasModM(gas, phase);
      if (mod != null && wp.depthM > mod) {
        warnings.add(
          '${gas!.id} at ${pyFormatG(wp.depthM)}m ($when) is past its MOD of '
          '${pyFormatG(mod)}m at max PO2 $limit',
        );
      }
    }
    previous = wp.gasId;
  }
  return warnings;
}

/// The waypoints as one entry per second, and warnings. The move from one
/// waypoint to the next starts at once, at the rate that applies; what
/// time is left is spent at the next waypoint's depth. A waypoint's gas
/// takes effect once its depth is reached, not during the move (as a real
/// Perdix export has its gas switches). A waypoint on a sidemount dive's
/// right tank is on the pair's gas. Throws a [PlanError] for a waypoint
/// with a gas the plan does not have.
(List<PlanSecond>, List<String>) expandPlan(DiveProfilePlan plan) {
  final warnings = <String>[];
  final wps = plan.sortedWaypoints();
  if (wps.isEmpty) {
    return ([], warnings);
  }
  for (final wp in wps) {
    if (plan.gasById(wp.gasId) == null) {
      throw PlanError("Waypoint references unknown gas '${wp.gasId}'");
    }
  }
  final points = [
    if (wps.first.runtimeSec > 0)
      PlannedWaypoint(runtimeSec: 0, depthM: 0.0, gasId: wps.first.gasId),
    ...wps,
  ];
  final timeline = <PlanSecond>[
    (
      points.first.runtimeSec,
      points.first.depthM,
      plan.breathedGasId(points.first.gasId),
    ),
  ];
  for (var i = 1; i < points.length; i++) {
    final prev = points[i - 1];
    final cur = points[i];
    final total = cur.runtimeSec - prev.runtimeSec;
    if (total <= 0) {
      warnings.add(
        'Waypoint at ${cur.runtimeSec}s does not come after the previous one '
        '(${prev.runtimeSec}s) - skipped',
      );
      continue;
    }
    final delta = cur.depthM - prev.depthM;
    var transit = 0.0;
    if (delta != 0) {
      final own = cur.rateMPerMin ?? 0.0;
      final rate = own != 0
          ? own
          : (delta > 0 ? plan.defaultDescentRate : plan.defaultAscentRate);
      transit = delta.abs() / rate * 60.0;
      if (transit > total) {
        warnings.add(
          'Waypoint at ${cur.runtimeSec}s: reaching ${pyFloatRepr(cur.depthM)}m '
          'needs ~${pyFormatFixed(transit, 0)}s at ${pyFormatFixed(rate, 0)} '
          'm/min but only ${total}s is available before it - clamped, the '
          'transit runs late',
        );
        transit = total.toDouble();
      }
    }
    final prevGas = plan.breathedGasId(prev.gasId);
    final curGas = plan.breathedGasId(cur.gasId);
    for (var t = 1; t <= total; t++) {
      timeline.add(
        transit > 0 && t <= transit
            ? (
                prev.runtimeSec + t,
                prev.depthM + delta * (t / transit),
                prevGas,
              )
            : (prev.runtimeSec + t, cur.depthM, curGas),
      );
    }
  }
  return (timeline, warnings);
}

// The O2 and He fractions breathed: the gas's own on open circuit; on the
// loop the diluent held at the setpoint in force (null: the low one).
(double, double) _effectiveFractions(
  DiveProfilePlan plan,
  PlannedGas gas,
  double depthM,
  double? setpoint,
) => plan.onLoop(gas)
    ? ccrEffectiveFractions(
        setpoint ?? plan.ccrLowSetpoint,
        surfacePressureBar + depthM / 10.0,
        gas.fO2,
        gas.fHe,
      )
    : (gas.fO2, gas.fHe);

// A virtual ascent to the surface from a depth, staying on one gas the
// whole way: like a real dive computer, which cannot see the diver's
// plans and only reacts once a switch has happened. No safety stop is
// added. Stops are held with the GF going from GF low at the first stop to
// GF high at the surface. Gives the time to surface and the first stop's
// depth and time, the time in whole minutes (at least one), as a computer
// shows it.
(int, double, int) _mandatoryStopSchedule(
  DiveProfilePlan plan,
  BuhlmannEngine engine,
  double depthM,
  PlannedGas gas,
  double gfLow,
  double gfHigh,
  double? setpointNow,
) {
  const ascentRateMps = 0.15;
  const maxSeconds = 20000;
  if (engine.getCeiling(gfLow) <= 0) {
    return (0, 0.0, 0);
  }
  final sim = engine.clone();
  var setpoint = setpointNow;
  var total = 0;
  var depth = depthM;
  var firstStop = 0.0; // where the GF-low ceiling first stops the ascent
  var firstStopDepth = 0.0;
  var firstStopDuration = 0;
  double gfAt(double d) => gfHigh + (gfLow - gfHigh) * (d / firstStop);

  while (depth > 0 && total < maxSeconds) {
    final ceiling = sim.getCeiling(firstStop != 0 ? gfAt(depth) : gfLow);
    if (depth > ceiling) {
      depth -= pyMin(depth, ascentRateMps);
      setpoint = plan.nextSetpoint(setpoint, depth);
      final (fO2, fHe) = _effectiveFractions(plan, gas, depth, setpoint);
      sim.update(depth, 1.0, fO2, fHe);
      total += 1;
      continue;
    }
    final stopDepth = (depth / 3.0).ceilToDouble() * 3.0;
    if (stopDepth < 3.0) {
      break;
    }
    if (firstStop == 0) {
      firstStop = stopDepth;
    }
    final nextLevel = stopDepth - 3.0;
    var duration = 0;
    while (total < maxSeconds && sim.getCeiling(gfAt(nextLevel)) > nextLevel) {
      final (fO2, fHe) = _effectiveFractions(plan, gas, stopDepth, setpoint);
      sim.update(stopDepth, 10.0, fO2, fHe);
      total += 10;
      duration += 10;
    }
    if (firstStopDepth == 0) {
      // A deep first stop can clear almost at once under GF low.
      firstStopDepth = stopDepth;
      firstStopDuration = math.max(60, (duration / 60.0).ceil() * 60);
    }
    depth = nextLevel;
    total += 20; // the move between stops
  }
  return (total, firstStopDepth, firstStopDuration);
}

// Time to surface when no deco is owed: a direct ascent at the plan's
// rate, plus the safety stop still to come after a dive past the trigger
// depth (none after deco: the stops were it). Shallower than the safety
// stop only the ascent counts.
int _noDecoTts(
  DiveProfilePlan plan,
  double depthM,
  double runningMaxM,
  bool hadDeco,
) {
  if (depthM <= 0) {
    return 0;
  }
  var ascent = (depthM / plan.defaultAscentRate * 60.0).ceil();
  if (runningMaxM >= safetyStopTriggerM &&
      !hadDeco &&
      depthM > safetyStopDepthM) {
    ascent += safetyStopSec;
  }
  return ascent;
}

/// The Bühlmann simulation of [plan] second by second, with every
/// [resolutionSec]-th second (and the last) kept as a sample. The tissues
/// are always loaded per second; the resolution only decides how many
/// samples there are.
///
/// Tank pressures are followed per tank: each second's gas is drawn at its
/// SAC from the tank it is breathed from; on a CCR loop [ccrLoopLpm] from
/// the diluent and [ccrMetabolicO2Lpm] from the oxygen cylinder. A
/// sidemount pair starts on the left tank and changes side whenever the
/// one breathed is the switch pressure below the other.
///
/// Throws a [PlanError] for a plan without a gas, a CCR dive without a
/// diluent, or a sidemount dive without both tanks.
(List<SimulatedSample>, List<String>) simulate(
  DiveProfilePlan plan, {
  int resolutionSec = 1,
}) {
  if (plan.gases.isEmpty) {
    throw const PlanError(
      'Define at least one gas before simulating a profile',
    );
  }
  if (plan.isCcr && plan.diluentGas() == null) {
    throw const PlanError(
      'A CCR dive needs a diluent - mark one gas as the diluent',
    );
  }
  final sidemount = plan.sidemountError();
  if (sidemount != null) {
    throw PlanError(sidemount);
  }
  final (timeline, warnings) = expandPlan(plan);
  if (timeline.isEmpty) {
    return ([], warnings);
  }

  final engine = BuhlmannEngine(surfacePressureBar: surfacePressureBar);
  final gfLow = plan.gfLow / 100.0;
  final gfHigh = plan.gfHigh / 100.0;
  final specs = plan.tankSpecs();
  final pressure = {for (final t in specs) t.ref: t.startPressureBar};
  final size = {for (final t in specs) t.ref: t.sizeL};
  final o2Tank = specs.where((t) => t.role == 'oxygen').firstOrNull;
  final breathingFrom = {
    for (final g in plan.breathedGases()) g.id: plan.tankRefsFor(g).first,
  };

  final samples = <SimulatedSample>[];
  int? lastNdl;
  var lastTts = 0;
  var lastStopDepth = 0.0;
  var lastStopDuration = 0;
  var inDeco = false;
  var hadDeco = false;
  var runningMax = 0.0;
  double? setpoint;

  for (final (i, (t, depth, gasId)) in timeline.indexed) {
    final gas = plan.gasById(gasId)!;
    final onLoop = plan.onLoop(gas);
    final ambient = surfacePressureBar + depth / 10.0;
    if (plan.isCcr) {
      setpoint = plan.nextSetpoint(setpoint, depth);
    }
    final (fO2, fHe) = _effectiveFractions(plan, gas, depth, setpoint);
    engine.update(depth, 1.0, fO2, fHe);

    final tank = breathingFrom[gasId]!;
    final sac = onLoop ? ccrLoopLpm : plan.sacFor(gas);
    if (sac > 0) {
      final drop = (sac / 60.0 * ambient) / size[tank]!;
      pressure[tank] = pyMax(0.0, pressure[tank]! - drop);
    }
    if (o2Tank != null && onLoop) {
      final drop = ccrMetabolicO2Lpm / 60.0 / o2Tank.sizeL;
      pressure[o2Tank.ref] = pyMax(0.0, pressure[o2Tank.ref]! - drop);
    }
    final pair = plan.tankRefsFor(gas);
    if (pair.length == 2) {
      final other = tank == pair[0] ? pair[1] : pair[0];
      if (pressure[tank]! <= pressure[other]! - plan.sidemountSwitchBar) {
        breathingFrom[gasId] = other; // from the next second on
      }
    }

    final ceiling = engine.getCeiling(gfHigh);
    runningMax = pyMax(runningMax, depth);
    // Also worked out the moment deco starts or clears, so that no sample
    // has a ceiling with the no-stop values or the other way round.
    if (t % recomputeIntervalSec == 0 || i == 0 || (ceiling > 0) != inDeco) {
      inDeco = ceiling > 0;
      if (!inDeco) {
        // null: without limit (99+), as at 3 m once deco has cleared.
        lastNdl = engine.computeNdlSeconds(
          depthMeters: depth,
          fO2: fO2,
          fHe: fHe,
          gf: gfHigh,
        );
        lastStopDepth = 0.0;
        lastStopDuration = 0;
      } else {
        hadDeco = true;
        lastNdl = null;
        (lastTts, lastStopDepth, lastStopDuration) = _mandatoryStopSchedule(
          plan,
          engine,
          depth,
          gas,
          gfLow,
          gfHigh,
          setpoint,
        );
      }
    } else if (!inDeco) {
      lastNdl = lastNdl == null ? null : math.max(0, lastNdl - 1);
    } else {
      lastTts = math.max(0, lastTts - 1);
      lastStopDuration = math.max(0, lastStopDuration - 1);
    }
    if (!inDeco) {
      lastTts = _noDecoTts(plan, depth, runningMax, hadDeco);
    }

    if (i % resolutionSec == 0 || i == timeline.length - 1) {
      samples.add(
        SimulatedSample(
          timeSec: t,
          depthM: depth,
          gasId: gasId,
          ceilingM: ceiling,
          ndlSec: lastNdl,
          ttsSec: lastTts,
          stopDepthM: lastStopDepth,
          stopDurationSec: lastStopDuration,
          cnsPct: engine.cns,
          po2: pyRoundTo(ambient * fO2, 3),
          divemode: onLoop ? 'closedcircuit' : 'opencircuit',
          setpoint: onLoop ? setpoint : null,
          cells: onLoop ? simulatedCells(ambient * fO2, t) : const [],
          tankPressureBar: pyRoundTo(pressure[tank]!, 1),
          tankRef: tank,
          tankPressures: {
            for (final MapEntry(:key, :value) in pressure.entries)
              key: pyRoundTo(value, 1),
          },
          ceilingGfLowM: engine.getCeiling(gfLow),
        ),
      );
    }
  }
  return (samples, warnings);
}

// The tissues at a time of the plan (the end of its last waypoint when no
// time is given), loaded per second as simulate does, without the look
// ahead. Also the timeline entry reached (null for an empty plan) and a
// CCR dive's setpoint in force then.
(BuhlmannEngine, PlanSecond?, double?) _loadedEngine(
  DiveProfilePlan plan, [
  num? untilSec,
]) {
  final (timeline, _) = expandPlan(plan);
  final engine = BuhlmannEngine(surfacePressureBar: surfacePressureBar);
  PlanSecond? reached;
  double? setpoint;
  for (final entry in timeline) {
    final (t, depth, gasId) = entry;
    if (untilSec != null && t > untilSec) {
      break;
    }
    if (plan.isCcr) {
      setpoint = plan.nextSetpoint(setpoint, depth);
    }
    final (fO2, fHe) = _effectiveFractions(
      plan,
      plan.gasById(gasId)!,
      depth,
      setpoint,
    );
    engine.update(depth, 1.0, fO2, fHe);
    reached = entry;
  }
  return (engine, reached, setpoint);
}

/// The waypoints that end the dive from its last waypoint, whether deco is
/// needed, and the stops (the safety stop or the deco stops and the holds
/// at gas switches). Without deco: a direct ascent at the plan's rate with
/// a 3 m, 3 min safety stop. With deco: the Bühlmann schedule, first stop
/// from GF low, stops on 3 m levels, each held until the ceiling for the
/// next level clears with the GF between GF low at the first stop and GF
/// high at the surface, in whole minutes; the 3 m stop is at least the
/// safety stop's 3 minutes.
///
/// This is a plan, so it changes gas on the way up: each ascent gas is
/// taken at the deep end of its range or its MOD at the deco PO2, the
/// shallower of the two, with a waypoint there. If the last waypoint's gas
/// was picked by hand, the ascent stays on it. Empty when the dive already
/// ends at the surface. The plan's automatic gases are picked again first.
(List<PlannedWaypoint>, bool, List<PlanStop>) planAscent(DiveProfilePlan plan) {
  final wps = plan.sortedWaypoints();
  if (wps.isEmpty || wps.last.depthM <= 0) {
    return ([], false, []);
  }
  applyAutoGases(plan);
  final last = wps.last;
  final (engine, _, setpoint) = _loadedEngine(plan);
  return _ascentFrom(
    plan,
    engine,
    last.depthM,
    last.runtimeSec.toDouble(),
    plan.breathedGas(plan.gasById(last.gasId)!),
    last.gasAuto,
    setpoint,
  );
}

/// "If the ascent started now": whether deco is needed, the stops and the
/// time to surface from any time of the plan, by the rules of
/// [planAscent]. Gas switches follow the waypoint that covers the moment
/// (automatic or by hand).
(bool, List<PlanStop>, int) ascentFromTime(DiveProfilePlan plan, num timeSec) {
  final (engine, reached, setpoint) = _loadedEngine(plan, timeSec);
  if (reached == null || reached.$2 <= 0) {
    return (false, [], 0);
  }
  final (t, depth, gasId) = reached;
  final covering = plan
      .sortedWaypoints()
      .where((wp) => wp.runtimeSec >= t)
      .firstOrNull;
  final (waypoints, decoNeeded, stops) = _ascentFrom(
    plan,
    engine,
    depth,
    t.toDouble(),
    plan.gasById(gasId)!,
    covering?.gasAuto ?? true,
    setpoint,
  );
  return (
    decoNeeded,
    stops,
    waypoints.isEmpty ? 0 : waypoints.last.runtimeSec - t,
  );
}

/// How the deco plan grows over the dive: every [intervalSec] while deco
/// is needed, the whole stop schedule an ascent started right then would
/// get. Times out of deco are left out.
List<(int, List<PlanStop>)> decoScheduleTimeline(
  DiveProfilePlan plan, {
  int intervalSec = decoScheduleIntervalSec,
}) {
  final (timeline, _) = expandPlan(plan);
  final wps = plan.sortedWaypoints();
  final engine = BuhlmannEngine(surfacePressureBar: surfacePressureBar);
  final gfHigh = plan.gfHigh / 100.0;
  final out = <(int, List<PlanStop>)>[];
  double? setpoint;
  for (final (t, depth, gasId) in timeline) {
    final gas = plan.gasById(gasId)!;
    if (plan.isCcr) {
      setpoint = plan.nextSetpoint(setpoint, depth);
    }
    final (fO2, fHe) = _effectiveFractions(plan, gas, depth, setpoint);
    engine.update(depth, 1.0, fO2, fHe);
    if (t % intervalSec != 0 || depth <= 0 || engine.getCeiling(gfHigh) <= 0) {
      continue;
    }
    final covering = wps.where((wp) => wp.runtimeSec >= t).firstOrNull;
    final (_, _, stops) = _ascentFrom(
      plan,
      engine.clone(),
      depth,
      t.toDouble(),
      gas,
      covering?.gasAuto ?? true,
      setpoint,
    );
    out.add((t, stops));
  }
  return out;
}

// planAscent's schedule from any state (tissues, depth, time, gas); the
// engine is moved on in place.
(List<PlannedWaypoint>, bool, List<PlanStop>) _ascentFrom(
  DiveProfilePlan plan,
  BuhlmannEngine engine,
  double startDepth,
  double startSec,
  PlannedGas startGas,
  bool auto,
  double? startSetpoint,
) {
  final gfLow = plan.gfLow / 100.0;
  final gfHigh = plan.gfHigh / 100.0;
  final rateMps = plan.defaultAscentRate / 60.0;
  var depth = startDepth;
  var t = startSec;
  var gas = startGas;
  var setpoint = startSetpoint;
  final out = <PlannedWaypoint>[];
  final stops = <PlanStop>[];

  PlannedGas gasFor(double d) =>
      auto ? (autoGasForWaypoint(plan, d, 'ascent') ?? gas) : gas;

  void addWaypoint(double d, double holdUntil, PlannedGas g) {
    var runtime = holdUntil.ceil();
    final rounded = pyRoundTo(d, 1);
    if (out.isNotEmpty &&
        out.last.depthM == rounded &&
        out.last.gasId == g.id) {
      // The same depth and gas as the waypoint before (a stop that began
      // with a gas-switch hold): that hold is made longer.
      out.last.runtimeSec = math.max(out.last.runtimeSec, runtime);
      return;
    }
    if (out.isNotEmpty && runtime <= out.last.runtimeSec) {
      runtime = out.last.runtimeSec + 1;
    }
    out.add(
      PlannedWaypoint(
        runtimeSec: runtime,
        depthM: rounded,
        gasId: g.id,
        gasAuto: auto,
        phase: 'ascent',
      ),
    );
  }

  void breathe(double d, double seconds) {
    if (plan.isCcr) {
      setpoint = plan.nextSetpoint(setpoint, d);
    }
    final (fO2, fHe) = _effectiveFractions(plan, gas, d, setpoint);
    engine.update(d, seconds, fO2, fHe);
  }

  // Where each ascent gas can first be used (the deep end of its range,
  // not past its MOD at the deco PO2) strictly between two depths, deepest
  // first. A CCR dive stays on the loop.
  List<double> switchDepthsBetween(double shallow, double deep) {
    if (!auto || plan.isCcr) {
      return [];
    }
    final found = {
      for (final g in plan.breathedGases())
        if (g.usePhase == 'any' || g.usePhase == 'ascent')
          plan.gasDeepestUseM(g, 'ascent'),
    };
    return found.where((d) => shallow < d && d < deep).toList()
      ..sort((a, b) => b.compareTo(a));
  }

  // Ascends to a depth at the ascent rate, loading the tissues per second.
  // Each gas switch on the way gets a hold on the new gas that ends in a
  // waypoint. Gives the time the depth was reached, before any switch hold
  // there, so that a stop there counts the hold (and lists it itself,
  // hence stopAtTarget).
  double ascendTo(double target, {bool stopAtTarget = false}) {
    void switchIfNeeded() {
      final next = gasFor(depth);
      if (next.id != gas.id && depth > 0) {
        gas = next;
        breathe(depth, gasSwitchHoldSec.toDouble());
        t += gasSwitchHoldSec;
        addWaypoint(depth, t, gas);
        if (!(stopAtTarget && depth == target)) {
          stops.add((depth, gasSwitchHoldSec, gas.id));
        }
      }
    }

    switchIfNeeded(); // already in a better gas's range
    var reached = t;
    for (final legEnd in [...switchDepthsBetween(target, depth), target]) {
      while (depth > legEnd) {
        final step = pyMin(rateMps, depth - legEnd);
        depth -= step;
        t += step / rateMps;
        breathe(depth, step / rateMps);
      }
      reached = t;
      switchIfNeeded();
    }
    return reached;
  }

  // Deco is needed when the diver cannot surface directly: the GF-high
  // ceiling. The first stop is then placed from the GF-low ceiling.
  var firstStop = 0.0;
  final decoNeeded = engine.getCeiling(gfHigh) > 0;

  // A free ascent, a second at a time, until the GF-low ceiling asks for a
  // first stop, or without deco up to the safety stop.
  while (depth > 0 && t - startSec < maxAscentPlanSec) {
    final ceiling = decoNeeded ? engine.getCeiling(gfLow) : 0.0;
    if (ceiling > 0) {
      final candidate =
          (ceiling / stopIntervalM).ceilToDouble() * stopIntervalM;
      if (depth - rateMps <= candidate) {
        firstStop = candidate;
        break;
      }
      ascendTo(depth - rateMps);
    } else if (depth <= safetyStopDepthM) {
      break;
    } else {
      ascendTo(pyMax(depth - rateMps, safetyStopDepthM));
    }
  }

  if (!decoNeeded || firstStop <= 0) {
    // No deco: the safety stop, then the surface.
    final arrive = depth > safetyStopDepthM
        ? ascendTo(safetyStopDepthM, stopAtTarget: true)
        : t;
    if (depth >= safetyStopDepthM) {
      // A switch hold here counts.
      final remaining = pyMax(0.0, arrive + safetyStopSec - t);
      breathe(depth, remaining);
      t += remaining;
      addWaypoint(depth, t, gas);
      stops.add((depth, safetyStopSec, gas.id));
    }
    ascendTo(0.0);
    addWaypoint(0.0, t, gas);
    return (out, false, stops);
  }

  // Deco stops on 3 m levels. A first stop shallower than the depth now
  // but not on it is gone to first.
  var stop = firstStop < depth
      ? firstStop
      : (depth / stopIntervalM).floorToDouble() * stopIntervalM;
  stop = pyMax(stop, stopIntervalM);
  firstStop = pyMax(firstStop, stop);
  double gfAt(double d) => gfHigh + (gfLow - gfHigh) * (d / firstStop);

  while (stop > 0 && t - startSec < maxAscentPlanSec) {
    final arrive = ascendTo(stop, stopAtTarget: true);
    final nextLevel = stop - stopIntervalM;
    while (engine.getCeiling(gfAt(nextLevel)) > nextLevel &&
        t - arrive < maxAscentPlanSec) {
      breathe(depth, 10.0);
      t += 10.0;
    }
    var held = t - arrive;
    if (nextLevel <= 0 && held < safetyStopSec) {
      // The last stop is never shorter than a no-deco dive's safety stop:
      // a small obligation that a deco gas clears on the way up would
      // otherwise leave no stop at all.
      breathe(depth, safetyStopSec - held);
      t = arrive + safetyStopSec;
      held = safetyStopSec.toDouble();
    }
    final rounded = held > 0 ? (held / 60.0).ceilToDouble() * 60.0 : 0.0;
    if (rounded > held) {
      breathe(depth, rounded - held);
      t = arrive + rounded;
    }
    if (rounded > 0) {
      addWaypoint(stop, t, gas);
      stops.add((stop, rounded.truncate(), gas.id));
    }
    stop = nextLevel;
  }

  ascendTo(0.0);
  addWaypoint(0.0, t, gas);
  return (out, true, stops);
}
