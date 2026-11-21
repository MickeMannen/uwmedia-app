// The overlay renders of the platform check: the bundled templates drawn
// by the app's renderer and painter on a black 1920x1080 frame, cropped to
// the overlay's own pixels and halved, as the golden test does it
// (test/hud/hud_golden_test.dart, Python tests/test_template_golden.py).
// Everything is read from the app's assets, so it runs on a phone.
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/app/hud_kit.dart';
import 'package:uwmedia_app/core/hud/dummy_telemetry.dart';
import 'package:uwmedia_app/core/hud/image_resize.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/units/units.dart';

import 'checks.dart';

/// The text of every JSON file of the bundled templates, by asset path.
Future<Map<String, String>> templateTexts() async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  return {
    for (final asset in manifest.listAssets())
      if (asset.startsWith('$bundledTemplatesRoot/') && asset.endsWith('.json'))
        asset: await rootBundle.loadString(asset, cache: false),
  };
}

/// A template's layout as the golden test loads it: its `normal.json`,
/// variant markers stripped. Also gives the file's asset path.
(Map<String, dynamic>, String) packLayout(
  List<dynamic> template,
  Map<String, String> texts,
) {
  final path =
      '$bundledTemplatesRoot/${template.whereType<String>().join('/')}/'
      'normal.json';
  return (
    stripVariantMarkers(
      loadLayoutFile(
        path,
        (file) =>
            texts[p.posix.normalize(file)] ??
            (throw StateError('no template file $file')),
      ),
    ),
    path,
  );
}

class _Rgba {
  _Rgba(this.width, this.height, this.bytes);

  final int width;
  final int height;
  final Uint8List bytes;
}

Future<_Rgba> _decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final image = (await codec.getNextFrame()).image;
  final data = await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  final out = _Rgba(image.width, image.height, data!.buffer.asUint8List());
  image.dispose();
  return out;
}

