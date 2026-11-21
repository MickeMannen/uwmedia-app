/// The sample dive of the Overlay Designer (Python
/// `utils/dummy_telemetry.py`): a full invented dive the time slider
/// scrubs, and forced states so that badges, notices and colours can be
/// looked at on demand.
///
/// The dive passes through every situation a template has to be checked
/// in, in this order: descent, bottom at 30 m, the NDL running down (Low
/// NDL Alert at 5 min), a deep excursion to 42 m (Depth Alert, HIGH PPO2),
/// a deco obligation with a 6 m stop, the ascent towards it (25 s of fast
/// ascent on the way), the approach, the stop, a 40 s violation (MISSED
/// DECO STOP), the stop clearing, the safety stop counting at 5 m, a pause
/// at 1.8 m, the stop completing, and the surface. One Nx32 cylinder (or
/// two for the sidemount variant) drains into the reserve during the
/// safety stop; the sidemount pair is over 35 bar apart before the first
/// change of cylinder at 7:00, so the tank-switch notification shows.
/// Garmin-style dive alerts are set where the watch would
/// raise them, so the Garmin rules see the same dive.
library;

import 'dart:math' as math;

import 'package:uwmedia_app/core/deco/gas_consumption.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

/// When the sample dive starts.
final DateTime dummyStart = naive(2026, 1, 1, 10);

/// Its length and the time between its samples, in seconds.
const dummyDurationS = 32 * 60;
const dummySampleS = 10;

// (elapsed seconds, depth m) breakpoints, straight lines between.
const _profile = <(int, double)>[
  (0, 0.0),
  (180, 30.0), // descent
  (840, 30.0), // bottom: the NDL runs out at 14:00
  (900, 42.0), // excursion below the MOD
  (960, 42.0),
  (1020, 30.0),
  (1140, 12.0), // ascent at 9 m/min
  (1165, 7.0), // 25 s at 12 m/min: fast ascent
  (1200, 6.0), // at the 6 m stop
  (1260, 6.0),
  (1270, 4.5), // 40 s above the stop
  (1310, 4.5),
  (1320, 6.0), // back at the stop until it clears (24:00)
  (1440, 6.0),
  (1500, 5.0), // safety stop
  (1560, 5.0),
  (1570, 1.8), // 40 s too shallow: paused
  (1610, 1.8),
  (1620, 5.0),
  (1860, 5.0), // counting to the end (5 min: the dive went below 30 m)
  (1920, 0.0), // surface
];

// Moments the watch would raise its own alerts (Garmin FIT dive_alert
// names). No safety_stop_started after deco: a Descent asks for no safety
// stop once a deco obligation has been cleared.
const _alerts = <int, List<String>>{
  510: ['approaching_ndl'],
  680: ['approaching_ndl'],
  840: ['ndl_reached'],
  1140: ['approaching_first_deco_stop'],
  1150: ['ascent_critical'],
  1270: ['deco_ceiling_broken'],
  1440: ['deco_stop_cleared'],
  1450: ['deco_complete'],
};
const _ndlOutS = 840; // NDL reaches zero
const _decoClearS = 1440; // last stop cleared
const _stopDepth = 6.0;
const _ceiling = 5.0;

/// The states the designer can force, in the order of its list.
const stateOptions = [
  'auto', 'normal', 'descent', 'ndl_low', //
  'deco', 'deco_approach', 'deco_at_stop', 'deco_violation',
  'deco_ceiling_violation', 'clear',
  'safety_pending', 'safety_stop', 'safety_paused', 'safety_done',
  'fast_ascent', 'high_ppo2', 'high_cns', 'low_gas', 'critical_gas',
  'surfacing',
];

/// The label of each state.
const stateLabels = {
  'auto': 'Auto (from data)',
  'normal': 'Normal',
  'descent': 'Descent',
  'ndl_low': 'Low NDL',
  'deco': 'Deco (far from the stop)',
  'deco_approach': 'Deco: approaching the stop',
  'deco_at_stop': 'Deco: at the stop',
  'deco_violation': 'Deco: above the stop',
  'deco_ceiling_violation': 'Deco: above the ceiling',
  'clear': 'Clear (deco done)',
  'safety_pending': 'Safety stop pending',
  'safety_stop': 'Safety stop counting',
  'safety_paused': 'Safety stop paused',
  'safety_done': 'Safety stop complete',
  'fast_ascent': 'Fast ascent',
  'high_ppo2': 'High PPO2 / deep',
  'high_cns': 'High CNS',
  'low_gas': 'Low gas (reserve)',
  'critical_gas': 'Critical gas',
  'surfacing': 'Surfacing',
};

