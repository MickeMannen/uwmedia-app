/// Apple Photos on the Mac as a source and a destination for the desktop
/// pages (user story U1.9, spec §10.50): what was picked in the system's
/// picker is copied into a working folder that the page then reads as any
/// folder, and results wait in a working folder until they are saved
/// into the album chosen.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/engine/media_library.dart';
import 'package:uwmedia_app/engine/mobile_color_batch.dart';

/// What a Photos source shows in place of a folder.
const fromPhotosTooltip = 'From Photos…';
const intoPhotosLabel = 'Save into Photos';

String fromPhotosText(int count) =>
    '$count item${count == 1 ? '' : 's'} from Photos';

String fetchingFromPhotosText(int count) =>
    'Fetching $count item${count == 1 ? '' : 's'} from Photos…';

const cancelFetchLabel = 'Cancel';

/// Says that picked files are on their way from Photos, while they are
/// ([photosFetching]), with a way to give them up; nothing otherwise.
class PhotosFetching extends StatelessWidget {
  const PhotosFetching({super.key, this.onCancel = cancelPhotosFetch});

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: photosFetching,
    builder: (context, count, _) => count == 0
        ? const SizedBox.shrink()
        : Row(
            spacing: 8,
            children: [
              const SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              Flexible(child: Text(fetchingFromPhotosText(count))),
              TextButton(
                onPressed: onCancel,
                child: const Text(cancelFetchLabel),
              ),
            ],
          ),
  );
}

/// The files of [folder] by name (not hidden ones, nor those inside its
/// folders): a working folder holds nothing but media.
List<String> mediaIn(String folder) {
  try {
    return [
      for (final entry in Directory(folder).listSync())
        if (entry is File && !p.basename(entry.path).startsWith('.'))
          entry.path,
    ]..sort();
  } on FileSystemException {
    return const [];
  }
}

// The working folder of each page's last pick, by the page's name.
final _lastPicked = <String, String>{};

/// [folder] is the working folder of [page]'s pick now: the folder of
/// its pick before is removed (owner, 2026-11-19: the copies stayed
/// until a start a day later, and a few videos are gigabytes). Each page
/// has its own, since another page may still be showing its files.
void keepPicked(String page, String folder) {
  final before = _lastPicked[page];
  _lastPicked[page] = folder;
  if (before == null || p.equals(before, folder)) {
    return;
  }
  try {
    Directory(before).deleteSync(recursive: true);
  } on FileSystemException {
    // Swept with the other working folders at a later start.
  }
}

/// Photos and videos picked in Photos, moved into a fresh working folder
/// made by [tempDir]; the folder, or `null` when nothing was picked.
/// With a [page] the folder of that page's pick before is removed
/// ([keepPicked]). Throws a [LibraryException] when a picked file could
/// not be read.
Future<String?> pickFromPhotos(
  MediaLibrary library,
  Directory Function(String prefix) tempDir, {
  String? page,
  bool photos = true,
  bool videos = true,
  bool multiple = true,
}) async {
  final files = await library.pick(
    photos: photos,
    videos: videos,
    multiple: multiple,
  );
  if (files.isEmpty) {
    return null;
  }
  final dir = tempDir('uwmedia_picked_');
  for (final file in files) {
    // Under the name Photos gave it; a second of the same name numbered.
    final name = p.basename(file);
    var target = p.join(dir.path, name);
    for (var n = 1; File(target).existsSync(); n++) {
      target = p.join(
        dir.path,
        '${p.basenameWithoutExtension(name)}_$n${p.extension(name)}',
      );
    }
    try {
      File(file).renameSync(target);
    } on FileSystemException {
      File(file).copySync(target);
    }
  }
  if (page != null) {
    keepPicked(page, dir.path);
  }
  return dir.path;
}

/// Every file of [folder] saved into [album] of Photos (made when it is
/// not there), or into a new album named for now; each saved file is
/// then removed from the folder. Gives what to tell the user, a line for
/// the whole and one for each file that Photos did not take; empty when
/// the folder held nothing.
Future<List<String>> saveFolderIntoPhotos(
  MediaLibrary library,
  String folder, {
  String? album,
  DateTime Function() now = naiveNow,
}) async {
  final files = mediaIn(folder);
  if (files.isEmpty) {
    return const [];
  }
  album ??= runAlbumName(now());
  var saved = 0;
  final problems = <String>[];
  for (final file in files) {
    try {
      await library.saveToAlbum(file, album);
      saved++;
    } on Exception catch (e) {
      problems.add('${p.basename(file)}: not saved into Photos ($e)');
      continue;
    }
    try {
      File(file).deleteSync();
    } on FileSystemException {
      // In Photos already; the working copy goes with the folder later.
    }
  }
  return [
    if (saved > 0)
      'Saved $saved file${saved == 1 ? '' : 's'} into the album "$album" '
          'in Photos.',
    ...problems,
    if (problems.isNotEmpty) 'What was not saved is kept for a day in $folder',
  ];
}

/// What a run that was stopped leaves for Photos: nothing. The working
/// [folder] is emptied (a stopped encode leaves half a file), and the
/// line says so.
String discardStopped(String folder) {
  for (final file in mediaIn(folder)) {
    try {
      File(file).deleteSync();
    } on FileSystemException {
      // Swept with the app's working folders later.
    }
  }
  return 'Stopped: nothing was saved into Photos.';
}
