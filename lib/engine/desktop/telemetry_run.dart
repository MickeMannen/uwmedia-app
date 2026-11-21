/// A telemetry-only render on the desktop (Python `cli_main.py`'s two
/// render loops on `ffmpeg/overlay_output.py`'s `FrameSink`): the overlay
/// alone, for a whole dive log or for the time of a clip, as a transparent
/// ProRes 4444 movie, a PNG sequence with alpha, or an HEVC video on
/// black. The Overlay Generator's output.
///
/// The overlay changes only when the dive sample does: it is drawn once
/// per sample, and the same picture is handed on for the frames between.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/engine/ffmpeg_commands.dart';
import 'package:uwmedia_app/core/engine/hud_layers.dart';
import 'package:uwmedia_app/core/engine/overlay_canvas.dart';
import 'package:uwmedia_app/core/engine/progress.dart';
import 'package:uwmedia_app/core/hud/hud_ops.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/image_resize.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/mobile_engine.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

/// The frame rate of a render from a log alone (spec §10.3).
const logRenderFps = 30.0;

/// What a telemetry-only render did.
typedef TelemetryStats = ({
  int frames,
  int pictures,
  int width,
  int height,
  Duration renderTime,
});

class TelemetryRun {
  TelemetryRun({
    required this.tools,
    required this.renderer,
    required this.painter,
    this.units = UnitSystem.metric,
    this.hwAccel = true,
    this.debug = false,
    this.native,
  });

  /// The runner's media engine, when the videos are to be written by it
  /// and not by ffmpeg (a Mac, `docs/design/macos-remove-ffmpeg.md` step 4): the
  /// drawn pictures go to its frame writer. A PNG sequence needs neither.
  final MobileMediaEngine? native;

  final FfmpegTools tools;
  final HudRenderer renderer;
  final HudPainter painter;
  final UnitSystem units;
  final bool hwAccel;
  final bool debug;

  /// The number of frames of a render of the whole [dive].
  static int logFrames(Dive dive) => (dive.duration * logRenderFps).truncate();

  /// Renders [source] (its placement is not used) for [totalFrames]
  /// frames at [fps], the first at [start] on the dive computer's clock,
  /// into [target] as [format]: a `.mov` for ProRes, a folder for a PNG
  /// sequence, the video on black for HEVC (`outputPathFor` names it).
  /// [size] ("1080p", "4k") and [fullFrame] decide the canvas
  /// ([overlayCanvas]). A frame with no dive sample shows a sample of
  /// zeros. [onProgress] gets the percentage, held back to one a percent;
  /// [control] stops the render. Throws an [EngineException] when ffmpeg
  /// fails and [RunStopped] when stopped.
  Future<TelemetryStats> render({
    required HudLayerSource source,
    required Dive? dive,
    required DateTime start,
    required double fps,
    required int totalFrames,
    required String format,
    required String target,
    String? size,
    bool fullFrame = false,
    void Function(double percent)? onProgress,
    RunControl? control,
  }) async {
    if (!overlayFormats.contains(format)) {
      throw ArgumentError.value(format, 'format', 'unknown overlay format');
    }
    final watch = Stopwatch()..start();
    final alpha = overlayHasAlpha(format);

    // The skin as the file has it.
    Uint8List? nativeRgba;
    (int, int)? nativeSize;
    final skinBytes = source.skinBytes;
    final sourceSkin = source.layout['hud_skin'];
    if (skinBytes != null &&
        !(sourceSkin is Map && sourceSkin['type'] == 'shape')) {
      try {
        final codec = await ui.instantiateImageCodec(skinBytes);
        final native = (await codec.getNextFrame()).image;
        codec.dispose();
        nativeRgba = (await native.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        ))!.buffer.asUint8List();
        nativeSize = (native.width, native.height);
        native.dispose();
      } on Exception {
        nativeRgba = null;
        nativeSize = null;
      }
    }
    final canvas = overlayCanvas(
      source.layout,
      size: size,
      fullFrame: fullFrame,
      skinSize: nativeSize,
    );
    final (width, height) = (canvas.width, canvas.height);
    final hudSkin = canvas.layout['hud_skin'] as Map<String, dynamic>;
    final rawOpacity = hudSkin['opacity'];
    final opacity = rawOpacity is num ? rawOpacity.toDouble() : 1.0;

    ui.Image? skin;
    List<HudOp> opsAt(Waypoint waypoint, double? flashAt) => renderer.drawHud(
      frameWidth: width,
      frameHeight: height,
      layout: canvas.layout,
      waypoint: waypoint,
      waypoints: dive?.waypoints,
      skinSize: nativeSize,
      renderLog: canvas.renderLog,
      units: units,
      flashAt: flashAt,
    );

    Future<ui.Image> draw(Waypoint waypoint, double? flashAt) async {
      final ops = opsAt(waypoint, flashAt);
      // The skin, once, at the size the renderer draws it at.
      final skinOp = ops.whereType<SkinOp>().firstOrNull;
      if (skin == null && nativeRgba != null && skinOp != null) {
        skin = await hudSkinImage(
          areaResize(
            nativeRgba,
            nativeSize!.$1,
            nativeSize.$2,
            skinOp.width,
            skinOp.height,
          ),
          skinOp.width,
          skinOp.height,
        );
      }
      final recorder = ui.PictureRecorder();
      final target = ui.Canvas(recorder);
      if (!alpha) {
        target.drawRect(
          ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
          ui.Paint()..color = const ui.Color(0xFF000000),
        );
      }
      painter.paint(target, ops, skin: skin, skinOpacity: opacity);
      final picture = recorder.endRecording();
      final image = await picture.toImage(width, height);
      picture.dispose();
      return image;
    }

