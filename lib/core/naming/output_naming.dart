/// The names of the files the app writes (Python `cli_main.py`
/// `output_filename`, `get_unique_path`, `resolve_target_path`,
/// `ffmpeg/overlay_output.output_path_for` and `utils/convert_naming.py`).
///
/// Nothing here touches the disk: whether a file exists, and whether two
/// paths are the same file, are asked through callbacks.
library;

import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';

/// A telemetry-only render as a transparent ProRes 4444 `.mov`.
const overlayFormatProres = 'prores';

/// A telemetry-only render as a folder of PNG frames with alpha.
const overlayFormatPng = 'png';

/// A telemetry-only render as HEVC `.mp4` on black.
const overlayFormatHevc = 'hevc';

/// The three overlay output formats.
const overlayFormats = [
  overlayFormatProres,
  overlayFormatPng,
  overlayFormatHevc,
];

/// The date-taken pattern of a batch run or a run into another folder.
const defaultFilenameFormat = '%Y%m%d_%H%M%S';

/// The pattern of an overlay rendered for one video.
const defaultRenderLogFilenameFormat = '{filename}_{hud}';

const _videoSuffixes = ['.mp4', '.mov', '.m4v', '.mkv', '.avi'];

/// Whether a batch run takes [path] for a video (by its extension), as
/// Python's `cli_main.py` does; anything else is a photo.
bool isVideoPath(String path) =>
    _videoSuffixes.contains(pySuffix(path).toLowerCase());

/// What of a run's settings decides the names of its output files.
class NamingArgs {
  const NamingArgs({
    this.renderVideoLog = false,
    this.originalLayoutStem,
    this.renderLogFilenameFormat = defaultRenderLogFilenameFormat,
    this.filenameFormat,
    this.keepFilename = false,
    this.overlayLayoutPaths = const [],
    this.overlayFormat = overlayFormatHevc,
    this.color,
    this.layout,
    this.noOverwrite = false,
    this.overwrite = false,
  });

  /// The run renders the overlay alone for a video (`--render-video-log`).
  final bool renderVideoLog;

  /// The name of the run's single layout, without its extension.
  final String? originalLayoutStem;

  /// The pattern of [renderVideoLog] names: `{filename}`, `{hud}` and
  /// `{datetaken}` (or `{datetaken:%Y%m%d}`).
  final String? renderLogFilenameFormat;

  /// The filename pattern; `null` or empty for the default.
  final String? filenameFormat;

  /// Keep the source's name.
  final bool keepFilename;

  /// The layout files of the run's overlays, in drawing order.
  final List<String> overlayLayoutPaths;

  /// One of [overlayFormats], for [renderVideoLog].
  final String overlayFormat;

  /// The colour profile, when the run corrects colour.
  final String? color;

  /// The run's single layout file.
  final String? layout;

  /// Skip a file whose output already exists.
  final bool noOverwrite;

  /// Write over an existing output.
  final bool overwrite;

  /// Whether the run makes outputs of its own that the two overwrite
  /// settings are about. An overlays-only run counts: the Color page sends
  /// one with colour correction switched off, and its "Skip if target
  /// exists" must still skip.
  bool get namesOutput =>
      (color ?? '').isNotEmpty ||
      (layout ?? '').isNotEmpty ||
      overlayLayoutPaths.isNotEmpty ||
      renderVideoLog;
}

/// The name of the first overlay drawn on the output: the layout's stem,
/// else the first overlay's; `null` without one.
String? firstOverlayName(NamingArgs args) {
  if ((args.originalLayoutStem ?? '').isNotEmpty) {
    return args.originalLayoutStem;
  }
  return args.overlayLayoutPaths.isEmpty
      ? null
      : pyStem(args.overlayLayoutPaths.first);
}

final _separator = RegExp(r'[/\\]');

// The folders of a path, so that "a/b/", "a//b" and "a/./b" are one place.
List<String> _folders(String path) {
  // An empty path is the folder the app runs in, as "." is.
  final parts = path.isEmpty ? <String>[] : path.split(_separator);
  return [
    for (final (i, part) in parts.indexed)
      if ((part.isNotEmpty || i == 0) && part != '.') part,
  ];
}

