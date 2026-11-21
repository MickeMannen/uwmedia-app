/// The Dive Profile Builder on the desktop (Python
/// `qml/DiveProfilePage.qml`): the dive settings, log details, gases and
/// waypoints on the left; the chart (click to place, drag to move,
/// right-click to delete, hover for the readout), the status and Open log,
/// End dive and Save log on the right.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/plan/profile_chart.dart';
import 'package:uwmedia_app/core/units/units.dart' as u;
import 'package:uwmedia_app/engine/file_picks.dart' as fs;
import 'package:uwmedia_app/pages/dive_profile/dive_profile_controller.dart';
import 'package:uwmedia_app/pages/dive_profile/profile_painter.dart';
import 'package:uwmedia_app/pages/shared/place_menu.dart';
import 'package:uwmedia_app/widgets/bound_field.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

const _helpText =
    '1. Set the scale. Enter the deepest depth you plan to reach and roughly '
    "how long the dive will last. This fixes the chart's axes so a click maps "
    'to a time and a depth. Both can be changed later under Dive settings, '
    'and the time axis grows automatically when you place points near its '
    'end.\n\n'
    '2. Click in the chart to place waypoints. Time snaps to whole minutes '
    'and depth to whole metres. Between two waypoints the diver moves at the '
    'default descent/ascent rate, then holds the new depth until the next '
    "waypoint's time.\n\n"
    '3. Edit on the chart. Drag a waypoint to move it, right-click it to '
    'delete it, or click it to load it into the Waypoints editor. Hover over '
    'the profile to see time, depth, gas, PO2, NDL or deco stop, TTS, CNS and '
    "tank pressure at that point. The line is drawn in each gas's colour "
    '(click a colour swatch in the Gases panel to change it) and the grey '
    'shaded bands show the planned deco stops (darker = longer stop).\n\n'
    '4. Gases by depth. In the Gases panel give each gas the depth range and '
    'phase it is used in, e.g. Air (any), EAN50 0-21 m Ascent/deco, O2 0-6 m '
    'Ascent/deco. Each waypoint then gets the gas covering its depth '
    'automatically - deco gases only on the way up (after the deepest '
    'point). A gas is never auto-picked deeper than its MOD, which follows '
    'your own Max PO2 bottom/deco under Dive settings (the table\'s MOD '
    'column uses the deco PO2 for Ascent/deco gases). A gas without a range '
    'is the fallback. Pick a specific gas in the Waypoints editor to override '
    'a waypoint.\n\n'
    '5. End the dive. Press End dive to ascend from the last waypoint at the '
    'default ascent rate: a 3 m / 3 min safety stop when no deco is needed, '
    'otherwise the deco stops for your GF settings (3 m levels, whole '
    'minutes), switching to each deco gas as soon as its range and MOD allow, '
    'with a 1 min hold at each gas switch (counted as part of a deco stop at '
    'the same depth).\n\n'
    '6. Dive type. Open circuit breathes each gas from its own tank. '
    'Sidemount needs two tanks of the same gas, one with Side set to Left and '
    'one to Right (usually T1 and T2); the dive starts on the left one and '
    'switches side whenever the one in use gets the set pressure below the '
    'other, and the profile line takes the colour of the tank in use. Other '
    'tanks are stages. CCR makes the gas ticked "Diluent" the loop, held at '
    'the low setpoint above the switch depth and the high one below it, with '
    'an O2 cylinder drawn at a metabolic rate; every other gas is '
    'open-circuit bailout, only used where you pick it for a waypoint.\n\n'
    '7. Save log. Saves the profile as UDDF, Garmin FIT or Subsurface XML, '
    'logged as if by the dive computer chosen under Log details (FIT needs a '
    'Garmin). Set the start date and time to match your photos and videos - '
    'left blank, the time of saving is used.';

/// What the button that opens a log says.
const openLogLabel = 'Open log…';

/// The page's file dialogs, so that a test can answer for them.
abstract interface class DiveProfileDialogs {
  Future<String?> openLog(String initialDirectory);

  /// Where to save, and which of [logFormats] was chosen.
  Future<({String path, String format})?> saveLog(
    String initialDirectory,
    String suggestedName,
    String format,
  );
}

