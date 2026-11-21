/// A hand-built dive profile (Python `models/dive_plan.py`): its gases,
/// its waypoints and the settings the Dive Profile Builder plans with.
/// Field names in JSON are the Python model's.
library;

import 'package:uwmedia_app/core/deco/deco_engine.dart';
import 'package:uwmedia_app/core/plan/dive_computers.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';

/// The tank reference of a CCR dive's oxygen cylinder (not a gas of the
/// plan: it is never breathed directly, the loop draws on it to hold the
/// setpoint).
const ccrO2TankRef = 'O2';

const _gasTypes = ['air', 'nitrox', 'trimix'];
const _diveTypes = ['oc', 'sidemount', 'ccr'];
const _sides = ['left', 'right'];
const _gasPhases = ['any', 'descent', 'ascent'];
const _phases = ['descent', 'ascent'];

Never _invalid(String field, Object? value, String rule) =>
    throw FormatException('$field: $rule', value);

double _number(
  Map<String, dynamic> json,
  String key,
  double fallback, {
  double? ge,
  double? gt,
  double? le,
}) {
  final raw = json[key];
  if (!json.containsKey(key)) {
    return fallback;
  }
  final value = raw is num
      ? raw.toDouble()
      : (raw is String ? pyFloat(raw) : null);
  if (value == null) {
    _invalid(key, raw, 'not a number');
  }
  _check(key, value, ge: ge, gt: gt, le: le);
  return value;
}

void _check(String key, num value, {double? ge, double? gt, double? le}) {
  if (ge != null && !(value >= ge)) {
    _invalid(key, value, 'must be at least $ge');
  }
  if (gt != null && !(value > gt)) {
    _invalid(key, value, 'must be more than $gt');
  }
  if (le != null && !(value <= le)) {
    _invalid(key, value, 'must be at most $le');
  }
}

double? _optional(
  Map<String, dynamic> json,
  String key, {
  double? ge,
  double? gt,
}) => json[key] == null ? null : _number(json, key, 0, ge: ge, gt: gt);

int? _wholeOrNull(Map<String, dynamic> json, String key, {double? gt}) {
  final raw = json[key];
  if (raw == null) {
    return null;
  }
  if (raw is! num || raw != raw.truncate()) {
    _invalid(key, raw, 'not a whole number');
  }
  _check(key, raw, gt: gt);
  return raw.toInt();
}

String? _oneOf(Map<String, dynamic> json, String key, List<String> allowed) {
  final raw = json[key];
  if (raw == null) {
    return null;
  }
  if (!allowed.contains(raw)) {
    _invalid(key, raw, 'not one of $allowed');
  }
  return raw as String;
}

// A key that is there has to hold the right kind of value: nothing (null)
// is only a value for the fields that may be without one.
String _text(Map<String, dynamic> json, String key, String fallback) {
  if (!json.containsKey(key)) {
    return fallback;
  }
  final raw = json[key];
  if (raw is! String) {
    _invalid(key, raw, 'not text');
  }
  return raw;
}

String? _textOrNull(Map<String, dynamic> json, String key) {
  final raw = json[key];
  if (raw != null && raw is! String) {
    _invalid(key, raw, 'not text');
  }
  return raw as String?;
}

bool _flag(Map<String, dynamic> json, String key) {
  if (!json.containsKey(key)) {
    return false;
  }
  final raw = json[key];
  if (raw is! bool) {
    _invalid(key, raw, 'not true or false');
  }
  return raw;
}

String _choice(
  Map<String, dynamic> json,
  String key,
  List<String> allowed,
  String fallback,
) {
  if (!json.containsKey(key)) {
    return fallback;
  }
  return _oneOf(json, key, allowed) ?? _invalid(key, null, 'not set');
}

List<Map<String, dynamic>> _maps(Map<String, dynamic> json, String key) {
  if (!json.containsKey(key)) {
    return const [];
  }
  final raw = json[key];
  if (raw is! List || raw.any((item) => item is! Map<String, dynamic>)) {
    _invalid(key, raw, 'not a list of entries');
  }
  return raw.cast<Map<String, dynamic>>();
}

// Python's truthiness of a JSON value.
bool _truthy(Object? value) =>
    value != null &&
    value != false &&
    value != 0 &&
    value != '' &&
    !(value is List && value.isEmpty) &&
    !(value is Map && value.isEmpty);

