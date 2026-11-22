/// The ffmpeg and ffprobe command lines of the desktop engine (Python
/// `ffmpeg/ffmpeg_class.py`, the ffmpeg half of `ffmpeg/color.py` and
/// `ffmpeg/overlay_output.py`; spec §2): which encoder, the arguments of
/// each kind of run, and how ffprobe's answers are read. Nothing is run
/// here; the engine that starts the processes is the caller.
library;

import 'dart:typed_data';

import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/engine/share_sizes.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';

/// The system the engine runs on, as far as the commands differ.
enum EngineOs { macos, windows, linux }

const encoderSoftware = 'libx265';
const encoderVideoToolbox = 'hevc_videotoolbox';
const encoderNvenc = 'hevc_nvenc';
const encoderAmf = 'hevc_amf';
const encoderQsv = 'hevc_qsv';

/// The hardware encoders Windows is asked for, in order (spec §10.1:
/// Python only tries NVENC).
const windowsHardwareEncoders = [encoderNvenc, encoderAmf, encoderQsv];

/// A clip is sampled for its colour every this many seconds.
const sampleSeconds = 2;

/// The share of a file's progress spent before the encode: the colour
/// analysis, then (with overlays) drawing the layers.
const analysisProgressEnd = 10.0;
const hudProgressEnd = 14.0;

/// The longest command the app gives ffmpeg with its filters written on
/// it (spec §10.79): Windows takes 32,767 characters in all, and a clip
/// whose colour changes often has a LUT of about 160 characters for each
/// change. A longer command has its filters read from files.
const maxCommandChars = 8000;

/// About the characters of a command line of [args]: each with a space
/// and the quotes it may need.
int commandChars(List<String> args) =>
    args.fold(0, (sum, arg) => sum + arg.length + 3);

// The options whose value is a filter graph, and the older options that
// take the same graph from a file (gone in ffmpeg 8 and later).
const _filterScripts = {
  '-vf': '-filter_script:v',
  '-filter:v': '-filter_script:v',
  '-af': '-filter_script:a',
  '-filter:a': '-filter_script:a',
  '-filter_complex': '-filter_complex_script',
  '-lavfi': '-filter_complex_script',
};

/// Whether the ffmpeg of [versionLine] (the first line of `ffmpeg
/// -version`) reads an option's value from a file as `-/option file`,
/// as ffmpeg 7.0 and later do. A version that cannot be read (a build
/// from git, "N-118000-g…") is taken to be a new one.
bool readsOptionFiles(String versionLine) {
  final major = RegExp(r'version\s+n?(\d+)\.').firstMatch(versionLine);
  return major == null || int.parse(major.group(1)!) >= 7;
}

/// [args] with each filter graph read from a file when the command is
/// longer than [maxChars]: [write] puts a graph into a file and gives its
/// path. With [optionFiles] as `-/vf file` (ffmpeg 7.0 on), else with the
/// older `-filter_script:v file`. A short command is given back as it is.
List<String> filtersFromFiles(
  List<String> args,
  String Function(String graph) write, {
  required bool optionFiles,
  int maxChars = maxCommandChars,
}) {
  if (commandChars(args) <= maxChars) {
    return args;
  }
  final out = <String>[];
  for (var i = 0; i < args.length; i++) {
    final script = _filterScripts[args[i]];
    if (script == null || i + 1 >= args.length) {
      out.add(args[i]);
      continue;
    }
    out
      ..add(optionFiles ? '-/${args[i].substring(1)}' : script)
      ..add(write(args[i + 1]));
    i++;
  }
  return out;
}

/// The bit rate assumed when ffprobe knows none.
const defaultBitrate = 10000000;

/// The HEVC encoder for a run: the software one without hardware
/// acceleration; VideoToolbox on macOS; on Windows the first of
/// [windowsHardwareEncoders] that [available] says opens here (found by a
/// test encode, [encoderProbeArgs]), else the software one; the software
/// one elsewhere.
String chooseEncoder({
  required bool hwAccel,
  required EngineOs os,
  Set<String> available = const {},
}) {
  if (!hwAccel) {
    return encoderSoftware;
  }
  if (os == EngineOs.macos) {
    return encoderVideoToolbox;
  }
  if (os == EngineOs.windows) {
    return windowsHardwareEncoders.where(available.contains).firstOrNull ??
        encoderSoftware;
  }
  return encoderSoftware;
}

/// The arguments of a one-frame test encode that tells whether [encoder]
/// opens on this machine (a PC without the matching GPU cannot, and every
/// encode would fail).
List<String> encoderProbeArgs(String encoder) => [
  '-hide_banner',
  '-loglevel',
  'error',
  '-f',
  'lavfi',
  '-i',
  'color=c=black:s=256x256:d=0.1',
  '-frames:v',
  '1',
  '-c:v',
  encoder,
  '-f',
  'null',
  '-',
];

