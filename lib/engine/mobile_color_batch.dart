/// The Color page's batch on a phone: the desktop's [ColorBatch] steps for
/// the photos and videos picked from the library, one file at a time in
/// the foreground (spec §9), each result saved into a new album and its
/// working copy removed. The dives come from the logs kept in the app.
///
/// Videos go through the phone's engine ([MobileVideoRun]); photos through
/// the app's own [PhotoRun] as on the desktop, an HEIC photo written as a
/// JPEG. Without exiftool the metadata carried over is the dates (and for
/// a video make, model and software), by the app's own writers.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/metadata/jpeg_exif.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/model/dive_manager.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';
import 'package:uwmedia_app/engine/desktop/color_batch.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/file_times.dart';
import 'package:uwmedia_app/engine/media_file_dates.dart';
import 'package:uwmedia_app/engine/media_library.dart';
import 'package:uwmedia_app/engine/mobile_engine.dart';
import 'package:uwmedia_app/engine/mobile_video_run.dart';
import 'package:uwmedia_app/engine/photo_run.dart';
import 'package:uwmedia_app/engine/result_folder.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

/// The album a phone run saves into, named for when it started.
String runAlbumName(DateTime now) => testAlbum.isNotEmpty
    ? testAlbum
    : 'UWMedia ${pyStrftime(now, '%Y-%m-%d %H.%M')}';

/// One album for every run of a test build
/// (`--dart-define=TEST_ALBUM=test_data_results`), so that test results
/// sit together and can be cleared at once; empty in a normal build.
const testAlbum = String.fromEnvironment('TEST_ALBUM');

/// A file's date tags as the app's own readers give them; `null` when the
/// file cannot be read.
MediaTags? readDatesOrNull(String path) {
  try {
    return readFileDates(path);
  } on Object {
    return null;
  }
}

class MobileColorBatch {
  MobileColorBatch({
    required this.engine,
    required this.library,
    required this.renderer,
    required this.painter,
    required this.tempDir,
    this.tanks,
    this.units = UnitSystem.metric,
    this.saveTo,
    DateTime Function()? now,
  }) : _now = now ?? naiveNow;

  final MobileMediaEngine engine;
  final MediaLibrary library;

  /// Where the results go instead of a new album of [library] (a folder
  /// of the phone's files).
  final SavePlace? saveTo;
  final HudRenderer renderer;
  final HudPainter painter;

  /// Makes a fresh working folder (`appTempDir` in the app).
  final Directory Function(String prefix) tempDir;
  final TankConfig? tanks;
  final UnitSystem units;
  final DateTime Function() _now;

  RunControl? _control;
  bool _stopped = false;

  /// Stops the file going and starts no more.
  Future<void> stop() async {
    _stopped = true;
    await _control?.stop();
  }

  /// Runs [settings] over the files of its source folder, the outputs
  /// written in its output folder first and then saved into a new album
  /// (or into [saveTo]).
  Future<List<FileResult>> run(
    ColorBatchSettings settings,
    ColorBatchListener listener,
  ) async {
    _stopped = false;
    final source = settings.source;
    if (!FileSystemEntity.isDirectorySync(source)) {
      throw const FormatException('Pick photos or videos first.');
    }
    final manager = DiveManager();
    final logs = settings.logsDir;
    if (logs != null && FileSystemEntity.isDirectorySync(logs)) {
      final tankConfig = tanks ?? TankConfig();
      final loaded = await loadDiveLogsOffThread(logs, tankConfig);
      loaded.messages.forEach(listener.message);
      manager.addDives(loaded.dives);
    }
    final layers = [
      for (final overlay in settings.overlays) overlayLayerSource(overlay),
      ...settings.watermarks,
    ];
    final outputDir = settings.output;
    Directory(outputDir).createSync(recursive: true);
    final files = batchFiles(source);
    final place = saveTo ?? AlbumPlace(library, runAlbumName(_now()));
    final unique = UniquePaths(
      (path) =>
          FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound,
    );
    final results = <FileResult>[];
    listener.started(files.length);
    for (final file in files) {
      if (_stopped) {
        break;
      }
      final name = p.basename(file);
      listener.active(name);
      FileResult result;
      try {
        final target = await _processFile(
          file,
          outputDir: outputDir,
          settings: settings,
          manager: manager,
          layers: layers,
          unique: unique,
          listener: listener,
        );
        try {
          await place.save(target);
        } finally {
          // Saved, or not to be: the working copy goes either way.
          _remove(target);
        }
        result = (file: name, status: FileStatus.done, error: null);
      } on RunStopped {
        break;
      } on Object catch (e) {
        result = (file: name, status: FileStatus.error, error: '$e');
      }
      results.add(result);
      listener.finished(results.length, files.length, result);
    }
    if (_stopped) {
      throw const RunStopped();
    }
    if (results.any((r) => r.status == FileStatus.done)) {
      listener.message(place.savedText);
    }
    return results;
  }

