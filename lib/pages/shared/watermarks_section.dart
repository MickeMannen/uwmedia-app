/// "My watermarks" on the Settings pages (spec §10.45): the diver's
/// pictures and texts that a run can put on every photo and video, each
/// with its place, size and opacity.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/hud_kit.dart';
import 'package:uwmedia_app/app/services.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/watermark/watermark.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/engine/file_picks.dart';
import 'package:uwmedia_app/engine/media_library.dart';
import 'package:uwmedia_app/engine/watermark_store.dart';
import 'package:uwmedia_app/pages/color_tuning/color_tuning_page.dart';
import 'package:uwmedia_app/pages/shared/phone_files.dart';
import 'package:uwmedia_app/pages/shared/photos.dart';
import 'package:uwmedia_app/pages/shared/place_menu.dart';
import 'package:uwmedia_app/pages/shared/watermark_editor.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

/// What the list says of [mark] under its name: its place on a landscape
/// frame, and on a portrait one when that is another; or the one kind of
/// frame it is for.
String watermarkSummary(Watermark mark) {
  final String place;
  if (!mark.onPortrait) {
    place = 'Landscape only · ${watermarkPlaceText(mark.place)}';
  } else if (!mark.onLandscape) {
    place = 'Portrait only · ${watermarkPlaceText(mark.placePortrait)}';
  } else {
    final upright = mark.placePortrait == mark.place
        ? ''
        : ' (portrait: '
              '${watermarkPlaceText(mark.placePortrait).toLowerCase()})';
    place = '${watermarkPlaceText(mark.place)}$upright';
  }
  String percent(double share) =>
      (share * 100).toStringAsFixed(mark.isPicture ? 0 : 1);
  // The size of the one kind of frame it is for; of both when they differ.
  final size = !mark.onLandscape
      ? '${percent(mark.sizePortrait)} % of the width'
      : mark.onPortrait && mark.sizePortrait != mark.size
      ? '${percent(mark.size)} % of the width '
            '(portrait: ${percent(mark.sizePortrait)} %)'
      : '${percent(mark.size)} % of the width';
  return mark.isPicture
      ? 'Picture · $place · $size · '
            '${(mark.opacity * 100).round()} % solid'
      : 'Text "${mark.text}" · $place · letters $size';
}

Future<String?> _pickFile() async => (await openFile(
  acceptedTypeGroups: const [
    XTypeGroup(
      label: 'Pictures',
      extensions: ['png', 'jpg', 'jpeg'],
      uniformTypeIdentifiers: ['public.png', 'public.jpeg'],
      mimeTypes: ['image/png', 'image/jpeg'],
    ),
  ],
  confirmButtonText: 'Select',
))?.path;

/// A picture or a video picked in the system's file dialog: the
/// editor's sample on a computer.
Future<String?> _pickSampleFile() async => (await openFile(
  acceptedTypeGroups: const [
    XTypeGroup(
      label: 'Pictures and videos',
      extensions: ['png', 'jpg', 'jpeg', 'mp4', 'mov', 'm4v', 'mkv', 'avi'],
      uniformTypeIdentifiers: ['public.png', 'public.jpeg', 'public.movie'],
      mimeTypes: ['image/png', 'image/jpeg', 'video/*'],
    ),
  ],
  confirmButtonText: 'Select',
))?.path;

/// The longest side of a video's frame taken as the editor's sample.
const sampleFrameSide = 1920;

/// [path] as the editor's sample on a computer: a picture as it is, a
/// video's middle frame as a PNG in a working folder made by [tempDir]
/// (as the phones', `pickSampleFromLibrary`). `null` when the video gave
/// no frame.
Future<String?> desktopSample(
  String path,
  FfmpegTools tools,
  Directory Function(String prefix) tempDir,
) async {
  if (!isVideoPath(path)) {
    return path;
  }
  try {
    final (width, height) = await tools.displayDimensions(path);
    final scale = math.min(1.0, sampleFrameSide / math.max(width, height));
    final frame = await tools.frameAt(
      path,
      await tools.duration(path) / 2,
      width: math.max(1, (width * scale).round()),
      height: math.max(1, (height * scale).round()),
    );
    if (frame == null) {
      return null;
    }
    final out = p.join(
      tempDir('uwmedia_sample_').path,
      '${p.basenameWithoutExtension(path)}.png',
    );
    File(out).writeAsBytesSync(await framePng(frame));
    return out;
  } on EngineException {
    return null;
  }
}

