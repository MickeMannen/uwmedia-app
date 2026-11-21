/// A plan rebuilt from a log (Python `utils/dive_plan_import.py`): for a
/// log the Dive Profile Builder wrote before it put the plan itself into
/// its files, and for any other log it opens (another program's UDDF or
/// Subsurface file, a Shearwater Cloud XML or CSV export, a Subsurface
/// CSV, a Garmin FIT activity).
///
/// The plan's ingredients are read from the file's own structure, not from
/// the parsed dive (which no longer says which tank a gas is in or when it
/// was switched to):
/// - gases and tanks: UDDF gas definitions and tank data, Subsurface
///   cylinders, FIT `dive_gas` messages and the tank pods' descriptors; a
///   CCR dive's diluent and oxygen cylinder are recognised;
/// - gas switches, each of which becomes a waypoint, so that the profile
///   is split into stretches of one gas;
/// - GF, the water temperature and, from FIT, the PO2 limits;
/// - the depth profile: the parsed dive's samples, thinned out
///   (Douglas-Peucker) to a few dozen waypoints per stretch.
///
/// What a log does not hold (SAC, rates, the gases' depth ranges) stays as
/// in the base plan. A gas first breathed after the deepest point is
/// marked an ascent gas, so that ending the dive keeps picking it on the
/// way up.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/parsers/fit_reader.dart';
import 'package:uwmedia_app/core/parsers/garmin.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/core/parsers/shearwater.dart';
import 'package:uwmedia_app/core/parsers/suunto.dart';
import 'package:uwmedia_app/core/parsers/xml_query.dart';
import 'package:uwmedia_app/core/plan/dive_computers.dart';
import 'package:uwmedia_app/core/plan/dive_plan.dart';
import 'package:uwmedia_app/core/plan/log_writers.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';
import 'package:xml/xml.dart';

const profileToleranceM = 0.6;
const maxProfileWaypoints = 60;

// The space the thinning measures distances in: minutes against metres, so
// that a metre of depth weighs like a minute of time.
const _timeScalePerM = 60.0;
const _psiToBar = 0.0689476;

/// A gas as a log has it.
class LoggedGas {
  LoggedGas({
    required this.name,
    required this.o2Percent,
    required this.hePercent,
    this.tankRef = 'T1',
    this.tankSizeL,
    this.startPressureBar,
    this.sidemountPair = false,
    this.rightTankRef,
    this.diluent = false,
  });

  final String name;
  final double o2Percent;
  final double hePercent;
  final String tankRef;
  final double? tankSizeL;
  final double? startPressureBar;
  final bool sidemountPair;

  /// A sidemount pair's right tank; `null` for the next free `T<n>`.
  final String? rightTankRef;
  bool diluent;
}

/// What one format's file says about the plan, before the profile.
class LoggedPlanParts {
  final List<LoggedGas> gases = [];

  /// Seconds and gas name, the first gas at 0 included.
  final List<(int, String)> switches = [];
  String diveType = 'oc';
  double? gfLow;
  double? gfHigh;
  double? maxPo2Bottom;
  double? maxPo2Deco;
  double? ccrO2TankSizeL;
  double? ccrO2StartPressureBar;
  double? waterTempC;
}

final _notAlnum = RegExp('[^a-z0-9]');

String _norm(String? text) =>
    (text ?? '').toLowerCase().replaceAll(_notAlnum, '');

double _number(String text) {
  final value = pyFloat(text);
  if (value == null) {
    throw FormatException('Not a number', text);
  }
  return value;
}

int _whole(double value) {
  if (!value.isFinite) {
    throw FormatException('Not a whole number', value);
  }
  return value.truncate();
}

/// The label of the computer that matches the log's device name
/// ("descent_x50i", "Descent X50i", "Perdix 2" …), else [fallback].
String computerLabelFor(Dive dive, String fallback) {
  final device = _norm(dive.device);
  if (device.isEmpty) {
    return fallback;
  }
  for (final MapEntry(key: label, value: computer) in diveComputers.entries) {
    final model = _norm(computer.model);
    if (model.isNotEmpty &&
        (device.contains(model) || model.contains(device))) {
      return label;
    }
  }
  return fallback;
}

