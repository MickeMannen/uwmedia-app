/// The Color Tuning page on the desktop (Python `qml/ColorTuningPage.qml`):
/// the picture and profile controls and the Original / Adjusted pair stay
/// at the top; only the slider groups scroll.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/color/color_params.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/engine/file_picks.dart' as fs;
import 'package:uwmedia_app/engine/media_library.dart';
import 'package:uwmedia_app/engine/mobile_engine.dart';
import 'package:uwmedia_app/pages/color_tuning/color_tuning_controller.dart';
import 'package:uwmedia_app/pages/shared/phone_files.dart';
import 'package:uwmedia_app/pages/shared/photos.dart';
import 'package:uwmedia_app/pages/shared/place_menu.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

/// The picture dialog, so that a test can answer for it.
typedef PickImage = Future<String?> Function(String initialDirectory);

Future<String?> _systemPickImage(String initialDirectory) async =>
    (await fs.openFile(
      initialDirectory: initialDirectory,
      acceptedTypeGroups: const [
        fs.XTypeGroup(
          label: 'Images',
          extensions: ['jpg', 'jpeg', 'png', 'tif', 'tiff', 'bmp', 'webp'],
        ),
      ],
    ))?.path;

/// The status line on a phone: a path in it (a picked file's copy lies
/// deep in the app's folders) shortened to the file's name, so the line
/// leaves the room to the sliders.
String phoneStatusText(String status) {
  final slash = status.indexOf('/');
  if (slash < 0) {
    return status;
  }
  // The path is the whole line, or what follows "…: ".
  final at = status.lastIndexOf(': ', slash) + 2;
  final from = at < 2 ? 0 : at;
  return '${status.substring(0, from)}${p.basename(status.substring(from))}';
}

/// A phone's sample: a photo from the library (spec §9.3).
Future<String?> pickFromLibrary(String initialDirectory) async =>
    (await ImagePicker().pickImage(source: ImageSource.gallery))?.path;

/// A phone's sample with the phone's media engine (spec §9.3): a photo
/// from the library, or a video's middle frame, saved as a PNG in a
/// working folder made by [tempDir]. `null` when nothing was picked or the
/// video gave no frame.
PickImage pickSampleFromLibrary(
  Directory Function(String prefix) tempDir, {
  MobileMediaEngine engine = const PlatformMediaEngine(),
  Future<String?> Function()? pickMedia,
}) => (initialDirectory) async {
  final path =
      await (pickMedia ?? () async => (await ImagePicker().pickMedia())?.path)
          .call();
  if (path == null || !isVideoPath(path)) {
    return path;
  }
  try {
    final clip = await engine.probe(path);
    final frame = await engine.frameAt(
      path,
      clip.durationSeconds / 2,
      maxWidth: 1920,
      maxHeight: 1920,
      exact: true,
    );
    if (frame == null) {
      return null;
    }
    final png = await framePng(frame);
    final out = p.join(
      tempDir('uwmedia_sample_').path,
      '${p.basenameWithoutExtension(path)}.png',
    );
    File(out).writeAsBytesSync(png);
    return out;
  } on Exception {
    return null;
  }
};

/// [frame] as PNG bytes.
Future<Uint8List> framePng(RgbImage frame) async {
  final rgba = Uint8List(frame.width * frame.height * 4);
  for (var i = 0, o = 0; i < frame.rgb.length; i += 3, o += 4) {
    rgba[o] = frame.rgb[i];
    rgba[o + 1] = frame.rgb[i + 1];
    rgba[o + 2] = frame.rgb[i + 2];
    rgba[o + 3] = 255;
  }
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    frame.width,
    frame.height,
    ui.PixelFormat.rgba8888,
    done.complete,
  );
  final image = await done.future;
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    return png!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

const loadImageLabel = 'Load Image…';

/// How tall a phone's one picture is.
const litePictureHeight = 260.0;

// The room a phone's picture card takes while it stays at the top: the
// picture, the line under it and the card's own edges.
const _pinnedHeight = litePictureHeight + 64;

class _PinnedPicture extends SliverPersistentHeaderDelegate {
  const _PinnedPicture({required this.background, required this.child});

