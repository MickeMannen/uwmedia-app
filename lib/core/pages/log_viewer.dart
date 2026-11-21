/// What the Log Viewer shows of a dive (Python
/// `uwmedia/backends/log_viewer_backend.py`): the line in the dive list,
/// the details pane (a grid of fields, the tanks, the depth profile, the
/// PO2 strip of a rebreather dive, the channels the log holds, its events)
/// and the table of every sample with its filter, which is what an
/// overlay is drawn from. Every value is text ready to show; an empty text
/// is something the log does not have, and the page leaves it out.
///
/// The unit system is an argument (spec §10.19). `toJson` on each result
/// gives the map the Python page gets.
library;

import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/units/units.dart' as u;
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';

/// The settings field that remembers the folder the dialogs open in.
const lastFolderField = 'log_viewer_folder';

/// The columns of the samples table, by the keys of a [SampleRow].
const tableColumns = [
  'time', 'depth', 'temp', 'ndl', 'tts', 'gas', 'po2', 'setpoint', //
  'cells', 'circuit', 'tanks',
];

/// The headings of the samples table.
List<String> tableHeaders(u.UnitSystem units) => [
  'Time',
  'Depth (${u.depthLabel(units)})',
  'Temp (${u.temperatureLabel(units)})',
  'NDL (s)',
  'TTS (s)',
  'Gas',
  'PO2',
  'SP',
  'Cells',
  'Circuit',
  'Tanks',
];

/// The chart draws at most this many points; a 1 s FIT log of an hour's
/// dive has about 3600, which only slows the drawing without showing more.
const maxChartPoints = 1500;
const maxEventLines = 60;

/// How the page names a log format.
const formatNames = {
  'uddf': 'UDDF',
  'fit': 'Garmin FIT',
  'subsurface_xml': 'Subsurface',
  'subsurface_csv': 'Subsurface CSV',
  'shearwater_xml': 'Shearwater Cloud',
  'shearwater_csv': 'Shearwater Cloud CSV',
  'suunto_json': 'Suunto app',
};

/// The channels listed under the profile as "also logged" when any sample
/// of the dive has them: the Python attribute's name, the label and the
/// value in a sample.
final List<(String, String, Object? Function(Waypoint))> channels = [
  ('temp', 'temperature', (wp) => wp.temp),
  ('ndl', 'NDL', (wp) => wp.ndl),
  ('tts', 'TTS', (wp) => wp.tts),
  ('ceiling', 'ceiling', (wp) => wp.ceiling),
  ('deco_stop_depth', 'deco stop', (wp) => wp.decoStopDepth),
  ('next_stop_depth', 'next stop', (wp) => wp.nextStopDepth),
  ('cns', 'CNS', (wp) => wp.cns),
  ('po2', 'ppO₂', (wp) => wp.po2),
  ('po2_1', 'ppO₂ cells', (wp) => wp.po2_1),
  ('setpoint', 'setpoint', (wp) => wp.setpoint),
  ('n2_tissue_load', 'N₂ tissue load', (wp) => wp.n2TissueLoad),
  ('ascent_rate', 'ascent rate', (wp) => wp.ascentRate),
  ('air_remaining', 'gas time remaining', (wp) => wp.airRemaining),
  ('pressure_sac', 'SAC', (wp) => wp.pressureSac),
  ('rmv', 'RMV', (wp) => wp.rmv),
  ('heart_rate', 'heart rate', (wp) => wp.heartRate),
  ('gf', 'GF', (wp) => wp.gf),
  ('battery', 'battery', (wp) => wp.battery),
];

/// Garmin logs a dismissal after nearly every alert; it says nothing new.
const ignoredAlerts = ['alert_dismissed'];

/// A number for display; "m", "bar" and "°C" are converted to [units],
/// anything else is printed as given. Nothing for no value.
String displayNumber(
  double? value,
  u.UnitSystem units, {
  String unit = '',
  int digits = 1,
}) {
  if (value == null) {
    return '';
  }
  var shown = value;
  var label = unit;
  switch (unit) {
    case 'm':
      shown = u.depth(value, units);
      label = u.depthLabel(units);
    case 'bar':
      shown = u.pressure(value, units);
      label = u.pressureLabel(units, upper: false);
    case '°C':
      shown = u.temperature(value, units);
      label = u.temperatureLabel(units);
  }
  final text = pyFormatFixed(shown, digits);
  return label.isEmpty ? text : '$text $label';
}

String _two(int value) => value.toString().padLeft(2, '0');

