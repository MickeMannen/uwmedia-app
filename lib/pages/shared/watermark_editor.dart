/// The editor of one watermark (spec §10.45, §10.63): its name, a text's
/// words and colour, its size and a picture's opacity, and its place on a
/// landscape frame and on a portrait one, each set by dragging the mark
/// on a sample picture; near an edge or the middle it is taken onto it,
/// so the nine places of before are the points it snaps to. A mark may be
/// for one of the two kinds of frame only.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:uwmedia_app/app/hud_kit.dart';
import 'package:uwmedia_app/core/hud/hud_designer.dart';
import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/image_size.dart';
import 'package:uwmedia_app/core/watermark/watermark.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';
import 'package:uwmedia_app/pages/shared/photos.dart';
import 'package:uwmedia_app/pages/shared/place_menu.dart';
import 'package:uwmedia_app/widgets/section_card.dart';

/// The colours a text watermark is offered at a tap, by name; any other
/// is made under "More…".
const watermarkTextColors = {
  'White': '#FFFFFF',
  'Black': '#000000',
  'Yellow': '#FFD60A',
  'Light blue': '#7FDBFF',
};

/// `#RRGGBB` as a colour; white for what is none.
Color colorOfHex(String hex) {
  final value = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
  return hex.length == 7 && value != null
      ? Color(0xFF000000 | value)
      : const Color(0xFFFFFFFF);
}

/// A colour as `#RRGGBB`.
String hexOfColor(Color color) {
  String two(double channel) =>
      (channel * 255).round().toRadixString(16).padLeft(2, '0').toUpperCase();
  return '#${two(color.r)}${two(color.g)}${two(color.b)}';
}

/// How wide and high [text] is drawn as a watermark, in letter heights,
/// measured with the renderer's own font; `null` for no text.
(double, double)? measuredTextBox(HudDesigner designer, Watermark mark) {
  if (mark.isPicture || mark.text.trim().isEmpty) {
    return null;
  }
  const probe = 200;
  final (w, h) = designer.measureElementBox(
    {...watermarkTextElement(mark), 'font_size': probe},
    const {'type': 'shape'},
    text: mark.text,
  );
  return (w / probe, h / probe);
}

/// Where a mark of [markW] by [markH] lies on a stage of [stageW] by
/// [stageH] at [place], as [watermarkLayout] puts it on a frame.
Offset watermarkOffset(
  WatermarkPlace place,
  double stageW,
  double stageH,
  double markW,
  double markH,
) {
  final (x, y) = watermarkCorner(place, stageW, stageH, markW, markH);
  return Offset(x, y);
}

// A drag that is the stage's from the moment the finger is down: the
// dialog scrolls, and would otherwise take every drag up or down.
class _StageDrag extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

/// A watermark's name, places, size and (a picture's) opacity or (a
/// text's) words and colour; pops the changed one on Save.
class WatermarkDialog extends StatefulWidget {
  const WatermarkDialog({
    super.key,
    required this.mark,
    this.pictureBytes,
    this.kit,
    this.pickSample,
    this.pickSampleFromPhotos,
  });

  final Watermark mark;

  /// The picture of a picture watermark.
  final Uint8List? pictureBytes;

  /// The renderer's fonts, for measuring a text; without them a text
  /// keeps to the nine places.
  final Future<HudKit> Function()? kit;

  /// A picture of the user's own to place the mark on (a video gives one
  /// of its frames); without it the stage stays plain.
  final Future<String?> Function()? pickSample;

  /// The same from Apple Photos, where a computer has it (the Mac): the
  /// button then asks which of the two.
  final Future<String?> Function()? pickSampleFromPhotos;

  @override
  State<WatermarkDialog> createState() => _WatermarkDialogState();
}

class _WatermarkDialogState extends State<WatermarkDialog> {
  late Watermark mark = widget.mark;
  late final _name = TextEditingController(text: widget.mark.name);
  late final _text = TextEditingController(text: widget.mark.text);
  late final (int, int)? _pictureSize = widget.pictureBytes == null
      ? null
      : imageSize(widget.pictureBytes!);

  HudDesigner? _designer;
  bool _portrait = false;
  String? _sample;

  // The mark's corner while it is dragged, before it is taken onto a
  // line; and which lines it lies on, to show them.
  Offset? _dragged;

