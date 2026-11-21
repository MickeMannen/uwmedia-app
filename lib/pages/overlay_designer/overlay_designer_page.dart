/// The Overlay Designer on the desktop (Python
/// `qml/OverlayDesignerPage.qml`, `OverlayDesignerCanvas.qml` and the
/// popups): the template cascade with undo, redo and the unsaved mark; New
/// custom, Save, Save as and Revert; the canvas with its toolbar, the
/// telemetry and time rows and the status line; and on the right the
/// element list and the inspector.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uwmedia_app/app/hud_kit.dart';
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/app_paths.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/config/config_store.dart' show StartFolder;
import 'package:uwmedia_app/core/hud/dummy_telemetry.dart';
import 'package:uwmedia_app/core/hud/template_tree.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/units/units.dart' as u;
import 'package:uwmedia_app/engine/file_picks.dart' as fs;
import 'package:uwmedia_app/pages/overlay_designer/designer_controller.dart';
import 'package:uwmedia_app/pages/overlay_designer/designer_inspector.dart';
import 'package:uwmedia_app/pages/shared/place_menu.dart';
import 'package:uwmedia_app/pages/shared/template_picker.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

const _warn = Color(0xFFF59E0B);
const _error = Color(0xFFEF4444);
const _select = Color(0xFF3B82F6);
const _marquee = Color(0xFF22C55E);
const _rightColumnWidth = 340.0;

/// The canvas's editing layer, whose top-left is the picture's.
const designerCanvasKey = ValueKey('designer-canvas');

const _zipTypes = fs.XTypeGroup(label: 'Zip archives', extensions: ['zip']);

const _imageTypes = fs.XTypeGroup(
  label: 'Images',
  extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp'],
);

/// The page's file dialogs, so that a test can answer for them.
abstract interface class DesignerDialogs {
  Future<String?> pickImage(String initialDirectory);

  /// A photo or video for the background.
  Future<String?> pickMedia(String initialDirectory);
  Future<String?> pickLogFile(String initialDirectory);
  Future<String?> pickFolder(String initialDirectory);
  Future<String?> pickZip(String initialDirectory);

  /// Where to export a page zip.
  Future<String?> saveZip(String initialDirectory, String suggestedName);
}

class SystemDesignerDialogs implements DesignerDialogs {
  const SystemDesignerDialogs();

  @override
  Future<String?> pickImage(String initialDirectory) async =>
      (await fs.openFile(
        acceptedTypeGroups: const [_imageTypes],
        initialDirectory: initialDirectory,
      ))?.path;

  @override
  Future<String?> pickMedia(String initialDirectory) async =>
      (await fs.openFile(initialDirectory: initialDirectory))?.path;

  @override
  Future<String?> pickLogFile(String initialDirectory) async =>
      (await fs.openFile(initialDirectory: initialDirectory))?.path;

  @override
  Future<String?> pickFolder(String initialDirectory) =>
      fs.getDirectoryPath(initialDirectory: initialDirectory);

  @override
  Future<String?> pickZip(String initialDirectory) async => (await fs.openFile(
    acceptedTypeGroups: const [_zipTypes],
    initialDirectory: initialDirectory,
  ))?.path;

  @override
  Future<String?> saveZip(
    String initialDirectory,
    String suggestedName,
  ) async => (await fs.getSaveLocation(
    acceptedTypeGroups: const [_zipTypes],
    initialDirectory: initialDirectory,
    suggestedName: suggestedName,
  ))?.path;
}

/// ffmpeg and exiftool on the desktop, for a background video or photo.
class DesktopDesignerMedia implements DesignerMedia {
  DesktopDesignerMedia(this.tools);

  final DesktopTools tools;

  @override
  Future<MediaTags?> metadata(String path) => tools.exiftool.metadata(path);

  @override
  Future<({double fps, int frames})> videoFacts(String path) async => (
    fps: await tools.ffmpeg.fps(path),
    frames: await tools.ffmpeg.frameCount(path),
  );

  @override
  Future<(int, int)> dimensions(String path) => tools.ffmpeg.dimensions(path);

  @override
  Future<RgbImage?> frameAt(
    String path,
    double seconds,
    int width,
    int height,
  ) => tools.ffmpeg.frameAt(path, seconds, width: width, height: height);
}

typedef DesignerSetup = Future<DesignerController> Function(AppServices);

Future<DesignerController> defaultDesignerSetup(AppServices services) async {
  final kit = await HudKit.load();
  Future<DesignerMedia>? media;
  // In checkout mode the bundled tree is the checkout's own folder, read
  // from disk so that a save shows at once (spec §10.84).
  final checkout = services.capabilities.desktop
      ? checkoutTemplatesDir()
      : null;
  final bundled = checkout == null
      ? await bundledTemplateFolder()
      : DiskTemplateFolder(checkout);
  final controller = DesignerController(
    config: services.config,
    home: services.home,
    kit: kit,
    // The bundled tree is the app's own; the user's is listed again after
    // every save.
    loadFolders: () async => (
      bundled,
      DiskTemplateFolder(services.userTemplatesDir) as TemplateFolder,
    ),
    templateBytes: templateFileBytes,
    checkout: checkout != null,
    onTemplatesChanged: () => services.templatesRevision.value++,
    // One lookup of the tools, tried again after a failure.
    media: () => media ??= services
        .desktopTools()
        .then<DesignerMedia>(DesktopDesignerMedia.new)
        .catchError((Object e) {
          media = null;
          throw e;
        }),
    tempDir: services.tempDir,
  );
  await controller.start();
  return controller;
}

