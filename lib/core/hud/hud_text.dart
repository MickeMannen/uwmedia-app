/// What an overlay element says: the value of its field at a waypoint and
/// how it is written (spec §5.4), and the lines of a state badge. Ported
/// from `gui/hud_renderer.py` of the Python app (`resolve_element_text`,
/// `format_telemetry_value`, `apply_value_format`, `text_parts`,
/// `badge_lines`). Nothing here measures or draws; the renderer and the
/// Overlay Designer both start from these strings.
library;

import 'package:uwmedia_app/core/hud/hud_geometry.dart';
import 'package:uwmedia_app/core/hud/hud_ops.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/rules/hud_gas.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/units/units.dart' as u;
import 'package:uwmedia_app/core/units/units.dart' show UnitSystem;
import 'package:uwmedia_app/core/util/py_round.dart';

const List<String> alignOptions = ['left', 'center', 'right'];
const List<String> valignOptions = ['top', 'middle', 'bottom'];
const List<String> smallSuffixStyles = ['seconds', 'decimals'];
const double smallSuffixDefaultScale = 0.35;

/// Text element `orientation`: "horizontal" (the default, absent),
/// "stacked" (upright letters one under the other), "up" (the line turned
/// to read bottom to top) or "down" (turned to read top to bottom).
const List<String> textOrientations = ['horizontal', 'stacked', 'up', 'down'];
const List<String> verticalOrientations = ['stacked', 'up', 'down'];

/// Of the font size, per stacked letter.
const double stackedLineAdvance = 1.05;

/// The prefix [badgeLines] puts on a line shown with the Perdix's check
/// mark.
const String checkMark = '✓ ';

/// A text element without an `outline` key draws no black outline.
const bool textOutlineDefault = false;

/// Python truthiness of a JSON value.
bool truthy(Object? value) => switch (value) {
  null || false => false,
  final num number => number != 0,
  final String text => text.isNotEmpty,
  final List<dynamic> list => list.isNotEmpty,
  final Map<dynamic, dynamic> map => map.isNotEmpty,
  _ => true,
};

/// Python `float(value)` of a JSON value; `null` where Python raises.
double? pyFloatOf(Object? value) => switch (value) {
  final num number => number.toDouble(),
  true => 1.0,
  false => 0.0,
  final String text => double.tryParse(text.trim()),
  _ => null,
};

/// Python `"#RRGGBB"` (the "#" optional) to a colour.
Rgb hexRgb(String hex) {
  var start = 0;
  while (start < hex.length && hex[start] == '#') {
    start++;
  }
  int part(int i) =>
      int.parse(hex.substring(start + i, start + i + 2), radix: 16);
  return (part(0), part(2), part(4));
}

/// Python `f"{n:02d}"`.
String _d2(int n) => n < 0 ? '-${-n}' : n.toString().padLeft(2, '0');

int _floorDiv(num a, num b) => (a / b).floor();

/// Python `a % b` for a positive [b]: never negative.
num _mod(num a, num b) => a - b * (a / b).floor();

/// The page's brand, model, rules and unit system: what every lookup of a
/// render needs. [rules] already carries the page's own `rules` block.
class HudContext {
  HudContext(
    this.rules,
    this.manufacturer,
    this.model,
    this.units, {
    this.flashAt,
  });

  /// For [layout] with the app's [rules] and the unit system in force.
  factory HudContext.of(
    Map<String, dynamic> layout,
    HudRules rules,
    UnitSystem currentUnits, {
    double? flashAt,
  }) => HudContext(
    rules.withOverrides(layout['rules']),
    rulesManufacturer(layout),
    layout.containsKey('model') ? layout['model'] as String? : 'Perdix2',
    u.resolveUnits(layout, currentUnits),
    flashAt: flashAt,
  );

  final HudRules rules;
  final String? manufacturer;
  final String? model;
  final UnitSystem units;

  /// The video's own time in seconds, which a video's flashing values
  /// flash by (spec §10 issue 9, owner 2026-11-19: the first half of
  /// each second in the flashing colour); `null` for a photo, whose
  /// flashing values keep the flashing colour.
  final double? flashAt;

