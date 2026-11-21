// The "Save to…" button with the place under it: a phone's Color and
// Resize pages', and the desktop's with its places; and the way to the
// Dive Logs page, there only when a log is missing.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/model/dive_manager.dart';
import 'package:uwmedia_app/core/pages/dive_matches.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/engine/media_library.dart';
import 'package:uwmedia_app/engine/result_folder.dart';
import 'package:uwmedia_app/pages/shared/dive_match_button.dart';
import 'package:uwmedia_app/pages/shared/logs_folder.dart';
import 'package:uwmedia_app/pages/shared/photos.dart';
import 'package:uwmedia_app/pages/shared/place_menu.dart';
import 'package:uwmedia_app/pages/shared/save_to.dart';

class _Folders implements ResultFolders {
  ResultFolder? offered;
  bool fail = false;

  @override
  Future<ResultFolder?> pick() async {
    if (fail) {
      throw const LibraryException('No access to the folder');
    }
    return offered;
  }

  @override
  Future<void> save(String path, ResultFolder folder) async {}
}

class _Library implements MediaLibrary {
  final saved = <(String, String)>[];

  @override
  Future<List<String>> pick({
    bool photos = true,
    bool videos = true,
    bool multiple = true,
  }) async => const [];

  @override
  Future<bool> saveToAlbum(String path, String album) async {
    saved.add((path, album));
    return true;
  }
}

