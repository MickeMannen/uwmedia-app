/// The Color page's batch on the desktop (Python `cli_main.py` as the page
/// starts it: `main` for a file or a folder, `process_single_file` for
/// each file, `_parallel_worker` for several at once): the dives of a
/// folder of logs, and every photo and video of the source colour
/// corrected, given its overlays for the dive of the moment it was taken,
/// or copied, each under the name the settings give, with its metadata
/// carried over.
///
/// The page starts the runs in the app instead of the CLI (spec §10.35).
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/engine/compare.dart';
import 'package:uwmedia_app/core/engine/share_sizes.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/model/dive_manager.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/engine/desktop/color_run.dart';
import 'package:uwmedia_app/engine/desktop/exiftool.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/overlay_run.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/desktop/wipe_run.dart';
import 'package:uwmedia_app/engine/mobile_engine.dart';
import 'package:uwmedia_app/engine/mobile_video_run.dart';
import 'package:uwmedia_app/engine/photo_run.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

/// One overlay of the run: a layout file and where the user put it
/// (fractions of the frame, and a scale), as the page's overlay list and
/// Python's `--overlays-file` entries hold it.
class OverlayInstance {
  const OverlayInstance({
    required this.layoutPath,
    this.x = 0,
    this.y = 0,
    this.scale = 1,
  });

  factory OverlayInstance.fromJson(Map<String, dynamic> json) =>
      OverlayInstance(
        layoutPath: json['layout_path'] as String,
        x: (json['x'] as num? ?? 0).toDouble(),
        y: (json['y'] as num? ?? 0).toDouble(),
        scale: (json['scale'] as num? ?? 1).toDouble(),
      );

  final String layoutPath;
  final double x;
  final double y;
  final double scale;

  Map<String, Object?> toJson() => {
    'layout_path': layoutPath,
    'x': x,
    'y': y,
    'scale': scale,
  };

  OverlayInstance moved({double? x, double? y, double? scale}) =>
      OverlayInstance(
        layoutPath: layoutPath,
        x: x ?? this.x,
        y: y ?? this.y,
        scale: scale ?? this.scale,
      );
}

/// What the page asks of a run.
class ColorBatchSettings {
  const ColorBatchSettings({
    required this.source,
    required this.output,
    this.sourceFiles = const [],
    this.logsDir,
    this.keptLogsDir,
    this.colorProfileName,
    this.colorProfile,
    this.overlays = const [],
    this.filenameFormat,
    this.noOverwrite = false,
    this.hwAccel = true,
    this.mediaShiftSeconds = 0,
    this.watermarks = const [],
    this.outputSize,
    this.parts = const {},
    this.compare,
  });

  /// Before and after the colour correction in one picture (spec
  /// §10.94): a split photo or video, or a photo's wipe video; `null`
  /// for the corrected picture alone. Only with a colour profile.
  final Compare? compare;

  /// A file, or a folder of them.
  final String source;

  /// Files picked one by one, run as a folder's are; [source] is not
  /// looked at then (spec §10.65).
  final List<String> sourceFiles;

  /// A folder, or for a single source a file name.
  final String output;

  /// The dive-logs folder; `null` or empty without one.
  final String? logsDir;

  /// Where the app keeps the logs imported on the Dive Logs page, read
  /// with the folder's (spec §10.57); `null` on a page without them.
  final String? keptLogsDir;

  /// The colour profile's name and values; `null` without colour
  /// correction.
  final String? colorProfileName;
  final ColorProfile? colorProfile;
  final List<OverlayInstance> overlays;

  /// The name pattern; `null` keeps each source's name.
  final String? filenameFormat;
  final bool noOverwrite;
  final bool hwAccel;

  /// The camera's clock offset, added to a file's time before it is
  /// matched to a dive (the output keeps the file's own time).
  final double mediaShiftSeconds;

  /// The diver's watermark: a layer drawn on every file, above the
  /// overlays; `null` for none.
  final List<HudLayerSource> watermarks;

  /// The size the videos are written in; `null` for their own (spec
  /// §10.51). Photos keep theirs.
  final OutputSize? outputSize;

  /// The part to write of a video, by its source file (spec §10.71): a
  /// video not named is written whole. Only the runs through the
  /// runner's media engine take it.
  final Map<String, ClipPart> parts;

  bool get colorCorrect => colorProfile != null;

