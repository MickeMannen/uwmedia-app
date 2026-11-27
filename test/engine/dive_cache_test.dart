// The app's cache of read dive logs (spec §10.106): a log is parsed once,
// again only when its file or the tank names change, and the logs used
// longest ago are let go past the limit.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/engine/desktop/color_batch.dart';
import 'package:uwmedia_app/engine/dive_cache.dart';
import 'package:uwmedia_app/engine/log_files.dart';

final Map<String, dynamic> _sources =
    (jsonDecode(
          utf8.decode(
            gzip.decode(
              File(
                'test/fixtures/python_reference/dives/'
                'fit_edit_cases.json.gz',
              ).readAsBytesSync(),
            ),
          ),
        ) as Map<String, dynamic>)['sources']
        as Map<String, dynamic>;

// A dive of [samples] waypoints, as a parser would give for [path].
Dive _dive(String path, int samples) => Dive(
  startTime: naive(2026, 11, 25, 10),
  endTime: naive(2026, 11, 25, 11),
  logPath: path,
  logFilename: p.basename(path),
  waypoints: [
    for (var i = 0; i < samples; i++)
      Waypoint(timestamp: naive(2026, 11, 25, 10, 0, i), timeSinceStart: i),
  ],
);

void main() {
  late Directory tmp;
  // The files the parser was asked for, in the order asked.
  late List<String> parsed;
  // Files that cannot be read, and files that are no logs.
  late Set<String> broken;
  late Set<String> noLogs;

  // A file's text is how many samples its dive has.
  Future<List<FileDives>> parser(List<String> paths, TankConfig tanks) async {
    parsed.addAll(paths.map(p.basename));
    return [
      for (final path in paths)
        if (broken.contains(p.basename(path)))
          (dives: null, reason: 'busy', raw: 'Error: busy')
        else if (noLogs.contains(p.basename(path)))
          (dives: null, reason: null, raw: null)
        else
          (
            dives: [_dive(path, int.parse(File(path).readAsStringSync()))],
            reason: null,
            raw: null,
          ),
    ];
  }

  String file(String name, int samples) {
    final path = p.join(tmp.path, name);
    File(path).writeAsStringSync('$samples');
    return path;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dive_cache');
    parsed = [];
    broken = {};
    noLogs = {};
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test(
    'a log is parsed once; a new one alone is parsed when it comes',
    () async {
      final cache = DiveCache(maxWaypoints: 1000, parser: parser, workers: 2);
      final a = file('a.fit', 10);
      final b = file('b.fit', 20);
      final first = await cache.files([a, b], TankConfig());
      expect(parsed..sort(), ['a.fit', 'b.fit']);
      expect(first.map((f) => f.dives!.single.waypoints.length), [10, 20]);
      expect(cache.heldWaypoints, 30);

      parsed.clear();
      final c = file('c.fit', 5);
      final again = await cache.files([c, b, a], TankConfig());
      expect(parsed, ['c.fit'], reason: 'the known ones are not parsed again');
      expect(identical(again[1].dives, first[1].dives), isTrue);
      expect(identical(again[2].dives, first[0].dives), isTrue);
      expect(cache.heldFiles, 3);

      // As readLogs says it.
      final read = await cache.read([a, b, c], TankConfig());
      expect(read.dives.map((d) => d.logFilename), ['a.fit', 'b.fit', 'c.fit']);
      expect(read.warnings, isEmpty);
      cache.clear();
      expect(cache.heldFiles, 0);
    },
  );

  test('a changed file, or other tank names, is read again', () async {
    final cache = DiveCache(maxWaypoints: 1000, parser: parser);
    final a = file('a.fit', 10);
    final b = file('b.fit', 20);
    await cache.files([a, b], TankConfig());
    parsed.clear();

    File(a).writeAsStringSync('123');
    final changed = await cache.files([a, b], TankConfig());
    expect(parsed, ['a.fit']);
    expect(changed.first.dives!.single.waypoints.length, 123);

    parsed.clear();
    final named = TankConfig({'1': 'Left'});
    await cache.files([a, b], named);
    expect(parsed..sort(), ['a.fit', 'b.fit']);
    parsed.clear();
    await cache.files([a, b], named);
    // The order is the tank order, and the sizes give VSAC.
    await cache.files([a], TankConfig({'1': 'Left'}, {'1': 11.1}));
    expect(parsed, ['a.fit']);
    // A sidemount name or side changes no dive (spec §10.104).
    parsed.clear();
    await cache.files(
      [a],
      TankConfig(
        {'1': 'Left'},
        {'1': 11.1},
        {'1': 'Port'},
        {'1': TankSide.left},
      ),
    );
    expect(parsed, isEmpty);
  });

  test('two readers at once share one parse; a file twice is one', () async {
    final cache = DiveCache(maxWaypoints: 1000, parser: parser);
    final a = file('a.fit', 10);
    final both = await Future.wait([
      cache.files([a, a], TankConfig()),
      cache.files([a], TankConfig()),
    ]);
    expect(parsed, ['a.fit']);
    expect(both[0].length, 2);
    expect(identical(both[0][0].dives, both[1][0].dives), isTrue);
  });

  test('past the limit the logs used longest ago go', () async {
    final cache = DiveCache(maxWaypoints: 100, parser: parser, workers: 1);
    final a = file('a.fit', 40);
    final b = file('b.fit', 40);
    final c = file('c.fit', 40);
    final all = await cache.files([a, b, c], TankConfig());
    expect(all.length, 3, reason: 'the reader has them all the same');
    expect(cache.heldWaypoints, 80);
    parsed.clear();
    await cache.files([b, c], TankConfig());
    expect(parsed, isEmpty);
    await cache.files([a], TankConfig());
    expect(parsed, ['a.fit'], reason: 'the first one was let go');
    // b was used longest ago now.
    parsed.clear();
    await cache.files([c, a], TankConfig());
    expect(parsed, isEmpty);
    await cache.files([b], TankConfig());
    expect(parsed, ['b.fit']);
  });

  test('a file that could not be read is tried again; what is no log is '
      'not', () async {
    final cache = DiveCache(maxWaypoints: 1000, parser: parser);
    final a = file('a.fit', 10);
    final notes = file('notes.txt', 0);
    broken = {'a.fit'};
    noLogs = {'notes.txt'};
    var read = await cache.read([a, notes], TankConfig());
    expect(read.dives, isEmpty);
    expect(read.warnings, [
      'a.fit: could not be read (busy)',
      'notes.txt: not a dive log UWMedia reads',
    ]);
    parsed.clear();
    broken = {};
    read = await cache.read([a, notes], TankConfig());
    expect(parsed, ['a.fit']);
    expect(read.dives.single.logFilename, 'a.fit');

    // A parser that fails altogether: a warning per file, nothing kept.
    final failing = DiveCache(
      parser: (paths, tanks) async => throw StateError('no isolate'),
    );
    final failed = await failing.read([a], TankConfig());
    expect(failed.warnings.single, contains('could not be read'));
    expect(failing.heldFiles, 0);
  });

  test('real logs, parsed on other isolates: as readLogs gives them, and a '
      'folder\'s dives for a run', () async {
    final paths = <String>[];
    for (final name in ['air', 'nitrox_30_min_later', 'ccr_1_h_later']) {
      final path = p.join(tmp.path, '$name.fit');
      File(path).writeAsBytesSync(base64.decode(_sources[name] as String));
      paths.add(path);
    }
    paths.add(file('notes.txt', 0));
    final cache = DiveCache(workers: 3);
    final plain = readLogs(paths, TankConfig());
    final read = await cache.read(paths, TankConfig());
    expect(
      [for (final dive in read.dives) jsonEncode(dive.toJson())],
      [for (final dive in plain.dives) jsonEncode(dive.toJson())],
    );
    expect(read.dives, isNotEmpty);
    expect(read.warnings, plain.warnings);
    final again = await cache.read(paths, TankConfig());
    expect(identical(again.dives.first, read.dives.first), isTrue);

    // A run's dives of the folder (the app's own cache): the same dives
    // the second time, the logs not parsed again.
    final loaded = await loadDiveLogsOffThread(tmp.path, TankConfig());
    final expected = loadDiveLogs(tmp.path, TankConfig());
    expect(
      [for (final dive in loaded.dives) jsonEncode(dive.toJson())],
      [for (final dive in expected.dives) jsonEncode(dive.toJson())],
    );
    expect(loaded.messages, expected.messages);
    final second = await loadDiveLogsOffThread(tmp.path, TankConfig());
    expect(identical(second.dives.first, loaded.dives.first), isTrue);
  });
}