// Python's floor division and modulo, for a time that runs backwards.
String _clock(int seconds) => '${(seconds / 60).floor()}:${_two(seconds % 60)}';

/// Seconds as "12:05 min"; nothing for no value.
String minutesText(int? seconds) =>
    seconds == null ? '' : '${_clock(seconds)} min';

/// Seconds as "12:05".
String clockText(int seconds) => _clock(seconds);

/// A gas by the name the page gives it: "Air", "Nx32", "Tx 18/45".
String viewerMixName(double o2Percent, double hePercent) {
  final o2 = pyRound(o2Percent);
  final he = pyRound(hePercent);
  if (he != 0) {
    return 'Tx $o2/$he';
  }
  if (o2 == 21) {
    return 'Air';
  }
  return o2 > 21 ? 'Nx$o2' : '$o2% O₂';
}

/// The mean depth over the samples that have one, weighted by time.
double? averageDepth(Dive dive) {
  final points = [
    for (final wp in dive.waypoints)
      if (wp.depth != null) (wp.timeSinceStart, wp.depth!),
  ];
  if (points.length < 2) {
    return points.isEmpty ? null : points.first.$2;
  }
  var area = 0.0;
  for (var i = 1; i < points.length; i++) {
    final (t0, d0) = points[i - 1];
    final (t1, d1) = points[i];
    area += (t1 - t0) * (d0 + d1) / 2;
  }
  final span = points.last.$1 - points.first.$1;
  return span > 0 ? area / span : null;
}

/// The computer's maker and model, the maker once.
String deviceText(Dive dive) {
  final device = dive.device ?? '';
  var maker = dive.manufactor ?? '';
  if (maker.isNotEmpty &&
      device.toLowerCase().startsWith(maker.toLowerCase())) {
    maker = '';
  }
  return [maker, device].where((part) => part.isNotEmpty).join(' ');
}

/// One line of the page's dive list.
class DiveRow {
  const DiveRow({
    required this.date,
    required this.time,
    required this.maxDepth,
    required this.duration,
    required this.file,
    required this.device,
  });

  final String date;
  final String time;
  final String maxDepth;
  final String duration;
  final String file;
  final String device;

  Map<String, Object?> toJson() => {
    'date': date,
    'time': time,
    'max_depth': maxDepth,
    'duration': duration,
    'file': file,
    'device': device,
  };
}

DiveRow diveRow(Dive dive, u.UnitSystem units) {
  assert(dive.startTime.isUtc, naiveTimeMessage);
  return DiveRow(
    date: pyStrftime(dive.startTime, '%Y-%m-%d'),
    time: pyStrftime(dive.startTime, '%H:%M'),
    maxDepth: displayNumber(dive.maxDepth, units, unit: 'm'),
    duration: minutesText(dive.duration),
    file: dive.logFilename ?? '',
    device: deviceText(dive),
  );
}

/// One tank of the dive in the details pane.
class TankRow {
  TankRow({
    required this.index,
    required this.key,
    required this.name,
    required this.serial,
    required this.mix,
  });

  final int index;
  final String key;
  final String name;
  final String serial;
  final String mix;
  String startPressure = '';
  String endPressure = '';

  Map<String, Object?> toJson() => {
    'index': index,
    'key': key,
    'name': name,
    'serial': serial,
    'mix': mix,
    'start_pressure': startPressure,
    'end_pressure': endPressure,
  };
}

/// The dive's tanks in the order the samples first name them, with the
/// first and the last pressure read. [reverseMap] is the tank-name mapping
/// turned round: a name's serial.
List<TankRow> tankRows(
  Dive dive,
  Map<String, String> reverseMap,
  u.UnitSystem units,
) {
  final seen = <String, TankRow>{};
  final readings = <String, (double, double)>{};
  for (final wp in dive.waypoints) {
    wp.tanks.forEach((key, tank) {
      seen.putIfAbsent(key, () {
        final serial = reverseMap[key] ?? '';
        return TankRow(
          index: seen.length + 1,
          key: key,
          name: tank.name ?? '',
          serial: serial != key ? serial : '',
          mix: viewerMixName(tank.o2Percent, tank.hePercent),
        );
      });
      final pressure = tank.pressureBar;
      if (pressure != null && pressure != 0) {
        readings[key] = (readings[key]?.$1 ?? pressure, pressure);
      }
    });
  }
  for (final row in seen.values) {
    final reading = readings[row.key];
    row
      ..startPressure = displayNumber(
        reading?.$1,
        units,
        unit: 'bar',
        digits: 0,
      )
      ..endPressure = displayNumber(reading?.$2, units, unit: 'bar', digits: 0);
  }
  return seen.values.toList();
}