class SystemDiveProfileDialogs implements DiveProfileDialogs {
  const SystemDiveProfileDialogs();

  @override
  Future<String?> openLog(String initialDirectory) async => (await fs.openFile(
    initialDirectory: initialDirectory,
    acceptedTypeGroups: const [
      fs.XTypeGroup(
        label: 'Dive logs',
        // `json` (Suunto app export): Python's open filter omits it, its
        // loader reads it (0.8.1); a deliberate widening.
        extensions: ['uddf', 'fit', 'ssrf', 'xml', 'csv', 'json'],
      ),
    ],
  ))?.path;

  @override
  Future<({String path, String format})?> saveLog(
    String initialDirectory,
    String suggestedName,
    String format,
  ) async {
    final groups = [
      for (final MapEntry(key: label, value: ext) in logFormats.entries)
        fs.XTypeGroup(label: label, extensions: [ext.substring(1)]),
    ];
    final picked = await fs.getSaveLocation(
      initialDirectory: initialDirectory,
      suggestedName: suggestedName,
      acceptedTypeGroups: [
        ...groups.where((g) => g.label == format),
        ...groups.where((g) => g.label != format),
      ],
    );
    if (picked == null) {
      return null;
    }
    return (path: picked.path, format: picked.activeFilter?.label ?? format);
  }
}

class DiveProfilePage extends StatefulWidget {
  const DiveProfilePage({
    super.key,
    required this.services,
    this.dialogs = const SystemDiveProfileDialogs(),
  });

  final AppServices services;
  final DiveProfileDialogs dialogs;

  @override
  State<DiveProfilePage> createState() => _DiveProfilePageState();
}

class _DiveProfilePageState extends State<DiveProfilePage> {
  late final DiveProfileController controller = DiveProfileController(
    config: widget.services.config,
    home: widget.services.home,
  );

  // The chart gesture: the waypoint pressed, where, whether it moved.
  int _dragRow = -1;
  bool _primary = false;
  Offset _press = Offset.zero;
  bool _moved = false;
  Offset? _hover;

  void _unitsChanged() => controller.unitsChanged();

  @override
  void initState() {
    super.initState();
    widget.services.unitsRevision.addListener(_unitsChanged);
  }

  @override
  void dispose() {
    widget.services.unitsRevision.removeListener(_unitsChanged);
    controller.dispose();
    super.dispose();
  }

