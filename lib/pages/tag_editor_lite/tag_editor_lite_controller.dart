/// The Tag Editor on a phone (spec §9.1, owner's decisions 2026-11-13):
/// photos and videos picked from the library or the phone's files, their resolved local date,
/// offset and raw date tags shown; one file's date and offset set, or one
/// shift for every file (hours and minutes, and optionally a new offset);
/// the changed files written into corrected copies by the app's own
/// writers and saved into a new album, the originals left as they are.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/metadata/tag_editor.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';
import 'package:uwmedia_app/engine/media_file_dates.dart';
import 'package:uwmedia_app/engine/media_library.dart';
import 'package:uwmedia_app/engine/result_folder.dart';

/// The raw date tags the page shows (E1/E2/E3), by exiftool name.
const liteRawTags = [
  'QuickTime:CreationDate',
  'QuickTime:CreateDate',
  'EXIF:DateTimeOriginal',
  'EXIF:CreateDate',
  'EXIF:OffsetTimeOriginal',
];

/// One picked file: what it says now and the change waiting for it.
class LiteItem {
  LiteItem(this.path, this.tags, {this.error})
    // A picked file is a copy made at the pick, so its own time says
    // nothing about when it was taken: the tags' date, else the name's.
    : local = error == null ? ownLocalTime(tags, path) : null,
      offset = error == null ? _offsetOf(tags) : null;

  final String path;
  final MediaTags tags;

  /// Why the file's dates could not be read; it is listed but not changed.
  final String? error;

  /// The tags to write into its copy; `null` while nothing is changed.
  Map<String, String>? pending;

  String get name => p.basename(path);

  /// The resolved local date (the tags', else the file name's); `null`
  /// when the file has none.
  final DateTime? local;

  /// The offset it was taken in, in minutes east of UTC; `null` when the
  /// tags do not say.
  final int? offset;

  static int? _offsetOf(MediaTags tags) {
    final fromTags = timezoneOffsetMinutes(tags);
    if (fromTags != null) {
      return fromTags;
    }
    try {
      return parseTimezone(tags['EXIF:OffsetTimeOriginal']);
    } on FormatException {
      return null;
    }
  }

  /// The local date and offset after the waiting change.
  (DateTime?, int?) get after {
    final changed = pending;
    if (changed == null) {
      return (local, offset);
    }
    final merged = {...tags, ...changed};
    DateTime? when;
    try {
      when = localCreationDate(merged);
    } on FormatException {
      when = null;
    }
    int? zone = timezoneOffsetMinutes(merged);
    if (zone == null) {
      try {
        zone = parseTimezone(merged['EXIF:OffsetTimeOriginal']);
      } on FormatException {
        zone = null;
      }
    }
    return (when, zone);
  }
}

/// Date text as the page shows and takes it: `2026:05:21 06:58:22`.
String liteDateText(DateTime? time) =>
    time == null ? '—' : pyStrftime(time, tagDateFormat);

class TagEditorLiteController extends ChangeNotifier {
  TagEditorLiteController({required this.library, required this.tempDir});

  final MediaLibrary library;

  /// Makes a working folder for the copies (`appTempDir` in the app).
  final Directory Function(String prefix) tempDir;

  List<LiteItem> items = [];

  /// Counts the picks, so that the page knows its fields show another
  /// file.
  int picks = 0;
  int selected = -1;
  String status = '';
  bool busy = false;
  bool _disposed = false;

  bool get hasChanges => items.any((i) => i.pending != null);

  void _say(String text, {bool working = false}) {
    status = text;
    busy = working;
    notifyListeners();
  }

  /// Photos and videos from the library, or from the phone's files with
  /// [from] (what a camera card or a cable copy left there), their dates
  /// read.
  Future<void> pick({Future<List<String>> Function()? from}) async {
    final List<String> paths;
    try {
      paths = await (from ?? library.pick)();
    } on LibraryException catch (e) {
      _say(e.message);
      return;
    }
    if (_disposed || paths.isEmpty) {
      return;
    }
    items = [
      for (final path in paths)
        if (hasMediaDates(path)) _read(path),
    ];
    final skipped = paths.length - items.length;
    selected = items.isEmpty ? -1 : 0;
    picks++;
    _say(
      'Picked ${items.length} file(s).'
      '${skipped > 0 ? ' $skipped of another type left out.' : ''}',
    );
  }

  static LiteItem _read(String path) {
    try {
      return LiteItem(path, readFileDates(path));
    } on FormatException catch (e) {
      return LiteItem(path, const {}, error: e.message);
    } on FileSystemException catch (e) {
      return LiteItem(path, const {}, error: e.message);
    } on Object catch (e) {
      // A malformed file is this file's problem, not the whole pick's.
      return LiteItem(path, const {}, error: 'could not be read ($e)');
    }
  }

