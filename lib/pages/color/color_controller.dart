/// The Color page's state (Python `backends/color_backend.py`): the
/// source, output and logs, colour correction and its profile, the name
/// pattern, "skip if target exists" and hardware encoding, the clock
/// offset between the camera and the dive computer, the overlays placed on
/// the preview (added from the template tree, moved and resized there),
/// the preview of the first source file with the dive matched to it, and
/// the batch run with its progress. Every field is kept in the settings
/// under the Python app's names.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/color/color_shader.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/engine/compare.dart';
import 'package:uwmedia_app/core/engine/share_sizes.dart';
import 'package:uwmedia_app/core/engine/space_estimate.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/image_size.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/hud/template_tree.dart';
import 'package:uwmedia_app/core/hud/true_size.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/model/dive_manager.dart';
import 'package:uwmedia_app/core/naming/clock_offset.dart';
import 'package:uwmedia_app/core/naming/filename_formats.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/pages/display_paths.dart';
import 'package:uwmedia_app/core/pages/dive_matches.dart';
import 'package:uwmedia_app/core/pages/run_estimate.dart';
import 'package:uwmedia_app/core/pages/run_timing.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_round.dart';
import 'package:uwmedia_app/core/watermark/watermark.dart';
import 'package:uwmedia_app/engine/app_log.dart';
import 'package:uwmedia_app/engine/desktop/color_batch.dart';
import 'package:uwmedia_app/engine/desktop/exiftool.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/mobile_engine.dart';
import 'package:uwmedia_app/engine/mobile_video_run.dart';
import 'package:uwmedia_app/engine/watermark_store.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/pages/color_tuning/color_tuning_controller.dart'
    show correctedSample, previewShader, sampleFilter;
import 'package:uwmedia_app/pages/shared/place_menu.dart';
import 'package:uwmedia_app/pages/shared/source_dates.dart';
import 'package:uwmedia_app/pages/shared/template_picker.dart';

/// The page's name at the [BatchGate].
const colorPage = 'Color';

/// The width the preview frame is worked on at.
const previewWorkingWidth = 1920;

/// The seconds of a video shown before and after the part on the
/// part's slider.
const partMargin = 5.0;

/// The comparisons as the page names them (spec §10.94): none, the
/// original beside the corrected picture, and a photo's wipe video.
const compareOffLabel = 'Off';
const compareChoices = {
  'Split, left and right': Compare(CompareKind.vertical),
  'Split, above and below': Compare(CompareKind.horizontal),
  'Split, diagonal': Compare(CompareKind.diagonal),
  'Wipe video, left to right': Compare(CompareKind.vertical, wipe: true),
  'Wipe video, top to bottom': Compare(CompareKind.horizontal, wipe: true),
  'Wipe video, diagonal': Compare(CompareKind.diagonal, wipe: true),
};

/// The output sizes as the page names them (spec §10.51).
const originalSizeLabel = 'As the original';
const whatsAppSizeLabel = 'WhatsApp';
const weChatSizeLabel = 'WeChat';
const instagramSizeLabel = 'Instagram / Facebook';

/// The settings fields of the page (the Python app's names).
const sourceField = 'source_input';
const outputField = 'output_input';
const colorSwitchField = 'color_switch';
const noOverwriteField = 'no_overwrite_switch';
const colorProfileField = 'color_profile';

/// The status before the first run.
const idleStatus = 'No batch running';

const offsetHoursField = 'color_offset_hours';

/// The page added last in "Add Overlay": brand, computer, page and tank
/// setup.
const overlayChoiceField = 'color_overlay_choice';
const offsetSecondsField = 'color_offset_seconds';
const filenameFormatField = 'filename_format_select';
const overlaysField = 'color_overlay_instances';

/// The files picked one by one as the source (several: one is kept as
/// the source itself).
const sourceFilesField = 'color_source_files';
const colorSourceDirField = 'color_source_dialog_dir';
const colorOutputDirField = 'color_output_dialog_dir';

/// The hardware encoding switch, shared with Convertion and Overlay
/// Generator.
const hwAccelSwitchField = 'hw_accel_switch';

const _videoSuffixes = {'.mp4', '.mov', '.m4v', '.mkv', '.avi'};

/// The preview reads frames of these; other videos show no frame.
const _previewVideoSuffixes = {'.mp4', '.mov'};

/// What the page needs of the media engine.
abstract interface class ColorPageEngine {
  /// Every tag of a file; `null` when it cannot be read.
  Future<MediaTags?> metadata(String path);

  /// A video's frame rate and frame count.
  Future<({double fps, int frames})> videoFacts(String path);

  /// The frame at [seconds], as RGB at [width] x [height]; `null` when
  /// there is none.
  Future<RgbImage?> frameAt(String path, double seconds, int width, int height);

  /// A video's width and height.
  Future<(int, int)> dimensions(String path);

  /// Draws [layers] over [base] for [waypoint].
  Future<ui.Image> overlaid(
    ui.Image base,
    List<HudLayerSource> layers,
    Waypoint? waypoint,
    List<Waypoint>? waypoints,
  );

  /// Runs the batch (see [ColorBatch.run]).
  Future<List<FileResult>> run(
    ColorBatchSettings settings,
    ColorBatchListener listener,
  );

  /// Stops a run.
  Future<void> stop();
}

/// One overlay on the page: its layout file (a working copy), the label
/// the list shows, and where the user put it.
class PlacedOverlay {
  PlacedOverlay({
    required this.id,
    required this.layoutPath,
    required this.label,
    this.x = 0,
    this.y = 0,
    this.scale = 1,
  });

  final int id;
  final String layoutPath;
  final String label;
  double x;
  double y;
  double scale;

  OverlayInstance get instance =>
      OverlayInstance(layoutPath: layoutPath, x: x, y: y, scale: scale);
}

/// A layout read from disk, with its skin.
class _LoadedLayout {
  _LoadedLayout(this.layout, this.skinBytes, this.skinSize);

  final Map<String, dynamic> layout;
  final Uint8List? skinBytes;
  final (int, int)? skinSize;
}

/// A watermark being moved on the preview: its name, the frame's shape,
/// where the pointer went down, and the mark's box then, in preview
/// frame pixels.
typedef _MarkDrag = ({
  String name,
  bool portrait,
  double startX,
  double startY,
  double x0,
  double y0,
  double w,
  double h,
});

/// A drag in progress on the preview.
class _Drag {
  _Drag.move(this.id, this.startX, this.startY, this.origX, this.origY)
    : resize = false,
      corner = '',
      anchorX = 0,
      anchorY = 0,
      origDiag = 1,
      origScale = 1,
      origW = 0,
      origH = 0;

  _Drag.resize(
    this.id,
    this.corner,
    this.anchorX,
    this.anchorY,
    this.origDiag,
    this.origScale,
    this.origW,
    this.origH,
  ) : resize = true,
      startX = 0,
      startY = 0,
      origX = 0,
      origY = 0;

  final int id;
  final bool resize;
  final double startX;
  final double startY;
  final double origX;
  final double origY;
  final String corner;
  final double anchorX;
  final double anchorY;
  final double origDiag;
  final double origScale;
  final double origW;
  final double origH;
}

const _oppositeCorner = {
  'top_left': 'bottom_right',
  'top_right': 'bottom_left',
  'bottom_left': 'top_right',
  'bottom_right': 'top_left',
};

/// The corners of a box, by name.
Map<String, (double, double)> cornerPoints((int, int, int, int) box) {
  final (x0, y0, x1, y1) = box;
  return {
    'top_left': (x0.toDouble(), y0.toDouble()),
    'top_right': (x1.toDouble(), y0.toDouble()),
    'bottom_left': (x0.toDouble(), y1.toDouble()),
    'bottom_right': (x1.toDouble(), y1.toDouble()),
  };
}

/// `0:00:10` for 10 seconds: Python's `str(timedelta(seconds=…))`.
String clockText(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  return '$h:${'$m'.padLeft(2, '0')}:${'$s'.padLeft(2, '0')}';
}

class ColorController extends ChangeNotifier implements ColorBatchListener {
  ColorController({
    required this.config,
    required this.gate,
    required this.home,
    required this.engine,
    required this.profiles,
    required this.templates,
    required this.tempDir,
    this.templateBytes,
    this.relistTemplates,
    this.watermarkStore,
    this.keptLogsDir,
    this.compareOffered = false,
    this.freeSpace,
    double Function()? clock,
    DateTime Function()? now,
    Future<RgbImage> Function((ColorProfile, RgbImage) job)? correct,
    Future<ColorShader?> Function()? shader,
  }) : timer = RunTimer(clock ?? _stopwatchClock()),
       _now = now ?? naiveNow,
       _correct = correct ?? ((job) => compute(correctedSample, job)),
       _shader = shader ?? previewShader(correct) {
    _restore();
  }

  final ConfigStore config;
  final BatchGate gate;
  final String home;

  /// Where the app keeps the logs imported on the Dive Logs page (the
  /// desktop's page, spec §10.57); `null` where [setLogs] gives that
  /// folder (a phone's page).
  final String? keptLogsDir;

  /// The engine; throws when the tools are missing.
  final Future<ColorPageEngine> Function() engine;

  /// The bytes free on the disk of a folder, `null` when that cannot be
  /// told; without it (a phone) the page says nothing of the room the
  /// results take ([spaceText]).
  final Future<int?> Function(String dir)? freeSpace;

  // The preview's colour correction: the frame's own analysis off the UI
  // thread, then the filter drawn by the shaders (spec §6), or without
  // them worked out by the engine.
  final Future<RgbImage> Function((ColorProfile, RgbImage) job) _correct;
  final Future<ColorShader?> Function() _shader;

  /// The colour profiles by name (bundled and the user's).
  final Map<String, Map<String, Object?>> profiles;

  /// The diver's watermarks; `null` where the page offers none.
  final WatermarkStore? watermarkStore;

  /// The template trees for the overlay picker.
  final TemplateTree templates;

