// The Tag Editor page (lib/pages/tag_editor/) on a made-up exiftool that
// keeps tags in memory, over a temporary folder of empty files: the file
// list, the fields and DJI's dates, writing, the two batch changes with
// their questions, the viewer, a pick that is overtaken; then the page on
// screen, and one round trip with the real exiftool on a picture made at
// run time.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/metadata/exiftool_commands.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/metadata/tag_editor.dart';
import 'package:uwmedia_app/engine/app_log.dart';
import 'package:uwmedia_app/engine/desktop/exiftool.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';
import 'package:uwmedia_app/pages/shared/place_menu.dart';
import 'package:uwmedia_app/pages/tag_editor/tag_editor_controller.dart';
import 'package:uwmedia_app/pages/tag_editor/tag_editor_page.dart';

import '../helpers/tools.dart';

/// Tags by file name; a file named in [refusing] cannot be written.
class FakeExiftool implements TagEditorEngine {
  final Map<String, MediaTags> files = {};
  final Set<String> refusing = {};
  final Map<String, Completer<void>> slow = {};
  final writes = <String, Map<String, Object?>>{};

  @override
  Future<Map<String, String>> tags(String path, List<String> names) async {
    await slow[p.basename(path)]?.future;
    return namedTags(files[p.basename(path)], names);
  }

  @override
  Future<MediaTags?> metadata(String path) async => files[p.basename(path)];

  @override
  Future<void> setTags(String path, Map<String, Object?> tags) async {
    final name = p.basename(path);
    if (refusing.contains(name)) {
      throw const EngineException('Error writing tags');
    }
    writes[name] = tags;
    (files[name] ??= {}).addAll(tags);
  }
}

