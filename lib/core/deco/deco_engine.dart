/// The decompression engine (spec §7), ported from `utils/deco_engine.py`
/// of the Python app: Bühlmann ZH-L16C with gradient factors, the Schreiner
/// equation, NOAA CNS limits, and the look-ahead that gives a dive's time to
/// surface and ceiling per second.
///
/// The arithmetic is written in the Python code's order of operations so
/// that results agree to the last bits; do not simplify an expression here
/// without regenerating `test/fixtures/python_reference/deco/`.
library;

import 'dart:math' as math;

import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

/// ZH-L16C constants of one tissue compartment.
class CompartmentConstants {
  const CompartmentConstants(
    this.n2HalfLife,
    this.n2A,
    this.n2B,
    this.heHalfLife,
    this.heA,
    this.heB,
  );

  final double n2HalfLife;
  final double n2A;
  final double n2B;
  final double heHalfLife;
  final double heA;
  final double heB;
}

/// Alveolar water vapour pressure at 37 °C (47 mmHg), taken off the ambient
/// pressure before the inspired inert-gas pressure.
const double waterVapourBar = 0.0627;

/// The default surface pressure in bar.
const double standardSurfacePressureBar = 1.01325;

/// ZH-L16C coefficients (N2 and He), the set Subsurface and most dive
/// computers use.
const List<CompartmentConstants> zhl16cCoefficients = [
  CompartmentConstants(5.0, 1.1696, 0.5578, 1.88, 1.6189, 0.4770),
  CompartmentConstants(8.0, 1.0000, 0.6514, 3.02, 1.3830, 0.5747),
  CompartmentConstants(12.5, 0.8618, 0.7222, 4.72, 1.1919, 0.6527),
  CompartmentConstants(18.5, 0.7562, 0.7825, 6.99, 1.0458, 0.7223),
  CompartmentConstants(27.0, 0.6200, 0.8126, 10.21, 0.9220, 0.7582),
  CompartmentConstants(38.3, 0.5043, 0.8434, 14.48, 0.8205, 0.7957),
  CompartmentConstants(54.3, 0.4410, 0.8693, 20.53, 0.7305, 0.8279),
  CompartmentConstants(77.0, 0.4000, 0.8910, 29.11, 0.6502, 0.8553),
  CompartmentConstants(109.0, 0.3750, 0.9092, 41.20, 0.5950, 0.8757),
  CompartmentConstants(146.0, 0.3500, 0.9222, 55.19, 0.5545, 0.8903),
  CompartmentConstants(187.0, 0.3295, 0.9319, 70.69, 0.5333, 0.8997),
  CompartmentConstants(239.0, 0.3065, 0.9403, 90.34, 0.5189, 0.9073),
  CompartmentConstants(305.0, 0.2835, 0.9477, 115.29, 0.5181, 0.9122),
  CompartmentConstants(390.0, 0.2610, 0.9544, 147.42, 0.5176, 0.9171),
  CompartmentConstants(498.0, 0.2480, 0.9602, 188.24, 0.5172, 0.9217),
  CompartmentConstants(635.0, 0.2327, 0.9653, 240.03, 0.5119, 0.9267),
];

/// Maximum operating depth in metres of a gas at a PO2 limit.
double modMeters(double fO2, {double maxPo2 = 1.4}) {
  if (fO2 <= 0) {
    return 0.0;
  }
  return pyMax(0.0, ((maxPo2 / fO2) - 1.0) * 10.0);
}

/// Effective O2 and He fractions breathed from a closed-circuit loop that
/// holds the PO2 at [setpoint] bar through a diluent of [dilO2]/[dilHe]
/// (fractions). Only O2 is added or removed by the controller, so the rest
/// of the loop keeps the diluent's own He:N2 ratio.
(double fO2, double fHe) ccrEffectiveFractions(
  double setpoint,
  double ambientPressureBar,
  double dilO2,
  double dilHe,
) {
  if (ambientPressureBar <= 0) {
    return (dilO2, dilHe);
  }
  final fO2 = pyMin(setpoint / ambientPressureBar, 1.0);
  final dilInert = pyMax(1e-9, 1.0 - dilO2);
  final fHe = (1.0 - fO2) * (dilHe / dilInert);
  return (fO2, fHe);
}

