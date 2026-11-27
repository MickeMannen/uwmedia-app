/// The dives of the log files the app has read, kept for every page (spec
/// §10.106): a log is parsed once, and read again only when its file or
/// the tank names it was read with change.
///
/// Parsing is what takes the time (the samples, the deco pass), and each
/// page that offers the kept logs used to parse them all for itself. Here
/// the files not yet known are parsed on other isolates, several at once,
/// and what they gave is kept by file up to [DiveCache.maxWaypoints]
/// samples; past that the logs used longest ago are let go and parsed
/// again when asked for.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/engine/app_log.dart';
import 'package:uwmedia_app/engine/log_files.dart';

/// Parses the files at the paths, in their order; by default on another
/// isolate.
typedef FilesParser = Future<List<FileDives>> Function(
  List<String> paths,
  TankConfig tanks,
);

// A top-level function, so that the closure sent to the isolate holds the
// paths and the tank names only.
Future<List<FileDives>> _parseOnIsolate(List<String> paths, TankConfig tanks) =>
    Isolate.run(() => [for (final path in paths) parseLogFileAt(path, tanks)]);

/// How many samples the app's cache keeps: some 280 hour-long dives
/// logged every second on a computer, half of that on a phone. It was a
/// fifth of this, and a diver's 120 logs were past it: the logs let go
/// were parsed again for every run and every pick (three to seven seconds
/// each time, owner 2026-11-27), and nothing was saved by it, as the Color
/// page holds every dive it was given (spec §10.115).
int get defaultMaxWaypoints =>
    Platform.isIOS || Platform.isAndroid ? 500000 : 1000000;

/// The cache every page reads its logs through.
final DiveCache diveCache = DiveCache();

class DiveCache {
  DiveCache({int? maxWaypoints, this.parser = _parseOnIsolate, int? workers})
    : maxWaypoints = maxWaypoints ?? defaultMaxWaypoints,
      workers =
          workers ?? math.max(1, math.min(4, Platform.numberOfProcessors - 1));

  /// The samples kept at most; the logs used longest ago go first.
  final int maxWaypoints;

  /// How many isolates parse at once.
  final int workers;
  final FilesParser parser;

  final Map<String, _Entry> _entries = {};
  int _clock = 0;

  /// The samples kept now.
  int get heldWaypoints =>
      _entries.values.fold(0, (sum, entry) => sum + entry.waypoints);

  /// The files kept now (or being parsed).
  int get heldFiles => _entries.length;

  /// Forgets everything.
  void clear() => _entries.clear();

  /// What each of the files at [paths] gives, in their order: from the
  /// cache where the file and [tanks] are as they were when it was read,
  /// parsed otherwise. The dives are shared with every other reader: they
  /// are not to be changed.
  Future<List<FileDives>> files(List<String> paths, TankConfig tanks) async {
    final tankMark = _tankMark(tanks);
    final wanted = <Future<FileDives>>[];
    final missing = <String, Completer<FileDives>>{};
    for (final path in paths) {
      final mark = '${_fileMark(path)}\n$tankMark';
      var entry = _entries[path];
      if (entry == null || entry.mark != mark) {
        // The same file twice in one request is parsed once.
        final completer = missing[path] ??= Completer<FileDives>();
        entry = _entries[path] = _Entry(mark, completer.future);
      }
      entry.used = ++_clock;
      wanted.add(entry.result);
    }
    if (missing.isNotEmpty) {
      _parse(missing, tanks);
    }
    final results = await Future.wait(wanted);
    _trim();
    return results;
  }

  /// Every dive of the files at [paths] with a warning per file that gave
  /// none, as [readLogs] gives them.
  Future<LogRead> read(List<String> paths, TankConfig tanks) async =>
      logReadOf(paths, await files(paths, tanks));

  // Parses the missing files, shared out over the isolates; each file's
  // result goes to whoever waits for it.
  void _parse(Map<String, Completer<FileDives>> missing, TankConfig tanks) {
    final paths = missing.keys.toList();
    final shares = math.min(workers, paths.length);
    for (var share = 0; share < shares; share++) {
      final mine = [
        for (var i = share; i < paths.length; i += shares) paths[i],
      ];
      unawaited(
        AppLog.timed(
          'Dive Logs',
          'Reading ${mine.length} dive log${mine.length == 1 ? '' : 's'}',
          () => parser(mine, tanks),
          slowMs: 1000,
        ).then<void>(
          (results) {
            for (final (i, path) in mine.indexed) {
              final result = results[i];
              final entry = _entries[path];
              if (entry != null &&
                  identical(entry.result, missing[path]!.future)) {
                if (result.reason != null) {
                  // A file that could not be read is tried again next
                  // time: it may only have been busy.
                  _entries.remove(path);
                } else {
                  entry.waypoints = (result.dives ?? const []).fold(
                    0,
                    (sum, dive) => sum + dive.waypoints.length,
                  );
                }
              }
              missing[path]!.complete(result);
            }
          },
          onError: (Object e) {
            for (final path in mine) {
              if (identical(_entries[path]?.result, missing[path]!.future)) {
                _entries.remove(path);
              }
              missing[path]!.complete((dives: null, reason: '$e', raw: '$e'));
            }
          },
        ),
      );
    }
  }

  // Lets the logs used longest ago go until the rest is within the limit.
  void _trim() {
    var held = heldWaypoints;
    if (held <= maxWaypoints) {
      return;
    }
    final oldestFirst = _entries.entries.toList()
      ..sort((a, b) => a.value.used.compareTo(b.value.used));
    for (final MapEntry(key: path, value: entry) in oldestFirst) {
      if (held <= maxWaypoints) {
        break;
      }
      if (entry.waypoints > 0) {
        held -= entry.waypoints;
        _entries.remove(path);
      }
    }
  }

  // What a file's dives depend on: its size and time (a file that is gone
  // or cannot be looked at has a mark of its own).
  static String _fileMark(String path) {
    try {
      final stat = File(path).statSync();
      return '${stat.type}\t${stat.size}\t'
          '${stat.modified.microsecondsSinceEpoch}';
    } on FileSystemException {
      return 'gone';
    }
  }

  // The tank names in their order (it is the tank order) and the sizes:
  // what a log is read with (spec §4.1, §10.54).
  static String _tankMark(TankConfig tanks) => [
    for (final MapEntry(:key, :value) in tanks.tanks.entries)
      'tank $key=$value',
    for (final MapEntry(:key, :value) in tanks.sizes.entries)
      'size $key=$value',
  ].join('\n');
}

class _Entry {
  _Entry(this.mark, this.result);

  final String mark;
  final Future<FileDives> result;

  /// The samples of its dives, once parsed.
  int waypoints = 0;

  /// When it was last asked for.
  int used = 0;
}
