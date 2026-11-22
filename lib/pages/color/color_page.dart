/// The Color page (Python `qml/ColorPage.qml` and `AddHudPopup.qml`): the
/// live preview with the overlays placed on it, the clock offset, the
/// overlay list, colour correction, source, output, logs and naming, and
/// the run's progress. On a phone (spec §9.2) the source is what was
/// picked from the library, the logs are the ones kept in the app, and the
/// results go into a new album; the page is otherwise the same.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/hud_kit.dart';
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/engine/share_sizes.dart';
import 'package:uwmedia_app/core/hud/template_tree.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/core/util/py_strftime.dart';
import 'package:uwmedia_app/engine/desktop/color_batch.dart';
import 'package:uwmedia_app/engine/desktop/free_space.dart';
import 'package:uwmedia_app/engine/file_picks.dart' as fs;
import 'package:uwmedia_app/engine/keep_awake.dart';
import 'package:uwmedia_app/engine/media_library.dart';
import 'package:uwmedia_app/engine/mobile_color_batch.dart';
import 'package:uwmedia_app/engine/mobile_engine.dart';
import 'package:uwmedia_app/engine/photo_run.dart';
import 'package:uwmedia_app/engine/result_folder.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/pages/color/color_controller.dart';
import 'package:uwmedia_app/pages/shared/dive_match_button.dart';
import 'package:uwmedia_app/pages/shared/loading_icon.dart';
import 'package:uwmedia_app/pages/shared/logs_folder.dart';
import 'package:uwmedia_app/pages/shared/phone_files.dart';
import 'package:uwmedia_app/pages/shared/photos.dart';
import 'package:uwmedia_app/pages/shared/place_menu.dart';
import 'package:uwmedia_app/pages/shared/save_to.dart';
import 'package:uwmedia_app/widgets/run_progress.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

const _selection = Color(0xFF3B82F6);

/// The preview's handles reach this far around a corner, in screen pixels.
const _handleReach = 16.0;

/// How long a press on the preview is held before the original is shown.
const originalHold = Duration(milliseconds: 300);

/// The engine on the desktop: ffmpeg, ffprobe and exiftool, and the
/// app's overlay drawing.
class DesktopColorPageEngine implements ColorPageEngine {
  DesktopColorPageEngine(this.tools, this.kit, this.services);

  final DesktopTools tools;
  final HudKit kit;
  final AppServices services;
  ColorBatch? _batch;

  UnitSystem get _units => normalizeUnits(services.config.settings()['units']);

  @override
  Future<MediaTags?> metadata(String path) => tools.exiftool.metadata(path);

  @override
  Future<({double fps, int frames})> videoFacts(String path) async => (
    fps: await tools.ffmpeg.fps(path),
    frames: await tools.ffmpeg.frameCount(path),
  );

  // The preview's frames and facts stay ffmpeg's whichever engine writes
  // the videos: one picture to compare the two engines' results with.
  @override
  Future<RgbImage?> frameAt(
    String path,
    double seconds,
    int width,
    int height,
  ) => tools.ffmpeg.frameAt(path, seconds, width: width, height: height);

  @override
  Future<(int, int)> dimensions(String path) =>
      tools.ffmpeg.displayDimensions(path);

  @override
  Future<ui.Image> overlaid(
    ui.Image base,
    List<HudLayerSource> layers,
    Waypoint? waypoint,
    List<Waypoint>? waypoints,
  ) => PhotoRun(
    renderer: kit.renderer,
    painter: kit.painter,
    units: _units,
  ).overlaid(base, layers, waypoint, waypoints);

  @override
  Future<List<FileResult>> run(
    ColorBatchSettings settings,
    ColorBatchListener listener,
  ) async {
    final batch = _batch = ColorBatch(
      tools: tools,
      renderer: kit.renderer,
      painter: kit.painter,
      tempDir: services.tempDir,
      tanks: services.config.tankConfig().tanks,
      units: _units,
      native: services.nativeVideoEngine,
    );
    try {
      return await batch.run(settings, listener);
    } finally {
      // A later Stop is not for this batch.
      _batch = null;
    }
  }

  @override
  Future<void> stop() async => _batch?.stop();
}

/// The engine on a phone: the phone's media engine for videos, the app's
/// own readers for the dates, and the app's overlay drawing.
class MobileColorPageEngine implements ColorPageEngine {
  MobileColorPageEngine(
    this.engine,
    this.library,
    this.kit,
    this.services, {
    this.folders = const PlatformResultFolders(),
  });

  /// The folders of the phone's files, for results that go into one.
  final ResultFolders folders;

  final MobileMediaEngine engine;
  final MediaLibrary library;
  final HudKit kit;
  final AppServices services;
  MobileColorBatch? _batch;

  UnitSystem get _units => normalizeUnits(services.config.settings()['units']);

  @override
  Future<MediaTags?> metadata(String path) async => readDatesOrNull(path);

  @override
  Future<({double fps, int frames})> videoFacts(String path) async {
    final clip = await engine.probe(path);
    return (fps: clip.frameRate, frames: clip.totalFrames);
  }

  @override
  Future<RgbImage?> frameAt(
    String path,
    double seconds,
    int width,
    int height,
  ) => engine.frameAt(
    path,
    seconds,
    maxWidth: width,
    maxHeight: height,
    exact: true,
  );

  @override
  Future<(int, int)> dimensions(String path) async {
    final clip = await engine.probe(path);
    return (clip.width, clip.height);
  }

  @override
  Future<ui.Image> overlaid(
    ui.Image base,
    List<HudLayerSource> layers,
    Waypoint? waypoint,
    List<Waypoint>? waypoints,
  ) => PhotoRun(
    renderer: kit.renderer,
    painter: kit.painter,
    units: _units,
  ).overlaid(base, layers, waypoint, waypoints);

