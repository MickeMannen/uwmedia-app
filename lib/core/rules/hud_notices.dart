/// Device notifications an overlay can show, ported from
/// `utils/hud_notices.py` of the Python app (spec §5.5): the messages a
/// dive computer puts on its screen (a Perdix's yellow "FAST ASCENT", a
/// Teric's "MISSED STOP" banner, a Descent's "Approaching NDL").
///
/// Which messages exist, their wording and what triggers them come from
/// each brand's `notices` list in `hud_rules.json`; the list order is the
/// priority order, and only the highest-priority active notice is shown.
///
/// A real computer keeps a notification up until a button is pressed; a
/// log does not record that press, so a notice stays for `show_seconds`
/// after it triggers (the brand's `notice_style.show_seconds`, 10 s unless
/// set).
///
/// Conditions (`when`) and their parameters:
///
/// - `fit_alert`: `alert`, the Garmin FIT dive_alert name on the waypoint
/// - `tank_critical`: a tank below the critical pressure; `{tank}` is its
///   name
/// - `stop_violation`: shallower than the deco stop (or the ceiling) for
///   `seconds`
/// - `po2_above`: PO2 above `bar` for `seconds`; `po2_below`: below `bar`
/// - `cns_at_least`: CNS at or above `percent`
/// - `ascent_faster_than`: faster than `m_per_min` for `seconds`
/// - `ndl_at_most`: NDL at or below `minutes` (not in deco); re-arms once
///   the NDL is `rearm_minutes` above it again
/// - `depth_deeper_than`: deeper than `metres`; re-arms `rearm_m` shallower
/// - `time_longer_than`: dive time longer than `minutes` (once per dive)
/// - `deco_required`, `deco_cleared`: the state becomes, or leaves, 'deco'
/// - `safety_started`, `safety_complete`: the safety stop starts counting,
///   or its countdown ends
/// - `mod_exceeded`, `near_mod`: deeper than the breathed gas's MOD, or
///   within `metres` above it
/// - `sidemount_switch`: the two sidemount tanks differ by more than the
///   brand's threshold; `{tank}` and `{side}` name the one to breathe from
/// - `setpoint_up`, `setpoint_down`: a rebreather's setpoint rises or falls
///
/// Any entry may name `circuits`: it only holds while the waypoint's
/// circuit is one of them. An entry with `"enabled": false` never fires.
///
/// A brand's `persistent_notices` use the same conditions but never time
/// out; a notice element with `"source": "persistent"` shows the first one
/// that holds.
library;

import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/rules/hud_gas.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/units/units.dart' as units_lib;
import 'package:uwmedia_app/core/units/units.dart' show UnitSystem;
import 'package:uwmedia_app/core/util/py_round.dart';

const int defaultShowSeconds = 10;

/// The conditions that can be read off one waypoint, without the dive.
const Set<String> _singleWaypointConditions = {
  'fit_alert',
  'tank_critical',
  'po2_below',
  'cns_at_least',
  'ndl_at_most',
  'depth_deeper_than',
  'time_longer_than',
  'po2_above',
  'ascent_faster_than',
  'stop_violation',
  'mod_exceeded',
  'near_mod',
};
const Set<String> _edgeConditions = {
  'deco_required',
  'deco_cleared',
  'safety_started',
  'safety_complete',
  'setpoint_up',
  'setpoint_down',
};
const Set<String> _sustainedConditions = {
  'po2_above',
  'ascent_faster_than',
  'stop_violation',
};

/// A notice as it is shown.
class Notice {
  const Notice({
    required this.id,
    required this.text,
    required this.caption,
    required this.color,
    required this.textColor,
    required this.icon,
    required this.since,
  });

  final Object id;
  final String text;
  final Object caption;

  /// The notice's colour (the text, the banner or the box border).
  final Object color;
  final Object? textColor;

  /// Box style: "none" drops the warning triangle.
  final Object? icon;

  /// The second of the dive it came up.
  final int since;

  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    'caption': caption,
    'color': color,
    'text_color': textColor,
    'icon': icon,
    'since': since,
  };
}

bool _truthy(Object? value) => switch (value) {
  null || false => false,
  final num number => number != 0,
  final String text => text.isNotEmpty,
  final List<dynamic> list => list.isNotEmpty,
  final Map<dynamic, dynamic> map => map.isNotEmpty,
  _ => true,
};

double _number(Object? value, double fallback) =>
    value is num ? value.toDouble() : fallback;

List<Map<String, dynamic>> _usable(Object? rules) => [
  if (rules is List<dynamic>)
    for (final rule in rules)
      if (rule is Map<String, dynamic> &&
          _truthy(rule['id']) &&
          _truthy(rule['text']) &&
          (!rule.containsKey('enabled') || _truthy(rule['enabled'])))
        rule,
];