/// The HUD state (the rules engine's `resolveState`) each forced state is
/// a case of. On a Shearwater any dive past 11 m is in the "safety_stop"
/// state (the counter is shown, pending) until the stop is done.
const stateOuter = {
  'normal': 'normal',
  'descent': 'normal',
  'ndl_low': 'normal',
  'deco': 'deco',
  'deco_approach': 'deco',
  'deco_at_stop': 'deco',
  'deco_violation': 'deco',
  'deco_ceiling_violation': 'deco',
  'clear': 'clear',
  'safety_pending': 'safety_stop',
  'safety_stop': 'safety_stop',
  'safety_paused': 'safety_stop',
  'safety_done': 'safety_stop',
  'fast_ascent': 'normal',
  'high_ppo2': 'normal',
  'high_cns': 'normal',
  'low_gas': 'normal',
  'critical_gas': 'normal',
  'surfacing': 'normal',
};

double _depthAt(int t) {
  if (t <= _profile.first.$1) {
    return _profile.first.$2;
  }
  for (var i = 0; i + 1 < _profile.length; i++) {
    final (t0, d0) = _profile[i];
    final (t1, d1) = _profile[i + 1];
    if (t0 <= t && t <= t1) {
      if (t1 == t0) {
        return d1;
      }
      final frac = (t - t0) / (t1 - t0);
      return d0 + (d1 - d0) * frac;
    }
  }
  return _profile.last.$2;
}

/// Seconds left at the 6 m stop: 180 until the diver gets there (20:00),
/// counting down while at the stop, frozen during the violation.
int? _stopTimeLeft(int t) {
  if (t < _ndlOutS || t >= _decoClearS) {
    return null;
  }
  if (t < 1200) {
    return 180;
  }
  if (t < 1260) {
    return 180 - (t - 1200);
  }
  if (t < 1320) {
    return 120;
  }
  return math.max(0, 120 - (t - 1320));
}

// A rebreather version of the same dive: a 0.7 bar setpoint switched to
// 1.3 below 6 m on the way down and back to 0.7 at the 1.8 m pause; three
// cells around the setpoint, cell 3 drifting low during the deep excursion
// (out of the vote); a bailout to EAN50 for the deco stop and its
// violation, back on the loop when the stop clears.
const _ccrDiluent = (18.0, 45.0);
const _ccrBailout = (50.0, 0.0);
const _ccrHighSpS = 40; // passing 6 m on the way down
const _ccrLowSpS = 1570; // the pause at 1.8 m
const _ccrBailoutS = (1200, 1440);
const _ccrAlerts = <int, List<String>>{
  _ccrHighSpS: ['setpoint_switch_auto_high'],
  _ccrLowSpS: ['setpoint_switch_auto_low'],
  1200: ['switched_to_open_circuit'],
  1440: ['switched_to_closed_circuit'],
};

void _setCcrFields(Waypoint wp, int t, double ambient) {
  final bailout = _ccrBailoutS.$1 <= t && t < _ccrBailoutS.$2;
  final gas = bailout ? _ccrBailout : _ccrDiluent;
  wp
    ..divemode = bailout ? 'opencircuit' : 'closedcircuit'
    ..gasO2Percent = gas.$1
    ..gasHePercent = gas.$2
    ..diluentO2Percent = _ccrDiluent.$1
    ..diluentHePercent = _ccrDiluent.$2;
  var setpoint = _ccrHighSpS <= t && t < _ccrLowSpS ? 1.3 : 0.7;
  // Pure O2 at the surface cannot reach more.
  setpoint = pyMin(setpoint, pyRoundTo(ambient * 0.98, 2));
  final drift = 900 <= t && t < 990 ? 0.45 : 0.0;
  wp
    ..po2_1 = pyRoundTo(setpoint + 0.02, 2)
    ..po2_2 = pyRoundTo(setpoint - 0.01, 2)
    ..po2_3 = pyRoundTo(setpoint - 0.03 - drift, 2);
  if (bailout) {
    wp
      ..setpoint = null
      ..po2 = pyRoundTo(ambient * gas.$1 / 100.0, 2);
  } else {
    wp
      ..setpoint = setpoint
      ..po2 = setpoint;
  }
}

