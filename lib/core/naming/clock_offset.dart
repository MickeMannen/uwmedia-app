/// The camera's clock against the dive computer's (Python
/// `utils/clock_offset.py`): how the Color page shows the offset and reads a
/// dive time typed from the computer's display.
///
/// A clip is matched to its dive by the time the camera wrote into the
/// file. That time is off by the camera's timezone setting (whole hours,
/// usually) and by however far its clock has drifted. The Color page lets
/// the user set both; only the matching uses the total, the file's own time
/// is written to the output unchanged.
library;

import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

/// "+2 h 14 s", "-37 s", "+1 h", "0 s": an offset the way the page shows
/// it.
String formatOffset(double seconds) {
  var total = pyRound(seconds);
  if (total == 0) {
    return '0 s';
  }
  final sign = total > 0 ? '+' : '-';
  total = total.abs();
  final hours = total ~/ 3600;
  final minutes = total % 3600 ~/ 60;
  final secs = total % 60;
  final parts = [
    if (hours != 0) '$hours h',
    if (minutes != 0) '$minutes min',
    if (secs != 0) '$secs s',
  ];
  return sign + parts.join(' ');
}

final _unitsText = RegExp(r'^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$');
final _digits = RegExp(r'^\d+$');

/// Seconds from what a dive computer shows as its dive time: "12:34",
/// "1:02:03", "12.34" (minutes.seconds the way some people type it), "754"
/// (plain seconds), "12m34s". `null` when it is not a time.
///
/// Only the digits 0-9 count; Python also reads the digits of other
/// scripts.
double? parseDiveTime(String? text) {
  final s = (text ?? '').pyStrip().toLowerCase().replaceAll(' ', '');
  if (s.isEmpty) {
    return null;
  }
  if (s.contains('m') || s.contains('s') || s.contains('h')) {
    final m = _unitsText.firstMatch(s);
    if (m == null || (m[1] == null && m[2] == null && m[3] == null)) {
      return null;
    }
    double of(String? g) => g == null ? 0 : double.parse(g);
    return of(m[1]) * 3600 + of(m[2]) * 60 + of(m[3]);
  }
  final String sep;
  final dotted = s.split('.');
  if (s.contains(':')) {
    sep = ':';
  } else if (dotted.length == 2 &&
      dotted.every(_digits.hasMatch) &&
      dotted[1].length == 2) {
    sep = '.';
  } else {
    return pyFloat(s);
  }
  final parts = s.split(sep);
  if (!parts.every(_digits.hasMatch) || parts.length > 3) {
    return null;
  }
  final nums = [
    for (var i = parts.length; i < 3; i++) 0.0,
    for (final p in parts) double.parse(p),
  ];
  final [h, mi, se] = nums;
  if (se >= 60 || (parts.length == 3 && mi >= 60)) {
    return null;
  }
  return h * 3600 + mi * 60 + se;
}