  /// The page's own colour, so the sliders are not seen behind the card.
  final Color background;
  final Widget child;

  @override
  double get minExtent => _pinnedHeight;

  @override
  double get maxExtent => _pinnedHeight;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => ColoredBox(
    color: background,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: child,
    ),
  );

  @override
  bool shouldRebuild(_PinnedPicture old) => true;
}

/// What the Save dialog says under a new name that is a bundled
/// profile's.
String takenProfileNameText(String name) =>
    '"$name" is a profile that comes with the app. Choose another name.';

/// What the Save dialog answered: over the profile, or as a new one of
/// [newName].
typedef _SaveAnswer = ({String? newName});

class _SaveProfileDialog extends StatefulWidget {
  const _SaveProfileDialog({
    required this.profile,
    required this.bundled,
    required this.newName,
    this.bundledNames = const {},
  });

  final String profile;

  /// Whether [profile] came with the app: then it is not saved over.
  final bool bundled;
  final String newName;

  /// The names of the profiles that come with the app: none of them can
  /// be the new profile's (spec §10.103), which the field says at once.
  final Set<String> bundledNames;

  @override
  State<_SaveProfileDialog> createState() => _SaveProfileDialogState();
}

class _SaveProfileDialogState extends State<_SaveProfileDialog> {
  late final _name = TextEditingController(text: widget.newName);

  bool get _taken => widget.bundledNames.contains(_name.text.trim());

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Save profile'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        if (widget.bundled)
          MutedText(
            '"${widget.profile}" comes with the app and stays as it is. '
            'Save the sliders as a profile of your own:',
          )
        else ...[
          FilledButton(
            onPressed: () => Navigator.of(context).pop((newName: null)),
            child: Text('Overwrite "${widget.profile}"'),
          ),
          const MutedText('Or as a new profile:'),
        ],
        // A name of the app's own is said in the field and cannot be
        // saved (owner, 2026-11-26: the page's status line alone was
        // "no real warning that it wasn't saved").
        ListenableBuilder(
          listenable: _name,
          builder: (context, _) => TextField(
            controller: _name,
            maxLength: newProfileNameMax,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'New profile name',
              errorMaxLines: 3,
              errorText: _taken
                  ? takenProfileNameText(_name.text.trim())
                  : null,
            ),
          ),
        ),
        ListenableBuilder(
          listenable: _name,
          builder: (context, _) => OutlinedButton(
            onPressed: _name.text.trim().isEmpty || _taken
                ? null
                : () => Navigator.of(context).pop((newName: _name.text)),
            child: const Text('Save As New'),
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
    ],
  );
}

class ColorTuningPage extends StatefulWidget {
  const ColorTuningPage({
    super.key,
    required this.services,
    this.pickImage = _systemPickImage,
    this.pickFile,
    this.bundledColorYaml,
    this.lite = false,
    this.photos,
  });

  /// Apple Photos as a place for the desktop's sample (spec §10.67(g));
  /// by default the Mac's, where the app runs on one.
  final MediaLibrary? photos;

  final AppServices services;
  final PickImage pickImage;

  /// A phone's sample from its files instead of the photo library; with
  /// it "Load Image…" opens the choice of the two.
  final PickImage? pickFile;

  /// The phones' page (spec §9.3): one slider per stage instead of the
  /// whole table, the sample from the photo library.
  final bool lite;

  /// The bundled `color.yaml`; by default read from the assets.
  final String? bundledColorYaml;

  @override
  State<ColorTuningPage> createState() => _ColorTuningPageState();
}