/// The gas used, in bar a minute at the surface: the open-circuit dive's
/// SAC. Its VSAC is that times the cylinder size, an 11.1 l AL80 (Nx32).
/// The Python sample dive has neither, so its SAC and VSAC fields show
/// nothing (spec §10.54).
const double _sacBarPerMin = 1.8;
const double _tankVolumeL = 11.1;

/// The first change of sidemount cylinder (utils/dummy_telemetry.py
/// `_SIDEMOUNT_FIRST_SWITCH_S`).
const int _sidemountFirstSwitchS = 7 * 60;

/// A 32-minute invented dive, the same every time (see the library
/// comment). [variant] only decides the number of tanks (two for
/// "sidemount", else one). [ccr] gives the rebreather version, with an
/// oxygen cylinder and the diluent as its tanks. [sac] false leaves out
/// SAC, VSAC and the tank sizes, for the dive Python's sample dive is
/// (what is compared with the Python app's renders and sweep).
Dive buildDummyDive({
  String? variant = 'single_tank',
  bool ccr = false,
  bool sac = true,
}) {
  final keys = ccr
      ? ['O2', 'DIL']
      : (variant == 'sidemount' ? ['Left', 'Right'] : ['T1']);
  final pressures = {for (final key in keys) key: 200.0};
  final waypoints = <Waypoint>[];
  var maxDepth = 0.0;
  var bottomTimeS = 0.0;
  var prevDepth = 0.0;

  for (var t = 0; t <= dummyDurationS; t += dummySampleS) {
    final depth = pyRoundTo(_depthAt(t), 1);
    maxDepth = pyMax(maxDepth, depth);
    final ambient = 1.0 + depth / 10.0;
    final inDeco = _ndlOutS <= t && t < _decoClearS;

    // Gas: 1.8 bar/min at the surface, scaled by the pressure, so
    // the single cylinder is into the reserve (under 50 bar) by the safety
    // stop; sidemount stays on the first cylinder for the first 7 minutes,
    // until the two are over 35 bar apart (past every brand's switch
    // threshold, so the tank-switch cue shows), then alternates every 5
    // minutes.
    final rateBarPerS = _sacBarPerMin / 60.0 * ambient;
    final String active;
    if (keys.length != 2) {
      active = keys[0];
    } else if (t < _sidemountFirstSwitchS) {
      active = keys[0];
    } else {
      active = keys[((t - _sidemountFirstSwitchS) ~/ 300 + 1) % 2];
    }
    pressures[active] = pyMax(
      20.0,
      pressures[active]! - rateBarPerS * dummySampleS,
    );

    if (depth >= 10.0) {
      bottomTimeS += dummySampleS;
    }
    final bottomMin = bottomTimeS / 60.0;

    // NDL: by depth on the way down, then 20 min running to 0 at 14:00
    // (the Low NDL Alert fires at 5 min), none in deco, 99 after.
    final int? ndlS;
    if (t < 180) {
      ndlS = (pyMax(3.0, pyMin(99.0, 99.0 - depth * 2.6)) * 60).truncate();
    } else if (t < _ndlOutS) {
      ndlS = pyRound(20.0 * (_ndlOutS - t) / (_ndlOutS - 180) * 60);
    } else if (inDeco) {
      ndlS = null;
    } else {
      ndlS = 99 * 60;
    }
    final stopLeft = _stopTimeLeft(t);
    // TTS: direct ascent at 9 m/min plus the stop and the safety stop.
    final ttsS =
        (depth / 9.0 * 60 + (stopLeft ?? 0) + (maxDepth >= 10.0 ? 180 : 0))
            .truncate();

    final primaryPressure = pressures[keys[0]]!;
    final airRemainingS = (pyMax(0.0, primaryPressure - 50.0) / rateBarPerS)
        .truncate();
    final ascentRate = t != 0 ? (prevDepth - depth) / dummySampleS * 60.0 : 0.0;
    prevDepth = depth;

    final tanks = {
      for (final key in keys)
        key: TankData(
          pressureBar: pyRoundTo(pressures[key]!, 1),
          o2Percent: 32.0,
          name: key,
          mode: 'OC',
          enabled: true,
        ),
    };
    final alerts = [...?_alerts[t]];
    if (ccr) {
      // The loop uses little gas: O2 and diluent drain slowly and evenly.
      for (final (key, mix) in [('O2', (100.0, 0.0)), ('DIL', _ccrDiluent)]) {
        tanks[key]!
          ..o2Percent = mix.$1
          ..hePercent = mix.$2
          ..mode = 'CC'
          ..pressureBar = pyRoundTo(
            200.0 - t / dummyDurationS * (key == 'O2' ? 40.0 : 25.0),
            1,
          );
      }
      alerts.addAll(_ccrAlerts[t] ?? const []);
    }
    final cleared = t == _decoClearS;

    final waypoint = Waypoint(
      timestamp: dummyStart.add(Duration(seconds: t)),
      depth: depth,
      temp: pyRoundTo(27.0 - depth * 0.12, 1),
      maxDepth: maxDepth,
      decoStopDepth: inDeco ? _stopDepth : (cleared ? 0.0 : null),
      ceiling: inDeco ? _ceiling : null,
      nextStopDepth: inDeco ? _stopDepth : (cleared ? 0.0 : null),
      nextStopTime: inDeco ? stopLeft : (cleared ? 0 : null),
      tts: ttsS,
      ndl: ndlS,
      timeSinceStart: t,
      diveTime: t,
      tanks: tanks,
      airRemaining: airRemainingS,
      // SAC and VSAC once the computer has its two minutes of pressures;
      // none on the loop.
      pressureSac: sac && !ccr && t >= sacWindowSec ? _sacBarPerMin : null,
      volumeSac: sac && !ccr && t >= sacWindowSec
          ? pyRoundTo(_sacBarPerMin * _tankVolumeL, 2)
          : null,
      ascentRate: pyRoundTo(ascentRate, 1),
      n2TissueLoad: pyRoundTo(pyMin(150.0, depth * 3.0 + bottomMin * 1.5), 1),
      heartRate: (78 + 10 * math.sin(t / 240.0)).truncate(),
      cns: pyMin(45, bottomMin * 1.4 + (maxDepth > 40 ? 10 : 0)).truncate(),
      po2: pyRoundTo(0.32 * ambient, 2),
      divemode: 'OC',
      gf: pyRoundTo(
        pyMin(inDeco ? 110.0 : 85.0, depth * 1.8 + bottomMin * 1.2),
        1,
      ),
      battery: 87.0,
      diveAlerts: alerts,
    );
    if (ccr) {
      _setCcrFields(waypoint, t, ambient);
    }
    waypoints.add(waypoint);
  }

  return Dive(
    startTime: dummyStart,
    endTime: dummyStart.add(const Duration(seconds: dummyDurationS)),
    waypoints: waypoints,
    device: 'Synthetic dive computer',
    manufactor: 'UWMedia',
    // A Shearwater's default conservatism, Med (Perdix 2 manual p.18).
    gfLow: 40,
    gfHigh: 85,
    durationSeconds: dummyDurationS,
    logFilename: 'dummy_telemetry',
    tankVolumesL: !sac || ccr
        ? null
        : {for (final key in keys) key: _tankVolumeL},
  );
}

