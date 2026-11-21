/// The Dive Profile Builder's logs as text (Python
/// `parsers/uddf_writer.py` and `parsers/subsurface_writer.py`): a
/// simulated dive written the way a Shearwater Cloud UDDF export and a
/// Subsurface divelog have it, closely enough that the app's own parsers
/// read them back. The text is what lxml writes, byte for byte.
library;

import 'dart:convert';

import 'package:uwmedia_app/core/plan/dive_computers.dart';
import 'package:uwmedia_app/core/plan/dive_plan.dart';
import 'package:uwmedia_app/core/plan/dive_plan_engine.dart';
import 'package:uwmedia_app/core/plan/plan_embed.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';

const uddfNamespace = 'http://www.streit.cc/uddf/3.2/';

/// "99+": how an NDL without limit is logged.
const ndlCapSec = 99 * 60;

/// The mix a CCR dive's oxygen cylinder holds (never breathed: no gas
/// switch names it).
const ccrO2MixId = 'ccr_o2';

/// Subsurface's own event type number for a gas change.
const gasChangeEventType = 25;

class _Node {
  _Node(this.tag, {this.text, Map<String, String>? attrs})
    : attrs = attrs ?? {};

  final String tag;
  final String? text;
  final Map<String, String> attrs;
  final List<_Node> children = [];

  _Node add(String tag, {Object? text, Map<String, Object>? attrs}) {
    final node = _Node(
      tag,
      text: text == null ? null : _text(text),
      attrs: {
        for (final MapEntry(:key, :value) in (attrs ?? const {}).entries)
          key: _text(value),
      },
    );
    children.add(node);
    return node;
  }

  // lxml's pretty-printed form: two spaces a level, an element's text on
  // its own line, an empty element closed in its tag.
  void write(StringBuffer out, int depth) {
    final indent = '  ' * depth;
    out.write('$indent<$tag');
    attrs.forEach((key, value) => out.write(' $key="${_escape(value, true)}"'));
    if (children.isEmpty) {
      out.writeln(text == null ? '/>' : '>${_escape(text!, false)}</$tag>');
      return;
    }
    out.writeln('>');
    for (final child in children) {
      child.write(out, depth + 1);
    }
    out.writeln('$indent</$tag>');
  }
}

// Python's `str()` of what the writers put into a file.
String _text(Object value) => value is double ? pyFloatRepr(value) : '$value';

final _notXml = RegExp('[\x00-\x08\x0B\x0C\x0E-\x1F\uFFFE\uFFFF]');

String _escape(String text, bool attribute) {
  if (_notXml.hasMatch(text)) {
    // lxml: "All strings must be XML compatible".
    throw FormatException('A character XML cannot hold', text);
  }
  var out = text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('\r', '&#13;');
  if (attribute) {
    out = out
        .replaceAll('"', '&quot;')
        .replaceAll('\n', '&#10;')
        .replaceAll('\t', '&#9;');
  }
  return out;
}

/// The dive's local start for a written log: [startTime], else the plan's
/// own, else [now]; without a fraction of a second.
DateTime logStartTime(
  DiveProfilePlan plan, {
  DateTime? startTime,
  required DateTime now,
}) {
  final when = startTime ?? plan.startTime ?? now;
  assert(when.isUtc, naiveTimeMessage);
  return naive(
    when.year,
    when.month,
    when.day,
    when.hour,
    when.minute,
    when.second,
  );
}

String _two(num value) => pyRound(value.toDouble()).toString().padLeft(2, '0');

String _fixed(double value, int decimals) => pyFormatFixed(value, decimals);

int _pascal(double bar) => (bar * 100000).truncate();

