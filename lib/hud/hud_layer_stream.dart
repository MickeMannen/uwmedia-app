/// An overlay layer of a video as ffmpeg takes it (Python
/// `ffmpeg/hud_layers.py`'s `HudLayer` and `write_layer_stream`): the
/// overlay changes only when the dive sample does, so each layer is drawn
/// once per sample as a transparent PNG, and a concat list tells ffmpeg
/// how long each is on screen.
///
/// The Python app can only draw onto an opaque frame and gets a layer's
/// transparency from drawing it twice, on black and on white; a Flutter
/// canvas starts transparent, so here a layer is drawn once.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/engine/hud_layers.dart';
import 'package:uwmedia_app/core/hud/hud_ops.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/image_resize.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

/// One overlay of a run: its layout (a page's layout with any variant
/// merged in), the bytes of its skin image file (`null` for a shape skin)
/// and, when the user placed it on the frame, where: the skin's top left
/// as fractions of the frame, and a scale. Without a placement the layout
/// is drawn by its own anchor on the whole frame.
class HudLayerSource {
  const HudLayerSource(
    this.layout, {
    this.skinBytes,
    this.placement,
    this.always = false,
    this.forFrame,
  });

  final Map<String, dynamic> layout;
  final Uint8List? skinBytes;
  final ({double x, double y, double scale})? placement;

  /// A layer that shows no dive data (a watermark): drawn on every file,
  /// matched to a dive or not, as one picture the whole clip through.
  final bool always;

  /// For a layer whose layout depends on the frame it is drawn on (a
  /// watermark has a place for landscape and one for portrait): the layer
  /// for a frame of that size.
  final HudLayerSource Function(int frameW, int frameH)? forFrame;

  /// This layer as it is drawn on a frame of [frameW] by [frameH].
  HudLayerSource on(int frameW, int frameH) =>
      forFrame?.call(frameW, frameH) ?? this;
}

/// The layers of [layers] a file gets: all of them when it is [matched]
/// to a dive, else only those that need none.
List<HudLayerSource> layersToDraw(
  List<HudLayerSource> layers, {
  required bool matched,
}) => [
  for (final layer in layers)
    if (matched || layer.always) layer,
];

/// A layer's stream: the concat list's path, and where its pictures go
/// on the frame.
typedef HudLayerStream = (String concatPath, int x, int y);

/// A layer's pictures, each with the number of frames it is shown for,
/// and the layer's top-left corner on the frame.
typedef HudLayerPictures = ({List<(String, int)> entries, int x, int y});

class _CanvasTooSmall implements Exception {
  const _CanvasTooSmall();
}

/// A layer that was stopped while being drawn.
class HudLayerStopped implements Exception {
  const HudLayerStopped();
}