/// NOAA CNS limits: (PO2 in bar, minutes).
const List<(double, double)> _cnsLimits = [
  (0.6, 720),
  (0.7, 570),
  (0.8, 450),
  (0.9, 360),
  (1.0, 300),
  (1.1, 240),
  (1.2, 210),
  (1.3, 180),
  (1.4, 150),
  (1.5, 120),
  (1.6, 45),
];

/// The CNS percentage added by [timeSeconds] at [po2], from the NOAA limits
/// with a straight line between the table's points. Nothing at or below
/// 0.5 bar, and nothing between 0.5 and 0.6 bar, where the table has no
/// point (as in Python).
double cnsIncrement(double po2, double timeSeconds) {
  if (po2 <= 0.5) {
    return 0.0;
  }
  double? timeLimit;
  if (po2 >= 1.6) {
    timeLimit = 45;
  } else {
    for (var i = 0; i < _cnsLimits.length - 1; i++) {
      final (p1, l1) = _cnsLimits[i];
      final (p2, l2) = _cnsLimits[i + 1];
      if (p1 <= po2 && po2 <= p2) {
        final fraction = (po2 - p1) / (p2 - p1);
        timeLimit = l1 + fraction * (l2 - l1);
        break;
      }
    }
  }
  if (timeLimit != null && timeLimit != 0) {
    return (100.0 / (timeLimit * 60.0)) * timeSeconds;
  }
  return 0.0;
}

/// The Bühlmann tissue model: sixteen compartments and the CNS clock.
class BuhlmannEngine {
  BuhlmannEngine({double surfacePressureBar = standardSurfacePressureBar})
    : surfacePressure = surfacePressureBar,
      // Tissues start saturated with air at the surface.
      pN2 = List<double>.filled(
        zhl16cCoefficients.length,
        (surfacePressureBar - waterVapourBar) * 0.79,
      ),
      pHe = List<double>.filled(zhl16cCoefficients.length, 0.0);

  BuhlmannEngine._copy(BuhlmannEngine other)
    : surfacePressure = other.surfacePressure,
      pN2 = List<double>.of(other.pN2),
      pHe = List<double>.of(other.pHe),
      cns = other.cns;

  final double surfacePressure;

  /// N2 and He partial pressures per compartment, in bar.
  final List<double> pN2;
  final List<double> pHe;

  /// Cumulative CNS toxicity in percent.
  double cns = 0.0;

  /// Moves the tissues [timeSeconds] on at [depthMeters] on a gas, with the
  /// Schreiner equation, and adds to the CNS clock.
  void update(double depthMeters, double timeSeconds, double fO2, double fHe) {
    final ambientPressure = surfacePressure + (depthMeters / 10.0);
    final po2 = ambientPressure * fO2;

    cns += cnsIncrement(po2, timeSeconds);

    final fN2 = 1.0 - fO2 - fHe;
    final piN2 = (ambientPressure - waterVapourBar) * fN2;
    final piHe = (ambientPressure - waterVapourBar) * fHe;

    final timeMinutes = timeSeconds / 60.0;

    for (var i = 0; i < zhl16cCoefficients.length; i++) {
      final coeffs = zhl16cCoefficients[i];
      pN2[i] = _schreiner(pN2[i], piN2, timeMinutes, coeffs.n2HalfLife);
      pHe[i] = _schreiner(pHe[i], piHe, timeMinutes, coeffs.heHalfLife);
    }
  }

  static double _schreiner(
    double pInitial,
    double pInspired,
    double time,
    double halfLife,
  ) {
    final k = math.log(2) / halfLife;
    return pInspired + (pInitial - pInspired) * math.exp(-k * time);
  }

  /// The decompression ceiling in metres at gradient factor [gf] (0..1).
  double getCeiling(double gf) {
    var maxCeilingBar = 0.0;

    for (var i = 0; i < zhl16cCoefficients.length; i++) {
      final coeffs = zhl16cCoefficients[i];
      final pTotal = pN2[i] + pHe[i];

      // A and B weighted by the two gases' share of the tissue tension.
      final a = (coeffs.n2A * pN2[i] + coeffs.heA * pHe[i]) / pTotal;
      final b = (coeffs.n2B * pN2[i] + coeffs.heB * pHe[i]) / pTotal;

      // Ambient pressure at which the tension meets the GF-scaled M-value.
      final denom = (gf / b) + (1.0 - gf);
      final ceilingBar = (pTotal - a * gf) / denom;

      if (ceilingBar > maxCeilingBar) {
        maxCeilingBar = ceilingBar;
      }
    }

    final ceilingMeters = (maxCeilingBar - surfacePressure) * 10.0;
    return pyMax(0.0, ceilingMeters);
  }

