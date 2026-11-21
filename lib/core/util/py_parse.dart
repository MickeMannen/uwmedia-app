/// Text-to-value conversions with the rules of the Python functions the
/// reference parsers use, so that the same odd input gives the same value
/// (or the same refusal) in the port.
library;

import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

// What Python's `str.strip()` removes: the characters `str.isspace()` is
// true for. Dart's `trim()` differs at the edges (it removes U+FEFF and
// keeps U+001C to U+001F).
final _pySpaceStart = RegExp(
  r'^[\t\n\v\f\r\x1c-\x1f \x85\xa0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]+',
);
final _pySpaceEnd = RegExp(
  r'[\t\n\v\f\r\x1c-\x1f \x85\xa0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]+$',
);

/// Python `str.strip()`.
extension PyStrip on String {
  String pyStrip() =>
      replaceFirst(_pySpaceStart, '').replaceFirst(_pySpaceEnd, '');
}

final _floatText = RegExp(
  r'^[+-]?(\d+(_\d+)*(\.(\d+(_\d+)*)?)?|\.\d+(_\d+)*)([eE][+-]?\d+(_\d+)*)?$',
);
final _specialFloat = RegExp(
  r'^([+-]?)(nan|inf|infinity)$',
  caseSensitive: false,
);
final _intText = RegExp(r'^[+-]?\d+(_\d+)*$');

/// Python `float(text)`, or `null` where Python raises `ValueError` (or
/// `TypeError` for `None`): surrounding whitespace is ignored, `nan`, `inf`
/// and `infinity` are read in any case, digits may be grouped with single
/// underscores. Not read, though Python does: digits other than 0-9.
double? pyFloat(String? text) {
  if (text == null) {
    return null;
  }
  final trimmed = text.pyStrip();
  final special = _specialFloat.firstMatch(trimmed);
  if (special != null) {
    if (special.group(2)!.toLowerCase() == 'nan') {
      return double.nan;
    }
    return special.group(1) == '-' ? double.negativeInfinity : double.infinity;
  }
  if (!_floatText.hasMatch(trimmed)) {
    return null;
  }
  return double.parse(trimmed.replaceAll('_', ''));
}

/// Python `int(text)`, or `null` where Python raises `ValueError`. Also
/// `null` for a number beyond 64 bits, which Python reads.
int? pyInt(String? text) {
  if (text == null) {
    return null;
  }
  final trimmed = text.pyStrip();
  if (!_intText.hasMatch(trimmed)) {
    return null;
  }
  return int.tryParse(trimmed.replaceAll('_', ''));
}

/// Python `max(a, b)`: the second only when it is greater, so a NaN second
/// value gives the first.
double pyMax(double a, double b) => b > a ? b : a;

/// Python `min(a, b)`: the second only when it is smaller.
double pyMin(double a, double b) => b < a ? b : a;

/// Python `Path(path).suffix` (3.14): from the last dot of the file name,
/// leading dots aside; empty when there is none.
String pySuffix(String path) {
  final name = pyFileName(path).replaceFirst(RegExp(r'^\.+'), '');
  final dot = name.lastIndexOf('.');
  return dot == -1 ? '' : name.substring(dot);
}

/// Python `Path(path).name`. Both `/` and `\` separate folders here, on
/// every platform, so that a path from another system reads the same.
/// A lone `.` is the current folder and has no name.
String pyFileName(String path) {
  final name = path.substring(path.lastIndexOf(RegExp(r'[/\\]')) + 1);
  return name == '.' ? '' : name;
}

const Map<String, String> _directives = {
  'Y': r'(?<Y>\d\d\d\d)',
  'm': r'(?<m>1[0-2]|0[1-9]|[1-9])',
  'd': r'(?<d>3[0-1]|[1-2]\d|0[1-9]|[1-9]| [1-9])',
  'H': r'(?<H>2[0-3]|[0-1]\d|\d)',
  'I': r'(?<I>1[0-2]|0[1-9]|[1-9])',
  'M': r'(?<M>[0-5]\d|\d)',
  'S': r'(?<S>6[0-1]|[0-5]\d|\d)',
  'p': r'(?<p>am|pm)',
};

