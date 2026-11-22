/// A photo's wipe video (spec §10.94): the original stands still, an
/// edge with a white line moves across it and uncovers the colour
/// corrected picture, which then stands still. The frames are mixed here
/// from the two pictures ([compareMix]) and handed to the encoder as the
/// Overlay Generator's drawn frames are: ffmpeg's input, or the runner's
/// media engine when the videos are its.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/engine/compare.dart';
import 'package:uwmedia_app/core/engine/ffmpeg_commands.dart';
import 'package:uwmedia_app/core/engine/progress.dart';
import 'package:uwmedia_app/core/hud/image_resize.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/mobile_engine.dart';

class WipeRun {
  WipeRun({required this.tools, this.native, this.hwAccel = true});

  final FfmpegTools tools;

  /// The runner's media engine, when the videos are written by it and
  /// not by ffmpeg (a Mac).
  final MobileMediaEngine? native;
  final bool hwAccel;

  /// Writes the wipe from [before] to [after] (RGBA pictures [width] by
  /// [height]) along [kind] into [output] as HEVC, the frame the
  /// picture's shape inside [box] ([wipeFrameSize]). [onProgress] gets
  /// the percentage; [control] stops it. Gives the frame's size. Throws
  /// an [EngineException] when the encoder fails and [RunStopped] when
  /// stopped; what was written is removed then.
  Future<(int, int)> write({
    required Uint8List before,
    required Uint8List after,
    required int width,
    required int height,
    required CompareKind kind,
    required String output,
    (int, int)? box,
    void Function(double percent)? onProgress,
    RunControl? control,
  }) async {
    final (w, h) = wipeFrameSize(width, height, box: box);
    final from = areaResize(before, width, height, w, h);
    final to = areaResize(after, width, height, w, h);
    final steps = wipeSteps();
    final total = steps.fold(0, (sum, step) => sum + step.$2);
    final progress = FileProgress(p.basename(output));
    var written = 0;
    void report(int frames) {
      written += frames;
      final step = progress.report(written / total * 100);
      if (step != null) {
        onProgress?.call(step);
      }
    }

    void checkStopped() {
      if (control?.stopped ?? false) {
        throw const RunStopped();
      }
    }

    // The frame of a step: the corrected picture up to the edge, the
    // original beyond it.
    final frame = Uint8List(w * h * 4);
    Uint8List mixed(double share) => share <= 0
        ? from
        : share >= 1
        ? to
        : compareMix(
            to,
            from,
            CompareEdge.wipe(kind, w, h, share),
            into: frame,
          );

    final engine = native;
    try {
      if (engine != null) {
        await engine.framesOpen(
          output: output,
          width: w,
          height: h,
          fps: wipeFps,
          prores: false,
        );
        try {
          control?.runningWith(engine.framesCancel);
          for (final (share, frames) in steps) {
            checkStopped();
            await engine.framesAdd(mixed(share), frames);
            report(frames);
          }
          checkStopped();
          await engine.framesClose();
        } on Object {
          await engine.framesCancel();
          checkStopped();
          rethrow;
        }
      } else {
        await _throughFfmpeg(steps, mixed, w, h, output, control, report);
      }
    } on Object {
      try {
        File(output).deleteSync();
      } on FileSystemException {
        // Nothing was written.
      }
      rethrow;
    }
    onProgress?.call(100);
    return (w, h);
  }

  Future<void> _throughFfmpeg(
    List<(double, int)> steps,
    Uint8List Function(double share) mixed,
    int width,
    int height,
    String output,
    RunControl? control,
    void Function(int frames) report,
  ) async {
    final Process process;
    try {
      process = await Process.start(
        tools.ffmpeg,
        frameSinkArgs(
          format: overlayFormatHevc,
          width: width,
          height: height,
          fps: wipeFps,
          target: output,
          encoder: await tools.encoder(hwAccel: hwAccel),
        ),
      );
    } on ProcessException catch (e) {
      throw EngineException('FFmpeg could not be started', output: '$e');
    }
    unawaited(process.stdout.drain<void>().catchError((Object _) {}));
    final errors = process.stderr.transform(systemEncoding.decoder).join();
    control?.runningWith(() => killTree(process));
    var failed = false;
    var finished = false;
    try {
      final raw = Uint8List(width * height * 3);
      for (final (share, frames) in steps) {
        // ffmpeg is told the frames are BGR.
        final rgba = mixed(share);
        var o = 0;
        for (var i = 0; i < rgba.length; i += 4) {
          raw[o++] = rgba[i + 2];
          raw[o++] = rgba[i + 1];
          raw[o++] = rgba[i];
        }
        for (var n = 0; n < frames; n++) {
          if (control?.stopped ?? false) {
            throw const RunStopped();
          }
          process.stdin.add(raw);
          // One frame at a time: ffmpeg sets the pace.
          await process.stdin.flush();
        }
        report(frames);
      }
      finished = true;
    } on IOException {
      // ffmpeg went away while frames were written: its exit says why.
      failed = true;
      finished = true;
    } finally {
      // Stopped, or the frames could not be made: ffmpeg is ended and
      // waited for, so that it has let go of the file it was writing.
      final ended = (control?.stopped ?? false) || !finished;
      if (ended) {
        await killTree(process);
      }
      try {
        await process.stdin.close();
      } on IOException {
        // Already gone.
      }
      if (ended) {
        await process.exitCode;
      }
    }
    final exit = await process.exitCode;
    if (control?.stopped ?? false) {
      throw const RunStopped();
    }
    if (exit != 0 || failed) {
      throw EngineException(
        'FFmpeg Error (Exit $exit)',
        exitCode: exit,
        output: (await errors).trim(),
      );
    }
  }
}