  /// The gradient factor in percent at [ambientBar]: the leading
  /// compartment's supersaturation over ambient as a share of its M-value
  /// gradient there. At the current depth this is GF99, at surface pressure
  /// SurfGF. Never negative: an on-gassing tissue reads 0.
  double gradientFactor(double ambientBar) {
    var worst = 0.0;
    for (var i = 0; i < zhl16cCoefficients.length; i++) {
      final coeffs = zhl16cCoefficients[i];
      final pTotal = pN2[i] + pHe[i];
      if (pTotal <= 0) {
        continue;
      }
      final a = (coeffs.n2A * pN2[i] + coeffs.heA * pHe[i]) / pTotal;
      final b = (coeffs.n2B * pN2[i] + coeffs.heB * pHe[i]) / pTotal;
      final mValue = ambientBar / b + a;
      final gradient = mValue - ambientBar;
      if (gradient <= 0) {
        continue;
      }
      worst = pyMax(worst, (pTotal - ambientBar) / gradient * 100.0);
    }
    return worst;
  }

  BuhlmannEngine clone() => BuhlmannEngine._copy(this);

  /// Seconds one can stay at [depthMeters] on this gas until the ceiling at
  /// [gf] first rises above the surface; pass GF high, as dive computers
  /// do. 0 when a stop is already owed, `null` when none appears within
  /// [capSeconds] (shown as "99+").
  int? computeNdlSeconds({
    required double depthMeters,
    required double fO2,
    required double fHe,
    required double gf,
    double stepSeconds = 10.0,
    int capSeconds = 99 * 60,
  }) {
    if (getCeiling(gf) > 0) {
      return 0;
    }
    final sim = clone();
    var elapsed = 0.0;
    while (elapsed < capSeconds) {
      sim.update(depthMeters, stepSeconds, fO2, fHe);
      elapsed += stepSeconds;
      if (sim.getCeiling(gf) > 0) {
        return elapsed.toInt();
      }
    }
    return null;
  }
}

/// A gas the diver carries, with the depth down to which it may be used.
class GasDefinition {
  const GasDefinition(this.name, this.fO2, this.fHe, this.modMeters);

  final String name;
  final double fO2;
  final double fHe;
  final double modMeters;
}

/// A rebreather loop: the setpoint in bar and the diluent's fractions.
typedef DecoLoop = ({double setpoint, double dilO2, double dilHe});

/// One sample of the profile handed to [DiveDecompressor.processWaypoints].
/// Python passes `Waypoint.model_dump()` dicts with `divetime` and
/// `datetime` added; these are the keys it reads.
class DecoWaypoint {
  DecoWaypoint({
    required this.divetime,
    required this.depth,
    required this.datetime,
    this.setpoint,
    this.diluentO2Percent,
    this.diluentHePercent,
  }) : assert(datetime.isUtc, naiveTimeMessage);

  /// Seconds since the start of the dive.
  final int divetime;

  /// Metres.
  final double depth;

  /// Naive local time of the sample.
  final DateTime datetime;

  final double? setpoint;
  final double? diluentO2Percent;
  final double? diluentHePercent;

  /// The loop of a waypoint that has both a setpoint and a diluent, else
  /// `null` (open circuit or bailout).
  DecoLoop? get loop {
    final setpoint = this.setpoint;
    final dilO2 = diluentO2Percent;
    if (setpoint == null || dilO2 == null) {
      return null;
    }
    return (
      setpoint: setpoint,
      dilO2: dilO2 / 100.0,
      dilHe: _orZero(diluentHePercent) / 100.0,
    );
  }
}

/// Calculated decompression data at one second of a dive.
class TtsDataPoint {
  const TtsDataPoint({
    required this.timestamp,
    required this.depth,
    required this.ttsSeconds,
    required this.ceilingMeters,
    required this.activeGas,
    required this.gfCurrent,
    required this.surfGf,
    required this.cns,
    required this.po2,
  });

  final DateTime timestamp;
  final double depth;

  /// Total time to surface.
  final int ttsSeconds;

  /// The ceiling at GF high.
  final double ceilingMeters;
  final String activeGas;

  /// GF99 in percent, one decimal.
  final double gfCurrent;

