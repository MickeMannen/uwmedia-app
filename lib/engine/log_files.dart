/// Dive log files on disk (Python `backends/log_viewer_backend.py`'s
/// `read_logs` and `log_files_in`): the logs of a folder, and every dive
/// of a set of files with a warning per file that gave none.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';

/// The dives read and the warnings, one per file that could not be read
/// or held no dives.
typedef LogRead = ({List<Dive> dives, List<String> warnings});

/// What one file gave: its dives (none for a log without dives), `null`
/// for a file that is no log the app reads, or why it could not be read
/// ([reason] as a warning says it, [raw] the error as it stands).
typedef FileDives = ({List<Dive>? dives, String? reason, String? raw});

/// The dives of the log at [path], each knowing its file; [tanks] names
/// the tank sensors.
FileDives parseLogFileAt(String path, TankConfig tanks) {
  final List<Dive>? found;
  try {
    found = parseLogFile(path, File(path).readAsBytesSync(), tanks: tanks);
  } on Object catch (e) {
    return (dives: null, reason: _reason(e), raw: '$e');
  }
  if (found != null) {
    final name = p.basename(path);
    for (final dive in found) {
      if ((dive.logPath ?? '').isEmpty) {
        dive.logPath = path;
      }
      if ((dive.logFilename ?? '').isEmpty) {
        dive.logFilename = name;
      }
    }
  }
  return (dives: found, reason: null, raw: null);
}

/// What the files at [paths] gave, as [readLogs] says it: every dive, and
/// a warning per file that could not be read or held no dives.
LogRead logReadOf(List<String> paths, List<FileDives> files) {
  final dives = <Dive>[];
  final warnings = <String>[];
  for (final (i, file) in files.indexed) {
    final name = p.basename(paths[i]);
    final found = file.dives;
    if (file.reason != null) {
      warnings.add('$name: could not be read (${file.reason})');
    } else if (found == null) {
      warnings.add('$name: not a dive log UWMedia reads');
    } else if (found.isEmpty) {
      warnings.add('$name: no dives in the file');
    } else {
      dives.addAll(found);
    }
  }
  return (dives: dives, warnings: warnings);
}

/// Every dive of the files at [paths], each knowing its file; [tanks]
/// names the tank sensors.
LogRead readLogs(List<String> paths, TankConfig tanks) =>
    logReadOf(paths, [for (final path in paths) parseLogFileAt(path, tanks)]);

String _reason(Object e) => switch (e) {
  FormatException(:final message) => message,
  FileSystemException(:final message, :final osError) =>
    osError == null ? message : '$message: ${osError.message}',
  _ => '$e',
};

/// The log files of [folder] (not its subfolders, not hidden files), by
/// name whatever the case.
List<String> logFilesIn(String folder) {
  final found = <String>[];
  for (final entry in Directory(folder).listSync()) {
    final name = p.basename(entry.path);
    if (entry is! File || name.startsWith('.')) {
      continue;
    }
    if (isLogFile(entry.path, _head(entry))) {
      found.add(entry.path);
    }
  }
  return found..sort(
    (a, b) =>
        p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()),
  );
}

// The first bytes of a file, which tell an XML or CSV log from others.
Uint8List _head(File file) {
  try {
    final handle = file.openSync();
    try {
      return handle.readSync(logHeadSize);
    } finally {
      handle.closeSync();
    }
  } on FileSystemException {
    return Uint8List(0);
  }
}
