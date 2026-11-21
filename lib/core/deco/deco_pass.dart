/// The pass every profile parser runs once its samples are read: the
/// Bühlmann recompute for ceiling, TTS, GF and CNS where the log does not
/// carry them, then SAC and gas time.
///
/// Python has this three times (inline in `parsers/uddf.py` and
/// `parsers/subsurface.py`, and `parsers/deco_pass.py`) with small
/// differences. The port has this one, with the UDDF copy's rules (spec
/// §10.16, decided 2026-11-12): SurfGF is always set, a logged CNS is kept,
/// a file that logs its stops gets a direct-ascent TTS where it says there
/// is none, and SAC is filled only when the log has none at all. A value
/// the log itself recorded always wins over the recompute.
library;

import 'package:uwmedia_app/core/deco/deco_engine.dart';
import 'package:uwmedia_app/core/deco/gas_consumption.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

/// A [GasDefinition] from percentages, with its MOD at PO2 1.4.
GasDefinition decoGas(String name, double o2Percent, double hePercent) {
  final fO2 = o2Percent / 100.0;
  return GasDefinition(name, fO2, hePercent / 100.0, modMeters(fO2));
}

/// GF low and high as 0..1 fractions from percent values, or `null` when
/// one is missing or they are not `0 < low ≤ high ≤ 100`.
(double low, double high)? parseGf(double? lowPercent, double? highPercent) {
  if (lowPercent == null || highPercent == null) {
    return null;
  }
  final low = lowPercent / 100.0;
  final high = highPercent / 100.0;
  return 0 < low && low <= high && high <= 1.0 ? (low, high) : null;
}

/// Fills `ceiling` and `surfGf`, and `tts`, `decoStopDepth`, `gf`, `po2`
/// and `cns` where still `null`, sets `nextStopDepth` from the stop depth,
/// then SAC and gas time when the log has no SAC.
///
/// [fileGf] are the log's own gradient factors (fractions); without them
/// the engine's 0.30/0.70 apply. [gases] defaults to air. Pass
/// [fileLogsStops] when the log records its deco stops: a waypoint it gives
/// no stop then gets the time of a direct ascent as its TTS.
///
/// A sample without a depth is at the surface for the recompute, which is
/// what the Python parsers hand their passes for a missing depth (0.0); in
/// the port's model it is `null` (spec §10.8, §10.17). The SAC fill takes
/// it the same way.
///
/// [unrecordableGas] is for the UDDF parser: Python cannot
/// record a gas without a name as the one breathed, and gives the whole
/// recompute up when that gas comes into use. If the gas with this name is
/// breathed at any second, nothing is recomputed (SAC is still filled).
void applyDecoAndGas(
  List<Waypoint> waypoints,
  List<GasDefinition> gases, {
  (double low, double high)? fileGf,
  bool fileLogsStops = false,
  String? unrecordableGas,
}) {
  if (waypoints.isEmpty) {
    return;
  }
  final decompressor = fileGf == null
      ? DiveDecompressor(simulationInterval: 10)
      : DiveDecompressor(
          gfLow: fileGf.$1,
          gfHigh: fileGf.$2,
          simulationInterval: 10,
        );
  final results = decompressor.processWaypoints([
    for (final wp in waypoints)
      DecoWaypoint(
        divetime: wp.timeSinceStart,
        depth: wp.depth ?? 0.0,
        datetime: wp.timestamp,
        setpoint: wp.setpoint,
        diluentO2Percent: wp.diluentO2Percent,
        diluentHePercent: wp.diluentHePercent,
      ),
  ], gases.isEmpty ? const [GasDefinition('AIR', 0.21, 0.0, 56.0)] : gases);

  if (unrecordableGas != null &&
      results.values.any((result) => result.activeGas == unrecordableGas)) {
    fillSacWhenNoneLogged(waypoints);
    return;
  }

  for (final wp in waypoints) {
    final res = results[wp.timeSinceStart];
    if (res == null) {
      continue;
    }
    if (wp.tts == null) {
      if (fileLogsStops && wp.decoStopDepth == 0.0) {
        // The file says no stop here: a direct ascent, whatever the
        // recompute still owes.
        final seconds = (wp.depth ?? 0.0) / decompressor.ascentRateMps;
        if (!seconds.isFinite) {
          // Python fails on this depth and gives the recompute up here:
          // the waypoints before it keep what they got.
          fillSacWhenNoneLogged(waypoints);
          return;
        }
        wp.tts = seconds.ceil();
      } else {
        wp.tts = res.ttsSeconds;
      }
    }
    wp.ceiling = res.ceilingMeters;
    wp.decoStopDepth ??= res.ceilingMeters;
    wp.gf ??= res.gfCurrent;
    // No log records SurfGF: always the recompute.
    wp.surfGf = res.surfGf;
    wp.po2 ??= pyRoundTo(res.po2, 2);
    wp.cns ??= res.cns.toInt();

    // The next stop: the next multiple of 3 m at or below the stop depth,
    // the log's own where it has one.
    final stop = wp.decoStopDepth ?? 0.0;
    wp.nextStopDepth = stop > 0 ? (stop / 3.0).ceilToDouble() * 3.0 : 0.0;
    wp.nextStopTime ??= 0;
  }

  fillSacWhenNoneLogged(waypoints);
}

/// SAC and gas time the way the computer shows them, for a log that
/// records no SAC at all.
void fillSacWhenNoneLogged(List<Waypoint> waypoints) {
  if (!waypoints.any((wp) => wp.pressureSac != null)) {
    fillSacAndGtr(waypoints);
  }
}