  NamingArgs get naming => NamingArgs(
    filenameFormat: filenameFormat,
    keepFilename: filenameFormat == null,
    overlayLayoutPaths: [for (final o in overlays) o.layoutPath],
    color: colorProfile == null ? null : colorProfileName ?? 'default',
    noOverwrite: noOverwrite,
  );
}

/// How one file ended.
enum FileStatus { done, skipped, error }

typedef FileResult = ({String file, FileStatus status, String? error});

/// What a run hears as it goes (Python's `UWMEDIA_PROGRESS` lines).
abstract interface class ColorBatchListener {
  /// The run's files are known: [total] of them.
  void started(int total);

  /// A file is being worked on now.
  void active(String file);

  /// The [done]th file of [total] ended.
  void finished(int done, int total, FileResult result);

  /// The percent of the encode or render of [file].
  void progress(String file, double percent);

  /// A line worth showing: a warning, a skipped file, a match.
  void message(String line);
}

/// The dives of a folder of logs, and a line for each log that could not
/// be read.
typedef LoadedDives = ({List<Dive> dives, List<String> messages});

/// Reads every log of [folder] (not hidden files, not subfolders). A log
/// that cannot be read is a message, not the end of the run.
LoadedDives loadDiveLogs(String folder, TankConfig tanks) {
  final dives = <Dive>[];
  final messages = <String>[];
  final entries = Directory(folder).listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in entries) {
    final name = p.basename(file.path);
    if (name.startsWith('.')) {
      continue;
    }
    try {
      final found = parseLogFile(
        file.path,
        file.readAsBytesSync(),
        tanks: tanks,
      );
      if (found != null) {
        dives.addAll(found);
      }
    } on Object catch (e) {
      messages.add('Warning: $name could not be read ($e)');
    }
  }
  return (dives: dives, messages: messages);
}

/// The dives a run matches its files to: those of the logs kept in the
/// app ([kept], when there are any) and of the logs folder ([folder],
/// when one is set), read on another isolate. Throws a [FormatException]
/// for a folder that is set and not there.
Future<LoadedDives> loadDiveSources(
  TankConfig tanks, {
  String? kept,
  String? folder,
}) async {
  final dives = <Dive>[];
  final messages = <String>[];
  final set = folder != null && folder.trim().isNotEmpty;
  if (set && !FileSystemEntity.isDirectorySync(folder)) {
    throw FormatException('Log directory $folder not found.');
  }
  for (final dir in [
    if (kept != null && FileSystemEntity.isDirectorySync(kept)) kept,
    if (set) folder,
  ]) {
    final loaded = await loadDiveLogsOffThread(dir, tanks);
    dives.addAll(loaded.dives);
    messages.addAll(loaded.messages);
  }
  return (dives: dives, messages: messages);
}

/// [loadDiveLogs] on another isolate, or the dives of the last read of
/// [folder] when its logs and [tanks] are as they were then: the page has
/// read them to match its files, and a run takes those instead of parsing
/// every log again (owner, 2026-11-19). A top-level function so the
/// closure sent there holds only [folder] and [tanks]: a closure made
/// inside a method carries that method's whole context (the listener, the
/// page behind it), and a timer in there cannot be sent.
Future<LoadedDives> loadDiveLogsOffThread(String folder, TankConfig tanks) {
  final mark = _logsMark(folder, tanks);
  final last = _lastRead[folder];
  if (last != null && last.mark == mark) {
    return last.loaded;
  }
  final loaded = Isolate.run(() => loadDiveLogs(folder, tanks));
  _lastRead[folder] = (mark: mark, loaded: loaded);
  // A read that failed is not kept.
  unawaited(
    loaded.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_lastRead[folder]?.loaded, loaded)) {
          _lastRead.remove(folder);
        }
      },
    ),
  );
  return loaded;
}

/// The last read of each folder of logs, and what it was read with.
final _lastRead = <String, ({String mark, Future<LoadedDives> loaded})>{};

/// What a read of [folder] depends on: each log's name, size and time,
/// and the tank names and sizes the logs are read with.
String _logsMark(String folder, TankConfig tanks) => ([
  for (final file in Directory(folder).listSync().whereType<File>())
    if (!p.basename(file.path).startsWith('.'))
      if (file.statSync() case FileStat(:final size, :final modified))
        'log ${file.path}\t$size\t${modified.microsecondsSinceEpoch}',
  for (final MapEntry(:key, :value) in tanks.tanks.entries) 'tank $key=$value',
  for (final MapEntry(:key, :value) in tanks.sizes.entries) 'size $key=$value',
]..sort()).join('\n');

