/// The Overlay Generator page's state (Python
/// `backends/overlay_generator_backend.py`): the overlays to render
/// (picked from the template trees or a layout file of the user's), the
/// source and logs folder or a single log file, the output, the name
/// pattern, the size and format, and the run, one overlay after another,
/// with its two progress bars. The fields are kept in the settings under
/// the Python app's names; the overlay list is not, as in Python.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/hud/image_size.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/hud/true_size.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/model/dive_manager.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/pages/display_paths.dart';
import 'package:uwmedia_app/core/pages/dive_matches.dart';
import 'package:uwmedia_app/core/pages/run_timing.dart';
import 'package:uwmedia_app/core/util/py_round.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';
import 'package:uwmedia_app/engine/app_log.dart';
import 'package:uwmedia_app/engine/desktop/color_batch.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/overlay_batch.dart';
import 'package:uwmedia_app/engine/dive_cache.dart';
import 'package:uwmedia_app/engine/log_files.dart';
import 'package:uwmedia_app/engine/log_store.dart';
import 'package:uwmedia_app/pages/shared/logs_folder.dart';
import 'package:uwmedia_app/pages/shared/place_menu.dart';
import 'package:uwmedia_app/pages/shared/source_dates.dart';
import 'package:uwmedia_app/pages/shared/template_picker.dart';

/// The page's name at the [BatchGate].
const overlayGeneratorPage = 'Overlay Generator';

const hudSourceField = 'hudpage_source_input';
const hudOutputField = 'hudpage_output_input';
const hudLogFileField = 'hudpage_log_file_input';
const hudLogFileModeField = 'hudpage_log_file_mode';
const hudFilenameFormatField = 'hudpage_filename_format_select';
const hudOverlaySizeField = 'hudpage_overlay_size';
const hudOutputFormatField = 'hudpage_output_format';

/// The brand, computer, page and tank setup of the overlay added last,
/// which the picker starts on (owner, 2026-11-16; Python starts at the
/// first brand each time; spec §10.64).
const hudOverlayChoiceField = 'hudpage_overlay_choice';
const hudSourceDirField = 'hudpage_source_dialog_dir';
const hudOutputDirField = 'hudpage_output_dialog_dir';

/// The files picked one by one as the source (several: one is kept as
/// the source itself).
const hudSourceFilesField = 'hudpage_source_files';
const hudCustomPathDirField = 'hudpage_custom_path_dialog_dir';
const _noOverwriteField = 'no_overwrite_switch';
const _hwAccelField = 'hw_accel_switch';

/// The name patterns offered, label and pattern.
const renderLogFormatPresets = [
  ('Original + overlay (GX010042_garmin_mk3i_main)', '{filename}_{hud}'),
  (
    'Date + time + overlay (20251101_121212_garmin_mk3i_main)',
    '{datetaken:%Y%m%d_%H%M%S}_{hud}',
  ),
];

const _legacyRenderLogFormatLabels = {
  'source_filename_hudname': 'Original + overlay (GX010042_garmin_mk3i_main)',
  'source_datetaken_hudname':
      'Date + time + overlay (20251101_121212_garmin_mk3i_main)',
};

/// The output formats offered, label and format.
const outputFormatChoices = [
  ('Transparent video (ProRes 4444 .mov)', overlayFormatProres),
  ('PNG sequence (folder of frames with alpha)', overlayFormatPng),
  ('Video on black (HEVC .mp4)', overlayFormatHevc),
];

/// The sizes offered: label, size and whether it is the whole frame.
const overlaySizeChoices = [
  ('1080p (template size)', '1080p', false),
  ('4K (2×)', '4k', false),
  ('Full frame 1080p', '1080p', true),
  ('Full frame 4K', '4k', true),
];

/// The brand list's last entry: a layout file of the user's.
const layoutCustom = 'Custom…';

/// What the page needs of the media engine.
abstract interface class OverlayGeneratorEngine {
  /// Every tag of a file; `null` when it cannot be read.
  Future<MediaTags?> metadata(String path);

  Future<List<FileResult>> runFolder(
    OverlayFolderSettings settings,
    ColorBatchListener listener,
  );

  Future<String> runLog({
    required String logPath,
    required String output,
    required String layoutPath,
    required OverlayLook look,
    bool hwAccel = true,
    void Function(double percent)? onProgress,
    void Function(String line)? onMessage,
  });