class OverlayDesignerPage extends StatefulWidget {
  const OverlayDesignerPage({
    super.key,
    required this.services,
    this.dialogs = const SystemDesignerDialogs(),
    this.setup = defaultDesignerSetup,
  });

  final AppServices services;
  final DesignerDialogs dialogs;
  final DesignerSetup setup;

  @override
  State<OverlayDesignerPage> createState() => _OverlayDesignerPageState();
}

class _OverlayDesignerPageState extends State<OverlayDesignerPage> {
  DesignerController? controller;
  Object? failed;
  final _canvasFocus = FocusNode(debugLabel: 'designer canvas');
  final _rightScroll = ScrollController();
  final _canvasDown = ScrollController();
  final _canvasAcross = ScrollController();
  bool _listOpen = true;

  @override
  void initState() {
    super.initState();
    widget.services.unitsRevision.addListener(_unitsChanged);
    widget
        .setup(widget.services)
        .then(
          (made) {
            if (!mounted) {
              made.dispose();
              return;
            }
            setState(() => controller = made);
          },
          onError: (Object e) {
            if (mounted) {
              setState(() => failed = e);
            }
          },
        );
  }

  void _unitsChanged() => controller?.unitsChanged();

  @override
  void dispose() {
    widget.services.unitsRevision.removeListener(_unitsChanged);
    controller?.dispose();
    _canvasFocus.dispose();
    _rightScroll.dispose();
    _canvasDown.dispose();
    _canvasAcross.dispose();
    super.dispose();
  }

  // -- the unsaved-changes guard ------------------------------------------