  /// The seconds a flashing element of [wp] follows.
  double flashTime(Waypoint wp) => flashAt ?? elapsedOf(wp);

  Object? rule(String key) => rules.getRuleConfig(manufacturer, model, key);
}

/// The brand a layout's colour and warning rules come from: its
/// `rules_profile` when set (a custom template borrowing a brand's
/// scheme), else its `manufacturer`.
String? rulesManufacturer(Map<String, dynamic> layout) {
  final profile = layout['rules_profile'];
  if (truthy(profile)) {
    return profile as String?;
  }
  return layout.containsKey('manufacturer')
      ? layout['manufacturer'] as String?
      : 'Shearwater';
}

/// Python `getattr(waypoint, field, None)`: a model field or one of the
/// computed values, by its name in the Python model.
Object? waypointValue(Waypoint? wp, String field) {
  if (wp == null) {
    return null;
  }
  return switch (field) {
    'timestamp' => wp.timestamp,
    'depth' => wp.depth,
    'temp' => wp.temp,
    'max_depth' => wp.maxDepth,
    'deco_stop_depth' => wp.decoStopDepth,
    'ceiling' => wp.ceiling,
    'tts' => wp.tts,
    'ndl' => wp.ndl,
    'time_since_start' => wp.timeSinceStart,
    'dive_time' => wp.diveTime,
    'tanks' => wp.tanks,
    'next_stop_depth' => wp.nextStopDepth,
    'next_stop_time' => wp.nextStopTime,
    'air_remaining' => wp.airRemaining,
    'ascent_rate' => wp.ascentRate,
    'n2_tissue_load' => wp.n2TissueLoad,
    'pressure_sac' => wp.pressureSac,
    'volume_sac' => wp.volumeSac,
    'rmv' => wp.rmv,
    'heart_rate' => wp.heartRate,
    'cns' => wp.cns,
    'po2' => wp.po2,
    'divemode' => wp.divemode,
    'gf' => wp.gf,
    'surf_gf' => wp.surfGf,
    'switchmix' => wp.switchmix,
    'battery' => wp.battery,
    'cleared_gas_mix' => wp.clearedGasMix,
    'setpoint' => wp.setpoint,
    'gas_o2_percent' => wp.gasO2Percent,
    'gas_he_percent' => wp.gasHePercent,
    'diluent_o2_percent' => wp.diluentO2Percent,
    'diluent_he_percent' => wp.diluentHePercent,
    'po2_1' => wp.po2_1,
    'po2_2' => wp.po2_2,
    'po2_3' => wp.po2_3,
    'dive_alerts' => wp.diveAlerts,
    'log_filename' => wp.logFilename,
    'primary_tank_pressure' => wp.primaryTankPressure,
    'primary_tank_name' => wp.primaryTankName,
    'secondary_tank_pressure' => wp.secondaryTankPressure,
    'secondary_tank_name' => wp.secondaryTankName,
    'circuit' => wp.circuit,
    'diluent_po2' => wp.diluentPo2,
    'gasmix' => wp.gasmix,
    // the breathed gas as a Perdix 3 writes it: "32%", "18/50"
    'gas_percent' => wp.gasPercent,
    _ => null,
  };
}

/// The seconds a blink follows in a photo: the dive time, else the time
/// since the start. A whole second, so the flashing colour (see
/// [HudContext.flashAt] for a video).
double elapsedOf(Waypoint wp) => (wp.diveTime ?? wp.timeSinceStart).toDouble();

/// (main, suffix) for the `small_suffix` text style, the way Garmin draws
/// "00:00" as a large "00" with a small, top-aligned ":00" and "12.3" as
/// "12" + ".3". "seconds" splits at the first ":", "decimals" at the first
/// "." (the separator stays with the suffix). What does not split comes
/// back whole.
(String, String) splitSmallSuffix(String text, Object? style) {
  if (text.isEmpty || !smallSuffixStyles.contains(style)) {
    return (text, '');
  }
  final index = text.indexOf(style == 'seconds' ? ':' : '.');
  if (index <= 0) {
    return (text, '');
  }
  return (text.substring(0, index), text.substring(index));
}

