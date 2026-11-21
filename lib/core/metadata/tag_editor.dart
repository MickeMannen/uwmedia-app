/// The logic of the Tag Editor page (Python `utils/tag_editor.py`): the
/// date tags it shows, DJI's dates from the file name, and the tags a batch
/// timezone change writes.
library;

import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';

/// One date tag the editor manages, with the guidance shown next to it.
typedef TagGuide = ({String tag, String tz, String example, String hint});

/// The tags the editor manages.
const List<TagGuide> tagGuide = [
  (
    tag: 'QuickTime:CreationDate',
    tz: 'Local Time + Offset',
    example: '2026:05:21 06:58:22+08:00',
    hint: 'Primary date used by Apple Photos for sorting.',
  ),
  (
    tag: 'QuickTime:CreateDate',
    tz: 'UTC (Universal Time)',
    example: '2026:05:20 22:58:22',
    hint: 'Technical creation time, usually stored in UTC.',
  ),
  (
    tag: 'EXIF:DateTimeOriginal',
    tz: 'Local Time (Naive)',
    example: '2026:05:21 06:58:22',
    hint: 'Original capture time for photos.',
  ),
  (
    tag: 'EXIF:CreateDate',
    tz: 'Local Time (Naive)',
    example: '2026:05:21 06:58:22',
    hint: 'Standard digitized creation date for photos.',
  ),
];

/// The file types the editor opens.
const tagEditorExtensions = {
  '.mp4',
  '.mov',
  '.m4v',
  '.jpg',
  '.jpeg',
  '.png',
  '.fit',
};

/// Batch mode: the file's own local time, with the given offset put on it.
const tzModeKeepLocal = 'Keep local time, set offset';

/// Batch mode: the local time worked out from the file's UTC time.
const tzModeFromUtc = 'Recalculate local time from UTC';

/// The two batch modes, in the order the page lists them.
const tzModeOptions = [tzModeKeepLocal, tzModeFromUtc];

/// The offsets the page offers.
const tzOffsets = [
  '+14:00', '+13:00', '+12:45', '+12:00', '+11:00', '+10:30', '+10:00', //
  '+09:30', '+09:00', '+08:00', '+07:00', '+06:30', '+06:00', '+05:45',
  '+05:30', '+05:00', '+04:30', '+04:00', '+03:30', '+03:00', '+02:00',
  '+01:00', '+00:00', '-01:00', '-02:00', '-03:00', '-03:30', '-04:00',
  '-05:00', '-06:00', '-07:00', '-08:00', '-09:00', '-09:30', '-10:00',
  '-11:00', '-12:00',
];

/// The offset of the system's clock as text, from what the platform says
/// it is now (`DateTime.now().timeZoneOffset`).
String localTzOffsetString(Duration systemOffset) =>
    tzIso(systemOffset.inSeconds ~/ 60);

// A naive timestamp from text fields, or null when there is no such time.
DateTime? _dateOf(RegExpMatch match) {
  final f = [for (var i = 1; i <= 6; i++) int.parse(match[i]!)];
  if (f[0] < 1 || f[3] > 23 || f[4] > 59 || f[5] > 59) {
    return null;
  }
  final time = naive(f[0], f[1], f[2], f[3], f[4], f[5]);
  return time.month == f[1] && time.day == f[2] ? time : null;
}

final _djiName = RegExp(
  r'DJI_(\d{4})(\d{2})(\d{2})_?(\d{2})(\d{2})(\d{2})',
  caseSensitive: false,
);

String _text(Object? value) => value == null ? '' : value.toString();

/// DJI drones write a correct local capture time into the file name (and
/// `OriginalFilePath`) but not into most date tags. If this looks like a
/// DJI file, the tag values that fix that, from the name's local time and
/// the file's (correct) UTC `CreateDate`; `null` otherwise.
Map<String, String>? calculateDjiDatetimes(String path, MediaTags tags) {
  final match =
      _djiName.firstMatch(_text(tags['QuickTime:OriginalFilePath'])) ??
      _djiName.firstMatch(pyFileName(path));
  if (match == null) {
    return null;
  }
  final local = _dateOf(match);
  if (local == null) {
    return null;
  }
  var utcText = _text(tags['QuickTime:CreateDate']);
  if (utcText.isEmpty) {
    utcText = _text(tags['CreateDate']);
  }
  if (utcText.isEmpty) {
    return null;
  }
  final head = utcText.length > 19 ? utcText.substring(0, 19) : utcText;
  final utc =
      pyStrptime(head, tagDateFormat) ?? pyStrptime(head, '%Y-%m-%d %H:%M:%S');
  if (utc == null) {
    return null;
  }
  final seconds = local.difference(utc).inSeconds;
  final offset = pyRound(seconds / 60 / 15) * 15;
  final localText = pyStrftime(local, tagDateFormat);
  return {
    'QuickTime:CreationDate': localText + tzIso(offset),
    'QuickTime:CreateDate': pyStrftime(utc, tagDateFormat),
    'EXIF:DateTimeOriginal': localText,
    'EXIF:CreateDate': localText,
  };
}

