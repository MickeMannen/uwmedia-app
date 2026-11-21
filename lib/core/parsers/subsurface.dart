/// Subsurface XML logs (`.ssrf`, and the `.xml` export), ported from
/// `parsers/subsurface.py` of the Python app (spec §4.1).
///
/// Values the log does not carry, or that do not parse, are `null` here
/// where Python stores 0 (spec §10.8): a sample's depth and temperature, an
/// unreadable TTS or NDL, and the pressure of a cylinder with no reading.
library;

import 'dart:typed_data';

import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/deco/deco_engine.dart';
import 'package:uwmedia_app/core/deco/deco_pass.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/parsers/subsurface_text.dart';
import 'package:uwmedia_app/core/parsers/xml_query.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';
import 'package:xml/xml.dart';

class _Cylinder {
  _Cylinder({
    required this.index,
    required this.use,
    required this.description,
    required this.o2,
    required this.he,
    required this.startBar,
    required this.endBar,
    required this.sizeL,
  });

  final int index;

  /// "diluent" or "oxygen" on a rebreather dive.
  final String? use;
  final String? description;

  /// Percent.
  final double o2;
  final double he;
  final double? startBar;
  final double? endBar;

  /// Water capacity in litres (`size='12.0 l'`), when given.
  final double? sizeL;

  String get name => _isEmpty(description) ? 'Mix ${index + 1}' : description!;
}

final _litresText = RegExp(r'^\s*([0-9]*\.?[0-9]+)\s*l\s*$');

// A cylinder size as Subsurface writes it ("12.0 l"); null for none, 0 or
// another unit.
double? _litres(String? text) {
  final match = _litresText.firstMatch(text ?? '');
  final litres = match == null ? null : double.tryParse(match.group(1)!);
  return litres == null || litres <= 0 ? null : litres;
}

const Set<String> _loopModes = {'closedcircuit', 'semiclosedcircuit'};
final _gfInDecoModel = RegExp(r'GF\s*(\d+)\s*/\s*(\d+)');
final _digits = RegExp(r'^\d+$');

bool _isEmpty(String? text) => text == null || text.isEmpty;

// Elements in no namespace, as lxml's plain-name paths match them.
Iterable<XmlElement> _children(XmlElement parent, String name) =>
    parent.childElements.where((e) => lxmlTag(e) == name);

Iterable<XmlElement> _everywhere(XmlDocument document, String name) =>
    document.descendantElements.where((e) => lxmlTag(e) == name);

/// `float(text) if text else None`, `None` for what does not parse, with
/// "bar" taken off.
double? _bar(String? text) {
  final cleaned = (text ?? '').replaceAll('bar', '').pyStrip();
  return cleaned.isEmpty ? null : pyFloat(cleaned);
}

