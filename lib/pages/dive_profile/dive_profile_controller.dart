/// The Dive Profile Builder's state (Python
/// `backends/dive_profile_backend.py`): the dive settings (kept in the
/// settings under the Python app's names), the gases and waypoints, the
/// simulated profile with its warnings, waypoints placed and moved on the
/// chart, End dive, the hover readout, and the log opened and saved as
/// UDDF, Garmin FIT or Subsurface XML with the plan in it.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/core/plan/dive_computers.dart';
import 'package:uwmedia_app/core/plan/dive_plan.dart';
import 'package:uwmedia_app/core/plan/dive_plan_engine.dart';
import 'package:uwmedia_app/core/plan/dive_plan_import.dart';
import 'package:uwmedia_app/core/plan/fit_writer.dart';
import 'package:uwmedia_app/core/plan/log_writers.dart';
import 'package:uwmedia_app/core/plan/plan_embed.dart';
import 'package:uwmedia_app/core/plan/profile_chart.dart';
import 'package:uwmedia_app/core/units/units.dart' as u;
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';

const diveTypeLabels = {
  'oc': 'Open circuit',
  'sidemount': 'Sidemount',
  'ccr': 'CCR',
};
const gasSideLabels = {'': 'Stage', 'left': 'Left', 'right': 'Right'};
const gasPhaseLabels = {
  'any': 'Any',
  'descent': 'Descent/bottom',
  'ascent': 'Ascent/deco',
};
const _gasPhaseArrows = {'any': '', 'descent': ' ↓', 'ascent': ' ↑'};
const diveGasTypes = ['Air', 'Nitrox', 'Trimix'];
const autoGasLabel = 'Auto';

/// The formats a log is saved as: dialog label, extension.
const logFormats = {
  'UDDF (*.uddf)': '.uddf',
  'Garmin FIT (*.fit)': '.fit',
  'Subsurface XML (*.ssrf)': '.ssrf',
};
const logFormatField = 'dive_profile_log_format';
const logDirField = 'dive_profile_log_dir';
const gfLowField = 'dive_profile_gf_low';
const gfHighField = 'dive_profile_gf_high';
const _defaultTankVolumeText = '11.1';
const _defaultStartPressure = 207.0;
const _startTimeFormats = ['%Y-%m-%d %H:%M', '%Y-%m-%d %H:%M:%S'];

/// Click-to-place snapping, and how close a press must land to grab a
/// waypoint.
const snapTimeSec = 60;
const snapDepthM = 1.0;
const waypointHitRadiusPx = 9.0;

/// A click in the last tenth of the time axis grows the planned runtime
/// by a quarter (rounded up to five minutes).
const runtimeGrowThreshold = 0.9;
const runtimeGrowFactor = 1.25;

/// The chart's own size: clicks and drags are in its pixels.
const canvasWidth = 700;
const canvasHeight = 420;

const _normal = '#E0E0E0';
const _good = '#22C55E';
const _bad = '#EF4444';

/// One line of the hover readout.
typedef CursorLine = ({String label, String value, String color});

bool _isNumber(Object? v) => v is num;
bool _isPositive(Object? v) => v is num && v > 0;
bool _isPo2(Object? v) => v is num && v >= 0.5 && v <= 2.0;
bool _isSetpoint(Object? v) => v is num && v >= 0.4 && v <= 1.6;
bool _isNonNegative(Object? v) => v is num && v >= 0;
final _digits = RegExp(r'^\d+$');

/// The plan's settings kept in the settings: the field's key and the check
/// a stored value has to pass to be taken.
final Map<String, (String, bool Function(Object?))> persistedPlanFields = {
  'name': ('dive_profile_name', (v) => v is String && v.trim().isNotEmpty),
  'default_descent_rate': ('dive_profile_descent_rate', _isPositive),
  'default_ascent_rate': ('dive_profile_ascent_rate', _isPositive),
  'water_temp_c': ('dive_profile_water_temp', _isNumber),
  'sac_lpm': ('dive_profile_sac_lpm', _isPositive),
  'max_po2_bottom': ('dive_profile_max_po2_bottom', _isPo2),
  'max_po2_deco': ('dive_profile_max_po2_deco', _isPo2),
  'max_depth_m': ('dive_profile_max_depth', _isPositive),
  'planned_runtime_sec': ('dive_profile_planned_runtime_sec', _isPositive),
  'dive_type': (
    'dive_profile_dive_type',
    (v) => v is String && diveTypeLabels.containsKey(v),
  ),
  'ccr_low_setpoint': ('dive_profile_ccr_low_setpoint', _isSetpoint),
  'ccr_high_setpoint': ('dive_profile_ccr_high_setpoint', _isSetpoint),
  'ccr_high_setpoint_depth_m': (
    'dive_profile_ccr_switch_depth',
    _isNonNegative,
  ),
  'ccr_low_setpoint_depth_m': (
    'dive_profile_ccr_low_switch_depth',
    _isNonNegative,
  ),
  'ccr_o2_tank_size_l': ('dive_profile_ccr_o2_tank_size', _isPositive),
  'ccr_o2_start_pressure_bar': (
    'dive_profile_ccr_o2_start_pressure',
    _isPositive,
  ),
  'sidemount_switch_bar': ('dive_profile_sidemount_switch_bar', _isPositive),
  'computer': (
    'dive_profile_computer',
    (v) => v is String && diveComputers.containsKey(computerLabel(v)),
  ),
  'computer_serial': (
    'dive_profile_computer_serial',
    (v) => v is String && _digits.hasMatch(v),
  ),
};

/// `m:ss`.
String formatMmss(num seconds) {
  final s = math.max(0, seconds.truncate());
  return '${s ~/ 60}:${'${s % 60}'.padLeft(2, '0')}';
}

String _g(num v) => pyFormatG(v.toDouble());
String _f0(num v) => pyFormatFixed(v.toDouble(), 0);

/// One decimal at most, no trailing zero (Python `_short`).
String shortNumber(num value) {
  var text = pyFormatFixed(value.toDouble(), 1);
  if (text.contains('.')) {
    text = text
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }
  return text;
}

String _formatMinutes(num seconds) => _g(seconds / 60);

String? gfPairError(double low, double high) {
  if (!(low >= 1 && low <= 100 && high >= 1 && high <= 100)) {
    return 'GF low and high must be between 1 and 100';
  }
  return low > high ? "GF low can't be higher than GF high" : null;
}

String? setpointPairError(double low, double high) {
  if (!(low >= 0.4 && low <= 1.6 && high >= 0.4 && high <= 1.6)) {
    return 'Setpoints must be between 0.4 and 1.6 bar';
  }
  return low > high
      ? "The low setpoint can't be higher than the high one"
      : null;
}

/// `null` for blank (the time of saving); throws for text that is not one
/// of the two formats.
DateTime? parseStartTime(String text) {
  final t = text.trim();
  if (t.isEmpty) {
    return null;
  }
  for (final format in _startTimeFormats) {
    final time = pyStrptime(t, format);
    if (time != null) {
      return time;
    }
  }
  throw const FormatException(
    'Enter the start as YYYY-MM-DD HH:MM, or leave it blank for the time of '
    'saving',
  );
}