/// The dive as a UDDF file's text. [samples] come from `simulate`. [now]
/// is the local time of writing and [utcOffsetMinutes] the machine's UTC
/// offset at the dive's start: the builder has no timezone of its own, so
/// a log is written as if dived where the machine is.
///
/// Every waypoint lists every tank's pressure, so both sidemount tanks or
/// a rebreather's oxygen and diluent cylinders all come through. The
/// device is the plan's computer; the generator's manufacturer is the
/// computer's too, since the UDDF parser reads a dive's manufacturer
/// there. Throws an [ArgumentError] without samples.
String uddfText(
  DiveProfilePlan plan,
  List<SimulatedSample> samples, {
  DateTime? startTime,
  required DateTime now,
  required int utcOffsetMinutes,
}) {
  if (samples.isEmpty) {
    // Python: "… run utils.dive_plan_engine.simulate() first".
    throw ArgumentError('No samples to write - simulate the plan first');
  }
  final start = logStartTime(plan, startTime: startTime, now: now);
  final computer = diveComputer(plan.computer);
  final serial = plan.computerSerial.isEmpty ? '0' : plan.computerSerial;

  final root = _Node(
    'uddf',
    attrs: {'xmlns': uddfNamespace, 'version': '3.2.3'},
  );
  final generator = root.add('generator')
    ..add('name', text: generatorName)
    ..add('type', text: 'logbook');
  generator
      .add('manufacturer', attrs: {'id': computer.manufacturer})
      .add('name', text: computer.manufacturer);
  generator.add(
    'datetime',
    text: '${formatNaive(logStartTime(plan, startTime: now, now: now))}Z',
  );

  final equipment = root.add('diver').add('owner').add('equipment');
  final divecomputer = equipment.add(
    'divecomputer',
    attrs: {'id': '${computer.model}_$serial'},
  )..add('name', text: computer.model);
  divecomputer
      .add('manufacturer', attrs: {'id': computer.manufacturer})
      .add('name', text: computer.manufacturer);
  divecomputer
    ..add('model', text: computer.model)
    ..add('serialnumber', text: serial);
  if (plan.isCcr) {
    // The rebreather's three cells, which measuredpo2 refers to.
    final rebreather = equipment.add('rebreather', attrs: {'id': 'rebreather'})
      ..add('name', text: 'Rebreather');
    for (var n = 1; n <= 3; n++) {
      rebreather.add('o2sensor', attrs: {'id': 'cell$n'});
    }
  }

  final gasDefinitions = root.add('gasdefinitions');
  final mixIds = <String, String>{};
  for (final gas in plan.breathedGases()) {
    final mixId = '${gas.id}:${_two(gas.o2Percent)}/${_two(gas.hePercent)}';
    mixIds[gas.id] = mixId;
    gasDefinitions.add('mix', attrs: {'id': mixId})
      ..add('name', text: gas.id)
      ..add('o2', text: pyRoundTo(gas.fO2, 4))
      ..add('he', text: pyRoundTo(gas.fHe, 4))
      ..add(
        'maximumpo2',
        text: plan.onLoop(gas) ? plan.ccrHighSetpoint : plan.maxPo2Bottom,
      );
  }
  if (plan.isCcr) {
    // The oxygen cylinder's own mix, so that its tank says what it holds.
    gasDefinitions.add('mix', attrs: {'id': ccrO2MixId})
      ..add('name', text: 'O2')
      ..add('o2', text: 1.0)
      ..add('he', text: 0.0);
  }

  root.add('decomodel').add('buehlmann', attrs: {'id': 'zhl16c'})
    ..add('gradientfactorhigh', text: plan.gfHigh.truncate())
    ..add('gradientfactorlow', text: plan.gfLow.truncate());

  final dive = root
      .add('profiledata')
      .add('repetitiongroup')
      .add('dive', attrs: {'id': '1'});
  final before = dive.add('informationbeforedive')
    ..add('datetime', text: '${formatNaive(start)}Z');
  final tanks = plan.tankSpecs();
  final endPressures = samples.last.tankPressures;
  for (final tank in tanks) {
    final data = before.add('tankdata', attrs: {'id': tank.ref});
    if (tank.gasId != null) {
      data.add('link', attrs: {'ref': mixIds[tank.gasId]!});
    } else if (tank.role == 'oxygen') {
      data.add('link', attrs: {'ref': ccrO2MixId});
    }
    data
      // UDDF volumes are in cubic metres.
      ..add('tankvolume', text: pyRoundTo(tank.sizeL / 1000.0, 4))
      ..add('tankpressurebegin', text: _pascal(tank.startPressureBar))
      ..add(
        'tankpressureend',
        text: _pascal(endPressures[tank.ref] ?? tank.startPressureBar),
      );
  }

  final samplesNode = dive.add('samples');
  final tempK = pyRoundTo(plan.waterTempC + 273.15, 2);
  String? lastGas;
  for (final s in samples) {
    final wp = samplesNode.add('waypoint');
    if (s.gasId != lastGas) {
      wp.add('switchmix', attrs: {'ref': mixIds[s.gasId]!});
      lastGas = s.gasId;
    }
    wp
      ..add('depth', text: pyRoundTo(s.depthM, 2))
      ..add('divetime', text: s.timeSec)
      ..add('temperature', text: tempK);
    for (final tank in tanks) {
      final pressure = s.tankPressures[tank.ref];
      if (pressure != null) {
        wp.add(
          'tankpressure',
          text: _pascal(pressure),
          attrs: {'ref': tank.ref},
        );
      }
    }
    wp.add('calculatedpo2', text: pyRoundTo(s.po2, 2));
    if (s.divemode == 'closedcircuit' && s.setpoint != null) {
      wp.add('setpo2', text: s.setpoint, attrs: {'setby': 'computer'});
    }
    for (final (n, cell) in s.cells.indexed) {
      wp.add('measuredpo2', text: cell, attrs: {'ref': 'cell${n + 1}'});
    }
    if (s.cnsPct != 0) {
      wp.add('cns', text: s.cnsPct.truncate());
    }
    wp.add('divemode', attrs: {'type': s.divemode});
    if (s.ceilingM > 0) {
      wp.add(
        'decostop',
        attrs: {
          'kind': 'mandatory',
          'decodepth': pyRoundTo(s.stopDepthM, 1),
          'duration': s.stopDurationSec,
        },
      );
    } else {
      // An NDL without limit is written as the 99-minute cap, so that the
      // sample still says "no stop owed".
      wp.add('nodecotime', text: s.ndlSec ?? ndlCapSec);
    }
    // Time to surface: not a UDDF element (Shearwater exports have none);
    // the app's own, which its UDDF parser prefers to working it out.
    wp.add('tts', text: s.ttsSec);
  }

  // Read back as the dive's timezone by the UDDF parser: minutes, a child
  // of the dive.
  dive.add('timezone', text: utcOffsetMinutes);
  // The plan itself, so that the builder can open this file again.
  dive
      .add('applicationdata')
      .add('uwmedia')
      .add('plan', text: planToJson(plan));

  final out = StringBuffer("<?xml version='1.0' encoding='UTF-8'?>\n");
  root.write(out, 0);
  return out.toString();
}

