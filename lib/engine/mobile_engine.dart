/// The phone's media engine (spec §2, §9; owner, 2026-11-13: native
/// engines, Media3 Transformer on Android and AVFoundation on iOS): a
/// video probed, a frame taken out of it, and a video written with a
/// downscale, the app's colour LUTs (each from its time on) and its
/// overlay pictures laid over it. The maths stays in Dart; the engine only
/// decodes, applies and encodes.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';

/// What a video is, as the runs need it.
class ClipInfo {
  const ClipInfo({
    required this.width,
    required this.height,
    required this.durationSeconds,
    this.frames,
    this.fps,
    this.bitrate,
    this.mime,
    this.hdr = false,
  });

  factory ClipInfo.fromMap(Map<Object?, Object?> map) => ClipInfo(
    width: (map['width'] as num? ?? 0).toInt(),
    height: (map['height'] as num? ?? 0).toInt(),
    durationSeconds: (map['durationMs'] as num? ?? 0) / 1000,
    frames: (map['frames'] as num?)?.toInt(),
    fps: (map['fps'] as num?)?.toDouble(),
    bitrate: (map['bitrate'] as num?)?.toInt(),
    mime: map['mime'] as String?,
    hdr: map['hdr'] == true,
  );

  /// The size the picture is shown at (turned upright).
  final int width;
  final int height;
  final double durationSeconds;

  /// The frame count the file gives, if it gives one.
  final int? frames;

  /// The frame rate; `null` when the file does not say.
  final double? fps;

  /// Bits a second of the video (the stream's, else the file's).
  final int? bitrate;
  final String? mime;

  /// An HDR (PQ or HLG) video.
  final bool hdr;

  /// The frame rate the runs count with: 30 when the file has none, as
  /// Python's frame-step fallback.
  double get frameRate => fps != null && fps! > 0 ? fps! : 30;

  /// The number of frames: the file's count, else its length at its rate.
  int get totalFrames => frames ?? (durationSeconds * frameRate).truncate();
}

/// One colour LUT of a run, applied from [seconds] on.
typedef TimedLut = ({double seconds, Uint8List lut});

/// One picture of an overlay layer, shown from [seconds] on.
typedef OverlayPicture = ({String path, double seconds});

/// An overlay layer: its pictures in time order, with their top-left
/// corner at ([x], [y]) pixels of the frame.
typedef OverlayLayer = ({int x, int y, List<OverlayPicture> pictures});

/// What an encode is asked to do.
class EncodeJob {
  const EncodeJob({
    required this.input,
    required this.output,
    required this.frameWidth,
    required this.frameHeight,
    this.fit,
    this.crop,
    this.h264 = false,
    this.bitrate,
    this.luts = const [],
    this.lutFade = 0,
    this.layers = const [],
    this.toneMap = false,
    this.part,
  });

  /// The part of the video written; `null` for all of it. The times of
  /// [luts] and of the [layers]' pictures count from its start.
  final ClipPart? part;

  final String input;
  final String output;

  /// The source's upright size. The layers are placed on it, or on what
  /// [crop] leaves of it; [fit] comes after them.
  final int frameWidth;
  final int frameHeight;

  /// The size to scale the video to fit in, padded (a conversion).
  final (int, int)? fit;

  /// The part of the upright source kept, before [fit] (a copy for
  /// sharing, cropped to portrait).
  final ({int x, int y, int width, int height})? crop;

  /// H.264 instead of HEVC (a copy for sharing).
  final bool h264;

  /// Bits a second; `null` leaves it to the encoder.
  final int? bitrate;
  final List<TimedLut> luts;

  /// How many seconds before a LUT's time the one before it starts
  /// turning into it; 0 switches at once.
  final double lutFade;
  final List<OverlayLayer> layers;

  /// The source's HDR seen by the probe. The engine turns an HDR source
  /// to SDR whenever a LUT or an overlay is applied; this records it.
  final bool toneMap;

