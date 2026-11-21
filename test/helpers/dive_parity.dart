import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/model/dive.dart';

import 'python_reference.dart';

/// Equal to the last bits on one machine (the same operations in the same
/// order as Python); the tolerance is for another platform's maths library.
Matcher nearly(num expected) =>
    closeTo(expected, expected.abs() * 1e-12 + 1e-12);

/// [value] without its null entries, recursively: the fixtures that dump
/// with `exclude_none` leave them out.
Object? withoutNulls(Object? value) => switch (value) {
  final Map<String, dynamic> map => {
    for (final entry in map.entries)
      if (entry.value != null) entry.key: withoutNulls(entry.value),
  },
  final List<dynamic> list => [for (final item in list) withoutNulls(item)],
  _ => value,
};

const _floatFields = [
  'ceiling',
  'deco_stop_depth',
  'depth',
  'max_depth',
  'temp',
];

/// Compares [dive] with a Python `Dive.model_dump(mode="json",
/// exclude_none=True, exclude={"log_path"})` in [want]: every field of the
/// dive and of every waypoint, floats that come out of arithmetic with
/// [nearly], everything else exactly.
///
/// [ignoreDiveFields] and [portOnlyWaypointFields] name what the port sets
/// and Python does not for the format at hand (spec §10.16).
/// [nullWherePythonHasZero] names the waypoint fields a format's Python
/// parser defaults to 0 when the log has none.
///
/// The deliberate differences from Python (spec §10.8) are counted, not
/// hidden: a waypoint whose depth or temperature is `null` in the port
/// where Python has its 0.0 default, and a tank without a reading. Returns
/// how many of each there were.
({int depthless, int templess, int pressureless, int zeroDefaults})
expectDiveMatchesPython(
  Dive dive,
  Map<String, dynamic> want, {
  required String reason,
  Set<String> ignoreDiveFields = const {},
  Set<String> portOnlyWaypointFields = const {},
  Set<String> nullWherePythonHasZero = const {},
}) {
  final expected = Map<String, dynamic>.of(want);
  final got = withoutNulls(dive.toJson())! as Map<String, dynamic>
    ..remove('log_path')
    // The tank sizes are the port's (spec §10.54).
    ..remove('tank_volumes_l');
  for (final field in ignoreDiveFields) {
    got.remove(field);
    expected.remove(field);
  }
  final wantWaypoints = jsonObjects(expected.remove('waypoints'));
  final gotWaypoints = jsonObjects(got.remove('waypoints'));
  expect(got, expected, reason: reason);
  expect(gotWaypoints, hasLength(wantWaypoints.length), reason: reason);

  var depthless = 0;
  var templess = 0;
  var pressureless = 0;
  var zeroDefaults = 0;
  for (var w = 0; w < gotWaypoints.length; w++) {
    final gotWp = gotWaypoints[w];
    final wantWp = Map<String, dynamic>.of(wantWaypoints[w]);
    final at = '$reason waypoint $w';
    for (final field in portOnlyWaypointFields) {
      expect(wantWp.containsKey(field), isFalse, reason: '$at $field');
      gotWp.remove(field);
    }
    for (final field in nullWherePythonHasZero) {
      if (!gotWp.containsKey(field) && wantWp[field] == 0) {
        // Not in the log: null in the port, Python's 0 default (§10.8).
        wantWp.remove(field);
        zeroDefaults += 1;
      }
    }
    for (final name in _floatFields) {
      final wantValue = wantWp.remove(name) as num?;
      final gotValue = gotWp.remove(name);
      if (gotValue == null && wantValue == 0.0) {
        if (name == 'depth') {
          depthless += 1;
          continue;
        }
        if (name == 'temp') {
          templess += 1;
          continue;
        }
      }
      expect(
        gotValue,
        wantValue == null ? isNull : nearly(wantValue),
        reason: '$at $name',
      );
    }
    final wantTanks = wantWp.remove('tanks') as Map<String, dynamic>;
    final gotTanks = gotWp.remove('tanks') as Map<String, dynamic>;
    expect(gotTanks.keys, wantTanks.keys, reason: '$at tanks');
    for (final key in wantTanks.keys) {
      final wantTank = Map<String, dynamic>.of(
        wantTanks[key] as Map<String, dynamic>,
      );
      final gotTank = gotTanks[key] as Map<String, dynamic>;
      if (!gotTank.containsKey('pressure_bar') &&
          wantTank['pressure_bar'] == 0.0) {
        // A tank without a reading: null in the port, 0.0 in Python.
        pressureless += 1;
        wantTank.remove('pressure_bar');
      }
      expect(gotTank.keys, wantTank.keys, reason: '$at tank $key');
      for (final field in wantTank.keys) {
        final value = wantTank[field];
        expect(
          gotTank[field],
          value is num ? nearly(value) : value,
          reason: '$at tank $key $field',
        );
      }
    }
    if (pressureless > 0 &&
        !gotWp.containsKey('pressure_sac') &&
        wantWp['pressure_sac'] == 0.0 &&
        !wantWp.containsKey('air_remaining')) {
      // Python computes a SAC of 0 from the 0 bar it stores for a tank
      // without a reading; the port has no pressure to compute one from.
      wantWp.remove('pressure_sac');
    }
    if (dive.tankVolumesL.isNotEmpty && !wantWp.containsKey('volume_sac')) {
      // VSAC worked out from the tank sizes after parsing (spec §10.54).
      gotWp.remove('volume_sac');
    }
    expect(gotWp, wantWp, reason: at);
  }
  return (
    depthless: depthless,
    templess: templess,
    pressureless: pressureless,
    zeroDefaults: zeroDefaults,
  );
}
