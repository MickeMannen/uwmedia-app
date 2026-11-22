/// Colour correction and overlays on one video, all composed by ffmpeg
/// (Python `ColorCorrectionEngine.process_video`): the layers are drawn
/// once per dive sample as transparent pictures, and ffmpeg decodes the
/// source, applies the colour LUTs and lays the layers over the result in
/// one pass. The overlays go on after the correction, so they keep their
/// own colours.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/engine/compare.dart';
import 'package:uwmedia_app/core/engine/ffmpeg_commands.dart';
import 'package:uwmedia_app/core/engine/hud_layers.dart';
import 'package:uwmedia_app/core/engine/progress.dart';
import 'package:uwmedia_app/core/engine/share_sizes.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/engine/compare_pictures.dart';
import 'package:uwmedia_app/engine/desktop/color_run.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

/// What an overlay run did, for the page's summary line.
typedef OverlayRunStats = ({
  int totalFrames,
  int samples,
  int layers,
  Duration analysisTime,
  Duration hudTime,
  Duration renderTime,
});

/// The overlay runs on top of a [ColorRun]'s tools and colour profile.
class OverlayRun {
  OverlayRun({
    required this.color,
    required this.renderer,
    required this.painter,
    this.units = UnitSystem.metric,
  });

  final ColorRun color;
  final HudRenderer renderer;
  final HudPainter painter;
  final UnitSystem units;

