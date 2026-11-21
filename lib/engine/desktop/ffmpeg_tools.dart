/// ffmpeg and ffprobe on the desktop (Python `ffmpeg/ffmpeg_class.py`'s
/// `FfmpegClass`): what a file is, which encoder opens on this machine,
/// and a run with its progress and Stop. The command lines themselves and
/// the reading of the answers are in `core/engine/ffmpeg_commands.dart`.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/app_paths.dart';

import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/engine/ffmpeg_commands.dart';
import 'package:uwmedia_app/core/engine/progress.dart';
import 'package:uwmedia_app/core/engine/share_sizes.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';

/// A tool that is missing, could not be run or ended with an error;
/// [message] is for the user, [output] what the tool wrote.
class EngineException implements Exception {
  const EngineException(this.message, {this.exitCode, this.output = ''});

  final String message;
  final int? exitCode;
  final String output;

  @override
  String toString() => output.isEmpty ? message : '$message\n$output';
}

/// A run that [ToolRun.stop] ended.
class RunStopped implements Exception {
  const RunStopped();

  @override
  String toString() => 'Stopped';
}

const ffmpegMissingMessage =
    'FFmpeg executable not found. Configure its location on the Settings '
    "page, or install FFmpeg and ensure it's on your PATH.";
const ffprobeMissingMessage =
    "ffprobe executable not found. Configure FFmpeg's location on the "
    'Settings page (ffprobe is expected alongside it), or install FFmpeg '
    "and ensure it's on your PATH.";

/// How long the one-frame test encode of an encoder may take.
const encoderProbeTimeout = Duration(seconds: 30);

/// The ffmpeg at [ffmpeg] and the ffprobe at [ffprobe] (`null` when none
/// was found: asking about a file then fails with a message).
class FfmpegTools {
  FfmpegTools({
    required this.ffmpeg,
    required this.ffprobe,
    required this.os,
    this.workDir,
  });

  final String ffmpeg;
  final String? ffprobe;
  final EngineOs os;

  /// Where a long command's filters are written; `appTempDir` when not
  /// given.
  final Directory Function()? workDir;

  // Whether each ffmpeg takes `-/option file`: asked once.
  static final Map<String, Future<bool>> _optionFiles = {};

  // The hardware encoders that opened, per ffmpeg: found once, by test
  // encodes that take a moment each.
  static final Map<String, Future<Set<String>>> _hardware = {};

  /// The first line of `ffmpeg -version`.
  Future<String> version() async {
    final result = await runCapture(ffmpeg, const ['-version']);
    if (result == null || result.exitCode != 0) {
      throw EngineException(
        'FFmpeg could not be run',
        exitCode: result?.exitCode,
        output: result?.stderr ?? '',
      );
    }
    return result.stdout.split('\n').first.trimRight();
  }

  /// The hardware encoders of Windows that open on this machine (spec
  /// §10.1); none elsewhere, where there is nothing to choose between.
  Future<Set<String>> hardwareEncoders() => _hardware.putIfAbsent(
    ffmpeg,
    () async => {
      if (os == EngineOs.windows)
        for (final encoder in windowsHardwareEncoders)
          if ((await runCapture(
                ffmpeg,
                encoderProbeArgs(encoder),
                timeout: encoderProbeTimeout,
              ))?.exitCode ==
              0)
            encoder,
    },
  );

  /// The HEVC encoder for a run on this machine.
  Future<String> encoder({required bool hwAccel}) async => chooseEncoder(
    hwAccel: hwAccel,
    os: os,
    available: hwAccel && os == EngineOs.windows
        ? await hardwareEncoders()
        : const {},
  );

  Future<String?> _probe(List<String> args) async {
    final probe = ffprobe;
    if (probe == null) {
      throw const EngineException(ffprobeMissingMessage);
    }
    final result = await runCapture(probe, args);
    return result == null || result.exitCode != 0 ? null : result.stdout;
  }

  Future<String> _answer(List<String> args, String path) async {
    final out = await _probe(args);
    if (out == null) {
      throw EngineException('ffprobe could not read $path');
    }
    return out;
  }

  /// The length of the file in seconds.
  Future<double> duration(String path) async {
    final seconds = parseDuration(await _answer(probeDurationArgs(path), path));
    if (seconds == null) {
      throw EngineException('ffprobe gave no duration for $path');
    }
    return seconds;
  }

