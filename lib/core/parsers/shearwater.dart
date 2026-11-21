/// Shearwater Cloud's own "Export as XML" and "Export as CSV" dive files
/// (Perdix, Petrel, Teric, ...), ported from `parsers/shearwater.py` of the
/// Python app (spec §4.1): one dive per file, a dive-level header and one
/// record per sample.
///
/// Both exports carry the same fields under different names, so each is
/// read into rows keyed by the CSV column name ([xmlTags] maps the XML's
/// tags onto those) and one builder turns rows into waypoints.
///
/// Units: tank pressure is always psi and SAC psi/min; depth and
/// temperature follow the header's "Imperial Units"; NDL, TTS and first
/// stop time are minutes.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:uwmedia_app/core/deco/deco_pass.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/parsers/xml_query.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_csv.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';
import 'package:xml/xml.dart';

const double _psiToBar = 0.0689476;
const double _ftToM = 0.3048;
const List<String> _tankColumns = [
  'Tank 1 pressure (PSI)',
  'Tank 2 pressure (PSI)',
  'Tank 3 pressure (PSI)',
  'Tank 4 pressure (PSI)',
];

/// A transmitter's status word (no reading, no signal) exported as a
/// pressure: 12 bits of 2 psi. From here up it is not a reading.
const int shearwaterStatusPsi = 0xFF0 * 2;

const String _timeColumn = 'Time (sec)';

/// XML tag to CSV column name, for the header and the sample records.
const Map<String, String> xmlTags = {
  // header
  'number': 'Dive Number',
  'gfMin': 'GF Minimum',
  'gfMax': 'GF Maximum',
  'imperialUnits': 'Imperial Units',
  'startDate': 'Start Date',
  'endDate': 'End Date',
  'computerSerial': 'Computer Serial Number',
  'maxDepth': 'Max Depth',
  // samples
  'currentDepth': 'Depth',
  'firstStopDepth': 'First Stop Depth',
  'ttsMins': 'Time To Surface (min)',
  'averagePPO2': 'Average PPO2',
  'fractionO2': 'Fraction O2',
  'fractionHe': 'Fraction He',
  'firstStopTime': 'First Stop Time',
  'currentNdl': 'Current NDL',
  'currentCircuitSetting': 'Current Circuit Mode',
  'waterTemp': 'Water Temp',
  'batteryVoltage': 'Battery Voltage',
  'tank0pressurePSI': 'Tank 1 pressure (PSI)',
  'tank1pressurePSI': 'Tank 2 pressure (PSI)',
  'tank2pressurePSI': 'Tank 3 pressure (PSI)',
  'tank3pressurePSI': 'Tank 4 pressure (PSI)',
  'gasTime': 'Gas Time Remaining',
  'sac': 'SAC Rate (2 minute avg)',
};

// "Start Date" is written in the exporting PC's locale.
const List<String> _dateFormats = [
  '%m/%d/%Y %I:%M:%S %p',
  '%d/%m/%Y %I:%M:%S %p',
  '%m/%d/%Y %H:%M:%S',
  '%d/%m/%Y %H:%M:%S',
  '%d.%m.%Y %H:%M:%S',
  '%Y-%m-%d %H:%M:%S',
  '%Y-%m-%dT%H:%M:%S',
];
final _filenameDate = RegExp(
  r'(\d{4})-(\d{1,2})-(\d{1,2}) (\d{1,2})-(\d{1,2})-(\d{1,2})',
);
final _filenameDevice = RegExp(r'^(.+?)\s*\[');
final _xmlDeclaration = RegExp(r'^\s*<\?xml[^>]*\?>');

/// One sample row: the file's text by column, and the time in seconds.
typedef ShearwaterRow = ({Map<String, String> fields, double? seconds});

/// The header and the sample rows of either export, keyed by CSV column
/// name. Everything is as in the file, so in its own units.
typedef ShearwaterTables = ({
  Map<String, String> header,
  List<ShearwaterRow> rows,
});

