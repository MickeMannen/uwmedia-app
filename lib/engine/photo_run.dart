/// A photo through the app (Python `cli_main.py`'s photo path): colour
/// correction, overlays for the dive sample of the moment it was taken,
/// and the save. A JPEG is saved with its source's own quantisation
/// tables and chroma subsampling, so that it comes out at the source's
/// quality. Also the telemetry-only photo: the overlay alone.
///
/// Decoding and drawing are Flutter's; the file names and the copying of
/// the metadata afterwards are the caller's ([PhotoRun.processFile] does
/// both on the desktop).
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/engine/compare.dart';
import 'package:uwmedia_app/core/engine/overlay_canvas.dart';
import 'package:uwmedia_app/core/engine/share_sizes.dart';
import 'package:uwmedia_app/core/hud/hud_ops.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/image_resize.dart';
import 'package:uwmedia_app/core/image/jpeg_encoder.dart';
import 'package:uwmedia_app/core/image/jpeg_tables.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/engine/desktop/exiftool.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart'
    show EngineException;
import 'package:uwmedia_app/hud/hud_layer_stream.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

/// The kinds of file a photo can be saved as.
enum PhotoFormat { jpeg, png }

/// The format a target's name asks for; `null` for one the app cannot
/// write.
PhotoFormat? photoFormatOf(String path) =>
    switch (p.extension(path).toLowerCase()) {
      '.jpg' || '.jpeg' => PhotoFormat.jpeg,
      '.png' => PhotoFormat.png,
      _ => null,
    };

/// A skin image's straight RGBA pixels and size.
class HudSkinPixels {
  HudSkinPixels(this.rgba, this.width, this.height);

  final Uint8List rgba;
  final int width;
  final int height;
}

class PhotoRun {
  PhotoRun({
    required this.renderer,
    required this.painter,
    this.engine,
    this.units = UnitSystem.metric,
  });

  final HudRenderer renderer;
  final HudPainter painter;

  /// The colour profile's engine; without one there is no colour
  /// correction.
  final ColorEngine? engine;
  final UnitSystem units;

  // The colour correction on another isolate (a large photo takes a
  // second or two); the closure holds only the engine and the picture.
  static Future<Uint8List> _correctedOffThread(
    ColorEngine colour,
    RgbImage frame,
  ) => Isolate.run(
    () => colour.applyFilter(frame, colour.analyze(frame).filter).rgb,
  );

