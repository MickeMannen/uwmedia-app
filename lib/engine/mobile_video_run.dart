/// A video's colour correction, overlays and downscale on a phone, the
/// work of the desktop's `ColorRun`, `OverlayRun` and `ConvertRun` done
/// through the phone's [MobileMediaEngine]: the clip is looked at every two
/// seconds and the distinct filters made LUTs, the layers drawn once per
/// dive sample, all as on the desktop; the engine applies them while it
/// encodes. The source's dates, make and model are written to the output
/// by the app's own MP4 writer afterwards (spec §9: the metadata subset).
///
/// Differences from the desktop (spec §10.43): the frames looked at are the
/// key frames nearest to the sample times, the output is HEVC at the
/// source's bit rate, and an HDR source is turned to SDR when a LUT or an
/// overlay is applied.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/engine/compare.dart';
import 'package:uwmedia_app/core/engine/ffmpeg_commands.dart';
import 'package:uwmedia_app/core/engine/hud_layers.dart';
import 'package:uwmedia_app/core/engine/progress.dart';
import 'package:uwmedia_app/core/engine/share_sizes.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/metadata/mp4_dates.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/engine/compare_pictures.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/media_file_dates.dart';
import 'package:uwmedia_app/engine/mobile_engine.dart';
import 'package:uwmedia_app/engine/mp4_file.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

/// The colour LUTs of a clip from its sampled [frames] and their
/// [filters]: one for each filter not close to the one kept before it,
/// from its frame's time on (the first from the start), as the desktop's
/// filter switches them.
List<({double seconds, Float32List filter})> timedFilters(
  List<int> frames,
  List<Float32List> filters,
  double fps,
) => [
  for (final (i, (frame, filter)) in distinctFilters(frames, filters).indexed)
    (seconds: i == 0 ? 0.0 : frame / fps, filter: filter),
];

/// The LUT of each of [timed] (64³ entries each), made on another
/// isolate. Top-level so the closure sent there holds only [color] and
/// [timed], not the run's context.
Future<List<Uint8List>> _lutsOffThread(
  ColorEngine color,
  List<({double seconds, Float32List filter})> timed,
) => Isolate.run(() => [for (final t in timed) color.lut3d(t.filter)]);

/// The shortest part of a video a run writes, in seconds.
const minClipPart = 1.0;

/// [part] as it lies within a video [seconds] long; `null` when it is
/// the whole video, or no part at all.
ClipPart? clipPartWithin(ClipPart? part, double seconds) {
  if (part == null || seconds <= 0) {
    return null;
  }
  final start = part.start.clamp(0.0, seconds);
  final end = part.end.clamp(start, seconds);
  if (end - start <= 0 || (start <= 0 && end >= seconds)) {
    return null;
  }
  return (start: start, end: end);
}

/// The pictures of a layer as the engine takes them: each from its first
/// frame's time on.
List<OverlayPicture> timedPictures(List<(String, int)> entries, double fps) {
  final out = <OverlayPicture>[];
  var frame = 0;
  for (final (path, frames) in entries) {
    out.add((path: path, seconds: frame / fps));
    frame += frames;
  }
  return out;
}

/// The source's QuickTime dates, make, model and software written to the
/// video at [target] (where it lies), the camera also when the source
/// names it elsewhere ([cameraOf]). A source that knows its timezone
/// only by a tag of its own (a Sony camera's) gets its local time with
/// the offset as `CreationDate`, as the desktop writes it after copying
/// the tags; the timezone tags themselves are not written (spec §10.23).
/// Gives a line for what could not be written; empty when all went well.
List<String> copyVideoDates(String source, String target) {
  final Map<String, String> tags;
  try {
    final meta = readFileDates(source);
    tags = {
      for (final MapEntry(:key, :value) in meta.entries)
        if (key.startsWith('QuickTime:') &&
            !mp4CameraTags.contains(key) &&
            !key.toLowerCase().endsWith('zone') &&
            value != null)
          key: '$value',
      if (timezoneTagsAfterCopy(meta) case final zone?)
        'QuickTime:CreationDate': zone['QuickTime:CreationDate']!,
    };
    // Which camera it was, where the source says it in a place of its
    // own that an encode does not carry over (a Sony's XML block, a DJI's
    // name): as QuickTime's Make and Model (spec §10.72).
    final camera = cameraOf(meta);
    if (camera.make case final String make) {
      tags.putIfAbsent('QuickTime:Make', () => make);
    }
    if (camera.model case final String model) {
      tags.putIfAbsent('QuickTime:Model', () => model);
    }
  } on Object catch (e) {
    return ['Warning: the dates could not be read ($e)'];
  }
  if (tags.isEmpty) {
    return const [];
  }
  try {
    final written = writeMp4Dates(target, tags);
    return [
      if (written.ignored.isNotEmpty)
        'Not written: ${written.ignored.join(', ')}',
    ];
  } on Object catch (e) {
    return ['Warning: the dates could not be written ($e)'];
  }
}