/// The size of the NDL's "+" against its digits when the element sets
/// `small_suffix_scale` (a Descent X50i's larger plus, level with the top
/// of the digits), else `null`: the small raised plus.
double? plusSignScale(Map<String, dynamic> elem) {
  final raw = elem['small_suffix_scale'];
  final scale = truthy(raw) ? pyFloatOf(raw) : 0.0;
  if (scale == null) {
    return null;
  }
  return scale > 0 ? scale.clamp(0.1, 1.0) : null;
}

/// (main, suffix, suffix scale) a text element draws: the NDL "99+" (a
/// small plus sign) and the `small_suffix` element key.
(String, String, double) textParts(
  String field,
  String text,
  Map<String, dynamic> elem,
) {
  if ((field == 'ndl' || field == 'ndl_before_clear') && text.endsWith('+')) {
    return (
      text.substring(0, text.length - 1),
      '+',
      plusSignScale(elem) ?? smallSuffixDefaultScale,
    );
  }
  final style = elem['small_suffix'];
  if (truthy(style)) {
    final (main, suffix) = splitSmallSuffix(text, style);
    if (suffix.isNotEmpty) {
      final scale = elem.containsKey('small_suffix_scale')
          ? pyFloatOf(elem['small_suffix_scale']) ?? smallSuffixDefaultScale
          : smallSuffixDefaultScale;
      return (main, suffix, scale.clamp(0.1, 1.0));
    }
  }
  return (text, '', smallSuffixDefaultScale);
}

/// The fields that carry a unit, and which one (for unit suffixes and the
/// `unit:<kind>` labels).
const Map<String, String> unitKindOfField = {
  'depth': 'depth',
  'max_depth': 'depth',
  'safety_stop_depth': 'depth',
  'deco_stop_depth': 'depth',
  'next_stop_depth': 'depth',
  'ceiling': 'depth',
  'mod': 'depth',
  'primary_tank_pressure': 'pressure',
  'secondary_tank_pressure': 'pressure',
  'temp': 'temp',
  'pressure_sac': 'sac',
  'volume_sac': 'volume_rate',
  'avg_depth': 'depth',
  'min_temp': 'temp',
  'ascent_rate_value': 'depth_rate',
};

String? unitKindOf(String field) =>
    field.startsWith('tank_pressure:') ? 'pressure' : unitKindOfField[field];

/// The unit a text element draws after its value when `unit_suffix` is on:
/// the field's own unit in [units] (or the element's `unit_kind`). Empty
/// when there is nothing to draw.
String unitSuffixText(
  Map<String, dynamic> elem,
  String field,
  UnitSystem units,
) {
  if (!truthy(elem['unit_suffix'])) {
    return '';
  }
  final named = elem['unit_kind'];
  final kind = truthy(named) ? '$named' : unitKindOf(field);
  return kind == null ? '' : u.unitLabel(kind, units);
}

/// A telemetry value as text, in [units] (the data is SI, the display
/// converts). [displayRule] is the brand's `display` rule: the depth
/// decimals per system, `percent_fields` (written with a % sign),
/// `gf99_on_gassing_text` (what GF99 reads at or below 0) and `air_text`
/// (how the brand writes air).
String formatTelemetryValue(
  String field,
  Object? rawVal,
  UnitSystem units, [
  Object? displayRule,
]) {
  if (displayRule is Map<String, dynamic> && rawVal != null) {
    if (field == 'gf' && truthy(displayRule['gf99_on_gassing_text'])) {
      final value = pyFloatOf(rawVal);
      if (value != null && value <= 0) {
        return '${displayRule['gf99_on_gassing_text']}';
      }
    }
    final text = _formatTelemetryValue(field, rawVal, units, displayRule);
    if (field == 'gasmix' && text == 'AIR' && truthy(displayRule['air_text'])) {
      return '${displayRule['air_text']}';
    }
    final percent = displayRule['percent_fields'];
    if (percent is List<dynamic> &&
        percent.contains(field) &&
        text != '--' &&
        text != 'wait') {
      return '$text%';
    }
    return text;
  }
  return _formatTelemetryValue(field, rawVal, units, displayRule);
}

