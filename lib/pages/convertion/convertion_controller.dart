/// The Convertion page's state (Python `backends/convertion_backend.py`):
/// a source video, a folder, the resolutions to convert to, the names the
/// files will get, and the run with its progress, elapsed time and Stop.
/// Source and destination are not kept between sessions, as in Python;
/// the folders the dialogs start in and the hardware switch are.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/hud_kit.dart';
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/engine/share_sizes.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/pages/display_paths.dart';
import 'package:uwmedia_app/core/pages/run_timing.dart';
import 'package:uwmedia_app/core/util/py_round.dart';
import 'package:uwmedia_app/core/watermark/watermark.dart';
import 'package:uwmedia_app/engine/app_log.dart';
import 'package:uwmedia_app/engine/desktop/color_run.dart';
import 'package:uwmedia_app/engine/desktop/convert_run.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/overlay_run.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/keep_awake.dart';
import 'package:uwmedia_app/engine/mobile_engine.dart';
import 'package:uwmedia_app/engine/mobile_video_run.dart';
import 'package:uwmedia_app/engine/watermark_store.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';

/// The page's name at the [BatchGate].
const convertionPage = 'Resize';

/// The folders the two dialogs start in, kept in the settings' fields.
const convertionSourceDirField = 'convertion_source_dialog_dir';
const convertionDestDirField = 'convertion_dest_dialog_dir';

/// The hardware encoding switch, shared with Color and Overlay Generator.
const hwAccelField = 'hw_accel_switch';

const noBatchText = 'No batch running';
const outputPreviewHint =
    '(select a source file and at least one output resolution)';
const nothingToRunText =
    'Nothing to run: select a source file, destination folder, and at '
    'least one output resolution first.';

/// The sizes named by where a video is sent (spec §10.49), by the key of
/// each: H.264 copies, as the video was shot.
const shareWhatsAppKey = 'whatsapp';
const shareWeChatKey = 'wechat';
const shareInstagramKey = 'instagram';
const shareKeys = [shareWhatsAppKey, shareWeChatKey, shareInstagramKey];

/// What the page says under its sizes about those named for an app.
const shareSizesHint =
    'WhatsApp, WeChat and Instagram / Facebook are small H.264 copies that '
    'play wherever they are sent. How big a video an app takes changes, so '
    'check the megabytes against what it says. For a portrait copy of a '
    'landscape video, crop it on the Color page ("Resize…").';

/// About how big a video of [seconds] at [bitrate] (a preset's, as
/// `24M`) gets, as the page says it; the sound adds little to it.
String sizeEstimateText(double seconds, String bitrate) =>
    megabytesText(presetBitrate(bitrate) * seconds / 8 / 1000000);

/// A size in megabytes as the page says it.
String megabytesText(double megabytes) {
  if (megabytes < 1) {
    return 'under 1 MB';
  }
  if (megabytes < 1000) {
    return 'about ${megabytes.round()} MB';
  }
  return 'about ${(megabytes / 1000).toStringAsFixed(1)} GB';
}

/// The videos in [folder], by name; none when it cannot be read.
List<String> videosIn(String folder) {
  try {
    return [
      for (final entry in Directory(folder).listSync())
        if (entry is File &&
            isVideoPath(entry.path) &&
            !p.basename(entry.path).startsWith('.'))
          entry.path,
    ]..sort();
  } on FileSystemException {
    return const [];
  }
}

/// What the page needs of the media engine.
abstract interface class ConvertionEngine {
  /// The video's width and height.
  Future<(int, int)> dimensions(String path);

  /// The video's length in seconds.
  Future<double> duration(String path);

  /// See [ConvertRun.convert].
  Future<ConvertResult> convert({
    required String source,
    required String outputDir,
    required List<String> resolutions,
    required bool hwAccel,
    required RunControl control,
    List<ShareCopy> shares,
    List<HudLayerSource> watermarks,
    void Function(ConvertStep step)? onStep,
    void Function(double percent)? onProgress,
  });
}

/// The engine on the desktop: ffmpeg and exiftool as found now.
class DesktopConvertionEngine implements ConvertionEngine {
  DesktopConvertionEngine(this.tools, {this.kit, this.tempDir, this.native});

  /// The runner's media engine when the videos are to be written by it
  /// (asked for at each run: the setting may have changed); `null`, or
  /// answering `null`, for ffmpeg.
  final MobileMediaEngine? Function()? native;

