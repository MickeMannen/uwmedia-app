/// One video downscaled to the resolutions picked on the Convertion page
/// (Python `cli_main.py`: the start of `process_single_file`, which reads
/// the file's local creation date and its timezone, then
/// `process_conversions`): one encode a resolution, one after the other,
/// each into a free name in the output folder, with the source's metadata
/// carried over.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/engine/share_sizes.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/engine/desktop/exiftool.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/overlay_run.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/mobile_video_run.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';

/// Where a conversion is: [done] of [total] encodes ended, and the file
/// being written now ([target], `null` before the first and after the
/// last).
typedef ConvertStep = ({int done, int total, String? target});

/// What a conversion did: the resolutions that failed, and what went
/// wrong or was only a warning, a line each.
typedef ConvertResult = ({List<String> failed, List<String> messages});

class ConvertRun {
  ConvertRun({
    required this.ffmpeg,
    required this.exiftool,
    this.marker,
    this.native,
  });

  /// The run through the runner's media engine, when the videos are to
  /// be written by it and not by ffmpeg (a Mac,
  /// `docs/design/macos-remove-ffmpeg.md`); a watermark is then drawn by it too. The
  /// metadata is still copied by exiftool.
  final MobileVideoRun? native;

  final FfmpegTools ffmpeg;
  final Exiftool exiftool;

  /// The run that draws a watermark on the video while it is resized
  /// (spec §10.52), for the hardware switch as given; without it a
  /// watermark is not drawn.
  final OverlayRun Function(bool hwAccel)? marker;