/// The first waypoint at or after [seconds] of dive time, else the last
/// one: the rule the designer's scrubbing uses.
Waypoint? waypointAt(Dive? dive, num seconds) {
  if (dive == null || dive.waypoints.isEmpty) {
    return null;
  }
  for (final wp in dive.waypoints) {
    if (wp.timeSinceStart >= seconds) {
      return wp;
    }
  }
  return dive.waypoints.last;
}

// A copy of a waypoint with some fields changed, by their names in the
// model's JSON (Python's `model_copy(update=...)`), in the same dive.
Waypoint _copy(Waypoint wp, Map<String, Object?> update) =>
    Waypoint.fromJson({...wp.toJson(), ...update})..dive = wp.dive;

// --- forced states --------------------------------------------------------

const Map<String, Object?> _quiet = {
  'deco_stop_depth': null,
  'next_stop_depth': null,
  'next_stop_time': null,
  'ceiling': null,
  'ndl': 600,
  'tts': 300,
  'dive_alerts': <String>[],
};
const Map<String, Object?> _deco = {
  'deco_stop_depth': _stopDepth,
  'next_stop_depth': _stopDepth,
  'next_stop_time': 180,
  'ceiling': _ceiling,
  'ndl': null,
  'tts': 600,
  'dive_alerts': <String>[],
};
const _started = {
  'dive_alerts': ['safety_stop_started'],
};

/// One stretch of a forced history: its length in seconds, its depth (or a
/// ramp from one depth to another) and the values of its waypoints.
typedef _Segment = (int seconds, double from, double to, Map<String, Object?>);