/// The media files of a folder, as Python's batch takes them: every file
/// but hidden ones, by name.
List<String> batchFiles(String folder) => [
  for (final entry
      in Directory(folder).listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path)))
    if (!p.basename(entry.path).startsWith('.')) entry.path,
];

/// The files picked one by one for a run, in the order they were picked;
/// `null` when none were (the run then takes its source path). Throws a
/// [FormatException] naming a picked file that is gone.
List<String>? pickedSourceFiles(List<String> picked) {
  if (picked.isEmpty) {
    return null;
  }
  for (final file in picked) {
    if (!File(file).existsSync()) {
      throw FormatException("Source file '$file' does not exist.");
    }
  }
  return picked;
}

/// An overlay's layout, with its skin read from beside the layout when
/// its path is relative (Python rewrites the layout file for that; the
/// file is left as it is here).
HudLayerSource overlayLayerSource(OverlayInstance overlay) {
  final layout = loadLayoutFile(
    overlay.layoutPath,
    (path) => File(path).readAsStringSync(),
    context: p.context,
  );
  final skin = layout['hud_skin'];
  final skinPath = skin is Map ? skin['path'] : null;
  Uint8List? bytes;
  if (skinPath is String && skinPath.isNotEmpty) {
    final full = p.isAbsolute(skinPath)
        ? skinPath
        : p.join(p.dirname(overlay.layoutPath), skinPath);
    final file = File(full);
    if (file.existsSync()) {
      bytes = file.readAsBytesSync();
    }
  }
  return HudLayerSource(
    layout,
    skinBytes: bytes,
    placement: (x: overlay.x, y: overlay.y, scale: overlay.scale),
  );
}

/// The part of [source] the run [settings] writes; `null` for all of it.
ClipPart? partOf(ColorBatchSettings settings, String source) {
  for (final MapEntry(:key, :value) in settings.parts.entries) {
    if (p.equals(key, source)) {
      return value;
    }
  }
  return null;
}

class ColorBatch {
  ColorBatch({
    required this.tools,
    required this.renderer,
    required this.painter,
    required this.tempDir,
    this.tanks,
    this.units = UnitSystem.metric,
    this.native,
    int? workers,
  }) : workers = workers ?? math.min(4, Platform.numberOfProcessors);

  /// The runner's media engine, when the videos are to be written by it
  /// and not by ffmpeg (a Mac, `docs/design/macos-remove-ffmpeg.md`): colour, overlays
  /// and an output size go through [MobileVideoRun] as on a phone, and a
  /// video with nothing to change is copied by it (by ffmpeg when it
  /// cannot). The metadata is still copied by exiftool.
  final MobileMediaEngine? native;

  // The engine writes one video at a time: the files of a folder that
  // run side by side take their turn for it.
  Future<void> _nativeTurn = Future.value();

  final ({FfmpegTools ffmpeg, Exiftool exiftool}) tools;
  final HudRenderer renderer;
  final HudPainter painter;

  /// Makes a fresh working folder (`appTempDir` in the app).
  final Directory Function(String prefix) tempDir;
  final TankConfig? tanks;
  final UnitSystem units;

  /// How many files run at once in a folder.
  final int workers;

  final Set<RunControl> _running = {};
  bool _stopped = false;

  /// Stops the files going and starts no more.
  Future<void> stop() async {
    _stopped = true;
    await Future.wait([
      for (final control in _running.toList()) control.stop(),
    ]);
  }

