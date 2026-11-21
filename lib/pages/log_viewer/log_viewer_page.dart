/// The Log Viewer page (Python `qml/LogViewerPage.qml`): open dive logs,
/// see a working list of their dives, and the selected one as UWMedia
/// reads it, with its fields, tanks, charts, events and samples; Adjust
/// time and Merge for Garmin FIT logs save a new file.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/pages/log_viewer.dart';
import 'package:uwmedia_app/engine/file_picks.dart' as fs;
import 'package:uwmedia_app/pages/log_viewer/dive_charts.dart';
import 'package:uwmedia_app/pages/log_viewer/log_viewer_controller.dart';
import 'package:uwmedia_app/pages/shared/place_menu.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

const _textColor = Color(0xFFE0E0E0);
const _warnColor = Color(0xFFF59E0B);
const _errorColor = Color(0xFFEF4444);

/// The samples table's column widths, the last filling the row.
const _columnWidths = <double>[80, 80, 80, 80, 80, 60, 50, 40, 130, 54, 260];

/// The page's file dialogs, so that a test can answer for them.
abstract interface class LogViewerDialogs {
  Future<List<String>> openFiles(String initialDirectory);
  Future<String?> openFolder(String initialDirectory);
  Future<String?> save(String suggested, String title);
}

class SystemLogViewerDialogs implements LogViewerDialogs {
  const SystemLogViewerDialogs();

  static const _logs = fs.XTypeGroup(
    label: 'Dive logs',
    extensions: ['fit', 'uddf', 'ssrf', 'xml', 'csv', 'json'],
  );

  @override
  Future<List<String>> openFiles(String initialDirectory) async => [
    for (final file in await fs.openFiles(
      acceptedTypeGroups: const [_logs],
      initialDirectory: initialDirectory,
    ))
      file.path,
  ];

  @override
  Future<String?> openFolder(String initialDirectory) =>
      fs.getDirectoryPath(initialDirectory: initialDirectory);

  @override
  Future<String?> save(String suggested, String title) async =>
      (await fs.getSaveLocation(
        initialDirectory: p.dirname(suggested),
        suggestedName: p.basename(suggested),
        confirmButtonText: 'Save',
        acceptedTypeGroups: const [
          fs.XTypeGroup(label: 'Garmin FIT', extensions: ['fit']),
        ],
      ))?.path;
}

/// What the page's one button says.
const openLogsLabel = 'Open dive logs…';

class LogViewerPage extends StatefulWidget {
  const LogViewerPage({
    super.key,
    required this.services,
    this.dialogs = const SystemLogViewerDialogs(),
    this.reader,
  });

  final AppServices services;
  final LogViewerDialogs dialogs;

