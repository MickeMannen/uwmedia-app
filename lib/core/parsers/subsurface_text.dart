/// The text forms Subsurface writes values in, ported from the helpers at
/// the top of `parsers/subsurface.py` of the Python app.
library;

import 'package:uwmedia_app/core/util/py_parse.dart';

/// Seconds from "m:ss", "h:mm:ss", "12.5 min", "90 s" or a plain number of
/// seconds; 0 for anything else.
int parseTimeStr(String text) {
  var timeStr = text.pyStrip();
  var isMinutes = false;

  if (timeStr.endsWith('min')) {
    isMinutes = true;
    timeStr = timeStr.substring(0, timeStr.length - 3).pyStrip();
  } else if (timeStr.endsWith('s')) {
    timeStr = timeStr.substring(0, timeStr.length - 1).pyStrip();
  }

  if (timeStr.contains(':')) {
    final parts = timeStr.split(':');
    if (parts.length == 2 || parts.length == 3) {
      var seconds = 0;
      for (final part in parts) {
        final value = pyInt(part);
        if (value == null) {
          return 0;
        }
        seconds = seconds * 60 + value;
      }
      return seconds;
    }
  }
  final value = pyFloat(timeStr);
  if (value == null || !value.isFinite) {
    return 0;
  }
  return (isMinutes ? value * 60 : value).toInt();
}

const double _ftToM = 0.3048;
const double _psiToBar = 0.0689476;

/// A number with one of [units] after it: the number and which unit, or
/// `null` when the number does not parse. The first unit the text ends
/// with wins; `''` in [units] stands for no unit.
(double value, String unit)? _withUnit(String text, List<String> units) {
  final trimmed = text.pyStrip();
  for (final unit in units) {
    if (unit.isEmpty || trimmed.endsWith(unit)) {
      final number = pyFloat(
        trimmed.substring(0, trimmed.length - unit.length),
      );
      return number == null ? null : (number, unit);
    }
  }
  return null;
}

/// Metres from "12.5 m", "33 ft" or a plain number; `null` for anything
/// else. (A text ending in "ft" never ends in "m", so the order is free.)
double? tryParseDepthStr(String text) {
  final parsed = _withUnit(text, ['m', 'ft', '']);
  if (parsed == null) {
    return null;
  }
  return parsed.$2 == 'ft' ? parsed.$1 * _ftToM : parsed.$1;
}

/// °C from "28.5 C", "50 F", "300.15 K" or a plain number; `null` for
/// anything else.
double? tryParseTempStr(String text) {
  final parsed = _withUnit(text, ['C', 'F', 'K', '']);
  if (parsed == null) {
    return null;
  }
  return switch (parsed.$2) {
    'F' => (parsed.$1 - 32.0) * 5.0 / 9.0,
    'K' => parsed.$1 - 273.15,
    _ => parsed.$1,
  };
}

/// Bar from "200.0 bar", "3000 psi" or a plain number; `null` for anything
/// else.
double? tryParsePressureStr(String text) {
  final parsed = _withUnit(text, ['bar', 'psi', '']);
  if (parsed == null) {
    return null;
  }
  return parsed.$2 == 'psi' ? parsed.$1 * _psiToBar : parsed.$1;
}

/// As in Python: 0.0 for a depth that does not parse.
double parseDepthStr(String text) => tryParseDepthStr(text) ?? 0.0;

/// As in Python: 0.0 for a temperature that does not parse.
double parseTempStr(String text) => tryParseTempStr(text) ?? 0.0;

/// As in Python: 0.0 for a pressure that does not parse.
double parsePressureStr(String text) => tryParsePressureStr(text) ?? 0.0;

/// A gas percentage from "32.0%", a fraction ("0.32") or a percentage
/// ("50"); [defaultValue] when there is none or it does not parse.
double parseGasPercent(String? text, double defaultValue) {
  if (text == null || text.isEmpty) {
    return defaultValue;
  }
  final gas = text.pyStrip();
  if (gas.endsWith('%')) {
    return pyFloat(gas.substring(0, gas.length - 1)) ?? defaultValue;
  }
  final value = pyFloat(gas);
  if (value == null) {
    return defaultValue;
  }
  return value <= 1.0 ? value * 100.0 : value;
}

/// Whether [text] is a time [parseTimeStr] reads, and not its 0 for
/// anything else.
bool isTimeStr(String text) {
  var timeStr = text.pyStrip();
  if (timeStr.endsWith('min')) {
    timeStr = timeStr.substring(0, timeStr.length - 3).pyStrip();
  } else if (timeStr.endsWith('s')) {
    timeStr = timeStr.substring(0, timeStr.length - 1).pyStrip();
  }
  if (timeStr.contains(':')) {
    final parts = timeStr.split(':');
    if (parts.length == 2 || parts.length == 3) {
      return parts.every((part) => pyInt(part) != null);
    }
  }
  final value = pyFloat(timeStr);
  return value != null && value.isFinite;
}
