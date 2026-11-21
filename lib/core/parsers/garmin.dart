/// Garmin Descent FIT logs, ported from `parsers/garmin.py` of the Python
/// app (spec §4.1). The parser works on decoded FIT messages in the shape
/// the Python FIT SDK gives them ([FitMessages]); `fit_reader.dart` makes
/// those from a file's bytes.
///
/// A value a record does not carry is `null` here where Python stores 0
/// (spec §10.8): depth, temperature, the stop depth and time, TTS, gas
/// time, ascent rate, tissue load, the SAC values, heart rate, CNS and a
/// tank's pressure. The PO2 is the exception (§10.8): it is computed from
/// the setpoint or the gas at depth when the record has none, as in Python.
library;

import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/deco/deco_engine.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

/// One decoded FIT message: field name (the FIT profile's snake_case name)
/// to value. A timestamp is a UTC `DateTime` or the raw FIT seconds.
typedef FitMesg = Map<String, Object?>;

/// Decoded messages by list name, as the Python SDK names them
/// (`record_mesgs`, `tank_update_mesgs`, ...).
typedef FitMessages = Map<String, List<FitMesg>>;

/// Seconds from the Unix epoch to the FIT epoch (1989-12-31 UTC).
const int fitEpochS = 631065600;

/// Garmin product codes the Python SDK's profile does not name yet. 4518 is
/// the Descent X50i.
const Map<int, String> _unmappedGarminProducts = {4518: 'descent_x50i'};

/// A Garmin rebreather's setpoint switches (dive_alert names) and which of
/// the two setpoints of `dive_settings` each switches to.
const Map<String, String> setpointAlerts = {
  'setpoint_switch_auto_low': 'low',
  'setpoint_switch_manual_low': 'low',
  'setpoint_switch_auto_high': 'high',
  'setpoint_switch_manual_high': 'high',
};
const String _diluentMode = 'closed_circuit_diluent';

/// The setpoints in force over a dive: each logged switch's setpoint from
/// its time on, and before the first one (a `null` time) the other
/// setpoint. No switch, or no value for the side switched to: nothing, none
/// is invented.
List<(DateTime? time, double bar)> setpointTimeline(
  List<(DateTime time, String side)> switches,
  Map<String, double?> setpoints,
) {
  final out = <(DateTime?, double)>[];
  for (final (time, side) in switches) {
    final value = setpoints[side];
    if (value != null) {
      out.add((time, value));
    }
  }
  if (out.isNotEmpty) {
    final before = setpoints[switches.first.$2 == 'low' ? 'high' : 'low'];
    if (before != null) {
      out.insert(0, (null, before));
    }
  }
  return out;
}

/// The UTC offset in minutes of a dive from its local and UTC start, to the
/// nearest minute.
int timezoneOffsetMinutes(DateTime local, DateTime utc) =>
    pyRound(local.difference(utc).inMicroseconds / 1e6 / 60);

/// Python `str(timezone(timedelta(minutes=m)))`: "UTC", "UTC+07:00".
String timezoneName(int offsetMinutes) {
  if (offsetMinutes == 0) {
    return 'UTC';
  }
  final sign = offsetMinutes < 0 ? '-' : '+';
  final minutes = offsetMinutes.abs();
  String two(int value) => value.toString().padLeft(2, '0');
  return 'UTC$sign${two(minutes ~/ 60)}:${two(minutes % 60)}';
}

/// A message's timestamp as a UTC instant.
DateTime? _instant(Object? value) => switch (value) {
  final int seconds => DateTime.fromMillisecondsSinceEpoch(
    (seconds + fitEpochS) * 1000,
    isUtc: true,
  ),
  final DateTime time => time.toUtc(),
  _ => null,
};

double? _double(Object? value) => (value as num?)?.toDouble();

// Python `int(x)`: towards zero.
int? _int(Object? value) => (value as num?)?.toInt();

bool _truthy(Object? value) => switch (value) {
  null => false,
  final num number => number != 0,
  final String text => text.isNotEmpty,
  _ => true,
};

class _Gas {
  _Gas({
    required this.he,
    required this.o2,
    required this.mode,
    required this.enabled,
  });

  /// Percent.
  final double he;
  final double o2;
  final String mode;
  final bool enabled;
}

const double _degreesPerSemicircle = 180.0 / 2147483648;