void main() {
  late Directory tmp;
  late Directory media;
  late ConfigStore config;
  late FakeExiftool exif;

  TagEditorController controller({
    Duration offset = const Duration(hours: 2),
  }) => TagEditorController(
    config: config,
    home: '/Users/diver',
    engine: () async => exif,
    systemOffset: offset,
  );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('uwmedia_tags_');
    media = Directory(p.join(tmp.path, 'media'))..createSync();
    for (final name in [
      'b.MP4',
      'DJI_20260521065822_0001_D.MP4',
      'A.jpg',
      'notes.txt',
      'log.FIT',
    ]) {
      File(p.join(media.path, name)).writeAsStringSync('x');
    }
    Directory(p.join(media.path, 'sub.mp4')).createSync();
    config = ConfigStore(() => Directory(p.join(tmp.path, 'config')));
    exif = FakeExiftool()
      ..files['b.MP4'] = {
        'QuickTime:CreationDate': '2026:03:14 11:30:00+02:00',
        'QuickTime:CreateDate': '2026:03:14 09:30:00',
      }
      ..files['DJI_20260521065822_0001_D.MP4'] = {
        'QuickTime:CreateDate': '2026:05:20 22:58:22',
      }
      ..files['A.jpg'] = {'EXIF:DateTimeOriginal': '2026:01:02 03:04:05'};
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('the offsets, the guidance', () {
    final c = controller();
    expect(c.currentTz, '+02:00');
    expect(c.tzOptions, tzOffsets);
    expect(c.currentTzMode, tzModeKeepLocal);
    expect(
      TagEditorController.helpOf(tagGuide.first),
      'Intended: Local Time + Offset  |  Example: 2026:05:21 06:58:22+08:00'
      '  —  Primary date used by Apple Photos for sorting.',
    );
    // An offset the list lacks comes first.
    final odd = controller(offset: const Duration(hours: 1, minutes: 15));
    expect(odd.currentTz, '+01:15');
    expect(odd.tzOptions.first, '+01:15');
    expect(odd.tzOptions.length, tzOffsets.length + 1);
  });

  test('a folder: its media by name, the first shown, DJI dates', () async {
    final c = controller();
    expect(c.dirLabel, noDirectoryText);
    expect(c.selectedFileName, 'None');
    expect(c.viewMetadataEnabled, isFalse);
    await c.chooseDirectory(media.path);
    expect(c.dirLabel, media.path);
    expect(c.fileNames, [
      'A.jpg',
      'b.MP4',
      'DJI_20260521065822_0001_D.MP4',
      'log.FIT',
    ]);
    expect(c.selectedIndex, 0);
    expect(c.selectedFileName, 'A.jpg');
    expect(c.tagValue('EXIF:DateTimeOriginal'), '2026:01:02 03:04:05');
    expect(c.tagValue('QuickTime:CreationDate'), '');
    expect(c.djiVisible, isFalse);
    expect(c.mediaDialogDir, media.path);

    await c.selectFile(2);
    expect(c.djiVisible, isTrue);
    expect(c.tagValue('QuickTime:CreationDate'), '2026:05:21 06:58:22+08:00');
    expect(c.tagValue('EXIF:CreateDate'), '2026:05:21 06:58:22');

    // DJI's values differ from the file's: Write puts them in.
    await c.writeTags();
    expect(c.statusText, 'Updated 3 tags successfully.');
    expect(exif.writes['DJI_20260521065822_0001_D.MP4'], {
      'QuickTime:CreationDate': '2026:05:21 06:58:22+08:00',
      'EXIF:DateTimeOriginal': '2026:05:21 06:58:22',
      'EXIF:CreateDate': '2026:05:21 06:58:22',
    });
    await c.writeTags();
    expect(c.statusText, 'No changes detected to update.');
  });

  test('files picked one by one are listed as a folder is', () async {
    final c = controller();
    await c.chooseFiles(const []);
    expect(c.dirLabel, noDirectoryText);
    // In the order picked, with one the page does not read.
    await c.chooseFiles([
      p.join(media.path, 'b.MP4'),
      p.join(media.path, 'A.jpg'),
      p.join(media.path, 'notes.txt'),
    ]);
    expect(c.fileNames, ['A.jpg', 'b.MP4']);
    expect(c.dirLabel, '2 files in ${media.path}');
    expect(c.selectedFileName, 'A.jpg');
    expect(c.tagValue('EXIF:DateTimeOriginal'), '2026:01:02 03:04:05');
    expect(c.mediaDialogDir, media.path);
  });

  test('editing, reverting, a write that fails', () async {
    final c = controller();
    await c.chooseDirectory(media.path);
    await c.selectFile(1);
    c.setTagValue('EXIF:DateTimeOriginal', ' 2026:03:14 11:30:00 ');
    await c.revert();
    expect(c.tagValue('EXIF:DateTimeOriginal'), '');
    c.setTagValue('EXIF:DateTimeOriginal', ' 2026:03:14 11:30:00 ');
    await c.writeTags();
    expect(exif.writes['b.MP4'], {
      'EXIF:DateTimeOriginal': '2026:03:14 11:30:00',
    });
    expect(c.tagValue('EXIF:DateTimeOriginal'), '2026:03:14 11:30:00');

    exif.refusing.add('b.MP4');
    c.setTagValue('EXIF:CreateDate', '2026:03:14 11:30:00');
    await c.writeTags();
    expect(c.statusText, 'Failed to update tags: Error writing tags');
  });

  test('what was written, and what failed, goes into the app\'s log', () async {
    final log = AppLog.instance = AppLog(File(p.join(tmp.path, 'app.log')));
    addTearDown(() => AppLog.instance = null);
    final c = controller();
    await c.chooseDirectory(media.path);
    await c.selectFile(1);
    c.setTagValue('EXIF:DateTimeOriginal', '2026:03:14 11:30:00');
    await c.writeTags();
    exif.refusing.add('b.MP4');
    c.setTagValue('EXIF:CreateDate', '2026:03:14 11:30:00');
    await c.writeTags();
    await c.shiftAll(1, 0, null);
    final lines = log.tail().map((l) => l.substring(20)).toList();
    expect(lines[0], '[Tag Editor] b.MP4: EXIF:DateTimeOriginal written');
    expect(lines[1], startsWith('[Tag Editor] b.MP4: could not write ('));
    expect(lines.last, startsWith('[Tag Editor] Shift of 4 files: Shifted'));
    expect(lines.last, contains('b.MP4'));
  });

  test('Update All (DJI) and the timezone for every file', () async {
    final c = controller();
    expect(c.askUpdateAll(), isNull);
    expect(c.statusText, 'No files in the list to update.');
    await c.chooseDirectory(media.path);
    expect(c.askUpdateAll(), (
      title: 'Confirm Update All',
      message:
          'Scan all 4 files and automatically update DJI videos with '
          'corrected datetimes?',
    ));
    await c.updateAll();
    expect(exif.writes.keys, ['DJI_20260521065822_0001_D.MP4']);
    expect(c.statusText, 'Successfully updated 1 files.');
    expect(c.busy, isFalse);

    c
      ..currentTz = '-05:00'
      ..currentTzMode = tzModeFromUtc;
    expect(
      c.askApplyTimezone()!.message,
      'Update all 4 files in the directory to timezone -05:00?\n\n'
      'Mode: $tzModeFromUtc',
    );
    exif.writes.clear();
    exif.refusing.add('A.jpg');
    await c.applyTimezone();
    // A.jpg cannot be written; log.FIT has no tags and gets its time from
    // the file.
    expect(c.statusText, 'Updated timezone for 3 files. Failed: 1.');
    expect(exif.writes['b.MP4'], {
      'QuickTime:CreationDate': '2026:03:14 04:30:00-05:00',
      'QuickTime:Timezone': '-05:00',
      'QuickTime:TimeZone': '-05:00',
      'EXIF:DateTimeOriginal': '2026:03:14 04:30:00',
      'EXIF:CreateDate': '2026:03:14 04:30:00',
    });
    expect(exif.writes['log.FIT']!['EXIF:OffsetTime'], '-05:00');

    c.currentTz = 'nowhere';
    expect(c.askApplyTimezone(), isNull);
    expect(c.statusText, "Invalid timezone format: 'nowhere'.");
  });

  test('Shift all files: one shift for every file, failures named', () async {
    final c = controller();
    expect(c.askShiftAll(1, 0, null), isNull);
    expect(c.statusText, 'No files in the list to update.');
    await c.chooseDirectory(media.path);
    expect(c.askShiftAll(0, 0, null), isNull);
    expect(
      c.statusText,
      'Nothing to shift: give hours, minutes or a new offset.',
    );
    expect(c.askShiftAll(0, 0, 'nowhere'), isNull);
    expect(c.statusText, "Invalid timezone format: 'nowhere'.");
    expect(
      c.askShiftAll(-1, -30, null)!.message,
      'Shift the date of all 4 files in the directory by -1 h 30 min, '
      'keeping their offsets?',
    );
    expect(
      c.askShiftAll(0, 45, '+08:00')!.message,
      'Shift the date of all 4 files in the directory by +0 h 45 min and '
      'set their offset to +08:00?',
    );
    exif.writes.clear();
    exif.refusing.add('A.jpg');
    await c.shiftAll(-1, -30, null);
    expect(exif.writes['b.MP4'], {
      'EXIF:DateTimeOriginal': '2026:03:14 10:00:00',
      'EXIF:CreateDate': '2026:03:14 10:00:00',
      'QuickTime:CreationDate': '2026:03:14 10:00:00+02:00',
      'QuickTime:CreateDate': '2026:03:14 08:00:00',
    });
    // log.FIT has no tags and is shifted from its file time.
    expect(exif.writes.keys, containsAll(['b.MP4', 'log.FIT']));
    expect(
      c.statusText,
      'Shifted 3 files by -1 h 30 min. Could not write 1: A.jpg '
      '(Error writing tags).',
    );
    expect(c.busy, isFalse);
  });

  test('the viewer, and a pick overtaken by the next', () async {
    final c = controller();
    expect(await c.allMetadata(), isNull);
    await c.chooseDirectory(media.path);
    await c.selectFile(1);
    exif.files['b.MP4']!['Composite:Empty'] = null;
    final viewer = (await c.allMetadata())!;
    expect(viewer.title, 'Metadata Viewer - b.MP4');
    expect(viewer.rows, [
      (tag: 'Composite:Empty', value: 'None'),
      (tag: 'QuickTime:CreateDate', value: '2026:03:14 09:30:00'),
      (tag: 'QuickTime:CreationDate', value: '2026:03:14 11:30:00+02:00'),
    ]);
    await c.selectFile(3);
    expect(await c.allMetadata(), isNull);
    expect(c.statusText, 'No metadata could be extracted from this file.');

    exif.slow['A.jpg'] = Completer();
    final first = c.selectFile(0);
    await c.selectFile(1);
    exif.slow['A.jpg']!.complete();
    await first;
    expect(c.selectedFileName, 'b.MP4');
    expect(c.tagValue('QuickTime:CreateDate'), '2026:03:14 09:30:00');

    // A folder without media picked while a file is still being read.
    exif.slow['A.jpg'] = Completer();
    final reading = c.selectFile(0);
    final empty = Directory(p.join(tmp.path, 'empty'))..createSync();
    await c.chooseDirectory(empty.path);
    exif.slow['A.jpg']!.complete();
    await reading;
    expect(c.fileNames, isEmpty);
    expect(c.viewMetadataEnabled, isFalse);
    expect(c.tagValue('EXIF:DateTimeOriginal'), isNot('2026:01:02 03:04:05'));
  });

  test('a write keeps the page busy and the file picked', () async {
    final c = controller();
    await c.chooseDirectory(media.path);
    await c.selectFile(1);
    c.setTagValue('EXIF:CreateDate', '2026:03:14 11:30:00');
    exif.slow['b.MP4'] = Completer();
    final writing = c.writeTags();
    await pumpEventQueue();
    expect(c.busy, isTrue);
    // While busy no second write and no viewer.
    await c.writeTags();
    expect(await c.allMetadata(), isNull);
    exif.slow['b.MP4']!.complete();
    await writing;
    expect(c.busy, isFalse);
    expect(exif.writes.length, 1);
  });

  testWidgets('on screen: a folder, a field, a confirmed batch', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: TagEditorPage(
              services: AppServices(
                capabilities: const Capabilities(desktop: true),
                config: config,
                home: '/Users/diver',
              ),
              pickFolder: (_) async => media.path,
              engine: () async => exif,
              systemOffset: const Duration(hours: 2),
            ),
          ),
        ),
      );
      await tester.tap(find.text(chooseMediaLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, folderPlaceLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // The folder is listed on the disk.
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('DJI_20260521065822_0001_D.MP4'), findsOneWidget);
    expect(find.text('2026:01:02 03:04:05'), findsOneWidget);

    await tester.tap(find.text('DJI_20260521065822_0001_D.MP4'));
    await tester.pumpAndSettle();
    expect(find.text(djiDetectedText), findsOneWidget);
    expect(find.text('2026:05:21 06:58:22+08:00'), findsOneWidget);

    await tester.ensureVisible(find.text('Update All (DJI)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update All (DJI)'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm Update All'), findsOneWidget);
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();
    expect(find.text('Successfully updated 1 files.'), findsOneWidget);

    await tester.ensureVisible(find.text('View All Metadata'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View All Metadata'));
    await tester.pumpAndSettle();
    Finder inViewer(String text) =>
        find.descendant(of: find.byType(Dialog), matching: find.text(text));
    expect(inViewer('QuickTime:CreateDate'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Filter'), 'zzz');
    await tester.pumpAndSettle();
    expect(inViewer('QuickTime:CreateDate'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // Shift all files by two hours back, with a new offset.
    await tester.ensureVisible(find.text('Shift All Files'));
    await tester.enterText(find.byKey(const ValueKey('shift-hours')), '-2');
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shift All Files'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm Shift All Files'), findsOneWidget);
    expect(
      find.textContaining('by -2 h 0 min and set their offset to'),
      findsOneWidget,
    );
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Shifted 4 files by -2 h 0 min.'),
      findsOneWidget,
    );
  });

  test(
    'with the real exiftool: a write and a batch timezone',
    () async {
      final found = await ToolFinder.forThisMachine().findAll(const {});
      final engine = DesktopTagEditorEngine(Exiftool(found[toolExiftool]!));
      final made = await Process.run(found[toolFfmpeg]!, [
        '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=64x48', //
        '-frames:v', '1', p.join(media.path, 'A.jpg'), '-y',
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');
      final c = TagEditorController(
        config: config,
        home: '/Users/diver',
        engine: () async => engine,
        systemOffset: Duration.zero,
      );
      await c.chooseDirectory(media.path);
      expect(c.selectedFileName, 'A.jpg');
      c.setTagValue('EXIF:DateTimeOriginal', '2026:01:02 03:04:05');
      await c.writeTags();
      expect(c.statusText, 'Updated 1 tags successfully.');
      expect(c.tagValue('EXIF:DateTimeOriginal'), '2026:01:02 03:04:05');

      c.currentTz = '+08:00';
      await c.applyTimezone();
      // The empty files cannot be written; the picture can.
      expect(c.statusText, startsWith('Updated timezone for 1 files. Failed:'));
      final tags = await engine.tags(p.join(media.path, 'A.jpg'), [
        'EXIF:OffsetTimeOriginal',
        'EXIF:CreateDate',
      ]);
      expect(tags, {
        'EXIF:OffsetTimeOriginal': '+08:00',
        'EXIF:CreateDate': '2026:01:02 03:04:05',
      });

      // Shift all files on a real video: its QuickTime dates move.
      final clip = p.join(media.path, 'b.MP4');
      final video = await Process.run(found[toolFfmpeg]!, [
        '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=64x48:rate=5', //
        '-t', '1', '-metadata', 'creation_time=2026-03-14T09:30:00Z',
        clip, '-y',
      ]);
      expect(video.exitCode, 0, reason: '${video.stderr}');
      await engine.setTags(clip, {
        'QuickTime:CreationDate': '2026:03:14 11:30:00+02:00',
      });
      await c.shiftAll(-1, 0, null);
      // The empty files cannot be written; the picture and the clip can.
      expect(
        c.statusText,
        startsWith('Shifted 2 files by -1 h 0 min. Could not write 2: '),
      );
      expect(
        await engine.tags(clip, [
          'QuickTime:CreationDate',
          'QuickTime:CreateDate',
          'QuickTime:TrackCreateDate',
        ]),
        {
          'QuickTime:CreationDate': '2026:03:14 10:30:00+02:00',
          'QuickTime:CreateDate': '2026:03:14 08:30:00',
          'QuickTime:TrackCreateDate': '2026:03:14 08:30:00',
        },
      );
    },
    skip: hasTool('exiftool') && hasTool('ffmpeg')
        ? null
        : 'needs exiftool and ffmpeg on the PATH',
  );
}
