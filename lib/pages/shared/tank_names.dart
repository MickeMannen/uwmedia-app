/// The tank sensor names and their order (Python
/// `backends/advanced_backend.py`, the Tank Sensor Names window): Garmin
/// tank sensor serials mapped to friendly names, the order being the tank
/// order. Edited on the desktop's Advanced page and the phones' Settings
/// page, saved into `config.yaml`. The port adds each tank's size, for
/// VSAC on dives whose log has none (spec §10.54).
library;

import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/parsers/fit_reader.dart';
import 'package:uwmedia_app/core/parsers/garmin.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

const fitLogsDirField = 'advanced_fit_logs_dialog_dir';

/// The tank serials of the Garmin `.fit` logs directly in [folder].
Set<String> fitTankSerials(String folder) => fitTankSerialsOf([
  for (final entry in Directory(folder).listSync())
    if (entry is File) entry.path,
]);

/// The tank serials of the Garmin `.fit` logs among [paths].
Set<String> fitTankSerialsOf(List<String> paths) => {
  for (final path in paths)
    if (p.extension(path).toLowerCase() == '.fit')
      ...uniqueTankSerials(readFitMessages(File(path).readAsBytesSync())),
};

class TankNamesEditor extends ChangeNotifier {
  TankNamesEditor({required this.config, required this.home});

  final ConfigStore config;
  final String home;

  Map<String, String> _tanks = {};
  Map<String, double> _sizes = {};
  final Set<String> _badSizes = {};
  String statusText = '';
  bool _unreadable = false;
  bool _disposed = false;

  /// The names in the saved order: the tank order (first is an overlay's
  /// primary tank).
  List<(String serial, String name)> get rows => [
    for (final MapEntry(:key, :value) in _tanks.entries) (key, value),
  ];

  /// The size of the tank with this serial in litres, if it has one.
  double? sizeOf(String serial) => _sizes[serial];

  /// The size typed for this serial is not a size: Save is off.
  bool badSize(String serial) => _badSizes.contains(serial);

  bool get canSave => _badSizes.isEmpty;

  /// `config.yaml` is there but cannot be read: saving replaces it.
  bool get unreadable => _unreadable;

  String get path => config.configYamlPath;

  /// The dialogs' folders: the FIT logs' starts in Downloads.
  String dialogDir(String field) => config.dialogDirFor(
    field,
    home: home,
    start: field == fitLogsDirField ? StartFolder.downloads : StartFolder.home,
  );

  /// The window opened: the saved names.
  void open() {
    final file = config.tankConfig();
    _tanks = Map.of(file.tanks.tanks);
    _sizes = Map.of(file.tanks.sizes);
    _badSizes.clear();
    _unreadable = file.unreadable;
    statusText = '';
    notifyListeners();
  }

  void setName(String serial, String name) {
    if (_tanks.containsKey(serial)) {
      _tanks[serial] = name;
    }
  }

  /// A size typed in, in litres (a comma for the decimal point too); empty
  /// clears it.
  void setSize(String serial, String text) {
    if (!_tanks.containsKey(serial)) {
      return;
    }
    final typed = text.trim().replaceAll(',', '.');
    final litres = double.tryParse(typed);
    final wasBad = _badSizes.contains(serial);
    if (typed.isEmpty) {
      _sizes.remove(serial);
      _badSizes.remove(serial);
    } else if (litres != null && validTankSize(litres)) {
      _sizes[serial] = litres;
      _badSizes.remove(serial);
    } else {
      _sizes.remove(serial);
      _badSizes.add(serial);
    }
    if (wasBad != _badSizes.contains(serial)) {
      notifyListeners();
    }
  }

  void remove(String serial) {
    _tanks.remove(serial);
    _sizes.remove(serial);
    _badSizes.remove(serial);
    notifyListeners();
  }

  /// Moves a row up ([step] -1) or down (+1) in the tank order.
  void move(String serial, int step) {
    final serials = _tanks.keys.toList();
    final at = serials.indexOf(serial);
    final to = at + step;
    if (at < 0 || to < 0 || to >= serials.length) {
      return;
    }
    serials.insert(to, serials.removeAt(at));
    _tanks = {for (final s in serials) s: _tanks[s]!};
    notifyListeners();
  }

  /// A serial typed in; false when it is empty or already there.
  bool addSerial(String text) {
    final serial = text.trim();
    if (serial.isEmpty || _tanks.containsKey(serial)) {
      return false;
    }
    _tanks[serial] = 'Tank $serial';
    notifyListeners();
    return true;
  }

  /// The sensors of the Garmin logs in [folder] (read on another isolate),
  /// the new ones added.
  Future<void> scanFolder(String folder) async {
    try {
      config.rememberDialogDir(fitLogsDirField, folder);
    } on FileSystemException {
      // Only not kept.
    }
    await _scan(() => fitTankSerials(folder), 'that folder');
  }

  /// The sensors of the Garmin logs [paths] (a phone picks files, not a
  /// folder), the new ones added.
  Future<void> scanFiles(List<String> paths) =>
      _scan(() => fitTankSerialsOf(paths), 'those files');