  @override
  Future<List<FileResult>> run(
    ColorBatchSettings settings,
    ColorBatchListener listener,
  ) async {
    final batch = _batch = MobileColorBatch(
      engine: engine,
      library: library,
      renderer: kit.renderer,
      painter: kit.painter,
      tempDir: services.tempDir,
      tanks: services.config.tankConfig().tanks,
      units: _units,
      saveTo: services.capabilities.resultFolders
          ? keptSavePlace(services.config, folders, library)
          : null,
    );
    try {
      return await withScreenOn(
        () => batch.run(settings, _RunProgressTap(listener)),
        onStop: batch.stop,
      );
    } finally {
      _batch = null;
    }
  }

  @override
  Future<void> stop() async => _batch?.stop();
}

/// Passes a run's news on to the page, and how many files are done to
/// the runner (Android's notification of the run).
class _RunProgressTap implements ColorBatchListener {
  _RunProgressTap(this.to);

  final ColorBatchListener to;

  @override
  void started(int total) {
    unawaited(reportRunProgress(0, total));
    to.started(total);
  }

  @override
  void active(String file) => to.active(file);

  @override
  void finished(int done, int total, FileResult result) {
    unawaited(reportRunProgress(done, total));
    to.finished(done, total, result);
  }

  @override
  void progress(String file, double percent) => to.progress(file, percent);

  @override
  void message(String line) => to.message(line);
}

/// The page on a phone: the phone's engine, a working folder for the
/// results before they go into the album, and the logs kept in the app.
Future<ColorController> phoneColorSetup(AppServices services) async {
  final kit = await HudKit.load();
  final bundled = await bundledTemplateFolder();
  TemplateTree list() => TemplateTree(
    bundled: bundled,
    user: DiskTemplateFolder(services.userTemplatesDir),
  );
  final profiles = services.config.colorProfiles(
    await rootBundle.loadString('assets/color.yaml'),
  );
  final engine = MobileColorPageEngine(
    const PlatformMediaEngine(),
    const PlatformMediaLibrary(),
    kit,
    services,
  );
  final controller = ColorController(
    config: services.config,
    gate: services.batches,
    home: services.home,
    engine: () async => engine,
    profiles: profiles,
    templates: list(),
    tempDir: services.tempDir,
    templateBytes: templateFileBytes,
    relistTemplates: list,
    watermarkStore: services.watermarks,
  )..setOutput(services.tempDir('uwmedia_color_out_').path);
  // Read while the page is shown: the kept logs' dives take seconds on a
  // phone (8.6 s for 119 logs on the iPhone, spec §10.89).
  unawaited(controller.setLogs(services.logStore.folder.path));
  return controller;
}

/// [files] (picked from the library) moved into a fresh working folder
/// made by [tempDir], a name that is there already numbered; the folder.
/// It takes the place of the page's folder before ([keepPicked]).
Directory collectPicked(
  List<String> files,
  Directory Function(String prefix) tempDir,
) {
  final dir = tempDir('uwmedia_picked_');
  final unique = UniquePaths(
    (path) => FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound,
  );
  for (final file in files) {
    final target = unique.unique(p.join(dir.path, p.basename(file)));
    try {
      File(file).renameSync(target);
    } on FileSystemException {
      File(file).copySync(target);
    }
  }
  keepPicked(colorPage, dir.path);
  return dir;
}

/// The page's file dialogs, so that a test can answer for them.
abstract interface class ColorDialogs {
  /// Photos and videos, several at once; empty when none was picked.
  Future<List<String>> pickFiles(String initialDirectory);
  Future<String?> pickFolder(String initialDirectory);
}

class SystemColorDialogs implements ColorDialogs {
  const SystemColorDialogs();

  @override
  Future<List<String>> pickFiles(String initialDirectory) async => [
    for (final file in await fs.openFiles(initialDirectory: initialDirectory))
      file.path,
  ];

  @override
  Future<String?> pickFolder(String initialDirectory) =>
      fs.getDirectoryPath(initialDirectory: initialDirectory);
}

/// What the page is made with: by default the assets, the user's
/// templates folder and the tools as found.
typedef ColorPageSetup = Future<ColorController> Function(AppServices);

Future<ColorController> defaultColorSetup(AppServices services) async {
  final kit = await HudKit.load();
  final bundled = await bundledTemplateFolder();
  TemplateTree list() => TemplateTree(
    bundled: bundled,
    user: DiskTemplateFolder(services.userTemplatesDir),
  );
  final profiles = services.config.colorProfiles(
    await rootBundle.loadString('assets/color.yaml'),
  );
  // One lookup of the tools, shared by every caller.
  Future<ColorPageEngine>? engine;
  return ColorController(
    config: services.config,
    gate: services.batches,
    home: services.home,
    keptLogsDir: services.logStore.folder.path,
    compareOffered: services.capabilities.desktop,
    engine: () => engine ??= services
        .desktopTools()
        .then<ColorPageEngine>(
          (tools) => DesktopColorPageEngine(tools, kit, services),
        )
        .catchError((Object e) {
          // Tried again next time.
          engine = null;
          throw e;
        }),
    profiles: profiles,
    templates: list(),
    tempDir: services.tempDir,
    templateBytes: templateFileBytes,
    relistTemplates: list,
    watermarkStore: services.watermarks,
    freeSpace: freeBytes,
  );
}

/// The most of the screen's height the preview takes on a phone (owner,
/// 2026-11-18: a portrait picture took too much).
const previewHeightShare = 0.42;

class ColorPage extends StatefulWidget {
  const ColorPage({
    super.key,
    required this.services,
    this.dialogs = const SystemColorDialogs(),
    this.setup = defaultColorSetup,
    this.phone = false,
    this.pickMedia,
    this.pickFiles = pickFromFiles,
    this.photos,
  });

