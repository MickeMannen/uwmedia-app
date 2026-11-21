/// The phones' Settings page: units, the default colour profile, output
/// names, hardware encoding, and the tank sensor names with their order
/// (Garmin logs picked as files, a phone has no folder to scan).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/engine/file_picks.dart' as fs;
import 'package:uwmedia_app/pages/settings/settings_controller.dart';
import 'package:uwmedia_app/pages/shared/tank_names.dart';
import 'package:uwmedia_app/pages/shared/watermarks_section.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

/// The page's file picker, so that a test can answer for it.
abstract interface class SettingsDialogs {
  /// Garmin `.fit` logs, several at once.
  Future<List<String>> pickLogs();
}

class SystemSettingsDialogs implements SettingsDialogs {
  const SystemSettingsDialogs();

  @override
  Future<List<String>> pickLogs() async => [
    for (final file in await fs.openFiles()) file.path,
  ];
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.services,
    this.dialogs = const SystemSettingsDialogs(),
    this.bundledColorYaml,
  });

  final AppServices services;
  final SettingsDialogs dialogs;

  /// The bundled profiles' text; read from the assets when not given.
  final String? bundledColorYaml;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  SettingsController? controller;

  @override
  void initState() {
    super.initState();
    final given = widget.bundledColorYaml;
    (given == null
            ? rootBundle.loadString('assets/color.yaml')
            : Future.value(given))
        .then((yaml) {
          if (!mounted) {
            return;
          }
          setState(
            () => controller = SettingsController(
              config: widget.services.config,
              home: widget.services.home,
              bundledColorYaml: yaml,
              onUnitsChanged: () => widget.services.unitsRevision.value++,
            ),
          );
        });
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  Future<void> _tankNames() async {
    final c = controller!;
    c.tanks.open();
    await showDialog<void>(
      context: context,
      builder: (context) => TankNamesDialog(
        editor: c.tanks,
        scanLabel: 'Read Garmin Logs…',
        scanLogs: () async {
          final paths = await widget.dialogs.pickLogs();
          if (paths.isNotEmpty) {
            await c.tanks.scanFiles(paths);
          }
        },
      ),
    );
  }

  Widget _choice<T>(
    String label,
    T value,
    Map<T, String> items,
    ValueChanged<T> onChanged,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(label),
      DropdownButton<T>(
        isExpanded: true,
        value: value,
        items: [
          for (final MapEntry(:key, :value) in items.entries)
            DropdownMenuItem(
              value: key,
              child: Text(value, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) => onChanged(v as T),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => PageFrame(
        title: 'Settings',
        children: [
          SectionCard(
            title: 'Units',
            children: [
              _choice(
                'Depths, pressures and temperatures everywhere in the app',
                c.units,
                {for (final s in UnitSystem.values) s: s.label},
                (v) => c.units = v,
              ),
            ],
          ),
          SectionCard(
            title: 'Colour and output',
            children: [
              _choice('Colour profile', c.profile, {
                for (final name in c.profiles) name: name,
              }, (v) => c.profile = v),
              _choice('Output names', c.filenameFormat, {
                for (final label in c.filenameFormats) label: label,
              }, (v) => c.filenameFormat = v),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Hardware encoding'),
                subtitle: const MutedText(
                  "Use the phone's video encoder: much faster, and the "
                  'usual choice.',
                  size: 12,
                ),
                value: c.hwAccel,
                onChanged: (v) => c.hwAccel = v,
              ),
            ],
          ),
          WatermarksSection(services: widget.services),
          SectionCard(
            title: 'Tank sensors',
            children: [
              const MutedText(
                'Name your Garmin tank sensors and set their order: an '
                "overlay's primary tank is the first one listed that the "
                'dive has.',
                size: 13,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: _tankNames,
                  child: const Text('Tank Sensor Names…'),
                ),
              ),
            ],
          ),
          if (c.statusText.isNotEmpty) MutedText(c.statusText, size: 13),
        ],
      ),
    );
  }
}