  Future<void> _scan(Set<String> Function() read, String where) async {
    final Set<String> found;
    try {
      found = await Isolate.run(read);
    } on Object catch (e) {
      statusText = 'Failed to scan $where: $e';
      notifyListeners();
      return;
    }
    final fresh = [
      for (final serial in found.toList()..sort())
        if (!_tanks.containsKey(serial)) serial,
    ];
    for (final serial in fresh) {
      _tanks[serial] = 'Tank $serial';
    }
    statusText = found.isEmpty
        ? 'No tank sensors found in $where.'
        : 'Found ${found.length} sensor(s) in .fit files, added '
              '${fresh.length} new.';
    notifyListeners();
  }

  /// Saves the names (an empty one as `Tank <serial>`) and the sizes into
  /// `config.yaml`, keeping whatever else the file holds. The path saved to, or `null`
  /// with [statusText] set when it could not be written.
  String? save() {
    final file = config.tankConfig();
    try {
      config.saveConfigYaml(
        file.withTanks(
          TankConfig(
            {
              for (final MapEntry(:key, :value) in _tanks.entries)
                key: value.trim().isEmpty ? 'Tank $key' : value.trim(),
            },
            {
              for (final MapEntry(:key, :value) in _sizes.entries)
                if (_tanks.containsKey(key)) key: value,
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

/// The Tank Sensor Names window: a row per sensor with its size, Up, Down
/// and Remove, a serial typed in, the sensors of Garmin logs scanned in
/// ([scanLogs], with its button's label), and Save.
class TankNamesDialog extends StatefulWidget {
  const TankNamesDialog({
    super.key,
    required this.editor,
    required this.scanLogs,
    this.scanLabel = 'Scan Logs Folder…',
  });

  final TankNamesEditor editor;
  final Future<void> Function() scanLogs;
  final String scanLabel;

  @override
  State<TankNamesDialog> createState() => _TankNamesDialogState();
}

class _TankNamesDialogState extends State<TankNamesDialog> {
  final _serial = TextEditingController();

  @override
  void dispose() {
    _serial.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final c = widget.editor;
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
    if (saved != null && mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Sensor names saved to:\n$saved')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.editor,
    builder: (context, _) {
      final c = widget.editor;
      final rows = c.rows;
      return AlertDialog(
        title: const Text('Tank Sensor Names'),
        // Scrolls on a phone, where the rows wrap and outgrow the screen.
        content: SingleChildScrollView(
          child: SizedBox(
            width: 640,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                const Text(
                  'Map Garmin tank sensor serial numbers to friendly names (e.g. '
                  '"Left", "Micke01"). The order is the tank order: an '
                  "overlay's primary tank is the first one listed here that the "
                  'dive has, its secondary tank the next. The size (water volume '
                  'in litres, e.g. 11.1 for an AL80) gives VSAC for dives whose '
                  'log has none.',
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final (i, (serial, name)) in rows.indexed)
                        Wrap(
                          key: ValueKey(serial),
                          spacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            SizedBox(width: 130, child: SelectableText(serial)),
                            SizedBox(
                              width: 200,
                              child: TextFormField(
                                initialValue: name,
                                decoration: const InputDecoration(
                                  isDense: true,
                                ),
                                onChanged: (v) => c.setName(serial, v),
                              ),
                            ),
                            SizedBox(
                              width: 90,
                              child: TextFormField(
                                initialValue: _litres(c.sizeOf(serial)),
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: InputDecoration(
                                  isDense: true,
                                  hintText: 'Size',
                                  suffixText: 'l',
                                  errorText: c.badSize(serial) ? '0-100' : null,
                                ),
                                onChanged: (v) => c.setSize(serial, v),
                              ),
                            ),
                            TextButton(
                              onPressed: i == 0
                                  ? null
                                  : () => c.move(serial, -1),
                              child: const Text('Up'),
                            ),
                            TextButton(
                              onPressed: i == rows.length - 1
                                  ? null
                                  : () => c.move(serial, 1),
                              child: const Text('Down'),
                            ),
                            TextButton(
                              onPressed: () => c.remove(serial),
                              child: const Text('Remove'),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                Row(
                  spacing: 8,
                  children: [
                    const Flexible(child: Text('Add serial manually')),
                    Expanded(
                      child: TextField(
                        controller: _serial,
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: 'Serial number',
                        ),
                      ),
                    ),
                    OutlinedButton(
                      onPressed: () {
                        if (c.addSerial(_serial.text)) {
                          _serial.clear();
                        }
                      },
                      child: const Text('Add'),
                    ),
                  ],
                ),
                if (c.statusText.isNotEmpty) MutedText(c.statusText),
              ],
            ),
          ),
        ),
        actions: [
          OutlinedButton(
            onPressed: widget.scanLogs,
            child: Text(widget.scanLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: c.canSave ? _save : null,
            child: const Text('Save'),
          ),
        ],
      );
    },
  );
}

/// A size as the field shows it: `12`, `11.1`; empty for none.
String _litres(double? litres) => litres == null
    ? ''
    : litres == litres.roundToDouble()
    ? litres.toStringAsFixed(0)
    : '$litres';