/// Constant-quality flags for [encoder], for renders with no source bit
/// rate to keep (the telemetry-only videos). `-crf` is the software
/// encoder's only; VideoToolbox takes `-q:v`, the others their own
/// constant-quality rate control.
List<String> qualityArgs(String encoder) => switch (encoder) {
  encoderVideoToolbox => ['-q:v', '65'],
  encoderNvenc => ['-rc', 'vbr', '-cq', '20', '-b:v', '0'],
  encoderAmf => ['-rc', 'cqp', '-qp_i', '20', '-qp_p', '20'],
  encoderQsv => ['-global_quality', '20'],
  _ => ['-crf', '18'],
};

// --- ffprobe ---------------------------------------------------------------

const _plainValue = 'default=noprint_wrappers=1:nokey=1';

List<String> _probe(List<String> middle, String path) => [
  '-v',
  'error',
  ...middle,
  path,
];

List<String> probeDurationArgs(String path) =>
    _probe(['-show_entries', 'format=duration', '-of', _plainValue], path);

List<String> probeStreamBitrateArgs(String path) => _probe([
  '-select_streams',
  'v:0',
  '-show_entries',
  'stream=bit_rate',
  '-of',
  _plainValue,
], path);

List<String> probeFormatBitrateArgs(String path) =>
    _probe(['-show_entries', 'format=bit_rate', '-of', _plainValue], path);

List<String> probeDimensionsArgs(String path) => _probe([
  '-select_streams',
  'v:0',
  '-show_entries',
  'stream=width,height',
  '-of',
  'csv=s=x:p=0',
], path);

/// The stored size and the rotation the file asks a player for; see
/// [parseDisplayDimensions].
List<String> probeDisplayDimensionsArgs(String path) => _probe([
  '-select_streams',
  'v:0',
  '-show_entries',
  'stream=width,height:stream_side_data=rotation',
  '-of',
  'default=noprint_wrappers=1',
], path);

List<String> probeFrameCountArgs(String path) => _probe([
  '-select_streams',
  'v:0',
  '-show_entries',
  'stream=nb_frames',
  '-of',
  _plainValue,
], path);

/// The video's frame rates: the average over the file and the stream's
/// own, a line each (`avg_frame_rate=30000/1001`).
List<String> probeFpsArgs(String path) => [
  '-v',
  'error',
  '-select_streams',
  'v:0',
  '-show_entries',
  'stream=avg_frame_rate,r_frame_rate',
  '-of',
  'default=noprint_wrappers=1',
  path,
];

/// Frames a second from [probeFpsArgs]' answer: the average rate, else
/// the stream's own, else 30 (what the Python app's OpenCV reader gives
/// the colour run, and its fallback).
double parseFps(String? output) {
  final rates = <String, double>{};
  for (final line in (output ?? '').split(RegExp(r'\s+'))) {
    final eq = line.indexOf('=');
    if (eq < 0) {
      continue;
    }
    final parts = line.substring(eq + 1).split('/');
    final top = pyFloat(parts[0]);
    final bottom = parts.length > 1 ? pyFloat(parts[1]) : 1.0;
    if (top != null && bottom != null && top > 0 && bottom > 0) {
      rates[line.substring(0, eq)] = top / bottom;
    }
  }
  return rates['avg_frame_rate'] ?? rates['r_frame_rate'] ?? 30.0;
}

/// One frame of the source as raw RGB on standard output: the frame at
/// [seconds], scaled to [width] by [height] by averaging the pixels each
/// output pixel covers. The frame is turned into RGB before it is scaled,
/// as OpenCV's read and resize in the Python app do: scaled in YUV, a
/// reduced frame differs by up to 165 levels at sharp colour edges, enough
/// to move the colour analysis. Like OpenCV it turns YUV into RGB with
/// the BT.601 matrix whatever the clip is tagged with: read as BT.709, a
/// camera's clip came out up to 2 levels apart on average and its filter
/// 0.07 apart (spec §10.30). With [hwAccel] that system's hardware
/// decodes the frame, which gives the same picture.
List<String> frameGrabArgs(
  String input,
  double seconds, {
  required int width,
  required int height,
  EngineOs? hwAccel,
}) => [
  '-nostdin',
  '-loglevel',
  'error',
  if (hwAccel != null) ...[
    '-hwaccel',
    hwAccel == EngineOs.macos ? 'videotoolbox' : 'auto',
  ],
  '-ss',
  pyFormatFixed(seconds, 6),
  '-i',
  input,
  '-frames:v',
  '1',
  '-vf',
  'scale=in_color_matrix=bt601,format=rgb24,scale=$width:$height:flags=area',
  '-f',
  'rawvideo',
  '-pix_fmt',
  'rgb24',
  '-',
];

