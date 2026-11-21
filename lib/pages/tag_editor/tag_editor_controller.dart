/// The Tag Editor page's state (Python `backends/tag_editor_backend.py`):
/// a folder of media, the four date tags of the file picked with their
/// guidance, DJI's corrected dates, writing the tags, the DJI fix and a
/// timezone for every file of the folder, and the viewer of all of a
/// file's tags. Nothing is kept between sessions but the folder the
/// dialog starts in, as in Python.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/metadata/tag_editor.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/engine/app_log.dart';
import 'package:uwmedia_app/engine/desktop/exiftool.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';

/// The folder the media dialog starts in, kept in the settings' fields.
const tagEditorMediaDirField = 'tag_editor_media_dialog_dir';

const noDirectoryText = 'No directory selected';
const djiDetectedText =
    'DJI file detected: values calculated from OriginalFilePath.';

/// The tags read for the file picked: the four edited and DJI's name.
final List<String> _tagsToGet = [
  for (final g in tagGuide) g.tag,
  'QuickTime:OriginalFilePath',
];

/// What the page needs of exiftool.
abstract interface class TagEditorEngine {
  /// See [Exiftool.tags].
  Future<Map<String, String>> tags(String path, List<String> names);

  /// See [Exiftool.metadata].
  Future<MediaTags?> metadata(String path);

  /// See [Exiftool.setTags].
  Future<void> setTags(String path, Map<String, Object?> tags);
}

/// exiftool on the desktop.
class DesktopTagEditorEngine implements TagEditorEngine {
  DesktopTagEditorEngine(this.exiftool);

  final Exiftool exiftool;

  @override
  Future<Map<String, String>> tags(String path, List<String> names) =>
      exiftool.tags(path, names);

  @override
  Future<MediaTags?> metadata(String path) => exiftool.metadata(path);

  @override
  Future<void> setTags(String path, Map<String, Object?> tags) =>
      exiftool.setTags(path, tags);
}

/// A question to answer before a change to every file.
typedef Confirmation = ({String title, String message});

/// One row of the metadata viewer.
typedef MetadataRow = ({String tag, Object? value});

class TagEditorController extends ChangeNotifier {
  TagEditorController({
    required this.config,
    required this.home,
    required this.engine,
    required Duration systemOffset,
  }) {
    final local = localTzOffsetString(systemOffset);
    tzOptions = [if (!tzOffsets.contains(local)) local, ...tzOffsets];
    _currentTz = local;
  }

  final ConfigStore config;
  final String home;

  /// exiftool; throws when it is missing.
  final Future<TagEditorEngine> Function() engine;

  /// The offsets offered, the system's own first when the list lacks it.
  late final List<String> tzOptions;

  String _dirLabel = noDirectoryText;
  List<String> _files = const [];
  int _selected = -1;
  String? _current;
  Map<String, String> _currentTags = const {};
  String _fileName = 'None';
  bool _dji = false;
  final Map<String, String> _values = {for (final g in tagGuide) g.tag: ''};
  late String _currentTz;
  String _currentTzMode = tzModeOptions.first;
  bool _busy = false;
  String _status = '';
  int _shown = 0;
  bool _disposed = false;

  String get dirLabel => _dirLabel;
  List<String> get fileNames => [for (final f in _files) p.basename(f)];
  int get selectedIndex => _selected;
  String get selectedFileName => _fileName;
  bool get djiVisible => _dji;
  bool get viewMetadataEnabled => _current != null;
  bool get busy => _busy;
  String get statusText => _status;
  String get currentTz => _currentTz;
  String get currentTzMode => _currentTzMode;

  /// The value in the field of [tag].
  String tagValue(String tag) => _values[tag] ?? '';

  /// The guidance under a tag's field.
  static String helpOf(TagGuide g) =>
      'Intended: ${g.tz}  |  Example: ${g.example}  —  ${g.hint}';

  String get mediaDialogDir => config.dialogDirFor(
    tagEditorMediaDirField,
    home: home,
    start: StartFolder.pictures,
  );

  set currentTz(String value) {
    if (value != _currentTz) {
      _currentTz = value;
      notifyListeners();
    }
  }

  set currentTzMode(String value) {
    if (value != _currentTzMode) {
      _currentTzMode = value;
      notifyListeners();
    }
  }

