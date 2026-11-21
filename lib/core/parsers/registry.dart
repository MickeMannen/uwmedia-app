/// Which parser reads a dive log, ported from `parsers/registry.py` of the
/// Python app (spec §4.1): the one place every page asks, so a new format
/// is added here once.
///
/// `.uddf`, `.fit` and `.ssrf` go by their suffix. `.xml` and `.csv` are
/// shared by more than one program's export and are told apart by content;
/// `.json` is a dive log only when it is the Suunto app's export
/// (`{"DeviceLog": ...}`): any other JSON (settings, plans, overlay
/// documents) is not one.
///
/// Nothing here touches the file system: the caller reads the file (or its
/// first [logHeadSize] bytes for [detectLogFormat]) and passes the bytes.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/deco/gas_consumption.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/parsers/fit_reader.dart';
import 'package:uwmedia_app/core/parsers/shearwater.dart';
import 'package:uwmedia_app/core/parsers/subsurface.dart';
import 'package:uwmedia_app/core/parsers/subsurface_csv.dart';
import 'package:uwmedia_app/core/parsers/suunto.dart';
import 'package:uwmedia_app/core/parsers/uddf.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';

const String uddfFormat = 'uddf';
const String fitFormat = 'fit';
const String subsurfaceXmlFormat = 'subsurface_xml';
const String subsurfaceCsvFormat = 'subsurface_csv';
const String shearwaterXmlFormat = 'shearwater_xml';
const String shearwaterCsvFormat = 'shearwater_csv';
const String suuntoJsonFormat = 'suunto_json';

/// The file suffixes a dive log can have.
const Set<String> logExtensions = {
  '.uddf',
  '.fit',
  '.ssrf',
  '.xml',
  '.csv',
  '.json',
};

/// How many bytes from the start of a file [detectLogFormat] looks at.
const int logHeadSize = 4096;

/// A parser: the file's bytes, where they came from and the tank sensor
/// names, to its dives.
typedef LogParser = List<Dive> Function(
  Uint8List bytes,
  String path,
  TankConfig tanks,
);

/// The parsers, by format key.
final Map<String, LogParser> logParsers = {
  uddfFormat: (bytes, path, _) => parseUddf(bytes, path),
  fitFormat: (bytes, path, tanks) => parseGarmin(bytes, path, tanks: tanks),
  subsurfaceXmlFormat: (bytes, path, tanks) =>
      parseSubsurface(bytes, path, tanks: tanks),
  subsurfaceCsvFormat: (bytes, path, _) =>
      parseSubsurfaceCsv(decodeUtf8Sig(bytes), path),
  shearwaterXmlFormat: (bytes, path, _) => parseShearwater(bytes, path),
  shearwaterCsvFormat: (bytes, path, _) => parseShearwater(bytes, path),
  suuntoJsonFormat: (bytes, path, _) => parseSuunto(bytes, path),
};

// What Python's str.splitlines() breaks a line at.
final _lineBreak = RegExp('\r\n|[\n\r\v\f\x1c\x1d\x1e\x85\u2028\u2029]');

/// UTF-8 text with the bytes that are not valid UTF-8 left out (Python's
/// `errors="ignore"`).
String _utf8Ignoring(Uint8List bytes) {
  final out = StringBuffer();
  var i = 0;
  while (i < bytes.length) {
    final lead = bytes[i];
    final length = lead < 0x80
        ? 1
        : lead >= 0xc2 && lead < 0xe0
        ? 2
        : lead >= 0xe0 && lead < 0xf0
        ? 3
        : lead >= 0xf0 && lead < 0xf5
        ? 4
        : 0;
    if (length == 0 || i + length > bytes.length) {
      i += 1;
      continue;
    }
    try {
      out.write(utf8.decode(Uint8List.sublistView(bytes, i, i + length)));
      i += length;
    } on FormatException {
      i += 1;
    }
  }
  return out.toString();
}

