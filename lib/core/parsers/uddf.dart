/// UDDF logs (Shearwater Cloud, APD, the app's own builder and others),
/// ported from `parsers/uddf.py` of the Python app (spec §4.1). Elements
/// are found by their local name, whatever namespace the file uses.
///
/// Not ported: `update_timezone`, which rewrites the user's log; the port
/// keeps a timezone offset in the app's own state (spec §10.11).
library;

import 'dart:typed_data';

import 'package:uwmedia_app/core/deco/deco_engine.dart';
import 'package:uwmedia_app/core/deco/deco_pass.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/parsers/xml_query.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';
import 'package:xml/xml.dart';

/// The Shearwater app ("Shearwater Cloud Desktop") writes a tank pressure
/// it does not know as 0, and a transmitter's status word (no reading, no
/// signal) as a pressure masked to 12 bits of 2 psi, about 564 bar. On its
/// files a tank pressure at or above this is no reading.
const String shearwaterAppGenerator = 'shearwater cloud';
const double shearwaterStatusBar = 0xFF0 * 2 / 14.5037738;

/// How many O2 cells a waypoint holds (`po2_1..3`). APD's Inspiration logs
/// both controllers' readings of its three cells as six o2sensors; the
/// first controller's three are the cells.
const int _cellCount = 3;

const Set<String> _loopModes = {'closedcircuit', 'semiclosedcircuit'};

class _Mix {
  const _Mix(this.name, this.o2, this.he);

  final String? name;

  /// Percent.
  final double o2;
  final double he;
}

const _Mix _air = _Mix('AIR', 21.0, 0.0);

/// Stands in for the name of a mix that has neither a name nor an id.
const String _unnamedGas = '\u0000unnamed';

/// A sample's number, or `null` when it is empty or unreadable: one bad
/// value is skipped instead of failing the whole log.
double? _number(String text) => text.isEmpty ? null : pyFloat(text);

/// Python `int(float(text))`: towards zero; `null` for what is no number
/// (also NaN, which Python refuses to turn into an int) and for a number
/// of seconds or percent no dive has (infinite or beyond 32 bits, on which
/// Python fails or never finishes; spec §10.18).
int? _wholeNumber(String text) => _whole(_number(text));

int? _whole(double? value) =>
    value == null || !value.isFinite || value.abs() >= 2147483648.0
    ? null
    : value.toInt();

/// A waypoint PO2 in bar. UDDF says pascal (APD writes 70000.0 for 0.7
/// bar), but the Shearwater app and the app's own writer write bar; no PO2
/// is anywhere near 10 bar, so a larger value is pascal.
double? _po2Bar(String text) {
  final value = _number(text);
  if (value == null) {
    return null;
  }
  return pyRoundTo(value > 10 ? value / 100000.0 : value, 2);
}

