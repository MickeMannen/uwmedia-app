// The phones' Tag Editor (lib/pages/tag_editor_lite/) on a made-up photo
// library: the fixture photo and a clip ffmpeg makes picked, one date set,
// every file shifted, corrected copies saved into an album with the
// originals byte for byte as they were, a refused save named; and the page
// on a phone-sized screen.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/engine/media_file_dates.dart';
import 'package:uwmedia_app/engine/media_library.dart';
import 'package:uwmedia_app/engine/result_folder.dart';
import 'package:uwmedia_app/pages/shared/save_to.dart';
import 'package:uwmedia_app/pages/tag_editor_lite/tag_editor_lite_controller.dart';
import 'package:uwmedia_app/pages/tag_editor_lite/tag_editor_lite_page.dart';

import '../helpers/tools.dart';

const _sony = 'test/fixtures/media/photo/jpeg_3x2_2mp.jpg';

/// Folders of the phone's files that keep what is saved into them.
class FakeFolders implements ResultFolders {
  ResultFolder? offered;
  final saved = <(String name, String folder)>[];

  @override
  Future<ResultFolder?> pick() async => offered;

  @override
  Future<void> save(String path, ResultFolder folder) async =>
      saved.add((p.basename(path), folder.name));
}

/// A library that hands out [picked] and keeps what is saved into
/// [albums] (album → copies of the saved files).
class FakeLibrary implements MediaLibrary {
  FakeLibrary(this.root);

  final Directory root;
  List<String> picked = [];
  final Set<String> refusing = {};
  final Map<String, List<String>> albums = {};

  @override
  Future<List<String>> pick({
    bool photos = true,
    bool videos = true,
    bool multiple = true,
  }) async => picked;

  @override
  Future<bool> saveToAlbum(String path, String album) async {
    if (refusing.contains(p.basename(path))) {
      throw const FormatException('the library refused it');
    }
    final dir = Directory(p.join(root.path, 'albums', album))
      ..createSync(recursive: true);
    final kept = p.join(dir.path, p.basename(path));
    File(path).copySync(kept);
    (albums[album] ??= []).add(kept);
    return true;
  }
}