  /// SurfGF in percent, one decimal.
  final double surfGf;

  /// Cumulative CNS toxicity in percent.
  final double cns;
  final double po2;
}

/// Runs a profile through the tissue model second by second and looks ahead
/// for the time to surface. It keeps its tissues and its safety-stop state
/// between calls, so use one per dive.
class DiveDecompressor {
  DiveDecompressor({
    this.gfLow = 0.30,
    this.gfHigh = 0.70,
    int simulationInterval = 10,
  }) : simInterval = simulationInterval;

  BuhlmannEngine engine = BuhlmannEngine();
  final double gfLow;
  final double gfHigh;

  /// Every how many seconds of the dive the look-ahead runs.
  final int simInterval;

  /// 9 m/min.
  final double ascentRateMps = 0.15;
  double safetyStopTimeLeft = 180.0;
  bool safetyStopTriggered = false;

  /// The decompression data for every second from 0 to the last waypoint's
  /// `divetime`.
  Map<int, TtsDataPoint> processWaypoints(
    List<DecoWaypoint> waypoints,
    List<GasDefinition> gases,
  ) {
    if (waypoints.isEmpty) {
      return {};
    }

    final interpolated = _interpolateProfile(waypoints);
    final results = <int, TtsDataPoint>{};

    var lastTts = 0;
    var lastCeiling = 0.0;
    var runningMaxDepth = 0.0;

    for (final MapEntry(key: sec, value: data) in interpolated.entries) {
      final depth = data.depth;
      runningMaxDepth = pyMax(runningMaxDepth, depth);

      // The safety stop's clock, one second at a time.
      if (runningMaxDepth > 10.0) {
        safetyStopTriggered = true;
        if (3.0 <= depth && depth <= 6.0) {
          safetyStopTimeLeft = pyMax(0.0, safetyStopTimeLeft - 1.0);
        } else if (depth < 3.0) {
          if (depth < 1.0) {
            safetyStopTriggered = false;
          }
        }
      }

      // On the loop a rebreather breathes its setpoint through the diluent;
      // otherwise the best gas carried for the depth.
      final loop = data.loop;
      final ambient = engine.surfacePressure + depth / 10.0;
      final activeGas = loop != null
          ? _loopGas(loop, ambient)
          : _getBestGas(depth, gases);

      engine.update(depth, 1.0, activeGas.fO2, activeGas.fHe);

      if (sec % simInterval == 0) {
        final (tts, ceiling) = _simulateTts(
          depth,
          activeGas,
          gases,
          loop: loop,
        );
        lastTts = tts;
        lastCeiling = ceiling;
      } else {
        // Between look-aheads the TTS counts down while at a stop.
        if (3.0 <= depth && depth <= 6.0 && lastTts > 0) {
          lastTts = (lastTts - 1 > 0 ? lastTts - 1 : 0);
        }
      }

      results[sec] = TtsDataPoint(
        timestamp: data.datetime,
        depth: depth,
        ttsSeconds: lastTts,
        ceilingMeters: lastCeiling,
        activeGas: activeGas.name,
        gfCurrent: pyRoundTo(engine.gradientFactor(ambient), 1),
        surfGf: pyRoundTo(engine.gradientFactor(engine.surfacePressure), 1),
        cns: engine.cns,
        po2: loop != null ? loop.setpoint : ambient * activeGas.fO2,
      );
    }

    return results;
  }

  /// The loop's gas at an ambient pressure.
  GasDefinition _loopGas(DecoLoop loop, double ambient) {
    final (fO2, fHe) = ccrEffectiveFractions(
      loop.setpoint,
      ambient,
      loop.dilO2,
      loop.dilHe,
    );
    return GasDefinition('CCR', fO2, fHe, 999.0);
  }