  /// The video's bit rate: the stream's, else the file's, else 10 Mbit/s.
  Future<int> bitrate(String path) async {
    var out = await _answer(probeStreamBitrateArgs(path), path);
    if (bitrateNeedsFormat(out)) {
      out = await _answer(probeFormatBitrateArgs(path), path);
    }
    return parseBitrate(out);
  }

  /// Width and height of the video.
  Future<(int, int)> dimensions(String path) async {
    final size = parseDimensions(
      await _answer(probeDimensionsArgs(path), path),
    );
    if (size == null) {
      throw EngineException('ffprobe gave no size for $path');
    }
    return size;
  }

  /// Width and height as the video is shown (a phone's upright video
  /// turned), which is what ffmpeg's filters get.
  Future<(int, int)> displayDimensions(String path) async {
    final size = parseDisplayDimensions(
      await _answer(probeDisplayDimensionsArgs(path), path),
    );
    if (size == null) {
      throw EngineException('ffprobe gave no size for $path');
    }
    return size;
  }

  /// The number of frames the file itself states; `null` when it states
  /// none.
  Future<int?> countedFrames(String path) async =>
      parseFrameCount(await _probe(probeFrameCountArgs(path)));

  /// The number of frames: the file's count, else guessed from the
  /// duration, else 0.
  Future<int> frameCount(String path) async {
    final count = parseFrameCount(await _probe(probeFrameCountArgs(path)));
    if (count != null) {
      return count;
    }
    final out = await _probe(probeDurationArgs(path));
    return framesFromDuration(out == null ? null : parseDuration(out));
  }

  /// The video's pixel format.
  Future<String> pixFmt(String path) async =>
      firstProbeLine(await _answer(probePixFmtArgs(path), path));

  /// Frames a second: the file's average rate, else 30.
  Future<double> fps(String path) async =>
      parseFps(await _probe(probeFpsArgs(path)));

  /// The frame at [seconds] as RGB, scaled to [width] by [height]; `null`
  /// when there is no frame there. With [hwAccel] the hardware decodes it
  /// (the same picture, several times as fast on a 4K clip), and the
  /// software does when the hardware gives none.
  Future<RgbImage?> frameAt(
    String path,
    double seconds, {
    required int width,
    required int height,
    bool hwAccel = false,
  }) async {
    Future<Uint8List?> grab(EngineOs? hw) => runForBytes(
      ffmpeg,
      frameGrabArgs(path, seconds, width: width, height: height, hwAccel: hw),
    );
    bool whole(Uint8List? bytes) =>
        bytes != null && bytes.length == width * height * 3;
    var bytes = hwAccel ? await grab(os) : null;
    if (!whole(bytes)) {
      bytes = await grab(null);
    }
    return whole(bytes) ? RgbImage(width, height, bytes!) : null;
  }

  /// Whether a hardware decoder can take the file.
  Future<bool> isHwDecodable(String path) async => hwDecodable(
    await _probe(probeCodecArgs(path)),
    os: os,
    // Only a Mac's rule asks for it.
    brand: os == EngineOs.macos ? await _probe(probeBrandArgs(path)) : null,
  );

  /// Runs ffmpeg with [args] to its end, with its progress reported on
  /// the error stream. [progress] turns that into the percentages
  /// [onProgress] gets; [onStarted] hands out the run, for Stop. Throws
  /// an [EngineException] with what ffmpeg wrote when it ends with an
  /// error, and [RunStopped] when it was stopped.
  Future<void> run(
    List<String> args, {
    EncodeProgress? progress,
    void Function(double percent)? onProgress,
    void Function(ToolRun run)? onStarted,
  }) async {
    var command = [...args, ...progressArgs];
    Directory? scripts;
    if (commandChars(command) > maxCommandChars) {
      // Too long for Windows (spec §10.79): the filters from files.
      final optionFiles = await _optionFiles.putIfAbsent(ffmpeg, () async {
        try {
          return readsOptionFiles(await version());
        } on EngineException {
          return true;
        }
      });
      final folder = scripts =
          (workDir ?? () => appTempDir('uwmedia_filters_'))();
      var count = 0;
      command = filtersFromFiles(
        command,
        (graph) => (File(
          p.join(folder.path, 'filter_${count++}.txt'),
        )..writeAsStringSync(graph)).path,
        optionFiles: optionFiles,
      );
    }
    try {
      await _run(command, progress, onProgress, onStarted);
    } finally {
      try {
        scripts?.deleteSync(recursive: true);
      } on FileSystemException {
        // Swept with the other working folders at the next start.
      }
    }
  }