  @override
  void initState() {
    super.initState();
    widget.kit
        ?.call()
        .then((kit) {
          if (mounted) {
            setState(() {
              _designer = HudDesigner(kit.renderer);
              _measure();
            });
          }
        })
        .catchError((Object _) {
          // Without the fonts a text keeps to the nine places.
        });
  }

  @override
  void dispose() {
    _name.dispose();
    _text.dispose();
    super.dispose();
  }

  void _measure() {
    final designer = _designer;
    if (designer != null && !mark.isPicture) {
      mark = mark.copyWith(textBox: measuredTextBox(designer, mark));
    }
  }

  void _textChanged(String value) {
    final said = value.trim();
    if (said.isEmpty || said == mark.text) {
      return;
    }
    setState(() {
      mark = mark.copyWith(text: said);
      _measure();
    });
  }

  WatermarkPlace get _place => _portrait ? mark.placePortrait : mark.place;

  // The size on frames of the shape shown: each shape has its own.
  double get _size => _portrait ? mark.sizePortrait : mark.size;

  // Whether the mark is put on frames of the shape shown.
  bool get _used => _portrait ? mark.onPortrait : mark.onLandscape;

  // On or off for the shape shown; taken off both, it goes onto the other.
  void _setUsed(bool used) {
    final landscape = _portrait ? mark.onLandscape : used;
    final portrait = _portrait ? used : mark.onPortrait;
    setState(
      () => mark = mark.copyWith(
        frames: landscape && portrait
            ? watermarkFramesBoth
            : landscape || (!portrait && _portrait)
            ? watermarkFramesLandscape
            : watermarkFramesPortrait,
      ),
    );
  }

  void _setPlace(WatermarkPlace place) {
    // A text that could not be measured keeps to the nine places.
    final kept = mark.isPicture || mark.textBox != null
        ? place
        : placeOfAnchor(
            anchorOfPlace((
              x: (place.x * 2).round() / 2,
              y: (place.y * 2).round() / 2,
            ))!,
          );
    setState(
      () => mark = _portrait
          ? mark.copyWith(placePortrait: kept)
          : mark.copyWith(place: kept),
    );
  }

  // The mark's size on a stage [stageW] wide.
  (double, double) _markSize(double stageW) {
    final (w, h) = watermarkShare(
      mark.shaped(portrait: _portrait),
      pictureSize: _pictureSize,
    );
    return (w * stageW, h * stageW);
  }

  Widget _markPicture() {
    final bytes = widget.pictureBytes;
    if (bytes != null) {
      return Opacity(
        opacity: mark.opacity,
        child: Image.memory(bytes, fit: BoxFit.fill, gaplessPlayback: true),
      );
    }
    // The renderer's bold letters with their dark outline, fitted into
    // the box the renderer's font gave.
    final family = fontFamilyOf(
      fontRegistry[defaultFontFamily]![fontWeightBold]!,
    );
    Text letters(Paint? stroke) => Text(
      mark.text,
      softWrap: false,
      style: TextStyle(
        fontFamily: family,
        fontWeight: FontWeight.bold,
        fontSize: 40,
        height: 1,
        color: stroke == null ? colorOfHex(mark.color) : null,
        foreground: stroke,
      ),
    );
    return FittedBox(
      fit: BoxFit.fill,
      child: Stack(
        children: [
          letters(
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 4
              ..color = const Color(0xCC000000),
          ),
          letters(null),
        ],
      ),
    );
  }