_Segment _at(int seconds, double depth, Map<String, Object?> extras) =>
    (seconds, depth, depth, extras);

// state -> the segments ending at the forced waypoint, and the values of
// that last waypoint only. Every history starts deeper than the
// safety-stop trigger where the state needs it armed.
final Map<String, (List<_Segment>, Map<String, Object?>)> _forced = {
  'descent': (
    [(60, 0.0, 10.0, _quiet)],
    {'ascent_rate': -10.0, 'max_depth': 10.0},
  ),
  'ndl_low': ([_at(120, 30.0, _quiet)], {'ndl': 240}),
  'deco': ([_at(60, 30.0, _deco)], {'depth': 20.0}),
  'deco_approach': ([_at(60, 30.0, _deco)], {'depth': 9.0}),
  'deco_at_stop': ([_at(60, 30.0, _deco)], {'depth': 6.4}),
  'deco_violation': (
    [_at(60, 30.0, _deco), _at(30, 6.0, _deco), _at(40, 5.6, _deco)],
    {
      'dive_alerts': ['deco_ceiling_broken'],
    },
  ),
  'deco_ceiling_violation': (
    [_at(60, 30.0, _deco), _at(30, 6.0, _deco), _at(40, 4.5, _deco)],
    {
      'dive_alerts': ['deco_ceiling_broken'],
    },
  ),
  'clear': (
    [
      _at(60, 30.0, _deco),
      _at(60, 6.0, {..._deco, 'next_stop_time': 30}),
      _at(10, 4.5, {
        ..._quiet,
        'deco_stop_depth': 0.0,
        'next_stop_depth': 0.0,
        'next_stop_time': 0,
        'ndl': 99 * 60,
        'tts': 30,
      }),
    ],
    {
      'dive_alerts': ['deco_stop_cleared'],
    },
  ),
  'safety_pending': ([_at(120, 20.0, _quiet), _at(10, 8.0, _quiet)], {}),
  'safety_stop': (
    [
      _at(120, 20.0, _quiet),
      _at(60, 5.0, {..._quiet, 'next_stop_depth': 5.0, 'next_stop_time': 120}),
    ],
    _started,
  ),
  'safety_paused': (
    [
      _at(120, 20.0, _quiet),
      _at(60, 5.0, {..._quiet, ..._started}),
      _at(30, 1.8, _quiet),
    ],
    {},
  ),
  'safety_done': (
    [
      _at(120, 20.0, _quiet),
      _at(320, 5.0, {..._quiet, ..._started}),
    ],
    {},
  ),
  // 12 m/min for 10 s
  'fast_ascent': (
    [_at(60, 20.0, _quiet), (20, 20.0, 16.0, _quiet)],
    {
      'dive_alerts': ['ascent_critical'],
    },
  ),
  // 30 s above the limit, then shown
  'high_ppo2': (
    [
      _at(40, 42.0, {..._quiet, 'po2': 1.7}),
    ],
    {'max_depth': 42.0},
  ),
  'high_cns': (
    [_at(30, 20.0, _quiet)],
    {
      'cns': 95,
      'dive_alerts': ['cns_critical'],
    },
  ),
  'low_gas': ([_at(30, 20.0, _quiet)], {'_tank_bar': 47.0}),
  'critical_gas': ([_at(30, 20.0, _quiet)], {'_tank_bar': 23.0}),
  'surfacing': (
    [
      _at(120, 20.0, _quiet),
      _at(200, 5.0, {..._quiet, ..._started}),
      _at(10, 0.3, _quiet),
    ],
    {},
  ),
};

const _keepsMaxDepth = ['low_gas', 'critical_gas', 'high_cns', 'ndl_low'];

Map<String, Object?> _withTanks(Waypoint wp, double bar) => {
  'tanks': wp.tanks.isEmpty
      ? {
          'T1': TankData(
            pressureBar: bar,
            o2Percent: 32.0,
            name: 'T1',
            mode: 'OC',
            enabled: true,
          ).toJson(),
        }
      : {
          for (final MapEntry(:key, :value) in wp.tanks.entries)
            key: {...value.toJson(), 'pressure_bar': bar},
        },
};