/// The size the colour analysis looks at a frame in: halved until a side
/// is 200 px or less (as `ColorEngine.reduced`).
(int, int) analysisSize(int width, int height) {
  var scale = 1;
  while (width / scale > 200 && height / scale > 200) {
    scale *= 2;
  }
  return (width ~/ scale, height ~/ scale);
}

List<String> probePixFmtArgs(String path) => _probe([
  '-select_streams',
  'v:0',
  '-show_entries',
  'stream=pix_fmt',
  '-of',
  _plainValue,
], path);

List<String> probeCodecArgs(String path) => _probe([
  '-select_streams',
  'v:0',
  '-show_entries',
  'stream=codec_name,pix_fmt',
  '-of',
  'default=noprint_wrappers=1',
], path);

/// Asks for the file's major brand ("XAVC" for a Sony camera's, "isom",
/// "mp42", "qt  ").
List<String> probeBrandArgs(String path) => _probe([
  '-show_entries',
  'format_tags=major_brand',
  '-of',
  _plainValue,
], path);

final _digits = RegExp(r'^[0-9]+$');

/// The first line of a one-value probe's answer, stripped; empty when
/// there is none. ffprobe 9 lists a stream again for each stream group it
/// belongs to (a DJI camera's video, for one), so `v:0` can answer twice
/// (`3840x2160`, a blank line, `3840x2160`); Python reads the whole
/// answer as one value and fails there (spec §10.53).
String firstProbeLine(String? output) {
  for (final line in (output ?? '').split('\n')) {
    final text = line.pyStrip();
    if (text.isNotEmpty) {
      return text;
    }
  }
  return '';
}

/// The duration in seconds from [probeDurationArgs]' answer; `null` when
/// it is not a number (Python raises).
double? parseDuration(String output) => pyFloat(output);

/// Whether the stream's bit rate answer has to be asked again of the
/// format ([probeFormatBitrateArgs]).
bool bitrateNeedsFormat(String output) {
  final text = firstProbeLine(output);
  return text.isEmpty || text == 'N/A';
}

/// The bit rate from the stream's or the format's answer; 10 Mbit/s when
/// it is not a whole number.
int parseBitrate(String output) {
  final text = firstProbeLine(output);
  return _digits.hasMatch(text) ? int.parse(text) : defaultBitrate;
}

/// Width and height from [probeDimensionsArgs]' answer; `null` when it is
/// not two whole numbers with an x between.
(int, int)? parseDimensions(String output) {
  final parts = firstProbeLine(output).split('x').map(pyInt).toList();
  return parts.length >= 2 && parts[0] != null && parts[1] != null
      ? (parts[0]!, parts[1]!)
      : null;
}

/// Width and height as the video is shown, from
/// [probeDisplayDimensionsArgs]' answer: the stored size, turned when the
/// file carries a quarter turn (a phone's upright video is stored lying
/// down). ffmpeg turns the picture before its filters, so this is the
/// size a filter sees. `null` when the size is not there.
(int, int)? parseDisplayDimensions(String output) {
  final values = <String, String>{};
  for (final line in output.split('\n')) {
    final eq = line.indexOf('=');
    if (eq > 0) {
      values.putIfAbsent(
        line.substring(0, eq).pyStrip(),
        () => line.substring(eq + 1).pyStrip(),
      );
    }
  }
  final w = pyInt(values['width'] ?? '');
  final h = pyInt(values['height'] ?? '');
  if (w == null || h == null) {
    return null;
  }
  final turn = double.tryParse(values['rotation'] ?? '') ?? 0;
  return turn.round().abs() % 180 == 90 ? (h, w) : (w, h);
}

/// The number of frames from [probeFrameCountArgs]' answer, or `null` when
/// the file does not say; then [framesFromDuration] stands in.
int? parseFrameCount(String? output) {
  final text = firstProbeLine(output);
  return _digits.hasMatch(text) ? int.parse(text) : null;
}

/// The frame count guessed from the duration at 30 frames a second, as
/// Python does when the file has no count (spec §10.3); 0 without a
/// duration.
int framesFromDuration(double? duration) =>
    duration == null || !duration.isFinite ? 0 : (duration * 30.0).truncate();