  Widget _stage(double room) {
    // A portrait stage is as high as the landscape one is wide at most.
    final stageW = _portrait ? math.min(room, 360.0) * 9 / 16 : room;
    final stageH = _portrait ? stageW * 16 / 9 : stageW * 9 / 16;
    final (markW, markH) = _markSize(stageW);
    final shown = watermarkOffset(_place, stageW, stageH, markW, markH);
    final sample = _sample;
    const guide = Color(0xFFFFD60A);
    // The mark follows a finger put down anywhere on the stage: a small
    // mark is hard to hit on a phone.
    return Center(
      child: RawGestureDetector(
        key: const ValueKey('watermark stage'),
        behavior: HitTestBehavior.opaque,
        gestures: {
          if (_used)
            _StageDrag: GestureRecognizerFactoryWithHandlers<_StageDrag>(
              _StageDrag.new,
              (drag) => drag
                ..onStart = ((_) => setState(() => _dragged = shown))
                ..onUpdate = (details) {
                  // Several moves may come between two frames.
                  final corner = (_dragged ?? shown) + details.delta;
                  _dragged = corner;
                  _setPlace(
                    watermarkPlaceAt(
                      corner.dx,
                      corner.dy,
                      stageW,
                      stageH,
                      markW,
                      markH,
                    ),
                  );
                }
                ..onEnd = ((_) => setState(() => _dragged = null))
                ..onCancel = (() => setState(() => _dragged = null)),
            ),
        },
        child: SizedBox(
          width: stageW,
          height: stageH,
          child: ClipRect(
            child: Stack(
              children: [
                Positioned.fill(
                  child: sample == null
                      ? const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0xFF2A8FB5), Color(0xFF0B3550)],
                            ),
                          ),
                        )
                      : Image.file(File(sample), fit: BoxFit.cover),
                ),
                // The lines the mark lies on while it is dragged.
                if (_dragged != null) ...[
                  if (anchorOfPlace((x: _place.x, y: 0)) != null)
                    Positioned(
                      left: shown.dx + markW * _place.x,
                      top: 0,
                      bottom: 0,
                      child: const SizedBox(
                        width: 1,
                        child: ColoredBox(color: guide),
                      ),
                    ),
                  if (anchorOfPlace((x: 0, y: _place.y)) != null)
                    Positioned(
                      top: shown.dy + markH * _place.y,
                      left: 0,
                      right: 0,
                      child: const SizedBox(
                        height: 1,
                        child: ColoredBox(color: guide),
                      ),
                    ),
                ],
                Positioned(
                  left: shown.dx,
                  top: shown.dy,
                  width: math.max(markW, 1),
                  height: math.max(markH, 1),
                  child: KeyedSubtree(
                    key: const ValueKey('watermark mark'),
                    // Faint on a shape of frame it is not put on.
                    child: Opacity(
                      opacity: _used ? 1 : 0.25,
                      child: _markPicture(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickSample(Future<String?> Function() pick) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await pick();
      if (path != null && mounted) {
        setState(() => _sample = path);
      }
    } on Exception catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not open the picture: $e')),
      );
    }
  }

  Future<void> _moreColors() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => ColorPickerDialog(color: mark.color),
    );
    if (picked != null && mounted) {
      setState(() => mark = mark.copyWith(color: picked));
    }
  }

