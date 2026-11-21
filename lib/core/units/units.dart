/// Unit systems for everything the app shows, ported from `utils/units.py`
/// of the Python app (spec §5.4). Every value in the data model stays SI:
/// metres, bar, °C. Only the display converts, here.
///
/// Python keeps the system in force in a global (the app setting, or a
/// one-off override); here every function takes it, and [resolveUnits]
/// gives the one a layout renders in.
///
/// Display rounding follows the computers; the per-brand depth decimals
/// are in `hud_rules.json` (`display.depth_decimals`).
library;

import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

enum UnitSystem {
  metric('metric', 'Metric (m, bar, °C)'),
  imperial('imperial', 'Imperial (ft, psi, °F)');

  const UnitSystem(this.key, this.label);

  /// The name in settings and layouts.
  final String key;
  final String label;
}

const double ftPerM = 3.280839895;
const double psiPerBar = 14.5037738;
const double cuftPerL = 0.0353146667;

/// The unit system a setting, a layout key or a CLI value names: imperial
/// for "imperial", "ft", "feet", "psi" or "us" in any case, else metric.
UnitSystem normalizeUnits(Object? value) {
  final text = (value == null || value == false || value == 0)
      ? ''
      : '$value'.pyStrip().toLowerCase();
  return const {'imperial', 'ft', 'feet', 'psi', 'us'}.contains(text)
      ? UnitSystem.imperial
      : UnitSystem.metric;
}

/// The system a layout renders in: its own `units` key, else [current].
UnitSystem resolveUnits(Map<String, dynamic>? layout, UnitSystem current) {
  final own = layout?['units'];
  final set = own != null && own != false && own != 0 && own != '';
  return set ? normalizeUnits(own) : current;
}

bool _imperial(UnitSystem units) => units == UnitSystem.imperial;

// --- conversions (SI in, display units out) ---

double depth(double metres, UnitSystem units) =>
    _imperial(units) ? metres * ftPerM : metres;

double pressure(double bar, UnitSystem units) =>
    _imperial(units) ? bar * psiPerBar : bar;

double temperature(double celsius, UnitSystem units) =>
    _imperial(units) ? celsius * 1.8 + 32.0 : celsius;

/// Volumetric SAC: L/min, or cuft/min in imperial.
double volumeRate(double litresPerMin, UnitSystem units) =>
    _imperial(units) ? litresPerMin * cuftPerL : litresPerMin;

double depthToMetres(double value, UnitSystem units) =>
    _imperial(units) ? value / ftPerM : value;

double pressureToBar(double value, UnitSystem units) =>
    _imperial(units) ? value / psiPerBar : value;

double temperatureToCelsius(double value, UnitSystem units) =>
    _imperial(units) ? (value - 32.0) / 1.8 : value;

/// A stop depth as the computers label it: whole metres, or the feet stop
/// level. 3 m stops are 10 ft stops and the 5 m safety stop is 15 ft, so
/// 4.4 to 5.6 m is 15 ft and everything else the nearest 10 ft.
double stopDepth(double metres, UnitSystem units) {
  if (!_imperial(units)) {
    return pyRound(metres).toDouble();
  }
  if (4.4 <= metres && metres <= 5.6) {
    return 15.0;
  }
  final feet = pyRound(metres * ftPerM / 10.0) * 10;
  return (feet > 10 ? feet : 10).toDouble();
}

// --- labels ---

String depthLabel(UnitSystem units) => _imperial(units) ? 'ft' : 'm';

String pressureLabel(UnitSystem units, {bool upper = true}) {
  final label = _imperial(units) ? 'psi' : 'bar';
  return upper ? label.toUpperCase() : label;
}

String temperatureLabel(UnitSystem units) => _imperial(units) ? '°F' : '°C';

String sacLabel(UnitSystem units) => _imperial(units) ? 'psi/min' : 'bar/min';

String volumeRateLabel(UnitSystem units) =>
    _imperial(units) ? 'cuft/min' : 'L/min';

String depthRateLabel(UnitSystem units) =>
    _imperial(units) ? 'ft/min' : 'm/min';

/// The label for a `unit:<kind>` field: depth, pressure, pressure_lower,
/// temp, sac, volume_rate, depth_rate; empty for any other kind.
String unitLabel(String kind, UnitSystem units) => switch (kind) {
  'depth' => depthLabel(units),
  'pressure' => pressureLabel(units),
  'pressure_lower' => pressureLabel(units, upper: false),
  'temp' => temperatureLabel(units),
  'sac' => sacLabel(units),
  'volume_rate' => volumeRateLabel(units),
  'depth_rate' => depthRateLabel(units),
  _ => '',
};

/// How many decimals a brand shows on a depth in [units]: its
/// `display.depth_decimals` rule, else 1 in metres and 0 in feet.
int depthDecimals(Map<String, dynamic>? displayRule, UnitSystem units) {
  final rule = displayRule?['depth_decimals'];
  if (rule is Map<String, dynamic> && rule.containsKey(units.key)) {
    return (rule[units.key] as num).toInt();
  }
  return units == UnitSystem.metric ? 1 : 0;
}

String formatDepth(
  double? metres,
  UnitSystem units, {
  int? decimals,
  Map<String, dynamic>? displayRule,
}) {
  if (metres == null) {
    return '--';
  }
  return pyFormatFixed(
    depth(metres, units),
    decimals ?? depthDecimals(displayRule, units),
  );
}

String formatPressure(double? bar, UnitSystem units) =>
    bar == null ? '--' : '${pyRound(pressure(bar, units))}';

String formatTemperature(
  double? celsius,
  UnitSystem units, {
  int decimals = 0,
}) => celsius == null
    ? '--'
    : pyFormatFixed(temperature(celsius, units), decimals);