/// False for sources hardware decoders cannot take: H.264 beyond 8-bit
/// 4:2:0 (Sony's 10-bit 4:2:2 XAVC, for one). VideoToolbox does not fall
/// back to software for those; it fails picture by picture and ffmpeg
/// drops the frames. [output] is [probeCodecArgs]' answer, `null` when the
/// probe failed (then the source counts as decodable).
///
/// On a Mac ([os]) a Sony camera's H.264 is not taken either (spec
/// §10.73): with ffmpeg 9 VideoToolbox lost 90 of the 2832 frames of an
/// 8-bit 4:2:0 XAVC S clip (4K at 50 frames a second and 150 Mbit/s) the
/// same way, and decoded it at 65 frames a second where ffmpeg's own
/// decoder did 150 and lost none. [brand] is the file's major brand
/// ([probeBrandArgs]' answer; "XAVC" for those); other H.264 of 8-bit
/// 4:2:0 decoded whole there (made-up clips up to 4K at 50 frames a
/// second and 120 Mbit/s). A source whose probe failed is not taken on a
/// Mac.
bool hwDecodable(String? output, {EngineOs? os, String? brand}) {
  if (output == null) {
    return os != EngineOs.macos;
  }
  final info = <String, String>{};
  for (final item in output.split(RegExp(r'\s+'))) {
    final eq = item.indexOf('=');
    if (eq != -1) {
      info[item.substring(0, eq)] = item.substring(eq + 1);
    }
  }
  if (os == EngineOs.macos &&
      info['codec_name'] == 'h264' &&
      (brand ?? '').trim().toUpperCase() == 'XAVC') {
    return false;
  }
  return !(info['codec_name'] == 'h264' &&
      !const ['yuv420p', 'yuvj420p', 'nv12'].contains(info['pix_fmt']));
}

// The arguments that have the source decoded by [os]'s hardware.
List<String> _hwDecodeArgs(EngineOs? os) => os == null
    ? const []
    : ['-hwaccel', os == EngineOs.macos ? 'videotoolbox' : 'auto'];

/// Whether a pixel format has more than 8 bits, so that the run keeps 10
/// bits (output `p010le`, the overlay blended in `yuv420p10`).
///
/// Python looks for "10" or "12" anywhere in the name, which also takes
/// `nv12`, an 8-bit format, for one; here `nv12` and `nv21` are 8-bit
/// (spec §10.26).
bool isTenBit(String pixFmt) =>
    pixFmt != 'nv12' && (pixFmt.contains('10') || pixFmt.contains('12'));

// --- Shared pieces ------------------------------------------------------------

/// The `-metadata creation_time=` arguments that carry a file's local
/// time and its offset; none without an offset.
List<String> creationTimeArgs(DateTime creationDate, int? tzOffsetMins) {
  assert(creationDate.isUtc, naiveTimeMessage);
  if (tzOffsetMins == null) {
    return const [];
  }
  final size = tzOffsetMins.abs();
  final zone =
      '${tzOffsetMins >= 0 ? '+' : '-'}'
      '${(size ~/ 60).toString().padLeft(2, '0')}'
      '${(size % 60).toString().padLeft(2, '0')}';
  return [
    '-metadata',
    'creation_time=${pyStrftime(creationDate, '%Y-%m-%dT%H:%M:%S')}$zone',
  ];
}

const _tagging = [
  '-map_metadata',
  '0',
  '-movflags',
  '+faststart+use_metadata_tags',
  '-tag:v',
  'hvc1',
  '-color_primaries',
  '1',
  '-color_trc',
  '1',
  '-colorspace',
  '1',
];

/// A command to run, and what its progress is measured against.
typedef FfmpegRun = ({List<String> args, double duration});

