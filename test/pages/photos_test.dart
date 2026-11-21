// Apple Photos beside the folders on the desktop's pages
// (lib/pages/shared/photos.dart, spec §10.50) on a made-up library: what
// was picked becomes a working folder, results go into a new album, and
// neither is kept in the settings. On the Resize page, the Tag Editor
// and the Overlay Generator.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/hud_kit.dart';
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/engine/share_sizes.dart';
import 'package:uwmedia_app/core/hud/template_tree.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/engine/desktop/color_batch.dart';
import 'package:uwmedia_app/engine/desktop/convert_run.dart';
import 'package:uwmedia_app/engine/desktop/overlay_batch.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/media_library.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/pages/convertion/convertion_controller.dart';
import 'package:uwmedia_app/pages/convertion/convertion_page.dart';
import 'package:uwmedia_app/pages/overlay_generator/overlay_generator_controller.dart';
import 'package:uwmedia_app/pages/overlay_generator/overlay_generator_page.dart';
import 'package:uwmedia_app/pages/shared/photos.dart';
import 'package:uwmedia_app/pages/shared/place_menu.dart';
import 'package:uwmedia_app/pages/shared/save_to.dart';
import 'package:uwmedia_app/pages/shared/template_picker.dart';
import 'package:uwmedia_app/pages/tag_editor/tag_editor_page.dart';

import '../helpers/menus.dart';
import 'tag_editor_test.dart' show FakeExiftool;

/// Photos with [offered] to pick (files made on the disk), that keeps
/// what it is given.
class FakePhotos implements MediaLibrary {
  List<String> offered = const [];
  final asked = <String>[];
  final saved = <(String name, String album)>[];
  final refused = <String>{};

  @override
  Future<List<String>> pick({
    bool photos = true,
    bool videos = true,
    bool multiple = true,
  }) async {
    asked.add('${photos ? 'photos ' : ''}${videos ? 'videos' : ''}'.trim());
    return offered;
  }

  @override
  Future<bool> saveToAlbum(String path, String album) async {
    if (refused.contains(p.basename(path))) {
      throw const LibraryException('refused');
    }
    saved.add((p.basename(path), album));
    return true;
  }
}

/// A Resize engine that writes an (empty) file for each size asked for.
class _WritingEngine implements ConvertionEngine {
  @override
  Future<(int, int)> dimensions(String path) async => (1920, 1080);

  @override
  Future<double> duration(String path) async => 10;

  @override
  Future<ConvertResult> convert({
    required String source,
    required String outputDir,
    required List<String> resolutions,
    required bool hwAccel,
    required RunControl control,
    List<ShareCopy> shares = const [],
    List<HudLayerSource> watermarks = const [],
    void Function(ConvertStep step)? onStep,
    void Function(double percent)? onProgress,
  }) async {
    for (final name in resolutions) {
      File(p.join(outputDir, '${p.basenameWithoutExtension(source)} $name.mp4'))
          .createSync(recursive: true);
    }
    return (failed: const <String>[], messages: const <String>[]);
  }
}

/// An Overlay Generator engine that writes an (empty) overlay for each
/// file of the source folder.
class _OverlayEngine implements OverlayGeneratorEngine {
  final ran = <OverlayFolderSettings>[];

  @override
  Future<MediaTags?> metadata(String path) async => null;

  @override
  Future<List<FileResult>> runFolder(
    OverlayFolderSettings settings,
    ColorBatchListener listener,
  ) async {
    ran.add(settings);
    for (final file in mediaIn(settings.source)) {
      File(
        p.join(settings.output, '${p.basenameWithoutExtension(file)}_hud.mov'),
      ).createSync(recursive: true);
    }
    return const [];
  }

  @override
  Future<String> runLog({
    required String logPath,
    required String output,
    required String layoutPath,
    required OverlayLook look,
    bool hwAccel = true,
    void Function(double percent)? onProgress,
    void Function(String line)? onMessage,
  }) async => '';

  @override
  Future<void> stop() async {}
}

