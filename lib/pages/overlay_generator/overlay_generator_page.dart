/// The Overlay Generator page on the desktop (Python
/// `qml/OverlayGeneratorPage.qml`): the overlays alone, for every video and
/// photo of a folder against the dive logs, or for a whole dive of one log
/// file.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/hud_kit.dart';
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/hud/template_tree.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/engine/desktop/color_batch.dart';
import 'package:uwmedia_app/engine/desktop/overlay_batch.dart';
import 'package:uwmedia_app/engine/file_picks.dart' as fs;
import 'package:uwmedia_app/engine/media_library.dart';
import 'package:uwmedia_app/engine/result_folder.dart';
import 'package:uwmedia_app/pages/overlay_generator/overlay_generator_controller.dart';
import 'package:uwmedia_app/pages/shared/dive_match_button.dart';
import 'package:uwmedia_app/pages/shared/logs_folder.dart';
import 'package:uwmedia_app/pages/shared/photos.dart';
import 'package:uwmedia_app/pages/shared/place_menu.dart';
import 'package:uwmedia_app/pages/shared/save_to.dart';
import 'package:uwmedia_app/pages/shared/template_picker.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

/// The runs on the desktop, a fresh [OverlayBatch] each.
class DesktopOverlayGeneratorEngine implements OverlayGeneratorEngine {
  DesktopOverlayGeneratorEngine(this.tools, this.kit, this.services);

  final DesktopTools tools;
  final HudKit kit;
  final AppServices services;
  OverlayBatch? _batch;

  OverlayBatch _fresh() => _batch = OverlayBatch(
    tools: tools,
    renderer: kit.renderer,
    painter: kit.painter,
    tanks: services.config.tankConfig().tanks,
    units: normalizeUnits(services.config.settings()['units']),
    native: services.nativeVideoEngine,
  );

  @override
  Future<MediaTags?> metadata(String path) => tools.exiftool.metadata(path);

  @override
  Future<List<FileResult>> runFolder(
    OverlayFolderSettings settings,
    ColorBatchListener listener,
  ) => _fresh().runFolder(settings, listener);

  @override
  Future<String> runLog({
    required String logPath,
    required String output,
    required String layoutPath,
    required OverlayLook look,
    bool hwAccel = true,
    void Function(double percent)? onProgress,
    void Function(String line)? onMessage,
  }) => _fresh().runLog(
    logPath: logPath,
    output: output,
    layoutPath: layoutPath,
    look: look,
    hwAccel: hwAccel,
    onProgress: onProgress,
    onMessage: onMessage,
  );

  @override
  Future<void> stop() async => _batch?.stop();
}

/// The page's file dialogs, so that a test can answer for them.
abstract interface class OverlayGeneratorDialogs {
  /// A layout file of the user's own.
  Future<String?> pickFile(String initialDirectory);

  /// Photos and videos, several at once; empty when none was picked.
  Future<List<String>> pickFiles(String initialDirectory);
  Future<String?> pickFolder(String initialDirectory);
}

class SystemOverlayGeneratorDialogs implements OverlayGeneratorDialogs {
  const SystemOverlayGeneratorDialogs();

  @override
  Future<String?> pickFile(String initialDirectory) async =>
      (await fs.openFile(initialDirectory: initialDirectory))?.path;

  @override
  Future<List<String>> pickFiles(String initialDirectory) async => [
    for (final file in await fs.openFiles(initialDirectory: initialDirectory))
      file.path,
  ];

  @override
  Future<String?> pickFolder(String initialDirectory) =>
      fs.getDirectoryPath(initialDirectory: initialDirectory);
}

typedef OverlayGeneratorSetup = Future<OverlayGeneratorController> Function(
  AppServices,
);