/// An image from straight (not premultiplied) RGBA bytes.
Future<ui.Image> _imageOf(Uint8List rgba, int width, int height) async {
  final premultiplied = Uint8List.fromList(rgba);
  for (var i = 0; i < premultiplied.length; i += 4) {
    final a = premultiplied[i + 3];
    if (a != 255) {
      premultiplied[i] = premultiplied[i] * a ~/ 255;
      premultiplied[i + 1] = premultiplied[i + 1] * a ~/ 255;
      premultiplied[i + 2] = premultiplied[i + 2] * a ~/ 255;
    }
  }
  final descriptor = ui.ImageDescriptor.raw(
    await ui.ImmutableBuffer.fromUint8List(premultiplied),
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  return (await (await descriptor.instantiateCodec()).getNextFrame()).image;
}

/// The bounding box (x, y, width, height) of the pixels that are not black,
/// and that part of [frame] halved by area averaging; a black frame gives
/// its top-left 2x2 halved to 1x1, as Python's `frame[:2, :2]`.
(List<int>, _Rgba) _cropAndHalve(_Rgba frame) {
  var x0 = frame.width;
  var y0 = frame.height;
  var x1 = -1;
  var y1 = -1;
  for (var y = 0; y < frame.height; y++) {
    for (var x = 0; x < frame.width; x++) {
      final i = 4 * (y * frame.width + x);
      if (frame.bytes[i] != 0 ||
          frame.bytes[i + 1] != 0 ||
          frame.bytes[i + 2] != 0) {
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
  }
  if (x1 < 0) {
    (x0, y0, x1, y1) = (0, 0, 1, 1);
  }
  final w = x1 - x0 + 1;
  final h = y1 - y0 + 1;
  final crop = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    final from = 4 * ((y0 + y) * frame.width + x0);
    crop.setRange(4 * y * w, 4 * (y + 1) * w, frame.bytes, from);
  }
  final outW = w ~/ 2 < 1 ? 1 : w ~/ 2;
  final outH = h ~/ 2 < 1 ? 1 : h ~/ 2;
  return (
    [x0, y0, w, h],
    _Rgba(outW, outH, areaResize(crop, w, h, outW, outH)),
  );
}

/// One check per case of the pack's `renders` section ([texts]: the
/// templates' JSON files, [templateTexts]); the PNGs go into [files] under
/// the name the result gives.
Future<void> runRenderChecks(
  CheckRecorder recorder,
  Map<String, dynamic> pack,
  HudKit kit,
  Map<String, String> texts,
  Map<String, Uint8List> files,
) async {
  final section = pack['renders'] as Map<String, dynamic>;
  final [frameW as int, frameH as int] = section['frame'] as List<dynamic>;
  final dives = <bool, Dive>{};
  for (final c in section['cases'] as List<dynamic>) {
    final spec = c as Map<String, dynamic>;
    final id = spec['id'] as String;
    await recorder.run('renders', 'renders/$id', () async {
      final ccr = spec['ccr'] == true;
      final dive = dives[ccr] ??= buildDummyDive(
        variant: section['dummy_variant'] as String?,
        ccr: ccr,
        // Python's sample dive, without the port's SAC (spec §10.54).
        sac: false,
      );
      final state = spec['state'] as String;
      final Waypoint waypoint;
      final List<Waypoint>? history;
      if (state.startsWith('ccr@')) {
        waypoint = waypointAt(dive, int.parse(state.substring(4)))!;
        history = dive.waypoints;
      } else {
        final (wp, h) = forcedDive(
          waypointAt(dive, section['forced_from_s'] as num),
          state,
        );
        waypoint = wp!;
        history = h;
      }
      final (layout, path) = packLayout(
        spec['template'] as List<dynamic>,
        texts,
      );
      final hudSkin = layout['hud_skin'] as Map<String, dynamic>;
      ui.Image? skin;
      (int, int)? skinSize;
      if (hudSkin['type'] != 'shape') {
        final skinPath = p.posix.normalize(
          p.posix.join(p.posix.dirname(path), hudSkin['path'] as String),
        );
        final bytes = await templateFileBytes(skinPath);
        if (bytes == null) {
          throw CheckFailure('no skin image $skinPath');
        }
        final native = await _decode(bytes);
        skinSize = (native.width, native.height);
        final scale = (hudSkin['scale'] as num?) ?? 1.0;
        final w = (native.width * scale * 1.0).truncate();
        final h = (native.height * scale * 1.0).truncate();
        skin = await _imageOf(
          areaResize(native.bytes, native.width, native.height, w, h),
          w,
          h,
        );
      }
      final ops = kit.renderer.drawHud(
        frameWidth: frameW,
        frameHeight: frameH,
        layout: layout,
        waypoint: waypoint,
        waypoints: history,
        skinSize: skinSize,
        units: normalizeUnits(spec['units']),
      );
      final pictureRecorder = ui.PictureRecorder();
      final canvas = ui.Canvas(pictureRecorder)
        ..drawRect(
          ui.Rect.fromLTWH(0, 0, frameW.toDouble(), frameH.toDouble()),
          ui.Paint()..color = const ui.Color(0xFF000000),
        );
      kit.painter.paint(
        canvas,
        ops,
        skin: skin,
        skinOpacity: ((hudSkin['opacity'] as num?) ?? 1.0).toDouble(),
      );
      skin?.dispose();
      final frame = await pictureRecorder.endRecording().toImage(
        frameW,
        frameH,
      );
      final data = await frame.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      frame.dispose();
      final (box, half) = _cropAndHalve(
        _Rgba(frameW, frameH, data!.buffer.asUint8List()),
      );
      final rgb = Uint8List(half.width * half.height * 3);
      for (var i = 0, o = 0; i < half.bytes.length; i += 4) {
        rgb[o++] = half.bytes[i];
        rgb[o++] = half.bytes[i + 1];
        rgb[o++] = half.bytes[i + 2];
      }
      // Opaque, so that the PNG holds exactly the RGB measured.
      for (var i = 3; i < half.bytes.length; i += 4) {
        half.bytes[i] = 255;
      }
      final image = await _imageOf(half.bytes, half.width, half.height);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final name = '$id.png';
      files[name] = png!.buffer.asUint8List();
      final result = <String, Object?>{
        'png': name,
        'box': box,
        'size': [half.width, half.height],
        'mean': channelMeans(rgb),
        'rgb_sha256': sha256Hex(rgb),
      };
      if (box[2] < 4 || box[3] < 4) {
        throw CheckFailure('the overlay drew (almost) nothing', result);
      }
      return result;
    });
  }
}

/// The texts of hud_rules.json and color.yaml as the app has them.
Future<(String, String)> bundledRulesAndProfiles() async => (
  await rootBundle.loadString('assets/hud_rules.json', cache: false),
  await rootBundle.loadString('assets/color.yaml', cache: false),
);