String _str(Object? value) => switch (value) {
  true => 'True',
  false => 'False',
  null => 'None',
  _ => '$value',
};

String _formatTelemetryValue(
  String field,
  Object? rawVal,
  UnitSystem units,
  Object? displayRule,
) {
  final imperial = units == UnitSystem.imperial;
  double number() => (rawVal! as num).toDouble();
  if (field == 'gasmix') {
    return rawVal != null ? _str(rawVal) : 'N/A';
  }
  if (field.startsWith('tank_name:')) {
    return truthy(rawVal) ? _str(rawVal) : field.replaceAll('tank_name:', '');
  }
  if (field == 'primary_tank_pressure' ||
      field == 'secondary_tank_pressure' ||
      field.startsWith('tank_pressure:')) {
    return rawVal == null ? '--' : u.formatPressure(number(), units);
  }
  if (field == 'primary_tank_name' || field == 'secondary_tank_name') {
    return truthy(rawVal) ? _str(rawVal) : '--';
  }
  if (rawVal != null) {
    switch (field) {
      case 'ndl' || 'ndl_before_clear' || 'air_remaining':
        final minutes = (number() / 60).truncate();
        if (field == 'air_remaining') {
          return '$minutes';
        }
        // The last minute before deco is "00", not "99+".
        return minutes > 99 ? '99+' : _d2(minutes < 0 ? 0 : minutes);
      case 'dive_time' || 'tts' || 'next_stop_time':
        final value = rawVal as num;
        return '${_d2(_floorDiv(value, 60))}:${_d2(_mod(value, 60).truncate())}';
      case 'depth' || 'max_depth':
        return u.formatDepth(
          number(),
          units,
          displayRule: displayRule is Map<String, dynamic> ? displayRule : null,
        );
      case 'deco_stop_depth' || 'next_stop_depth':
        // A stop level: whole metres, or the feet stop level.
        return imperial
            ? pyFormatFixed(u.stopDepth(number(), units), 0)
            : pyFormatFixed(number(), 1);
      case 'ceiling':
        return pyFormatFixed(u.depth(number(), units), 1);
      case 'temp':
        return imperial
            ? u.formatTemperature(number(), units)
            : pyFormatFixed(u.temperature(number(), units), 1);
      case 'gf' || 'surf_gf':
        // Whole percent, as GF99 and SurfGF read on a Perdix.
        return '${pyRound(number())}';
      case 'mod':
        return pyFormatFixed(u.depth(number(), units), 0);
      case 'volume_sac':
        return imperial
            ? pyFormatFixed(u.volumeRate(number(), units), 2)
            : '${number().truncate()}';
    }
  }
  if (field == 'pressure_sac') {
    // A Perdix shows "wait" until it has two minutes of data.
    if (rawVal == null) {
      return 'wait';
    }
    return imperial
        ? pyFormatFixed(u.pressure(number(), units), 0)
        : pyFormatFixed(number(), 1);
  }
  if (rawVal == null) {
    return '--';
  }
  if (rawVal is double) {
    return pyFormatFixed(rawVal, 1);
  }
  return _str(rawVal);
}

/// [_formatValue], then in capitals where the element says `uppercase`
/// (a Suunto Nautic writes "NX32", "AIR").
String? applyValueFormat(
  Map<String, dynamic> elem,
  String? val,
  Object? rawVal,
  UnitSystem units,
) {
  final formatted = _formatValue(elem, val, rawVal, units);
  return truthy(elem['uppercase']) && formatted != null
      ? formatted.toUpperCase()
      : formatted;
}