Future<OverlayGeneratorController> defaultOverlayGeneratorSetup(
  AppServices services,
) async {
  final kit = await HudKit.load();
  final bundled = await bundledTemplateFolder();
  TemplateTree list() => TemplateTree(
    bundled: bundled,
    user: DiskTemplateFolder(services.userTemplatesDir),
  );
  // One lookup of the tools, shared by every caller (a Stop during the
  // first one reaches the same engine).
  Future<OverlayGeneratorEngine>? engine;
  return OverlayGeneratorController(
    config: services.config,
    gate: services.batches,
    home: services.home,
    keptLogsDir: services.logStore.folder.path,
    engine: () => engine ??= services
        .desktopTools()
        .then<OverlayGeneratorEngine>(
          (tools) => DesktopOverlayGeneratorEngine(tools, kit, services),
        )
        .catchError((Object e) {
          // Tried again next time.
          engine = null;
          throw e;
        }),
    picker: TemplatePicker(
      list(),
      tempDir: services.tempDir,
      templateBytes: templateFileBytes,
      relist: list,
    ),
  );
}

class OverlayGeneratorPage extends StatefulWidget {
  const OverlayGeneratorPage({
    super.key,
    required this.services,
    this.dialogs = const SystemOverlayGeneratorDialogs(),
    this.setup = defaultOverlayGeneratorSetup,
    this.photos,
  });

  final AppServices services;
  final OverlayGeneratorDialogs dialogs;
  final OverlayGeneratorSetup setup;

  /// Apple Photos, in place of the system's (a test's).
  final MediaLibrary? photos;

  @override
  State<OverlayGeneratorPage> createState() => _OverlayGeneratorPageState();
}

class _OverlayGeneratorPageState extends State<OverlayGeneratorPage> {
  OverlayGeneratorController? controller;
  Object? failed;
  int? _row;
  final _customPath = TextEditingController();

  // Apple Photos, as on the Color page (spec §10.50): the working folder
  // of what was picked there, and the one the results wait in on their
  // way into an album (with the output folder as it was before).
  String? _photosSource;
  String? _photosOut;
  String _outputBefore = '';
  bool _wasRunning = false;
  int _photosCount = 0;

  // While the results of a run are being saved into Photos: no new run.
  bool _savingPhotos = false;

  MediaLibrary? get _photos =>
      widget.photos ??
      (widget.services.capabilities.photos
          ? const PlatformMediaLibrary()
          : null);

  Future<void> _fromPhotos() async {
    final c = controller!;
    final String? dir;
    try {
      dir = await pickFromPhotos(
        _photos!,
        widget.services.tempDir,
        page: 'Overlay Generator',
      );
    } on Exception catch (e) {
      c.message('Could not pick from Photos: $e');
      return;
    }
    if (dir == null || !mounted) {
      return;
    }
    final picked = dir;
    setState(() {
      _photosSource = picked;
      _photosCount = mediaIn(picked).length;
    });
    c.setSource(picked, remember: false);
  }

  void _intoPhotos(bool on) {
    final c = controller!;
    if (on) {
      _outputBefore = c.outputText;
      final dir = widget.services.tempDir('uwmedia_photos_out_').path;
      setState(() => _photosOut = dir);
      c.setOutput(dir, remember: false);
    } else {
      setState(() => _photosOut = null);
      c.setOutput(_outputBefore, remember: false);
    }
  }

  Future<void> _chooseAlbum() async {
    final album = await chooseResultAlbum(context, widget.services.config);
    if (album == null || !mounted) {
      return;
    }
    if (_photosOut == null) {
      _intoPhotos(true);
    } else {
      setState(() {});
    }
  }

  // A run that ended with the results waiting for Photos: into an album.
  void _runWatch() {
    final c = controller;
    if (c == null) {
      return;
    }
    final ended = _wasRunning && !c.isRunning;
    _wasRunning = c.isRunning;
    final out = _photosOut;
    final library = _photos;
    if (!ended || out == null || library == null) {
      return;
    }
    if (c.statusText == 'Aborted') {
      c.message(discardStopped(out));
      return;
    }
    setState(() => _savingPhotos = true);
    unawaited(
      saveFolderIntoPhotos(
        library,
        out,
        album: keptResultAlbum(widget.services.config),
      ).then((lines) {
        if (mounted) {
          setState(() => _savingPhotos = false);
          lines.forEach(c.message);
        }
      }),
    );
  }