String _mmss(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')} min';
}

final List<int> _crcTable = [
  for (var n = 0; n < 256; n++)
    Iterable<int>.generate(8)
        .fold(n, (c, _) => c.isOdd ? 0xEDB88320 ^ (c >> 1) : c >> 1),
];

// An id of eight hex digits that is the same every time, the form
// Subsurface uses for a device and a dive: the CRC-32 of the text.
String _hexId(String text) {
  var crc = 0xFFFFFFFF;
  for (final byte in utf8.encode(text)) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
}

/// The dive as a Subsurface divelog's text (.ssrf). One cylinder per tank
/// of the plan, described by its tank reference so that the parser keys
/// the tank pressures as the other formats do; every sample has every
/// cylinder's pressure. Gas and sidemount tank switches are gaschange
/// events; a CCR dive is marked as one, with modechange events around a
/// bailout, like Subsurface's own CCR logs. Throws an [ArgumentError]
/// without samples.
String subsurfaceText(
  DiveProfilePlan plan,
  List<SimulatedSample> samples, {
  DateTime? startTime,
  required DateTime now,
}) {
  if (samples.isEmpty) {
    // Python: "… run utils.dive_plan_engine.simulate() first".
    throw ArgumentError('No samples to write - simulate the plan first');
  }
  final start = logStartTime(plan, startTime: startTime, now: now);
  final computer = diveComputer(plan.computer);
  final serial = plan.computerSerial.isEmpty ? '0' : plan.computerSerial;

  final root =
      _Node('divelog', attrs: {'program': 'subsurface', 'version': '3'})
        ..add('settings')
        ..add('divesites');
  final dive = root
      .add('dives')
      .add(
        'dive',
        attrs: {
          'number': '1',
          'date': pyStrftime(start, '%Y-%m-%d'),
          'time': pyStrftime(start, '%H:%M:%S'),
          'duration': _mmss(samples.last.timeSec),
        },
      );
  dive.add(
    'notes',
    text:
        '${plan.name} - synthetic profile from the $subsurfaceNotesMark, not '
        'a real dive',
  );

  final tanks = plan.tankSpecs();
  final tankIndex = {for (final (i, t) in tanks.indexed) t.ref: i};
  final endPressures = samples.last.tankPressures;
  for (final tank in tanks) {
    dive.add(
      'cylinder',
      attrs: {
        'size': '${_fixed(tank.sizeL, 1)} l',
        'workpressure': '${_fixed(tank.startPressureBar, 1)} bar',
        'description': tank.ref,
        'o2': '${_fixed(tank.o2Percent, 1)}%',
        if (tank.hePercent != 0) 'he': '${_fixed(tank.hePercent, 1)}%',
        'start': '${_fixed(tank.startPressureBar, 1)} bar',
        'end':
            '${_fixed(endPressures[tank.ref] ?? tank.startPressureBar, 1)} bar',
        if (tank.role != 'oc') 'use': tank.role,
      },
    );
  }

  final device = '${computer.label}_$serial';
  final divecomputer = dive.add(
    'divecomputer',
    attrs: {
      'model': computer.label,
      'deviceid': _hexId(device),
      'diveid': _hexId('${device}_${formatNaive(start)}'),
      if (plan.isCcr) ...{'dctype': 'CCR', 'no_o2sensors': '3'},
    },
  );
  final depths = [for (final s in samples) s.depthM];
  divecomputer
    ..add(
      'depth',
      attrs: {
        'max': '${_fixed(depths.reduce(pyMax), 1)} m',
        'mean': '${_fixed(pySum(depths) / depths.length, 3)} m',
      },
    )
    ..add('temperature', attrs: {'water': '${_fixed(plan.waterTempC, 1)} C'})
    ..add('extradata', attrs: {'key': 'Serial', 'value': serial})
    ..add(
      'extradata',
      attrs: {
        'key': 'Deco model',
        'value': 'GF ${pyFormatG(plan.gfLow)}/${pyFormatG(plan.gfHigh)}',
      },
    )
    // The plan itself, so that the builder can open this file again.
    ..add(
      'extradata',
      attrs: {'key': subsurfacePlanKey, 'value': planToJson(plan)},
    );

  String? lastTank;
  String? lastMode;
  for (final (i, s) in samples.indexed) {
    if (plan.isCcr && s.divemode != lastMode) {
      if (lastMode != null) {
        divecomputer.add(
          'event',
          attrs: {
            'time': _mmss(s.timeSec),
            'type': '8',
            'name': 'modechange',
            'divemode': s.divemode == 'closedcircuit' ? 'CCR' : 'OC',
          },
        );
      }
      lastMode = s.divemode;
    }
    if (s.tankRef != lastTank) {
      final index = tankIndex[s.tankRef]!;
      divecomputer.add(
        'event',
        attrs: {
          'time': _mmss(s.timeSec),
          'type': '$gasChangeEventType',
          'flags': '${index + 1}',
          'name': 'gaschange',
          'cylinder': '$index',
        },
      );
      lastTank = s.tankRef;
    }
    divecomputer.add(
      'sample',
      attrs: {
        'time': _mmss(s.timeSec),
        'depth': '${_fixed(s.depthM, 2)} m',
        if (i == 0) 'temp': '${_fixed(plan.waterTempC, 1)} C',
        for (final tank in tanks)
          if (s.tankPressures[tank.ref] case final double pressure)
            'pressure${tankIndex[tank.ref]}': '${_fixed(pressure, 1)} bar',
        if (s.ceilingM > 0) ...{
          'in_deco': '1',
          'stopdepth': '${_fixed(s.stopDepthM, 1)} m',
          'stoptime': _mmss(s.stopDurationSec),
        } else
          'ndl': _mmss(s.ndlSec ?? ndlCapSec),
        'tts': _mmss(s.ttsSec),
        'cns': '${s.cnsPct.truncate()}%',
        // On the loop Subsurface's po2 is the setpoint, the cells are
        // sensorN and the computer's own reading dc_supplied_ppo2.
        'po2': '${_fixed(s.setpoint ?? s.po2, 2)} bar',
        for (final (n, cell) in s.cells.indexed)
          'sensor${n + 1}': '${_fixed(cell, 2)} bar',
        if (s.cells.isNotEmpty) 'dc_supplied_ppo2': '${_fixed(s.po2, 2)} bar',
      },
    );
  }

  final out = StringBuffer();
  root.write(out, 0);
  return out.toString();
}
