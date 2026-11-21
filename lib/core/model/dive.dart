/// The dive data model (spec §4), ported from `models/dive.py` of the Python
/// app. Field names are the Python names in camelCase; the JSON mapping
/// keeps the Python snake_case names. Units: metres, °C, bar, seconds,
/// naive local timestamps (`naive_time.dart`). A value the log does not
/// carry is `null`.
///
/// The fields are mutable because the parsers fill a waypoint in passes
/// (the deco recompute, the SAC and gas-time fill), as the Python code does.
library;

import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

/// One tank's reading at a waypoint.
class TankData {
  TankData({
    required this.pressureBar,
    this.o2Percent = 21.0,
    this.hePercent = 0.0,
    this.name,
    this.mode,
    this.enabled,
  });

  factory TankData.fromJson(Map<String, dynamic> json) => TankData(
    pressureBar: (json['pressure_bar'] as num?)?.toDouble(),
    o2Percent: (json['o2_percent'] as num?)?.toDouble() ?? 21.0,
    hePercent: (json['he_percent'] as num?)?.toDouble() ?? 0.0,
    name: json['name'] as String?,
    mode: json['mode'] as String?,
    enabled: json['enabled'] as bool?,
  );

  /// Tank pressure in bar; `null` for a tank the log lists without a
  /// reading (Python has 0 there, spec §10.8).
  double? pressureBar;
  double o2Percent;
  double hePercent;

  /// Tank name or sensor id.
  String? name;

  /// Dive mode of the gas (open circuit, diluent, ...).
  String? mode;
  bool? enabled;

  Map<String, dynamic> toJson() => {
    'pressure_bar': pressureBar,
    'o2_percent': o2Percent,
    'he_percent': hePercent,
    'name': name,
    'mode': mode,
    'enabled': enabled,
  };
}

/// One sample of a dive.
class Waypoint {
  Waypoint({
    required this.timestamp,
    required this.timeSinceStart,
    this.depth,
    this.temp,
    this.maxDepth = 0.0,
    this.decoStopDepth,
    this.ceiling,
    this.tts,
    this.ndl,
    this.diveTime,
    Map<String, TankData>? tanks,
    this.nextStopDepth,
    this.nextStopTime,
    this.airRemaining,
    this.ascentRate,
    this.n2TissueLoad,
    this.pressureSac,
    this.volumeSac,
    this.rmv,
    this.heartRate,
    this.cns,
    this.po2,
    this.divemode,
    this.gf,
    this.surfGf,
    this.switchmix,
    this.battery,
    this.clearedGasMix,
    this.setpoint,
    this.gasO2Percent,
    this.gasHePercent,
    this.diluentO2Percent,
    this.diluentHePercent,
    this.po2_1,
    this.po2_2,
    this.po2_3,
    List<String>? diveAlerts,
  }) : assert(timestamp.isUtc, naiveTimeMessage),
       // Copies, as pydantic makes them: the caller's map and list stay its
       // own.
       tanks = tanks == null ? <String, TankData>{} : Map.of(tanks),
       diveAlerts = diveAlerts == null ? <String>[] : List.of(diveAlerts);

  factory Waypoint.fromJson(Map<String, dynamic> json) => Waypoint(
    timestamp: parseNaive(json['timestamp'] as String),
    timeSinceStart: json['time_since_start'] as int,
    depth: _double(json['depth']),
    temp: _double(json['temp']),
    maxDepth: _double(json['max_depth']) ?? 0.0,
    decoStopDepth: _double(json['deco_stop_depth']),
    ceiling: _double(json['ceiling']),
    tts: json['tts'] as int?,
    ndl: json['ndl'] as int?,
    diveTime: json['dive_time'] as int?,
    tanks: {
      for (final entry
          in (json['tanks'] as Map<String, dynamic>? ?? const {}).entries)
        entry.key: TankData.fromJson(entry.value as Map<String, dynamic>),
    },
    nextStopDepth: _double(json['next_stop_depth']),
    nextStopTime: json['next_stop_time'] as int?,
    airRemaining: json['air_remaining'] as int?,
    ascentRate: _double(json['ascent_rate']),
    n2TissueLoad: _double(json['n2_tissue_load']),
    pressureSac: _double(json['pressure_sac']),
    volumeSac: _double(json['volume_sac']),
    rmv: _double(json['rmv']),
    heartRate: json['heart_rate'] as int?,
    cns: json['cns'] as int?,
    po2: _double(json['po2']),
    divemode: json['divemode'] as String?,
    gf: _double(json['gf']),
    surfGf: _double(json['surf_gf']),
    switchmix: _double(json['switchmix']),
    battery: _double(json['battery']),
    clearedGasMix: json['cleared_gas_mix'] as String?,
    setpoint: _double(json['setpoint']),
    gasO2Percent: _double(json['gas_o2_percent']),
    gasHePercent: _double(json['gas_he_percent']),
    diluentO2Percent: _double(json['diluent_o2_percent']),
    diluentHePercent: _double(json['diluent_he_percent']),
    po2_1: _double(json['po2_1']),
    po2_2: _double(json['po2_2']),
    po2_3: _double(json['po2_3']),
    diveAlerts: [
      for (final alert in json['dive_alerts'] as List<dynamic>? ?? const [])
        alert as String,
    ],
  );

