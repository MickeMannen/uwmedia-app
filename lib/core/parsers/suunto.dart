/// The Suunto app's per-dive JSON export (EON Steel / EON Steel Black / EON
/// Core, Nautic, D5, Ocean), ported from `parsers/suunto.py` of the Python
/// app (0.8.0, spec §4.1): one dive per file.
///
///     {"DeviceLog": {"Header": {...}, "Samples": [{...}, ...]}}
///
/// The tree is the device's own log, in SI units: Header (DateTime in
/// ISO 8601 with the time zone, ActivityType 51 for scuba, Device.Name,
/// DiveTime in s, Diving.Gases[] with Oxygen / Helium fractions, TankSize
/// m3 and Start/EndPressure Pa, Diving.Algorithm) and sparse Samples (Depth
/// m, Temperature K, NoDecTime and TimeToSurface s, Ceiling m, GasTime s,
/// Ventilation m3/s, Cylinders[] with GasNumber, Pressure, Pressure2, and
/// events). A value carries forward to the next record that has the key.
///
/// Quirks handled as in Python: gas numbers are 1-based list positions on
/// the EON / D5 and an explicit 0-based GasNumber on the Ocean / Nautic;
/// records are sorted by time and the first of a second is kept; records
/// after DiveTime are surface readings (dropped); NoDecTime -1 and
/// TimeToSurface 0 mean "no value"; Ceiling 0 means no ceiling; the
/// Nautic's Device.Name is its internal name "Vaasa". The logged ceiling is
/// also the stop (`next_stop_depth`).
///
/// No stop time is logged: the stop time and the GF99 come from the shared
/// deco pass (spec §10.16). Python's `parsers/deco_pass.py` also fills SAC
/// and gas time on samples that lack one; the port's pass fills them only
/// when no sample has a SAC, which for this format (never a logged SAC)
/// is the same thing.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:uwmedia_app/core/deco/deco_pass.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/parsers/garmin.dart' show timezoneName;
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

const int scubaActivity = 51;
const double _paPerBar = 100000.0;
const double _kelvin = 273.15;
const int _ndlAbsent = -1;
const List<String> _eventKinds = ['Notify', 'Warning', 'Alarm', 'State'];

/// Device.Name as the app writes it, lower-cased, to the model name the
/// templates use (`parsers/suunto.py` INTERNAL_NAMES).
const Map<String, String> internalNames = {
  'vaasa': 'Nautic',
  'porvoo': 'Ocean',
};

/// Gradient factors in force when the log names none (Python
/// DEFAULT_GF: Nautic medium 40/85, manual p.42; EON Bühlmann 16 GF 30/70,
/// EON Core p.18). A Fused RGBM 2 dive gets the deco engine's own default.
const Map<String, (double, double)> _defaultGf = {'nautic': (0.40, 0.85)};
const (double, double) _buhlmannDefaultGf = (0.30, 0.70);

/// Suunto event types to the dive_alerts names the HUD rules know
/// (`hud_rules.json` "alert"), keyed by the type with only letters and
/// digits, lower-cased.
const Map<String, String> _alerts = {
  'ceilingbroken': 'deco_ceiling_broken',
  'po2high': 'po2_crit_high',
  'po2low': 'po2_crit_low',
  'ascentspeed': 'ascent_critical',
  'safetystopbroken': 'safety_stop_broken',
  'cns80': 'cns_warning',
  'cns100': 'cns_critical',
  'otu250': 'otu_warning',
  'otu300': 'otu_critical',
};

/// Whether the start of a `.json` file is a Suunto app dive export.
bool isSuuntoJson(String head) => head.contains('"DeviceLog"');

final _alnum = RegExp(r'[\p{L}\p{N}]', unicode: true);

// Python: "".join(c for c in str(text or "").lower() if c.isalnum()).
String _key(Object? text) {
  final shown = text == null || text == '' ? '' : '$text';
  return _alnum.allMatches(shown.toLowerCase()).map((m) => m.group(0)!).join();
}

// Python `_num`: a number or a numeric text as a float, else null (a bool
// is not a number here).
double? _num(Object? value) => switch (value) {
  final num n => n.toDouble(),
  final String s => pyFloat(s),
  _ => null,
};