final _compactDate = RegExp(r'(\d{4})(\d{2})(\d{2})_?(\d{2})(\d{2})(\d{2})');
final _separatedDate = RegExp(
  r'(\d{4})[_-]?(\d{2})[_-]?(\d{2})[_-](\d{2})(\d{2})(\d{2})',
);

/// The local capture time in a file's name, by the common conventions
/// (`20260905_143000`, `2026-09-05_143000`), or `null`.
DateTime? parseDateFromFilename(String path) {
  final name = pyFileName(path);
  for (final pattern in [_compactDate, _separatedDate]) {
    final match = pattern.firstMatch(name);
    final time = match == null ? null : _dateOf(match);
    if (time != null) {
      return time;
    }
  }
  return null;
}

// What Python's get_tags answers for a tag: the tag by its full name, else
// one with the same name in another group.
String _looseTag(MediaTags meta, String name) {
  var value = meta[name];
  if (value == null) {
    final bare = name.split(':').last;
    for (final entry in meta.entries) {
      if (entry.key.split(':').last == bare) {
        value = entry.value;
        break;
      }
    }
  }
  return _text(value);
}

/// The tags a batch timezone change writes to one file, or `null` when no
/// usable date was found.
///
/// With [tzModeKeepLocal] the file keeps its local time and gets the
/// offset [tzMinutes]; with [tzModeFromUtc] the local time is the file's
/// UTC creation time moved by the offset. The local time comes from the
/// tags, else from [fileModified] (the file's modification time in local
/// time), else from the file's name.
Map<String, String>? batchTimezoneUpdates({
  required MediaTags? meta,
  required String path,
  required String mode,
  required int tzMinutes,
  DateTime? fileModified,
}) {
  DateTime? ownLocalTime() {
    try {
      return localCreationDate(meta, fileModified: fileModified);
    } on FormatException {
      return parseDateFromFilename(path) ?? fileModified;
    }
  }

  DateTime? local;
  if (mode == tzModeKeepLocal) {
    local = ownLocalTime();
  } else {
    DateTime? utc;
    try {
      utc = standardizedCreationDate(meta);
    } on FormatException {
      final tags = meta ?? const {};
      var create = _looseTag(tags, 'QuickTime:CreateDate');
      if (create.isEmpty) {
        create = _looseTag(tags, 'CreateDate');
      }
      if (create.isNotEmpty) {
        utc = pyStrptime(
          create.length > 19 ? create.substring(0, 19) : create,
          tagDateFormat,
        );
      }
    }
    final shifted = utc?.add(Duration(minutes: tzMinutes));
    // Past the year 9999 (Python cannot hold it): the file's own time.
    local = shifted == null || shifted.year < 1 || shifted.year > 9999
        ? ownLocalTime()
        : shifted;
  }
  if (local == null) {
    return null;
  }

  final localText = pyStrftime(local, tagDateFormat);
  final offset = tzIso(tzMinutes);
  if (const ['.mp4', '.mov', '.m4v'].contains(pySuffix(path).toLowerCase())) {
    return {
      'QuickTime:CreationDate': localText + offset,
      'QuickTime:Timezone': offset,
      'QuickTime:TimeZone': offset,
      'EXIF:DateTimeOriginal': localText,
      'EXIF:CreateDate': localText,
    };
  }
  return {
    'EXIF:DateTimeOriginal': localText,
    'EXIF:CreateDate': localText,
    'EXIF:OffsetTime': offset,
    'EXIF:OffsetTimeOriginal': offset,
    'EXIF:OffsetTimeDigitized': offset,
  };
}

/// A shift as the page says it: "+1 h 30 min", "-0 h 45 min".
String shiftText(int minutes) {
  final size = minutes.abs();
  return '${minutes < 0 ? '-' : '+'}${size ~/ 60} h ${size % 60} min';
}