  final DesktopTools tools;

  /// What draws a watermark, loaded when one is asked for, and where its
  /// pictures are made; without them none is drawn.
  final Future<HudKit> Function()? kit;
  final Directory Function(String prefix)? tempDir;

  @override
  Future<(int, int)> dimensions(String path) =>
      tools.ffmpeg.displayDimensions(path);

  @override
  Future<double> duration(String path) => tools.ffmpeg.duration(path);

  @override
  Future<ConvertResult> convert({
    required String source,
    required String outputDir,
    required List<String> resolutions,
    required bool hwAccel,
    required RunControl control,
    List<ShareCopy> shares = const [],
    List<HudLayerSource> watermarks = const [],
    void Function(ConvertStep step)? onStep,
    void Function(double percent)? onProgress,
  }) =>
      // On a Mac: not slowed behind other windows (spec §10.98).
      withScreenOn(() async {
        final temp = tempDir;
        final drawing = watermarks.isEmpty || temp == null
            ? null
            : await kit?.call();
        final engine = temp == null ? null : native?.call();
        return ConvertRun(
          ffmpeg: tools.ffmpeg,
          exiftool: tools.exiftool,
          native: engine == null
              ? null
              : MobileVideoRun(
                  engine: engine,
                  tempDir: temp!,
                  renderer: drawing?.renderer,
                  painter: drawing?.painter,
                ),
          marker: drawing == null
              ? null
              : (hw) => OverlayRun(
                  color: ColorRun(
                    tools: tools.ffmpeg,
                    engine: ColorEngine(ColorProfile.fromMap(const {})),
                    tempDir: temp!,
                    hwAccel: hw,
                  ),
                  renderer: drawing.renderer,
                  painter: drawing.painter,
                ),
        ).convert(
          source: source,
          outputDir: outputDir,
          resolutions: resolutions,
          shares: shares,
          watermarks: watermarks,
          hwAccel: hwAccel,
          control: control,
          onStep: onStep,
          onProgress: onProgress,
        );
      });
}

class ConvertionController extends ChangeNotifier {
  ConvertionController({
    required this.config,
    required this.gate,
    required this.home,
    required this.engine,
    this.watermarkStore,
    double Function()? clock,
  }) : timer = RunTimer(clock ?? _stopwatchClock()) {
    final saved = config.fields()[hwAccelField];
    _hwAccel = saved is! bool || saved;
  }

  final ConfigStore config;
  final BatchGate gate;
  final String home;

  /// The diver's watermarks (Settings); `null` where there are none.
  final WatermarkStore? watermarkStore;

  /// The watermarks by name.
  List<String> get watermarkList => [
    for (final mark in watermarkStore?.list() ?? const <Watermark>[]) mark.name,
  ];