void main() {
  late Directory tmp;
  late ConfigStore config;
  late FakePhotos photos;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('uwmedia_photos_');
    config = ConfigStore(() => Directory(p.join(tmp.path, 'config')));
    photos = FakePhotos();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Directory tempDir(String prefix) => tmp.createTempSync(prefix);

  List<String> library(List<String> names) {
    final dir = Directory(p.join(tmp.path, 'library'))..createSync();
    return [
      for (final name in names)
        (File(p.join(dir.path, name))..writeAsStringSync(name)).path,
    ];
  }

  AppServices services() => AppServices(
    capabilities: const Capabilities(desktop: true, photos: true),
    config: config,
    home: '/Users/diver',
    dataDir: () => Directory(p.join(tmp.path, 'data')),
    tempDir: tempDir,
  );

  test(
    'what was picked becomes a working folder; nothing picked, none',
    () async {
      expect(await pickFromPhotos(photos, tempDir), isNull);
      photos.offered = library(['IMG_1.HEIC', 'IMG_2.MOV']);
      final dir = await pickFromPhotos(photos, tempDir, photos: false);
      expect(photos.asked, ['photos videos', 'videos']);
      expect(p.basename(dir!), startsWith('uwmedia_picked_'));
      expect(
        [for (final f in mediaIn(dir)) p.basename(f)],
        ['IMG_1.HEIC', 'IMG_2.MOV'],
      );
      expect(fromPhotosText(2), '2 items from Photos');
      expect(fromPhotosText(1), '1 item from Photos');
    },
  );

  test('a page\'s pick before is removed when it picks again', () async {
    photos.offered = library(['A.JPG']);
    final first = await pickFromPhotos(photos, tempDir, page: 'one');
    photos.offered = library(['B.JPG']);
    final other = await pickFromPhotos(photos, tempDir, page: 'two');
    // Nothing picked: the folder that is there stays.
    photos.offered = const [];
    expect(await pickFromPhotos(photos, tempDir, page: 'one'), isNull);
    expect(Directory(first!).existsSync(), isTrue);
    photos.offered = library(['C.JPG']);
    final second = await pickFromPhotos(photos, tempDir, page: 'one');
    expect(Directory(first).existsSync(), isFalse);
    expect(mediaIn(second!).map(p.basename), ['C.JPG']);
    // Another page's files stay: it may still show them.
    expect(Directory(other!).existsSync(), isTrue);
  });

  test(
    'a folder into a new album: saved files go, refused ones stay',
    () async {
      final out = tempDir('out_');
      for (final name in ['a.jpg', 'b.mp4', '.hidden']) {
        File(p.join(out.path, name)).writeAsStringSync(name);
      }
      photos.refused.add('b.mp4');
      final lines = await saveFolderIntoPhotos(
        photos,
        out.path,
        now: () => naive(2026, 11, 14, 9, 30),
      );
      expect(photos.saved, [('a.jpg', 'UWMedia 2026-11-14 09.30')]);
      expect(lines, [
        'Saved 1 file into the album "UWMedia 2026-11-14 09.30" in Photos.',
        'b.mp4: not saved into Photos (refused)',
        'What was not saved is kept for a day in ${out.path}',
      ]);
      expect(File(p.join(out.path, 'a.jpg')).existsSync(), isFalse);
      expect(File(p.join(out.path, 'b.mp4')).existsSync(), isTrue);
      expect(
        await saveFolderIntoPhotos(photos, tempDir('none_').path),
        isEmpty,
      );

      // After Stop nothing goes into Photos: the folder is emptied.
      expect(
        discardStopped(out.path),
        'Stopped: nothing was saved into Photos.',
      );
      expect(mediaIn(out.path), isEmpty);
    },
  );

  testWidgets('Resize: videos from Photos, the results into an album', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    photos.offered = library(['Reef.mov', 'Wreck.mov']);
    final engine = _WritingEngine();
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: ConvertionPage(
              services: services(),
              engine: () async => engine,
              photos: photos,
            ),
          ),
        ),
      );
    });
    await choosePlace(
      tester,
      find.text(chooseVideosLabel),
      photoLibraryPlaceLabel,
      real: true,
    );
    expect(photos.asked, ['videos']);
    expect(find.text('2 items from Photos'), findsOneWidget);

    await choosePlace(tester, find.text(saveToLabel), saveToAlbumChoice);
    // The album asked for, as on a phone (owner, 2026-11-19).
    await tester.enterText(find.byType(TextField), 'Dives');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('The album "Dives" in Photos'), findsOneWidget);
    // Neither working folder is kept for the dialogs of the next time.
    expect(config.fields()[convertionSourceDirField], isNull);
    expect(config.fields()[convertionDestDirField], isNull);

    await tester.tap(find.text('720p'));
    await tester.pump();
    await tester.ensureVisible(find.text('Start'));
    await tester.runAsync(() async {
      await tester.tap(find.text('Start'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(
      [for (final s in photos.saved) s.$1],
      ['Reef 720p.mp4', 'Wreck 720p.mp4'],
    );
    expect(photos.saved.first.$2, 'Dives');
    expect(find.textContaining('Saved 2 files into the album'), findsOneWidget);
  });

  testWidgets('Resize: no Photos where the system has none', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: ConvertionPage(
            services: AppServices(
              capabilities: const Capabilities(desktop: true),
              config: config,
              home: '/Users/diver',
              dataDir: () => Directory(p.join(tmp.path, 'data')),
            ),
            engine: () async => _WritingEngine(),
          ),
        ),
      ),
    );
    // Files only: the button opens the dialog with no menu between.
    expect(
      [
        for (final place
            in tester
                .widget<PlaceMenuButton>(
                  find.widgetWithText(PlaceMenuButton, chooseVideosLabel),
                )
                .places)
          place.label,
      ],
      [filesPlaceLabel],
    );
  });

  testWidgets('Tag Editor: copies from Photos, saved into an album', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    photos.offered = library(['IMG_1.JPG', 'IMG_2.MP4']);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: TagEditorPage(
              services: services(),
              engine: () async => FakeExiftool(),
              systemOffset: const Duration(hours: 2),
              photos: photos,
            ),
          ),
        ),
      );
      expect(find.text(intoPhotosLabel), findsNothing);
      await tester.tap(find.text(chooseMediaLabel));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(MenuItemButton, photoLibraryPlaceLabel),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.text('2 items from Photos'), findsOneWidget);
    expect(find.text('IMG_1.JPG'), findsWidgets);
    expect(find.text('IMG_2.MP4'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text(intoPhotosLabel));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect([for (final s in photos.saved) s.$1], ['IMG_1.JPG', 'IMG_2.MP4']);
    expect(find.textContaining('Saved 2 files into the album'), findsOneWidget);
    expect(find.text('0 items from Photos'), findsOneWidget);
  });

  testWidgets('Overlay Generator: from Photos, into an album', (tester) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    photos.offered = library(['Reef.mov', 'Wreck.mov']);
    final kept = Directory(p.join(tmp.path, 'kept'))..createSync();
    File(p.join(kept.path, 'dive.uddf')).writeAsStringSync('<uddf/>');
    final engine = _OverlayEngine();
    late OverlayGeneratorController made;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: OverlayGeneratorPage(
              services: services(),
              photos: photos,
              setup: (s) async => made = OverlayGeneratorController(
                keptLogsDir: kept.path,
                config: config,
                gate: s.batches,
                home: '/Users/diver',
                engine: () async => engine,
                picker: TemplatePicker(
                  TemplateTree(
                    bundled: DiskTemplateFolder('assets/overlays/templates'),
                  ),
                  tempDir: tempDir,
                  templateBytes: (path) async => File(path).readAsBytesSync(),
                ),
                clock: () => 0,
              )..overlays.add((label: 'Mine', layoutPath: '/mine.json')),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    await choosePlace(
      tester,
      find.text(chooseMediaLabel),
      photoLibraryPlaceLabel,
      real: true,
    );
    await tester.pumpAndSettle();
    expect(find.text('2 items from Photos'), findsOneWidget);
    expect(p.basename(made.sourceText), startsWith('uwmedia_picked_'));

    await choosePlace(tester, find.text(saveToLabel), saveToAlbumChoice);
    // The album asked for, as on a phone (owner, 2026-11-19).
    await tester.enterText(find.byType(TextField), 'Dives');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('The album "Dives" in Photos'), findsOneWidget);
    // Neither working folder is kept in the settings.
    expect(config.fields()[hudSourceField], isNull);
    expect(config.fields()[hudOutputField], isNull);

    await tester.ensureVisible(find.text('Start'));
    await tester.runAsync(() async {
      await tester.tap(find.text('Start'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(engine.ran.single.source, made.sourceText);
    expect(
      [for (final s in photos.saved) s.$1],
      ['Reef_hud.mov', 'Wreck_hud.mov'],
    );
    expect(photos.saved.first.$2, 'Dives');

    // A folder of frames for each overlay is nothing for an album: it is
    // not offered then.
    made.outputFormat = outputFormatChoices[1].$1;
    await tester.pumpAndSettle();
    expect(made.outputIsFrames, isTrue);
    expect(
      [
        for (final place
            in tester
                .widget<PlaceMenuButton>(
                  find.widgetWithText(PlaceMenuButton, saveToLabel),
                )
                .places)
          place.label,
      ],
      [folderPlaceLabel],
    );
  });
}