/// An image of [straightRgba] ([width] x [height], colours not yet
/// multiplied by their alpha), for the painter to draw as a skin.
Future<ui.Image> hudSkinImage(
  Uint8List straightRgba,
  int width,
  int height,
) async {
  final premultiplied = Uint8List.fromList(straightRgba);
  for (var i = 0; i < premultiplied.length; i += 4) {
    final a = premultiplied[i + 3];
    if (a != 255) {
      premultiplied[i] = premultiplied[i] * a ~/ 255;
      premultiplied[i + 1] = premultiplied[i + 1] * a ~/ 255;
      premultiplied[i + 2] = premultiplied[i + 2] * a ~/ 255;
    }
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(premultiplied);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  final image = (await codec.getNextFrame()).image;
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return image;
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

/// Whether a drawing flashes: its operations [opsAt] the half second a
/// flashing value shows its flashing colour differ from those at the
/// other half.
bool drawingFlashes(List<HudOp> Function(double flashAt) opsAt) {
  String text(List<HudOp> ops) =>
      jsonEncode([for (final op in ops) op.toJson()]);
  return text(opsAt(flashOn)) != text(opsAt(flashOff));
}

/// Draws overlay layers for a video of one size.
class HudLayerWriter {
  HudLayerWriter(
    this.renderer,
    this.painter, {
    required this.frameW,
    required this.frameH,
    this.units = UnitSystem.metric,
  });

  final HudRenderer renderer;
  final HudPainter painter;
  final int frameW;
  final int frameH;
  final UnitSystem units;

  /// Draws [source] for every one of [segments] into [outDir] (layer
  /// number [index]): a PNG per change, and the concat list that times
  /// them. `null` when the layer draws nothing in the whole clip.
  /// [onSegment] is called after each segment, with its number;
  /// [stopped] is asked before each.
  Future<HudLayerStream?> write(
    HudLayerSource source,
    List<HudSegment> segments,
    List<Waypoint> waypoints,
    double fps,
    Directory outDir,
    int index, {
    void Function(int segment)? onSegment,
    bool Function()? stopped,
  }) async {
    final drawn = await pictures(
      source,
      segments,
      waypoints,
      outDir,
      index,
      fps: fps,
      onSegment: onSegment,
      stopped: stopped,
    );
    if (drawn == null) {
      return null;
    }
    final concat = p.join(outDir.path, layerConcatName(index));
    File(concat).writeAsStringSync(
      ffconcatText(drawn.entries, fps, windowsPaths: Platform.isWindows),
    );
    return (concat, drawn.x, drawn.y);
  }

  /// The PNGs of [write] without the concat list: each picture's path and
  /// how many frames it is shown for, in order, and where the layer's
  /// top-left corner lies on the frame. For the phones' engine, which
  /// takes the pictures themselves. A sample whose values flash is shown
  /// by two pictures in turn, half a second each, by the clip's own time
  /// at [fps] (spec §10 issue 9).
  Future<HudLayerPictures?> pictures(
    HudLayerSource layer,
    List<HudSegment> segments,
    List<Waypoint> waypoints,
    Directory outDir,
    int index, {
    required double fps,
    void Function(int segment)? onSegment,
    bool Function()? stopped,
  }) async {
    final source = layer.on(frameW, frameH);
    final placement = source.placement;
    final layout = placement == null
        ? source.layout
        : resolveOverlayInstanceLayout(
            source.layout,
            placement.x,
            placement.y,
            placement.scale,
            frameW,
            frameH,
          );
    final hudSkin = layout['hud_skin'] is Map<String, dynamic>
        ? layout['hud_skin'] as Map<String, dynamic>
        : const <String, dynamic>{};
    num number(Map<String, dynamic> map, String key, num fallback) =>
        map[key] is num ? map[key] as num : fallback;

    // The skin, once, at the size it is drawn at.
    ui.Image? skin;
    (int, int)? nativeSize;
    (int, int)? drawnSize;
    final bytes = source.skinBytes;
    if (bytes != null && hudSkin['type'] != 'shape') {
      try {
        final codec = await ui.instantiateImageCodec(bytes);
        final native = (await codec.getNextFrame()).image;
        codec.dispose();
        final data = await native.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        nativeSize = (native.width, native.height);
        final scale =
            number(hudSkin, 'scale', 1.0) *
            (frameW / number(layout, 'design_width', 1920).toDouble());
        final w = (native.width * scale).truncate();
        final h = (native.height * scale).truncate();
        drawnSize = (w < 1 ? 1 : w, h < 1 ? 1 : h);
        skin = await hudSkinImage(
          areaResize(
            data!.buffer.asUint8List(),
            native.width,
            native.height,
            drawnSize.$1,
            drawnSize.$2,
          ),
          drawnSize.$1,
          drawnSize.$2,
        );
        native.dispose();
      } on Exception {
        // An image that cannot be read: the layer is drawn without it.
        skin = null;
        nativeSize = null;
        drawnSize = null;
      }
    }
    final opacity = number(hudSkin, 'opacity', 1.0).toDouble();
    final canvas = HudLayerCanvas(
      layout,
      frameW: frameW,
      frameH: frameH,
      resolved: placement != null,
      skinSize: drawnSize,
    );

    List<HudOp> opsAt(Waypoint? waypoint, double? flashAt) {
      final (x0, y0, x1, y1) = canvas.region;
      return renderer.drawHud(
        frameWidth: x1 - x0,
        frameHeight: y1 - y0,
        layout: canvas.canvasLayout,
        waypoint: waypoint,
        waypoints: waypoints,
        skinSize: nativeSize,
        units: units,
        flashAt: flashAt,
      );
    }

    Future<ui.Image> draw(Waypoint? waypoint, double? flashAt) {
      final (x0, y0, x1, y1) = canvas.region;
      final ops = opsAt(waypoint, flashAt);
      final recorder = ui.PictureRecorder();
      painter.paint(ui.Canvas(recorder), ops, skin: skin, skinOpacity: opacity);
      final picture = recorder.endRecording();
      final image = picture.toImage(x1 - x0, y1 - y0);
      picture.dispose();
      return image;
    }

    try {
      List<(String, int)> entries;
      while (true) {
        try {
          entries = await _writePngs(
            canvas,
            draw,
            (waypoint) => drawingFlashes((at) => opsAt(waypoint, at)),
            fps,
            segments,
            outDir,
            index,
            onSegment,
            stopped,
          );
          break;
        } on _CanvasTooSmall {
          // Something is drawn past the canvas: again on a bigger one.
          canvas.widen();
        }
      }
      if (entries.isEmpty) {
        return null;
      }
      return (entries: entries, x: canvas.region.$1, y: canvas.region.$2);
    } finally {
      skin?.dispose();
    }
  }

  Future<List<(String, int)>> _writePngs(
    HudLayerCanvas canvas,
    Future<ui.Image> Function(Waypoint?, double?) draw,
    bool Function(Waypoint?) flashes,
    double fps,
    List<HudSegment> segments,
    Directory outDir,
    int index,
    void Function(int)? onSegment,
    bool Function()? stopped,
  ) async {
    final entries = <(String, int)>[];
    // The last picture written, and its file.
    Uint8List? previous;
    String? previousPath;
    var written = 0;
    var drew = false;
    void show(String path, int frames) {
      if (entries.isNotEmpty && entries.last.$1 == path) {
        final (_, shown) = entries.last;
        entries[entries.length - 1] = (path, shown + frames);
      } else {
        entries.add((path, frames));
      }
    }

    for (final (i, segment) in segments.indexed) {
      if (stopped?.call() ?? false) {
        throw const HudLayerStopped();
      }
      // A sample whose values flash has two pictures, each drawn once and
      // shown in turn.
      final made = <double?, String>{};
      for (final (waypoint, _, frames, flashAt) in flashSegments(
        [segment],
        fps,
        flashes,
      )) {
        final known = made[flashAt];
        if (known != null) {
          show(known, frames);
          continue;
        }
        final image = await draw(waypoint, flashAt);
        try {
          final pixels = (await image.toByteData(
            format: ui.ImageByteFormat.rawStraightRgba,
          ))!.buffer.asUint8List();
          if (!canvas.isFullFrame && canvas.reachesCanvasEdge(pixels)) {
            throw const _CanvasTooSmall();
          }
          if (!drew) {
            for (var a = 3; a < pixels.length; a += 4) {
              if (pixels[a] != 0) {
                drew = true;
                break;
              }
            }
          }
          if (previous == null || !_sameBytes(pixels, previous)) {
            final path = p.join(outDir.path, layerPngName(index, written++));
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            File(path).writeAsBytesSync(png!.buffer.asUint8List());
            previous = pixels;
            previousPath = path;
          }
          made[flashAt] = previousPath!;
          show(previousPath, frames);
        } finally {
          image.dispose();
        }
      }
      onSegment?.call(i);
    }
    return drew ? entries : [];
  }
}
