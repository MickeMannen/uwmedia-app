/// The Overlay Generator's runs on the desktop (Python `cli_main.py` as the
/// page starts it, once per overlay): `--render-video-log`, the overlay
/// alone for every video and photo of a folder, for the moment each was
/// taken, against a folder of logs; and `--render-log`, the overlay alone
/// for a whole dive of one log file.
///
/// The page starts the runs in the app instead of the CLI (spec §10.38).
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/model/dive_manager.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';
import 'package:uwmedia_app/engine/desktop/color_batch.dart';
import 'package:uwmedia_app/engine/desktop/exiftool.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/desktop/telemetry_run.dart';
import 'package:uwmedia_app/engine/layout_package.dart';
import 'package:uwmedia_app/engine/mobile_engine.dart';
import 'package:uwmedia_app/engine/photo_run.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

/// How an overlay is rendered: the output format ([overlayFormats]), the
/// canvas size ("1080p", "4k") and whether it is the whole frame.
typedef OverlayLook = ({String format, String size, bool fullFrame});

/// What the page asks of one overlay's run over a folder.
class OverlayFolderSettings {
  const OverlayFolderSettings({
    required this.source,
    required this.output,
    this.sourceFiles = const [],
    this.logsDir = '',
    this.keptLogsDir,
    required this.layoutPath,
    required this.look,
    this.filenameFormat = defaultRenderLogFilenameFormat,
    this.noOverwrite = false,
    this.hwAccel = true,
  });

  final String source;
  final String output;

  /// Files picked one by one, run as a folder's are; [source] is not
  /// looked at then (spec §10.65).
  final List<String> sourceFiles;

  /// The dive-logs folder; empty without one.
  final String logsDir;

  /// Where the app keeps the logs imported on the Dive Logs page, read
  /// with the folder's (spec §10.57).
  final String? keptLogsDir;
  final String layoutPath;
  final OverlayLook look;

  /// `{filename}`, `{hud}` and `{datetaken:…}`.
  final String filenameFormat;
  final bool noOverwrite;
  final bool hwAccel;

  NamingArgs get naming => NamingArgs(
    renderVideoLog: true,
    originalLayoutStem: p.basenameWithoutExtension(layoutPath),
    renderLogFilenameFormat: filenameFormat,
    overlayFormat: look.format,
    layout: layoutPath,
    noOverwrite: noOverwrite,
  );
}

class OverlayBatch {
  OverlayBatch({
    required this.tools,
    required this.renderer,
    required this.painter,
    this.tanks,
    this.units = UnitSystem.metric,
    this.native,
    int? workers,
  }) : workers =
           // The engine writes one video at a time.
           native != null
           ? 1
           : workers ?? math.min(4, Platform.numberOfProcessors);

  /// The runner's media engine, when the ProRes and HEVC videos are to
  /// be written by it and not by ffmpeg (a Mac,
  /// `docs/design/macos-remove-ffmpeg.md` step 4).
  final MobileMediaEngine? native;

  final ({FfmpegTools ffmpeg, Exiftool exiftool}) tools;
  final HudRenderer renderer;
  final HudPainter painter;
  final TankConfig? tanks;
  final UnitSystem units;
  final int workers;

  final Set<RunControl> _running = {};
  bool _stopped = false;

  /// Stops the renders going and starts no more.
  Future<void> stop() async {
    _stopped = true;
    await Future.wait([for (final c in _running.toList()) c.stop()]);
  }

  /// The layout of [path] with its skin, read from beside it when its path
  /// is relative; a `.zip` HUD package read from inside it.
  static HudLayerSource layerOf(String path) {
    if (isLayoutPackage(path)) {
      return layerOfPackage(path);
    }
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
    return HudLayerSource(layout, skinBytes: bytes);
  }

  TelemetryRun _telemetry(bool hwAccel) => TelemetryRun(
    tools: tools.ffmpeg,
    renderer: renderer,
    painter: painter,
    units: units,
    hwAccel: hwAccel,
    native: native,
  );