/// Reads [bytes] as the CSV export when [path] ends in `.csv`, else as the
/// XML export. Throws a [FormatException] for a file that is neither text
/// nor well-formed.
ShearwaterTables readShearwaterTables(Uint8List bytes, String path) =>
    pySuffix(path).toLowerCase() == '.csv'
    ? _csvTables(bytes)
    : _xmlTables(bytes);

ShearwaterTables _xmlTables(Uint8List bytes) {
  // The export says encoding="utf-16" but is plain UTF-8, which an XML
  // parser refuses, so the declaration is dropped before parsing. A file
  // that really is UTF-16 starts with its byte order mark.
  String text;
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
          (bytes[0] == 0xfe && bytes[1] == 0xff))) {
    if (bytes.length.isOdd) {
      throw const FormatException('Truncated UTF-16 text');
    }
    final littleEndian = bytes[0] == 0xff;
    text = String.fromCharCodes([
      for (var i = 2; i < bytes.length; i += 2)
        littleEndian
            ? bytes[i] | bytes[i + 1] << 8
            : bytes[i] << 8 | bytes[i + 1],
    ]);
  } else {
    text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('﻿')) {
      text = text.substring(1);
    }
  }
  text = text.replaceFirst(_xmlDeclaration, '');
  final root = XmlDocument.parse(text).rootElement;

  XmlElement? log;
  for (final child in root.childElements) {
    if (lxmlTag(child) == 'diveLog') {
      log = child;
      break;
    }
  }
  if (log == null) {
    return (header: {}, rows: []);
  }
  final header = <String, String>{
    for (final child in log.childElements)
      if (lxmlTag(child) != 'diveLogRecords')
        xmlTags[lxmlTag(child)] ?? lxmlTag(child): leadingText(child),
  };
  final rows = <ShearwaterRow>[];
  for (final record in log.descendantElements) {
    if (lxmlTag(record) != 'diveLogRecord') {
      continue;
    }
    final fields = <String, String>{
      for (final child in record.childElements)
        xmlTags[lxmlTag(child)] ?? lxmlTag(child): leadingText(child),
    };
    // <currentTime> is milliseconds.
    final ms = pyFloat(fields['currentTime']);
    rows.add((fields: fields, seconds: ms == null ? null : ms / 1000.0));
  }
  return (header: header, rows: rows);
}

ShearwaterTables _csvTables(Uint8List bytes) {
  var text = utf8.decode(bytes, allowMalformed: true);
  if (text.startsWith('﻿')) {
    text = text.substring(1);
  }
  // Two tables back to back: the dive header and its one row, then the
  // sample header and the samples.
  final lines = pyCsvRows(text);
  if (lines.length < 2) {
    return (header: {}, rows: []);
  }
  // The first of a repeated column name wins.
  Map<String, String> zipFirstWins(List<String> names, List<String> values) {
    final map = <String, String>{};
    for (var i = 0; i < names.length && i < values.length; i++) {
      map.putIfAbsent(names[i], () => values[i]);
    }
    return map;
  }

  final header = zipFirstWins(lines[0], lines[1]);
  final rows = <ShearwaterRow>[];
  if (lines.length > 2) {
    final columns = lines[2];
    for (final values in lines.skip(3)) {
      if (values.isEmpty) {
        continue;
      }
      final fields = zipFirstWins(columns, values);
      rows.add((fields: fields, seconds: pyFloat(fields[_timeColumn])));
    }
  }
  return (header: header, rows: rows);
}

