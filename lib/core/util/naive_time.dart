/// Naive local timestamps (spec §4): every time in the dive model is the
/// wall-clock time where the dive or the recording happened, with no zone.
///
/// Dart has no naive date-time type, so the model carries them in
/// `DateTime` values flagged UTC and uses only their calendar fields. That
/// keeps arithmetic on the wall clock: a local `DateTime` would move by an
/// hour across a daylight-saving change of the machine the app runs on.
/// Never call `toLocal()` or `toUtc()` on one, and never build one with
/// `DateTime(...)` or `DateTime.now()`.
library;

/// The message of the asserts that guard the model against a local
/// `DateTime`.
const naiveTimeMessage =
    'a naive timestamp must be a UTC-flagged DateTime from naive_time.dart';

/// A naive timestamp from its calendar fields.
DateTime naive(
  int year, [
  int month = 1,
  int day = 1,
  int hour = 0,
  int minute = 0,
  int second = 0,
  int millisecond = 0,
  int microsecond = 0,
]) => DateTime.utc(
  year,
  month,
  day,
  hour,
  minute,
  second,
  millisecond,
  microsecond,
);

final _naiveText = RegExp(r'^(\d{4}-\d\d-\d\d)T\d\d:\d\d:\d\d(\.\d{1,6})?$');

/// Parses `YYYY-MM-DDTHH:MM:SS[.ffffff]`, the text Python's
/// `datetime.isoformat()` gives for a naive datetime and the form the
/// model's own JSON uses. Anything else is refused: a zone suffix, another
/// layout, or a date that does not exist (`2026-02-30`). Dates in log files
/// have their own parsers.
DateTime parseNaive(String text) {
  final match = _naiveText.firstMatch(text);
  if (match == null) {
    throw FormatException('Not a naive ISO timestamp', text);
  }
  final time = DateTime.parse('${text}Z');
  if (!formatNaive(time).startsWith(match.group(1)!)) {
    throw FormatException('No such date', text);
  }
  return time;
}

/// Python `datetime.isoformat()` of a naive datetime: seconds, and six
/// fractional digits only when there is a fraction.
String formatNaive(DateTime time) {
  assert(time.isUtc, naiveTimeMessage);
  String two(int value) => value.toString().padLeft(2, '0');
  final date =
      '${time.year.toString().padLeft(4, '0')}-${two(time.month)}-${two(time.day)}';
  final clock = '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  final micros = time.millisecond * 1000 + time.microsecond;
  final fraction = micros == 0 ? '' : '.${micros.toString().padLeft(6, '0')}';
  return '${date}T$clock$fraction';
}

/// The machine's clock now, as a naive timestamp to the second (Python's
/// `datetime.now()` where a log is stamped with the time of saving).
DateTime naiveNow() {
  final now = DateTime.now();
  return naive(now.year, now.month, now.day, now.hour, now.minute, now.second);
}

/// The machine's offset from UTC, in minutes, at the wall-clock [time] in
/// its own zone (Python `time.astimezone().utcoffset()`): a summer date
/// gets the summer offset whatever the date today.
int localUtcOffsetMinutesAt(DateTime time) {
  assert(time.isUtc, naiveTimeMessage);
  return DateTime(
    time.year,
    time.month,
    time.day,
    time.hour,
    time.minute,
    time.second,
  ).timeZoneOffset.inMinutes;
}