/// The dives of a UDDF file; none when it is not well-formed XML. A dive
/// without a usable start time, or without samples, is left out.
///
/// Throws a [FormatException] for a gas mix whose O2 or He fraction is not
/// a number, as Python lets that error out.
List<Dive> parseUddf(Uint8List bytes, String path) {
  final XmlDocument document;
  try {
    document = parseXmlBytes(bytes);
  } on FormatException {
    return [];
  } on XmlException {
    return [];
  }
  final root = document.rootElement;
  final dives = <Dive>[];

  // 1. Global metadata.
  final deviceName = stringValue(firstByPath(root, ['divecomputer', 'name']));
  final manufacturer = stringValue(
    firstByPath(root, ['generator', 'manufacturer', 'name']),
  );
  String generator = '';
  for (final element in childrenNamed(root, 'generator')) {
    final name = childrenNamed(element, 'name').firstOrNull;
    if (name != null) {
      generator = name.innerText.pyStrip();
      break;
    }
  }
  final shearwaterApp = generator.toLowerCase().startsWith(
    shearwaterAppGenerator,
  );

  // A rebreather's O2 cells: measuredpo2 (or APD's ppo2) refs name an
  // o2sensor; a cell's number is the o2sensor's place in the file.
  final cellOf = <String, int>{};
  var sensorIndex = 0;
  for (final sensor in descendantsNamed(root, 'o2sensor')) {
    final id = sensor.getAttribute('id');
    if (id != null && id.isNotEmpty) {
      cellOf[id] = sensorIndex;
      sensorIndex += 1;
    }
  }

  // 2. Gas definitions, by mix id.
  final gasMixes = <String?, _Mix>{};
  for (final mix in descendantsNamed(root, 'mix')) {
    final mixId = mix.getAttribute('id');
    final nameText = stringValue(childrenNamed(mix, 'name').firstOrNull);
    double percent(String child, double fallback) {
      final text = stringValue(childrenNamed(mix, child).firstOrNull);
      if (text.isEmpty) {
        return fallback;
      }
      final fraction = pyFloat(text);
      if (fraction == null) {
        throw FormatException('Gas mix $mixId: $child is not a number', text);
      }
      return fraction * 100;
    }

    gasMixes[mixId] = _Mix(
      nameText.isEmpty ? mixId : nameText,
      percent('o2', 21.0),
      percent('he', 0.0),
    );
  }

  // The file's own deco model settings: the recompute runs with the same
  // gradient factors, so its TTS and ceiling agree with the log.
  final gfLow = stringValue(
    firstByPath(root, [
      'decomodel',
      'gradientfactorlow',
    ], anyDepthBelowFirst: true),
  );
  final gfHigh = stringValue(
    firstByPath(root, [
      'decomodel',
      'gradientfactorhigh',
    ], anyDepthBelowFirst: true),
  );
  final fileGf = gfLow.isEmpty || gfHigh.isEmpty
      ? null
      : parseGf(pyFloat(gfLow), pyFloat(gfHigh));

  // 3. The dives, wherever they are in the file.
  for (final diveElem in descendantsNamed(document, 'dive')) {
    // A log that records its own <decostop>s says "no stop" by leaving it
    // out; the recompute must not invent one there.
    final fileLogsStops = descendantsNamed(diveElem, 'decostop').isNotEmpty;

    DateTime? startTime;
    final dtStr = stringValue(
      descendantsNamed(diveElem, 'datetime').firstOrNull,
    );
    if (dtStr.isNotEmpty) {
      // The wall clock time as logged, whatever offset is written after it.
      startTime = pyFromIsoformatNaive(dtStr.replaceAll('Z', '+00:00'));
    }
    if (startTime == null) {
      // The legacy year/month/day/hour/minute fields.
      String field(String name) =>
          stringValue(descendantsNamed(diveElem, name).firstOrNull);
      final parts = [
        for (final name in ['year', 'month', 'day', 'hour', 'minute'])
          field(name),
      ];
      if (parts.every((part) => part.isNotEmpty)) {
        final numbers = [for (final part in parts) pyInt(part)];
        if (numbers.every((number) => number != null)) {
          final [year, month, day, hour, minute] = [
            for (final number in numbers) number!,
          ];
          if (year >= 1 &&
              year <= 9999 &&
              hour >= 0 &&
              hour < 24 &&
              minute >= 0 &&
              minute < 60) {
            final candidate = naive(year, month, day, hour, minute);
            if (candidate.month == month && candidate.day == day) {
              startTime = candidate;
            }
          }
        }
      }
    }
    if (startTime == null) {
      continue;
    }

    final tzOffsetStr = stringValue(
      childrenNamed(diveElem, 'timezone').firstOrNull,
    );

    // A tank's own mix where its tankdata links one (the app's builder
    // links each cylinder; the Shearwater app links none): by the tankdata
    // id, and as T<n> for the n-th tankdata (the Shearwater app's refs).
    final tankMix = <String, String>{};
    // Each tank's size, by the same keys (and by its number, for samples
    // whose tankpressure names no tank): UDDF gives m³; a value over 1 is
    // taken as litres.
    final tankVolumes = <String, double>{};
    var tankNumber = 0;
    for (final tankdata in descendantsNamed(diveElem, 'tankdata')) {
      tankNumber += 1;
      final volume = pyFloat(
        stringValue(childrenNamed(tankdata, 'tankvolume').firstOrNull),
      );
      if (volume != null && volume > 0) {
        final litres = volume > 1 ? volume : pyRoundTo(volume * 1000.0, 2);
        final id = tankdata.getAttribute('id');
        for (final key in [
          'T$tankNumber',
          '$tankNumber',
          if (id != null && id.isNotEmpty) id,
        ]) {
          tankVolumes[key] = litres;
        }
      }
      final link = childAttribute(tankdata, 'link', 'ref');
      if (gasMixes.containsKey(link)) {
        tankMix.putIfAbsent('T$tankNumber', () => link);
        final id = tankdata.getAttribute('id');
        if (id != null && id.isNotEmpty) {
          tankMix[id] = link;
        }
      }
    }

    final waypoints = <Waypoint>[];
    var currentMaxDepth = 0.0;
    String? activeMixId;
    var hasActiveMix = false;
    double? lastPo2;
    String? lastDivemode;
    double? lastSetpoint;
    String? diluentId;
    var hasDiluent = false;
    // Cell number to its last reading, in the order the cells first read.
    final lastCells = <int, double>{};
    final refsSeen = Map<String, int>.of(cellOf);

    // 4. The samples.
    for (final sample in descendantsNamed(diveElem, 'waypoint')) {
      String child(String name) =>
          stringValue(childrenNamed(sample, name).firstOrNull);

      final secondsStr = child('divetime');
      if (secondsStr.isEmpty) {
        continue;
      }
      final seconds = _wholeNumber(secondsStr);
      if (seconds == null) {
        continue;
      }
      final timestamp = startTime.add(Duration(seconds: seconds));

      // No <depth> is null in the port (spec §10.8), 0.0 in Python; a
      // sample with an unreadable depth is skipped.
      final depthStr = child('depth');
      final double? depth;
      if (depthStr.isEmpty) {
        depth = null;
      } else {
        depth = pyFloat(depthStr);
        if (depth == null) {
          continue;
        }
        if (depth > currentMaxDepth) {
          currentMaxDepth = depth;
        }
      }

      // Kelvin as UDDF says, or Celsius as some programs write. No
      // temperature, or an unreadable one, is null (§10.8); Python has 0.0.
      var temp = pyFloat(child('temperature'));
      if (temp != null && temp > 150) {
        temp -= 273.15;
      }

      final ndl = _wholeNumber(child('nodecotime'));
      // The app's own per-waypoint extension; absent in other exports.
      final loggedTts = _wholeNumber(child('tts'));
      final cns = _wholeNumber(child('cns'));

      // PO2, held between the samples that log it.
      final po2Value = _po2Bar(child('calculatedpo2'));
      if (po2Value != null) {
        lastPo2 = po2Value;
      }
      var po2 = lastPo2;

      // Setpoint and O2 cells, held between the samples that log them.
      final setpoint = _po2Bar(child('setpo2'));
      if (setpoint != null) {
        lastSetpoint = setpoint;
      }
      for (final elem in sample.childElements) {
        final ref = elem.getAttribute('ref');
        final isCell =
            elem.name.local == 'measuredpo2' ||
            (elem.name.local == 'ppo2' && ref != null);
        if (!isCell) {
          continue;
        }
        final value = _po2Bar(leadingText(elem));
        if (value == null) {
          continue;
        }
        final key = ref ?? '';
        if (!refsSeen.containsKey(key)) {
          var highest = -1;
          for (final index in refsSeen.values) {
            if (index > highest) {
              highest = index;
            }
          }
          refsSeen[key] = highest + 1;
        }
        final cell = refsSeen[key]!;
        if (cell < _cellCount) {
          lastCells[cell] = value;
        }
      }

      // The dive mode is not on every sample, so the last one holds.
      var divemode = childAttribute(sample, 'divemode', 'type');
      if (divemode.isEmpty) {
        divemode = child('divemode');
      }
      if (divemode.isNotEmpty) {
        lastDivemode = divemode;
      }
      final onLoop = _loopModes.contains(lastDivemode);

      // A rebreather's PO2 where the file logs none: the cells' average,
      // else the setpoint in force; not the open-circuit recompute, which
      // knows nothing of the loop.
      if (po2 == null && onLoop) {
        if (lastCells.isNotEmpty) {
          po2 = pyRoundTo(pySum(lastCells.values) / lastCells.length, 2);
        } else if (lastSetpoint != null) {
          po2 = lastSetpoint;
        }
      }

      // The deco stop: the file's own where it logs one, since computers
      // use their own tuned algorithm.
      final decostop = childrenNamed(sample, 'decostop').firstOrNull;
      final double? loggedStopDepth;
      final int? loggedStopTime;
      if (decostop != null) {
        loggedStopDepth = pyFloat(decostop.getAttribute('decodepth'));
        final duration = pyFloat(decostop.getAttribute('duration'));
        loggedStopTime = _whole(duration);
      } else if ((ndl != null && ndl > 0) || fileLogsStops) {
        // The file's own NDL says no stop is owed yet, or the file logs
        // stops and has none here.
        loggedStopDepth = 0.0;
        loggedStopTime = 0;
      } else {
        loggedStopDepth = null;
        loggedStopTime = null;
      }

      final gf = _number(child('gradientfactor'));
      final battery = _number(child('batterychargecondition'));

      // Gas switch.
      final mixRef = childAttribute(sample, 'switchmix', 'ref');
      if (mixRef.isNotEmpty) {
        activeMixId = mixRef;
        hasActiveMix = true;
      }
      // A rebreather's diluent: the mix breathed on the loop, kept after a
      // bailout.
      if (onLoop && gasMixes.containsKey(activeMixId)) {
        diluentId = activeMixId;
        hasDiluent = true;
      }
      // Before any switch Python looks the mix up by `None`, which finds a
      // mix written without an id.
      final breathed = gasMixes[hasActiveMix ? activeMixId : null];
      final diluent = gasMixes[hasDiluent ? diluentId : null];

      // One <tankpressure> per tank per sample. A tank shows its own mix
      // where its tankdata links one, else the mix being breathed.
      final tanks = <String, TankData>{};
      final gasInfo = breathed ?? _air;
      var index = 0;
      for (final elem in childrenNamed(sample, 'tankpressure')) {
        index += 1;
        final pressurePa = pyFloat(leadingText(elem));
        if (pressurePa == null) {
          continue;
        }
        final pressureBar = pressurePa > 5000
            ? pressurePa / 100000.0
            : pressurePa;
        if (shearwaterApp &&
            (pressureBar <= 0 || pressureBar >= shearwaterStatusBar)) {
          // The app's "unknown" or a transmitter status, not a reading.
          continue;
        }
        final ref = elem.getAttribute('ref');
        final key = ref == null || ref.isEmpty ? '$index' : ref;
        final own = gasMixes[tankMix[key]] ?? gasInfo;
        tanks[key] = TankData(
          pressureBar: pressureBar,
          o2Percent: own.o2,
          hePercent: own.he,
          name: own.name,
        );
      }

      waypoints.add(
        Waypoint(
          timestamp: timestamp,
          depth: depth,
          maxDepth: currentMaxDepth,
          temp: temp,
          ndl: ndl,
          tts: loggedTts,
          cns: cns,
          po2: po2,
          po2_1: lastCells[0],
          po2_2: lastCells[1],
          po2_3: lastCells[2],
          divemode: lastDivemode,
          setpoint: onLoop ? lastSetpoint : null,
          gasO2Percent: breathed?.o2,
          gasHePercent: breathed?.he,
          diluentO2Percent: diluent?.o2,
          diluentHePercent: diluent?.he,
          gf: gf,
          battery: battery,
          timeSinceStart: seconds,
          diveTime: seconds,
          tanks: tanks,
          decoStopDepth: loggedStopDepth,
          nextStopTime: loggedStopTime,
        ),
      );
    }

    if (waypoints.isEmpty) {
      continue;
    }

    // A file that lists a mix without oxygen gets no recompute at all:
    // Python's MOD for it divides by zero and the whole step is given up
    // (spec §10.16).
    if (gasMixes.values.any((mix) => mix.o2 == 0)) {
      fillSacWhenNoneLogged(waypoints);
    } else {
      applyDecoAndGas(
        waypoints,
        [
          for (final mix in gasMixes.values)
            GasDefinition(
              mix.name ?? _unnamedGas,
              mix.o2 / 100.0,
              mix.he / 100.0,
              pyMax(0, ((1.4 / (mix.o2 / 100.0)) - 1.0) * 10.0),
            ),
        ],
        fileGf: fileGf,
        fileLogsStops: fileLogsStops,
        unrecordableGas: _unnamedGas,
      );
    }

    dives.add(
      Dive(
        startTime: startTime,
        endTime: waypoints.last.timestamp,
        waypoints: waypoints,
        device: deviceName.isEmpty ? null : deviceName,
        manufactor: manufacturer.isEmpty ? null : manufacturer,
        gfLow: fileGf == null ? null : pyRound(fileGf.$1 * 100),
        gfHigh: fileGf == null ? null : pyRound(fileGf.$2 * 100),
        timezone: tzOffsetStr.isEmpty ? null : tzOffsetStr,
        logFilename: pyFileName(path),
        logPath: path,
        tankVolumesL: {
          for (final key in waypoints.expand((wp) => wp.tanks.keys).toSet())
            key: ?tankVolumes[key],
        },
      ),
    );
  }

  return dives;
}