void main() {
  late Directory tmp;
  late ConfigStore config;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('uwmedia_save_to_');
    config = ConfigStore(() => Directory(p.join(tmp.path, 'config')));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> show(
    WidgetTester tester,
    _Folders folders, {
    bool enabled = true,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SaveToButton(
          key: UniqueKey(),
          config: config,
          folders: folders,
          albums: () async => const ['Bonaire', 'Red Sea'],
          enabled: enabled,
        ),
      ),
    ),
  );

  Future<void> choose(WidgetTester tester, String choice) async {
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, choice));
    await tester.pumpAndSettle();
  }

  testWidgets('a folder, kept for the next start', (tester) async {
    final folders = _Folders()..offered = (name: 'Dives', bookmark: 'Ym9v');
    await show(tester, folders);
    expect(find.text(noPlaceChosenText), findsOneWidget);
    // A new album for each run is not among the choices.
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(MenuItemButton, 'A new album in Photos'),
      findsNothing,
    );
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();

    await choose(tester, saveToFolderChoice);
    expect(find.text('The folder "Dives"'), findsOneWidget);
    expect(keptResultFolder(config), (name: 'Dives', bookmark: 'Ym9v'));

    // The page opened again shows what is kept.
    await show(tester, folders);
    expect(find.text('The folder "Dives"'), findsOneWidget);
  });

  testWidgets('an album of the user\'s own, kept for the next start', (
    tester,
  ) async {
    final folders = _Folders()..offered = (name: 'Dives', bookmark: 'Ym9v');
    await show(tester, folders);
    await choose(tester, saveToFolderChoice);

    // One of the library's albums, tapped: in place of the folder.
    await choose(tester, saveToAlbumChoice);
    await tester.tap(find.text('Red Sea'));
    await tester.pumpAndSettle();
    expect(find.text('The album "Red Sea" in Photos'), findsOneWidget);
    expect(keptResultFolder(config), isNull);
    expect(keptResultAlbum(config), 'Red Sea');
    final library = _Library();
    final place = keptSavePlace(config, folders, library)!;
    await place.save('/work/a.mp4');
    expect(library.saved, [('/work/a.mp4', 'Red Sea')]);

    // The page opened again shows it; a name typed makes another.
    await show(tester, folders);
    expect(find.text('The album "Red Sea" in Photos'), findsOneWidget);
    await choose(tester, saveToAlbumChoice);
    await tester.enterText(find.byType(TextField), ' Lembeh ');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(keptResultAlbum(config), 'Lembeh');

    // Cancelled, or left empty: as it was.
    await choose(tester, saveToAlbumChoice);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await choose(tester, saveToAlbumChoice);
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(keptResultAlbum(config), 'Lembeh');
  });

  testWidgets('no folder picked, or none to be had, changes nothing', (
    tester,
  ) async {
    final folders = _Folders();
    await show(tester, folders);
    await choose(tester, saveToFolderChoice);
    expect(find.text(noPlaceChosenText), findsOneWidget);
    expect(keptResultFolder(config), isNull);

    folders.fail = true;
    await choose(tester, saveToFolderChoice);
    expect(
      find.text('Could not open the folder: No access to the folder'),
      findsOneWidget,
    );
    expect(keptResultFolder(config), isNull);
  });

  testWidgets('off during a run', (tester) async {
    await show(tester, _Folders(), enabled: false);
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );
  });

  testWidgets('the desktop: the place under the button; one place, no menu', (
    tester,
  ) async {
    final picked = <String>[];
    Future<void> show(String? location, List<String> places) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SaveToPlace(
                location: location,
                places: [
                  for (final place in places)
                    (
                      icon: Icons.folder_outlined,
                      label: place,
                      onPressed: () => picked.add(place),
                    ),
                ],
              ),
            ),
          ),
        );

    await show(null, [folderPlaceLabel]);
    expect(find.text(noOutputText), findsOneWidget);
    // The button says what it is for, not where: it stays short.
    await tester.tap(find.widgetWithText(OutlinedButton, saveToLabel));
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
    expect(picked, [folderPlaceLabel]);

    await show('~/Dives/out', [folderPlaceLabel, saveToAlbumChoice]);
    expect(find.text('~/Dives/out'), findsOneWidget);
    expect(find.text(noOutputText), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, saveToLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, saveToAlbumChoice));
    await tester.pumpAndSettle();
    expect(picked, [folderPlaceLabel, saveToAlbumChoice]);
  });

  testWidgets('Dive Logs: the way there while no log is kept', (tester) async {
    final services = AppServices(
      capabilities: const Capabilities(desktop: true),
      config: config,
      home: tmp.path,
    );
    Future<void> show({required int kept}) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DiveLogsLink(services: services, kept: kept),
        ),
      ),
    );

    // Logs kept: nothing here (the match button's list leads there).
    await show(kept: 3);
    expect(find.text(noLogsHint), findsNothing);
    expect(find.text(diveLogsButtonLabel), findsNothing);

    await show(kept: 0);
    expect(find.text(noLogsHint), findsOneWidget);
    await tester.tap(find.text(diveLogsButtonLabel));
    expect(services.pageAsked.value, diveLogsTitle);
  });

  testWidgets('the match button: green, orange, red, and the list', (
    tester,
  ) async {
    final dive = Dive(
      startTime: naive(2026, 10, 29, 12),
      endTime: naive(2026, 10, 29, 12, 40),
      waypoints: const [],
      logFilename: '521 Arild.fit',
    );
    final manager = DiveManager()..addDives([dive]);
    final inDive = naive(2026, 10, 29, 12, 5, 9);
    var asked = 0;
    Future<void> show(Map<String, DateTime?>? times, {bool pending = false}) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DiveMatchButton(
                matches: times == null ? null : matchDives(manager, times),
                pending: pending,
                onDiveLogs: () => asked++,
              ),
            ),
          ),
        );
    Color iconColor() => tester
        .widget<Icon>(
          find.descendant(
            of: find.byType(OutlinedButton),
            matching: find.byType(Icon),
          ),
        )
        .color!;

    // Nothing to say; the dates still being read.
    await show(null);
    expect(find.byType(OutlinedButton), findsNothing);
    await show(null, pending: true);
    expect(find.text(matchingText), findsOneWidget);

    await show({'/m/a.mp4': inDive, '/m/b.jpg': inDive});
    expect(find.text('Dive logs: all 2 matched'), findsOneWidget);
    expect(iconColor(), matchedColor);
    await show({'/m/a.mp4': naive(2020), '/m/b.jpg': null});
    expect(find.text('Dive logs: none of 2 matched'), findsOneWidget);
    expect(iconColor(), unmatchedColor);

    await show({'/m/a.mp4': inDive, '/m/b.jpg': naive(2020), '/m/c.jpg': null});
    expect(find.text('Dive logs: 2 of 3 not matched'), findsOneWidget);
    expect(iconColor(), partlyMatchedColor);

    // The list: each file with its dive and the time it was looked up
    // at, a green or a red mark before it.
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();
    expect(find.byType(DiveMatchDialog), findsOneWidget);
    expect(find.text('a.mp4'), findsOneWidget);
    expect(
      find.text('2026-10-29 12:00 (521 Arild.fit) · 2026-10-29 12:05:09'),
      findsOneWidget,
    );
    expect(find.text('$noDiveText · 2020-01-01 00:00:00'), findsOneWidget);
    expect(find.text('$noDiveText · $noDateText'), findsOneWidget);
    final marks = [
      for (final tile in tester.widgetList<ListTile>(find.byType(ListTile)))
        (tile.leading! as Icon).color,
    ];
    expect(marks, [matchedColor, unmatchedColor, unmatchedColor]);
    // A file has no dive: the way to the Dive Logs page.
    await tester.tap(find.text('Dive Logs…'));
    await tester.pumpAndSettle();
    expect(asked, 1);
    expect(find.byType(DiveMatchDialog), findsNothing);
  });

  testWidgets('files on their way from Photos are said, while they are', (
    tester,
  ) async {
    addTearDown(() => photosFetching.value = 0);
    var cancelled = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PhotosFetching(onCancel: () => cancelled++)),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    photosFetching.value = 1;
    await tester.pump();
    expect(find.text('Fetching 1 item from Photos…'), findsOneWidget);
    photosFetching.value = 3;
    await tester.pump();
    expect(find.text('Fetching 3 items from Photos…'), findsOneWidget);
    await tester.tap(find.text(cancelFetchLabel));
    expect(cancelled, 1);
    photosFetching.value = 0;
    await tester.pump();
    expect(find.textContaining('Fetching'), findsNothing);
  });
}
