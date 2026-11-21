/// The overlay rules engine (spec §5.5), ported from
/// `utils/hud_rules_engine.py` of the Python app: the colour and state rules
/// of `hud_rules.json`, looked up brand → model → default, and what they
/// make of a waypoint (deco state, safety-stop and deco-clear timelines,
/// stop phases, tank and rebreather colours).
///
/// Python keeps the rules in a module global and a page's own overrides in
/// a context variable; here both are fields of [HudRules], and
/// [HudRules.withOverrides] gives the engine for one page.
library;

import 'dart:convert';

import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';

/// Safety-stop phases a timeline reports; `null` = nothing shown. 'warn' is
/// a Descent's "Descend to complete safety stop".
const String ssPending = 'pending';
const String ssCounting = 'counting';
const String ssPaused = 'paused';
const String ssComplete = 'complete';
const String ssWarn = 'warn';

/// Dive-alert names (Garmin FIT) that [HudRules.resolveState] trusts as a
/// direct state signal, ahead of the depth bands.
const Set<String> _decoAlerts = {
  'deco_ceiling_broken',
  'approaching_first_deco_stop',
};
const Set<String> _decoClearedAlerts = {'deco_stop_cleared'};
const Set<String> _decoCompleteAlerts = {'deco_complete'};
const Set<String> _safetyStopStartAlerts = {'safety_stop_started'};
const Set<String> _safetyStopEndAlerts = {'safety_stop_complete'};

const List<String> cellFields = ['po2_1', 'po2_2', 'po2_3'];
const Set<String> loopCircuits = {'CC', 'SC'};

/// The rules used when `hud_rules.json` cannot be read.
const Map<String, dynamic> fallbackRules = {
  'default': {
    'ndl': [
      {'max': 10, 'color': '#FF0000'},
      {'min': 10, 'max': 30, 'color': '#FFFF00'},
      {'min': 30, 'color': '#FFFFFF'},
    ],
    'tank_pressure': [
      {'max': 60, 'color': '#FF0000'},
      {'max': 70, 'color': '#FFA500'},
    ],
    'tank_pressure_fill': [
      {'max': 50, 'color': '#FF0000'},
      {'max': 70, 'color': '#FFFF00'},
    ],
    'safety_stop': {
      'text': 'SAFETY STOP',
      'color': '#FFFF00',
      'trigger_max_depth': 10.0,
      'min_depth': 3.0,
      'max_depth': 6.0,
    },
    'badge_states': {
      'safety_stop': {'label': 'STOP', 'color': '#00FF00'},
      'deco': {'label': 'DECO', 'color': '#FFA500'},
    },
  },
};

/// True for a key that annotates the rules rather than configuring them:
/// any key starting with "_" ("_source": "manual p.27"). Lookups never
/// match them and merges skip them.
bool isAnnotationKey(Object? key) => key is String && key.startsWith('_');

/// (state, phase, seconds, stop depth): everything a stop badge needs.
typedef StopPhase = (String state, String? phase, int? seconds, double? depth);

// Python truthiness of a rule value.
bool _truthy(Object? value) => switch (value) {
  null || false => false,
  final num number => number != 0,
  final String text => text.isNotEmpty,
  final List<dynamic> list => list.isNotEmpty,
  final Map<dynamic, dynamic> map => map.isNotEmpty,
  _ => true,
};

// Python `float(value)` for a rule lookup's value; null where it raises.
double? _float(Object? value) => switch (value) {
  final num number => number.toDouble(),
  final bool flag => flag ? 1.0 : 0.0,
  final String text => pyFloat(text),
  _ => null,
};

double _number(Object? value, double fallback) =>
    value is num ? value.toDouble() : fallback;

Map<String, dynamic>? _dict(Object? value) =>
    value is Map<String, dynamic> ? value : null;

// Python `a or b` on optional numbers: the second when the first is None or 0.
double? _or(double? first, double? second) =>
    first == null || first == 0 ? second : first;

class _Timelines {
  final Map<String, Object> byKey = {};
}

// Per-dive timelines, cached per waypoint list (by identity), as in Python.
final Expando<_Timelines> _timelineCache = Expando<_Timelines>();

/// The rules of `hud_rules.json` and, for one page, its own overrides.
class HudRules {
  /// [rules] is the decoded `hud_rules.json` (or [fallbackRules]).
  /// [overrides] is a layout's own `rules` block: checked before every
  /// lookup, a `null` in it switches that rule off.
  HudRules(this.rules, {Map<String, dynamic>? overrides})
    : overrides = overrides == null || overrides.isEmpty ? null : overrides;

  /// Brand → model → rule key. Keys starting with "_" are annotations.
  final Map<String, dynamic> rules;
  final Map<String, dynamic>? overrides;

  /// The same rules with a page's `rules` block (or without one).
  HudRules withOverrides(Object? pageRules) =>
      HudRules(rules, overrides: _dict(pageRules));