/// The brand's (or model's) `notices` list, without the entries that are
/// switched off or incomplete.
List<Map<String, dynamic>> noticeRules(
  HudRules rules,
  String? manufacturer,
  String? model,
) => _usable(rules.getRuleConfig(manufacturer, model, 'notices'));

List<Map<String, dynamic>> persistentNoticeRules(
  HudRules rules,
  String? manufacturer,
  String? model,
) => _usable(rules.getRuleConfig(manufacturer, model, 'persistent_notices'));

/// How the brand draws a notice: `style` ("text", "banner", ...), `color`,
/// `caption_color`, `text_color`, `confirm_text`, `show_seconds`.
Map<String, dynamic> noticeStyle(
  HudRules rules,
  String? manufacturer,
  String? model,
) {
  final style = rules.getRuleConfig(manufacturer, model, 'notice_style');
  return {
    if (style is Map<String, dynamic>)
      for (final entry in style.entries)
        if (!isAnnotationKey(entry.key)) entry.key: entry.value,
  };
}

Notice _render(
  Map<String, dynamic> rule,
  Map<String, dynamic> style,
  Map<String, Object> context,
  int since,
) {
  var text = '${rule['text']}';
  for (final entry in context.entries) {
    text = text.replaceAll('{${entry.key}}', '${entry.value}');
  }
  return Notice(
    id: rule['id'] as Object,
    text: text,
    caption: rule['caption'] as Object? ?? '',
    color: _truthy(rule['color'])
        ? rule['color'] as Object
        : style['color'] as Object? ?? '#FFFF00',
    textColor: _truthy(rule['text_color'])
        ? rule['text_color']
        : style['text_color'],
    icon: _truthy(rule['icon']) ? rule['icon'] : style['icon'],
    since: since,
  );
}

double? _ascentRate(Waypoint wp, Waypoint? prev) {
  final rate = wp.ascentRate;
  if (rate != null) {
    return rate;
  }
  if (prev == null) {
    return null;
  }
  final d0 = prev.depth;
  final d1 = wp.depth;
  if (d0 == null || d1 == null || wp.timeSinceStart <= prev.timeSinceStart) {
    return null;
  }
  return (d0 - d1) / (wp.timeSinceStart - prev.timeSinceStart) * 60.0;
}

class _NoticeEngine {
  _NoticeEngine(this.rules, this.manufacturer, this.model, this.units);

  final HudRules rules;
  final String? manufacturer;
  final String? model;
  final UnitSystem units;

  String? _criticalTank(Waypoint wp) {
    for (final entry in wp.tanks.entries) {
      if (rules.tankPressureState(
            manufacturer,
            model,
            entry.value.pressureBar,
          ) ==
          'critical') {
        // Its name where it has one, as the tank fields show it (the name
        // in sidemount, spec §10.104); else its key, as Python.
        final name = entry.value.name;
        return name == null || name.isEmpty ? entry.key : name;
      }
    }
    return null;
  }

