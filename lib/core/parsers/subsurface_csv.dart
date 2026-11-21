/// Subsurface's "Export > CSV dive profile" file, ported from
/// `parsers/subsurface_csv.py` of the Python app (spec §4.1): one row per
/// sample, every dive of the export in the same table, keyed by dive
/// number, date and time. Units are in the column names. Temperature and
/// pressure are only filled in on the samples where they changed, so the
/// last value carries forward. There is no gas or cylinder information: the
/// gas is taken as air in one tank, and TTS and ceiling come from the deco
/// recompute.
library;

import 'package:uwmedia_app/core/deco/deco_pass.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/parsers/subsurface_text.dart';
import 'package:uwmedia_app/core/util/py_csv.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';

const double psiToBar = 0.0689476;
const double ftToM = 0.3048;

/// The column starting with [prefix] and the unit in its brackets.
(String? name, String unit) _column(List<String> columns, String prefix) {
  for (final name in columns) {
    if (name.toLowerCase().startsWith(prefix)) {
      if (!name.contains('(')) {
        return (name, '');
      }
      // Python: name[name.find("(") + 1:name.find(")")], where a missing
      // ")" is index -1, the last character.
      final open = name.indexOf('(') + 1;
      final close = name.contains(')') ? name.indexOf(')') : name.length - 1;
      final unit = close > open ? name.substring(open, close) : '';
      return (name, unit.pyStrip().toLowerCase());
    }
  }
  return (null, '');
}

/// Whether [firstLine] is the header of a Subsurface dive-profile CSV.
bool isSubsurfaceProfileHeader(String firstLine) {
  final line = firstLine.toLowerCase();
  return line.contains('sample time') && line.contains('sample depth');
}

/// The dives of a Subsurface dive-profile CSV. [text] is the file's content
/// (UTF-8, a byte order mark already removed) and [path] where it came
/// from. A table without a time or a depth column has no dives.
List<Dive> parseSubsurfaceCsv(String text, String path) {
  final PyDictReader reader;
  try {
    reader = PyDictReader(text);
  } on FormatException {
    // Python's reader refuses the file; the parser then has no dives.
    return [];
  }
  final columns = reader.fieldnames;

  final (timeCol, _) = _column(columns, 'sample time');
  final (depthCol, depthUnit) = _column(columns, 'sample depth');
  final (tempCol, tempUnit) = _column(columns, 'sample temperature');
  final (pressureCol, pressureUnit) = _column(columns, 'sample pressure');
  final (hrCol, _) = _column(columns, 'sample heartrate');
  if (_isEmpty(timeCol) || _isEmpty(depthCol)) {
    return [];
  }

  // Samples by dive, in the file's dive order.
  final groups = <(String?, String?, String?), List<Map<String, String?>>>{};
  for (final row in reader.rows) {
    final key = (
      _cell(row, 'dive number'),
      _cell(row, 'date'),
      _cell(row, 'time'),
    );
    groups.putIfAbsent(key, () => []).add(row);
  }

  final dives = <Dive>[];
  for (final MapEntry(key: (_, dateStr, timeStr), value: samples)
      in groups.entries) {
    // A row too short for a column has None there, which is no date.
    final startTime = pyStrptime(
      '${dateStr ?? 'None'} ${timeStr ?? 'None'}',
      '%Y-%m-%d %H:%M:%S',
    );
    if (startTime == null) {
      continue;
    }

    final waypoints = <Waypoint>[];
    var currentMaxDepth = 0.0;
    double? currentTemp;
    double? currentPressure;
    var lastSeconds = -1;
    for (final row in samples) {
      final timeText = row[timeCol];
      if (_isEmpty(timeText)) {
        continue;
      }
      final seconds = parseTimeStr(timeText!);
      if (seconds <= lastSeconds) {
        continue;
      }
      lastSeconds = seconds;

      // No depth, or one that is not a number, is null (spec §10.8); Python
      // stores 0.0. A negative depth reads as the surface.
      final depthValue = pyFloat(row[depthCol]);
      double? depth;
      if (depthValue != null) {
        depth = pyMax(0.0, depthValue);
        if (depthUnit == 'ft') {
          depth *= ftToM;
        }
        currentMaxDepth = pyMax(currentMaxDepth, depth);
      }

      final temp = tempCol == null ? null : pyFloat(row[tempCol]);
      if (temp != null) {
        currentTemp = tempUnit == 'f' ? (temp - 32.0) * 5.0 / 9.0 : temp;
      }
      final pressure = pressureCol == null ? null : pyFloat(row[pressureCol]);
      if (pressure != null && pressure > 0) {
        currentPressure = pressureUnit == 'psi'
            ? pressure * psiToBar
            : pressure;
      }
      final heartRate = hrCol == null ? null : pyFloat(row[hrCol]);

      waypoints.add(
        Waypoint(
          timestamp: startTime.add(Duration(seconds: seconds)),
          depth: depth,
          maxDepth: currentMaxDepth,
          temp: currentTemp,
          heartRate: heartRate?.toInt(),
          timeSinceStart: seconds,
          diveTime: seconds,
          tanks: currentPressure == null
              ? null
              : {'1': TankData(pressureBar: currentPressure)},
        ),
      );
    }

    if (waypoints.isEmpty) {
      continue;
    }
    applyDecoAndGas(waypoints, [decoGas('AIR', 21.0, 0.0)]);
    final endTime = waypoints.last.timestamp;
    dives.add(
      Dive(
        startTime: startTime,
        endTime: endTime,
        waypoints: waypoints,
        durationSeconds: endTime.difference(startTime).inSeconds,
        logFilename: pyFileName(path),
        logPath: path,
      ),
    );
  }
  return dives;
}

bool _isEmpty(String? text) => text == null || text.isEmpty;

// Python: `row.get(name, "")`: the empty text without such a column, None
// (null) for a column the row is too short for.
String? _cell(Map<String, String?> row, String name) =>
    row.containsKey(name) ? row[name] : '';