  /// Runs [apply] when nothing is unsaved, or once the user saved or
  /// discarded the changes.
  Future<void> _guarded(Future<void> Function() apply) async {
    final c = controller!;
    if (!c.isDirty) {
      await apply();
      return;
    }
    final go = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Unsaved changes'),
        content: const SizedBox(
          width: 420,
          child: Text(
            'This template has unsaved changes. Switching templates will lose '
            'them unless you save first.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
          if (c.canSave)
            FilledButton(
              onPressed: () async {
                if (await c.save() && context.mounted) {
                  Navigator.pop(context, true);
                }
              },
              child: const Text('Save'),
            ),
        ],
      ),
    );
    if (go == true && mounted) {
      await apply();
    }
  }

  // -- dialogs ---------------------------------------------------------------

  Future<void> _replaceImage() async {
    final c = controller!;
    final path = await widget.dialogs.pickImage(
      widget.services.config.dialogDirFor(
        imageDirField,
        home: widget.services.home,
      ),
    );
    if (path != null && mounted) {
      c.replaceSkinImage(path);
    }
  }

  void _addElement() => showDialog<void>(
    context: context,
    builder: (_) => _AddElementDialog(controller!),
  );

  void _saveAs() => showDialog<void>(
    context: context,
    builder: (_) => _SaveAsDialog(controller!),
  );

  // The background's dialog starts in Pictures, the log's in Downloads.
  String _dir(String field) => widget.services.config.dialogDirFor(
    field,
    home: widget.services.home,
    start: switch (field) {
      backgroundDirField => StartFolder.pictures,
      logDirField => StartFolder.downloads,
      _ => StartFolder.home,
    },
  );

  Future<void> _exportZip() async {
    final c = controller!;
    final path = await widget.dialogs.saveZip(
      _dir(zipDirField),
      c.exportZipName,
    );
    if (path != null && mounted) {
      await c.exportZip(path);
    }
  }

  // A page zip read, then saved as a new page through Save as.
  void _importZip() => _guarded(() async {
    final c = controller!;
    final path = await widget.dialogs.pickZip(_dir(zipDirField));
    if (path == null || !mounted) {
      return;
    }
    final suggested = c.importZip(path);
    if (suggested.isEmpty || !mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _SaveAsDialog(c, importName: suggested),
    );
    // Closed without importing.
    if (c.importPending) {
      c.cancelImport();
    }
  });

  void _mediaDialog() => showDialog<void>(
    context: context,
    builder: (_) => _MediaDialog(
      controller: controller!,
      dialogs: widget.dialogs,
      dir: _dir,
      keptLogs: () => widget.services.logStore.folder.path,
    ),
  );

  void _newCustom() => _guarded(
    () => showDialog<void>(
      context: context,
      builder: (_) => _NewCustomDialog(
        controller!,
        pickImage: () => widget.dialogs.pickImage(
          widget.services.config.dialogDirFor(
            imageDirField,
            home: widget.services.home,
          ),
        ),
      ),
    ),
  );

  // -- the rows ----------------------------------------------------------------

  Widget _combo(
    String label,
    String? value,
    Choices choices,
    FutureOr<void> Function(String key) onPick, {
    double width = 150,
    bool guarded = true,
  }) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 6,
    children: [
      Text(label),
      ConstrainedBox(
        constraints: BoxConstraints(minWidth: 100, maxWidth: width),
        child: DropdownButton<String>(
          isExpanded: true,
          value: choices.containsValue(value) ? value : null,
          items: [
            for (final MapEntry(:key, :value) in choices.entries)
              DropdownMenuItem(
                value: value,
                child: Text(key, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (key) {
            if (key == null || key == value) {
              return;
            }
            if (guarded) {
              _guarded(() async => await onPick(key));
            } else {
              onPick(key);
            }
          },
        ),
      ),
    ],
  );

  Widget _cascade(DesignerController c) => Wrap(
    spacing: 12,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      _combo('Brand', c.selectedBrand, c.brandChoices, c.selectBrand),
      if (c.computerVisible)
        _combo(
          'Computer',
          c.selectedComputer,
          c.computerChoices,
          c.selectComputer,
        ),
      _combo('Page', c.selectedPage, c.pageChoices, c.selectPage, width: 170),
      if (c.variantChoices.isNotEmpty)
        _combo(
          'Variant',
          c.selectedVariant,
          c.variantChoices,
          c.selectVariant,
          width: 140,
        ),
      IconButton(
        icon: const Icon(Icons.undo),
        tooltip: 'Undo (Cmd/Ctrl-Z)',
        onPressed: c.canUndo ? c.undo : null,
      ),
      IconButton(
        icon: const Icon(Icons.redo),
        tooltip: 'Redo (Shift-Cmd/Ctrl-Z)',
        onPressed: c.canRedo ? c.redo : null,
      ),
      Text(
        c.isDirty ? '● Unsaved changes' : 'Saved',
        style: TextStyle(
          fontSize: 12,
          color: c.isDirty ? _warn : const Color(0xFF707070),
        ),
      ),
    ],
  );

  Widget _saveRow(DesignerController c) => Row(
    spacing: 8,
    children: [
      OutlinedButton(onPressed: _newCustom, child: const Text('New custom…')),
      (c.isDirty && c.canSave ? FilledButton.new : OutlinedButton.new)(
        onPressed: c.canSave && c.isDirty ? c.save : null,
        child: const Text('Save'),
      ),
      OutlinedButton(
        onPressed: c.hasDocument ? _saveAs : null,
        child: const Text('Save as…'),
      ),
      TextButton(
        onPressed: c.isDirty ? c.revert : null,
        child: const Text('Revert'),
      ),
      Tooltip(
        message: 'Background and dive logs, export / import a page as a zip',
        child: MenuAnchor(
          builder: (context, menu, _) => TextButton(
            onPressed: () => menu.isOpen ? menu.close() : menu.open(),
            child: const Text('More ▾'),
          ),
          menuChildren: [
            MenuItemButton(
              onPressed: _mediaDialog,
              child: const Text('Background and dive logs…'),
            ),
            const Divider(height: 1),
            MenuItemButton(
              onPressed: c.hasDocument ? _exportZip : null,
              child: const Text('Export page as zip…'),
            ),
            MenuItemButton(
              onPressed: _importZip,
              child: const Text('Import page from zip…'),
            ),
          ],
        ),
      ),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (c.readOnlyHint.isNotEmpty)
              Text(
                c.readOnlyHint,
                style: const TextStyle(fontSize: 12, color: _warn),
                overflow: TextOverflow.ellipsis,
              ),
            Text(
              c.writeTargetText,
              style: const TextStyle(fontSize: 12, color: mutedText),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    ],
  );

  Widget _toggle(
    String label,
    bool on,
    VoidCallback? onPressed, {
    String? tip,
  }) {
    final button = TextButton(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(30, 34),
        backgroundColor: on ? accent.withValues(alpha: 0.25) : null,
      ),
      onPressed: onPressed,
      child: Text(label, style: const TextStyle(fontSize: 13)),
    );
    return tip == null ? button : Tooltip(message: tip, child: button);
  }

  Widget _toolbar(DesignerController c) => Wrap(
    spacing: 3,
    runSpacing: 3,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      _toggle(
        'Design view',
        c.viewMode == viewDesign,
        () => c.setViewMode(viewDesign),
      ),
      _toggle(
        'Frame preview',
        c.viewMode == viewFrame,
        () => c.setViewMode(viewFrame),
      ),
      const SizedBox(width: 8),
      _toggle('Bounds', c.showBounds, () => c.setShowBounds(!c.showBounds)),
      _toggle('Grid', c.showGrid, () => c.setShowGrid(!c.showGrid)),
      _toggle(
        'Snap',
        c.snapEnabled,
        () => c.setSnapEnabled(!c.snapEnabled),
        tip: "Snap dragged elements to the grid and to other elements' edges",
      ),
      Tooltip(
        message: 'Grid size',
        child: DropdownButton<int>(
          value: c.gridSize,
          isDense: true,
          items: [
            for (final size in gridSizes)
              DropdownMenuItem(value: size, child: Text('$size')),
          ],
          onChanged: (v) => c.setGridSize(v!),
        ),
      ),
      const SizedBox(width: 16),
      _toggle('−', false, c.zoomOut),
      SizedBox(
        width: 44,
        child: Text(
          '${c.zoomPercent}%',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),
      ),
      _toggle('+', false, c.zoomIn),
      _toggle('Fit', c.zoomIsFit, c.zoomFit),
      _toggle('100%', false, () => c.setZoomPercent(100)),
    ],
  );

  Widget _canvas(DesignerController c) => Focus(
    focusNode: _canvasFocus,
    onKeyEvent: (_, event) => designerKey(c, event),
    child: ListenableBuilder(
      listenable: _canvasFocus,
      builder: (context, _) => DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF141414),
          border: Border.all(
            color: _canvasFocus.hasFocus ? _select : const Color(0xFF2A2A2A),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, box) {
            // Fit follows the viewport in this same layout, so the canvas is
            // never laid out at the old zoom and resized a frame later; the
            // rest of the page hears of it after the frame.
            final ratioChanged = c.setPixelRatio(
              MediaQuery.devicePixelRatioOf(context),
            );
            if (c.fitViewport(box.maxWidth - 2, box.maxHeight - 2) ||
                ratioChanged) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  c.viewportFitted();
                }
              });
            }
            if (!c.hasDocument) {
              return const Center(child: MutedText('No template selected'));
            }
            final w = c.canvasDisplayWidth.toDouble();
            final h = c.canvasDisplayHeight.toDouble();
            return GestureDetector(
              // The dark area around the picture: focus, and nothing picked.
              onTapDown: (_) {
                _canvasFocus.requestFocus();
                c.clearSelection();
              },
              child: Scrollbar(
                controller: _canvasDown,
                child: SingleChildScrollView(
                  controller: _canvasDown,
                  child: SingleChildScrollView(
                    controller: _canvasAcross,
                    scrollDirection: Axis.horizontal,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minWidth: box.maxWidth - 2,
                        minHeight: box.maxHeight - 2,
                      ),
                      child: Center(
                        child: SizedBox(
                          width: w,
                          height: h,
                          child: _CanvasLayer(
                            key: designerCanvasKey,
                            controller: c,
                            onFocus: _canvasFocus.requestFocus,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );

  Widget _telemetryRow(DesignerController c) => Wrap(
    spacing: 4,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      const Text('Telemetry', style: TextStyle(fontSize: 12)),
      _toggle(
        'Dummy',
        c.telemetrySource == sourceDummy,
        () => c.setTelemetrySource(sourceDummy),
      ),
      _toggle(
        'Loaded log',
        c.telemetrySource == sourceLog,
        c.logTelemetryAvailable ? () => c.setTelemetrySource(sourceLog) : null,
      ),
      const SizedBox(width: 8),
      _combo(
        'State',
        c.stateOverride,
        {for (final s in stateOptions) stateLabels[s]!: s},
        c.selectState,
        width: 190,
        guarded: false,
      ),
      const SizedBox(width: 8),
      Tooltip(
        message:
            "Preview this page in metres or feet; the app's setting "
            '(Settings) is not changed',
        child: _combo(
          'Units',
          c.units.key,
          {for (final s in u.UnitSystem.values) s.label: s.key},
          (key) => c.selectUnits(u.normalizeUnits(key)),
          width: 190,
          guarded: false,
        ),
      ),
    ],
  );

  Widget _timeRow(DesignerController c) => Row(
    spacing: 4,
    children: [
      const Text('Time', style: TextStyle(fontSize: 12)),
      IconButton(
        icon: Icon(c.playing ? Icons.stop : Icons.play_arrow),
        tooltip: c.playing ? 'Pause' : 'Play the dive at 10x speed',
        onPressed: c.timeEnabled ? c.togglePlay : null,
      ),
      Expanded(
        child: Slider(
          min: c.timeMin.toDouble(),
          max: c.timeMax < c.timeMin
              ? c.timeMin.toDouble()
              : c.timeMax.toDouble(),
          value: c.timeValue
              .clamp(c.timeMin, c.timeMax < c.timeMin ? c.timeMin : c.timeMax)
              .toDouble(),
          onChanged: c.timeEnabled ? (v) => c.onTimeChanged(v.round()) : null,
        ),
      ),
      SizedBox(
        width: 64,
        child: Text(c.timeText, style: const TextStyle(fontSize: 12)),
      ),
    ],
  );

  Widget _statusRow(DesignerController c) {
    final count = c.selectionCount;
    final hidden = c.hiddenIndices.length;
    final tag = count > 1
        ? '$count selected'
        : hidden > 0
        ? '$hidden hidden'
        : '';
    return Row(
      spacing: 12,
      children: [
        if (tag.isNotEmpty) MutedText(tag, size: 12),
        Expanded(
          child: Text(
            c.dataText,
            style: const TextStyle(fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Expanded(
          child: Text(
            c.status,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12, color: Color(0xFF808080)),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _elementList(DesignerController c) {
    final rows = c.elementRows;
    final selected = c.selectedIndices.toSet();
    return SectionCard(
      children: [
        Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: () => setState(() => _listOpen = !_listOpen),
                child: Text(
                  '${_listOpen ? '▾' : '▸'}  Elements (${rows.length})'
                  '${!_listOpen && c.selectionLabel.isNotEmpty ? '  ·  ${c.selectionLabel}' : ''}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            TextButton(
              onPressed: c.hasDocument ? _addElement : null,
              child: const Text('+ Add'),
            ),
          ],
        ),
        if (_listOpen) ...[
          Material(
            type: MaterialType.transparency,
            child: ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              title: const Text(
                'Skin and placement',
                style: TextStyle(fontSize: 12),
              ),
              selected: c.skinSelected,
              selectedTileColor: accent.withValues(alpha: 0.15),
              onTap: c.selectSkin,
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 6 * 30),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final row in rows)
                  Opacity(
                    opacity: row.hidden ? 0.45 : 1,
                    child: Material(
                      type: MaterialType.transparency,
                      child: ListTile(
                        key: ValueKey('element-${row.index}'),
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        selected: selected.contains(row.index),
                        selectedTileColor: accent.withValues(alpha: 0.15),
                        title: Text(
                          '${row.label}  ·  ${row.kind}',
                          style: const TextStyle(fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (row.shared) const MutedText('shared', size: 10),
                            IconButton(
                              iconSize: 16,
                              visualDensity: VisualDensity.compact,
                              icon: Icon(
                                row.hidden
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                              ),
                              tooltip: row.hidden
                                  ? 'Show element (designer only)'
                                  : 'Hide element (designer only)',
                              onPressed: () => c.toggleHidden(row.index),
                            ),
                          ],
                        ),
                        onTap: () {
                          final keys = HardwareKeyboard.instance;
                          if (keys.isControlPressed ||
                              keys.isMetaPressed ||
                              keys.isShiftPressed) {
                            c.toggleElement(row.index);
                          } else {
                            c.selectElement(row.index);
                          }
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (rows.isEmpty)
            const MutedText('No elements - use + Add', size: 12),
        ],
      ],
    );
  }

  Widget _rightColumn(DesignerController c) => SizedBox(
    width: _rightColumnWidth,
    child: Scrollbar(
      controller: _rightScroll,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _rightScroll,
        padding: const EdgeInsets.only(right: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            Text(
              c.templateTitle,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            _elementList(c),
            DesignerInspector(controller: c, onReplaceImage: _replaceImage),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c == null) {
      return PageFrame(
        title: 'Overlay Designer',
        children: [
          if (failed != null)
            Text(
              'The designer could not start: $failed',
              style: const TextStyle(color: _error),
            )
          else
            const Center(child: CircularProgressIndicator()),
        ],
      );
    }
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 10,
          children: [
            _cascade(c),
            _saveRow(c),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 8,
                      children: [
                        _toolbar(c),
                        Expanded(child: _canvas(c)),
                        _telemetryRow(c),
                        _timeRow(c),
                        _statusRow(c),
                      ],
                    ),
                  ),
                  _rightColumn(c),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The picture with the editing layer on it: element bounds, the selection
/// and its label, the marquee, and the pointer handed to the controller in
/// canvas pixels.
class _CanvasLayer extends StatelessWidget {
  const _CanvasLayer({
    super.key,
    required this.controller,
    required this.onFocus,
  });

  final DesignerController controller;
  final VoidCallback onFocus;

  Widget _box(
    DisplayBox box, {
    Color fill = Colors.transparent,
    required Color border,
    double width = 1,
  }) => Positioned(
    left: box.$1,
    top: box.$2,
    width: box.$3,
    height: box.$4,
    child: IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          border: Border.all(color: border, width: width),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final image = c.canvasImage;
    final selection = c.selectionBox;
    final marquee = c.marqueeBox;
    // The press is followed by the controller, not by this build: a press
    // rebuilds the page before the pointer moves.
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        if (event.buttons != kPrimaryButton) {
          return;
        }
        onFocus();
        final keys = HardwareKeyboard.instance;
        c.press(
          event.localPosition.dx,
          event.localPosition.dy,
          toggle:
              keys.isControlPressed ||
              keys.isMetaPressed ||
              keys.isShiftPressed,
        );
      },
      onPointerMove: (event) {
        if (c.pressing) {
          c.drag(event.localPosition.dx, event.localPosition.dy);
        }
      },
      onPointerUp: (_) {
        if (c.pressing) {
          c.release();
        }
      },
      onPointerCancel: (_) {
        if (c.pressing) {
          c.release();
        }
      },
      // The press is the canvas's own: the dark area's tap must not clear
      // what it picked.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) {},
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: image == null
                  ? const SizedBox()
                  : RawImage(
                      image: image,
                      fit: BoxFit.fill,
                      // The design view comes in the screen's pixels; a
                      // pixel's rounding at the edge is smoothed, not
                      // doubled.
                      filterQuality: FilterQuality.medium,
                    ),
            ),
            if (c.showBounds)
              for (final box in c.elementBoxes)
                _box(box, border: const Color(0x663B82F6)),
            for (final box in c.secondarySelectionBoxes)
              _box(box, fill: const Color(0x183B82F6), border: _select),
            if (marquee != null)
              _box(marquee, fill: const Color(0x2222C55E), border: _marquee),
            if (selection != null) ...[
              _box(
                selection,
                fill: const Color(0x223B82F6),
                border: _select,
                width: 2,
              ),
              Positioned(
                left: selection.$1,
                bottom: c.canvasDisplayHeight - selection.$2 + 2,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: _select,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: Text(
                      c.selectionLabel,
                      style: const TextStyle(fontSize: 11, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// "Add element" (Python `qml/AddElementPopup.qml`).
class _AddElementDialog extends StatefulWidget {
  const _AddElementDialog(this.controller);

  final DesignerController controller;

  @override
  State<_AddElementDialog> createState() => _AddElementDialogState();
}

const _addKinds = {
  'text': 'Telemetry field',
  'custom': 'Custom label',
  'badge': 'State badge',
  'tank_icon': 'Tank icon',
  'graph': 'Depth graph',
  'tissue_bar': 'Tissue load bar',
  'ascent_chevrons': 'Ascent chevrons',
  'notice': 'Notice',
  'tank_switch_arrows': 'Tank switch arrows',
  'arc': 'Arc gauge',
  'segment_bar': 'Segment bar',
};

// The kinds the dialog's field picker is shown for.
const _fieldKinds = {'text', 'tank_icon', 'arc', 'segment_bar'};

class _AddElementDialogState extends State<_AddElementDialog> {
  String kind = 'text';
  late String field = widget.controller.addableFields.contains('depth')
      ? 'depth'
      : widget.controller.addableFields.firstOrNull ?? '';
  final _custom = TextEditingController();

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  String get _help => switch (kind) {
    'badge' =>
      'Label + ceiling depth + countdown for safety stop / deco / clear, '
          "styled by the computer's hud_rules.json.",
    'graph' =>
      'Whole-dive depth profile with a playback cursor and deco-ceiling '
          'shading.',
    'tank_icon' =>
      'Colour fill (red / yellow / green by pressure), optionally with its '
          'own drawn outline.',
    'tissue_bar' =>
      'Garmin-style vertical nitrogen-loading bar (green / yellow / red) '
          'with a marker at the current load.',
    'ascent_chevrons' =>
      "Ascent-rate indicator in the template's brand style: Garmin - "
          'chevrons over a bar, green / yellow / red, the lower one on '
          'descent; Shearwater - six arrows, white / yellow / flashing red, '
          'one per 3 m/min (Perdix 2 manual p.12).',
    'arc' =>
      'Arc gauge (Suunto EON style): a circular track filled from its start '
          'by the field over Range min - max (raw units: seconds for NDL / '
          'TTS, bar for a tank, m/min for the ascent rate). Put its label '
          'and value inside as text elements.',
    'segment_bar' =>
      'Vertical stack of segments lit from the bottom by the field over '
          "Range min - max (Suunto's ascent bar: 5 segments, 0-10 m/min, one "
          'per 2 m/min). Colour by value, or each segment by its place on the '
          'scale.',
    'tank_switch_arrows' =>
      'Descent-style triangles that point at the sidemount tank to breathe '
          'from while the two tanks differ by more than the switch pressure '
          '(hud_rules.json sidemount_switch); nothing is drawn otherwise. '
          "Tick 'Hide during a tank switch' on the SM label and tank icons "
          'they replace.',
    'notice' =>
      "The computer's own notification (FAST ASCENT, MISSED DECO STOP, HIGH "
          'PPO2, Low NDL Alert…) in its wording and colours from '
          'hud_rules.json, shown for a few seconds when the log triggers it. '
          "Nothing is drawn otherwise. Tick 'Hide while a notice shows' on "
          'the elements it covers.',
    'text' when field == depthSmallDecimals =>
      'Depth with the decimal part in a small font, top-aligned with the '
          'metres (e.g. 12 and a small .3) - the way Garmin and Shearwater '
          'computers show it. Saved as a depth element with the Small suffix '
          'style set; adjust Suffix size in the inspector.',
    'text' when field == diveTimeSmallSeconds =>
      'Dive time with the seconds in a small font, top-aligned with the '
          'minutes (e.g. 32 and a small :15) - the way Garmin and Shearwater '
          'computers show it. Saved as a dive_time element with the Small '
          'suffix style set; adjust Suffix size in the inspector.',
    _ =>
      'New elements appear at the centre of the skin - drag them into place '
          'or type X/Y in the inspector.',
  };

  void _add() {
    final c = widget.controller;
    if (kind == 'custom') {
      if (_custom.text.trim().isEmpty) {
        return;
      }
      c.addCustomLabel(_custom.text);
    } else if (_fieldKinds.contains(kind)) {
      c.addElement(field, kind);
    } else {
      // The kind names its own field.
      c.addElement(kind, kind);
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add element'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          RadioGroup<String>(
            groupValue: kind,
            onChanged: (v) => setState(() {
              kind = v!;
              // An arc starts on the NDL, a segment bar on the ascent rate.
              final preset = const {
                'arc': 'ndl',
                'segment_bar': 'ascent_rate',
              }[kind];
              final fields = widget.controller.addableFields;
              if (preset != null && fields.isNotEmpty) {
                field = fields.contains(preset) ? preset : fields.first;
              }
            }),
            child: Wrap(
              children: [
                for (final MapEntry(:key, :value) in _addKinds.entries)
                  SizedBox(
                    width: 200,
                    child: RadioListTile<String>(
                      dense: true,
                      value: key,
                      title: Text(value),
                    ),
                  ),
              ],
            ),
          ),
          if (_fieldKinds.contains(kind))
            Row(
              spacing: 8,
              children: [
                const Text('Field'),
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: field,
                    items: [
                      for (final f in widget.controller.addableFields)
                        DropdownMenuItem(value: f, child: Text(f)),
                    ],
                    onChanged: (v) => setState(() => field = v!),
                  ),
                ),
              ],
            ),
          if (kind == 'custom')
            TextField(
              controller: _custom,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Text',
                hintText: 'e.g. NDL, m, BAR',
              ),
              onSubmitted: (_) => _add(),
            ),
          MutedText(_help, size: 12),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _add, child: const Text('Add')),
    ],
  );
}

/// Where a page goes: the computer it is saved under, a new computer's
/// name, and the page name, with the path it will get.
class _TargetFields extends StatelessWidget {
  const _TargetFields({
    required this.controller,
    required this.target,
    required this.onTarget,
    required this.computer,
    required this.page,
    required this.pageHint,
    this.extra = const [],
  });

  final DesignerController controller;
  final int target;
  final ValueChanged<int> onTarget;
  final TextEditingController computer;
  final TextEditingController page;
  final String pageHint;
  final List<Widget> extra;

  @override
  Widget build(BuildContext context) {
    final targets = controller.saveAsTargets;
    final newComputer = target == targets.length - 1;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Row(
          spacing: 12,
          children: [
            const SizedBox(width: 110, child: Text('Under')),
            Expanded(
              child: DropdownButton<int>(
                isExpanded: true,
                value: target,
                items: [
                  for (final (i, t) in targets.indexed)
                    DropdownMenuItem(value: i, child: Text(t.label)),
                ],
                onChanged: (v) => onTarget(v!),
              ),
            ),
          ],
        ),
        if (newComputer)
          Row(
            spacing: 12,
            children: [
              const SizedBox(width: 110, child: Text('Computer name')),
              Expanded(
                child: TextField(
                  controller: computer,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: 'e.g. My HUD'),
                ),
              ),
            ],
          ),
        ...extra,
        Row(
          spacing: 12,
          children: [
            const SizedBox(width: 110, child: Text('Page name')),
            Expanded(
              child: TextField(
                controller: page,
                autofocus: !newComputer,
                decoration: InputDecoration(hintText: pageHint),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

String _wouldBe(
  DesignerController c,
  int target,
  String computer,
  String page,
) {
  final targets = c.saveAsTargets;
  final t = targets[target.clamp(0, targets.length - 1)];
  final newComputer = target == targets.length - 1;
  final comp = newComputer ? c.slugFor(computer) : t.computer;
  final slug = c.slugFor(page);
  return '${t.brand}/${comp.isEmpty ? '…' : comp}/${slug.isEmpty ? '…' : slug}';
}

/// "Save as new page" (Python `qml/SaveTemplateAsPopup.qml`).
class _SaveAsDialog extends StatefulWidget {
  const _SaveAsDialog(this.controller, {this.importName});

  final DesignerController controller;

  /// Set for a page zip being imported: the page name to suggest.
  final String? importName;

  @override
  State<_SaveAsDialog> createState() => _SaveAsDialogState();
}

class _SaveAsDialogState extends State<_SaveAsDialog> {
  bool get importing => widget.importName != null;

  // An import goes under a new computer unless another is picked.
  late int target = importing
      ? widget.controller.saveAsTargets.length - 1
      : widget.controller.saveAsCurrentTargetIndex;
  final _computer = TextEditingController();
  late final _page = TextEditingController(text: widget.importName ?? '');
  String error = '';
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _computer.addListener(() => setState(() {}));
    _page.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _computer.dispose();
    _page.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (busy) {
      return;
    }
    setState(() => busy = true);
    final result = importing
        ? await widget.controller.finishImport(
            target,
            _computer.text,
            _page.text,
          )
        : await widget.controller.saveAs(target, _computer.text, _page.text);
    if (!mounted) {
      return;
    }
    if (result.isEmpty) {
      Navigator.pop(context);
    } else {
      setState(() {
        error = result;
        busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final newComputer = target == c.saveAsTargets.length - 1;
    return AlertDialog(
      title: Text(importing ? 'Import as new page' : 'Save as new page'),
      content: SizedBox(
        width: 470,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 10,
          children: [
            _TargetFields(
              controller: c,
              target: target,
              onTarget: (v) => setState(() => target = v),
              computer: _computer,
              page: _page,
              pageHint: 'e.g. My main screen',
            ),
            MutedText(
              'Will be saved as ${_wouldBe(c, target, _computer.text, _page.text)}'
              '${newComputer ? ' (default colour rules)' : " (inherits this computer's colour and warning rules)"}',
              size: 12,
            ),
            if (error.isNotEmpty)
              Text(error, style: const TextStyle(color: _error)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: busy ? null : _save,
          child: Text(importing ? 'Import' : 'Save'),
        ),
      ],
    );
  }
}

/// "New custom template" (Python `qml/NewCustomTemplatePopup.qml`): an
/// empty page on an image or a rounded rectangle.
class _NewCustomDialog extends StatefulWidget {
  const _NewCustomDialog(this.controller, {required this.pickImage});

  final DesignerController controller;
  final Future<String?> Function() pickImage;

  @override
  State<_NewCustomDialog> createState() => _NewCustomDialogState();
}

class _NewCustomDialogState extends State<_NewCustomDialog> {
  late int target = widget.controller.saveAsTargets.length - 1;
  final _computer = TextEditingController();
  final _page = TextEditingController(text: 'Main');
  final _width = TextEditingController(text: '400');
  final _height = TextEditingController(text: '200');
  final _color = TextEditingController(text: '#000000');
  String kind = 'image';
  String imagePath = '';
  String rules = 'Default';
  String error = '';
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _computer.addListener(() => setState(() {}));
    _page.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    for (final text in [_computer, _page, _width, _height, _color]) {
      text.dispose();
    }
    super.dispose();
  }

  Future<void> _create() async {
    if (busy) {
      return;
    }
    setState(() => busy = true);
    final result = await widget.controller.createCustomTemplate(
      targetIndex: target,
      newComputerName: _computer.text,
      pageName: _page.text,
      backgroundKind: kind,
      imagePath: imagePath,
      rulesProfile: rules,
      shapeWidth: _width.text,
      shapeHeight: _height.text,
      shapeColor: _color.text.trim(),
    );
    if (!mounted) {
      return;
    }
    if (result.isEmpty) {
      Navigator.pop(context);
    } else {
      setState(() {
        error = result;
        busy = false;
      });
    }
  }

  Widget _row(String label, Widget field) => Row(
    spacing: 12,
    children: [
      SizedBox(width: 110, child: Text(label)),
      Expanded(child: field),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final newComputer = target == c.saveAsTargets.length - 1;
    final digits = [FilteringTextInputFormatter.digitsOnly];
    return AlertDialog(
      title: const Text('New custom template'),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 10,
            children: [
              _TargetFields(
                controller: c,
                target: target,
                onTarget: (v) => setState(() => target = v),
                computer: _computer,
                page: _page,
                pageHint: 'e.g. Main',
                extra: [
                  if (newComputer)
                    _row(
                      'Colour rules',
                      DropdownButton<String>(
                        isExpanded: true,
                        value: rules,
                        items: [
                          for (final profile in c.rulesProfiles)
                            DropdownMenuItem(
                              value: profile,
                              child: Text(profile),
                            ),
                        ],
                        onChanged: (v) => setState(() => rules = v!),
                      ),
                    ),
                ],
              ),
              _row(
                'Background',
                RadioGroup<String>(
                  groupValue: kind,
                  onChanged: (v) => setState(() => kind = v!),
                  child: const Row(
                    children: [
                      Expanded(
                        child: RadioListTile<String>(
                          dense: true,
                          value: 'image',
                          title: Text('Image'),
                        ),
                      ),
                      Expanded(
                        child: RadioListTile<String>(
                          dense: true,
                          value: 'shape',
                          title: Text('Shape'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (kind == 'image')
                _row(
                  'Image file',
                  Row(
                    spacing: 8,
                    children: [
                      Expanded(
                        child: Text(
                          imagePath.isEmpty
                              ? 'PNG, JPEG, WebP or BMP - PNG with '
                                    'transparency works best'
                              : imagePath,
                          style: TextStyle(
                            color: imagePath.isEmpty ? mutedText : null,
                            fontSize: 12,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      OutlinedButton(
                        onPressed: () async {
                          final path = await widget.pickImage();
                          if (path != null && mounted) {
                            c.rememberImageDir(path);
                            setState(() => imagePath = path);
                          }
                        },
                        child: const Text('Browse…'),
                      ),
                    ],
                  ),
                )
              else
                _row(
                  'Size (px)',
                  Row(
                    spacing: 8,
                    children: [
                      SizedBox(
                        width: 70,
                        child: TextField(
                          controller: _width,
                          inputFormatters: digits,
                        ),
                      ),
                      const Text('×'),
                      SizedBox(
                        width: 70,
                        child: TextField(
                          controller: _height,
                          inputFormatters: digits,
                        ),
                      ),
                      const Text('Colour'),
                      SizedBox(width: 90, child: TextField(controller: _color)),
                    ],
                  ),
                ),
              MutedText(
                'Creates ${_wouldBe(c, target, _computer.text, _page.text)}'
                '${newComputer ? '' : " (inherits this computer's colour and warning rules)"}'
                '. An image background is copied in and scaled to fit; add '
                'fields afterwards with + Add.',
                size: 12,
              ),
              if (error.isNotEmpty)
                Text(error, style: const TextStyle(color: _error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: busy ? null : _create,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// "Background and dive logs" (the More menu, Python's media popup): a
/// photo or video behind Frame preview, dive logs matched to its time with
/// the hours between the clocks, a loaded dive previewed on its own, and
/// the raw data of the sample shown.
class _MediaDialog extends StatelessWidget {
  const _MediaDialog({
    required this.controller,
    required this.dialogs,
    required this.dir,
    required this.keptLogs,
  });

  final DesignerController controller;
  final DesignerDialogs dialogs;
  final String Function(String field) dir;

  /// The folder of the logs kept in the app (the Dive Logs page).
  final String Function() keptLogs;

  Future<void> _showWaypoint(BuildContext context) async {
    final json = controller.waypointJson();
    if (json == null || !context.mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Current Waypoint Raw Data'),
        content: SizedBox(
          width: 500,
          height: 600,
          child: SingleChildScrollView(
            child: SelectableText(
              json,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller;
      return AlertDialog(
        title: const Text('Background and dive logs (optional)'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 10,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: () async {
                      final path = await dialogs.pickMedia(
                        dir(backgroundDirField),
                      );
                      if (path != null) {
                        await c.loadBackground(path);
                      }
                    },
                    child: const Text('Load video/photo'),
                  ),
                  OutlinedButton(
                    onPressed: c.hasBackground ? c.clearBackground : null,
                    child: const Text('Clear background'),
                  ),
                  OutlinedButton(
                    onPressed: () async {
                      final path = await dialogs.pickLogFile(dir(logDirField));
                      if (path != null) {
                        await c.loadLogFile(path);
                      }
                    },
                    child: const Text('Select log file'),
                  ),
                  OutlinedButton(
                    onPressed: () async {
                      final path = await dialogs.pickFolder(dir(logDirField));
                      if (path != null) {
                        await c.loadLogFolder(path);
                      }
                    },
                    child: const Text('Select log directory'),
                  ),
                  OutlinedButton(
                    onPressed: () => c.loadLogFolder(keptLogs(), kept: true),
                    child: const Text(importedLogsPlaceLabel),
                  ),
                ],
              ),
              Row(
                children: [
                  const Text('TZ offset (log vs media)'),
                  Expanded(
                    child: Slider(
                      min: -24,
                      max: 24,
                      divisions: 48,
                      value: c.tzValue.toDouble(),
                      onChanged: (v) => c.setTz(v.round(), match: false),
                      onChangeEnd: (v) => c.setTz(v.round()),
                    ),
                  ),
                  SizedBox(width: 40, child: Text(c.tzText)),
                ],
              ),
              const Text('Preview a loaded log directly (no video needed)'),
              DropdownButton<String>(
                isExpanded: true,
                value: c.selectedLogLabel,
                hint: Text(c.logFileEnabled ? 'Pick a dive' : 'No logs loaded'),
                items: [
                  for (final label in c.logFileList)
                    DropdownMenuItem(
                      value: label,
                      child: Text(label, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: c.logFileEnabled
                    ? (label) => c.selectLogFile(label!)
                    : null,
              ),
              MutedText(c.logText, size: 12),
              if (c.status.isNotEmpty) MutedText(c.status, size: 12),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => _showWaypoint(context),
            child: const Text('Show raw waypoint data'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}