/// One physical tank of the dive, as the log writers record it.
class TankSpec {
  const TankSpec({
    required this.ref,
    required this.sizeL,
    required this.startPressureBar,
    required this.o2Percent,
    required this.hePercent,
    this.role = 'oc',
    this.gasId,
  });

  final String ref;
  final double sizeL;
  final double startPressureBar;
  final double o2Percent;
  final double hePercent;

  /// "oc" (breathed open circuit, a bailout too), "diluent" or "oxygen".
  final String role;

  /// The gas filled in it; `null` for the CCR oxygen cylinder.
  final String? gasId;

  Map<String, dynamic> toJson() => {
    'ref': ref,
    'size_l': sizeL,
    'start_pressure_bar': startPressureBar,
    'o2_percent': o2Percent,
    'he_percent': hePercent,
    'role': role,
    'gas_id': gasId,
  };
}

/// One gas available to the profile. On a CCR dive the diluent gas is the
/// loop: what is breathed from it is worked out per depth to hold the
/// plan's setpoint.
class PlannedGas {
  PlannedGas({
    required this.id,
    this.gasType = 'air',
    this.o2Percent = 21.0,
    this.hePercent = 0.0,
    this.diluent = false,
    this.side,
    this.tankRef = 'T1',
    this.tankSizeL = 11.1,
    this.startPressureBar = 207.0,
    this.sacLpm,
    this.useMinDepthM,
    this.useMaxDepthM,
    this.usePhase = 'any',
    this.color,
  });

  factory PlannedGas.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String) {
      _invalid('id', id, 'a gas needs an id');
    }
    return PlannedGas(
      id: id,
      gasType: _choice(json, 'gas_type', _gasTypes, 'air'),
      o2Percent: _number(json, 'o2_percent', 21.0, ge: 1.0, le: 100.0),
      hePercent: _number(json, 'he_percent', 0.0, ge: 0.0, le: 99.0),
      diluent: _flag(json, 'diluent'),
      side: _oneOf(json, 'side', _sides),
      tankRef: _text(json, 'tank_ref', 'T1'),
      tankSizeL: _number(json, 'tank_size_l', 11.1, gt: 0),
      startPressureBar: _number(json, 'start_pressure_bar', 207.0, ge: 0),
      sacLpm: _optional(json, 'sac_lpm', ge: 0),
      useMinDepthM: _optional(json, 'use_min_depth_m', ge: 0),
      useMaxDepthM: _optional(json, 'use_max_depth_m', ge: 0),
      usePhase: _choice(json, 'use_phase', _gasPhases, 'any'),
      color: _textOrNull(json, 'color'),
    );
  }

  /// A label that is the gas's own, "Bottom" or "Deco 50%".
  String id;

  /// "air", "nitrox" or "trimix".
  String gasType;
  double o2Percent;
  double hePercent;

  /// CCR dives only: this gas is the loop's diluent; the others are
  /// open-circuit bailout.
  bool diluent;

  /// Sidemount dives only: "left" or "right", the side the tank is worn
  /// on; `null` for a stage tank. The left and the right tank (the same
  /// gas) are breathed in turn; the right one is never picked on its own.
  String? side;

  /// The tank this gas is breathed from.
  String tankRef;

  /// An AL80 by default: 11.1 L of water, 207 bar.
  double tankSizeL;
  double startPressureBar;

  /// This gas's own SAC in L/min; `null` for the plan's.
  double? sacLpm;

  /// The depth range the gas is picked in by itself; `null` ends are the
  /// surface and no limit.
  double? useMinDepthM;
  double? useMaxDepthM;

  /// The part of the dive the range is for: "descent" (the descent and the
  /// bottom), "ascent" (everything after the deepest waypoint) or "any".
  String usePhase;

  /// "#RRGGBB" of the profile line while this gas is breathed; `null` for
  /// a colour by position.
  String? color;

  bool get hasDepthRange => useMinDepthM != null || useMaxDepthM != null;

  bool coversDepth(double depthM) =>
      (useMinDepthM ?? 0.0) <= depthM &&
      depthM <= (useMaxDepthM ?? double.infinity);

  double get fO2 => o2Percent / 100.0;

  double get fHe => hePercent / 100.0;

  double get modM => modMeters(fO2);

  Map<String, dynamic> toJson() => {
    'id': id,
    'gas_type': gasType,
    'o2_percent': o2Percent,
    'he_percent': hePercent,
    'diluent': diluent,
    'side': side,
    'tank_ref': tankRef,
    'tank_size_l': tankSizeL,
    'start_pressure_bar': startPressureBar,
    'sac_lpm': sacLpm,
    'use_min_depth_m': useMinDepthM,
    'use_max_depth_m': useMaxDepthM,
    'use_phase': usePhase,
    'color': color,
  };
}