  /// Naive local time of the sample.
  DateTime timestamp;

  /// Depth in metres.
  double? depth;

  /// Temperature in °C.
  double? temp;

  /// Maximum depth reached until this waypoint.
  double maxDepth;

  /// Current deco stop depth in metres; above 0 means "in deco" to the
  /// rules engine.
  double? decoStopDepth;

  /// Deco ceiling in metres, recomputed by the parsers' Bühlmann pass; not
  /// rounded to a stop level.
  double? ceiling;

  /// Time to surface in seconds.
  int? tts;

  /// No-deco limit in seconds.
  int? ndl;

  /// Seconds since the start of the dive.
  int timeSinceStart;

  /// Elapsed dive time in seconds.
  int? diveTime;

  /// Tank readings by tank key, in order: the first is the primary tank,
  /// the second the secondary.
  Map<String, TankData> tanks;

  double? nextStopDepth;
  int? nextStopTime;

  /// Gas time remaining in seconds.
  int? airRemaining;

  /// Metres per minute.
  double? ascentRate;

  /// Garmin N2 tissue load in percent; can exceed 100.
  double? n2TissueLoad;
  double? pressureSac;
  double? volumeSac;
  double? rmv;
  int? heartRate;
  int? cns;
  double? po2;
  String? divemode;

  /// GF99 in percent.
  double? gf;

  /// SurfGF in percent.
  double? surfGf;
  double? switchmix;
  double? battery;

  /// Backup or next gas shown during a gas-switch prompt (Shearwater).
  String? clearedGasMix;

  /// A rebreather's setpoint in force (bar) while on the loop; `null` on
  /// open circuit or bailout.
  double? setpoint;

  /// O2 % of the gas breathed (the diluent on the loop, the bailout gas on
  /// open circuit), apart from the tanks; `null` = the first tank's mix.
  double? gasO2Percent;
  double? gasHePercent;

  /// A rebreather dive's diluent, kept after a bailout.
  double? diluentO2Percent;
  double? diluentHePercent;

  /// CCR cell readings in bar.
  double? po2_1;
  double? po2_2;
  double? po2_3;

  /// Dive-alert event names since the previous waypoint (Garmin FIT).
  List<String> diveAlerts;

  /// The dive this waypoint belongs to; set by the [Dive] constructor.
  Dive? dive;

  String? get logFilename => dive?.logFilename;

  /// Pressure of the first tank.
  double? get primaryTankPressure =>
      tanks.isEmpty ? null : tanks.values.first.pressureBar;

  /// Name of the first tank, falling back to its key.
  String? get primaryTankName {
    if (tanks.isEmpty) {
      return null;
    }
    final first = tanks.entries.first;
    return _nameOrKey(first);
  }

  /// Pressure of the second tank (sidemount's second cylinder), if any.
  double? get secondaryTankPressure =>
      tanks.length < 2 ? null : tanks.values.elementAt(1).pressureBar;

  /// Name of the second tank, falling back to its key.
  String? get secondaryTankName =>
      tanks.length < 2 ? null : _nameOrKey(tanks.entries.elementAt(1));

