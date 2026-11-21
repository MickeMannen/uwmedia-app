/// The overlay layers of a video run (Python `ffmpeg/hud_layers.py`).
///
/// An overlay only changes when the dive sample does (samples are 1 to 10
/// seconds apart), so each layer is drawn once per sample as a transparent
/// picture instead of onto every frame. ffmpeg reads each layer's
/// pictures through a concat list, one entry per run of frames that show
/// the same sample, and lays them over the footage itself.
///
/// A layer's transparency comes from drawing it twice, on black and on
/// white: every element is blended linearly onto the frame, so the
/// difference between the two is how much of the background shows
/// through.
library;

import 'dart:typed_data';

import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/util/json_tree.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

/// The room around a layer's skin for elements drawn past its edge, tried
/// in order: a layer whose drawing reaches the canvas edge is drawn again
/// on the next one, and at last on the whole frame.
const canvasPads = [64, 256];

/// A run of frames that show the same dive sample.
typedef HudSegment = (Waypoint? waypoint, int startFrame, int frameCount);

/// The runs of frames of a clip that show the same dive sample: the same
/// lookup per frame as drawing the overlay onto every frame would do. A
/// frame further than [sampleReach] from the dive has none (its values
/// are "--").
/// [start] is the time of the first frame on the dive computer's clock.
List<HudSegment> hudSegments(
  Dive dive,
  DateTime start,
  double fps,
  int totalFrames,
) {
  assert(start.isUtc, naiveTimeMessage);
  final segments = <HudSegment>[];
  for (var i = 0; i < totalFrames; i++) {
    // As Python's timedelta(seconds=…): whole microseconds, a half to the
    // even one.
    final seconds = i / fps;
    final whole = seconds.truncate();
    final micros = whole * 1000000 + pyRound((seconds - whole) * 1e6);
    final wp = dive.getWaypointNear(start.add(Duration(microseconds: micros)));
    if (segments.isNotEmpty && identical(segments.last.$1, wp)) {
      final (_, first, count) = segments.last;
      segments[segments.length - 1] = (wp, first, count + 1);
    } else {
      segments.add((wp, i, 1));
    }
  }
  return segments;
}

/// A run of frames to draw: the sample it shows, and the video time its
/// flashing values are drawn at (`null`: the sample draws nothing that
/// flashes).
typedef FlashSegment = (
  Waypoint? waypoint,
  int startFrame,
  int frameCount,
  double? flashAt,
);

/// The video time of the half second a flashing value is shown in its
/// flashing colour, and of the half second it is not.
const flashOn = 0.0;
const flashOff = 0.5;

/// [segments] with each one whose drawing [flashes] cut at the half
/// seconds of the clip's own time (frame 0 is 0 s): a flashing value
/// shows its flashing colour in the first half of each second and its
/// own in the second (spec §10 issue 9, owner 2026-11-19). A segment that
/// does not flash stays whole.
List<FlashSegment> flashSegments(
  List<HudSegment> segments,
  double fps,
  bool Function(Waypoint? waypoint) flashes,
) {
  final out = <FlashSegment>[];
  for (final (waypoint, first, count) in segments) {
    if (count < 1 || fps <= 0 || !flashes(waypoint)) {
      out.add((waypoint, first, count, null));
      continue;
    }
    for (var i = first; i < first + count; i++) {
      final at = (i * 2 / fps).floor().isEven ? flashOn : flashOff;
      if (out.isNotEmpty &&
          identical(out.last.$1, waypoint) &&
          out.last.$4 == at &&
          out.last.$2 + out.last.$3 == i) {
        final (_, start, frames, _) = out.last;
        out[out.length - 1] = (waypoint, start, frames + 1, at);
      } else {
        out.add((waypoint, i, 1, at));
      }
    }
  }
  return out;
}

final _f32 = Float32List(1);
double _f(double x) {
  _f32[0] = x;
  return _f32[0];
}

int _rint(double x) => pyRound(x);