  /// The rule under [ruleKey]: the page's override, else the model's, the
  /// brand's, the brand's default, the global default; `null` when none.
  Object? getRuleConfig(String? manufacturer, String? model, String ruleKey) {
    if (isAnnotationKey(ruleKey)) {
      return null;
    }
    final own = overrides;
    if (own != null && own.containsKey(ruleKey)) {
      return own[ruleKey];
    }
    // An annotation is never a brand or a model: look past it.
    final brandName = isAnnotationKey(manufacturer) ? null : manufacturer;
    final modelName = isAnnotationKey(model) ? null : model;

    if (brandName != null &&
        brandName.isNotEmpty &&
        rules.containsKey(brandName)) {
      final brand = _dict(rules[brandName]) ?? const <String, dynamic>{};
      if (modelName != null &&
          modelName.isNotEmpty &&
          brand.containsKey(modelName)) {
        final modelBlock = _dict(brand[modelName]);
        if (modelBlock != null && modelBlock.containsKey(ruleKey)) {
          return modelBlock[ruleKey];
        }
      }
      if (brand.containsKey(ruleKey)) {
        return brand[ruleKey];
      }
      final brandDefault = _dict(brand['default']);
      if (brandDefault != null && brandDefault.containsKey(ruleKey)) {
        return brandDefault[ruleKey];
      }
    }
    final globalDefault = _dict(rules['default']) ?? const <String, dynamic>{};
    return globalDefault[ruleKey];
  }

  /// The colour of a value from the band rules for `ndl` (seconds), tank
  /// pressures (bar), `po2` and the cells, and `safety_stop`;
  /// [defaultColor] for any other field or without a matching rule.
  String getDynamicColor(
    String? manufacturer,
    String? model,
    String field,
    Object? value,
    String defaultColor,
  ) {
    if (value == null) {
      return defaultColor;
    }
    final String ruleKey;
    if (field == 'ndl' || field == 'ndl_before_clear') {
      ruleKey = 'ndl';
    } else if (field == 'primary_tank_pressure' ||
        field == 'secondary_tank_pressure' ||
        field.startsWith('tank_pressure:')) {
      ruleKey = 'tank_pressure';
    } else if (field == 'po2' || cellFields.contains(field)) {
      ruleKey = 'po2';
    } else if (field == 'safety_stop') {
      ruleKey = 'safety_stop';
    } else {
      return defaultColor;
    }

    var config = getRuleConfig(manufacturer, model, ruleKey);
    if (!_truthy(config)) {
      if (ruleKey == 'tank_pressure' &&
          getRuleConfig(manufacturer, model, 'tank_reserve')
              is Map<String, dynamic>) {
        config = const <dynamic>[];
      } else {
        return defaultColor;
      }
    }

    if (ruleKey == 'safety_stop') {
      final color = _dict(config)?['color'];
      return color is String ? color : '#FFFF00';
    }

    if (config is! List<dynamic>) {
      return defaultColor;
    }
    final bands = [for (final band in config) _dict(band) ?? const {}];

    String? inBand(double number) {
      for (final rule in bands) {
        final min = rule['min'];
        final max = rule['max'];
        if (min is num && number < min) {
          continue;
        }
        if (max is num && number >= max) {
          continue;
        }
        return rule['color'] as String?;
      }
      return null;
    }

    final number = _float(value);
    if (number == null) {
      return defaultColor;
    }

    if (ruleKey == 'ndl') {
      final minutes = number / 60.0;
      String safeColor() {
        for (final rule in bands) {
          if (_number(rule['min'], 0) >= 30) {
            return rule['color'] as String;
          }
        }
        return defaultColor;
      }

      // NDL <= 0: no time left, in deco. Only a brand with an "ndl_zero"
      // colour tells that apart from the unlimited case below.
      if (minutes <= 0) {
        final zeroColor = getRuleConfig(manufacturer, model, 'ndl_zero');
        if (_truthy(zeroColor)) {
          return zeroColor! as String;
        }
        return safeColor();
      }
      // >= 99 is an unlimited NDL ("99+"): safe.
      if (minutes >= 99) {
        return safeColor();
      }
      return inBand(minutes) ?? defaultColor;
    }

    if (ruleKey == 'tank_pressure') {
      final reserveRule = _dict(
        getRuleConfig(manufacturer, model, 'tank_reserve'),
      );
      if (reserveRule != null) {
        final state = tankPressureState(manufacturer, model, number);
        if (state == 'critical') {
          return reserveRule['critical_color'] as String? ?? '#FF0000';
        }
        if (state == 'reserve') {
          return reserveRule['reserve_color'] as String? ?? '#FFFF00';
        }
        return defaultColor;
      }
    }
    return inBand(number) ?? defaultColor;
  }

  /// (reserve, critical) pressures in bar from the brand's `tank_reserve`
  /// rule, or `null` without one. [reserveBar] is the diver's own setting
  /// when known, else the rule's `default_bar`. Critical is the larger of
  /// `critical_min_bar` and `critical_fraction` × reserve or, for a
  /// computer where it is its own setting, `critical_default_bar`.
  (double reserve, double critical)? tankReserveThresholds(
    String? manufacturer,
    String? model, {
    double? reserveBar,
  }) {
    final rule = _dict(getRuleConfig(manufacturer, model, 'tank_reserve'));
    if (rule == null) {
      return null;
    }
    final reserve = reserveBar ?? _number(rule['default_bar'], 50);
    final double critical;
    if (rule.containsKey('critical_default_bar') && reserveBar == null) {
      critical = _number(rule['critical_default_bar'], 0);
    } else {
      critical = pyMax(
        _number(rule['critical_min_bar'], 0),
        reserve * _number(rule['critical_fraction'], 0.5),
      );
    }
    return (reserve, critical);
  }