  @override
  void initState() {
    super.initState();
    widget.services.templatesRevision.addListener(_templatesChanged);
    widget.services.keptLogsRevision.addListener(_keptLogsChanged);
    widget
        .setup(widget.services)
        .then(
          (made) {
            if (!mounted) {
              made.dispose();
              return;
            }
            setState(() => controller = made);
            made
              ..addListener(_runWatch)
              ..loadLogChoices();
          },
          onError: (Object e) {
            if (mounted) {
              setState(() => failed = e);
            }
          },
        );
  }

  // A page saved in the Overlay Designer is offered at once.
  void _templatesChanged() => controller?.picker.reload();

  // Logs kept or removed on the Dive Logs page: the dives offered follow.
  void _keptLogsChanged() {
    if (mounted) {
      setState(() {});
      controller?.loadLogChoices();
    }
  }

  @override
  void dispose() {
    widget.services.templatesRevision.removeListener(_templatesChanged);
    widget.services.keptLogsRevision.removeListener(_keptLogsChanged);
    controller?.dispose();
    _customPath.dispose();
    super.dispose();
  }

  Future<void> _pickCustomLayout() async {
    final c = controller!;
    final path = await widget.dialogs.pickFile(
      c.dialogDir(hudCustomPathDirField),
    );
    if (path == null || !mounted) {
      return;
    }
    c.rememberDialogDir(hudCustomPathDirField, p.dirname(path));
    _customPath.text = path;
    c.customPathText = path;
  }

  Future<void> _pickSourceFiles() async {
    final c = controller!;
    final files = await widget.dialogs.pickFiles(
      c.dialogDir(hudSourceDirField),
    );
    if (files.isEmpty || !mounted) {
      return;
    }
    setState(() => _photosSource = null);
    c
      ..rememberDialogDir(hudSourceDirField, p.dirname(files.first))
      ..setSourceFiles(files);
  }

  Future<void> _pickOutputFolder() async {
    final c = controller!;
    final path = await widget.dialogs.pickFolder(
      c.dialogDir(hudOutputDirField),
    );
    if (path == null || !mounted) {
      return;
    }
    c.rememberDialogDir(hudOutputDirField, path);
    if (_photosOut != null) {
      // Out of Photos again, into the folder picked.
      setState(() => _photosOut = null);
    }
    c.outputText = path;
  }

  // A folder of frames for each overlay is nothing for an album: out of
  // Photos when that format is chosen.
  void _setOutputFormat(String format) {
    final c = controller!..outputFormat = format;
    if (c.outputIsFrames && _photosOut != null) {
      _intoPhotos(false);
    }
  }

  Widget _dropdown(
    String label,
    String value,
    List<String> items,
    void Function(String) onChanged, {
    String? tooltip,
    bool enabled = true,
  }) {
    final field = Row(
      spacing: 8,
      children: [
        SizedBox(width: 120, child: Text(label)),
        Expanded(
          child: DropdownButton<String>(
            isExpanded: true,
            value: items.contains(value) ? value : null,
            items: [
              for (final item in items)
                DropdownMenuItem(value: item, child: Text(item)),
            ],
            onChanged: enabled ? (v) => onChanged(v!) : null,
          ),
        ),
      ],
    );
    return tooltip == null ? field : Tooltip(message: tooltip, child: field);
  }