/// The start of the dive: the header's "Start Date" in the reading whose
/// date is the one in the file name, else its first reading (month first),
/// else the file name's own date and time.
DateTime? _startTime(Map<String, String> header, String path) {
  final text = (header['Start Date'] ?? '').pyStrip();
  final candidates = [
    for (final format in _dateFormats) ?pyStrptime(text, format),
  ];
  final match = _filenameDate.firstMatch(pyStem(path));
  DateTime? fromName;
  if (match != null) {
    final parts = [for (var i = 1; i <= 6; i++) int.parse(match.group(i)!)];
    fromName = naive(
      parts[0],
      parts[1],
      parts[2],
      parts[3],
      parts[4],
      parts[5],
    );
    // Python's datetime() refuses a date or time that does not exist, and
    // the parser lets that error out.
    if (parts[0] < 1 ||
        fromName.month != parts[1] ||
        fromName.day != parts[2] ||
        fromName.hour != parts[3] ||
        fromName.minute != parts[4] ||
        fromName.second != parts[5]) {
      throw FormatException('No such date in the file name', path);
    }
    for (final candidate in candidates) {
      if (candidate.year == fromName.year &&
          candidate.month == fromName.month &&
          candidate.day == fromName.day) {
        return candidate;
      }
    }
  }
  return candidates.isNotEmpty ? candidates.first : fromName;
}

/// The circuit from the XML's "OC/BO"- or "CC/BO"-style text or the CSV's
/// numeric mode. Only open circuit (XML "OC/BO", CSV 1) is confirmed
/// against a real export.
String? shearwaterDivemode(String? value) {
  final text = (value ?? '').pyStrip().toUpperCase();
  if (text.isEmpty) {
    return null;
  }
  if (text.startsWith('CC') || text.startsWith('SC')) {
    return 'closedcircuit';
  }
  if (text.contains('OC') || text == '1') {
    return 'opencircuit';
  }
  if (text == '0') {
    return 'closedcircuit';
  }
  return null;
}