  final AppServices services;
  final ColorDialogs dialogs;
  final ColorPageSetup setup;

  /// The phone's page: media from the library, the kept logs, results
  /// into an album (spec §9.2).
  final bool phone;

  /// Photos and videos picked from the library (the phone's page); by
  /// default the library's own picker.
  final Future<List<String>> Function()? pickMedia;

  /// Photos and videos picked from the phone's files (the phone's page).
  final Future<List<String>> Function() pickFiles;

  /// Apple Photos beside the folders on the desktop's page (spec §10.50);
  /// by default the Mac's, where the app runs on one.
  final MediaLibrary? photos;

  @override
  State<ColorPage> createState() => _ColorPageState();
}

class _ColorPageState extends State<ColorPage> {
  ColorController? controller;
  Object? failed;
  final _diveTime = TextEditingController();

  // The clock offset is one row until it is opened.
  bool _offsetOpen = false;
  Timer? _hold;

  // Apple Photos on the desktop's page: the working folder of what was
  // picked there, and the one the results wait in on their way into an
  // album (with the output folder as it was before).
  String? _photosSource;
  String? _photosOut;
  String _outputBefore = '';
  bool _wasRunning = false;
  int _photosCount = 0;

  // While the results of a run are being saved into Photos: no new run,
  // and the switch stays as it is.
  bool _savingPhotos = false;