  /// (true now, text substitutions) for a rule at one waypoint; durations
  /// and edges are the timeline's.
  (bool, Map<String, Object>) conditionNow(
    Map<String, dynamic> rule,
    Waypoint wp,
    Waypoint? prev,
    List<Waypoint>? waypoints,
  ) {
    final when = rule['when'];
    final ctx = <String, Object>{};
    final circuits = rule['circuits'];
    if (_truthy(circuits) &&
        !(circuits is List<dynamic> && circuits.contains(wp.circuit))) {
      return (false, ctx);
    }
    if (when == 'setpoint_up' || when == 'setpoint_down') {
      final now = wp.setpoint;
      final before = prev?.setpoint;
      if (now == null || before == null) {
        return (false, ctx);
      }
      ctx['setpoint'] = pyFormatFixed(now, 1);
      return (when == 'setpoint_up' ? now > before : now < before, ctx);
    }
    final cns = wp.cns;
    if (cns != null) {
      ctx['cns'] = cns;
    }
    final next = wp.nextStopDepth;
    final stop = next == null || next == 0 ? wp.decoStopDepth : next;
    if (stop != null && stop != 0) {
      ctx['stop'] =
          '${pyFormatFixed(units_lib.stopDepth(stop, units), 0)} '
          '${units_lib.depthLabel(units)}';
    }
    switch (when) {
      case 'fit_alert':
        return (wp.diveAlerts.contains(rule['alert']), ctx);
      case 'tank_critical':
        final tank = _criticalTank(wp);
        if (tank != null) {
          ctx['tank'] = tank;
        }
        return (tank != null, ctx);
      case 'po2_below':
        final po2 = wp.po2;
        return (po2 != null && po2 < _number(rule['bar'], 0.18), ctx);
      case 'po2_above':
        final po2 = wp.po2;
        return (po2 != null && po2 > _number(rule['bar'], 1.61), ctx);
      case 'cns_at_least':
        return (cns != null && cns >= _number(rule['percent'], 90), ctx);
      case 'ascent_faster_than':
        final rate = _ascentRate(wp, prev);
        return (rate != null && rate > _number(rule['m_per_min'], 10), ctx);
      case 'ndl_at_most':
        final ndl = wp.ndl;
        if (ndl == null || ndl <= 0) {
          return (false, ctx);
        }
        if (rules.resolveState(manufacturer, model, wp, waypoints) == 'deco') {
          return (false, ctx);
        }
        return (ndl <= _number(rule['minutes'], 5) * 60.0, ctx);
      case 'depth_deeper_than':
        final depth = wp.depth;
        return (depth != null && depth > _number(rule['metres'], 40), ctx);
      case 'time_longer_than':
        final t = wp.diveTime ?? wp.timeSinceStart;
        return (t > _number(rule['minutes'], 60) * 60.0, ctx);
      case 'mod_exceeded' || 'near_mod':
        final mod = modMetres(rules, manufacturer, model, wp);
        final depth = wp.depth;
        if (mod == null || depth == null) {
          return (false, ctx);
        }
        // "34m" / "112ft" in the system in force.
        ctx['mod'] =
            '${pyFormatFixed(units_lib.depth(mod, units), 0)}'
            '${units_lib.depthLabel(units)}';
        if (when == 'mod_exceeded') {
          return (depth > mod, ctx);
        }
        return (
          mod - _number(rule['metres'], 1.9) <= depth && depth <= mod,
          ctx,
        );
      case 'stop_violation':
        final phase = rules.decoStopPhase(manufacturer, model, wp);
        return (phase == 'violation' || phase == 'ceiling_violation', ctx);
      case 'sidemount_switch':
        final target = rules.sidemountSwitchTarget(manufacturer, model, wp);
        if (target == null) {
          return (false, ctx);
        }
        final entry = wp.tanks.entries.elementAt(target == 'primary' ? 0 : 1);
        final name = entry.value.name;
        ctx['tank'] = name == null || name.isEmpty ? entry.key : name;
        // The first tank is worn on the left.
        ctx['side'] = target == 'primary' ? 'Left' : 'Right';
        return (true, ctx);
      case 'deco_required' || 'deco_cleared':
        return (
          rules.resolveState(manufacturer, model, wp, waypoints) == 'deco',
          ctx,
        );
      case 'safety_started' || 'safety_complete':
        final phase = rules
            .safetyStopPhase(manufacturer, model, wp, waypoints)
            ?.$1;
        return (
          when == 'safety_complete'
              ? phase == ssComplete
              : phase == ssCounting || phase == ssWarn,
          ctx,
        );
    }
    return (false, ctx);
  }

  /// For the latched conditions: has the situation gone away enough for
  /// the device to raise the alert again?
  bool rearmed(
    Map<String, dynamic> rule,
    Waypoint wp,
    Waypoint? prev,
    List<Waypoint>? waypoints,
  ) {
    final when = rule['when'];
    if (when == 'ndl_at_most') {
      final ndl = wp.ndl;
      return ndl != null &&
          ndl >=
              (_number(rule['minutes'], 5) +
                      _number(rule['rearm_minutes'], 3)) *
                  60.0;
    }
    if (when == 'depth_deeper_than') {
      final depth = wp.depth;
      return depth != null &&
          depth < _number(rule['metres'], 40) - _number(rule['rearm_m'], 2);
    }
    if (when == 'cns_at_least' || when == 'time_longer_than') {
      // Once per dive.
      return false;
    }
    return !conditionNow(rule, wp, prev, waypoints).$1;
  }