  /// A depth for every second from 0 to the last `divetime`, on straight
  /// lines between the waypoints.
  ///
  /// As in Python, the timestamp and the loop are the earlier waypoint's,
  /// and a profile whose first waypoint is later than second 0 is continued
  /// backwards along its first segment (which can give a depth above the
  /// surface; spec §10.17).
  Map<int, ({double depth, DateTime datetime, DecoLoop? loop})>
  _interpolateProfile(List<DecoWaypoint> waypoints) {
    // Python's sorted() is stable; List.sort is not promised to be.
    final order = List<int>.generate(waypoints.length, (i) => i)
      ..sort((a, b) {
        final byTime = waypoints[a].divetime.compareTo(waypoints[b].divetime);
        return byTime != 0 ? byTime : a.compareTo(b);
      });
    final sorted = [for (final i in order) waypoints[i]];
    final maxTime = sorted.last.divetime;

    final timeline =
        <int, ({double depth, DateTime datetime, DecoLoop? loop})>{};
    var index = 0;

    for (var s = 0; s <= maxTime; s++) {
      while (index < sorted.length - 1 && sorted[index + 1].divetime <= s) {
        index += 1;
      }

      final p1 = sorted[index];
      double depth;
      if (index < sorted.length - 1) {
        final p2 = sorted[index + 1];
        final dt = p2.divetime - p1.divetime;
        if (dt > 0) {
          final fraction = (s - p1.divetime) / dt;
          depth = p1.depth + (p2.depth - p1.depth) * fraction;
        } else {
          depth = p1.depth;
        }
      } else {
        depth = p1.depth;
      }

      timeline[s] = (depth: depth, datetime: p1.datetime, loop: p1.loop);
    }
    return timeline;
  }

  /// A virtual ascent from the current state: the time to surface and the
  /// current ceiling at GF high. On the loop the ascent stays on the loop
  /// at the same setpoint.
  (int tts, double ceiling) _simulateTts(
    double currentDepth,
    GasDefinition currentGas,
    List<GasDefinition> allGases, {
    DecoLoop? loop,
  }) {
    GasDefinition gasAt(double depth) {
      if (loop != null) {
        return _loopGas(loop, engine.surfacePressure + depth / 10.0);
      }
      return _getBestGas(depth, allGases);
    }

    // A copy, so the look-ahead leaves the dive's own tissues alone.
    final simEngine = engine.clone();
    final currentCeiling = simEngine.getCeiling(gfHigh);

    if (currentDepth <= 0.1) {
      return (0, 0.0);
    }

    var totalTime = 0;
    var simDepth = currentDepth;
    var simGas = currentGas;

    final needsSafetyStop = safetyStopTriggered && safetyStopTimeLeft > 0;
    var safetyStopDone = false;

    while (simDepth > 0) {
      final targetCeiling = simEngine.getCeiling(gfLow);

      if (simDepth > targetCeiling && simDepth > 0) {
        // Deeper than the ceiling: ascend, with what is left of the safety
        // stop once on passing 5 m.
        if (needsSafetyStop && !safetyStopDone && simDepth <= 5.0) {
          final remTime = safetyStopTimeLeft;
          totalTime += remTime.toInt();
          safetyStopDone = true;
          simEngine.update(5.0, remTime, simGas.fO2, simGas.fHe);
        }

        final ascStep = pyMin(simDepth, ascentRateMps);
        simDepth -= ascStep;
        totalTime += 1;

        simGas = gasAt(simDepth);
        simEngine.update(simDepth, 1.0, simGas.fO2, simGas.fHe);
      } else {
        // A mandatory stop, on a multiple of 3 m.
        var stopDepth = (simDepth / 3.0).ceilToDouble() * 3.0;
        if (stopDepth < 3.0) {
          stopDepth = 0.0;
        }

        if (stopDepth == 0) {
          break;
        }

        if (loop != null) {
          simGas = gasAt(stopDepth);
        }
        // Wait until the ceiling at GF high allows the next stop.
        while (true) {
          final nextStopCeiling = simEngine.getCeiling(gfHigh);
          if (nextStopCeiling <= (stopDepth - 3.0)) {
            break;
          }

          simEngine.update(stopDepth, 10.0, simGas.fO2, simGas.fHe);
          totalTime += 10;
          if (totalTime > 10000) {
            break;
          }
        }

        simDepth = stopDepth - 3.0;
        // The move between two stops.
        totalTime += 20;
      }
    }

    return (totalTime, currentCeiling);
  }

  /// The richest gas (highest O2) usable at [depth]; of two equally rich
  /// ones the first in the list. Air when none fits.
  GasDefinition _getBestGas(double depth, List<GasDefinition> gases) {
    GasDefinition? best;
    for (final gas in gases) {
      if (gas.modMeters >= depth && (best == null || gas.fO2 > best.fO2)) {
        best = gas;
      }
    }
    return best ?? const GasDefinition('AIR', 0.21, 0.0, 100.0);
  }
}

// Python: `float(value or 0.0)`.
double _orZero(double? value) => value ?? 0.0;