  /// The circuit label a dive computer shows: "CC" on the loop, "SC"
  /// semi-closed, "BO" on open circuit during a rebreather dive, otherwise
  /// "OC", also when the log names no mode.
  String get circuit {
    final mode = (divemode ?? '').toLowerCase();
    if (mode == 'closedcircuit' || mode == 'cc' || mode == 'ccr') {
      return 'CC';
    }
    if (mode == 'semiclosedcircuit' || mode == 'sc' || mode == 'scr') {
      return 'SC';
    }
    return dive != null && dive!.isCcr ? 'BO' : 'OC';
  }

  /// PO2 of the diluent at this depth (DilPO2), on a rebreather dive.
  double? get diluentPo2 {
    final o2 = diluentO2Percent;
    if (o2 == null) {
      return null;
    }
    return pyRoundTo((1.0 + (depth ?? 0.0) / 10.0) * o2 / 100.0, 2);
  }

  /// (O2 %, He %) of the gas breathed: `gasO2Percent`/`gasHePercent` where
  /// the log names it (a rebreather's diluent, a bailout gas), else the
  /// first tank's mix; `null` when the log has neither.
  (int, int)? _breathedMix() {
    final gasO2 = gasO2Percent;
    if (gasO2 != null) {
      return (pyRound(gasO2), pyRound(gasHePercent ?? 0.0));
    }
    if (tanks.isEmpty) {
      return null;
    }
    final firstTank = tanks.values.first;
    return (pyRound(firstTank.o2Percent), pyRound(firstTank.hePercent));
  }

  /// The gas breathed as a Perdix 3 writes it over its mode badge: the O2
  /// percentage ("32%"), or O2/He for a trimix ("18/50"); "--" without a
  /// gas (Python 0.8.1, `gas_percent`).
  String get gasPercent {
    final mix = _breathedMix();
    if (mix == null) {
      return '--';
    }
    final (o2, he) = mix;
    return he != 0 ? '${_two(o2)}/${_two(he)}' : '$o2%';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  /// The gas breathed (see [_breathedMix]) by its name: AIR, Nx32, 18/45.
  /// Trimix reads O2 first.
  String get gasmix {
    final mix = _breathedMix();
    if (mix == null) {
      return 'N/A';
    }
    final (o2, he) = mix;
    if (he != 0) {
      return '${_two(o2)}/${_two(he)}';
    } else if (o2 >= 22) {
      return 'Nx${_two(o2)}';
    } else if (o2 == 21) {
      return 'AIR';
    } else {
      return '${_two(o2)}%';
    }
  }

  Map<String, dynamic> toJson() => {
    'timestamp': formatNaive(timestamp),
    'depth': depth,
    'temp': temp,
    'max_depth': maxDepth,
    'deco_stop_depth': decoStopDepth,
    'ceiling': ceiling,
    'tts': tts,
    'ndl': ndl,
    'time_since_start': timeSinceStart,
    'dive_time': diveTime,
    'tanks': {
      for (final entry in tanks.entries) entry.key: entry.value.toJson(),
    },
    'next_stop_depth': nextStopDepth,
    'next_stop_time': nextStopTime,
    'air_remaining': airRemaining,
    'ascent_rate': ascentRate,
    'n2_tissue_load': n2TissueLoad,
    'pressure_sac': pressureSac,
    'volume_sac': volumeSac,
    'rmv': rmv,
    'heart_rate': heartRate,
    'cns': cns,
    'po2': po2,
    'divemode': divemode,
    'gf': gf,
    'surf_gf': surfGf,
    'switchmix': switchmix,
    'battery': battery,
    'cleared_gas_mix': clearedGasMix,
    'setpoint': setpoint,
    'gas_o2_percent': gasO2Percent,
    'gas_he_percent': gasHePercent,
    'diluent_o2_percent': diluentO2Percent,
    'diluent_he_percent': diluentHePercent,
    'po2_1': po2_1,
    'po2_2': po2_2,
    'po2_3': po2_3,
    'dive_alerts': List<String>.of(diveAlerts),
  };

  // Python: `tank.name or key`, so an empty name also falls back.
  static String _nameOrKey(MapEntry<String, TankData> entry) {
    final name = entry.value.name;
    return name == null || name.isEmpty ? entry.key : name;
  }
}

/// How far before a dive's first sample or after its last a photo or a
/// video frame is still given one (spec §10.10).
const sampleReach = Duration(minutes: 1);

/// Shallower than this a sample is at the surface, and at least this deep
/// the dive has gone down: before the descent (the surface after the
/// entry, the dive computer's dive already started) the depth is not
/// shown (spec §10.87, owner 2026-11-19).
const surfaceDepth = 0.5;
const descentDepth = 3.0;

/// One dive: its samples and what the log says about it.
class Dive {
  Dive({
    required this.startTime,
    required this.endTime,
    required List<Waypoint> waypoints,
    this.device,
    this.manufactor,
    this.startLatitude,
    this.startLongitude,
    this.endLatitude,
    this.endLongitude,
    this.timezone,
    this.durationSeconds,
    this.gfLow,
    this.gfHigh,
    this.logFilename,
    this.logPath,
    this.logFormat,
    Map<String, double>? tankVolumesL,
  }) : assert(startTime.isUtc && endTime.isUtc, naiveTimeMessage),
       tankVolumesL = tankVolumesL ?? {},
       // A copy, as pydantic makes one; the waypoints themselves are shared.
       waypoints = List.of(waypoints) {
    for (final waypoint in this.waypoints) {
      waypoint.dive = this;
    }
  }