// Python `int(x)` of a float: truncation. (Python's `int("1.9")` on a text
// gas number raises; here the text is read as a float first. Unlisted
// leniency for a file no Suunto app writes.)
int _int(double x) => x.truncate();

Map<String, dynamic> _map(Object? value) =>
    value is Map<String, dynamic> ? value : const {};

// Python `x or {}` then use as a mapping.
Map<String, dynamic> _mapOr(Object? a, [Object? b]) =>
    _map(a).isNotEmpty ? _map(a) : _map(b);

/// A parsed ISO 8601 time: the wall clock as written (a naive timestamp)
/// and its UTC offset in seconds, `null` when the text names no zone.
typedef SuuntoTime = ({DateTime wall, int? offsetSeconds});

final _offsetTail = RegExp(r'(?:[Zz]|([+-])(\d\d)(?::?(\d\d)(?::?(\d\d))?)?)$');
final _dateHead = RegExp(r'^\d{4}-\d\d-\d\d');

/// Python `parse_time`: `datetime.fromisoformat`, or `null`. Reads what
/// `pyFromIsoformatNaive` reads, plus the offset.
SuuntoTime? parseSuuntoTime(Object? text) {
  if (text is! String) {
    return null;
  }
  final wall = pyFromIsoformatNaive(text);
  if (wall == null) {
    return null;
  }
  final dateEnd = _dateHead.hasMatch(text) ? 10 : 8;
  int? offset;
  if (text.length > dateEnd + 1) {
    final tail = _offsetTail.firstMatch(text.substring(dateEnd + 1));
    if (tail != null) {
      final sign = tail.group(1);
      if (sign == null) {
        offset = 0;
      } else {
        final seconds =
            int.parse(tail.group(2)!) * 3600 +
            int.parse(tail.group(3) ?? '0') * 60 +
            int.parse(tail.group(4) ?? '0');
        offset = sign == '-' ? -seconds : seconds;
      }
    }
  }
  return (wall: wall, offsetSeconds: offset);
}

// Seconds from [from] to [to]; Python refuses to subtract a time with a
// zone from one without.
double _secondsBetween(SuuntoTime from, SuuntoTime to) {
  if ((from.offsetSeconds == null) != (to.offsetSeconds == null)) {
    throw const FormatException(
      "can't subtract offset-naive and offset-aware datetimes",
    );
  }
  final micros =
      to.wall.difference(from.wall).inMicroseconds -
      ((to.offsetSeconds ?? 0) - (from.offsetSeconds ?? 0)) * 1000000;
  return micros / 1e6;
}

/// The `DeviceLog` object of an export's JSON [bytes] (utf-8 with an
/// optional byte order mark); an empty map for what is not one. Throws a
/// [FormatException] for text that is not JSON.
Map<String, dynamic> readDeviceLog(Uint8List bytes) {
  var text = utf8.decode(bytes);
  if (text.startsWith('\u{FEFF}')) {
    text = text.substring(1);
  }
  final data = jsonDecode(text);
  final Object? log = data is Map<String, dynamic>
      ? (data.containsKey('DeviceLog') ? data['DeviceLog'] : data)
      : null;
  return log is Map<String, dynamic> ? log : const {};
}

/// The model name of the log's device ("Nautic" for the internal "Vaasa"),
/// or `null`.
String? deviceName(Map<String, dynamic> log) {
  final header = _map(log['Header']);
  final device = _mapOr(header['Device'], log['Device']);
  final name = _text(device['Name']).pyStrip();
  final shown = internalNames[name.toLowerCase()] ?? name;
  return shown.isEmpty ? null : shown;
}

// Python truthiness of a JSON value.
bool _truthy(Object? v) => switch (v) {
  null => false,
  final bool b => b,
  final num n => n != 0,
  final String s => s.isNotEmpty,
  final List<dynamic> l => l.isNotEmpty,
  final Map<dynamic, dynamic> m => m.isNotEmpty,
  _ => true,
};