bool _knowsGas(Waypoint wp) => wp.tanks.isNotEmpty || wp.gasO2Percent != null;

String _cells(Waypoint wp) => [
  wp.po2_1,
  wp.po2_2,
  wp.po2_3,
].nonNulls.map((c) => pyFormatFixed(c, 2)).join(' / ');

/// Alerts, gas changes and, on a rebreather dive, the circuit (bailout,
/// back on the loop) and the setpoint changes, each with its dive time;
/// past [maxLines] only how many more there are.
List<String> diveEvents(Dive dive, {int maxLines = maxEventLines}) {
  var events = <String>[];
  String? previousGas;
  String? previousCircuit;
  double? previousSetpoint;
  for (final wp in dive.waypoints) {
    final at = _clock(wp.timeSinceStart);
    for (final alert in wp.diveAlerts) {
      if (ignoredAlerts.any(alert.startsWith)) {
        continue;
      }
      events.add('$at  ${alert.replaceAll('_', ' ')}');
    }
    final circuit = wp.circuit;
    if (dive.isCcr && previousCircuit != null && circuit != previousCircuit) {
      events.add(
        '$at  '
        '${circuit == 'BO' ? 'bailout to open circuit' : 'back on the loop'}',
      );
    }
    previousCircuit = circuit.isEmpty ? previousCircuit : circuit;
    final setpoint = wp.setpoint;
    if (setpoint != null) {
      if (previousSetpoint != null && setpoint != previousSetpoint) {
        events.add(
          '$at  setpoint ${pyFormatG(previousSetpoint)} → '
          '${pyFormatG(setpoint)}',
        );
      }
      previousSetpoint = setpoint;
    }
    if (_knowsGas(wp)) {
      final gas = wp.gasmix;
      if (previousGas != null && gas != previousGas) {
        events.add('$at  gas change: $previousGas → $gas');
      }
      previousGas = gas;
    }
  }
  if (events.length > maxLines) {
    final more = events.length - maxLines;
    events = [...events.take(maxLines), '... and $more more'];
  }
  return events;
}

// The samples with a depth, thinned to at most [maxPoints] and always
// with the last one.
List<Waypoint> _picked(Dive dive, int maxPoints) {
  final points = [
    for (final wp in dive.waypoints)
      if (wp.depth != null) wp,
  ];
  final step = (points.length / maxPoints).ceil().clamp(1, points.length + 1);
  final picked = [for (var i = 0; i < points.length; i += step) points[i]];
  if (points.isNotEmpty && !identical(picked.last, points.last)) {
    picked.add(points.last);
  }
  return picked;
}

/// One point of the depth profile, in the unit system's depths.
typedef ChartSample = ({int time, double depth, double ceiling});

/// The depth profile's points.
List<ChartSample> chartSamples(
  Dive dive,
  u.UnitSystem units, {
  int maxPoints = maxChartPoints,
}) => [
  for (final wp in _picked(dive, maxPoints))
    (
      time: wp.timeSinceStart,
      depth: u.depth(wp.depth!, units),
      ceiling: u.depth(wp.ceiling ?? 0.0, units),
    ),
];

/// One point of the PO2 strip: -1 for a value the sample does not have.
typedef Po2Sample = ({
  int time,
  double po2,
  double setpoint,
  double c1,
  double c2,
  double c3,
  bool bailout,
});

/// The PO2 strip under the profile: per (thinned) sample the PO2, the
/// setpoint and the three cells, and whether the diver is on a bailout;
/// for a dive with a setpoint or cells, empty otherwise.
List<Po2Sample> po2Samples(Dive dive, {int maxPoints = maxChartPoints}) {
  if (!dive.waypoints.any((wp) => wp.setpoint != null || wp.po2_1 != null)) {
    return [];
  }
  return [
    for (final wp in _picked(dive, maxPoints))
      (
        time: wp.timeSinceStart,
        po2: wp.po2 ?? -1.0,
        setpoint: wp.setpoint ?? -1.0,
        c1: wp.po2_1 ?? -1.0,
        c2: wp.po2_2 ?? -1.0,
        c3: wp.po2_3 ?? -1.0,
        bailout: wp.circuit == 'BO',
      ),
  ];
}