  factory Dive.fromJson(Map<String, dynamic> json) => Dive(
    startTime: parseNaive(json['start_time'] as String),
    endTime: parseNaive(json['end_time'] as String),
    waypoints: [
      for (final waypoint in json['waypoints'] as List<dynamic>)
        Waypoint.fromJson(waypoint as Map<String, dynamic>),
    ],
    device: json['device'] as String?,
    manufactor: json['manufactor'] as String?,
    startLatitude: _double(json['start_latitude']),
    startLongitude: _double(json['start_longitude']),
    endLatitude: _double(json['end_latitude']),
    endLongitude: _double(json['end_longitude']),
    timezone: json['timezone'] as String?,
    durationSeconds: json['duration_seconds'] as int?,
    gfLow: json['gf_low'] as int?,
    gfHigh: json['gf_high'] as int?,
    logFilename: json['log_filename'] as String?,
    logPath: json['log_path'] as String?,
    logFormat: json['log_format'] as String?,
    tankVolumesL: {
      for (final MapEntry(:key, :value)
          in (json['tank_volumes_l'] as Map<String, dynamic>? ?? const {})
              .entries)
        key: (value as num).toDouble(),
    },
  );

  DateTime startTime;
  DateTime endTime;
  List<Waypoint> waypoints;

  String? device;

  /// The maker of the dive computer. The name keeps the Python model's
  /// spelling (spec §4).
  String? manufactor;
  double? startLatitude;
  double? startLongitude;
  double? endLatitude;
  double? endLongitude;
  String? timezone;
  int? durationSeconds;

  /// The computer's GF low and high settings in percent, when the log
  /// carries them.
  int? gfLow;
  int? gfHigh;

  String? logFilename;
  String? logPath;

  /// The format key the dive was read from ("fit", "uddf",
  /// "shearwater_csv", ...).
  String? logFormat;

  /// The size of each tank (water capacity in litres) by its key in the
  /// waypoints' `tanks`, where the log gives one: what the VSAC of a log
  /// that records none is worked out from (`fillVolumeSac`). Not in the
  /// Python model (spec §10.54).
  Map<String, double> tankVolumesL;

  (int, bool)? _isCcrCache;
  List<DateTime>? _timestampCache;

  /// A rebreather dive: some waypoint is on the loop.
  bool get isCcr {
    final cached = _isCcrCache;
    if (cached != null && cached.$1 == waypoints.length) {
      return cached.$2;
    }
    final value = waypoints.any(
      (waypoint) =>
          waypoint.divemode == 'closedcircuit' ||
          waypoint.divemode == 'semiclosedcircuit',
    );
    _isCcrCache = (waypoints.length, value);
    return value;
  }

  double get maxDepth {
    var deepest = 0.0;
    var first = true;
    for (final waypoint in waypoints) {
      final depth = waypoint.depth ?? 0.0;
      if (first || depth > deepest) {
        deepest = depth;
        first = false;
      }
    }
    return deepest;
  }