/// FIT logs the computer's own next stop but no ceiling, GF99 or SurfGF:
/// they come from the same Bühlmann engine the other parsers use. On a
/// rebreather's loop the setpoint through the diluent, otherwise every gas
/// as open circuit (spec §10.13).
void _addCeilings(List<Waypoint> waypoints, Iterable<_Gas> gasList) {
  final gases = [
    for (final g in gasList)
      if (g.enabled && g.o2 != 0)
        GasDefinition(
          '${pyFormatG(g.o2)}/${pyFormatG(g.he)}',
          g.o2 / 100.0,
          g.he / 100.0,
          pyMax(0.0, (1.4 / (g.o2 / 100.0) - 1.0) * 10.0),
        ),
  ];
  final results = DiveDecompressor(simulationInterval: 10).processWaypoints([
    for (final wp in waypoints)
      DecoWaypoint(
        divetime: wp.timeSinceStart,
        // A record without a depth is at the surface here, as Python's 0.0.
        depth: wp.depth ?? 0.0,
        datetime: wp.timestamp,
        setpoint: wp.setpoint,
        diluentO2Percent: wp.diluentO2Percent,
        diluentHePercent: wp.diluentHePercent,
      ),
  ], gases.isEmpty ? const [GasDefinition('AIR', 0.21, 0.0, 56.0)] : gases);
  for (final wp in waypoints) {
    final res = results[wp.timeSinceStart];
    if (res != null) {
      wp.ceiling = res.ceilingMeters;
      wp.gf ??= res.gfCurrent;
      wp.surfGf = res.surfGf;
    }
  }
}

/// The serial numbers of the tank sensors in a FIT file, in the order they
/// are first heard from.
List<String> uniqueTankSerials(FitMessages messages) {
  final serials = <String>{};
  for (final update in messages['tank_update_mesgs'] ?? const <FitMesg>[]) {
    final sensor = update['sensor'];
    if (sensor != null) {
      serials.add('$sensor');
    }
  }
  return serials.toList();
}

