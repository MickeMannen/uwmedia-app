/// Output filename patterns (Python `utils/filename_formats.py` and the
/// Color page's presets in `color_backend.py`): the date codes of
/// [pyStrftime] applied to a file's date taken, with `{filename}` for the
/// source name and `{hud}` for the first overlay's.
library;

import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';

/// The sample date the preset labels and the examples show.
final DateTime exampleDateTime = naive(2026, 9, 5, 14, 30);

/// The Color page's built-in presets, label and pattern. The empty pattern
/// keeps the original name.
const List<(String, String)> filenameFormatPresets = [
  ('Original (DSC06641)', ''),
  ('Original + color (DSC06641_color)', '{filename}_color'),
  ('Date + time (20260905_143000)', '%Y%m%d_%H%M%S'),
  ('Date + time + color (20260905_143000_color)', '%Y%m%d_%H%M%S_color'),
  // "{hud}": the first overlay's name; left out when there is no overlay.
  (
    'Date + time + overlay (20260905_143000_garmin_mk3i_main)',
    '%Y%m%d_%H%M%S_{hud}',
  ),
];

/// Labels saved in the settings by earlier versions of the Python app, and
/// today's label for each.
const Map<String, String> legacyPresetLabels = {
  'Keep original filename': 'Original (DSC06641)',
  'Date taken': 'Date + time (20260905_143000)',
};

/// Why [pattern] can't be used as a filename pattern, or `null`.
String? patternError(String pattern) {
  if (pattern.pyStrip().isEmpty) {
    return 'Enter a pattern, e.g. %Y%m%d_%H%M%S_Bali';
  }
  if (pattern.contains('/') || pattern.contains(r'\')) {
    return r"A filename pattern can't contain / or \";
  }
  final String example;
  try {
    example = pyStrftime(exampleDateTime, pattern);
  } on FormatException catch (e) {
    return 'Invalid pattern: ${e.message}';
  }
  if (example == pattern) {
    return 'The pattern has no date codes (%Y, %m, %d, %H, %M, %S …), '
        'so every file would get the same name';
  }
  return null;
}

/// [pattern] on the sample date; the pattern itself when it can't be used.
String exampleFilename(String pattern) {
  try {
    return pyStrftime(exampleDateTime, pattern);
  } on FormatException {
    return pattern;
  }
}