  /// 'critical' below the critical pressure, 'reserve' below the reserve
  /// pressure, else `null` (also without a `tank_reserve` rule or a
  /// number).
  String? tankPressureState(
    String? manufacturer,
    String? model,
    Object? value, {
    double? reserveBar,
  }) {
    final thresholds = tankReserveThresholds(
      manufacturer,
      model,
      reserveBar: reserveBar,
    );
    if (thresholds == null || value is! num) {
      return null;
    }
    final (reserve, critical) = thresholds;
    if (value < critical) {
      return 'critical';
    }
    if (value < reserve) {
      return 'reserve';
    }
    return null;
  }

  /// The safety-stop text while inside the rule's depth band after a dive
  /// deep enough to owe one; else the empty string.
  String getSafetyStopText(
    String? manufacturer,
    String? model,
    Waypoint? waypoint,
  ) {
    if (waypoint == null) {
      return '';
    }
    final config = _dict(getRuleConfig(manufacturer, model, 'safety_stop'));
    if (config == null || config.isEmpty) {
      return '';
    }
    final trigger = _number(config['trigger_max_depth'], 10.0);
    final minDepth = _number(config['min_depth'], 3.0);
    final maxDepth = _number(config['max_depth'], 6.0);
    final text = config['text'] as String? ?? 'SAFETY STOP';

    final depth = waypoint.depth ?? 0.0;
    if (waypoint.maxDepth >= trigger &&
        minDepth <= depth &&
        depth <= maxDepth) {
      return text;
    }
    return '';
  }

  /// Where the diver is relative to a mandatory deco stop, for brands with
  /// a `deco_stop` rule: 'far', 'approach', 'at_stop', 'violation' or, with
  /// `ceiling_phase`, 'ceiling_violation'. `null` outside deco or without
  /// the rule.
  String? decoStopPhase(String? manufacturer, String? model, Waypoint? wp) {
    if (wp == null) {
      return null;
    }
    final rule = _dict(getRuleConfig(manufacturer, model, 'deco_stop'));
    if (rule == null) {
      return null;
    }
    final stop = _or(wp.nextStopDepth, wp.decoStopDepth);
    final depth = wp.depth;
    if (stop == null || stop == 0 || stop <= 0 || depth == null) {
      return null;
    }
    // Positive = deeper than the stop.
    final above = depth - stop;
    // Shallower than the stop but deeper than the ceiling is one thing,
    // shallower than the ceiling another.
    if (_truthy(rule['ceiling_phase'])) {
      final ceiling = wp.ceiling;
      if (ceiling != null && 0 < ceiling && ceiling < stop && depth < ceiling) {
        return 'ceiling_violation';
      }
    }
    if (above < -_number(rule['violation_above_m'], 0.0)) {
      return 'violation';
    }
    if (above <= _number(rule['at_stop_m'], 1.5)) {
      return 'at_stop';
    }
    if (above <= _number(rule['approach_m'], 5.1)) {
      return 'approach';
    }
    return 'far';
  }

  /// 'primary' or 'secondary': the tank to breathe from when the two
  /// sidemount tanks differ by more than the brand's `sidemount_switch`
  /// threshold. `null` without the rule, a second tank, or a difference
  /// within the threshold.
  String? sidemountSwitchTarget(
    String? manufacturer,
    String? model,
    Waypoint? wp,
  ) {
    if (wp == null) {
      return null;
    }
    final rule = _dict(getRuleConfig(manufacturer, model, 'sidemount_switch'));
    if (rule == null) {
      return null;
    }
    if (wp.tanks.length < 2) {
      return null;
    }
    final p1 = wp.tanks.values.first.pressureBar;
    final p2 = wp.tanks.values.elementAt(1).pressureBar;
    if (p1 == null || p2 == null) {
      return null;
    }
    final threshold = _number(rule['threshold_bar'], 21.0);
    if (p2 - p1 > threshold) {
      return 'secondary';
    }
    if (p1 - p2 > threshold) {
      return 'primary';
    }
    return null;
  }

  /// True while the diver is more than the brand's `ceiling_broken` margin
  /// above a mandatory deco stop.
  bool ceilingBroken(String? manufacturer, String? model, Waypoint? wp) {
    if (wp == null) {
      return false;
    }
    final rule = _dict(getRuleConfig(manufacturer, model, 'ceiling_broken'));
    if (rule == null) {
      return false;
    }
    final ceiling = _or(wp.decoStopDepth, wp.nextStopDepth);
    final depth = wp.depth;
    if (ceiling == null || ceiling == 0 || ceiling <= 0 || depth == null) {
      return false;
    }
    return depth < ceiling - _number(rule['margin'], 0.6);
  }

