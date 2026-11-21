/// When a photo or a video was taken, and in which timezone (Python
/// `metadata/exif.py`, spec §3 E2 and E3), from the file's tags.
///
/// The tags come as exiftool gives them in JSON: a map from group-prefixed
/// names (`QuickTime:CreationDate`, `EXIF:DateTimeOriginal`) or bare names
/// to text or numbers. Where they come from (exiftool on desktop, the
/// port's own readers elsewhere) is not this file's business.
library;

import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';

/// A file's tags by name.
typedef MediaTags = Map<String, Object?>;

/// The layout of the dates in the tags.
const tagDateFormat = '%Y:%m:%d %H:%M:%S';

// Python's `a or b`: nothing, empty text, zero and false do not count.
bool _truthy(Object? value) =>
    value != null && value != '' && value != 0 && value != false;

Object? _first(MediaTags meta, List<String> names) {
  for (final name in names) {
    final value = meta[name];
    if (_truthy(value)) {
      return value;
    }
  }
  return null;
}

String _head(String text) => text.length > 19 ? text.substring(0, 19) : text;

DateTime? _tagDate(Object? value) =>
    pyStrptime(_head(value.toString()), tagDateFormat);

const _createDate = ['QuickTime:CreateDate', 'CreateDate'];
const _creationDate = ['QuickTime:CreationDate', 'CreationDate'];
const _timezone = [
  'QuickTime:Timezone',
  'QuickTime:TimeZone',
  'Timezone',
  'TimeZone',
];

final _offsetText = RegExp(r'^([+-])?(\d{2}):?(\d{2})');
final _offsetAtEnd = RegExp(r'([+-]\d{2}:?\d{2})\n?$');

/// The minutes east of UTC that [value] stands for: a number of minutes, or
/// text starting like `+02:00`, `02:00` or `+0200`. `null` when it is
/// neither.
///
/// Throws a [FormatException] for an offset of a day or more, where
/// Python's `timezone()` raises.
int? parseTimezone(Object? value) {
  if (value == null || value == '') {
    return null;
  }
  final int minutes;
  if (value is bool) {
    // Python's True and False are the numbers 1 and 0.
    minutes = value ? 1 : 0;
  } else if (value is num) {
    if (!value.isFinite) {
      throw FormatException('Not a timezone offset', value);
    }
    minutes = value.truncate();
  } else {
    final match = _offsetText.firstMatch(value.toString());
    if (match == null) {
      return null;
    }
    final size = int.parse(match[2]!) * 60 + int.parse(match[3]!);
    minutes = match[1] == '-' ? -size : size;
  }
  if (minutes.abs() >= 24 * 60) {
    throw FormatException('A timezone offset must be under 24 hours', value);
  }
  return minutes;
}

int? _timezoneOrNull(Object? value) {
  try {
    return parseTimezone(value);
  } on FormatException {
    return null;
  }
}

/// `+08:00` or `-03:30` for [minutes] east of UTC.
String tzIso(int minutes) {
  final size = minutes.abs();
  final hours = (size ~/ 60).toString().padLeft(2, '0');
  final mins = (size % 60).toString().padLeft(2, '0');
  return '${minutes >= 0 ? '+' : '-'}$hours:$mins';
}

/// The timezone a file was recorded in, in minutes east of UTC, or `null`
/// when the tags do not say: the offset at the end of `CreationDate`, else
/// `CreationDate` minus `CreateDate` (which is UTC) to the nearest quarter
/// of an hour, else Sony's `Timezone`/`TimeZone` tag.
///
/// Both dates must be there for the first two, as in Python. An offset of
/// a day or more in the `Timezone` tag is no answer here; Python raises.
int? timezoneOffsetMinutes(MediaTags? meta) {
  if (meta == null || meta.isEmpty) {
    return null;
  }
  final create = _first(meta, _createDate);
  final creation = _first(meta, _creationDate);
  int? fromDates() {
    if (create == null || creation == null) {
      return null;
    }
    final match = _offsetAtEnd.firstMatch(creation.toString());
    if (match != null) {
      // An offset that cannot be leaves the question to the Timezone tag.
      return _timezoneOrNull(match[1]);
    }
    final utc = _tagDate(create);
    final local = _tagDate(creation);
    if (utc == null || local == null) {
      return null;
    }
    // Whole minutes toward zero, then to the nearest 15 (a half to the
    // even one), so that a clock set a little off does not show.
    final minutes = local.difference(utc).inSeconds ~/ 60;
    return pyRound(minutes / 15) * 15;
  }

  // Python's `a or b or c or d` is d when none counts, so a TimeZone tag
  // of 0 is an answer though a Timezone tag of 0 is not.
  return fromDates() ??
      _timezoneOrNull(_first(meta, _timezone) ?? meta[_timezone.last]);
}

bool _inPythonRange(DateTime time) => time.year >= 1 && time.year <= 9999;