// Python `str(x or "")`.
String _text(Object? value) {
  if (value == null || value == false || value == 0 || value == '') {
    return '';
  }
  return value is double ? pyFloatRepr(value) : '$value';
}

/// A gas of the header's list.
class SuuntoGas {
  SuuntoGas({
    required this.number,
    required this.o2Percent,
    required this.hePercent,
    this.tankSizeL,
    this.startPressureBar,
  });

  final int number;
  final double o2Percent;
  final double hePercent;
  final double? tankSizeL;
  final double? startPressureBar;
}

/// The header's gases by the number the samples use for them.
Map<int, SuuntoGas> readGases(Map<String, dynamic> log) {
  final gases = <int, SuuntoGas>{};
  final listed = _map(_map(log['Header'])['Diving'])['Gases'];
  if (listed is! List) {
    return gases;
  }
  for (final (index, gas) in listed.indexed) {
    if (gas is! Map<String, dynamic>) {
      continue;
    }
    final raw = _num(gas['GasNumber']);
    final number = raw != null ? _int(raw) : index + 1;
    final o2 = _num(gas['Oxygen']);
    final size = _num(gas['TankSize']);
    var start = _num(gas['StartPressure']);
    if (start == null || start == 0) {
      start = _num(gas['TankFillPressure']);
    }
    final hasStart = start != null && start != 0;
    gases[number] = SuuntoGas(
      number: number,
      o2Percent: o2 != null ? pyRoundTo(o2 * 100.0, 1) : 21.0,
      hePercent: pyRoundTo((_num(gas['Helium']) ?? 0.0) * 100.0, 1),
      tankSizeL: size != null && size != 0 ? pyRoundTo(size * 1000.0, 1) : null,
      startPressureBar: hasStart ? pyRoundTo(start / _paPerBar, 1) : null,
    );
  }
  return gases;
}

/// One sample record: its second from the header's start, its values, the
/// events on it and the gas switch it names.
class SuuntoRecord {
  SuuntoRecord(this.seconds, this.values);

  final double seconds;
  final Map<String, dynamic> values;

  /// (kind, type, active) of the Notify / Warning / Alarm / State events.
  final List<(String, String, bool)> events = [];
  int? gasSwitch;
}

Iterable<Map<String, dynamic>> _eventItems(Object? raw) => switch (raw) {
  final Map<String, dynamic> map => [map],
  final List<dynamic> list => list.whereType<Map<String, dynamic>>(),
  _ => const [],
};

/// The samples as records in time order, seconds from [start]; records
/// after the header's DiveTime (surface readings) are left out.
List<SuuntoRecord> sampleRecords(Map<String, dynamic> log, SuuntoTime start) {
  final header = _map(log['Header']);
  final limit = _num(header['DiveTime']);
  final records = <SuuntoRecord>[];
  final samples = log['Samples'];
  for (final sample in samples is List ? samples : const []) {
    if (sample is! Map<String, dynamic>) {
      continue;
    }
    final when = parseSuuntoTime(sample['TimeISO8601']);
    if (when == null) {
      continue;
    }
    final seconds = _secondsBetween(start, when);
    if (seconds < 0 || (limit != null && seconds > limit)) {
      continue;
    }
    final record = SuuntoRecord(seconds, sample);
    for (final item in [
      ..._eventItems(sample['Events']),
      ..._eventItems(sample['DiveEvents']),
    ]) {
      for (final MapEntry(key: kind, value: body) in item.entries) {
        if (kind == 'GasSwitch' &&
            body is Map<String, dynamic> &&
            _num(body['GasNumber']) != null) {
          record.gasSwitch = _int(_num(body['GasNumber'])!);
        } else if (_eventKinds.contains(kind) && body is Map<String, dynamic>) {
          record.events.add((
            kind,
            _text(body['Type']),
            body['Active'] != false,
          ));
        }
      }
    }
    records.add(record);
  }
  // Stable: same-time records keep their file order (List.sort is not).
  final order = {for (final (i, r) in records.indexed) r: i};
  records.sort((a, b) {
    final byTime = a.seconds.compareTo(b.seconds);
    return byTime != 0 ? byTime : order[a]!.compareTo(order[b]!);
  });
  return records;
}