  /// Converts [source] to each of [resolutions] (names of
  /// [convertResolutions]) and to each of [shares] (the copies for
  /// sharing, spec §10.49) in [outputDir], made when it is not there.
  /// [onStep] hears of each encode as it starts and ends, [onProgress]
  /// the percent of the one going. A resolution that fails does not stop
  /// the others. Throws a [FormatException] when the file is no video or
  /// has no date to stamp the outputs with, and [RunStopped] when
  /// [control] was stopped.
  Future<ConvertResult> convert({
    required String source,
    required String outputDir,
    required List<String> resolutions,
    required bool hwAccel,
    List<ShareCopy> shares = const [],
    List<HudLayerSource> watermarks = const [],
    RunControl? control,
    void Function(ConvertStep step)? onStep,
    void Function(double percent)? onProgress,
  }) async {
    if (!isVideoPath(source)) {
      throw FormatException('Not a video: ${p.basename(source)}');
    }
    final meta = await exiftool.metadata(source);
    if (control?.stopped ?? false) {
      throw const RunStopped();
    }
    final DateTime creationDate;
    try {
      creationDate = localCreationDate(
        meta,
        fileModified: fileModified(source),
      );
    } on FormatException catch (e) {
      throw FormatException('Error extracting metadata: ${e.message}');
    }
    final tzOffsetMins = timezoneOffsetMinutes(meta);
    // With a watermark the encode is the overlay run's: the mark drawn
    // on the picture, then the size.
    final sizes = {
      for (final (name, w, h, bitrate) in convertResolutions)
        name: (w, h, bitrate),
    };
    final messages = <String>[];
    final native = this.native;
    final marking = watermarks.isEmpty || native != null
        ? null
        : marker?.call(hwAccel);
    // The engine's encode of one size or copy: with a watermark the mark
    // drawn on the picture, then the size.
    Future<void> byEngine(String target, String name, ShareCopy? share) async {
      final preset = sizes[name];
      final lines = watermarks.isNotEmpty && native!.renderer != null
          ? await native.process(
              input: source,
              output: target,
              layers: watermarks,
              size: share == null
                  ? OutputSize.resolution(name, always: true)
                  : OutputSize.share(share),
              onProgress: onProgress,
              control: control,
            )
          : await native!.convert(
              input: source,
              output: target,
              size: preset == null ? null : (preset.$1, preset.$2),
              bitrate: preset == null ? null : presetBitrate(preset.$3),
              share: share,
              onProgress: onProgress,
              control: control,
            );
      for (final line in lines) {
        messages.add('$name: $line');
      }
    }

    Future<void> marked(String target, OutputSize size) =>
        marking!.processVideo(
          input: source,
          output: target,
          creationDate: creationDate,
          layers: watermarks,
          tzOffsetMins: tzOffsetMins,
          colorCorrect: false,
          size: size,
          onProgress: onProgress,
          control: control,
        );
    Directory(outputDir).createSync(recursive: true);

    final wanted = [
      for (final name in resolutions)
        if (sizes.containsKey(name)) name,
    ];
    final unique = UniquePaths(
      (path) =>
          FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound,
    );
    final total = wanted.length + shares.length;
    final failed = <String>[];
    onStep?.call((done: 0, total: total, target: null));
    var done = 0;
    for (final name in wanted) {
      if (control?.stopped ?? false) {
        throw const RunStopped();
      }
      final (width, height, bitrate) = sizes[name]!;
      final target = unique.unique(
        p.join(outputDir, convertOutputFilename(source, name)),
      );
      onStep?.call((done: done, total: total, target: p.basename(target)));
      try {
        if (native != null) {
          await byEngine(target, name, null);
        } else if (marking != null) {
          await marked(target, OutputSize.resolution(name, always: true));
        } else {
          await ffmpeg.processVideo(
            input: source,
            output: target,
            creationDate: creationDate,
            hwAccel: hwAccel,
            tzOffsetMins: tzOffsetMins,
            targetResolution: (width, height),
            bitrate: bitrate,
            onProgress: onProgress,
            onStarted: control?.running,
          );
        }
        try {
          for (final line in await exiftool.copyAll(source, target)) {
            messages.add('$name: $line');
          }
        } on Exception catch (e) {
          messages.add('$name: Warning: Failed to copy metadata: $e');
        }
      } on RunStopped {
        _remove(target);
        rethrow;
      } on Exception catch (e) {
        _remove(target);
        failed.add(name);
        messages.add('Error converting to $name: $e');
      }
      done++;
      onStep?.call((
        done: done,
        total: total,
        target: done < total ? p.basename(target) : null,
      ));
    }
    if (shares.isNotEmpty) {
      final (sourceW, sourceH) = native != null
          ? (0, 0)
          : await ffmpeg.displayDimensions(source);
      for (final copy in shares) {
        if (control?.stopped ?? false) {
          throw const RunStopped();
        }
        final name = copy.label;
        final target = unique.unique(p.join(outputDir, copy.filename(source)));
        onStep?.call((done: done, total: total, target: p.basename(target)));
        try {
          if (native != null) {
            await byEngine(target, name, copy);
          } else if (marking != null) {
            await marked(target, OutputSize.share(copy));
          } else {
            await ffmpeg.shareVideo(
              input: source,
              output: target,
              creationDate: creationDate,
              hwAccel: hwAccel,
              frame: shareFrame(copy, sourceW, sourceH),
              sourceWidth: sourceW,
              sourceHeight: sourceH,
              tzOffsetMins: tzOffsetMins,
              onProgress: onProgress,
              onStarted: control?.running,
            );
          }
          try {
            for (final line in await exiftool.copyAll(source, target)) {
              messages.add('$name: $line');
            }
          } on Exception catch (e) {
            messages.add('$name: Warning: Failed to copy metadata: $e');
          }
        } on RunStopped {
          _remove(target);
          rethrow;
        } on Exception catch (e) {
          _remove(target);
          failed.add(name);
          messages.add('Error converting to $name: $e');
        }
        done++;
        onStep?.call((
          done: done,
          total: total,
          target: done < total ? p.basename(target) : null,
        ));
      }
    }
    return (failed: failed, messages: messages);
  }

  // A stopped or failed encode's half-written file (spec §10.49; the
  // Python app leaves it).
  static void _remove(String path) {
    try {
      File(path).deleteSync();
    } on FileSystemException {
      // Never written.
    }
  }
}