  Map<int, Notice?> buildTimeline(List<Waypoint> waypoints) {
    final noticeList = noticeRules(rules, manufacturer, model);
    final style = noticeStyle(rules, manufacturer, model);
    final defaultShow = (style['show_seconds'] as num? ?? defaultShowSeconds)
        .toInt();
    int showSeconds(Map<String, dynamic> rule) =>
        (rule['show_seconds'] as num? ?? defaultShow).toInt();
    final timeline = <int, Notice?>{};
    if (noticeList.isEmpty) {
      return timeline;
    }
    // Per rule: armed (may fire), since (the condition first true, for
    // durations), until (the end of its display), ctx (the text
    // substitutions at trigger time), was (the condition at the previous
    // waypoint, for the edge conditions).
    final armed = List<bool>.filled(noticeList.length, true);
    final since = List<int?>.filled(noticeList.length, null);
    final until = List<int>.filled(noticeList.length, -1);
    final was = List<bool>.filled(noticeList.length, false);
    final contexts = [for (final _ in noticeList) <String, Object>{}];
    Waypoint? prev;
    for (final wp in waypoints) {
      final t = wp.timeSinceStart;
      for (var i = 0; i < noticeList.length; i++) {
        final rule = noticeList[i];
        final (now, ctx) = conditionNow(rule, wp, prev, waypoints);
        final when = rule['when'];
        if (_edgeConditions.contains(when)) {
          // Fires on the way into the condition, or for deco_cleared out
          // of it.
          final into = when != 'deco_cleared';
          final fired = into ? now && !was[i] : !now && was[i];
          was[i] = now;
          if (fired && (when != 'deco_cleared' || prev != null)) {
            until[i] = t + showSeconds(rule);
            contexts[i].addAll(ctx);
          }
          continue;
        }
        if (!now) {
          since[i] = null;
          if (!armed[i] && rearmed(rule, wp, prev, waypoints)) {
            armed[i] = true;
          }
          continue;
        }
        since[i] ??= t;
        final held = t - since[i]!;
        final needed = _sustainedConditions.contains(when)
            ? _number(rule['seconds'], 0)
            : 0.0;
        if (armed[i] && held >= needed) {
          armed[i] = false;
          until[i] = t + showSeconds(rule);
          contexts[i].addAll(ctx);
        }
      }
      Notice? active;
      for (var i = 0; i < noticeList.length; i++) {
        if (until[i] > t) {
          active = _render(
            noticeList[i],
            style,
            contexts[i],
            until[i] - showSeconds(noticeList[i]),
          );
          break;
        }
      }
      timeline[t] = active;
      prev = wp;
    }
    return timeline;
  }
}

/// {time since start: notice or null} for the whole dive, cached per
/// waypoint list like the other timelines. [units] is the system the
/// depths in a notice's text are written in.
Map<int, Notice?>? noticeTimeline(
  HudRules rules,
  String? manufacturer,
  String? model,
  List<Waypoint>? waypoints, {
  UnitSystem units = UnitSystem.metric,
}) {
  if (waypoints == null || waypoints.isEmpty) {
    return null;
  }
  return rules.cachedTimeline(
    'notice:${units.key}',
    manufacturer,
    model,
    waypoints,
    () => _NoticeEngine(
      rules,
      manufacturer,
      model,
      units,
    ).buildTimeline(waypoints),
  );
}

/// The persistent notification the computer would be showing now: the
/// first `persistent_notices` entry whose condition holds at [waypoint]
/// (no history, no time-out: it stays while the situation lasts).
Notice? activePersistentNotice(
  HudRules rules,
  String? manufacturer,
  String? model,
  Waypoint? waypoint, {
  List<Waypoint>? waypoints,
  UnitSystem units = UnitSystem.metric,
}) {
  if (waypoint == null) {
    return null;
  }
  final style = noticeStyle(rules, manufacturer, model);
  final engine = _NoticeEngine(rules, manufacturer, model, units);
  for (final rule in persistentNoticeRules(rules, manufacturer, model)) {
    final (now, ctx) = engine.conditionNow(rule, waypoint, null, waypoints);
    if (now) {
      return _render(rule, style, ctx, waypoint.timeSinceStart);
    }
  }
  return null;
}

/// The notice the computer would be showing at [waypoint]: from the dive's
/// timeline when the whole dive is at hand, otherwise from what this one
/// waypoint says (the conditions that need no history; the Overlay
/// Designer's forced states use this).
Notice? activeNotice(
  HudRules rules,
  String? manufacturer,
  String? model,
  Waypoint? waypoint, {
  List<Waypoint>? waypoints,
  UnitSystem units = UnitSystem.metric,
}) {
  if (waypoint == null) {
    return null;
  }
  final timeline = noticeTimeline(
    rules,
    manufacturer,
    model,
    waypoints,
    units: units,
  );
  if (timeline != null) {
    return timeline[waypoint.timeSinceStart];
  }
  final style = noticeStyle(rules, manufacturer, model);
  final engine = _NoticeEngine(rules, manufacturer, model, units);
  for (final rule in noticeRules(rules, manufacturer, model)) {
    if (!_singleWaypointConditions.contains(rule['when'])) {
      continue;
    }
    final (now, ctx) = engine.conditionNow(rule, waypoint, null, null);
    if (now) {
      return _render(rule, style, ctx, waypoint.timeSinceStart);
    }
  }
  return null;
}