/// One hand-placed point of the profile. The move to it starts right after
/// the waypoint before it, at [rateMPerMin] (or the plan's rate for that
/// direction); what time is left before [runtimeSec] is spent at
/// [depthM].
class PlannedWaypoint {
  PlannedWaypoint({
    required this.runtimeSec,
    required this.depthM,
    required this.gasId,
    this.rateMPerMin,
    this.phase,
    this.gasAuto = false,
  });

  factory PlannedWaypoint.fromJson(Map<String, dynamic> json) {
    final runtime = _wholeOrNull(json, 'runtime_sec');
    if (runtime == null || runtime < 0) {
      _invalid('runtime_sec', json['runtime_sec'], 'must be 0 or more');
    }
    if (json['depth_m'] == null) {
      _invalid('depth_m', null, 'a waypoint needs a depth');
    }
    final gas = json['gas_id'];
    if (gas is! String) {
      _invalid('gas_id', gas, 'a waypoint needs a gas');
    }
    return PlannedWaypoint(
      runtimeSec: runtime,
      depthM: _number(json, 'depth_m', 0, ge: 0),
      gasId: gas,
      rateMPerMin: _optional(json, 'rate_m_per_min', gt: 0),
      phase: _oneOf(json, 'phase', _phases),
      gasAuto: _flag(json, 'gas_auto'),
    );
  }

  /// Dive time in seconds.
  int runtimeSec;
  double depthM;
  String gasId;

  /// The rate of the move that arrives here; `null` for the plan's.
  double? rateMPerMin;

  /// "descent" or "ascent" when set by hand (the waypoints that end the
  /// dive, which can lie at the greatest depth and still belong to the
  /// ascent); `null` to have it worked out.
  String? phase;

  /// The gas is picked again from the gases' depth ranges whenever the
  /// plan changes.
  bool gasAuto;

  Map<String, dynamic> toJson() => {
    'runtime_sec': runtimeSec,
    'depth_m': depthM,
    'gas_id': gasId,
    'rate_m_per_min': rateMPerMin,
    'phase': phase,
    'gas_auto': gasAuto,
  };
}

/// A gas of an older plan, or of a log, that was one sidemount pair (tanks
/// `<tank_ref>L` and `<tank_ref>R`) as two tanks: the gas itself on the
/// left in its own tank, and `<name> R` on the right in [rightRef] or else
/// the next free `T<n>`. Only a dive's first pair gets sides; a later one
/// becomes a stage tank ([first] false).
List<Map<String, dynamic>> splitSidemountPair(
  Map<String, dynamic> gas,
  Iterable<String> takenRefs, {
  bool first = true,
  String? rightRef,
}) {
  final left = Map<String, dynamic>.of(gas)..remove('sidemount_pair');
  if (!first) {
    return [left];
  }
  left['side'] = 'left';
  var ref = rightRef;
  if (ref == null) {
    final taken = {...takenRefs, left['tank_ref'] ?? 'T1'};
    var n = 1;
    while (taken.contains('T$n')) {
      n++;
    }
    ref = 'T$n';
  }
  return [
    left,
    {
      ...left,
      'id': '${left['id']} R',
      'side': 'right',
      'tank_ref': ref,
      'color': null,
    },
  ];
}

class DiveProfilePlan {
  DiveProfilePlan({
    this.name = 'Custom Dive',
    this.gfLow = 30.0,
    this.gfHigh = 70.0,
    this.defaultDescentRate = 20.0,
    this.defaultAscentRate = 9.0,
    this.waterTempC = 20.0,
    this.sacLpm = 20.0,
    this.maxPo2Bottom = 1.4,
    this.maxPo2Deco = 1.6,
    this.maxDepthM,
    this.plannedRuntimeSec,
    this.diveType = 'oc',
    this.ccrLowSetpoint = 0.7,
    this.ccrHighSetpoint = 1.3,
    this.ccrHighSetpointDepthM = 8.0,
    this.ccrLowSetpointDepthM = 2.0,
    this.ccrO2TankSizeL = 3.0,
    this.ccrO2StartPressureBar = 200.0,
    this.sidemountSwitchBar = 30.0,
    this.startTime,
    this.computer = defaultDiveComputer,
    this.computerSerial = '12345678',
    List<PlannedGas>? gases,
    List<PlannedWaypoint>? waypoints,
  }) : assert(startTime == null || startTime.isUtc, naiveTimeMessage),
       gases = gases ?? [],
       waypoints = waypoints ?? [];