/// An element's `value_format` on a resolved value: "minutes", "m:ss",
/// "minutes_prime" ("24′", an NDL past 99 minutes ">99′"), "m'ss" ("2′50"),
/// "integer", "decimal1", "decimal2" or "decimal2_no_lead" (".41"). Only a
/// number is reformatted; a value with a unit is converted to [units]
/// first.
String? _formatValue(
  Map<String, dynamic> elem,
  String? val,
  Object? rawVal,
  UnitSystem units,
) {
  final valueFormat = elem['value_format'];
  if (!truthy(valueFormat) || rawVal is! num) {
    return val;
  }
  if (valueFormat == 'minutes') {
    return '${_floorDiv(rawVal, 60)}';
  }
  if (valueFormat == 'm:ss') {
    // A Descent X50i's dive time and TTS: "0:00", "1:16".
    return '${_floorDiv(rawVal, 60)}:${_d2(_mod(rawVal, 60).truncate())}';
  }
  if (valueFormat == 'minutes_prime') {
    // A Suunto's minutes with a prime: "24′"; an NDL at the 100-minute
    // cap ">99′" (EON Core manual p.25, Nautic p.21).
    final minutes = _floorDiv(rawVal, 60);
    return elem['field'] == 'ndl' && minutes > 99 ? '>99′' : '$minutes′';
  }
  if (valueFormat == "m'ss") {
    // A Suunto's stop counter and the Nautic's dive time: "2′50", "24′05".
    return '${_floorDiv(rawVal, 60)}′${_d2(_mod(rawVal, 60).truncate())}';
  }
  final field = elem['field'] is String ? elem['field'] as String : '';
  var value = rawVal.toDouble();
  switch (unitKindOf(field)) {
    case 'depth':
      value = field == 'deco_stop_depth' || field == 'next_stop_depth'
          ? u.stopDepth(value, units)
          : u.depth(value, units);
    case 'temp':
      value = u.temperature(value, units);
    case 'pressure':
      value = u.pressure(value, units);
    case 'volume_rate':
      value = u.volumeRate(value, units);
  }
  switch (valueFormat) {
    case 'integer':
      return pyFormatFixed(value, 0);
    case 'decimal2':
      return pyFormatFixed(value, 2);
    case 'decimal1':
      return pyFormatFixed(value, 1);
    case 'decimal2_no_lead':
      final text = pyFormatFixed(value, 2);
      return text.startsWith('0.') ? text.substring(1) : text;
  }
  return val;
}

const List<String> _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _hhmm(DateTime t) => '${_d2(t.hour)}:${_d2(t.minute)}';