/// `mm:ss`, or minutes; throws for anything else.
int parseTimeToSeconds(String text) {
  final t = text.trim();
  if (t.isEmpty) {
    throw const FormatException('Enter a time');
  }
  if (t.contains(':')) {
    final at = t.indexOf(':');
    final minutes = int.tryParse(t.substring(0, at).trim());
    final seconds = int.tryParse(t.substring(at + 1).trim());
    if (minutes == null || seconds == null) {
      throw FormatException('invalid time: $t');
    }
    return minutes * 60 + seconds;
  }
  final minutes = pyFloat(t);
  if (minutes == null) {
    throw FormatException('could not convert string to float: $t');
  }
  return pyRound(minutes * 60);
}

double _number(String text) =>
    pyFloat(text.trim()) ??
    (throw FormatException('could not convert string to float: $text'));

class DiveProfileController extends ChangeNotifier {
  DiveProfileController({
    required this.config,
    required this.home,
    DateTime Function()? now,
    int Function(DateTime localStart)? utcOffsetMinutes,
  }) : _now = now ?? naiveNow,
       _utcOffset = utcOffsetMinutes ?? localUtcOffsetMinutesAt {
    _loadPersistedPlanFields();
    _applyDiveTypeDefaults();
    _loadPersistedGf();
    _syncTextsFromPlan();
    newGas();
    _resimulate();
  }

  final ConfigStore config;
  final String home;
  final DateTime Function() _now;
  // The machine's UTC offset at a dive's local start.
  final int Function(DateTime localStart) _utcOffset;

  DiveProfilePlan plan = DiveProfilePlan(gases: [PlannedGas(id: 'Air')]);
  List<SimulatedSample> samples = [];
  List<String> warnings = [];
  List<(int, List<PlanStop>)> decoSchedules = [];
  double? cursorTime;
  bool dragging = false;

  u.UnitSystem get units => u.normalizeUnits(config.settings()['units']);

  void _remember(String key, Object? value) {
    try {
      config.setField(key, value);
    } on FileSystemException {
      // Only not kept.
    }
  }

  Object? _planValue(String attr) => plan.toJson()[attr];

  void _persist(String attr) =>
      _remember(persistedPlanFields[attr]!.$1, _planValue(attr));

  // One field of the plan by its JSON name (the model's own check
  // applies); a value the model refuses leaves the plan as it is.
  void _setPlanValue(String attr, Object? value) {
    try {
      final json = plan.toJson()..[attr] = value;
      plan = DiveProfilePlan.fromJson(json);
    } on FormatException {
      // Out of the model's range.
    }
  }

  void _loadPersistedPlanFields() {
    final fields = config.fields();
    persistedPlanFields.forEach((attr, entry) {
      final (key, valid) = entry;
      var value = fields[key];
      if (value != null && valid(value)) {
        if (attr == 'computer') {
          value = computerLabel(value as String);
        }
        if (attr == 'planned_runtime_sec') {
          value = (value as num).truncate();
        }
        try {
          _setPlanValue(attr, value);
        } on FormatException {
          // Out of the model's range: not taken.
        }
      }
    });
  }

  void _loadPersistedGf() {
    final fields = config.fields();
    // Python's float(): a number, or text of one.
    double? number(Object? v) => v is num
        ? v.toDouble()
        : v is String
        ? pyFloat(v.trim())
        : null;
    final low = number(fields[gfLowField] ?? plan.gfLow);
    final high = number(fields[gfHighField] ?? plan.gfHigh);
    if (low == null || high == null) {
      return;
    }
    if (gfPairError(low, high) == null) {
      plan
        ..gfLow = low
        ..gfHigh = high;
    }
  }

  // -- texts -------------------------------------------------------------------

  String nameText = '';
  String gfLowText = '';
  String gfHighText = '';
  String gfErrorText = '';
  String descentRateText = '';
  String ascentRateText = '';
  String waterTempText = '';
  String sacText = '';
  String maxDepthText = '';
  String bottomPo2Text = '';
  String decoPo2Text = '';
  String runtimeText = '';
  String ccrLowText = '';
  String ccrHighText = '';
  String ccrErrorText = '';
  String ccrHighDepthText = '';
  String ccrLowDepthText = '';
  String ccrO2SizeText = '';
  String ccrO2StartText = '';
  String sidemountSwitchText = '';
  String serialText = '';
  String startTimeText = '';
  String logErrorText = '';

  void _syncTextsFromPlan() {
    final units = this.units;
    nameText = plan.name;
    gfLowText = _g(plan.gfLow);
    gfHighText = _g(plan.gfHigh);
    gfErrorText = '';
    descentRateText = shortNumber(u.depth(plan.defaultDescentRate, units));
    ascentRateText = shortNumber(u.depth(plan.defaultAscentRate, units));
    waterTempText = shortNumber(u.temperature(plan.waterTempC, units));
    sacText = _g(plan.sacLpm);
    final maxDepth = plan.maxDepthM;
    maxDepthText = maxDepth == null || maxDepth == 0
        ? ''
        : shortNumber(u.depth(maxDepth, units));
    bottomPo2Text = _g(plan.maxPo2Bottom);
    decoPo2Text = _g(plan.maxPo2Deco);
    final runtime = plan.plannedRuntimeSec;
    runtimeText = runtime == null || runtime == 0
        ? ''
        : _formatMinutes(runtime);
    if (plan.ccrLowSetpoint > plan.ccrHighSetpoint) {
      plan.ccrLowSetpoint = plan.ccrHighSetpoint;
    }
    ccrLowText = _g(plan.ccrLowSetpoint);
    ccrHighText = _g(plan.ccrHighSetpoint);
    ccrErrorText = '';
    ccrHighDepthText = _f0(u.depth(plan.ccrHighSetpointDepthM, units));
    ccrLowDepthText = _f0(u.depth(plan.ccrLowSetpointDepthM, units));
    ccrO2SizeText = _g(plan.ccrO2TankSizeL);
    ccrO2StartText = _f0(u.pressure(plan.ccrO2StartPressureBar, units));
    sidemountSwitchText = _f0(u.pressure(plan.sidemountSwitchBar, units));
    serialText = plan.computerSerial;
    final start = plan.startTime;
    startTimeText = start == null
        ? ''
        : pyStrftime(start, _startTimeFormats[0]);
    logErrorText = '';
  }

  // -- dive settings -------------------------------------------------------------

  void setName(String value) {
    nameText = value;
    if (value.trim().isNotEmpty) {
      plan.name = value;
      _persist('name');
    }
    notifyListeners();
  }

  void setGfLow(String value) {
    gfLowText = value;
    _applyGf();
  }

  void setGfHigh(String value) {
    gfHighText = value;
    _applyGf();
  }