/// The dive of a Shearwater Cloud export, or none when the file cannot be
/// read as one, has no start date or no samples.
///
/// The XML reader here is more forgiving than lxml, which Python uses: a
/// file with an undefined entity, a bare `&`, text after the root element
/// or an undeclared prefix is no dive in Python and is read here; an
/// entity declared in the file's own DTD is expanded by lxml and not here.
/// Shearwater's exports have none of these (spec §10.18).
List<Dive> parseShearwater(Uint8List bytes, String path) {
  final ShearwaterTables tables;
  try {
    tables = readShearwaterTables(bytes, path);
  } on FormatException {
    return [];
  } on XmlException {
    return [];
  }
  final (:header, :rows) = tables;

  final startTime = _startTime(header, path);
  if (startTime == null || rows.isEmpty) {
    return [];
  }

  final imperial =
      (header['Imperial Units'] ?? '').pyStrip().toLowerCase() == 'true';
  final depthScale = imperial ? _ftToM : 1.0;

  double? toC(String? value) {
    final temp = pyFloat(value);
    if (temp == null) {
      return null;
    }
    return imperial ? (temp - 32.0) * 5.0 / 9.0 : temp;
  }

  final waypoints = <Waypoint>[];
  // The gases seen, by their percentages to one decimal, in first-seen
  // order: what the deco pass may choose from.
  final gases = <(double, double), String>{};
  var currentMaxDepth = 0.0;
  var lastSeconds = -1;
  for (final (:fields, seconds: secondsF) in rows) {
    if (secondsF == null) {
      continue;
    }
    final seconds = pyRound(secondsF);
    if (seconds <= lastSeconds) {
      continue;
    }
    lastSeconds = seconds;

    // No depth is null (spec §10.8); Python stores 0.0. An empty first-stop
    // cell stays "no stop" (0), which is what it means in this export.
    final depthValue = pyFloat(fields['Depth']);
    final depth = depthValue == null ? null : depthValue * depthScale;
    if (depth != null) {
      currentMaxDepth = pyMax(currentMaxDepth, depth);
    }

    final o2 = _or(pyFloat(fields['Fraction O2']), 0.21) * 100.0;
    final he = _or(pyFloat(fields['Fraction He']), 0.0) * 100.0;
    gases.putIfAbsent((
      pyRoundTo(o2, 1),
      pyRoundTo(he, 1),
    ), () => '${pyFormatG(o2)}/${pyFormatG(he)}');

    final stopDepth =
        _or(pyFloat(fields['First Stop Depth']), 0.0) * depthScale;
    final stopMin = pyFloat(fields['First Stop Time']);
    final ndlMin = pyFloat(fields['Current NDL']);
    // NDL 0 with no stop is the computer at the surface or not diving yet,
    // not "in deco".
    final ndl = ndlMin != null && (ndlMin > 0 || stopDepth > 0)
        ? (ndlMin * 60).toInt()
        : null;
    final ttsMin = pyFloat(fields['Time To Surface (min)']);
    final gasTime = pyFloat(fields['Gas Time Remaining']);
    final sacPsi = pyFloat(fields['SAC Rate (2 minute avg)']);

    final tanks = <String, TankData>{};
    for (var n = 1; n <= _tankColumns.length; n++) {
      final psi = pyFloat(fields[_tankColumns[n - 1]]);
      if (psi != null && 0 < psi && psi < shearwaterStatusPsi) {
        tanks['T$n'] = TankData(
          pressureBar: psi * _psiToBar,
          o2Percent: o2,
          hePercent: he,
        );
      }
    }

    final po2 = pyFloat(fields['Average PPO2']);
    waypoints.add(
      Waypoint(
        timestamp: startTime.add(Duration(seconds: seconds)),
        depth: depth,
        maxDepth: currentMaxDepth,
        temp: toC(fields['Water Temp']),
        ndl: ndl,
        tts: ttsMin == null ? null : (ttsMin * 60).toInt(),
        decoStopDepth: stopDepth,
        nextStopTime: stopMin != null && stopDepth > 0
            ? (stopMin * 60).toInt()
            : 0,
        po2: po2 == null ? null : pyRoundTo(po2, 2),
        divemode: shearwaterDivemode(fields['Current Circuit Mode']),
        battery: pyFloat(fields['Battery Voltage']),
        airRemaining: gasTime == null ? null : (gasTime * 60).toInt(),
        pressureSac: sacPsi != null && sacPsi > 0
            ? pyRoundTo(sacPsi * _psiToBar, 2)
            : null,
        timeSinceStart: seconds,
        diveTime: seconds,
        tanks: tanks,
      ),
    );
  }

  if (waypoints.isEmpty) {
    return [];
  }

  final fileGf = parseGf(
    pyFloat(header['GF Minimum']),
    pyFloat(header['GF Maximum']),
  );
  applyDecoAndGas(waypoints, [
    for (final MapEntry(key: (o2, he), value: name) in gases.entries)
      decoGas(name, o2, he),
  ], fileGf: fileGf);

  // The XML header has no product name (<product> is a number under
  // another key), so there the device comes from the export's file name,
  // "Perdix 2[A5419AC1]#451 ...".
  final product = (header['Product'] ?? '').pyStrip();
  final device = product.isNotEmpty
      ? product
      : _filenameDevice.firstMatch(pyStem(path))?.group(1);
  final endTime = waypoints.last.timestamp;
  return [
    Dive(
      startTime: startTime,
      endTime: endTime,
      waypoints: waypoints,
      device: device,
      manufactor: 'Shearwater Research, Inc',
      durationSeconds: endTime.difference(startTime).inSeconds,
      // Python uses the file's gradient factors for the recompute and drops
      // them; the port keeps them on the dive (spec §10.16).
      gfLow: fileGf == null ? null : pyRound(fileGf.$1 * 100),
      gfHigh: fileGf == null ? null : pyRound(fileGf.$2 * 100),
      logFilename: pyFileName(path),
      logPath: path,
    ),
  ];
}

// Python: `value or fallback`, where 0.0 is falsy and NaN is not.
double _or(double? value, double fallback) =>
    value == null || value == 0 ? fallback : value;
