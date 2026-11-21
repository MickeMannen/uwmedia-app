/// The Dive Logs page (spec §12.3; on the desktop too since §10.57): logs
/// picked with the document picker (a Garmin "Export Original" zip too),
/// or on a computer dropped on the page, kept in the app, their dives
/// listed, a log removed; and how to get the logs off Garmin Connect and
/// Shearwater Cloud.
library;

import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/pages/display_paths.dart';
import 'package:uwmedia_app/core/units/units.dart' as u;
import 'package:uwmedia_app/core/util/py_strftime.dart';
import 'package:uwmedia_app/engine/app_log.dart';
import 'package:uwmedia_app/engine/file_picks.dart' as fs;
import 'package:uwmedia_app/engine/log_files.dart';
import 'package:uwmedia_app/engine/log_store.dart';
import 'package:uwmedia_app/pages/shared/logs_folder.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

const _garminUrl = 'https://connect.garmin.com/';
const _shearwaterUrl = 'https://shearwater.com/pages/shearwater-cloud';

/// The page's state: the kept logs and their dives.
class DiveLogsController extends ChangeNotifier {
  DiveLogsController({
    required this.store,
    required this.tanks,
    this.onChanged,
  });

  final LogStore store;
  final TankConfig Function() tanks;

  /// Told when the kept logs changed here (imported, removed).
  final VoidCallback? onChanged;

  List<DiveSummary> dives = [];
  List<String> warnings = [];
  String status = '';
  bool busy = false;
  bool _disposed = false;
  int _loads = 0;

  /// The dives of the kept logs, read off the UI isolate.
  Future<void> load() async {
    final ticket = ++_loads;
    busy = true;
    notifyListeners();
    final folder = store.folder.path;
    final config = tanks();
    final LogSummaries read = await compute(
      (String dir) => LogStore(Directory(dir)).summaries(config),
      folder,
    );
    // A later load (a log opened meanwhile) has the newer list.
    if (_disposed || ticket != _loads) {
      return;
    }
    dives = read.dives..sort((a, b) => b.start.compareTo(a.start));
    if (read.warnings.join() != warnings.join()) {
      for (final warning in read.warnings) {
        AppLog.note('Dive Logs', warning);
      }
    }
    warnings = read.warnings;
    busy = false;
    notifyListeners();
  }

  /// What was dropped on the page: the files as they are, a folder's
  /// logs (not its subfolders'), then [import].
  Future<void> drop(List<String> paths) async {
    if (busy) {
      return;
    }
    final files = <String>[];
    for (final path in paths) {
      if (FileSystemEntity.isDirectorySync(path)) {
        try {
          files.addAll(logFilesIn(path));
        } on FileSystemException {
          // An unreadable folder gives no logs.
        }
      } else {
        files.add(path);
      }
    }
    if (files.isEmpty) {
      status = 'No dive logs among what was dropped.';
      notifyListeners();
      return;
    }
    await import(files);
  }

  /// The picked files copied in, then the list read again.
  Future<void> import(List<String> paths) async {
    if (paths.isEmpty) {
      return;
    }
    status = importSummary(store.import(paths));
    // Into the app's log (spec §10.76), with the files picked.
    AppLog.note('Dive Logs', '${paths.map(p.basename).join(', ')}: $status');
    onChanged?.call();
    await load();
  }