  void _applyGf() {
    final low = pyFloat(gfLowText.trim());
    final high = pyFloat(gfHighText.trim());
    final error = low == null || high == null
        ? 'Enter GF low and high as numbers, e.g. 30 and 70'
        : gfPairError(low, high);
    gfErrorText = error ?? '';
    if (error != null || (low == plan.gfLow && high == plan.gfHigh)) {
      notifyListeners();
      return;
    }
    plan
      ..gfLow = low!
      ..gfHigh = high!;
    _remember(gfLowField, low);
    _remember(gfHighField, high);
    _resimulate();
  }

  void _rate(String value, bool descent) {
    final rate = pyFloat(value.trim());
    if (rate != null) {
      final metres = u.depthToMetres(rate, units);
      if (metres > 0) {
        if (descent) {
          plan.defaultDescentRate = metres;
          _persist('default_descent_rate');
        } else {
          plan.defaultAscentRate = metres;
          _persist('default_ascent_rate');
        }
      }
    }
    _resimulate();
  }

  void setDescentRate(String value) {
    descentRateText = value;
    _rate(value, true);
  }

  void setAscentRate(String value) {
    ascentRateText = value;
    _rate(value, false);
  }

  void setWaterTemp(String value) {
    waterTempText = value;
    final t = pyFloat(value.trim());
    if (t != null) {
      plan.waterTempC = u.temperatureToCelsius(t, units);
      _persist('water_temp_c');
    }
    notifyListeners();
  }

  void setSac(String value) {
    sacText = value;
    final sac = pyFloat(value.trim());
    if (sac != null && sac > 0) {
      plan.sacLpm = sac;
      _persist('sac_lpm');
    }
    _resimulate();
  }

  void _setPo2(String attr, String value) {
    final po2 = pyFloat(value.trim());
    if (po2 != null && po2 >= 0.5 && po2 <= 2.0) {
      if (attr == 'max_po2_bottom') {
        plan.maxPo2Bottom = po2;
      } else {
        plan.maxPo2Deco = po2;
      }
      _persist(attr);
    }
    _resimulate();
  }

  void setBottomPo2(String value) {
    bottomPo2Text = value;
    _setPo2('max_po2_bottom', value);
  }

  void setDecoPo2(String value) {
    decoPo2Text = value;
    _setPo2('max_po2_deco', value);
  }

  String get diveTypeLabel => diveTypeLabels[plan.diveType]!;
  bool get isCcr => plan.diveType == 'ccr';
  bool get isSidemount => plan.diveType == 'sidemount';

  void selectDiveType(String label) {
    final type = diveTypeLabels.entries
        .firstWhere(
          (e) => e.value == label,
          orElse: () => diveTypeLabels.entries.first,
        )
        .key;
    if (type == plan.diveType) {
      return;
    }
    plan.diveType = type;
    _persist('dive_type');
    _applyDiveTypeDefaults();
    final editing = _editingGasIndex;
    if (editing >= 0) {
      _loadGasFields(plan.gases[editing]);
    } else {
      newGas();
    }
    _updateCursorInfo();
    _resimulate();
  }

  // A CCR dive needs a diluent, a sidemount dive a left tank (the first
  // bottom gas); the gas editor then offers its right-hand twin.
  void _applyDiveTypeDefaults() {
    final gases = plan.gases;
    if (plan.isCcr && gases.isNotEmpty && plan.diluentGas() == null) {
      gases.first.diluent = true;
    }
    if (plan.diveType == 'sidemount' &&
        gases.isNotEmpty &&
        !gases.any((g) => (g.side ?? '').isNotEmpty)) {
      (gases.where((g) => g.usePhase != 'ascent').firstOrNull ?? gases.first)
              .side =
          'left';
    }
  }

  // A typed number applied to the plan when [valid] (typed in the unit
  // system in force; the plan keeps SI); the text is kept either way.
  void _setPlanNumber(String attr, String value, bool Function(double) valid) {
    var number = pyFloat(value.trim());
    if (number == null || !valid(number)) {
      return;
    }
    if (attr.endsWith('_m')) {
      number = u.depthToMetres(number, units);
    } else if (attr.endsWith('_bar')) {
      number = u.pressureToBar(number, units);
    }
    _setPlanValue(attr, number);
    _persist(attr);
  }

  void setCcrLow(String value) {
    ccrLowText = value;
    _applySetpoints();
  }

  void setCcrHigh(String value) {
    ccrHighText = value;
    _applySetpoints();
  }

  void _applySetpoints() {
    final low = pyFloat(ccrLowText.trim());
    final high = pyFloat(ccrHighText.trim());
    final error = low == null || high == null
        ? 'Enter the setpoints as numbers, e.g. 0.7 and 1.3'
        : setpointPairError(low, high);
    ccrErrorText = error ?? '';
    if (error != null) {
      notifyListeners();
      return;
    }
    plan
      ..ccrLowSetpoint = low!
      ..ccrHighSetpoint = high!;
    _persist('ccr_low_setpoint');
    _persist('ccr_high_setpoint');
    _resimulate();
  }

  void setCcrHighDepth(String value) {
    ccrHighDepthText = value;
    _setPlanNumber('ccr_high_setpoint_depth_m', value, (v) => v >= 0);
    _resimulate();
  }

  void setCcrLowDepth(String value) {
    ccrLowDepthText = value;
    _setPlanNumber('ccr_low_setpoint_depth_m', value, (v) => v >= 0);
    _resimulate();
  }

  void setCcrO2Size(String value) {
    ccrO2SizeText = value;
    _setPlanNumber('ccr_o2_tank_size_l', value, (v) => v > 0);
    _resimulate();
  }

  void setCcrO2Start(String value) {
    ccrO2StartText = value;
    _setPlanNumber('ccr_o2_start_pressure_bar', value, (v) => v > 0);
    _resimulate();
  }

  void setSidemountSwitch(String value) {
    sidemountSwitchText = value;
    _setPlanNumber('sidemount_switch_bar', value, (v) => v > 0);
    _resimulate();
  }

  // -- log details -----------------------------------------------------------

  List<String> get computerList => diveComputers.keys.toList();

  void selectComputer(String label) {
    if (diveComputers.containsKey(label)) {
      plan.computer = label;
      _persist('computer');
      notifyListeners();
    }
  }

  void setSerial(String value) {
    serialText = value;
    if (_digits.hasMatch(value.trim())) {
      plan.computerSerial = value.trim();
      _persist('computer_serial');
    }
    _checkLogDetails();
  }

  void setStartTime(String value) {
    startTimeText = value;
    try {
      plan.startTime = parseStartTime(value);
    } on FormatException {
      // The text stays; the plan keeps its time.
    }
    _checkLogDetails();
  }

  void _checkLogDetails() {
    final errors = <String>[];
    try {
      parseStartTime(startTimeText);
    } on FormatException catch (e) {
      errors.add(e.message);
    }
    if (!_digits.hasMatch(serialText.trim())) {
      errors.add('The serial number must be digits only');
    }
    logErrorText = errors.join(' · ');
    notifyListeners();
  }