Future<String?> _pickFromLibrary() async =>
    (await const PlatformMediaLibrary().pick(
      videos: false,
      multiple: false,
    )).firstOrNull;

class WatermarksSection extends StatefulWidget {
  const WatermarksSection({
    super.key,
    required this.services,
    this.pickFile = _pickFile,
    this.pickFromLibrary = _pickFromLibrary,
    this.pickSampleFile = _pickSampleFile,
    this.kit = HudKit.load,
    this.pickSample,
    this.photos,
  });

  /// The renderer's fonts, with which the editor measures a text.
  final Future<HudKit> Function()? kit;

  /// The picture the editor's mark is placed on; by default a photo (or
  /// a video's frame) from a phone's library, a picture or video file
  /// (its middle frame) on a computer.
  final Future<String?> Function()? pickSample;

  final AppServices services;

  /// Apple Photos on a computer that has it (the Mac), for a test; the
  /// system's own otherwise.
  final MediaLibrary? photos;

  /// A picture file picked in the system's file dialog (Files on a phone).
  final Future<String?> Function() pickFile;

  /// A picture picked from the phone's library.
  final Future<String?> Function() pickFromLibrary;

  /// A picture or video file picked for the editor's sample on a
  /// computer.
  final Future<String?> Function() pickSampleFile;

  @override
  State<WatermarksSection> createState() => _WatermarksSectionState();
}

class _WatermarksSectionState extends State<WatermarksSection> {
  WatermarkStore get store => widget.services.watermarks;
  String _status = '';

  // Saved: shown here, and told to the pages that offer the watermarks.
  void _changed([String status = '']) {
    setState(() => _status = status);
    widget.services.watermarksRevision.value++;
  }

  // Apple Photos beside the files on a computer that has it (the Mac),
  // as on the pages that pick photos and videos (spec §10.50).
  MediaLibrary? get _photos => !widget.services.capabilities.desktop
      ? null
      : widget.photos ??
            (widget.services.capabilities.photos
                ? const PlatformMediaLibrary()
                : null);

  // One item picked in Photos, as a copy in a working folder; the copy
  // of the pick before under the same [keep] is removed.
  Future<String?> _fromPhotos(String keep, {required bool videos}) async {
    final dir = await pickFromPhotos(
      _photos!,
      widget.services.tempDir,
      page: keep,
      videos: videos,
      multiple: false,
    );
    return dir == null ? null : mediaIn(dir).firstOrNull;
  }

  // A computer's sample of [path]: a picture as it is, a video's middle
  // frame.
  Future<String?> _desktopSample(String? path) async {
    if (path == null || !isVideoPath(path)) {
      return path;
    }
    // Without ffmpeg no frame: the editor says the sample failed.
    final services = widget.services;
    final tools = await services.desktopTools();
    final sample = await desktopSample(path, tools.ffmpeg, services.tempDir);
    if (sample == null) {
      throw const EngineException('The video gave no frame');
    }
    return sample;
  }

  // A photo, or a video's middle frame, from a phone's library or, on a
  // computer, from a file.
  Future<String?> _sample() async {
    final services = widget.services;
    if (services.capabilities.desktop) {
      return _desktopSample(await widget.pickSampleFile());
    }
    return services.capabilities.mobileEngine
        ? pickSampleFromLibrary(services.tempDir)('')
        : widget.pickFromLibrary();
  }

  // The same from Apple Photos on the Mac.
  Future<String?> _sampleFromPhotos() async =>
      _desktopSample(await _fromPhotos('Watermark sample', videos: true));