  /// The log file [name] and its dives removed.
  Future<void> remove(String name) async {
    store.remove(name);
    status = 'Removed $name.';
    AppLog.note('Dive Logs', status);
    onChanged?.call();
    await load();
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

/// The page's file picker, so that a test can answer for it.
abstract interface class DiveLogsDialogs {
  Future<List<String>> pickLogs();
}

class SystemDiveLogsDialogs implements DiveLogsDialogs {
  const SystemDiveLogsDialogs();

  @override
  Future<List<String>> pickLogs() async => [
    for (final file in await fs.openFiles()) file.path,
  ];
}

class DiveLogsPage extends StatefulWidget {
  const DiveLogsPage({
    super.key,
    required this.services,
    this.dialogs = const SystemDiveLogsDialogs(),
  });

  final AppServices services;
  final DiveLogsDialogs dialogs;

  @override
  State<DiveLogsPage> createState() => _DiveLogsPageState();
}

class _DiveLogsPageState extends State<DiveLogsPage> {
  // Files dragged over the page.
  bool _dragging = false;

  late final controller = DiveLogsController(
    store: widget.services.logStore,
    tanks: () => widget.services.config.tankConfig().tanks,
    onChanged: () => widget.services.keptLogsRevision.value++,
  );

  @override
  void initState() {
    super.initState();
    final services = widget.services;
    if (services.logsRevision.value > 0) {
      controller.status = services.logsMessage;
    }
    services.logsRevision.addListener(_opened);
    controller.load();
  }

  // Logs opened with UWMedia were kept: listed again, and what was kept
  // said.
  void _opened() {
    controller.status = widget.services.logsMessage;
    controller.load();
  }

  @override
  void dispose() {
    widget.services.logsRevision.removeListener(_opened);
    controller.dispose();
    super.dispose();
  }

  // The dive-logs folder a desktop user had set before the logs were
  // kept in the app: its logs imported, or the offer put away.
  Future<void> _importFolder(String folder) async {
    List<String> files;
    try {
      files = logFilesIn(folder);
    } on FileSystemException {
      files = const [];
    }
    if (files.isEmpty) {
      answerLogsFolderOffer(widget.services.config, folder);
      setState(() => controller.status = 'No dive logs found in $folder.');
      return;
    }
    // Answered once the logs are in: an import that fails leaves the
    // offer standing.
    await controller.import(files);
    if (mounted) {
      setState(() => answerLogsFolderOffer(widget.services.config, folder));
    }
  }

  Widget _folderOffer(String folder) => SectionCard(
    title: 'Your dive-logs folder',
    children: [
      Text(
        'The app now reads only the dive logs kept here, not the folder '
        '${contractHomePath(folder, widget.services.home) ?? folder}. '
        'Import that folder\'s logs? They are copied; the folder is left '
        'as it is.',
        style: const TextStyle(fontSize: 13),
      ),
      Wrap(
        spacing: 8,
        children: [
          FilledButton(
            onPressed: controller.busy ? null : () => _importFolder(folder),
            child: const Text('Import its logs'),
          ),
          TextButton(
            onPressed: () => setState(
              () => answerLogsFolderOffer(widget.services.config, folder),
            ),
            child: const Text('Not now'),
          ),
        ],
      ),
    ],
  );

  Future<void> _open(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Widget? _offer() {
    final folder = logsFolderToOffer(widget.services.config);
    return folder == null ? null : _folderOffer(folder);
  }

  Widget _recipe(String title, List<String> steps, String url, String link) =>
      SectionCard(
        title: title,
        children: [
          for (final (i, step) in steps.indexed)
            Text('${i + 1}. $step', style: const TextStyle(fontSize: 13)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: () => _open(url), child: Text(link)),
          ),
        ],
      );

  // "3 dives" or, when the files are not one dive each, "5 dives in 2
  // logs". The same dive in a second log is counted once.
  static String _monthCount(List<MapEntry<String, List<DiveSummary>>> files) {
    final dives = files.fold(
      0,
      (n, f) => n + f.value.where((dive) => dive.copyOf == null).length,
    );
    final text = '$dives dive${dives == 1 ? '' : 's'}';
    return dives == files.length
        ? text
        : '$text in ${files.length} log${files.length == 1 ? '' : 's'}';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller;
      final desktop = widget.services.capabilities.desktop;
      final units = u.normalizeUnits(
        widget.services.config.settings()['units'],
      );
      final byFile = <String, List<DiveSummary>>{};
      for (final dive in c.dives) {
        (byFile[dive.file] ??= []).add(dive);
      }
      // The files by the month of their newest dive, the newest month
      // first (the dives are sorted so): a long list stays folded.
      final byMonth = <String, List<MapEntry<String, List<DiveSummary>>>>{};
      for (final entry in byFile.entries) {
        final month = pyStrftime(entry.value.first.start, '%B %Y');
        (byMonth[month] ??= []).add(entry);
      }
      final page = PageFrame(
        title: 'Dive Logs',
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: c.busy
                    ? null
                    : () async => c.import(await widget.dialogs.pickLogs()),
                child: const Text('Import logs…'),
              ),
            ],
          ),
          MutedText(
            'Garmin .fit (or the zip Garmin Connect gives), UDDF, Subsurface '
            'and Shearwater exports. The logs are kept in the app; the Color '
            'page finds the dive for each photo and video in them.'
            '${desktop ? ' The Overlay Generator does too. Logs, a zip or '
                      'a folder can also be dropped on this page.' : ''}',
            size: 13,
          ),
          if (desktop) ?_offer(),
          if (c.busy) const LinearProgressIndicator(),
          if (c.status.isNotEmpty) MutedText(c.status, size: 13),
          if (c.dives.isEmpty && !c.busy)
            const MutedText('No dive logs yet.', size: 13),
          for (final (i, MapEntry(key: month, value: files))
              in byMonth.entries.indexed)
            ExpansionTile(
              key: PageStorageKey(month),
              tilePadding: EdgeInsets.zero,
              initiallyExpanded: i == 0,
              title: Text(month),
              subtitle: MutedText(_monthCount(files), size: 12),
              children: [
                for (final MapEntry(key: file, value: dives) in files)
                  SectionCard(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              file,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: 'Remove this log',
                            onPressed: c.busy ? null : () => c.remove(file),
                          ),
                        ],
                      ),
                      for (final dive in dives)
                        if (dive.copyOf case final other?)
                          MutedText(
                            '${pyStrftime(dive.start, '%Y-%m-%d %H:%M')} · '
                            'the same dive as in $other',
                            size: 13,
                          )
                        else
                          Text(
                            '${pyStrftime(dive.start, '%Y-%m-%d %H:%M')} · '
                            '${(dive.seconds / 60).round()} min · '
                            '${u.depth(dive.maxDepth, units).toStringAsFixed(1)} '
                            '${u.depthLabel(units)}'
                            '${dive.device.isEmpty ? '' : ' · ${dive.device}'}',
                            style: const TextStyle(fontSize: 13),
                          ),
                    ],
                  ),
              ],
            ),
          for (final warning in c.warnings) MutedText(warning, size: 12),
          const Text(
            'How to get your logs',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          _recipe(
            'Garmin',
            [
              desktop
                  ? 'Open connect.garmin.com in the browser and sign in.'
                  : 'Open connect.garmin.com in the phone\'s browser and '
                        'sign in (the Garmin Connect app cannot export).',
              'Open the dive, then the gear menu, then "Export Original".',
              desktop
                  ? 'The zip lands in Downloads: import it here as it is.'
                  : 'The zip lands in Files / Downloads: import it here as '
                        'it is.',
            ],
            _garminUrl,
            'Open Garmin Connect',
          ),
          _recipe(
            'Shearwater',
            [
              'In Shearwater Cloud, open the dive and export it as UDDF.',
              desktop
                  ? 'Import the file here.'
                  : 'Share the file to UWMedia, or save it to Files and '
                        'import it here.',
            ],
            _shearwaterUrl,
            'About Shearwater Cloud',
          ),
        ],
      );
      if (!desktop) {
        return page;
      }
      // Only while the page is shown and nothing covers it: the shell
      // keeps the other pages, and a dialog, under it.
      return DropTarget(
        enable:
            Visibility.of(context) &&
            (ModalRoute.of(context)?.isCurrent ?? true),
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (details) {
          setState(() => _dragging = false);
          c.drop([for (final file in details.files) file.path]);
        },
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: _dragging ? Border.all(color: accent, width: 2) : null,
          ),
          child: page,
        ),
      );
    },
  );
}