  /// From the model's JSON, with the forms older versions saved brought up
  /// to date: a computer's old label, one setpoint switch depth for both
  /// ways (kept as the depth of the switch up, the switch down 6 m above
  /// it), and a gas marked as a sidemount pair (the left tank, and a right
  /// tank of the same gas beside it). Throws a [FormatException] for a
  /// value outside its range.
  factory DiveProfilePlan.fromJson(Map<String, dynamic> source) {
    final json = Map<String, dynamic>.of(source);
    if (json.containsKey('ccr_setpoint_switch_depth_m')) {
      final old = json.remove('ccr_setpoint_switch_depth_m');
      if (old != null && !json.containsKey('ccr_high_setpoint_depth_m')) {
        final depth = _number({'d': old}, 'd', 0);
        json['ccr_high_setpoint_depth_m'] = depth;
        json.putIfAbsent(
          'ccr_low_setpoint_depth_m',
          () => pyMax(0.0, depth - 6.0),
        );
      }
    }
    final all = _maps(json, 'gases');
    final gases = <Map<String, dynamic>>[];
    for (final gas in all) {
      if (_truthy(gas['sidemount_pair'])) {
        if (gas['id'] is! String) {
          _invalid('id', gas['id'], 'a gas needs an id');
        }
        gases.addAll(
          splitSidemountPair(gas, [
            for (final g in all) _text(g, 'tank_ref', 'T1'),
            for (final g in gases) _text(g, 'tank_ref', 'T1'),
          ], first: !gases.any((g) => _truthy(g['side']))),
        );
      } else {
        gases.add(gas);
      }
    }
    final start = json['start_time'];
    return DiveProfilePlan(
      name: _text(json, 'name', 'Custom Dive'),
      gfLow: _number(json, 'gf_low', 30.0, ge: 0, le: 100),
      gfHigh: _number(json, 'gf_high', 70.0, ge: 0, le: 100),
      defaultDescentRate: _number(json, 'default_descent_rate', 20.0, gt: 0),
      defaultAscentRate: _number(json, 'default_ascent_rate', 9.0, gt: 0),
      waterTempC: _number(json, 'water_temp_c', 20.0),
      sacLpm: _number(json, 'sac_lpm', 20.0, ge: 0),
      maxPo2Bottom: _number(json, 'max_po2_bottom', 1.4, ge: 0.5, le: 2.0),
      maxPo2Deco: _number(json, 'max_po2_deco', 1.6, ge: 0.5, le: 2.0),
      maxDepthM: _optional(json, 'max_depth_m', gt: 0),
      plannedRuntimeSec: _wholeOrNull(json, 'planned_runtime_sec', gt: 0),
      diveType: _choice(json, 'dive_type', _diveTypes, 'oc'),
      ccrLowSetpoint: _number(json, 'ccr_low_setpoint', 0.7, ge: 0.4, le: 1.6),
      ccrHighSetpoint: _number(
        json,
        'ccr_high_setpoint',
        1.3,
        ge: 0.4,
        le: 1.6,
      ),
      ccrHighSetpointDepthM: _number(
        json,
        'ccr_high_setpoint_depth_m',
        8.0,
        ge: 0,
      ),
      ccrLowSetpointDepthM: _number(
        json,
        'ccr_low_setpoint_depth_m',
        2.0,
        ge: 0,
      ),
      ccrO2TankSizeL: _number(json, 'ccr_o2_tank_size_l', 3.0, gt: 0),
      ccrO2StartPressureBar: _number(
        json,
        'ccr_o2_start_pressure_bar',
        200.0,
        ge: 0,
      ),
      sidemountSwitchBar: _number(json, 'sidemount_switch_bar', 30.0, gt: 0),
      startTime: start == null
          ? null
          : (start is String ? pyFromIsoformatNaive(start) : null) ??
                _invalid('start_time', start, 'not a date and time'),
      computer: computerLabel(_text(json, 'computer', defaultDiveComputer)),
      computerSerial: _text(json, 'computer_serial', '12345678'),
      gases: [for (final gas in gases) PlannedGas.fromJson(gas)],
      waypoints: [
        for (final wp in _maps(json, 'waypoints')) PlannedWaypoint.fromJson(wp),
      ],
    );
  }

