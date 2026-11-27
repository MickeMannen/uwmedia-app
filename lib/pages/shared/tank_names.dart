/// The tank sensor names (spec §4.1, §10.104): the Garmin tank sensors of
/// the dive logs the app keeps, each with the name the diver gives it, the
/// name and the side it has in sidemount, and its size. The order is the
/// tank order. Edited on the desktop's Advanced page and the phones'
/// Settings page, saved into `config.yaml`.
///
/// The window reads no log of its own: a sensor is here because a kept log
/// has it (the Dive Logs page), or because it was saved before.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/parsers/fit_reader.dart';
import 'package:uwmedia_app/core/parsers/garmin.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/engine/log_store.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

/// Where a sensor is in the kept logs: in how many dives, and the start of
/// the last of them.
typedef SensorSeen = ({int dives, DateTime? last});

/// The tank sensors of the Garmin logs kept in [folder], with where each
/// was seen. A dive kept twice (the same dive under two file names) counts
/// once; a log that cannot be read is passed over.
Map<String, SensorSeen> keptTankSensors(String folder) {
  final dir = Directory(folder);
  if (!dir.existsSync()) {
    return {};
  }
  // The dives' starts as the Dive Logs page has them (remembered per
  // file); the names do not matter for them.
  final starts = <String, DateTime>{};
  final copies = <String>{};
  try {
    for (final dive in LogStore(dir).summaries(TankConfig()).dives) {
      if (dive.copyOf != null) {
        copies.add(dive.file);
      } else {
        starts.putIfAbsent(dive.file, () => dive.start);
      }
    }
  } on Object {
    // No dates then.
  }
  final seen = <String, SensorSeen>{};
  for (final entry in dir.listSync()) {
    final name = p.basename(entry.path);
    if (entry is! File ||
        p.extension(name).toLowerCase() != '.fit' ||
        (copies.contains(name) && !starts.containsKey(name))) {
      continue;
    }
    final List<String> serials;
    try {
      serials = uniqueTankSerials(readFitMessages(entry.readAsBytesSync()));
    } on Object {
      continue;
    }
    final start = starts[name];
    for (final serial in serials) {
      final before = seen[serial];
      final last = before?.last;
      seen[serial] = (
        dives: (before?.dives ?? 0) + 1,
        last: start == null || (last != null && last.isAfter(start))
            ? last
            : start,
      );
    }
  }
  return seen;
}

/// One sensor as the window shows it.
typedef TankRow = ({
  String serial,
  String name,
  String sidemountName,
  TankSide? side,
  SensorSeen? seen,
});

class TankNamesEditor extends ChangeNotifier {
  TankNamesEditor({required this.config});

  final ConfigStore config;

  List<String> _order = [];
  final Map<String, String> _names = {};
  final Map<String, String> _sidemount = {};
  final Map<String, TankSide> _sides = {};
  final Map<String, double> _sizes = {};
  final Map<String, double> _working = {};
  final Set<String> _badSizes = {};
  final Set<String> _badWorking = {};
  Map<String, SensorSeen> _seen = {};
  String statusText = '';
  bool _unreadable = false;
  bool _reading = false;
  bool _disposed = false;
  int _opened = 0;

  /// The sensors in the saved order: the tank order (the first one a dive
  /// has is the tank an overlay with one tank shows).
  List<TankRow> get rows => [
    for (final serial in _order)
      (
        serial: serial,
        name: _names[serial] ?? '',
        sidemountName: _sidemount[serial] ?? '',
        side: _sides[serial],
        seen: _seen[serial],
      ),
  ];

  /// The kept logs are being read.
  bool get reading => _reading;

  /// The size of the tank with this serial in litres, if it has one.
  double? sizeOf(String serial) => _sizes[serial];

  /// The pressure this tank is rated at in bar: what its size in cubic
  /// feet is counted at.
  double workingBarOf(String serial) => _working[serial] ?? defaultWorkingBar;

  /// The size as its field shows it in [units]: litres, or cubic feet at
  /// the tank's rated pressure; empty for none.
  String sizeText(String serial, UnitSystem units) {
    final litres = _sizes[serial];
    if (litres == null) {
      return '';
    }
    return units == UnitSystem.imperial
        ? _number(cubicFeetOf(litres, workingBarOf(serial)), 1)
        : _number(litres, 2);
  }

  /// The rated pressure as its field shows it, in psi.
  String workingText(String serial) =>
      _number(workingBarOf(serial) * psiPerBar, 0);