/// The waypoint and the history for a forced [state]: a short invented
/// dive ending in that situation, built from [waypoint]'s own values
/// (tanks, temperature, CNS …). The history is what the timelines (safety
/// stop, deco clear, notices) need to report the state. "auto" and an
/// unknown state give the waypoint itself and no history, "normal" the
/// single-waypoint form of [applyState].
(Waypoint?, List<Waypoint>?) forcedDive(Waypoint? waypoint, String state) {
  if (waypoint == null || !stateOptions.contains(state) || state == 'auto') {
    return (waypoint, null);
  }
  if (state == 'normal') {
    return (applyState(waypoint, 'normal'), null);
  }
  final (segments, last) = _forced[state]!;
  final history = <Waypoint>[];
  var t = 0;
  var maxDepth = 0.0;
  double? prevDepth;
  for (final (seconds, from, to, extras) in segments) {
    final steps = math.max(1, seconds ~/ dummySampleS);
    for (var i = 0; i < steps; i++) {
      final d = from == to ? from : from + (to - from) * (i + 1) / steps;
      maxDepth = pyMax(maxDepth, d);
      history.add(
        _copy(waypoint, {
          ...extras,
          'dive_alerts': i == 0 ? extras['dive_alerts'] : const <String>[],
          'depth': pyRoundTo(d, 1),
          'max_depth': pyMax(
            maxDepth,
            _keepsMaxDepth.contains(state) ? waypoint.maxDepth : 0.0,
          ),
          'ascent_rate': prevDepth == null
              ? 0.0
              : pyRoundTo((prevDepth - d) / dummySampleS * 60.0, 1),
          'time_since_start': t,
          'dive_time': t,
          'timestamp': formatNaive(dummyStart.add(Duration(seconds: t))),
        }),
      );
      prevDepth = d;
      t += dummySampleS;
    }
  }
  final end = history.last;
  final update = {
    for (final MapEntry(:key, :value) in last.entries)
      if (!key.startsWith('_')) key: value,
    if (last['_tank_bar'] case final double bar) ..._withTanks(end, bar),
  };
  if (update['max_depth'] case final double depth) {
    update['max_depth'] = pyMax(depth, end.maxDepth);
  }
  final forced = _copy(end, update);
  history[history.length - 1] = forced;
  return (forced, history);
}

/// A copy of [waypoint] changed so that the rules engine reports [state]
/// from this one waypoint (both the Garmin alerts path and the
/// Shearwater/UDDF depth bands are satisfied at once) for the four
/// original states; the other states are [forcedDive]'s last waypoint.
/// "auto" and anything unknown give the waypoint itself.
Waypoint applyState(Waypoint waypoint, String state) {
  if (!stateOptions.contains(state) || state == 'auto') {
    return waypoint;
  }
  final update = <String, Object?>{
    'deco_stop_depth': null,
    'next_stop_depth': null,
    'next_stop_time': null,
    'dive_alerts': const <String>[],
  };
  final depth = waypoint.depth;
  switch (state) {
    case 'normal':
      // Take away the safety-stop trigger (max depth of 10 m or more while
      // between 3 and 6 m) without moving the diver somewhere unlikely.
      if (depth != null && 3.0 <= depth && depth <= 6.0) {
        update['max_depth'] = pyMin(waypoint.maxDepth, 9.9);
      }
    case 'safety_stop':
      update.addAll({
        'depth': 5.0,
        'max_depth': pyMax(waypoint.maxDepth, 18.0),
        'next_stop_depth': 5.0,
        'next_stop_time': 120,
        'dive_alerts': ['safety_stop_started'],
      });
    case 'deco':
      update.addAll({
        'depth': 12.0,
        'max_depth': pyMax(waypoint.maxDepth, 30.0),
        'deco_stop_depth': 6.0,
        'next_stop_depth': 6.0,
        'next_stop_time': 180,
        'ndl': null,
        'tts': 600,
        'dive_alerts': ['approaching_first_deco_stop'],
      });
    case 'clear':
      // Deco just cleared: Garmin's own deco_stop_cleared alert drives the
      // alert path; a Shearwater badge shows its deco-clear count-up.
      update.addAll({
        'depth': 4.5,
        'max_depth': pyMax(waypoint.maxDepth, 30.0),
        'deco_stop_depth': 0.0,
        'next_stop_depth': 0.0,
        'next_stop_time': 0,
        'ndl': 99 * 60,
        'tts': 30,
        'dive_alerts': ['deco_stop_cleared'],
      });
    default:
      return forcedDive(waypoint, state).$1!;
  }
  return _copy(waypoint, update);
}
