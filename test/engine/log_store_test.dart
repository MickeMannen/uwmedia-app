// The phones' log store (lib/engine/log_store.dart) and Dive Logs page:
// logs picked (a Garmin "Export Original" zip among them, built here from
// the FIT edit fixture's invented logs) kept in the app's data folder,
// what is no log refused, the dives listed, a log removed.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/model/dive_manager.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/engine/app_log.dart';
import 'package:uwmedia_app/engine/desktop/color_batch.dart';
import 'package:uwmedia_app/engine/log_files.dart';
import 'package:uwmedia_app/engine/log_store.dart';
import 'package:uwmedia_app/pages/dive_logs/dive_logs_page.dart';
import 'package:uwmedia_app/pages/shared/logs_folder.dart';

final Map<String, dynamic> _sources =
    (jsonDecode(
          utf8.decode(
            gzip.decode(
              File(
                'test/fixtures/python_reference/dives/fit_edit_cases.json.gz',
              ).readAsBytesSync(),
            ),
          ),
        ) as Map<String, dynamic>)['sources']
        as Map<String, dynamic>;

List<int> _fit(String name) => base64.decode(_sources[name] as String);

class FakeDialogs implements DiveLogsDialogs {
  List<String> picked = [];

  @override
  Future<List<String>> pickLogs() async => picked;
}