bool _sameFolder(List<String> a, List<String> b) =>
    a.length == b.length &&
    [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((same) => same);

String _withSuffix(String path, String suffix) =>
    path.substring(0, path.length - pySuffix(path).length) + suffix;

/// Python `str(datetime)`.
String _dateText(DateTime time) => formatNaive(time).replaceFirst('T', ' ');

/// Python `pattern.format(filename=, hud=, datetaken=)` for the patterns a
/// render-log name is made of: the three fields, a date format after
/// `datetaken:`, and `{{` and `}}` for braces. Anything else Python's
/// `format` can do (conversions, attributes, alignment) is a
/// [FormatException], like an unknown field.
String _formatRenderLog(
  String pattern,
  String filename,
  String hud,
  DateTime taken,
) {
  final out = StringBuffer();
  var i = 0;
  while (i < pattern.length) {
    final ch = pattern[i];
    final doubled = i + 1 < pattern.length && pattern[i + 1] == ch;
    if ((ch == '{' || ch == '}') && doubled) {
      out.write(ch);
      i += 2;
    } else if (ch == '}') {
      throw const FormatException("Single '}' in the pattern");
    } else if (ch == '{') {
      final end = pattern.indexOf('}', i);
      if (end == -1) {
        throw const FormatException("A '{' without its '}'");
      }
      final field = pattern.substring(i + 1, end);
      if (field.contains('{')) {
        throw FormatException('A field inside a field: {$field}');
      }
      final colon = field.indexOf(':');
      final name = colon == -1 ? field : field.substring(0, colon);
      final spec = colon == -1 ? '' : field.substring(colon + 1);
      if (name == 'datetaken') {
        out.write(spec.isEmpty ? _dateText(taken) : pyStrftime(taken, spec));
      } else if ((name == 'filename' || name == 'hud') && spec.isEmpty) {
        out.write(name == 'hud' ? hud : filename);
      } else {
        throw FormatException('Unknown field {$field}');
      }
      i = end + 1;
    } else {
      out.write(ch);
      i++;
    }
  }
  return out.toString();
}

/// The path a render of [format] writes, from the name the run would have
/// used: `.mov` for ProRes, a folder (no suffix) for a PNG sequence, the
/// given name for HEVC. A photo rendered with alpha becomes a `.png`.
String outputPathFor(String format, String path, {bool isVideo = true}) {
  if (format == overlayFormatProres) {
    return _withSuffix(path, isVideo ? '.mov' : '.png');
  }
  if (format == overlayFormatPng) {
    return _withSuffix(path, isVideo ? '' : '.png');
  }
  return path;
}

final _hudWithSeparator = RegExp(r'[_\- ]?\{hud\}');

/// The output file name for [source]: the render-log pattern, a forced
/// name (a single file to an explicit output path), the kept name, a
/// filename pattern, or by default, for a batch run ([sourceIsFolder]) or
/// another folder, the date taken as `%Y%m%d_%H%M%S`. Extensions are
/// lower-cased. A pattern that can't be used gives the source's name.
///
/// A photo whose date has a fraction of a second gets its hundredths of
/// a second appended (`_12` for .123; Python appended the milliseconds,
/// `_123`; spec §10.95), which keeps date-named photos of one second
/// apart; not when the name is the source's own or was given. Two that
/// still get one name are numbered by [resolveTargetPath].
String outputFilename({
  required String source,
  required String outputDir,
  required bool sourceIsFolder,
  required NamingArgs args,
  required DateTime creationDate,
  String? forcedFilename,
}) {
  assert(creationDate.isUtc, naiveTimeMessage);
  final stem = pyStem(source);
  final suffix = pySuffix(source).toLowerCase();
  final forced = (forcedFilename ?? '').isNotEmpty;
  final isVideo = _videoSuffixes.contains(suffix);
  String filename;
  if (args.renderVideoLog) {
    final layoutName = (args.originalLayoutStem ?? '').isNotEmpty
        ? args.originalLayoutStem!
        : 'default';
    try {
      filename =
          _formatRenderLog(
            args.renderLogFilenameFormat!,
            stem,
            layoutName,
            creationDate,
          ) +
          suffix;
    } on Object {
      filename = '${stem}_$layoutName$suffix';
    }
    // The last part only: a pattern can give a slash (%D, "sub/{filename}").
    filename = pyFileName(
      outputPathFor(args.overlayFormat, filename, isVideo: isVideo),
    );
  } else if (forced) {
    filename = pyStem(forcedFilename!) + pySuffix(forcedFilename).toLowerCase();
  } else if (args.keepFilename) {
    filename = stem + suffix;
  } else {
    var format = args.filenameFormat ?? '';
    final sourceFolder = _folders(source)..removeLast();
    if (format.isEmpty &&
        (sourceIsFolder || !_sameFolder(_folders(outputDir), sourceFolder))) {
      format = defaultFilenameFormat;
    }
    if (format.isEmpty) {
      filename = stem + suffix;
    } else {
      try {
        // "{hud}" is dropped, with the separator before it, when there is
        // no overlay.
        final hud = firstOverlayName(args) ?? '';
        final pattern = hud.isEmpty
            ? format.replaceAll(_hudWithSeparator, '')
            : format;
        filename =
            pyStrftime(
              creationDate,
              pattern,
            ).replaceAll('{filename}', stem).replaceAll('{hud}', hud) +
            suffix;
      } on FormatException {
        filename = stem + suffix;
      }
    }
  }

  final keepsName =
      args.keepFilename || (args.filenameFormat ?? '').contains('{filename}');
  final fraction = creationDate.millisecond > 0 || creationDate.microsecond > 0;
  if (!args.renderVideoLog && !forced && !keepsName && !isVideo && fraction) {
    final hundredths = (creationDate.millisecond ~/ 10).toString().padLeft(
      2,
      '0',
    );
    filename = '${pyStem(filename)}_$hundredths${pySuffix(filename)}';
  }
  return filename;
}

/// Hands out file names that are free: not on the disk and not handed out
/// before by this object (one per run).
class UniquePaths {
  /// [exists] says whether a path is taken on the disk.
  UniquePaths(this.exists);

  final bool Function(String path) exists;

  // Lower-cased: on case-insensitive file systems "A.jpg" is "a.jpg".
  final Set<String> _reserved = {};

  /// [path], or with `_1`, `_2` … before the extension when it is taken.
  /// The extension is lower-cased unless [lowerSuffix] is off (a moved
  /// original keeps its own name).
  String unique(String path, {bool lowerSuffix = true}) {
    final suffix = lowerSuffix ? pySuffix(path).toLowerCase() : pySuffix(path);
    final base = path.substring(0, path.length - suffix.length);
    var candidate = base + suffix;
    for (
      var counter = 1;
      exists(candidate) || _reserved.contains(candidate.toLowerCase());
      counter++
    ) {
      candidate = '${base}_$counter$suffix';
    }
    _reserved.add(candidate.toLowerCase());
    return candidate;
  }

  /// [path], or with `_1`, `_2` … before the extension when this object
  /// has handed that name out already; the disk is not looked at. For the
  /// second file of a run that gets the name of the first (two photos of
  /// one second).
  String numbered(String path) {
    final suffix = pySuffix(path);
    final base = path.substring(0, path.length - suffix.length);
    var candidate = path;
    for (
      var counter = 1;
      _reserved.contains(candidate.toLowerCase());
      counter++
    ) {
      candidate = '${base}_$counter$suffix';
    }
    return candidate;
  }

  /// Marks [path] as handed out, when it was given without [unique].
  void reserve(String path) => _reserved.add(path.toLowerCase());
}

/// Where a file goes and whether it is skipped.
typedef TargetPath = ({String path, bool skipped, bool overwrites});

/// Applies "skip if the target exists" and "overwrite" to [target]. An
/// existing file otherwise gets `_1`, `_2` … appended by [unique].
/// So does a name [unique] handed out earlier in the run, whatever the
/// settings.
///
/// The source itself is never written over (same folder and same name),
/// even with overwrite on: it is still being read. It isn't an earlier
/// output either, so the skip setting doesn't skip because of it.
/// [sameFile] decides, not the spelling: where file names ignore case
/// "DSC01.jpg" is the source "DSC01.JPG".
TargetPath resolveTargetPath({
  required String target,
  required String source,
  required NamingArgs args,
  required UniquePaths unique,
  required bool Function(String a, String b) sameFile,
}) {
  // A name this run has given to another file already is that file's:
  // this one is numbered, and skip and overwrite hold for its own name
  // (else the second photo of a second was skipped, or written over the
  // first).
  final numbered = unique.numbered(target);
  final taken = unique.exists(numbered);
  final writesOverSource = taken && sameFile(numbered, source);
  final own = args.namesOutput && !writesOverSource;
  if (own && args.noOverwrite && taken) {
    unique.reserve(numbered);
    return (path: numbered, skipped: true, overwrites: false);
  }
  if (own && args.overwrite) {
    unique.reserve(numbered);
    return (path: numbered, skipped: false, overwrites: taken);
  }
  return (path: unique.unique(target), skipped: false, overwrites: false);
}

/// The resolutions Convertion offers: name, width, height and HEVC bit
/// rate.
const List<(String, int, int, String)> convertResolutions = [
  ('1080p', 1920, 1080, '24M'),
  ('720p', 1280, 720, '12M'),
  ('480p', 854, 480, '7M'),
  ('360p', 640, 360, '4M'),
];

/// The bits a second of a conversion preset ('24M').
int presetBitrate(String text) {
  final value = text.trim().toUpperCase();
  final scale = value.endsWith('M')
      ? 1000000
      : value.endsWith('K')
      ? 1000
      : 1;
  final digits = scale == 1 ? value : value.substring(0, value.length - 1);
  return (double.parse(digits) * scale).round();
}

final _resolutionName = RegExp(
  '[ _](4k|2160p|1080p|720p|480p|360p)',
  caseSensitive: false,
);

/// The name of a converted file: 'Dive 4K.MP4' gives 'Dive 1080p.mp4', and
/// a name with no resolution in it gets one added, 'Dive.MP4' gives
/// 'Dive 1080p.mp4'.
String convertOutputFilename(String source, String resolution) {
  final stem = pyStem(source);
  final newStem = _resolutionName.hasMatch(stem)
      ? stem.replaceAll(_resolutionName, ' $resolution')
      : '$stem $resolution';
  return newStem + pySuffix(source).toLowerCase();
}
