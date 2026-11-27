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

  // The work under way, by the order it began: what it is and its clock.
  static final _underWay = <int, (String, Stopwatch)>{};
  static int _begun = 0;

  /// [work] is under way until its future ends (spec §10.109): a piece
  /// of the app's own work that reads files, runs a tool or waits for
  /// the system, so that the log can say what was still going when the
  /// app was closed ([underWay]). A line is written when it took
  /// [slowMs] or longer ("... took 1234 ms"); with `null` never, with 0
  /// always. What it gives, or throws, is passed on.
  static Future<T> timed<T>(
    String source,
    String what,
    Future<T> Function() work, {
    int? slowMs = 500,
  }) async {
    final id = _begun++;
    final clock = Stopwatch()..start();
    _underWay[id] = (what, clock);
    var ended = 'took';
    try {
      return await work();
    } on Object {
      ended = 'failed after';
      rethrow;
    } finally {
      _underWay.remove(id);
      final ms = clock.elapsedMilliseconds;
      if (slowMs != null && ms >= slowMs) {
        note(source, '$what $ended $ms ms');
      }
    }
  }

  /// The work under way now, oldest first, each with how long it has
  /// been going: "ffmpeg -version (1234 ms)".
  static List<String> underWay() => [
    for (final (what, clock) in _underWay.values)
      '$what (${clock.elapsedMilliseconds} ms)',
  ];

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