/// What a run says when the phone took an export away (the screen
/// locked, the app left) and it started again from the beginning.
String restartMessage(String name) =>
    '$name: the phone was locked or UWMedia left, so the video started '
    'again from the beginning.';

class MobileVideoRun {
  MobileVideoRun({
    required this.engine,
    required this.tempDir,
    this.renderer,
    this.painter,
    this.units = UnitSystem.metric,
  });

  final MobileMediaEngine engine;

  /// Makes a fresh working folder (`appTempDir` in the app).
  final Directory Function(String prefix) tempDir;
  final HudRenderer? renderer;
  final HudPainter? painter;
  final UnitSystem units;

  /// The filters of the frames [color] looks at (one every two seconds and
  /// the last); a frame that cannot be read is passed over. Of a part of
  /// the clip ([firstFrame], [frameCount]) the frames count from its
  /// first.
  Future<({List<int> frames, List<Float32List> filters})> analyze(
    String input,
    ClipInfo clip,
    ColorEngine color, {
    void Function(double percent)? onProgress,
    bool Function()? stopped,
    int firstFrame = 0,
    int? frameCount,
  }) async {
    final fps = clip.frameRate;
    final wanted = sampleFrames(fps, frameCount ?? clip.totalFrames);
    final (width, height) = analysisSize(clip.width, clip.height);
    final frames = <int>[];
    final filters = <Float32List>[];
    for (final (n, index) in wanted.indexed) {
      if (stopped?.call() ?? false) {
        throw const RunStopped();
      }
      final frame = await engine.frameAt(
        input,
        (firstFrame + index) / fps,
        maxWidth: width,
        maxHeight: height,
      );
      if (frame != null) {
        frames.add(index);
        filters.add(color.analyze(frame).filter);
      }
      onProgress?.call(analysisProgressEnd * (n + 1) / wanted.length);
    }
    return (frames: frames, filters: filters);
  }