  String name;
  double gfLow;
  double gfHigh;

  /// m/min.
  double defaultDescentRate;
  double defaultAscentRate;
  double waterTempC;

  /// Surface air consumption in L/min for every gas without its own.
  double sacLpm;

  /// The highest PO2 accepted on the descent and the bottom, and on the
  /// ascent: each limits a gas's MOD there.
  double maxPo2Bottom;
  double maxPo2Deco;

  /// The planned depth and runtime, which fix the chart's axes.
  double? maxDepthM;
  int? plannedRuntimeSec;

  /// "oc", "sidemount" (open circuit from a left and a right tank of the
  /// same gas) or "ccr" (the diluent gas is the loop, every other gas an
  /// open-circuit bailout).
  String diveType;

  /// The loop's PO2 from the start and again once back above
  /// [ccrLowSetpointDepthM], and the one once deeper than
  /// [ccrHighSetpointDepthM].
  double ccrLowSetpoint;
  double ccrHighSetpoint;
  double ccrHighSetpointDepthM;
  double ccrLowSetpointDepthM;
  double ccrO2TankSizeL;
  double ccrO2StartPressureBar;

  /// Sidemount: the other tank of the pair is taken once the one breathed
  /// is this far below it.
  double sidemountSwitchBar;

  /// The local start of the dive; `null` for the time of saving.
  DateTime? startTime;

  /// The label of the computer the log poses as.
  String computer;

  /// Digits only: FIT stores the serial as a number.
  String computerSerial;
  List<PlannedGas> gases;
  List<PlannedWaypoint> waypoints;

  /// The waypoints by time; ones of the same time keep their order.
  List<PlannedWaypoint> sortedWaypoints() {
    final indexed = waypoints.indexed.toList()
      ..sort((a, b) {
        final byTime = a.$2.runtimeSec.compareTo(b.$2.runtimeSec);
        return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
      });
    return [for (final (_, wp) in indexed) wp];
  }

  PlannedGas? gasById(String gasId) =>
      gases.where((g) => g.id == gasId).firstOrNull;

  bool get isCcr => diveType == 'ccr';

  /// The loop gas of a CCR dive; `null` on other dives.
  PlannedGas? diluentGas() =>
      isCcr ? gases.where((g) => g.diluent).firstOrNull : null;

  /// Breathing this gas means breathing the loop.
  bool onLoop(PlannedGas gas) => isCcr && gas.diluent;

  /// The setpoint in force at [depthM] after [current] (`null` at the
  /// start): high once deeper than the high depth, low once shallower than
  /// the low depth, otherwise as it was.
  double nextSetpoint(double? current, double depthM) {
    if (depthM > ccrHighSetpointDepthM) {
      return ccrHighSetpoint;
    }
    if (depthM < ccrLowSetpointDepthM || current == null) {
      return ccrLowSetpoint;
    }
    return current;
  }

  /// The left and the right tank of a sidemount dive; `null` on other
  /// dives or while either side is missing.
  (PlannedGas, PlannedGas)? sidemountTanks() {
    if (diveType != 'sidemount') {
      return null;
    }
    final left = gases.where((g) => g.side == 'left').firstOrNull;
    final right = gases.where((g) => g.side == 'right').firstOrNull;
    return left != null && right != null ? (left, right) : null;
  }

  /// Why this sidemount dive cannot be built yet; `null` when it can.
  String? sidemountError() =>
      diveType == 'sidemount' && sidemountTanks() == null
      ? 'Sidemount needs two tanks of the same gas: set one tank\'s side to '
            'Left and another\'s to Right'
      : null;

  /// The gas a tank stands for: a sidemount dive's right tank is its left
  /// tank's gas.
  PlannedGas breathedGas(PlannedGas gas) {
    final pair = sidemountTanks();
    return pair != null && identical(gas, pair.$2) ? pair.$1 : gas;
  }

  String breathedGasId(String gasId) {
    final gas = gasById(gasId);
    return gas == null ? gasId : breathedGas(gas).id;
  }

  /// The gases the diver can switch between: all but a sidemount dive's
  /// right tank.
  List<PlannedGas> breathedGases() {
    final pair = sidemountTanks();
    return [
      for (final g in gases)
        if (pair == null || !identical(g, pair.$2)) g,
    ];
  }