void main() {
  final withVideo = hasTool('ffmpeg');
  late Directory tmp;
  late FakeLibrary library;
  late String photo;
  late String clip;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('uwmedia_lite_');
    library = FakeLibrary(tmp);
    final picked = Directory(p.join(tmp.path, 'picked'))..createSync();
    photo = p.join(picked.path, 'DSC0001.JPG');
    File(_sony).copySync(photo);
    clip = p.join(picked.path, 'clip.mp4');
    if (withVideo) {
      final run = await Process.run('ffmpeg', [
        '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=64x48:rate=5', //
        '-t', '1', '-pix_fmt', 'yuv420p', '-c:v', 'libx264',
        '-metadata', 'creation_time=2026-03-14T09:30:00Z', clip, '-y',
      ]);
      expect(run.exitCode, 0, reason: '${run.stderr}');
    }
    final notes = p.join(picked.path, 'notes.txt');
    File(notes).writeAsStringSync('x');
    library.picked = [photo, if (withVideo) clip, notes];
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  TagEditorLiteController make() => TagEditorLiteController(
    library: library,
    tempDir: (prefix) => tmp.createTempSync(prefix),
  );

  test('pick, set one date, shift all, save copies', () async {
    final c = make();
    await c.pick();
    expect(c.items.map((i) => i.name), [
      'DSC0001.JPG',
      if (withVideo) 'clip.mp4',
    ]);
    expect(c.status, startsWith('Picked ${c.items.length} file(s).'));
    expect(c.status, contains('1 of another type left out.'));
    final shot = c.items.first;
    expect(liteDateText(shot.local), '2025:12:03 09:15:48');
    expect(shot.offset, 480);

    expect(
      c.setDate(0, 'yesterday', '+08:00'),
      "Not a date: 'yesterday' (use 2026:05:21 06:58:22).",
    );
    expect(c.setDate(0, '2025:12:03 10:00:00', '+07:00'), isNull);
    expect(liteDateText(shot.after.$1), '2025:12:03 10:00:00');
    expect(shot.after.$2, 420);

    expect(
      c.shiftAll(0, 0, null),
      'Nothing to shift: give hours, minutes or a new offset.',
    );
    expect(c.shiftAll(-1, 0, null), isNull);
    expect(liteDateText(shot.after.$1), '2025:12:03 08:15:48');
    expect(shot.after.$2, 480);

    final before = {
      for (final path in library.picked) path: File(path).readAsBytesSync(),
    };
    await c.saveCopies('Trip');
    expect(
      c.status,
      withVideo
          ? 'Saved 2 corrected copies into the album "Trip".'
          : 'Saved 1 corrected copy into the album "Trip".',
    );
    expect(c.hasChanges, isFalse);
    before.forEach((path, bytes) {
      expect(File(path).readAsBytesSync(), bytes, reason: path);
    });
    final copies = {
      for (final path in library.albums['Trip']!) p.basename(path): path,
    };
    expect(
      readFileDates(copies['DSC0001.JPG']!),
      containsPair('EXIF:DateTimeOriginal', '2025:12:03 08:15:48'),
    );
    if (withVideo) {
      expect(
        readFileDates(copies['clip.mp4']!),
        containsPair('QuickTime:CreateDate', '2026:03:14 08:30:00'),
      );
    }
    // The working folder of the copies is gone.
    expect(
      tmp.listSync().where(
        (e) => p.basename(e.path).startsWith('uwmedia_copies_'),
      ),
      isEmpty,
    );

    await c.saveCopies('Trip');
    expect(c.status, 'Nothing changed to save.');
    c.dispose();
  });

  test('an offset kept as it is; a second pick; files without dates', () async {
    final c = make();
    await c.pick();
    final first = c.picks;
    // The file's own offset kept: no offset tags written.
    expect(c.setDate(0, '2025:12:03 10:00:00', null), isNull);
    expect(
      c.items.first.pending!.keys.where((k) => k.contains('Offset')),
      isEmpty,
    );
    expect(c.items.first.after.$2, 480);

    // A broken photo and one without any date: listed, not changed.
    final broken = p.join(tmp.path, 'picked', 'broken.jpg');
    File(broken).writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xE1, 0, 9, 1, 2, 3]);
    final plain = p.join(tmp.path, 'picked', 'plain.jpg');
    final made = withVideo
        ? await Process.run('ffmpeg', [
            '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=16x16', //
            '-frames:v', '1', plain, '-y',
          ])
        : null;
    final hasPlain = made != null && made.exitCode == 0;
    library.picked = [broken, if (hasPlain) plain, photo];
    await c.pick();
    expect(c.picks, first + 1);
    expect(c.items.first.error, isNotNull);
    if (hasPlain) {
      // The picked copy's own time is no capture time.
      expect(c.items[1].local, isNull);
    }
    c.shiftAll(1, 0, null);
    expect(
      [for (final i in c.items) i.pending != null],
      [false, if (hasPlain) false, true],
    );
    c.dispose();
  });

  test("picked from the phone's files; a pick that fails is said", () async {
    final c = make();
    await c.pick(from: () async => [photo]);
    expect(c.items.map((i) => i.name), ['DSC0001.JPG']);
    expect(c.status, 'Picked 1 file(s).');
    await c.pick(
      from: () async => throw const LibraryException('It could not be read'),
    );
    expect(c.status, 'It could not be read');
    expect(c.items, hasLength(1));
    c.dispose();
  });

  test('a copy the library refuses is named', () async {
    final c = make();
    await c.pick();
    library.refusing.add('DSC0001.JPG');
    c.shiftAll(0, 30, '+02:00');
    await c.saveCopies('Refused');
    expect(
      c.status,
      '${withVideo ? 'Saved 1 corrected copy into the album "Refused".' : 'No copy was saved.'} '
      'Could not save 1: DSC0001.JPG (the library refused it).',
    );
    expect(c.items.first.pending, isNotNull);
    c.dispose();
  });

  testWidgets('on a phone: pick, shift all, save to a new album', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = AppServices(
      capabilities: const Capabilities(desktop: false),
      config: ConfigStore(() => Directory(p.join(tmp.path, 'config'))),
      home: tmp.path,
      tempDir: (prefix) => tmp.createTempSync(prefix),
    );
    library.picked = [photo];
    final fromFiles = p.join(tmp.path, 'picked', 'CARD0001.JPG');
    File(_sony).copySync(fromFiles);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: TagEditorLitePage(
            services: services,
            library: library,
            pickFiles: () async => [fromFiles],
          ),
        ),
      ),
    );
    // From the phone's files (owner, 2026-11-25).
    await tester.tap(find.text('Pick photos and videos'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    expect(find.text('CARD0001.JPG'), findsWidgets);
    expect(find.text('DSC0001.JPG'), findsNothing);

    await tester.tap(find.text('Pick photos and videos'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Photo library'));
    await tester.pumpAndSettle();
    expect(find.text('DSC0001.JPG'), findsWidgets);
    expect(find.textContaining('2025:12:03 09:15:48 +08:00'), findsOneWidget);

    await tester.ensureVisible(find.text('Shift all'));
    await tester.enterText(find.byKey(const ValueKey('lite-hours')), '2');
    await tester.tap(find.text('Shift all'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('→  2025:12:03 11:15:48 +08:00'),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('Save copies to new album…'));
    await tester.tap(find.text('Save copies to new album…'));
    await tester.pumpAndSettle();
    expect(find.text('Save to a new album'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Album'), 'Bali');
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(
      find.text('Saved 1 corrected copy into the album "Bali".'),
      findsOneWidget,
    );
    expect(library.albums['Bali'], hasLength(1));
  });

  testWidgets('on a phone with "Save to…": the copies go to the place chosen, '
      'a folder or an album; with none, to a new album', (tester) async {
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = AppServices(
      capabilities: const Capabilities(desktop: false, resultFolders: true),
      config: ConfigStore(() => Directory(p.join(tmp.path, 'config'))),
      home: tmp.path,
      tempDir: (prefix) => tmp.createTempSync(prefix),
    );
    library.picked = [photo];
    final folders = FakeFolders()
      ..offered = (name: 'Dive trip', bookmark: 'b1');
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: TagEditorLitePage(
            services: services,
            library: library,
            folders: folders,
            albums: () async => const ['Bali'],
          ),
        ),
      ),
    );
    // The place is chosen as on Color; no album is asked for at the save.
    expect(find.text(saveToLabel), findsOneWidget);
    expect(find.text(noPlaceChosenText), findsOneWidget);
    expect(find.text('Save copies to new album…'), findsNothing);

    Future<void> shiftAndSave(String hours) async {
      await tester.ensureVisible(find.text('Shift all'));
      await tester.enterText(find.byKey(const ValueKey('lite-hours')), hours);
      await tester.tap(find.text('Shift all'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(saveCopiesLabel));
      await tester.runAsync(() async {
        await tester.tap(find.text(saveCopiesLabel));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
    }

    await tester.tap(find.text('Pick photos and videos'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Photo library'));
    await tester.pumpAndSettle();

    // No place chosen yet: a new album named for now.
    await shiftAndSave('1');
    expect(library.albums.keys.single, startsWith('UWMedia '));
    expect(
      find.textContaining('Saved 1 corrected copy into the album "UWMedia '),
      findsOneWidget,
    );

    // A folder in Files.
    await tester.ensureVisible(find.text(saveToLabel));
    await tester.tap(find.text(saveToLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text(saveToFolderChoice));
    await tester.pumpAndSettle();
    expect(find.text('The folder "Dive trip"'), findsOneWidget);
    await shiftAndSave('2');
    expect(folders.saved, [('DSC0001.JPG', 'Dive trip')]);
    expect(
      find.text('Saved 1 corrected copy into the folder "Dive trip".'),
      findsOneWidget,
    );
    expect(library.albums, hasLength(1));
  });
}