  String ceilingBrokenColor(String? manufacturer, String? model) {
    final rule = _dict(getRuleConfig(manufacturer, model, 'ceiling_broken'));
    return rule?['color'] as String? ?? '#FF0000';
  }

  /// A per-dive timeline, built once per waypoint list (by identity),
  /// brand, model and overrides. [kind] names the timeline.
  T cachedTimeline<T extends Object>(
    String kind,
    String? manufacturer,
    String? model,
    List<Waypoint> waypoints,
    T Function() build,
  ) {
    final key =
        '$kind|${waypoints.length}|$manufacturer|$model|'
        '${jsonEncode(overrides)}';
    final cache = _timelineCache[waypoints] ??= _Timelines();
    return (cache.byKey[key] ??= build()) as T;
  }

  bool _inDeco(Waypoint wp) {
    final alerts = wp.diveAlerts.toSet();
    if (alerts.intersection(_decoCompleteAlerts).isNotEmpty) {
      return false;
    }
    if (alerts.intersection(_decoClearedAlerts).isNotEmpty ||
        alerts.intersection(_decoAlerts).isNotEmpty) {
      return true;
    }
    final stop = wp.decoStopDepth;
    return stop != null && stop != 0;
  }

  /// Garmin Descent: after a dive deeper than `trigger_max_depth` the stop
  /// is armed; its timer starts once within `start_window` m of
  /// `stop_depth`, pauses while more than `pause_above` m above it, and the
  /// whole stop resets when descending below the trigger depth. Mandatory
  /// deco ends the safety stop for good. Surfacing after the timer started
  /// ends it too. The computer's own started / complete alerts override the
  /// depth rules. Only 'counting' (or 'warn') is ever reported.
  Map<int, (String?, int)> _garminSafetyTimeline(
    Map<String, dynamic> cfg,
    List<Waypoint> waypoints,
  ) {
    final duration = (cfg['duration_sec'] as num).toInt();
    final trigger = _number(cfg['trigger_max_depth'], 11.0);
    final stopDepth = _number(cfg['stop_depth'], 5.0);
    final startWindow = _number(cfg['start_window'], 1.0);
    final pauseAbove = _number(cfg['pause_above'], 3.0);
    final warnAbove = (cfg['warn_above_m'] as num?)?.toDouble();
    final surface = _number(cfg['min_depth'], 1.2);

    final timeline = <int, (String?, int)>{};
    var armed = false;
    var started = false;
    var left = duration;
    int? prevT;
    var hadDeco = false;
    for (final wp in waypoints) {
      final t = wp.timeSinceStart;
      final depth = wp.depth ?? 0.0;
      final dt = prevT == null ? 0 : (t - prevT > 0 ? t - prevT : 0);
      prevT = t;
      if (_inDeco(wp)) {
        hadDeco = true;
      }
      if (depth > trigger || hadDeco) {
        armed = wp.maxDepth >= trigger && !hadDeco;
        started = false;
        left = duration;
        timeline[t] = (null, left);
        continue;
      }
      if (!armed && wp.maxDepth >= trigger) {
        armed = true;
      }
      final alerts = wp.diveAlerts.toSet();
      if (alerts.intersection(_safetyStopStartAlerts).isNotEmpty) {
        armed = true;
        started = true;
        left = duration;
      }
      if (armed && left > 0) {
        if (started && depth < surface) {
          // Surfaced: the stop is over, whatever was left.
          left = 0;
        } else if (!started && (depth - stopDepth).abs() <= startWindow) {
          started = true;
        }
        if (started && left > 0 && depth >= stopDepth - pauseAbove) {
          left = left - dt > 0 ? left - dt : 0;
        }
      }
      if (alerts.intersection(_safetyStopEndAlerts).isNotEmpty) {
        left = 0;
      }
      String? phase = armed && started && left > 0 ? ssCounting : null;
      if (phase != null && warnAbove != null && depth < stopDepth - warnAbove) {
        phase = ssWarn;
      }
      timeline[t] = (phase, left);
    }
    return timeline;
  }

