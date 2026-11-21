// Where a phone run's results go: the folder kept in the settings, and
// the two places as a run uses them.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/engine/app_log.dart';
import 'package:uwmedia_app/engine/media_library.dart';
import 'package:uwmedia_app/engine/result_folder.dart';

class FakeFolders implements ResultFolders {
  ResultFolder? offered;
  bool refuse = false;
  final saved = <(String name, String bookmark)>[];

  @override
  Future<ResultFolder?> pick() async => offered;

  @override
  Future<void> save(String path, ResultFolder folder) async {
    if (refuse) {
      throw const LibraryException('The folder is no longer there.');
    }
    saved.add((p.basename(path), folder.bookmark));
  }
}

class _Library implements MediaLibrary {
  final saved = <(String, String)>[];
  var inAlbum = true;

  @override
  Future<List<String>> pick({
    bool photos = true,
    bool videos = true,
    bool multiple = true,
  }) async => const [];

  @override
  Future<bool> saveToAlbum(String path, String album) async {
    saved.add((p.basename(path), album));
    return inAlbum;
  }
}

void main() {
  late Directory tmp;
  late ConfigStore config;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('uwmedia_result_folder_');
    config = ConfigStore(() => Directory(p.join(tmp.path, 'config')));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('the folder is kept in the settings, beside what is there', () {
    expect(keptResultFolder(config), isNull);
    expect(keptSavePlace(config, FakeFolders()), isNull);
    config.setField('source', '/media');

    keepResultFolder(config, (name: 'Dives', bookmark: 'Ym9va21hcms='));
    expect(keptResultFolder(config), (name: 'Dives', bookmark: 'Ym9va21hcms='));
    expect(config.fields()['source'], '/media');
    // Another store on the same folder: the next start.
    final again = ConfigStore(() => Directory(p.join(tmp.path, 'config')));
    expect(keptResultFolder(again)?.name, 'Dives');

    // Back to the album.
    keepResultFolder(config, null);
    expect(keptResultFolder(config), isNull);
    expect(config.fields()['source'], '/media');
  });

  test('what is kept but is no folder is none', () {
    for (final kept in <Object?>[
      'Dives',
      {'name': 'Dives'},
      {'name': 'Dives', 'bookmark': ''},
      {'name': 3, 'bookmark': 'Ym9v'},
    ]) {
      config.updateSettings({resultFolderKey: kept});
      expect(keptResultFolder(config), isNull, reason: '$kept');
    }
  });

  test('the two places', () async {
    final library = _Library();
    final album = AlbumPlace(library, 'UWMedia 2026-11-16 10.00');
    await album.save('/work/a.mp4');
    expect(library.saved, [('a.mp4', 'UWMedia 2026-11-16 10.00')]);
    expect(album.savedText, 'Saved into the album "UWMedia 2026-11-16 10.00".');

    final folders = FakeFolders();
    keepResultFolder(config, (name: 'Dives', bookmark: 'Ym9v'));
    final place = keptSavePlace(config, folders)!;
    await place.save('/work/b.mp4');
    expect(folders.saved, [('b.mp4', 'Ym9v')]);
    expect(place.savedText, 'Saved into the folder "Dives".');
    expect(library.saved, hasLength(1));
  });

  test('each save goes into the app\'s log', () async {
    final log = AppLog.instance = AppLog(File(p.join(tmp.path, 'app.log')));
    addTearDown(() => AppLog.instance = null);
    await AlbumPlace(_Library(), 'Reef').save('/work/a.mp4');
    await AlbumPlace(_Library()..inAlbum = false, 'Reef').save('/work/b.jpg');
    keepResultFolder(config, (name: 'Dives', bookmark: 'Ym9v'));
    await keptSavePlace(config, FakeFolders())!.save('/work/c.mp4');
    expect(log.tail().map((l) => l.substring(20)), [
      '[Photos] a.mp4: saved into "Reef"',
      '[Photos] b.jpg: saved, not into "Reef" (no access)',
      '[Files] c.mp4: saved into "Dives"',
    ]);
  });

  test('an album that Photos does not let the app have', () async {
    final library = _Library()..inAlbum = false;
    final album = AlbumPlace(library, 'UWMedia 2026-11-17 10.00');
    await album.save('/work/a.mp4');
    expect(library.saved, [('a.mp4', 'UWMedia 2026-11-17 10.00')]);
    expect(album.savedText, savedWithoutAlbumText);
  });
}