  /// One overlay over every file of a folder (or one file); the result of
  /// every file, in the order they ended.
  Future<List<FileResult>> runFolder(
    OverlayFolderSettings settings,
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
      if (ColorBatch.samePath(source, settings.output)) {
        throw const FormatException(
          'Source and output paths cannot be the same.',
        );
      }
    }
    if (!File(settings.layoutPath).existsSync()) {
      throw FormatException(
        isLayoutPackage(settings.layoutPath)
            ? 'HUD package ${settings.layoutPath} not found.'
            : 'Layout ${settings.layoutPath} not found.',
      );
    }
    final loaded = await loadDiveSources(
      tanks ?? TankConfig(),
      kept: settings.keptLogsDir,
      folder: settings.logsDir,
    );
    loaded.messages.forEach(listener.message);
    final manager = DiveManager()..addDives(loaded.dives);
    final layer = layerOf(settings.layoutPath);

    final files = picked ?? (sourceIsFolder ? batchFiles(source) : [source]);
    // A file name as the output of a single file: its folder (the render's
    // own name is used, as in Python).
    final output = settings.output;
    final outputDir =
        !sourceIsFolder &&
            p.extension(output).isNotEmpty &&
            !FileSystemEntity.isDirectorySync(output)
        ? p.dirname(output)
        : output;
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
        result = await _renderFile(
          file,
          outputDir: outputDir,
          sourceIsFolder: sourceIsFolder,
          settings: settings,
          manager: manager,
          layer: layer,
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

    var next = 0;
    Future<void> worker() async {
      while (!_stopped && next < files.length) {
        await one(files[next++]);
      }
    }

    await Future.wait([
      for (var i = 0; i < math.min(workers, math.max(1, files.length)); i++)
        worker(),
    ]);
    if (_stopped) {
      throw const RunStopped();
    }
    return results;
  }