  /// Shearwater: once the depth exceeds `trigger_max_depth` the counter
  /// appears showing the planned time ('pending'); the countdown begins
  /// once shallower than `start_below` and runs while the depth stays
  /// inside `count_range`, 'paused' outside it; 'complete' at zero. With
  /// `adapt` enabled the planned time becomes its `duration_sec` once the
  /// dive goes deeper than `deep_m` or the NDL drops under `low_ndl_sec`.
  /// Mandatory deco replaces the safety stop; once cleared it starts over.
  Map<int, (String?, int)> _shearwaterSafetyTimeline(
    Map<String, dynamic> cfg,
    List<Waypoint> waypoints,
  ) {
    final duration = (cfg['duration_sec'] as num? ?? 180).toInt();
    final trigger = _number(cfg['trigger_max_depth'], 11.0);
    final startBelow = _number(cfg['start_below'], 6.0);
    final range = cfg['count_range'] as List<dynamic>? ?? const [2.4, 8.3];
    final lo = (range[0] as num).toDouble();
    final hi = (range[1] as num).toDouble();
    final adaptRule = _dict(cfg['adapt']);
    final adapt = adaptRule != null && _truthy(adaptRule['enabled'])
        ? adaptRule
        : null;
    final adaptDuration = (adapt?['duration_sec'] as num? ?? 300).toInt();

    final timeline = <int, (String?, int)>{};
    var armed = false;
    var started = false;
    var planned = duration;
    var left = duration;
    int? prevT;
    for (final wp in waypoints) {
      final t = wp.timeSinceStart;
      final depth = wp.depth ?? 0.0;
      final dt = prevT == null ? 0 : (t - prevT > 0 ? t - prevT : 0);
      prevT = t;
      if (_inDeco(wp)) {
        // Deco stops replace the safety stop; once they are cleared it
        // starts over, pending again until shallower than the start depth.
        armed = true;
        started = false;
        left = planned;
        timeline[t] = (null, planned);
        continue;
      }
      final maxDepth = wp.maxDepth;
      final deepest = pyMax(maxDepth, depth);
      if (!armed && deepest > trigger) {
        armed = true;
      } else if (armed && depth > trigger && (started || left < planned)) {
        // "Countdown Reset": deeper than the trigger depth again.
        started = false;
        left = planned;
      }
      if (adapt != null && !started && planned != adaptDuration) {
        final ndl = wp.ndl;
        if (deepest > _number(adapt['deep_m'], 30.0) ||
            (ndl != null &&
                0 < ndl &&
                ndl < (adapt['low_ndl_sec'] as num? ?? 300).toInt())) {
          planned = left = adaptDuration;
        }
      }
      if (!armed) {
        timeline[t] = (null, planned);
        continue;
      }
      if (!started) {
        if (depth < startBelow) {
          started = true;
        } else {
          timeline[t] = (ssPending, planned);
          continue;
        }
      }
      if (left <= 0) {
        timeline[t] = (ssComplete, 0);
        continue;
      }
      if (lo <= depth && depth <= hi) {
        left = left - dt > 0 ? left - dt : 0;
        timeline[t] = (left == 0 ? ssComplete : ssCounting, left);
      } else {
        timeline[t] = (ssPaused, left);
      }
    }
    return timeline;
  }

  /// {time since start: (phase, seconds left)} for the whole dive, from the
  /// brand's `safety_stop` rule: the Shearwater dialect when it has
  /// `start_below`, the Garmin one when it has `duration_sec`. `null` when
  /// the rule has no timer or there are no waypoints.
  Map<int, (String?, int)>? safetyStopTimeline(
    String? manufacturer,
    String? model,
    List<Waypoint>? waypoints,
  ) {
    if (waypoints == null || waypoints.isEmpty) {
      return null;
    }
    final cfg = _dict(getRuleConfig(manufacturer, model, 'safety_stop'));
    if (cfg == null) {
      return null;
    }
    if (cfg.containsKey('start_below')) {
      return cachedTimeline(
        'ss',
        manufacturer,
        model,
        waypoints,
        () => _shearwaterSafetyTimeline(cfg, waypoints),
      );
    }
    if (_truthy(cfg['duration_sec'])) {
      return cachedTimeline(
        'ss',
        manufacturer,
        model,
        waypoints,
        () => _garminSafetyTimeline(cfg, waypoints),
      );
    }
    return null;
  }

  /// (phase, seconds left) at this waypoint, or `null` when no timeline
  /// applies. A `null` phase is nothing to show at this waypoint.
  (String? phase, int seconds)? safetyStopPhase(
    String? manufacturer,
    String? model,
    Waypoint? waypoint,
    List<Waypoint>? waypoints,
  ) {
    final timeline = safetyStopTimeline(manufacturer, model, waypoints);
    if (timeline == null || waypoint == null) {
      return null;
    }
    return timeline[waypoint.timeSinceStart];
  }

  /// (counting, seconds left): the Garmin-style view of [safetyStopPhase].
  (bool counting, int seconds)? safetyStopStatus(
    String? manufacturer,
    String? model,
    Waypoint? waypoint,
    List<Waypoint>? waypoints,
  ) {
    final phase = safetyStopPhase(manufacturer, model, waypoint, waypoints);
    if (phase == null) {
      return null;
    }
    return (phase.$1 == ssCounting, phase.$2);
  }

  /// {time since start: seconds since the last deco stop cleared} for
  /// every waypoint after a deco run, for brands with a `deco_clear` rule.
  /// A later deco run restarts it. `null` without the rule or waypoints.
  Map<int, int>? decoClearTimeline(
    String? manufacturer,
    String? model,
    List<Waypoint>? waypoints,
  ) {
    if (waypoints == null || waypoints.isEmpty) {
      return null;
    }
    final rule = _dict(getRuleConfig(manufacturer, model, 'deco_clear'));
    if (rule == null ||
        (rule.containsKey('count_up') && !_truthy(rule['count_up']))) {
      return null;
    }
    return cachedTimeline('dc', manufacturer, model, waypoints, () {
      final timeline = <int, int>{};
      int? clearedAt;
      var wasInDeco = false;
      for (final wp in waypoints) {
        final t = wp.timeSinceStart;
        if (_inDeco(wp)) {
          clearedAt = null;
          wasInDeco = true;
        } else if (wasInDeco && clearedAt == null) {
          clearedAt = t;
        }
        if (clearedAt != null && (wp.depth ?? 0.0) > 0) {
          timeline[t] = t - clearedAt;
        }
      }
      return timeline;
    });
  }

