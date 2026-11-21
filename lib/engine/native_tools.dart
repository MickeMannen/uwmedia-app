/// ffmpeg's and exiftool's places taken by the runner's media engine and
/// the app's own readers and writers, for a desktop build that carries
/// neither (the Mac App Store's, `docs/design/macos-remove-ffmpeg.md` step 7; spec
/// §10.74). The pages and the runs ask a [FfmpegTools] and an [Exiftool]
/// for what they need; these two answer from the engine and from
/// `lib/core/metadata/`, so the pages and the runs stay as they are.
///
/// What they cannot do they say: a run that would start ffmpeg throws an
/// [EngineException]. The runs are given the engine too
/// ([storeDesktopTools] goes with `AppServices.nativeVideoEngine`), so
/// every video is written by it and those calls are not made.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/engine/ffmpeg_commands.dart';
import 'package:uwmedia_app/core/engine/progress.dart';
import 'package:uwmedia_app/core/engine/share_sizes.dart';
import 'package:uwmedia_app/core/metadata/exiftool_commands.dart';
import 'package:uwmedia_app/core/metadata/jpeg_exif.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/engine/desktop/exiftool.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/media_file_dates.dart';
import 'package:uwmedia_app/engine/mobile_engine.dart';
import 'package:uwmedia_app/engine/mobile_video_run.dart';
import 'package:uwmedia_app/engine/photo_run.dart';

/// What a build without ffmpeg says of a run only ffmpeg could do.
const noFfmpegMessage = 'This version of UWMedia has no FFmpeg for this';

/// A file's date tags (and its camera) as the app's own readers give
/// them; `null` for a file they do not read, or cannot.
MediaTags? ownTags(String path) {
  if (!hasMediaDates(path)) {
    return null;
  }
  try {
    return readFileDates(path);
  } on Object {
    return null;
  }
}

/// [FfmpegTools] answered by the runner's media engine.
class NativeFfmpegTools extends FfmpegTools {
  NativeFfmpegTools(this.engine, {required super.os})
    : super(ffmpeg: '', ffprobe: null);

  final MobileMediaEngine engine;

  @override
  Future<String> version() async => 'the media engine of this system';

  @override
  Future<Set<String>> hardwareEncoders() async => const {};

  /// The engine has one encoder; the name is not used by its runs.
  @override
  Future<String> encoder({required bool hwAccel}) async => encoderVideoToolbox;

  @override
  Future<double> duration(String path) async =>
      (await engine.probe(path)).durationSeconds;

  /// The video's bit rate, else 10 Mbit/s, as ffmpeg's.
  @override
  Future<int> bitrate(String path) async =>
      (await engine.probe(path)).bitrate ?? 10000000;

  /// The engine gives the size as the video is shown; a video stored on
  /// its side has that size here too.
  @override
  Future<(int, int)> dimensions(String path) => displayDimensions(path);

  @override
  Future<(int, int)> displayDimensions(String path) async {
    final clip = await engine.probe(path);
    return (clip.width, clip.height);
  }

  @override
  Future<int?> countedFrames(String path) async =>
      (await engine.probe(path)).frames;

  /// The frames, 0 for a file that is no video (as ffmpeg's count).
  @override
  Future<int> frameCount(String path) async {
    try {
      return (await engine.probe(path)).totalFrames;
    } on EngineException {
      return 0;
    }
  }

  /// Whether the source has more than 8 bits is the engine's own
  /// business; the runs through it do not ask.
  @override
  Future<String> pixFmt(String path) async => 'yuv420p';

  @override
  Future<double> fps(String path) async {
    try {
      return (await engine.probe(path)).frameRate;
    } on EngineException {
      return 30;
    }
  }

  @override
  Future<RgbImage?> frameAt(
    String path,
    double seconds, {
    required int width,
    required int height,
    bool hwAccel = false,
  }) => engine.frameAt(
    path,
    seconds,
    maxWidth: width,
    maxHeight: height,
    exact: true,
  );

  @override
  Future<bool> isHwDecodable(String path) async => false;