  /// Runs [settings]; the result of every file, in the order they ended.
  /// Throws a [FormatException] for settings the run cannot start with
  /// (a source that is not there, a log folder that is not one).
  Future<List<FileResult>> run(
    ColorBatchSettings settings,
    ColorBatchListener listener,
  ) async {
    _stopped = false;
    final source = settings.source;
    final picked = pickedSourceFiles(settings.sourceFiles);
    final sourceIsFolder =
        picked != null || FileSystemEntity.isDirectorySync(source);
    if (picked == null) {
      if (!sourceIsFolder && !File(source).existsSync()) {
        throw FormatException("Source path '$source' does not exist.");
      }
      if (samePath(source, settings.output)) {
        throw const FormatException(
          'Source and output paths cannot be the same.',
        );
      }
    }

    // The dives, read on another isolate.
    final manager = DiveManager();
    final loaded = await loadDiveSources(
      tanks ?? TankConfig(),
      kept: settings.keptLogsDir,
      folder: settings.logsDir,
    );
    loaded.messages.forEach(listener.message);
    manager.addDives(loaded.dives);

    final layers = [
      for (final overlay in settings.overlays) overlayLayerSource(overlay),
      ...settings.watermarks,
    ];

    // The files and where they go.
    final String outputDir;
    String? forcedFilename;
    final List<String> files;
    if (sourceIsFolder) {
      if (File(settings.output).existsSync()) {
        throw const FormatException(
          'Source is a directory but output is a file.',
        );
      }
      outputDir = settings.output;
      files = picked ?? batchFiles(source);
    } else {
      final output = settings.output;
      if (p.extension(output).isEmpty ||
          FileSystemEntity.isDirectorySync(output)) {
        outputDir = output;
      } else {
        // A file name given: that name is used as it is.
        outputDir = p.dirname(output);
        forcedFilename = p.basename(output);
      }
      files = [source];
    }
    Directory(outputDir).createSync(recursive: true);

    final unique = UniquePaths(
      (path) =>
          FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound,
    );
    final results = <FileResult>[];
    listener.started(files.length);

    Future<void> one(String file) async {
      if (_stopped) {
        return;
      }
      listener.active(p.basename(file));
      FileResult result;
      try {
        result = await _processFile(
          file,
          outputDir: outputDir,
          sourceIsFolder: sourceIsFolder,
          forcedFilename: forcedFilename,
          settings: settings,
          manager: manager,
          layers: layers,
          unique: unique,
          listener: listener,
        );
      } on RunStopped {
        return;
      } on Object catch (e) {
        result = (
          file: p.basename(file),
          status: FileStatus.error,
          error: '$e',
        );
      }
      results.add(result);
      listener.finished(results.length, files.length, result);
    }

    if (files.length > 1) {
      var next = 0;
      Future<void> worker() async {
        while (!_stopped && next < files.length) {
          await one(files[next++]);
        }
      }

      await Future.wait([
        for (var i = 0; i < math.min(workers, files.length); i++) worker(),
      ]);
    } else {
      for (final file in files) {
        await one(file);
      }
    }
    if (_stopped) {
      throw const RunStopped();
    }
    return results;
  }

  /// Whether [a] is the output [b] (or, when [b] is not there yet, its
  /// folder).
  static bool samePath(String a, String b) {
    try {
      final output =
          FileSystemEntity.typeSync(b) == FileSystemEntityType.notFound
          ? p.dirname(b)
          : b;
      return File(a).resolveSymbolicLinksSync() ==
          File(output).resolveSymbolicLinksSync();
    } on FileSystemException {
      return false;
    }
  }