  int? decoClearSeconds(
    String? manufacturer,
    String? model,
    Waypoint? waypoint,
    List<Waypoint>? waypoints,
  ) {
    final timeline = decoClearTimeline(manufacturer, model, waypoints);
    if (timeline == null || waypoint == null) {
      return null;
    }
    return timeline[waypoint.timeSinceStart];
  }

  /// The overlay state of one waypoint: 'deco', 'clear', 'safety_stop' or
  /// 'normal'. The waypoint's own dive alerts first, then a deco stop, the
  /// deco-clear counter, the safety-stop timeline (with the whole dive at
  /// hand) and last the safety stop's depth band.
  String resolveState(
    String? manufacturer,
    String? model,
    Waypoint? waypoint, [
    List<Waypoint>? waypoints,
  ]) {
    if (waypoint == null) {
      return 'normal';
    }
    final alerts = waypoint.diveAlerts.toSet();
    // deco_complete first: clearing the last stop fires both it and
    // deco_stop_cleared, and "fully done" is the more final of the two.
    if (alerts.intersection(_decoCompleteAlerts).isNotEmpty) {
      return 'normal';
    }
    if (alerts.intersection(_decoClearedAlerts).isNotEmpty) {
      return 'clear';
    }
    if (alerts.intersection(_decoAlerts).isNotEmpty) {
      return 'deco';
    }
    if (alerts.intersection(_safetyStopStartAlerts).isNotEmpty) {
      return 'safety_stop';
    }
    if (alerts.intersection(_safetyStopEndAlerts).isNotEmpty) {
      return 'normal';
    }

    final decoDepth = waypoint.decoStopDepth;
    if (decoDepth != null && decoDepth > 0) {
      return 'deco';
    }
    if (decoClearSeconds(manufacturer, model, waypoint, waypoints) != null) {
      return 'clear';
    }
    final phase = safetyStopPhase(manufacturer, model, waypoint, waypoints);
    if (phase != null) {
      return phase.$1 != null ? 'safety_stop' : 'normal';
    }
    if (getSafetyStopText(manufacturer, model, waypoint).isNotEmpty) {
      return 'safety_stop';
    }
    return 'normal';
  }

  /// The deco stop depth of the most recent waypoint up to [waypoint] that
  /// still had one (the stop just cleared), or `null`.
  double? _lastStopDepth(Waypoint waypoint, List<Waypoint>? waypoints) {
    if (waypoints == null || waypoints.isEmpty) {
      return null;
    }
    final now = waypoint.timeSinceStart;
    for (final w in waypoints.reversed) {
      if (w.timeSinceStart > now) {
        continue;
      }
      final depth = _or(w.nextStopDepth, w.decoStopDepth);
      if (depth != null && depth > 0) {
        return depth;
      }
    }
    return null;
  }

  /// (state, phase, seconds, stop depth) of a waypoint: the resolved state;
  /// its phase (safety stop: pending / counting / paused / complete, deco:
  /// far / approach / at_stop / violation, clear: 'clear'); the seconds to
  /// show (time left on a stop, time elapsed on a deco-clear count-up); and
  /// the stop depth (`null` for a Shearwater safety stop, which names
  /// none).
  StopPhase stopPhase(
    String? manufacturer,
    String? model,
    Waypoint? waypoint, [
    List<Waypoint>? waypoints,
  ]) {
    final state = resolveState(manufacturer, model, waypoint, waypoints);
    if (state == 'normal' || waypoint == null) {
      return (state, null, null, null);
    }
    if (state == 'safety_stop') {
      final phase = safetyStopPhase(manufacturer, model, waypoint, waypoints);
      final cfg =
          _dict(getRuleConfig(manufacturer, model, 'safety_stop')) ??
          const <String, dynamic>{};
      if (phase != null && phase.$1 != null) {
        final depth = cfg.containsKey('start_below')
            ? null
            : _number(cfg['stop_depth'], 5.0);
        return (state, phase.$1, phase.$2, depth);
      }
      // An alert-driven or depth-band safety stop without a timeline.
      return (
        state,
        ssCounting,
        waypoint.nextStopTime,
        _or(waypoint.nextStopDepth, (cfg['stop_depth'] as num?)?.toDouble()),
      );
    }
    if (state == 'clear') {
      final elapsed = decoClearSeconds(
        manufacturer,
        model,
        waypoint,
        waypoints,
      );
      if (elapsed != null) {
        return (state, 'clear', elapsed, null);
      }
      // The computer's own "cleared" alert (Descent): the log's stop fields
      // are already zero, so the badge keeps the depth of the stop it just
      // cleared.
      final next = waypoint.nextStopDepth;
      final depth = next != null && next != 0
          ? next
          : _lastStopDepth(waypoint, waypoints);
      final time = waypoint.nextStopTime;
      return (state, 'clear', time == null || time == 0 ? 0 : time, depth);
    }
    return (
      state,
      decoStopPhase(manufacturer, model, waypoint),
      waypoint.nextStopTime,
      waypoint.nextStopDepth,
    );
  }