  // The output of [source] in [outputDir]; its path.
  Future<String> _processFile(
    String source, {
    required String outputDir,
    required ColorBatchSettings settings,
    required DiveManager manager,
    required List<HudLayerSource> layers,
    required UniquePaths unique,
    required ColorBatchListener listener,
  }) async {
    final name = p.basename(source);
    final meta = readDatesOrNull(source);
    final DateTime creationDate;
    try {
      creationDate = localCreationDate(
        meta,
        fileModified: fileModified(source),
      );
    } on FormatException catch (e) {
      throw FormatException('Error extracting metadata: ${e.message}');
    }
    var filename = outputFilename(
      source: source,
      outputDir: outputDir,
      sourceIsFolder: true,
      args: settings.naming,
      creationDate: creationDate,
    );
    final video = isVideoPath(source);
    var size = video ? settings.outputSize : null;
    // A photo keeps its size and takes only the window (spec §10.77).
    final cutOfRun = settings.outputSize?.pictureCut;
    final photoCut = !video && cutOfRun != null && cutOfRun.cuts
        ? cutOfRun
        : null;
    if (size != null) {
      // A size that leaves this video as it is (a resolution it does not
      // reach) is no size: the file takes the run's usual way.
      try {
        final clip = await engine.probe(source);
        if (size.frameFor(clip.width, clip.height) == null) {
          size = null;
        }
      } on EngineException {
        // The run itself says what is wrong with the file.
      }
    }
    if (size != null && size.h264) {
      // A copy for sharing is an MP4 whatever the source is.
      filename = p.setExtension(filename, '.mp4');
    }
    if (!video && photoFormatOf(filename) == null) {
      // An HEIC photo (the iPhone's) comes out as a JPEG.
      filename = '${p.withoutExtension(filename)}.jpg';
    }
    final target = unique.unique(p.join(outputDir, filename));

    final matchDate = creationDate.add(
      Duration(microseconds: (settings.mediaShiftSeconds * 1e6).round()),
    );
    final dive = manager.dives.isEmpty
        ? null
        : manager.findDiveForTimestamp(matchDate);
    if (manager.dives.isNotEmpty && dive == null) {
      listener.message('Warning: No matching dive log found for $name.');
    }
    final profile = settings.colorProfile;
    final color = profile == null ? null : ColorEngine(profile);
    final control = _control = RunControl();
    final drawn = layersToDraw(layers, matched: dive != null);
    try {
      void progress(double percent) => listener.progress(name, percent);
      if (video) {
        if (color == null &&
            drawn.isEmpty &&
            size == null &&
            partOf(settings, source) == null) {
          // Nothing to change: the file as it is.
          File(source).copySync(target);
        } else {
          final lines =
              await MobileVideoRun(
                engine: engine,
                tempDir: tempDir,
                renderer: renderer,
                painter: painter,
                units: units,
              ).process(
                input: source,
                output: target,
                color: color,
                layers: drawn,
                dive: dive,
                matchDate: matchDate,
                size: size,
                part: partOf(settings, source),
                onProgress: progress,
                onRestart: () => listener.message(restartMessage(name)),
                control: control,
              );
          for (final line in lines) {
            listener.message('$name: $line');
          }
        }
      } else if (color != null || drawn.isNotEmpty || photoCut != null) {
        final format = photoFormatOf(target)!;
        var bytes =
            await PhotoRun(
              renderer: renderer,
              painter: painter,
              engine: color,
              units: units,
            ).process(
              File(source).readAsBytesSync(),
              format: format,
              colorCorrect: color != null,
              layers: drawn,
              dive: dive,
              matchDate: matchDate,
              cut: photoCut,
            );
        if (format == PhotoFormat.jpeg) {
          bytes = _withDates(bytes, meta, name, listener);
        }
        File(target).writeAsBytesSync(bytes, flush: true);
        progress(100);
      } else {
        File(source).copySync(target);
      }
    } on Object {
      _remove(target);
      rethrow;
    } finally {
      _control = null;
    }
    if (control.stopped) {
      _remove(target);
      throw const RunStopped();
    }
    return target;
  }

  // [jpeg] with the source's EXIF dates and offsets ([meta]).
  static Uint8List _withDates(
    Uint8List jpeg,
    MediaTags? meta,
    String name,
    ColorBatchListener listener,
  ) {
    final tags = {
      for (final MapEntry(:key, :value) in (meta ?? const {}).entries)
        if (jpegDateTags.containsKey(key) && value != null) key: '$value',
    };
    if (tags.isEmpty) {
      return jpeg;
    }
    try {
      return writeJpegDates(jpeg, tags);
    } on Object catch (e) {
      listener.message('$name: Warning: the dates could not be written ($e)');
      return jpeg;
    }
  }

  static void _remove(String path) {
    try {
      File(path).deleteSync();
    } on FileSystemException {
      // Not there.
    }
  }
}
