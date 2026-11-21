/// What the app asks of exiftool (Python `metadata/exif.py` on
/// pyexiftool): the argument lists of a read, a write and the copy of all
/// tags from a source to its output, and the reading of exiftool's JSON.
/// Running exiftool is the desktop engine's (`engine/desktop/exiftool.dart`).
library;

import 'dart:convert';

import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';

/// Before every command: tag names with their group ("QuickTime:Make"),
/// values as numbers and plain text, not exiftool's print forms.
const exiftoolCommonArgs = ['-G', '-n'];

/// All tags of [path] as JSON, or only [tags] when given.
List<String> exiftoolReadArgs(String path, [List<String>? tags]) => [
  ...exiftoolCommonArgs,
  '-j',
  for (final tag in tags ?? const <String>[]) '-$tag',
  path,
];

/// The tags of the first file in exiftool's JSON answer; `null` when the
/// answer is not that.
MediaTags? parseExiftoolJson(String output) {
  try {
    final data = jsonDecode(output);
    if (data is List && data.isNotEmpty && data.first is Map<String, dynamic>) {
      return data.first as Map<String, dynamic>;
    }
  } on FormatException {
    // Not JSON: no answer.
  }
  return null;
}

/// What exiftool answered for each of [names], as text: the tag by the
/// name asked for, else the first tag whose name ends like it (exiftool
/// answers with the group in front, and not always the one asked for);
/// empty for a tag the file does not have.
Map<String, String> namedTags(MediaTags? meta, List<String> names) {
  final result = <String, String>{};
  for (final name in names) {
    Object? value = meta?[name];
    if (value == null && meta != null) {
      final bare = name.split(':').last;
      for (final entry in meta.entries) {
        if (entry.key.endsWith(bare)) {
          value = entry.value;
          break;
        }
      }
    }
    result[name] = value == null ? '' : '$value';
  }
  return result;
}

/// Writes [tags] into the file at [path], in place.
List<String> exiftoolSetTagsArgs(String path, Map<String, Object?> tags) => [
  ...exiftoolCommonArgs,
  '-overwrite_original',
  for (final MapEntry(:key, :value) in tags.entries) '-$key=$value',
  path,
];

/// Copies every tag of [source] into [dest], without the embedded
/// preview images.
List<String> exiftoolCopyAllArgs(String source, String dest) => [
  ...exiftoolCommonArgs,
  '-TagsFromFile',
  source,
  '-all:all',
  '--ThumbnailImage',
  '--PreviewImage',
  '--JpgFromRaw',
  '--OtherImage',
  '-overwrite_original',
  dest,
];

/// Writes the timezone tags after a copy ([timezoneTagsAfterCopy]) into
/// the output.
List<String> exiftoolTimezoneArgs(String dest, Map<String, String> tags) => [
  ...exiftoolCommonArgs,
  for (final MapEntry(:key, :value) in tags.entries) '-$key=$value',
  '-overwrite_original',
  dest,
];

/// Writes the tags the user asked for ("Tag=value" each) into the output.
List<String> exiftoolCustomTagsArgs(String dest, List<String> customTags) => [
  ...exiftoolCommonArgs,
  for (final tag in customTags) '-$tag',
  '-overwrite_original',
  dest,
];

// The forms of a date in Sony's XML tags, tried in this order: the look of
// the text, then how it is read (the date's separator, whether a fraction
// and a zone are part of it).
final _xmlDateForms = <(RegExp, String, bool, bool)>[
  (RegExp(r'^\d+:\d+:\d+ \d+:\d+:\d+.\d+[+-]\d+:\d+$'), ':', true, true),
  (RegExp(r'^\d+:\d+:\d+ \d+:\d+:\d+$'), ':', false, false),
  (RegExp(r'^\d+:\d+:\d+ \d+:\d+:\d+[+-]\d+:\d+$'), ':', false, true),
  (RegExp(r'^\d+-\d+-\d+ \d+:\d+:\d+$'), '-', false, false),
  (RegExp(r'^\d+-\d+-\d+ \d+:\d+:\d+[+-]\d+:\d+$'), '-', false, true),
  (RegExp(r'^\d+-\d+-\d+T\d+:\d+:\d+[+-]\d+:\d+$'), '-', false, true),
  (RegExp(r'^\d+-\d+-\d+T\d+:\d+:\d+Z$'), '-', false, false),
];

