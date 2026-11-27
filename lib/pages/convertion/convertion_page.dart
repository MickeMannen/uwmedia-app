/// The Convertion page (Python `qml/ConvertionPage.qml`): one video
/// downscaled to the resolutions switched on, into a folder. On a phone
/// (spec §9.2) the video is picked from the library and the results go
/// into a new album.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/hud_kit.dart';
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/engine/share_sizes.dart';
import 'package:uwmedia_app/engine/desktop/convert_run.dart';
import 'package:uwmedia_app/engine/desktop/process_runner.dart';
import 'package:uwmedia_app/engine/file_picks.dart';
import 'package:uwmedia_app/engine/keep_awake.dart';
import 'package:uwmedia_app/engine/media_library.dart';
import 'package:uwmedia_app/engine/mobile_convert_run.dart';
import 'package:uwmedia_app/engine/mobile_engine.dart';
import 'package:uwmedia_app/engine/result_folder.dart';
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/pages/convertion/convertion_controller.dart';
import 'package:uwmedia_app/pages/shared/phone_files.dart';
import 'package:uwmedia_app/pages/shared/photos.dart';
import 'package:uwmedia_app/pages/shared/place_menu.dart';
import 'package:uwmedia_app/pages/shared/save_to.dart';
import 'package:uwmedia_app/widgets/run_progress.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

/// The two dialogs, so that a test can answer for them.
abstract interface class ConvertionDialogs {
  /// The videos picked: several on the desktop, one on a phone, none when
  /// the dialog was closed.
  Future<List<String>> pickVideos(String initialDirectory);

  /// A video from the phone's files (the phone's page only).
  Future<List<String>> pickVideoFiles();
  Future<String?> pickFolder(String initialDirectory);
}

class SystemConvertionDialogs implements ConvertionDialogs {
  const SystemConvertionDialogs();

  @override
  Future<List<String>> pickVideos(String initialDirectory) async => [
    for (final file in await openFiles(
      initialDirectory: initialDirectory,
      confirmButtonText: 'Select',
    ))
      file.path,
  ];

  @override
  Future<List<String>> pickVideoFiles() => pickVideos('');

  @override
  Future<String?> pickFolder(String initialDirectory) => getDirectoryPath(
    initialDirectory: initialDirectory,
    confirmButtonText: 'Select',
  );
}

/// A video from the phone's library; there are no folders to pick.
class PhoneConvertionDialogs implements ConvertionDialogs {
  const PhoneConvertionDialogs();

  @override
  Future<List<String>> pickVideos(String initialDirectory) =>
      const PlatformMediaLibrary().pick(photos: false, multiple: false);

  @override
  Future<List<String>> pickVideoFiles() =>
      pickFromFiles(photos: false, multiple: false);

  @override
  Future<String?> pickFolder(String initialDirectory) async => null;
}

/// The engine on a phone: the phone's media engine, the results saved
/// into a new album.
class MobileConvertionEngine implements ConvertionEngine {
  MobileConvertionEngine(
    this.engine,
    this.library,
    this.tempDir, {
    this.kit,
    this.saveTo,
  });

  /// Where a run started now saves instead of a new album; asked at each
  /// run.
  final SavePlace? Function()? saveTo;

  /// What draws a watermark, loaded when one is asked for.
  final Future<HudKit> Function()? kit;

  final MobileMediaEngine engine;
  final MediaLibrary library;
  final Directory Function(String prefix) tempDir;

  @override
  Future<(int, int)> dimensions(String path) async {
    final clip = await engine.probe(path);
    return (clip.width, clip.height);
  }

  @override
  Future<double> duration(String path) async =>
      (await engine.probe(path)).durationSeconds;