  // -- the chart's scale -----------------------------------------------------

  bool get scaleDefined =>
      (plan.maxDepthM ?? 0) > 0 && (plan.plannedRuntimeSec ?? 0) > 0;

  void setMaxDepth(String value) {
    maxDepthText = value;
    final d = pyFloat(value.trim());
    if (d != null) {
      final metres = u.depthToMetres(d, units);
      if (metres > 0) {
        plan.maxDepthM = metres;
        _persist('max_depth_m');
      }
    }
    _resimulate();
  }

  void setRuntime(String value) {
    runtimeText = value;
    try {
      final seconds = parseTimeToSeconds(value);
      if (seconds > 0) {
        plan.plannedRuntimeSec = seconds;
        _persist('planned_runtime_sec');
      }
    } on FormatException {
      // The text stays.
    }
    _resimulate();
  }

  /// The scale dialog's OK: an error for the dialog, or '' when set.
  String defineScale(String maxDepth, String runtime) {
    final units = this.units;
    final d = pyFloat(maxDepth.trim());
    if (d == null) {
      return 'Enter the max depth in '
          '${units == u.UnitSystem.imperial ? 'feet' : 'metres'}';
    }
    final depth = u.depthToMetres(d, units);
    if (depth <= 0) {
      return 'Max depth must be greater than 0';
    }
    final int seconds;
    try {
      seconds = parseTimeToSeconds(runtime);
    } on FormatException {
      return 'Enter the planned runtime in minutes (or mm:ss)';
    }
    if (seconds <= 0) {
      return 'Planned runtime must be greater than 0';
    }
    plan
      ..maxDepthM = depth
      ..plannedRuntimeSec = seconds;
    _persist('max_depth_m');
    _persist('planned_runtime_sec');
    maxDepthText = shortNumber(u.depth(depth, units));
    runtimeText = _formatMinutes(seconds);
    _resimulate();
    return '';
  }

  void _growRuntimeFor(int runtimeSec) {
    final planned = plan.plannedRuntimeSec;
    if (planned == null ||
        planned == 0 ||
        runtimeSec < planned * runtimeGrowThreshold) {
      return;
    }
    final grown =
        (math.max(planned, runtimeSec) * runtimeGrowFactor / 300.0).ceil() *
        300;
    plan.plannedRuntimeSec = grown;
    _persist('planned_runtime_sec');
    runtimeText = _formatMinutes(grown);
  }

  // -- gases -----------------------------------------------------------------------

  List<String> get gasTableHeaders => [
    'Name',
    'Type',
    'O2%',
    'He%',
    'Tank L/${u.pressureLabel(units, upper: false)}',
    'MOD (${u.depthLabel(units)})',
    'Use',
  ];

  static String _gasUse(PlannedGas gas) {
    if (!gas.hasDepthRange && gas.usePhase == 'any') {
      return 'any';
    }
    final low = gas.useMinDepthM == null ? '0' : _g(gas.useMinDepthM!);
    final high = gas.useMaxDepthM == null ? '∞' : _g(gas.useMaxDepthM!);
    return '$low-${high}m${_gasPhaseArrows[gas.usePhase]}';
  }

  List<List<String>> get gasTableRows {
    final units = this.units;
    return [
      for (final g in plan.gases)
        [
          g.id,
          plan.isCcr
              ? (g.diluent ? 'DIL' : 'BAILOUT')
              : g.gasType.toUpperCase(),
          _f0(g.o2Percent),
          _f0(g.hePercent),
          '${g.tankRef}'
              '${plan.diveType == 'sidemount' && (g.side ?? '').isNotEmpty ? ' ${gasSideLabels[g.side]}' : ''}'
              ' ${_g(g.tankSizeL)}L/${_f0(u.pressure(g.startPressureBar, units))}',
          _f0(u.depth(plan.gasDisplayModM(g), units)),
          _gasUse(g),
        ],
    ];
  }

  List<String> get gasColors => [
    for (final g in plan.gases) gasColor(plan, g.id),
  ];

  // The gas editor's fields.
  String gasNameText = '';
  String gasType = 'Air';
  String gasO2Text = '21';
  String gasHeText = '0';
  bool gasDiluent = false;
  String gasSide = '';
  String gasTankText = 'T1';
  String gasVolumeText = _defaultTankVolumeText;
  String gasStartPressureText = '207';
  String gasMinDepthText = '';
  String gasMaxDepthText = '';
  String gasPhase = 'any';
  String _gasColor = '';
  String gasStatusText = '';
  String? _editingGasId;

  String get gasColorText =>
      _gasColor.isNotEmpty ? _gasColor : nextFreeGasColor(plan);

  void setGasColorChoice(String color) {
    _gasColor = color;
    notifyListeners();
  }

  void editGasField(void Function() change) {
    change();
    notifyListeners();
  }

  int get _editingGasIndex => _editingGasId == null
      ? -1
      : plan.gases.indexWhere((g) => g.id == _editingGasId);

  int get selectedGasRow => _editingGasIndex;

  /// Recolours a gas from its table swatch.
  void setGasColor(int row, String color) {
    if (row >= 0 && row < plan.gases.length) {
      plan.gases[row].color = color;
      _updateCursorInfo();
      notifyListeners();
    }
  }

  void selectGasRow(int row) {
    if (row < 0 || row >= plan.gases.length) {
      return;
    }
    _editingGasId = plan.gases[row].id;
    _loadGasFields(plan.gases[row]);
    gasStatusText = '';
    notifyListeners();
  }

  void _loadGasFields(PlannedGas g) {
    final units = this.units;
    gasNameText = g.id;
    gasType = diveGasTypes.firstWhere(
      (t) => t.toLowerCase() == g.gasType,
      orElse: () => 'Air',
    );
    gasO2Text = _g(g.o2Percent);
    gasHeText = _g(g.hePercent);
    gasDiluent = g.diluent;
    gasSide = g.side ?? '';
    gasTankText = g.tankRef;
    gasVolumeText = _g(g.tankSizeL);
    gasStartPressureText = _f0(u.pressure(g.startPressureBar, units));
    gasMinDepthText = g.useMinDepthM == null
        ? ''
        : _f0(u.depth(g.useMinDepthM!, units));
    gasMaxDepthText = g.useMaxDepthM == null
        ? ''
        : _f0(u.depth(g.useMaxDepthM!, units));
    gasPhase = g.usePhase;
    _gasColor = gasColor(plan, g.id);
    notifyListeners();
  }

  // The first of T1, T2 … no gas uses yet.
  String _nextFreeTank() {
    final used = {for (final g in plan.gases) g.tankRef};
    var n = 1;
    while (used.contains('T$n')) {
      n++;
    }
    return 'T$n';
  }

