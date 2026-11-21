/// The system's file dialogs, as `file_selector` has them, with what was
/// picked remembered for a sandboxed app (the Mac App Store build, spec
/// §13.5, §10.74): the sandbox lets the app into a file or folder only
/// while the user's pick lasts, and into it again at the next start only
/// through a bookmark made of the pick ([FileAccess]). Outside a sandbox
/// these are `file_selector`'s own.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/services.dart';

export 'package:file_selector/file_selector.dart'
    show FileSaveLocation, XFile, XTypeGroup;

/// The file in the config folder that holds the bookmarks.
const bookmarksFilename = 'bookmarks.json';

/// How many picks are remembered; the oldest go first.
const bookmarksKept = 300;

/// Whether the app runs in the App Sandbox (the system says so to every
/// sandboxed process).
bool get appSandboxed =>
    Platform.isMacOS &&
    Platform.environment.containsKey('APP_SANDBOX_CONTAINER_ID');

/// The picks of a sandboxed app, kept as security-scoped bookmarks and
/// opened again at the start.
class FileAccess {
  FileAccess(this.file, {MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('uwmedia/file_access');

  /// Where the bookmarks are kept.
  final File file;
  final MethodChannel _channel;

  /// The one of the app; `null` outside a sandbox, where nothing needs
  /// remembering.
  static FileAccess? instance;

  Map<String, String> _read() {
    try {
      final json = jsonDecode(file.readAsStringSync());
      if (json is Map<String, dynamic>) {
        return {
          for (final MapEntry(:key, :value) in json.entries)
            if (value is String) key: value,
        };
      }
    } on Object {
      // None yet, or damaged: nothing remembered.
    }
    return {};
  }

  void _write(Map<String, String> bookmarks) {
    try {
      file.parent.createSync(recursive: true);
      final fresh = File('${file.path}.new')
        ..writeAsStringSync(jsonEncode(bookmarks), flush: true);
      fresh.renameSync(file.path);
    } on FileSystemException {
      // Not remembered: the user picks again the next time.
    }
  }

  /// Remembers the pick of [path] (a file or a folder) for the next
  /// starts.
  Future<void> remember(String path) async {
    try {
      final data = await _channel.invokeMethod<Uint8List>('bookmark', {
        'path': path,
      });
      if (data == null) {
        return;
      }
      final bookmarks = _read()
        // The newest last.
        ..remove(path)
        ..[path] = base64Encode(data);
      while (bookmarks.length > bookmarksKept) {
        bookmarks.remove(bookmarks.keys.first);
      }
      _write(bookmarks);
    } on PlatformException {
      // No bookmark: the pick lasts until the app is closed.
    } on MissingPluginException {
      return;
    }
  }

  /// Opens every remembered pick again; one that is gone (the file
  /// removed, the drive not there) is forgotten. Gives how many were
  /// opened.
  Future<int> restore() async {
    final bookmarks = _read();
    var opened = 0;
    var changed = false;
    for (final MapEntry(key: path, value: text) in bookmarks.entries.toList()) {
      try {
        final answer = await _channel.invokeMapMethod<String, Object?>(
          'resolve',
          {'bookmark': base64Decode(text)},
        );
        final now = answer?['path'];
        if (now is! String) {
          bookmarks.remove(path);
          changed = true;
          continue;
        }
        opened++;
        if (answer?['fresh'] case final Uint8List fresh) {
          // The system asked for the bookmark to be made again.
          bookmarks[path] = base64Encode(fresh);
          changed = true;
        }
      } on PlatformException {
        bookmarks.remove(path);
        changed = true;
      } on MissingPluginException {
        return opened;
      } on FormatException {
        bookmarks.remove(path);
        changed = true;
      }
    }
    if (changed) {
      _write(bookmarks);
    }
    return opened;
  }
}

Future<void> _remember(Iterable<String?> paths) async {
  final access = FileAccess.instance;
  if (access == null) {
    return;
  }
  for (final path in paths) {
    if (path != null && path.isNotEmpty) {
      await access.remember(path);
    }
  }
}

const _androidPicks = MethodChannel('uwmedia/file_picks');

/// The types the Android picker offers for [groups]: every group's
/// `mimeTypes`, or none (every file) when a group has none, as a dive log
/// group, whose types Android does not know.
List<String> pickMimeTypes(List<fs.XTypeGroup> groups) {
  if (groups.isEmpty || groups.any((g) => g.mimeTypes?.isEmpty ?? true)) {
    return const [];
  }
  return {for (final g in groups) ...g.mimeTypes!}.toList();
}

/// The files picked on Android, copied into the app's cache a piece at a
/// time under their own names (MainActivity.kt): `file_selector` read
/// each one whole into memory first, and a large video closed the app.
Future<List<fs.XFile>> _pickOnAndroid(
  List<fs.XTypeGroup> groups, {
  required bool multiple,
}) async {
  final picked = await _androidPicks.invokeListMethod<Map<Object?, Object?>>(
    'open',
    {'mimeTypes': pickMimeTypes(groups), 'multiple': multiple},
  );
  return [
    for (final file in picked ?? const <Map<Object?, Object?>>[])
      fs.XFile(file['path']! as String, name: file['name']! as String),
  ];
}

/// `file_selector`'s `openFile`.
Future<fs.XFile?> openFile({
  List<fs.XTypeGroup> acceptedTypeGroups = const [],
  String? initialDirectory,
  String? confirmButtonText,
}) async {
  if (Platform.isAndroid) {
    return (await _pickOnAndroid(
      acceptedTypeGroups,
      multiple: false,
    )).firstOrNull;
  }
  final file = await fs.openFile(
    acceptedTypeGroups: acceptedTypeGroups,
    initialDirectory: initialDirectory,
    confirmButtonText: confirmButtonText,
  );
  await _remember([file?.path]);
  return file;
}

/// `file_selector`'s `openFiles`.
Future<List<fs.XFile>> openFiles({
  List<fs.XTypeGroup> acceptedTypeGroups = const [],
  String? initialDirectory,
  String? confirmButtonText,
}) async {
  if (Platform.isAndroid) {
    return _pickOnAndroid(acceptedTypeGroups, multiple: true);
  }
  final files = await fs.openFiles(
    acceptedTypeGroups: acceptedTypeGroups,
    initialDirectory: initialDirectory,
    confirmButtonText: confirmButtonText,
  );
  await _remember(files.map((file) => file.path));
  return files;
}

/// `file_selector`'s `getDirectoryPath`.
Future<String?> getDirectoryPath({
  String? initialDirectory,
  String? confirmButtonText,
}) async {
  final folder = await fs.getDirectoryPath(
    initialDirectory: initialDirectory,
    confirmButtonText: confirmButtonText,
  );
  await _remember([folder]);
  return folder;
}

/// `file_selector`'s `getSaveLocation`. The file to save is not there
/// yet, so its folder cannot be remembered by it: the pick lasts until
/// the app is closed.
Future<fs.FileSaveLocation?> getSaveLocation({
  List<fs.XTypeGroup> acceptedTypeGroups = const [],
  String? initialDirectory,
  String? suggestedName,
  String? confirmButtonText,
}) => fs.getSaveLocation(
  acceptedTypeGroups: acceptedTypeGroups,
  initialDirectory: initialDirectory,
  suggestedName: suggestedName,
  confirmButtonText: confirmButtonText,
);
