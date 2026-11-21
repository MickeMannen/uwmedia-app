/// Values a computer shows that no log records, computed from what the log
/// has, ported from `utils/hud_gas.py` of the Python app:
///
/// - the MOD of the breathed gas from its O2 fraction and the brand's MOD
///   PO2 limit;
/// - a Shearwater's gas time remaining (GTR) from the tank pressure trend:
///   the SAC is the pressure drop over the last two minutes normalised to
///   1 ATA; the gas left after the reserve and a direct ascent at 10 m/min,
///   divided by the SAC at the current ambient pressure, is the time. No
///   value until two minutes of data exist ("wait"), and none once
///   decompression stops are required.
library;

import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

/// The O2 fraction of the gas breathed: the log's own (a rebreather's
/// diluent on the loop), else the first tank with a mix; or `null`.
double? gasO2Fraction(Waypoint waypoint) {
  final own = waypoint.gasO2Percent;
  if (own != null && own > 0) {
    return own / 100.0;
  }
  for (final tank in waypoint.tanks.values) {
    if (tank.o2Percent > 0) {
      return tank.o2Percent / 100.0;
    }
  }
  return null;
}

/// The maximum operating depth of the breathed gas at the brand's MOD PO2
/// limit (`po2_limits.mod`, 1.4 bar when the brand sets none).
double? modMetres(
  HudRules rules,
  String? manufacturer,
  String? model,
  Waypoint waypoint,
) {
  final fO2 = gasO2Fraction(waypoint);
  if (fO2 == null || fO2 == 0) {
    return null;
  }
  final limits = rules.getRuleConfig(manufacturer, model, 'po2_limits');
  final limit = limits is Map<String, dynamic> && limits['mod'] is num
      ? (limits['mod'] as num).toDouble()
      : 1.4;
  return pyMax(0.0, (limit / fO2 - 1.0) * 10.0);
}

double? _primaryPressure(Waypoint wp) =>
    wp.tanks.isEmpty ? null : wp.tanks.values.first.pressureBar;

/// {time since start: seconds, or null where the device would show "wait"
/// (under two minutes of pressure data) or nothing (in deco)}.
Map<int, int?> _buildGtrTimeline(
  HudRules rules,
  String? manufacturer,
  String? model,
  List<Waypoint> waypoints,
  Map<String, dynamic> rule,
) {
  final window = (rule['sac_window_s'] as num? ?? 120).toDouble();
  final ascentRate = (rule['ascent_m_per_min'] as num? ?? 10.0).toDouble();
  final reserve = rules.tankReserveThresholds(manufacturer, model)?.$1 ?? 50.0;
  // (seconds, pressure, ambient) of the samples inside the window.
  final history = <(double, double, double)>[];
  final timeline = <int, int?>{};
  for (final wp in waypoints) {
    final t = wp.timeSinceStart.toDouble();
    final depth = wp.depth ?? 0.0;
    final pressure = _primaryPressure(wp);
    final ambient = 1.0 + depth / 10.0;
    if (pressure == null) {
      timeline[wp.timeSinceStart] = null;
      continue;
    }
    history.add((t, pressure, ambient));
    while (history.isNotEmpty && t - history.first.$1 > window) {
      history.removeAt(0);
    }
    final stop = wp.decoStopDepth;
    final inDeco = stop != null && stop != 0;
    if (inDeco || t - history.first.$1 < window - 1e-6) {
      timeline[wp.timeSinceStart] = null;
      continue;
    }
    final (t0, p0, _) = history.first;
    final minutes = (t - t0) / 60.0;
    final meanAmbient = pySum(history.map((h) => h.$3)) / history.length;
    // bar/min at 1 ATA.
    final sac = minutes > 0 ? (p0 - pressure) / minutes / meanAmbient : 0.0;
    if (sac <= 0.05) {
      // No measurable consumption yet.
      timeline[wp.timeSinceStart] = null;
      continue;
    }
    final ascentMinutes = depth / ascentRate;
    final pAscent = sac * ascentMinutes * (ambient + 1.0) / 2.0;
    final remaining = pressure - reserve - pAscent;
    timeline[wp.timeSinceStart] = (pyMax(0.0, remaining / (sac * ambient)) * 60)
        .toInt();
  }
  return timeline;
}

/// Seconds of gas time remaining as the brand's `gas_time` rule defines it,
/// or `null` (no rule, no history yet, in deco). Only the Shearwater GTR
/// formula exists so far.
int? gasTimeRemaining(
  HudRules rules,
  String? manufacturer,
  String? model,
  Waypoint? waypoint,
  List<Waypoint>? waypoints,
) {
  final rule = rules.getRuleConfig(manufacturer, model, 'gas_time');
  if (rule is! Map<String, dynamic> ||
      rule['formula'] != 'shearwater_gtr' ||
      waypoints == null ||
      waypoints.isEmpty ||
      waypoint == null) {
    return null;
  }
  final timeline = rules.cachedTimeline(
    'gtr',
    manufacturer,
    model,
    waypoints,
    () => _buildGtrTimeline(rules, manufacturer, model, waypoints, rule),
  );
  return timeline[waypoint.timeSinceStart];
}