  /// Deselects the table: the next Add makes a new gas.
  void newGas() {
    _editingGasId = null;
    gasNameText = '';
    gasType = 'Air';
    gasO2Text = '21';
    gasHeText = '0';
    gasDiluent = plan.isCcr && plan.diluentGas() == null;
    gasSide = '';
    if (plan.diveType == 'sidemount') {
      final left = plan.gases.where((g) => g.side == 'left').firstOrNull;
      final right = plan.gases.where((g) => g.side == 'right').firstOrNull;
      if (left == null) {
        gasSide = 'left';
      } else if (right == null) {
        gasSide = 'right';
        gasNameText = '${left.id} R';
        gasType = diveGasTypes.firstWhere(
          (t) => t.toLowerCase() == left.gasType,
          orElse: () => 'Air',
        );
        gasO2Text = _g(left.o2Percent);
        gasHeText = _g(left.hePercent);
      }
    }
    gasTankText = _nextFreeTank();
    gasVolumeText = _defaultTankVolumeText;
    gasStartPressureText = _f0(u.pressure(_defaultStartPressure, units));
    gasMinDepthText = '';
    gasMaxDepthText = '';
    gasPhase = 'any';
    _gasColor = '';
    gasStatusText = '';
    notifyListeners();
  }

  PlannedGas? _sidemountTwin(PlannedGas gas) {
    if (plan.diveType != 'sidemount' || (gas.side ?? '').isEmpty) {
      return null;
    }
    final other = gas.side == 'left' ? 'right' : 'left';
    return plan.gases
        .where((g) => g.side == other && g.id != gas.id)
        .firstOrNull;
  }

  String? _sidemountSideError(PlannedGas gas, int editing) {
    final side = gasSideLabels[gas.side]!.toLowerCase();
    final taken = [
      for (final (i, g) in plan.gases.indexed)
        if (g.side == gas.side && i != editing) g,
    ].firstOrNull;
    if (taken != null) {
      return '${taken.id} is already the $side tank';
    }
    final twin = _sidemountTwin(gas);
    if (twin == null) {
      return null;
    }
    if (twin.tankRef == gas.tankRef) {
      return 'the left and right tanks need tanks of their own '
          '(${twin.id} is in ${twin.tankRef})';
    }
    if (editing < 0 &&
        (twin.o2Percent != gas.o2Percent || twin.hePercent != gas.hePercent)) {
      return 'the left and right tanks must hold the same gas - ${twin.id} '
          'is ${_g(twin.o2Percent)}/${_g(twin.hePercent)}';
    }
    return null;
  }

  /// Add / Update: updates the selected gas, or adds a new one.
  void addGas() {
    final units = this.units;
    final editing = _editingGasIndex;
    final action = editing >= 0 ? 'update' : 'add';
    final name = gasNameText.trim().isNotEmpty
        ? gasNameText.trim()
        : editing >= 0
        ? plan.gases[editing].id
        : 'Gas ${plan.gases.length + 1}';
    final clash = plan.gases.indexWhere((g) => g.id == name);
    if (clash >= 0 && clash != editing) {
      gasStatusText =
          "Could not $action gas: another gas is already named '$name'";
      notifyListeners();
      return;
    }
    final PlannedGas gas;
    try {
      double? optionalDepth(String text) =>
          text.trim().isEmpty ? null : u.depthToMetres(_number(text), units);
      final fields = <String, dynamic>{
        'id': name,
        'gas_type': gasType.toLowerCase(),
        'o2_percent': _number(gasO2Text),
        'he_percent': gasHeText.trim().isEmpty ? 0.0 : _number(gasHeText),
        'diluent': gasDiluent,
        'side': gasSide.isEmpty ? null : gasSide,
        'tank_ref': gasTankText.trim().isEmpty
            ? _nextFreeTank()
            : gasTankText.trim(),
        'tank_size_l': _number(gasVolumeText),
        'start_pressure_bar': u.pressureToBar(
          _number(gasStartPressureText),
          units,
        ),
        'use_min_depth_m': optionalDepth(gasMinDepthText),
        'use_max_depth_m': optionalDepth(gasMaxDepthText),
        'use_phase': gasPhase,
        'color': _gasColor.isNotEmpty ? _gasColor : nextFreeGasColor(plan),
      };
      // Update keeps what the editor does not show (a gas's own SAC).
      final base = editing >= 0
          ? plan.gases[editing].toJson()
          : <String, dynamic>{};
      gas = PlannedGas.fromJson({...base, ...fields});
      final low = gas.useMinDepthM;
      final high = gas.useMaxDepthM;
      if (low != null && high != null && low > high) {
        throw const FormatException(
          "the 'from' depth must be shallower than the 'to' depth",
        );
      }
    } on FormatException catch (e) {
      gasStatusText = 'Could not $action gas: ${e.message}';
      notifyListeners();
      return;
    }
    if (plan.diveType == 'sidemount' && (gas.side ?? '').isNotEmpty) {
      final error = _sidemountSideError(gas, editing);
      if (error != null) {
        gasStatusText = 'Could not $action gas: $error';
        notifyListeners();
        return;
      }
    }
    if (gas.diluent) {
      // One loop per dive.
      for (final other in plan.gases) {
        other.diluent = false;
      }
    }
    if (editing >= 0) {
      final oldId = plan.gases[editing].id;
      plan.gases[editing] = gas;
      final twin = _sidemountTwin(gas);
      if (twin != null) {
        // Both sides hold the same gas.
        twin
          ..gasType = gas.gasType
          ..o2Percent = gas.o2Percent
          ..hePercent = gas.hePercent;
      }
      if (oldId != gas.id) {
        for (final wp in plan.waypoints) {
          if (wp.gasId == oldId) {
            wp.gasId = gas.id;
          }
        }
      }
      _editingGasId = gas.id;
      _loadGasFields(gas);
    } else {
      plan.gases.add(gas);
      newGas();
    }
    gasStatusText = '';
    final phase = gas.usePhase == 'ascent' ? 'ascent' : 'descent';
    final mod = plan.gasModM(gas, phase);
    final maxUse = gas.useMaxDepthM;
    if (mod != null && maxUse != null && maxUse > mod) {
      gasStatusText =
          "Note: $name's range goes to ${_g(maxUse)}m but its MOD at PO2 "
          '${_g(plan.maxPo2For(phase))} is ${_g(mod)}m - it will only be '
          'used from ${_g(mod)}m';
    }
    _resimulate();
  }

  void removeGasAt(int row) {
    if (row < 0 || row >= plan.gases.length) {
      return;
    }
    final name = plan.gases[row].id;
    plan.gases.removeWhere((g) => g.id == name);
    for (final wp in plan.waypoints) {
      if (wp.gasId == name) {
        wp.gasAuto = true;
      }
    }
    if (_editingGasId == name) {
      newGas();
    }
    _resimulate();
  }

  // -- waypoints ---------------------------------------------------------------------

  List<String> get waypointHeaders => [
    'Time',
    'Depth (${u.depthLabel(units)})',
    'Gas',
    'Rate (${u.depthRateLabel(units)})',
  ];