/// The start of a file as text, for telling formats apart: UTF-16 when it
/// starts with that byte order mark, else UTF-8 without one; bytes that are
/// not text are dropped.
String _head(Uint8List bytes) {
  final raw = bytes.length > logHeadSize
      ? Uint8List.sublistView(bytes, 0, logHeadSize)
      : bytes;
  if (raw.length >= 2 &&
      ((raw[0] == 0xff && raw[1] == 0xfe) ||
          (raw[0] == 0xfe && raw[1] == 0xff))) {
    final littleEndian = raw[0] == 0xff;
    final units = <int>[
      for (var i = 2; i + 1 < raw.length; i += 2)
        littleEndian ? raw[i] | raw[i + 1] << 8 : raw[i] << 8 | raw[i + 1],
    ];
    return String.fromCharCodes(units);
  }
  return _utf8Ignoring(raw).replaceFirst(RegExp('^\u{FEFF}+'), '');
}

/// Python `open(encoding="utf-8-sig", errors="replace")`: UTF-8 with one
/// leading byte order mark removed, bytes that are not text replaced.
String decodeUtf8Sig(Uint8List bytes) {
  final text = utf8.decode(bytes, allowMalformed: true);
  return text.startsWith('\u{FEFF}') ? text.substring(1) : text;
}

/// Whether [head] starts as a FIT file does, whatever the file is called:
/// a header of 12 or 14 bytes with ".FIT" at bytes 8 to 11.
bool isFitHeader(List<int> head) =>
    head.length >= 12 &&
    (head[0] == 12 || head[0] == 14) &&
    head[8] == 0x2E &&
    head[9] == 0x46 &&
    head[10] == 0x49 &&
    head[11] == 0x54;

/// The format key of the log at [path], whose content starts with [head],
/// or `null` when it is not a log the app reads. [head] is looked at for
/// `.xml`, `.csv` and `.json`, and for a FIT file under another name.
String? detectLogFormat(String path, Uint8List head) {
  final suffix = pySuffix(path).toLowerCase();
  if (suffix == '.uddf') {
    return uddfFormat;
  }
  if (suffix == '.fit') {
    return fitFormat;
  }
  if (suffix == '.ssrf') {
    return subsurfaceXmlFormat;
  }
  if (suffix != '.xml' && suffix != '.csv' && suffix != '.json') {
    // Chrome on Android saves a download it has no type for as .bin
    // (spec §10.90): a FIT file is known by its header.
    return isFitHeader(head) ? fitFormat : null;
  }
  final text = _head(head);
  if (suffix == '.json') {
    return isSuuntoJson(text) ? suuntoJsonFormat : null;
  }
  if (suffix == '.xml') {
    return text.contains('<diveLog>')
        ? shearwaterXmlFormat
        : subsurfaceXmlFormat;
  }
  final firstLine = text.isEmpty ? '' : text.split(_lineBreak).first;
  if (firstLine.startsWith('Dive Number,')) {
    return shearwaterCsvFormat;
  }
  if (isSubsurfaceProfileHeader(firstLine)) {
    return subsurfaceCsvFormat;
  }
  return null;
}

/// Whether the file is a log the app reads.
bool isLogFile(String path, Uint8List head) =>
    detectLogFormat(path, head) != null;

/// The dives in one log file, each tagged with its format, or `null` when
/// the file is not a log format the app reads. Pass [logFormat] to skip the
/// detection, and [tanks] for the formats that name tanks by their sensor.
/// A dive whose log gives tank sizes but no VSAC gets VSAC worked out
/// (`fillVolumeSac`, spec §10.54); a tank whose log gives no size takes
/// the one set for it in [tanks].
List<Dive>? parseLogFile(
  String path,
  Uint8List bytes, {
  String? logFormat,
  TankConfig? tanks,
}) {
  final format = logFormat == null || logFormat.isEmpty
      ? detectLogFormat(path, bytes)
      : logFormat;
  if (format == null) {
    return null;
  }
  final parser = logParsers[format];
  if (parser == null) {
    throw UnsupportedError('No parser for the log format "$format"');
  }
  final config = tanks ?? TankConfig();
  final dives = parser(bytes, path, config);
  final sizes = config.sizesByKey;
  for (final dive in dives) {
    dive.logFormat = format;
    if (sizes.isNotEmpty) {
      // The log's own size wins.
      dive.tankVolumesL = {
        for (final key in {for (final wp in dive.waypoints) ...wp.tanks.keys})
          key: ?sizes[key],
        ...dive.tankVolumesL,
      };
    }
    // VSAC where the log has tank sizes but no VSAC of its own.
    fillVolumeSac(dive.waypoints, dive.tankVolumesL);
  }
  return dives;
}
