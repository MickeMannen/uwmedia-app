/// The canvas of a telemetry-only render (Python `cli_main.py`'s
/// `overlay_canvas`): how big the frames are and in which of the
/// renderer's two modes the overlay is drawn on them.
library;

import 'package:uwmedia_app/core/naming/output_naming.dart';
import 'package:uwmedia_app/core/util/json_tree.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

/// The sizes a telemetry-only render comes in, and how much each
/// enlarges the template: its own size in the 1920x1080 design frame, or
/// twice that for 4K footage, so that the overlay drops onto 4K footage
/// one to one.
const overlaySizes = {'1080p': 1.0, '4k': 2.0};

/// Whether a format of a telemetry-only render carries transparency.
bool overlayHasAlpha(String format) =>
    format == overlayFormatProres || format == overlayFormatPng;

/// A side of a canvas: a whole, even number of pixels, two at least
/// (video encoders want even sides).
int evenSide(num value) {
  final whole = pyRound(value.toDouble());
  final side = whole < 2 ? 2 : whole;
  return side.isOdd ? side + 1 : side;
}

num _number(Map<String, dynamic> map, String key, num fallback) =>
    map[key] is num ? map[key] as num : fallback;

/// The canvas for a telemetry-only render of [layout]: its size, whether
/// the overlay is drawn in the renderer's telemetry-only mode
/// (`renderLog`), and the layout to draw (a copy; [layout] is left alone).
///
/// Without [fullFrame] the skin is the frame: the layout's anchor and
/// offsets are taken out, everything is enlarged by [size]'s factor
/// through the skin's scale, and the canvas is the skin's size
/// ([skinSize] is the skin image's own size; without one, for an image
/// skin, the canvas is the design frame). With [fullFrame] the canvas is
/// the whole design frame (1920x1080, or twice that at "4k") and the
/// overlay is drawn where the layout anchors it, so that there is nothing
/// to place in the editor.
({int width, int height, bool renderLog, Map<String, dynamic> layout})
overlayCanvas(
  Map<String, dynamic> layout, {
  String? size,
  bool fullFrame = false,
  (int, int)? skinSize,
}) {
  final factor = overlaySizes[(size ?? '1080p').toLowerCase()] ?? 1.0;
  final copy = jsonCopyMap(layout);
  final existing = copy['hud_skin'];
  final hudSkin = existing is Map<String, dynamic>
      ? existing
      : (copy['hud_skin'] = <String, dynamic>{});
  if (fullFrame) {
    return (
      width: evenSide(_number(copy, 'design_width', 1920).toDouble() * factor),
      height: evenSide(
        _number(copy, 'design_height', 1080).toDouble() * factor,
      ),
      renderLog: false,
      layout: copy,
    );
  }
  final userScale = _number(hudSkin, 'scale', 1.0).toDouble() * factor;
  hudSkin
    ..['anchor'] = 'CENTER'
    ..['ref_offset_x'] = 0.0
    ..['ref_offset_y'] = 0.0
    ..['scale'] = userScale;
  final int width;
  final int height;
  if ((hudSkin['type'] ?? 'image') == 'shape') {
    final w = _number(hudSkin, 'width', 400).toDouble() * factor;
    final h = _number(hudSkin, 'height', 200).toDouble() * factor;
    hudSkin
      ..['width'] = w
      ..['height'] = h;
    (width, height) = (evenSide(w), evenSide(h));
  } else if (skinSize == null) {
    (width, height) = (evenSide(1920 * factor), evenSide(1080 * factor));
  } else {
    (width, height) = (
      evenSide(skinSize.$1 * userScale),
      evenSide(skinSize.$2 * userScale),
    );
  }
  return (width: width, height: height, renderLog: true, layout: copy);
}