  Future<void> _addPicture(Future<String?> Function() pick) async {
    final String? path;
    try {
      path = await pick();
    } on Exception catch (e) {
      setState(() => _status = 'Could not pick a picture: $e');
      return;
    }
    if (path == null || !mounted) {
      return;
    }
    try {
      final mark = store.addPicture(path);
      _changed();
      await _edit(mark);
    } on FormatException catch (e) {
      setState(() => _status = e.message);
    } on FileSystemException catch (e) {
      setState(() => _status = 'Could not keep the picture: ${e.message}');
    }
  }

  Future<void> _addText() async {
    final said = await showDialog<String>(
      context: context,
      builder: (context) => const _TextDialog(),
    );
    if (said == null || said.trim().isEmpty || !mounted) {
      return;
    }
    try {
      final mark = store.addText(said);
      _changed();
      await _edit(mark);
    } on FileSystemException catch (e) {
      setState(() => _status = 'Could not keep the watermark: ${e.message}');
    }
  }

  Future<void> _edit(Watermark mark) async {
    final changed = await showDialog<Watermark>(
      context: context,
      builder: (context) => WatermarkDialog(
        mark: mark,
        pictureBytes: store.pictureBytes(mark),
        kit: widget.kit,
        pickSample: widget.pickSample ?? _sample,
        pickSampleFromPhotos: _photos == null ? null : _sampleFromPhotos,
      ),
    );
    if (changed == null || !mounted) {
      return;
    }
    try {
      store.update(mark.name, changed);
      _changed();
    } on FileSystemException catch (e) {
      setState(() => _status = 'Could not keep the watermark: ${e.message}');
    }
  }

  void _remove(Watermark mark) {
    try {
      store.remove(mark.name);
      _changed();
    } on FileSystemException catch (e) {
      setState(() => _status = 'Could not remove it: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final marks = store.list();
    final phone = !widget.services.capabilities.desktop;
    final photos = _photos;
    return SectionCard(
      title: 'My watermarks',
      children: [
        const MutedText(
          'Your logo or name on the photos and videos you make. Add them '
          'here, then tick those you want on the Color page.',
        ),
        for (final mark in marks)
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(mark.name),
                    MutedText(watermarkSummary(mark), size: 11),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'Change ${mark.name}',
                onPressed: () => _edit(mark),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Remove ${mark.name}',
                onPressed: () => _remove(mark),
              ),
            ],
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            // A phone: one button, with the library or Files to choose
            // from, as where photos are picked (owner, 2026-11-25).
            if (phone)
              PickMediaButton(
                label: 'Add picture…',
                icon: Icons.add_photo_alternate_outlined,
                filled: false,
                onPick: ({required fromFiles}) => _addPicture(
                  fromFiles ? widget.pickFile : widget.pickFromLibrary,
                ),
              )
            // The Mac: from a file or from Photos, as its other pages
            // (owner, 2026-11-26).
            else if (photos != null)
              PlaceMenuButton(
                label: 'Add picture…',
                icon: Icons.add_photo_alternate_outlined,
                places: [
                  (
                    icon: Icons.description_outlined,
                    label: filesPlaceLabel,
                    onPressed: () => _addPicture(widget.pickFile),
                  ),
                  (
                    icon: Icons.photo_library_outlined,
                    label: photoLibraryPlaceLabel,
                    onPressed: () => _addPicture(
                      () => _fromPhotos('Watermarks', videos: false),
                    ),
                  ),
                ],
              )
            else
              OutlinedButton(
                onPressed: () => _addPicture(widget.pickFile),
                child: const Text('Add picture…'),
              ),
            OutlinedButton(onPressed: _addText, child: const Text('Add text…')),
          ],
        ),
        if (photos != null) const PhotosFetching(),
        if (_status.isNotEmpty) MutedText(_status),
      ],
    );
  }
}

/// Asks for the words of a new text watermark; pops them on Add.
class _TextDialog extends StatefulWidget {
  const _TextDialog();

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New text watermark'),
    content: TextField(
      controller: _text,
      autofocus: true,
      decoration: const InputDecoration(
        labelText: 'Text',
        hintText: '© Your name',
      ),
      onSubmitted: (v) => Navigator.of(context).pop(v),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_text.text),
        child: const Text('Add'),
      ),
    ],
  );
}