  Future<void> stop();
}

/// One overlay to render: the label the list shows and its layout file.
typedef SelectedOverlay = ({String label, String layoutPath});

/// A kept log a whole dive can be rendered from: its file, and its first
/// dive's date, length and the file's name.
typedef LogChoice = ({String path, String label});

class OverlayGeneratorController extends ChangeNotifier
    implements ColorBatchListener {
  OverlayGeneratorController({
    required this.config,
    required this.gate,
    required this.home,
    required this.engine,
    required this.picker,
    this.keptLogsDir,
    double Function()? clock,
  }) : timer = RunTimer(clock ?? _stopwatchClock()) {
    _restore();
    picker.restore(config.fields()[hudOverlayChoiceField]);
  }

  /// Where the app keeps the logs imported on the Dive Logs page: the
  /// logs the runs read (spec §10.65).
  final String? keptLogsDir;

  /// How many logs the app keeps.
  int get keptLogsCount => keptLogsIn(keptLogsDir);

  final ConfigStore config;
  final BatchGate gate;
  final String home;
  final Future<OverlayGeneratorEngine> Function() engine;
  final TemplatePicker picker;
  final RunTimer timer;

  String _source = '';
  String _output = '';
  String _logFile = '';
  List<String> _sourceFiles = const [];
  List<LogChoice> _logChoices = const [];
  int _logLoads = 0;
  bool _logFileMode = false;
  bool _skipExisting = false;
  bool _hwAccel = true;
  String _filenameFormat = renderLogFormatPresets[1].$1;
  String _overlaySize = '4K (2×)';
  String _outputFormat = outputFormatChoices.first.$1;
  bool _custom = false;
  String _customPath = '';
  final List<SelectedOverlay> overlays = [];

  String get sourceText => _source;
  String get outputText => _output;

  /// The files picked one by one, when several were; empty for a folder
  /// or one file ([sourceText]).
  List<String> get sourceFiles => List.unmodifiable(_sourceFiles);

  bool get hasSource => _source.trim().isNotEmpty || _sourceFiles.isNotEmpty;

  /// The source as the page shows it: the folder, the file, or the picked
  /// files' number and where they lie.
  String get sourceSummary {
    if (_sourceFiles.isEmpty) {
      return displayPath(_source);
    }
    final names = [for (final file in _sourceFiles) p.basename(file)];
    final folders = {for (final file in _sourceFiles) p.dirname(file)};
    return '${pickedFilesText(names)}'
        '${folders.length == 1 ? ' in ${displayPath(folders.single)}' : ''}';
  }

  /// The kept logs a whole dive can be rendered from: each log file with
  /// its first dive (the one the run renders), the newest first.
  List<LogChoice> get logChoices => List.unmodifiable(_logChoices);

  /// The kept logs read again (off the UI isolate), for [logChoices]; a
  /// chosen log that is gone is no longer chosen.
  Future<void> loadLogChoices() async {
    final dir = keptLogsDir;
    if (dir == null) {
      return;
    }
    final ticket = ++_logLoads;
    final tanks = config.tankConfig().tanks;
    // Through the app's cache: only the logs not read yet are parsed
    // (spec §10.106).
    final LogRead read = await diveCache.read(
      // None when the folder is not there yet.
      await compute(
        (String folder) => LogStore(Directory(folder)).files(),
        dir,
      ),
      tanks,
    );
    if (_disposed || ticket != _logLoads) {
      return;
    }
    final first = <String, Dive>{};
    for (final dive in read.dives) {
      first.putIfAbsent(dive.logFilename ?? '', () => dive);
    }
    _logChoices = [
      for (final MapEntry(key: name, value: dive)
          in first.entries.toList()
            ..sort((a, b) => b.value.startTime.compareTo(a.value.startTime)))
        if (name.isNotEmpty)
          (
            path: p.join(dir, name),
            label:
                '${pyStrftime(dive.startTime, '%Y-%m-%d %H:%M')} · '
                '${(dive.duration / 60).round()} min · $name',
          ),
    ];
    _dives = DiveManager()..addDives(read.dives);
    unawaited(_readSourceDates());
    // A log typed in an older version, or removed on Dive Logs since: the
    // list shows none chosen, so none is. (A loop: a closure here would
    // take the controller into what the isolate above is sent.)
    var kept = false;
    for (final choice in _logChoices) {
      kept = kept || choice.path == _logFile.trim();
    }
    if (!kept) {
      _logFile = '';
    }
    notifyListeners();
  }

  // -- the dives of the source files (spec §10.67(c)) -----------------------

  DiveManager _dives = DiveManager();
  DiveMatches? _matches;
  late final _sourceDates = SourceDates(
    reader: () async => (await engine()).metadata,
    onRead: () {
      _matches = null;
      notifyListeners();
    },
  );

  /// The dives the picked photos and videos are matched to, as a run
  /// would match them; `null` while their dates are being read, for a
  /// whole dive, and with no file or no log at all.
  DiveMatches? get diveMatches {
    final dates = _sourceDates.dates;
    if (dates == null || _logFileMode || _dives.dives.isEmpty) {
      return null;
    }
    return _matches ??= matchDives(_dives, dates);
  }

  /// Whether the files' dates are being read for [diveMatches].
  bool get diveMatchesPending =>
      _sourceDates.reading && !_logFileMode && _dives.dives.isNotEmpty;

  // The files a run would take, as far as they are there.
  List<String> _sourceList() {
    if (_sourceFiles.isNotEmpty) {
      return [
        for (final file in _sourceFiles)
          if (File(file).existsSync()) file,
      ];
    }
    final value = _source.trim();
    if (value.isEmpty) {
      return const [];
    }
    if (FileSystemEntity.isDirectorySync(value)) {
      try {
        return batchFiles(value);
      } on FileSystemException {
        return const [];
      }
    }
    return File(value).existsSync() ? [value] : const [];
  }

  // Read only when there are files to match (not for a whole dive) and a
  // log to match them to (one exiftool call a file).
  Future<void> _readSourceDates() async {
    _matches = null;
    if (!_logFileMode && _dives.dives.isNotEmpty) {
      await _sourceDates.load(_sourceList());
    }
  }

  String get logFileText => _logFile;
  bool get logFileMode => _logFileMode;
  bool get skipExisting => _skipExisting;
  bool get hwAccel => _hwAccel;
  String get filenameFormat => _filenameFormat;
  String get overlaySize => _overlaySize;
  String get outputFormat => _outputFormat;
  bool get isCustom => _custom;
  String get customPathText => _customPath;

  String displayPath(String path) => contractHomePath(path, home) ?? path;

  /// The dialogs' folders: the source's starts in Pictures.
  String dialogDir(String field) => config.dialogDirFor(
    field,
    home: home,
    start: field == hudSourceDirField ? StartFolder.pictures : StartFolder.home,
  );

  void rememberDialogDir(String field, String folder) =>
      _remember(field, folder);

  void _remember(String key, Object? value) {
    try {
      config.setField(key, value);
    } on FileSystemException {
      // Only not kept.
    }
  }

  void _restore() {
    final fields = config.fields();
    String text(String key) =>
        fields[key] is String ? fields[key] as String : '';
    _source = text(hudSourceField);
    _output = text(hudOutputField);
    final picked = fields[hudSourceFilesField];
    if (picked is List) {
      _sourceFiles = [...picked.whereType<String>()];
    }
    _logFile = text(hudLogFileField);
    _logFileMode = fields[hudLogFileModeField] == true;
    _skipExisting = fields[_noOverwriteField] == true;
    _hwAccel = fields[_hwAccelField] is! bool || fields[_hwAccelField] as bool;
    var format = fields[hudFilenameFormatField];
    format = _legacyRenderLogFormatLabels[format] ?? format;
    if (renderLogFormatPresets.any((preset) => preset.$1 == format)) {
      _filenameFormat = format as String;
    }
    final size = fields[hudOverlaySizeField];
    if (overlaySizeChoices.any((choice) => choice.$1 == size)) {
      _overlaySize = size as String;
    }
    final output = fields[hudOutputFormatField];
    if (outputFormatChoices.any((choice) => choice.$1 == output)) {
      _outputFormat = output as String;
    }
  }

  void _set(String key, Object? value, void Function() apply) {
    apply();
    _remember(key, value);
    notifyListeners();
  }

  /// A folder, or one file, as the source.
  set sourceText(String v) => setSource(v);

  /// Without [remember] the source is for this session only (a working
  /// folder of what was picked in Photos).
  void setSource(String v, {bool remember = true}) {
    _sourceFiles = const [];
    _source = v;
    if (remember) {
      _remember(hudSourceFilesField, const <String>[]);
      _remember(hudSourceField, v);
    }
    notifyListeners();
    unawaited(_readSourceDates());
  }

  /// Files picked one by one as the source: one is [sourceText]'s file.
  void setSourceFiles(List<String> files) {
    if (files.length < 2) {
      if (files.isNotEmpty) {
        sourceText = files.single;
      }
      return;
    }
    _sourceFiles = [...files];
    _remember(hudSourceFilesField, _sourceFiles);
    _set(hudSourceField, '', () => _source = '');
    unawaited(_readSourceDates());
  }

  set outputText(String v) => setOutput(v);

  /// Without [remember] the output is for this session only (a working
  /// folder on the way into Photos).
  void setOutput(String v, {bool remember = true}) {
    _output = v;
    if (remember) {
      _remember(hudOutputField, v);
    }
    notifyListeners();
  }

  /// Whether the output is a folder of frames for each overlay, not a
  /// video.
  bool get outputIsFrames => outputFormatChoices.any(
    (choice) => choice.$1 == _outputFormat && choice.$2 == overlayFormatPng,
  );

  set logFileText(String v) => _set(hudLogFileField, v, () => _logFile = v);
  set logFileMode(bool v) {
    _set(hudLogFileModeField, v, () => _logFileMode = v);
    unawaited(_readSourceDates());
  }

  set skipExisting(bool v) =>
      _set(_noOverwriteField, v, () => _skipExisting = v);
  set hwAccel(bool v) => _set(_hwAccelField, v, () => _hwAccel = v);
  set filenameFormat(String v) =>
      _set(hudFilenameFormatField, v, () => _filenameFormat = v);
  set overlaySize(String v) =>
      _set(hudOverlaySizeField, v, () => _overlaySize = v);
  set outputFormat(String v) =>
      _set(hudOutputFormatField, v, () => _outputFormat = v);

  set customPathText(String v) {
    _customPath = v;
    notifyListeners();
  }

  /// The brand list's choice: a brand's key, or [layoutCustom].
  void selectBrand(String key) {
    _custom = key == layoutCustom;
    if (!_custom) {
      picker.selectBrand(key);
    }
    notifyListeners();
  }

  OverlayLook get _look {
    final format = outputFormatChoices
        .firstWhere((c) => c.$1 == _outputFormat)
        .$2;
    final (_, size, fullFrame) = overlaySizeChoices.firstWhere(
      (c) => c.$1 == _overlaySize,
    );
    return (format: format, size: size, fullFrame: fullFrame);
  }

  /// Adds the picked overlay, or the custom layout file, to the list.
  Future<void> addOverlay() async {
    if (_custom) {
      final path = _customPath.trim();
      if (path.isEmpty) {
        return;
      }
      if (!layoutSuffixes.contains(p.extension(path).toLowerCase())) {
        _setStatus(
          'Only a layout file (.json) or a HUD package (.zip) can be added '
          'here.',
        );
        return;
      }
      overlays.add((label: p.basenameWithoutExtension(path), layoutPath: path));
    } else {
      final picked = await picker.materialize('uwmedia_qt_hud_');
      if (picked == null) {
        return;
      }
      _remember(hudOverlayChoiceField, picker.choice);
      _toTrueSize(picked);
      overlays.add((
        label: p
            .basenameWithoutExtension(picked.layoutPath)
            .replaceAll('_', ' '),
        layoutPath: picked.layoutPath,
      ));
    }
    notifyListeners();
  }

  /// The working copy of a picked template drawn at its computer's real
  /// size beside the others (spec §10.100): its skin's scale is set in
  /// the copy, which the overlay-only video takes its size from. A
  /// template without a known width, or one drawn as a shape, is left.
  void _toTrueSize(PickedLayout picked) {
    final skin = picked.layout['hud_skin'];
    final skinPath = skin is Map ? skin['path'] : null;
    (int, int)? skinSize;
    if (skinPath is String && skinPath.isNotEmpty) {
      final file = File(
        p.isAbsolute(skinPath)
            ? skinPath
            : p.join(p.dirname(picked.layoutPath), skinPath),
      );
      if (file.existsSync()) {
        skinSize = imageSize(file.readAsBytesSync());
      }
    }
    final sized = trueSizedLayout(
      picked.layout,
      widthMm: pictureWidthMm(picked.brand, picked.computer, picked.manifest),
      skinSize: skinSize,
    );
    if (!identical(sized, picked.layout)) {
      File(picked.layoutPath)
          .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(sized));
    }
  }

  void removeOverlayAt(int index) {
    if (index >= 0 && index < overlays.length) {
      overlays.removeAt(index);
      notifyListeners();
    }
  }

  // -- the run -----------------------------------------------------------------

  String _status = 'No batch running';
  String _overlayProgress = '';
  bool _running = false;
  bool _stopRequested = false;
  bool _logMode = false;
  int _runTotal = 0;
  int _runIndex = 0;
  int _filesTotal = 0;
  int _filesDone = 0;
  String _currentFile = '';
  double _filePct = 0;
  final List<String> _messages = [];
  Timer? _ticker;

  String get statusText => _status;
  String get overlayProgressText => _overlayProgress;
  bool get isRunning => _running;
  List<String> get messages => List.unmodifiable(_messages);

  /// False until the run has said how many files the source holds.
  bool get progressKnown => _filesTotal > 0;

  double get _runFraction {
    if (_filesTotal <= 0) {
      return 0;
    }
    var done = _filesDone.toDouble();
    if (_filesTotal == 1 && _filesDone == 0) {
      done = _filePct / 100;
    }
    return (done / _filesTotal).clamp(0.0, 1.0);
  }

  /// The overlay in flight: its files.
  double get currentProgress => _runFraction;

  String get currentProgressText {
    if (!_running || _filesTotal <= 0) {
      return '';
    }
    if (_logMode || _filesTotal == 1) {
      final name = _currentFile.isNotEmpty
          ? _currentFile
          : (_logMode ? p.basename(_logFile.trim()) : '');
      return 'Rendering $name - ${pyFormatFixed(_filePct, 0)} %'.replaceAll(
        '  ',
        ' ',
      );
    }
    if (_filesDone >= _filesTotal) {
      return 'All $_filesTotal videos done';
    }
    final text =
        'Video ${math.min(_filesDone + 1, _filesTotal)} of $_filesTotal';
    return _currentFile.isEmpty ? text : '$text: $_currentFile';
  }

  /// The whole batch: files times overlays.
  double get totalProgress => _runTotal <= 0
      ? 0
      : ((math.max(0, _runIndex - 1) + _runFraction) / _runTotal).clamp(
          0.0,
          1.0,
        );

  String get totalProgressText {
    if (!_running || _runTotal <= 0 || _filesTotal <= 0) {
      return '';
    }
    final total = _filesTotal * _runTotal;
    final done =
        math.max(0, _runIndex - 1) * _filesTotal +
        math.min(_filesDone, _filesTotal);
    final unit = _logMode ? 'render' : 'video render';
    return '$done of $total ${unit}s ($_filesTotal × $_runTotal overlays)'
        .replaceAll('(1 × ', '(1 log × ');
  }

  String get timingText => timer.text(totalProgress);

  void _setStatus(String text) {
    _status = text;
    AppLog.note('Overlay Generator', text);
    notifyListeners();
  }

  /// Start, or Stop while a run is going.
  Future<void> startOrStop() async {
    if (_running) {
      _stopRequested = true;
      _setStatus('Aborting…');
      await (await engine()).stop();
      return;
    }
    if (_logFileMode) {
      final log = _logFile.trim();
      if (overlays.isEmpty || log.isEmpty || _output.trim().isEmpty) {
        _setStatus(
          'Nothing to run: select a dive, an output folder, and at least '
          'one overlay first.',
        );
        return;
      }
      if (!File(log).existsSync()) {
        _setStatus('Log file not found: $log');
        return;
      }
    } else if (overlays.isEmpty ||
        !hasSource ||
        _output.trim().isEmpty ||
        keptLogsCount == 0) {
      _setStatus(
        'Nothing to run: choose photos and videos, where to save and at '
        'least one overlay, and import dive logs on the Dive Logs page '
        'first.',
      );
      return;
    }
    if (!gate.enter(overlayGeneratorPage)) {
      return;
    }
    _running = true;
    _stopRequested = false;
    _logMode = _logFileMode;
    _runTotal = overlays.length;
    _runIndex = 0;
    _messages.clear();
    timer.start();
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => notifyListeners(),
    );
    notifyListeners();

    final failed = <String>[];
    final queue = [...overlays];
    final look = _look;
    final pattern = renderLogFormatPresets
        .firstWhere((preset) => preset.$1 == _filenameFormat)
        .$2;
    try {
      final tools = await engine();
      for (final overlay in queue) {
        if (_stopRequested) {
          break;
        }
        _runIndex++;
        _overlayProgress = 'Overlay $_runIndex of $_runTotal: ${overlay.label}';
        _status = 'Starting…';
        _filesTotal = _logMode ? 1 : 0;
        _filesDone = 0;
        _currentFile = '';
        _filePct = 0;
        notifyListeners();
        try {
          if (_logMode) {
            final written = await tools.runLog(
              logPath: _logFile.trim(),
              output: _output.trim(),
              layoutPath: overlay.layoutPath,
              look: look,
              hwAccel: _hwAccel,
              onProgress: (pct) => progress(p.basename(_logFile.trim()), pct),
              onMessage: message,
            );
            _filesDone = 1;
            _status = 'Done: ${p.basename(written)}';
          } else {
            final results = await tools.runFolder(
              OverlayFolderSettings(
                source: _source.trim(),
                sourceFiles: _sourceFiles,
                output: _output.trim(),
                keptLogsDir: keptLogsDir,
                layoutPath: overlay.layoutPath,
                look: look,
                filenameFormat: pattern,
                noOverwrite: _skipExisting,
                hwAccel: _hwAccel,
              ),
              this,
            );
            final errors = results.where((r) => r.status == FileStatus.error);
            if (errors.isNotEmpty) {
              failed.add(
                '${overlay.label} (${errors.map((e) => '${e.file}: ${e.error}').join(', ')})',
              );
            }
          }
        } on RunStopped {
          break;
        } on Exception catch (e) {
          failed.add('${overlay.label} (${_reason(e)})');
        }
      }
    } on Exception catch (e) {
      failed.add(_reason(e));
    } finally {
      _ticker?.cancel();
      _ticker = null;
      final aborted = _stopRequested;
      _status = aborted
          ? 'Aborted'
          : failed.isEmpty
          ? 'Done'
          : 'Done - ${failed.length} of $_runTotal overlays failed: '
                '${failed.join('; ')}';
      _overlayProgress = '';
      _filesTotal = 0;
      _running = false;
      timer.stop(ok: !aborted && failed.isEmpty);
      gate.leave(overlayGeneratorPage);
      notifyListeners();
    }
  }

  @override
  void started(int total) {
    _filesTotal = total;
    _filesDone = 0;
    _currentFile = '';
    if (total == 0) {
      _status = 'No files found in the Source folder';
    }
    notifyListeners();
  }

  @override
  void active(String file) {
    _currentFile = file;
    _filePct = 0;
    notifyListeners();
  }

  @override
  void finished(int done, int total, FileResult result) {
    _filesDone = done;
    _filesTotal = total;
    _filePct = 0;
    final status = result.status.name;
    _status =
        '${status[0].toUpperCase()}${status.substring(1)}: ${result.file}';
    if (result.status == FileStatus.error) {
      _messages.add('${result.file}: ${result.error}');
      AppLog.note('Overlay Generator', '${result.file}: ${result.error}');
    }
    notifyListeners();
  }

  @override
  void progress(String file, double percent) {
    _filePct = percent.clamp(0.0, 100.0);
    notifyListeners();
  }

  @override
  void message(String line) {
    _messages.add(line);
    AppLog.note('Overlay Generator', line);
    notifyListeners();
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _sourceDates.dispose();
    if (_running) {
      // No further overlay starts either.
      _stopRequested = true;
      unawaited(engine().then((tools) => tools.stop()));
    }
    super.dispose();
  }
}

String _reason(Exception e) => switch (e) {
  FormatException(:final message) => message,
  EngineException() => e.toString(),
  _ => '$e',
};

double Function() _stopwatchClock() {
  final watch = Stopwatch()..start();
  return () => watch.elapsedMicroseconds / 1e6;
}