  @override
  Future<ConvertResult> convert({
    required String source,
    required String outputDir,
    required List<String> resolutions,
    required bool hwAccel,
    required RunControl control,
    List<ShareCopy> shares = const [],
    List<HudLayerSource> watermarks = const [],
    void Function(ConvertStep step)? onStep,
    void Function(double percent)? onProgress,
  }) => withScreenOn(() async {
    final report = RunProgressReporter();
    final drawing = watermarks.isEmpty ? null : await kit?.call();
    return MobileConvertRun(
      engine: engine,
      library: library,
      tempDir: tempDir,
      renderer: drawing?.renderer,
      painter: drawing?.painter,
      saveTo: saveTo?.call(),
    ).convert(
      source: source,
      outputDir: outputDir,
      resolutions: resolutions,
      shares: shares,
      watermarks: watermarks,
      control: control,
      onStep: (step) {
        report.files(step.done, step.total);
        onStep?.call(step);
      },
      onProgress: onProgress == null
          ? report.file
          : (percent) {
              report.file(percent);
              onProgress(percent);
            },
    );
  }, onStop: control.stop);
}

class ConvertionPage extends StatefulWidget {
  const ConvertionPage({
    super.key,
    required this.services,
    this.dialogs = const SystemConvertionDialogs(),
    this.engine,
    this.phone = false,
    this.photos,
  });

  final AppServices services;
  final ConvertionDialogs dialogs;

  /// The phone's page: the video from the library, the results into an
  /// album (spec §9.2).
  final bool phone;

  /// Apple Photos beside the folders on the desktop's page (spec §10.50);
  /// by default the Mac's, where the app runs on one.
  final MediaLibrary? photos;

  /// The media engine; by default ffmpeg and exiftool as found.
  final Future<ConvertionEngine> Function()? engine;

  @override
  State<ConvertionPage> createState() => _ConvertionPageState();
}

class _ConvertionPageState extends State<ConvertionPage> {
  late final ConvertionController controller = ConvertionController(
    config: widget.services.config,
    gate: widget.services.batches,
    home: widget.services.home,
    watermarkStore: widget.services.watermarks,
    engine:
        widget.engine ??
        (widget.phone
            ? () async => MobileConvertionEngine(
                const PlatformMediaEngine(),
                const PlatformMediaLibrary(),
                widget.services.tempDir,
                kit: _hudKit,
                saveTo: widget.services.capabilities.resultFolders
                    ? () => keptSavePlace(
                        widget.services.config,
                        const PlatformResultFolders(),
                        const PlatformMediaLibrary(),
                      )
                    : null,
              )
            : () async => DesktopConvertionEngine(
                await widget.services.desktopTools(),
                kit: _hudKit,
                tempDir: widget.services.tempDir,
                native: () => widget.services.nativeVideoEngine,
              )),
  );

  // What draws a watermark: the fonts and rules, read once when the first
  // run with a watermark asks for them.
  Future<HudKit>? _kit;
  Future<HudKit> _hudKit() => _kit ??= HudKit.load();

  void _watermarksChanged() => controller.watermarksChanged();