  Widget _settings() {
    final c = controller!;
    final running = c.isRunning;
    final logMode = c.logFileMode;
    final matches = c.diveMatches;
    return SectionCard(
      children: [
        // What the overlays are made for: the photos and videos picked,
        // each matched to its dive, or a whole dive without a video.
        Tooltip(
          message:
              'Photos and videos: an overlay for each, matched to its dive '
              'in the logs kept on the Dive Logs page.\nA whole dive: the '
              'overlay of one dive from start to end with no video, e.g. one '
              'saved by the Dive Profile Builder and imported on the Dive '
              'Logs page.',
          child: SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('Photos and videos')),
              ButtonSegment(value: true, label: Text('A whole dive')),
            ],
            selected: {logMode},
            onSelectionChanged: running
                ? null
                : (picked) => c.logFileMode = picked.first,
          ),
        ),
        if (logMode)
          DropdownButton<String>(
            isExpanded: true,
            hint: Text(
              c.logChoices.isEmpty ? 'No dive logs kept yet' : 'Choose a dive',
            ),
            value: c.logChoices.any((log) => log.path == c.logFileText)
                ? c.logFileText
                : null,
            items: [
              for (final log in c.logChoices)
                DropdownMenuItem(
                  value: log.path,
                  child: Text(log.label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: running ? null : (v) => c.logFileText = v!,
          )
        else ...[
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: PlaceMenuButton(
              label: chooseMediaLabel,
              icon: Icons.photo_library_outlined,
              filled: true,
              enabled: !running,
              places: [
                (
                  icon: Icons.description_outlined,
                  label: filesPlaceLabel,
                  onPressed: _pickSourceFiles,
                ),
                if (_photos != null)
                  (
                    icon: Icons.photo_library_outlined,
                    label: photoLibraryPlaceLabel,
                    onPressed: _fromPhotos,
                  ),
              ],
            ),
          ),
          if (_photos != null) const PhotosFetching(),
          if (c.hasSource)
            SelectableText(
              _photosSource != null && c.sourceText == _photosSource
                  ? fromPhotosText(_photosCount)
                  : c.sourceSummary,
              style: const TextStyle(fontSize: 12),
            ),
        ],
        SaveToPlace(
          location: _photosOut != null
              ? saveToText(null, keptResultAlbum(widget.services.config))
              : c.outputText.trim().isEmpty
              ? null
              : c.displayPath(c.outputText),
          enabled: !running && !_savingPhotos,
          places: [
            (
              icon: Icons.folder_outlined,
              label: folderPlaceLabel,
              onPressed: _pickOutputFolder,
            ),
            // A video for each overlay can go into an album; a folder of
            // frames cannot.
            if (_photos != null && !c.outputIsFrames)
              (
                icon: Icons.photo_library_outlined,
                label: saveToAlbumChoice,
                onPressed: _chooseAlbum,
              ),
          ],
        ),
        DiveMatchButton(
          matches: matches,
          pending: c.diveMatchesPending,
          onDiveLogs: () => widget.services.openPage(diveLogsTitle),
        ),
        DiveLogsLink(
          services: widget.services,
          kept: c.keptLogsCount,
          enabled: !running,
        ),
        _dropdown(
          'Output filename',
          c.filenameFormat,
          [for (final (label, _) in renderLogFormatPresets) label],
          (v) => c.filenameFormat = v,
          enabled: !running && !logMode,
        ),
        _dropdown(
          'Overlay size',
          c.overlaySize,
          [for (final (label, _, _) in overlaySizeChoices) label],
          (v) => c.overlaySize = v,
          enabled: !running,
          tooltip:
              "1080p: the template's size in a 1920×1080 frame. 4K: twice "
              'that, 1:1 on 4K footage. Full frame: the whole 1920×1080 / '
              '3840×2160 frame with the overlay placed as in the template - '
              'nothing to position in the editor.',
        ),
        _dropdown(
          'Output format',
          c.outputFormat,
          [for (final (label, _) in outputFormatChoices) label],
          _setOutputFormat,
          enabled: !running,
          tooltip:
              'Transparent ProRes 4444 drops onto the footage in any editor '
              'with nothing to key out. PNG sequence writes one frame per file '
              'into a folder. Video on black is the old output: key out the '
              'black.',
        ),
        Row(
          children: [
            const Text('Skip if target exists'),
            Switch(
              value: c.skipExisting,
              onChanged: running || logMode ? null : (v) => c.skipExisting = v,
            ),
            const SizedBox(width: 16),
            const MutedText('Hardware acceleration', size: 14),
            Switch(
              value: c.hwAccel,
              onChanged: running ? null : (v) => c.hwAccel = v,
            ),
          ],
        ),
      ],
    );
  }

  Widget _picker() {
    final c = controller!;
    final picker = c.picker;
    final running = c.isRunning;
    Widget choice(
      String label,
      Map<String, String> choices,
      String? selected,
      void Function(String) onPick,
    ) => _dropdown(
      label,
      choices.entries.where((e) => e.value == selected).firstOrNull?.key ?? '',
      choices.keys.toList(),
      (name) => onPick(choices[name]!),
      enabled: !running,
    );
    final brands = {...picker.brandChoices, layoutCustom: layoutCustom};
    return SectionCard(
      title: 'Select overlay',
      children: [
        choice(
          'HUD brand',
          brands,
          c.isCustom ? layoutCustom : picker.selectedBrand,
          c.selectBrand,
        ),
        if (c.isCustom)
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _customPath,
                  decoration: const InputDecoration(
                    labelText: 'Custom path',
                    hintText: 'A layout file (.json)',
                  ),
                  onChanged: (v) => c.customPathText = v,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.description_outlined),
                tooltip: 'Choose file',
                onPressed: running ? null : _pickCustomLayout,
              ),
            ],
          )
        else ...[
          if (picker.computerVisible)
            choice(
              'Dive computer',
              picker.computerChoices,
              picker.selectedComputer,
              picker.selectComputer,
            ),
          choice(
            'Page',
            picker.pageChoices,
            picker.selectedPage,
            picker.selectPage,
          ),
          if (picker.variantChoices.isNotEmpty)
            Tooltip(
              message:
                  'Which tank layout of the page to render - no tank, single '
                  'tank, sidemount or multi-tank',
              child: choice(
                'Tank setup',
                picker.variantChoices,
                picker.selectedVariant,
                picker.selectVariant,
              ),
            ),
        ],
        if (picker.error.isNotEmpty && !c.isCustom)
          Text(picker.error, style: const TextStyle(color: Color(0xFFEF4444))),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: cardBorder),
            borderRadius: BorderRadius.circular(4),
          ),
          child: SizedBox(
            height: 120,
            child: Material(
              type: MaterialType.transparency,
              child: ListView(
                children: [
                  for (final (i, overlay) in c.overlays.indexed)
                    ListTile(
                      dense: true,
                      title: Text(overlay.label),
                      selected: i == _row,
                      selectedColor: accent,
                      onTap: () => setState(() => _row = i),
                    ),
                ],
              ),
            ),
          ),
        ),
        Row(
          spacing: 8,
          children: [
            FilledButton(
              onPressed: running ? null : c.addOverlay,
              child: const Text('+ Add'),
            ),
            OutlinedButton(
              onPressed: running || _row == null
                  ? null
                  : () {
                      c.removeOverlayAt(_row!);
                      setState(() => _row = null);
                    },
              child: const Text('Remove Selected'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _progress() {
    final c = controller!;
    final owner = widget.services.batches.owner;
    final blocked =
        !c.isRunning &&
        (_savingPhotos || (owner != null && owner != overlayGeneratorPage));
    Widget bar(double value, String text) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 2,
      children: [
        LinearProgressIndicator(value: c.progressKnown ? value : null),
        if (text.isNotEmpty) MutedText(text, size: 11),
      ],
    );
    return SectionCard(
      title: 'Progress',
      children: [
        if (c.isRunning) ...[
          if (c.overlayProgressText.isNotEmpty)
            MutedText(c.overlayProgressText),
          bar(c.currentProgress, c.currentProgressText),
          bar(c.totalProgress, c.totalProgressText),
        ],
        if (c.timingText.isNotEmpty) MutedText(c.timingText, size: 11),
        SelectableText(
          c.statusText,
          style: const TextStyle(color: mutedText, fontSize: 12),
        ),
        if (c.messages.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: MutedText('${c.messages.length} messages'),
            children: [
              for (final line in c.messages)
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    line,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
            ],
          ),
        SizedBox(
          height: 40,
          child: Tooltip(
            message: !blocked
                ? ''
                : _savingPhotos
                ? 'Saving into Photos…'
                : 'Another operation ($owner) is already running',
            child: FilledButton.icon(
              icon: Icon(c.isRunning ? Icons.stop : Icons.play_arrow),
              label: Text(c.isRunning ? 'Stop' : 'Start'),
              onPressed: blocked ? null : c.startOrStop,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c == null) {
      return Center(
        child: failed == null
            ? const CircularProgressIndicator()
            : Text('The Overlay Generator could not start: $failed'),
      );
    }
    return ListenableBuilder(
      listenable: Listenable.merge([c, c.picker, widget.services.batches]),
      builder: (context, _) => PageFrame(
        title: 'Overlay Generator',
        maxWidth: 820,
        children: [_settings(), _picker(), _progress()],
      ),
    );
  }
}