// dive_alerts for the events that switched on: the shared alert name where
// one means the same, and "suunto:<Type>" for every one.
List<String> _alertsOf(List<(String, String, bool)> events) {
  final alerts = <String>[];
  for (final (kind, type, active) in events) {
    if (!active || kind == 'State' || type.isEmpty) {
      continue;
    }
    final shared = _alerts[_key(type)];
    if (shared != null && !alerts.contains(shared)) {
      alerts.add(shared);
    }
    alerts.add('suunto:$type');
  }
  return alerts;
}

(double, double)? _fileGf(Map<String, dynamic> log, String? device) {
  final algorithm = _key(_map(_map(log['Header'])['Diving'])['Algorithm']);
  for (final MapEntry(key: model, value: gf) in _defaultGf.entries) {
    if (_key(device).contains(model)) {
      return gf;
    }
  }
  if (algorithm.contains('buhlmann') || algorithm.contains('bhlmann')) {
    return _buhlmannDefaultGf;
  }
  return null;
}

/// The dives of a Suunto app export (always one, or none for a log that is
/// not a scuba dive, has no start or no depth sample). [bytes] is the
/// file's content and [path] where it came from.
List<Dive> parseSuunto(Uint8List bytes, String path) {
  final Map<String, dynamic> log;
  try {
    log = readDeviceLog(bytes);
  } on FormatException {
    return [];
  }
  final header = _map(log['Header']);
  final activity = header['ActivityType'];
  if (activity is! num || activity != scubaActivity) {
    return [];
  }
  final start = parseSuuntoTime(header['DateTime']);
  if (start == null) {
    return [];
  }

  final gases = readGases(log);
  final device = deviceName(log);
  final startLocal = start.wall;
  final (waypoints, loggedCeilings, tankVolumes) = _waypoints(
    sampleRecords(log, start),
    gases,
    startLocal,
  );
  if (waypoints.isEmpty) {
    return [];
  }

  final mixes =
      {for (final g in gases.values) (g.o2Percent, g.hePercent)}.toList()..sort(
        (a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2),
      );
  if (mixes.isEmpty) {
    mixes.add((21.0, 0.0));
  }
  applyDecoAndGas(waypoints, [
    for (final (o2, he) in mixes)
      decoGas('${pyFormatG(o2)}/${pyFormatG(he)}', o2, he),
  ], fileGf: _fileGf(log, device));
  for (final (i, wp) in waypoints.indexed) {
    final ceiling = loggedCeilings[i];
    if (ceiling != null) {
      // The computer's own ceiling is also the stop it shows (EON Core
      // manual p.26), not the next 3 m step below it.
      wp.ceiling = ceiling;
      wp.nextStopDepth = ceiling;
    }
  }

  final endTime = waypoints.last.timestamp;
  final offset = start.offsetSeconds;
  return [
    Dive(
      startTime: startLocal,
      endTime: endTime,
      waypoints: waypoints,
      device: device,
      manufactor: 'Suunto',
      timezone: offset == null ? null : timezoneName(offset ~/ 60),
      durationSeconds: endTime.difference(startLocal).inSeconds,
      logFilename: pyFileName(path),
      logPath: path,
      tankVolumesL: tankVolumes,
    ),
  ];
}