/// The convert and passthrough command (Python
/// `FfmpegClass.process_video`). With no change asked for (no size, no bit
/// rate, no colour) the streams are copied and only the date is written;
/// otherwise the video is encoded with [encoder], scaled into
/// [targetResolution] (keeping its shape, padded), at [bitrate] or else at
/// the [sourceBitrate] (left out when unknown). [duration] is ffprobe's,
/// in seconds.
FfmpegRun processVideoArgs({
  required String input,
  required String output,
  required DateTime creationDate,
  required double duration,
  required String encoder,
  bool colorCorrect = false,
  int? tzOffsetMins,
  (int, int)? targetResolution,
  String? bitrate,
  int? sourceBitrate,
  EngineOs? hwDecode,
}) {
  final hasBitrate = (bitrate ?? '').isNotEmpty;
  final filter = switch (targetResolution) {
    (final w, final h) =>
      'scale=$w:$h:force_original_aspect_ratio=decrease,'
          'pad=$w:$h:(ow-iw)/2:(oh-ih)/2',
    null => null,
  };
  final date = creationTimeArgs(creationDate, tzOffsetMins);
  final seconds = duration.truncateToDouble();
  if (filter == null && !hasBitrate && !colorCorrect) {
    return (
      args: [
        '-y',
        '-i',
        input,
        // Video and sound, and subtitles when there are any; data streams
        // the container cannot take are left behind.
        '-c',
        'copy',
        '-map',
        '0:v',
        '-map',
        '0:a?',
        '-map',
        '0:s?',
        '-map_metadata',
        '0',
        ...date,
        '-movflags',
        '+faststart+use_metadata_tags',
        output,
      ],
      duration: seconds,
    );
  }
  return (
    args: [
      '-y',
      // The source decoded by hardware when asked for (spec §10.73; the
      // Python app's convert decodes in software).
      ..._hwDecodeArgs(hwDecode),
      '-i',
      input,
      if (filter != null) ...['-filter_complex', filter],
      '-vcodec',
      encoder,
      if (hasBitrate) ...[
        '-b:v',
        bitrate!,
      ] else if (sourceBitrate != null) ...[
        '-b:v',
        '$sourceBitrate',
      ],
      ..._tagging,
      ...date,
      '-acodec',
      'copy',
      '-pix_fmt',
      'yuv420p',
      output,
    ],
    duration: seconds,
  );
}

/// The H.264 encoder that goes with the HEVC [encoder] a run would use
/// (the same hardware), for the copies made for sharing.
String h264EncoderFor(String encoder) => switch (encoder) {
  encoderVideoToolbox => 'h264_videotoolbox',
  encoderNvenc => 'h264_nvenc',
  encoderAmf => 'h264_amf',
  encoderQsv => 'h264_qsv',
  _ => 'libx264',
};

/// The picture filter of a copy for sharing: the crop when there is one,
/// then the scale to [frame]'s size, between bars when the shapes differ
/// by more than rounding. [sourceW] by [sourceH] is the source's picture.
String shareFilter(ShareFrame frame, int sourceW, int sourceH) =>
    [?cropFilter(frame), fitFilter(frame, sourceW, sourceH)].join(',');

/// The crop of [frame] as a filter; `null` when it keeps the whole
/// picture.
String? cropFilter(ShareFrame frame) {
  final crop = frame.crop;
  return crop == null
      ? null
      : 'crop=${crop.width}:${crop.height}:${crop.x}:${crop.y}';
}

/// The scale to [frame]'s size of what is left of a [sourceW] by
/// [sourceH] picture after [cropFilter], between bars when the shapes
/// differ by more than rounding.
String fitFilter(ShareFrame frame, int sourceW, int sourceH) {
  final crop = frame.crop;
  final w = crop?.width ?? sourceW;
  final h = crop?.height ?? sourceH;
  final sameShape = (w / h - frame.width / frame.height).abs() < 0.01;
  return [
    if (sameShape)
      'scale=${frame.width}:${frame.height}'
    else ...[
      'scale=${frame.width}:${frame.height}:force_original_aspect_ratio=decrease',
      'pad=${frame.width}:${frame.height}:(ow-iw)/2:(oh-ih)/2',
    ],
    'setsar=1',
  ].join(',');
}

/// The command of a copy for sharing (spec §10.49): [frame]'s picture as
/// H.264 with [encoder] at the frame's bit rate, the sound as AAC, in an
/// MP4 with the source's date.
FfmpegRun shareVideoArgs({
  required String input,
  required String output,
  required DateTime creationDate,
  required double duration,
  required String encoder,
  required ShareFrame frame,
  required int sourceWidth,
  required int sourceHeight,
  int? tzOffsetMins,
  EngineOs? hwDecode,
}) => (
  args: [
    '-y',
    ..._hwDecodeArgs(hwDecode),
    '-i',
    input,
    '-filter_complex',
    shareFilter(frame, sourceWidth, sourceHeight),
    '-vcodec',
    encoder,
    '-b:v',
    '${frame.bitrate}',
    '-map_metadata',
    '0',
    '-movflags',
    '+faststart+use_metadata_tags',
    '-color_primaries',
    '1',
    '-color_trc',
    '1',
    '-colorspace',
    '1',
    ...creationTimeArgs(creationDate, tzOffsetMins),
    '-acodec',
    'aac',
    '-b:a',
    '128k',
    '-pix_fmt',
    'yuv420p',
    output,
  ],
  duration: duration.truncateToDouble(),
);

// --- Colour and overlay runs ----------------------------------------------------

/// How many frames lie between two analysed ones.
int sampleStep(double fps) {
  final step = (fps * sampleSeconds).truncate();
  return step <= 0 ? 30 : step;
}