  MediaLibrary? get _photos => widget.phone
      ? null
      : widget.photos ??
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
        page: colorPage,
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
    await c.setSource(picked, remember: false);
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
    if (c.statusText == 'Stopped') {
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

  // A press held on the picture itself (not on an overlay) shows the
  // original until it is let go.
  void _holdStarted() {
    _hold?.cancel();
    final c = controller!;
    if (c.dragging) {
      return;
    }
    _hold = Timer(originalHold, () => c.showOriginal = true);
  }

  void _holdEnded() {
    _hold?.cancel();
    _hold = null;
    controller?.showOriginal = false;
  }

  @override
  void initState() {
    super.initState();
    widget.services.templatesRevision.addListener(_templatesChanged);
    widget.services.watermarksRevision.addListener(_watermarksChanged);
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
              ..refreshPreview();
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

  // Logs kept or removed on the Dive Logs page: the file shown is matched
  // to them again.
  void _keptLogsChanged() => controller?.loadDives();

  // A watermark added or changed on the Settings page is offered at once.
  void _watermarksChanged() => controller?.watermarksChanged();

  @override
  void dispose() {
    widget.services.templatesRevision.removeListener(_templatesChanged);
    widget.services.watermarksRevision.removeListener(_watermarksChanged);
    widget.services.keptLogsRevision.removeListener(_keptLogsChanged);
    _hold?.cancel();
    controller?.dispose();
    _diveTime.dispose();
    super.dispose();
  }

  // The desktop's source: files picked in the dialog, one or several.
  Future<void> _pickSourceFiles() async {
    final c = controller!;
    final files = await widget.dialogs.pickFiles(
      c.dialogDir(colorSourceDirField),
    );
    if (files.isEmpty || !mounted) {
      return;
    }
    c.rememberDialogDir(colorSourceDirField, p.dirname(files.first));
    setState(() => _photosSource = null);
    await c.setSourceFiles(files);
  }

  Future<void> _pickOutputFolder() async {
    final c = controller!;
    final path = await widget.dialogs.pickFolder(
      c.dialogDir(colorOutputDirField),
    );
    if (path == null || !mounted) {
      return;
    }
    c.rememberDialogDir(colorOutputDirField, path);
    if (_photosOut != null) {
      // Out of Photos again, into the folder picked.
      setState(() => _photosOut = null);
    }
    c.setOutput(path);
  }

  // Where the desktop's photos and videos come from and where the
  // results go: picked, not typed (owner, 2026-11-16; spec §10.65).
  List<Widget> _sourceAndOutput() {
    final c = controller!;
    final running = c.isRunning;
    final fromPhotos = _photosSource != null && c.sourceText == _photosSource;
    final output = _photosOut != null
        ? saveToText(null, keptResultAlbum(widget.services.config))
        : c.outputText.trim().isEmpty
        ? null
        : c.displayPath(c.outputText);
    final matches = c.diveMatches;
    return [
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
          fromPhotos ? fromPhotosText(_photosCount) : c.sourceSummary,
          style: const TextStyle(fontSize: 12),
        ),
      if (c.sourceCountText.isNotEmpty) MutedText(c.sourceCountText),
      SaveToPlace(
        location: output,
        enabled: !running && !_savingPhotos,
        places: [
          (
            icon: Icons.folder_outlined,
            label: folderPlaceLabel,
            onPressed: _pickOutputFolder,
          ),
          if (_photos != null)
            (
              icon: Icons.photo_library_outlined,
              label: saveToAlbumChoice,
              onPressed: _chooseAlbum,
            ),
        ],
      ),
      // The room the results take, and when the disk has not got it
      // (spec §10.96).
      if (c.spaceText.isNotEmpty)
        c.spaceShort
            ? Row(
                spacing: 6,
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 16,
                    color: partlyMatchedColor,
                  ),
                  Expanded(
                    child: Text(
                      c.spaceText,
                      style: const TextStyle(
                        fontSize: 12,
                        color: partlyMatchedColor,
                      ),
                    ),
                  ),
                ],
              )
            : MutedText(c.spaceText),
      DiveMatchButton(
        matches: matches,
        pending: c.diveMatchesPending,
        onDiveLogs: () => widget.services.openPage(diveLogsTitle),
      ),
      // With logs kept, the way to the Dive Logs page is in the list.
      DiveLogsLink(
        services: widget.services,
        kept: keptLogsIn(c.keptLogsDir),
        enabled: !running,
      ),
    ];
  }

  Widget _preview(BoxConstraints constraints) {
    final c = controller!;
    var width = constraints.maxWidth.clamp(200.0, 760.0);
    var height = width * c.viewHeight / c.viewWidth;
    // An upright picture as wide as the page would fill the screen and
    // push the controls off it: no higher than a share of the screen.
    final room =
        MediaQuery.sizeOf(context).height *
        (widget.phone ? previewHeightShare : 0.7);
    if (height > room) {
      height = room;
      width = height * c.viewWidth / c.viewHeight;
    }
    final toFrame = c.viewWidth / width;
    final original = c.showOriginal && c.originalImage != null;
    final image = original ? c.originalImage : c.previewImage;
    // One finger on an overlay moves it; one finger on the picture moves
    // the picture under the window, two fingers zoom it (owner,
    // 2026-11-19: on the preview itself, no "Select picture…").
    final listener = Listener(
      onPointerDown: (e) {
        _touches[e.pointer] = e.localPosition;
        _moved = 0;
        if (_touches.length > 1) {
          // A second finger: no overlay is moved, no original shown.
          _holdEnded();
          c.release();
          return;
        }
        if (!c.isRunning) {
          c.pressAt(
            e.localPosition.dx * toFrame,
            e.localPosition.dy * toFrame,
            _handleReach * toFrame,
          );
        }
        _holdStarted();
      },
      onPointerMove: c.isRunning
          ? null
          : (e) {
              final before = _touches[e.pointer];
              if (before == null) {
                return;
              }
              if (_touches.length > 1) {
                final others = [
                  for (final MapEntry(:key, :value) in _touches.entries)
                    if (key != e.pointer) value,
                ];
                final other = others.first;
                _touches[e.pointer] = e.localPosition;
                if (!c.canCrop) {
                  return;
                }
                final was = (before - other).distance;
                final now = (e.localPosition - other).distance;
                if (was > 1 && now > 1) {
                  c.zoomCrop(now / was);
                }
                // The middle of the two moves half as far as the finger.
                final by = (e.localPosition - before) / 2;
                c.panCrop(by.dx / width, by.dy / height);
                return;
              }
              _touches[e.pointer] = e.localPosition;
              if (c.dragging) {
                c.dragTo(
                  e.localPosition.dx * toFrame,
                  e.localPosition.dy * toFrame,
                );
                return;
              }
              if (!c.canCrop) {
                return;
              }
              final by = e.localPosition - before;
              _moved += by.distance;
              if (_moved > 6) {
                // A drag, not a press held for the original.
                _holdEnded();
              }
              c.panCrop(by.dx / width, by.dy / height);
            },
      // A pinch on a trackpad.
      onPointerPanZoomStart: (_) => _trackpadScale = 1,
      onPointerPanZoomUpdate: c.isRunning || !c.canCrop
          ? null
          : (e) {
              if (e.scale > 0 && _trackpadScale > 0) {
                c.zoomCrop(e.scale / _trackpadScale);
              }
              _trackpadScale = e.scale;
            },
      onPointerUp: (e) {
        _touches.remove(e.pointer);
        _holdEnded();
        if (!c.isRunning) {
          c.release();
        }
      },
      onPointerCancel: (e) {
        _touches.remove(e.pointer);
        _holdEnded();
        c.release();
      },
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (image != null) RawImage(image: image, fit: BoxFit.fill),
            if (c.previewLoading) const Center(child: LoadingIcon()),
            if (original)
              const Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0xAA000000),
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      child: Text('Original'),
                    ),
                  ),
                ),
              )
            else
              CustomPaint(
                painter: _SelectionPainter(
                  box:
                      c.markDragBox ??
                      (c.selectedOverlay == null
                          ? null
                          : c.boxOf(c.selectedOverlay!)),
                  scale: 1 / toFrame,
                  dragging: c.dragging,
                ),
              ),
          ],
        ),
      ),
    );
    final sized = SizedBox(
      key: const ValueKey('preview'),
      width: width,
      height: height,
      // A touch on the preview is the picture's from the moment a finger
      // is down (it moves an overlay or the picture, two fingers zoom):
      // the page it lies in scrolls, and would take the drag and then
      // the second finger too.
      child: RawGestureDetector(
        gestures: {
          _PreviewTouch: GestureRecognizerFactoryWithHandlers<_PreviewTouch>(
            _PreviewTouch.new,
            (_) {},
          ),
        },
        child: listener,
      ),
    );
    // A picture made narrower for its height lies in the middle, on a
    // computer too: stretched to the card's width, it was wider than the
    // box and the pointer took it to be (owner, 2026-11-19).
    return Align(heightFactor: 1, child: sized);
  }

  // The fingers on the preview and where each is; how far a single one
  // has gone since it came down; a trackpad pinch's last scale.
  final _touches = <int, Offset>{};
  double _moved = 0;
  double _trackpadScale = 1;

  // The shape of the videos written and the way to the window (owner,
  // 2026-11-18: with the picture, not with the size).
  Widget _pictureRow() {
    final c = controller!;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [
        // A list, not buttons in a row: five shapes do not fit a phone.
        DropdownButton<ShareShape>(
          key: const ValueKey('picture shape'),
          value: c.pictureShape,
          isDense: true,
          items: [
            for (final (shape, label) in pictureShapeLabels)
              if (c.shapeChoices.contains(shape))
                DropdownMenuItem(value: shape, child: Text(label)),
          ],
          onChanged: c.isRunning || !c.canShape
              ? null
              : (picked) {
                  if (picked != null) {
                    c.pictureShape = picked;
                  }
                },
        ),
        MutedText(
          c.canShape
              ? c.pictureText
              : 'The shape and a part of the picture: with one photo or '
                    'one video selected.',
          size: 11,
        ),
      ],
    );
  }

  // How far the picture is zoomed in, and the way back. On a computer
  // with a slider too: a mouse has no two fingers.
  List<Widget> _zoomRow() {
    final c = controller!;
    final zoom = 1 / c.cropSize;
    return [
      if (!widget.phone || c.cropSize < 1)
        Row(
          children: [
            const Icon(Icons.zoom_in, size: 18),
            if (widget.phone)
              const Spacer()
            else
              Expanded(
                child: Slider(
                  key: const ValueKey('crop zoom'),
                  min: 1,
                  max: 1 / minCropSize,
                  value: zoom.clamp(1, 1 / minCropSize),
                  onChanged: c.isRunning ? null : (v) => c.setCrop(size: 1 / v),
                ),
              ),
            Text('${zoom.toStringAsFixed(1)}×'),
            TextButton(
              onPressed: c.isRunning ? null : c.clearCrop,
              child: const Text('Reset'),
            ),
          ],
        ),
      MutedText(
        widget.phone
            ? 'Zoom in with two fingers and drag the picture to the part '
                  'to keep.'
            : 'Zoom in with the slider or a pinch on the trackpad, and '
                  'drag the picture to the part to keep.',
        size: 11,
      ),
    ];
  }

  Widget _offsetControls({bool heading = true}) {
    final c = controller!;
    final enabled = c.canSync && !c.isRunning;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 2,
          children: [
            if (heading) const Text('Clock offset'),
            for (final (seconds, label) in const [
              (-60.0, '-1m'),
              (-10.0, '-10s'),
              (-1.0, '-1s'),
              (1.0, '+1s'),
              (10.0, '+10s'),
              (60.0, '+1m'),
            ])
              Tooltip(
                message:
                    'Move the overlay against the footage until its depth '
                    'follows the scene',
                child: TextButton(
                  onPressed: enabled ? () => c.nudgeOffset(seconds) : null,
                  child: Text(label),
                ),
              ),
            SizedBox(
              width: 72,
              child: Text(c.offsetSecondsText, textAlign: TextAlign.right),
            ),
            Tooltip(
              message: 'Back to no correction',
              child: TextButton(
                onPressed: enabled ? c.resetOffset : null,
                child: const Text('0'),
              ),
            ),
          ],
        ),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            const Text('Computer shows'),
            SizedBox(
              width: 80,
              child: TextField(
                controller: _diveTime,
                enabled: enabled,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'mm:ss',
                ),
                onSubmitted: c.syncToDiveTime,
              ),
            ),
            Tooltip(
              message:
                  'Scrub to a frame where the dive computer is readable, type '
                  'the dive time it shows, and this frame becomes that moment '
                  'of the dive',
              child: OutlinedButton(
                onPressed: enabled
                    ? () => c.syncToDiveTime(_diveTime.text)
                    : null,
                child: const Text('Set'),
              ),
            ),
            const Text('Hours'),
            Tooltip(
              message: 'Whole hours, for a camera left on home time',
              child: DropdownButton<int>(
                value: c.offsetHours,
                items: [
                  for (var h = -12; h <= 14; h++)
                    DropdownMenuItem(
                      value: h,
                      child: Text('${h > 0 ? '+' : ''}$h h'),
                    ),
                ],
                onChanged: enabled ? (v) => c.setOffsetHours(v ?? 0) : null,
              ),
            ),
          ],
        ),
        if (c.offsetText.isNotEmpty) MutedText(c.offsetText),
      ],
    );
  }

  // The offset is one row that says what is set, opened to the controls
  // when it is to be changed (Python: the controls always there; spec
  // §10.62, on the desktop too since §10.64).
  Widget _offsetRow() {
    final c = controller!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _offsetOpen = !_offsetOpen),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              spacing: 8,
              children: [
                const Text('Clock offset'),
                Expanded(child: MutedText(c.offsetSummary, maxLines: 1)),
                Icon(_offsetOpen ? Icons.expand_less : Icons.expand_more),
              ],
            ),
          ),
        ),
        if (_offsetOpen) _offsetControls(heading: false),
      ],
    );
  }

  Widget _leftColumn() {
    final c = controller!;
    final dive = c.matchedDive;
    final taken = c.matchTime;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        // The heading is the card's own, so the card starts level with
        // the first one beside it (owner, 2026-11-16).
        SectionCard(
          title: 'Live preview',
          children: [
            _pictureRow(),
            // The card's own width, inside its padding: the column's would
            // squeeze the picture into the card while the box and the
            // pointer kept the column's scale (owner, 2026-11-19).
            LayoutBuilder(builder: (context, inner) => _preview(inner)),
            if (c.canCrop) ..._zoomRow(),
            Row(
              children: [
                // The part a second longer at its start (and at its end,
                // after the slider).
                if (c.trimmed)
                  IconButton(
                    key: const ValueKey('part earlier'),
                    icon: const Icon(Icons.keyboard_double_arrow_left),
                    tooltip: 'Start the part 1 s earlier',
                    visualDensity: VisualDensity.compact,
                    onPressed: c.isRunning || c.part.start <= 0
                        ? null
                        : () => c.extendPart(atStart: true),
                  ),
                Expanded(
                  // Over the part alone when one is set (owner,
                  // 2026-11-18): a short part of a long video has the
                  // whole slider.
                  child: Slider(
                    key: const ValueKey('scrub'),
                    min: c.scrubFrom.toDouble(),
                    max: math.max(c.scrubUntil, c.scrubFrom + 1).toDouble(),
                    value: c.scrubValue
                        .clamp(
                          c.scrubFrom,
                          math.max(c.scrubUntil, c.scrubFrom + 1),
                        )
                        .toDouble(),
                    onChanged: c.scrubEnabled && !c.isRunning
                        ? (v) => c.scrubTo(v.round())
                        : null,
                  ),
                ),
                if (c.trimmed)
                  IconButton(
                    key: const ValueKey('part later'),
                    icon: const Icon(Icons.keyboard_double_arrow_right),
                    tooltip: 'End the part 1 s later',
                    visualDensity: VisualDensity.compact,
                    onPressed: c.isRunning || c.part.end >= c.videoSeconds
                        ? null
                        : () => c.extendPart(atStart: false),
                  ),
                Text(c.scrubTimeText),
              ],
            ),
            // The part of the video to write (spec §10.71, §10.75): a
            // long video, ten seconds of it to share.
            if (c.canTrim) ...[
              RangeSlider(
                key: const ValueKey('video part'),
                min: c.partFrom,
                max: c.partUntil,
                values: RangeValues(c.part.start, c.part.end),
                onChanged: c.isRunning
                    ? null
                    : (v) => c.setPart(v.start, v.end),
                // The slider's stretch moves only when the finger is off
                // it.
                onChangeEnd: (_) => c.settlePartView(),
              ),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 4,
                children: [
                  MutedText('Part to write: ${c.partText}', size: 12),
                  if (c.trimmed)
                    IconButton(
                      key: const ValueKey('whole video'),
                      icon: const Icon(Icons.settings_backup_restore, size: 18),
                      tooltip: 'The whole video again',
                      visualDensity: VisualDensity.compact,
                      onPressed: c.isRunning ? null : c.clearPart,
                    ),
                ],
              ),
              const MutedText(
                'Drag the two ends to the part. The slider then shows the '
                'part with 5 s before and after it; drag an end into that '
                'to make the part longer.',
                size: 11,
              ),
            ],
            if (c.previewImage != null)
              const MutedText(
                'Press and hold the picture to see the original.',
                size: 11,
              ),
            MutedText(
              dive == null && c.divesLoading
                  ? 'Reading the dive logs…'
                  : dive == null
                  ? taken == null
                        ? 'No dive matched to this file'
                        // The time the logs were searched for: a camera
                        // clock off by hours shows here.
                        : 'No dive matched to this file (its time with '
                              'the offset: '
                              '${pyStrftime(taken, '%Y-%m-%d %H:%M:%S')})'
                  : 'Dive of ${pyStrftime(dive.startTime, '%Y-%m-%d %H:%M')}',
            ),
            _offsetRow(),
          ],
        ),
        SectionCard(
          title: 'Overlays',
          children: [
            // As tall as its rows, each with its own way out (Python: a
            // list of a fixed height and "Remove Selected"; spec §10.62).
            if (c.overlays.isNotEmpty)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF3A3A3A),
                  border: Border.all(color: const Color(0xFF4A4A4A)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Column(
                  children: [
                    for (final (i, overlay) in c.overlays.indexed)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(start: 12),
                        child: Row(
                          children: [
                            Expanded(child: Text(overlay.label)),
                            IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              tooltip: 'Remove this overlay',
                              visualDensity: VisualDensity.compact,
                              onPressed: c.isRunning
                                  ? null
                                  : () => c.removeOverlayAt(i),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton(
                onPressed: c.isRunning ? null : _addOverlay,
                child: const Text('+ Add Overlay…'),
              ),
            ),
            if (c.watermarkStore != null) ...[
              // Several can be on at once (owner, 2026-11-16).
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  const Text('Watermarks'),
                  for (final name in c.watermarkList)
                    FilterChip(
                      label: Text(name),
                      selected: c.isWatermarkOn(name),
                      onSelected: c.isRunning
                          ? null
                          : (on) => c.setWatermark(name, on),
                    ),
                ],
              ),
              MutedText(
                c.watermarkList.isEmpty
                    ? 'Your logo or name on every photo and video: add it '
                          'under Settings → My watermarks.'
                    : 'Those ticked go on every photo and video of the run, '
                          'with or without a dive. Drag one on the preview to '
                          'move it for this session.',
                size: 11,
              ),
              if (c.watermarksMoved)
                Row(
                  children: [
                    const Expanded(
                      child: MutedText(
                        'Moved on the preview: used so until the app is '
                        'closed. Settings keeps its own place.',
                        size: 11,
                      ),
                    ),
                    TextButton(
                      onPressed: c.isRunning ? null : c.resetWatermarkPlaces,
                      child: const Text('Put back'),
                    ),
                  ],
                ),
            ],
          ],
        ),
      ],
    );
  }

  Future<void> _addOverlay() async {
    final c = controller!..openPicker();
    await showDialog<void>(
      context: context,
      builder: (context) => _AddOverlayDialog(controller: c),
    );
  }

  Future<void> _pickMedia({required bool fromFiles}) async {
    final c = controller!;
    final pick = fromFiles
        ? widget.pickFiles
        : widget.pickMedia ?? () => const PlatformMediaLibrary().pick();
    final List<String> files;
    try {
      files = await pick();
    } on Exception catch (e) {
      c.message(
        'Could not pick from ${fromFiles ? 'Files' : 'the library'}: $e',
      );
      return;
    }
    if (files.isEmpty || !mounted) {
      return;
    }
    final dir = collectPicked(files, widget.services.tempDir);
    await c.setSource(dir.path);
  }

  Widget _phoneSource() {
    final c = controller!;
    final logs = widget.services.logStore.files().length;
    final matches = c.diveMatches;
    return SectionCard(
      title: 'Photos and videos',
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: PickMediaButton(
            label: pickMediaLabel,
            enabled: !c.isRunning,
            onPick: _pickMedia,
          ),
        ),
        if (c.sourceCountText.isNotEmpty) MutedText(c.sourceCountText),
        DiveMatchButton(
          matches: matches,
          pending: c.diveMatchesPending,
          onDiveLogs: () => widget.services.openPage(diveLogsTitle),
        ),
        DiveLogsLink(
          services: widget.services,
          kept: logs,
          enabled: !c.isRunning,
        ),
        if (widget.services.capabilities.resultFolders) ...[
          SaveToButton(config: widget.services.config, enabled: !c.isRunning),
          const MutedText(
            'The originals are left as they are. Output names and the '
            'default profile are set on the Settings page.',
            size: 11,
          ),
        ] else
          const MutedText(
            'The results are saved into a new album; the originals are left '
            'as they are. Output names and the default profile are set on '
            'the Settings page.',
            size: 11,
          ),
      ],
    );
  }

  Widget _settingsColumn() {
    final c = controller!;
    final running = c.isRunning;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 10,
      children: [
        SectionCard(
          title: 'Color correction',
          children: [
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Apply color correction'),
                Switch(
                  value: c.colorChecked,
                  onChanged: running ? null : (v) => c.colorChecked = v,
                ),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: c.colorProfile,
                  items: [
                    for (final name in c.colorProfileList)
                      DropdownMenuItem(value: name, child: Text(name)),
                  ],
                  onChanged: running || !c.colorChecked
                      ? null
                      : (v) => c.colorProfile = v!,
                ),
              ],
            ),
            if (!widget.phone)
              Row(
                children: [
                  const MutedText('Hardware acceleration', size: 14),
                  Switch(
                    value: c.hwAccel,
                    onChanged: running ? null : (v) => c.hwAccel = v,
                  ),
                ],
              ),
          ],
        ),
        SectionCard(
          title: 'Output size',
          children: [
            DropdownButton<String>(
              key: const ValueKey('output size'),
              isExpanded: true,
              value: c.outputSize,
              items: [
                for (final label in c.outputSizeList)
                  DropdownMenuItem(value: label, child: Text(label)),
              ],
              onChanged: running ? null : (v) => c.outputSize = v!,
            ),
            if (c.outputSize != originalSizeLabel)
              const MutedText(
                'For the videos; photos keep their size. A video smaller '
                'than a size is not made larger. The shape and the part of '
                'the picture kept are chosen above the preview.',
                size: 11,
              ),
          ],
        ),
        if (c.compareOffered)
          SectionCard(
            title: 'Before and after',
            children: [
              DropdownButton<String>(
                key: const ValueKey('compare'),
                isExpanded: true,
                value: c.compare,
                items: [
                  for (final label in c.compareList)
                    DropdownMenuItem(value: label, child: Text(label)),
                ],
                onChanged: running || !c.canCompare
                    ? null
                    : (v) => c.compare = v!,
              ),
              MutedText(
                !c.canCompare
                    ? 'With one photo or one video and the color correction '
                          'on: the original and the corrected picture in one.'
                    : c.compare == compareOffLabel
                    ? 'The original and the corrected picture in one, with '
                          'the overlays on both.'
                    : 'Written as "… compare". A video is the part chosen '
                          'under the preview, ten seconds at most; a wipe '
                          'video of a photo is four seconds.',
                size: 11,
              ),
            ],
          ),
        if (!widget.phone)
          SectionCard(
            title: 'Source & output',
            children: [
              ..._sourceAndOutput(),
              const Text('Output filename'),
              DropdownButton<String>(
                isExpanded: true,
                value: c.filenameFormat,
                items: [
                  for (final label in c.filenameFormatList)
                    DropdownMenuItem(value: label, child: Text(label)),
                ],
                onChanged: running ? null : (v) => c.filenameFormat = v!,
              ),
              Tooltip(
                message:
                    'Leave a file alone when its output is already in the '
                    'output folder, instead of writing a _1 copy. Lets an '
                    'interrupted batch pick up where it stopped.',
                child: Row(
                  children: [
                    const Text('Skip if target exists'),
                    Switch(
                      value: c.skipExisting,
                      onChanged: running ? null : (v) => c.skipExisting = v,
                    ),
                  ],
                ),
              ),
            ],
          ),
        // A phone has the run under the page instead (see [build]).
        if (!widget.phone)
          SectionCard(
            title: 'Progress',
            children: [
              ..._progressLines(),
              StartStopButton(
                running: c.isRunning,
                onStartStop: _startOrStop,
                busyElsewhere: _busyElsewhere,
              ),
            ],
          ),
      ],
    );
  }

  // Start asks first when the results will not fit on the disk, as far
  // as the page can tell (spec §10.96); Stop goes straight on.
  Future<void> _startOrStop() async {
    final c = controller!;
    if (!c.isRunning && c.spaceShort) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('The disk may fill up'),
          content: Text(
            '${c.spaceText}.\n\nThe run stops when the disk is full. '
            'Free some space or choose another folder for the results.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Start anyway'),
            ),
          ],
        ),
      );
      if (go != true) {
        return;
      }
    }
    await c.startOrStop();
  }

  // While a run goes: the whole run first (its bar, the files done and
  // the time left), then the one file in progress (owner, 2026-11-22: a
  // line naming every file worked on did not read well). After it, how
  // long it took, where it is and what it said.
  List<Widget> _progressLines({bool status = true}) {
    final c = controller!;
    final current = c.currentFile;
    final others = c.activeFiles.length - 1;
    final fileFraction = c.currentFileFraction;
    return [
      if (c.isRunning) ...[
        _bar('Total', c.currentFraction),
        MutedText(
          [
            '${c.filesDone} of ${c.filesTotal} files',
            if (c.timingText.isNotEmpty) c.timingText,
          ].join(' · '),
          size: 11,
        ),
        if (current != null) ...[
          // One file is the whole run: its bar is the one above.
          if (c.filesTotal > 1 && fileFraction != null)
            _bar('Now', fileFraction),
          MutedText(
            'Now: $current${others > 0 ? ' and $others more' : ''}',
            size: 11,
          ),
        ],
      ] else if (c.timingText.isNotEmpty)
        MutedText(c.timingText, size: 11),
      // The count is in the lines above while the run goes.
      if (status && !(c.isRunning && c.statusText.startsWith('Processing')))
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
    ];
  }

  // Why Start cannot be pressed now, if so.
  String? get _busyElsewhere {
    final owner = widget.services.batches.owner;
    return _savingPhotos
        ? 'Saving into Photos…'
        : owner != null && owner != colorPage
        ? 'Another operation ($owner) is already running'
        : null;
  }

  // The phone's page while a run goes: the picture and the progress, the
  // settings (which cannot be changed then) out of the way.
  Widget _phoneRunning() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 12,
    children: [
      SectionCard(
        children: [LayoutBuilder(builder: (context, inner) => _preview(inner))],
      ),
      SectionCard(title: 'Progress', children: _progressLines()),
    ],
  );

  Widget _bar(String label, double fraction) => Row(
    spacing: 6,
    children: [
      SizedBox(width: 46, child: MutedText(label, size: 11)),
      Expanded(child: LinearProgressIndicator(value: fraction)),
      SizedBox(
        width: 40,
        child: MutedText('${(fraction * 100).round()}%', size: 11),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c == null) {
      return Center(
        child: failed == null
            ? const CircularProgressIndicator()
            : Text('The Color page could not start: $failed'),
      );
    }
    return ListenableBuilder(
      listenable: Listenable.merge([c, widget.services.batches]),
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 1000;
          final left = _leftColumn();
          final body = wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 12,
                  children: [
                    Expanded(flex: 3, child: left),
                    Expanded(flex: 2, child: _settingsColumn()),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 12,
                  children: [left, _settingsColumn()],
                );
          if (!widget.phone) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: body,
            );
          }
          // A phone picks its photos and videos first, above the preview;
          // what the last run said comes last.
          final lastRun = _progressLines(status: false);
          return Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: c.isRunning
                      ? _phoneRunning()
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          spacing: 12,
                          children: [
                            _phoneSource(),
                            body,
                            if (lastRun.isNotEmpty)
                              SectionCard(title: 'Last run', children: lastRun),
                          ],
                        ),
                ),
              ),
              // Start and Stop under the page, with how the last run
              // ended above the button.
              RunStartBar(
                running: c.isRunning,
                onStartStop: c.startOrStop,
                lines: [if (c.statusText != idleStatus) c.statusText],
                busyElsewhere: _busyElsewhere,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The selected overlay's box and its corner handles on the preview.
class _SelectionPainter extends CustomPainter {
  _SelectionPainter({
    required this.box,
    required this.scale,
    required this.dragging,
  });

  final (int, int, int, int)? box;
  final double scale;
  final bool dragging;

  @override
  void paint(Canvas canvas, Size size) {
    final b = box;
    if (b == null) {
      return;
    }
    final rect = Rect.fromLTRB(
      b.$1 * scale,
      b.$2 * scale,
      b.$3 * scale,
      b.$4 * scale,
    );
    if (dragging) {
      canvas.drawRect(rect, Paint()..color = const Color(0x333B82F6));
    }
    final stroke = Paint()
      ..color = _selection
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(rect, stroke);
    for (final corner in [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ]) {
      final handle = Rect.fromCenter(center: corner, width: 10, height: 10);
      canvas
        ..drawRect(handle, Paint()..color = Colors.white)
        ..drawRect(handle, stroke);
    }
  }

  @override
  bool shouldRepaint(_SelectionPainter old) =>
      old.box != box || old.scale != scale || old.dragging != dragging;
}

/// The overlay picker: brand, dive computer, page and tank setup.
class _AddOverlayDialog extends StatelessWidget {
  const _AddOverlayDialog({required this.controller});

  final ColorController controller;

  Widget _choice(
    String label,
    Map<String, String> choices,
    String? selected,
    void Function(String) onPick,
  ) => DropdownButtonFormField<String>(
    // A new field when the choices or the pick change above it.
    key: ValueKey('$label|$selected|${choices.keys.join(',')}'),
    initialValue: choices.values.contains(selected) ? selected : null,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: [
      for (final MapEntry(:key, :value) in choices.entries)
        DropdownMenuItem(value: value, child: Text(key)),
    ],
    onChanged: (v) {
      if (v != null) {
        onPick(v);
      }
    },
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller.picker,
    builder: (context, _) {
      final c = controller.picker;
      return AlertDialog(
        title: const Text('Add Overlay'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 8,
            children: [
              _choice(
                'Overlay brand',
                c.brandChoices,
                c.selectedBrand,
                c.selectBrand,
              ),
              if (c.computerVisible)
                _choice(
                  'Dive computer',
                  c.computerChoices,
                  c.selectedComputer,
                  c.selectComputer,
                ),
              _choice('Page', c.pageChoices, c.selectedPage, c.selectPage),
              if (c.variantChoices.isNotEmpty)
                _choice(
                  'Tank setup',
                  c.variantChoices,
                  c.selectedVariant,
                  c.selectVariant,
                ),
              if (c.error.isNotEmpty)
                Text(c.error, style: const TextStyle(color: Color(0xFFEF4444))),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (await controller.addPickedOverlay() && context.mounted) {
                Navigator.of(context).pop();
              }
            },
            child: const Text('Add'),
          ),
        ],
      );
    },
  );
}

/// The button that puts the window on the whole picture.
/// The shapes a video can be written in, as the Color page lists them.
const pictureShapeLabels = [
  (ShareShape.asShot, 'As shot'),
  (ShareShape.portraitCropped, 'Portrait 9:16'),
  (ShareShape.landscapeCropped, 'Landscape 16:9'),
  (ShareShape.squareCropped, 'Square 1:1'),
  (ShareShape.portraitBars, 'Portrait with bars'),
];

// Takes every touch on the preview at once; what the fingers do is read
// by the preview's own listener.
class _PreviewTouch extends ScaleGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}