  List<List<String>> get waypointRows {
    final units = this.units;
    return [
      for (final wp in plan.sortedWaypoints())
        [
          formatMmss(wp.runtimeSec),
          pyFormatFixed(u.depth(wp.depthM, units), 1),
          wp.gasAuto ? '${wp.gasId} (auto)' : wp.gasId,
          wp.rateMPerMin == null || wp.rateMPerMin == 0
              ? 'default'
              : _f0(u.depth(wp.rateMPerMin!, units)),
        ],
    ];
  }

  List<String> get waypointGasColors => [
    for (final wp in plan.sortedWaypoints()) gasColor(plan, wp.gasId),
  ];

  List<String> get wpGasChoices => [
    autoGasLabel,
    for (final g in plan.breathedGases()) g.id,
  ];

  String wpTimeText = '';
  String wpDepthText = '';
  String wpGasText = '';
  String wpRateText = '';
  String wpStatusText = '';
  String endDiveStatusText = '';
  int? _editingRuntime;

  /// The selected row of the waypoint table, by its waypoint's time;
  /// `null` when none is (any change to the list clears it).
  int? get selectedWaypointRow {
    final runtime = _editingRuntime;
    if (runtime == null) {
      return null;
    }
    final row = plan.sortedWaypoints().indexWhere(
      (w) => w.runtimeSec == runtime,
    );
    return row < 0 ? null : row;
  }

  void _clearWaypointInputs() {
    _editingRuntime = null;
    endDiveStatusText = '';
    wpTimeText = '';
    wpDepthText = '';
    wpRateText = '';
  }

  void selectWaypointRow(int row) {
    final wps = plan.sortedWaypoints();
    if (row < 0 || row >= wps.length) {
      return;
    }
    final wp = wps[row];
    _editingRuntime = wp.runtimeSec;
    wpTimeText = formatMmss(wp.runtimeSec);
    // In the unit system in force, as Add / Update reads them (Python fills
    // in metres, so Update in feet moved the waypoint; spec §10.41).
    final units = this.units;
    wpDepthText = shortNumber(u.depth(wp.depthM, units));
    wpGasText = wp.gasAuto ? autoGasLabel : wp.gasId;
    wpRateText = wp.rateMPerMin == null || wp.rateMPerMin == 0
        ? ''
        : shortNumber(u.depth(wp.rateMPerMin!, units));
    notifyListeners();
  }

  void addOrUpdateWaypoint() {
    final units = this.units;
    final PlannedWaypoint wp;
    try {
      final runtime = parseTimeToSeconds(wpTimeText);
      final depth = u.depthToMetres(_number(wpDepthText), units);
      if (plan.gases.isEmpty) {
        throw const FormatException('Define a gas first');
      }
      final auto = wpGasText.isEmpty || wpGasText == autoGasLabel;
      final rate = wpRateText.trim().isEmpty
          ? null
          : u.depthToMetres(_number(wpRateText), units);
      wp = PlannedWaypoint.fromJson({
        'runtime_sec': runtime,
        'depth_m': depth,
        'gas_id': auto ? plan.breathedGases().first.id : wpGasText,
        'rate_m_per_min': rate,
        'gas_auto': auto,
      });
    } on FormatException catch (e) {
      wpStatusText = 'Could not save waypoint: ${e.message}';
      notifyListeners();
      return;
    }
    final editing = _editingRuntime;
    final edited = plan.waypoints
        .where((w) => w.runtimeSec == editing)
        .firstOrNull;
    if (edited != null) {
      wp.phase = edited.phase;
    }
    plan.waypoints
      ..removeWhere(
        (w) => w.runtimeSec == editing || w.runtimeSec == wp.runtimeSec,
      )
      ..add(wp);
    wpStatusText = '';
    _clearWaypointInputs();
    _resimulate();
  }

  void removeWaypointAt(int row) {
    final wps = plan.sortedWaypoints();
    if (row < 0 || row >= wps.length) {
      return;
    }
    final runtime = wps[row].runtimeSec;
    plan.waypoints.removeWhere((w) => w.runtimeSec == runtime);
    _clearWaypointInputs();
    _resimulate();
  }

  // -- the chart ---------------------------------------------------------------------

  (double, double)? get axes => chartAxes(plan, samples);

  (int, double)? _snappedPoint(double x, double y) {
    final a = axes;
    if (a == null) {
      return null;
    }
    final (time, depth) = pointFromXy(x, y, canvasWidth, canvasHeight, a);
    return (
      pyRound(time / snapTimeSec) * snapTimeSec,
      pyRound(depth / snapDepthM) * snapDepthM,
    );
  }

  /// The waypoint (row of [DiveProfilePlan.sortedWaypoints]) under the
  /// chart pixel ([x], [y]); -1 for none.
  int waypointIndexAt(double x, double y) {
    final a = axes;
    if (a == null) {
      return -1;
    }
    var best = -1;
    var bestDist = waypointHitRadiusPx;
    for (final (i, wp) in plan.sortedWaypoints().indexed) {
      final (wx, wy) = xyOf(
        wp.runtimeSec,
        wp.depthM,
        canvasWidth,
        canvasHeight,
        a,
      );
      final dist = math.sqrt(math.pow(wx - x, 2) + math.pow(wy - y, 2));
      if (dist <= bestDist) {
        best = i;
        bestDist = dist;
      }
    }
    return best;
  }

  void addWaypointAt(double x, double y) {
    if (plan.gases.isEmpty) {
      wpStatusText = 'Define a gas first';
      notifyListeners();
      return;
    }
    final point = _snappedPoint(x, y);
    if (point == null) {
      return;
    }
    final (runtime, depth) = point;
    plan.waypoints
      ..removeWhere((w) => w.runtimeSec == runtime)
      ..add(
        PlannedWaypoint(
          runtimeSec: runtime,
          depthM: depth,
          gasId: plan.breathedGases().first.id,
          gasAuto: true,
        ),
      );
    _growRuntimeFor(runtime);
    wpStatusText = '';
    _clearWaypointInputs();
    _resimulate();
  }

  /// A drag: the time kept between the neighbours so the order never
  /// changes; the axes stay until [dropWaypoint].
  void moveWaypoint(int row, double x, double y) {
    final wps = plan.sortedWaypoints();
    if (row < 0 || row >= wps.length) {
      return;
    }
    final point = _snappedPoint(x, y);
    if (point == null) {
      return;
    }
    var (runtime, depth) = point;
    final low = row > 0 ? wps[row - 1].runtimeSec + snapTimeSec : 0;
    final high = row + 1 < wps.length
        ? wps[row + 1].runtimeSec - snapTimeSec
        : null;
    runtime = math.max(low, runtime);
    if (high != null) {
      runtime = math.min(high, runtime);
    }
    final wp = wps[row];
    if (wp.runtimeSec == runtime && wp.depthM == depth) {
      return;
    }
    wp
      ..runtimeSec = runtime
      ..depthM = depth;
    dragging = true;
    notifyListeners();
  }