  /// How the logs are read; by default on another isolate.
  final LogReader? reader;

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage> {
  late final LogViewerController controller = widget.reader == null
      ? LogViewerController(
          config: widget.services.config,
          home: widget.services.home,
        )
      : LogViewerController(
          config: widget.services.config,
          home: widget.services.home,
          reader: widget.reader!,
        );
  final _listFocus = FocusNode();
  final _filter = TextEditingController();
  bool samplesOpen = false;

  void _unitsChanged() => controller.unitsChanged();

  @override
  void initState() {
    super.initState();
    widget.services.unitsRevision.addListener(_unitsChanged);
    // The field follows the controller when it resets the filter (another
    // dive selected); while the user types they are the same already.
    controller.addListener(() {
      if (_filter.text != controller.filterText) {
        _filter.text = controller.filterText;
      }
    });
  }

  @override
  void dispose() {
    widget.services.unitsRevision.removeListener(_unitsChanged);
    controller.dispose();
    _listFocus.dispose();
    _filter.dispose();
    super.dispose();
  }

  Future<void> _openFiles() async {
    final paths = await widget.dialogs.openFiles(controller.dialogFolder);
    if (mounted) {
      await controller.addFiles(paths);
    }
  }

  Future<void> _openFolder() async {
    final folder = await widget.dialogs.openFolder(controller.dialogFolder);
    if (folder != null && mounted) {
      await controller.addFolder(folder);
    }
  }

  // The logs kept in the app (the Dive Logs page).
  Future<void> _openImported() => controller.addFolder(
    widget.services.logStore.folder.path,
    remember: false,
  );

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final c = controller;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
        c.select(c.currentRow - 1);
      case LogicalKeyboardKey.arrowDown:
        c.select(c.currentRow + 1);
      case LogicalKeyboardKey.delete || LogicalKeyboardKey.backspace:
        c.removeSelected();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Widget _small(String text, VoidCallback? onPressed, String tip) => Tooltip(
    message: tip,
    child: TextButton(
      onPressed: onPressed,
      child: Text(text, style: const TextStyle(fontSize: 12)),
    ),
  );

  Widget _topCard() {
    final c = controller;
    return SectionCard(
      children: [
        Row(
          spacing: 8,
          children: [
            const Text(
              'DIVE LOGS',
              style: TextStyle(
                color: mutedText,
                fontSize: 12,
                letterSpacing: 1,
              ),
            ),
            // One button, as the other pages' (spec §10.67(g)).
            Tooltip(
              message:
                  'Garmin .fit, UDDF, Subsurface (.ssrf/.xml/.csv) and '
                  'Shearwater Cloud (.xml/.csv) and Suunto app (.json) logs; '
                  'several files at once, every log of a folder, or the '
                  'logs imported on the Dive Logs page. The dives are added '
                  'to the list.',
              child: PlaceMenuButton(
                label: openLogsLabel,
                icon: Icons.scuba_diving_outlined,
                enabled: !c.busy,
                places: [
                  (
                    icon: Icons.description_outlined,
                    label: filesPlaceLabel,
                    onPressed: _openFiles,
                  ),
                  (
                    icon: Icons.folder_outlined,
                    label: folderPlaceLabel,
                    onPressed: _openFolder,
                  ),
                  (
                    icon: Icons.inventory_2_outlined,
                    label: importedLogsPlaceLabel,
                    onPressed: _openImported,
                  ),
                ],
              ),
            ),
            Expanded(
              child: Text(
                c.files.join(', '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: mutedText, fontSize: 12),
              ),
            ),
          ],
        ),
        if (c.diveCount == 0)
          const MutedText(
            'Open dive logs to see them the way UWMedia reads them - to check '
            'what an overlay will show before rendering. Open adds to the '
            'list; Remove takes a dive off it. The files themselves are never '
            'changed; Adjust time saves a corrected copy of a Garmin log.',
          ),
        if (c.busy) const LinearProgressIndicator(),
        if (c.message.isNotEmpty) MutedText(c.message),
        for (final warning in c.warnings)
          Text(
            '⚠ $warning',
            style: const TextStyle(color: _warnColor, fontSize: 11),
          ),
      ],
    );
  }

  Widget _cell(String text, double width, {Color color = _textColor}) =>
      SizedBox(
        width: width,
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: color, fontSize: 12),
        ),
      );

  Widget _head(String text, double width) =>
      _cell(text, width, color: mutedText);

  Widget _diveList() {
    final c = controller;
    return SizedBox(
      width: 430,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              Row(
                children: [
                  Text(
                    'DIVES (${c.diveCount})',
                    style: const TextStyle(
                      color: mutedText,
                      fontSize: 12,
                      letterSpacing: 1,
                    ),
                  ),
                  const Spacer(),
                  _small(
                    'Remove',
                    c.currentRow >= 0 ? c.removeSelected : null,
                    'Takes the selected dive off the list (Delete or '
                        'Backspace does the same); the file is not touched',
                  ),
                  _small(
                    'Clear',
                    c.diveCount > 0 ? c.clear : null,
                    'Empties the list; the files are not touched',
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Row(
                  spacing: 8,
                  children: [
                    _head('Date', 78),
                    _head('Time', 40),
                    _head('Depth', 54),
                    _head('Duration', 70),
                    Expanded(child: _head('File', 100)),
                  ],
                ),
              ),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: cardBorder),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Focus(
                    focusNode: _listFocus,
                    onKeyEvent: _onKey,
                    child: ListView.builder(
                      itemCount: c.rows.length,
                      itemExtent: 28,
                      itemBuilder: (context, i) {
                        final row = c.rows[i];
                        final current = i == c.currentRow;
                        return GestureDetector(
                          onTap: () {
                            _listFocus.requestFocus();
                            c.select(i);
                          },
                          child: ColoredBox(
                            color: current
                                ? const Color(0x4700A6ED)
                                : i.isOdd
                                ? const Color(0xFF1A1A1A)
                                : const Color(0xFF202020),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              child: Row(
                                spacing: 8,
                                children: [
                                  _cell(row.date, 78),
                                  _cell(row.time, 40),
                                  _cell(row.maxDepth, 54),
                                  _cell(row.duration, 70),
                                  Expanded(
                                    child: _cell(
                                      row.file,
                                      100,
                                      color: mutedText,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
              if (c.diveCount > 0)
                const MutedText(
                  '↑/↓ moves through the list · Delete removes the selected '
                  'dive from it',
                  size: 11,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(String label, String value, {double width = 150}) =>
      value.isEmpty
      ? const SizedBox.shrink()
      : SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 1,
            children: [
              MutedText(label, size: 11),
              SelectableText(
                value,
                style: const TextStyle(color: _textColor, fontSize: 13),
              ),
            ],
          ),
        );

  Widget _tanks(DiveDetails d) {
    if (d.tanks.isEmpty) {
      return const Text(
        'No tank data in this dive',
        style: TextStyle(color: _textColor, fontSize: 12),
      );
    }
    Widget line(List<(String, double, bool)> cells, {bool head = false}) => Row(
      spacing: 8,
      children: [
        for (final (text, width, selectable) in cells)
          SizedBox(
            width: width,
            child: selectable && !head
                ? SelectableText(
                    text,
                    maxLines: 1,
                    style: const TextStyle(color: _textColor, fontSize: 12),
                  )
                : Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: head ? mutedText : _textColor,
                      fontSize: head ? 11 : 12,
                    ),
                  ),
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        line(head: true, [
          ('#', 20, false),
          ('Sensor', 80, false),
          ('Serial', 95, false),
          ('Name', 90, false),
          ('Mix', 70, false),
          ('Start', 65, false),
          ('End', 65, false),
        ]),
        for (final t in d.tanks)
          line([
            ('${t.index}', 20, false),
            (t.key, 80, true),
            (t.serial, 95, true),
            (t.name, 90, false),
            (t.mix, 70, false),
            (t.startPressure, 65, false),
            (t.endPressure, 65, false),
          ]),
        const Text(
          'Select a sensor or serial and copy it (Cmd/Ctrl+C) to give it a '
          'friendly name under Settings → Sensor names; overlays then show '
          'that name.',
          style: TextStyle(color: Color(0xFF808080), fontSize: 10),
        ),
      ],
    );
  }

  Widget _diveCard() {
    final c = controller;
    final d = c.selected;
    final busy = c.busy;
    return SectionCard(
      children: [
        Row(
          children: [
            const Text(
              'DIVE',
              style: TextStyle(
                color: mutedText,
                fontSize: 12,
                letterSpacing: 1,
              ),
            ),
            const Spacer(),
            if (d != null) ...[
              _small(
                'Adjust time…',
                c.canAdjustTime && !busy ? _adjustTime : null,
                c.canAdjustTime
                    ? 'For a dive computer whose clock was wrong: set this '
                          "dive's real start time and time zone and save a "
                          'corrected copy of the log'
                    : 'Garmin FIT logs only',
              ),
              _small(
                'Merge…',
                c.canMerge && !busy ? _merge : null,
                c.canMerge
                    ? 'For a dive the computer split in two: join this dive '
                          'with the next one in the list into a single log'
                    : 'Garmin FIT logs only, and a later FIT dive that starts '
                          "within 2 hours of this one's end must be in the list",
              ),
            ],
          ],
        ),
        Text(
          d?.title ?? 'No dive selected',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: _textColor,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
        if (d != null) ...[
          MutedText(
            d.file + (d.format.isEmpty ? '' : ' · ${d.format}'),
            size: 11,
          ),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              _field('Start', d.start),
              _field('End', d.end),
              _field('Time zone', d.timezone),
              _field('Duration', d.duration),
              _field('Max depth', d.maxDepth),
              _field('Avg depth', d.avgDepth),
              _field('Water temp (min)', d.tempMin),
              _field('Water temp (max)', d.tempMax),
              _field('Dive computer', d.device, width: 316),
              _field('Latitude', d.lat),
              _field('Longitude', d.lng),
              _field('Exit latitude', d.exitLat),
              _field('Exit longitude', d.exitLng),
              _field('Rebreather', d.rebreather, width: 316),
            ],
          ),
          const MutedText('Tanks / sensors', size: 11),
          _tanks(d),
          ProfileChart(
            samples: d.samples,
            depthUnit: d.depthUnit,
            showCeiling: d.hasCeiling,
          ),
          Po2Chart(samples: d.po2Samples),
          MutedText(
            d.sampleCount > 0
                ? '${d.sampleCount} samples'
                      '${d.channels.isEmpty ? '' : ' · logged: ${d.channels.join(', ')}'}'
                : 'No dive profile in the log',
            size: 11,
          ),
          if (d.events.isNotEmpty) ...[
            const MutedText('Events', size: 11),
            for (final line in d.events)
              Text(
                line,
                style: const TextStyle(
                  color: _textColor,
                  fontSize: 11,
                  fontFamily: 'monospace',
                  fontFamilyFallback: ['Menlo', 'Consolas'],
                ),
              ),
          ],
        ],
      ],
    );
  }

  Widget _row(List<String> cells, {bool head = false}) => Row(
    children: [
      for (var i = 0; i < cells.length; i++)
        if (i == _columnWidths.length - 1)
          Expanded(child: _tableCell(cells[i], head))
        else
          SizedBox(width: _columnWidths[i], child: _tableCell(cells[i], head)),
    ],
  );

  Widget _tableCell(String text, bool head) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      color: _textColor,
      fontSize: 12,
      fontWeight: head ? FontWeight.bold : FontWeight.normal,
    ),
  );

  Widget _samplesCard() {
    final c = controller;
    final d = c.selected!;
    final rows = samplesOpen ? c.tableRows : const <List<String>>[];
    return SectionCard(
      children: [
        Row(
          children: [
            Text(
              'SAMPLES (${d.sampleCount})',
              style: const TextStyle(
                color: mutedText,
                fontSize: 12,
                letterSpacing: 1,
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() => samplesOpen = !samplesOpen),
              child: Text(samplesOpen ? 'Hide' : 'Show'),
            ),
          ],
        ),
        if (!samplesOpen)
          const MutedText(
            'Every sample as the overlays read it: time, depth, temperature, '
            "NDL, TTS, gas, PO2, a rebreather's setpoint, cells and circuit, "
            'and tank pressures.',
            size: 11,
          )
        else ...[
          Row(
            spacing: 8,
            children: [
              const Text('Filter:'),
              Expanded(
                child: TextField(
                  controller: _filter,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Type to filter samples...',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (text) => c.filterText = text,
                ),
              ),
              MutedText('${rows.length} shown', size: 11),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: _row(c.tableHeadings, head: true),
          ),
          SizedBox(
            height: 380,
            child: ListView.builder(
              itemCount: rows.length,
              itemExtent: 24,
              itemBuilder: (context, i) => ColoredBox(
                color: i.isEven
                    ? const Color(0xFF1A1A1A)
                    : const Color(0xFF141414),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: _row(rows[i]),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _adjustTime() async {
    final c = controller;
    await showDialog<void>(
      context: context,
      builder: (context) => _AdjustDialog(
        start: c.adjustStartText,
        offset: c.adjustOffsetText,
        save: (start, offset) =>
            c.adjustTime(start, offset, widget.dialogs.save),
      ),
    );
  }

  Future<void> _merge() async {
    final c = controller;
    await showDialog<void>(
      context: context,
      builder: (context) => _MergeDialog(
        candidates: c.mergeCandidateLabels,
        save: (index, closeGap) =>
            c.mergeDives(index, closeGap, widget.dialogs.save),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          _topCard(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                _diveList(),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 12,
                      children: [
                        _diveCard(),
                        if (controller.selected != null) _samplesCard(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// The frame of the two tools' dialogs: Save runs [onSave], whose error
/// keeps the dialog open with the error shown.
class _ToolDialog extends StatefulWidget {
  const _ToolDialog({
    required this.title,
    required this.children,
    required this.onSave,
  });

  final String title;
  final List<Widget> children;
  final Future<String> Function() onSave;

  @override
  State<_ToolDialog> createState() => _ToolDialogState();
}

class _ToolDialogState extends State<_ToolDialog> {
  String error = '';
  bool saving = false;

  Future<void> _save() async {
    setState(() => saving = true);
    final result = await widget.onSave();
    if (!mounted) {
      return;
    }
    if (result.isEmpty) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        saving = false;
        error = result;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            ...widget.children,
            if (error.isNotEmpty)
              Text(error, style: const TextStyle(color: _errorColor)),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: saving ? null : _save, child: const Text('Save')),
    ],
  );
}

class _AdjustDialog extends StatefulWidget {
  const _AdjustDialog({
    required this.start,
    required this.offset,
    required this.save,
  });

  final String start;
  final String offset;
  final Future<String> Function(String start, String offset) save;

  @override
  State<_AdjustDialog> createState() => _AdjustDialogState();
}

class _AdjustDialogState extends State<_AdjustDialog> {
  late final start = TextEditingController(text: widget.start);
  late final offset = TextEditingController(text: widget.offset);

  @override
  void dispose() {
    start.dispose();
    offset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ToolDialog(
    title: "Adjust the dive's time",
    onSave: () => widget.save(start.text, offset.text),
    children: [
      const Text(
        'For a dive computer whose clock was wrong before the dive. Enter '
        "when the dive really started, in the dive site's local time, and "
        "that place's time zone. Every sample moves by the same amount; the "
        'corrected log is saved as a new file and added to the list.',
      ),
      TextField(
        controller: start,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Start (local time)',
          hintText: 'YYYY-MM-DD HH:MM:SS',
        ),
      ),
      TextField(
        controller: offset,
        decoration: const InputDecoration(
          labelText: 'Time zone (UTC offset)',
          hintText: 'e.g. +07:00',
        ),
      ),
    ],
  );
}

class _MergeDialog extends StatefulWidget {
  const _MergeDialog({required this.candidates, required this.save});

  final List<String> candidates;
  final Future<String> Function(int candidate, bool closeGap) save;

  @override
  State<_MergeDialog> createState() => _MergeDialogState();
}

class _MergeDialogState extends State<_MergeDialog> {
  int candidate = 0;
  bool closeGap = false;

  @override
  Widget build(BuildContext context) => _ToolDialog(
    title: 'Merge two dives into one',
    onSave: () => widget.save(candidate, closeGap),
    children: [
      const Text(
        'For a dive your computer split in two (a short surface stop ended '
        'one log and started another). The selected dive and the one chosen '
        'below are saved as a single Garmin log that starts with the first '
        'and ends with the second, with the gases and tank readings of both; '
        'the original files are kept.',
      ),
      DropdownButtonFormField<int>(
        initialValue: candidate,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Merge with'),
        items: [
          for (var i = 0; i < widget.candidates.length; i++)
            DropdownMenuItem(value: i, child: Text(widget.candidates[i])),
        ],
        onChanged: (v) => setState(() => candidate = v ?? 0),
      ),
      const MutedText('The time between the dives'),
      RadioGroup<bool>(
        groupValue: closeGap,
        onChanged: (v) => setState(() => closeGap = v ?? false),
        child: const Column(
          children: [
            RadioListTile<bool>(
              value: false,
              title: Text(
                'Keep the real times - the surface interval is filled with the '
                "first dive's last sample, so photos and videos from both "
                'dives still match the log',
              ),
            ),
            RadioListTile<bool>(
              value: true,
              title: Text(
                'Close the gap - the second dive moves back to follow the '
                'first without a break (one continuous dive; its photos and '
                'videos no longer match)',
              ),
            ),
          ],
        ),
      ),
      const MutedText(
        'Garmin Connect takes the merged log for the first dive, so delete '
        'both original dives there before uploading it.',
      ),
    ],
  );
}
