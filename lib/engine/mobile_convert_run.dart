/// The Convertion page's run on a phone: the desktop's [ConvertRun] steps
/// through the phone's engine, each converted file saved into a new album
/// and its working copy removed.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/engine/share_sizes.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/engine/desktop/convert_run.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/media_library.dart';
import 'package:uwmedia_app/engine/mobile_color_batch.dart';
import 'package:uwmedia_app/engine/mobile_engine.dart';
import 'package:uwmedia_app/engine/mobile_video_run.dart';
import 'package:uwmedia_app/engine/result_folder.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

class MobileConvertRun {
  MobileConvertRun({
    required this.engine,
    required this.library,
    required this.tempDir,
    this.renderer,
    this.painter,
    this.saveTo,
    DateTime Function()? now,
  }) : _now = now ?? naiveNow;

  /// Where the results go instead of a new album of [library] (a folder
  /// of the phone's files).
  final SavePlace? saveTo;

  /// What draws a watermark (spec §10.52); without them none is drawn.
  final HudRenderer? renderer;
  final HudPainter? painter;

  final MobileMediaEngine engine;
  final MediaLibrary library;

  /// Makes a fresh working folder (`appTempDir` in the app).
  final Directory Function(String prefix) tempDir;
  final DateTime Function() _now;

  /// [source] converted to each of [resolutions] (names of
  /// [convertResolutions]) in [outputDir], each then saved into a new
  /// album (or into [saveTo]). As [ConvertRun.convert]: a resolution that fails does not stop
  /// the others; [RunStopped] when [control] was stopped.
  Future<ConvertResult> convert({
    required String source,
    required String outputDir,
    required List<String> resolutions,
    List<ShareCopy> shares = const [],
    List<HudLayerSource> watermarks = const [],
    RunControl? control,
    void Function(ConvertStep step)? onStep,
    void Function(double percent)? onProgress,
  }) async {
    if (!isVideoPath(source)) {
      throw FormatException('Not a video: ${p.basename(source)}');
    }
    Directory(outputDir).createSync(recursive: true);
    final sizes = {
      for (final (name, w, h, bitrate) in convertResolutions)
        name: (w, h, bitrate),
    };
    final wanted = [
      for (final name in resolutions)
        if (sizes.containsKey(name)) name,
    ];
    final unique = UniquePaths(
      (path) =>
          FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound,
    );
    final place = saveTo ?? AlbumPlace(library, runAlbumName(_now()));
    final run = MobileVideoRun(
      engine: engine,
      tempDir: tempDir,
      renderer: renderer,
      painter: painter,
    );
    final marking =
        watermarks.isNotEmpty && renderer != null && painter != null;
    final total = wanted.length + shares.length;
    final failed = <String>[];
    final messages = <String>[];
    onStep?.call((done: 0, total: total, target: null));
    var done = 0;
    // The plain sizes, then the copies for sharing: one encode each.
    final encodes = <(String, String, ShareCopy?)>[
      for (final name in wanted)
        (name, convertOutputFilename(source, name), null),
      for (final copy in shares) (copy.label, copy.filename(source), copy),
    ];
    for (final (name, filename, share) in encodes) {
      if (control?.stopped ?? false) {
        throw const RunStopped();
      }
      final preset = sizes[name];
      final target = unique.unique(p.join(outputDir, filename));
      onStep?.call((done: done, total: total, target: p.basename(target)));
      try {
        // With a watermark: the mark drawn on the picture, then the size.
        final lines = marking
            ? await run.process(
                input: source,
                output: target,
                layers: watermarks,
                size: share == null
                    ? OutputSize.resolution(name, always: true)
                    : OutputSize.share(share),
                onProgress: onProgress,
                onRestart: () => messages.add(restartMessage(name)),
                control: control,
              )
            : await run.convert(
                input: source,
                output: target,
                size: preset == null ? null : (preset.$1, preset.$2),
                bitrate: preset == null ? null : presetBitrate(preset.$3),
                share: share,
                onProgress: onProgress,
                onRestart: () => messages.add(restartMessage(name)),
                control: control,
              );
        for (final line in lines) {
          messages.add('$name: $line');
        }
        await place.save(target);
      } on RunStopped {
        rethrow;
      } on Exception catch (e) {
        failed.add(name);
        messages.add('Error converting to $name: $e');
      } finally {
        // Saved, or not to be: the working copy goes either way.
        try {
          File(target).deleteSync();
        } on FileSystemException {
          // Not there.
        }
      }
      done++;
      onStep?.call((
        done: done,
        total: total,
        target: done < total ? p.basename(target) : null,
      ));
    }
    if (failed.length < total) {
      messages.add(place.savedText);
    }
    return (failed: failed, messages: messages);
  }
}