  /// `endTime − startTime` in whole seconds.
  int get duration => endTime.difference(startTime).inSeconds;

  /// Call after changing the waypoints' timestamps or the list itself.
  void invalidateTimestampCache() {
    _timestampCache = null;
    _beforeDescent = null;
  }

  /// How many of the first samples lie before the descent: up to the
  /// last one at the surface ([surfaceDepth]) before the dive first
  /// reaches [descentDepth]. None when it is never at the surface before
  /// that, or never gets there.
  int get samplesBeforeDescent {
    final deep = waypoints.indexWhere(
      (w) => w.depth != null && w.depth! >= descentDepth,
    );
    if (deep <= 0) {
      return 0;
    }
    return waypoints
            .sublist(0, deep)
            .lastIndexWhere((w) => w.depth != null && w.depth! < surfaceDepth) +
        1;
  }

  // The samples before the descent as they are shown, without their
  // depth; made once, so that a video's frames stay one run per sample.
  Map<Waypoint, Waypoint>? _beforeDescent;

  /// [waypoint] as the overlay shows it: before the descent its depth is
  /// `null` ("--"), the rest as logged.
  Waypoint shown(Waypoint waypoint) {
    final map = _beforeDescent ??= {
      for (final w in waypoints.take(samplesBeforeDescent))
        w: Waypoint.fromJson(w.toJson())..depth = null,
    };
    return map[waypoint] ?? waypoint;
  }

  /// [getWaypointAt] for a time within [reach] of the dive's samples,
  /// else `null`: a photo taken on the boat before the dive shows "--",
  /// not the first sample's values (spec §10.10, owner 2026-11-19). A
  /// sample before the descent comes [shown], without its depth.
  Waypoint? getWaypointNear(
    DateTime targetTime, {
    Duration reach = sampleReach,
  }) {
    if (waypoints.isEmpty ||
        targetTime.isBefore(waypoints.first.timestamp.subtract(reach)) ||
        targetTime.isAfter(waypoints.last.timestamp.add(reach))) {
      return null;
    }
    final at = getWaypointAt(targetTime);
    return at == null ? null : shown(at);
  }

  /// The waypoint closest to [targetTime]; on an exact tie the later one.
  ///
  /// There is no limit on how far away the closest one may be: a time long
  /// before or after the dive gets its first or last sample, as in Python.
  /// What the media is drawn with is [getWaypointNear].
  Waypoint? getWaypointAt(DateTime targetTime) {
    assert(targetTime.isUtc, naiveTimeMessage);
    if (waypoints.isEmpty) {
      return null;
    }
    var timestamps = _timestampCache;
    if (timestamps == null || timestamps.length != waypoints.length) {
      timestamps = [for (final waypoint in waypoints) waypoint.timestamp];
      _timestampCache = timestamps;
    }

    // bisect_left: the first index whose timestamp is not before the target.
    var low = 0;
    var high = timestamps.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (timestamps[middle].isBefore(targetTime)) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low == 0) {
      return waypoints.first;
    }
    if (low == waypoints.length) {
      return waypoints.last;
    }
    final before = waypoints[low - 1];
    final after = waypoints[low];
    if (targetTime.difference(before.timestamp) <
        after.timestamp.difference(targetTime)) {
      return before;
    }
    return after;
  }

  Map<String, dynamic> toJson() => {
    'start_time': formatNaive(startTime),
    'end_time': formatNaive(endTime),
    'waypoints': [for (final waypoint in waypoints) waypoint.toJson()],
    'device': device,
    'manufactor': manufactor,
    'start_latitude': startLatitude,
    'start_longitude': startLongitude,
    'end_latitude': endLatitude,
    'end_longitude': endLongitude,
    'timezone': timezone,
    'duration_seconds': durationSeconds,
    'gf_low': gfLow,
    'gf_high': gfHigh,
    'log_filename': logFilename,
    'log_path': logPath,
    'log_format': logFormat,
    // Port only: left out when there are none, so a dive the Python model
    // can hold dumps as it does.
    if (tankVolumesL.isNotEmpty) 'tank_volumes_l': Map.of(tankVolumesL),
  };
}

double? _double(Object? value) => (value as num?)?.toDouble();