/// The dives of a Subsurface XML file; none when it is not well-formed
/// XML. A dive without a date and time, a dive computer or samples is left
/// out. [tanks] names the cylinders by their sensor.
List<Dive> parseSubsurface(Uint8List bytes, String path, {TankConfig? tanks}) {
  final tankConfig = tanks ?? TankConfig();
  final XmlDocument document;
  try {
    document = parseXmlBytes(bytes);
  } on FormatException {
    return [];
  } on XmlException {
    return [];
  }
  final dives = <Dive>[];

  // 1. Dive sites by uuid.
  final sites = <String?, (double?, double?)>{};
  for (final site in _everywhere(document, 'site')) {
    double? lat;
    double? lon;
    final gps = site.getAttribute('gps');
    if (!_isEmpty(gps)) {
      final parts = gps!.pyStrip().split(RegExp(r'\s+'));
      if (parts.length == 2) {
        // Python reads the latitude first and keeps it when the longitude
        // then fails.
        lat = pyFloat(parts[0]);
        if (lat != null) {
          lon = pyFloat(parts[1]);
        }
      }
    }
    sites[site.getAttribute('uuid')] = (lat, lon);
  }

  // 2. The dives, wherever they are in the file.
  for (final diveElem in _everywhere(document, 'dive')) {
    final dateStr = diveElem.getAttribute('date');
    final timeStr = diveElem.getAttribute('time');
    if (_isEmpty(dateStr) || _isEmpty(timeStr)) {
      continue;
    }
    final startTime = pyStrptime('$dateStr $timeStr', '%Y-%m-%d %H:%M:%S');
    if (startTime == null) {
      continue;
    }

    final durationStr = diveElem.getAttribute('duration');
    final durationSeconds = _isEmpty(durationStr)
        ? null
        : parseTimeStr(durationStr!);

    final siteId = diveElem.getAttribute('divesiteid');
    final (lat, lon) = !_isEmpty(siteId) && sites.containsKey(siteId)
        ? sites[siteId]!
        : (null, null);

    final cylinders = <_Cylinder>[];
    for (final cyl in _children(diveElem, 'cylinder')) {
      final start = cyl.getAttribute('start');
      final end = cyl.getAttribute('end');
      cylinders.add(
        _Cylinder(
          index: cylinders.length,
          use: cyl.getAttribute('use'),
          description: cyl.getAttribute('description'),
          o2: parseGasPercent(cyl.getAttribute('o2'), 21.0),
          he: parseGasPercent(cyl.getAttribute('he'), 0.0),
          // An unreadable pressure is no pressure; Python has 0.0.
          startBar: _isEmpty(start) ? null : tryParsePressureStr(start!),
          endBar: _isEmpty(end) ? null : tryParsePressureStr(end!),
          sizeL: _litres(cyl.getAttribute('size')),
        ),
      );
    }

    final computer = _children(diveElem, 'divecomputer').firstOrNull;
    if (computer == null) {
      continue;
    }

    final device = computer.getAttribute('model');
    String? manufacturer;
    if (!_isEmpty(device)) {
      if (device!.contains('Garmin')) {
        manufacturer = 'Garmin';
      } else if (device.contains('Shearwater')) {
        manufacturer = 'Shearwater';
      }
    }

    final extradata = <String, String?>{};
    for (final ed in _children(computer, 'extradata')) {
      final key = ed.getAttribute('key');
      if (!_isEmpty(key)) {
        extradata[key!] = ed.getAttribute('value');
      }
    }

    // The file's own gradient factors ("Deco model" extradata, "GF 40/85")
    // drive the recompute.
    (double, double)? fileGf;
    final gfMatch = _gfInDecoModel.firstMatch(extradata['Deco model'] ?? '');
    if (gfMatch != null) {
      // Digits beyond 64 bits are no gradient factor either.
      final low = (int.tryParse(gfMatch.group(1)!) ?? 0) / 100.0;
      final high = (int.tryParse(gfMatch.group(2)!) ?? 0) / 100.0;
      if (0 < low && low <= high && high <= 1.0) {
        fileGf = (low, high);
      }
    }
    // A log that records its own stopdepth says "no stop" by leaving it
    // out.
    final fileLogsStops = _children(
      computer,
      'sample',
    ).any((sample) => sample.getAttribute('stopdepth') != null);

    // Tank keys: the sensor's name, else the cylinder's description, else
    // its number.
    final tankKeys = <String>[];
    for (var idx = 0; idx < cylinders.length; idx++) {
      final sensorId = extradata['Sensor ${idx + 1}'];
      final String serial;
      if (!_isEmpty(sensorId)) {
        serial = sensorId!;
      } else {
        final description = cylinders[idx].description;
        serial = _isEmpty(description) ? '${idx + 1}' : description!;
      }
      var key = tankConfig.mapTankName(serial);
      if (tankKeys.contains(key)) {
        // Two cylinders with one description stay two tanks.
        key = '$key (${idx + 1})';
      }
      tankKeys.add(key);
    }

    // A rebreather dive (dctype CCR / SCR): which cylinder is breathed
    // (gaschange events) and the circuit (modechange events, else a switch
    // to a cylinder that is neither diluent nor oxygen is a bailout).
    final dctype = (computer.getAttribute('dctype') ?? '').toUpperCase();
    final loopMode = switch (dctype) {
      'CCR' => 'closedcircuit',
      'SCR' => 'semiclosedcircuit',
      _ => null,
    };
    final events = <(int, XmlElement)>[];
    for (final ev in _children(computer, 'event')) {
      final name = ev.getAttribute('name');
      if (!_isEmpty(ev.getAttribute('time')) &&
          (name == 'gaschange' || name == 'modechange')) {
        events.add((parseTimeStr(ev.getAttribute('time')!), ev));
      }
    }
    // By time, events of one second in the file's order.
    final order = List<int>.generate(events.length, (i) => i)
      ..sort((a, b) {
        final byTime = events[a].$1.compareTo(events[b].$1);
        return byTime != 0 ? byTime : a.compareTo(b);
      });
    final sortedEvents = [for (final i in order) events[i]];
    final hasModechange = sortedEvents.any(
      (event) => event.$2.getAttribute('name') == 'modechange',
    );
    final diluents = [
      for (final c in cylinders)
        if (c.use == 'diluent') c.index,
    ];
    int? breathedCyl = cylinders.isEmpty
        ? null
        : (diluents.isEmpty ? 0 : diluents.first);
    int? diluentCyl = loopMode != null && diluents.isNotEmpty
        ? diluents.first
        : null;
    var divemodeNow = loopMode;
    var eventPtr = 0;

    // The water temperature of the dive, until a sample has its own.
    double? currentTemp;
    final waterTemp = _children(
      computer,
      'temperature',
    ).firstOrNull?.getAttribute('water');
    if (!_isEmpty(waterTemp)) {
      currentTemp = tryParseTempStr(waterTemp!);
    }

    final waypoints = <Waypoint>[];
    var currentMaxDepth = 0.0;
    double? lastPo2;
    double? lastSetpoint;
    double? lastDcPo2;
    final lastCells = <int, double>{};
    // Whether a cylinder ever had a live per-sample pressure. One that has
    // only the dive's start and end pressure gets a straight line between
    // them below.
    final livePressureSeen = List<bool>.filled(cylinders.length, false);

    // Each cylinder starts at its own starting pressure where known.
    final activeTanks = <String, TankData>{
      for (final cyl in cylinders)
        tankKeys[cyl.index]: TankData(
          pressureBar: cyl.startBar,
          o2Percent: cyl.o2,
          hePercent: cyl.he,
          name: cyl.name,
        ),
    };

    var lastSeconds = -1;
    for (final sample in _children(computer, 'sample')) {
      final timeVal = sample.getAttribute('time');
      if (_isEmpty(timeVal)) {
        continue;
      }
      final seconds = parseTimeStr(timeVal!);
      if (seconds < lastSeconds) {
        // A spurious wrap-around sample at the end.
        continue;
      }
      lastSeconds = seconds;
      final timestamp = startTime.add(Duration(seconds: seconds));

      final depthVal = sample.getAttribute('depth');
      final depth = _isEmpty(depthVal) ? null : tryParseDepthStr(depthVal!);
      if (depth != null && depth > currentMaxDepth) {
        currentMaxDepth = depth;
      }

      final tempVal = sample.getAttribute('temp');
      if (!_isEmpty(tempVal)) {
        currentTemp = tryParseTempStr(tempVal!);
      }

      // Gas and circuit changes up to this sample.
      while (eventPtr < sortedEvents.length &&
          sortedEvents[eventPtr].$1 <= seconds) {
        final ev = sortedEvents[eventPtr].$2;
        eventPtr += 1;
        if (ev.getAttribute('name') == 'modechange' && loopMode != null) {
          final mode = (ev.getAttribute('divemode') ?? '').toUpperCase();
          divemodeNow = mode == 'CCR' || mode == 'SCR' || mode == 'PSCR'
              ? loopMode
              : 'opencircuit';
          continue;
        }
        final cylAttr = ev.getAttribute('cylinder');
        if (cylAttr != null && _digits.hasMatch(cylAttr)) {
          final index = int.tryParse(cylAttr);
          if (index != null && index < cylinders.length) {
            breathedCyl = index;
          }
        }
        if (loopMode != null && !hasModechange && breathedCyl != null) {
          final use = cylinders[breathedCyl].use;
          if (use == 'diluent') {
            divemodeNow = loopMode;
          } else if (use != 'oxygen') {
            divemodeNow = 'opencircuit';
          }
        }
      }
      final onLoop = _loopModes.contains(divemodeNow);
      if (onLoop &&
          breathedCyl != null &&
          cylinders[breathedCyl].use == 'diluent') {
        diluentCyl = breathedCyl;
      }

      // PO2: on the loop Subsurface's po2= is the setpoint and
      // dc_supplied_ppo2 the computer's own reading.
      final po2Val = sample.getAttribute('po2');
      double? setpoint;
      if (!_isEmpty(po2Val)) {
        final value = pyFloat(po2Val!.replaceAll('bar', '').pyStrip());
        if (value != null) {
          lastPo2 = pyRoundTo(value, 2);
        }
      }
      if (onLoop) {
        // A po2 of 0.0 bar (some OSTC samples) is no setpoint.
        if (!_isEmpty(po2Val) && lastPo2 != null && lastPo2 != 0) {
          lastSetpoint = lastPo2;
        }
        setpoint = lastSetpoint;
        final dcPo2 = _bar(sample.getAttribute('dc_supplied_ppo2'));
        if (dcPo2 != null) {
          lastDcPo2 = pyRoundTo(dcPo2, 2);
        }
      }
      final po2 = onLoop && lastDcPo2 != null ? lastDcPo2 : lastPo2;

      // A rebreather's O2 cells, held between the samples that log them.
      for (var n = 1; n <= 3; n++) {
        final cell = _bar(sample.getAttribute('sensor$n'));
        if (cell != null) {
          lastCells[n] = pyRoundTo(cell, 2);
        }
      }

      // An unreadable TTS or NDL is none; Python has 0, which reads as
      // "in deco".
      int? time(String name) {
        final value = sample.getAttribute(name);
        return _isEmpty(value) || !isTimeStr(value!)
            ? null
            : parseTimeStr(value);
      }

      final tts = time('tts');
      final ndl = time('ndl');

      // The deco stop: the file's own where it logs one.
      final stopDepthVal = sample.getAttribute('stopdepth');
      // An unreadable stop depth is "no stop", as in Python.
      var loggedStopDepth = _isEmpty(stopDepthVal)
          ? null
          : parseDepthStr(stopDepthVal!);
      // An unreadable stop time is 0, as in Python: unlike a TTS or an NDL
      // of 0 it claims nothing.
      final stopTimeVal = sample.getAttribute('stoptime');
      var loggedStopTime = _isEmpty(stopTimeVal)
          ? null
          : parseTimeStr(stopTimeVal!);
      if (loggedStopDepth == null &&
          (fileLogsStops || (ndl != null && ndl > 0))) {
        loggedStopDepth = 0.0;
        loggedStopTime = 0;
      }

      // Cylinder pressures.
      for (final cyl in cylinders) {
        final pressure = sample.getAttribute('pressure${cyl.index}');
        if (pressure != null) {
          livePressureSeen[cyl.index] = true;
          activeTanks[tankKeys[cyl.index]] = TankData(
            pressureBar: tryParsePressureStr(pressure),
            o2Percent: cyl.o2,
            hePercent: cyl.he,
            name: cyl.name,
          );
        }
      }

      final gf = _optionalFloat(sample.getAttribute('gf'));
      final battery = _optionalFloat(sample.getAttribute('battery'));

      // The breathed gas and the diluent, apart from the tanks; nothing
      // for a dive with neither events nor a loop (the first tank's mix is
      // the gas then).
      final breathed = sortedEvents.isNotEmpty || loopMode != null
          ? breathedCyl
          : null;
      final breathedMix = breathed != null && breathed < cylinders.length
          ? cylinders[breathed]
          : null;
      final diluentMix = diluentCyl != null && diluentCyl < cylinders.length
          ? cylinders[diluentCyl]
          : null;

      waypoints.add(
        Waypoint(
          timestamp: timestamp,
          depth: depth,
          maxDepth: currentMaxDepth,
          temp: currentTemp,
          ndl: ndl,
          tts: tts,
          po2: po2,
          po2_1: lastCells[1],
          po2_2: lastCells[2],
          po2_3: lastCells[3],
          divemode: divemodeNow,
          setpoint: setpoint,
          gasO2Percent: breathedMix?.o2,
          gasHePercent: breathedMix?.he,
          diluentO2Percent: diluentMix?.o2,
          diluentHePercent: diluentMix?.he,
          gf: gf,
          battery: battery,
          timeSinceStart: seconds,
          diveTime: seconds,
          // Each waypoint its own copy of the readings; the TankData
          // objects are replaced, never changed, above.
          tanks: activeTanks,
          decoStopDepth: loggedStopDepth,
          nextStopTime: loggedStopTime,
        ),
      );
    }

    if (waypoints.isEmpty) {
      continue;
    }

    // A file that lists a cylinder without oxygen gets no recompute at
    // all: Python's MOD for it divides by zero and the whole step is given
    // up (spec §10.16). The Subsurface copy of the pass has no
    // direct-ascent TTS for a file that logs its stops.
    if (cylinders.any((cyl) => cyl.o2 == 0)) {
      fillSacWhenNoneLogged(waypoints);
    } else {
      applyDecoAndGas(waypoints, [
        for (final cyl in cylinders)
          GasDefinition(
            _isEmpty(cyl.description) ? 'Mix ${cyl.index}' : cyl.description!,
            cyl.o2 / 100.0,
            cyl.he / 100.0,
            pyMax(0, ((1.4 / (cyl.o2 / 100.0)) - 1.0) * 10.0),
          ),
      ], fileGf: fileGf);
    }

    // A cylinder with no live pressure anywhere in the dive goes in a
    // straight line from its start to its end pressure.
    final lastSecond = waypoints.last.timeSinceStart;
    final totalSeconds = lastSecond == 0 ? 1 : lastSecond;
    for (final cyl in cylinders) {
      final start = cyl.startBar;
      final end = cyl.endBar;
      if (livePressureSeen[cyl.index] || start == null || end == null) {
        continue;
      }
      final key = tankKeys[cyl.index];
      for (final wp in waypoints) {
        final frac = pyMin(1.0, pyMax(0.0, wp.timeSinceStart / totalSeconds));
        final existing = wp.tanks[key];
        if (existing != null) {
          wp.tanks[key] = TankData(
            pressureBar: start + (end - start) * frac,
            o2Percent: existing.o2Percent,
            hePercent: existing.hePercent,
            name: existing.name,
            mode: existing.mode,
            enabled: existing.enabled,
          );
        }
      }
    }

    final endTime = waypoints.last.timestamp;
    dives.add(
      Dive(
        startTime: startTime,
        endTime: endTime,
        waypoints: waypoints,
        device: device,
        manufactor: manufacturer,
        gfLow: fileGf == null ? null : pyRound(fileGf.$1 * 100),
        gfHigh: fileGf == null ? null : pyRound(fileGf.$2 * 100),
        startLatitude: lat,
        startLongitude: lon,
        // The dive's own duration, else from the samples (also for a
        // duration of 0).
        durationSeconds: durationSeconds == null || durationSeconds == 0
            ? endTime.difference(startTime).inSeconds
            : durationSeconds,
        logFilename: pyFileName(path),
        logPath: path,
        tankVolumesL: {
          for (final (idx, cyl) in cylinders.indexed)
            if (cyl.sizeL != null) tankKeys[idx]: cyl.sizeL!,
        },
      ),
    );
  }

  return dives;
}

/// An optional sample value; empty or unreadable gives `null`.
double? _optionalFloat(String? value) =>
    _isEmpty(value) ? null : pyFloat(value);