  /// The tank or tanks a gas is breathed from: both sidemount tanks, left
  /// first, for either of them.
  List<String> tankRefsFor(PlannedGas gas) {
    final pair = sidemountTanks();
    return pair != null && (identical(gas, pair.$1) || identical(gas, pair.$2))
        ? [pair.$1.tankRef, pair.$2.tankRef]
        : [gas.tankRef];
  }

  /// The gas row whose own tank this is.
  PlannedGas? gasForTank(String ref) =>
      gases.where((g) => g.tankRef == ref).firstOrNull;

  /// Every tank of the dive: a CCR dive's oxygen cylinder first, then the
  /// gases' tanks in gas order. Gases that share a tank share the first
  /// one's.
  List<TankSpec> tankSpecs() {
    final specs = <TankSpec>[
      if (isCcr)
        TankSpec(
          ref: ccrO2TankRef,
          sizeL: ccrO2TankSizeL,
          startPressureBar: ccrO2StartPressureBar,
          o2Percent: 100.0,
          hePercent: 0.0,
          role: 'oxygen',
        ),
    ];
    final seen = {for (final s in specs) s.ref};
    for (final gas in gases) {
      if (!seen.add(gas.tankRef)) {
        continue;
      }
      specs.add(
        TankSpec(
          ref: gas.tankRef,
          sizeL: gas.tankSizeL,
          startPressureBar: gas.startPressureBar,
          o2Percent: gas.o2Percent,
          hePercent: gas.hePercent,
          role: onLoop(gas) ? 'diluent' : 'oc',
          gasId: breathedGas(gas).id,
        ),
      );
    }
    return specs;
  }

  double sacFor(PlannedGas gas) => gas.sacLpm ?? sacLpm;

  double maxPo2For(String phase) =>
      phase == 'ascent' ? maxPo2Deco : maxPo2Bottom;

  /// The MOD at the PO2 limit of the phase, rounded down to 0.1 m so that
  /// a waypoint placed at it never passes the limit. `null` for a CCR
  /// diluent: the loop holds its setpoint.
  double? gasModM(PlannedGas gas, String phase) => onLoop(gas)
      ? null
      : (modMeters(gas.fO2, maxPo2: maxPo2For(phase)) * 10).floorToDouble() /
            10;

  /// The MOD the gas table shows: at the deco PO2 for an ascent gas, the
  /// bottom PO2 otherwise.
  double gasDisplayModM(PlannedGas gas) =>
      gasModM(gas, gas.usePhase == 'ascent' ? 'ascent' : 'descent') ?? gas.modM;

  /// Inside the gas's own depth range and phase, and within its MOD.
  bool gasUsableAt(PlannedGas gas, double depthM, String phase) {
    if ((gas.usePhase != 'any' && gas.usePhase != phase) ||
        !gas.coversDepth(depthM)) {
      return false;
    }
    final mod = gasModM(gas, phase);
    return mod == null || depthM <= mod;
  }

  /// The deep end of where the gas may be picked by itself: its range,
  /// not past its MOD for the phase.
  double gasDeepestUseM(PlannedGas gas, String phase) {
    final high = gas.useMaxDepthM ?? double.infinity;
    final mod = gasModM(gas, phase);
    return mod == null ? high : pyMin(high, mod);
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'gf_low': gfLow,
    'gf_high': gfHigh,
    'default_descent_rate': defaultDescentRate,
    'default_ascent_rate': defaultAscentRate,
    'water_temp_c': waterTempC,
    'sac_lpm': sacLpm,
    'max_po2_bottom': maxPo2Bottom,
    'max_po2_deco': maxPo2Deco,
    'max_depth_m': maxDepthM,
    'planned_runtime_sec': plannedRuntimeSec,
    'dive_type': diveType,
    'ccr_low_setpoint': ccrLowSetpoint,
    'ccr_high_setpoint': ccrHighSetpoint,
    'ccr_high_setpoint_depth_m': ccrHighSetpointDepthM,
    'ccr_low_setpoint_depth_m': ccrLowSetpointDepthM,
    'ccr_o2_tank_size_l': ccrO2TankSizeL,
    'ccr_o2_start_pressure_bar': ccrO2StartPressureBar,
    'sidemount_switch_bar': sidemountSwitchBar,
    'start_time': startTime == null ? null : formatNaive(startTime!),
    'computer': computer,
    'computer_serial': computerSerial,
    'gases': [for (final gas in gases) gas.toJson()],
    'waypoints': [for (final wp in waypoints) wp.toJson()],
  };
}
