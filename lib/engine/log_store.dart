/// The dive logs kept in the app on a phone (spec §12.3): a phone has no
/// logs folder to point at, so picked logs are copied into the app's data
/// folder and the dives read from there. A Garmin "Export Original" zip is
/// unpacked to the logs inside it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/model/dive_manager.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/engine/log_files.dart';

/// The folder under the data folder that holds the logs.
const logStoreFolder = 'dive_logs';

/// What an import did: the logs kept, and the files that were not.
typedef LogImport = ({List<String> kept, List<String> refused});

/// What [done] says to the user: how many logs were kept, then each
/// refusal.
String importSummary(LogImport done) =>
    ['Kept ${done.kept.length} log(s).', ...done.refused].join(' ');

/// What the Dive Logs page says of one dive of a kept log. [copyOf] is
/// the log that holds the same dive when this one is its copy, which no
/// run takes ([DiveManager.addDives]).
typedef DiveSummary = ({
  String file,
  DateTime start,
  int seconds,
  double maxDepth,
  String device,
  String? copyOf,
});

/// The dives of the kept logs as the page lists them, with a warning per
/// file that gave none.
typedef LogSummaries = ({List<DiveSummary> dives, List<String> warnings});

/// The file in the logs folder that remembers each log's dives (hidden,
/// so that it is no log itself), and the version of what it holds.
const logIndexFile = '.dive_index.json';
const _indexVersion = 2;

class LogStore {
  LogStore(this.folder);

  /// Where the logs are kept (created when needed).
  final Directory folder;

  /// The log files kept, by name.
  List<String> files() =>
      folder.existsSync() ? logFilesIn(folder.path) : <String>[];

  /// Every dive of the kept logs, with a warning per file that gave none
  /// (see [readLogs]).
  LogRead dives(TankConfig tanks) => readLogs(files(), tanks);

  /// The dives of the kept logs for the page's list. A log is parsed
  /// once: what the list says of it is remembered in [logIndexFile] with
  /// the file's size and time, and read from there until the file changes.
  LogSummaries summaries(TankConfig tanks) {
    final known = _readIndex();
    final index = <String, dynamic>{};
    final dives = <DiveSummary>[];
    final copies = <DiveCopy>[];
    final warnings = <String>[];
    var changed = false;
    for (final path in files()) {
      final name = p.basename(path);
      final FileStat stat = File(path).statSync();
      final modified = stat.modified.millisecondsSinceEpoch;
      var entry = known[name];
      if (entry is! Map<String, dynamic> ||
          entry['size'] != stat.size ||
          entry['modified'] != modified ||
          entry['dives'] is! List<dynamic>) {
        final read = readLogs([path], tanks);
        entry = {
          'size': stat.size,
          'modified': modified,
          'dives': [
            for (final dive in read.dives)
              {
                'start': formatNaive(dive.startTime),
                'seconds': dive.duration,
                'max_depth': dive.maxDepth,
                'device': dive.device ?? '',
                'format': dive.logFormat,
                'maker': dive.manufactor,
                'samples': dive.waypoints.length,
              },
          ],
          if (read.warnings.isNotEmpty) 'warning': read.warnings.first,
        };
        changed = true;
      }
      index[name] = entry;
      try {
        final found = [
          for (final dive in entry['dives'] as List<dynamic>)
            (
              file: name,
              start: parseNaive(
                (dive as Map<String, dynamic>)['start'] as String,
              ),
              seconds: dive['seconds'] as int,
              maxDepth: (dive['max_depth'] as num).toDouble(),
              device: dive['device'] as String,
              copyOf: null,
            ),
        ];
        final foundCopies = [
          for (final (i, dive) in (entry['dives'] as List<dynamic>).indexed)
            (
              start: found[i].start,
              logFormat: (dive as Map<String, dynamic>)['format'] as String?,
              logPath: path,
              manufactor: dive['maker'] as String?,
              samples: dive['samples'] as int,
            ),
        ];
        dives.addAll(found);
        copies.addAll(foundCopies);
        if (entry['warning'] case final String warning) {
          warnings.add(warning);
        }
      } on Object {
        // A damaged entry: read again the next time.
        index.remove(name);
        changed = true;
      }
    }
    if (changed || index.length != known.length) {
      _writeIndex(index);
    }
    return (dives: _copiesMarked(dives, copies), warnings: warnings);
  }