/// The moment a file was taken, as a real UTC `DateTime` (not a naive
/// one): `CreationDate` with its offset, else `CreateDate`, which
/// QuickTime keeps in UTC. Throws a [FormatException] when neither can be
/// read.
DateTime standardizedCreationDate(MediaTags? meta) {
  if (meta == null || meta.isEmpty) {
    throw const FormatException('Could not extract metadata');
  }
  final creation = _first(meta, _creationDate);
  if (creation != null) {
    final text = creation.toString();
    final local = _tagDate(text);
    if (local != null) {
      // Subseconds come before the offset: "...12:34:56.98+08:00".
      final rest = text
          .substring(text.length < 19 ? text.length : 19)
          .replaceFirst(RegExp(r'^\.\d+'), '');
      final minutes = _timezoneOrNull(rest);
      if (minutes != null) {
        final utc = local.subtract(Duration(minutes: minutes));
        if (_inPythonRange(utc)) {
          return utc;
        }
      }
    }
  }
  final create = _first(meta, _createDate);
  if (create != null) {
    final utc = _tagDate(create);
    if (utc == null) {
      throw FormatException('Not a date', create);
    }
    return utc;
  }
  throw const FormatException('No valid creation date found in video metadata');
}

final _subseconds = RegExp(r'\.(\d+)');
final _notDigit = RegExp('[^0-9]');
const _localDate = [
  ..._creationDate,
  'EXIF:DateTimeOriginal',
  'DateTimeOriginal',
  'EXIF:CreateDate',
];
const _subsecTags = [
  'EXIF:SubSecTimeOriginal',
  'SubSecTimeOriginal',
  'EXIF:SubSecTimeDigitized',
  'SubSecTimeDigitized',
  'EXIF:SubSecTime',
  'SubSecTime',
];

/// The local time a photo or video was taken, as a naive timestamp.
///
/// The first of `CreationDate`, `DateTimeOriginal` and `EXIF:CreateDate`
/// that is set, with the fraction of a second from the text itself or from
/// a `SubSecTime` tag. If that one cannot be read: `CreateDate` (UTC,
/// unless it is all zeros) moved by the `Timezone`/`TimeZone` tag when
/// there is one. Else [fileModified], the file's modification time in
/// local time. Throws a [FormatException] when all of that fails.
DateTime localCreationDate(MediaTags? meta, {DateTime? fileModified}) {
  assert(fileModified == null || fileModified.isUtc, naiveTimeMessage);
  if (meta == null || meta.isEmpty) {
    throw const FormatException('Could not extract metadata');
  }
  final creation = _first(meta, _localDate);
  if (creation != null) {
    final text = creation.toString();
    final time = _tagDate(text);
    if (time != null) {
      final inText = _subseconds.firstMatch(text)?[1];
      final digits = (inText ?? _first(meta, _subsecTags)?.toString() ?? '')
          .replaceAll(_notDigit, '');
      if (digits.isEmpty) {
        return time;
      }
      final micros = (double.parse('0.$digits') * 1000000).truncate();
      return time.add(Duration(microseconds: micros));
    }
  }

  final create = _first(meta, _createDate)?.toString();
  if (create != null && !create.startsWith('0000')) {
    final utc = _tagDate(create);
    if (utc != null) {
      try {
        final minutes = parseTimezone(_first(meta, _timezone));
        final local = utc.add(Duration(minutes: minutes ?? 0));
        if (_inPythonRange(local)) {
          return local;
        }
      } on FormatException {
        // An offset that cannot be: on to the file's own time.
      }
    }
  }

  if (fileModified != null) {
    return fileModified;
  }
  throw const FormatException('No valid creation date found in video metadata');
}

/// The tags written to an output after the source's tags were copied to it
/// (Python `copy_all`): the local creation date with the timezone, and the
/// timezone itself. [forcedTzMinutes] replaces the source's own timezone;
/// `null` when there is neither, and nothing is written then. Throws like
/// [localCreationDate] when there is a timezone but no date.
Map<String, String>? timezoneTagsAfterCopy(
  MediaTags? meta, {
  int? forcedTzMinutes,
  DateTime? fileModified,
}) {
  final minutes = forcedTzMinutes ?? timezoneOffsetMinutes(meta);
  if (minutes == null) {
    return null;
  }
  final taken = localCreationDate(meta, fileModified: fileModified);
  final offset = tzIso(minutes);
  return {
    'QuickTime:CreationDate': pyStrftime(taken, tagDateFormat) + offset,
    'QuickTime:Timezone': offset,
    'QuickTime:TimeZone': offset,
  };
}

/// The camera a photo or video is from, as its tags say it (the app's
/// own readers' or exiftool's, spec §10.72): the maker and the model,
/// each `null` when no tag says it. EXIF's or QuickTime's `Make` and
/// `Model`, a Sony camera's XML block, or the name a DJI camera writes as
/// the file's encoder ("DJI OsmoAction5 Pro"), with the model name of its
/// `Category` when there is no other.
({String? make, String? model}) cameraOf(MediaTags? meta) {
  String? said(List<String> names) {
    for (final name in names) {
      final value = meta?[name];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return null;
  }

  var make = said(const [
    'EXIF:Make',
    'QuickTime:Make',
    'XML:DeviceManufacturer',
  ]);
  var model = said(const [
    'EXIF:Model',
    'QuickTime:Model',
    'XML:DeviceModelName',
  ]);
  final encoder = said(const ['QuickTime:Encoder']);
  if (encoder != null && encoder.startsWith('DJI ')) {
    make ??= 'DJI';
    model ??= encoder.substring(4).trim();
  }
  if (model == null) {
    final named = RegExp(r'model_name:([^;]+)')
        .firstMatch(said(const ['QuickTime:Category']) ?? '');
    model = named?[1]?.trim();
  }
  return (make: make, model: model);
}
