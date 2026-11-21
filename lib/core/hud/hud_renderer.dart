/// The overlay renderer, ported from `gui/hud_renderer.py` of the Python
/// app (spec §5): a layout, a waypoint and the dive in, the list of drawing
/// operations out ([HudOp]). It works out every position and size the way
/// the Python renderer does (the same truncations, the same rounding, the
/// same order) and draws nothing itself; a painter turns the list into
/// pixels, and the Overlay Designer reads its geometry.
///
/// Per frame: the skin, then every graph, then one pass over the elements
/// in their order (graph stop labels, badges, notices, tank icons, tissue
/// bars, arc gauges and segment bars, chevrons, tank switch arrows, text),
/// then the clip to the skin's `screen` when it has one.
///
/// Differences from Python, both where Python fails: a waypoint without a
/// depth counts as the surface in a graph (the port's model has `null`
/// where Python's parsers store 0.0, spec §10.8), and a missing waypoint
/// draws its "--" texts instead of raising.
library;

import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/hud_geometry.dart';
import 'package:uwmedia_app/core/hud/hud_ops.dart';
import 'package:uwmedia_app/core/hud/hud_text.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/rules/hud_notices.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/units/units.dart' as u;
import 'package:uwmedia_app/core/units/units.dart' show UnitSystem;
import 'package:uwmedia_app/core/util/py_parse.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

const Rgb _black = (0, 0, 0);
const Rgb _white = (255, 255, 255);

int _max(int a, int b) => a > b ? a : b;
int _min(int a, int b) => a < b ? a : b;
int _floorDiv(num a, num b) => (a / b).floor();
int _round(num x) => pyRound(x.toDouble());

/// Where the skin sits in the frame and at what scale its elements draw.
class SkinInfo {
  const SkinInfo({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.resScale,
    required this.userScale,
    required this.renderLog,
  });

  final int x;
  final int y;
  final int w;
  final int h;

  /// Frame width over design width; 1 in the telemetry-only mode.
  final double resScale;

  /// `hud_skin.scale`.
  final num userScale;
  final bool renderLog;

  /// Skin pixels to frame pixels.
  double get scale => renderLog ? userScale.toDouble() : userScale * resScale;
}

/// Python `'X' in anchor`.
bool _anchorHas(String anchor, String part) => anchor.contains(part);

/// The skin's `screen` area ({x0, y0, x1, y1} as fractions of the skin) in
/// frame pixels, or `null` when the template defines none.
(int, int, int, int)? screenBox(
  Map<String, dynamic> hudSkin,
  int skinX,
  int skinY,
  int wHud,
  int hHud,
) {
  final screen = hudSkin['screen'];
  if (screen is! Map<String, dynamic>) {
    return null;
  }
  final values = <double>[];
  for (final key in const ['x0', 'y0', 'x1', 'y1']) {
    final value = screen.containsKey(key) ? pyFloatOf(screen[key]) : null;
    if (value == null) {
      return null;
    }
    values.add(value);
  }
  return (
    _round(skinX + values[0] * wHud),
    _round(skinY + values[1] * hHud),
    _round(skinX + values[2] * wHud),
    _round(skinY + values[3] * hHud),
  );
}

/// One overlay instance's placement on the Color page ([x], [y] the
/// skin's top left as fractions of the output frame, [scale] a multiplier)
/// as a layout [HudRenderer.drawHud] renders unchanged: a TOP_LEFT anchor
/// with the offsets in design pixels, and the scale in `hud_skin.scale`.
Map<String, dynamic> resolveOverlayInstanceLayout(
  Map<String, dynamic> layout,
  double x,
  double y,
  double scale,
  int frameW,
  int frameH,
) {
  final resolved = _deepCopy(layout) as Map<String, dynamic>;
  final hudSkin = resolved.putIfAbsent(
    'hud_skin',
    () => <String, dynamic>{},
  ) as Map<String, dynamic>;
  final designW = _number(resolved, 'design_width', 1920).toDouble();
  hudSkin['anchor'] = 'TOP_LEFT';
  hudSkin['ref_offset_x'] = x * designW;
  hudSkin['ref_offset_y'] = y * frameH * designW / frameW;
  if (hudSkin['type'] == 'shape') {
    hudSkin['width'] = _number(hudSkin, 'width', 400) * scale;
    hudSkin['height'] = _number(hudSkin, 'height', 200) * scale;
  }
  hudSkin['scale'] = _number(hudSkin, 'scale', 1.0) * scale;
  return resolved;
}

/// The pixel box (x0, y0, x1, y1) an overlay instance takes on a frame of
/// [frameW] x [frameH], placed as [resolveOverlayInstanceLayout] places it
/// (Python `overlay_pixel_bbox`): for the preview's hit test and handles.
/// [skinSize] is the skin picture's own size; an image skin without one
/// has no box (all zeros).
(int, int, int, int) overlayPixelBox(
  Map<String, dynamic> layout,
  double x,
  double y,
  double scale,
  int frameW,
  int frameH, {
  (int, int)? skinSize,
}) {
  final hudSkin = layout['hud_skin'] is Map<String, dynamic>
      ? layout['hud_skin'] as Map<String, dynamic>
      : const <String, dynamic>{};
  final resScale = frameW / _number(layout, 'design_width', 1920).toDouble();
  final int wHud;
  final int hHud;
  if ((hudSkin['type'] ?? 'image') == 'shape') {
    wHud = (_number(hudSkin, 'width', 400) * scale * resScale).truncate();
    hHud = (_number(hudSkin, 'height', 200) * scale * resScale).truncate();
  } else {
    final size = skinSize;
    if (size == null) {
      return (0, 0, 0, 0);
    }
    final userScale = _number(hudSkin, 'scale', 1.0) * scale;
    wHud = (size.$1 * userScale * resScale).truncate();
    hHud = (size.$2 * userScale * resScale).truncate();
  }
  final skinX = (x * frameW).truncate();
  final skinY = (y * frameH).truncate();
  return (skinX, skinY, skinX + wHud, skinY + hHud);
}

Object? _deepCopy(Object? value) => switch (value) {
  final Map<String, dynamic> map => <String, dynamic>{
    for (final entry in map.entries) entry.key: _deepCopy(entry.value),
  },
  final List<dynamic> list => <dynamic>[
    for (final item in list) _deepCopy(item),
  ],
  _ => value,
};

num _number(Map<String, dynamic> map, String key, num fallback) =>
    elemNum(map, key, fallback);

/// (dx, dy, bbox) to add to an element's anchor so the text's ink box is
/// aligned as asked: right and center put the ink's right edge or centre
/// on the anchor, bottom and middle its bottom edge or centre.
(double, double, (int, int, int, int)) textAnchorShift(
  HudFont font,
  String text, [
  Object? align = 'left',
  Object? valign = 'top',
]) {
  final box = font.getbbox(text);
  final (left, top, right, bottom) = box;
  final dx = align == 'center'
      ? -(left + right) / 2.0
      : align == 'right'
      ? -right.toDouble()
      : 0.0;
  final dy = valign == 'middle'
      ? -(top + bottom) / 2.0
      : valign == 'bottom'
      ? -bottom.toDouble()
      : 0.0;
  return (dx, dy, box);
}

/// (dx, dy, w, h) of a vertical text element's ink box from its anchor.
/// "stacked": one letter per line, each centred in a column as wide as the
/// widest letter; "up" and "down": the flat ink box turned on its side.
(double, double, int, int) orientedTextGeometry(
  HudFont font,
  String text,
  Object? orientation,
  int size, [
  Object? align = 'left',
  Object? valign = 'top',
]) {
  final int w;
  final int h;
  if (orientation == 'stacked') {
    var widest = 0;
    var count = 0;
    for (final rune in text.runes) {
      final (left, _, right, _) = font.getbbox(String.fromCharCode(rune));
      widest = _max(widest, right - left);
      count++;
    }
    w = widest;
    h = (size * stackedLineAdvance).truncate() * count;
  } else {
    final (left, top, right, bottom) = font.getbbox(text);
    w = bottom - top;
    h = right - left;
  }
  final dx = align == 'center'
      ? -w / 2.0
      : align == 'right'
      ? -w.toDouble()
      : 0.0;
  final dy = valign == 'middle'
      ? -h / 2.0
      : valign == 'bottom'
      ? -h.toDouble()
      : 0.0;
  return (dx, dy, w, h);
}

/// A badge line's text run: its text, the font it draws in, and whether
/// it is a small unit.
typedef BadgeRun = (String text, HudFont font, bool isUnit);

/// The deco stop markers a badge font may lack (Python `BADGE_ARROWS`).
const String badgeArrows = '↑↓';

/// The family an arrow is drawn in when the badge's font has none: Roboto
/// has the arrows Roboto Condensed lacks (Python `BADGE_ARROW_FAMILY`).
const String badgeArrowFamily = 'Roboto';

/// A unit right after a number on a badge value line: "6m", "20ft",
/// "2min" (Python `BADGE_UNIT_RE`).
final RegExp badgeUnitPattern = RegExp(r'(?<=\d)(min|ft|m)(?![A-Za-z])');

/// A badge's `unit_scale` when it sets one, else `null`.
double? badgeUnitScaleOf(Map<String, dynamic> elem) {
  final raw = elem['unit_scale'];
  return truthy(raw) ? pyFloatOf(raw) : null;
}

/// Python compares fonts by identity (`get_font` caches them); the port's
/// font objects need not be the same object for the same file and size.
bool _sameFont(HudFont a, HudFont b) => a.file == b.file && a.size == b.size;

/// The runs of a badge line (Python `_badge_font_runs`): a deco stop's ↑ /
/// ↓ marker in Roboto where the badge's own font has no arrow (Roboto
/// Condensed), and with [unitScale] the units after its numbers ("6m
/// 2min") in the same font at that share of the size (Peregrine and Teric
/// manuals: small cyan m / min).
List<BadgeRun> badgeFontRuns(
  HudFonts fonts,
  String text,
  HudFont font,
  int size,
  Object? weight, [
  double? unitScale,
]) {
  var segments = <(String, bool)>[(text, false)];
  if (unitScale != null && unitScale != 0) {
    segments = [];
    var pos = 0;
    for (final m in badgeUnitPattern.allMatches(text)) {
      if (m.start > pos) {
        segments.add((text.substring(pos, m.start), false));
      }
      segments.add((m.group(0)!, true));
      pos = m.end;
    }
    if (pos < text.length) {
      segments.add((text.substring(pos), false));
    }
  }
  final runs = <BadgeRun>[];
  for (final (segment, isUnit) in segments) {
    if (isUnit) {
      runs.add((
        segment,
        fonts.font(_max(1, _round(size * unitScale!)), font.file),
        true,
      ));
      continue;
    }
    if (!segment.runes.any((r) => badgeArrows.runes.contains(r))) {
      runs.add((segment, font, false));
      continue;
    }
    for (final rune in segment.runes) {
      final char = String.fromCharCode(rune);
      final f = badgeArrows.contains(char) && !font.hasGlyph(char)
          ? fonts.get(size, badgeArrowFamily, weight)
          : font;
      if (runs.isNotEmpty && _sameFont(runs.last.$2, f) && !runs.last.$3) {
        runs.last = (runs.last.$1 + char, f, false);
      } else {
        runs.add((char, f, false));
      }
    }
  }
  return runs;
}

/// (left, right) of a badge line's ink from its draw x, with the check
/// mark stroked in front of a [checkMark] line included, so a value line
/// can be centred under the whole title (and a "✓ 2:59" timer under its
/// title). A check mark inside the line ("6m✓ 2min") is stepped over the
/// way the badge draws it, and with [unitScale] the small units are
/// measured at their own size.
(double, double) badgeTitleInkSpan(
  HudFonts fonts,
  HudFont font,
  String text,
  int size, [
  double? unitScale,
]) {
  final w = (size * 0.9).truncate();
  double? left;
  var right = 0.0;
  var x = 0.0;
  final pieces = text.split(checkMark.trim());
  for (var i = 0; i < pieces.length; i++) {
    var piece = pieces[i];
    if (i != 0) {
      // The stroke's half width reaches left of its first point.
      left ??= ((w * 0.05).truncate() - _max(2, (size / 8).truncate()) ~/ 2)
          .toDouble();
      if (x + w > right) {
        right = x + w;
      }
      x += w + (size * 0.35).truncate();
      piece = piece.replaceFirst(RegExp('^ +'), '');
    }
    if (piece.isEmpty) {
      continue;
    }
    for (final (run, runFont, _) in badgeFontRuns(
      fonts,
      piece,
      font,
      size,
      null,
      unitScale,
    )) {
      final (runLeft, _, runRight, _) = runFont.getbbox(run);
      left ??= x + runLeft;
      right = x + runRight;
      x += runFont.getlength(run);
    }
  }
  return (left ?? 0.0, right);
}

/// (dx, left, right) of one badge line: the shift that puts its ink on
/// the element's anchor for [align], and its ink span from the draw x. A
/// line with small units ([unitScale]) is measured as drawn; other lines
/// keep the plain text box. Shared by the renderer and the designer.
(double, double, double) badgeLineAnchor(
  HudFonts fonts,
  HudFont font,
  String text,
  int size,
  Object? align, [
  double? unitScale,
]) {
  if (unitScale != null && unitScale != 0) {
    final (left, right) = badgeTitleInkSpan(fonts, font, text, size, unitScale);
    final dx = align == 'center'
        ? -(left + right) / 2.0
        : align == 'right'
        ? -right
        : 0.0;
    return (dx, left, right);
  }
  final (dx, _, (left, _, right, _)) = textAnchorShift(font, text, align);
  return (dx, left.toDouble(), right.toDouble());
}