  Map<String, Object?> toMap() => {
    'input': input,
    'output': output,
    'frameWidth': frameWidth,
    'frameHeight': frameHeight,
    if (fit != null) ...{'width': fit!.$1, 'height': fit!.$2},
    if (crop != null)
      'crop': {
        'x': crop!.x,
        'y': crop!.y,
        'width': crop!.width,
        'height': crop!.height,
      },
    if (h264) 'codec': 'h264',
    'bitrate': bitrate,
    if (part != null) ...{'start': part!.start, 'end': part!.end},
    'toneMap': toneMap,
    'lutSize': lutSize,
    'lutFade': lutFade,
    'luts': [
      for (final lut in luts) {'seconds': lut.seconds, 'lut': lut.lut},
    ],
    'layers': [
      for (final layer in layers)
        {
          'x': layer.x,
          'y': layer.y,
          'pictures': [
            for (final picture in layer.pictures)
              {'path': picture.path, 'seconds': picture.seconds},
          ],
        },
    ],
  };
}

/// A part of a video, in seconds from its start.
typedef ClipPart = ({double start, double end});

/// How an encode went.
typedef EncodeResult = ({
  Duration time,
  int bytes,
  String? mime,
  String? encoder,
});

abstract interface class MobileMediaEngine {
  /// The video at [path]. Throws an [EngineException] for a file that is
  /// no video.
  Future<ClipInfo> probe(String path);

  /// The frame at [seconds], upright and no bigger than [maxWidth] by
  /// [maxHeight]; `null` when there is none. Without [exact] it may be the
  /// key frame nearest to that time (much faster on a 4K clip; Android,
  /// and an HDR clip on iOS). On iOS its colours are read as the
  /// desktop's frame grab reads them (BT.601, spec §10.30).
  Future<RgbImage?> frameAt(
    String path,
    double seconds, {
    required int maxWidth,
    required int maxHeight,
    bool exact = false,
  });

  /// Writes [job]. [onProgress] hears the percent done; [onRestart] that
  /// the encode started again from the beginning (iOS takes an export
  /// away when the screen locks, and the engine starts it again once the
  /// app is back). Throws [RunStopped] after [cancel] and an
  /// [EngineException] when the encode fails.
  Future<EncodeResult> encode(
    EncodeJob job, {
    void Function(double percent)? onProgress,
    void Function()? onRestart,
  });

  /// Stops the encode going on.
  Future<void> cancel();

  /// Starts a video of pictures the app draws ([framesAdd], then
  /// [framesClose]) at [output]: [width] by [height] at [fps], as ProRes
  /// 4444 with its transparency ([prores]) or as HEVC. Only the Apple
  /// engine has it (the Overlay Generator on a Mac); throws an
  /// [EngineException] where there is none.
  Future<void> framesOpen({
    required String output,
    required int width,
    required int height,
    required double fps,
    required bool prores,
  });

  /// [rgba] ([framesOpen]'s size, the alpha not multiplied in) as the
  /// next [count] frames.
  Future<void> framesAdd(Uint8List rgba, int count);

  /// Ends the video and writes its index.
  Future<void> framesClose();

  /// Gives the video up and removes what was written of it.
  Future<void> framesCancel();

  /// The video and its sound at [input] as they are, written to [output]
  /// in a file of its ending's type (MP4, or MOV). Only the Apple engine
  /// has it (a Mac's run of a video it changes nothing in); throws an
  /// [EngineException] where there is none, or when the file cannot hold
  /// the video.
  Future<void> copy(String input, String output);
}

/// How far the percent of an encode drops when the engine starts it
/// again, at least.
const restartDrop = 10;

/// The engine in the app's runner (`MediaEngine.kt`).
class PlatformMediaEngine implements MobileMediaEngine {
  const PlatformMediaEngine();

  static const _channel = MethodChannel('uwmedia/media_engine');