    // The runs of frames that show the same sample, a sample whose values
    // flash cut at the clip's half seconds (spec §10 issue 9).
    final segments = flashSegments(
      dive == null || dive.waypoints.isEmpty
          ? <HudSegment>[(null, 0, totalFrames)]
          : hudSegments(dive, start, fps, totalFrames),
      fps,
      (waypoint) =>
          waypoint != null && drawingFlashes((at) => opsAt(waypoint, at)),
    );

    // Where the frames go.
    Process? process;
    Future<String>? errors;
    final engine = format == overlayFormatPng ? null : native;
    if (format == overlayFormatPng) {
      Directory(target).createSync(recursive: true);
    } else if (engine != null) {
      await engine.framesOpen(
        output: target,
        width: width,
        height: height,
        fps: fps,
        prores: format == overlayFormatProres,
      );
      control?.runningWith(engine.framesCancel);
    } else {
      try {
        process = await Process.start(
          tools.ffmpeg,
          frameSinkArgs(
            format: format,
            width: width,
            height: height,
            fps: fps,
            target: target,
            encoder: await tools.encoder(hwAccel: hwAccel),
            debug: debug,
          ),
        );
      } on ProcessException catch (e) {
        throw EngineException('FFmpeg could not be started', output: '$e');
      }
      unawaited(process.stdout.drain<void>().catchError((Object _) {}));
      errors = process.stderr.transform(systemEncoding.decoder).join();
      final running = process;
      control?.runningWith(() => killTree(running));
    }

    final progress = FileProgress(p.basename(target));
    var frames = 0;
    var pictures = 0;
    var failed = false;
    try {
      String? lastPng;
      for (final (waypoint, first, count, flashAt) in segments) {
        if (control?.stopped ?? false) {
          throw const RunStopped();
        }
        final at = start.add(
          Duration(microseconds: (first / fps * 1e6).round()),
        );
        final image = await draw(
          waypoint ??
              Waypoint(timestamp: at, timeSinceStart: 0, depth: 0, temp: 0),
          flashAt,
        );
        pictures++;
        try {
          if (engine != null) {
            final rgba = (await image.toByteData(
              format: ui.ImageByteFormat.rawStraightRgba,
            ))!.buffer.asUint8List();
            await engine.framesAdd(rgba, count);
            frames += count;
            _report(progress, frames, totalFrames, onProgress);
          } else if (process == null) {
            final png = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!.buffer.asUint8List();
            for (var n = 0; n < count; n++) {
              frames++;
              final path = p.join(target, frameFileName(frames));
              if (n == 0) {
                File(path).writeAsBytesSync(png);
              } else {
                // The same picture again: a copy, not another encode.
                File(lastPng!).copySync(path);
              }
              lastPng = path;
            }
          } else {
            final rgba = (await image.toByteData(
              format: ui.ImageByteFormat.rawStraightRgba,
            ))!.buffer.asUint8List();
            final raw = _forFfmpeg(rgba, alpha: alpha);
            for (var n = 0; n < count; n++) {
              if (control?.stopped ?? false) {
                throw const RunStopped();
              }
              process.stdin.add(raw);
              // One frame at a time: ffmpeg sets the pace.
              await process.stdin.flush();
              frames++;
              _report(progress, frames, totalFrames, onProgress);
            }
          }
        } finally {
          image.dispose();
        }
        if (process == null && engine == null) {
          _report(progress, frames, totalFrames, onProgress);
        }
      }
      if (engine != null) {
        if (control?.stopped ?? false) {
          throw const RunStopped();
        }
        await engine.framesClose();
      }
    } on RunStopped {
      failed = true;
      await engine?.framesCancel();
      rethrow;
    } on EngineException {
      if (engine == null) {
        rethrow;
      }
      // The engine's writer: given up, and a Stop is why when one came.
      await engine.framesCancel();
      if (control?.stopped ?? false) {
        throw const RunStopped();
      }
      rethrow;
    } on IOException {
      // ffmpeg went away while frames were written: its exit says why.
      failed = true;
    } finally {
      skin?.dispose();
      if (process != null) {
        if (control?.stopped ?? false) {
          await killTree(process);
        }
        try {
          await process.stdin.close();
        } on IOException {
          // Already gone.
        }
      }
    }
    if (process != null) {
      final exit = await process.exitCode;
      if (control?.stopped ?? false) {
        throw const RunStopped();
      }
      if (exit != 0 || failed) {
        throw EngineException(
          'FFmpeg Error (Exit $exit)',
          exitCode: exit,
          output: (await errors!).trim(),
        );
      }
    }
    return (
      frames: frames,
      pictures: pictures,
      width: width,
      height: height,
      renderTime: watch.elapsed,
    );
  }

  static void _report(
    FileProgress progress,
    int frames,
    int total,
    void Function(double)? onProgress,
  ) {
    final percent = total > 0 ? frames / total * 100 : 100.0;
    final step = progress.report(percent);
    if (step != null) {
      onProgress?.call(step);
    } else if (frames == total) {
      onProgress?.call(100.0);
    }
  }

  // Flutter's RGBA as ffmpeg is told the frames are: BGRA with the alpha,
  // BGR without.
  static Uint8List _forFfmpeg(Uint8List rgba, {required bool alpha}) {
    final pixels = rgba.length ~/ 4;
    final out = Uint8List(pixels * (alpha ? 4 : 3));
    var o = 0;
    for (var i = 0; i < rgba.length; i += 4) {
      out[o++] = rgba[i + 2];
      out[o++] = rgba[i + 1];
      out[o++] = rgba[i];
      if (alpha) {
        out[o++] = rgba[i + 3];
      }
    }
    return out;
  }
}