// One waypoint per record with a depth, each value carried forward from the
// last record that had it; events between two waypoints go on the later
// one. Also the ceiling each waypoint's log gave (null where none yet), and
// each tank's size where its gas gives one.
(List<Waypoint>, List<double?>, Map<String, double>) _waypoints(
  List<SuuntoRecord> records,
  Map<int, SuuntoGas> gases,
  DateTime start,
) {
  final waypoints = <Waypoint>[];
  final loggedCeilings = <double?>[];
  double? temp, ceiling, rmv;
  int? ndl, tts, airRemaining;
  final pressures = <(int, String), double>{};
  final tankNames = <(int, String), String>{};
  int? currentGas = gases.isEmpty ? null : gases.keys.reduce(_min);
  var pendingAlerts = <String>[];
  var maxDepth = 0.0;
  var lastSecond = -1;

  for (final record in records) {
    final values = record.values;
    if (record.gasSwitch != null) {
      currentGas = record.gasSwitch;
    }
    for (final alert in _alertsOf(record.events)) {
      if (!pendingAlerts.contains(alert)) {
        pendingAlerts.add(alert);
      }
    }

    final t = _num(values['Temperature']);
    if (t != null) {
      temp = t > 100 ? pyRoundTo(t - _kelvin, 2) : t;
    }
    final n = _num(values['NoDecTime']);
    if (n != null) {
      ndl = n <= _ndlAbsent ? null : _int(n);
    }
    final s = _num(values['TimeToSurface']);
    if (s != null) {
      tts = s > 0 ? _int(s) : null;
    }
    final c = _num(values['Ceiling']);
    if (c != null) {
      ceiling = pyMax(0.0, c);
    }
    Object? gasTime = values['GasTime'];
    Object? ventilation = values['Ventilation'];
    final cylinders = values['Cylinders'];
    // Python tests `values.get("Cylinders")` for truthiness.
    final hasCylinders = _truthy(cylinders);
    for (final cylinder in cylinders is List ? cylinders : const []) {
      if (cylinder is! Map<String, dynamic> ||
          _num(cylinder['GasNumber']) == null) {
        continue;
      }
      final number = _int(_num(cylinder['GasNumber'])!);
      for (final slot in const ['Pressure', 'Pressure2', 'Pressure3']) {
        final pa = _num(cylinder[slot]);
        if (pa != null && pa > 0) {
          pressures[(number, slot)] = pyRoundTo(pa / _paPerBar, 1);
          tankNames.putIfAbsent((
            number,
            slot,
          ), () => 'T${tankNames.length + 1}');
        }
      }
      if (number == currentGas) {
        if (cylinder.containsKey('GasTime')) {
          gasTime = cylinder['GasTime'];
        }
        if (cylinder.containsKey('Ventilation')) {
          ventilation = cylinder['Ventilation'];
        }
      }
    }
    if (values.containsKey('GasTime') || hasCylinders) {
      final left = _num(gasTime);
      airRemaining = left != null && left > 0 ? _int(left) : null;
    }
    if (values.containsKey('Ventilation') || hasCylinders) {
      final perSecond = _num(ventilation);
      rmv = perSecond != null && perSecond != 0
          ? pyRoundTo(perSecond * 60000.0, 1)
          : null;
    }

    final depth = _num(values['Depth']);
    final second = pyRound(record.seconds);
    if (depth == null || second <= lastSecond) {
      continue;
    }
    lastSecond = second;
    final shownDepth = pyMax(0.0, depth);
    if (shownDepth > maxDepth) {
      maxDepth = shownDepth;
    }

    final gas = currentGas == null ? null : gases[currentGas];
    final names = tankNames.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final tanks = <String, TankData>{};
    for (final MapEntry(key: key, value: name) in names) {
      final mix = gases[key.$1];
      tanks[name] = TankData(
        pressureBar: pressures[key],
        o2Percent: mix?.o2Percent ?? 21.0,
        hePercent: mix?.hePercent ?? 0.0,
      );
    }
    loggedCeilings.add(ceiling);
    waypoints.add(
      Waypoint(
        timestamp: start.add(Duration(seconds: second)),
        depth: shownDepth,
        maxDepth: maxDepth,
        temp: temp,
        ndl: ndl,
        tts: tts,
        decoStopDepth: ceiling,
        airRemaining: airRemaining,
        rmv: rmv,
        gasO2Percent: gas?.o2Percent,
        gasHePercent: gas?.hePercent,
        timeSinceStart: second,
        diveTime: second,
        tanks: tanks,
        diveAlerts: pendingAlerts,
      ),
    );
    pendingAlerts = [];
  }
  return (
    waypoints,
    loggedCeilings,
    {
      for (final MapEntry(key: (number, _), value: name) in tankNames.entries)
        name: ?gases[number]?.tankSizeL,
    },
  );
}

int _min(int a, int b) => a < b ? a : b;
