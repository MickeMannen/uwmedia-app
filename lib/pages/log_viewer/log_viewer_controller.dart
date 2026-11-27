/// The Log Viewer page's state (Python `backends/log_viewer_backend.py`'s
/// `LogViewerBackend`): a working list of dives from the logs opened, the
/// one selected with its details and samples table, and the two tools for
/// Garmin FIT logs, Adjust time and Merge, which save a new file and add
/// it to the list. The logs themselves are never changed.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/pages/log_viewer.dart';
import 'package:uwmedia_app/core/pages/log_viewer_tools.dart' as tools;
import 'package:uwmedia_app/core/parsers/fit_merge.dart';
import 'package:uwmedia_app/core/parsers/fit_time.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';
import 'package:uwmedia_app/engine/dive_cache.dart';
import 'package:uwmedia_app/engine/log_files.dart';

/// Reads the logs at the paths; by default through the app's cache, on
/// other isolates.
typedef LogReader = Future<LogRead> Function(
  List<String> paths,
  TankConfig tanks,
);

/// A Save As dialog: where to save, starting at [suggested]; `null` when
/// cancelled.
typedef SaveDialog = Future<String?> Function(String suggested, String title);

// Through the app's cache: a log another page has read, or this one
// before, is not parsed again (spec §10.106).
Future<LogRead> _readCached(List<String> paths, TankConfig tanks) =>
    diveCache.read(paths, tanks);

class LogViewerController extends ChangeNotifier {
  LogViewerController({
    required this.config,
    required this.home,
    this.reader = _readCached,
  });

  final ConfigStore config;
  final String home;
  final LogReader reader;

  List<Dive> _dives = [];
  List<DiveRow> _rows = [];
  List<String> _files = [];
  List<String> _warnings = [];
  String _message = '';
  bool _busy = false;
  int _current = -1;
  DiveDetails? _selected;
  List<SampleRow> _allRows = [];
  String _filter = '';
  bool _disposed = false;
  // Worked out when the selection or the list changes (they look at the
  // disk), not on every rebuild.
  bool _canAdjust = false;
  List<Dive> _mergeWith = const [];

  List<DiveRow> get rows => _rows;
  int get diveCount => _dives.length;
  List<String> get files => _files;
  List<String> get warnings => _warnings;
  String get message => _message;
  bool get busy => _busy;
  int get currentRow => _current;

  /// The selected dive's details, `null` when none is selected.
  DiveDetails? get selected => _selected;

  /// The unit system the settings name now.
  UnitSystem get units => normalizeUnits(config.settings()['units']);

  /// The folder the dialogs open in: the last one used, else Downloads,
  /// else Documents, else home.
  String get dialogFolder {
    final documents = p.join(home, 'Documents');
    return config.dialogDirFor(
      lastFolderField,
      home: Directory(documents).existsSync() ? documents : home,
      start: StartFolder.downloads,
    );
  }

  void _rememberFolder(String folder) {
    try {
      config.rememberDialogDir(lastFolderField, folder);
    } on FileSystemException {
      // The config folder cannot be written: only not kept.
    }
  }

  void _setMessage(String text) {
    _message = text;
    notifyListeners();
  }

  // -- opening -------------------------------------------------------------

  /// The logs of a folder picked in the dialog. Without [remember] the
  /// dialogs' folder is left as it was (the app's own folder of logs).
  Future<void> addFolder(String folder, {bool remember = true}) async {
    if (remember) {
      _rememberFolder(folder);
    }
    List<String> found;
    try {
      found = logFilesIn(folder);
    } on FileSystemException catch (e) {
      _setMessage('Cannot read ${p.basename(folder)}: ${e.message}');
      return;
    }
    if (found.isEmpty) {
      _setMessage('No dive logs in ${p.basename(folder)}.');
      return;
    }
    await _read(found);
  }

  /// Log files picked in the dialog.
  Future<void> addFiles(List<String> paths) async {
    if (paths.isNotEmpty) {
      _rememberFolder(p.dirname(paths.first));
      await _read(paths);
    }
  }

  Future<void> _read(List<String> paths) async {
    if (_busy || _disposed) {
      return;
    }
    _busy = true;
    _setMessage(
      'Reading ${paths.length} file${paths.length != 1 ? 's' : ''}...',
    );
    LogRead read;
    try {
      read = await reader(paths, config.tankConfig().tanks);
    } on Object catch (e) {
      read = (dives: const [], warnings: ['Could not read the logs: $e']);
    }
    if (!_disposed) {
      _applyRead(read);
    }
  }