/// One line for a rebreather dive: the diluent, the setpoints and the
/// time on a bailout; nothing for an open-circuit dive.
String rebreatherText(Dive dive) {
  if (!dive.isCcr) {
    return '';
  }
  final parts = ['CCR'];
  final diluent = dive.waypoints
      .where((wp) => wp.diluentO2Percent != null)
      .firstOrNull;
  if (diluent != null) {
    parts.add(
      'diluent '
      '${viewerMixName(diluent.diluentO2Percent!, diluent.diluentHePercent ?? 0.0)}',
    );
  }
  final setpoints = {
    for (final wp in dive.waypoints)
      if (wp.setpoint != null) wp.setpoint!,
  }.toList()..sort();
  if (setpoints.isNotEmpty) {
    parts.add('setpoint ${setpoints.map(pyFormatG).join(' / ')}');
  }
  var bailout = 0;
  final wps = dive.waypoints;
  for (var i = 1; i < wps.length; i++) {
    if (wps[i - 1].circuit == 'BO') {
      bailout += wps[i].timeSinceStart - wps[i - 1].timeSinceStart;
    }
  }
  if (bailout != 0) {
    parts.add('bailout ${minutesText(bailout)}');
  }
  return parts.join(', ');
}

/// Everything the details pane shows for one dive.
class DiveDetails {
  DiveDetails({
    required this.title,
    required this.file,
    required this.path,
    required this.format,
    required this.start,
    required this.end,
    required this.timezone,
    required this.duration,
    required this.depthUnit,
    required this.maxDepth,
    required this.avgDepth,
    required this.tempMin,
    required this.tempMax,
    required this.device,
    required this.lat,
    required this.lng,
    required this.exitLat,
    required this.exitLng,
    required this.tanks,
    required this.samples,
    required this.po2Samples,
    required this.rebreather,
    required this.sampleCount,
    required this.channels,
    required this.events,
  });

  final String title;
  final String file;
  final String path;
  final String format;
  final String start;
  final String end;
  final String timezone;
  final String duration;

  /// For the chart's axis.
  final String depthUnit;
  final String maxDepth;
  final String avgDepth;
  final String tempMin;
  final String tempMax;
  final String device;
  final String lat;
  final String lng;
  final String exitLat;
  final String exitLng;
  final List<TankRow> tanks;
  final List<ChartSample> samples;
  final List<Po2Sample> po2Samples;
  final String rebreather;
  final int sampleCount;
  final List<String> channels;
  final List<String> events;

  bool get hasCeiling => samples.any((s) => s.ceiling > 0);

  Map<String, Object?> toJson() => {
    'title': title,
    'file': file,
    'path': path,
    'format': format,
    'start': start,
    'end': end,
    'timezone': timezone,
    'duration': duration,
    'depth_unit': depthUnit,
    'max_depth': maxDepth,
    'avg_depth': avgDepth,
    'temp_min': tempMin,
    'temp_max': tempMax,
    'device': device,
    'lat': lat,
    'lng': lng,
    'exit_lat': exitLat,
    'exit_lng': exitLng,
    'tanks': [for (final tank in tanks) tank.toJson()],
    'samples': [
      for (final s in samples)
        {'time': s.time, 'depth': s.depth, 'ceiling': s.ceiling},
    ],
    'has_ceiling': hasCeiling,
    'po2_samples': [
      for (final s in po2Samples)
        {
          'time': s.time,
          'po2': s.po2,
          'setpoint': s.setpoint,
          'c1': s.c1,
          'c2': s.c2,
          'c3': s.c3,
          'bailout': s.bailout,
        },
    ],
    'rebreather': rebreather,
    'sample_count': sampleCount,
    'channels': channels,
    'events': events,
  };
}