  @override
  Future<void> run(
    List<String> args, {
    EncodeProgress? progress,
    void Function(double percent)? onProgress,
    void Function(ToolRun run)? onStarted,
  }) => throw const EngineException(noFfmpegMessage);

  /// A copy as the video is, or (a size or a bit rate asked for) the
  /// engine's conversion; the source's dates either way.
  @override
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
    if (colorCorrect) {
      throw const EngineException(noFfmpegMessage);
    }
    if (targetResolution == null && (bitrate ?? '').isEmpty) {
      await engine.copy(input, output);
      copyVideoDates(input, output);
      onProgress?.call(100);
      return;
    }
    await MobileVideoRun(
      engine: engine,
      tempDir: Directory.systemTemp.createTempSync,
    ).convert(
      input: input,
      output: output,
      size: targetResolution,
      bitrate: (bitrate ?? '').isEmpty ? null : presetBitrate(bitrate!),
      onProgress: onProgress,
    );
  }

  @override
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
  }) => throw const EngineException(noFfmpegMessage);
}

/// [Exiftool] answered by the app's own readers and writers: the dates
/// and the camera of JPEG and HEIC photos and of MP4 and MOV videos
/// (spec §10.72). Every other tag is not read, and not carried over to a
/// result.
class NativeExiftool extends Exiftool {
  NativeExiftool() : super('');

  @override
  Future<RunResult?> execute(List<String> args) async => null;

  @override
  Future<MediaTags?> metadata(String path) async => ownTags(path);

  @override
  Future<Map<String, String>> tags(String path, List<String> names) async =>
      namedTags(ownTags(path), names);

  /// The date tags among [tags] written into the file where it lies; the
  /// others are not this build's to write and are passed over.
  @override
  Future<void> setTags(String path, Map<String, Object?> tags) async {
    if (tags.isEmpty || !hasMediaDates(path)) {
      return;
    }
    final video = isVideoPath(path);
    final dates = {
      for (final MapEntry(:key, :value) in tags.entries)
        if (value != null &&
            (video
                ? key.startsWith('QuickTime:') || !key.contains(':')
                : jpegDateTags.containsKey(key)))
          (video && !key.contains(':') ? 'QuickTime:$key' : key): '$value',
    };
    if (dates.isEmpty) {
      return;
    }
    final fresh = '$path.dates${p.extension(path)}';
    try {
      writeFileDatesCopy(path, dates, fresh);
      File(fresh).renameSync(path);
    } on Object catch (e) {
      try {
        File(fresh).deleteSync();
      } on FileSystemException {
        // Never written.
      }
      throw EngineException('Error writing tags', output: '$e');
    }
  }

  /// The source's dates on the result: a video's by the phones' date copy
  /// (its timezone as `CreationDate` too), a JPEG's EXIF dates. Gives a
  /// line for what could not be written.
  @override
  Future<List<String>> copyAll(
    String source,
    String dest, {
    int? forcedTzMinutes,
    List<String>? customTags,
  }) async {
    if (isVideoPath(dest)) {
      return hasMediaDates(source) && hasMediaDates(dest)
          ? copyVideoDates(source, dest)
          : const [];
    }
    final meta = ownTags(source);
    final dates = {
      for (final MapEntry(:key, :value) in (meta ?? const {}).entries)
        if (jpegDateTags.containsKey(key) && value != null) key: '$value',
    };
    if (dates.isEmpty || photoFormatOf(dest) != PhotoFormat.jpeg) {
      return const [];
    }
    try {
      final bytes = File(dest).readAsBytesSync();
      File(dest).writeAsBytesSync(writeJpegDates(bytes, dates), flush: true);
      return const [];
    } on Object catch (e) {
      return ['Warning: the dates could not be written ($e)'];
    }
  }
}

/// The tools of a desktop build without ffmpeg and exiftool.
({FfmpegTools ffmpeg, Exiftool exiftool}) storeDesktopTools(
  MobileMediaEngine engine,
  EngineOs os,
) => (ffmpeg: NativeFfmpegTools(engine, os: os), exiftool: NativeExiftool());