  Future<FileResult> _processFile(
    String source, {
    required String outputDir,
    required bool sourceIsFolder,
    required String? forcedFilename,
    required ColorBatchSettings settings,
    required DiveManager manager,
    required List<HudLayerSource> layers,
    required UniquePaths unique,
    required ColorBatchListener listener,
  }) async {
    final name = p.basename(source);
    final exiftool = tools.exiftool;
    final meta = await exiftool.metadata(source);
    final DateTime creationDate;
    try {
      creationDate = localCreationDate(
        meta,
        fileModified: fileModified(source),
      );
    } on FormatException catch (e) {
      return (
        file: name,
        status: FileStatus.error,
        error: 'Error extracting metadata: ${e.message}',
      );
    }

    final naming = settings.naming;
    var size = isVideoPath(source) ? settings.outputSize : null;
    // A photo keeps its size and takes only the window (spec §10.77).
    final cutOfRun = settings.outputSize?.pictureCut;
    final photoCut = !isVideoPath(source) && cutOfRun != null && cutOfRun.cuts
        ? cutOfRun
        : null;
    if (size != null) {
      // A size that leaves this video as it is (a resolution it does not
      // reach) is no size: the file takes the run's usual way.
      try {
        final (w, h) = await tools.ffmpeg.displayDimensions(source);
        if (size.frameFor(w, h) == null) {
          size = null;
        }
      } on EngineException {
        // The run itself says what is wrong with the file.
      }
    }
    // A comparison (spec §10.94) only of a colour correction; a video is
    // always split, a photo split or made a wipe video.
    final compare = settings.colorCorrect ? settings.compare : null;
    final wipe = compare != null && compare.wipe && !isVideoPath(source);
    var filename = outputFilename(
      source: source,
      outputDir: outputDir,
      sourceIsFolder: sourceIsFolder,
      args: naming,
      creationDate: creationDate,
      forcedFilename: forcedFilename,
    );
    if (size != null && size.h264) {
      // A copy for sharing is an MP4 whatever the source is.
      filename = p.setExtension(filename, '.mp4');
    }
    if (compare != null) {
      filename = compareFilename(filename, video: wipe);
    }
    final target = resolveTargetPath(
      target: p.join(outputDir, filename),
      source: source,
      args: naming,
      unique: unique,
      sameFile: (a, b) {
        try {
          return File(a).resolveSymbolicLinksSync() ==
              File(b).resolveSymbolicLinksSync();
        } on FileSystemException {
          return false;
        }
      },
    );
    if (target.skipped) {
      listener.message('Skipping: Target file ${target.path} already exists.');
      return (file: name, status: FileStatus.skipped, error: null);
    }
    final targetPath = target.path;
    Directory(p.dirname(targetPath)).createSync(recursive: true);

    final tzOffsetMins = timezoneOffsetMinutes(meta);
    final matchDate = creationDate.add(
      Duration(microseconds: (settings.mediaShiftSeconds * 1e6).round()),
    );
    final dive = manager.dives.isEmpty
        ? null
        : manager.findDiveForTimestamp(matchDate);
    if (manager.dives.isNotEmpty && dive == null) {
      listener.message('Warning: No matching dive log found for $name.');
    }

    final colorCorrect = settings.colorCorrect;
    // A part of the video (spec §10.71, §10.75) is written anew even
    // when nothing else is changed.
    // A comparison is ten seconds of the video at most.
    final ownPart = isVideoPath(source) ? partOf(settings, source) : null;
    final part = compare != null && isVideoPath(source)
        ? compareClipPart(ownPart)
        : ownPart;
    final drawn = layersToDraw(layers, matched: dive != null);
    final overlays = layers.isNotEmpty;
    final control = RunControl();
    _running.add(control);
    // A Stop while the file was looked at: no encode.
    if (_stopped) {
      _running.remove(control);
      throw const RunStopped();
    }
    try {
      void progress(double percent) => listener.progress(name, percent);
      final native = this.native;
      if (isVideoPath(source) &&
          native != null &&
          (colorCorrect || overlays || size != null || part != null)) {
        final profile = settings.colorProfile;
        final before = _nativeTurn;
        final turn = Completer<void>();
        _nativeTurn = turn.future;
        try {
          await before;
          if (control.stopped) {
            throw const RunStopped();
          }
          final lines =
              await MobileVideoRun(
                engine: native,
                tempDir: tempDir,
                renderer: renderer,
                painter: painter,
                units: units,
              ).process(
                input: source,
                output: targetPath,
                color: !colorCorrect
                    ? null
                    : ColorEngine(profile ?? ColorProfile.fromMap(const {})),
                layers: drawn,
                dive: dive,
                matchDate: matchDate,
                size: size,
                part: part,
                compare: compare,
                onProgress: progress,
                control: control,
              );
          for (final line in lines) {
            listener.message('$name: $line');
          }
        } finally {
          turn.complete();
        }
        await _copyMetadata(source, targetPath, listener);
      } else if (isVideoPath(source)) {
        if (colorCorrect && !overlays && size == null && compare == null) {
          await _colorRun(settings, part).processVideoLut(
            input: source,
            output: targetPath,
            creationDate: creationDate,
            tzOffsetMins: tzOffsetMins,
            onProgress: progress,
            control: control,
          );
        } else if (colorCorrect || overlays || size != null || part != null) {
          await OverlayRun(
            color: _colorRun(settings, part),
            renderer: renderer,
            painter: painter,
            units: units,
          ).processVideo(
            input: source,
            output: targetPath,
            creationDate: creationDate,
            layers: layers,
            dive: dive,
            // The dive is followed from the part's start.
            matchDate: part == null
                ? matchDate
                : matchDate.add(
                    Duration(microseconds: (part.start * 1e6).round()),
                  ),
            tzOffsetMins: tzOffsetMins,
            colorCorrect: colorCorrect,
            size: size,
            compare: compare,
            onProgress: progress,
            control: control,
          );
        } else {
          // Nothing to change: the video as it is, by the engine when the
          // videos are its, else (or when it cannot) by ffmpeg.
          var copied = false;
          if (native != null) {
            try {
              await native.copy(source, targetPath);
              for (final line in copyVideoDates(source, targetPath)) {
                listener.message('$name: $line');
              }
              progress(100);
              copied = true;
            } on EngineException catch (e) {
              listener.message(
                '$name: copied by FFmpeg (the engine could not: ${e.message})',
              );
            }
          }
          if (!copied) {
            await tools.ffmpeg.processVideo(
              input: source,
              output: targetPath,
              creationDate: creationDate,
              hwAccel: settings.hwAccel,
              tzOffsetMins: tzOffsetMins,
              onProgress: progress,
              onStarted: control.running,
            );
          }
        }
        if (settings.hwAccel &&
            part == null &&
            (colorCorrect || overlays || size != null)) {
          await _warnOfLostFrames(source, targetPath, listener);
        }
        await _copyMetadata(source, targetPath, listener);
      } else if (wipe) {
        // A photo's wipe video: its two pictures, then the frames.
        final pair =
            await PhotoRun(
              renderer: renderer,
              painter: painter,
              engine: ColorEngine(settings.colorProfile!),
              units: units,
            ).pair(
              File(source).readAsBytesSync(),
              layers: drawn,
              dive: dive,
              matchDate: matchDate,
              cut: photoCut,
            );
        if (control.stopped) {
          throw const RunStopped();
        }
        Future<void> write() =>
            WipeRun(
              tools: tools.ffmpeg,
              native: native,
              hwAccel: settings.hwAccel,
            ).write(
              before: pair.before,
              after: pair.after,
              width: pair.width,
              height: pair.height,
              kind: compare.kind,
              output: targetPath,
              box: settings.outputSize?.box,
              onProgress: progress,
              control: control,
            );
        if (native == null) {
          await write();
        } else {
          // The engine writes one video at a time: this one in its turn.
          final before = _nativeTurn;
          final turn = Completer<void>();
          _nativeTurn = turn.future;
          try {
            await before;
            if (control.stopped) {
              throw const RunStopped();
            }
            await write();
          } finally {
            turn.complete();
          }
        }
        await _copyMetadata(source, targetPath, listener);
      } else if (colorCorrect || overlays || photoCut != null) {
        final profile = settings.colorProfile;
        try {
          for (final line
              in await PhotoRun(
                renderer: renderer,
                painter: painter,
                engine: profile == null ? null : ColorEngine(profile),
                units: units,
              ).processFile(
                source,
                targetPath,
                colorCorrect: colorCorrect,
                layers: drawn,
                dive: dive,
                matchDate: matchDate,
                exiftool: exiftool,
                cut: photoCut,
                compare: compare,
              )) {
            listener.message('$name: $line');
          }
        } on EngineException catch (e) {
          // A picture that cannot be read (or written as its type) is
          // copied as it is, as Python does.
          listener.message('Error: Could not process $name ($e); copied.');
          File(source).copySync(targetPath);
          await _copyMetadata(source, targetPath, listener);
        }
      } else {
        File(source).copySync(targetPath);
        await _copyMetadata(source, targetPath, listener);
      }
    } finally {
      _running.remove(control);
    }
    if (control.stopped) {
      throw const RunStopped();
    }
    return (file: name, status: FileStatus.done, error: null);
  }