DiveDetails diveDetails(
  Dive dive,
  Map<String, String> reverseMap,
  u.UnitSystem units, {
  int maxPoints = maxChartPoints,
  int maxLines = maxEventLines,
}) {
  final temps = [for (final wp in dive.waypoints) wp.temp].nonNulls.toList();
  final present = [
    if (dive.waypoints.any((wp) => wp.tanks.isNotEmpty)) 'tank pressure',
    for (final (_, label, value) in channels)
      if (dive.waypoints.any((wp) => value(wp) != null)) label,
    if (dive.waypoints.any((wp) => wp.diveAlerts.isNotEmpty)) 'dive alerts',
  ];
  final gps = dive.startLatitude != null && dive.startLongitude != null;
  final exitGps = dive.endLatitude != null && dive.endLongitude != null;
  final device = deviceText(dive);
  String place(double? value, bool known) =>
      known ? displayNumber(value, units, digits: 6) : '';
  String temp(double Function(double, double) pick) =>
      temps.isEmpty ? '' : displayNumber(temps.reduce(pick), units, unit: '°C');
  return DiveDetails(
    title:
        pyStrftime(dive.startTime, '%Y-%m-%d %H:%M') +
        (device.isEmpty ? '' : ' — $device'),
    file: dive.logFilename ?? '',
    path: dive.logPath ?? '',
    format: formatNames[dive.logFormat ?? ''] ?? dive.logFormat ?? '',
    start: pyStrftime(dive.startTime, '%Y-%m-%d %H:%M:%S'),
    end: pyStrftime(dive.endTime, '%Y-%m-%d %H:%M:%S'),
    timezone: dive.timezone ?? '',
    duration: minutesText(dive.duration),
    depthUnit: u.depthLabel(units),
    maxDepth: displayNumber(dive.maxDepth, units, unit: 'm'),
    avgDepth: displayNumber(averageDepth(dive), units, unit: 'm'),
    tempMin: temp((a, b) => a < b ? a : b),
    tempMax: temp((a, b) => a > b ? a : b),
    device: device,
    lat: place(dive.startLatitude, gps),
    lng: place(dive.startLongitude, gps),
    exitLat: place(dive.endLatitude, exitGps),
    exitLng: place(dive.endLongitude, exitGps),
    tanks: tankRows(dive, reverseMap, units),
    samples: chartSamples(dive, units, maxPoints: maxPoints),
    po2Samples: po2Samples(dive, maxPoints: maxPoints),
    rebreather: rebreatherText(dive),
    sampleCount: dive.waypoints.length,
    channels: present,
    events: diveEvents(dive, maxLines: maxLines),
  );
}

String _tankReading(
  String key,
  TankData tank,
  Map<String, String> reverseMap,
  u.UnitSystem units,
) {
  final serial = reverseMap[key];
  final label = serial != null && serial.isNotEmpty && serial != key
      ? '$key ($serial)'
      : key;
  var text =
      '$label: '
      '${displayNumber(tank.pressureBar, units, unit: 'bar', digits: 0)}';
  if (tank.hePercent != 0) {
    text +=
        ' (${pyFormatFixed(tank.o2Percent, 0)}/'
        '${pyFormatFixed(tank.hePercent, 0)})';
  } else if ((tank.o2Percent - 21.0).abs() > 0.5) {
    text += ' (Nx${pyFormatFixed(tank.o2Percent, 0)})';
  }
  return text;
}

/// One sample as a line of the table: a text per column of
/// [tableColumns].
typedef SampleRow = Map<String, String>;

/// Every sample of the dive as a line of the table.
List<SampleRow> sampleRows(
  Dive dive,
  Map<String, String> reverseMap,
  u.UnitSystem units,
) {
  // The number without its unit: the column's heading has it.
  String bare(double? value, String unit) {
    final text = displayNumber(value, units, unit: unit);
    final cut = text.lastIndexOf(' ');
    return cut < 0 ? text : text.substring(0, cut);
  }

  return [
    for (final wp in dive.waypoints)
      {
        'time': pyStrftime(wp.timestamp, '%H:%M:%S'),
        'depth': bare(wp.depth, 'm'),
        'temp': bare(wp.temp, '°C'),
        'ndl': wp.ndl == null ? '' : '${wp.ndl}',
        'tts': wp.tts == null ? '' : '${wp.tts}',
        'gas': _knowsGas(wp) ? wp.gasmix : '',
        'po2': wp.po2 == null ? '' : pyFormatFixed(wp.po2!, 2),
        'setpoint': wp.setpoint == null ? '' : pyFormatG(wp.setpoint!),
        'cells': _cells(wp),
        'circuit': dive.isCcr ? wp.circuit : '',
        'tanks': [
          for (final MapEntry(:key, :value) in wp.tanks.entries)
            _tankReading(key, value, reverseMap, units),
        ].join('; '),
      },
  ];
}

/// The lines of the table that have [filter] in any column, whatever the
/// case; all of them without a filter.
List<SampleRow> filterSampleRows(List<SampleRow> rows, String? filter) {
  final text = (filter ?? '').toLowerCase();
  return text.isEmpty
      ? rows
      : [
          for (final row in rows)
            if (row.values.any((v) => v.toLowerCase().contains(text))) row,
        ];
}