  /// Makes a fresh working folder (`appTempDir` in the app).
  final Directory Function(String prefix) tempDir;

  /// The bytes of a template file (an asset or a file on disk).
  final Future<Uint8List?> Function(String path)? templateBytes;

  /// Lists the template trees again (after a save in the Overlay
  /// Designer).
  final TemplateTree Function()? relistTemplates;
  final RunTimer timer;
  final DateTime Function() _now;

  // -- fields ------------------------------------------------------------

  String _source = '';
  List<String> _sourceFiles = const [];
  String _output = '';
  String _logs = '';
  bool _color = true;
  bool _hwAccel = true;
  bool _skipExisting = false;
  late String _profile;
  String _filenameFormat = filenameFormatPresets.first.$1;
  int _offsetHours = 0;
  double _offsetSeconds = 0;
  final List<PlacedOverlay> overlays = [];
  int _nextId = 0;

  String get sourceText => _source;

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

  String get outputText => _output;
  String get logsText => _logs;
  bool get colorChecked => _color;
  bool get hwAccel => _hwAccel;
  bool get skipExisting => _skipExisting;
  String get colorProfile => _profile;
  String get filenameFormat => _filenameFormat;
  int get offsetHours => _offsetHours;
  double get offsetSeconds => _offsetSeconds;

  List<String> get colorProfileList =>
      profiles.keys.isEmpty ? ['default'] : profiles.keys.toList();

  List<String> get filenameFormatList => [
    for (final (label, _) in filenameFormatPresets) label,
  ];

  String displayPath(String path) => contractHomePath(path, home) ?? path;

  void _remember(String key, Object? value) {
    try {
      config.setField(key, value);
    } on FileSystemException {
      // The config folder cannot be written: only not kept.
    }
  }

  void _restore() {
    final fields = config.fields();
    String text(String key) =>
        fields[key] is String ? fields[key] as String : '';
    _source = text(sourceField);
    final picked = fields[sourceFilesField];
    if (picked is List) {
      _sourceFiles = [...picked.whereType<String>()];
    }
    _output = text(outputField);
    _color =
        fields[colorSwitchField] is! bool || fields[colorSwitchField] as bool;
    _hwAccel =
        fields[hwAccelSwitchField] is! bool ||
        fields[hwAccelSwitchField] as bool;
    _skipExisting = fields[noOverwriteField] == true;
    final names = colorProfileList;
    _profile = names.contains(fields[colorProfileField])
        ? fields[colorProfileField] as String
        : names.first;
    final hours = fields[offsetHoursField];
    final seconds = fields[offsetSecondsField];
    _offsetHours = hours is num ? hours.truncate() : 0;
    _offsetSeconds = seconds is num ? seconds.toDouble() : 0;
    var format = fields[filenameFormatField];
    format = legacyPresetLabels[format] ?? format;
    if (filenameFormatList.contains(format)) {
      _filenameFormat = format as String;
    }
    final saved = fields[overlaysField];
    if (saved is List) {
      for (final entry in saved.whereType<Map<String, dynamic>>()) {
        final path = entry['layout_path'];
        if (path is! String || !File(path).existsSync()) {
          // A layout no longer there is passed over.
          continue;
        }
        overlays.add(
          PlacedOverlay(
            id: _nextId++,
            layoutPath: path,
            label: entry['label'] is String
                ? entry['label'] as String
                : p.basenameWithoutExtension(path),
            x: entry['x'] is num ? (entry['x'] as num).toDouble() : 0,
            y: entry['y'] is num ? (entry['y'] as num).toDouble() : 0,
            scale: entry['scale'] is num
                ? (entry['scale'] as num).toDouble()
                : 1,
          ),
        );
      }
    }
  }

  void _persistOverlays() => _remember(overlaysField, [
    for (final o in overlays)
      {
        'layout_path': o.layoutPath,
        'label': o.label,
        'x': o.x,
        'y': o.y,
        'scale': o.scale,
      },
  ]);

  /// Without [remember] the source is for this session only (a working
  /// folder of what was picked in Photos).
  Future<void> setSource(String value, {bool remember = true}) async {
    if (value == _source && _sourceFiles.isEmpty) {
      return;
    }
    _source = value;
    _sourceFiles = const [];
    if (remember) {
      _remember(sourceField, value);
      _remember(sourceFilesField, const <String>[]);
    }
    notifyListeners();
    await refreshPreview();
  }

  /// Files picked one by one as the source: one is [setSource]'s file.
  Future<void> setSourceFiles(List<String> files) async {
    if (files.length < 2) {
      if (files.isNotEmpty) {
        await setSource(files.single);
      }
      return;
    }
    _source = '';
    _sourceFiles = [...files];
    _remember(sourceField, '');
    _remember(sourceFilesField, _sourceFiles);
    notifyListeners();
    await refreshPreview();
  }

  // The files a run would take, as far as they are there.
  List<String>? _sourceList() {
    if (_sourceFiles.isNotEmpty) {
      return [
        for (final file in _sourceFiles)
          if (File(file).existsSync()) file,
      ];
    }
    final value = _source.trim();
    if (value.isEmpty) {
      return null;
    }
    if (FileSystemEntity.isDirectorySync(value)) {
      try {
        return batchFiles(value);
      } on FileSystemException {
        return null;
      }
    }
    return File(value).existsSync() ? [value] : null;
  }

  /// Without [remember] the output is for this session only (a working
  /// folder on the way into Photos).
  void setOutput(String value, {bool remember = true}) {
    if (value != _output) {
      _output = value;
      if (remember) {
        _remember(outputField, value);
      }
      notifyListeners();
      unawaited(_refreshSpace());
    }
  }

  // -- the room the results take (spec §10.96) -------------------------------

  List<SourceSize> _sizes = const [];
  int? _free;
  int _spaceTicket = 0;

  // The source files' sizes and the room on the output's disk, read
  // again when the source or the output changes and when a run ends.
  Future<void> _refreshSpace() async {
    final free = freeSpace;
    if (free == null) {
      return;
    }
    final ticket = ++_spaceTicket;
    final sizes = <SourceSize>[];
    for (final file in _sourceList() ?? const <String>[]) {
      try {
        sizes.add((
          bytes: File(file).lengthSync(),
          video: _videoSuffixes.contains(p.extension(file).toLowerCase()),
        ));
      } on FileSystemException {
        // Gone meanwhile: the run says so.
      }
    }
    int? room;
    var dir = _output.trim();
    if (dir.isNotEmpty) {
      // The output need not be there yet: the nearest folder that is.
      while (!FileSystemEntity.isDirectorySync(dir) && p.dirname(dir) != dir) {
        dir = p.dirname(dir);
      }
      try {
        room = await free(dir);
      } on Object {
        room = null;
      }
    }
    if (ticket != _spaceTicket || _disposed) {
      return;
    }
    _sizes = sizes;
    _free = room;
    notifyListeners();
  }

  /// The bytes the run's results take, about, with the settings as they
  /// are; `null` with no source, no output, or where the free space is
  /// not asked for.
  int? get spaceNeeded {
    if (freeSpace == null || _sizes.isEmpty || _output.trim().isEmpty) {
      return null;
    }
    final compare = _color ? compareChoice : null;
    return estimatedOutputBytes(
      _sizes,
      rewritten: _color || overlays.isNotEmpty || _watermarkLayers().isNotEmpty,
      compare: compare != null,
      wipe: compare != null && compare.wipe,
      partFraction: _part != null && videoSeconds > 0
          ? (part.end - part.start) / videoSeconds
          : null,
    );
  }

  /// "About 14.2 GB needed, 114.0 GB free" under the output, or that
  /// there is only so much; empty when [spaceNeeded] is.
  String get spaceText => switch (spaceNeeded) {
    null => '',
    final needed => spaceLine(needed, _free),
  };

  /// Whether the results will not fit, as far as can be told.
  bool get spaceShort => switch (spaceNeeded) {
    null => false,
    final needed => spaceIsShort(needed, _free),
  };

  /// The folder whose logs are read (a phone's page: the logs kept in
  /// the app). Nothing of it is kept: since §10.65 no page has a logs
  /// folder of the user's own.
  Future<void> setLogs(String value) async {
    if (value == _logs) {
      return;
    }
    _logs = value;
    notifyListeners();
    await loadDives();
  }

  set colorChecked(bool value) {
    if (value != _color) {
      _color = value;
      _remember(colorSwitchField, value);
      notifyListeners();
      unawaited(_compose());
    }
  }

  set hwAccel(bool value) {
    if (value != _hwAccel) {
      _hwAccel = value;
      _remember(hwAccelSwitchField, value);
      notifyListeners();
    }
  }

  set skipExisting(bool value) {
    if (value != _skipExisting) {
      _skipExisting = value;
      _remember(noOverwriteField, value);
      notifyListeners();
    }
  }

  set colorProfile(String value) {
    if (value != _profile) {
      _profile = value;
      _remember(colorProfileField, value);
      notifyListeners();
      unawaited(_compose());
    }
  }

  set filenameFormat(String value) {
    if (value != _filenameFormat) {
      _filenameFormat = value;
      _remember(filenameFormatField, value);
      notifyListeners();
    }
  }

  // The dialogs' folders: the source's starts in Pictures.
  String dialogDir(String field) => config.dialogDirFor(
    field,
    home: home,
    start: field == colorSourceDirField
        ? StartFolder.pictures
        : StartFolder.home,
  );

  void rememberDialogDir(String field, String folder) {
    try {
      config.rememberDialogDir(field, folder);
    } on FileSystemException {
      // Only not kept.
    }
  }

  /// "3 videos, 12 photos found" for the source, as a run would take it.
  String get sourceCountText {
    final files = _sourceList();
    if (files == null) {
      return '';
    }
    if (files.isEmpty) {
      return 'No media files found';
    }
    final videos = files
        .where((f) => _videoSuffixes.contains(p.extension(f).toLowerCase()))
        .length;
    final photos = files.length - videos;
    final parts = [
      if (videos > 0) '$videos video${videos != 1 ? 's' : ''}',
      if (photos > 0) '$photos photo${photos != 1 ? 's' : ''}',
    ];
    return '${parts.join(', ')} found';
  }