  /// Writes [input] to [output] colour-corrected by [color] (when given)
  /// and with [layers] laid over it for the [dive] sample of each moment
  /// ([matchDate] is when the footage starts on the dive computer's
  /// clock). [onProgress] hears the percent of the whole run, [onRestart]
  /// that the encode started again from the beginning (the screen locked);
  /// [control] stops it. Gives the lines worth showing. Throws an [EngineException]
  /// when the video cannot be read or written, and [RunStopped]. With
  /// [compare] (and [color]) the original shows on one side of an edge
  /// and the corrected picture on the other (spec §10.94; the Apple
  /// engine).
  Future<List<String>> process({
    required String input,
    required String output,
    ColorEngine? color,
    List<HudLayerSource> layers = const [],
    Dive? dive,
    DateTime? matchDate,
    OutputSize? size,
    ClipPart? part,
    Compare? compare,
    void Function(double percent)? onProgress,
    void Function()? onRestart,
    RunControl? control,
  }) async {
    final progress = FileProgress(p.basename(input));
    void report(double percent) {
      final step = progress.report(percent);
      if (step != null) {
        onProgress?.call(step);
      }
    }

    bool stopped() => control?.stopped ?? false;
    final clip = await engine.probe(input);
    final fps = clip.frameRate;
    // A part of the clip (spec §10.71): only its frames are looked at,
    // drawn for and written, and the dive is followed from its start.
    final kept = clipPartWithin(part, clip.durationSeconds);
    final firstFrame = kept == null ? 0 : (kept.start * fps).round();
    final totalFrames = kept == null
        ? clip.totalFrames
        : ((kept.end - kept.start) * fps).round().clamp(1, clip.totalFrames);
    final start = matchDate == null || kept == null
        ? matchDate
        : matchDate.add(Duration(microseconds: (kept.start * 1e6).round()));
    // An output size (spec §10.51): the layers lie on what its crop
    // leaves of the picture; the engine scales after them.
    final frame = size?.frameFor(
      clip.width,
      clip.height,
      sourceBitrate: clip.bitrate,
    );
    final frameW = frame?.crop?.width ?? clip.width;
    final frameH = frame?.crop?.height ?? clip.height;

    var luts = <TimedLut>[];
    if (color != null) {
      final analysis = await analyze(
        input,
        clip,
        color,
        onProgress: report,
        stopped: stopped,
        firstFrame: firstFrame,
        frameCount: totalFrames,
      );
      if (analysis.filters.isEmpty) {
        throw const EngineException('Could not analyze any frames.');
      }
      final timed = timedFilters(analysis.frames, analysis.filters, fps);
      final tables = await _lutsOffThread(color, timed);
      luts = [
        for (final (i, t) in timed.indexed)
          (seconds: t.seconds, lut: tables[i]),
      ];
    }
    if (stopped()) {
      throw const RunStopped();
    }

    final workDir = tempDir('uwmedia_overlay_');
    try {
      final drawn = <OverlayLayer>[];
      final draw = renderer;
      final paint = painter;
      // Without a matched dive only the layers that need none (a
      // watermark), each one picture for the whole clip.
      final matched =
          dive != null && dive.waypoints.isNotEmpty && start != null;
      final wanted = layersToDraw(layers, matched: matched);
      if (wanted.isNotEmpty && draw != null && paint != null) {
        final List<HudSegment> whole = [(null, 0, totalFrames)];
        final segments = matched
            ? hudSegments(dive, start, fps, totalFrames)
            : whole;
        final writer = HudLayerWriter(
          draw,
          paint,
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
            final pictures = await writer.pictures(
              layer,
              layer.always ? whole : segments,
              dive?.waypoints ?? const [],
              workDir,
              li,
              fps: fps,
              stopped: stopped,
              onSegment: (i) => report(
                analysisProgressEnd +
                    (hudProgressEnd - analysisProgressEnd) *
                        (before[li] + i + 1) /
                        (steps < 1 ? 1 : steps),
              ),
            );
            if (pictures != null) {
              drawn.add((
                x: pictures.x,
                y: pictures.y,
                pictures: timedPictures(pictures.entries, fps),
              ));
            }
          } on HudLayerStopped {
            throw const RunStopped();
          }
        }
      }
      if (stopped()) {
        throw const RunStopped();
      }
      ({String mask, String line})? pictures;
      if (compare != null && luts.isNotEmpty) {
        final written = await writeComparePictures(
          CompareEdge.split(compare.kind, frameW, frameH),
          workDir,
        );
        pictures = (mask: written[0], line: written[1]);
      }
      await _encode(
        EncodeJob(
          input: input,
          output: output,
          frameWidth: clip.width,
          frameHeight: clip.height,
          fit: frame == null ? null : (frame.width, frame.height),
          crop: frame?.crop,
          h264: frame != null && size!.h264,
          bitrate: frame?.bitrate ?? clip.bitrate,
          luts: luts,
          // From one analysed frame to the next.
          lutFade: sampleStep(fps) / fps,
          layers: drawn,
          toneMap: clip.hdr && (luts.isNotEmpty || drawn.isNotEmpty),
          part: kept,
          compare: pictures,
        ),
        control,
        (percent) =>
            report(hudProgressEnd + (100 - hudProgressEnd) * percent / 100),
        () {
          progress.restart();
          onRestart?.call();
        },
      );
      return copyVideoDates(input, output);
    } finally {
      try {
        workDir.deleteSync(recursive: true);
      } on FileSystemException {
        // The sweep at the next start takes it.
      }
    }
  }

  /// [input] scaled to fit [size] (padded) as HEVC at [bitrate] into
  /// [output], with the source's dates; for a [share] copy that copy's
  /// crop, size and bit rate, as H.264; [onRestart] as for [process].
  /// Gives the lines worth showing.
  Future<List<String>> convert({
    required String input,
    required String output,
    (int, int)? size,
    int? bitrate,
    ShareCopy? share,
    void Function(double percent)? onProgress,
    void Function()? onRestart,
    RunControl? control,
  }) async {
    final clip = await engine.probe(input);
    final frame = share == null
        ? null
        : shareFrame(share, clip.width, clip.height);
    await _encode(
      EncodeJob(
        input: input,
        output: output,
        frameWidth: clip.width,
        frameHeight: clip.height,
        fit: frame == null ? size : (frame.width, frame.height),
        crop: frame?.crop,
        h264: frame != null,
        bitrate: frame?.bitrate ?? bitrate,
      ),
      control,
      onProgress,
      onRestart,
    );
    return copyVideoDates(input, output);
  }

  Future<EncodeResult> _encode(
    EncodeJob job,
    RunControl? control,
    void Function(double percent)? onProgress, [
    void Function()? onRestart,
  ]) async {
    control?.runningWith(engine.cancel);
    if (control?.stopped ?? false) {
      throw const RunStopped();
    }
    try {
      return await engine.encode(
        job,
        onProgress: onProgress,
        onRestart: onRestart,
      );
    } on RunStopped {
      _remove(job.output);
      rethrow;
    } on EngineException {
      _remove(job.output);
      rethrow;
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