/// The tags "Shift all files" writes to one file (spec §9.1), or `null`
/// when no usable date was found or the shifted one cannot be.
///
/// The file's local capture time (from the tags, else [fileModified], else
/// its name, as a batch timezone change finds it) moves by [shiftMinutes].
/// With [tzMinutes] the file gets that offset, and its UTC time follows
/// from the new local time; without, it keeps its own offset (the
/// `CreationDate` suffix, the `Timezone` tag or a photo's `OffsetTime`
/// tags), and when it has none its UTC `CreateDate` moves by the same
/// shift. A video's `TrackCreateDate` and `MediaCreateDate` (UTC) follow
/// its `CreateDate` when it has them.
Map<String, String>? shiftUpdates({
  required MediaTags? meta,
  required String path,
  required int shiftMinutes,
  int? tzMinutes,
  DateTime? fileModified,
}) {
  final local = ownLocalTime(meta, path, fileModified: fileModified);
  if (local == null) {
    return null;
  }
  return retimeUpdates(
    meta: meta,
    path: path,
    from: local,
    to: local.add(Duration(minutes: shiftMinutes)),
    tzMinutes: tzMinutes,
  );
}

/// The local capture time a batch change starts from: the tags', else
/// [fileModified] (the file's modification time in local time), else the
/// file name's; `null` when there is none.
DateTime? ownLocalTime(MediaTags? meta, String path, {DateTime? fileModified}) {
  try {
    return localCreationDate(meta, fileModified: fileModified);
  } on FormatException {
    return parseDateFromFilename(path) ?? fileModified;
  }
}

/// The tags that move a file whose local capture time is [from] to the
/// local time [to] (see [shiftUpdates], which is this with `to` = `from`
/// plus the shift; the phones' Tag Editor sets one file's date with it).
/// `null` when [to] cannot be stored.
Map<String, String>? retimeUpdates({
  required MediaTags? meta,
  required String path,
  required DateTime from,
  required DateTime to,
  int? tzMinutes,
}) {
  final shift = to.difference(from);
  final moved = to;
  bool inRange(DateTime t) => t.year >= 1 && t.year <= 9999;
  if (!inRange(moved)) {
    return null;
  }
  final tags = meta ?? const <String, Object?>{};
  final own =
      timezoneOffsetMinutes(meta) ??
      _timezoneOf(tags['EXIF:OffsetTimeOriginal']) ??
      _timezoneOf(tags['EXIF:OffsetTime']);
  final offset = tzMinutes ?? own;
  DateTime? utc;
  if (offset != null) {
    utc = moved.subtract(Duration(minutes: offset));
  } else {
    var create = _looseTag(tags, 'QuickTime:CreateDate');
    if (create.isEmpty) {
      create = _looseTag(tags, 'CreateDate');
    }
    final before = create.isEmpty || create.startsWith('0000')
        ? null
        : pyStrptime(
            create.length > 19 ? create.substring(0, 19) : create,
            tagDateFormat,
          );
    utc = before?.add(shift);
  }
  if (utc != null && !inRange(utc)) {
    utc = null;
  }

  final localText = pyStrftime(moved, tagDateFormat);
  final utcText = utc == null ? null : pyStrftime(utc, tagDateFormat);
  final updates = <String, String>{
    'EXIF:DateTimeOriginal': localText,
    'EXIF:CreateDate': localText,
  };
  if (const ['.mp4', '.mov', '.m4v'].contains(pySuffix(path).toLowerCase())) {
    if (offset != null) {
      updates['QuickTime:CreationDate'] = localText + tzIso(offset);
    }
    if (utcText != null) {
      updates['QuickTime:CreateDate'] = utcText;
      for (final tag in const [
        'QuickTime:TrackCreateDate',
        'QuickTime:MediaCreateDate',
      ]) {
        if (tags.containsKey(tag)) {
          updates[tag] = utcText;
        }
      }
    }
    if (tzMinutes != null) {
      updates['QuickTime:Timezone'] = tzIso(tzMinutes);
      updates['QuickTime:TimeZone'] = tzIso(tzMinutes);
    }
  } else if (tzMinutes != null) {
    for (final tag in const [
      'EXIF:OffsetTime',
      'EXIF:OffsetTimeOriginal',
      'EXIF:OffsetTimeDigitized',
    ]) {
      updates[tag] = tzIso(tzMinutes);
    }
  }
  return updates;
}

int? _timezoneOf(Object? value) {
  try {
    return parseTimezone(value);
  } on FormatException {
    return null;
  }
}

/// The rows (tag and value) whose tag or value contains [text], whatever
/// the case: the filter of the editor's metadata viewer.
List<({String tag, Object? value})> filterMetadataRows(
  List<({String tag, Object? value})> rows,
  String? text,
) {
  final wanted = (text ?? '').toLowerCase();
  return [
    for (final row in rows)
      if (row.tag.toLowerCase().contains(wanted) ||
          // Python's str(None).
          (row.value == null ? 'None' : '${row.value}').toLowerCase().contains(
            wanted,
          ))
        row,
  ];
}