  /// Whether the run puts the watermark called [name] on every copy; the
  /// same choice as the Color page's.
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
      // The settings cannot be written: not chosen.
    }
    notifyListeners();
  }

  /// A watermark added, changed or chosen elsewhere.
  void watermarksChanged() => notifyListeners();

  /// The engine for a probe or a run; throws when the tools are missing.
  final Future<ConvertionEngine> Function() engine;
  final RunTimer timer;

  String _source = '';

  // Every video of the run ([_source] is the first), with what the probe
  // gave of each: its height, its length in seconds.
  List<String> _sources = const [];
  Map<String, int> _heights = const {};
  Map<String, int> _widths = const {};
  Map<String, double> _lengths = const {};

  // The sizes for sharing that are on.
  final Map<String, bool> _shareChecked = {
    for (final key in shareKeys) key: false,
  };
  String _dest = '';
  String _sourceResolutionText = '';
  late bool _hwAccel;
  final Map<String, bool> _checked = {
    for (final (name, _, _, _) in convertResolutions) name: false,
  };
  final Map<String, bool> _enabled = {
    for (final (name, _, _, _) in convertResolutions) name: true,
  };

  String _status = noBatchText;
  RunControl? _control;
  int _total = 0;
  int _done = 0;
  String? _target;
  double _percent = 0;
  Timer? _ticker;
  bool _stopping = false;
  bool _disposed = false;

  /// The source: the video, or the first of several.
  String get sourceText => _source;

  /// Every video of the run.
  List<String> get sources => List.unmodifiable(_sources);

  /// The source as its field shows it: the one video, or how many there
  /// are and where.
  String get sourceDisplay => _sources.length < 2
      ? displayPath(_source)
      : '${_sources.length} videos in ${displayPath(p.dirname(_source))}';
  String get destText => _dest;
  String get sourceResolutionText => _sourceResolutionText;
  bool get hwAccel => _hwAccel;
  String get statusText => _status;
  bool get isRunning => _control != null;

  List<String> get resolutionNames => [
    for (final (name, _, _, _) in convertResolutions) name,
  ];

  bool isChecked(String name) => _checked[name] ?? false;

  bool isEnabled(String name) => _enabled[name] ?? false;

  // Whether [source] can be made [name]'s size: not above its own.
  bool _allowed(String source, String name) {
    final height = _heights[source];
    if (height == null) {
      return true;
    }
    for (final (preset, _, rh, _) in convertResolutions) {
      if (preset == name) {
        return rh <= height;
      }
    }
    return false;
  }

  /// About how big the source gets at the resolution [name] (several
  /// videos: all of them together); empty while no length is known, and
  /// for a size the source cannot have.
  String sizeText(String name) {
    if (!isEnabled(name)) {
      return '';
    }
    final seconds = [
      for (final source in _sources)
        if (_allowed(source, name)) ?_lengths[source],
    ];
    if (seconds.isEmpty) {
      return '';
    }
    for (final (preset, _, _, bitrate) in convertResolutions) {
      if (preset == name) {
        return sizeEstimateText(seconds.reduce((a, b) => a + b), bitrate);
      }
    }
    return '';
  }

  // --- The copies for sharing (spec §10.49) -----------------------------

  bool isShareChecked(String key) => _shareChecked[key] ?? false;

  void setShareChecked(String key, bool value) {
    if (_shareChecked[key] == value) {
      return;
    }
    _shareChecked[key] = value;
    notifyListeners();
  }

  /// The first video's picture size, once measured.
  (int, int)? get sourceSize {
    final w = _widths[_source];
    final h = _heights[_source];
    return w == null || h == null ? null : (w, h);
  }

  // The copy of [key]: as the video was shot, landscape or portrait (a
  // crop to portrait is the Color page's, where the overlays and the
  // watermark are laid on what it leaves; owner, 2026-11-17).
  ShareCopy _copyOf(String key) => ShareCopy(switch (key) {
    shareWhatsAppKey => shareWhatsApp,
    shareWeChatKey => shareWeChat,
    _ => shareInstagram,
  }, ShareShape.asShot);

  /// The copies for sharing a run makes of each video.
  List<ShareCopy> get shares => [
    for (final key in shareKeys)
      if (isShareChecked(key)) _copyOf(key),
  ];

  /// What the page calls the copy of [key].
  String shareTitle(String key) => _copyOf(key).size.name;

  /// The picture size of the copy of [key] (of the first video) and
  /// about how big all the videos' copies get together; the size alone
  /// while no length is known, empty before a video is measured.
  String shareText(String key) {
    final copy = _copyOf(key);
    final first = sourceSize;
    if (first == null) {
      return '';
    }
    final frame = shareFrame(copy, first.$1, first.$2);
    var megabytes = 0.0;
    var timed = false;
    for (final source in _sources) {
      final w = _widths[source];
      final h = _heights[source];
      final seconds = _lengths[source];
      if (w != null && h != null && seconds != null) {
        megabytes += shareFrame(copy, w, h).bitrate * seconds / 8 / 1000000;
        timed = true;
      }
    }
    final size = '${frame.width}x${frame.height}';
    return timed ? '$size, ${megabytesText(megabytes)}' : size;
  }

  /// A path as the fields show it, the home folder as `~`.
  String displayPath(String path) => contractHomePath(path, home) ?? path;

  String get sourceDialogDir => config.dialogDirFor(
    convertionSourceDirField,
    home: home,
    start: StartFolder.pictures,
  );

  String get destDialogDir =>
      config.dialogDirFor(convertionDestDirField, home: home);

  set hwAccel(bool value) {
    if (value == _hwAccel) {
      return;
    }
    _hwAccel = value;
    _remember(hwAccelField, value);
    notifyListeners();
  }

  /// The video picked in the dialog: remembered, then measured so that
  /// only resolutions up to its own can be picked.
  Future<void> chooseSource(String path) => chooseSources([path]);

  /// The videos picked in the dialog (a folder among them stands for the
  /// videos in it): each measured; a resolution can be picked when one of
  /// them is that big, and a run makes of each video the sizes up to its
  /// own.
  /// Without [remember] the dialog's folder is left as it was (videos
  /// picked in Photos lie in a working folder).
  Future<void> chooseSources(List<String> paths, {bool remember = true}) async {
    final picked = [
      for (final path in paths)
        if (FileSystemEntity.isDirectorySync(path)) ...videosIn(path) else path,
    ];
    if (picked.isEmpty) {
      return;
    }
    if (remember) {
      _remember(convertionSourceDirField, p.dirname(picked.first));
    }
    _source = picked.first;
    _sources = picked;
    // The last files' limits do not hold for these.
    _sourceResolutionText = '';
    _heights = const {};
    _widths = const {};
    _lengths = const {};
    for (final name in _enabled.keys) {
      _enabled[name] = true;
    }
    notifyListeners();
    final heights = <String, int>{};
    final widths = <String, int>{};
    final lengths = <String, double>{};
    (int, int)? largest;
    String? failure;
    for (final path in picked) {
      try {
        final tools = await engine();
        final (w, h) = await tools.dimensions(path);
        heights[path] = h;
        widths[path] = w;
        if (largest == null || h > largest.$2) {
          largest = (w, h);
        }
        try {
          lengths[path] = await tools.duration(path);
        } on Exception {
          // The sizes are then shown without its megabytes.
        }
      } on Exception catch (e) {
        failure ??= _reason(e);
      }
    }
    if (!identical(_sources, picked) || _disposed) {
      // Other files were picked meanwhile.
      return;
    }
    String label;
    if (largest == null) {
      label = 'Could not detect resolution: $failure';
    } else {
      final (w, h) = largest;
      label = '${w}x$h';
      for (final (name, _, rh, _) in convertResolutions) {
        if (rh <= h) {
          label = '${w}x$h (up to $name)';
          break;
        }
      }
      if (picked.length > 1) {
        final unread = picked.length - heights.length;
        label =
            '${picked.length} videos, the largest $label'
            '${unread > 0 ? '; $unread could not be read' : ''}';
      }
    }
    _sourceResolutionText = label;
    _heights = heights;
    _widths = widths;
    _lengths = lengths;
    for (final (name, _, _, _) in convertResolutions) {
      final allowed = picked.any((source) => _allowed(source, name));
      _enabled[name] = allowed;
      if (!allowed) {
        _checked[name] = false;
      }
    }
    notifyListeners();
  }

  // A folder or a switch kept in the settings; one that cannot be written
  // is only not kept.
  void _remember(String key, Object? value) {
    try {
      config.setField(key, value);
    } on FileSystemException {
      // The config folder cannot be written.
    }
  }

  void chooseDest(String path, {bool remember = true}) {
    if (remember) {
      _remember(convertionDestDirField, path);
    }
    _dest = path;
    notifyListeners();
  }

  void setChecked(String name, bool value) {
    if (_checked[name] == value) {
      return;
    }
    _checked[name] = value;
    notifyListeners();
  }

  List<String> get _selected => [
    for (final MapEntry(:key, :value) in _checked.entries)
      if (value) key,
  ];

  /// The files a run will write, a line each, or a hint while there is
  /// nothing to say.
  String get outputPreviewText {
    final source = _source.trim();
    final dest = _dest.trim();
    final selected = _selected;
    final copies = shares;
    if (source.isEmpty || (selected.isEmpty && copies.isEmpty)) {
      return outputPreviewHint;
    }
    return [
      for (final video in _sources) ...[
        for (final name in selected)
          if (_allowed(video, name)) convertOutputFilename(video, name),
        for (final copy in copies) copy.filename(video),
      ],
    ].map((name) => dest.isEmpty ? name : p.join(dest, name)).join('\n');
  }

  /// False until the run has said how many encodes it holds.
  bool get progressKnown => _total > 0;

  /// 0 to 1 over the run: encodes done plus the percent of the one going.
  double get progressFraction {
    if (_total <= 0) {
      return 0;
    }
    var done = _done.toDouble();
    if (_target != null && _done < _total) {
      done += _percent / 100;
    }
    return (done / _total).clamp(0.0, 1.0);
  }

  String get progressFractionText => !isRunning || _total <= 0
      ? ''
      : '$_done/$_total · ${pyFormatFixed(progressFraction * 100, 0)}%';

  String get timingText => timer.text(progressFraction);

  void _setStatus(String text) {
    // After Stop, the run's last lines do not cover "Stopping…".
    if (!_stopping) {
      _status = text;
    }
    notifyListeners();
  }

  /// Start, or Stop while a run is going.
  Future<void> startOrStop() async {
    final running = _control;
    if (running != null) {
      if (!_stopping) {
        _setStatus('Stopping…');
        _stopping = true;
        await running.stop();
      }
      return;
    }
    final source = _source.trim();
    final dest = _dest.trim();
    final selected = _selected;
    final copies = shares;
    // Of each video, the sizes up to its own; every copy for sharing.
    final jobs = [
      for (final video in _sources)
        (
          video,
          [
            for (final name in selected)
              if (_allowed(video, name)) name,
          ],
        ),
    ].where((job) => job.$2.isNotEmpty || copies.isNotEmpty).toList();
    if (source.isEmpty || dest.isEmpty || jobs.isEmpty) {
      _setStatus(nothingToRunText);
      return;
    }
    if (!gate.enter(convertionPage)) {
      return;
    }
    final control = RunControl();
    _control = control;
    _total = 0;
    _done = 0;
    _target = null;
    _percent = 0;
    _status = 'Starting…';
    timer.start();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      notifyListeners();
    });
    notifyListeners();

    var ok = false;
    try {
      final tools = await engine();
      final several = jobs.length > 1;
      final marks =
          watermarkStore?.selectedLayers() ?? const <HudLayerSource>[];
      final grand = jobs.fold(
        0,
        (sum, job) => sum + job.$2.length + copies.length,
      );
      final failed = <String>[];
      final errors = <String>[];
      String? saved;
      var before = 0;
      for (final (video, resolutions) in jobs) {
        final base = before;
        final ConvertResult result;
        try {
          result = await tools.convert(
            source: video,
            outputDir: dest,
            resolutions: resolutions,
            shares: copies,
            watermarks: marks,
            hwAccel: _hwAccel,
            control: control,
            onStep: (step) {
              // The run's first word is said once, for all the videos.
              if (base > 0 && step.done == 0 && step.target == null) {
                return;
              }
              _onStep((
                done: base + step.done,
                total: grand,
                target: step.target,
              ));
            },
            onProgress: _onProgress,
          );
        } on RunStopped {
          rethrow;
        } on Exception catch (e) {
          if (!several) {
            rethrow;
          }
          // One video's failure is that video's; the others go on.
          failed.add(p.basename(video));
          errors.add('Error converting ${p.basename(video)}: ${_reason(e)}');
          before += resolutions.length + copies.length;
          continue;
        }
        before += resolutions.length + copies.length;
        if (result.failed.isNotEmpty) {
          failed.add(
            several
                ? '${p.basename(video)} (${result.failed.join(', ')})'
                : result.failed.join(', '),
          );
        }
        for (final line in result.messages) {
          AppLog.note('Resize', line);
        }
        errors.addAll(result.messages.where((m) => m.startsWith('Error')));
        // A phone's run says which album it saved into.
        saved ??= result.messages
            .where((m) => m.startsWith('Saved into'))
            .firstOrNull;
      }
      ok = failed.isEmpty;
      _status = ok
          ? saved == null
                ? 'Finished'
                : 'Finished. $saved'
          : 'Failed: ${failed.join(', ')}\n${errors.join('\n')}';
    } on RunStopped {
      _status = 'Stopped';
    } on Exception catch (e) {
      _status = _reason(e);
    } finally {
      _ticker?.cancel();
      _ticker = null;
      AppLog.note('Resize', _status);
      _control = null;
      _stopping = false;
      timer.stop(ok: ok);
      gate.leave(convertionPage);
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  void _onStep(ConvertStep step) {
    _done = step.done;
    _total = step.total;
    _percent = 0;
    _target = step.target;
    if (step.target == null && step.done == 0) {
      _setStatus('Processing 0 of ${step.total}…');
    } else if (step.done >= step.total) {
      _setStatus('Finished — last file: ${step.target ?? ''}');
    } else if (step.target == null) {
      _setStatus('Processing ${step.done} of ${step.total}…');
    } else {
      _setStatus('Processing: ${step.target}');
    }
  }

  void _onProgress(double percent) {
    _percent = percent.clamp(0.0, 100.0);
    final shown = pyFormatFixed(percent, 0);
    _setStatus(
      _target != null
          ? 'Processing: $_target — $shown%'
          : 'Rendering — $shown%',
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    unawaited(_control?.stop());
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