/// BGRA from the same picture drawn on black and on white ([onBlack] and
/// [onWhite], three bytes a pixel): alpha is how little of the background
/// shows through, the colour is not premultiplied. The arithmetic is
/// NumPy's, in 32-bit floats.
Uint8List matte(Uint8List onBlack, Uint8List onWhite) {
  assert(
    onBlack.length == onWhite.length && onBlack.length % 3 == 0,
    'two BGR pictures of one size',
  );
  final pixels = onBlack.length ~/ 3;
  final out = Uint8List(pixels * 4);
  final tiny = _f(1e-6);
  for (var p = 0; p < pixels; p++) {
    final i = p * 3;
    final sum =
        (onWhite[i] - onBlack[i]) +
        (onWhite[i + 1] - onBlack[i + 1]) +
        (onWhite[i + 2] - onBlack[i + 2]);
    final mean = _f(sum / 3.0);
    var alpha = _f(1.0 - _f(mean / 255.0));
    alpha = alpha < 0 ? 0.0 : (alpha > 1 ? 1.0 : alpha);
    for (var c = 0; c < 3; c++) {
      final colour = alpha > 0
          ? _f(onBlack[i + c] / (alpha > tiny ? alpha : tiny))
          : 0.0;
      final rounded = _rint(colour);
      out[p * 4 + c] = rounded < 0 ? 0 : (rounded > 255 ? 255 : rounded);
    }
    out[p * 4 + 3] = _rint(_f(alpha * 255.0));
  }
  return out;
}

// The next double after x in the direction of `toward`.
double _nextAfter(double x, double toward) {
  if (x.isNaN || toward.isNaN || x == toward) {
    return x;
  }
  final data = ByteData(8)..setFloat64(0, x);
  if (x == 0) {
    data.setUint64(0, 1);
    return toward > 0 ? data.getFloat64(0) : -data.getFloat64(0);
  }
  final bits = data.getUint64(0);
  data.setUint64(0, (toward > x) == (x > 0) ? bits + 1 : bits - 1);
  return data.getFloat64(0);
}

/// The `design_width` that makes the renderer's scale (canvas width over
/// design width) come out exactly the whole frame's, so that every size it
/// truncates is the same on the canvas.
double canvasDesignWidth(int canvasW, double resScale) {
  var width = canvasW / resScale;
  for (var i = 0; i < 8; i++) {
    final got = canvasW / width;
    if (got == resScale) {
      break;
    }
    width = _nextAfter(width, got < resScale ? 0.0 : double.infinity);
  }
  return width;
}

/// One overlay as the renderer draws it on a frame, kept on the smallest
/// canvas that holds it. [resolved] marks a layout placed by
/// `resolveOverlayInstanceLayout` (anchored top left, with offsets), whose
/// skin position is known and which can be drawn on a cropped canvas; any
/// other layout is drawn on the whole frame.
class HudLayerCanvas {
  HudLayerCanvas(
    this.layout, {
    required this.frameW,
    required this.frameH,
    required bool resolved,
    this.skinSize,
  }) {
    fullFrame();
    if (resolved) {
      _cropToSkin(canvasPads.first);
    }
  }

  final Map<String, dynamic> layout;
  final int frameW;
  final int frameH;

  /// The size of the skin image as it is drawn (already scaled); `null`
  /// for a shape skin or an image that could not be read.
  final (int w, int h)? skinSize;

  int _padIndex = 0;

  /// The part of the frame the canvas covers: left, top, right, bottom.
  late (int, int, int, int) region;

  /// The layout to draw on the canvas: the layer's own on the whole frame,
  /// a copy moved to the canvas otherwise.
  late Map<String, dynamic> canvasLayout;

  /// How many times the canvas has been widened.
  int get padIndex => _padIndex;

  bool get isFullFrame => region == (0, 0, frameW, frameH);

  void fullFrame() {
    region = (0, 0, frameW, frameH);
    canvasLayout = layout;
  }