  Future<FileResult> _renderFile(
    String source, {
    required String outputDir,
    required bool sourceIsFolder,
    required OverlayFolderSettings settings,
    required DiveManager manager,
    required HudLayerSource layer,
    required UniquePaths unique,
    required ColorBatchListener listener,
  }) async {
    final name = p.basename(source);
    final meta = await tools.exiftool.metadata(source);
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
    final target = resolveTargetPath(
      target: p.join(
        outputDir,
        outputFilename(
          source: source,
          outputDir: outputDir,
          sourceIsFolder: sourceIsFolder,
          args: naming,
          creationDate: creationDate,
        ),
      ),
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
    final dive = manager.dives.isEmpty
        ? null
        : manager.findDiveForTimestamp(creationDate);
    if (manager.dives.isNotEmpty && dive == null) {
      listener.message('Warning: No matching dive log found for $name.');
    }
    final look = settings.look;
    final control = RunControl();
    _running.add(control);
    // A Stop while the file was looked at: no render.
    if (_stopped) {
      _running.remove(control);
      throw const RunStopped();
    }
    try {
      if (isVideoPath(source)) {
        final fps = await tools.ffmpeg.fps(source);
        final frames = await tools.ffmpeg.frameCount(source);
        if (_stopped) {
          throw const RunStopped();
        }
        await _telemetry(settings.hwAccel).render(
          source: layer,
          dive: dive,
          start: creationDate,
          fps: fps,
          totalFrames: frames,
          format: look.format,
          target: targetPath,
          size: look.size,
          fullFrame: look.fullFrame,
          onProgress: (percent) => listener.progress(name, percent),
          control: control,
        );
      } else {
        final alpha = look.format != overlayFormatHevc;
        final format = alpha ? PhotoFormat.png : photoFormatOf(targetPath);
        if (format == null) {
          return (
            file: name,
            status: FileStatus.error,
            error:
                'Photos are saved as JPEG or PNG, not ${p.extension(targetPath)}',
          );
        }
        final bytes =
            await PhotoRun(
              renderer: renderer,
              painter: painter,
              units: units,
            ).telemetryPhoto(
              layer,
              overlayFormat: look.format,
              format: format,
              matchDate: creationDate,
              dive: dive,
              sourceBytes: File(source).readAsBytesSync(),
              size: look.size,
              fullFrame: look.fullFrame,
            );
        File(targetPath).writeAsBytesSync(bytes, flush: true);
        if (alpha) {
          // A transparent picture gets no metadata, as in Python.
          return (file: name, status: FileStatus.done, error: null);
        }
      }
    } finally {
      _running.remove(control);
    }
    if (control.stopped) {
      throw const RunStopped();
    }
    // A PNG sequence is a folder: nothing to tag.
    if (!FileSystemEntity.isDirectorySync(targetPath)) {
      try {
        for (final line in await tools.exiftool.copyAll(source, targetPath)) {
          listener.message('$name: $line');
        }
      } on Exception catch (e) {
        listener.message('Warning: Failed to copy metadata: $e');
      }
    }
    return (file: name, status: FileStatus.done, error: null);
  }

  /// One overlay for the whole first dive of the log file [logPath], into
  /// [output] (a folder, or a file name): `<log>_<layout>` in the format's
  /// shape, never over an existing file. Gives the path written. Throws a
  /// [FormatException] for a log that cannot be used.
  Future<String> runLog({
    required String logPath,
    required String output,
    required String layoutPath,
    required OverlayLook look,
    bool hwAccel = true,
    void Function(double percent)? onProgress,
    void Function(String line)? onMessage,
  }) async {
    _stopped = false;
    final dives = parseLogFile(
      logPath,
      File(logPath).readAsBytesSync(),
      tanks: tanks,
    );
    if (dives == null) {
      throw FormatException(
        'Unsupported log format ${p.extension(logPath).toLowerCase()}',
      );
    }
    if (dives.isEmpty) {
      throw FormatException('No dives found in ${p.basename(logPath)}');
    }
    final dive = dives.first;
    if (dive.duration <= 0) {
      throw const FormatException('Dive duration is zero.');
    }
    final layoutName = p.basenameWithoutExtension(layoutPath);
    final String target;
    if (p.extension(output).isNotEmpty) {
      target = outputPathFor(look.format, output);
    } else {
      Directory(output).createSync(recursive: true);
      target =
          UniquePaths(
            (path) =>
                FileSystemEntity.typeSync(path) !=
                FileSystemEntityType.notFound,
          ).unique(
            outputPathFor(
              look.format,
              p.join(
                output,
                '${p.basenameWithoutExtension(logPath)}_$layoutName.mp4',
              ),
            ),
          );
    }
    final control = RunControl();
    _running.add(control);
    try {
      await _telemetry(hwAccel).render(
        source: layerOf(layoutPath),
        dive: dive,
        start: dive.startTime,
        fps: logRenderFps,
        totalFrames: TelemetryRun.logFrames(dive),
        format: look.format,
        target: target,
        size: look.size,
        fullFrame: look.fullFrame,
        onProgress: onProgress,
        control: control,
      );
    } finally {
      _running.remove(control);
    }
    if (control.stopped || _stopped) {
      throw const RunStopped();
    }
    if (!FileSystemEntity.isDirectorySync(target)) {
      // The dive's own time, in UTC as the log has no zone here (Python's
      // --tz-adjust, which the page never sends, is 0).
      final local = pyStrftime(dive.startTime, '%Y:%m:%d %H:%M:%S');
      try {
        await tools.exiftool.setTags(target, {
          'QuickTime:CreateDate': local,
          'QuickTime:CreationDate': '$local+00:00',
          'QuickTime:TrackCreateDate': local,
          'QuickTime:MediaCreateDate': local,
          'QuickTime:Timezone': '+00:00',
          'QuickTime:TimeZone': '+00:00',
          'EXIF:DateTimeOriginal': local,
          'EXIF:CreateDate': local,
        });
      } on Exception catch (e) {
        onMessage?.call('Warning: Failed to write creation date metadata: $e');
      }
    }
    return target;
  }
}
