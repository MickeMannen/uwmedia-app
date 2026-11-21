/// SAC and gas time remaining (GTR) for logs that do not carry them, ported
/// from `utils/gas_consumption.py` of the Python app, the way the Perdix 2
/// manual defines them (p.41):
///
/// - SAC is the rate of tank-pressure change over the last two minutes,
///   normalised to 1 atmosphere, in bar/min. Nothing for the first 30
///   seconds of a dive, and nothing until the window is full (the computer
///   says "wait").
/// - GTR is the time that can be spent at the current depth until a direct
///   ascent at 10 m/min would surface with the reserve pressure.
///
/// Two tanks (sidemount) are summed, and a reserve is kept in each.
library;

import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

const int sacWindowSec = 120;
const int sacWarmupSec = 30;
const double ascentRateMPerMin = 10.0;

/// Perdix 2 "Reserve Pressure" default (p.53).
const double defaultReserveBar = 50.0;

double _ambientAta(double depthM) => 1.0 + pyMax(0.0, depthM) / 10.0;

double? _totalPressure(Waypoint wp) {
  final readings = [
    for (final tank in wp.tanks.values)
      if (tank.pressureBar != null) tank.pressureBar!,
  ];
  return readings.isEmpty ? null : pySum(readings);
}

/// Sets `pressureSac` (bar/min) and `airRemaining` (seconds) on every
/// waypoint that has neither, from the tank pressures on them. The
/// waypoints must be in time order. Values a log carries are left alone.
void fillSacAndGtr(
  List<Waypoint> waypoints, {
  double reserveBar = defaultReserveBar,
  int windowSec = sacWindowSec,
  int warmupSec = sacWarmupSec,
}) {
  // (seconds, total pressure, ambient) of the samples inside the window.
  final history = <(int, double, double)>[];
  for (final wp in waypoints) {
    final t = wp.timeSinceStart;
    // A sample without a depth is at the surface here, as in the deco pass:
    // the Python parsers store 0.0 for a missing depth (spec §10.17).
    final depth = wp.depth ?? 0.0;
    final pressure = _totalPressure(wp);
    if (pressure == null) {
      continue;
    }
    final ambient = _ambientAta(depth);
    history.add((t, pressure, ambient));
    while (history.isNotEmpty && history.first.$1 < t - windowSec) {
      history.removeAt(0);
    }
    if (wp.pressureSac != null) {
      continue;
    }
    if (t < warmupSec || history.length < 2) {
      continue;
    }
    final (t0, p0, _) = history.first;
    final span = t - t0;
    if (span < windowSec) {
      // The computer says "wait" until it has the full window.
      continue;
    }
    final avgAmbient = pySum(history.map((h) => h.$3)) / history.length;
    var sac = (p0 - pressure) / (span / 60.0) / avgAmbient;
    sac = pyMax(0.0, sac);
    wp.pressureSac = pyRoundTo(sac, 2);
    if (wp.airRemaining == null) {
      final tankCount = wp.tanks.isEmpty ? 1 : wp.tanks.length;
      final ascentMin = depth / ascentRateMPerMin;
      // Average ambient pressure on the way up.
      final pAscent = sac * ascentMin * (1.0 + depth / 20.0);
      final remaining = pressure - reserveBar * tankCount - pAscent;
      if (sac > 0) {
        final gtrMin = remaining / (sac * ambient);
        wp.airRemaining = (pyMax(0.0, gtrMin) * 60).toInt();
      }
    }
  }
}

/// Sets `volumeSac` (litres a minute at the surface) on the waypoints of a
/// log that records none, from the tank pressures and the tank sizes in
/// [volumesL] (by tank key): the gas in the tanks (pressure times size,
/// summed) used over the last two minutes, normalised to 1 atmosphere, the
/// way [fillSacAndGtr] works out SAC from the pressures. A waypoint with a
/// reading on a tank whose size is not known gets none. The Python app has
/// no such step: it shows VSAC only where the log has it (spec §10.54).
void fillVolumeSac(
  List<Waypoint> waypoints,
  Map<String, double> volumesL, {
  int windowSec = sacWindowSec,
  int warmupSec = sacWarmupSec,
}) {
  if (volumesL.isEmpty || waypoints.any((wp) => wp.volumeSac != null)) {
    return;
  }
  // (seconds, litres of gas at 1 bar, ambient) of the samples inside the
  // window.
  final history = <(int, double, double)>[];
  for (final wp in waypoints) {
    double? gas;
    for (final MapEntry(:key, value: tank) in wp.tanks.entries) {
      final pressure = tank.pressureBar;
      if (pressure == null) {
        continue;
      }
      final volume = volumesL[key];
      if (volume == null) {
        gas = null;
        break;
      }
      gas = (gas ?? 0.0) + pressure * volume;
    }
    if (gas == null) {
      continue;
    }
    final t = wp.timeSinceStart;
    history.add((t, gas, _ambientAta(wp.depth ?? 0.0)));
    while (history.isNotEmpty && history.first.$1 < t - windowSec) {
      history.removeAt(0);
    }
    if (t < warmupSec || history.length < 2) {
      continue;
    }
    final (t0, g0, _) = history.first;
    final span = t - t0;
    if (span < windowSec) {
      continue;
    }
    final avgAmbient = pySum(history.map((h) => h.$3)) / history.length;
    wp.volumeSac = pyRoundTo(
      pyMax(0.0, (g0 - gas) / (span / 60.0) / avgAmbient),
      2,
    );
  }
}