/// (display text, raw value) of one text element's [field] at [waypoint]:
/// the chain the renderer draws with, so the Overlay Designer measures the
/// string it draws. A missing waypoint gives "--" or `null` everywhere.
(String?, Object?) resolveElementText(
  HudContext ctx,
  String field,
  Waypoint? waypoint, [
  List<Waypoint>? waypoints,
]) {
  final rules = ctx.rules;
  final manufacturer = ctx.manufacturer;
  final model = ctx.model;
  final units = ctx.units;
  // The brand's depth decimals per unit system, among others.
  final display = ctx.rule('display');
  String format(String asField, Object? raw) =>
      formatTelemetryValue(asField, raw, units, display);

  switch (field) {
    case 'safety_stop':
      return (rules.getSafetyStopText(manufacturer, model, waypoint), null);
    case 'safety_stop_depth':
      // The brand's fixed safety stop depth (a Suunto's 3.0 m, 10 ft), in
      // the units in force.
      final rule = ctx.rule('safety_stop');
      final raw = rule is Map<String, dynamic> ? rule['stop_depth'] : null;
      return (format('depth', raw), raw);
    case 'time_of_day':
      return (waypoint == null ? null : _hhmm(waypoint.timestamp), null);
    case 'eod':
      // End of dive: the time of day the diver can expect to surface.
      if (waypoint == null) {
        return (null, null);
      }
      return (
        _hhmm(waypoint.timestamp.add(Duration(seconds: waypoint.tts ?? 0))),
        null,
      );
    case 'date':
      // A Shearwater's DATE info screen: "03-Mar-20".
      if (waypoint == null) {
        return (null, null);
      }
      final t = waypoint.timestamp;
      return (
        '${_d2(t.day)}-${_months[t.month - 1]}-${_d2(t.year % 100)}',
        null,
      );
    case 'avg_depth':
      final raw = rules.averageDepthAt(waypoint, waypoints);
      return (format('max_depth', raw), raw);
    case 'ascent_rate_value':
      // The ascent rate as a number beside the arrows, in m/min or ft/min
      // (Teric manual p.12 "graphically and numerically"); 0 when level or
      // descending.
      final raw = ascentRateFor(waypoint, waypoints);
      if (raw == null) {
        return ('--', null);
      }
      return ('${pyRound(u.depth(raw > 0 ? raw : 0.0, units))}', raw);
    case 'min_temp':
      // The coldest water so far.
      final now = waypoint?.timeSinceStart ?? 0;
      double? coldest;
      for (final wp
          in waypoints == null || waypoints.isEmpty
              ? <Waypoint?>[waypoint]
              : waypoints) {
        final temp = wp?.temp;
        if (wp != null && temp != null && wp.timeSinceStart <= now) {
          coldest = coldest == null || temp < coldest ? temp : coldest;
        }
      }
      return (format('temp', coldest), coldest);
    case 'gf_setting':
      // The conservatism the dive was made with, "40/85".
      final dive = waypoint?.dive;
      final low = dive?.gfLow;
      final high = dive?.gfHigh;
      return (
        low != null && low != 0 && high != null && high != 0
            ? '$low/$high'
            : '--',
        null,
      );
    case 'ambient_mbar' || 'surface_mbar':
      // The PRESSURE info screen in mbar: the surface pressure and the
      // pressure now (salt water, 100.5 mbar per metre).
      final depth = field == 'ambient_mbar' ? waypoint?.depth ?? 0.0 : 0.0;
      final raw = pyRound(1013 + depth * 100.5);
      return ('$raw', raw);
    case 'ndl_before_clear':
      final raw = rules.getNdlBeforeClear(
        manufacturer,
        model,
        waypoint,
        waypoints,
      );
      // Only shown during the clear count-up: nothing (not "--") the rest
      // of the dive.
      return raw == null ? ('', null) : (format(field, raw), raw);
    case 'mod':
      final raw = waypoint == null
          ? null
          : modMetres(rules, manufacturer, model, waypoint);
      return (format(field, raw), raw);
    case 'circuit':
      // CC / SC / BO / OC, in the brand's own words.
      final raw = waypoint?.circuit;
      final labels = ctx.rule('circuit_labels');
      final shown = labels is Map<String, dynamic> && truthy(raw)
          ? (labels.containsKey(raw) ? labels[raw] : raw)
          : raw;
      return (truthy(shown) ? _str(shown) : '--', raw);
  }
  if (field.startsWith('unit:')) {
    // A unit label that follows the unit system.
    return (u.unitLabel(field.substring('unit:'.length), units), null);
  }
  if (field == 'air_remaining' &&
      waypoint != null &&
      waypoint.airRemaining == null) {
    // No logged gas time: the brand's formula from the pressure trend,
    // "wait" until it has two minutes of data.
    final raw = gasTimeRemaining(
      rules,
      manufacturer,
      model,
      waypoint,
      waypoints,
    );
    if (raw == null) {
      if (ctx.rule('gas_time') is! Map<String, dynamic>) {
        return ('--', null);
      }
      // Once deco stops are required the slot reads "deco".
      return (
        rules.resolveState(manufacturer, model, waypoint, waypoints) == 'deco'
            ? 'deco'
            : 'wait',
        null,
      );
    }
    return (format(field, raw), raw);
  }
  if (field == 'pressure_sac' &&
      waypoint?.pressureSac == null &&
      ctx.rule('gas_time') is! Map<String, dynamic>) {
    // "wait" is a Shearwater's; a Descent shows no value yet.
    return ('--', null);
  }
  if (field.startsWith('custom:')) {
    return (field.replaceAll('custom:', ''), null);
  }
  if (field.startsWith('tank_pressure:')) {
    final tank = waypoint?.tanks[field.replaceAll('tank_pressure:', '')];
    final raw = tank?.pressureBar;
    return (format(field, raw), raw);
  }
  if (field.startsWith('tank_name:')) {
    final name = field.replaceAll('tank_name:', '');
    final tank = waypoint?.tanks[name];
    final raw = tank == null ? name : tank.name;
    return (format(field, raw), raw);
  }
  final raw = waypointValue(waypoint, field);
  if (field == 'ndl' && raw == null && waypoint != null) {
    // No NDL is an unbounded one: "99+" as the screens show it, but not in
    // deco, where the brand's own deco handling applies.
    if (rules.resolveState(manufacturer, model, waypoint, waypoints) !=
        'deco') {
      return ('99+', null);
    }
  }
  return (format(field, raw), raw);
}

