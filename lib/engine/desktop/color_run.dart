/// The colour correction of one video on the desktop (Python
/// `ColorCorrectionEngine.process_video_lut`): the clip is looked at every
/// two seconds, each look gives a filter, the filters that differ become
/// 3D LUTs, and ffmpeg applies them while it encodes, fading from one LUT
/// to the next over the two seconds before each one's time.
///
/// The frames are taken out of the clip by ffmpeg, one run a frame,
/// already scaled to the size the analysis works at (the Python app reads
/// them with OpenCV at full size and scales them itself, spec §10.30).
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/engine/ffmpeg_commands.dart';
import 'package:uwmedia_app/core/engine/progress.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/free_space.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/mobile_engine.dart';

/// What a colour run did, for the page's summary line.
typedef ColorRunStats = ({
  int totalFrames,
  int samples,
  int luts,
  Duration analysisTime,
  Duration lutTime,
  Duration renderTime,
});

/// What a clip is, as far as the colour and overlay runs need it.
typedef ClipFacts = ({
  double fps,
  int width,
  int height,
  int totalFrames,
  bool tenBit,
});

/// How many frames of a clip are taken out for the analysis at a time:
/// more than four gave nothing more on the development Mac.
const analysisGrabs = 4;

/// The bytes of one colour table in the tables file (a LUT's points, three
/// bytes each).
const lutTableBytes = lutSize * lutSize * lutSize * 3;

/// What the colour tables leave free on their disk at least: the run's
/// video is mostly written to the same disk.
const freeSpaceMargin = 1000000000;

/// How many LUTs are worked out at once, each in an isolate of its own:
/// half the cores, at most four (a batch may run several clips at once).
final lutWorkers = (Platform.numberOfProcessors ~/ 2).clamp(1, 4);

/// How many LUTs an isolate works out: two keep the batches short, so a
/// Stop is taken within about a second.
const lutsPerWorker = 2;

/// [filters]' LUTs, worked out in an isolate. A function of its own, so
/// that the isolate gets only these two.
Future<List<Uint8List>> _lutsAside(
  ColorEngine engine,
  List<Float32List> filters,
) => Isolate.run(() => [for (final filter in filters) engine.lut3d(filter)]);

/// The colour runs of one ffmpeg with one colour profile.
class ColorRun {
  ColorRun({
    required this.tools,
    required this.engine,
    required this.tempDir,
    this.hwAccel = true,
    this.debug = false,
    this.part,
    this.freeSpace = freeBytes,
  });

  /// The bytes free on the disk of a folder, `null` when not known
  /// ([freeBytes]; the tests give their own).
  final Future<int?> Function(String dir) freeSpace;

  /// The part of the clip the run writes (spec §10.71, §10.75); `null`
  /// for all of it. The clip is then that part to the run: [probe] gives
  /// its frames, [analyze] looks at them, and ffmpeg reads no others.
  final ClipPart? part;

  final FfmpegTools tools;
  final ColorEngine engine;

  /// Makes a fresh working folder (`appTempDir` in the app).
  final Directory Function(String prefix) tempDir;
  final bool hwAccel;
  final bool debug;

  // The clip's frame the part starts at.
  int _firstFrame = 0;

  /// Frame rate, size, frame count and whether the source has more than
  /// 8 bits.
  Future<ClipFacts> probe(String input) async {
    final fps = await tools.fps(input);
    final (width, height) = await tools.dimensions(input);
    var frames = await tools.countedFrames(input);
    if (frames == null) {
      // A file without a count: its length at its own frame rate.
      try {
        frames = (await tools.duration(input) * fps).truncate();
      } on EngineException {
        frames = 0;
      }
    }
    final kept = part;
    if (kept != null && fps > 0) {
      final from = (kept.start * fps).round().clamp(0, frames);
      _firstFrame = from;
      frames = ((kept.end - kept.start) * fps).round().clamp(
        1,
        frames - from < 1 ? 1 : frames - from,
      );
    }
    var tenBit = false;
    try {
      tenBit = isTenBit(await tools.pixFmt(input));
    } on EngineException {
      tenBit = false;
    }
    return (
      fps: fps,
      width: width,
      height: height,
      totalFrames: frames,
      tenBit: tenBit,
    );
  }