  Future<void> _run(
    List<String> command,
    EncodeProgress? progress,
    void Function(double percent)? onProgress,
    void Function(ToolRun run)? onStarted,
  ) async {
    final ToolRun tool;
    try {
      tool = await ToolRun.start(ffmpeg, command);
    } on Exception catch (e) {
      throw EngineException('FFmpeg could not be started', output: '$e');
    }
    onStarted?.call(tool);
    final errors = <String>[];
    await for (final line in tool.lines) {
      // ffmpeg's progress lines are key=value; anything else is a message.
      if (!_progressLine.hasMatch(line)) {
        errors.add(line);
      }
      final percent = progress?.onLine(line);
      if (percent != null) {
        onProgress?.call(percent);
      }
    }
    final exit = await tool.exitCode;
    if (tool.stopped) {
      throw const RunStopped();
    }
    if (exit != 0) {
      throw EngineException(
        'FFmpeg Error (Exit $exit)',
        exitCode: exit,
        output: errors.join('\n'),
      );
    }
    final done = progress?.onDone();
    if (done != null) {
      onProgress?.call(done);
    }
  }

  /// Converts or passes on one video (the Convertion page; Python
  /// `process_video`): scaled into [targetResolution] and encoded at
  /// [bitrate] or at the source's own, or with nothing asked for copied
  /// as it is, in both cases with the creation date written.
  Future<void> processVideo({
    required String input,
    required String output,
    required DateTime creationDate,
    required bool hwAccel,
    bool colorCorrect = false,
    int? tzOffsetMins,
    (int, int)? targetResolution,
    String? bitrate,
    void Function(double percent)? onProgress,
    void Function(ToolRun run)? onStarted,
  }) async {
    final seconds = await duration(input);
    int? sourceBitrate;
    // A plain copy asks for no bit rate.
    final copies =
        targetResolution == null && (bitrate ?? '').isEmpty && !colorCorrect;
    if (!copies && (bitrate ?? '').isEmpty) {
      try {
        sourceBitrate = await this.bitrate(input);
      } on EngineException {
        // Without it the encoder's own default stands.
        sourceBitrate = null;
      }
    }
    final command = processVideoArgs(
      input: input,
      output: output,
      creationDate: creationDate,
      duration: seconds,
      encoder: await encoder(hwAccel: hwAccel),
      colorCorrect: colorCorrect,
      tzOffsetMins: tzOffsetMins,
      targetResolution: targetResolution,
      bitrate: bitrate,
      sourceBitrate: sourceBitrate,
      hwDecode: !copies && hwAccel && await isHwDecodable(input) ? os : null,
    );
    await run(
      command.args,
      progress: EncodeProgress(duration: command.duration),
      onProgress: onProgress,
      onStarted: onStarted,
    );
  }

  /// A copy of [input] for sharing ([shareVideoArgs]): [frame]'s picture
  /// of the [sourceWidth] by [sourceHeight] source, as H.264.
  Future<void> shareVideo({
    required String input,
    required String output,
    required DateTime creationDate,
    required bool hwAccel,
    required ShareFrame frame,
    required int sourceWidth,
    required int sourceHeight,
    int? tzOffsetMins,
    void Function(double percent)? onProgress,
    void Function(ToolRun run)? onStarted,
  }) async {
    final command = shareVideoArgs(
      input: input,
      output: output,
      creationDate: creationDate,
      duration: await duration(input),
      encoder: h264EncoderFor(await encoder(hwAccel: hwAccel)),
      frame: frame,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      tzOffsetMins: tzOffsetMins,
      hwDecode: hwAccel && await isHwDecodable(input) ? os : null,
    );
    await run(
      command.args,
      progress: EncodeProgress(duration: command.duration),
      onProgress: onProgress,
      onStarted: onStarted,
    );
  }
}

final _progressLine = RegExp(
  r'^(frame|fps|stream_\d+_\d+_q|bitrate|total_size|out_time_us|out_time_ms|'
  r'out_time|dup_frames|drop_frames|speed|progress)=',
);