  /// The NDL (seconds) from just before deco started, while the waypoint's
  /// own state is 'clear'; `null` otherwise.
  int? getNdlBeforeClear(
    String? manufacturer,
    String? model,
    Waypoint? waypoint,
    List<Waypoint>? waypoints,
  ) {
    if (waypoint == null || waypoints == null || waypoints.isEmpty) {
      return null;
    }
    if (resolveState(manufacturer, model, waypoint) != 'clear') {
      return null;
    }
    int? lastNdl;
    for (final wp in waypoints) {
      if (wp.timeSinceStart > waypoint.timeSinceStart) {
        break;
      }
      lastNdl = wp.ndl ?? lastNdl;
    }
    return lastNdl;
  }

  /// Label, colour and the rest of a state's badge, from the `badge_states`
  /// blocks: the global default, the brand's default, the brand and the
  /// model layered on top of each other (a key set to `null` removes it),
  /// and last the page's own `rules` (an EON page shows the stop counter
  /// alone, its label and depth in cells of their own;
  /// `utils/hud_rules_engine.py:781` of Python 0.8.0). `null` for 'normal'
  /// or when nothing is defined for the state.
  Map<String, dynamic>? getBadgeConfig(
    String? manufacturer,
    String? model,
    String state,
  ) {
    if (state != 'safety_stop' && state != 'deco' && state != 'clear') {
      return null;
    }
    final brand =
        (manufacturer == null || manufacturer.isEmpty
            ? null
            : _dict(rules[manufacturer])) ??
        const <String, dynamic>{};
    final merged = <String, dynamic>{};
    var found = false;
    for (final block in [
      rules['default'] ?? const <String, dynamic>{},
      brand['default'] ?? const <String, dynamic>{},
      brand,
      if (model != null && model.isNotEmpty)
        brand[model] ?? const <String, dynamic>{}
      else
        const <String, dynamic>{},
      overrides ?? const <String, dynamic>{},
    ]) {
      final cfg = _dict(_dict(_dict(block)?['badge_states'])?[state]);
      if (cfg == null) {
        continue;
      }
      found = true;
      for (final entry in cfg.entries) {
        if (isAnnotationKey(entry.key)) {
          continue;
        }
        if (entry.value == null) {
          merged.remove(entry.key);
        } else {
          merged[entry.key] = entry.value;
        }
      }
    }
    return found ? merged : null;
  }

  /// The solid fill colour of a tank icon from the `tank_pressure_fill`
  /// bands, green above them; `null` without a reading or the bands.
  String? getTankFillColor(String? manufacturer, String? model, Object? value) {
    if (value == null) {
      return null;
    }
    final bands = getRuleConfig(manufacturer, model, 'tank_pressure_fill');
    if (bands is! List<dynamic>) {
      return null;
    }
    final bar = _float(value);
    if (bar == null) {
      return null;
    }
    for (final item in bands) {
      final band = _dict(item) ?? const <String, dynamic>{};
      final min = band['min'];
      final max = band['max'];
      if (min is num && bar < min) {
        continue;
      }
      if (max is num && bar >= max) {
        continue;
      }
      return band['color'] as String;
    }
    return '#00FF00';
  }