  @override
  Future<ClipInfo> probe(String path) async {
    try {
      final map = await _channel.invokeMapMethod<Object?, Object?>('probe', {
        'path': path,
      });
      return ClipInfo.fromMap(map!);
    } on PlatformException catch (e) {
      throw EngineException('Could not read the video: ${e.message}');
    }
  }

  @override
  Future<RgbImage?> frameAt(
    String path,
    double seconds, {
    required int maxWidth,
    required int maxHeight,
    bool exact = false,
  }) async {
    final Map<Object?, Object?>? map;
    try {
      map = await _channel.invokeMapMethod<Object?, Object?>('frameAt', {
        'path': path,
        'seconds': seconds,
        'maxWidth': maxWidth,
        'maxHeight': maxHeight,
        'exact': exact,
      });
    } on PlatformException {
      return null;
    }
    if (map == null) {
      return null;
    }
    final width = map['width']! as int;
    final height = map['height']! as int;
    return RgbImage(width, height, rgbOfRgba(map['rgba']! as Uint8List));
  }

  @override
  Future<EncodeResult> encode(
    EncodeJob job, {
    void Function(double percent)? onProgress,
    void Function()? onRestart,
  }) async {
    Timer? poll;
    if (onProgress != null || onRestart != null) {
      var last = 0;
      poll = Timer.periodic(const Duration(milliseconds: 500), (_) async {
        final percent = await _channel.invokeMethod<int>('progress');
        if (percent == null || !(poll?.isActive ?? false)) {
          return;
        }
        // An encode only goes forward: a percent well below the last one
        // is the engine starting it again.
        if (percent + restartDrop < last) {
          onRestart?.call();
        }
        last = percent;
        onProgress?.call(percent.toDouble());
      });
    }
    try {
      final map = await _channel.invokeMapMethod<Object?, Object?>(
        'encode',
        job.toMap(),
      );
      return (
        time: Duration(milliseconds: (map!['ms']! as num).toInt()),
        bytes: (map['bytes']! as num).toInt(),
        mime: map['mime'] as String?,
        encoder: map['encoder'] as String?,
      );
    } on PlatformException catch (e) {
      if (e.code == 'cancelled') {
        throw const RunStopped();
      }
      throw EngineException('${e.message}');
    } finally {
      poll?.cancel();
    }
  }

  @override
  Future<void> cancel() => _channel.invokeMethod<void>('cancel');

  // The quality of an HEVC video of drawn frames, where ffmpeg is given
  // `-q:v 65` (`qualityArgs`).
  static const _framesQuality = 0.65;

  Future<T?> _frames<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      throw EngineException('${e.message}');
    } on MissingPluginException {
      throw const EngineException('This engine writes no video of pictures');
    }
  }

  @override
  Future<void> framesOpen({
    required String output,
    required int width,
    required int height,
    required double fps,
    required bool prores,
  }) => _frames<void>('framesOpen', {
    'output': output,
    'width': width,
    'height': height,
    'fps': fps,
    'codec': prores ? 'prores4444' : 'hevc',
    if (!prores) 'quality': _framesQuality,
  });

  @override
  Future<void> framesAdd(Uint8List rgba, int count) =>
      _frames<void>('framesAdd', {'rgba': rgba, 'count': count});

  @override
  Future<void> framesClose() => _frames<void>('framesClose');

  @override
  Future<void> framesCancel() => _frames<void>('framesCancel');

  @override
  Future<void> copy(String input, String output) async {
    try {
      await _channel.invokeMethod<void>('copy', {
        'input': input,
        'output': output,
      });
    } on PlatformException catch (e) {
      throw EngineException('${e.message}');
    } on MissingPluginException {
      throw const EngineException('This engine copies no video');
    }
  }
}

/// RGB bytes of RGBA ones (the alpha dropped).
Uint8List rgbOfRgba(Uint8List rgba) {
  final rgb = Uint8List(rgba.length ~/ 4 * 3);
  var o = 0;
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    rgb[o++] = rgba[i];
    rgb[o++] = rgba[i + 1];
    rgb[o++] = rgba[i + 2];
  }
  return rgb;
}