  Widget _row(String label, Widget field, {bool visible = true}) => !visible
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            spacing: 8,
            children: [
              SizedBox(width: 190, child: Text(label)),
              Expanded(child: field),
            ],
          ),
        );

  Widget _pair(Widget a, Widget b) => Row(
    spacing: 6,
    children: [
      Expanded(child: a),
      const Text('/'),
      Expanded(child: b),
    ],
  );

  Widget _dropdown(
    String value,
    List<String> items,
    void Function(String) onChanged,
  ) => DropdownButton<String>(
    isExpanded: true,
    value: items.contains(value) ? value : null,
    items: [
      for (final item in items)
        DropdownMenuItem(value: item, child: Text(item)),
    ],
    onChanged: (v) => onChanged(v!),
  );

  Widget _error(String text) => text.isEmpty
      ? const SizedBox.shrink()
      : Text(text, style: const TextStyle(color: Color(0xFFEF4444)));

  Widget _settings() {
    final c = controller;
    final units = c.units;
    final depth = u.depthLabel(units);
    final pressure = u.pressureLabel(units, upper: false);
    return SectionCard(
      title: 'Dive settings',
      children: [
        _row('Name', BoundField(value: c.nameText, onChanged: c.setName)),
        _row(
          'Dive type',
          _dropdown(
            c.diveTypeLabel,
            diveTypeLabels.values.toList(),
            c.selectDiveType,
          ),
        ),
        _row(
          'GF Low/High',
          _pair(
            BoundField(value: c.gfLowText, onChanged: c.setGfLow, hint: 'low'),
            BoundField(
              value: c.gfHighText,
              onChanged: c.setGfHigh,
              hint: 'high',
            ),
          ),
        ),
        _error(c.gfErrorText),
        _row(
          'Descent rate (${u.depthRateLabel(units)})',
          BoundField(value: c.descentRateText, onChanged: c.setDescentRate),
        ),
        _row(
          'Ascent rate (${u.depthRateLabel(units)})',
          BoundField(value: c.ascentRateText, onChanged: c.setAscentRate),
        ),
        _row(
          'Water temp (${u.temperatureLabel(units)})',
          BoundField(value: c.waterTempText, onChanged: c.setWaterTemp),
        ),
        _row(
          'SAC rate (L/min)',
          BoundField(value: c.sacText, onChanged: c.setSac, hint: '20'),
        ),
        _row(
          'Max PO2 bottom (bar)',
          BoundField(
            value: c.bottomPo2Text,
            onChanged: c.setBottomPo2,
            hint: '1.4',
          ),
        ),
        _row(
          'Max PO2 deco (bar)',
          BoundField(
            value: c.decoPo2Text,
            onChanged: c.setDecoPo2,
            hint: '1.6',
          ),
        ),
        _row(
          'Setpoint low/high',
          _pair(
            BoundField(
              value: c.ccrLowText,
              onChanged: c.setCcrLow,
              hint: '0.7',
            ),
            BoundField(
              value: c.ccrHighText,
              onChanged: c.setCcrHigh,
              hint: '1.3',
            ),
          ),
          visible: c.isCcr,
        ),
        if (c.isCcr) _error(c.ccrErrorText),
        _row(
          'SP switch down/up ($depth)',
          _pair(
            BoundField(
              value: c.ccrHighDepthText,
              onChanged: c.setCcrHighDepth,
              hint: '8',
              tooltip:
                  'Switch to the high setpoint descending through this depth',
            ),
            BoundField(
              value: c.ccrLowDepthText,
              onChanged: c.setCcrLowDepth,
              hint: '2',
              tooltip:
                  'Back to the low setpoint ascending through this depth '
                  '(dive computers want them 6 m apart)',
            ),
          ),
          visible: c.isCcr,
        ),
        _row(
          'O2 cylinder (L / $pressure)',
          _pair(
            BoundField(
              value: c.ccrO2SizeText,
              onChanged: c.setCcrO2Size,
              hint: '3',
            ),
            BoundField(
              value: c.ccrO2StartText,
              onChanged: c.setCcrO2Start,
              hint: '200',
            ),
          ),
          visible: c.isCcr,
        ),
        _row(
          'Switch tanks every ($pressure)',
          BoundField(
            value: c.sidemountSwitchText,
            onChanged: c.setSidemountSwitch,
            hint: '30',
            tooltip:
                'Switch to the other tank once the one in use is this far '
                'below it',
          ),
          visible: c.isSidemount,
        ),
        _row(
          'Max depth ($depth)',
          BoundField(
            value: c.maxDepthText,
            onChanged: c.setMaxDepth,
            hint: 'chart scale',
          ),
        ),
        _row(
          'Planned runtime (min)',
          BoundField(
            value: c.runtimeText,
            onChanged: c.setRuntime,
            hint: 'chart scale',
          ),
        ),
      ],
    );
  }

  Widget _logDetails() {
    final c = controller;
    return SectionCard(
      title: 'Log details',
      children: [
        _row(
          'Dive computer',
          _dropdown(c.plan.computer, c.computerList, c.selectComputer),
        ),
        _row(
          'Serial number',
          BoundField(value: c.serialText, onChanged: c.setSerial),
        ),
        _row(
          'Start',
          BoundField(
            value: c.startTimeText,
            onChanged: c.setStartTime,
            hint: 'YYYY-MM-DD HH:MM (blank = now)',
            tooltip:
                'Local date and time the dive starts - set it to match your '
                'photos and videos',
          ),
        ),
        _error(c.logErrorText),
      ],
    );
  }

  Widget _swatch(String color, VoidCallback? onTap, {String? tooltip}) {
    Widget box = Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: hexColor(color),
        border: Border.all(color: Colors.white24),
      ),
    );
    if (onTap != null) {
      box = InkWell(onTap: onTap, child: box);
    }
    return tooltip == null ? box : Tooltip(message: tooltip, child: box);
  }

  Future<String?> _pickColor(String current) => showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Line colour'),
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final color in gasColors)
                InkWell(
                  onTap: () => Navigator.of(context).pop(color),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: hexColor(color),
                      border: Border.all(
                        color: color == current ? Colors.white : Colors.white24,
                        width: color == current ? 2 : 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _table(
    List<String> headers,
    List<List<String>> rows,
    List<String> colors,
    int? selected,
    void Function(int) onSelect, {
    void Function(int)? onSwatch,
  }) {
    Widget cell(String text, {bool head = false}) => Expanded(
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          fontWeight: head ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const SizedBox(width: 24),
            for (final h in headers) cell(h, head: true),
          ],
        ),
        for (final (i, row) in rows.indexed)
          Material(
            color: i == selected
                ? accent.withValues(alpha: 0.25)
                : Colors.transparent,
            child: InkWell(
              onTap: () => onSelect(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      child: _swatch(
                        colors[i],
                        onSwatch == null ? null : () => onSwatch(i),
                        tooltip: onSwatch == null ? null : 'Change line colour',
                      ),
                    ),
                    for (final value in row) cell(value),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _gases() {
    final c = controller;
    final units = c.units;
    final editing = c.selectedGasRow;
    return SectionCard(
      title: 'Gases',
      children: [
        _table(
          c.gasTableHeaders,
          c.gasTableRows,
          c.gasColors,
          editing >= 0 ? editing : null,
          c.selectGasRow,
          onSwatch: (row) async {
            final color = await _pickColor(c.gasColors[row]);
            if (color != null) {
              c.setGasColor(row, color);
            }
          },
        ),
        const Divider(),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            BoundField(
              value: c.gasNameText,
              onChanged: (v) => c.editGasField(() => c.gasNameText = v),
              hint: 'e.g. Bottom',
              label: 'Name',
              width: 120,
            ),
            SizedBox(
              width: 110,
              child: _dropdown(
                c.gasType,
                diveGasTypes,
                (v) => c.editGasField(() => c.gasType = v),
              ),
            ),
            _swatch(c.gasColorText, () async {
              final color = await _pickColor(c.gasColorText);
              if (color != null) {
                c.setGasColorChoice(color);
              }
            }, tooltip: 'Line colour for this gas'),
            BoundField(
              value: c.gasO2Text,
              onChanged: (v) => c.editGasField(() => c.gasO2Text = v),
              label: 'O2%',
              width: 60,
            ),
            BoundField(
              value: c.gasHeText,
              onChanged: (v) => c.editGasField(() => c.gasHeText = v),
              label: 'He%',
              width: 60,
            ),
            BoundField(
              value: c.gasTankText,
              onChanged: (v) => c.editGasField(() => c.gasTankText = v),
              label: 'Tank',
              width: 60,
            ),
            BoundField(
              value: c.gasVolumeText,
              onChanged: (v) => c.editGasField(() => c.gasVolumeText = v),
              label: 'Volume (L)',
              hint: '11.1',
              width: 90,
            ),
            BoundField(
              value: c.gasStartPressureText,
              onChanged: (v) =>
                  c.editGasField(() => c.gasStartPressureText = v),
              label: 'Start (${u.pressureLabel(units, upper: false)})',
              hint: '207',
              width: 90,
            ),
            if (c.isCcr)
              Tooltip(
                message: 'Unticked gases are open-circuit bailout',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: c.gasDiluent,
                      onChanged: (v) =>
                          c.editGasField(() => c.gasDiluent = v ?? false),
                    ),
                    const Text('Diluent (the loop)'),
                  ],
                ),
              ),
            if (c.isSidemount)
              Tooltip(
                message:
                    'Left and Right: the two sidemount tanks, same gas, '
                    'breathed alternately. Stage: any other tank',
                child: SizedBox(
                  width: 100,
                  child: _dropdown(
                    gasSideLabels[c.gasSide]!,
                    gasSideLabels.values.toList(),
                    (label) => c.editGasField(
                      () => c.gasSide = gasSideLabels.entries
                          .firstWhere((e) => e.value == label)
                          .key,
                    ),
                  ),
                ),
              ),
            const Text('Use from'),
            BoundField(
              value: c.gasMinDepthText,
              onChanged: (v) => c.editGasField(() => c.gasMinDepthText = v),
              hint: '0',
              width: 50,
            ),
            const Text('to'),
            BoundField(
              value: c.gasMaxDepthText,
              onChanged: (v) => c.editGasField(() => c.gasMaxDepthText = v),
              hint: '∞',
              width: 50,
            ),
            Text(u.depthLabel(units)),
            SizedBox(
              width: 140,
              child: _dropdown(
                gasPhaseLabels[c.gasPhase]!,
                gasPhaseLabels.values.toList(),
                (label) => c.editGasField(
                  () => c.gasPhase = gasPhaseLabels.entries
                      .firstWhere((e) => e.value == label)
                      .key,
                ),
              ),
            ),
          ],
        ),
        Row(
          spacing: 8,
          children: [
            FilledButton(
              onPressed: c.addGas,
              child: Text(editing >= 0 ? 'Update' : 'Add'),
            ),
            OutlinedButton(onPressed: c.newGas, child: const Text('New')),
            OutlinedButton(
              onPressed: editing >= 0 ? () => c.removeGasAt(editing) : null,
              child: const Text('Remove'),
            ),
          ],
        ),
        if (c.gasStatusText.isNotEmpty) MutedText(c.gasStatusText),
      ],
    );
  }

  Widget _waypoints() {
    final c = controller;
    final units = c.units;
    return SectionCard(
      title: 'Waypoints',
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: SingleChildScrollView(
            child: _table(
              c.waypointHeaders,
              c.waypointRows,
              c.waypointGasColors,
              c.selectedWaypointRow,
              c.selectWaypointRow,
            ),
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            BoundField(
              value: c.wpTimeText,
              onChanged: (v) => c.wpTimeText = v,
              label: 'Time',
              hint: 'mm:ss or minutes',
              width: 120,
            ),
            BoundField(
              value: c.wpDepthText,
              onChanged: (v) => c.wpDepthText = v,
              label: 'Depth',
              hint: units == u.UnitSystem.imperial ? 'feet' : 'metres',
              width: 90,
            ),
            SizedBox(
              width: 120,
              child: _dropdown(
                c.wpGasText.isEmpty ? autoGasLabel : c.wpGasText,
                c.wpGasChoices,
                (v) => c.editGasField(() => c.wpGasText = v),
              ),
            ),
            BoundField(
              value: c.wpRateText,
              onChanged: (v) => c.wpRateText = v,
              label: 'Rate',
              hint: 'default',
              width: 90,
            ),
            FilledButton(
              onPressed: c.addOrUpdateWaypoint,
              child: const Text('Add / Update'),
            ),
            OutlinedButton(
              onPressed: c.selectedWaypointRow == null
                  ? null
                  : () => c.removeWaypointAt(c.selectedWaypointRow!),
              child: const Text('Remove Selected'),
            ),
          ],
        ),
        if (c.wpStatusText.isNotEmpty) MutedText(c.wpStatusText),
      ],
    );
  }

  Future<void> _scaleThenPlace(Offset at) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => _ScaleDialog(controller: controller),
    );
    if (ok ?? false) {
      controller.addWaypointAt(at.dx, at.dy);
    }
  }

  Widget _chart() {
    final c = controller;
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = (constraints.maxWidth / canvasWidth).clamp(0.0, 1.0);
        Offset local(Offset position) => position / scale;
        final hover = _hover;
        // At its own size, never stretched by the column: clicks map in the
        // chart's 700 x 420 pixels.
        return Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: canvasWidth * scale,
            height: canvasHeight * scale,
            child: MouseRegion(
              cursor: _dragRow >= 0
                  ? SystemMouseCursors.grabbing
                  : SystemMouseCursors.precise,
              onHover: (e) {
                final at = local(e.localPosition);
                setState(() => _hover = at);
                c.scrub(at.dx);
              },
              onExit: (_) {
                setState(() => _hover = null);
                c.clearCursor();
              },
              child: Listener(
                onPointerDown: (e) {
                  final at = local(e.localPosition);
                  _primary = e.buttons == kPrimaryMouseButton;
                  _moved = false;
                  _dragRow = -1;
                  if (e.buttons == kSecondaryMouseButton) {
                    final row = c.waypointIndexAt(at.dx, at.dy);
                    if (row >= 0) {
                      c.removeWaypointAt(row);
                    }
                    return;
                  }
                  _press = at;
                  _moved = false;
                  _dragRow = c.waypointIndexAt(at.dx, at.dy);
                },
                onPointerMove: (e) {
                  if (e.buttons != kPrimaryMouseButton) {
                    return;
                  }
                  final at = local(e.localPosition);
                  if (!_moved && (at - _press).distance > 4) {
                    _moved = true;
                  }
                  if (!_moved) {
                    return;
                  }
                  if (_dragRow >= 0) {
                    c.moveWaypoint(_dragRow, at.dx, at.dy);
                  } else {
                    c.scrub(at.dx);
                  }
                },
                onPointerCancel: (_) {
                  final row = _dragRow;
                  _dragRow = -1;
                  if (_primary && row >= 0 && _moved) {
                    c.dropWaypoint(row);
                  }
                  _primary = false;
                },
                onPointerUp: (e) {
                  final at = local(e.localPosition);
                  final row = _dragRow;
                  _dragRow = -1;
                  if (!_primary) {
                    // A right-click (deleted on the press) does nothing more.
                    return;
                  }
                  _primary = false;
                  if (row >= 0 && _moved) {
                    c.dropWaypoint(row);
                  } else if (row >= 0) {
                    c.selectWaypointRow(row);
                  } else if (!_moved) {
                    if (c.scaleDefined) {
                      c.addWaypointAt(at.dx, at.dy);
                    } else {
                      _scaleThenPlace(at);
                    }
                  }
                },
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: ProfilePainter(
                          plan: c.plan,
                          samples: c.samples,
                          units: c.units,
                          cursorTime: c.cursorTime,
                          waypointsOnly: c.dragging,
                          decoSchedules: c.decoSchedules,
                        ),
                      ),
                    ),
                    if (hover != null &&
                        _dragRow < 0 &&
                        c.cursorInfo.isNotEmpty)
                      _hoverBox(hover * scale, canvasWidth * scale),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _hoverBox(Offset at, double width) {
    final lines = controller.cursorInfo;
    const boxW = 230.0;
    final left = at.dx + 16 + boxW > width ? at.dx - 16 - boxW : at.dx + 16;
    return Positioned(
      left: left < 0 ? 0 : left,
      top: (at.dy - 60).clamp(0.0, double.infinity),
      child: IgnorePointer(
        child: Container(
          width: boxW,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xE6111827),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: const Color(0xFF4B5563)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final line in lines)
                Row(
                  children: [
                    SizedBox(
                      width: 64,
                      child: Text(
                        line.label,
                        style: const TextStyle(
                          color: Color(0xFF9CA3AF),
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        line.value,
                        style: TextStyle(
                          color: hexColor(line.color),
                          fontSize: 12,
                          fontWeight: line.label == 'Gas'
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _open() async {
    final path = await widget.dialogs.openLog(controller.dialogDir);
    if (path != null && mounted) {
      await _openPath(path);
    }
  }

  // One of the logs kept in the app (the Dive Logs page), picked from
  // their list.
  Future<void> _openImported() async {
    final store = widget.services.logStore;
    final files = store.files()..sort();
    final path = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text(importedLogsPlaceLabel),
        children: [
          if (files.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Text(
                'No logs imported yet: import them on the Dive Logs page.',
              ),
            ),
          for (final file in files)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, file),
              child: Text(p.basename(file)),
            ),
        ],
      ),
    );
    if (path != null && mounted) {
      await _openPath(path, kept: true);
    }
  }

  Future<void> _openPath(String path, {bool kept = false}) async {
    final error = controller.openLog(
      path,
      tanks: widget.services.config.tankConfig().tanks,
      kept: kept,
    );
    if (error != null && mounted) {
      await _message('Could not open log', error);
    }
  }

  Future<void> _save() async {
    final c = controller;
    final picked = await widget.dialogs.saveLog(
      c.dialogDir,
      c.suggestedLogName,
      c.savedLogFormat,
    );
    if (picked == null || !mounted) {
      return;
    }
    final result = c.saveLog(picked.path, picked.format);
    if (mounted) {
      await _message(result.ok ? 'Saved' : 'Save failed', result.message);
    }
  }

  Future<void> _message(String title, String text) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SelectableText(text),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );

  Widget _right() {
    final c = controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Row(
          children: [
            const Expanded(
              child: MutedText(
                'Click to add a waypoint · drag a point to move it · '
                'right-click to delete · hover for NDL/PO2',
              ),
            ),
            TextButton(
              onPressed: () =>
                  _message('How the profile builder works', _helpText),
              child: const Text('How it works'),
            ),
          ],
        ),
        _chart(),
        Text(
          c.statusText,
          style: TextStyle(
            color: c.statusIsError ? const Color(0xFFEF4444) : mutedText,
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Tooltip(
              message:
                  'Open a log saved by the Dive Profile Builder to edit it, or '
                  'import another log as a plan: a file, or one of the logs '
                  'imported on the Dive Logs page',
              child: PlaceMenuButton(
                label: openLogLabel,
                icon: Icons.file_open_outlined,
                places: [
                  (
                    icon: Icons.description_outlined,
                    label: filesPlaceLabel,
                    onPressed: _open,
                  ),
                  (
                    icon: Icons.inventory_2_outlined,
                    label: importedLogsPlaceLabel,
                    onPressed: _openImported,
                  ),
                ],
              ),
            ),
            Tooltip(
              message:
                  'Ascend from the last waypoint: 3m/3min safety stop if no '
                  'deco is needed, otherwise the deco stops',
              child: OutlinedButton(
                onPressed: c.endDive,
                child: const Text('End dive'),
              ),
            ),
            Tooltip(
              message: 'Save as UDDF, Garmin FIT or Subsurface XML',
              child: FilledButton(
                onPressed: _save,
                child: const Text('Save log…'),
              ),
            ),
          ],
        ),
        if (c.endDiveStatusText.isNotEmpty) MutedText(c.endDiveStatusText),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          const Text(
            '⚠ DO NOT USE THIS FOR DIVE PLANNING - THIS IS FOR TEST DATA FOR '
            'OVERLAYS ⚠',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFFF59E0B),
              fontWeight: FontWeight.bold,
            ),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 12,
              children: [
                Expanded(
                  flex: 5,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 10,
                      children: [
                        _settings(),
                        _logDetails(),
                        _gases(),
                        _waypoints(),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  flex: 6,
                  child: SingleChildScrollView(child: _right()),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// The chart's scale, asked for on the first click: max depth and planned
/// runtime.
class _ScaleDialog extends StatefulWidget {
  const _ScaleDialog({required this.controller});

  final DiveProfileController controller;

  @override
  State<_ScaleDialog> createState() => _ScaleDialogState();
}

class _ScaleDialogState extends State<_ScaleDialog> {
  late final _depth = TextEditingController(
    text: widget.controller.maxDepthText,
  );
  late final _runtime = TextEditingController(
    text: widget.controller.runtimeText,
  );
  String _error = '';

  @override
  void dispose() {
    _depth.dispose();
    _runtime.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return AlertDialog(
      title: const Text('Set up the dive profile'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              const Text(_helpText),
              TextField(
                controller: _depth,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Max depth (${u.depthLabel(c.units)})',
                  hintText: 'e.g. 40',
                ),
              ),
              TextField(
                controller: _runtime,
                decoration: const InputDecoration(
                  labelText: 'Planned runtime (min)',
                  hintText: 'e.g. 60',
                ),
              ),
              if (_error.isNotEmpty)
                Text(_error, style: const TextStyle(color: Color(0xFFEF4444))),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final message = c.defineScale(_depth.text, _runtime.text);
            if (message.isEmpty) {
              Navigator.of(context).pop(true);
            } else {
              setState(() => _error = message);
            }
          },
          child: const Text('OK'),
        ),
      ],
    );
  }
}
