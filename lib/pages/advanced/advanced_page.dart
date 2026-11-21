/// The Advanced page on the desktop (Python `qml/AdvancedPage.qml`): the
/// unit system, the folders of the user's files, the sensor names and the
/// external tools.
library;

import 'package:flutter/material.dart';
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/engine/desktop/tool_finder.dart';
import 'package:uwmedia_app/engine/file_picks.dart' as fs;
import 'package:uwmedia_app/pages/advanced/advanced_controller.dart';
import 'package:uwmedia_app/pages/shared/tank_names.dart';
import 'package:uwmedia_app/pages/shared/watermarks_section.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

/// The page's file dialogs, so that a test can answer for them.
abstract interface class AdvancedDialogs {
  Future<String?> pickFile(String initialDirectory);
  Future<String?> pickFolder(String initialDirectory);
}

class SystemAdvancedDialogs implements AdvancedDialogs {
  const SystemAdvancedDialogs();

  @override
  Future<String?> pickFile(String initialDirectory) async =>
      (await fs.openFile(initialDirectory: initialDirectory))?.path;

  @override
  Future<String?> pickFolder(String initialDirectory) =>
      fs.getDirectoryPath(initialDirectory: initialDirectory);
}

class AdvancedPage extends StatefulWidget {
  const AdvancedPage({
    super.key,
    required this.services,
    this.dialogs = const SystemAdvancedDialogs(),
    this.finder,
  });

  final AppServices services;
  final AdvancedDialogs dialogs;

  /// Finds the tools; by default on this machine.
  final ToolFinder Function()? finder;

  @override
  State<AdvancedPage> createState() => _AdvancedPageState();
}

class _AdvancedPageState extends State<AdvancedPage> {
  late final AdvancedController controller = AdvancedController(
    config: widget.services.config,
    home: widget.services.home,
    dataDir: widget.services.dataDir,
    finder: widget.finder ?? ToolFinder.forThisMachine,
    onUnitsChanged: () => widget.services.unitsRevision.value++,
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _changeFolder(String kind) async {
    final path = await widget.dialogs.pickFolder(
      controller.dialogDir(folderDialogField(kind)),
    );
    if (path != null && mounted) {
      controller.setFolder(kind, path);
    }
  }

  Future<void> _changeTool(String tool) async {
    final path = await widget.dialogs.pickFile(
      controller.dialogDir(toolDirField),
    );
    if (path == null || !mounted) {
      return;
    }
    final error = await controller.setTool(tool, path);
    if (error != null && mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Not a valid $tool executable'),
          content: Text(error),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  Widget _row(
    String label,
    String value,
    VoidCallback onChange,
    VoidCallback onReset,
  ) => Row(
    spacing: 8,
    children: [
      SizedBox(width: 140, child: Text(label)),
      Expanded(
        child: SelectableText(
          value,
          maxLines: 1,
          style: const TextStyle(fontSize: 12),
        ),
      ),
      OutlinedButton(onPressed: onChange, child: const Text('Change…')),
      TextButton(onPressed: onReset, child: const Text('Reset')),
    ],
  );

  Future<void> _tankNames() async {
    controller.openTankNames();
    await showDialog<void>(
      context: context,
      builder: (context) => TankNamesDialog(
        editor: controller.tanks,
        scanLogs: () async {
          final folder = await widget.dialogs.pickFolder(
            controller.dialogDir(fitLogsDirField),
          );
          if (folder != null) {
            await controller.scanFolder(folder);
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller;
      return PageFrame(
        title: 'Settings',
        maxWidth: 820,
        children: [
          SectionCard(
            title: 'Units',
            children: [
              Tooltip(
                message:
                    'Depths, pressures and temperatures everywhere in the app: '
                    'overlays, Log Viewer, Dive Profile Builder. The dive logs '
                    'stay as recorded.',
                child: DropdownButton<UnitSystem>(
                  value: c.units,
                  items: [
                    for (final system in UnitSystem.values)
                      DropdownMenuItem(
                        value: system,
                        child: Text(system.label),
                      ),
                  ],
                  onChanged: (v) => c.units = v!,
                ),
              ),
            ],
          ),
          SectionCard(
            title: 'Locations',
            children: [
              _row(
                'Layouts',
                c.layoutsDirText,
                () => _changeFolder('layouts'),
                () => c.resetFolder('layouts'),
              ),
              _row(
                'Templates',
                c.templatesDirText,
                () => _changeFolder('templates'),
                () => c.resetFolder('templates'),
              ),
              _row(
                'Color profiles',
                c.colorDirText,
                () => _changeFolder('color'),
                () => c.resetFolder('color'),
              ),
            ],
          ),
          WatermarksSection(services: widget.services),
          SectionCard(
            title: 'Sensor names',
            children: [
              const MutedText('Config file', size: 11),
              SelectableText(
                c.tankNamesPathText,
                style: const TextStyle(fontSize: 12),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: _tankNames,
                  child: const Text('Edit Tank Sensor Names…'),
                ),
              ),
            ],
          ),
          if (widget.services.capabilities.nativeVideo &&
              widget.services.capabilities.externalTools)
            SectionCard(
              title: 'Video engine',
              children: [
                DropdownButton<String>(
                  key: const ValueKey('video engine'),
                  value: c.videoEngine,
                  items: [
                    for (final MapEntry(:key, :value)
                        in videoEngineLabels.entries)
                      DropdownMenuItem(value: key, child: Text(value)),
                  ],
                  onChanged: (v) => c.videoEngine = v!,
                ),
                const MutedText(
                  'What writes the videos of the Color and Resize pages and '
                  "of the Overlay Generator. macOS's own engine is faster "
                  'and leaves the Mac free for other work; it reads no MKV '
                  'or AVI. The previews and the metadata use FFmpeg and '
                  'ExifTool either way.',
                  size: 12,
                ),
              ],
            ),
          if (widget.services.capabilities.externalTools)
            SectionCard(
              title: 'External tools',
              children: [
                _row(
                  'FFmpeg',
                  c.ffmpegPathText,
                  () => _changeTool(toolFfmpeg),
                  () => c.resetTool(toolFfmpeg),
                ),
                _row(
                  'ExifTool',
                  c.exiftoolPathText,
                  () => _changeTool(toolExiftool),
                  () => c.resetTool(toolExiftool),
                ),
              ],
            ),
          if (c.statusText.isNotEmpty) MutedText(c.statusText),
        ],
      );
    },
  );
}

/// The Tank Sensor Names window: names, order, add, scan, save.