  // The same dive in two logs is one dive: the copy a run would not take
  // says which log holds the dive, by the steps of DiveManager.addDives.
  static List<DiveSummary> _copiesMarked(
    List<DiveSummary> dives,
    List<DiveCopy> copies,
  ) {
    final held = <(DateTime, int), int>{};
    final keptAs = <int, int>{};
    for (final i in Iterable<int>.generate(dives.length)) {
      final same = held.entries
          .where((e) => isSameDive(copies[i], copies[e.value]))
          .firstOrNull;
      if (same != null) {
        if (isPoorerCopy(copies[i], copies[same.value])) {
          keptAs[i] = same.value;
          continue;
        }
        held.remove(same.key);
        keptAs[same.value] = i;
      }
      final key = (dives[i].start, dives[i].seconds);
      if (held[key] case final replaced?) {
        keptAs[replaced] = i;
      }
      held[key] = i;
    }
    int kept(int i) => keptAs[i] == null ? i : kept(keptAs[i]!);
    return [
      for (final (i, dive) in dives.indexed)
        keptAs.containsKey(i)
            ? (
                file: dive.file,
                start: dive.start,
                seconds: dive.seconds,
                maxDepth: dive.maxDepth,
                device: dive.device,
                copyOf: dives[kept(i)].file,
              )
            : dive,
    ];
  }

  File get _indexFile => File(p.join(folder.path, logIndexFile));

  Map<String, dynamic> _readIndex() {
    try {
      final json = jsonDecode(_indexFile.readAsStringSync());
      if (json is Map<String, dynamic> &&
          json['version'] == _indexVersion &&
          json['logs'] is Map<String, dynamic>) {
        return json['logs'] as Map<String, dynamic>;
      }
    } on Object {
      // None yet, or damaged: every log is read.
    }
    return {};
  }

  // Remembering is a help only: a folder that cannot be written to means
  // the logs are read each time.
  void _writeIndex(Map<String, dynamic> logs) {
    try {
      final fresh = File('${_indexFile.path}.new')
        ..writeAsStringSync(
          jsonEncode({'version': _indexVersion, 'logs': logs}),
          flush: true,
        );
      fresh.renameSync(_indexFile.path);
    } on FileSystemException {
      return;
    }
  }

  /// The logs among [paths] copied in (a zip's logs unpacked); a file of
  /// the same name is replaced.
  LogImport import(List<String> paths) {
    folder.createSync(recursive: true);
    final kept = <String>[];
    final refused = <String>[];
    for (final path in paths) {
      final name = p.basename(path);
      try {
        if (p.extension(name).toLowerCase() == '.zip') {
          final inside = _unzip(path);
          if (inside.isEmpty) {
            refused.add('$name: no dive logs in the zip');
          }
          kept.addAll(inside);
        } else {
          final bytes = File(path).readAsBytesSync();
          if (!isLogFile(name, bytes)) {
            refused.add('$name: not a dive log UWMedia reads');
            continue;
          }
          kept.add(_keep(_logName(name, bytes), bytes));
        }
      } on FileSystemException catch (e) {
        refused.add('$name: ${e.message}');
      } on FormatException catch (e) {
        refused.add('$name: ${e.message}');
      }
    }
    return (kept: kept, refused: refused);
  }

  List<String> _unzip(String path) {
    final bytes = File(path).readAsBytesSync();
    if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4B) {
      throw const FormatException('not a zip file');
    }
    final kept = <String>[];
    for (final entry in ZipDecoder().decodeBytes(bytes).files) {
      final name = p.posix.basename(entry.name.replaceAll(r'\', '/'));
      if (!entry.isFile || name.isEmpty || name.startsWith('.')) {
        continue;
      }
      final content = entry.content;
      if (isLogFile(name, content)) {
        kept.add(_keep(_logName(name, content), content));
      }
    }
    return kept;
  }

  // A FIT log under another name ("Dive.bin" from Chrome on Android) kept
  // as "Dive.fit" (spec §10.90).
  // "Dive.fit.bin" as "Dive.fit".
  static String _logName(String name, List<int> bytes) {
    if (pySuffix(name).toLowerCase() == '.fit' || !isFitHeader(bytes)) {
      return name;
    }
    final stem = p.withoutExtension(name);
    return pySuffix(stem).toLowerCase() == '.fit' ? stem : '$stem.fit';
  }

  String _keep(String name, List<int> bytes) {
    final target = p.join(folder.path, name);
    final fresh = File('$target.new')..writeAsBytesSync(bytes, flush: true);
    fresh.renameSync(target);
    return name;
  }

  /// The kept log [name] removed; false when there was none.
  bool remove(String name) {
    final file = File(p.join(folder.path, p.basename(name)));
    if (!file.existsSync()) {
      return false;
    }
    file.deleteSync();
    return true;
  }
}
