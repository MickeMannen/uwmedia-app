/// The app's log (spec §10.76): what the runs said and what went wrong,
/// kept in a file in the cache folder so that a problem can be reported
/// after it happened (the About page's "Report a problem"). It holds file
/// names and messages, no pictures, and leaves the machine only when the
/// user sends a report.
library;

import 'dart:io';

import 'package:uwmedia_app/core/diagnostics/report.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

/// The log's file in the cache folder.
const appLogFilename = 'uwmedia.log';

/// The size at which the log starts anew at the next start; the one
/// before is kept beside it.
const appLogMaxBytes = 512 * 1024;

class AppLog {
  AppLog(this.file, {DateTime Function()? now}) : _now = now ?? naiveNow {
    try {
      file.parent.createSync(recursive: true);
      if (file.existsSync() && file.lengthSync() > appLogMaxBytes) {
        file.renameSync('${file.path}.1');
      }
    } on FileSystemException {
      // No log then; the app goes on.
    }
  }

  /// The running app's log; `null` in tests and before it is set up.
  static AppLog? instance;

  /// A line into the running app's log, when there is one.
  static void note(String source, String text) => instance?.add(source, text);

  final File file;
  final DateTime Function() _now;

  void add(String source, String text) {
    if (text.trim().isEmpty) {
      return;
    }
    try {
      file.writeAsStringSync(
        '${logLine(_now(), source, text)}\n',
        mode: FileMode.append,
      );
    } on FileSystemException {
      // A full disk must not stop a run.
    }
  }

  /// The last [lines] lines, the kept older file first when this one is
  /// short of them.
  List<String> tail([int lines = reportLogLines]) {
    final all = <String>[];
    for (final part in [File('${file.path}.1'), file]) {
      try {
        if (part.existsSync()) {
          all.addAll(part.readAsLinesSync().where((line) => line.isNotEmpty));
        }
      } on FileSystemException {
        // Unreadable: without it.
      }
    }
    return all.length > lines ? all.sublist(all.length - lines) : all;
  }
}