  ColorRun _colorRun(ColorBatchSettings settings, [ClipPart? part]) => ColorRun(
    part: part,
    tools: tools.ffmpeg,
    engine: ColorEngine(
      settings.colorProfile ?? ColorProfile.fromMap(const {}),
    ),
    tempDir: tempDir,
    hwAccel: settings.hwAccel,
  );

  // A hardware decoder that fails on some pictures loses them without a
  // word (a Sony camera's H.264 on a Mac, spec §10.73): a result with
  // fewer frames than its source is said, so that it is not taken for
  // whole.
  Future<void> _warnOfLostFrames(
    String source,
    String target,
    ColorBatchListener listener,
  ) async {
    try {
      final had = await tools.ffmpeg.countedFrames(source);
      final has = await tools.ffmpeg.countedFrames(target);
      if (had != null && has != null && has < had - 1) {
        listener.message(
          'Warning: ${p.basename(source)} lost ${had - has} of its $had '
          'frames, probably in hardware decoding. Turn "Hardware '
          'acceleration" off and run it again.',
        );
      }
    } on EngineException {
      // Not counted: nothing to say.
    }
  }

  Future<void> _copyMetadata(
    String source,
    String target,
    ColorBatchListener listener,
  ) async {
    try {
      for (final line in await tools.exiftool.copyAll(source, target)) {
        listener.message('${p.basename(source)}: $line');
      }
    } on Exception catch (e) {
      listener.message('Warning: Failed to copy metadata: $e');
    }
  }
}