  // Apple Photos on the desktop's page: whether the videos were picked
  // there, and the folder the results wait in on their way into an album
  // (with the destination as it was before).
  bool _photosSource = false;
  String? _photosOut;
  String _destBefore = '';
  bool _wasRunning = false;

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
    final String? dir;
    try {
      dir = await pickFromPhotos(
        _photos!,
        widget.services.tempDir,
        page: 'Resize',
        photos: false,
      );
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not pick from Photos: $e')),
        );
      }
      return;
    }
    if (dir == null || !mounted) {
      return;
    }
    setState(() => _photosSource = true);
    await controller.chooseSources(mediaIn(dir), remember: false);
  }

  void _intoPhotos(bool on) {
    if (on) {
      _destBefore = controller.destText;
      final dir = widget.services.tempDir('uwmedia_photos_out_').path;
      setState(() => _photosOut = dir);
      controller.chooseDest(dir, remember: false);
    } else {
      setState(() => _photosOut = null);
      controller.chooseDest(_destBefore, remember: false);
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
    final ended = _wasRunning && !controller.isRunning;
    _wasRunning = controller.isRunning;
    final out = _photosOut;
    final library = _photos;
    if (!ended || out == null || library == null) {
      return;
    }
    void say(String text) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(text)));
      }
    }

    if (controller.statusText == 'Stopped') {
      say(discardStopped(out));
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
          if (lines.isNotEmpty) {
            say(lines.join('\n'));
          }
        }
      }),
    );
  }

  @override
  void initState() {
    super.initState();
    controller.addListener(_runWatch);
    widget.services.watermarksRevision.addListener(_watermarksChanged);
    if (widget.phone) {
      // The results wait in a working folder until they are in the album.
      controller.chooseDest(
        widget.services.tempDir('uwmedia_convert_out_').path,
      );
    }
  }

  @override
  void dispose() {
    widget.services.watermarksRevision.removeListener(_watermarksChanged);
    controller.dispose();
    super.dispose();
  }

  Future<void> _browseSource({bool fromFiles = false}) async {
    final List<String> paths;
    try {
      paths = fromFiles
          ? await widget.dialogs.pickVideoFiles()
          : await widget.dialogs.pickVideos(controller.sourceDialogDir);
    } on LibraryException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
      return;
    }
    if (paths.isNotEmpty) {
      setState(() => _photosSource = false);
      await controller.chooseSources(paths);
    }
  }

  Future<void> _browseDest() async {
    final path = await widget.dialogs.pickFolder(controller.destDialogDir);
    if (path != null) {
      if (_photosOut != null) {
        // Out of Photos again, into the folder picked.
        setState(() => _photosOut = null);
      }
      controller.chooseDest(path);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, widget.services.batches]),
    builder: (context, _) {
      final c = controller;
      final running = c.isRunning;
      final owner = widget.services.batches.owner;
      final busyElsewhere = _savingPhotos
          ? 'Saving into Photos…'
          : owner != null && owner != convertionPage
          ? 'Another operation ($owner) is already running'
          : null;
      final outputFiles = SectionCard(
        title: 'Output files',
        children: [
          SelectableText(
            widget.phone ? c.outputNamesText : c.outputPreviewText,
            style: const TextStyle(color: mutedText, fontSize: 12),
          ),
        ],
      );
      final progress = RunProgressCard(
        running: running,
        known: c.progressKnown,
        fraction: c.progressFraction,
        fractionText: c.progressFractionText,
        timingText: c.timingText,
        statusText: c.statusText,
        onStartStop: c.startOrStop,
        busyElsewhere: busyElsewhere,
        button: !widget.phone,
      );
      if (widget.phone && running) {
        // A phone's page while a run goes: the video, what is made of it
        // and the progress, the choices (which cannot be changed then)
        // out of the way; Stop under the page.
        return Column(
          children: [
            Expanded(
              child: PageFrame(
                title: 'Resize',
                children: [
                  SectionCard(
                    children: [
                      Text(p.basename(c.sourceText)),
                      if (c.sourceResolutionText.isNotEmpty)
                        MutedText(c.sourceResolutionText, size: 14),
                    ],
                  ),
                  outputFiles,
                  progress,
                ],
              ),
            ),
            RunStartBar(running: true, onStartStop: c.startOrStop),
          ],
        );
      }
      final page = PageFrame(
        title: 'Resize',
        children: [
          SectionCard(
            children: [
              if (widget.phone) ...[
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: PickMediaButton(
                    label: 'Pick a video',
                    icon: Icons.video_library_outlined,
                    enabled: !running,
                    onPick: _browseSource,
                  ),
                ),
                if (c.sourceText.isNotEmpty) Text(p.basename(c.sourceText)),
              ] else ...[
                // Picked, not typed, as on the phones (owner, 2026-11-16;
                // spec §10.65).
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: PlaceMenuButton(
                    label: chooseVideosLabel,
                    icon: Icons.video_library_outlined,
                    filled: true,
                    enabled: !running,
                    places: [
                      (
                        icon: Icons.description_outlined,
                        label: filesPlaceLabel,
                        onPressed: _browseSource,
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
                if (c.sourceText.isNotEmpty)
                  SelectableText(
                    _photosSource
                        ? fromPhotosText(c.sources.length)
                        : c.sourceDisplay,
                    style: const TextStyle(fontSize: 12),
                  ),
                SaveToPlace(
                  location: _photosOut != null
                      ? saveToText(
                          null,
                          keptResultAlbum(widget.services.config),
                        )
                      : c.destText.trim().isEmpty
                      ? null
                      : c.displayPath(c.destText),
                  enabled: !running && !_savingPhotos,
                  places: [
                    (
                      icon: Icons.folder_outlined,
                      label: folderPlaceLabel,
                      onPressed: _browseDest,
                    ),
                    if (_photos != null)
                      (
                        icon: Icons.photo_library_outlined,
                        label: saveToAlbumChoice,
                        onPressed: _chooseAlbum,
                      ),
                  ],
                ),
              ],
              if (c.sourceResolutionText.isNotEmpty)
                MutedText(c.sourceResolutionText, size: 14),
              if (widget.phone &&
                  widget.services.capabilities.resultFolders) ...[
                SaveToButton(config: widget.services.config, enabled: !running),
                const MutedText(
                  'HEVC, the sizes named for an app H.264; the original is '
                  'left as it is.',
                  size: 11,
                ),
              ] else if (widget.phone)
                const MutedText(
                  'Each size is saved into a new album (HEVC; the sizes named '
                  'for an app H.264); the original is left as it is.',
                  size: 11,
                )
              else
                Row(
                  children: [
                    const Flexible(
                      child: MutedText('Hardware acceleration', size: 14),
                    ),
                    Switch(
                      value: c.hwAccel,
                      onChanged: running ? null : (v) => c.hwAccel = v,
                    ),
                  ],
                ),
            ],
          ),
          SectionCard(
            title: 'Output resolutions',
            children: [
              // Two columns on a phone, however narrow.
              LayoutBuilder(
                builder: (context, inner) => Wrap(
                  children: [
                    for (final name in c.resolutionNames)
                      SizedBox(
                        width: widget.phone ? inner.maxWidth / 2 : 300,
                        child: SwitchListTile(
                          dense: true,
                          contentPadding: widget.phone
                              ? const EdgeInsets.symmetric(horizontal: 4)
                              : null,
                          title: Text(name),
                          subtitle: c.sizeText(name).isEmpty
                              ? null
                              : Text(c.sizeText(name)),
                          value: c.isChecked(name),
                          onChanged: running || !c.isEnabled(name)
                              ? null
                              : (v) => c.setChecked(name, v),
                        ),
                      ),
                    // The sizes named by where the video is sent (spec
                    // §10.49).
                    for (final key in shareKeys)
                      SizedBox(
                        width: widget.phone ? inner.maxWidth / 2 : 300,
                        child: SwitchListTile(
                          dense: true,
                          contentPadding: widget.phone
                              ? const EdgeInsets.symmetric(horizontal: 4)
                              : null,
                          title: Text(c.shareTitle(key)),
                          subtitle: c.shareText(key).isEmpty
                              ? null
                              : Text(c.shareText(key)),
                          value: c.isShareChecked(key),
                          onChanged: running
                              ? null
                              : (v) => c.setShareChecked(key, v),
                        ),
                      ),
                  ],
                ),
              ),
              const MutedText(shareSizesHint, size: 11),
            ],
          ),
          if (c.watermarkList.isNotEmpty)
            SectionCard(
              title: 'Watermarks',
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final name in c.watermarkList)
                      FilterChip(
                        label: Text(name),
                        selected: c.isWatermarkOn(name),
                        onSelected: running
                            ? null
                            : (on) {
                                c.setWatermark(name, on);
                                widget.services.watermarksRevision.value++;
                              },
                      ),
                  ],
                ),
                const MutedText(
                  'Those ticked go on every copy this run makes. Add or '
                  'change watermarks on the Settings page.',
                  size: 11,
                ),
              ],
            ),
          outputFiles,
          // A phone has Start under the page, and no progress to show
          // before a run.
          if (!widget.phone) progress,
        ],
      );
      if (!widget.phone) {
        return page;
      }
      return Column(
        children: [
          Expanded(child: page),
          RunStartBar(
            running: false,
            onStartStop: c.startOrStop,
            lines: [
              if (c.statusText != noBatchText) c.statusText,
              c.timingText,
            ],
            busyElsewhere: busyElsewhere,
          ),
        ],
      );
    },
  );
}