  void select(int index) {
    if (index >= 0 && index < items.length) {
      selected = index;
      notifyListeners();
    }
  }

  /// One file's local date ([dateText], `2026:05:21 06:58:22`) and offset
  /// ([offsetText], `+08:00`; `null` keeps the file's own, or none) set;
  /// the reason when they cannot be.
  String? setDate(int index, String dateText, String? offsetText) {
    final item = items[index];
    final from = item.local;
    if (from == null) {
      return 'This file has no date to change.';
    }
    final to = pyStrptime(dateText.trim(), tagDateFormat);
    if (to == null) {
      return "Not a date: '$dateText' (use 2026:05:21 06:58:22).";
    }
    int? zone;
    if (offsetText != null) {
      try {
        zone = parseTimezone(offsetText.trim());
      } on FormatException {
        zone = null;
      }
      if (zone == null) {
        return "Not an offset: '$offsetText' (use +08:00).";
      }
    }
    final updates = retimeUpdates(
      meta: item.tags,
      path: item.path,
      from: from,
      to: to,
      tzMinutes: zone,
    );
    if (updates == null) {
      return 'That date cannot be stored.';
    }
    item.pending = updates;
    _say(
      '${item.name}: ${liteDateText(to)}'
      '${zone == null ? '' : ' ${tzIso(zone)}'}, not saved yet.',
    );
    return null;
  }

  /// Every file moved by [hours] and [minutes] (either may be negative)
  /// and given [tz] when it is not `null`; the reason when nothing can be.
  String? shiftAll(int hours, int minutes, String? tz) {
    final shift = hours * 60 + minutes;
    int? zone;
    if (tz != null) {
      try {
        zone = parseTimezone(tz);
      } on FormatException {
        zone = null;
      }
      if (zone == null) {
        return "Not an offset: '$tz' (use +08:00).";
      }
    }
    if (shift == 0 && zone == null) {
      return 'Nothing to shift: give hours, minutes or a new offset.';
    }
    var changed = 0;
    for (final item in items) {
      if (item.error != null) {
        continue;
      }
      final updates = shiftUpdates(
        meta: item.tags,
        path: item.path,
        shiftMinutes: shift,
        tzMinutes: zone,
      );
      if (updates != null) {
        item.pending = updates;
        changed++;
      }
    }
    _say(
      '$changed file(s) shifted by ${shiftText(shift)}'
      '${zone == null ? '' : ', offset ${tzIso(zone)}'}, not saved yet.',
    );
    return null;
  }

  void discard() {
    for (final item in items) {
      item.pending = null;
    }
    _say('Changes discarded.');
  }

  /// The album name suggested for the copies.
  String get albumSuggestion =>
      'UWMedia ${pyStrftime(naiveNow(), '%Y-%m-%d %H.%M')}';

  /// The changed files written into corrected copies and saved into the
  /// album [album]; the originals left as they are.
  Future<void> saveCopies(String album) async {
    final name = album.trim();
    if (name.isNotEmpty) {
      await saveCopiesTo(AlbumPlace(library, name));
    }
  }

  /// The same into [place]: an album, or a folder of the phone's files
  /// (the pages' "Save to…", spec §10.112).
  Future<void> saveCopiesTo(SavePlace place) async {
    if (busy) {
      return;
    }
    final changed = [
      for (final item in items)
        if (item.pending != null) item,
    ];
    if (changed.isEmpty) {
      _say('Nothing changed to save.');
      return;
    }
    final folder = tempDir('uwmedia_copies_');
    var saved = 0;
    final failed = <String>[];
    try {
      for (final (i, item) in changed.indexed) {
        if (_disposed) {
          return;
        }
        _say('Saving ${i + 1}/${changed.length}: ${item.name}', working: true);
        final copy = p.join(folder.path, item.name);
        try {
          writeFileDatesCopy(item.path, item.pending!, copy);
          await place.save(copy);
          item.pending = null;
          saved++;
        } on Object catch (e) {
          failed.add('${item.name} (${e is FormatException ? e.message : e})');
        }
      }
    } finally {
      try {
        folder.deleteSync(recursive: true);
      } on FileSystemException {
        // Swept at the next start.
      }
    }
    // "Saved into the album …" as the runs say it, with how many.
    final where = saved == 0
        ? 'No copy was saved.'
        : place.savedText.replaceFirst(
            'Saved',
            'Saved $saved corrected ${saved == 1 ? 'copy' : 'copies'}',
          );
    _say(
      failed.isEmpty
          ? where
          : '$where Could not save ${failed.length}: ${failed.join(', ')}.',
    );
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