/// '2:33' (m:ss), '02:33' (mm:ss), '2′33' (m'ss, a Suunto's stop
/// counter) or '2min' (whole minutes, rounded up, as a Perdix shows a deco
/// stop's time).
String formatStopTimer(num seconds, Object? format) {
  final s = seconds < 0 ? 0 : seconds.truncate();
  if (format == 'min') {
    final minutes = s == 0 ? 0 : (s / 60).ceil();
    return '${s != 0 && minutes < 1 ? 1 : minutes}min';
  }
  final mins = s ~/ 60;
  final secs = _d2(s % 60);
  if (format == "m'ss") {
    return '$mins′$secs';
  }
  return format == 'm:ss' ? '$mins:$secs' : '${_d2(mins)}:$secs';
}

/// A line of a state badge.
typedef BadgeLine = (String text, Rgb color, bool isValue);

final _trailingSpace = RegExp(r'[ \t\n\r\x0b\x0c]+$');

/// The lines a state badge shows at [waypoint], or `null` when nothing is
/// drawn (the 'normal' state, no badge rule, no waypoint).
///
/// What is shown comes from the rules engine's `stopPhase` (state, phase,
/// seconds, stop depth) and is styled by the brand's `badge_states` entry
/// for the state:
///
/// - `label`, `color`: the title line (a label of "" draws no title);
/// - `value_color`: the colour of the depth and timer lines;
/// - `<phase>_color`, `<phase>_value_color`, `<phase>_value_text`,
///   `<phase>_label`: the same per phase;
/// - `check_mark`: "✓ " before the value at the stop or while counting;
/// - `show_depth` false: no stop-depth line;
/// - `inline`: depth and timer on one line, "6m↑ 2min";
/// - `timer_format`: "m:ss", "mm:ss" or "min"; the element's own key wins;
/// - `blink`, `blink_depth`, `clear_blink_depth`: red flashing by time.
///
/// Element keys: `depth_unit`, `depth_font` ("label" draws the depth line
/// at the label size), `timer_format`, `style` ("box" implies m:ss).
List<BadgeLine>? badgeLines(
  HudContext ctx,
  Map<String, dynamic> elem,
  Waypoint? waypoint, [
  List<Waypoint>? waypoints,
]) {
  if (waypoint == null) {
    return null;
  }
  final rules = ctx.rules;
  final manufacturer = ctx.manufacturer;
  final model = ctx.model;
  final (state, phase, seconds, stopDepthRaw) = rules.stopPhase(
    manufacturer,
    model,
    waypoint,
    waypoints,
  );
  if (state == 'normal') {
    return null;
  }
  final badge = rules.getBadgeConfig(manufacturer, model, state);
  if (badge == null || badge.isEmpty) {
    return null;
  }
  String text(String key, String fallback) =>
      badge.containsKey(key) ? _str(badge[key]) : fallback;

  final elapsed = ctx.flashTime(waypoint);
  String blinkRed(String hex) => resolveBlinkColor(hex, '#FF0000', elapsed);
  // The "on" half of each second.
  final blinkPhase = resolveBlinkColor('a', 'b', elapsed) == 'b';

  var titleHex = text('color', '#FFFFFF');
  if (phase != null && truthy(badge['${phase}_color'])) {
    titleHex = '${badge['${phase}_color']}';
  }
  if (truthy(badge['blink'])) {
    titleHex = blinkRed(titleHex);
  }
  var valueHex = text('value_color', titleHex);
  if (phase != null && truthy(badge['${phase}_value_color'])) {
    valueHex = '${badge['${phase}_value_color']}';
  }
  // E.g. a Teric: "CLEAR" once the stop is done.
  final valueText = phase == null ? null : badge['${phase}_value_text'];
  final violating =
      phase == 'violation' ||
      phase == 'ceiling_violation' ||
      ((state == 'deco' || state == 'clear') &&
          rules.ceilingBroken(manufacturer, model, waypoint));
  if (violating) {
    // A Teric: yellow above the stop, flashing red above the ceiling; a
    // Perdix: red for both.
    Object? red = truthy(badge['violation_color'])
        ? badge['violation_color']
        : rules.ceilingBrokenColor(manufacturer, model);
    if (phase == 'ceiling_violation' &&
        truthy(badge['ceiling_violation_color'])) {
      red = badge['ceiling_violation_color'];
    }
    final base = text('color', '#FFFFFF');
    titleHex = resolveBlinkColor(base, '$red', elapsed);
    valueHex = resolveBlinkColor(text('value_color', base), '$red', elapsed);
  }

  var label = text('label', state.toUpperCase());
  if (phase != null && truthy(badge['${phase}_label'])) {
    // E.g. a Perdix 3: "PAUSED" in place of "SAFETY".
    label = '${badge['${phase}_label']}';
  }
  final lines = <BadgeLine>[
    if (label.isNotEmpty) (label, hexRgb(titleHex), false),
  ];
  // The check mark sits in front of the value ("✓2:59" while the safety
  // stop counts, "20ft ✓2min" at the deco stop); the title keeps its
  // colour.
  final check =
      truthy(badge['check_mark']) &&
      (phase == 'at_stop' || phase == 'counting');

  final timerFormat = truthy(elem['timer_format'])
      ? elem['timer_format']
      : elem['style'] == 'box'
      ? 'm:ss'
      : badge.containsKey('timer_format')
      ? badge['timer_format']
      : 'mm:ss';
  // `depth_unit` set at all: show the unit of the system in force.
  final unit = truthy(elem['depth_unit']) ? u.depthLabel(ctx.units) : '';
  final depthIsValue = elem['depth_font'] != 'label';
  final showDepth =
      (!badge.containsKey('show_depth') || truthy(badge['show_depth'])) &&
      stopDepthRaw != null &&
      stopDepthRaw != 0;
  // Whole metres, or the feet stop level.
  final stopDepth = showDepth ? u.stopDepth(stopDepthRaw, ctx.units) : 0.0;
  if (showDepth && truthy(badge['inline'])) {
    // "6m 2min" far from the stop; "6m↑ 2min" with the arrow flashing
    // while approaching; "6m✓ 2min" at the stop; "6m↓ 2min" shallower.
    final String marker;
    if (phase == 'approach') {
      marker = blinkPhase ? '↑' : ' ';
    } else if (check) {
      marker = checkMark.trim();
    } else if (phase == 'violation' || phase == 'ceiling_violation') {
      marker = '↓';
    } else {
      marker = '';
    }
    final timer = seconds == null ? '' : formatStopTimer(seconds, timerFormat);
    lines.add((
      '${pyFormatFixed(stopDepth, 0)}$unit$marker $timer'.replaceFirst(
        _trailingSpace,
        '',
      ),
      hexRgb(valueHex),
      true,
    ));
    return lines;
  }
  if (showDepth) {
    var depthHex = valueHex;
    if (truthy(badge['blink_depth']) ||
        (phase == 'clear' && truthy(badge['clear_blink_depth']))) {
      // A Descent: the current depth and the stop depth flash red.
      depthHex = blinkRed(depthHex);
    }
    lines.add((
      '↑${pyFormatFixed(stopDepth, 0)}$unit',
      hexRgb(depthHex),
      depthIsValue,
    ));
  }
  if (truthy(valueText)) {
    lines.add(('$valueText', hexRgb(valueHex), true));
  } else if (seconds != null) {
    final timer = formatStopTimer(seconds, timerFormat);
    lines.add(('${check ? checkMark : ''}$timer', hexRgb(valueHex), true));
  }
  return lines;
}