  void setTagValue(String tag, String value) {
    _values[tag] = value;
    notifyListeners();
  }

  // What a write did, into the app's log (spec §10.76): a report then
  // says which files the Tag Editor changed or could not.
  static void _log(String text) => AppLog.note('Tag Editor', text);

  void _setStatus(String text, {bool busy = false}) {
    _status = text;
    _busy = busy;
    notifyListeners();
  }

  /// The folder picked in the dialog: its media files by name, the first
  /// of them shown.
  /// Without [remember] the dialog's folder is left as it was, and
  /// [label] is shown for the folder (files picked in Photos lie in a
  /// working folder).
  Future<void> chooseDirectory(
    String path, {
    bool remember = true,
    String? label,
  }) async {
    if (remember) {
      try {
        config.rememberDialogDir(tagEditorMediaDirField, path);
      } on FileSystemException {
        // The config folder cannot be written: only not kept.
      }
    }
    _dirLabel = label ?? path;
    List<String> found;
    try {
      found = [for (final entry in Directory(path).listSync()) entry.path];
    } on FileSystemException catch (e) {
      found = const [];
      _status = 'Cannot read the folder: ${e.message}';
    }
    await _list(found);
  }

  /// Files picked one by one in the dialog (spec §10.67(g)): those the
  /// page reads, listed as a folder's are.
  Future<void> chooseFiles(List<String> paths) async {
    if (paths.isEmpty) {
      return;
    }
    try {
      config.rememberDialogDir(tagEditorMediaDirField, p.dirname(paths.first));
    } on FileSystemException {
      // The config folder cannot be written: only not kept.
    }
    final folders = {for (final path in paths) p.dirname(path)};
    await _list(
      paths,
      label: (count) =>
          '$count file${count == 1 ? '' : 's'}'
          '${folders.length == 1 ? ' in ${folders.single}' : ''}',
    );
  }

  // [label] names the place by how many of [paths] are listed.
  Future<void> _list(
    List<String> paths, {
    String Function(int count)? label,
  }) async {
    // A file still being read from the last folder is not shown.
    _shown++;
    // Links to files count, as Python's is_file() follows them.
    final found = [
      for (final path in paths)
        if (FileSystemEntity.isFileSync(path) &&
            tagEditorExtensions.contains(pySuffix(path).toLowerCase()))
          path,
    ];
    // By name whatever the case, the listing's order between equals
    // (Python's sort is stable).
    final order = [for (var i = 0; i < found.length; i++) i]
      ..sort((a, b) {
        final byName = p
            .basename(found[a])
            .toLowerCase()
            .compareTo(p.basename(found[b]).toLowerCase());
        return byName != 0 ? byName : a.compareTo(b);
      });
    final files = [for (final i in order) found[i]];
    if (label != null) {
      _dirLabel = label(files.length);
    }
    _files = files;
    _current = null;
    _selected = -1;
    notifyListeners();
    if (files.isNotEmpty) {
      await selectFile(0);
    }
  }

  /// Shows the file at [index] of the list.
  Future<void> selectFile(int index) async {
    if (index < 0 || index >= _files.length) {
      return;
    }
    _selected = index;
    await _display(_files[index]);
  }

  // Reads the file's tags into the fields; DJI's corrected values in
  // place of the file's own when it is a DJI file.
  Future<void> _display(String path) async {
    final ticket = ++_shown;
    _current = path;
    _fileName = p.basename(path);
    notifyListeners();
    Map<String, String> tags;
    try {
      tags = await (await engine()).tags(path, _tagsToGet);
    } on Exception catch (e) {
      tags = const {};
      _status = _reason(e);
    }
    if (ticket != _shown || _disposed) {
      // Another file was picked meanwhile.
      return;
    }
    _currentTags = tags;
    final calculated = calculateDjiDatetimes(path, tags);
    _dji = calculated != null;
    for (final g in tagGuide) {
      _values[g.tag] = (calculated ?? tags)[g.tag] ?? '';
    }
    notifyListeners();
  }

  /// The fields back to what the file holds.
  Future<void> revert() async {
    final current = _current;
    if (current != null) {
      await _display(current);
    }
  }