List<Waypoint> _byTime(Dive dive) {
  final indexed = dive.waypoints.indexed.toList()
    ..sort((a, b) {
      final byTime = a.$2.timeSinceStart.compareTo(b.$2.timeSinceStart);
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
  return [for (final (_, wp) in indexed) wp];
}

// A CCR log's low and high setpoints and where it switched: the lowest and
// the highest setpoint of its samples, the depth of the first switch up
// and of the last switch down. Left as they are when the log has no
// setpoints, or only one.
void _setpointsFromLog(DiveProfilePlan plan, Dive dive) {
  final logged = [
    for (final wp in _byTime(dive))
      if (wp.setpoint != null) (wp.depth ?? 0.0, wp.setpoint!),
  ];
  final values = {for (final (_, sp) in logged) sp}.toList()..sort();
  bool fits(double v) => 0.4 <= v && v <= 1.6;
  if (values.isEmpty || !fits(values.first) || !fits(values.last)) {
    return;
  }
  plan
    ..ccrLowSetpoint = values.first
    ..ccrHighSetpoint = values.last;
  if (values.length < 2) {
    return;
  }
  double? firstUp;
  double? lastDown;
  for (var i = 1; i < logged.length; i++) {
    final (depth, now) = logged[i];
    final before = logged[i - 1].$2;
    if (now > before) {
      firstUp ??= depth;
    } else if (now < before) {
      lastDown = depth;
    }
  }
  if (firstUp != null) {
    plan.ccrHighSetpointDepthM = pyRound(firstUp).toDouble();
  }
  if (lastDown != null) {
    plan.ccrLowSetpointDepthM = pyRound(lastDown).toDouble();
  }
}

/// "Air", "EAN32", "Tx18/45": a gas name for a file that has none.
String mixName(double o2Percent, double hePercent) {
  if (hePercent > 0) {
    return 'Tx${pyFormatG(o2Percent)}/${pyFormatG(hePercent)}';
  }
  return (o2Percent - 21.0).abs() < 0.5 ? 'Air' : 'EAN${pyFormatG(o2Percent)}';
}

String gasTypeFor(double o2Percent, double hePercent) => hePercent > 0
    ? 'trimix'
    : ((o2Percent - 21.0).abs() < 0.5 ? 'air' : 'nitrox');

/// "12:34 min", "45 s" or "12:34" as seconds.
int mmssSeconds(String? text) {
  var t = (text ?? '').pyStrip();
  if (t.endsWith('min')) {
    t = t.substring(0, t.length - 3).pyStrip();
  } else if (t.endsWith('s')) {
    t = t.substring(0, t.length - 1).pyStrip();
  }
  final colon = t.indexOf(':');
  if (colon != -1) {
    final minutes = pyInt(t.substring(0, colon));
    if (minutes == null) {
      throw FormatException('Not a time', text);
    }
    return minutes * 60 + _whole(_number(t.substring(colon + 1)));
  }
  return t.isEmpty ? 0 : _whole(_number(t));
}

/// Tank references in file order as, per gas, its tank, its right tank and
/// whether it is a pair. A sidemount pair is two tanks in a row: the
/// writers' own order for the left tank and then the right one, with the
/// same mix (when [mixes], one per tank, is given), or as older versions
/// named them, `<ref>L` followed by `<ref>R` (the right tank is then named
/// afresh). One pair per dive.
List<(String, String?, bool)> pairUp(
  List<String> refs, [
  List<Object?>? mixes,
]) {
  final out = <(String, String?, bool)>[];
  var paired = false;
  var i = 0;
  while (i < refs.length) {
    final ref = refs[i];
    final next = i + 1 < refs.length ? refs[i + 1] : null;
    if (!paired &&
        next != null &&
        ref.endsWith('L') &&
        next == '${ref.substring(0, ref.length - 1)}R') {
      out.add((ref.substring(0, ref.length - 1), null, true));
      paired = true;
      i += 2;
    } else if (!paired &&
        next != null &&
        mixes != null &&
        mixes[i] == mixes[i + 1]) {
      out.add((ref, next, true));
      paired = true;
      i += 2;
    } else {
      out.add((ref, null, false));
      i += 1;
    }
  }
  return out;
}

// --- UDDF ---------------------------------------------------------------------

Iterable<XmlElement> _named(XmlElement node, String name) =>
    node.childElements.where((e) => e.localName == name);

String _childText(XmlElement node, String name) =>
    stringValue(_named(node, name).firstOrNull);

Iterable<XmlElement> _under(XmlElement root, String parent, String name) => root
    .descendantElements
    .where((e) => e.localName == name && e.parentElement?.localName == parent);

LoggedPlanParts _uddfParts(Uint8List bytes) {
  final root = parseXmlBytes(bytes).rootElement;
  final parts = LoggedPlanParts();

  final mixes = <String, (String, double, double)>{};
  for (final mix in _under(root, 'gasdefinitions', 'mix')) {
    final id = mix.getAttribute('id') ?? '';
    if (id == ccrO2MixId) {
      continue; // a CCR oxygen cylinder's own mix, never a breathed gas
    }
    final named = _childText(mix, 'name');
    final o2 = _childText(mix, 'o2');
    final he = _childText(mix, 'he');
    mixes[id] = (
      named.isNotEmpty ? named : id.split(':').first,
      (o2.isEmpty ? 0.21 : _number(o2)) * 100.0,
      (he.isEmpty ? 0.0 : _number(he)) * 100.0,
    );
  }

  // ref, mix id, size in litres, start in bar
  final tanks = <(String, String?, double?, double?)>[];
  for (final data in _under(root, 'informationbeforedive', 'tankdata')) {
    final link = _named(data, 'link').firstOrNull?.getAttribute('ref') ?? '';
    final volume = _childText(data, 'tankvolume');
    final begin = _childText(data, 'tankpressurebegin');
    tanks.add((
      data.getAttribute('id') ?? '',
      link.isEmpty ? null : link,
      volume.isEmpty ? null : _number(volume) * 1000.0,
      begin.isEmpty ? null : _number(begin) / 100000.0,
    ));
  }

  final ccr = _under(
    root,
    'waypoint',
    'divemode',
  ).any((e) => _norm(e.getAttribute('type')) == 'closedcircuit');
  parts.diveType = ccr ? 'ccr' : 'oc';
  final o2Tank = ccr
      ? tanks
            .where(
              (t) =>
                  t.$1 == ccrO2TankRef && (t.$2 == null || t.$2 == ccrO2MixId),
            )
            .firstOrNull
      : null;
  if (o2Tank != null) {
    parts
      ..ccrO2TankSizeL = o2Tank.$3
      ..ccrO2StartPressureBar = o2Tank.$4;
  }
  final byMix = <String, List<(String, double?, double?)>>{};
  for (final tank in tanks) {
    if (!identical(tank, o2Tank) && mixes.containsKey(tank.$2)) {
      byMix.putIfAbsent(tank.$2!, () => []).add((tank.$1, tank.$3, tank.$4));
    }
  }
  mixes.forEach((mixId, mix) {
    final own = byMix[mixId] ?? const [];
    final refs = own.isEmpty ? ['T1'] : [for (final t in own) t.$1];
    final (tankRef, rightRef, pair) = pairUp(refs, [
      for (final _ in refs) mixId,
    ]).first;
    parts.gases.add(
      LoggedGas(
        name: mix.$1,
        o2Percent: mix.$2,
        hePercent: mix.$3,
        tankRef: tankRef,
        sidemountPair: pair,
        rightTankRef: rightRef,
        tankSizeL: own.isEmpty ? null : own.first.$2,
        startPressureBar: own.isEmpty ? null : own.first.$3,
      ),
    );
  });
  if (parts.gases.any((g) => g.sidemountPair) && !ccr) {
    parts.diveType = 'sidemount';
  }

  final onLoop = <String>{};
  for (final wp in _under(root, 'samples', 'waypoint')) {
    final ref = _named(wp, 'switchmix').firstOrNull?.getAttribute('ref') ?? '';
    final mix = mixes[ref];
    if (ref.isNotEmpty && mix != null) {
      final time = _childText(wp, 'divetime');
      parts.switches.add((time.isEmpty ? 0 : _whole(_number(time)), mix.$1));
    }
    if (ccr &&
        parts.switches.isNotEmpty &&
        _norm(_named(wp, 'divemode').firstOrNull?.getAttribute('type')) ==
            'closedcircuit') {
      onLoop.add(parts.switches.last.$2);
    }
  }
  for (final gas in parts.gases) {
    gas.diluent = ccr && onLoop.contains(gas.name);
  }

  double? factor(String name) {
    // The first one in the file inside any decomodel.
    final text = stringValue(
      root.descendantElements
          .where(
            (e) =>
                e.localName == name &&
                e.ancestorElements.any((a) => a.localName == 'decomodel'),
          )
          .firstOrNull,
    );
    final value = text.isEmpty ? 0.0 : _number(text);
    return value == 0 ? null : value;
  }

  parts
    ..gfHigh = factor('gradientfactorhigh')
    ..gfLow = factor('gradientfactorlow');
  final temperature = _under(
    root,
    'waypoint',
    'temperature',
  ).expand((e) => e.children.whereType<XmlText>()).firstOrNull;
  if (temperature != null) {
    parts.waterTempC = pyRoundTo(_number(temperature.value) - 273.15, 1);
  }
  return parts;
}

// --- Subsurface XML -----------------------------------------------------------

typedef _Cylinder = ({
  String ref,
  double o2,
  double he,
  double? size,
  double? start,
  String use,
});

final _notNumber = RegExp('[^0-9.]');
final _gfPair = RegExp(r'(\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)');

LoggedPlanParts _subsurfaceParts(Uint8List bytes) {
  final root = parseXmlBytes(bytes).rootElement;
  final parts = LoggedPlanParts();
  final dive = root.descendantElements
      .where((e) => e.name.qualified == 'dive')
      .firstOrNull;
  if (dive == null) {
    throw const FormatException('No dive in the file');
  }
  Iterable<XmlElement> children(XmlElement node, String name) =>
      node.childElements.where((e) => e.name.qualified == name);

  final cylinders = <_Cylinder>[];
  for (final cyl in children(dive, 'cylinder')) {
    double? number(String attr) {
      final value = cyl.getAttribute(attr) ?? '';
      return value.isEmpty ? null : _number(value.replaceAll(_notNumber, ''));
    }

    final described = cyl.getAttribute('description') ?? '';
    cylinders.add((
      ref: described.isNotEmpty ? described : 'T${cylinders.length + 1}',
      o2: number('o2') ?? 21.0,
      he: number('he') ?? 0.0,
      size: number('size'),
      start: number('start'),
      use: cyl.getAttribute('use') ?? 'oc',
    ));
  }
  final computer = children(dive, 'divecomputer').firstOrNull;
  if (computer == null) {
    throw const FormatException('No dive computer in the dive');
  }
  final ccr = (computer.getAttribute('dctype') ?? '').toUpperCase() == 'CCR';
  parts.diveType = ccr ? 'ccr' : 'oc';
  final o2Index = cylinders.indexWhere((c) => c.use == 'oxygen');
  if (o2Index != -1) {
    parts
      ..ccrO2TankSizeL = cylinders[o2Index].size
      ..ccrO2StartPressureBar = cylinders[o2Index].start;
  }
  final gasCylinders = [
    for (final (i, c) in cylinders.indexed)
      if (i != o2Index) c,
  ];
  // Cylinders in order: a sidemount pair (two in a row of one mix, or an
  // older <ref>L and <ref>R) is one gas.
  final nameOfCylinder = <int, String>{};
  var i = 0;
  for (final (tankRef, rightRef, pair) in pairUp([
    for (final c in gasCylinders) c.ref,
  ], ccr ? null : [for (final c in gasCylinders) (c.o2, c.he, c.use)])) {
    final c = gasCylinders[i];
    final name = mixName(c.o2, c.he);
    parts.gases.add(
      LoggedGas(
        name: name,
        o2Percent: c.o2,
        hePercent: c.he,
        tankRef: tankRef,
        sidemountPair: pair,
        rightTankRef: rightRef,
        tankSizeL: c.size,
        startPressureBar: c.start,
        diluent: c.use == 'diluent',
      ),
    );
    for (var k = 0; k < (pair ? 2 : 1); k++) {
      // The first cylinder that is the same in every way, as Python's
      // list.index finds it.
      nameOfCylinder[cylinders.indexOf(gasCylinders[i])] = name;
      i++;
    }
  }
  if (parts.gases.any((g) => g.sidemountPair) && !ccr) {
    parts.diveType = 'sidemount';
  }
  for (final event in children(computer, 'event')) {
    if (event.getAttribute('name') != 'gaschange') {
      continue;
    }
    final cylinder = (event.getAttribute('cylinder') ?? '0').pyStrip();
    if (!RegExp(r'^[+-]?\d+(_\d+)*$').hasMatch(cylinder)) {
      throw FormatException('Not a cylinder number', cylinder);
    }
    // A number too large to be an index is no cylinder of the dive.
    final name = nameOfCylinder[pyInt(cylinder)];
    if (name != null) {
      parts.switches.add((
        mmssSeconds(event.getAttribute('time') ?? '0:00 min'),
        name,
      ));
    }
  }
  String extra(String key) =>
      children(computer, 'extradata')
          .where((e) => e.getAttribute('key') == key)
          .firstOrNull
          ?.getAttribute('value') ??
      '';
  // "GF 40/85" (the builder's writer) or "Buhlmann ZHL-16C 40/85"
  // (Subsurface's own): the pair around the slash, not the first two
  // numbers.
  final gf = _gfPair.firstMatch(extra('Deco model'));
  if (gf != null) {
    parts
      ..gfLow = _number(gf[1]!)
      ..gfHigh = _number(gf[2]!);
  }
  final water =
      children(computer, 'temperature').firstOrNull?.getAttribute('water') ??
      '';
  if (water.isNotEmpty) {
    parts.waterTempC = _number(water.replaceAll(RegExp(r'[^0-9.\-]'), ''));
  }
  return parts;
}

// --- Shearwater Cloud XML and CSV, Subsurface CSV (opened, never written) -----

// Gases and switches from each record's O2 and He fractions (one tank, T1:
// the export does not say which transmitter is on which gas), GF and start
// pressure from the header and the first record.
LoggedPlanParts _shearwaterParts(Uint8List bytes, String path) {
  final tables = readShearwaterTables(bytes, path);
  final parts = LoggedPlanParts();
  final imperial =
      (tables.header['Imperial Units'] ?? '').pyStrip().toLowerCase() == 'true';
  final gases = <(double, double), String>{};
  String? current;
  var ccr = false;
  for (final row in tables.rows) {
    final seconds = row.seconds;
    if (seconds == null) {
      continue;
    }
    double fraction(String column, double fallback) {
      final value = pyFloat(row.fields[column]) ?? 0.0;
      return pyRoundTo((value == 0 ? fallback : value) * 100.0, 1);
    }

    final o2 = fraction('Fraction O2', 0.21);
    final he = fraction('Fraction He', 0.0);
    final name = gases.putIfAbsent((o2, he), () => mixName(o2, he));
    if (name != current) {
      parts.switches.add((_whole(seconds), name));
      current = name;
    }
    final mode = (row.fields['Current Circuit Mode'] ?? '')
        .pyStrip()
        .toUpperCase();
    ccr = ccr || mode.startsWith('CC') || mode.startsWith('SC') || mode == '0';
  }
  final startPsi = tables.rows
      .map((r) => pyFloat(r.fields['Tank 1 pressure (PSI)']))
      .where((p) => p != null && p != 0)
      .firstOrNull;
  for (final (i, MapEntry(key: (o2, he), value: name))
      in gases.entries.indexed) {
    parts.gases.add(
      LoggedGas(
        name: name,
        o2Percent: o2,
        hePercent: he,
        tankRef: i == 0 ? 'T1' : 'T${i + 1}',
        startPressureBar: i == 0 && startPsi != null
            ? startPsi * _psiToBar
            : null,
        diluent: ccr && i == 0,
      ),
    );
  }
  parts
    ..diveType = ccr ? 'ccr' : 'oc'
    ..gfLow = pyFloat(tables.header['GF Minimum'])
    ..gfHigh = pyFloat(tables.header['GF Maximum']);
  final temp = tables.rows
      .map((r) => pyFloat(r.fields['Water Temp']))
      .where((t) => t != null)
      .firstOrNull;
  if (temp != null) {
    parts.waterTempC = imperial ? (temp - 32.0) * 5.0 / 9.0 : temp;
  }
  return parts;
}

// --- Suunto app JSON ------------------------------------------------------------

// Gases (mix, tank size, start pressure) from the export's header and the
// switches from its GasSwitch events, by the gas numbers the samples use;
// an export with no gas list (an Ocean, a Nautic) gets the builder's own
// gases. The first gas in the list is the one in use until the first
// switch (Python `_suunto_parts`).
LoggedPlanParts _suuntoParts(Uint8List bytes, Dive? dive) {
  final log = readDeviceLog(bytes);
  final parts = LoggedPlanParts();
  final gases = readGases(log);
  final numbers = gases.keys.toList()..sort();
  final names = {
    for (final number in numbers)
      number: mixName(gases[number]!.o2Percent, gases[number]!.hePercent),
  };
  for (final (i, number) in numbers.indexed) {
    final gas = gases[number]!;
    parts.gases.add(
      LoggedGas(
        name: names[number]!,
        o2Percent: gas.o2Percent,
        hePercent: gas.hePercent,
        tankRef: 'T${i + 1}',
        tankSizeL: gas.tankSizeL,
        startPressureBar: gas.startPressureBar,
      ),
    );
  }
  final start = parseSuuntoTime(_mapOf(log['Header'])['DateTime']);
  if (gases.isNotEmpty && start != null) {
    var current = names[numbers.first]!;
    parts.switches.add((0, current));
    for (final record in sampleRecords(log, start)) {
      final switched = record.gasSwitch;
      final name = switched == null ? null : names[switched];
      if (name != null && name != current) {
        parts.switches.add((record.seconds.truncate(), name));
        current = name;
      }
    }
  }
  if (dive != null) {
    parts.waterTempC = dive.waypoints
        .map((wp) => wp.temp)
        .where((t) => t != null)
        .firstOrNull;
  }
  return parts;
}

Map<String, dynamic> _mapOf(Object? value) =>
    value is Map<String, dynamic> ? value : const {};

// --- Garmin FIT ---------------------------------------------------------------

double? _fitNumber(Object? value) => value is num ? value.toDouble() : null;

// Seconds of a message's timestamp, on whatever clock the reader gives it.
int? _fitSeconds(Object? value) => switch (value) {
  final int seconds => seconds,
  final DateTime time => time.millisecondsSinceEpoch ~/ 1000,
  _ => null,
};

bool _closedCircuit(FitMesg gas) =>
    '${gas['mode'] ?? ''}'.startsWith('closed_circuit');

LoggedPlanParts _fitParts(Uint8List bytes) {
  final messages = readFitMessages(bytes);
  final parts = LoggedPlanParts();
  final gases = messages['dive_gas_mesgs'] ?? const <FitMesg>[];
  // The tank pods: the devices with a descriptor, in the order of their
  // device index.
  final pods = [
    for (final m in messages['device_info_mesgs'] ?? const <FitMesg>[])
      if (m['descriptor'] case final Object d when '$d'.isNotEmpty) m,
  ];
  int indexOf(FitMesg m) => switch (m['device_index']) {
    final int index => index,
    _ => 0,
  };
  // A stable sort, as Python's.
  final order = [for (var i = 0; i < pods.length; i++) i]
    ..sort((a, b) {
      final byIndex = indexOf(pods[a]).compareTo(indexOf(pods[b]));
      return byIndex != 0 ? byIndex : a.compareTo(b);
    });
  final sorted = [for (final i in order) pods[i]];
  final starts = <Object?, double?>{
    for (final m in messages['tank_summary_mesgs'] ?? const <FitMesg>[])
      m['sensor']: _fitNumber(m['start_pressure']),
  };
  var refs = [for (final m in sorted) '${m['descriptor']}'];
  final startOfRef = {
    for (final m in sorted) '${m['descriptor']}': starts[m['serial_number']],
  };
  final ccr = gases.any(_closedCircuit);
  parts.diveType = ccr ? 'ccr' : 'oc';
  if (ccr && refs.isNotEmpty && refs.first == ccrO2TankRef) {
    parts.ccrO2StartPressureBar = startOfRef[ccrO2TankRef];
    refs = refs.sublist(1);
  }
  var assignments = pairUp(refs);
  if (!ccr &&
      !assignments.any((a) => a.$3) &&
      refs.length == gases.length + 1 &&
      refs.length >= 2) {
    // FIT does not say which gas a tank holds: one tank more than gases
    // is a sidemount pair, the first gas's (the writers' order).
    assignments = [
      (refs[0], refs[1], true),
      for (final r in refs.skip(2)) (r, null, false),
    ];
  }
  for (final (i, g) in gases.indexed) {
    // Python's `float(x or 21)`: nothing and 0 are the default.
    double content(String key, double fallback) {
      final value = _fitNumber(g[key]);
      return value == null || value == 0 ? fallback : value;
    }

    final o2 = content('oxygen_content', 21);
    final he = content('helium_content', 0);
    final (tankRef, rightRef, pair) = i < assignments.length
        ? assignments[i]
        : ('T${i + 1}', null, false);
    parts.gases.add(
      LoggedGas(
        name: mixName(o2, he),
        o2Percent: o2,
        hePercent: he,
        tankRef: tankRef,
        sidemountPair: pair,
        rightTankRef: rightRef,
        startPressureBar:
            startOfRef[pair && rightRef == null ? '${tankRef}L' : tankRef],
        diluent: _closedCircuit(g),
      ),
    );
  }
  if (parts.gases.any((g) => g.sidemountPair) && !ccr) {
    parts.diveType = 'sidemount';
  }

  final records = messages['record_mesgs'] ?? const <FitMesg>[];
  final first = records.isEmpty
      ? null
      : _fitSeconds(records.first['timestamp']);
  if (parts.gases.isNotEmpty) {
    parts.switches.add((0, parts.gases.first.name));
  }
  for (final event in messages['event_mesgs'] ?? const <FitMesg>[]) {
    if (event['event'] != 'dive_gas_switched') {
      continue;
    }
    final index = event['data'];
    if (index is int &&
        index >= 0 &&
        index < parts.gases.length &&
        first != null) {
      final at = _fitSeconds(event['timestamp']);
      if (at == null) {
        throw const FormatException('FIT gas switch without a timestamp');
      }
      parts.switches.add((at - first, parts.gases[index].name));
    }
  }

  final settings = messages['dive_settings_mesgs'] ?? const <FitMesg>[];
  if (settings.isNotEmpty) {
    final s = settings.first;
    parts
      ..gfLow = _fitNumber(s['gf_low'])
      ..gfHigh = _fitNumber(s['gf_high'])
      ..maxPo2Bottom = _fitNumber(s['po2_warn'])
      ..maxPo2Deco = _fitNumber(s['po2_deco']);
  }
  if (records.isNotEmpty) {
    parts.waterTempC =
        _fitNumber(records.first['temperature']) ?? parts.waterTempC;
  }
  return parts;
}

// --- Profile --------------------------------------------------------------------

double _hypot(double x, double y) => math.sqrt(x * x + y * y);

/// Douglas-Peucker over points of seconds and metres, with distances
/// measured in minutes and metres. The first and the last point are
/// always kept.
List<(double, double)> simplifyProfile(
  List<(double, double)> points, {
  double toleranceM = profileToleranceM,
}) {
  if (points.length <= 2) {
    return List.of(points);
  }
  final xs = [for (final (t, _) in points) t / _timeScalePerM];
  final ys = [for (final (_, d) in points) d];
  final keep = List.filled(points.length, false);
  keep[0] = keep[points.length - 1] = true;
  final stack = [(0, points.length - 1)];
  while (stack.isNotEmpty) {
    final (a, b) = stack.removeLast();
    if (b - a < 2) {
      continue;
    }
    final dx = xs[b] - xs[a];
    final dy = ys[b] - ys[a];
    final length = _hypot(dx, dy);
    var best = 0.0;
    var bestIndex = -1;
    for (var i = a + 1; i < b; i++) {
      final dist = length == 0
          ? _hypot(xs[i] - xs[a], ys[i] - ys[a])
          : (dy * xs[i] - dx * ys[i] + xs[b] * ys[a] - ys[b] * xs[a]).abs() /
                length;
      if (dist > best) {
        best = dist;
        bestIndex = i;
      }
    }
    if (best > toleranceM) {
      keep[bestIndex] = true;
      stack
        ..add((a, bestIndex))
        ..add((bestIndex, b));
    }
  }
  return [
    for (final (i, p) in points.indexed)
      if (keep[i]) p,
  ];
}

/// The dive's depth samples as thinned-out waypoints, split at every gas
/// switch (which gets a waypoint of its own on the new gas).
List<PlannedWaypoint> profileWaypoints(
  Dive dive,
  List<(int, String)> switchesIn,
  String firstGas,
) {
  var samples = [
    for (final wp in dive.waypoints)
      if (wp.depth != null) (wp.timeSinceStart, pyRoundTo(wp.depth!, 1)),
  ]..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  if (samples.isEmpty) {
    return [];
  }
  if (samples.first.$1 < 0) {
    // Times counted from a start the parser put after the samples (an
    // older Garmin FIT): count from the first sample instead.
    final offset = samples.first.$1;
    samples = [for (final (t, d) in samples) (t - offset, d)];
  }
  final switches = [
    for (final (t, g) in switchesIn) (t < 0 ? 0 : t, g),
  ]..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  final depthAt = {for (final (t, d) in samples) t: d};
  double depthNear(int t) {
    final exact = depthAt[t];
    if (exact != null) {
      return exact;
    }
    final before = samples.where((s) => s.$1 <= t);
    return before.isEmpty ? samples.first.$2 : before.last.$2;
  }

  final gas = switches.isNotEmpty && switches.first.$1 == 0
      ? switches.first.$2
      : firstGas;
  final boundaries = <(int, String)>[];
  var current = gas;
  for (final (t, g) in switches) {
    // A sidemount change of side is the same gas, not a switch.
    if (t > 0 && g != current) {
      boundaries.add((t, g));
    }
    current = g;
  }
  final segments = <(String, List<(double, double)>)>[(gas, [])];
  var bi = 0;
  for (final (t, d) in samples) {
    while (bi < boundaries.length && boundaries[bi].$1 <= t) {
      final (switchT, newGas) = boundaries[bi];
      final point = (switchT.toDouble(), depthNear(switchT));
      segments.last.$2.add(point);
      segments.add((newGas, [point]));
      bi++;
    }
    segments.last.$2.add((t.toDouble(), d));
  }

  var tolerance = profileToleranceM;
  List<PlannedWaypoint> out;
  while (true) {
    out = [];
    final seen = <int>{};
    for (final (segmentGas, points) in segments) {
      for (final (t, d) in simplifyProfile(points, toleranceM: tolerance)) {
        final runtime = pyRound(t);
        if (!seen.add(runtime)) {
          continue;
        }
        out.add(
          PlannedWaypoint.fromJson({
            'runtime_sec': runtime,
            'depth_m': pyMax(0.0, d),
            'gas_id': segmentGas,
          }),
        );
      }
    }
    if (out.length <= maxProfileWaypoints || tolerance > 20) {
      break;
    }
    tolerance *= 1.5;
  }
  // The builder's first waypoint is where the descent arrives; the start
  // at the surface is understood.
  if (out.length > 1 && out.first.runtimeSec == 0 && out.first.depthM <= 0) {
    out.removeAt(0);
  }
  return out;
}

// --- Entry point ------------------------------------------------------------------

/// What the log in [bytes] (a file at [path]) says about its plan. [dive]
/// is the file's parsed dive, which a Subsurface CSV needs. Throws a
/// [FormatException] for a file it cannot read.
LoggedPlanParts loggedPlanParts(String path, Uint8List bytes, [Dive? dive]) {
  final head = bytes.length > logHeadSize
      ? Uint8List.sublistView(bytes, 0, logHeadSize)
      : bytes;
  final format = detectLogFormat(path, head);
  if (format == shearwaterXmlFormat || format == shearwaterCsvFormat) {
    return _shearwaterParts(bytes, path);
  }
  if (format == suuntoJsonFormat) {
    return _suuntoParts(bytes, dive);
  }
  if (format == subsurfaceCsvFormat) {
    // A Subsurface CSV profile has no gas, cylinder or GF: the builder's
    // own settings stand for those; the water temperature is the first
    // sample's that has one.
    final parts = LoggedPlanParts();
    if (dive != null) {
      parts.waterTempC = dive.waypoints
          .map((wp) => wp.temp)
          .where((t) => t != null)
          .firstOrNull;
    }
    return parts;
  }
  final suffix = pySuffix(path).toLowerCase();
  if (suffix == '.uddf') {
    return _uddfParts(bytes);
  }
  if (suffix == '.ssrf' || suffix == '.xml') {
    return _subsurfaceParts(bytes);
  }
  if (suffix == '.fit') {
    return _fitParts(bytes);
  }
  throw FormatException(
    "Unknown log format '${pySuffix(path)}' - use .uddf, .fit, .ssrf, a "
    'Shearwater/Subsurface .xml/.csv or a Suunto app .json export',
  );
}

/// A plan that reproduces the log at [path] (parsed as [dive] by the
/// matching parser): its gases, tanks, gas switches, GF, computer, start
/// time and thinned-out profile, with [base]'s settings for what the log
/// does not record. Throws a [FormatException] for a log whose values
/// cannot be a plan's.
DiveProfilePlan planFromLog(
  String path,
  Uint8List bytes,
  Dive dive, {
  DiveProfilePlan? base,
}) {
  final plan = DiveProfilePlan.fromJson((base ?? DiveProfilePlan()).toJson());
  final parts = loggedPlanParts(path, bytes, dive);

  final used = <String>{};
  final gases = <PlannedGas>[];
  final rename = <String, String>{};
  for (final logged in parts.gases) {
    final stripped = logged.name.pyStrip();
    final own = stripped.isEmpty ? 'Gas' : stripped;
    var name = own;
    for (var n = 2; used.contains(name); n++) {
      name = '$own $n';
    }
    used.add(name);
    rename[logged.name] = name;
    final size = logged.tankSizeL ?? 0.0;
    final start = logged.startPressureBar ?? 0.0;
    final fields = <String, dynamic>{
      'id': name,
      'gas_type': gasTypeFor(logged.o2Percent, logged.hePercent),
      'o2_percent': pyRoundTo(logged.o2Percent, 1),
      'he_percent': pyRoundTo(logged.hePercent, 1),
      'tank_ref': logged.tankRef,
      'diluent': logged.diluent,
      'tank_size_l': size != 0 ? size : 11.1,
      'start_pressure_bar': start != 0 ? pyRound(start).toDouble() : 207.0,
    };
    if (logged.sidemountPair) {
      // A left and right pair: this gas on the left, "<name> R" on the
      // right.
      for (final split in splitSidemountPair(
        fields,
        [
          for (final g in parts.gases) g.tankRef,
          for (final g in gases) g.tankRef,
        ],
        first: !gases.any((g) => (g.side ?? '').isNotEmpty),
        rightRef: logged.rightTankRef,
      )) {
        used.add(split['id'] as String);
        gases.add(PlannedGas.fromJson(split));
      }
    } else {
      gases.add(PlannedGas.fromJson(fields));
    }
  }
  if (gases.isEmpty) {
    gases.add(PlannedGas(id: 'Air'));
  }
  final switches = [
    for (final (t, g) in parts.switches)
      if (used.contains(rename[g] ?? g)) (t, rename[g] ?? g),
  ];
  plan
    ..gases = gases
    ..diveType = parts.diveType;
  if (plan.isCcr && !gases.any((g) => g.diluent)) {
    gases.first.diluent = true;
  }
  plan.waypoints = profileWaypoints(dive, switches, gases.first.id);

  // A gas first breathed after the deepest point is an ascent gas.
  if (plan.waypoints.isNotEmpty) {
    var deepest = plan.waypoints.first;
    for (final w in plan.waypoints) {
      if (w.depthM > deepest.depthM ||
          (w.depthM == deepest.depthM && w.runtimeSec < deepest.runtimeSec)) {
        deepest = w;
      }
    }
    final firstUse = <String, int>{};
    for (final w in plan.sortedWaypoints()) {
      firstUse.putIfAbsent(w.gasId, () => w.runtimeSec);
    }
    for (final g in gases) {
      if ((firstUse[g.id] ?? 0) > deepest.runtimeSec) {
        g.usePhase = 'ascent';
      }
    }
  }

  final gfLow = parts.gfLow ?? 0.0;
  final gfHigh = parts.gfHigh ?? 0.0;
  if (gfLow != 0 && gfHigh != 0 && gfLow <= gfHigh) {
    plan
      ..gfLow = gfLow
      ..gfHigh = gfHigh;
  }
  bool po2(double? v) => v != null && v != 0 && 0.5 <= v && v <= 2.0;
  if (po2(parts.maxPo2Bottom)) {
    plan.maxPo2Bottom = parts.maxPo2Bottom!;
  }
  if (po2(parts.maxPo2Deco)) {
    plan.maxPo2Deco = parts.maxPo2Deco!;
  }
  if (plan.isCcr) {
    _setpointsFromLog(plan, dive);
  }
  if ((parts.ccrO2TankSizeL ?? 0) != 0) {
    plan.ccrO2TankSizeL = parts.ccrO2TankSizeL!;
  }
  if ((parts.ccrO2StartPressureBar ?? 0) != 0) {
    plan.ccrO2StartPressureBar = parts.ccrO2StartPressureBar!;
  }
  final temp = parts.waterTempC;
  if (temp != null && -5 < temp && temp < 45) {
    plan.waterTempC = pyRoundTo(temp, 1);
  }

  final logName = dive.logFilename ?? '';
  if (logName.isNotEmpty) {
    final named = pyStem(logName).replaceAll('_', ' ');
    plan.name = named.isNotEmpty ? named : plan.name;
  }
  final ordered = _byTime(dive);
  final start = ordered.isNotEmpty && ordered.first.timeSinceStart < 0
      ? ordered.first.timestamp
      : dive.startTime;
  plan
    ..startTime = naive(
      start.year,
      start.month,
      start.day,
      start.hour,
      start.minute,
      start.second,
    )
    ..computer = computerLabelFor(dive, (base ?? DiveProfilePlan()).computer);
  final maxDepth = plan.waypoints.fold(0.0, (m, w) => pyMax(m, w.depthM));
  if (maxDepth > 0) {
    plan.maxDepthM = (maxDepth / 5.0).ceilToDouble() * 5;
  }
  final runtime = plan.waypoints.fold(
    0,
    (m, w) => w.runtimeSec > m ? w.runtimeSec : m,
  );
  if (runtime > 0) {
    plan.plannedRuntimeSec = (runtime / 300.0).ceil() * 300;
  }
  return plan;
}