/// The dive of a decoded FIT file; none when it has no timing messages or
/// no records. [tanks] names the tank sensors and gives their order.
///
/// Throws a [FormatException] for a message the Python parser fails on: a
/// tank update or a session start without a timestamp.
List<Dive> parseGarminMessages(
  FitMessages messages,
  String path, {
  TankConfig? tanks,
}) {
  final tankConfig = tanks ?? TankConfig();
  List<FitMesg> list(String name) => messages[name] ?? const <FitMesg>[];

  String? device;
  String? manufacturer;
  final ids = list('file_id_mesgs');
  if (ids.isNotEmpty) {
    Object? product = ids.first['garmin_product'];
    if (product is int && _unmappedGarminProducts.containsKey(product)) {
      product = _unmappedGarminProducts[product];
    }
    device = product?.toString();
    manufacturer = ids.first['manufacturer']?.toString();
  }

  // The time of the dive: start and end as UTC instants, and the zone.
  final sessions = list('session_mesgs');
  final activities = list('activity_mesgs');
  DateTime startUtc;
  double duration;
  int offsetMinutes;

  int zoneOf(FitMesg mesg, DateTime start) {
    final localEpoch = mesg['local_timestamp'];
    if (!_truthy(localEpoch)) {
      return 0;
    }
    return timezoneOffsetMinutes(_instant(_int(localEpoch))!, start);
  }

  if (activities.isEmpty) {
    // The session, when there is no activity.
    if (sessions.isEmpty) {
      return [];
    }
    final start = _instant(sessions.first['start_time']);
    if (start == null) {
      throw FormatException('FIT session without a start time', path);
    }
    startUtc = start;
    offsetMinutes = zoneOf(sessions.first, start);
    duration = _double(sessions.first['total_elapsed_time']) ?? 0;
  } else {
    final activity = activities.first;
    final stamped = _instant(activity['timestamp']);
    final sessionStart = sessions.isEmpty
        ? null
        : _instant(sessions.first['start_time']);
    // An activity without a timestamp is still a dive when it gives no
    // local time either (the zone is then UTC) and the session says when
    // the dive started.
    if (stamped == null &&
        (_truthy(activity['local_timestamp']) || sessionStart == null)) {
      throw FormatException('FIT activity without a timestamp', path);
    }
    offsetMinutes = stamped == null ? 0 : zoneOf(activity, stamped);
    // The activity's local/UTC pair gives the zone; the dive starts at the
    // session's start_time where there is one, since some files stamp the
    // activity at the dive's end.
    startUtc = sessionStart ?? stamped!;
    duration = _double(activity['total_timer_time']) ?? 0;
  }
  final endUtc = startUtc.add(Duration(microseconds: pyRound(duration * 1e6)));

  // Naive local times for the model.
  final offset = Duration(minutes: offsetMinutes);
  DateTime local(DateTime utc) => utc.add(offset);
  final startLocal = local(startUtc);
  final endLocal = local(endUtc);

  double? degrees(Object? semicircles) {
    final value = _double(semicircles);
    return value == null ? null : value * _degreesPerSemicircle;
  }

  final session = sessions.isEmpty ? const <String, Object?>{} : sessions.first;

  // Tank transmitters: the name the diver gave each.
  final sensorNames = <Object, String?>{};
  for (final info in list('device_info_mesgs')) {
    final serial = info['serial_number'];
    if (serial != null && _truthy(serial)) {
      String? name;
      for (final key in ['descriptor', 'nickname', 'product_name']) {
        if (_truthy(info[key])) {
          name = info[key]!.toString();
          break;
        }
      }
      sensorNames[serial] = name;
    }
  }

  // Gas mixes by index.
  final gasByIndex = <Object, _Gas>{};
  for (final gas in list('dive_gas_mesgs')) {
    final index = gas['message_index'];
    if (index != null) {
      gasByIndex[index] = _Gas(
        he: _double(gas['helium_content']) ?? 0,
        o2: gas.containsKey('oxygen_content')
            ? (_double(gas['oxygen_content']) ?? 0)
            : 21,
        mode: (gas['mode'] ?? 'open_circuit').toString(),
        enabled: gas['status'] == 'enabled',
      );
    }
  }
  _Gas? gasAt(Object? index) => index == null ? null : gasByIndex[index];

  // Which gas is breathed when: the computer logs a dive_gas_switched event
  // with the index of the gas in use, at the start of the dive and at every
  // switch. Tank readings take the gas active at their time.
  final gasSwitches = <(DateTime, Object)>[];
  for (final event in list('event_mesgs')) {
    final data = event['data'];
    if (event['event'] != 'dive_gas_switched' ||
        data == null ||
        !gasByIndex.containsKey(data)) {
      continue;
    }
    final time = _instant(event['timestamp']);
    if (time == null) {
      continue;
    }
    gasSwitches.add((local(time), data));
  }
  _sortByTime(gasSwitches, (pair) => pair.$1);
  Object? defaultGas;
  if (gasByIndex.containsKey(0)) {
    defaultGas = 0;
  } else if (gasByIndex.isNotEmpty) {
    defaultGas = gasByIndex.keys.reduce(
      (a, b) => (b as num) < (a as num) ? b : a,
    );
  }
  // The start-of-dive switch names the first gas; a dive that logs none
  // breathes the first listed gas until its first switch.
  final startsWithSwitch =
      gasSwitches.isNotEmpty &&
      !gasSwitches.first.$1.isAfter(
        startLocal.add(const Duration(seconds: 60)),
      );
  var activeGas = startsWithSwitch ? gasSwitches.first.$2 : defaultGas;

  // Tank updates by time, each time's readings by tank key.
  final tankUpdates = <DateTime, Map<String, TankData>>{};
  // Tank keys whose readings do not name a gas of their own.
  final tanksFollowingGas = <String>{};
  for (final update in list('tank_update_mesgs')) {
    final time = _instant(update['timestamp']);
    if (time == null) {
      throw FormatException('FIT tank update without a timestamp', path);
    }
    final sensor = update['sensor'];
    final serial = sensor != null
        ? '$sensor'
        : '${update['gas_type_index'] ?? 'default'}';
    final key = tankConfig.mapTankName(serial);
    final name = sensor != null && _truthy(sensor) ? sensorNames[sensor] : null;

    // Not in Garmin's profile; honoured when a file has it.
    final gasIndex = update['gas_type_index'];
    if (gasIndex == null) {
      tanksFollowingGas.add(key);
    }
    final gas = gasAt(gasIndex);
    tankUpdates.putIfAbsent(local(time), () => {})[key] = TankData(
      // No pressure in the message is no reading; Python has 0.0.
      pressureBar: _double(update['pressure']),
      o2Percent: gas?.o2 ?? 21,
      hePercent: gas?.he ?? 0,
      name: name,
      mode: gas?.mode ?? 'open_circuit',
      enabled: gas?.enabled ?? true,
    );
  }

  // Dive-alert events: a more direct state signal than depth bands. A
  // value the profile does not name stays a number, as text.
  final alertEvents = <(DateTime, String)>[];
  for (final event in list('event_mesgs')) {
    if (event['event'] != 'dive_alert') {
      continue;
    }
    final alert = event['dive_alert'];
    final time = _instant(event['timestamp']);
    if (alert == null || time == null) {
      continue;
    }
    alertEvents.add((local(time), '$alert'));
  }
  _sortByTime(alertEvents, (pair) => pair.$1);

  // A rebreather dive: the setpoint in force from the switch alerts.
  final settingsList = list('dive_settings_mesgs');
  final settings = settingsList.isEmpty
      ? const <String, Object?>{}
      : settingsList.first;
  final setpointsInForce = setpointTimeline(
    [
      for (final (time, name) in alertEvents)
        if (setpointAlerts.containsKey(name)) (time, setpointAlerts[name]!),
    ],
    {
      'low': _double(settings['ccr_low_setpoint']),
      'high': _double(settings['ccr_high_setpoint']),
    },
  );
  var setpointPtr = 0;
  double? setpoint =
      setpointsInForce.isNotEmpty && setpointsInForce.first.$1 == null
      ? setpointsInForce.first.$2
      : null;
  final rebreather = gasByIndex.values.any((g) => g.mode == _diluentMode);
  // The diluent DilPO2 shows, also after a bailout: the one last breathed
  // on the loop, before that the first listed.
  _Gas? diluent;
  final sortedIndexes = gasByIndex.keys.toList()
    ..sort((a, b) => (a as num).compareTo(b as num));
  for (final index in sortedIndexes) {
    if (gasByIndex[index]!.mode == _diluentMode) {
      diluent = gasByIndex[index];
      break;
    }
  }

  // If the first record is before the first tank update, every tank shows
  // its first reading from the start.
  final sortedTankTimes = tankUpdates.keys.toList()..sort();
  var initialTanks = <String, TankData>{};
  for (final time in sortedTankTimes) {
    for (final entry in tankUpdates[time]!.entries) {
      initialTanks.putIfAbsent(entry.key, () => entry.value);
    }
  }
  // Primary, secondary, ...: the order of the tank configuration, not which
  // pod happened to be heard from first on this dive.
  initialTanks = {
    for (final key in tankConfig.orderTanks(initialTanks.keys))
      key: initialTanks[key]!,
  };

  final currentTanks = Map<String, TankData>.of(initialTanks);
  var tankPtr = 0;
  var alertPtr = 0;
  var switchPtr = 0;
  var currentMaxDepth = 0.0;

  Map<String, TankData> withActiveGas(Map<String, TankData> readings) {
    final gas = gasAt(activeGas);
    if (gas == null) {
      return readings;
    }
    return {
      for (final entry in readings.entries)
        entry.key: tanksFollowingGas.contains(entry.key)
            ? TankData(
                pressureBar: entry.value.pressureBar,
                o2Percent: gas.o2,
                hePercent: gas.he,
                name: entry.value.name,
                mode: gas.mode,
                enabled: gas.enabled,
              )
            : entry.value,
    };
  }

  var wpTanks = withActiveGas(currentTanks);
  final waypoints = <Waypoint>[];

  for (final record in list('record_mesgs')) {
    final time = _instant(record['timestamp']);
    if (time == null) {
      continue;
    }
    final tsLocal = local(time);

    // Catch the tanks and the breathed gas up to this record.
    var tanksChanged = false;
    while (tankPtr < sortedTankTimes.length &&
        !sortedTankTimes[tankPtr].isAfter(tsLocal)) {
      currentTanks.addAll(tankUpdates[sortedTankTimes[tankPtr]]!);
      tankPtr += 1;
      tanksChanged = true;
    }
    while (switchPtr < gasSwitches.length &&
        !gasSwitches[switchPtr].$1.isAfter(tsLocal)) {
      if (gasSwitches[switchPtr].$2 != activeGas) {
        activeGas = gasSwitches[switchPtr].$2;
        tanksChanged = true;
      }
      switchPtr += 1;
    }
    if (tanksChanged) {
      wpTanks = withActiveGas(currentTanks);
    }

    final depth = _double(record['depth']);
    if (depth != null && depth > currentMaxDepth) {
      currentMaxDepth = depth;
    }

    // The alerts since the previous record.
    final wpAlerts = <String>[];
    while (alertPtr < alertEvents.length &&
        !alertEvents[alertPtr].$1.isAfter(tsLocal)) {
      wpAlerts.add(alertEvents[alertPtr].$2);
      alertPtr += 1;
    }
    while (setpointPtr < setpointsInForce.length &&
        (setpointsInForce[setpointPtr].$1 == null ||
            !setpointsInForce[setpointPtr].$1!.isAfter(tsLocal))) {
      setpoint = setpointsInForce[setpointPtr].$2;
      setpointPtr += 1;
    }

    // The breathed gas says the circuit: a diluent is on the loop, any
    // other gas of a rebreather dive is bailout (open circuit).
    final gas = gasAt(activeGas);
    final onLoop = rebreather && gas != null && gas.mode == _diluentMode;
    final divemode = rebreather
        ? (onLoop ? 'closedcircuit' : 'opencircuit')
        : null;
    if (onLoop) {
      diluent = gas;
    }
    // PO2: the record's own, else the setpoint in force on the loop, else
    // the breathed gas at this depth.
    var po2 = _double(record['po2']);
    if (po2 == null) {
      if (onLoop && setpoint != null) {
        po2 = setpoint;
      } else {
        final fO2 = (gas != null && gas.o2 != 0 ? gas.o2 : 21) / 100.0;
        po2 = pyRoundTo((1.0 + (depth ?? 0.0) / 10.0) * fO2, 2);
      }
    }

    final sinceStart = tsLocal.difference(startLocal).inMicroseconds ~/ 1000000;
    final stopDepth = _double(record['next_stop_depth']);
    // FIT logs the ascent rate in m/s (positive = getting shallower); the
    // overlays work in m/min.
    final ascentRate = _double(record['ascent_rate']);
    waypoints.add(
      Waypoint(
        timestamp: tsLocal,
        depth: depth,
        maxDepth: currentMaxDepth,
        temp: _double(record['temperature']),
        timeSinceStart: sinceStart,
        diveTime: sinceStart,
        decoStopDepth: stopDepth,
        nextStopDepth: stopDepth,
        nextStopTime: _int(record['next_stop_time']),
        tts: _int(record['time_to_surface']),
        // A Descent leaves ndl_time out where it computes no NDL (shallower
        // than about 7.5 m: unbounded) and logs 0 in deco.
        ndl: _int(record['ndl_time']),
        airRemaining: _int(record['air_time_remaining']),
        ascentRate: ascentRate == null ? null : ascentRate * 60.0,
        n2TissueLoad: _double(record['n2_load']),
        pressureSac: _double(record['pressure_sac']),
        volumeSac: _double(record['volume_sac']),
        rmv: _double(record['rmv']),
        heartRate: _int(record['heart_rate']),
        cns: _int(record['cns_load']),
        po2: po2,
        divemode: divemode,
        setpoint: onLoop ? setpoint : null,
        gasO2Percent: rebreather ? gas?.o2 : null,
        gasHePercent: rebreather ? gas?.he : null,
        diluentO2Percent: rebreather ? diluent?.o2 : null,
        diluentHePercent: rebreather ? diluent?.he : null,
        tanks: wpTanks,
        diveAlerts: wpAlerts,
      ),
    );
  }

  if (waypoints.isEmpty) {
    return [];
  }
  _addCeilings(waypoints, gasByIndex.values);

  return [
    Dive(
      startTime: startLocal,
      endTime: endLocal,
      waypoints: waypoints,
      logFilename: pyFileName(path),
      logPath: path,
      device: device,
      manufactor: manufacturer,
      startLatitude: degrees(session['start_position_lat']),
      startLongitude: degrees(session['start_position_long']),
      endLatitude: degrees(session['end_position_lat']),
      endLongitude: degrees(session['end_position_long']),
      timezone: timezoneName(offsetMinutes),
    ),
  ];
}

/// Sorts by time, keeping the file's order for equal times (Python's
/// `sort` is stable; `List.sort` is not promised to be).
void _sortByTime<T>(List<T> items, DateTime Function(T) timeOf) {
  final indexed = items.indexed.toList()
    ..sort((a, b) {
      final byTime = timeOf(a.$2).compareTo(timeOf(b.$2));
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
  items
    ..clear()
    ..addAll([for (final (_, item) in indexed) item]);
}