  static Future<ui.Image> _decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final image = (await codec.getNextFrame()).image;
    codec.dispose();
    return image;
  }

  static Future<Uint8List> _rgbaOf(ui.Image image) async =>
      (await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!
          .buffer
          .asUint8List();

  /// The skin of [source] decoded, `null` for a shape skin or none.
  static Future<HudSkinPixels?> skinOf(HudLayerSource source) async {
    final bytes = source.skinBytes;
    final hudSkin = source.layout['hud_skin'];
    if (bytes == null || (hudSkin is Map && hudSkin['type'] == 'shape')) {
      return null;
    }
    try {
      final image = await _decode(bytes);
      final skin = HudSkinPixels(
        await _rgbaOf(image),
        image.width,
        image.height,
      );
      image.dispose();
      return skin;
    } on Exception {
      return null;
    }
  }

  // Draws a layout on [canvas], with its skin at the size the renderer
  // gives it.
  /// Draws [layout] on [canvas] for [waypoint], with [skin] at the size
  /// the renderer gives it: what a run draws, for the Overlay Designer's
  /// canvas too.
  Future<void> paintLayout(
    ui.Canvas canvas,
    Map<String, dynamic> layout,
    HudSkinPixels? skin,
    Waypoint? waypoint,
    List<Waypoint>? waypoints,
    int width,
    int height, {
    bool renderLog = false,
  }) async {
    final ops = renderer.drawHud(
      frameWidth: width,
      frameHeight: height,
      layout: layout,
      waypoint: waypoint,
      waypoints: waypoints,
      skinSize: skin == null ? null : (skin.width, skin.height),
      renderLog: renderLog,
      units: units,
    );
    ui.Image? image;
    final skinOp = ops.whereType<SkinOp>().firstOrNull;
    if (skin != null && skinOp != null) {
      image = await hudSkinImage(
        areaResize(
          skin.rgba,
          skin.width,
          skin.height,
          skinOp.width,
          skinOp.height,
        ),
        skinOp.width,
        skinOp.height,
      );
    }
    final hudSkin = layout['hud_skin'];
    final opacity = hudSkin is Map && hudSkin['opacity'] is num
        ? (hudSkin['opacity'] as num).toDouble()
        : 1.0;
    painter.paint(canvas, ops, skin: image, skinOpacity: opacity);
    image?.dispose();
  }

  static Uint8List _rgbOf(Uint8List rgba) {
    final rgb = Uint8List(rgba.length ~/ 4 * 3);
    var o = 0;
    for (var i = 0; i < rgba.length; i += 4) {
      rgb[o++] = rgba[i];
      rgb[o++] = rgba[i + 1];
      rgb[o++] = rgba[i + 2];
    }
    return rgb;
  }

  // The picture as a file of [format]: a JPEG with [source]'s tables
  // and subsampling when it is a JPEG whose tables can be used, at the
  // finest tables otherwise.
  static Future<Uint8List> _encode(
    Uint8List rgba,
    int width,
    int height,
    PhotoFormat format,
    Uint8List? source,
  ) async {
    if (format == PhotoFormat.png) {
      final image = await hudSkinImage(rgba, width, height);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return png!.buffer.asUint8List();
    }
    final read = source == null ? null : readJpegTables(source);
    final tables = read == null ? null : usableQuantTables(read.quantization);
    return encodeJpeg(
      _rgbOf(rgba),
      width,
      height,
      quantTables: tables ?? jpegFinestTables,
      sampling: read?.sampling,
    );
  }

  // The photo in [sourceBytes] upright as RGBA pixels, only the window
  // of [cut] kept.
  static Future<({Uint8List rgba, int width, int height})> _read(
    Uint8List sourceBytes,
    PictureCut? cut,
  ) async {
    final ui.Image decoded;
    try {
      decoded = await _decode(sourceBytes);
    } on Exception {
      throw const EngineException('Could not read the image');
    }
    var width = decoded.width;
    var height = decoded.height;
    var rgba = await _rgbaOf(decoded);
    decoded.dispose();
    final crop = cut?.cropOf(width, height);
    if (crop != null) {
      final kept = Uint8List(crop.width * crop.height * 4);
      for (var y = 0; y < crop.height; y++) {
        final from = ((crop.y + y) * width + crop.x) * 4;
        kept.setRange(y * crop.width * 4, (y + 1) * crop.width * 4, rgba, from);
      }
      rgba = kept;
      width = crop.width;
      height = crop.height;
    }
    return (rgba: rgba, width: width, height: height);
  }

  // [rgba] colour-corrected by [colour], as a picture of its own.
  static Future<Uint8List> _corrected(
    ColorEngine colour,
    Uint8List rgba,
    int width,
    int height,
  ) async {
    final frame = RgbImage(width, height, _rgbOf(rgba));
    final corrected = await _correctedOffThread(colour, frame);
    final out = Uint8List(rgba.length);
    var o = 0;
    for (var i = 0; i < out.length; i += 4) {
      out[i] = corrected[o++];
      out[i + 1] = corrected[o++];
      out[i + 2] = corrected[o++];
      out[i + 3] = 255;
    }
    return out;
  }

  // [rgba] with the [layers] a run draws laid over it for the dive
  // sample at [matchDate]. Without a dive only the layers that need none
  // (a watermark); a photo taken away from the dive's samples shows "--"
  // (spec §10.10).
  Future<Uint8List> _withLayers(
    Uint8List rgba,
    int width,
    int height,
    List<HudLayerSource> layers,
    Dive? dive,
    DateTime? matchDate,
  ) async {
    final matched = dive != null && matchDate != null;
    final wanted = layersToDraw(layers, matched: matched);
    if (wanted.isEmpty) {
      return rgba;
    }
    final base = await hudSkinImage(rgba, width, height);
    final composed = await overlaid(
      base,
      wanted,
      matched ? dive.getWaypointNear(matchDate) : null,
      dive?.waypoints,
    );
    base.dispose();
    final out = await _rgbaOf(composed);
    composed.dispose();
    return out;
  }

  /// The photo in [sourceBytes] colour-corrected (with an [engine] and
  /// [colorCorrect]) and with [layers] laid over it in order for the dive
  /// sample at [matchDate] (the moment it was taken, on the dive
  /// computer's clock), as a file of [format]. Without a [dive], or with
  /// no sample for that moment, only the layers that need none are drawn. Throws an
  /// [EngineException] for a file that is no picture. With a [cut] only
  /// its window of the picture is kept, at its own pixels, and the
  /// layers lie on that (as for a video, spec §10.75). With [compare]
  /// (and the colour correction) the original shows on one side of an
  /// edge and the corrected picture on the other, the layers over both
  /// (spec §10.94).
  Future<Uint8List> process(
    Uint8List sourceBytes, {
    required PhotoFormat format,
    bool colorCorrect = true,
    List<HudLayerSource> layers = const [],
    Dive? dive,
    DateTime? matchDate,
    PictureCut? cut,
    Compare? compare,
  }) async {
    final read = await _read(sourceBytes, cut);
    final (width, height) = (read.width, read.height);
    var rgba = read.rgba;
    final colour = engine;
    if (colorCorrect && colour != null) {
      final corrected = await _corrected(colour, rgba, width, height);
      rgba = compare == null
          ? corrected
          : compareMix(
              rgba,
              corrected,
              CompareEdge.split(compare.kind, width, height),
            );
    }
    rgba = await _withLayers(rgba, width, height, layers, dive, matchDate);
    return _encode(rgba, width, height, format, sourceBytes);
  }

  /// The photo in [sourceBytes] twice, as RGBA pictures of the same
  /// size: as it is and colour-corrected by the [engine], each with
  /// [layers] laid over it as [process] lays them (the two pictures of a
  /// wipe video, spec §10.94). Throws an [EngineException] for a file
  /// that is no picture, and without an [engine].
  Future<({Uint8List before, Uint8List after, int width, int height})> pair(
    Uint8List sourceBytes, {
    List<HudLayerSource> layers = const [],
    Dive? dive,
    DateTime? matchDate,
    PictureCut? cut,
  }) async {
    final colour = engine;
    if (colour == null) {
      throw const EngineException('No colour correction to compare with');
    }
    final read = await _read(sourceBytes, cut);
    final (width, height) = (read.width, read.height);
    final corrected = await _corrected(colour, read.rgba, width, height);
    return (
      before: await _withLayers(
        read.rgba,
        width,
        height,
        layers,
        dive,
        matchDate,
      ),
      after: await _withLayers(
        corrected,
        width,
        height,
        layers,
        dive,
        matchDate,
      ),
      width: width,
      height: height,
    );
  }

  /// [base] with [layers] drawn over it in order for [waypoint] (each
  /// where its placement puts it, else by its own anchor): the picture a
  /// run writes, and the Color page's preview.
  Future<ui.Image> overlaid(
    ui.Image base,
    List<HudLayerSource> layers,
    Waypoint? waypoint,
    List<Waypoint>? waypoints,
  ) async {
    final width = base.width;
    final height = base.height;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..drawImage(base, ui.Offset.zero, ui.Paint());
    for (final one in layers) {
      final layer = one.on(width, height);
      final placement = layer.placement;
      await paintLayout(
        canvas,
        placement == null
            ? layer.layout
            : resolveOverlayInstanceLayout(
                layer.layout,
                placement.x,
                placement.y,
                placement.scale,
                width,
                height,
              ),
        await skinOf(layer),
        waypoint,
        waypoints,
        width,
        height,
      );
    }
    final picture = recorder.endRecording();
    final composed = await picture.toImage(width, height);
    picture.dispose();
    return composed;
  }

  /// The overlay alone for the moment a photo was taken (Python's
  /// telemetry-only photo): a transparent PNG for the formats with alpha
  /// ([overlayFormat] ProRes or PNG), else the overlay on black as a file
  /// of [format], a JPEG with [sourceBytes]' tables when that is a JPEG.
  /// A moment with no dive sample shows a sample of zeros. [size] and
  /// [fullFrame] decide the canvas ([overlayCanvas]).
  Future<Uint8List> telemetryPhoto(
    HudLayerSource source, {
    required String overlayFormat,
    required PhotoFormat format,
    required DateTime matchDate,
    Dive? dive,
    Uint8List? sourceBytes,
    String? size,
    bool fullFrame = false,
  }) async {
    final skin = await skinOf(source);
    final canvasPlan = overlayCanvas(
      source.layout,
      size: size,
      fullFrame: fullFrame,
      skinSize: skin == null ? null : (skin.width, skin.height),
    );
    final alpha = overlayHasAlpha(overlayFormat);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    if (!alpha) {
      canvas.drawRect(
        ui.Rect.fromLTWH(
          0,
          0,
          canvasPlan.width.toDouble(),
          canvasPlan.height.toDouble(),
        ),
        ui.Paint()..color = const ui.Color(0xFF000000),
      );
    }
    await paintLayout(
      canvas,
      canvasPlan.layout,
      skin,
      dive == null
          ? Waypoint(timestamp: matchDate, timeSinceStart: 0, depth: 0, temp: 0)
          : dive.getWaypointNear(matchDate),
      dive?.waypoints,
      canvasPlan.width,
      canvasPlan.height,
      renderLog: canvasPlan.renderLog,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(canvasPlan.width, canvasPlan.height);
    picture.dispose();
    try {
      if (alpha) {
        // A transparent PNG, whatever the source photo's type.
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        return png!.buffer.asUint8List();
      }
      return await _encode(
        await _rgbaOf(image),
        canvasPlan.width,
        canvasPlan.height,
        format,
        sourceBytes,
      );
    } finally {
      image.dispose();
    }
  }

  /// [process] from the file at [source] to the file at [target] (whose
  /// name says the format), then the source's metadata carried over with
  /// [exiftool] when there is one. Gives what exiftool had to say. A
  /// target the app cannot write as is an [EngineException].
  Future<List<String>> processFile(
    String source,
    String target, {
    bool colorCorrect = true,
    List<HudLayerSource> layers = const [],
    Dive? dive,
    DateTime? matchDate,
    Exiftool? exiftool,
    int? forcedTzMinutes,
    List<String>? customTags,
    PictureCut? cut,
    Compare? compare,
  }) async {
    final format = photoFormatOf(target);
    if (format == null) {
      throw EngineException(
        'Photos are saved as JPEG or PNG, not ${p.extension(target)}',
      );
    }
    final bytes = await process(
      File(source).readAsBytesSync(),
      format: format,
      colorCorrect: colorCorrect,
      layers: layers,
      dive: dive,
      matchDate: matchDate,
      cut: cut,
      compare: compare,
    );
    File(target).writeAsBytesSync(bytes, flush: true);
    if (exiftool == null) {
      return const [];
    }
    final messages = await exiftool.copyAll(
      source,
      target,
      forcedTzMinutes: forcedTzMinutes,
      customTags: customTags,
    );
    // The picture was turned upright when it was read; the copied tag
    // would have a viewer turn it again.
    final turned = await exiftool.tags(target, ['Orientation']);
    if (!const ['', '1'].contains(turned['Orientation'])) {
      await exiftool.setTags(target, {'Orientation': 1});
    }
    return messages;
  }
}