final Map<String, RegExp> _formatCache = {};

RegExp _formatRegExp(String format) => _formatCache.putIfAbsent(format, () {
  final pattern = StringBuffer('^');
  for (var i = 0; i < format.length; i++) {
    final c = format[i];
    if (c == '%') {
      i += 1;
      final directive = _directives[format[i]];
      if (directive == null) {
        throw ArgumentError.value(format, 'format', 'unsupported directive');
      }
      pattern.write(directive);
    } else if (c.trim().isEmpty) {
      pattern.write(r'\s+');
    } else {
      pattern.write(RegExp.escape(c));
    }
  }
  pattern.write(r'$');
  return RegExp(pattern.toString(), caseSensitive: false);
});

/// Python `datetime.strptime(text, format)` as a naive timestamp, or `null`
/// where Python raises `ValueError`. Supports `%Y %m %d %H %I %M %S %p`
/// with the same leniency (one or two digits for all but the year) and the
/// same strictness (the whole text must match, the date must exist, a
/// second of 60 is refused).
DateTime? pyStrptime(String text, String format) {
  final match = _formatRegExp(format).firstMatch(text);
  if (match == null) {
    return null;
  }
  final names = match.groupNames.toSet();
  int field(String name, int fallback) => names.contains(name)
      ? int.parse(match.namedGroup(name)!.trim())
      : fallback;
  final year = field('Y', 1900);
  final month = field('m', 1);
  final day = field('d', 1);
  var hour = field('H', 0);
  if (names.contains('I')) {
    final twelve = field('I', 12);
    final pm =
        names.contains('p') && match.namedGroup('p')!.toLowerCase() == 'pm';
    // 12 AM is midnight, 12 PM is noon.
    hour = pm ? (twelve == 12 ? 12 : twelve + 12) : (twelve == 12 ? 0 : twelve);
  }
  final minute = field('M', 0);
  final second = field('S', 0);
  if (second > 59) {
    return null;
  }
  // Python has no year 0.
  if (year < 1) {
    return null;
  }
  final time = naive(year, month, day, hour, minute, second);
  if (time.month != month || time.day != day) {
    return null;
  }
  return time;
}

/// Python `Path(path).stem`: the file name without its suffix.
String pyStem(String path) {
  final name = pyFileName(path);
  return name.substring(0, name.length - pySuffix(path).length);
}

/// Python `f"{x:g}"`: six significant digits (an exact half to the even
/// digit), trailing zeros dropped, an exponent form below 1e-4 and from
/// 1e6 up (there an exact half still rounds away from zero).
String pyFormatG(double x) {
  if (x.isNaN) {
    return 'nan';
  }
  if (x.isInfinite) {
    return x < 0 ? '-inf' : 'inf';
  }
  if (x == 0) {
    return x.isNegative ? '-0' : '0';
  }
  // The decimal exponent of the value as six digits will show it.
  final exponent = int.parse(x.toStringAsExponential(5).split('e')[1]);
  String trimmed(String digits) => digits.contains('.')
      ? digits.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
      : digits;
  if (exponent >= -4 && exponent < 6) {
    final fixed = pyFormatFixed(x, 5 - exponent);
    // Rounding can carry into one more digit (999999.5).
    if (exponent < 5 || fixed.replaceFirst('-', '').length <= 6) {
      return trimmed(fixed);
    }
  }
  final scientific = x.toStringAsExponential(5);
  final split = scientific.indexOf('e');
  final shown = int.parse(scientific.substring(split + 1));
  final sign = shown < 0 ? '-' : '+';
  final power = shown.abs().toString().padLeft(2, '0');
  return '${trimmed(scientific.substring(0, split))}e$sign$power';
}

