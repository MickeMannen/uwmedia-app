// The Log Viewer page (lib/pages/log_viewer/, lib/engine/log_files.dart)
// on the invented Garmin FIT logs of the FIT edit fixture, written to a
// temporary folder with a few files that are no logs: reading a folder
// and files (on another isolate too), the list and its warnings, the
// selection, the samples table, Remove and Clear, Adjust time and Merge
// with their errors, and the page on screen.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/engine/log_files.dart';
import 'package:uwmedia_app/pages/log_viewer/dive_charts.dart';
import 'package:uwmedia_app/pages/log_viewer/log_viewer_controller.dart';
import 'package:uwmedia_app/pages/log_viewer/log_viewer_page.dart';
import 'package:uwmedia_app/pages/shared/place_menu.dart';

void main() {
  final sources =
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

  late Directory tmp;
  late Directory logs;
  late ConfigStore config;

  String write(String name, List<int> bytes) {
    final path = p.join(logs.path, name);
    File(path).writeAsBytesSync(bytes);
    return path;
  }

  Future<LogRead> here(List<String> paths, TankConfig tanks) async =>
      readLogs(paths, tanks);

  LogViewerController controller() =>
      LogViewerController(config: config, home: tmp.path, reader: here);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('uwmedia_logs_');
    logs = Directory(p.join(tmp.path, 'logs'))..createSync();
    write(
      'Second.fit',
      base64.decode(sources['nitrox_30_min_later'] as String),
    );
    write('first.fit', base64.decode(sources['air'] as String));
    write('later.FIT', base64.decode(sources['air_3_h_later'] as String));
    write('broken.fit', [14, 16, 1, 2, 3]);
    write('notes.txt', utf8.encode('not a log'));
    write('.hidden.fit', base64.decode(sources['air'] as String));
    config = ConfigStore(() => Directory(p.join(tmp.path, 'config')));
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('the log files of a folder, and reading them', () async {
    expect(
      [for (final f in logFilesIn(logs.path)) p.basename(f)],
      ['broken.fit', 'first.fit', 'later.FIT', 'Second.fit'],
    );
    final read = await readOnIsolate(
      logFilesIn(logs.path),
      config.tankConfig().tanks,
    );
    expect(read.dives.length, 3);
    expect(read.dives.map((d) => d.logFilename), [
      'first.fit',
      'later.FIT',
      'Second.fit',
    ]);
    expect(read.dives.every((d) => d.logFormat == fitFormat), isTrue);
    expect(read.warnings.single, startsWith('broken.fit: '));
    final plain = readLogs([p.join(logs.path, 'notes.txt')], TankConfig());
    expect(plain.warnings, ['notes.txt: not a dive log UWMedia reads']);
  });

  test('the imported logs: a folder whose place is not kept', () async {
    final c = controller();
    final before = c.dialogFolder;
    await c.addFolder(logs.path, remember: false);
    expect(c.diveCount, 3);
    expect(c.dialogFolder, before);
    await c.addFolder(logs.path);
    expect(c.dialogFolder, logs.path);
    c.dispose();
  });

  test('the list: read, sorted, kept once, selected, removed', () async {
    final c = controller();
    expect(c.dialogFolder, tmp.path);
    await c.addFolder(logs.path);
    expect(c.diveCount, 3);
    expect(c.message, 'Added 3 dives.');
    expect(c.files, ['first.fit', 'later.FIT', 'Second.fit']);
    expect(c.warnings.single, startsWith('broken.fit:'));
    expect(c.rows.map((r) => r.file), ['first.fit', 'Second.fit', 'later.FIT']);
    expect(c.currentRow, 0);
    expect(c.selected!.file, 'first.fit');
    expect(c.selected!.format, isNotEmpty);
    expect(c.dialogFolder, logs.path);

    // The same files again: nothing new, the selection stays.
    c.select(1);
    await c.addFiles([p.join(logs.path, 'Second.fit')]);
    expect(c.message, 'Added 0 dives, 1 already in the list.');
    expect(c.currentRow, 1);

    // The table and its filter.
    expect(c.tableHeadings.length, 11);
    final all = c.tableRows;
    expect(all.length, c.selected!.sampleCount);
    c.filterText = all.last.first;
    expect(c.tableRows.length, lessThan(all.length));
    c.select(0);
    expect(c.filterText, '');

    // The units of the settings.
    config.updateSettings({'units': 'imperial'});
    c.unitsChanged();
    expect(c.rows.first.maxDepth, endsWith('ft'));

    c.removeSelected();
    expect(c.diveCount, 2);
    expect(c.currentRow, 0);
    expect(c.message, 'Removed 1 dive from the list.');
    c.clear();
    expect(c.diveCount, 0);
    expect(c.selected, isNull);
    expect(c.warnings, isEmpty);

    final empty = Directory(p.join(tmp.path, 'none'))..createSync();
    await c.addFolder(empty.path);
    expect(c.message, 'No dive logs in none.');
  });

  test('Adjust time: the dialog\'s values, its errors, the copy', () async {
    final c = controller();
    await c.addFiles([p.join(logs.path, 'first.fit')]);
    expect(c.canAdjustTime, isTrue);
    expect(
      c.adjustStartText,
      matches(RegExp(r'^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$')),
    );
    expect(c.adjustOffsetText, matches(RegExp(r'^[+-]\d\d:\d\d$')));

    Future<String?> cancel(String suggested, String title) async => null;
    final asked = <String>[];
    Future<String?> saveAs(String suggested, String title) async {
      asked.add('$title: ${p.basename(suggested)}');
      return p.join(logs.path, 'moved');
    }

    expect(
      await c.adjustTime('yesterday', '+07:00', saveAs),
      "Enter the start as YYYY-MM-DD HH:MM:SS (the dive site's local time)",
    );
    expect(
      await c.adjustTime('2026-03-05 14:23', 'Mars', saveAs),
      'Enter the time zone as a UTC offset, e.g. +07:00 or -05:30',
    );
    expect(await c.adjustTime('2026-03-05 14:23', '+07:00', cancel), '');
    expect(c.diveCount, 1);
    expect(
      await c.adjustTime(
        '2026-03-05 14:23',
        '+07:00',
        (_, _) async => p.join(logs.path, 'first.fit'),
      ),
      'Save the adjusted log under a new name; the original is kept as it is',
    );

    expect(await c.adjustTime('2026-03-05 14:23:07', '+7', saveAs), '');
    expect(asked, ['Save the adjusted log: first (adjusted).fit']);
    expect(File(p.join(logs.path, 'moved.fit')).existsSync(), isTrue);
    expect(c.diveCount, 2);
    expect(c.rows.map((r) => r.file), contains('moved.fit'));
    final moved = c.rows.indexWhere((r) => r.file == 'moved.fit');
    c.select(moved);
    expect(c.selected!.start, '2026-03-05 14:23:07');
    expect(c.selected!.timezone, 'UTC+07:00');
  });

  test('Merge: the candidates, the copy, the errors', () async {
    final c = controller();
    await c.addFolder(logs.path);
    expect(c.canMerge, isTrue);
    expect(c.mergeCandidateLabels.single, contains('Second.fit'));
    expect(
      await c.mergeDives(1, false, (_, _) async => 'x'),
      'Pick the dive to merge with',
    );
    expect(
      await c.mergeDives(
        0,
        false,
        (_, _) async => p.join(logs.path, 'Second.fit'),
      ),
      'Save the merged dive under a new name; the original logs are kept as '
      'they are',
    );
    expect(
      await c.mergeDives(0, false, (_, _) async => p.join(logs.path, 'one')),
      '',
    );
    expect(c.files, contains('one.fit'));
    expect(c.diveCount, 4);

    // The last dive has nothing after it.
    c.select(c.rows.indexWhere((r) => r.file == 'later.FIT'));
    expect(c.canMerge, isFalse);
    expect(
      await c.mergeDives(0, false, (_, _) async => 'x'),
      'Select a Garmin FIT dive that another FIT dive follows within 2 hours',
    );
  });

  testWidgets('on screen: open, select by keys, charts, samples, dialogs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dialogs = _Dialogs(logs.path);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: LogViewerPage(
              services: AppServices(
                capabilities: const Capabilities(desktop: true),
                config: config,
                home: tmp.path,
              ),
              dialogs: dialogs,
              reader: here,
            ),
          ),
        ),
      );
      await tester.tap(find.text(openLogsLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, folderPlaceLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.text('DIVES (3)'), findsOneWidget);
    expect(find.text('Added 3 dives.'), findsOneWidget);
    expect(find.byType(ProfileChart), findsOneWidget);
    expect(find.textContaining('first.fit ·'), findsOneWidget);

    await tester.tap(find.text('Second.fit').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Second.fit ·'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(find.textContaining('first.fit ·'), findsOneWidget);

    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();
    final shown = tester.widget<Text>(find.textContaining(' shown')).data!;
    await tester.enterText(
      find.widgetWithText(TextField, 'Type to filter samples...'),
      'zzz',
    );
    await tester.pumpAndSettle();
    expect(find.text('0 shown'), findsOneWidget);
    // Another dive: the filter is emptied, in the field too.
    await tester.tap(find.text('Second.fit').last);
    await tester.pumpAndSettle();
    expect(find.text('zzz'), findsNothing);
    expect(find.text('0 shown'), findsNothing);
    await tester.tap(find.text('first.fit').last);
    await tester.pumpAndSettle();
    expect(find.text(shown), findsOneWidget);

    await tester.tap(find.text('Merge…'));
    await tester.pumpAndSettle();
    expect(find.text('Merge two dives into one'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Adjust time…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Start (local time)'),
      'soon',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        "Enter the start as YYYY-MM-DD HH:MM:SS (the dive site's local time)",
      ),
      findsOneWidget,
    );
  });
}

/// The default reader of the page: [readLogs] on another isolate.
Future<LogRead> readOnIsolate(List<String> paths, TankConfig tanks) =>
    LogViewerController(
      config: ConfigStore(() => Directory.systemTemp),
      home: '',
    ).reader(paths, tanks);

class _Dialogs implements LogViewerDialogs {
  _Dialogs(this.folder);

  final String folder;

  @override
  Future<List<String>> openFiles(String initialDirectory) async => const [];

  @override
  Future<String?> openFolder(String initialDirectory) async => folder;

  @override
  Future<String?> save(String suggested, String title) async => null;
}