  /// Writes the fields that differ from the file's tags.
  Future<void> writeTags() async {
    final current = _current;
    if (current == null || _busy) {
      return;
    }
    final updates = <String, Object?>{
      for (final MapEntry(:key, :value) in _values.entries)
        if (value.trim() != (_currentTags[key] ?? '')) key: value.trim(),
    };
    if (updates.isEmpty) {
      _setStatus('No changes detected to update.');
      return;
    }
    _busy = true;
    notifyListeners();
    try {
      await (await engine()).setTags(current, updates);
      if (_current == current) {
        await _display(current);
      }
      _setStatus('Updated ${updates.length} tags successfully.');
      _log('${p.basename(current)}: ${updates.keys.join(', ')} written');
    } on Exception catch (e) {
      _setStatus('Failed to update tags: ${_reason(e)}');
      _log('${p.basename(current)}: could not write (${_reasonLine(e)})');
    }
  }

  /// The question before Update All (DJI); `null` with the reason in the
  /// status when there is nothing to do.
  Confirmation? askUpdateAll() {
    if (_files.isEmpty) {
      _setStatus('No files in the list to update.');
      return null;
    }
    return (
      title: 'Confirm Update All',
      message:
          'Scan all ${_files.length} files and automatically update DJI '
          'videos with corrected datetimes?',
    );
  }

  /// Every DJI file of the list given its corrected dates.
  Future<void> updateAll() async {
    if (_busy) {
      return;
    }
    final files = _files;
    _setStatus('Processing 0/${files.length}...', busy: true);
    var updated = 0;
    var errors = 0;
    for (var i = 0; i < files.length && !_disposed; i++) {
      final path = files[i];
      _setStatus(
        'Processing ${i + 1}/${files.length}: ${p.basename(path)}',
        busy: true,
      );
      try {
        final tools = await engine();
        final tags = await tools.tags(path, _tagsToGet);
        final calculated = calculateDjiDatetimes(path, tags);
        if (calculated == null) {
          continue;
        }
        final updates = {
          for (final g in tagGuide)
            if (calculated[g.tag] != (tags[g.tag] ?? ''))
              g.tag: calculated[g.tag],
        };
        if (updates.isNotEmpty) {
          await tools.setTags(path, updates);
          updated++;
        }
      } on Exception catch (e) {
        errors++;
        _log('${p.basename(path)}: DJI dates not written (${_reasonLine(e)})');
      }
    }
    await _redisplay();
    _setStatus(
      errors > 0
          ? 'Updated $updated files. Failed: $errors.'
          : 'Successfully updated $updated files.',
    );
    _log('Update All of ${files.length} files: $_status');
  }

  int? _tzMinutes() {
    try {
      return parseTimezone(_currentTz);
    } on FormatException {
      return null;
    }
  }

  /// The question before a timezone for every file; `null` with the
  /// reason in the status when there is nothing to do.
  Confirmation? askApplyTimezone() {
    if (_files.isEmpty) {
      _setStatus('No files in the list to update.');
      return null;
    }
    if (_tzMinutes() == null) {
      _setStatus("Invalid timezone format: '$_currentTz'.");
      return null;
    }
    return (
      title: 'Confirm Batch Timezone Update',
      message:
          'Update all ${_files.length} files in the directory to timezone '
          '$_currentTz?\n\nMode: $_currentTzMode',
    );
  }

  /// The timezone, by the mode, written to every file of the list.
  Future<void> applyTimezone() async {
    final minutes = _tzMinutes();
    if (_busy || minutes == null) {
      return;
    }
    final files = _files;
    final mode = _currentTzMode;
    _setStatus('Updating 0/${files.length}...', busy: true);
    var updated = 0;
    var errors = 0;
    for (var i = 0; i < files.length && !_disposed; i++) {
      final path = files[i];
      _setStatus(
        'Updating ${i + 1}/${files.length}: ${p.basename(path)}',
        busy: true,
      );
      try {
        final tools = await engine();
        final updates = batchTimezoneUpdates(
          meta: await tools.metadata(path),
          path: path,
          mode: mode,
          tzMinutes: minutes,
          fileModified: fileModified(path),
        );
        if (updates != null) {
          await tools.setTags(path, updates);
          updated++;
        }
      } on Exception catch (e) {
        errors++;
        _log('${p.basename(path)}: timezone not written (${_reasonLine(e)})');
      }
    }
    await _redisplay();
    _setStatus(
      errors > 0
          ? 'Updated timezone for $updated files. Failed: $errors.'
          : 'Successfully updated timezone for $updated files.',
    );
    _log('Timezone $_currentTz ($mode) for ${files.length} files: $_status');
  }