  /// The size typed for this serial is not a size: Save is off.
  bool badSize(String serial) => _badSizes.contains(serial);

  /// The rated pressure typed for this serial is not one: Save is off.
  bool badWorking(String serial) => _badWorking.contains(serial);

  bool get canSave => _badSizes.isEmpty && _badWorking.isEmpty;

  /// `config.yaml` is there but cannot be read: saving replaces it.
  bool get unreadable => _unreadable;

  String get path => config.configYamlPath;

  /// The window opened: the saved sensors.
  void open() {
    final file = config.tankConfig();
    final saved = file.tanks;
    _opened++;
    _order = saved.tanks.keys.toList();
    _names
      ..clear()
      ..addAll(saved.tanks);
    _sidemount
      ..clear()
      ..addAll(saved.sidemountNames);
    _sides
      ..clear()
      ..addAll(saved.sides);
    _sizes
      ..clear()
      ..addAll(saved.sizes);
    _working
      ..clear()
      ..addAll(saved.workingBar);
    _badSizes.clear();
    _badWorking.clear();
    _seen = {};
    _unreadable = file.unreadable;
    statusText = '';
    notifyListeners();
  }

  /// The sensors of the dive logs the app keeps in [folder] (read on
  /// another isolate): where each was seen, and the ones not saved yet
  /// added after the saved ones, by serial.
  Future<void> readKept(String folder) async {
    final opened = _opened;
    _reading = true;
    notifyListeners();
    Map<String, SensorSeen> found;
    try {
      found = await Isolate.run(() => keptTankSensors(folder));
    } on Object {
      found = {};
    }
    if (_disposed || opened != _opened) {
      return;
    }
    _reading = false;
    _seen = found;
    final fresh = [
      for (final serial in found.keys.toList()..sort())
        if (!_names.containsKey(serial)) serial,
    ];
    for (final serial in fresh) {
      _order.add(serial);
      _names[serial] = 'Tank $serial';
    }
    if (fresh.isNotEmpty) {
      statusText =
          '${fresh.length} new sensor(s) from your dive logs: name them '
          'and Save.';
    }
    notifyListeners();
  }

  void setName(String serial, String name) {
    if (_names.containsKey(serial)) {
      _names[serial] = name;
    }
  }

  /// The name on a sidemount overlay; empty for the same name there.
  void setSidemountName(String serial, String name) {
    if (!_names.containsKey(serial)) {
      return;
    }
    if (name.trim().isEmpty) {
      _sidemount.remove(serial);
    } else {
      _sidemount[serial] = name;
    }
  }

  /// The side the tank is worn on in sidemount; `null` for neither.
  void setSide(String serial, TankSide? side) {
    if (!_names.containsKey(serial)) {
      return;
    }
    if (side == null) {
      _sides.remove(serial);
    } else {
      _sides[serial] = side;
    }
    notifyListeners();
  }

  /// A size typed in (a comma for the decimal point too): litres, or with
  /// imperial [units] cubic feet at the tank's rated pressure. Empty
  /// clears it.
  void setSize(
    String serial,
    String text, {
    UnitSystem units = UnitSystem.metric,
  }) {
    if (!_names.containsKey(serial)) {
      return;
    }
    final typed = text.trim().replaceAll(',', '.');
    final value = double.tryParse(typed);
    final imperial = units == UnitSystem.imperial;
    // The litres are kept to 0.01, which gives the cubic feet back to 0.1.
    final litres = value == null
        ? null
        : imperial
        ? (litresOfCubicFeet(value, workingBarOf(serial)) * 100).round() / 100
        : value;
    final wasBad = _badSizes.contains(serial);
    if (typed.isEmpty) {
      _sizes.remove(serial);
      _working.remove(serial);
      _badSizes.remove(serial);
    } else if (litres != null && validTankSize(litres)) {
      _sizes[serial] = litres;
      if (imperial) {
        _working[serial] = workingBarOf(serial);
      }
      _badSizes.remove(serial);
    } else {
      _sizes.remove(serial);
      _badSizes.add(serial);
    }
    if (wasBad != _badSizes.contains(serial)) {
      notifyListeners();
    }
  }

