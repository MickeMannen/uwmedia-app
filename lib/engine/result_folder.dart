/// Where a phone run's results go (owner, 2026-11-16): a new album of
/// the photo library, or a folder of the phone's files that the user
/// picked (iCloud Drive, "On My iPhone", a drive). The app may write into
/// such a folder only through the leave the system's picker gave it, kept
/// as a bookmark that outlives the app's restart (iOS: a security-scoped
/// bookmark; Android: the address of the document tree, its leave taken
/// for good).
library;

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/engine/app_log.dart';
import 'package:uwmedia_app/engine/media_library.dart';

/// A folder of the phone's files: what the pages call it, and the
/// system's bookmark of it (iOS: base64; Android: the tree's address).
typedef ResultFolder = ({String name, String bookmark});

/// The settings key the chosen folder is kept under; none is the album.
const resultFolderKey = 'result_folder';

/// The folder kept in the settings; `null` when the results go into an
/// album.
ResultFolder? keptResultFolder(ConfigStore config) {
  final kept = config.settings()[resultFolderKey];
  if (kept is! Map) {
    return null;
  }
  final name = kept['name'];
  final bookmark = kept['bookmark'];
  return name is String && bookmark is String && bookmark.isNotEmpty
      ? (name: name, bookmark: bookmark)
      : null;
}

/// Keeps [folder] as where the results go; `null` is the album again.
void keepResultFolder(ConfigStore config, ResultFolder? folder) =>
    config.updateSettings({
      resultFolderKey: folder == null
          ? null
          : {'name': folder.name, 'bookmark': folder.bookmark},
    });

/// The settings key of the album the results go into when no folder is
/// kept; none is a new album for each run, named for when it started.
const resultAlbumKey = 'result_album';

/// The album kept in the settings (owner, 2026-11-17: chosen once, for
/// every run and the next start); `null` for a new one each run.
String? keptResultAlbum(ConfigStore config) {
  final kept = config.settings()[resultAlbumKey];
  return kept is String && kept.trim().isNotEmpty ? kept.trim() : null;
}

/// Keeps [album] as where the results go, in place of a folder; `null`
/// is a new album each run again.
void keepResultAlbum(ConfigStore config, String? album) =>
    config.updateSettings({
      resultAlbumKey: album == null || album.trim().isEmpty
          ? null
          : album.trim(),
      resultFolderKey: null,
    });

/// The albums of the photo library by name, to choose one from; none
/// where the library shows the app no album (Android; iOS without full
/// access).
Future<List<String>> photoAlbums() async {
  try {
    return await const MethodChannel('uwmedia/media_library')
            .invokeListMethod<String>('albums') ??
        const [];
  } on MissingPluginException {
    return const [];
  } on PlatformException {
    return const [];
  }
}

/// The folders of the phone's files, as far as a run needs them.
abstract interface class ResultFolders {
  /// A folder picked in the system's picker; `null` when none was.
  Future<ResultFolder?> pick();

  /// The file at [path] copied into [folder] under its own name (numbered
  /// when the folder has one of that name). Throws a [LibraryException]
  /// when the folder is gone or does not take it.
  Future<void> save(String path, ResultFolder folder);
}

/// The folders through the runner's own channel (iOS: the document
/// picker and a security-scoped bookmark; Android: the system's folder
/// picker and a document tree, `MediaLibrary.kt`).
class PlatformResultFolders implements ResultFolders {
  const PlatformResultFolders();

  static const _channel = MethodChannel('uwmedia/media_library');

  @override
  Future<ResultFolder?> pick() async {
    try {
      final picked = await _channel.invokeMapMethod<String, Object?>(
        'pickFolder',
      );
      final name = picked?['name'];
      final bookmark = picked?['bookmark'];
      return name is String && bookmark is String
          ? (name: name, bookmark: bookmark)
          : null;
    } on PlatformException catch (e) {
      throw LibraryException(e.message ?? 'The folder could not be opened');
    }
  }

  @override
  Future<void> save(String path, ResultFolder folder) async {
    try {
      await _channel.invokeMethod<void>('saveToFolder', {
        'path': path,
        'bookmark': folder.bookmark,
      });
    } on PlatformException catch (e) {
      throw LibraryException(e.message ?? 'The folder did not take the file');
    }
  }
}

/// Where the results of one run are saved, and how the run says so.
abstract interface class SavePlace {
  Future<void> save(String path);

  /// The line of a run that saved something.
  String get savedText;
}

/// What a run says when Photos took the files but let the app have no
/// album for them.
const savedWithoutAlbumText =
    'Saved into Photos, but not into an album: for that UWMedia needs full '
    'access (Settings, Apps, UWMedia, Photos).';

/// The album [album] of the photo library.
class AlbumPlace implements SavePlace {
  AlbumPlace(this.library, this.album);

  final MediaLibrary library;
  final String album;

  // Whether Photos kept a file out of the album.
  var _withoutAlbum = false;

  @override
  Future<void> save(String path) async {
    // Each save into the app's log (spec §10.76), and one that failed.
    final name = p.basename(path);
    try {
      if (!await library.saveToAlbum(path, album)) {
        _withoutAlbum = true;
        AppLog.note('Photos', '$name: saved, not into "$album" (no access)');
        return;
      }
    } on Object catch (e) {
      AppLog.note('Photos', '$name: not saved into "$album" ($e)');
      rethrow;
    }
    AppLog.note('Photos', '$name: saved into "$album"');
  }

  @override
  String get savedText =>
      _withoutAlbum ? savedWithoutAlbumText : 'Saved into the album "$album".';
}

/// A folder of the phone's files.
class FolderPlace implements SavePlace {
  const FolderPlace(this.folders, this.folder);

  final ResultFolders folders;
  final ResultFolder folder;

  @override
  Future<void> save(String path) async {
    final name = p.basename(path);
    try {
      await folders.save(path, folder);
    } on Object catch (e) {
      AppLog.note('Files', '$name: not saved into "${folder.name}" ($e)');
      rethrow;
    }
    AppLog.note('Files', '$name: saved into "${folder.name}"');
  }

  @override
  String get savedText => 'Saved into the folder "${folder.name}".';
}

/// Where a run started now saves: the folder kept in the settings, else
/// the album kept there (into [library]); `null` for a new album.
SavePlace? keptSavePlace(
  ConfigStore config,
  ResultFolders folders, [
  MediaLibrary? library,
]) {
  final folder = keptResultFolder(config);
  if (folder != null) {
    return FolderPlace(folders, folder);
  }
  final album = keptResultAlbum(config);
  return album == null || library == null ? null : AlbumPlace(library, album);
}