  /// The question before Shift all files: every file of the list moved by
  /// [hours] and [minutes] (both may be negative; they add up), and given
  /// the offset [tz] when there is one. `null` with the reason in the
  /// status when there is nothing to do.
  Confirmation? askShiftAll(int hours, int minutes, String? tz) {
    if (_files.isEmpty) {
      _setStatus('No files in the list to update.');
      return null;
    }
    final total = hours * 60 + minutes;
    if (tz != null && _timezoneOf(tz) == null) {
      _setStatus("Invalid timezone format: '$tz'.");
      return null;
    }
    if (total == 0 && tz == null) {
      _setStatus('Nothing to shift: give hours, minutes or a new offset.');
      return null;
    }
    return (
      title: 'Confirm Shift All Files',
      message:
          'Shift the date of all ${_files.length} files in the directory by '
          '${shiftText(total)}'
          '${tz == null ? ', keeping their offsets' : ' and set their offset to $tz'}?',
    );
  }

  static int? _timezoneOf(String text) {
    try {
      return parseTimezone(text);
    } on FormatException {
      return null;
    }
  }

  /// Every file of the list shifted (see [askShiftAll]), one after the
  /// other, with the files that could not be written named at the end.
  Future<void> shiftAll(int hours, int minutes, String? tz) async {
    if (_busy) {
      return;
    }
    final shift = hours * 60 + minutes;
    final tzMinutes = tz == null ? null : _timezoneOf(tz);
    final files = _files;
    _setStatus('Shifting 0/${files.length}...', busy: true);
    var updated = 0;
    final failed = <String>[];
    for (var i = 0; i < files.length && !_disposed; i++) {
      final path = files[i];
      final name = p.basename(path);
      _setStatus('Shifting ${i + 1}/${files.length}: $name', busy: true);
      try {
        final tools = await engine();
        final updates = shiftUpdates(
          meta: await tools.metadata(path),
          path: path,
          shiftMinutes: shift,
          tzMinutes: tzMinutes,
          fileModified: fileModified(path),
        );
        if (updates == null) {
          failed.add('$name (no date)');
          continue;
        }
        await tools.setTags(path, updates);
        updated++;
      } on Exception catch (e) {
        failed.add('$name (${_reason(e).trim()})');
      }
    }
    await _redisplay();
    _setStatus(
      failed.isEmpty
          ? 'Shifted $updated files by ${shiftText(shift)}.'
          : 'Shifted $updated files by ${shiftText(shift)}. Could not '
                'write ${failed.length}: ${failed.join(', ')}.',
    );
    _log(
      'Shift of ${files.length} files'
      '${tz == null ? '' : ', offset $tz'}: $_status',
    );
  }

  // A reason on one line for the log.
  static String _reasonLine(Exception e) =>
      _reason(e).trim().replaceAll(RegExp(r'\s*\n\s*'), ' ');

  Future<void> _redisplay() async {
    final current = _current;
    if (current != null) {
      await _display(current);
    }
  }

  /// Every tag of the file shown, sorted by name whatever the case, with
  /// the viewer's title; `null` with the reason in the status when there
  /// are none, or while a batch runs.
  Future<({String title, List<MetadataRow> rows})?> allMetadata() async {
    final current = _current;
    if (current == null || _busy) {
      return null;
    }
    MediaTags? meta;
    try {
      meta = await (await engine()).metadata(current);
    } on Exception catch (e) {
      _setStatus('Failed to load metadata: ${_reason(e)}');
      return null;
    }
    if (meta == null || meta.isEmpty) {
      _setStatus('No metadata could be extracted from this file.');
      return null;
    }
    final keys = meta.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return (
      title: 'Metadata Viewer - ${p.basename(current)}',
      rows: [
        // Python's str(None).
        for (final key in keys)
          (tag: key, value: meta[key] == null ? 'None' : '${meta[key]}'),
      ],
    );
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }
}

String _reason(Exception e) => switch (e) {
  FormatException(:final message) => message,
  EngineException() => e.toString(),
  _ => '$e',
};