  /// The rated pressure typed in, in psi: the tank keeps its cubic feet,
  /// so its litres follow.
  void setWorkingPsi(String serial, String text) {
    if (!_names.containsKey(serial)) {
      return;
    }
    final psi = double.tryParse(text.trim().replaceAll(',', '.'));
    final bar = psi == null ? null : psi / psiPerBar;
    final wasBad = _badWorking.contains(serial);
    if (bar != null && validWorkingBar(bar)) {
      final litres = _sizes[serial];
      if (litres != null) {
        final cubicFeet = cubicFeetOf(litres, workingBarOf(serial));
        final next = (litresOfCubicFeet(cubicFeet, bar) * 100).round() / 100;
        if (validTankSize(next)) {
          _sizes[serial] = next;
        }
      }
      _working[serial] = bar;
      _badWorking.remove(serial);
    } else {
      _badWorking.add(serial);
    }
    if (wasBad != _badWorking.contains(serial)) {
      notifyListeners();
    }
  }

  /// A row dragged from place [from] to place [to] in the tank order.
  void reorder(int from, int to) {
    if (from < 0 || from >= _order.length) {
      return;
    }
    _order.insert(to.clamp(0, _order.length - 1), _order.removeAt(from));
    notifyListeners();
  }

  /// Saves the sensors into `config.yaml` (an empty name as
  /// `Tank <serial>`), keeping whatever else the file holds. The path
  /// saved to, or `null` with [statusText] set when it could not be
  /// written.
  String? save() {
    final file = config.tankConfig();
    try {
      config.saveConfigYaml(
        file.withTanks(
          TankConfig(
            {
              for (final serial in _order)
                serial: _names[serial]!.trim().isEmpty
                    ? 'Tank $serial'
                    : _names[serial]!.trim(),
            },
            Map.of(_sizes),
            {
              for (final MapEntry(:key, :value) in _sidemount.entries)
                if (value.trim().isNotEmpty) key: value.trim(),
            },
            Map.of(_sides),
            {
              for (final MapEntry(:key, :value) in _working.entries)
                if (_sizes.containsKey(key)) key: value,
            },
          ),
        ),
      );
    } on FileSystemException catch (e) {
      statusText = 'Could not save: ${e.message}';
      notifyListeners();
      return null;
    }
    _unreadable = false;
    notifyListeners();
    return config.configYamlPath;
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The Tank Sensor Names window: the sensors of the kept Garmin logs, a
/// block per sensor with its name, its name and side in sidemount and its
/// size, dragged into the tank order, and Save. [onSaved] is told when the
/// names are saved.
class TankNamesDialog extends StatelessWidget {
  const TankNamesDialog({
    super.key,
    required this.editor,
    this.units = UnitSystem.metric,
    this.onSaved,
  });

  final TankNamesEditor editor;

  /// Litres, or cubic feet at a rated pressure.
  final UnitSystem units;
  final VoidCallback? onSaved;

  Future<void> _save(BuildContext context) async {
    final c = editor;
    if (c.unreadable) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Replace the sensor names file?'),
          content: Text(
            '${c.path} cannot be read. Saving replaces what it holds with '
            'these names.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (!(replace ?? false)) {
        return;
      }
    }
    final saved = c.save();
    if (saved != null) {
      onSaved?.call();
      if (context.mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('Saved')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: editor,
    builder: (context, _) {
      final c = editor;
      final rows = c.rows;
      return AlertDialog(
        title: const Text('Tank Sensor Names'),
        // Scrolls on a phone, where the fields wrap and outgrow the screen.
        content: SingleChildScrollView(
          child: SizedBox(
            width: 640,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                const Text(
                  'The tank sensors of your Garmin dive logs. Give each a '
                  'name. The two sidemount fields are for overlays with two '
                  'tanks: the side the tank is worn on, and another name '
                  'there if you want one.',
                ),
                if (rows.isEmpty)
                  MutedText(
                    c.reading
                        ? 'Reading your dive logs…'
                        : 'No tank sensors yet. Import Garmin dive logs on '
                              'the Dive Logs page and their sensors are '
                              'listed here.',
                  )
                else
                  ReorderableListView(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    onReorderItem: c.reorder,
                    children: [
                      for (final (i, row) in rows.indexed)
                        _SensorBlock(
                          key: ValueKey(row.serial),
                          editor: c,
                          row: row,
                          index: i,
                          units: units,
                          reading: c.reading,
                        ),
                    ],
                  ),
                if (rows.length > 1)
                  const MutedText(
                    'Drag a sensor by its handle to change the order: with '
                    'several tanks on a dive, an overlay with one tank shows '
                    'the first.',
                  ),
                if (c.statusText.isNotEmpty) MutedText(c.statusText),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: c.canSave ? () => _save(context) : null,
            child: const Text('Save'),
          ),
        ],
      );
    },
  );
}

class _SensorBlock extends StatelessWidget {
  const _SensorBlock({
    super.key,
    required this.editor,
    required this.row,
    required this.index,
    required this.units,
    required this.reading,
  });

  final TankNamesEditor editor;
  final TankRow row;
  final int index;
  final UnitSystem units;
  final bool reading;

  @override
  Widget build(BuildContext context) {
    final c = editor;
    final serial = row.serial;
    final imperial = units == UnitSystem.imperial;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.only(top: 2, right: 4),
              child: Tooltip(
                message: 'Drag to change the order',
                child: Icon(Icons.drag_handle),
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SelectableText(
                      'Sensor $serial',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    MutedText(seenText(row.seen, reading: reading)),
                  ],
                ),
                // On a phone two fields share a line.
                LayoutBuilder(
                  builder: (context, box) {
                    final narrow = box.maxWidth < 420;
                    final half = (box.maxWidth - 8) / 2;
                    return Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.end,
                      children: [
                        SizedBox(
                          width: narrow ? half : 150,
                          child: TextFormField(
                            key: ValueKey('name-$serial'),
                            initialValue: row.name,
                            decoration: const InputDecoration(
                              isDense: true,
                              labelText: 'Name',
                            ),
                            onChanged: (v) => c.setName(serial, v),
                          ),
                        ),
                        SizedBox(
                          width: narrow ? half : 150,
                          child: TextFormField(
                            key: ValueKey('sidemount-$serial'),
                            initialValue: row.sidemountName,
                            decoration: InputDecoration(
                              isDense: true,
                              labelText: 'Sidemount name',
                              hintText: 'The same',
                              floatingLabelBehavior:
                                  FloatingLabelBehavior.always,
                            ),
                            onChanged: (v) => c.setSidemountName(serial, v),
                          ),
                        ),
                        SizedBox(
                          width: narrow ? half : 110,
                          child: DropdownButtonFormField<TankSide?>(
                            key: ValueKey('side-$serial'),
                            initialValue: row.side,
                            isDense: true,
                            decoration: const InputDecoration(
                              isDense: true,
                              labelText: 'Sidemount side',
                            ),
                            items: const [
                              DropdownMenuItem(child: Text('–')),
                              DropdownMenuItem(
                                value: TankSide.left,
                                child: Text('Left'),
                              ),
                              DropdownMenuItem(
                                value: TankSide.right,
                                child: Text('Right'),
                              ),
                            ],
                            onChanged: (v) => c.setSide(serial, v),
                          ),
                        ),
                        SizedBox(
                          width: narrow ? half : 90,
                          child: TextFormField(
                            key: ValueKey('size-$serial'),
                            initialValue: c.sizeText(serial, units),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              labelText: 'Size',
                              suffixText: imperial ? 'cu ft' : 'l',
                              errorText: c.badSize(serial)
                                  ? (imperial ? 'Not a size' : '0-100')
                                  : null,
                            ),
                            onChanged: (v) =>
                                c.setSize(serial, v, units: units),
                          ),
                        ),
                        if (imperial)
                          SizedBox(
                            width: narrow ? half : 90,
                            child: TextFormField(
                              key: ValueKey('working-$serial'),
                              initialValue: c.workingText(serial),
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                isDense: true,
                                labelText: 'Rated at',
                                suffixText: 'psi',
                                errorText: c.badWorking(serial)
                                    ? '725-5800'
                                    : null,
                              ),
                              onChanged: (v) => c.setWorkingPsi(serial, v),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Where a sensor was seen, as its block says it.
String seenText(SensorSeen? seen, {bool reading = false}) {
  if (seen == null) {
    return reading ? '' : 'not in your dive logs';
  }
  final dives = seen.dives == 1 ? '1 dive' : '${seen.dives} dives';
  final last = seen.last;
  return last == null
      ? dives
      : '$dives, last ${formatNaive(last).substring(0, 10)}';
}

/// A number as a field shows it, with at most [decimals] decimals and no
/// zeros at its end: `12`, `11.1`, `77.4`.
String _number(double value, int decimals) {
  final text = value.toStringAsFixed(decimals);
  return text.contains('.') ? text.replaceFirst(RegExp(r'\.?0+$'), '') : text;
}
