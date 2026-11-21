/// The dives a page's photos and videos are matched to, all of them and
/// not only the one in the preview: which logs a run will read from, and
/// which files have none (owner, 2026-11-17: where is the matched log
/// shown; then, for many files, a button that says whether all have one
/// and opens the list of them).
library;

import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/model/dive_manager.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';

/// One file: the time it is matched at (its own with the clock offset;
/// `null` when its date could not be read) and the dive found for it.
typedef FileMatch = ({String file, DateTime? time, Dive? dive});

/// The files in their order ([rows]), the [dives] matched (each once, by
/// start), how many [files] there are and how many match no dive.
typedef DiveMatches = ({
  List<FileMatch> rows,
  List<Dive> dives,
  int files,
  int unmatched,
});

/// Each file of [times] (its own time with the clock offset, `null` when
/// it has none) matched to the dives of [manager], as a run matches it.
DiveMatches matchDives(DiveManager manager, Map<String, DateTime?> times) {
  final rows = <FileMatch>[
    for (final MapEntry(key: file, value: time) in times.entries)
      (
        file: file,
        time: time,
        dive: time == null ? null : manager.findDiveForTimestamp(time),
      ),
  ];
  final dives = {for (final row in rows) ?row.dive}.toList()
    ..sort((a, b) => a.startTime.compareTo(b.startTime));
  return (
    rows: rows,
    dives: dives,
    files: rows.length,
    unmatched: rows.where((row) => row.dive == null).length,
  );
}

/// "2026-10-29 11:20 (521 Arild.fit)": a dive by its start and its log.
String diveLabel(Dive dive) =>
    '${pyStrftime(dive.startTime, '%Y-%m-%d %H:%M')}'
    '${dive.logFilename == null ? '' : ' (${dive.logFilename})'}';

/// What the page's button says: "Dive logs: all 12 matched", "Dive logs:
/// 3 of 12 not matched", "Dive logs: none of 12 matched"; for one file
/// "Dive log: matched" or "Dive log: not matched". Empty without a file.
String diveMatchLabel(DiveMatches matches) {
  final (rows: _, dives: _, :files, :unmatched) = matches;
  if (files == 0) {
    return '';
  }
  if (files == 1) {
    return unmatched == 0 ? 'Dive log: matched' : 'Dive log: not matched';
  }
  return unmatched == 0
      ? 'Dive logs: all $files matched'
      : unmatched == files
      ? 'Dive logs: none of $files matched'
      : 'Dive logs: $unmatched of $files not matched';
}

/// How many dives [diveMatchText] names before "and N more".
const diveMatchesShown = 3;

/// "Dive log: 2026-10-29 11:20 (521 Arild.fit)", with the files that
/// match none counted after it; empty without a file.
String diveMatchText(DiveMatches matches) {
  final (rows: _, :dives, :files, :unmatched) = matches;
  if (files == 0) {
    return '';
  }
  if (dives.isEmpty) {
    return files == 1
        ? 'No dive log matches this file'
        : 'No dive log matches these $files files';
  }
  final names = [
    for (final dive in dives.take(diveMatchesShown)) diveLabel(dive),
  ];
  final more = dives.length - names.length;
  final matched =
      '${dives.length == 1 ? 'Dive log' : '${dives.length} dive logs'}: '
      '${names.join(', ')}${more > 0 ? ' and $more more' : ''}';
  return unmatched == 0
      ? matched
      : '$matched. $unmatched of $files files match no dive log.';
}