  void _applyRead(LogRead read) {
    bool same(Dive a, Dive b) =>
        a.logPath == b.logPath && a.startTime == b.startTime;
    final current = _current >= 0 ? _dives[_current] : null;
    final added = [
      for (final dive in read.dives)
        if (!_dives.any((known) => same(known, dive))) dive,
    ];
    final skipped = read.dives.length - added.length;
    // Python sorts stably by start: earlier ones first, the list's order
    // between equals.
    final all = [..._dives, ...added];
    final order = [for (var i = 0; i < all.length; i++) i]
      ..sort((a, b) {
        final byStart = all[a].startTime.compareTo(all[b].startTime);
        return byStart != 0 ? byStart : a.compareTo(b);
      });
    _dives = [for (final i in order) all[i]];
    _refreshRows();
    _warnings = [..._warnings, ...read.warnings];

    if (current != null) {
      _setCurrent(_rowOf(current));
    } else if (added.isNotEmpty) {
      _setCurrent(added.map(_rowOf).reduce((a, b) => a < b ? a : b));
    }
    final parts = [
      'Added ${added.length} dive${added.length != 1 ? 's' : ''}',
      if (skipped > 0) '$skipped already in the list',
    ];
    _busy = false;
    _setMessage('${parts.join(', ')}.');
  }

  // By identity: the same dive read from two files is two dives.
  int _rowOf(Dive dive) => _dives.indexWhere((d) => identical(d, dive));