  /// The frames the clip is looked at and the filter of each: a frame
  /// that cannot be read is passed over. The frames are taken out
  /// [analysisGrabs] at a time, by the hardware when the run uses it and
  /// it can take the clip.
  Future<({List<int> frames, List<Float32List> filters, int samples})> analyze(
    String input,
    ClipFacts clip, {
    void Function(double percent)? onProgress,
    RunControl? control,
  }) async {
    final wanted = sampleFrames(clip.fps, clip.totalFrames);
    final (width, height) = analysisSize(clip.width, clip.height);
    final hw = hwAccel && await tools.isHwDecodable(input);
    final frames = <int>[];
    final filters = <Float32List>[];
    for (var n = 0; n < wanted.length; n += analysisGrabs) {
      if (control?.stopped ?? false) {
        throw const RunStopped();
      }
      final indices = wanted.skip(n).take(analysisGrabs).toList();
      final grabbed = await Future.wait([
        for (final index in indices)
          tools.frameAt(
            input,
            (_firstFrame + index) / clip.fps,
            width: width,
            height: height,
            hwAccel: hw,
          ),
      ]);
      for (final (i, frame) in grabbed.indexed) {
        if (frame != null) {
          frames.add(indices[i]);
          filters.add(engine.analyze(frame).filter);
        }
      }
      onProgress?.call(
        analysisProgressEnd * (n + indices.length) / wanted.length,
      );
    }
    return (frames: frames, filters: filters, samples: wanted.length);
  }

  /// Writes the LUTs of the distinct filters into [lutDir] (one as a
  /// `.cube` file, several as the raw colour tables the fade between
  /// them is mixed on), and gives the ffmpeg filter that applies them
  /// (each from its time on, the one before fading into it), and how
  /// many LUTs there are. The LUTs are worked out beside the app's own
  /// work, which goes on meanwhile, several at once (spec §10.88).
  ///
  /// The colour tables are refused before a byte is written when the
  /// disk has not room for them and [freeSpaceMargin] more (an
  /// [EngineException]), and [control] stops the writing between two
  /// batches of LUTs ([RunStopped]).
  Future<(String vf, int luts)> writeLuts(
    List<int> frames,
    List<Float32List> filters,
    double fps,
    Directory lutDir, {
    RunControl? control,
  }) async {
    final plan = lut3dFilter(
      frameIndices: frames,
      filters: filters,
      fps: fps,
      lutDir: lutDir.path,
      separator: Platform.pathSeparator,
    );
    final luts = [for (final (_, filter) in plan.luts) filter];
    final tables = plan.tables;
    final dir = lutDir.path;
    if (tables == null) {
      final cube = p.join(dir, lutFileName(0));
      final engine = this.engine;
      final filter = luts.single;
      await Isolate.run(() {
        File(cube)
            .writeAsStringSync(cubeFileText(engine.lut3d(filter), lutSize));
      });
      return (plan.vf, plan.luts.length);
    }

    final needed = tables.length * lutTableBytes;
    final free = await freeSpace(dir);
    if (free != null && free < needed + freeSpaceMargin) {
      throw EngineException(
        'Not enough free space for the colour tables: '
        '${gigabytesText(needed + freeSpaceMargin)} needed on the disk of '
        '$dir, ${gigabytesText(free)} free.',
      );
    }

    // The LUTs the tables use, in their order: a LUT stands at one step
    // or at several on end (one whose step the next takes is not used).
    final used = <int>[];
    for (final lut in tables) {
      if (used.isEmpty || used.last != lut) {
        used.add(lut);
      }
    }
    final batch = lutWorkers * lutsPerWorker;
    final file = await File(p.join(dir, lutTablesFileName))
        .open(mode: FileMode.writeOnly);
    try {
      var next = 0;
      for (var first = 0; first < used.length; first += batch) {
        if (control?.stopped ?? false) {
          throw const RunStopped();
        }
        final end = first + batch < used.length ? first + batch : used.length;
        final made = <int, Uint8List>{};
        final parts = await Future.wait([
          for (var from = first; from < end; from += lutsPerWorker)
            _lutsAside(engine, [
              for (final lut in used.sublist(
                from,
                from + lutsPerWorker < end ? from + lutsPerWorker : end,
              ))
                luts[lut],
            ]),
        ]);
        for (final (i, table) in parts.expand((part) => part).indexed) {
          made[used[first + i]] = table;
        }
        while (next < tables.length && made.containsKey(tables[next])) {
          await file.writeFrom(made[tables[next]]!);
          next++;
        }
      }
    } finally {
      await file.close();
    }
    return (plan.vf, plan.luts.length);
  }