  void dropWaypoint(int row) {
    dragging = false;
    final wps = plan.sortedWaypoints();
    if (row >= 0 && row < wps.length) {
      _growRuntimeFor(wps[row].runtimeSec);
    }
    _clearWaypointInputs();
    _resimulate();
  }

  /// The ascent from the last waypoint: a 3 m / 3 min safety stop when no
  /// deco is needed, else the deco stops.
  void endDive() {
    final wps = plan.sortedWaypoints();
    String message;
    if (wps.isEmpty) {
      message = 'Place at least one waypoint before ending the dive';
    } else if (wps.last.depthM <= 0) {
      message =
          'The dive already ends at the surface - remove the last '
          'waypoint(s) to re-plan the ascent';
    } else {
      message = 'Nothing to add - the ascent planner returned no waypoints';
      List<PlannedWaypoint> ascent;
      bool deco;
      List<PlanStop> stops;
      try {
        (ascent, deco, stops) = planAscent(plan);
      } on PlanError catch (e) {
        (ascent, deco, stops) = (const [], false, const []);
        message = 'Could not plan the ascent: ${e.message}';
      }
      if (ascent.isNotEmpty) {
        plan.waypoints.addAll(ascent);
        _growRuntimeFor(ascent.last.runtimeSec);
        final surfaced = formatMmss(ascent.last.runtimeSec);
        if (deco) {
          final parts = <String>[];
          var current = wps.last.gasId;
          for (final (depth, seconds, gasId) in stops) {
            final change = gasId != current ? ' $gasId' : '';
            current = gasId;
            parts.add('${_g(depth)}m ${seconds ~/ 60}min$change');
          }
          message =
              'Deco ascent added: ${parts.join(', ')} - surfacing at $surfaced';
        } else {
          message =
              'No deco needed - 3m/3min safety stop added, surfacing at '
              '$surfaced';
        }
        _clearWaypointInputs();
        _resimulate();
      }
    }
    endDiveStatusText = message;
    notifyListeners();
  }

  String statusText = 'Click in the chart to place the first waypoint';
  bool statusIsError = false;
  final Map<int, (bool, List<PlanStop>, int)> _decoPlanCache = {};

  void _resimulate() {
    _decoPlanCache.clear();
    final gasWarnings = applyAutoGases(plan);
    List<SimulatedSample> simulated;
    List<String> simWarnings;
    try {
      (simulated, simWarnings) = simulate(plan, resolutionSec: 10);
    } on PlanError catch (e) {
      (simulated, simWarnings) = (const <SimulatedSample>[], [e.message]);
    }
    samples = simulated;
    warnings = [...gasWarnings, ...simWarnings];
    decoSchedules = simulated.any((s) => s.ceilingM > 0)
        ? decoScheduleTimeline(plan)
        : const [];
    if (warnings.isNotEmpty) {
      statusText = warnings.join(' | ');
      statusIsError = true;
    } else if (samples.isNotEmpty) {
      final maxDepth = samples.map((s) => s.depthM).reduce(math.max);
      statusText =
          '${samples.length} samples · max depth ${_f0(maxDepth)}m · runtime '
          '${formatMmss(samples.last.timeSec)}';
      statusIsError = false;
    } else {
      statusText = 'Click in the chart to place the first waypoint';
      statusIsError = false;
    }
    _updateCursorInfo();
    notifyListeners();
  }

  // -- the hover readout ---------------------------------------------------------

  List<CursorLine> cursorInfo = const [];

  String _phaseAt(num time) {
    final wps = plan.sortedWaypoints();
    final phases = waypointPhases(wps);
    for (final (i, wp) in wps.indexed) {
      if (wp.runtimeSec >= time) {
        return phases[i];
      }
    }
    return 'ascent';
  }

  void _updateCursorInfo() {
    final time = cursorTime;
    final sample = time == null ? null : nearestSample(samples, time);
    if (sample == null) {
      cursorInfo = const [];
      return;
    }
    final units = this.units;
    final gas = plan.gasById(sample.gasId);
    final limit = plan.maxPo2For(_phaseAt(sample.timeSec));
    final onLoop = gas != null && plan.onLoop(gas);
    final over = gas != null && !onLoop && sample.po2 > limit + 0.005;
    final info = <CursorLine>[
      (label: 'Time', value: formatMmss(sample.timeSec), color: _normal),
      (
        label: 'Depth',
        value:
            '${pyFormatFixed(u.depth(sample.depthM, units), 1)} '
            '${u.depthLabel(units)}',
        color: _normal,
      ),
      (label: 'Gas', value: sample.gasId, color: gasColor(plan, sample.gasId)),
      (
        label: 'PO2',
        value: '${pyFormatFixed(sample.po2, 2)} bar (max ${_g(limit)})',
        color: over ? _bad : _normal,
      ),
    ];
    if (plan.isCcr) {
      info.add((
        label: 'Loop',
        value: onLoop && sample.setpoint != null
            ? 'SP ${_g(sample.setpoint!)}'
            : 'Bailout (OC)',
        color: onLoop ? _normal : _bad,
      ));
    }
    if (sample.ceilingM > 0) {
      final (_, stops, tts) = _decoPlanCache.putIfAbsent(sample.timeSec, () {
        try {
          return ascentFromTime(plan, sample.timeSec);
        } on PlanError {
          return (false, const <PlanStop>[], sample.ttsSec);
        }
      });
      info.add((
        label: 'Ceiling',
        value:
            '${pyFormatFixed(sample.ceilingM, 1)} m (GF ${_g(plan.gfHigh)}) · '
            '${pyFormatFixed(sample.ceilingGfLowM, 1)} m (GF ${_g(plan.gfLow)})',
        color: _bad,
      ));
      var current = sample.gasId;
      for (final (i, (depth, seconds, gasId)) in stops.indexed) {
        final change = gasId != current ? '  → $gasId' : '';
        current = gasId;
        info.add((
          label: i == 0 ? 'Deco stops' : '',
          value: '${_g(depth)} m  ${seconds ~/ 60} min$change',
          color: change.isNotEmpty ? gasColor(plan, gasId) : _bad,
        ));
      }
      info.add((label: 'TTS', value: formatMmss(tts), color: _normal));
    } else {
      info.add((
        label: 'NDL',
        value: sample.ndlSec == null
            ? '99+ min'
            : '${sample.ndlSec! ~/ 60} min',
        color: _good,
      ));
    }
    info.add((label: 'CNS', value: '${_f0(sample.cnsPct)} %', color: _normal));
    var refs = gas == null ? [sample.tankRef] : plan.tankRefsFor(gas);
    if (onLoop) {
      refs = [
        for (final t in plan.tankSpecs())
          if (t.role == 'oxygen') t.ref,
        ...refs,
      ];
    }
    final tanks = [
      for (final ref in refs)
        if (sample.tankPressures.containsKey(ref))
          '${ref == sample.tankRef && refs.length > 1 ? '▸' : ''}$ref '
              '${_f0(u.pressure(sample.tankPressures[ref]!, units))}',
    ];
    final unit = u.pressureLabel(units, upper: false);
    info.add((
      label: tanks.length > 1 ? 'Tanks' : 'Tank',
      value: tanks.isEmpty
          ? '${_f0(u.pressure(sample.tankPressureBar, units))} $unit'
          : '${tanks.join('  ')} $unit',
      color: _normal,
    ));
    cursorInfo = info;
  }