  /// Writes [input] to [output] with [layers] laid over it in order (the
  /// last on top), colour-corrected first when [colorCorrect].
  ///
  /// [matchDate] is the time the footage starts on the dive computer's
  /// clock (the file's creation date plus the camera's clock offset); it
  /// decides which sample each frame shows. [creationDate] stays the
  /// file's own time, written to the output. Without a [dive] with
  /// samples nothing is drawn. [onProgress] gets the percentage of the
  /// whole run; [control] stops it. Throws an [EngineException] when
  /// ffmpeg fails and [RunStopped] when stopped.
  ///
  /// With [compare] (and the colour correction) the video shows the
  /// original on one side of an edge and the corrected picture on the
  /// other, the layers over both (spec §10.94).
  Future<OverlayRunStats> processVideo({
    required String input,
    required String output,
    required DateTime creationDate,
    required List<HudLayerSource> layers,
    Dive? dive,
    DateTime? matchDate,
    int? tzOffsetMins,
    bool colorCorrect = true,
    OutputSize? size,
    Compare? compare,
    void Function(double percent)? onProgress,
    RunControl? control,
  }) async {
    final progress = FileProgress(p.basename(input));
    void report(double percent) {
      final step = progress.report(percent);
      if (step != null) {
        onProgress?.call(step);
      }
    }

    void checkStopped() {
      if (control?.stopped ?? false) {
        throw const RunStopped();
      }
    }

    final tools = color.tools;
    final clip = await color.probe(input);
    final duration = clip.fps > 0 ? clip.totalFrames / clip.fps : 0.0;
    // An output size (spec §10.51): the layers lie on what its crop
    // leaves of the picture, and the scale comes after them.
    // The picture as it is shown: ffmpeg turns a phone's upright video
    // before its filters, so that is the shape they get.
    final (shownW, shownH) = size == null
        ? (clip.width, clip.height)
        : await tools.displayDimensions(input);
    int? ownRate;
    if (size != null && size.resolution == null && size.share == null) {
      // A part of the picture at the video's own size: its share of the
      // video's own bit rate.
      try {
        ownRate = await tools.bitrate(input);
      } on EngineException {
        ownRate = null;
      }
    }
    final frame = size?.frameFor(shownW, shownH, sourceBitrate: ownRate);
    final frameW = frame?.crop?.width ?? shownW;
    final frameH = frame?.crop?.height ?? shownH;

    final watch = Stopwatch()..start();
    var frames = <int>[];
    var filters = <Float32List>[];
    var samples = 0;
    if (colorCorrect) {
      final analysis = await color.analyze(
        input,
        clip,
        onProgress: report,
        control: control,
      );
      (frames, filters, samples) = (
        analysis.frames,
        analysis.filters,
        analysis.samples,
      );
    }
    final analysisTime = watch.elapsed;

    final workDir = color.tempDir('uwmedia_overlay_');
    try {
      String? colorVf;
      if (filters.isNotEmpty) {
        colorVf = (await color.writeLuts(
          frames,
          filters,
          clip.fps,
          workDir,
          control: control,
        )).$1;
      }
      checkStopped();
      // A comparison: the mask and the line as pictures of the frame the
      // layers lie on.
      List<String> pictures = const [];
      if (compare != null && colorVf != null) {
        pictures = await writeComparePictures(
          CompareEdge.split(compare.kind, frameW, frameH),
          workDir,
        );
      }

      // The layers: without a matched dive only those that need none (a
      // watermark), each one picture for the whole clip.
      watch.reset();
      final streams = <HudLayerStream>[];
      final matched = dive != null && dive.waypoints.isNotEmpty;
      final wanted = layersToDraw(layers, matched: matched);
      if (wanted.isNotEmpty) {
        final List<HudSegment> whole = [(null, 0, clip.totalFrames)];
        final segments = matched
            ? hudSegments(
                dive,
                matchDate ?? creationDate,
                clip.fps,
                clip.totalFrames,
              )
            : whole;
        final writer = HudLayerWriter(
          renderer,
          painter,
          frameW: frameW,
          frameH: frameH,
          units: units,
        );
        // A layer that needs no dive is one picture, one step.
        final before = <int>[];
        var steps = 0;
        for (final layer in wanted) {
          before.add(steps);
          steps += layer.always ? 1 : segments.length;
        }
        for (final (li, layer) in wanted.indexed) {
          try {
            final stream = await writer.write(
              layer,
              layer.always ? whole : segments,
              dive?.waypoints ?? const [],
              clip.fps,
              workDir,
              li,
              stopped: () => control?.stopped ?? false,
              onSegment: (i) => report(
                analysisProgressEnd +
                    (hudProgressEnd - analysisProgressEnd) *
                        (before[li] + i + 1) /
                        (steps < 1 ? 1 : steps),
              ),
            );
            if (stream != null) {
              streams.add(stream);
            }
          } on HudLayerStopped {
            throw const RunStopped();
          }
        }
      }
      final hudTime = watch.elapsed;

      final shared = await color.sharedArgs(
        input: input,
        output: output,
        creationDate: creationDate,
        tzOffsetMins: tzOffsetMins,
        tenBit: clip.tenBit,
        bitrate: frame?.bitrate,
        h264: frame != null && size!.h264,
      );
      checkStopped();
      watch.reset();
      await tools.run(
        overlayCommandArgs(
          input: input,
          layers: streams,
          colorVf: pictures.isEmpty
              ? colorVf
              : compareLink(
                  colorVf: colorVf!,
                  maskInput: streams.length + 1,
                  lineInput: streams.length + 2,
                  tenBit: clip.tenBit,
                ),
          tenBit: clip.tenBit,
          inputArgs: shared.input,
          outputArgs: shared.output,
          before: frame == null ? null : cropFilter(frame),
          after: frame == null ? null : fitFilter(frame, shownW, shownH),
          pictures: pictures,
        ),
        progress: EncodeProgress(
          duration: duration,
          rangeStart: hudProgressEnd,
        ),
        onProgress: onProgress,
        onStarted: control?.running,
      );
      return (
        totalFrames: clip.totalFrames,
        samples: samples,
        layers: streams.length,
        analysisTime: analysisTime,
        hudTime: hudTime,
        renderTime: watch.elapsed,
      );
    } finally {
      try {
        workDir.deleteSync(recursive: true);
      } on FileSystemException {
        // The sweep at the next start takes it.
      }
    }
  }
}