  /// The arguments before the source and after the filters that the
  /// colour and the overlay runs share.
  Future<({List<String> input, List<String> output})> sharedArgs({
    required String input,
    required String output,
    required DateTime creationDate,
    required int? tzOffsetMins,
    required bool tenBit,
    int? bitrate,
    bool h264 = false,
  }) async {
    // An output size brings its own bit rate; else the source's.
    if (bitrate == null) {
      try {
        bitrate = await tools.bitrate(input);
      } on EngineException {
        bitrate = null;
      }
    }
    final encoder = await tools.encoder(hwAccel: hwAccel);
    final kept = part;
    return (
      input: [
        ...colorInputArgs(
          debug: debug,
          hwAccel: hwAccel,
          sourceHwDecodable: hwAccel && await tools.isHwDecodable(input),
          os: tools.os,
        ),
        // Before the source: only the part is read.
        if (kept != null) ...partInputArgs(kept.start, kept.end),
      ],
      output: colorOutputArgs(
        output: output,
        creationDate: creationDate,
        encoder: h264 ? h264EncoderFor(encoder) : encoder,
        tenBit: tenBit,
        sourceBitrate: bitrate,
        tzOffsetMins: tzOffsetMins,
        h264: h264,
      ),
    );
  }

  /// Colour-corrects [input] into [output]. [onProgress] gets the
  /// percentage of the whole run (the analysis is its first tenth), held
  /// back to one a percent; [control] stops it. Throws an
  /// [EngineException] when no frame could be read or ffmpeg fails, and
  /// [RunStopped] when stopped.
  Future<ColorRunStats> processVideoLut({
    required String input,
    required String output,
    required DateTime creationDate,
    int? tzOffsetMins,
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

    final clip = await probe(input);
    final duration = clip.fps > 0 ? clip.totalFrames / clip.fps : 0.0;

    final watch = Stopwatch()..start();
    final analysis = await analyze(
      input,
      clip,
      onProgress: report,
      control: control,
    );
    final analysisTime = watch.elapsed;
    if (analysis.filters.isEmpty) {
      throw const EngineException('Could not analyze any frames.');
    }

    final lutDir = tempDir('uwmedia_lut_');
    try {
      watch.reset();
      final (vf, luts) = await writeLuts(
        analysis.frames,
        analysis.filters,
        clip.fps,
        lutDir,
        control: control,
      );
      final lutTime = watch.elapsed;
      if (control?.stopped ?? false) {
        throw const RunStopped();
      }

      final shared = await sharedArgs(
        input: input,
        output: output,
        creationDate: creationDate,
        tzOffsetMins: tzOffsetMins,
        tenBit: clip.tenBit,
      );
      watch.reset();
      await tools.run(
        lutCommandArgs(
          input: input,
          vf: vf,
          inputArgs: shared.input,
          outputArgs: shared.output,
        ),
        progress: EncodeProgress(
          duration: duration,
          rangeStart: analysisProgressEnd,
        ),
        onProgress: onProgress,
        onStarted: control?.running,
      );
      return (
        totalFrames: clip.totalFrames,
        samples: analysis.samples,
        luts: luts,
        analysisTime: analysisTime,
        lutTime: lutTime,
        renderTime: watch.elapsed,
      );
    } finally {
      try {
        lutDir.deleteSync(recursive: true);
      } on FileSystemException {
        // The sweep at the next start takes it.
      }
    }
  }
}