  void _refreshRows() {
    final system = units;
    _rows = [for (final dive in _dives) diveRow(dive, system)];
    _files = {
      for (final dive in _dives)
        if ((dive.logFilename ?? '').isNotEmpty) dive.logFilename!,
    }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  // -- selection -----------------------------------------------------------

  void select(int row) {
    if (row >= 0 && row < _dives.length && row != _current) {
      _setCurrent(row);
    }
  }

  void _setCurrent(int row) {
    _current = row;
    if (row < 0) {
      _selected = null;
      _allRows = [];
    } else {
      final reverse = {
        for (final MapEntry(:key, :value)
            in config.tankConfig().tanks.tanks.entries)
          value: key,
      };
      final system = units;
      _selected = diveDetails(_dives[row], reverse, system);
      _allRows = sampleRows(_dives[row], reverse, system);
    }
    _filter = '';
    final dive = _selectedDive;
    _canAdjust = dive != null && _isFitFile(dive);
    _mergeWith = _canAdjust
        ? tools.mergeCandidates(
            _dives,
            dive!,
            fileExists: (path) => File(path).existsSync(),
          )
        : const [];
    notifyListeners();
  }

  /// Takes the selected dive off the list; the file is not touched.
  void removeSelected() {
    final row = _current;
    if (row < 0 || row >= _dives.length) {
      return;
    }
    _dives = [..._dives]..removeAt(row);
    _refreshRows();
    _setCurrent(row < _dives.length ? row : _dives.length - 1);
    _setMessage('Removed 1 dive from the list.');
  }

  void clear() {
    _dives = [];
    _rows = [];
    _files = [];
    _warnings = [];
    _setCurrent(-1);
    _setMessage('');
  }

  /// The unit system changed: the list, the details and the table follow.
  void unitsChanged() {
    _refreshRows();
    _setCurrent(_current);
  }

  // -- samples table -------------------------------------------------------

  List<String> get tableHeadings => tableHeaders(units);

  String get filterText => _filter;

  set filterText(String value) {
    if (value != _filter) {
      _filter = value;
      notifyListeners();
    }
  }

  /// The table's lines that the filter keeps, a text per column.
  List<List<String>> get tableRows => [
    for (final row in filterSampleRows(_allRows, _filter))
      [for (final key in tableColumns) row[key] ?? ''],
  ];

  // -- Adjust time (Garmin FIT) ----------------------------------------------

  Dive? get _selectedDive =>
      _current >= 0 && _current < _dives.length ? _dives[_current] : null;

  static bool _isFitFile(Dive dive) =>
      dive.logFormat == 'fit' &&
      (dive.logPath ?? '').isNotEmpty &&
      File(dive.logPath!).existsSync();

  bool get canAdjustTime => _canAdjust;

  /// The selected dive's start as the dialog shows it.
  String get adjustStartText {
    final dive = _selectedDive;
    return dive == null ? '' : pyStrftime(dive.startTime, '%Y-%m-%d %H:%M:%S');
  }

  /// The selected FIT dive's UTC offset as the dialog shows it.
  String get adjustOffsetText {
    if (!canAdjustTime) {
      return '';
    }
    try {
      final time = fitActivityTime(
        File(_selectedDive!.logPath!).readAsBytesSync(),
      );
      return tools.formatUtcOffset(time.utcOffsetMinutes ?? 0);
    } on Object {
      // A file that cannot be read, or a FIT the reader stumbles on.
      return '';
    }
  }

  static String _withFit(String path) =>
      p.extension(path).toLowerCase() == '.fit' ? path : '$path.fit';

  static bool _sameFile(String a, String b) {
    try {
      return File(a).absolute.resolveSymbolicLinksSync() ==
          File(b).absolute.resolveSymbolicLinksSync();
    } on FileSystemException {
      return p.equals(p.absolute(a), p.absolute(b));
    }
  }

  /// The Adjust time dialog's Save: asks where to save, writes the copy
  /// and adds it to the list. An error for the dialog, or '' (also when
  /// the save was cancelled).
  Future<String> adjustTime(
    String startText,
    String offsetText,
    SaveDialog save,
  ) async {
    if (!canAdjustTime) {
      return 'Only Garmin FIT logs can be adjusted';
    }
    final DateTime localStart;
    try {
      localStart = tools.parseLocalStart(startText);
    } on FormatException {
      return "Enter the start as YYYY-MM-DD HH:MM:SS (the dive site's local "
          'time)';
    }
    final int offset;
    try {
      offset = tools.parseUtcOffset(offsetText);
    } on FormatException {
      return 'Enter the time zone as a UTC offset, e.g. +07:00 or -05:30';
    }
    final source = _selectedDive!.logPath!;
    final picked = await save(
      tools.adjustedName(source),
      'Save the adjusted log',
    );
    if (picked == null || picked.isEmpty) {
      return '';
    }
    final target = _withFit(picked);
    if (_sameFile(target, source)) {
      return 'Save the adjusted log under a new name; the original is kept '
          'as it is';
    }
    try {
      final adjusted = adjustFitTime(
        File(source).readAsBytesSync(),
        localStart,
        offset,
      ).bytes;
      File(target).writeAsBytesSync(adjusted, flush: true);
    } on Object catch (e) {
      return 'Could not save the adjusted log: ${_reason(e)}';
    }
    _rememberFolder(p.dirname(target));
    await _read([target]);
    return '';
  }

  // -- Merge dives (Garmin FIT) ------------------------------------------------

  List<Dive> _candidates() => _mergeWith;

  /// A FIT dive is selected and a later FIT dive in the list starts within
  /// the merge's limit after it ends.
  bool get canMerge => _candidates().isNotEmpty;

  /// The dives the selected one can be merged with, as the dialog lists
  /// them.
  List<String> get mergeCandidateLabels {
    final dive = _selectedDive;
    return [
      for (final other in _candidates()) tools.candidateLabel(dive!, other),
    ];
  }

  /// The Merge dialog's Save: joins the selected dive with the
  /// [candidate]th of [mergeCandidateLabels] into a new file and adds it
  /// to the list. [closeGap] moves the second dive back to follow the
  /// first; otherwise the real times are kept. An error for the dialog,
  /// or ''.
  Future<String> mergeDives(
    int candidate,
    bool closeGap,
    SaveDialog save,
  ) async {
    final candidates = _candidates();
    if (candidates.isEmpty) {
      return 'Select a Garmin FIT dive that another FIT dive follows within '
          '2 hours';
    }
    if (candidate < 0 || candidate >= candidates.length) {
      return 'Pick the dive to merge with';
    }
    final first = _selectedDive!.logPath!;
    final second = candidates[candidate].logPath!;
    final picked = await save(tools.mergedName(first), 'Save the merged dive');
    if (picked == null || picked.isEmpty) {
      return '';
    }
    final target = _withFit(picked);
    if (_sameFile(target, first) || _sameFile(target, second)) {
      return 'Save the merged dive under a new name; the original logs are '
          'kept as they are';
    }
    try {
      final merged = mergeFitDives(
        File(first).readAsBytesSync(),
        File(second).readAsBytesSync(),
        closeGap: closeGap,
        firstName: p.basename(first),
        secondName: p.basename(second),
      );
      File(target).writeAsBytesSync(merged.bytes, flush: true);
    } on Object catch (e) {
      return 'Could not merge the dives: ${_reason(e)}';
    }
    _rememberFolder(p.dirname(target));
    await _read([target]);
    return '';
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

String _reason(Object e) => switch (e) {
  FormatException(:final message) => message,
  FileSystemException(:final message) => message,
  _ => '$e',
};