/// The frames a clip's colour is analysed at: one every [sampleSeconds],
/// and the last frame.
List<int> sampleFrames(double fps, int totalFrames) {
  final step = sampleStep(fps);
  final frames = [for (var i = 0; i < totalFrames; i += step) i];
  if (totalFrames > 0 && frames.last != totalFrames - 1) {
    frames.add(totalFrames - 1);
  }
  return frames;
}

/// A path the way an ffmpeg filter argument wants it: forward slashes, and
/// the colon of a drive letter escaped.
String filterPath(String path) =>
    path.replaceAll(r'\', '/').replaceAll(':', r'\:');

/// The LUT file of the [index]-th distinct filter, in [lutDir].
String lutFileName(int index) => 'lut_${index.toString().padLeft(4, '0')}.cube';

/// The file of the colour tables a clip's colour fades through, in the
/// LUT folder: raw pictures of [haldLevel]³ squared pixels of three bytes,
/// one after the other.
const lutTablesFileName = 'lut_tables.raw';

/// The side of the colour table (ffmpeg's Hald CLUT) the fade is mixed
/// on: a level's square is the LUT's size, so each of its points is one
/// of the LUT's own, and a LUT's bytes (red fastest) are the table's
/// picture as they stand.
const haldLevel = 8;

/// The colour correction of a clip as an ffmpeg filter: which of the
/// sampled filters get a LUT of their own (each that is not close to the
/// one kept before it), and the `-vf` value that applies them. One LUT is
/// one `lut3d` of a `.cube` file. Several are alone from their frames on
/// (the first from the start), and over the [sampleStep] before its
/// frame the LUT before turns into each: the colour fades instead of
/// jumping, as on the phones (spec §10.60).
///
/// ffmpeg has no filter that mixes two LUTs, so the fade is mixed on
/// colour tables (Hald CLUTs with the LUT's own points, so nothing is
/// lost) and one `haldclut` puts each frame's table on the picture
/// (spec §10.64). The tables are the pictures of a raw video, one for
/// every [sampleStep] of the clip ([tables]: the LUT of each, the last
/// twice), read
/// while the clip is: no LUT is named in the filter and none waits in
/// memory (spec §10.66). Each is held for a step, a second stream of
/// them runs one table ahead, and `maskedmerge` mixes the two by a grey
/// picture that goes from black to white over the step. The three
/// streams count frames at [sampleStep] a second, so a table changes on
/// the very frame the grey starts again; the mixed tables get the clip's
/// times after that (half a frame early, so that a frame's own time,
/// however it is rounded, lies behind its table's), and the last stays
/// to the clip's end, the grey going on without an end. A LUT whose
/// frame is not a step's first (the clip's last frame) stands at the
/// next step, which the clip ends on
/// its way to. `haldclut` reads a planar picture's channels in the wrong
/// order (ffmpeg 9.0), so the picture goes in packed. Python switches
/// with `sendcmd`, which ffmpeg's `lut3d` refuses, so there the first
/// LUT stays for the whole clip (spec §10.56).
///
/// The value stands as one link of a chain too (the overlay run's): it
/// starts with a filter that takes the chain's picture and ends with the
/// one that gives it on.
///
/// The caller writes into [lutDir] (which has the system's separator at
/// its end or none) the one LUT as `lut_0000.cube`, or, when there are
/// [tables], the LUTs they name as [lutTablesFileName].
({List<(int frame, Float32List filter)> luts, String vf, List<int>? tables})
lut3dFilter({
  required List<int> frameIndices,
  required List<Float32List> filters,
  required double fps,
  required String lutDir,
  String separator = '/',
}) {
  if (filters.isEmpty) {
    throw ArgumentError('No frame of the clip was analysed');
  }
  final luts = distinctFilters(frameIndices, filters);
  String file(String name) {
    final path = lutDir.endsWith(separator)
        ? '$lutDir$name'
        : '$lutDir$separator$name';
    return "'${filterPath(path)}'";
  }

  if (luts.length == 1) {
    return (
      luts: luts,
      vf: 'lut3d=file=${file(lutFileName(0))}:interp=trilinear',
      tables: null,
    );
  }

  final step = sampleStep(fps);
  // The step each LUT stands at, and the LUT of each step up to the
  // last one's.
  final tables = <int>[];
  for (var i = 1; i < luts.length; i++) {
    final at = (luts[i].$1 + step - 1) ~/ step;
    while (tables.length < at) {
      tables.add(i - 1);
    }
  }
  // The last twice: ffmpeg's `fps` gives a stream's last picture no time.
  tables
    ..add(luts.length - 1)
    ..add(luts.length - 1);

  const side = haldLevel * haldLevel * haldLevel;
  // The grey of a frame: how far its step has come.
  final share = '65535*mod(N,$step)/$step';
  return (
    luts: luts,
    // The picture, packed; the tables, a step each, and the same a table
    // ahead; the grey; the two mixed, kept to the end, at the clip's
    // times; the table put on the picture.
    vf:
        'format=rgb24|rgb48le[lm];'
        'movie=filename=${file(lutTablesFileName)}:f=rawvideo:'
        "format_opts='video_size=${side}x$side\\:pixel_format=rgb24"
        "\\:framerate=1',fps=$step,format=gbrp16le,split[la][lb];"
        '[lb]trim=start_frame=$step,setpts=PTS-STARTPTS[ld];'
        'color=s=16x16:r=$step,format=gbrp16le,'
        "geq=r='$share':g='$share':b='$share',"
        'scale=$side:$side:flags=neighbor[lw];'
        '[la][ld][lw]maskedmerge,'
        'settb=1/1000000,setpts=(N-0.5)/($fps*TB),format=rgb48le[lt];'
        '[lm][lt]haldclut=interp=trilinear:shortest=1',
    tables: tables,
  );
}

/// The arguments before the source of a colour or overlay run: quiet
/// unless [debug], and the source decoded by hardware when the run uses
/// it and the decoder can take the source ([hwDecodable]).
List<String> colorInputArgs({
  required bool debug,
  required bool hwAccel,
  required bool sourceHwDecodable,
  required EngineOs os,
}) => [
  '-y',
  if (!debug) ...['-nostats', '-loglevel', 'error'],
  if (hwAccel && sourceHwDecodable) ...[
    '-hwaccel',
    os == EngineOs.macos ? 'videotoolbox' : 'auto',
  ],
];

/// The arguments before a source of which only the part from [start] to
/// [end] seconds is read (spec §10.75).
List<String> partInputArgs(double start, double end) => [
  '-ss',
  start.toStringAsFixed(3),
  '-t',
  (end - start).toStringAsFixed(3),
];

/// The arguments after the filters of a colour or overlay run: the
/// source's bit rate (left out when unknown), its metadata, the tags, the
/// file's own time, the encoder and the pixel format (10 bits kept for a
/// 10-bit source). With [h264] (an output size for sharing, spec §10.51)
/// the encoder is an H.264 one: no HEVC tag, 8 bits, the sound as AAC.
List<String> colorOutputArgs({
  required String output,
  required DateTime creationDate,
  required String encoder,
  required bool tenBit,
  int? sourceBitrate,
  int? tzOffsetMins,
  bool h264 = false,
}) => [
  if (sourceBitrate != null) ...['-b:v', '$sourceBitrate'],
  ...h264
      ? _tagging.where((arg) => arg != '-tag:v' && arg != 'hvc1')
      : _tagging,
  ...creationTimeArgs(creationDate, tzOffsetMins),
  '-vcodec',
  encoder,
  '-pix_fmt',
  tenBit && !h264 ? 'p010le' : 'yuv420p',
  '-acodec',
  if (h264) ...['aac', '-b:a', '128k'] else 'copy',
  output,
];

/// The colour-only command (Python `process_video_lut`): the source
/// through the `-vf` value of [lut3dFilter].
List<String> lutCommandArgs({
  required String input,
  required String vf,
  required List<String> inputArgs,
  required List<String> outputArgs,
}) => [
  ...inputArgs,
  '-i',
  input,
  '-vf',
  vf,
  '-map',
  '0:v:0',
  '-map',
  '0:a?',
  ...outputArgs,
];

/// The filter graph of an overlay run and the label of its result: the
/// source (input 0) through the colour correction [colorVf] (untouched
/// without one), then each layer (inputs 1 to N, at [positions]) laid over
/// it in order, the last on top. The overlays go on after the colour
/// correction, so they keep their own colours. `overlay` blends in 8-bit
/// 4:2:0 unless told otherwise, so a 10-bit source ([tenBit]) blends in
/// `yuv420p10`.
///
/// With an output size (spec §10.51) [before] (a crop) comes ahead of
/// the colour correction and [after] (the scale, bars) behind the last
/// layer, so the layers lie on the cropped picture at its own size.
(String graph, String label) overlayFilterComplex(
  String? colorVf,
  List<(int x, int y)> positions, {
  bool tenBit = false,
  String? before,
  String? after,
}) {
  final blend = tenBit ? ':format=yuv420p10' : '';
  final first = [?before, if ((colorVf ?? '').isNotEmpty) colorVf!].join(',');
  final parts = ['[0:v]${first.isEmpty ? 'null' : first}[v0]'];
  for (final (index, (x, y)) in positions.indexed) {
    final i = index + 1;
    parts
      ..add('[$i:v]format=rgba[h$i]')
      ..add('[v${i - 1}][h$i]overlay=x=$x:y=$y:eof_action=repeat$blend[v$i]');
  }
  if (after == null) {
    return (parts.join(';'), '[v${positions.length}]');
  }
  parts.add('[v${positions.length}]$after[vout]');
  return (parts.join(';'), '[vout]');
}

/// The colour correction [colorVf] as the link of a comparison (spec
/// §10.94): the picture twice, one of them corrected, and the two merged
/// by a mask picture (input [maskInput]: white where the corrected one
/// shows), with the divider line (input [lineInput]) laid over the edge.
/// Both pictures are merged as planar RGB, where one grey mask serves
/// every channel, in 10 bits for a [tenBit] source. Takes [colorVf]'s
/// place in [overlayFilterComplex], so the overlays lie on both sides.
String compareLink({
  required String colorVf,
  required int maskInput,
  required int lineInput,
  bool tenBit = false,
}) {
  final planes = tenBit ? 'gbrp10le' : 'gbrp';
  final blend = tenBit ? ':format=yuv420p10' : '';
  return 'split[cmo][cmc];'
      '[cmc]$colorVf,format=$planes[cmd];'
      '[cmo]format=$planes[cme];'
      '[$maskInput:v]format=$planes[cmm];'
      '[cme][cmd][cmm]maskedmerge[cmx];'
      '[$lineInput:v]format=rgba[cml];'
      '[cmx][cml]overlay=eof_action=repeat$blend';
}

/// The overlay command (Python `ColorCorrectionEngine.process_video`):
/// the source, then one concat list per layer, composed by
/// [overlayFilterComplex]. [pictures] are single pictures read after the
/// layers (a comparison's mask and line, [compareLink]).
List<String> overlayCommandArgs({
  required String input,
  required List<(String concatPath, int x, int y)> layers,
  required String? colorVf,
  required bool tenBit,
  required List<String> inputArgs,
  required List<String> outputArgs,
  String? before,
  String? after,
  List<String> pictures = const [],
}) {
  final (graph, label) = overlayFilterComplex(
    colorVf,
    [for (final (_, x, y) in layers) (x, y)],
    tenBit: tenBit,
    before: before,
    after: after,
  );
  return [
    ...inputArgs,
    '-i',
    input,
    for (final (path, _, _) in layers) ...[
      '-f',
      'concat',
      '-safe',
      '0',
      '-i',
      path,
    ],
    for (final picture in pictures) ...['-i', picture],
    '-filter_complex',
    graph,
    '-map',
    label,
    '-map',
    '0:a?',
    ...outputArgs,
  ];
}

// --- Telemetry-only renders -------------------------------------------------

/// The arguments of the encoder that takes raw frames on its input for a
/// telemetry-only video (Python `FrameSink.command`, without the
/// program): `bgra` frames to ProRes 4444 with alpha, or `bgr24` frames to
/// HEVC on black. A PNG sequence needs no ffmpeg. [fps] is written as
/// Python writes a float (`30.0`).
List<String> frameSinkArgs({
  required String format,
  required int width,
  required int height,
  required double fps,
  required String target,
  required String encoder,
  bool debug = false,
}) {
  if (format != overlayFormatProres && format != overlayFormatHevc) {
    throw ArgumentError.value(format, 'format', 'no encoder takes it');
  }
  final alpha = format == overlayFormatProres;
  return [
    '-y',
    '-f',
    'rawvideo',
    '-vcodec',
    'rawvideo',
    '-s',
    '${width}x$height',
    '-pix_fmt',
    alpha ? 'bgra' : 'bgr24',
    '-r',
    pyFloatRepr(fps),
    '-i',
    '-',
    if (alpha)
    // ProRes 4444 keeps the alpha; every major editor reads it.
    ...[
      '-c:v',
      'prores_ks',
      '-profile:v',
      '4444',
      '-pix_fmt',
      'yuva444p10le',
      '-vendor',
      'ap10',
    ] else ...[
      '-vcodec',
      encoder,
      '-pix_fmt',
      'yuv420p',
      '-tag:v',
      'hvc1',
      ...qualityArgs(encoder),
    ],
    target,
    if (!debug) ...['-nostats', '-loglevel', 'error'],
  ];
}

/// The name of a frame of a PNG sequence (frames count from 1).
String frameFileName(int frame) =>
    'frame_${frame.toString().padLeft(6, '0')}.png';