final _isoDate = RegExp(r'^(?:(\d{4})-(\d\d)-(\d\d)|(\d{4})(\d\d)(\d\d))');
final _isoTime = RegExp(
  r'^(\d\d)(?::?(\d\d)(?::?(\d\d)(?:[.,](\d+))?)?)?'
  r'(?:[Zz]|[+-]\d\d(?::?\d\d(?::?\d\d(?:[.,]\d+)?)?)?)?$',
);

/// Python `datetime.fromisoformat(text).replace(tzinfo=None)`: the wall
/// clock time as written, any UTC offset dropped without converting; `null`
/// where Python raises `ValueError`.
///
/// Reads `YYYY-MM-DD` or `YYYYMMDD`, alone or followed by any one separator
/// character and `HH[:MM[:SS[.ffffff]]]` (colons optional, digits beyond
/// microseconds dropped) and an offset (`Z`, `±HH[:MM[:SS]]`). Not read,
/// though Python does: ISO week dates, `24:00`, a stray character before
/// the offset, an empty or over-long seconds field. Read, though Python
/// refuses: a lowercase `z`, an offset of 24 hours or more.
DateTime? pyFromIsoformatNaive(String text) {
  final date = _isoDate.firstMatch(text);
  if (date == null) {
    return null;
  }
  final year = int.parse(date.group(1) ?? date.group(4)!);
  final month = int.parse(date.group(2) ?? date.group(5)!);
  final day = int.parse(date.group(3) ?? date.group(6)!);
  if (year < 1) {
    return null;
  }
  var hour = 0;
  var minute = 0;
  var second = 0;
  var micros = 0;
  final rest = text.substring(date.end);
  if (rest.isNotEmpty) {
    if (rest.length < 3) {
      return null;
    }
    // Any one character separates the date from the time.
    final time = _isoTime.firstMatch(rest.substring(1));
    if (time == null) {
      return null;
    }
    hour = int.parse(time.group(1)!);
    minute = int.parse(time.group(2) ?? '0');
    second = int.parse(time.group(3) ?? '0');
    final fraction = time.group(4);
    if (fraction != null) {
      micros = int.parse(fraction.padRight(6, '0').substring(0, 6));
    }
  }
  if (hour > 23 || minute > 59 || second > 59) {
    return null;
  }
  final result = naive(
    year,
    month,
    day,
    hour,
    minute,
    second,
    micros ~/ 1000,
    micros % 1000,
  );
  if (result.month != month || result.day != day) {
    return null;
  }
  return result;
}

/// Python `repr(x)` of a float: the shortest digits that read back as the
/// same number, as `0.0001`, `100.0` or `123456789.123`, and with an
/// exponent below 1e-4 and from 1e16 up (`1e-05`, `1.5e+16`).
String pyFloatRepr(double x) {
  if (x.isNaN) {
    return 'nan';
  }
  if (x.isInfinite) {
    return x > 0 ? 'inf' : '-inf';
  }
  // Dart's shortest digits are Python's; only the layout differs.
  final [mantissa, exponentText] = x.abs().toStringAsExponential().split('e');
  final digits = mantissa.replaceFirst('.', '');
  final exponent = int.parse(exponentText);
  final sign = x.isNegative ? '-' : '';
  if (exponent < -4 || exponent >= 16) {
    final rest = digits.length > 1 ? '.${digits.substring(1)}' : '';
    final size = exponent.abs().toString().padLeft(2, '0');
    return '$sign${digits[0]}${rest}e${exponent < 0 ? '-' : '+'}$size';
  }
  if (exponent < 0) {
    return '${sign}0.${'0' * (-exponent - 1)}$digits';
  }
  final whole = digits.length > exponent + 1
      ? digits.substring(0, exponent + 1)
      : digits.padRight(exponent + 1, '0');
  final fraction = digits.length > exponent + 1
      ? digits.substring(exponent + 1)
      : '0';
  return '$sign$whole.$fraction';
}