  // -- dives and the preview ------------------------------------------------

  DiveManager _dives = DiveManager();
  ui.Image? _frame;
  ui.Image? _preview;
  double _viewW = previewWorkingWidth.toDouble();
  double _viewH = previewWorkingWidth * 9 / 16;
  String? _videoPath;
  double _fps = 30;
  DateTime? _creationDate;
  Dive? _dive;
  Waypoint? _waypoint;
  bool _scrubEnabled = false;
  int _scrubMax = 0;
  int _scrubValue = 0;
  String _scrubTimeText = '--';
  int _previewTicket = 0;
  int _composeTicket = 0;
  int _divesTicket = 0;
  bool _divesLoading = false;
  int? _scrubWanted;
  bool _scrubbing = false;

  // The photos the slider goes through, when the source is several files
  // and the first is a photo (owner, 2026-11-22: each picked photo can be
  // looked at before the run); empty otherwise. [_walkAt] is the one
  // shown.
  List<String> _walk = const [];
  int _walkAt = 0;
  int? _walkWanted;
  bool _walking = false;
  bool _stopRequested = false;
  bool _disposed = false;

  /// The preview with its overlays, `null` while there is none.
  ui.Image? get previewImage => _preview;

  /// The preview's frame as the file has it: no correction, no overlays.
  ui.Image? get originalImage => _frame;

  /// Whether the preview shows the original for now (a press held on it).
  bool get showOriginal => _showOriginal;
  bool _showOriginal = false;
  set showOriginal(bool value) {
    if (value != _showOriginal) {
      _showOriginal = value;
      notifyListeners();
    }
  }

  /// The preview frame's size (the overlays' coordinates).
  double get viewWidth => _viewW;
  double get viewHeight => _viewH;
  bool get scrubEnabled => _scrubEnabled;
  int get scrubMaximum => _scrubMax;
  int get scrubValue => _scrubValue;
  String get scrubTimeText => _scrubTimeText;

  /// The matched dive's start, for the preview's caption.
  Dive? get matchedDive => _dive;
  Waypoint? get matchedWaypoint => _waypoint;

  /// The time the first source file is matched to the logs at (its own
  /// with the clock offset added); `null` without a file.
  DateTime? get matchTime =>
      _creationDate == null || _firstSourceFile() == null ? null : _matchTime();

  /// Whether the logs' dives are being read: the page is shown meanwhile
  /// (a phone's kept logs take seconds, spec §10.89).
  bool get divesLoading => _divesLoading;

  /// Reads the logs folder's dives and matches the preview again.
  Future<void> loadDives() async {
    final ticket = ++_divesTicket;
    if (!_divesLoading) {
      _divesLoading = true;
      notifyListeners();
    }
    try {
      await _loadDives(ticket);
    } finally {
      if (ticket == _divesTicket) {
        _divesLoading = false;
        if (!_disposed) {
          notifyListeners();
        }
      }
    }
  }

  Future<void> _loadDives(int ticket) async {
    final folder = _logs.trim();
    final manager = DiveManager();
    try {
      final loaded = await loadDiveSources(
        config.tankConfig().tanks,
        kept: keptLogsDir,
        folder: FileSystemEntity.isDirectorySync(folder) ? folder : null,
      );
      manager.addDives(loaded.dives);
    } on Object {
      // The run says which logs could not be read.
    }
    if (_disposed || ticket != _divesTicket) {
      return;
    }
    _dives = manager;
    unawaited(_readSourceDates());
    _match();
    await _compose();
  }

  String? _firstSourceFile() => _sourceList()?.firstOrNull;

  // -- the dives of all the source files -------------------------------------

  // Each source file's own date. They are read only when there is a log
  // to match them to (one exiftool call a file on the desktop).
  late final _sourceDates = SourceDates(
    reader: () async => (await engine()).metadata,
    onRead: () {
      _matches = null;
      if (!_disposed) {
        notifyListeners();
      }
    },
  );
  DiveMatches? _matches;

  /// The dives the source files are matched to, as a run would match
  /// them (each file's own time with the clock offset); `null` while the
  /// files' dates are being read, and with no file or no log at all.
  DiveMatches? get diveMatches {
    final dates = _sourceDates.dates;
    if (dates == null || _dives.dives.isEmpty) {
      return null;
    }
    final shift = Duration(microseconds: (_mediaShiftSeconds * 1e6).round());
    return _matches ??= matchDives(_dives, {
      for (final MapEntry(key: file, value: date) in dates.entries)
        file: date?.add(shift),
    });
  }

  /// Whether the files' dates are being read for [diveMatches].
  bool get diveMatchesPending =>
      _divesLoading || _sourceDates.reading && _dives.dives.isNotEmpty;

  Future<void> _readSourceDates() async {
    _matches = null;
    if (_dives.dives.isEmpty) {
      return;
    }
    await _sourceDates.load(_sourceList() ?? const []);
  }

  void _setScrub(bool enabled, int maximum, int value, String text) {
    _scrubEnabled = enabled;
    _scrubMax = maximum;
    _scrubValue = value;
    _scrubTimeText = text;
  }

  /// The first source file's frame (a video's tenth, or the photo) at the
  /// working width, its date, and the dive matched to it.
  Future<void> refreshPreview() async {
    final ticket = ++_previewTicket;
    unawaited(_readSourceDates());
    unawaited(_refreshSpace());
    _videoPath = null;
    final files = _sourceList();
    _sourceCount = files?.length ?? 0;
    final first = files?.firstOrNull;
    final shown = _walk.isEmpty ? null : _walk[_walkAt];
    final photos = [
      for (final file in files ?? const <String>[])
        if (!_videoSuffixes.contains(p.extension(file).toLowerCase())) file,
    ];
    _walk = photos.length > 1 && first == photos.first ? photos : const [];
    // The photo shown stays the one shown while it is among them.
    _walkAt = math.max(0, shown == null ? 0 : _walk.indexOf(shown));
    final file = _walk.isEmpty ? first : _walk[_walkAt];
    if (file != null && !_previewLoading) {
      _previewLoading = true;
      notifyListeners();
    }
    try {
      await _readPreview(ticket, file);
    } finally {
      if (ticket == _previewTicket && _previewLoading) {
        _previewLoading = false;
        if (!_disposed) {
          notifyListeners();
        }
      }
    }
  }

  /// Whether the file to show is still being read (the page shows the
  /// app's icon moving meanwhile; owner, 2026-11-19).
  bool get previewLoading => _previewLoading;
  bool _previewLoading = false;

  // How many files the run takes, as of the last [refreshPreview].
  int _sourceCount = 0;

  String get _walkText =>
      '${p.basename(_walk[_walkAt])} · ${_walkAt + 1} of ${_walk.length}';

  // The slider moved to photo [index] of [_walk]: the slider follows at
  // once; the photos are read one at a time, the latest asked for next.
  Future<void> _walkTo(int index) async {
    _walkAt = index.clamp(0, _walk.length - 1);
    _scrubValue = _walkAt;
    _scrubTimeText = _walkText;
    notifyListeners();
    _walkWanted = _walkAt;
    if (_walking) {
      return;
    }
    _walking = true;
    try {
      while (_walkWanted != null && !_disposed) {
        final want = _walkWanted!;
        _walkWanted = null;
        if (want >= _walk.length) {
          break;
        }
        // The dives are the ones read already: only matched again.
        await _readPreview(++_previewTicket, _walk[want], dives: false);
      }
    } finally {
      _walking = false;
    }
  }

  Future<void> _readPreview(
    int ticket,
    String? file, {
    bool dives = true,
  }) async {
    if (file == null) {
      _grabbed = null;
      _setFrame(null);
      _dive = null;
      _waypoint = null;
      // No video, no part of one (the page read the part's frames from an
      // empty slider: "Invalid argument(s): 0", the iPhone's log of
      // 2026-11-19).
      _part = null;
      _partView = null;
      _videoPath = null;
      _setScrub(false, 0, 0, '--');
      notifyListeners();
      return;
    }
    ColorPageEngine tools;
    try {
      tools = await engine();
    } on Exception catch (e) {
      if (ticket != _previewTicket || _disposed) {
        return;
      }
      _status = _reason(e);
      _setFrame(null);
      _setScrub(false, 0, 0, '--');
      notifyListeners();
      return;
    }
    DateTime created;
    try {
      created = localCreationDate(
        await tools.metadata(file),
        fileModified: fileModified(file),
      );
    } on FormatException {
      created = _now();
    }
    if (ticket != _previewTicket || _disposed) {
      return;
    }
    // Worked out here, set only if this is still the file to show.
    ui.Image? frame;
    RgbImage? grabbed;
    var fps = 30.0;
    var viewW = previewWorkingWidth.toDouble();
    var viewH = previewWorkingWidth * 9 / 16;
    String? video;
    (bool, int, int, String) scrub = (false, 0, 0, '--');
    if (_previewVideoSuffixes.contains(p.extension(file).toLowerCase())) {
      try {
        final facts = await tools.videoFacts(file);
        final (w, h) = await tools.dimensions(file);
        fps = facts.fps > 0 ? facts.fps : 30;
        final total = math.max(1, facts.frames);
        final index = math.min(10, total - 1);
        viewH = (previewWorkingWidth * h / w).truncateToDouble();
        final rgb = await tools.frameAt(
          file,
          index / fps,
          previewWorkingWidth,
          viewH.toInt(),
        );
        if (rgb != null) {
          grabbed = rgb;
          final shaped = _shaped(rgb);
          viewW = shaped.width.toDouble();
          viewH = shaped.height.toDouble();
          frame = await _imageOf(shaped);
          video = file;
          scrub = (
            true,
            math.max(1, total - 1),
            index,
            clockText(index ~/ fps),
          );
        }
      } on Exception {
        frame = null;
      }
    } else if (!_videoSuffixes.contains(p.extension(file).toLowerCase())) {
      frame = await _photo(file);
      if (frame != null) {
        // Kept as pixels too, for the window cut out of it.
        grabbed = await _rgbOf(frame);
        final shaped = grabbed == null ? null : _shaped(grabbed);
        if (shaped != null && !identical(shaped, grabbed)) {
          frame.dispose();
          frame = await _imageOf(shaped);
        }
        viewW = frame.width.toDouble();
        viewH = frame.height.toDouble();
        scrub = (false, 0, 0, 'Photo');
      }
      if (_walk.isNotEmpty) {
        // Also for a photo that cannot be shown: the slider goes on.
        scrub = (true, _walk.length - 1, _walkAt, _walkText);
      }
    }
    if (ticket != _previewTicket || _disposed) {
      frame?.dispose();
      return;
    }
    _creationDate = created;
    if (video != _videoPath || _sourceCount != 1) {
      // Another video: its own part. And none in a run of several files
      // (owner, 2026-11-19).
      _part = null;
      _partView = null;
    }
    if (video == null && _shape == ShareShape.portraitBars) {
      // No bars around a photo.
      _shape = ShareShape.asShot;
    }
    _videoPath = video;
    _grabbed = grabbed;
    _fps = fps;
    if (frame != null) {
      _viewW = viewW;
      _viewH = viewH;
    }
    _setScrub(scrub.$1, scrub.$2, scrub.$3, scrub.$4);
    _setFrame(frame);
    if (dives) {
      await loadDives();
    } else {
      _match();
      await _compose();
    }
  }

