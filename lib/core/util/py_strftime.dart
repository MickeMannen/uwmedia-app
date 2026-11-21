/// Python `datetime.strftime` for a naive timestamp, in the C locale.
///
/// Python hands the pattern to the C library, so what an odd code gives
/// there depends on the system: macOS prints the letter of a code it does
/// not know, Windows raises. Here the codes below are the whole set, the
/// same on every platform, and anything else is a [FormatException]
/// (spec §10.22). The results of the known codes are those of Python 3.14
/// on macOS.
library;

import 'package:uwmedia_app/core/util/naive_time.dart';

const _days = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

// The codes `%-` takes the padding from; on the others it changes nothing.
const _unpaddable = 'deHIjklmMSUVW';

String _pad(int value, int width, [String fill = '0']) =>
    value.toString().padLeft(width, fill);

int _dayOfYear(DateTime t) =>
    t.difference(DateTime.utc(t.year)).inDays + 1; // 1..366

/// ISO 8601 week-numbering year and week of [t].
(int, int) _isoWeek(DateTime t) {
  // The Thursday of t's week decides the year.
  final thursday = t.add(Duration(days: 4 - t.weekday));
  return (thursday.year, (_dayOfYear(thursday) - 1) ~/ 7 + 1);
}

String _code(String code, DateTime t) {
  final hour12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
  switch (code) {
    case 'a':
      return _days[t.weekday - 1].substring(0, 3);
    case 'A':
      return _days[t.weekday - 1];
    case 'b' || 'h':
      return _months[t.month - 1].substring(0, 3);
    case 'B':
      return _months[t.month - 1];
    case 'c':
      return pyStrftime(t, '%a %b %e %H:%M:%S %Y');
    case 'C':
      return _pad(t.year ~/ 100, 2);
    case 'd':
      return _pad(t.day, 2);
    case 'D' || 'x':
      return pyStrftime(t, '%m/%d/%y');
    case 'e':
      return _pad(t.day, 2, ' ');
    case 'f':
      return _pad(t.millisecond * 1000 + t.microsecond, 6);
    case 'F':
      return pyStrftime(t, '%Y-%m-%d');
    case 'g':
      return _pad(_isoWeek(t).$1 % 100, 2);
    case 'G':
      return _pad(_isoWeek(t).$1, 4);
    case 'H':
      return _pad(t.hour, 2);
    case 'I':
      return _pad(hour12, 2);
    case 'j':
      return _pad(_dayOfYear(t), 3);
    case 'k':
      return _pad(t.hour, 2, ' ');
    case 'l':
      return _pad(hour12, 2, ' ');
    case 'm':
      return _pad(t.month, 2);
    case 'M':
      return _pad(t.minute, 2);
    case 'n':
      return '\n';
    case 'p':
      return t.hour < 12 ? 'AM' : 'PM';
    case 'r':
      return pyStrftime(t, '%I:%M:%S %p');
    case 'R':
      return pyStrftime(t, '%H:%M');
    case 'S':
      return _pad(t.second, 2);
    case 't':
      return '\t';
    case 'T' || 'X':
      return pyStrftime(t, '%H:%M:%S');
    case 'u':
      return '${t.weekday}';
    case 'U':
      // Weeks from the first Sunday; the days before it are week 0.
      return _pad((_dayOfYear(t) + 6 - t.weekday % 7) ~/ 7, 2);
    case 'V':
      return _pad(_isoWeek(t).$2, 2);
    case 'w':
      return '${t.weekday % 7}';
    case 'W':
      // Weeks from the first Monday.
      return _pad((_dayOfYear(t) + 6 - (t.weekday - 1)) ~/ 7, 2);
    case 'y':
      return _pad(t.year % 100, 2);
    case 'Y':
      return _pad(t.year, 4);
    case 'z' || 'Z':
      return ''; // a naive time has no zone
    case '%':
      return '%';
  }
  throw FormatException('Unknown date code %$code');
}

/// [time] written with [pattern]'s `%` codes: `aAbBcCdDeFgGhHIjklmMnprRS
/// tTuUVwWxXyYzZ%` and `%f` (microseconds), `%-d` and the like without the
/// padding, and the `E` and `O` modifiers, which change nothing in the C
/// locale. Throws a [FormatException] for any other code and for a `%`
/// with nothing after it.
String pyStrftime(DateTime time, String pattern) {
  assert(time.isUtc, naiveTimeMessage);
  final out = StringBuffer();
  var i = 0;
  while (i < pattern.length) {
    final ch = pattern[i++];
    if (ch != '%') {
      out.write(ch);
      continue;
    }
    // Python's "%:z": the offset with a colon, nothing for a naive time.
    if (pattern.startsWith(':z', i)) {
      i += 2;
      continue;
    }
    var unpadded = false;
    if (i < pattern.length && pattern[i] == '-') {
      unpadded = true;
      i++;
    }
    if (i < pattern.length &&
        (pattern[i] == 'E' || pattern[i] == 'O') &&
        i + 1 < pattern.length) {
      i++;
    }
    if (i >= pattern.length) {
      throw const FormatException('A % with no date code after it');
    }
    final code = pattern[i++];
    // Python's own codes take no flag or modifier: "%-f" is not "%f".
    if (code == 'f' && pattern[i - 2] != '%') {
      throw const FormatException('Unknown date code %-f');
    }
    var text = _code(code, time);
    if (unpadded && _unpaddable.contains(code)) {
      text = text.replaceFirst(RegExp(r'^[0 ]+(?=.)'), '');
    }
    out.write(text);
  }
  return out.toString();
}