  void clearCursor() {
    cursorTime = null;
    _updateCursorInfo();
    notifyListeners();
  }

  /// The mouse over the chart at [x]: the readout of the sample there.
  void scrub(double x) {
    final a = axes;
    if (samples.isEmpty || a == null) {
      return;
    }
    cursorTime = pointFromXy(x, 0, canvasWidth, canvasHeight, a).$1;
    _updateCursorInfo();
    notifyListeners();
  }

  /// The unit system changed: texts and tables follow (the plan is SI).
  void unitsChanged() {
    final before = gasStartPressureText;
    _syncTextsFromPlan();
    // The gas form's untouched default start pressure follows too.
    if (before == '207' ||
        before ==
            _f0(u.pressure(_defaultStartPressure, u.UnitSystem.imperial))) {
      gasStartPressureText = _f0(u.pressure(_defaultStartPressure, units));
    }
    _updateCursorInfo();
    notifyListeners();
  }

  // -- opening and saving logs -----------------------------------------------------

  String get dialogDir => config.dialogDirFor(
    logDirField,
    home: home,
    start: StartFolder.downloads,
  );

  String get savedLogFormat {
    final chosen = config.fields()[logFormatField];
    return logFormats.containsKey(chosen)
        ? chosen as String
        : logFormats.keys.first;
  }

  /// Replaces the plan with the one in the log at [path]: the plan kept in
  /// it when the builder wrote it, else one rebuilt from its gases,
  /// switches and samples. A status line; throws a [FormatException] for a
  /// file it cannot read. A log kept in the app ([kept]) leaves the folder
  /// to pick from as it was.
  String loadLog(String path, {TankConfig? tanks, bool kept = false}) {
    final file = File(path);
    if (!file.existsSync()) {
      throw FormatException('$path does not exist');
    }
    if (!kept) {
      _remember(logDirField, p.dirname(path));
    }
    final bytes = file.readAsBytesSync();
    final name = p.basename(path);
    if (detectLogFormat(
          path,
          bytes.length > logHeadSize
              ? Uint8List.sublistView(bytes, 0, logHeadSize)
              : bytes,
        ) ==
        null) {
      throw FormatException(
        "Unknown log format '${p.extension(path)}' - use .uddf, .fit, .ssrf, "
        'a Shearwater/Subsurface .xml/.csv or a Suunto app .json export',
      );
    }
    final origin = readLogOrigin(name, bytes, inflate: zlib.decode);
    if (origin.plan != null) {
      _applyPlan(origin.plan!);
      return 'Opened $name: plan restored as saved';
    }
    final dives = parseLogFile(path, bytes, tanks: tanks);
    if (dives == null || dives.isEmpty) {
      throw FormatException('No dive found in $name');
    }
    _applyPlan(planFromLog(path, bytes, dives.first, base: plan));
    return origin.createdByUwmedia
        ? 'Opened $name: saved before UWMedia kept the plan, so rebuilt from '
              'its samples - check the waypoints'
        : 'Imported $name: plan rebuilt from its samples - check the gases '
              'and waypoints';
  }

  /// [loadLog] for the Open dialog: the status, or the error to show.
  String? openLog(String path, {TankConfig? tanks, bool kept = false}) {
    try {
      endDiveStatusText = loadLog(path, tanks: tanks, kept: kept);
      notifyListeners();
      return null;
    } on FormatException catch (e) {
      return e.message;
    } on Object catch (e) {
      return '$e';
    }
  }

  void _applyPlan(DiveProfilePlan opened) {
    plan = opened;
    _applyDiveTypeDefaults();
    for (final attr in persistedPlanFields.keys) {
      _persist(attr);
    }
    _remember(gfLowField, plan.gfLow);
    _remember(gfHighField, plan.gfHigh);
    _syncTextsFromPlan();
    _checkLogDetails();
    newGas();
    _clearWaypointInputs();
    _resimulate();
  }

  /// The plan at full resolution as a log at [path], in the format its
  /// extension names. The simulation's warnings; throws a
  /// [FormatException] when it cannot be written.
  List<String> writeLog(String path) {
    final ext = p.extension(path).toLowerCase();
    if (!logFormats.containsValue(ext)) {
      throw FormatException(
        "Unknown log format '${p.extension(path)}' - use .uddf, .fit or .ssrf",
      );
    }
    if (logErrorText.isNotEmpty) {
      throw FormatException(logErrorText);
    }
    if (nameText.trim().isNotEmpty) {
      plan.name = nameText.trim();
    }
    final (full, warns) = simulate(plan, resolutionSec: 1);
    if (full.isEmpty) {
      throw const FormatException('Add at least one waypoint first');
    }
    final now = _now();
    final offset = _utcOffset(plan.startTime ?? now);
    final Uint8List bytes = switch (ext) {
      '.fit' => fitBytes(
        plan,
        full,
        startTime: plan.startTime,
        now: now,
        utcOffsetMinutes: offset,
        deflate: zlib.encode,
      ),
      '.uddf' => utf8.encode(
        uddfText(
          plan,
          full,
          startTime: plan.startTime,
          now: now,
          utcOffsetMinutes: offset,
        ),
      ),
      _ => utf8.encode(
        subsurfaceText(plan, full, startTime: plan.startTime, now: now),
      ),
    };
    File(path).writeAsBytesSync(bytes, flush: true);
    return warns;
  }

  /// The Save dialog's answer: the log written; the message to show.
  ({bool ok, String message}) saveLog(String picked, String format) {
    var path = picked;
    _remember(logDirField, p.dirname(path));
    if (logFormats.containsKey(format)) {
      _remember(logFormatField, format);
      if (!logFormats.containsValue(p.extension(path).toLowerCase())) {
        path += logFormats[format]!;
      }
    }
    try {
      final warns = writeLog(path);
      var message = 'Dive log written to:\n$path';
      if (warns.isNotEmpty) {
        message += '\n\n${warns.length} warning(s):\n${warns.join('\n')}';
      }
      return (ok: true, message: message);
    } on FormatException catch (e) {
      return (ok: false, message: e.message);
    } on PlanError catch (e) {
      return (ok: false, message: e.message);
    } on FileSystemException catch (e) {
      return (ok: false, message: e.message);
    } on ArgumentError catch (e) {
      // A writer refusing the plan (a FIT from a computer that writes none).
      return (ok: false, message: '${e.message}');
    }
  }

  /// What the Save dialog suggests: the dive's name in the chosen format.
  String get suggestedLogName {
    final base = nameText.trim().replaceAll(' ', '_');
    return (base.isEmpty ? 'dive_profile' : base) + logFormats[savedLogFormat]!;
  }
}