  Future<ui.Image?> _photo(String path) async {
    try {
      final codec = await ui.instantiateImageCodec(
        File(path).readAsBytesSync(),
        targetWidth: previewWorkingWidth,
      );
      final image = (await codec.getNextFrame()).image;
      codec.dispose();
      return image;
    } on Object {
      return null;
    }
  }

  static Future<RgbImage?> _rgbOf(ui.Image image) async {
    final data = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (data == null) {
      return null;
    }
    final rgba = data.buffer.asUint8List();
    final rgb = Uint8List(image.width * image.height * 3);
    for (var i = 0, o = 0; o < rgb.length; i += 4, o += 3) {
      rgb[o] = rgba[i];
      rgb[o + 1] = rgba[i + 1];
      rgb[o + 2] = rgba[i + 2];
    }
    return RgbImage(image.width, image.height, rgb);
  }

  static Future<ui.Image> _imageOf(RgbImage rgb) {
    final rgba = Uint8List(rgb.width * rgb.height * 4);
    for (var i = 0, o = 0; i < rgb.rgb.length; i += 3, o += 4) {
      rgba[o] = rgb.rgb[i];
      rgba[o + 1] = rgb.rgb[i + 1];
      rgba[o + 2] = rgb.rgb[i + 2];
      rgba[o + 3] = 255;
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      rgb.width,
      rgb.height,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    return done.future;
  }

  void _setFrame(ui.Image? frame) {
    // The page may be showing the old frame itself (a press held on the
    // preview): it is told before the frame goes.
    if (_showOriginal) {
      _showOriginal = false;
      notifyListeners();
    }
    _frame?.dispose();
    _frame = frame;
    if (frame == null) {
      _preview?.dispose();
      _preview = null;
    }
  }

  /// The scrub slider moved to frame [index] of the previewed video: the
  /// slider follows at once; frames are read one at a time, the latest
  /// asked for next. With several photos as the source the slider goes
  /// through them instead, and [index] is the photo's.
  Future<void> scrubTo(int index) async {
    if (_videoPath == null) {
      if (_walk.isNotEmpty) {
        await _walkTo(index);
      }
      return;
    }
    _scrubValue = index;
    _scrubTimeText = clockText(index ~/ _fps);
    notifyListeners();
    _scrubWanted = index;
    if (_scrubbing) {
      return;
    }
    _scrubbing = true;
    try {
      while (_scrubWanted != null && !_disposed) {
        final want = _scrubWanted!;
        _scrubWanted = null;
        final path = _videoPath;
        if (path == null) {
          break;
        }
        final ticket = _previewTicket;
        RgbImage? rgb;
        try {
          final size = _grabbed;
          rgb = await (await engine()).frameAt(
            path,
            want / _fps,
            size?.width ?? _viewW.toInt(),
            size?.height ?? _viewH.toInt(),
          );
        } on Exception {
          rgb = null;
        }
        if (rgb == null || ticket != _previewTicket || _disposed) {
          continue;
        }
        final shaped = _shaped(rgb);
        final image = await _imageOf(shaped);
        if (ticket != _previewTicket || _disposed) {
          image.dispose();
          continue;
        }
        _grabbed = rgb;
        _viewW = shaped.width.toDouble();
        _viewH = shaped.height.toDouble();
        _setFrame(image);
        _syncWaypoint(want / _fps);
        await _compose();
      }
    } finally {
      _scrubbing = false;
    }
  }

  double get _mediaShiftSeconds => _offsetHours * 3600.0 + _offsetSeconds;

  DateTime _matchTime() => _creationDate!.add(
    Duration(microseconds: (_mediaShiftSeconds * 1e6).round()),
  );

  double get _elapsed => _videoPath == null ? 0 : _scrubValue / _fps;

  void _match() {
    _matches = null;
    if (_creationDate == null) {
      return;
    }
    _dive = _dives.dives.isEmpty
        ? null
        : _dives.findDiveForTimestamp(_matchTime());
    if (_dive != null) {
      _syncWaypoint(_elapsed);
    } else {
      _waypoint = null;
    }
  }

  // The first sample at or after the frame's time on the computer's
  // clock, as the Python page takes it.
  void _syncWaypoint(double elapsed) {
    final dive = _dive;
    if (dive == null || _creationDate == null) {
      _waypoint = null;
      return;
    }
    final target = _matchTime().add(
      Duration(microseconds: (elapsed * 1e6).round()),
    );
    // Away from the dive's samples: none, its values "--" (spec §10.10).
    _waypoint = dive.getWaypointNear(target) == null
        ? null
        : dive.shown(
            dive.waypoints
                    .where((w) => !w.timestamp.isBefore(target))
                    .firstOrNull ??
                dive.waypoints.last,
          );
  }

  // -- overlays ----------------------------------------------------------------

  final Map<String, _LoadedLayout?> _layouts = {};

  _LoadedLayout? _layout(String path) => _layouts.putIfAbsent(path, () {
    try {
      final layout = loadLayoutFile(
        path,
        (file) => File(file).readAsStringSync(),
        context: p.context,
      );
      final skin = layout['hud_skin'];
      final skinPath = skin is Map ? skin['path'] : null;
      Uint8List? bytes;
      if (skinPath is String && skinPath.isNotEmpty) {
        final full = p.isAbsolute(skinPath)
            ? skinPath
            : p.join(p.dirname(path), skinPath);
        if (File(full).existsSync()) {
          bytes = File(full).readAsBytesSync();
        }
      }
      return _LoadedLayout(
        layout,
        bytes,
        bytes == null ? null : imageSize(bytes),
      );
    } on Object {
      return null;
    }
  });

  /// The box of [overlay] on the preview frame.
  (int, int, int, int)? boxOf(PlacedOverlay overlay) {
    final loaded = _layout(overlay.layoutPath);
    if (loaded == null) {
      return null;
    }
    return overlayPixelBox(
      loaded.layout,
      overlay.x,
      overlay.y,
      overlay.scale,
      _viewW.toInt(),
      _viewH.toInt(),
      skinSize: loaded.skinSize,
    );
  }

  List<HudLayerSource> _layers() => [
    for (final o in overlays)
      if (_layout(o.layoutPath) case final loaded?)
        HudLayerSource(
          loaded.layout,
          skinBytes: loaded.skinBytes,
          placement: (x: o.x, y: o.y, scale: o.scale),
        ),
    ..._watermarkLayers(),
  ];

  // -- the watermark -----------------------------------------------------------

  /// The watermarks by name.
  List<String> get watermarkList => [
    for (final mark in watermarkStore?.list() ?? const <Watermark>[]) mark.name,
  ];

  // -- the part of the video to write (spec §10.71) ---------------------

  ClipPart? _part;

  /// The shown video's length in seconds; 0 without a video.
  double get videoSeconds =>
      _videoPath == null || _fps <= 0 ? 0 : (_scrubMax + 1) / _fps;

  /// Whether a part of the shown video can be chosen: the run's one
  /// file, a video longer than the shortest part.
  bool get canTrim => _sourceCount == 1 && videoSeconds > minClipPart;

  /// The part of the shown video the run writes: all of it until
  /// [setPart] says otherwise.
  ClipPart get part => _part ?? (start: 0, end: videoSeconds);

  /// Whether the run writes only a part of the shown video.
  bool get trimmed => _part != null;

  /// The part from [start] to [end] seconds, at least [minClipPart] long
  /// (the end that moved gives way); the preview shows the frame at the
  /// end that moved.
  void setPart(double start, double end, {bool show = true}) {
    final length = videoSeconds;
    if (!canTrim) {
      return;
    }
    final before = part;
    var from = start.clamp(0.0, length);
    var to = end.clamp(0.0, length);
    final startMoved = (from - before.start).abs() > (to - before.end).abs();
    if (to - from < minClipPart) {
      if (startMoved) {
        from = (to - minClipPart).clamp(0.0, length);
        to = from + minClipPart;
      } else {
        to = (from + minClipPart).clamp(0.0, length);
        from = to - minClipPart;
      }
    }
    final next = from <= 0 && to >= length ? null : (start: from, end: to);
    if (next == _part) {
      return;
    }
    _part = next;
    if (next == null) {
      _partView = null;
    }
    notifyListeners();
    // The frame shown stays when it is inside the part and the part was
    // set from it; else the end that moved is shown.
    final at = _scrubValue.clamp(scrubFrom, scrubUntil);
    if (show || at != _scrubValue) {
      unawaited(
        scrubTo(
          show
              ? ((startMoved ? from : to) * _fps).round().clamp(0, _scrubMax)
              : at,
        ),
      );
    }
  }

  /// The first and the last frame the scrub slider goes between: the
  /// part's own, so that a short part of a long video has the whole
  /// slider (owner, 2026-11-18).
  /// A slider with no frames (no file, or none read) has neither.
  int get scrubFrom => _part == null || _scrubMax < 1
      ? 0
      : (_part!.start * _fps).round().clamp(0, _scrubMax - 1);
  int get scrubUntil => _part == null || _scrubMax < 1
      ? _scrubMax
      : (_part!.end * _fps).round().clamp(scrubFrom + 1, _scrubMax);

  /// The part starts, or ends, at the frame shown.
  void partStartHere() => setPart(_elapsed, part.end, show: false);
  void partEndHere() => setPart(part.start, _elapsed, show: false);

  // The stretch of the video the part's slider shows, `null` for all of
  // it.
  ClipPart? _partView;

  /// The seconds the part's slider goes between: the whole video until
  /// a part is set, then the part with [partMargin] before and after it
  /// (owner, 2026-11-19), so that ten seconds of a long video can be set
  /// finely. An end dragged into the margin makes the part longer, and
  /// [settlePartView] then gives it a margin again.
  double get partFrom {
    final view = _partView;
    return view == null ? 0 : math.min(view.start, part.start);
  }

  double get partUntil {
    final view = _partView;
    return view == null ? videoSeconds : math.max(view.end, part.end);
  }

  /// The slider's stretch set anew around the part: when a drag of one
  /// of its ends is over, not during it (the slider must not move under
  /// the finger).
  void settlePartView() {
    final kept = _part;
    final next = kept == null
        ? null
        : (
            start: math.max(0.0, kept.start - partMargin),
            end: math.min(videoSeconds, kept.end + partMargin),
          );
    if (next != _partView) {
      _partView = next;
      notifyListeners();
    }
  }

  /// The part made [seconds] longer at its start or at its end; the
  /// frame there is shown.
  void extendPart({required bool atStart, double seconds = 1}) => atStart
      ? setPart(part.start - seconds, part.end)
      : setPart(part.start, part.end + seconds);

  /// The whole video again.
  void clearPart() {
    if (_part != null) {
      _part = null;
      _partView = null;
      notifyListeners();
    }
  }

  /// What the page says of the part: "0:05.0 to 0:15.5 (10.5 s)".
  String get partText {
    String clock(double seconds) {
      final tenths = (seconds * 10).round();
      return '${tenths ~/ 600}:${(tenths ~/ 10 % 60).toString().padLeft(2, '0')}'
          '.${tenths % 10}';
    }

    final kept = part;
    return trimmed
        ? '${clock(kept.start)} to ${clock(kept.end)} '
              '(${(kept.end - kept.start).toStringAsFixed(1)} s)'
        : 'The whole video';
  }

  // -- before and after in one picture (spec §10.94) ----------------------

  /// Whether the page has the comparison at all: on a computer.
  final bool compareOffered;

  String _compare = compareOffLabel;

  /// Whether a comparison can be chosen now: with one photo or one video
  /// and the colour correction on (there is nothing to compare without).
  bool get canCompare => compareOffered && _sourceCount == 1 && _color;

  /// The comparisons to choose from: the splits, and for a photo its
  /// wipe videos.
  List<String> get compareList => [
    compareOffLabel,
    for (final MapEntry(key: label, value: compare) in compareChoices.entries)
      if (!compare.wipe || _videoPath == null) label,
  ];

  /// The comparison chosen, by its name on the page ([compareOffLabel]
  /// for none). For this session only.
  String get compare =>
      canCompare && compareList.contains(_compare) ? _compare : compareOffLabel;

  set compare(String value) {
    if (value == _compare || !compareList.contains(value)) {
      return;
    }
    _compare = value;
    notifyListeners();
    unawaited(_compose());
  }

  /// The comparison the run writes; `null` for the corrected picture
  /// alone.
  Compare? get compareChoice => compareChoices[compare];

  // [original] and [corrected] in one picture as the run splits them,
  // for the preview.
  Future<ui.Image> _split(
    ui.Image original,
    ui.Image corrected,
    CompareKind kind,
  ) async {
    final edge = CompareEdge.split(kind, original.width, original.height);
    final corners = edge.farCorners;
    final far = ui.Path()
      ..addPolygon([for (final (x, y) in corners) ui.Offset(x, y)], true);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder)
      ..drawImage(original, ui.Offset.zero, ui.Paint())
      ..save()
      ..clipPath(far)
      ..drawImage(corrected, ui.Offset.zero, ui.Paint())
      ..restore()
      ..drawLine(
        ui.Offset(corners.first.$1, corners.first.$2),
        ui.Offset(corners.last.$1, corners.last.$2),
        ui.Paint()
          ..color = const ui.Color(0xFFFFFFFF)
          ..strokeWidth = edge.lineWidth.toDouble(),
      );
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(original.width, original.height);
    } finally {
      picture.dispose();
    }
  }

  // -- output size (spec §10.51) and the part of the picture kept ------
  // -- (spec §10.75) -----------------------------------------------------

  String _outputSize = originalSizeLabel;
  ShareShape _shape = ShareShape.asShot;
  double _cropAt = 0.5;
  double _cropAtY = 0.5;
  double _cropSize = 1;

  // The video frame as it was grabbed, before the crop.
  RgbImage? _grabbed;

  /// The sizes a run can write its videos in: their own, the Resize
  /// page's resolutions, and its copies for sharing. A size says nothing
  /// of the picture's shape; that is [pictureShape].
  List<String> get outputSizeList => [
    originalSizeLabel,
    for (final (name, _, _, _) in convertResolutions) name,
    whatsAppSizeLabel,
    weChatSizeLabel,
    instagramSizeLabel,
  ];

  /// The size the run writes its videos in (photos keep theirs). For
  /// this session only: the next start is "as the original" again.
  String get outputSize => _outputSize;

  set outputSize(String value) {
    if (value == _outputSize || !outputSizeList.contains(value)) {
      return;
    }
    _outputSize = value;
    notifyListeners();
  }

  /// The chosen size as the page says it.
  String get outputSizeText => _outputSize;

  /// Whether the videos are written upright (9:16).
  bool get outputPortrait =>
      _shape == ShareShape.portraitCropped || _shape == ShareShape.portraitBars;

  /// The shape of the videos written: as shot, 9:16, 16:9 or 1:1 cut out
  /// of the picture, or 9:16 around the whole picture.
  ShareShape get pictureShape => canShape ? _shape : ShareShape.asShot;

  /// Whether the picture can be given a shape and a window: with one
  /// photo or one video selected (owner, 2026-11-19). A run of several
  /// files writes each as it is.
  bool get canShape => _sourceCount == 1;

  /// The shapes to choose from: no bars around a photo.
  List<ShareShape> get shapeChoices => [
    for (final shape in ShareShape.values)
      if (shape != ShareShape.portraitBars || _videoPath != null) shape,
  ];

  set pictureShape(ShareShape value) {
    if (value == _shape) {
      return;
    }
    _shape = value;
    // Another shape's window is another window: the largest again.
    _cropSize = 1;
    notifyListeners();
    unawaited(_reshape());
  }

  /// The window's shape, width over height; `null` for the picture's own.
  double? get cropAspect => pictureShape.aspect;

  /// Whether a window can be placed on the picture (the bars keep all of
  /// it).
  bool get canCrop => canShape && _shape != ShareShape.portraitBars;

  /// Whether a window is cut out of the picture.
  bool get outputCropped => _cut.cuts;

  /// What the page says of the part kept.
  String get pictureText => switch (pictureShape) {
    ShareShape.asShot =>
      _cropSize < 1
          ? 'As shot, ${(_cropSize * 100).round()} % of the picture'
          : 'As shot, the whole picture',
    ShareShape.portraitCropped =>
      _cropSize < 1
          ? 'Portrait, ${(_cropSize * 100).round()} % of the tallest window'
          : 'Portrait, cut out of the picture',
    ShareShape.portraitBars => 'Portrait, the whole picture between bars',
    ShareShape.landscapeCropped =>
      _cropSize < 1
          ? 'Landscape, ${(_cropSize * 100).round()} % of the widest window'
          : 'Landscape, cut out of the picture',
    ShareShape.squareCropped =>
      _cropSize < 1
          ? 'Square, ${(_cropSize * 100).round()} % of the largest window'
          : 'Square, cut out of the picture',
  };

  /// The frame the window is placed on (the video's frame or the photo
  /// as it was read, before the crop). `null` when no window is to be
  /// placed: the bars, or the run is not one file.
  RgbImage? get cropFrame {
    return canCrop ? _grabbed : null;
  }

  /// Where the window lies from left to right and from top to bottom, 0
  /// to 1 each, and its size: its share of the largest window of its
  /// shape the picture holds ([minCropSize] to 1).
  double get cropAt => _cropAt;
  double get cropAtY => _cropAtY;
  double get cropSize => _cropSize;

  /// Moves the window, or makes it another size.
  void setCrop({double? at, double? atY, double? size}) {
    final x = (at ?? _cropAt).clamp(0.0, 1.0);
    final y = (atY ?? _cropAtY).clamp(0.0, 1.0);
    final share = (size ?? _cropSize).clamp(minCropSize, 1.0);
    if (x == _cropAt && y == _cropAtY && share == _cropSize) {
      return;
    }
    _cropAt = x;
    _cropAtY = y;
    _cropSize = share;
    notifyListeners();
    unawaited(_reshape());
  }

  /// The whole picture again (the tallest window, for portrait), in the
  /// middle.
  void clearCrop() => setCrop(at: 0.5, atY: 0.5, size: 1);

  /// The picture zoomed by [factor] (above 1 is in: a smaller window).
  void zoomCrop(double factor) {
    if (canCrop && factor > 0 && factor.isFinite) {
      setCrop(size: _cropSize / factor);
    }
  }

  /// The picture moved under the finger by [dx] and [dy], shares of the
  /// preview's width and height: the window goes the other way.
  void panCrop(double dx, double dy) {
    final frame = cropFrame;
    final crop = frame == null ? null : _cut.cropOf(frame.width, frame.height);
    if (frame == null || crop == null) {
      return;
    }
    final roomX = frame.width - crop.width;
    final roomY = frame.height - crop.height;
    setCrop(
      at: roomX <= 0 ? null : _cropAt - dx * crop.width / roomX,
      atY: roomY <= 0 ? null : _cropAtY - dy * crop.height / roomY,
    );
  }

  PictureCut get _cut => canShape
      ? PictureCut(shape: _shape, at: _cropAt, atY: _cropAtY, size: _cropSize)
      : const PictureCut();

  ShareCopy _copy(ShareSize size) => ShareCopy(
    size,
    _cut.shape,
    cropAt: _cut.at,
    cropAtY: _cut.atY,
    cropSize: _cut.size,
  );

  /// The run's output size; `null` for the videos as they are.
  OutputSize? get outputSizeChoice => switch (_outputSize) {
    originalSizeLabel => _cut.whole ? null : OutputSize.original(_cut),
    whatsAppSizeLabel => OutputSize.share(_copy(shareWhatsApp)),
    weChatSizeLabel => OutputSize.share(_copy(shareWeChat)),
    instagramSizeLabel => OutputSize.share(_copy(shareInstagram)),
    final name => OutputSize.resolution(name, cut: _cut),
  };

  // The grabbed frame as the run leaves it: the part inside the window
  // when one is cut out, so that the overlays are placed on what the run
  // will write.
  RgbImage _shaped(RgbImage rgb) {
    final crop = _cut.cropOf(rgb.width, rgb.height);
    if (crop == null) {
      return rgb;
    }
    final out = Uint8List(crop.width * crop.height * 3);
    for (var y = 0; y < crop.height; y++) {
      final from = ((crop.y + y) * rgb.width + crop.x) * 3;
      out.setRange(y * crop.width * 3, (y + 1) * crop.width * 3, rgb.rgb, from);
    }
    return RgbImage(crop.width, crop.height, out);
  }

  // The shown video frame made again from the grabbed one, after the
  // output size or its window changed.
  // Asked for again while one is being made (the window dragged): the
  // last asking is made when that one is done.
  bool _reshaping = false;
  bool _reshapeWanted = false;

  Future<void> _reshape() async {
    _reshapeWanted = true;
    if (_reshaping) {
      return;
    }
    _reshaping = true;
    try {
      while (_reshapeWanted && !_disposed) {
        _reshapeWanted = false;
        final grabbed = _grabbed;
        if (grabbed == null) {
          return;
        }
        final ticket = _previewTicket;
        final shaped = _shaped(grabbed);
        final image = await _imageOf(shaped);
        if (ticket != _previewTicket ||
            _disposed ||
            !identical(grabbed, _grabbed)) {
          image.dispose();
          // Another frame came meanwhile (a scrub): shaped again.
          _reshapeWanted = !_disposed;
          continue;
        }
        _viewW = shaped.width.toDouble();
        _viewH = shaped.height.toDouble();
        _setFrame(image);
        await _compose();
      }
    } finally {
      _reshaping = false;
    }
  }

  /// Whether the run puts the watermark called [name] on every file.
  bool isWatermarkOn(String name) =>
      watermarkStore?.selectedNames.contains(name) ?? false;

  void setWatermark(String name, bool on) {
    final store = watermarkStore;
    if (store == null || on == isWatermarkOn(name)) {
      return;
    }
    try {
      store.select(name, on);
    } on FileSystemException {
      // The config folder cannot be written: only not kept.
    }
    watermarksChanged();
  }

  /// The watermarks were changed (on the Settings page): drawn again.
  void watermarksChanged() {
    _watermarkLayerOf = null;
    _pictureSizes.clear();
    notifyListeners();
    unawaited(_compose());
  }

  // The chosen watermarks as layers, read once per choice.
  String? _watermarkLayerOf;
  List<HudLayerSource> _watermarkLayersKept = const [];

  List<HudLayerSource> _watermarkLayers() {
    final store = watermarkStore;
    if (store == null) {
      return const [];
    }
    final marks = [for (final mark in store.selected) _placed(mark)];
    final key = jsonEncode([for (final mark in marks) mark.toJson()]);
    if (_watermarkLayerOf != key) {
      _watermarkLayerOf = key;
      _watermarkLayersKept = [for (final mark in marks) ?store.layerOf(mark)];
    }
    return _watermarkLayersKept;
  }

  // -- a watermark moved on the preview (user story U14.2) ---------------

  // Where a watermark was dragged to on the preview, by its name and the
  // frame's shape (portrait or not): for the session's runs only, the
  // watermark kept under Settings is not changed.
  final _markPlaces = <(String, bool), WatermarkPlace>{};

  // The pictures' sizes, read once.
  final _pictureSizes = <String, (int, int)?>{};

  _MarkDrag? _markDrag;

  Watermark _placed(Watermark mark) => mark.copyWith(
    place: _markPlaces[(mark.name, false)],
    placePortrait: _markPlaces[(mark.name, true)],
  );

  /// Whether a watermark was moved on the preview this session.
  bool get watermarksMoved => _markPlaces.isNotEmpty;

  /// The watermarks back at the places kept under Settings.
  void resetWatermarkPlaces() {
    if (_markPlaces.isEmpty) {
      return;
    }
    _markPlaces.clear();
    watermarksChanged();
  }

  // [mark]'s box on the preview frame (left, top, right, bottom); `null`
  // when it is not put on a frame of this shape.
  (double, double, double, double)? _markBox(Watermark mark) {
    final w = _viewW;
    final h = _viewH;
    if (w <= 0 || h <= 0 || !mark.usedOn(w.toInt(), h.toInt())) {
      return null;
    }
    final picture = mark.picture;
    final size = picture == null
        ? null
        : _pictureSizes.putIfAbsent(picture, () {
            final bytes = watermarkStore?.pictureBytes(mark);
            return bytes == null ? null : imageSize(bytes);
          });
    final (shareW, shareH) = watermarkShare(
      mark.shaped(portrait: h > w),
      pictureSize: size,
    );
    final markW = shareW * w;
    final markH = shareH * w;
    final (x, y) = watermarkCorner(
      mark.placeOn(w.toInt(), h.toInt()),
      w,
      h,
      markW,
      markH,
    );
    return (x, y, x + markW, y + markH);
  }

  /// The box of the watermark being moved, to draw around it.
  (int, int, int, int)? get markDragBox {
    final drag = _markDrag;
    final mark = watermarkStore?.selected
        .where((m) => m.name == drag?.name)
        .firstOrNull;
    final box = mark == null ? null : _markBox(_placed(mark));
    return box == null
        ? null
        : (box.$1.round(), box.$2.round(), box.$3.round(), box.$4.round());
  }

  // The watermark under ([x], [y]), the one drawn last first: taken to
  // be moved.
  bool _pressMark(double x, double y) {
    final marks = watermarkStore?.selected ?? const <Watermark>[];
    for (final mark in marks.reversed) {
      final box = _markBox(_placed(mark));
      if (box == null) {
        continue;
      }
      final (x0, y0, x1, y1) = box;
      if (x0 <= x && x <= x1 && y0 <= y && y <= y1) {
        _selected = null;
        _drag = null;
        _markDrag = (
          name: mark.name,
          portrait: _viewH > _viewW,
          startX: x,
          startY: y,
          x0: x0,
          y0: y0,
          w: x1 - x0,
          h: y1 - y0,
        );
        notifyListeners();
        return true;
      }
    }
    return false;
  }

  void _dragMark(_MarkDrag drag, double x, double y) {
    _markPlaces[(drag.name, drag.portrait)] = watermarkPlaceAt(
      drag.x0 + x - drag.startX,
      drag.y0 + y - drag.startY,
      _viewW,
      _viewH,
      drag.w,
      drag.h,
    );
    notifyListeners();
    unawaited(_composeWhileDragged());
  }

  // The last frame corrected, kept while the frame and the profile stay.
  ui.Image? _corrected;
  ui.Image? _correctedOf;
  String? _correctedProfile;
  Map<String, Object?>? _correctedValues;

  // [base] (a copy of [frame]) with the page's colour correction, or as
  // it is with the correction off; the caller's to dispose. The
  // correction is the shown frame's own: a run follows the light through
  // a whole video, so its result can differ a little from this.
  Future<ui.Image> _coloured(ui.Image frame, ui.Image base) async {
    if (!_color) {
      return base.clone();
    }
    final values = profiles[_profile];
    if (_corrected != null &&
        identical(_correctedOf, frame) &&
        _correctedProfile == _profile &&
        identical(_correctedValues, values)) {
      return _corrected!.clone();
    }
    final data = await base.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (data == null) {
      return base.clone();
    }
    final rgba = data.buffer.asUint8List();
    final rgb = Uint8List(base.width * base.height * 3);
    for (var i = 0, o = 0; o < rgb.length; i += 4, o += 3) {
      rgb[o] = rgba[i];
      rgb[o + 1] = rgba[i + 1];
      rgb[o + 2] = rgba[i + 2];
    }
    final job = (
      ColorProfile.fromMap((values ?? const {}).cast<String, dynamic>()),
      RgbImage(base.width, base.height, rgb),
    );
    final shader = await _shader();
    final image = shader == null
        ? await _imageOf(await _correct(job))
        : shader.apply(base, job.$1, await compute(sampleFilter, job));
    if (_disposed) {
      return image;
    }
    _corrected?.dispose();
    _corrected = image;
    _correctedOf = frame;
    _correctedProfile = _profile;
    _correctedValues = values;
    return image.clone();
  }

  /// The preview frame, colour corrected when that is on, with the
  /// overlays drawn for the matched sample (a made-up one without a dive,
  /// so that they show).
  Future<void> _compose() async {
    final frame = _frame;
    final ticket = ++_composeTicket;
    if (frame == null) {
      notifyListeners();
      return;
    }
    // Copies of its own: a scrub may replace the frame meanwhile.
    final plain = frame.clone();
    final original = frame.clone();
    ui.Image base;
    try {
      base = await _coloured(frame, plain);
    } on Object {
      // A frame that cannot be corrected is shown as it is.
      base = plain.clone();
    } finally {
      plain.dispose();
    }
    // A comparison: the original on one side, as the run writes it (a
    // wipe is shown as it stands half way).
    final compared = compareChoice;
    if (compared != null) {
      try {
        final split = await _split(original, base, compared.kind);
        base.dispose();
        base = split;
      } on Object {
        // Shown without the split.
      }
    }
    original.dispose();
    ui.Image composed;
    try {
      final layers = _layers();
      composed = layers.isEmpty
          ? base.clone()
          : await (await engine()).overlaid(
              base,
              layers,
              // Made-up values to place the overlays by while no dive is
              // matched.
              _dive != null
                  ? _waypoint
                  : _waypoint ??
                        Waypoint(
                          timestamp: _now(),
                          timeSinceStart: 0,
                          depth: 10.5,
                          temp: 22.0,
                        ),
              _dive?.waypoints,
            );
    } on Object {
      composed = base.clone();
    } finally {
      base.dispose();
    }
    if (ticket != _composeTicket || _disposed) {
      composed.dispose();
      return;
    }
    _preview?.dispose();
    _preview = composed;
    notifyListeners();
  }

  int? _selected;

  /// The overlay selected on the preview.
  PlacedOverlay? get selectedOverlay =>
      overlays.where((o) => o.id == _selected).firstOrNull;

  Future<void> removeOverlayAt(int index) async {
    if (index < 0 || index >= overlays.length) {
      return;
    }
    final removed = overlays.removeAt(index);
    if (removed.id == _selected) {
      _selected = null;
    }
    _persistOverlays();
    await _compose();
  }

  _Drag? _drag;

  /// The pointer went down at ([x], [y]) on the preview frame; [handle] is
  /// the handles' reach there, in frame pixels.
  void pressAt(double x, double y, double handle) {
    final selected = selectedOverlay;
    if (selected != null) {
      final box = boxOf(selected);
      if (box != null) {
        for (final MapEntry(key: corner, value: (cx, cy)) in cornerPoints(
          box,
        ).entries) {
          if ((x - cx).abs() <= handle && (y - cy).abs() <= handle) {
            final (anchorX, anchorY) = cornerPoints(
              box,
            )[_oppositeCorner[corner]]!;
            final (x0, y0, x1, y1) = box;
            _drag = _Drag.resize(
              selected.id,
              corner,
              anchorX,
              anchorY,
              math.max(
                1,
                math.sqrt(math.pow(x1 - x0, 2) + math.pow(y1 - y0, 2)),
              ),
              selected.scale,
              (x1 - x0).toDouble(),
              (y1 - y0).toDouble(),
            );
            notifyListeners();
            return;
          }
        }
      }
    }
    // A watermark lies above the overlays.
    if (_pressMark(x, y)) {
      return;
    }
    for (final overlay in overlays.reversed) {
      final box = boxOf(overlay);
      if (box == null) {
        continue;
      }
      final (x0, y0, x1, y1) = box;
      if (x0 - 0.5 <= x && x <= x1 + 0.5 && y0 - 0.5 <= y && y <= y1 + 0.5) {
        _selected = overlay.id;
        _drag = _Drag.move(overlay.id, x, y, overlay.x, overlay.y);
        notifyListeners();
        return;
      }
    }
    _selected = null;
    _drag = null;
    _markDrag = null;
    notifyListeners();
  }

  /// The pointer moved to ([x], [y]) on the preview frame.
  void dragTo(double x, double y) {
    if (_markDrag case final mark?) {
      _dragMark(mark, x, y);
      return;
    }
    final drag = _drag;
    final overlay = overlays.where((o) => o.id == drag?.id).firstOrNull;
    if (drag == null || overlay == null) {
      return;
    }
    double clamp(double v) => v.clamp(-0.5, 1.5);
    if (!drag.resize) {
      overlay
        ..x = clamp(drag.origX + (x - drag.startX) / _viewW)
        ..y = clamp(drag.origY + (y - drag.startY) / _viewH);
    } else {
      final diag = math.sqrt(
        math.pow(x - drag.anchorX, 2) + math.pow(y - drag.anchorY, 2),
      );
      final factor = math.max(0.05, diag / drag.origDiag);
      overlay.scale = math.max(0.1, drag.origScale * factor);
      final anchor = _oppositeCorner[drag.corner]!;
      final newW = drag.origW * factor;
      final newH = drag.origH * factor;
      final x0 = anchor.contains('right') ? drag.anchorX - newW : drag.anchorX;
      final y0 = anchor.contains('bottom') ? drag.anchorY - newH : drag.anchorY;
      overlay
        ..x = clamp(x0 / _viewW)
        ..y = clamp(y0 / _viewH);
    }
    notifyListeners();
    // The overlay follows the box (owner, 2026-11-19: the box ran ahead
    // of the overlay, which was drawn again only when let go).
    unawaited(_composeWhileDragged());
  }

  // Drawn again while the drag goes on: one drawing at a time, then once
  // more with where the overlay is by then.
  bool _composing = false;
  bool _composeWanted = false;

  Future<void> _composeWhileDragged() async {
    _composeWanted = true;
    if (_composing) {
      return;
    }
    _composing = true;
    try {
      while (_composeWanted && dragging && !_disposed) {
        _composeWanted = false;
        await _compose();
      }
    } finally {
      _composing = false;
    }
  }

  /// Whether an overlay is being moved or resized, or a watermark moved.
  bool get dragging => _drag != null || _markDrag != null;

  /// The pointer went up: the new place is drawn and kept.
  Future<void> release() async {
    if (_markDrag != null) {
      _markDrag = null;
      notifyListeners();
      await _compose();
      return;
    }
    if (_drag != null) {
      _drag = null;
      _persistOverlays();
      await _compose();
    }
  }

  // -- the overlay picker ----------------------------------------------------

  /// Brand, dive computer, page and tank setup over the template trees.
  late final TemplatePicker picker = TemplatePicker(
    templates,
    tempDir: tempDir,
    templateBytes: templateBytes,
    relist: relistTemplates,
  );

  /// The picker as "Add Overlay" opens it: on the page added last time,
  /// also after a restart (Python starts at the first brand each time;
  /// spec §10.62).
  void openPicker() => picker.restore(config.fields()[overlayChoiceField]);

  /// Adds the picked page as an overlay, at the bottom left of the
  /// preview. False with the picker's error set when there is no layout
  /// for the choice.
  Future<bool> addPickedOverlay() async {
    final picked = await picker.materialize('uwmedia_qt_color_overlay_');
    if (picked == null) {
      return false;
    }
    _remember(overlayChoiceField, picker.choice);
    final layoutPath = picked.layoutPath;
    _layouts.remove(layoutPath);
    // Seeded at the bottom left; dragged from there. Its size is the
    // computer's own beside the others' (spec §10.100).
    final manifest = picked.manifest;
    final skinSize = _layout(layoutPath)?.skinSize;
    final scale = trueSizeScale(
      widthMm: pictureWidthMm(picked.brand, picked.computer, manifest),
      layout: picked.layout,
      skinSize: skinSize,
    );
    final box = overlayPixelBox(
      picked.layout,
      0,
      0,
      scale,
      _viewW.toInt(),
      _viewH.toInt(),
      skinSize: skinSize,
    );
    final seedH = _viewH == 0 ? 0.0 : (box.$4 - box.$2) / _viewH.toInt();
    overlays.add(
      PlacedOverlay(
        id: _nextId++,
        layoutPath: layoutPath,
        label:
            '${manifest['manufacturer'] ?? picked.brand} '
            '${manifest['model'] ?? picked.computer} - ${picked.page['name']}',
        y: math.max(0, 1 - seedH),
        scale: scale,
      ),
    );
    _persistOverlays();
    await _compose();
    return true;
  }

  // -- the clock offset --------------------------------------------------------

  String get offsetSecondsText => formatOffset(_offsetSeconds);

  /// The offset in force in a few words, for a row that hides the
  /// controls.
  String get offsetSummary =>
      _mediaShiftSeconds == 0 ? 'None' : formatOffset(_mediaShiftSeconds);

  /// The offset in force, under the controls; empty without one.
  String get offsetText {
    final total = _mediaShiftSeconds;
    return total == 0
        ? ''
        : "${formatOffset(total)} added to every file's time before it is "
              'matched to the log';
  }

  /// A previewed file with a date and at least one dive loaded.
  bool get canSync => _creationDate != null && _dives.dives.isNotEmpty;

  Future<void> setOffsetHours(int value) async {
    if (value == _offsetHours) {
      return;
    }
    _offsetHours = value;
    _remember(offsetHoursField, value);
    await _offsetChanged();
  }

  Future<void> nudgeOffset(double seconds) =>
      _setOffsetSeconds(_offsetSeconds + seconds);

  Future<void> resetOffset() => _setOffsetSeconds(0);

  Future<void> _setOffsetSeconds(double seconds) async {
    _offsetSeconds = seconds;
    _remember(offsetSecondsField, seconds);
    await _offsetChanged();
  }

  Future<void> _offsetChanged() async {
    _match();
    await _compose();
  }

  /// The computer in the previewed frame shows dive time [text] ("12:34"):
  /// the seconds are set so that this frame lands on that moment of the
  /// dive. False, with the reason in the status, when that cannot be.
  Future<bool> syncToDiveTime(String text) async {
    final seconds = parseDiveTime(text);
    if (seconds == null) {
      _setStatus("Not a dive time: '$text' (use mm:ss)");
      return false;
    }
    final created = _creationDate;
    if (created == null) {
      _setStatus(
        'Select a source first - the offset is between its clock and the '
        "computer's",
      );
      return false;
    }
    var dive = _dive;
    if (dive == null && _dives.dives.isNotEmpty) {
      final media = _matchTime();
      dive = _dives.dives.values.reduce(
        (a, b) =>
            a.startTime.difference(media).abs() <=
                b.startTime.difference(media).abs()
            ? a
            : b,
      );
    }
    if (dive == null) {
      _setStatus('Select a dive logs folder first');
      return false;
    }
    final onComputer = dive.startTime.add(
      Duration(microseconds: (seconds * 1e6).round()),
    );
    final onCamera = created.add(
      Duration(microseconds: ((_offsetHours * 3600 + _elapsed) * 1e6).round()),
    );
    await _setOffsetSeconds(
      onComputer.difference(onCamera).inMicroseconds / 1e6,
    );
    _setStatus(
      'Synced: this frame is dive time ${text.trim()} - clock offset '
      '${formatOffset(_mediaShiftSeconds)}',
    );
    return true;
  }

  // -- the run ---------------------------------------------------------------

  String _status = idleStatus;
  bool _running = false;
  int _total = 0;
  int _done = 0;
  final List<String> _active = [];
  final Map<String, double> _filePercent = {};
  final List<String> _messages = [];
  Timer? _ticker;

  String get statusText => _status;
  bool get isRunning => _running;
  int get filesDone => _done;
  int get filesTotal => _total;
  List<String> get activeFiles => List.unmodifiable(_active);

  /// The file in progress the page names: of the files worked on at once
  /// the one begun first.
  String? get currentFile => _active.firstOrNull;

  /// How far [currentFile] is, 0 to 1; `null` when it has not said (a
  /// photo says nothing until it is done).
  double? get currentFileFraction {
    final percent = _filePercent[currentFile];
    return percent == null ? null : (percent / 100).clamp(0.0, 1.0);
  }

  /// The run's warnings and errors, a line each.
  List<String> get messages => List.unmodifiable(_messages);

  double get overallFraction => _total == 0 ? 0 : _done / _total;

  /// The whole batch's encoding: each file's last percent (100 once it
  /// ended) over all files.
  double get currentFraction => _total == 0
      ? 0
      : math.min(
          1,
          _filePercent.values.fold<double>(0, (a, b) => a + b) / (_total * 100),
        );

  /// "Elapsed 4:12 · about 9:30 left": the time left is the run's own
  /// estimate (spec §10.97), by the files' sizes and their pace.
  String get timingText => timer.textWithLeft(_estimate?.remaining());

  RunEstimate? _estimate;

  // The run's files by name with their work: a file's size; for a
  // comparison every video the same, as each gives its ten seconds.
  Map<String, RunFile> _runFiles() {
    final sameVideos = _color && compareChoice != null;
    final files = <String, RunFile>{};
    for (final file in _sourceList() ?? const <String>[]) {
      final video = _videoSuffixes.contains(p.extension(file).toLowerCase());
      double weight;
      try {
        weight = video && sameVideos ? 1 : File(file).lengthSync().toDouble();
      } on FileSystemException {
        continue;
      }
      files[p.basename(file)] = (weight: weight, video: video);
    }
    return files;
  }

  void _setStatus(String text) {
    _status = text;
    AppLog.note('Color', text);
    notifyListeners();
  }

  /// Start, or Stop while a run is going.
  Future<void> startOrStop() async {
    if (_running) {
      _stopRequested = true;
      _setStatus('Stopping…');
      await (await engine()).stop();
      return;
    }
    if (!hasSource || _output.trim().isEmpty) {
      _setStatus(
        'Nothing to run: select a source file or folder and an output first.',
      );
      return;
    }
    if (!gate.enter(colorPage)) {
      return;
    }
    _running = true;
    _stopRequested = false;
    _total = 0;
    _done = 0;
    _active.clear();
    _filePercent.clear();
    _estimate = null;
    _messages.clear();
    _drag = null;
    _status = 'Starting…';
    AppLog.note(
      'Color',
      'Run: ${_sourceList()?.length ?? 0} files, colour '
          '${_color ? _profile : 'off'}, ${overlays.length} overlays, size '
          '$_outputSize, $pictureText, part: $partText, into '
          // The folder's name only: a report carries no one's home path.
          '${p.basename(_output).startsWith('uwmedia_photos_out_') ? 'Photos' : 'the folder ${p.basename(_output)}'}',
    );
    timer.start();
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => notifyListeners(),
    );
    notifyListeners();

    final pattern = filenameFormatPresets
        .where((preset) => preset.$1 == _filenameFormat)
        .firstOrNull
        ?.$2;
    final profile = profiles[_profile];
    var ok = false;
    try {
      final tools = await engine();
      if (_stopRequested) {
        // Stop came while the tools were looked for.
        throw const RunStopped();
      }
      final results = await tools.run(
        ColorBatchSettings(
          source: _source.trim(),
          // The picked files that are still there, as the page counts
          // them; when none is, all of them, so that the run names one.
          sourceFiles: switch (_sourceFiles
              .where((file) => File(file).existsSync())
              .toList()) {
            [] => _sourceFiles,
            final there => there,
          },
          output: _output.trim(),
          logsDir: _logs.trim().isEmpty ? null : _logs.trim(),
          keptLogsDir: keptLogsDir,
          colorProfileName: _color ? _profile : null,
          colorProfile: _color
              ? ColorProfile.fromMap(
                  (profile ?? const {}).cast<String, dynamic>(),
                )
              : null,
          overlays: [for (final o in overlays) o.instance],
          watermarks: _watermarkLayers(),
          outputSize: outputSizeChoice,
          compare: compareChoice,
          parts: {
            if ((_part, _videoPath) case (final part?, final video?))
              video: part,
          },
          filenameFormat: pattern == null || pattern.isEmpty ? null : pattern,
          noOverwrite: _skipExisting,
          hwAccel: _hwAccel,
          mediaShiftSeconds: _mediaShiftSeconds,
        ),
        this,
      );
      final failed = results
          .where((r) => r.status == FileStatus.error)
          .toList();
      ok = failed.isEmpty;
      final skipped = results
          .where((r) => r.status == FileStatus.skipped)
          .length;
      _status = ok
          ? 'Finished: ${results.length - skipped} done'
                '${skipped > 0 ? ', $skipped skipped' : ''}'
          : '${failed.length} of ${results.length} '
                'file${results.length != 1 ? 's' : ''} failed: '
                '${failed.map((f) => '${f.file} (${f.error})').join('; ')}';
    } on RunStopped {
      _status = 'Stopped';
    } on Exception catch (e) {
      _status = _reason(e);
    } finally {
      _ticker?.cancel();
      _ticker = null;
      _running = false;
      _active.clear();
      timer.stop(ok: ok);
      gate.leave(colorPage);
      notifyListeners();
      unawaited(_refreshSpace());
    }
  }

  @override
  void started(int total) {
    _total = total;
    _estimate = RunEstimate(timer.clock, _runFiles(), total: total);
    _setStatus('Starting — 0 of $total files…');
  }

  @override
  void active(String file) {
    _estimate?.begun(file);
    if (!_active.contains(file)) {
      _active.add(file);
      notifyListeners();
    }
  }

  @override
  void finished(int done, int total, FileResult result) {
    _done = done;
    _total = total;
    _active.remove(result.file);
    _filePercent[result.file] = 100;
    _estimate?.ended(result.file, counted: result.status == FileStatus.done);
    if (result.status == FileStatus.error) {
      _messages.add('${result.file}: ${result.error}');
      AppLog.note('Color', '${result.file}: ${result.error}');
      unawaited(_noteFacts(result.file));
    }
    _setStatus(
      done >= total
          ? 'Finished — last file: ${result.file}'
          : 'Processing — $done of $total files done…',
    );
  }

  // What a file that failed is, into the log (spec §10.76): a report
  // then says what kind of video the run could not take.
  Future<void> _noteFacts(String name) async {
    final path = _sourceList()
        ?.where((file) => p.basename(file) == name)
        .firstOrNull;
    if (path == null) {
      return;
    }
    try {
      final size = File(path).lengthSync();
      var facts = '$name: $size bytes';
      if (_videoSuffixes.contains(p.extension(path).toLowerCase())) {
        final tools = await engine();
        final (w, h) = await tools.dimensions(path);
        final video = await tools.videoFacts(path);
        facts +=
            ', $w x $h, ${video.fps.toStringAsFixed(2)} fps, '
            '${video.frames} frames';
      }
      AppLog.note('Color', facts);
    } on Object catch (e) {
      AppLog.note('Color', '$name: could not be looked at ($e)');
    }
  }

  @override
  void progress(String file, double percent) {
    _filePercent[file] = percent;
    _estimate?.progress(file, percent);
    if (_status.startsWith('Starting') && _done < _total) {
      _status = 'Processing — $_done of $_total files done…';
    }
    if (_total == 1) {
      _status = 'Processing: $file — ${pyFormatFixed(percent, 0)}%';
    }
    notifyListeners();
  }

  @override
  void message(String line) {
    _messages.add(line);
    AppLog.note('Color', line);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_running) {
      // A batch nobody watches any more is stopped.
      unawaited(engine().then((tools) => tools.stop()));
    }
    _ticker?.cancel();
    _sourceDates.dispose();
    _frame?.dispose();
    _preview?.dispose();
    _corrected?.dispose();
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

double Function() _stopwatchClock() {
  final watch = Stopwatch()..start();
  return () => watch.elapsedMicroseconds / 1e6;
}