class _ColorTuningPageState extends State<ColorTuningPage> {
  ColorTuningController? controller;
  final _newName = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future<String?>(() async {
      try {
        return widget.bundledColorYaml ??
            await rootBundle.loadString('assets/color.yaml');
      } on Object {
        // Without the bundled profiles: the user's alone, else the
        // table's defaults.
        return null;
      }
    }).then((text) {
      if (!mounted) {
        return;
      }
      setState(
        () => controller = ColorTuningController(
          config: widget.services.config,
          home: widget.services.home,
          bundledColorYaml: text,
        )..addListener(_syncName),
      );
    });
  }

  void _syncName() {
    final name = controller!.newProfileName;
    if (_newName.text != name) {
      _newName.text = name;
    }
  }

  @override
  void dispose() {
    controller?.dispose();
    _newName.dispose();
    super.dispose();
  }

  MediaLibrary? get _photos => widget.lite
      ? null
      : widget.photos ??
            (widget.services.capabilities.photos
                ? const PlatformMediaLibrary()
                : null);

  // The desktop's sample from Apple Photos: one photo, as a copy in a
  // working folder.
  Future<void> _loadFromPhotos() async {
    final c = controller!;
    final messenger = ScaffoldMessenger.of(context);
    final String? dir;
    try {
      dir = await pickFromPhotos(
        _photos!,
        widget.services.tempDir,
        page: 'Color Tuning',
        videos: false,
        multiple: false,
      );
    } on Exception catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not pick from Photos: $e')),
      );
      return;
    }
    final path = dir == null ? null : mediaIn(dir).firstOrNull;
    if (path != null && mounted) {
      await c.loadImage(path, remember: false);
    }
  }

  Future<void> _load({bool fromFiles = false}) async {
    final c = controller!;
    final pick = fromFiles ? widget.pickFile! : widget.pickImage;
    final path = await pick(c.dialogDir);
    if (path != null && mounted) {
      await c.loadImage(path);
    }
  }

  // The original is shown while a finger is held on a phone's picture.
  bool _showOriginal = false;

  // A phone's one picture: the adjusted one, the original while it is
  // pressed and held (as the Color page's preview).
  Widget _litePicture() {
    final c = controller!;
    final image = _showOriginal ? c.originalImage : c.resultImage;
    return SectionCard(
      children: [
        GestureDetector(
          onLongPressStart: (_) => setState(() => _showOriginal = true),
          onLongPressEnd: (_) => setState(() => _showOriginal = false),
          onLongPressCancel: () => setState(() => _showOriginal = false),
          child: Container(
            height: litePictureHeight,
            color: Colors.black,
            padding: const EdgeInsets.all(2),
            alignment: Alignment.center,
            child: image == null
                ? null
                : RawImage(image: image, fit: BoxFit.contain),
          ),
        ),
        MutedText(
          _showOriginal
              ? 'Original'
              : 'Adjusted. Press and hold the picture to see the original.',
          size: 11,
          maxLines: 1,
        ),
      ],
    );
  }

  // A phone's Save: asks whether the profile is written over or the
  // sliders become a new one.
  Future<void> _askSave() async {
    final c = controller!;
    final answer = await showDialog<_SaveAnswer>(
      context: context,
      builder: (context) => _SaveProfileDialog(
        profile: c.currentProfile,
        bundled: c.currentIsBundled,
        newName: c.newProfileName,
        bundledNames: c.bundledProfiles,
      ),
    );
    if (answer == null) {
      return;
    }
    final name = answer.newName;
    if (name == null) {
      c.saveProfile();
    } else {
      c
        ..newProfileName = name
        ..saveNewProfile();
    }
  }

  // The phones' page: the file and profile row scrolls away, the picture
  // stays at the top and the sliders go under it.
  Widget _litePage() {
    final c = controller!;
    final background = Theme.of(context).scaffoldBackgroundColor;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                const Text(
                  'Color Tuning',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                SectionCard(
                  children: [
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (widget.pickFile == null)
                          OutlinedButton(
                            onPressed: _load,
                            child: const Text(loadImageLabel),
                          )
                        else
                          PickMediaButton(
                            label: loadImageLabel,
                            filled: false,
                            onPick: _load,
                          ),
                        const Text('Profile:'),
                        DropdownButton<String>(
                          value: c.currentProfile,
                          items: [
                            for (final name in c.profileList)
                              DropdownMenuItem(value: name, child: Text(name)),
                          ],
                          onChanged: (v) => c.currentProfile = v!,
                        ),
                        OutlinedButton(
                          onPressed: _askSave,
                          child: const Text('Save…'),
                        ),
                      ],
                    ),
                    MutedText(phoneStatusText(c.statusText), maxLines: 1),
                  ],
                ),
              ],
            ),
          ),
        ),
        SliverPersistentHeader(
          pinned: true,
          delegate: _PinnedPicture(
            background: background,
            child: _litePicture(),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          sliver: SliverToBoxAdapter(
            child: SectionCard(
              title: 'Adjust',
              children: [for (final slider in liteSliders) _liteSlider(slider)],
            ),
          ),
        ),
      ],
    );
  }

  Widget _pane(String title, ui.Image? image) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        Container(
          height: 260,
          color: Colors.black,
          padding: const EdgeInsets.all(2),
          child: image == null
              ? null
              : RawImage(image: image, fit: BoxFit.contain),
        ),
      ],
    ),
  );

  Widget _liteSlider(LiteSlider slider) {
    final c = controller!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          slider.photosOnly ? '${slider.label} (photos only)' : slider.label,
        ),
        Slider(
          min: slider.min,
          max: slider.max,
          value: c.liteValueOf(slider),
          onChanged: (v) => c.setLite(slider, v),
        ),
      ],
    );
  }

  Widget _slider(ColorParam param) {
    final c = controller!;
    return Row(
      spacing: 8,
      children: [
        SizedBox(width: 190, child: Text(param.label)),
        Expanded(
          child: Slider(
            min: param.min,
            max: param.max,
            divisions: param.isInt ? (param.max - param.min).round() : null,
            value: c.sliderValueOf(param.key),
            onChanged: (v) => c.setValue(param.key, v),
          ),
        ),
        SizedBox(width: 60, child: Text(c.textOf(param.key))),
        IconButton(
          icon: const Icon(Icons.restart_alt),
          tooltip: 'Back to the default profile',
          onPressed: () => c.reset(param.key),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (widget.lite) {
      return ListenableBuilder(
        listenable: c,
        builder: (context, _) => _litePage(),
      );
    }
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            const Text(
              'Color Tuning',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            SectionCard(
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    PlaceMenuButton(
                      label: loadImageLabel,
                      icon: Icons.image_outlined,
                      places: [
                        (
                          icon: Icons.description_outlined,
                          label: filesPlaceLabel,
                          onPressed: _load,
                        ),
                        if (_photos != null)
                          (
                            icon: Icons.photo_library_outlined,
                            label: photoLibraryPlaceLabel,
                            onPressed: _loadFromPhotos,
                          ),
                      ],
                    ),
                    if (_photos != null) const PhotosFetching(),
                    const Text('Profile:'),
                    DropdownButton<String>(
                      value: c.currentProfile,
                      items: [
                        for (final name in c.profileList)
                          DropdownMenuItem(value: name, child: Text(name)),
                      ],
                      onChanged: (v) => c.currentProfile = v!,
                    ),
                    // A bundled profile is not saved over (spec §10.103).
                    Tooltip(
                      message: c.currentIsBundled
                          ? bundledProfileText(c.currentProfile)
                          : 'Save the sliders as "${c.currentProfile}"',
                      child: OutlinedButton(
                        onPressed: c.currentIsBundled ? null : c.saveProfile,
                        child: const Text('Save Profile'),
                      ),
                    ),
                    SizedBox(
                      width: 200,
                      child: Tooltip(
                        message: 'Name for Save As New, at most 10 characters',
                        child: TextField(
                          controller: _newName,
                          maxLength: newProfileNameMax,
                          decoration: const InputDecoration(
                            isDense: true,
                            counterText: '',
                            hintText: 'New profile name',
                          ),
                          onChanged: (v) => c.newProfileName = v,
                        ),
                      ),
                    ),
                    OutlinedButton(
                      onPressed: c.saveNewProfile,
                      child: const Text('Save As New'),
                    ),
                  ],
                ),
                MutedText(c.statusText),
              ],
            ),
            SectionCard(
              children: [
                Row(
                  spacing: 16,
                  children: [
                    _pane('Original', c.originalImage),
                    _pane('Adjusted', c.resultImage),
                  ],
                ),
              ],
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(right: 16),
                children: [
                  for (final (title, params) in colorParamGroups)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: SectionCard(
                        title: title,
                        children: [for (final param in params) _slider(param)],
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
}