  void _cropToSkin(int pad) {
    final skin = layout['hud_skin'] as Map<String, dynamic>? ?? const {};
    num number(String key, num fallback) {
      final value = skin[key];
      return value is num ? value : fallback;
    }

    final rawWidth = layout['design_width'];
    final designW = (rawWidth is num ? rawWidth : 1920).toDouble();
    final resScale = frameW / designW;
    final int wHud;
    final int hHud;
    if ((skin['type'] ?? 'image') == 'shape') {
      wHud = (number('width', 400) * resScale).truncate();
      hHud = (number('height', 200) * resScale).truncate();
    } else if (skinSize != null) {
      (wHud, hHud) = skinSize!;
    } else {
      return;
    }
    final skinX = (number('ref_offset_x', 0.0) * resScale).truncate();
    final skinY = (number('ref_offset_y', 0.0) * resScale).truncate();
    final x0 = skinX - pad < 0 ? 0 : skinX - pad;
    final y0 = skinY - pad < 0 ? 0 : skinY - pad;
    final x1 = skinX + wHud + pad > frameW ? frameW : skinX + wHud + pad;
    final y1 = skinY + hHud + pad > frameH ? frameH : skinY + hHud + pad;
    if (x1 <= x0 || y1 <= y0) {
      return;
    }
    final canvas = jsonCopyMap(layout);
    canvas['design_width'] = canvasDesignWidth(x1 - x0, resScale);
    // The millionth: the renderer's truncation must land on the moved
    // pixel, not one short.
    (canvas['hud_skin'] as Map<String, dynamic>)
      ..['ref_offset_x'] = (skinX - x0 + 1e-6) / resScale
      ..['ref_offset_y'] = (skinY - y0 + 1e-6) / resScale;
    region = (x0, y0, x1, y1);
    canvasLayout = canvas;
  }

  /// Whether a drawing (BGRA, the size of [region]) touches a canvas edge
  /// that is not also a frame edge, so that a draw on the whole frame
  /// might have drawn past it. Then [widen] and draw again.
  bool reachesCanvasEdge(Uint8List bgra) {
    final (x0, y0, x1, y1) = region;
    final w = x1 - x0;
    final h = y1 - y0;
    bool column(int x) =>
        Iterable<int>.generate(h).any((y) => bgra[(y * w + x) * 4 + 3] != 0);
    bool row(int y) =>
        Iterable<int>.generate(w).any((x) => bgra[(y * w + x) * 4 + 3] != 0);
    return (x0 > 0 && column(0)) ||
        (y0 > 0 && row(0)) ||
        (x1 < frameW && column(w - 1)) ||
        (y1 < frameH && row(h - 1));
  }

  /// The next bigger canvas after the drawing reached this one's edge.
  void widen() {
    _padIndex += 1;
    fullFrame();
    if (_padIndex < canvasPads.length) {
      _cropToSkin(canvasPads[_padIndex]);
    }
  }
}

/// The name of the [number]-th picture of layer [index].
String layerPngName(int index, int number) =>
    'hud${index}_${number.toString().padLeft(5, '0')}.png';

/// The name of layer [index]'s concat list.
String layerConcatName(int index) => 'hud$index.ffconcat';

/// The pictures a layer's stream is made of, from the picture of every
/// segment (BGRA) and the segment's length in frames: a segment that
/// draws the same as the one before only makes that one longer. Gives the
/// index of the segment whose picture is kept and the frames it is shown
/// for; nothing when the layer draws nothing in the whole clip.
List<(int segment, int frames)> layerEntries(
  List<Uint8List> pictures,
  List<int> frameCounts,
) {
  final entries = <(int, int)>[];
  var drew = false;
  Uint8List? previous;
  for (final (i, picture) in pictures.indexed) {
    if (!drew) {
      for (var a = 3; a < picture.length; a += 4) {
        if (picture[a] != 0) {
          drew = true;
          break;
        }
      }
    }
    if (previous != null && _sameBytes(picture, previous)) {
      final (segment, frames) = entries.last;
      entries[entries.length - 1] = (segment, frames + frameCounts[i]);
    } else {
      entries.add((i, frameCounts[i]));
      previous = picture;
    }
  }
  return drew ? entries : [];
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

/// The text of a layer's concat list: each picture's path (with forward
/// slashes, for which [windowsPaths] says the paths are Windows') and how
/// long it is shown. The last picture's time is cut
/// short by ffmpeg, but the overlay keeps it on screen to the end of the
/// clip (`eof_action=repeat`).
String ffconcatText(
  List<(String pngPath, int frames)> entries,
  double fps, {
  bool windowsPaths = false,
}) {
  final lines = ['ffconcat version 1.0'];
  for (final (path, frames) in entries) {
    // Only a Windows path has backslashes between its folders.
    final quoted = (windowsPaths ? path.replaceAll(r'\', '/') : path)
        .replaceAll("'", r"'\''");
    lines
      ..add("file '$quoted'")
      ..add('duration ${pyFormatFixed(frames / fps, 6)}');
  }
  return '${lines.join('\n')}\n';
}