void main() {
  late Directory tmp;
  late Directory picked;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('uwmedia_logstore_');
    picked = Directory(p.join(tmp.path, 'picked'))..createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String file(String name, List<int> bytes) {
    final path = p.join(picked.path, name);
    File(path).writeAsBytesSync(bytes);
    return path;
  }

  String garminZip() {
    final archive = Archive();
    final fit = _fit('nitrox_30_min_later');
    archive
      ..addFile(ArchiveFile('123456_ACTIVITY.fit', fit.length, fit))
      ..addFile(ArchiveFile('readme.txt', 2, [104, 105]));
    return file('activity_123456.zip', ZipEncoder().encode(archive));
  }

  test('import, list, remove', () {
    final store = LogStore(Directory(p.join(tmp.path, 'data', logStoreFolder)));
    expect(store.files(), isEmpty);
    final done = store.import([
      file('air.FIT', _fit('air')),
      garminZip(),
      file('notes.txt', utf8.encode('hello')),
      file('empty.zip', ZipEncoder().encode(Archive())),
    ]);
    expect(done.kept, ['air.FIT', '123456_ACTIVITY.fit']);
    expect(done.refused, [
      'notes.txt: not a dive log UWMedia reads',
      'empty.zip: no dive logs in the zip',
    ]);
    expect(
      store.files().map(p.basename),
      unorderedEquals(['air.FIT', '123456_ACTIVITY.fit']),
    );
    final read = store.dives(TankConfig());
    expect(read.dives, hasLength(2));
    expect(store.remove('air.FIT'), isTrue);
    expect(store.remove('air.FIT'), isFalse);
    expect(store.files().map(p.basename), ['123456_ACTIVITY.fit']);
  });

  test('a FIT log saved as .bin is known by its header and kept as .fit '
      '(spec §10.90: Chrome on Android)', () {
    final store = LogStore(Directory(p.join(tmp.path, 'data', logStoreFolder)));
    final archive = Archive();
    final fit = _fit('nitrox_30_min_later');
    archive.addFile(ArchiveFile('123456_ACTIVITY.bin', fit.length, fit));
    final done = store.import([
      file('air.bin', _fit('air')),
      file('Dive (1).fit.bin', _fit('air')),
      file('activity_123456.zip', ZipEncoder().encode(archive)),
      // Not FIT inside: still refused.
      file('firmware.bin', List<int>.generate(64, (i) => i)),
    ]);
    expect(done.kept, ['air.fit', 'Dive (1).fit', '123456_ACTIVITY.fit']);
    expect(done.refused, ['firmware.bin: not a dive log UWMedia reads']);
    expect(
      store.files().map(p.basename),
      unorderedEquals(['air.fit', 'Dive (1).fit', '123456_ACTIVITY.fit']),
    );
    expect(store.dives(TankConfig()).dives, hasLength(3));
    // A folder's .bin FIT log is listed with the logs too.
    expect(
      logFilesIn(picked.path).map(p.basename),
      unorderedEquals(['air.bin', 'Dive (1).fit.bin']),
    );
    expect(isFitHeader(_fit('air')), isTrue);
    expect(isFitHeader(utf8.encode('<?xml version="1.0"?>')), isFalse);
  });

  test('imports and removals go into the app\'s log', () async {
    final log = AppLog.instance = AppLog(File(p.join(tmp.path, 'app.log')));
    addTearDown(() => AppLog.instance = null);
    final store = LogStore(Directory(p.join(tmp.path, 'kept')));
    final c = DiveLogsController(store: store, tanks: TankConfig.new);
    await c.import([
      garminZip(),
      file('notes.txt', [104]),
    ]);
    await c.remove('123456_ACTIVITY.fit');
    expect(log.tail().map((l) => l.substring(20)), [
      '[Dive Logs] activity_123456.zip, notes.txt: Kept 1 log(s). '
          'notes.txt: not a dive log UWMedia reads',
      '[Dive Logs] Removed 123456_ACTIVITY.fit.',
    ]);
  });

  test(
    'dropped on the page: files, a folder\'s logs, or nothing usable',
    () async {
      final store = LogStore(Directory(p.join(tmp.path, 'kept')));
      final c = DiveLogsController(store: store, tanks: TankConfig.new);
      final folder = Directory(p.join(tmp.path, 'trip'))..createSync();
      File(p.join(folder.path, 'air.fit')).writeAsBytesSync(_fit('air'));
      File(p.join(folder.path, 'notes.txt')).writeAsStringSync('hi');
      Directory(p.join(folder.path, 'old')).createSync();
      File(p.join(folder.path, 'old', 'deep.fit'))
          .writeAsBytesSync(_fit('air'));
      await c.drop([folder.path, garminZip()]);
      expect(c.status, 'Kept 2 log(s).');
      expect(
        store.files().map(p.basename),
        unorderedEquals(['air.fit', '123456_ACTIVITY.fit']),
      );
      final empty = Directory(p.join(tmp.path, 'empty'))..createSync();
      await c.drop([empty.path]);
      expect(c.status, 'No dive logs among what was dropped.');
      await c.drop([
        file('notes.txt', [104]),
      ]);
      expect(
        c.status,
        'Kept 0 log(s). notes.txt: not a dive log UWMedia reads',
      );
      c.dispose();
    },
  );

  test('the list of dives is remembered: a log is parsed once', () {
    final store = LogStore(Directory(p.join(tmp.path, 'data', logStoreFolder)));
    expect(store.summaries(TankConfig()).dives, isEmpty);
    store.import([file('air.FIT', _fit('air')), garminZip()]);
    final first = store.summaries(TankConfig());
    final parsed = store.dives(TankConfig()).dives;
    expect(first.dives.map((d) => d.file), ['123456_ACTIVITY.fit', 'air.FIT']);
    expect(first.warnings, isEmpty);
    for (final (i, dive) in parsed.indexed) {
      expect(first.dives[i].start, dive.startTime);
      expect(first.dives[i].seconds, dive.duration);
      expect(first.dives[i].maxDepth, dive.maxDepth);
      expect(first.dives[i].device, dive.device ?? '');
    }
    // The index is no log, and the next list comes from it: what it says
    // is what is listed.
    final index = File(p.join(store.folder.path, logIndexFile));
    expect(store.files().map(p.basename), isNot(contains(logIndexFile)));
    final kept = jsonDecode(index.readAsStringSync()) as Map<String, dynamic>;
    final logs = kept['logs'] as Map<String, dynamic>;
    final air = logs['air.FIT'] as Map<String, dynamic>;
    ((air['dives'] as List<dynamic>).first as Map<String, dynamic>)['device'] =
        'from the index';
    index.writeAsStringSync(jsonEncode(kept));
    expect(store.summaries(TankConfig()).dives.last.device, 'from the index');
    // A log that changed is read again; one removed leaves the index.
    File(p.join(store.folder.path, 'air.FIT'))
        .writeAsBytesSync(_fit('nitrox_30_min_later'));
    final again = store.summaries(TankConfig());
    expect(again.dives.last.device, isNot('from the index'));
    expect(again.dives.last.start, again.dives.first.start);
    store.remove('123456_ACTIVITY.fit');
    expect(store.summaries(TankConfig()).dives, hasLength(1));
    expect(index.readAsStringSync(), isNot(contains('123456_ACTIVITY')));
    // A file that is no log gives its warning each time, from the index
    // too; a damaged index means only that the logs are read.
    File(p.join(store.folder.path, 'broken.fit'))
        .writeAsBytesSync(_fit('air').sublist(0, 200));
    final warned = store.summaries(TankConfig()).warnings;
    expect(store.summaries(TankConfig()).warnings, warned);
    index.writeAsStringSync('not json');
    expect(store.summaries(TankConfig()).dives, hasLength(1));
  });

  test('the same dive under another file name is listed once', () {
    final store = LogStore(Directory(p.join(tmp.path, 'data', logStoreFolder)));
    store.import([
      file('air.FIT', _fit('air')),
      file('air (1).FIT', _fit('air')),
      file('later.FIT', _fit('nitrox_30_min_later')),
    ]);
    final listed = store.summaries(TankConfig()).dives;
    expect(listed, hasLength(3));
    // The one a run takes is the one listed as the dive; the other says
    // where the dive is.
    final manager = DiveManager()..addDives(store.dives(TankConfig()).dives);
    expect(manager.dives, hasLength(2));
    final taken = {
      for (final dive in manager.dives.values) p.basename(dive.logPath!),
    };
    expect({
      for (final dive in listed)
        if (dive.copyOf == null) dive.file,
    }, taken);
    final copy = listed.singleWhere((dive) => dive.copyOf != null);
    expect({copy.file, copy.copyOf}, {'air.FIT', 'air (1).FIT'});
    expect(taken, contains(copy.copyOf));
    // From the index too, and gone with the log that held the dive.
    expect(store.summaries(TankConfig()).dives, listed);
    store.remove(copy.copyOf!);
    expect(store.summaries(TankConfig()).dives.map((dive) => dive.copyOf), [
      null,
      null,
    ]);
  });

  test('a run reads the kept logs and the logs folder together', () async {
    final store = LogStore(Directory(p.join(tmp.path, 'data', 'dive_logs')));
    // Nothing kept yet and no folder: no dives, and no complaint.
    var read = await loadDiveSources(TankConfig(), kept: store.folder.path);
    expect(read.dives, isEmpty);

    store.import([garminZip()]);
    read = await loadDiveSources(
      TankConfig(),
      kept: store.folder.path,
      folder: '  ',
    );
    expect(read.dives, hasLength(1));

    // The same dive in the folder too: read twice, held once.
    final folder = Directory(p.join(tmp.path, 'logs'))..createSync();
    File(p.join(folder.path, 'same.fit'))
        .writeAsBytesSync(_fit('nitrox_30_min_later'));
    read = await loadDiveSources(
      TankConfig(),
      kept: store.folder.path,
      folder: folder.path,
    );
    expect(read.dives, hasLength(2));
    expect((DiveManager()..addDives(read.dives)).dives, hasLength(1));

    // A folder that is set and not there is said, kept logs or not.
    await expectLater(
      loadDiveSources(
        TankConfig(),
        kept: store.folder.path,
        folder: p.join(tmp.path, 'gone'),
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('not found'),
        ),
      ),
    );
  });

  test('a run takes the dives the page has read, while the logs are '
      'the same', () async {
    final folder = Directory(p.join(tmp.path, 'logs'))..createSync();
    final log = File(p.join(folder.path, 'dive.fit'))
      ..writeAsBytesSync(_fit('air'));
    final first = await loadDiveLogsOffThread(folder.path, TankConfig());
    expect(first.dives, hasLength(1));
    // Read once: the same dives again.
    expect(
      identical(
        (await loadDiveLogsOffThread(folder.path, TankConfig())).dives,
        first.dives,
      ),
      isTrue,
    );
    // A log changed, added or removed, or other tank names: read again.
    log.writeAsBytesSync(_fit('nitrox_30_min_later'));
    final changed = await loadDiveLogsOffThread(folder.path, TankConfig());
    expect(identical(changed.dives, first.dives), isFalse);
    expect(changed.dives.single.startTime, isNot(first.dives.single.startTime));
    File(p.join(folder.path, 'more.fit')).writeAsBytesSync(_fit('air'));
    final added = await loadDiveLogsOffThread(folder.path, TankConfig());
    expect(added.dives, hasLength(2));
    final named = await loadDiveLogsOffThread(
      folder.path,
      TankConfig({'123': 'Left'}),
    );
    expect(identical(named.dives, added.dives), isFalse);
    File(p.join(folder.path, 'more.fit')).deleteSync();
    expect(
      await loadDiveLogsOffThread(folder.path, TankConfig({'123': 'Left'})),
      isA<LoadedDives>().having((r) => r.dives, 'dives', hasLength(1)),
    );
  });

  testWidgets('the page on a phone: import, list, remove', (tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = AppServices(
      capabilities: const Capabilities(desktop: false),
      config: ConfigStore(() => Directory(p.join(tmp.path, 'config'))),
      home: tmp.path,
      dataDir: () => Directory(p.join(tmp.path, 'data')),
    );
    final dialogs = FakeDialogs()..picked = [garminZip()];
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: DiveLogsPage(services: services, dialogs: dialogs),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(find.text('No dive logs yet.'), findsOneWidget);
    expect(find.text('How to get your logs'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Import logs…'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    expect(find.text('123456_ACTIVITY.fit'), findsOneWidget);
    expect(find.textContaining('Kept 1 log(s).'), findsOneWidget);
    // Under its month, which is open as the newest; the pages that match
    // dives were told.
    expect(find.text('1 dive'), findsOneWidget);
    expect(services.keptLogsRevision.value, 1);
    // The same log under another name: its dive is not listed twice.
    final fit = _fit('nitrox_30_min_later');
    dialogs.picked = [file('again.fit', fit)];
    await tester.runAsync(() async {
      await tester.tap(find.text('Import logs…'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    expect(find.text('1 dive in 2 logs'), findsOneWidget);
    expect(find.textContaining('the same dive as in'), findsOneWidget);
    // Either log removed leaves the dive, listed as a dive.
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Remove this log').first);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('the same dive as in'), findsNothing);
    expect(find.text('1 dive'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Remove this log'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    expect(find.text('No dive logs yet.'), findsOneWidget);
    expect(services.keptLogsRevision.value, 4);
  });

  testWidgets('the desktop: the logs folder of before is offered once', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // A folder the user had set, with a log and something else in it.
    final folder = Directory(p.join(tmp.path, 'my logs'))..createSync();
    File(p.join(folder.path, 'dive.fit'))
        .writeAsBytesSync(_fit('nitrox_30_min_later'));
    File(p.join(folder.path, 'notes.txt')).writeAsStringSync('hi');
    final config = ConfigStore(() => Directory(p.join(tmp.path, 'config')))
      ..setField(diveLogsFolderField, folder.path);
    final services = AppServices(
      capabilities: const Capabilities(desktop: true),
      config: config,
      home: tmp.path,
      dataDir: () => Directory(p.join(tmp.path, 'data')),
    );
    Future<void> show() async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(),
            home: Scaffold(
              body: DiveLogsPage(
                key: UniqueKey(),
                services: services,
                dialogs: FakeDialogs(),
              ),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
    }

    await show();
    expect(find.text('Your dive-logs folder'), findsOneWidget);
    expect(find.textContaining(p.join('~', 'my logs')), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Import its logs'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    // Copied in, the folder and the Python app's field left as they are,
    // and not offered again.
    expect(find.text('dive.fit'), findsOneWidget);
    expect(find.textContaining('Kept 1 log(s).'), findsOneWidget);
    expect(find.text('Your dive-logs folder'), findsNothing);
    expect(File(p.join(folder.path, 'dive.fit')).existsSync(), isTrue);
    expect(config.fields()[diveLogsFolderField], folder.path);
    expect(logsFolderToOffer(config), isNull);
    await show();
    expect(find.text('Your dive-logs folder'), findsNothing);

    // Another folder set (by the Python app): offered, and put away.
    final other = Directory(p.join(tmp.path, 'other'))..createSync();
    config.setField(diveLogsFolderField, other.path);
    await show();
    expect(find.text('Your dive-logs folder'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.text('Your dive-logs folder'), findsNothing);
    // A folder that is gone is not offered.
    config.setField(diveLogsFolderField, p.join(tmp.path, 'gone'));
    expect(logsFolderToOffer(config), isNull);
  });

  testWidgets('the desktop: logs dropped on the page are kept', (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = AppServices(
      capabilities: const Capabilities(desktop: true),
      config: ConfigStore(() => Directory(p.join(tmp.path, 'config'))),
      home: tmp.path,
      dataDir: () => Directory(p.join(tmp.path, 'data')),
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: DiveLogsPage(services: services, dialogs: FakeDialogs()),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    final target = tester.widget<DropTarget>(find.byType(DropTarget));
    expect(target.enable, isTrue);
    await tester.runAsync(() async {
      target.onDragDone!(
        DropDoneDetails(
          files: [DropItemFile(file('air.fit', _fit('air')))],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    expect(find.text('air.fit'), findsOneWidget);
    expect(find.textContaining('Kept 1 log(s).'), findsOneWidget);
    expect(services.keptLogsRevision.value, 1);
  });

  testWidgets('a phone has no drop target', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: DiveLogsPage(
              services: AppServices(
                capabilities: const Capabilities(desktop: false),
                config: ConfigStore(
                  () => Directory(p.join(tmp.path, 'config')),
                ),
                home: tmp.path,
                dataDir: () => Directory(p.join(tmp.path, 'data')),
              ),
              dialogs: FakeDialogs(),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(find.byType(DropTarget), findsNothing);
  });
}