  /// A rebreather screen's colours for one value, or `null`: `color` for
  /// the text, or `box` and `color` (and `outline`) for a value on a filled
  /// box. From the brand's rules `po2_cc`, `cells`, `dil_po2`, `setpoint`,
  /// `circuit` and `bailout`.
  Map<String, String>? ccrStyle(
    String? manufacturer,
    String? model,
    String field,
    Waypoint? waypoint,
    Object? value,
    String baseColor, {
    double? elapsed,
  }) {
    if (waypoint == null) {
      return null;
    }
    final circuit = waypoint.circuit;

    Map<String, String>? band(String ruleKey) {
      final rule = _dict(getRuleConfig(manufacturer, model, ruleKey));
      if (rule == null || value is! num) {
        return null;
      }
      final min = rule['min'];
      final max = rule['max'];
      if ((min is num && value < min) || (max is num && value > max)) {
        final color = rule['color'] as String? ?? '#FF0000';
        return {
          'color': _truthy(rule['blink'])
              ? resolveBlinkColor(baseColor, color, elapsed)
              : color,
        };
      }
      return null;
    }

    if (field == 'po2' && loopCircuits.contains(circuit)) {
      return band('po2_cc');
    }
    if (field == 'diluent_po2') {
      return band('dil_po2');
    }
    if (cellFields.contains(field) && value is num) {
      final rule = _dict(getRuleConfig(manufacturer, model, 'cells'));
      if (rule == null) {
        return null;
      }
      final cells = [waypoint.po2_1, waypoint.po2_2, waypoint.po2_3];
      final values = <int, double>{
        for (var i = 0; i < cells.length; i++)
          if (cells[i] != null) i: cells[i]!,
      };
      final index = cellFields.indexOf(field);
      if (failedCells(
        values,
        fraction: _number(rule['vote_fraction'], 0.20),
      ).contains(index)) {
        final outOfRange =
            value < _number(rule['min'], 0.0) ||
            value > _number(rule['max'], 99.0);
        return {
          'color':
              rule[outOfRange ? 'out_of_range_color' : 'failed_color']
                  as String? ??
              '#FFFF00',
        };
      }
      return null;
    }
    if (field == 'setpoint' && value is num) {
      final rule = _dict(getRuleConfig(manufacturer, model, 'setpoint'));
      final setpoints = _diveSetpoints(waypoint);
      if (rule == null || setpoints.length < 2) {
        return null;
      }
      if (value >= setpoints.last) {
        return {'color': rule['high_color'] as String? ?? baseColor};
      }
      if (value <= setpoints.first) {
        return {'color': rule['low_color'] as String? ?? baseColor};
      }
      return null;
    }
    if (field == 'circuit') {
      final look = _dict(
        _dict(getRuleConfig(manufacturer, model, 'circuit'))?[circuit],
      );
      if (look != null && _truthy(look['box'])) {
        return {
          'box': look['box'] as String,
          'color': look['text'] as String? ?? '#000000',
          if (_truthy(look['outline'])) 'outline': look['outline'] as String,
        };
      }
      return null;
    }
    if (field == 'gasmix' && circuit == 'BO') {
      final rule = _dict(getRuleConfig(manufacturer, model, 'bailout'));
      if (rule != null && _truthy(rule['gas_color'])) {
        return {'color': rule['gas_color'] as String};
      }
    }
    return null;
  }

  /// The dive's running average depth up to [waypoint] (time-weighted); the
  /// waypoint's own depth without the dive at hand.
  double? averageDepthAt(Waypoint? waypoint, List<Waypoint>? waypoints) {
    if (waypoint == null) {
      return null;
    }
    if (waypoints == null || waypoints.isEmpty) {
      return waypoint.depth;
    }
    final timeline = cachedTimeline('avg_depth', null, null, waypoints, () {
      final out = <int, double>{};
      var area = 0.0;
      (int, double)? prev;
      int? start;
      for (final wp in waypoints) {
        final t = wp.timeSinceStart;
        final d = wp.depth;
        if (d == null) {
          continue;
        }
        if (prev != null && t > prev.$1) {
          area += (t - prev.$1) * (d + prev.$2) / 2.0;
        }
        start ??= t;
        prev = (t, d);
        out[t] = t > start ? area / (t - start) : d;
      }
      return out;
    });
    return timeline[waypoint.timeSinceStart] ?? waypoint.depth;
  }
}

/// A time-based colour toggle for flashing elements: [blinkColor] in the
/// first half of each [period], [baseColor] in the second. Driven by dive
/// time, so the phase is the same for a waypoint however fast it renders.
String resolveBlinkColor(
  String baseColor,
  String blinkColor,
  double? elapsedSeconds, {
  double period = 1.0,
}) {
  final elapsed = elapsedSeconds == null || elapsedSeconds == 0 || period <= 0
      ? 0.0
      : elapsedSeconds;
  final phase = (elapsed % period) / period;
  return phase < 0.5 ? blinkColor : baseColor;
}

/// 'single_tank' or 'sidemount' page variant for a whole dive, from its
/// logged tank count (two or more tank keys: sidemount). A rebreather dive
/// is never sidemount.
String resolveTankVariant(Dive? dive) {
  if (dive == null || dive.waypoints.isEmpty || dive.isCcr) {
    return 'single_tank';
  }
  final tanks = <String>{for (final wp in dive.waypoints) ...wp.tanks.keys};
  return tanks.length >= 2 ? 'sidemount' : 'single_tank';
}

/// The cells that fail the vote: a cell passes when it is within
/// [fraction] of at least one other cell; one cell alone is never voted
/// out.
Set<int> failedCells(Map<int, double> values, {double fraction = 0.20}) {
  if (values.length < 2) {
    return {};
  }
  final failed = <int>{};
  for (final MapEntry(key: i, value: a) in values.entries) {
    final passes = values.entries.any(
      (other) =>
          other.key != i &&
          (a - other.value).abs() <= fraction * pyMax(a, other.value),
    );
    if (!passes) {
      failed.add(i);
    }
  }
  return failed;
}

final Expando<(int, List<double>)> _setpointCache = Expando();

/// The distinct setpoints of the waypoint's dive, in rising order.
List<double> _diveSetpoints(Waypoint waypoint) {
  final dive = waypoint.dive;
  if (dive == null) {
    return const [];
  }
  final cached = _setpointCache[dive];
  if (cached != null && cached.$1 == dive.waypoints.length) {
    return cached.$2;
  }
  final values = <double>{
    for (final wp in dive.waypoints)
      if (wp.setpoint != null) wp.setpoint!,
  }.toList()..sort();
  _setpointCache[dive] = (dive.waypoints.length, values);
  return values;
}