/// The font size (px) a badge line draws at: [size], or smaller when the
/// element has a `max_width` (skin px, before the skin scale [pxScale])
/// and the line, check mark included, is wider (a deco stop's "6m✓ 2min"
/// in the panel a "3:00" fills). Shared by the renderer and the designer.
int fittedBadgeLineSize(
  HudFonts fonts,
  Map<String, dynamic> elem,
  String text,
  int size, [
  double pxScale = 1.0,
  double? unitScale,
]) {
  final raw = elem['max_width'];
  final limit = truthy(raw) ? pyFloatOf(raw) : 0.0;
  if (limit == null) {
    return size;
  }
  final maxW = limit * pxScale;
  if (maxW <= 0 || size <= 1) {
    return size;
  }
  double width(int px) {
    final (left, right) = badgeTitleInkSpan(
      fonts,
      fonts.get(px, elem['font_family'], elem['font_weight']),
      text,
      px,
      unitScale,
    );
    return right - left;
  }

  if (width(size) <= maxW) {
    return size;
  }
  var lo = 1;
  var hi = size;
  while (lo < hi) {
    final mid = (lo + hi + 1) ~/ 2;
    if (width(mid) <= maxW) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

/// (label px, value px): the final sizes of a badge's two font tiers.
(int, int) badgeLineSizes(Map<String, dynamic> elem, SkinInfo skin) {
  final base = _number(elem, 'font_size', 16);
  final value = _number(elem, 'value_font_size', base);
  final itemScale = _number(elem, 'scale', 1.0);
  int scaled(num size) => _max(
    1,
    (skin.renderLog
            ? size * skin.userScale * itemScale
            : size * skin.userScale * skin.resScale * itemScale)
        .truncate(),
  );
  return (scaled(base), scaled(value));
}

List<String> _words(String text) => [
  for (final word in text.split(RegExp(r'\s+')))
    if (word.isNotEmpty) word,
];

/// The renderer for one set of fonts and rules.
class HudRenderer {
  HudRenderer(this.fonts, this.rules);

  final HudFonts fonts;

  /// The app's rules; a page's own `rules` block is laid over them per
  /// render.
  final HudRules rules;

  /// The font size (px) a text element draws at: [size], or smaller when
  /// the element has a `max_width` (skin px) and the value with its small
  /// suffix, and the unit drawn after it, is wider than that.
  int fittedFontSize(
    Map<String, dynamic> elem,
    int size,
    String mainStr, {
    String suffixStr = '',
    double suffixScale = 1.0,
    double pxScale = 1.0,
    String unitText = '',
  }) {
    final raw = elem['max_width'];
    final limit = truthy(raw) ? pyFloatOf(raw) : 0.0;
    if (limit == null) {
      return size;
    }
    final maxW = limit * pxScale;
    if (maxW <= 0 || size <= 1 || mainStr.isEmpty) {
      return size;
    }
    final family = elem['font_family'];
    final weight = elem['font_weight'];
    final unitAfter =
        unitText.isNotEmpty &&
        (_get(elem, 'unit_position', 'right') != 'below' || suffixStr.isEmpty);
    final unitScale = _number(elem, 'unit_scale', 0.35).toDouble();

    double width(int px) {
      var w = fonts.get(px, family, weight).getlength(mainStr);
      if (suffixStr.isNotEmpty) {
        w += fonts
            .get(_max(1, _round(px * suffixScale)), family, weight)
            .getlength(suffixStr);
      }
      if (unitAfter) {
        final HudFont unitFont;
        if (elem['unit_span'] == 'digits' &&
            elem['unit_orientation'] == 'stacked') {
          unitFont = fonts.get(
            digitSpanUnitSize(
              fonts.get(px, family, weight),
              unitText,
              family,
              weight,
            ),
            family,
            weight,
          );
        } else {
          unitFont = fonts.get(
            _max(1, (px * unitScale).truncate()),
            family,
            weight,
          );
        }
        if (elem['unit_orientation'] == 'stacked') {
          // One letter wide.
          var widest = 0.0;
          for (final rune in unitText.runes) {
            final l = unitFont.getlength(String.fromCharCode(rune));
            if (l > widest) {
              widest = l;
            }
          }
          w += (px * 0.08).truncate() + widest;
        } else {
          w += (px * 0.08).truncate() + unitFont.getlength(unitText);
        }
      }
      return w;
    }

    if (width(size) <= maxW) {
      return size;
    }
    var lo = 1;
    var hi = size;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (width(mid) <= maxW) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return _max(1, lo);
  }

  /// The font size at which [unitText], stacked one letter per line, runs
  /// from the top of [font]'s digits to their baseline
  /// (gui/hud_renderer.py `digit_span_unit_size`).
  int digitSpanUnitSize(
    HudFont font,
    String unitText,
    Object? family,
    Object? weight,
  ) {
    final (_, digitTop, _, digitBottom) = font.getbbox('0');
    const probe = 100;
    final probeFont = fonts.get(probe, family, weight);
    var letterH = 0;
    var first = true;
    for (final rune in unitText.runes) {
      final (_, top, _, bottom) = probeFont.getbbox(String.fromCharCode(rune));
      if (first || bottom - top > letterH) {
        letterH = bottom - top;
        first = false;
      }
    }
    final span =
        (unitText.runes.length - 1) * (probe * stackedLineAdvance).truncate() +
        letterH;
    return _max(1, (probe * (digitBottom - digitTop) / span).truncate());
  }

  /// (x, y, unit font, unit size) for the unit drawn after a value: to the
  /// right of the value's run on its baseline, or below its small part
  /// (with no small part it goes after the value). x is in frame pixels, y
  /// from the element's own y. A stacked unit with `"unit_span": "digits"`
  /// is sized so its letters run from the digits' top to their baseline (a
  /// Shearwater's B/A/R beside the tank pressure, Perdix 2 manual p.40);
  /// `unit_dx` still moves it.
  (double, double, HudFont, int) unitSuffixGeometry(
    Map<String, dynamic> elem,
    HudFont font,
    String mainText,
    int size,
    double runRight,
    double? suffixX,
    double pxScale, [
    String unitText = '',
  ]) {
    final family = elem['font_family'];
    final weight = elem['font_weight'];
    final dx = _number(elem, 'unit_dx', 0.0).toDouble() * pxScale;
    if (elem['unit_span'] == 'digits' &&
        elem['unit_orientation'] == 'stacked' &&
        unitText.isNotEmpty) {
      final unitSize = digitSpanUnitSize(font, unitText, family, weight);
      return (
        runRight + (size * 0.06).truncate() + dx,
        font.getbbox('0').$2.toDouble(),
        fonts.get(unitSize, family, weight),
        unitSize,
      );
    }
    final scale = _number(elem, 'unit_scale', 0.35).toDouble();
    final unitSize = _max(1, (size * scale).truncate());
    final unitFont = fonts.get(unitSize, family, weight);
    final dy = _number(elem, 'unit_dy', 0.0).toDouble() * pxScale;
    final mainBottom = font.getbbox(mainText).$4;
    final unitBottom = unitFont.getbbox('m').$4;
    final below = _get(elem, 'unit_position', 'right') == 'below';
    final double x;
    final double y;
    if (below && suffixX != null) {
      x = suffixX + dx;
      y = mainBottom + (size * 0.08).truncate() + dy;
    } else if (below) {
      // Nothing small to sit under (whole feet on a Shearwater): after the
      // value instead, the offsets left out.
      x = runRight + (size * 0.08).truncate();
      y = (mainBottom - unitBottom).toDouble();
    } else {
      x = runRight + (size * 0.08).truncate() + dx;
      // Baselines together.
      y = mainBottom - unitBottom + dy;
    }
    return (x, y, unitFont, unitSize);
  }

  /// Extra x shift for a right or centre aligned value whose `align_unit`
  /// puts the unit drawn after it inside the aligned run (a Peregrine's
  /// "45ft" ends where "15.7m" does); 0 otherwise, and for a unit under the
  /// decimals, which sits inside the run already.
  double unitAlignShift(
    Map<String, dynamic> elem,
    HudFont font,
    String mainText,
    String suffixText,
    HudFont? suffixFont,
    int size,
    String unitText,
    Object? align,
    double pxScale,
  ) {
    if (!(truthy(elem['align_unit']) &&
        unitText.isNotEmpty &&
        (align == 'right' || align == 'center'))) {
      return 0.0;
    }
    var runRight = font.getlength(mainText);
    double? suffixX;
    if (suffixFont != null) {
      final rawDx = elem['small_suffix_dx'];
      suffixX =
          runRight + (truthy(rawDx) ? pyFloatOf(rawDx) ?? 0.0 : 0.0) * pxScale;
      runRight = suffixX + suffixFont.getlength(suffixText);
    }
    final (x, _, unitFont, _) = unitSuffixGeometry(
      elem,
      font,
      mainText,
      size,
      runRight,
      suffixX,
      pxScale,
      unitText,
    );
    final over = x + unitFont.getlength(unitText) - runRight;
    final extra = over > 0 ? over : 0.0;
    return align == 'right' ? -extra : -extra / 2.0;
  }

  /// The drawing of [layout] at [waypoint] on a frame of [frameWidth] x
  /// [frameHeight].
  ///
  /// [skinSize] is the skin image's own size in pixels (not needed for a
  /// shape skin); without it an image skin draws nothing, as when Python
  /// cannot read the image. [renderLog] is the telemetry-only mode: the
  /// skin at the frame's corner and no frame scaling. [units] is the unit
  /// system in force; a layout's own `units` key wins. [flashAt] is the
  /// video's own time, which flashing values follow (see
  /// [HudContext.flashAt]); without it they show the flashing colour.
  List<HudOp> drawHud({
    required int frameWidth,
    required int frameHeight,
    required Map<String, dynamic> layout,
    required Waypoint? waypoint,
    List<Waypoint>? waypoints,
    (int, int)? skinSize,
    bool renderLog = false,
    UnitSystem units = UnitSystem.metric,
    double? flashAt,
  }) {
    final ops = <HudOp>[];
    final hudSkin = layout['hud_skin'] is Map<String, dynamic>
        ? layout['hud_skin'] as Map<String, dynamic>
        : const <String, dynamic>{};

    // Universal scaling factor (base 1920 px).
    final designW = _number(layout, 'design_width', 1920).toDouble();
    final resScale = renderLog ? 1.0 : frameWidth / designW;
    final isShape = _get(hudSkin, 'type', 'image') == 'shape';
    final skinOpacity = _number(hudSkin, 'opacity', 1.0).toDouble();
    final userScale = _number(hudSkin, 'scale', 1.0);

    final int wHud;
    final int hHud;
    if (isShape) {
      wHud = (_number(hudSkin, 'width', 400) * resScale).truncate();
      hHud = (_number(hudSkin, 'height', 200) * resScale).truncate();
    } else {
      if (!truthy(hudSkin['path']) || skinSize == null) {
        return ops;
      }
      wHud = (skinSize.$1 * userScale * resScale).truncate();
      hHud = (skinSize.$2 * userScale * resScale).truncate();
    }

    // The frame side the anchor names, and the same corner of the HUD.
    final anchor = '${_get(hudSkin, 'anchor', 'TOP_LEFT')}';
    var baseX = 0.0;
    var baseY = 0.0;
    var pivotX = 0.0;
    var pivotY = 0.0;
    if (_anchorHas(anchor, 'CENTER')) {
      baseX = frameWidth / 2.0;
      pivotX = wHud / 2.0;
    } else if (_anchorHas(anchor, 'RIGHT')) {
      baseX = frameWidth.toDouble();
      pivotX = wHud.toDouble();
    }
    if (_anchorHas(anchor, 'MIDDLE')) {
      baseY = frameHeight / 2.0;
      pivotY = hHud / 2.0;
    } else if (_anchorHas(anchor, 'BOTTOM')) {
      baseY = frameHeight.toDouble();
      pivotY = hHud.toDouble();
    }
    final refX = _number(hudSkin, 'ref_offset_x', 0.0);
    final refY = _number(hudSkin, 'ref_offset_y', 0.0);
    final skinX = renderLog
        ? 0
        : (baseX + (refX * resScale) - pivotX).truncate();
    final skinY = renderLog
        ? 0
        : (baseY + (refY * resScale) - pivotY).truncate();

    if (isShape) {
      final radius = (_number(hudSkin, 'corner_radius', 20) * resScale)
          .truncate();
      ops.add(
        BlendOp(skinOpacity, [
          CvRoundedRectOp(
            skinX,
            skinY,
            skinX + wHud,
            skinY + hHud,
            hexRgb('${_get(hudSkin, 'color', '#000000')}'),
            -1,
            radius,
          ),
        ]),
      );
    }

    final skin = SkinInfo(
      x: skinX,
      y: skinY,
      w: wHud,
      h: hHud,
      resScale: resScale,
      userScale: userScale,
      renderLog: renderLog,
    );
    ops.add(SkinOp(skinX, skinY, wHud, hHud));
    _Pass(
      this,
      HudContext.of(layout, rules, units, flashAt: flashAt),
      skin,
      ops,
    ).drawTelemetry(layout, waypoint, waypoints);
    final screen = screenBox(hudSkin, skinX, skinY, wHud, hHud);
    if (screen != null) {
      // Nothing is drawn outside the computer's screen: whatever the
      // elements put on the bezel is undone, as where the glass ends.
      final shape = hudSkin['screen'] as Map<String, dynamic>;
      ops.add(
        ClipOp(
          screen.$1,
          screen.$2,
          screen.$3,
          screen.$4,
          '${_get(shape, 'shape', 'rect')}',
        ),
      );
    }
    return ops;
  }
}

/// Python `map.get(key, fallback)`.
Object? _get(Map<String, dynamic> map, String key, Object? fallback) =>
    map.containsKey(key) ? map[key] : fallback;

/// What a notice element draws: (caption, confirm, message, style) with
/// the texts resolved from the element and the brand's `notice_style`.
(String, String, String, Map<String, dynamic>) noticeLines(
  HudContext ctx,
  Map<String, dynamic> elem,
  Notice notice,
) {
  final style = noticeStyle(ctx.rules, ctx.manufacturer, ctx.model);
  style['style'] = truthy(elem['style'])
      ? elem['style']
      : _get(style, 'style', 'text');
  final confirm = elem['confirm_text'] ?? _get(style, 'confirm_text', '');
  return (
    '${notice.caption}',
    truthy(confirm) ? '$confirm' : '',
    notice.text,
    style,
  );
}

/// One render: the page's context, the skin and the list being built.
class _Pass {
  _Pass(this.renderer, this.ctx, this.skin, this.ops);

  final HudRenderer renderer;
  final HudContext ctx;
  final SkinInfo skin;
  final List<HudOp> ops;

  HudFonts get fonts => renderer.fonts;
  HudRules get rules => ctx.rules;
  String? get manufacturer => ctx.manufacturer;
  String? get model => ctx.model;
  UnitSystem get units => ctx.units;

  int absX(Map<String, dynamic> elem) =>
      (skin.x + (_number(elem, 'rel_x', 0.0) * skin.w)).truncate();
  int absY(Map<String, dynamic> elem) =>
      (skin.y + (_number(elem, 'rel_y', 0.0) * skin.h)).truncate();

  void text(
    num x,
    num y,
    String text,
    HudFont font,
    Rgb color, {
    int strokeWidth = 0,
    Rgb? strokeColor,
  }) => ops.add(
    TextOp(
      x.toDouble(),
      y.toDouble(),
      text,
      font.file,
      font.size,
      color,
      strokeWidth: strokeWidth,
      strokeColor: strokeColor,
    ),
  );

  /// The four black copies of an outlined text.
  void outlineCopies(num x, num y, String text, HudFont font, int distance) {
    for (final (dx, dy) in [
      (-distance, -distance),
      (distance, -distance),
      (-distance, distance),
      (distance, distance),
    ]) {
      this.text(x + dx, y + dy, text, font, _black);
    }
  }

  void polygon(List<HudPoint> points, Rgb fill) =>
      ops.add(PolygonOp(points, fill: fill));

  void rect(num x0, num y0, num x1, num y1, Rgb fill) => ops.add(
    RectOp(
      x0.toDouble(),
      y0.toDouble(),
      x1.toDouble(),
      y1.toDouble(),
      fill: fill,
    ),
  );

  void roundedRect(
    num x0,
    num y0,
    num x1,
    num y1,
    num radius, {
    Rgb? fill,
    Rgb? outline,
    int width = 1,
  }) => ops.add(
    RoundedRectOp(
      x0.toDouble(),
      y0.toDouble(),
      x1.toDouble(),
      y1.toDouble(),
      radius.toDouble(),
      fill: fill,
      outline: outline,
      width: width,
    ),
  );

  // --- the pass ---

  void drawTelemetry(
    Map<String, dynamic> layout,
    Waypoint? waypoint,
    List<Waypoint>? waypoints,
  ) {
    final hudSkin = layout['hud_skin'];
    final elements = <Map<String, dynamic>>[
      if (hudSkin is Map<String, dynamic> &&
          hudSkin['linked_elements'] is List<dynamic>)
        for (final elem in hudSkin['linked_elements'] as List<dynamic>)
          if (elem is Map<String, dynamic>) elem,
    ];
    bool isGraph(Map<String, dynamic> elem) =>
        elem['type'] == 'graph' || _field(elem) == 'depth_graph';

    // The graphs first, under everything else.
    for (final elem in elements) {
      if (isGraph(elem)) {
        drawDepthGraph(elem, waypoint, waypoints);
      }
    }

    // `hide_in_states` elements (the NDL a stop box replaces) step aside
    // while the HUD is in one of those states.
    String? hudState;
    if (elements.any((e) => truthy(e['hide_in_states']))) {
      hudState = rules.resolveState(manufacturer, model, waypoint, waypoints);
    }
    // The device's own notification, when a notice element draws it; the
    // elements it covers (`hide_when_notice`) step aside while it shows.
    Notice? notice;
    if (elements.any(
      (e) =>
          (e['type'] == 'notice' && e['source'] != 'persistent') ||
          truthy(e['hide_when_notice']),
    )) {
      notice = activeNotice(
        rules,
        manufacturer,
        model,
        waypoint,
        waypoints: waypoints,
        units: units,
      );
    }
    Notice? persistent;
    if (elements.any(
      (e) => e['type'] == 'notice' && e['source'] == 'persistent',
    )) {
      persistent = activePersistentNotice(
        rules,
        manufacturer,
        model,
        waypoint,
        waypoints: waypoints,
        units: units,
      );
    }
    // The sidemount tank to breathe from: the elements with
    // `hide_when_switch` step aside while it is pointed out.
    String? switchTarget;
    if (elements.any(
      (e) => truthy(e['hide_when_switch']) || e['type'] == 'tank_switch_arrows',
    )) {
      switchTarget = rules.sidemountSwitchTarget(manufacturer, model, waypoint);
    }

    // A pop-up notice covers the screen under it, so it is drawn last, over
    // a variant's elements that come after it in the merged list; one with
    // `hide_others` takes the whole screen while it shows (a Mk3i's
    // alerts). Python's stable sort on "is a pop-up notice".
    bool popUp(Map<String, dynamic> e) =>
        e['type'] == 'notice' && e['source'] != 'persistent';
    final hideAll =
        notice != null &&
        elements.any((e) => popUp(e) && truthy(e['hide_others']));
    final ordered = [
      ...elements.where((e) => !popUp(e)),
      ...elements.where(popUp),
    ];
    for (final elem in ordered) {
      if (hideAll && elem['type'] != 'notice') {
        continue;
      }
      final hidden = elem['hide_in_states'];
      if (hudState != null &&
          hidden is List<dynamic> &&
          hidden.contains(hudState)) {
        continue;
      }
      final circuits = elem['hide_in_circuits'];
      if (truthy(circuits)) {
        // A CC page's setpoint steps aside on a bailout, its PPO2 on the
        // loop.
        final circuit = waypoint?.circuit;
        if (circuits is List<dynamic> &&
            circuits.contains(truthy(circuit) ? circuit : 'OC')) {
          continue;
        }
      }
      if (notice != null && truthy(elem['hide_when_notice'])) {
        continue;
      }
      if (switchTarget != null && truthy(elem['hide_when_switch'])) {
        continue;
      }
      switch (elem['type']) {
        case 'tank_switch_arrows':
          drawTankSwitchArrows(
            elem,
            switchTarget,
            waypoint == null ? 0 : waypoint.diveTime ?? waypoint.timeSinceStart,
          );
          continue;
        case 'notice':
          final shown = elem['source'] == 'persistent' ? persistent : notice;
          if (shown != null) {
            drawNotice(elem, shown);
          }
          continue;
      }
      if (isGraph(elem)) {
        if (truthy(elem['stop_label'])) {
          drawGraphStopLabel(elem, waypoint, waypoints);
        }
        continue;
      }
      switch (elem['type']) {
        case 'badge':
          drawStateBadge(elem, waypoint, waypoints);
        case 'tank_icon':
          drawTankFill(elem, waypoint);
        case 'tissue_bar':
          drawTissueBar(elem, waypoint);
        case 'arc':
          drawArc(elem, gaugeValue(elem, waypoint, waypoints));
        case 'segment_bar':
          drawSegmentBar(elem, gaugeValue(elem, waypoint, waypoints));
        case 'ascent_chevrons':
          drawAscentChevrons(elem, waypoint, waypoints);
        default:
          drawText(elem, waypoint, waypoints);
      }
    }
  }

  String _field(Map<String, dynamic> elem) =>
      elem['field'] is String ? elem['field'] as String : '';

  // --- text ---

  void drawText(
    Map<String, dynamic> elem,
    Waypoint? waypoint,
    List<Waypoint>? waypoints,
  ) {
    final field = _field(elem);
    var (val, rawVal) = resolveElementText(ctx, field, waypoint, waypoints);
    val = applyValueFormat(elem, val, rawVal, units);

    if (field == 'ndl' && (rawVal == null || (rawVal is num && rawVal <= 0))) {
      // In deco a Perdix shows NDL "0" in red, for brands with an
      // `ndl_zero` colour, rather than "99+" or "--".
      if (truthy(ctx.rule('ndl_zero')) &&
          rules.resolveState(manufacturer, model, waypoint, waypoints) ==
              'deco') {
        val = '0';
        rawVal = 0;
        val = applyValueFormat(elem, val, rawVal, units); // a Nautic's "0′"
      }
    }
    if (val == null || val.isEmpty) {
      return;
    }

    var x = absX(elem).toDouble();
    var y = absY(elem).toDouble();

    final defaultColor = '${_get(elem, 'color', '#FFFFFF')}';
    var colorHex = rules.getDynamicColor(
      manufacturer,
      model,
      field,
      rawVal,
      defaultColor,
    );
    final elapsed = waypoint == null ? 0.0 : ctx.flashTime(waypoint);
    if (field == 'depth') {
      // Above a deco ceiling by more than the margin: the depth flashes
      // red along with the badge's ceiling line.
      final state = rules.resolveState(
        manufacturer,
        model,
        waypoint,
        waypoints,
      );
      if ((state == 'deco' || state == 'clear') &&
          rules.ceilingBroken(manufacturer, model, waypoint)) {
        colorHex = resolveBlinkColor(
          colorHex,
          rules.ceilingBrokenColor(manufacturer, model),
          elapsed,
        );
      } else if (state == 'safety_stop' &&
          rules.stopPhase(manufacturer, model, waypoint, waypoints).$2 ==
              'warn') {
        // More than warn_above_m above the safety stop ceiling: the depth
        // turns yellow with the stop depth.
        final ssRule = ctx.rule('safety_stop');
        final warn = ssRule is Map<String, dynamic>
            ? ssRule['warn_color']
            : null;
        colorHex = truthy(warn) ? '$warn' : '#FFFF00';
      }
    }
    if ((field == 'gf' || field == 'surf_gf') && rawVal is num) {
      final gfRule = ctx.rule('gf_colors');
      if (gfRule is Map<String, dynamic>) {
        final own = waypoint?.dive?.gfHigh;
        final gfHigh = own != null && own != 0
            ? own
            : _number(gfRule, 'gf_high_default', 85);
        if (rawVal > 100) {
          colorHex = '${_get(gfRule, 'above_100', '#FF0000')}';
        } else if (rawVal > gfHigh) {
          colorHex = '${_get(gfRule, 'above_gf_high', '#FFFF00')}';
        }
      }
    }
    // A box the element always sits on (a Nautic's stop timer pill); the
    // rules' own boxes below (CCR, tank reserve) take its place.
    Rgb? boxRgb = truthy(elem['box_color'])
        ? hexRgb('${elem['box_color']}')
        : null;
    Rgb? boxOutlineRgb;
    final ccr = rules.ccrStyle(
      manufacturer,
      model,
      field,
      waypoint,
      rawVal,
      colorHex,
      elapsed: elapsed,
    );
    if (ccr != null && ccr.isNotEmpty) {
      // A rebreather's loop PPO2, cells, DilPO2, setpoint, CC / BO badge.
      colorHex = ccr['color'] ?? colorHex;
      if (truthy(ccr['box'])) {
        boxRgb = hexRgb(ccr['box']!);
      }
      if (truthy(ccr['outline'])) {
        boxOutlineRgb = hexRgb(ccr['outline']!);
      }
    }
    if (field == 'primary_tank_pressure' ||
        field == 'secondary_tank_pressure' ||
        field.startsWith('tank_pressure:')) {
      // Below the reserve or critical pressure: a Shearwater puts the
      // value on a yellow or red box, a Descent turns it yellow, then
      // flashing red.
      final reserveRule = ctx.rule('tank_reserve');
      if (reserveRule is Map<String, dynamic>) {
        final tankState = rules.tankPressureState(
          manufacturer,
          model,
          rawVal is num ? rawVal.toDouble() : null,
        );
        if (tankState != null && reserveRule['style'] == 'fill') {
          boxRgb = hexRgb(
            '${_get(reserveRule, '${tankState}_color', '#FFFF00')}',
          );
          final textColor = reserveRule['${tankState}_text_color'];
          colorHex = truthy(textColor)
              ? '$textColor'
              : tankState == 'critical'
              ? '#FFFFFF'
              : '#000000';
        } else if (tankState == 'critical' &&
            truthy(reserveRule['critical_blink'])) {
          colorHex = resolveBlinkColor(
            defaultColor,
            '${_get(reserveRule, 'critical_color', '#FF0000')}',
            elapsed,
          );
        }
      }
    }
    var colorRgb = hexRgb(colorHex);

    final baseFontSize = _number(elem, 'font_size', 16);
    final itemScale = _number(elem, 'scale', 1.0);
    var finalSize =
        (skin.renderLog
                ? baseFontSize * skin.userScale * itemScale
                : baseFontSize * skin.userScale * skin.resScale * itemScale)
            .truncate();
    if (finalSize < 1) {
      finalSize = 1;
    }

    final valStr = val;
    final (mainStr, suffixStr, suffixScale) = textParts(field, valStr, elem);
    // "m" / "ft", "BAR" / "PSI" ... drawn after the value.
    final unitText = unitSuffixText(elem, field, units);
    final pxScale = skin.scale;
    finalSize = renderer.fittedFontSize(
      elem,
      finalSize,
      mainStr,
      suffixStr: suffixStr,
      suffixScale: suffixScale,
      pxScale: pxScale,
      unitText: unitText,
    );
    final family = elem['font_family'];
    final weight = elem['font_weight'];
    final font = fonts.get(finalSize, family, weight);
    var outline = truthy(_get(elem, 'outline', textOutlineDefault));
    HudFont? suffixFont;
    if (suffixStr.isNotEmpty) {
      suffixFont = fonts.get(
        _max(1, _round(finalSize * suffixScale)),
        family,
        weight,
      );
    }
    final align = _get(elem, 'align', 'left');
    final valign = _get(elem, 'valign', 'top');
    final orientation = elem['orientation'];
    if (verticalOrientations.contains(orientation)) {
      // A small suffix or the NDL "+" is not split for vertical text: the
      // whole string is stacked or turned as one.
      drawOrientedText(
        valStr,
        font,
        orientation,
        x,
        y,
        align,
        valign,
        colorRgb,
        finalSize,
        outline: outline,
      );
      return;
    }
    if (align != 'left' || valign != 'top') {
      var (dx, dy, (left, _, right, _)) = textAnchorShift(
        font,
        mainStr,
        align,
        valign,
      );
      if (suffixFont != null) {
        // The whole main and suffix run is what gets aligned.
        final totalRight = right + suffixFont.getlength(suffixStr);
        if (align == 'center') {
          dx = -(left + totalRight) / 2.0;
        } else if (align == 'right') {
          dx = -totalRight;
        }
      }
      dx += renderer.unitAlignShift(
        elem,
        font,
        mainStr,
        suffixStr,
        suffixFont,
        finalSize,
        unitText,
        align,
        pxScale,
      );
      x = _round(x + dx).toDouble();
      y = _round(y + dy).toDouble();
    }
    if (suffixFont != null) {
      // The devices draw the NDL "+" and the seconds or decimal part as a
      // small mark top-aligned with the main digits.
      final oDist = _max(1, (finalSize / 20).truncate());
      if (outline) {
        outlineCopies(x, y, mainStr, font, oDist);
      }
      text(x, y, mainStr, font, colorRgb);

      final suffixX =
          x +
          font.getlength(mainStr) +
          (truthy(elem['small_suffix_dx'])
                  ? pyFloatOf(elem['small_suffix_dx']) ?? 0.0
                  : 0.0) *
              pxScale;
      var suffixY = y;
      if (truthy(elem['small_suffix']) ||
          (suffixStr == '+' && plusSignScale(elem) != null)) {
        // The suffix's ink top on the main digits' ink top. The NDL "+"
        // keeps its raised look.
        suffixY =
            y + (font.getbbox(mainStr).$2 - suffixFont.getbbox(suffixStr).$2);
        if (elem['small_suffix_align'] == 'baseline') {
          // A Suunto's small decimal sits on the digits' baseline ("36.6").
          suffixY =
              y + (font.getbbox(mainStr).$4 - suffixFont.getbbox(suffixStr).$4);
        }
      }
      final suffixO = _max(1, (suffixFont.size / 20).truncate());
      if (outline) {
        outlineCopies(suffixX, suffixY, suffixStr, suffixFont, suffixO);
      }
      text(suffixX, suffixY, suffixStr, suffixFont, colorRgb);
      if (unitText.isNotEmpty) {
        final runRight = suffixX + suffixFont.getlength(suffixStr);
        drawUnitSuffix(
          elem,
          unitText,
          y,
          runRight,
          suffixX,
          font,
          mainStr,
          finalSize,
          colorRgb,
          pxScale,
          outline: outline,
        );
      }
      return;
    }

    final highlight = elem['tank_switch_highlight'];
    if (truthy(highlight)) {
      // Sidemount tank-switch notification: a filled box behind this
      // tank's label when it is the one to breathe from.
      if (rules.sidemountSwitchTarget(manufacturer, model, waypoint) ==
          highlight) {
        final rule = ctx.rule('sidemount_switch');
        final r = rule is Map<String, dynamic>
            ? rule
            : const <String, dynamic>{};
        if (elem['tank_switch_style'] == 'text') {
          // A Descent X50i: the pressure itself turns blue, no box.
          colorRgb = hexRgb('${_get(r, 'color', '#00C800')}');
        } else {
          boxRgb = hexRgb('${_get(r, 'color', '#00C800')}');
          colorRgb = hexRgb('${_get(r, 'text_color', '#000000')}');
        }
      }
    }
    if (boxRgb != null) {
      drawTextBox(
        x,
        y,
        font,
        valStr,
        finalSize,
        boxRgb,
        boxOutlineRgb,
        _number(elem, 'box_pad', 0.15).toDouble(),
      );
      outline = false;
    }

    final oDist = _max(1, (finalSize / 20).truncate());
    if (outline) {
      outlineCopies(x, y, valStr, font, oDist);
    }
    text(x, y, valStr, font, colorRgb);
    if (unitText.isNotEmpty) {
      final runRight = x + font.getlength(valStr);
      drawUnitSuffix(
        elem,
        unitText,
        y,
        runRight,
        null,
        font,
        valStr,
        finalSize,
        colorRgb,
        pxScale,
        outline: outline,
      );
    }
  }

  void drawUnitSuffix(
    Map<String, dynamic> elem,
    String unitText,
    double y0,
    double runRight,
    double? suffixX,
    HudFont font,
    String mainText,
    int size,
    Rgb colorRgb,
    double pxScale, {
    required bool outline,
  }) {
    final (gx, gy, unitFont, unitSize) = renderer.unitSuffixGeometry(
      elem,
      font,
      mainText,
      size,
      runRight,
      suffixX,
      pxScale,
      unitText,
    );
    final x = _round(gx);
    final y = _round(y0 + gy);
    final colour = truthy(elem['unit_color'])
        ? hexRgb('${elem['unit_color']}')
        : colorRgb;
    if (verticalOrientations.contains(elem['unit_orientation'])) {
      drawOrientedText(
        unitText,
        unitFont,
        elem['unit_orientation'],
        x,
        y,
        'left',
        'top',
        colour,
        unitSize,
        outline: outline,
      );
      return;
    }
    if (outline) {
      outlineCopies(
        x,
        y,
        unitText,
        unitFont,
        _max(1, (unitSize / 20).truncate()),
      );
    }
    text(x, y, unitText, unitFont, colour);
  }

  /// A vertical text element at anchor ([x], [y]): stacked letters one per
  /// line, or the line turned on its side.
  void drawOrientedText(
    String value,
    HudFont font,
    Object? orientation,
    num x,
    num y,
    Object? align,
    Object? valign,
    Rgb colorRgb,
    int size, {
    required bool outline,
  }) {
    final (dx, dy, w, _) = orientedTextGeometry(
      font,
      value,
      orientation,
      size,
      align,
      valign,
    );
    final x0 = _round(x + dx);
    final y0 = _round(y + dy);
    final oDist = _max(1, (size / 20).truncate());
    if (orientation == 'stacked') {
      final advance = (size * stackedLineAdvance).truncate();
      var index = 0;
      for (final rune in value.runes) {
        final ch = String.fromCharCode(rune);
        final (left, top, right, _) = font.getbbox(ch);
        // The letter centred in the column, its ink top on the line top.
        final cx = x0 + (w - (right - left)) / 2.0 - left;
        final cy = y0 + index * advance - top;
        if (outline) {
          outlineCopies(cx, cy, ch, font, oDist);
        }
        text(cx, cy, ch, font, colorRgb);
        index++;
      }
      return;
    }
    final margin = oDist + 1;
    ops.add(
      RotatedTextOp(
        x0 - margin,
        y0 - margin,
        value,
        font.file,
        font.size,
        '$orientation',
        colorRgb,
        outline ? oDist : 0,
      ),
    );
  }

  /// A filled rounded box behind [value] drawn at ([x], [y]): the way a
  /// Perdix highlights a tank to switch to or a tank pressure below the
  /// reserve; with [outlineRgb] an outlined one (a Descent's CC box).
  void drawTextBox(
    num x,
    num y,
    HudFont font,
    String value,
    int size,
    Rgb boxRgb,
    Rgb? outlineRgb, [
    double padShare = 0.15,
  ]) {
    final (left, top, right, bottom) = font.getbbox(value);
    final pad = _max(1, (size * padShare).truncate());
    final radiusShare = padShare * 1.5 < 0.15 ? padShare * 1.5 : 0.15;
    roundedRect(
      x + left - pad,
      y + top - pad,
      x + right + pad,
      y + bottom + pad,
      _max(1, (size * radiusShare).truncate()),
      fill: boxRgb,
      outline: outlineRgb,
      width: outlineRgb != null ? _max(1, (size * 0.08).truncate()) : 0,
    );
  }

  // --- state badge ---

  /// A check mark the height of a [size] px line at ([x], [y]); returns
  /// the x where the text after it starts.
  double drawCheckMark(
    double x,
    num y,
    int size,
    Rgb colorRgb, {
    required bool outline,
  }) {
    final w = (size * 0.9).truncate();
    final h = (size * 0.8).truncate();
    final top = y + (size * 0.15).truncate();
    final points = <HudPoint>[
      (x + (w * 0.05).truncate(), (top + (h * 0.55).truncate()).toDouble()),
      (x + (w * 0.38).truncate(), (top + h).toDouble()),
      (x + w, (top + (h * 0.05).truncate()).toDouble()),
    ];
    final stroke = _max(2, (size / 8).truncate());
    if (outline) {
      ops.add(LineOp(points, _black, stroke + 2, joint: 'curve'));
    }
    ops.add(LineOp(points, colorRgb, stroke, joint: 'curve'));
    return x + w + (size * 0.35).truncate();
  }

  void drawStateBadge(
    Map<String, dynamic> elem,
    Waypoint? waypoint,
    List<Waypoint>? waypoints,
  ) {
    final lines = badgeLines(ctx, elem, waypoint, waypoints);
    if (lines == null || lines.isEmpty) {
      return;
    }
    final x0 = absX(elem);
    final y0 = absY(elem);
    final (labelSize, valueSize) = badgeLineSizes(elem, skin);
    final state = rules.resolveState(manufacturer, model, waypoint, waypoints);
    if (elem['style'] == 'box') {
      final (boxW, boxH) = badgeBoxSize(elem, skin.scale);
      drawBadgeBox(
        elem,
        lines,
        state,
        x0,
        y0,
        labelSize,
        valueSize,
        boxW,
        boxH,
      );
      return;
    }
    final family = elem['font_family'];
    final weight = elem['font_weight'];
    final labelFont = fonts.get(labelSize, family, weight);
    final valueFont = fonts.get(valueSize, family, weight);
    final outline = truthy(_get(elem, 'outline', textOutlineDefault));
    final align = _get(elem, 'align', 'left');
    final valign = _get(elem, 'valign', 'top');

    final badgeCfg =
        rules.getBadgeConfig(manufacturer, model, state) ??
        const <String, dynamic>{};
    final titleBox = truthy(_get(elem, 'title_box', badgeCfg['title_box']));
    // "center": the value lines sit centred under the title's ink (a
    // Perdix centres the safety-stop time under "SAFETY STOP") whatever
    // the element's own alignment.
    final valueAlign = truthy(elem['value_align'])
        ? elem['value_align']
        : badgeCfg['value_align'];
    double? titleCenter;

    // `line_spacing`: the line pitch as a share of each line's font size
    // (a Peregrine's tall stop time sits close under its title).
    final spacing = _number(elem, 'line_spacing', 1.2).toDouble();
    var y = y0;
    if (valign != 'top') {
      var blockH = 0;
      for (final (_, _, isValue) in lines) {
        blockH += ((isValue ? valueSize : labelSize) * spacing).truncate();
      }
      y -= valign == 'bottom' ? blockH : blockH ~/ 2;
    }
    final pxScale = skin.scale;
    // `unit_scale` / `unit_color`: the units after a value line's numbers
    // ("6m 2min") small and in their own colour, as a Peregrine or a Teric
    // draws them.
    final badgeUnitScale = badgeUnitScaleOf(elem);
    final unitRgb = truthy(elem['unit_color'])
        ? hexRgb('${elem['unit_color']}')
        : null;
    for (var index = 0; index < lines.length; index++) {
      final (lineText, colorRgb, isValue) = lines[index];
      var font = isValue ? valueFont : labelFont;
      final pitchSize = isValue ? valueSize : labelSize;
      var finalSize = pitchSize;
      final lineUnits = isValue ? badgeUnitScale : null;
      final lineY = y;
      final fitted = fittedBadgeLineSize(
        fonts,
        elem,
        lineText,
        finalSize,
        pxScale,
        lineUnits,
      );
      if (fitted != finalSize) {
        // A line too wide for `max_width` shrinks, on the full-size line's
        // baseline.
        final fittedFont = fonts.get(fitted, family, weight);
        y += font.getbbox('0').$4 - fittedFont.getbbox('0').$4;
        font = fittedFont;
        finalSize = fitted;
      }
      var x = x0.toDouble();
      if (align != 'left') {
        final (dx, _, _) = badgeLineAnchor(
          fonts,
          font,
          lineText,
          finalSize,
          align,
          lineUnits,
        );
        x = _round(x0 + dx).toDouble();
      }
      if (isValue && valueAlign == 'center' && titleCenter != null) {
        // The drawn check mark included.
        final (left, right) = badgeTitleInkSpan(
          fonts,
          font,
          lineText,
          finalSize,
          lineUnits,
        );
        x = _round(titleCenter - (left + right) / 2.0).toDouble();
      } else if (!isValue && titleCenter == null) {
        final (left, right) = badgeTitleInkSpan(
          fonts,
          font,
          lineText,
          finalSize,
        );
        titleCenter = x + (left + right) / 2.0;
      }
      if (index == 0 && !isValue && titleBox) {
        // Perdix 3 style: the title in a filled box of its colour, in
        // black text.
        final (left, top, right, bottom) = font.getbbox(lineText);
        final pad = _max(1, (finalSize * 0.12).truncate());
        roundedRect(
          x + left - pad,
          y + top - pad,
          x + right + pad,
          y + bottom + pad,
          _max(1, (finalSize * 0.1).truncate()),
          fill: colorRgb,
        );
        text(x, y, lineText, font, _black);
        final boxBottom = y + bottom + pad;
        y = lineY + (pitchSize * spacing).truncate() + pad;
        if (index + 1 < lines.length) {
          // The next line's ink starts a pad below the box, however tight
          // the spacing (the Perdix 3's timer under SAFETY).
          final nextFont = lines[index + 1].$3 ? valueFont : labelFont;
          final nextY = boxBottom + pad - nextFont.getbbox('0').$2;
          if (nextY > y) {
            y = nextY;
          }
        }
        continue;
      }
      final oDist = _max(1, (finalSize / 20).truncate());
      // The bundled fonts have no check mark glyph: it is drawn as a
      // stroke in the line's colour wherever it sits in the text ("✓
      // 2:59", "6m✓ 2min"), the text pieces around it.
      final pieces = lineText.split(checkMark.trim());
      for (var i = 0; i < pieces.length; i++) {
        var piece = pieces[i];
        if (i != 0) {
          x = drawCheckMark(x, y, finalSize, colorRgb, outline: outline);
          piece = piece.replaceFirst(RegExp('^ +'), '');
        }
        if (piece.isEmpty) {
          continue;
        }
        for (final (run, runFont, isUnit) in badgeFontRuns(
          fonts,
          piece,
          font,
          finalSize,
          weight,
          lineUnits,
        )) {
          // A small unit sits on the digits' baseline.
          final runY = isUnit ? y + (font.ascent - runFont.ascent) : y;
          final runRgb = isUnit && unitRgb != null ? unitRgb : colorRgb;
          if (outline) {
            outlineCopies(x, runY, run, runFont, oDist);
          }
          text(x, runY, run, runFont, runRgb);
          x += runFont.getlength(run);
        }
      }
      y = lineY + (pitchSize * spacing).truncate();
    }
  }

  /// A Garmin Descent's stop box: a filled rounded box in the state's
  /// colour in the NDL's place, the label and the stop depth on the top
  /// row, the stop timer large underneath, in dark text. `fill_colors` on
  /// the element sets the colour per state.
  void drawBadgeBox(
    Map<String, dynamic> elem,
    List<BadgeLine> lines,
    String state,
    int x0,
    int y0,
    int labelSize,
    int valueSize,
    int boxW,
    int boxH,
  ) {
    final scale = skin.scale;
    final fills = elem['fill_colors'];
    final fillHex = fills is Map<String, dynamic> ? fills[state] : null;
    final fill = truthy(fillHex) ? hexRgb('$fillHex') : lines.first.$2;
    final textRgb = hexRgb('${_get(elem, 'text_color', '#000000')}');
    final radius = _max(
      1,
      (_number(elem, 'corner_radius', 4) * scale).truncate(),
    );
    roundedRect(x0, y0, x0 + boxW, y0 + boxH, radius, fill: fill);

    final family = elem['font_family'];
    final weight = elem['font_weight'];
    final labelFont = fonts.get(labelSize, family, weight);
    final valueFont = fonts.get(valueSize, family, weight);
    final pad = _max(1, (_number(elem, 'padding', 4) * scale).truncate());
    final topRow = [
      for (final (lineText, _, isValue) in lines)
        if (!isValue || lineText.startsWith('↑')) lineText,
    ];
    String? timer;
    for (final (lineText, _, isValue) in lines) {
      if (isValue && !lineText.startsWith('↑')) {
        timer = lineText;
        break;
      }
    }

    final depthSize = elem['depth_font_size'];
    if (truthy(depthSize)) {
      // A Descent X50i's top row: the label at the left, and at the right
      // an arrow under a bar (drawn, the face has no such glyph) before
      // the stop depth in its own larger size. Placed by their ink, so
      // the row sits `padding` inside the box.
      final label = topRow.firstWhere(
        (t) => !t.startsWith('↑'),
        orElse: () => '',
      );
      final depthLine = topRow.firstWhere(
        (t) => t.startsWith('↑'),
        orElse: () => '',
      );
      final depth = depthLine.isEmpty ? '' : depthLine.substring(1);
      if (label.isNotEmpty) {
        final (left, top, _, _) = labelFont.getbbox(label);
        text(
          x0 + pad + _number(elem, 'label_dx', 0.0).toDouble() * scale - left,
          y0 + pad - top,
          label,
          labelFont,
          textRgb,
        );
      }
      if (depth.isNotEmpty) {
        final base = _number(elem, 'font_size', 16).toDouble();
        final depthPx = _max(
          1,
          (labelSize * pyFloatOf(depthSize)! / pyMax(1.0, base)).truncate(),
        );
        final depthFont = fonts.get(depthPx, family, weight);
        // The unit a little smaller.
        final unitFont = fonts.get(
          _max(1, (depthPx * 0.85).truncate()),
          family,
          weight,
        );
        final digits = depth.replaceFirst(RegExp(r'[a-zA-Z]+$'), '');
        final unit = depth.substring(digits.length);
        final (left, top, _, bottom) = depthFont.getbbox(
          digits.isEmpty ? depth : digits,
        );
        final cap = bottom - top;
        final unitW = unit.isEmpty ? 0 : unitFont.getbbox(unit).$3;
        final textX = x0 + boxW - pad - unitW - depthFont.getlength(digits);
        final textY = y0 + pad - top;
        text(textX, textY, digits, depthFont, textRgb);
        if (unit.isNotEmpty) {
          // Baselines together.
          text(
            textX + depthFont.getlength(digits),
            textY + bottom - unitFont.getbbox(unit).$4,
            unit,
            unitFont,
            textRgb,
          );
        }
        for (final shape in stopArrowShapes(
          textX + left - 0.17 * cap,
          (y0 + pad).toDouble(),
          cap.toDouble(),
        )) {
          polygon(shape, textRgb);
        }
      }
    } else {
      text(x0 + pad, y0 + pad, topRow.join('  '), labelFont, textRgb);
    }
    if (timer != null && timer.isNotEmpty) {
      final (left, _, right, bottom) = valueFont.getbbox(timer);
      text(
        x0 + (boxW - (right - left)) / 2 - left,
        y0 + boxH - pad - bottom,
        timer,
        valueFont,
        textRgb,
      );
    }
  }

  // --- tank icons ---

  Object? _tankValue(Map<String, dynamic> elem, Waypoint? waypoint) {
    if (waypoint == null) {
      return null;
    }
    final field = elem['field'] is String
        ? elem['field'] as String
        : 'primary_tank_pressure';
    if (field.startsWith('tank_pressure:')) {
      return waypoint
          .tanks[field.replaceAll('tank_pressure:', '')]
          ?.pressureBar;
    }
    return waypointValue(waypoint, field);
  }

  /// A tank-pressure icon: an optional drawn outline (a rounded rectangle
  /// and a cap) and the solid status fill; or the "segments" style.
  /// `rel_x`, `rel_y`, `width` and `height` are the fill rectangle. The
  /// fill is left out while the tank has no pressure reading; the outline
  /// is not.
  void drawTankFill(Map<String, dynamic> elem, Waypoint? waypoint) {
    final x0 = absX(elem);
    final y0 = absY(elem);
    final scale = skin.scale;
    final w = _max(1, (_number(elem, 'width', 20) * scale).truncate());
    final h = _max(1, (_number(elem, 'height', 30) * scale).truncate());
    final radius = _max(
      1,
      (_number(elem, 'corner_radius', 4) * scale).truncate(),
    );

    if (elem['style'] == 'segments') {
      // A Shearwater's horizontal segmented gauge (it draws its own
      // outline).
      final rawVal = _tankValue(elem, waypoint);
      drawTankSegments(
        elem,
        rawVal,
        rules.getTankFillColor(manufacturer, model, rawVal),
        x0,
        y0,
        scale,
      );
      return;
    }

    final metrics = tankOutlineMetrics(elem);
    if (metrics != null) {
      final (gap, stroke, capH) = metrics;
      final gapPx = _round(gap * scale);
      final strokePx = _max(1, _round(stroke * scale));
      final capPx = _max(1, _round(capH * scale));
      final outlineRgb = hexRgb(
        '${_get(elem, 'outline_color', tankOutlineDefaultColor)}',
      );
      final ox0 = x0 - gapPx - strokePx;
      final oy0 = y0 - gapPx - strokePx;
      final ox1 = x0 + w + gapPx + strokePx;
      final oy1 = y0 + h + gapPx + strokePx;
      roundedRect(
        ox0,
        oy0,
        ox1,
        oy1,
        _max(1, radius + gapPx + strokePx),
        outline: outlineRgb,
        width: strokePx,
      );
      final capW = _max(2, _round((ox1 - ox0) * 0.45));
      final cx = _floorDiv(ox0 + ox1, 2);
      roundedRect(
        cx - _floorDiv(capW, 2),
        oy0 - capPx + strokePx,
        cx + _floorDiv(capW, 2),
        oy0 + strokePx,
        _max(1, _floorDiv(capPx, 2)),
        outline: outlineRgb,
        width: strokePx,
      );
    }

    if (waypoint == null) {
      return;
    }
    final rawVal = _tankValue(elem, waypoint);
    final colorHex = rules.getTankFillColor(manufacturer, model, rawVal);
    if (colorHex == null || colorHex.isEmpty) {
      return;
    }
    var top = y0;
    if (truthy(elem['fill_level'])) {
      // The fill drops with the pressure, from `full_bar` down to
      // `empty_bar`.
      final fraction = tankFillFraction(rawVal, elem);
      if (fraction <= 0) {
        return;
      }
      top = y0 + h - _max(1, _round(h * fraction));
    }
    roundedRect(x0, top, x0 + w, y0 + h, radius, fill: hexRgb(colorHex));
  }

  void drawTankSegments(
    Map<String, dynamic> elem,
    Object? rawVal,
    String? fillHex,
    int x0,
    int y0,
    double scale,
  ) {
    final (n, gap, fullBar, pad, stroke, nose, nub) = tankSegmentsGeometry(
      elem,
    );
    final segW = _max(1, _round(_number(elem, 'width', 12).truncate() * scale));
    final segH = _max(
      1,
      _round(_number(elem, 'height', 23).truncate() * scale),
    );
    final gapPx = _round(gap * scale);
    final padPx = _round(pad * scale);
    final strokePx = _max(1, _round(stroke * scale));
    final nosePx = _max(2, _round(nose * scale));
    final nubPx = _max(2, _round(nub * scale));
    final radius = _max(
      1,
      _round(_number(elem, 'corner_radius', 2).truncate() * scale),
    );
    final totalW = n * segW + (n - 1) * gapPx;

    final outlineRgb = hexRgb(
      '${_get(elem, 'outline_color', tankSegmentOutlineDefault)}',
    );
    final bx0 = x0 - padPx - strokePx;
    final by0 = y0 - padPx - strokePx;
    final bx1 = x0 + totalW + padPx + strokePx;
    final by1 = y0 + segH + padPx + strokePx;
    final bodyH = by1 - by0;
    // The body with a rounded shoulder on the right: a rectangle and half
    // an ellipse.
    roundedRect(
      bx0,
      by0,
      bx1,
      by1,
      _max(1, radius + padPx),
      outline: outlineRgb,
      width: strokePx,
    );
    ops.add(
      PieSliceOp(
        (bx1 - nosePx).toDouble(),
        by0.toDouble(),
        (bx1 + nosePx).toDouble(),
        by1.toDouble(),
        270,
        90,
        fill: _black,
        outline: outlineRgb,
        width: strokePx,
      ),
    );
    // Cover the seam where the shoulder meets the body again.
    rect(
      bx1 - strokePx,
      by0 + strokePx,
      bx1 + strokePx,
      by1 - strokePx,
      _black,
    );
    ops
      ..add(
        LineOp(
          [
            ((bx1 - strokePx).toDouble(), by0.toDouble()),
            (bx1.toDouble(), by0.toDouble()),
          ],
          outlineRgb,
          strokePx,
        ),
      )
      ..add(
        LineOp(
          [
            ((bx1 - strokePx).toDouble(), by1.toDouble()),
            (bx1.toDouble(), by1.toDouble()),
          ],
          outlineRgb,
          strokePx,
        ),
      );
    // The valve nub.
    final nubH = _max(2, _round(bodyH * 0.3));
    final cy = _floorDiv(by0 + by1, 2);
    rect(
      bx1 + nosePx - 1,
      cy - _floorDiv(nubH, 2),
      bx1 + nosePx + nubPx,
      cy + _floorDiv(nubH, 2),
      outlineRgb,
    );

    final lit = tankSegmentsLit(rawVal, fullBar, n);
    final fillRgb = fillHex != null && fillHex.isNotEmpty
        ? hexRgb(fillHex)
        : tankSegmentUnlit;
    for (var i = 0; i < n; i++) {
      final sx = x0 + i * (segW + gapPx);
      roundedRect(
        sx,
        y0,
        sx + segW,
        y0 + segH,
        radius,
        fill: i < lit ? fillRgb : tankSegmentUnlit,
      );
    }
  }

  // --- tissue bar ---

  /// A vertical tissue-load bar: three stacked segments in the colours of
  /// the `tissue_load` bands (0-80 %, 80-100 %, 100-120 % of the height),
  /// and a marker at the bar's left edge at the current load. Drawn
  /// without a value too (the marker at the bottom). `style: "fill"` is a
  /// Shearwater's outlined frame that fills from the bottom.
  void drawTissueBar(Map<String, dynamic> elem, Waypoint? waypoint) {
    final x0 = absX(elem);
    final y0 = absY(elem);
    final scale = skin.scale;
    final (w, h, r) = tissueBarGeometry(elem);
    final wPx = _max(2, _round(w * scale));
    final hPx = _max(4, _round(h * scale));
    final rPx = _max(1, _round(r * scale));
    final gapPx = _max(1, _round(1.5 * scale));

    final rule = ctx.rule('tissue_load');
    final bands = rule is List<dynamic> && rule.length >= 3
        ? [for (final band in rule.take(3)) band as Map<String, dynamic>]
        : tissueBarDefaultBands;
    final colors = [
      for (final band in bands) hexRgb('${_get(band, 'color', '#FFFFFF')}'),
    ];

    final value = waypointValue(
      waypoint,
      elem['field'] is String ? elem['field'] as String : 'n2_tissue_load',
    );
    final fraction = tissueBarMarkerFraction(value);
    final bottom = y0 + hPx;

    if (elem['style'] == 'fill') {
      final frameRgb = hexRgb('${_get(elem, 'outline_color', '#00ADED')}');
      final stroke = _max(1, _round(2 * scale));
      final radius = _max(1, _round(3 * scale));
      var fillColor = colors[0];
      final v = (value == null ? null : pyFloatOf(value)) ?? 0.0;
      for (var i = 0; i < bands.length; i++) {
        final band = bands[i];
        if (band.containsKey('min') && v < (band['min'] as num)) {
          continue;
        }
        if (band.containsKey('max') && v >= (band['max'] as num)) {
          continue;
        }
        fillColor = colors[i];
        break;
      }
      // The black interior first (the icon covers what is behind it),
      // then the fill, then the frame.
      roundedRect(x0, y0, x0 + wPx, bottom, radius, fill: _black);
      final fillH = _round((hPx - 2 * stroke) * fraction);
      if (fillH > 0) {
        rect(
          x0 + stroke,
          bottom - stroke - fillH,
          x0 + wPx - stroke,
          bottom - stroke,
          fillColor,
        );
      }
      roundedRect(
        x0,
        y0,
        x0 + wPx,
        bottom,
        radius,
        outline: frameRgb,
        width: stroke,
      );
      return;
    }

    // The segment heights follow the percent ranges.
    const fractions = [
      80.0 / tissueBarMaxPercent,
      20.0 / tissueBarMaxPercent,
      20.0 / tissueBarMaxPercent,
    ];
    var cursor = bottom;
    final segmentGap = elem['segment_gap'];
    for (var i = 0; i < 3; i++) {
      final segH = _max(1, _round(hPx * fractions[i]));
      final top = cursor - segH;
      if (segmentGap == null) {
        rect(
          x0,
          top + (cursor != bottom ? gapPx : 0),
          x0 + wPx,
          cursor,
          colors[i],
        );
      } else {
        // The gap comes off the foot of every segment but the lowest.
        final foot = cursor == bottom
            ? cursor
            : cursor - _max(1, _round(pyFloatOf(segmentGap)! * scale));
        rect(x0, top + 1, x0 + wPx, _max(top + 1, foot), colors[i]);
      }
      cursor = top;
    }

    final markerY = _max(
      y0 + rPx,
      _min(bottom, bottom - _round(fraction * hPx)),
    );
    if (elem['marker_style'] == 'pointer') {
      for (final (half, left, tip, color) in tissuePointerShapes(r * scale)) {
        // A 45-degree point.
        final body = tip - half;
        polygon([
          (x0 + left, markerY - half),
          (x0 + body, markerY - half),
          (x0 + tip, markerY.toDouble()),
          (x0 + body, markerY + half),
          (x0 + left, markerY + half),
        ], color);
      }
      return;
    }
    ops.add(
      EllipseOp(
        (x0 - rPx).toDouble(),
        (markerY - rPx).toDouble(),
        (x0 + rPx).toDouble(),
        (markerY + rPx).toDouble(),
        fill: _white,
        outline: _black,
      ),
    );
  }

  // --- arc gauge and segment bar ---

  /// The number an arc or segment bar shows: the field's raw value, or the
  /// ascent rate (positive going up) derived the way the chevrons derive
  /// it.
  double? gaugeValue(
    Map<String, dynamic> elem,
    Waypoint? waypoint,
    List<Waypoint>? waypoints,
  ) {
    if (waypoint == null) {
      return null;
    }
    final field = _field(elem);
    final Object? value = field == 'ascent_rate'
        ? ascentRateFor(waypoint, waypoints)
        : resolveElementText(ctx, field, waypoint, waypoints).$2;
    return value is num ? value.toDouble() : null;
  }

  /// A gauge's colour at [value]: the element's own `bands` ([{"min",
  /// "max", "color"}], the hud_rules.json shape) where it has them, else
  /// the brand's bands for the field (ascent rate, tissue load) or its
  /// colour rule, else [fallback].
  String bandColor(
    Map<String, dynamic> elem,
    String field,
    double value,
    String fallback,
  ) {
    var bands = elem['bands'];
    if (bands is! List<dynamic> && gaugeBandRules.containsKey(field)) {
      bands = ctx.rule(gaugeBandRules[field]!);
    }
    if (bands is List<dynamic>) {
      for (final band in bands.whereType<Map<String, dynamic>>()) {
        if (band.containsKey('min') && value < pyFloatOf(band['min'])!) {
          continue;
        }
        if (band.containsKey('max') && value >= pyFloatOf(band['max'])!) {
          continue;
        }
        return '${_get(band, 'color', fallback)}';
      }
      return fallback;
    }
    return rules.getDynamicColor(manufacturer, model, field, value, fallback);
  }

  /// An arc gauge (a Suunto EON's NDL / ascent-time / tank / stop arc): a
  /// track from `start_angle` through `sweep` degrees (0 = 3 o'clock,
  /// clockwise), filled from its start in proportion to the value over
  /// range_min..range_max. `segments` > 1 splits the track with
  /// `segment_gap` degrees between the parts. The fill takes `color`, or
  /// the band / rule colour at the value. Drawn without a value too (an
  /// empty track), like the device's.
  void drawArc(Map<String, dynamic> elem, double? value) {
    final scale = skin.scale;
    final (w, h, thick) = arcGeometry(elem);
    final x0 = absX(elem);
    final y0 = absY(elem);
    final x1 = x0 + _max(2, _round(w * scale));
    final y1 = y0 + _max(2, _round(h * scale));
    final widthPx = _max(1, _round(thick * scale));
    final start = _number(elem, 'start_angle', 135).toDouble();
    final sweep = _number(elem, 'sweep', 270).toDouble();
    final count = _max(1, _number(elem, 'segments', 1).truncate());
    final gap = count > 1 ? _number(elem, 'segment_gap', 0).toDouble() : 0.0;
    final track = hexRgb('${_get(elem, 'track_color', '#303030')}');
    final field = _field(elem);
    final fill = value == null
        ? null
        : hexRgb(
            bandColor(elem, field, value, '${_get(elem, 'color', '#FFFFFF')}'),
          );
    final fillEnd = start + sweep * gaugeFraction(elem, value, arcDefaults);
    final part = (sweep - gap * (count - 1)) / count;
    void arc(double a0, double a1, Rgb color) => ops.add(
      ArcOp(
        x0.toDouble(),
        y0.toDouble(),
        x1.toDouble(),
        y1.toDouble(),
        a0,
        a1,
        color: color,
        width: widthPx,
      ),
    );
    for (var i = 0; i < count; i++) {
      final a0 = start + i * (part + gap);
      final a1 = a0 + part;
      arc(a0, a1, track);
      if (fill != null && fillEnd > a0) {
        arc(a0, fillEnd < a1 ? fillEnd : a1, fill);
      }
    }
  }

  /// A vertical stack of segments lit from the bottom by a value over
  /// range_min..range_max (a Suunto's ascent-rate bar, 2 m/min a segment;
  /// an EON's NDL / tank scale). Whole segments light (`step`, the
  /// default) or the fill runs continuously (`step: false`). `color_mode`
  /// "value" lights every segment in the value's colour; "position" gives
  /// each segment the colour of its own place on the scale. Unlit segments
  /// take `track_color`. `orientation: "horizontal"` lays the segments left
  /// to right and fills from the left (a Nautic's sidemount tank bars).
  void drawSegmentBar(Map<String, dynamic> elem, double? value) {
    final scale = skin.scale;
    final (w, h, count, gap) = segmentBarGeometry(elem);
    final x0 = absX(elem);
    final y0 = absY(elem);
    final horizontal = elem['orientation'] == 'horizontal';
    final wPx = _max(horizontal ? count : 1, _round(w * scale));
    final hPx = _max(horizontal ? 1 : count, _round(h * scale));
    final gapPx = gap * scale;
    final track = hexRgb('${_get(elem, 'track_color', '#303030')}');
    final field = _field(elem);
    final fallback = '${_get(elem, 'color', '#FFFFFF')}';
    var fraction = gaugeFraction(elem, value, segmentBarDefaults);
    if (elem['step'] != false) {
      fraction = (fraction * count + 1e-9).truncate() / count;
    }
    final length = horizontal ? wPx : hPx;
    final segLen = (length - gapPx * (count - 1)) / count;
    final litPx = fraction * length;
    final low = _number(elem, 'range_min', 0).toDouble();
    final high = _number(elem, 'range_max', 10).toDouble();
    final valueColor = value == null
        ? track
        : hexRgb(bandColor(elem, field, value, fallback));

    // The span a..b along the bar, measured from its start (bottom or
    // left).
    void span(double a, double b, Rgb color) {
      if (horizontal) {
        rect(x0 + _round(a), y0, x0 + _round(b), y0 + hPx, color);
      } else {
        rect(x0, y0 + hPx - _round(b), x0 + wPx, y0 + hPx - _round(a), color);
      }
    }

    for (var i = 0; i < count; i++) {
      final segStart = i * (segLen + gapPx);
      final segEnd = segStart + segLen;
      span(segStart, segEnd, track);
      final litEnd = segEnd < litPx ? segEnd : litPx;
      if (litEnd <= segStart) {
        continue;
      }
      final Rgb color;
      if (elem['color_mode'] == 'position') {
        final at = low + (high - low) * (i + 0.5) / count;
        color = hexRgb(bandColor(elem, field, at, fallback));
      } else {
        color = valueColor;
      }
      span(segStart, litEnd, color);
    }
  }

  // --- ascent indicator ---

  /// An ascent-rate indicator: `up_count` upward chevrons above a white
  /// bar and `down_count` downward ones below it. Unlit chevrons are grey;
  /// on ascent the ones nearest the bar light in the `ascent_rate` band
  /// colour of the rate, on descent the downward ones light white. Always
  /// drawn. The brand's `ascent_chevrons` rule gives a Shearwater its six
  /// arrows without a bar; `style: "solid"` is a Descent X50i's thick
  /// nested chevrons.
  void drawAscentChevrons(
    Map<String, dynamic> elem,
    Waypoint? waypoint,
    List<Waypoint>? waypoints,
  ) {
    final x0 = absX(elem);
    final y0 = absY(elem);
    final scale = skin.scale;
    final (w, h, up, down) = ascentChevronGeometry(elem);
    final rule = ctx.rule('ascent_chevrons');
    final chevronRule = rule is Map<String, dynamic>
        ? rule
        : const <String, dynamic>{};
    final showBar = truthy(_get(elem, 'bar', _get(chevronRule, 'bar', true)));
    final wPx = _max(4, _round(w * scale));
    final hPx = _max(8, _round(h * scale));
    final barH = showBar ? _max(2, _round(hPx * 0.10)) : 0;
    final gap = _max(1, _round(1.0 * scale));
    final n = up + down;
    final chevH = n == 0
        ? 0
        : _max(
            3,
            ((hPx - barH - gap * (n + (showBar ? 1 : -1))) / n).truncate(),
          );
    // The apex depth of the "^", and the band's thickness.
    final arrow = _max(1, _round(wPx * 0.45));
    final bandT = _max(1, chevH - arrow);

    final rate = ascentRateFor(waypoint, waypoints);
    final litUp = ascentLitCount(
      rate,
      up,
      chevronRule['m_per_min_per_chevron'],
    );
    final litDown = rate != null && rate <= -ascentDeadbandMPerMin && down > 0
        ? 1
        : 0;

    final bandRule = ctx.rule('ascent_rate');
    final bands = bandRule is List<dynamic>
        ? [for (final band in bandRule) band as Map<String, dynamic>]
        : ascentDefaultBands;
    var litColor = chevronUnlit;
    if (litUp != 0) {
      for (final band in bands) {
        if (band.containsKey('min') && rate! < (band['min'] as num)) {
          continue;
        }
        if (band.containsKey('max') && rate! >= (band['max'] as num)) {
          continue;
        }
        var hex = '${_get(band, 'color', '#00FF00')}';
        if (truthy(band['blink'])) {
          // The band colour is the first-half colour, like the badges'
          // flashing red, so whole-second waypoints show it.
          hex = resolveBlinkColor('#8A8A8A', hex, ctx.flashTime(waypoint!));
        }
        litColor = hexRgb(hex);
        break;
      }
    }

    final left = x0.toDouble();
    final right = (x0 + wPx).toDouble();
    final mid = x0 + wPx / 2.0;

    if (elem['style'] == 'solid') {
      final (shapes, total) = solidChevronLayout(up, down, showBar: showBar);
      final k = total != 0 ? hPx / total : 1.0;
      final rise = solidChevronArrow * k;
      final thick = solidChevronThick * k;
      final ups = [
        for (final s in shapes)
          if (s.$1 == 'up') s,
      ];
      final downs = [
        for (final s in shapes)
          if (s.$1 == 'down') s,
      ];
      for (final (direction, _, top, bottom) in shapes) {
        if (direction == 'bar') {
          rect(left, y0 + top * k, right, y0 + bottom * k, _white);
        }
      }
      // The lit ones are the closest to the bar, like the device.
      for (var i = 0; i < ups.length; i++) {
        final (_, kind, t, b) = ups[i];
        final color = ups.length - 1 - i < litUp ? litColor : chevronSolidUnlit;
        final top = y0 + t * k;
        final bottom = y0 + b * k;
        polygon([
          (left, top + rise),
          (mid, top),
          (right, top + rise),
          (right, bottom),
          if (kind != 'flat') (mid, top + thick),
          (left, bottom),
        ], color);
      }
      for (var i = 0; i < downs.length; i++) {
        final (_, kind, t, b) = downs[i];
        final color = i < litDown ? _white : chevronSolidUnlit;
        final top = y0 + t * k;
        final bottom = y0 + b * k;
        polygon([
          (left, top),
          if (kind != 'flat') (mid, bottom - thick),
          (right, top),
          (right, bottom - rise),
          (mid, bottom),
          (left, bottom - rise),
        ], color);
      }
      return;
    }

    void chevron(int top, Rgb color, {required bool pointingUp}) {
      if (pointingUp) {
        polygon([
          (left, (top + arrow).toDouble()),
          (mid, top.toDouble()),
          (right, (top + arrow).toDouble()),
          (right, (top + arrow + bandT).toDouble()),
          (mid, (top + bandT).toDouble()),
          (left, (top + arrow + bandT).toDouble()),
        ], color);
      } else {
        final bottom = top + arrow + bandT;
        polygon([
          (left, (bottom - arrow).toDouble()),
          (mid, bottom.toDouble()),
          (right, (bottom - arrow).toDouble()),
          (right, (bottom - arrow - bandT).toDouble()),
          (mid, (bottom - bandT).toDouble()),
          (left, (bottom - arrow - bandT).toDouble()),
        ], color);
      }
    }

    var y = y0;
    // The upward chevrons: the lit ones are the lowest, like the device.
    for (var i = 0; i < up; i++) {
      chevron(
        y,
        up - 1 - i < litUp ? litColor : chevronUnlit,
        pointingUp: true,
      );
      y += chevH + gap;
    }
    if (showBar) {
      rect(x0, y, x0 + wPx, y + barH, _white);
      y += barH + gap;
    }
    for (var i = 0; i < down; i++) {
      chevron(y, i < litDown ? _white : chevronUnlit, pointingUp: false);
      y += chevH + gap;
    }
  }

  // --- tank switch arrows ---

  /// While the two sidemount tanks differ by more than the brand's
  /// `sidemount_switch` threshold, `count` triangles in the rule's colour
  /// point at the tank to breathe from: right for the secondary tank, left
  /// for the primary, the nearest one lit first. Nothing otherwise.
  void drawTankSwitchArrows(
    Map<String, dynamic> elem,
    String? target,
    num? elapsed,
  ) {
    if (target != 'primary' && target != 'secondary') {
      return;
    }
    final rule = ctx.rule('sidemount_switch');
    final r = rule is Map<String, dynamic> ? rule : const <String, dynamic>{};
    final base = hexRgb(
      '${truthy(elem['color']) ? elem['color'] : _get(r, 'color', '#00AAFF')}',
    );
    final scale = skin.scale;
    final (w, h, gap, count) = tankSwitchArrowsGeometry(elem);
    final wPx = _max(1, _round(w * scale));
    final hPx = _max(1, _round(h * scale));
    final gapPx = _round(gap * scale);
    final x = absX(elem);
    final y = absY(elem);
    final pointRight = target == 'secondary';
    final levels = tankSwitchArrowLevels(elapsed, count);
    // i = 0 is the triangle nearest the target.
    for (var i = 0; i < levels.length; i++) {
      final level = levels[i];
      if (level <= 0) {
        continue;
      }
      final slot = pointRight ? count - 1 - i : i;
      final sx = (x + slot * (wPx + gapPx)).toDouble();
      final colour = (
        _round(base.$1 * level),
        _round(base.$2 * level),
        _round(base.$3 * level),
      );
      final mid = (y + hPx ~/ 2).toDouble();
      polygon(
        pointRight
            ? [(sx, y.toDouble()), (sx + wPx, mid), (sx, (y + hPx).toDouble())]
            : [
                (sx + wPx, y.toDouble()),
                (sx, mid),
                (sx + wPx, (y + hPx).toDouble()),
              ],
        colour,
      );
    }
  }

  // --- notices ---

  /// [value] as one line when it fits [widthPx] in [font], else two: as
  /// many words as fit on the first, the rest on the second.
  List<String> wrapTwoLines(String value, HudFont font, num widthPx) {
    final words = _words(value);
    if (words.length < 2 || font.getlength(value) <= widthPx) {
      return [value];
    }
    var first = 1;
    while (first < words.length - 1 &&
        font.getlength(words.sublist(0, first + 1).join(' ')) <= widthPx) {
      first++;
    }
    return [words.sublist(0, first).join(' '), words.sublist(first).join(' ')];
  }

  /// The largest font at or under [size] whose [value] fits [widthPx].
  (HudFont, int) fitFont(
    String value,
    num size,
    num widthPx,
    Object? family,
    Object? weight, {
    int floor = 8,
  }) {
    var s = _max(floor, size.truncate());
    var font = fonts.get(s, family, weight);
    while (s > floor && font.getlength(value) > widthPx) {
      s = _max(floor, (s * 0.92).truncate());
      font = fonts.get(s, family, weight);
    }
    return (font, s);
  }

  /// The largest font at or under [size] at which every one of [lines]
  /// fits [widthPx], measured in pixels, not characters.
  (HudFont, int) fitFontLines(
    List<String> lines,
    num size,
    num widthPx,
    Object? family,
    Object? weight,
  ) {
    var (font, s) = fitFont(lines.first, size, widthPx, family, weight);
    for (final line in lines.skip(1)) {
      (font, s) = fitFont(line, s, widthPx, family, weight);
    }
    return (font, s);
  }

  /// A two-line alert with its widest line split in two, for when three
  /// lines are larger than two: (lines, font, size), else `null`. The
  /// split is the one with the narrowest wider half; the lines sit 1.2 em
  /// apart, so three of them take 3.4 em of the box's height.
  (List<String>, HudFont, int)? threeLineFit(
    List<String> parts,
    int size,
    num heightPx,
    num widthPx,
    Object? family,
    Object? weight,
  ) {
    final cap = _min(size, (heightPx / 3.4).truncate());
    final font = fonts.get(_max(1, cap), family, weight);
    var widest = 0;
    var widestLength = double.negativeInfinity;
    for (var i = 0; i < parts.length; i++) {
      final length = font.getlength(parts[i]);
      if (length > widestLength) {
        widestLength = length;
        widest = i;
      }
    }
    final words = _words(parts[widest]);
    if (parts.length != 2 || words.length < 2) {
      return null;
    }
    var cut = 1;
    var best = double.infinity;
    for (var i = 1; i < words.length; i++) {
      final wider = pyMax(
        font.getlength(words.sublist(0, i).join(' ')),
        font.getlength(words.sublist(i).join(' ')),
      );
      if (wider < best) {
        best = wider;
        cut = i;
      }
    }
    final lines = [
      ...parts.sublist(0, widest),
      words.sublist(0, cut).join(' '),
      words.sublist(cut).join(' '),
      ...parts.sublist(widest + 1),
    ];
    final (fitted, fittedSize) = fitFontLines(
      lines,
      cap,
      widthPx,
      family,
      weight,
    );
    return (lines, fitted, fittedSize);
  }

  /// A device notification in the brand's style. "text" (Perdix 2): the
  /// caption top left and the confirm hint top right in the caption
  /// colour, the message under them in the notice colour, shrunk to fit
  /// `width`. "banner" (Teric): a filled band in the notice colour with
  /// the caption small above the message and the confirm hint at the right
  /// edge. "box" (Descent X50i): a dark box with a border in the notice
  /// colour, a warning triangle and the message on up to three lines.
  /// "frame" (Perdix 2 persistent notification): an outlined box with the
  /// parts of the message stacked inside.
  void drawNotice(Map<String, dynamic> elem, Notice notice) {
    final (caption, confirm, message, style) = noticeLines(ctx, elem, notice);
    final scale = skin.scale;
    final itemScale = _number(elem, 'scale', 1.0).toDouble();
    final x0 = absX(elem);
    final y0 = absY(elem);
    final widthPx = _max(
      8,
      (_number(elem, 'width', 400).toDouble() * scale).truncate(),
    );
    final msgSize = _max(
      1,
      (_number(elem, 'font_size', 40).toDouble() * scale * itemScale)
          .truncate(),
    );
    final capSize = _max(
      1,
      (_number(elem, 'caption_font_size', 18).toDouble() * scale * itemScale)
          .truncate(),
    );
    final family = elem['font_family'];
    final weight = elem['font_weight'];
    Object? first(List<Object?> values) =>
        values.firstWhere(truthy, orElse: () => values.last);
    final styleColor = _get(style, 'color', '#FFFF00');
    final colour = hexRgb('${first([notice.color, styleColor])}');
    final textColour = hexRgb(
      '${first([notice.textColor, style['text_color'], notice.color, styleColor])}',
    );
    final capColour = hexRgb(
      '${first([elem['caption_color'], style['caption_color'], '#FFFF00'])}',
    );
    final outline = truthy(elem['outline']);
    final capFont = fonts.get(capSize, family, weight);
    final capH = (capSize * 1.25).truncate();
    int heightOf() =>
        _max(4, (_number(elem, 'height', 60).toDouble() * scale).truncate());

    if (style['style'] == 'frame') {
      final heightPx = heightOf();
      final pad = _max(2, (heightPx * 0.06).truncate());
      roundedRect(
        x0,
        y0,
        x0 + widthPx,
        y0 + heightPx,
        _max(2, (heightPx * 0.08).truncate()),
        outline: colour,
        width: _max(1, (heightPx * 0.03).truncate()),
      );
      var parts = [
        for (final p in message.split('\n'))
          if (p.pyStrip().isNotEmpty) p.pyStrip(),
      ];
      if (parts.isEmpty) {
        parts = [message];
      }
      final lineH = (heightPx - 2 * pad) / _max(1, parts.length);
      for (var i = 0; i < parts.length; i++) {
        final part = parts[i];
        final (font, size) = fitFont(
          part,
          _min(msgSize, (lineH * 0.9).truncate()),
          widthPx - 2 * pad,
          family,
          weight,
        );
        final (left, _, right, _) = font.getbbox(part);
        final x = x0 + _floorDiv(widthPx - (right - left), 2) - left;
        text(
          x,
          (y0 + pad + i * lineH + (lineH - size) / 2).truncate(),
          part,
          font,
          colour,
        );
      }
      return;
    }

    if (style['style'] == 'box') {
      final heightPx = heightOf();
      final pad = _max(2, (heightPx * 0.1).truncate());
      roundedRect(
        x0,
        y0,
        x0 + widthPx,
        y0 + heightPx,
        _max(2, (heightPx * 0.12).truncate()),
        fill: (20, 20, 20),
        outline: colour,
        width: _max(1, (heightPx * 0.03).truncate()),
      );
      // A warning carries the triangle in a left column; an information
      // alert (`icon: none`) has none and its text centred.
      final icon = first([notice.icon, style['icon'], 'warning']) != 'none';
      final int innerX;
      if (icon) {
        final tri = (heightPx * 0.5).truncate();
        final tx = x0 + pad;
        final ty = y0 + _floorDiv(heightPx - tri, 2);
        ops.add(
          PolygonOp(
            [
              ((tx + tri ~/ 2).toDouble(), ty.toDouble()),
              (tx.toDouble(), (ty + tri).toDouble()),
              ((tx + tri).toDouble(), (ty + tri).toDouble()),
            ],
            outline: colour,
            width: _max(1, tri ~/ 10),
          ),
        );
        // The "!" drawn to the triangle's size: a bar and a dot.
        final stroke = _max(1, tri ~/ 10);
        final mid = (tx + tri ~/ 2).toDouble();
        ops.add(
          LineOp(
            [
              (mid, (ty + (tri * 0.38).truncate()).toDouble()),
              (mid, (ty + (tri * 0.72).truncate()).toDouble()),
            ],
            colour,
            stroke,
          ),
        );
        final dot = _max(1, stroke ~/ 2 + 1);
        final dotY = ty + (tri * 0.84).truncate();
        ops.add(
          EllipseOp(
            mid - dot,
            (dotY - dot).toDouble(),
            mid + dot,
            (dotY + dot).toDouble(),
            fill: colour,
          ),
        );
        innerX = tx + tri + pad;
      } else {
        innerX = x0 + pad;
      }
      final innerW = x0 + widthPx - pad - innerX;
      // Two lines at a sentence boundary when the text has one, else
      // wrapped at a word.
      final wrapped = message.contains('\n')
          ? message
          : message.replaceAll('. ', '.\n');
      var parts = [
        for (final p in wrapped.split('\n'))
          if (p.pyStrip().isNotEmpty) p.pyStrip(),
      ].take(2).toList();
      if (parts.isEmpty) {
        return;
      }
      // The text's share of a line's height.
      final fill = _number(elem, 'line_fill', 0.8).toDouble();
      if (parts.length == 1) {
        parts = wrapTwoLines(
          parts[0],
          fonts.get(
            _max(
              1,
              _min(
                msgSize,
                (_floorDiv(heightPx - 2 * pad, 2) * fill).truncate(),
              ),
            ),
            family,
            weight,
          ),
          innerW,
        );
      }
      final lineH = _floorDiv(heightPx - 2 * pad, _max(1, parts.length));
      var (font, size) = fitFontLines(
        parts,
        _min(msgSize, (lineH * fill).truncate()),
        innerW,
        family,
        weight,
      );
      final int pitch;
      final int firstY;
      if (truthy(elem['line_fill'])) {
        // A line too long for the box at a readable size goes on two.
        final three = threeLineFit(
          parts,
          msgSize,
          heightPx - 2 * pad,
          innerW,
          family,
          weight,
        );
        if (three != null && three.$3 > size) {
          (parts, font, size) = three;
        }
        // The lines 1.2 em apart, their ink centred in the box.
        pitch = _round(size * 1.2);
        final inkTop = font.getbbox(parts.first).$2;
        final inkBottom =
            (parts.length - 1) * pitch + font.getbbox(parts.last).$4;
        firstY = y0 + _floorDiv(heightPx - (inkBottom - inkTop), 2) - inkTop;
      } else {
        pitch = lineH;
        firstY = y0 + pad + _floorDiv(lineH - size, 2);
      }
      for (var i = 0; i < parts.length; i++) {
        final part = parts[i];
        final num x = icon
            ? innerX
            : innerX + ((innerW - font.getlength(part)) / 2).floorToDouble();
        text(x, firstY + i * pitch, part, font, textColour);
      }
      return;
    }

    if (style['style'] == 'banner') {
      final heightPx = heightOf();
      final pad = _max(2, (heightPx * 0.08).truncate());
      roundedRect(
        x0,
        y0,
        x0 + widthPx,
        y0 + heightPx,
        _max(2, (heightPx * 0.12).truncate()),
        fill: colour,
      );
      var inner = widthPx - 2 * pad;
      if (confirm.isNotEmpty) {
        final length = capFont.getlength(confirm);
        inner -= length.truncate() + pad;
        text(
          x0 + widthPx - pad - length,
          y0 + pad,
          confirm,
          capFont,
          textColour,
        );
      }
      if (caption.isNotEmpty) {
        text(x0 + pad, y0 + pad, caption, capFont, textColour);
      }
      final (font, _) = fitFont(
        message,
        _min(msgSize, heightPx - capH - 2 * pad),
        inner,
        family,
        weight,
      );
      text(x0 + pad, y0 + pad + capH, message, font, textColour);
      return;
    }

    final (font, size) = fitFont(message, msgSize, widthPx, family, weight);
    final capO = _max(1, (capSize / 20).truncate());
    if (caption.isNotEmpty) {
      if (outline) {
        outlineCopies(x0, y0, caption, capFont, capO);
      }
      text(x0, y0, caption, capFont, capColour);
    }
    if (confirm.isNotEmpty) {
      final cx = x0 + widthPx - capFont.getlength(confirm);
      if (outline) {
        outlineCopies(cx, y0, confirm, capFont, capO);
      }
      text(cx, y0, confirm, capFont, capColour);
    }
    final my = y0 + (caption.isNotEmpty || confirm.isNotEmpty ? capH : 0);
    if (outline) {
      outlineCopies(x0, my, message, font, _max(1, (size / 20).truncate()));
    }
    text(x0, my, message, font, textColour);
  }

  // --- depth graph ---

  /// (text, in deco) of a graph's stop label, 'STOP 6m 2:00' while a stop
  /// is pending, else `null`: out of deco the label shows nothing.
  (String, bool)? graphStopLabel(Waypoint? waypoint) {
    if (waypoint == null) {
      return null;
    }
    final stop = stopDepthOf(waypoint);
    if (stop <= 0) {
      return null;
    }
    final seconds = waypoint.nextStopTime;
    final time = seconds != null && seconds != 0
        ? ' ${_floorDiv(seconds, 60)}:'
              '${(seconds % 60).toString().padLeft(2, '0')}'
        : '';
    return (
      'STOP ${pyFormatG(u.stopDepth(stop, units))}${u.depthLabel(units)}$time',
      true,
    );
  }

  /// A graph's optional `stop_label`: the current stop as text next to the
  /// playback cursor, in the stops colour.
  void drawGraphStopLabel(
    Map<String, dynamic> elem,
    Waypoint? waypoint,
    List<Waypoint>? waypoints,
  ) {
    final label = graphStopLabel(waypoint);
    if (waypoints == null || waypoints.length < 2 || label == null) {
      return;
    }
    final graphW =
        (_number(elem, 'width', 300) * skin.userScale * skin.resScale)
            .truncate();
    final graphH =
        (_number(elem, 'height', 150) * skin.userScale * skin.resScale)
            .truncate();
    final x0 = absX(elem);
    final y0 = absY(elem);
    var maxD = 0.0;
    for (final wp in waypoints) {
      maxD = pyMax(maxD, wp.depth ?? 0.0);
    }
    maxD = (maxD > 0 ? maxD : 1.0) * 1.1;
    final t0 = waypoints.first.timeSinceStart;
    final span = waypoints.last.timeSinceStart - t0;
    final totalT = span == 0 ? 1 : span;
    double xForTime(int t) =>
        x0 + pyMin(1.0, pyMax(0.0, (t - t0) / totalT)) * graphW;
    int yForDepth(double d) => (y0 + d * graphH / maxD).truncate();

    final (labelText, inDeco) = label;
    final scale = skin.resScale * skin.userScale;
    final font = fonts.get(
      _max(1, (_number(elem, 'font_size', 16) * scale).truncate()),
      elem['font_family'],
      elem['font_weight'],
    );
    final color = inDeco && truthy(elem['stops_color'])
        ? elem['stops_color']
        : _get(elem, 'color', '#00FF00');
    final (left, top, right, bottom) = font.getbbox(labelText);
    final pad = (6 * scale).truncate();
    final wp = waypoint!;
    var x = xForTime(wp.timeSinceStart) + pad;
    if (x + (right - left) > x0 + graphW) {
      // Flip to the cursor's left near the end.
      x = xForTime(wp.timeSinceStart) - pad - (right - left);
    }
    final y = _min(
      _max(y0, yForDepth(wp.depth ?? 0.0) - (bottom - top) - pad),
      y0 + graphH - (bottom - top),
    );
    text(
      x - left,
      y - top,
      labelText,
      font,
      hexRgb('$color'),
      strokeWidth: _max(1, (2 * scale).truncate()),
      strokeColor: _black,
    );
  }

  void drawDepthGraph(
    Map<String, dynamic> elem,
    Waypoint? waypoint,
    List<Waypoint>? waypoints,
  ) {
    final resScale = skin.resScale;
    final graphW = (_number(elem, 'width', 300) * skin.userScale * resScale)
        .truncate();
    final graphH = (_number(elem, 'height', 150) * skin.userScale * resScale)
        .truncate();
    final x0 = absX(elem);
    final y0 = absY(elem);
    final colorRgb = hexRgb('${_get(elem, 'color', '#00FF00')}');

    // The background box and its border.
    final backgroundOpacity = graphOpacity(
      elem,
      'background_opacity',
      graphBackgroundOpacity,
    );
    if (backgroundOpacity > 0) {
      final background = truthy(elem['background_color'])
          ? hexRgb('${elem['background_color']}')
          : _black;
      ops.add(
        BlendOp(backgroundOpacity, [
          CvRectOp(x0, y0, x0 + graphW, y0 + graphH, background, -1),
          CvRectOp(x0, y0, x0 + graphW, y0 + graphH, colorRgb, 1),
        ]),
      );
    }
    if (waypoints == null || waypoints.isEmpty) {
      return;
    }
    var maxD = waypoints.first.depth ?? 0.0;
    for (final wp in waypoints) {
      maxD = pyMax(maxD, wp.depth ?? 0.0);
    }
    if (maxD <= 0) {
      maxD = 1.0;
    }
    maxD *= 1.1;
    final count = waypoints.length;
    if (count < 2) {
      return;
    }

    // By elapsed dive time, not by sample: logs are not evenly sampled,
    // and the graph always shows the whole dive.
    final t0 = waypoints.first.timeSinceStart;
    var totalT = waypoints.last.timeSinceStart - t0;
    if (totalT <= 0) {
      totalT = 1;
    }
    final dy = graphH / maxD;
    double xForTime(int t) =>
        x0 + pyMin(1.0, pyMax(0.0, (t - t0) / totalT)) * graphW;
    int yForDepth(double? d) => (y0 + (d ?? 0.0) * dy).truncate();
    (int, int) point(Waypoint wp) =>
        (xForTime(wp.timeSinceStart).truncate(), yForDepth(wp.depth));

    // reveal_profile: the line and fill only run up to the playback
    // position (the axes still span the whole dive).
    final reveal = truthy(elem['reveal_profile']);
    final revealT = waypoint?.timeSinceStart;
    var shown = waypoints;
    if (reveal && revealT != null) {
      shown = [
        for (final wp in waypoints)
          if (wp.timeSinceStart <= revealT) wp,
      ];
      if (shown.isEmpty) {
        shown = waypoints.sublist(0, 1);
      }
    }
    // The deco shading follows the same switch.
    final shadeT = reveal ? revealT : waypoints.last.timeSinceStart;

    final fillOpacity = graphOpacity(elem, 'fill_opacity', graphFillOpacity);
    if (fillOpacity > 0) {
      ops.add(
        BlendOp(fillOpacity, [
          CvFillOp(
            [
              (x0, y0),
              for (final wp in shown) point(wp),
              (xForTime(shown.last.timeSinceStart).truncate(), y0),
            ],
            truthy(elem['fill_color'])
                ? hexRgb('${elem['fill_color']}')
                : colorRgb,
          ),
        ]),
      );
    }

    if (waypoint != null && truthy(elem['stops_color'])) {
      _drawDecoHistory(elem, waypoints, shadeT!, xForTime, yForDepth, y0);
    } else if (waypoint != null) {
      // A band from the surface down to each waypoint's own stop depth.
      final ceilingRgb = hexRgb('${_get(elem, 'ceiling_color', '#808080')}');
      final band = <HudOp>[];
      for (var i = 0; i < count; i++) {
        final wp = waypoints[i];
        if (wp.timeSinceStart > shadeT!) {
          break;
        }
        final ceiling = wp.decoStopDepth;
        if (ceiling == null || ceiling <= 0) {
          continue;
        }
        final nextT = i + 1 < count ? waypoints[i + 1].timeSinceStart : shadeT;
        final xStart = xForTime(wp.timeSinceStart).truncate();
        final xEnd = _max(xStart + 1, xForTime(_min(nextT, shadeT)).truncate());
        band.add(
          CvRectOp(xStart, y0, xEnd, yForDepth(ceiling), ceilingRgb, -1),
        );
      }
      final bandOpacity = graphOpacity(
        elem,
        'ceiling_opacity',
        graphBandOpacity,
      );
      if (band.isNotEmpty && bandOpacity > 0) {
        ops.add(BlendOp(bandOpacity, band));
      }
    }

    ops.add(
      CvPolylineOp(
        [for (final wp in shown) point(wp)],
        colorRgb,
        (2 * resScale).truncate(),
      ),
    );

    if (waypoint != null) {
      // The cursor: the waypoint nearest in time.
      var current = waypoints.first;
      Duration? closest;
      for (final wp in waypoints) {
        final diff = wp.timestamp.difference(waypoint.timestamp).abs();
        if (closest == null || diff < closest) {
          closest = diff;
          current = wp;
        }
      }
      final (cx, cy) = point(current);
      ops.add(CvLineOp(cx, y0, cx, y0 + graphH, colorRgb, 1));
      final size = (_number(elem, 'marker_size', 6) * resScale).truncate();
      switch (_get(elem, 'marker_style', 'dot')) {
        case 'dot':
          ops
            ..add(CvCircleOp(cx, cy, size, colorRgb, -1))
            ..add(CvCircleOp(cx, cy, size, _white, 1));
        case 'cross':
          ops
            ..add(CvLineOp(cx - size, cy, cx + size, cy, colorRgb, 1))
            ..add(CvLineOp(cx, cy - size, cx, cy + size, colorRgb, 1));
        case 'bold_cross':
          final thickness = _max(2, (3 * resScale).truncate());
          ops
            ..add(CvLineOp(cx - size, cy, cx + size, cy, colorRgb, thickness))
            ..add(CvLineOp(cx, cy - size, cx, cy + size, colorRgb, thickness));
      }
    }
  }

  /// A graph with `stops_color`: the deco stops and the ceiling as two
  /// shaded areas, both drawn up to [revealT] and never erased afterwards.
  /// The stops are a stepped area from the surface down to each stop level;
  /// the recomputed ceiling a smooth area on top.
  void _drawDecoHistory(
    Map<String, dynamic> elem,
    List<Waypoint> waypoints,
    int revealT,
    double Function(int) xForTime,
    int Function(double?) yForDepth,
    int y0,
  ) {
    final stopsRgb = hexRgb('${elem['stops_color']}');
    final ceilingRgb = hexRgb('${_get(elem, 'ceiling_color', '#808080')}');
    final revealed = [
      for (final wp in waypoints)
        if (wp.timeSinceStart <= revealT) wp,
    ];
    if (revealed.isEmpty) {
      return;
    }
    final stops = <HudOp>[];
    for (var i = 0; i < revealed.length; i++) {
      final wp = revealed[i];
      final stop = stopDepthOf(wp);
      if (stop <= 0) {
        continue;
      }
      final nextT = i + 1 < waypoints.length
          ? waypoints[i + 1].timeSinceStart
          : revealT;
      final xStart = xForTime(wp.timeSinceStart).truncate();
      final xEnd = _max(xStart + 1, xForTime(_min(nextT, revealT)).truncate());
      stops.add(CvRectOp(xStart, y0, xEnd, yForDepth(stop), stopsRgb, -1));
    }
    final stopsOpacity = graphOpacity(elem, 'stops_opacity', graphStopsOpacity);
    if (stops.isNotEmpty && stopsOpacity > 0) {
      ops.add(BlendOp(stopsOpacity, stops));
    }

    if (revealed.any((wp) => (wp.ceiling ?? 0) > 0)) {
      final ceilingOpacity = graphOpacity(
        elem,
        'ceiling_opacity',
        graphCeilingOpacity,
      );
      if (ceilingOpacity > 0) {
        ops.add(
          BlendOp(ceilingOpacity, [
            CvFillOp([
              (xForTime(revealed.first.timeSinceStart).truncate(), y0),
              for (final wp in revealed)
                (
                  xForTime(wp.timeSinceStart).truncate(),
                  yForDepth(wp.ceiling ?? 0.0),
                ),
              (xForTime(revealed.last.timeSinceStart).truncate(), y0),
            ], ceilingRgb),
          ]),
        );
      }
    }
  }
}