final _xmlDateParts = RegExp(
  r'^(\d+[:-]\d+[:-]\d+)[ T](\d+:\d+:\d+)(\.\d{1,6})?'
  r'(?:([+-])(\d\d):([0-5]\d)|Z)?$',
);

/// A date of Sony's XML tags as exiftool takes it for an XMP tag
/// ("2025:09:13 09:37:36+07:00"); `null` for text that is no such date.
String? xmlDateForXmp(String text) {
  for (final (look, separator, fraction, zone) in _xmlDateForms) {
    if (!look.hasMatch(text)) {
      continue;
    }
    // The first form the text looks like decides; when it cannot be read
    // as that form, it is no date.
    final parts = _xmlDateParts.firstMatch(text);
    if (parts == null ||
        (parts[3] != null) != fraction ||
        (parts[4] != null) != zone) {
      return null;
    }
    final time = pyStrptime(
      '${parts[1]} ${parts[2]}',
      '%Y$separator%m$separator%d %H:%M:%S',
    );
    if (time == null) {
      return null;
    }
    var offset = '';
    if (zone) {
      if (int.parse(parts[5]!) > 23) {
        return null;
      }
      final zero = parts[5] == '00' && parts[6] == '00';
      offset = '${zero ? '+' : parts[4]}${parts[5]}:${parts[6]}';
    }
    return pyStrftime(time, tagDateFormat) + offset;
  }
  return null;
}

// Python's str() of a JSON value.
String _pyText(Object? value) => switch (value) {
  null => 'None',
  true => 'True',
  false => 'False',
  final double number => pyFloatRepr(number),
  _ => '$value',
};

final _frameRateLetter = RegExp(r'p$');

/// Sony's cameras keep the date, the camera and the lens of a clip in an
/// XML block (exiftool's `XML:` tags); this writes them into the output
/// as XMP, where other software looks (Python `set_xmp_data`). `null`
/// when [meta] has none of them.
List<String>? exiftoolXmpArgs(String dest, MediaTags meta) {
  final args = <String>[];
  meta.forEach((key, value) {
    switch (key) {
      case 'XML:LastUpdate' || 'XML:CreationDateValue':
        final date = xmlDateForXmp(_pyText(value));
        if (date != null) {
          final tag = key == 'XML:LastUpdate'
              ? 'xmp:MetadataDate'
              : 'xmp:CreateDate';
          args.add('-$tag=$date');
        }
      case 'XML:VideoFormatVideoFrameCaptureFps':
        // "50.00p" is 50 frames a second.
        args.add(
          '-XMP-xmpDM:videoFrameRate='
          '${_pyText(value).replaceFirst(_frameRateLetter, '')}',
        );
      case 'XML:DeviceManufacturer':
        args.add('-XMP:Make=${_pyText(value)}');
      case 'XML:DeviceModelName':
        args.add('-XMP:Model=${_pyText(value)}');
      case 'XML:LensModelName':
        args.add('-XMP-aux:lens=${_pyText(value)}');
    }
  });
  return args.isEmpty
      ? null
      : [...exiftoolCommonArgs, ...args, '-overwrite_original', dest];
}

/// The commands that carry a source's metadata over to its output, in
/// the order they are run (Python `copy_all`): every tag copied, then the
/// local creation date with its timezone ([forcedTzMinutes], else the
/// source's own; left out when there is none), then the user's own tags,
/// then Sony's XML tags as XMP. [meta] is the source's metadata and
/// [fileModified] its modification time in local time. Throws a
/// [FormatException] when a timezone is to be written and the source has
/// no date to write it with.
List<List<String>> copyAllCommands({
  required String source,
  required String dest,
  required MediaTags? meta,
  int? forcedTzMinutes,
  DateTime? fileModified,
  List<String>? customTags,
}) {
  final timezone = timezoneTagsAfterCopy(
    meta,
    forcedTzMinutes: forcedTzMinutes,
    fileModified: fileModified,
  );
  return [
    exiftoolCopyAllArgs(source, dest),
    if (timezone != null) exiftoolTimezoneArgs(dest, timezone),
    if (customTags != null && customTags.isNotEmpty)
      exiftoolCustomTagsArgs(dest, customTags),
    if (meta != null && meta.keys.any((key) => key.startsWith('XML:')))
      ?exiftoolXmpArgs(dest, meta),
  ];
}