  Widget _swatch(String hex, {String? tooltip}) {
    final chosen = mark.color.toUpperCase() == hex.toUpperCase();
    return Tooltip(
      message: tooltip ?? hex,
      child: InkWell(
        onTap: () => setState(() => mark = mark.copyWith(color: hex)),
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: colorOfHex(hex),
            shape: BoxShape.circle,
            border: Border.all(
              color: chosen ? const Color(0xFFFFD60A) : const Color(0xFF808080),
              width: chosen ? 3 : 1,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final picture = mark.isPicture;
    final shape = _portrait ? 'portrait' : 'landscape';
    // A picture's width, or a text's letter height, of the frame's width.
    final (low, high) = picture ? (0.05, 0.5) : (0.015, 0.1);
    return AlertDialog(
      title: Text(picture ? 'Picture watermark' : 'Text watermark'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              if (!picture) ...[
                TextField(
                  controller: _text,
                  decoration: const InputDecoration(labelText: 'Text'),
                  onChanged: _textChanged,
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text('Colour'),
                    for (final MapEntry(:key, :value)
                        in watermarkTextColors.entries)
                      _swatch(value, tooltip: key),
                    // One made under "More…".
                    if (!watermarkTextColors.containsValue(
                      mark.color.toUpperCase(),
                    ))
                      _swatch(mark.color),
                    OutlinedButton(
                      onPressed: _moreColors,
                      child: const Text('More…'),
                    ),
                  ],
                ),
              ],
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: false, label: Text('Landscape')),
                      ButtonSegment(value: true, label: Text('Portrait')),
                    ],
                    selected: {_portrait},
                    onSelectionChanged: (v) =>
                        setState(() => _portrait = v.single),
                  ),
                  if (widget.pickSample != null &&
                      widget.pickSampleFromPhotos != null) ...[
                    PlaceMenuButton(
                      label: 'Sample picture…',
                      icon: Icons.image_outlined,
                      places: [
                        (
                          icon: Icons.description_outlined,
                          label: filesPlaceLabel,
                          onPressed: () => _pickSample(widget.pickSample!),
                        ),
                        (
                          icon: Icons.photo_library_outlined,
                          label: photoLibraryPlaceLabel,
                          onPressed: () =>
                              _pickSample(widget.pickSampleFromPhotos!),
                        ),
                      ],
                    ),
                    const PhotosFetching(),
                  ] else if (widget.pickSample != null)
                    OutlinedButton(
                      onPressed: () => _pickSample(widget.pickSample!),
                      child: const Text('Sample picture…'),
                    ),
                ],
              ),
              LayoutBuilder(
                builder: (context, inner) => _stage(inner.maxWidth),
              ),
              MutedText(
                _used
                    ? 'Drag on the picture to move the mark to where it goes '
                          'on a ${_portrait ? 'portrait' : 'landscape'} photo '
                          'or video. Near an edge or the middle it is taken '
                          'onto it.'
                    : 'Not put on ${_portrait ? 'portrait' : 'landscape'} '
                          'photos and videos.',
                size: 11,
              ),
              SwitchListTile(
                key: const ValueKey('watermark used'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  'Put it on ${_portrait ? 'portrait' : 'landscape'} photos '
                  'and videos',
                ),
                value: _used,
                onChanged: _setUsed,
              ),
              Text(
                picture
                    ? 'Size on $shape photos: '
                          '${(_size * 100).round()} % of the width'
                    : 'Letters on $shape photos: '
                          '${(_size * 100).toStringAsFixed(1)} % of the width',
              ),
              Slider(
                min: low,
                max: high,
                value: _size.clamp(low, high),
                onChanged: (v) => setState(
                  () => mark = _portrait
                      ? mark.copyWith(sizePortrait: v)
                      : mark.copyWith(size: v),
                ),
              ),
              if (picture) ...[
                Text('Opacity: ${(mark.opacity * 100).round()} %'),
                Slider(
                  min: watermarkMinOpacity,
                  value: mark.opacity.clamp(watermarkMinOpacity, 1.0),
                  onChanged: (v) =>
                      setState(() => mark = mark.copyWith(opacity: v)),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(mark.copyWith(name: _name.text.trim())),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Any colour: its hue, how strong and how light it is, or its `#RRGGBB`
/// typed; pops the colour on OK.
class ColorPickerDialog extends StatefulWidget {
  const ColorPickerDialog({super.key, required this.color});

  /// The colour it opens on, as `#RRGGBB`.
  final String color;

  @override
  State<ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<ColorPickerDialog> {
  late HSVColor _color = HSVColor.fromColor(colorOfHex(widget.color));
  late final _hex = TextEditingController(text: hexOfColor(_color.toColor()));

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _set(HSVColor color) {
    setState(() => _color = color);
    _hex.text = hexOfColor(color.toColor());
  }

  void _typed(String value) {
    final hex = value.startsWith('#') ? value : '#$value';
    if (RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(hex)) {
      setState(() => _color = HSVColor.fromColor(colorOfHex(hex)));
    }
  }

  // A slider on a band of the colours it runs through.
  Widget _band(
    String label,
    double value,
    double max,
    List<Color> colors,
    ValueChanged<double> onChanged,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(label),
      Stack(
        alignment: Alignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              height: 14,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(7),
                gradient: LinearGradient(colors: colors),
              ),
            ),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: Colors.transparent,
              inactiveTrackColor: Colors.transparent,
              thumbColor: Colors.white,
            ),
            child: Slider(max: max, value: value, onChanged: onChanged),
          ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Colour'),
    content: SizedBox(
      width: 360,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            Container(
              key: const ValueKey('picked colour'),
              height: 44,
              decoration: BoxDecoration(
                color: _color.toColor(),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF808080)),
              ),
            ),
            _band('Hue', _color.hue, 360, [
              for (var hue = 0; hue <= 360; hue += 60)
                HSVColor.fromAHSV(1, hue % 360.0, 1, 1).toColor(),
            ], (v) => _set(_color.withHue(v == 360 ? 0 : v))),
            _band('Strength', _color.saturation, 1, [
              _color.withSaturation(0).toColor(),
              _color.withSaturation(1).toColor(),
            ], (v) => _set(_color.withSaturation(v))),
            _band('Light', _color.value, 1, [
              Colors.black,
              _color.withValue(1).toColor(),
            ], (v) => _set(_color.withValue(v))),
            TextField(
              controller: _hex,
              decoration: const InputDecoration(
                labelText: 'As #RRGGBB',
                isDense: true,
              ),
              onChanged: _typed,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.of(context).pop(hexOfColor(_color.toColor())),
        child: const Text('OK'),
      ),
    ],
  );
}
