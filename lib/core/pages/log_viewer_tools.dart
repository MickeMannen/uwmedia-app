/// The Log Viewer's helpers around its two FIT tools, "Adjust time" and
/// "Merge dives" (Python `uwmedia/backends/log_viewer_backend.py`): what
/// the dialogs' text fields mean, the name a result is saved under and
/// which dives a dive can be merged with.
library;

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/parsers/fit_merge.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';

const _startFormats = ['%Y-%m-%d %H:%M:%S', '%Y-%m-%d %H:%M'];

final _whitespace = RegExp(r'\s+');

/// "2026-03-05 14:23" or "2026-03-05 14:23:07" as a naive local time.
/// Throws a [FormatException] for anything else.
DateTime parseLocalStart(String text) {
  final tidy = text.trim().split(_whitespace).join(' ');
  for (final format in _startFormats) {
    final time = pyStrptime(tidy, format);
    if (time != null) {
      return time;
    }
  }
  throw FormatException('Not a date and time', text);
}

final _utcOffset = RegExp(
  r'^(?:UTC|GMT)?\s*([+-]?)(\d{1,2})(?::?(\d{2}))?$',
  caseSensitive: false,
);

/// "+07:00", "-5:30", "+7", "UTC+08:00" or "0" as minutes east of UTC.
/// Throws a [FormatException] for anything else, and for an offset outside
/// UTC-12:00 to UTC+14:00.
int parseUtcOffset(String text) {
  final match = _utcOffset.firstMatch(text.trim());
  if (match == null) {
    throw FormatException('Not a UTC offset', text);
  }
  final minutes = int.parse(match[3] ?? '0');
  var total = int.parse(match[2]!) * 60 + minutes;
  if (match[1] == '-') {
    total = -total;
  }
  if (total < -12 * 60 || total > 14 * 60 || minutes >= 60) {
    throw FormatException('Not a UTC offset', text);
  }
  return total;
}

/// Minutes east of UTC as "+07:00" or "-05:30".
String formatUtcOffset(int minutes) {
  final sign = minutes < 0 ? '-' : '+';
  final abs = minutes.abs();
  return '$sign${'${abs ~/ 60}'.padLeft(2, '0')}:'
      '${'${abs % 60}'.padLeft(2, '0')}';
}

// Python's `path.with_name(stem + mark + suffix)`.
String _marked(String path, String mark, p.Context context) {
  final separators = context.style == p.Style.windows ? r'/\' : '/';
  var cut = -1;
  for (var i = 0; i < path.length; i++) {
    if (separators.contains(path[i])) {
      cut = i;
    }
  }
  return '${path.substring(0, cut + 1)}${pyStem(path)} ($mark)'
      '${pySuffix(path)}';
}

/// Where Save As starts after "Adjust time": "Dive 12.fit" gives
/// "Dive 12 (adjusted).fit".
String adjustedName(String path, {p.Context? context}) =>
    _marked(path, 'adjusted', context ?? p.context);

/// Where Save As starts for a merge: "Dive 12.fit" gives
/// "Dive 12 (merged).fit".
String mergedName(String path, {p.Context? context}) =>
    _marked(path, 'merged', context ?? p.context);

double _secondsBetween(DateTime from, DateTime to) =>
    to.difference(from).inMicroseconds / Duration.microsecondsPerSecond;

/// The FIT dives of [dives] that start after [dive] ends, within the
/// merge's limit (the ones [dive] can be merged with), earliest first.
/// [fileExists] says whether a dive's log file is still there.
List<Dive> mergeCandidates(
  List<Dive> dives,
  Dive dive, {
  required bool Function(String path) fileExists,
}) {
  final found = <Dive>[];
  for (final other in dives) {
    final path = other.logPath;
    if (identical(other, dive) ||
        other.logFormat != 'fit' ||
        path == null ||
        path.isEmpty ||
        !fileExists(path) ||
        path == dive.logPath) {
      continue;
    }
    final gap = _secondsBetween(dive.endTime, other.startTime);
    if (gap > 0 && gap <= maxMergeGapSeconds) {
      found.add(other);
    }
  }
  // A stable sort, as Python's.
  final order = [for (var i = 0; i < found.length; i++) i]
    ..sort((a, b) {
      final byStart = found[a].startTime.compareTo(found[b].startTime);
      return byStart != 0 ? byStart : a.compareTo(b);
    });
  return [for (final i in order) found[i]];
}

/// How the merge dialog names a dive to merge with: its start, its file
/// and how long after [dive] it began.
String candidateLabel(Dive dive, Dive other) {
  assert(other.startTime.isUtc, naiveTimeMessage);
  final gap = _secondsBetween(dive.endTime, other.startTime).truncate();
  final file = switch (other.logFilename) {
    final String name when name.isNotEmpty => name,
    _ => pyFileName(other.logPath ?? ''),
  };
  return '${pyStrftime(other.startTime, '%H:%M')} · $file '
      '(${(gap / 60).floor()} min after this dive)';
}
