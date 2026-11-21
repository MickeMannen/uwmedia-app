/// The logic of the Overlay Designer that needs no canvas (Python
/// `utils/hud_designer.py`): anchor maths, reading a layout's elements,
/// element bounds and hit-testing, and alignment.
///
/// The layout schema is the template files' own (spec §5), so what the
/// designer saves loads in the renderer unchanged, and the other way
/// round.
library;

import 'dart:math' as math;

import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/hud_geometry.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/hud_text.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/units/units.dart' show UnitSystem;
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

/// The nine places a skin can be anchored to.
const anchors = [
  'TOP_LEFT', 'TOP_CENTER', 'TOP_RIGHT', //
  'MIDDLE_LEFT', 'CENTER', 'MIDDLE_RIGHT',
  'BOTTOM_LEFT', 'BOTTOM_CENTER', 'BOTTOM_RIGHT',
];

/// The marker styles of a depth graph.
const markerStyles = ['dot', 'cross', 'bold_cross'];

/// The kinds of element.
const elementKinds = [
  'text', 'badge', 'tank_icon', 'graph', 'tissue_bar', 'ascent_chevrons', //
  'notice', 'tank_switch_arrows', 'arc', 'segment_bar',
];

/// The top-left corner of the skin, from its anchor and offset.
(double, double) resolveAnchorPosition(
  String anchor,
  num refX,
  num refY,
  num viewW,
  num viewH,
  num skinW,
  num skinH,
) {
  var baseX = 0.0;
  var baseY = 0.0;
  var pivotX = 0.0;
  var pivotY = 0.0;
  if (anchor.contains('CENTER')) {
    baseX = viewW / 2.0;
    pivotX = skinW / 2.0;
  } else if (anchor.contains('RIGHT')) {
    baseX = viewW.toDouble();
    pivotX = skinW.toDouble();
  }
  if (anchor.contains('MIDDLE')) {
    baseY = viewH / 2.0;
    pivotY = skinH / 2.0;
  } else if (anchor.contains('BOTTOM')) {
    baseY = viewH.toDouble();
    pivotY = skinH.toDouble();
  }
  return (baseX + refX - pivotX, baseY + refY - pivotY);
}

/// The top-left corner of the skin from a `hud_skin` block: anchor and
/// offset when it has them, else the older `x_pct`/`y_pct`.
(double, double) resolveSkinPosition(
  Map<String, dynamic> skin,
  num skinW,
  num skinH,
  num viewW,
  num viewH,
) {
  final refX = skin['ref_offset_x'];
  final refY = skin['ref_offset_y'];
  if (refX is num && refY is num) {
    final anchor = skin['anchor'] as String? ?? 'TOP_LEFT';
    return resolveAnchorPosition(
      anchor,
      refX,
      refY,
      viewW,
      viewH,
      skinW,
      skinH,
    );
  }
  return (
    elemNum(skin, 'x_pct', 0.0) * viewW.toDouble(),
    elemNum(skin, 'y_pct', 0.0) * viewH.toDouble(),
  );
}

/// The skin's size in design pixels.
(double, double) skinPixelSize(Map<String, dynamic> skin) {
  if (skin['type'] == 'shape') {
    return (
      elemNum(skin, 'width', 400).toDouble(),
      elemNum(skin, 'height', 200).toDouble(),
    );
  }
  final scale = elemNum(skin, 'scale', 1.0);
  return (
    (elemNum(skin, 'native_width', 0) * scale).toDouble(),
    (elemNum(skin, 'native_height', 0) * scale).toDouble(),
  );
}

/// One of [elementKinds]: "graph" also for the older form that only has
/// the field `depth_graph`, "text" for anything without a type.
String elementKind(Map<String, dynamic> element) {
  final kind = element['type'];
  if (kind == 'graph' || element['field'] == 'depth_graph') {
    return 'graph';
  }
  return kind is String && kind != 'text' && elementKinds.contains(kind)
      ? kind
      : 'text';
}

/// A new element of [kind] for [field], in the middle of the skin, with
/// the values the renderer would assume for missing keys.
Map<String, dynamic> elementDefaults(String kind, String field) => {
  'field': field,
  'rel_x': 0.5,
  'rel_y': 0.5,
  ...switch (kind) {
    'graph' => {
      'type': 'graph',
      'width': 300,
      'height': 150,
      'color': '#00FF00',
      'ceiling_color': '#808080',
      'marker_style': 'dot',
      'marker_size': 6,
    },
    'badge' => {
      'type': 'badge',
      'font_size': 16,
      'value_font_size': 32,
      'scale': 1.0,
    },
    'tank_icon' => {
      'type': 'tank_icon',
      'width': 20,
      'height': 30,
      'corner_radius': 4,
    },
    'tissue_bar' => {
      'type': 'tissue_bar',
      'field': 'n2_tissue_load',
      'width': 12,
      'height': 33,
      'marker_size': 4,
    },
    'ascent_chevrons' => {
      'type': 'ascent_chevrons',
      'field': 'ascent_rate',
      'width': 16,
      'height': 47,
      'up_count': 4,
      'down_count': 1,
    },
    // An arc gauge: NDL over 0-100 minutes.
    'arc' => {
      'type': 'arc',
      'width': 120,
      'height': 120,
      'thickness': 12,
      'start_angle': 135,
      'sweep': 270,
      'range_min': 0,
      'range_max': 6000,
      'color': '#7ED321',
    },
    // A segment bar: the ascent rate, 2 m/min a segment.
    'segment_bar' => {
      'type': 'segment_bar',
      'width': 12,
      'height': 60,
      'segments': 5,
      'segment_gap': 2,
      'range_min': 0,
      'range_max': 10,
      'color': '#7ED321',
    },
    // The device's own notification: the message fitted into `width`, a
    // caption line above it.
    'notice' => {
      'type': 'notice',
      'field': 'notice',
      'width': 400,
      'height': 60,
      'font_size': 40,
      'caption_font_size': 18,
      'scale': 1.0,
    },
    // The Descent's triangles pointing at the sidemount tank to breathe
    // from; nothing while the tanks are within the switch pressure.
    'tank_switch_arrows' => {
      'type': 'tank_switch_arrows',
      'field': 'tank_switch',
      'width': 23,
      'height': 44,
      'gap': 13,
      'count': 2,
    },
    _ => {'color': '#FFFFFF', 'font_size': 30, 'scale': 1.0},
  },
};

const Map<String, (String, Map<String, Object>)> _parseDefaults = {
  'graph': (
    'depth_graph',
    {
      'width': 300,
      'height': 150,
      'color': '#00FF00',
      'marker_style': 'dot',
      'marker_size': 6,
    },
  ),
  'badge': ('state_badge', {'font_size': 16, 'scale': 1.0}),
  'tank_icon': (
    'primary_tank_pressure',
    {'width': 20, 'height': 30, 'corner_radius': 4},
  ),
  'tissue_bar': (
    'n2_tissue_load',
    {'width': 12, 'height': 33, 'marker_size': 4},
  ),
  'ascent_chevrons': (
    'ascent_rate',
    {'width': 16, 'height': 47, 'up_count': 4, 'down_count': 1},
  ),
  'notice': (
    'notice',
    {
      'width': 400,
      'height': 60,
      'font_size': 40,
      'caption_font_size': 18,
      'scale': 1.0,
    },
  ),
  'tank_switch_arrows': (
    'tank_switch',
    {'width': 23, 'height': 44, 'gap': 13, 'count': 2},
  ),
  'arc': ('ndl', arcDefaults),
  'segment_bar': ('ascent_rate', segmentBarDefaults),
  'text': ('', {'color': '#FFFFFF', 'font_size': 16, 'scale': 1.0}),
};

/// The elements of a `hud_skin` block, each with every key of the file
/// and the defaults of its kind for the keys it leaves out. Throws an
/// [ArgumentError] for an element without `rel_x` or `rel_y`.
List<Map<String, dynamic>> parseLayoutElements(Map<String, dynamic> hudSkin) {
  final out = <Map<String, dynamic>>[];
  for (final element
      in (hudSkin['linked_elements'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>()) {
    if (!element.containsKey('rel_x') || !element.containsKey('rel_y')) {
      throw ArgumentError.value(element, 'element', 'no rel_x or rel_y');
    }
    final kind = elementKind(element);
    final (field, defaults) = _parseDefaults[kind]!;
    final named = element['field'];
    // A text element keeps the field it has, an empty one too.
    final entry = {
      ...element,
      'field': truthy(named) || (kind == 'text' && element.containsKey('field'))
          ? named
          : field,
    };
    if (kind == 'graph') {
      entry['type'] = 'graph';
    }
    defaults.forEach((key, value) => entry.putIfAbsent(key, () => value));
    out.add(entry);
  }
  return out;
}

/// The fields an element can show: the model's own, the computed ones,
/// and with a [dive] its tanks by name.
List<String> availableTelemetryFields([Dive? dive]) {
  final fields = [
    ...Waypoint(timestamp: naive(2000), timeSinceStart: 0).toJson().keys,
    'primary_tank_pressure', 'primary_tank_name', //
    'secondary_tank_pressure', 'secondary_tank_name',
    'gasmix', 'gas_percent', 'safety_stop', 'safety_stop_depth',
    'time_of_day',
    // a rebreather's CC / BO / OC label and its diluent's PO2
    'circuit', 'diluent_po2',
    // info screens and gauge pages
    'avg_depth', 'min_temp', 'gf_setting', 'eod', 'date', 'ambient_mbar',
    'surface_mbar',
    // the ascent rate in m/min or ft/min, beside a Teric's arrows
    'ascent_rate_value',
    // the breathed gas's MOD at the brand's ppO2 limit
    'mod',
    // unit labels that follow the unit system
    'unit:depth', 'unit:pressure', 'unit:pressure_lower', 'unit:temp',
    'unit:sac', 'unit:volume_rate', 'unit:depth_rate',
  ]..remove('tanks');
  fields.sort();
  if (dive != null && dive.waypoints.isNotEmpty) {
    final tanks = {for (final wp in dive.waypoints) ...wp.tanks.keys}.toList()
      ..sort();
    for (final tank in tanks) {
      fields
        ..add('tank_pressure:$tank')
        ..add('tank_name:$tank');
    }
  }
  return fields;
}

/// What the designer calls an element of [field].
String elementDisplayName(String field) {
  if (field.startsWith('custom:')) {
    return field.replaceAll('custom:', '');
  }
  if (field.startsWith('tank_pressure:')) {
    return '${field.replaceAll('tank_pressure:', '')} (Bar)';
  }
  if (field.startsWith('tank_name:')) {
    return field.replaceAll('tank_name:', '');
  }
  return switch (field) {
    'depth_graph' => 'Depth Graph',
    'state_badge' => 'State Badge',
    'time_of_day' => 'Time of Day',
    _ => field,
  };
}

/// The index of the topmost (last drawn) box that holds the point, with
/// [slack] pixels of tolerance so that thin text can still be grabbed;
/// `null` when none does.
int? hitTestBounds(
  num x,
  num y,
  List<(num, num, num, num)> bounds, {
  num slack = 2.0,
}) {
  for (var index = bounds.length - 1; index >= 0; index--) {
    final (x0, y0, x1, y1) = bounds[index];
    if (x0 - slack <= x &&
        x <= x1 + slack &&
        y0 - slack <= y &&
        y <= y1 + slack) {
      return index;
    }
  }
  return null;
}

double _float(Map<String, dynamic> elem, String key, num fallback) =>
    elemNum(elem, key, fallback).toDouble();

const _oneToOne = SkinInfo(
  x: 0,
  y: 0,
  w: 0,
  h: 0,
  resScale: 1.0,
  userScale: 1.0,
  renderLog: true,
);

/// The part of the designer's logic that measures text, with the
/// renderer's own fonts and sizing.
class HudDesigner {
  HudDesigner(this.renderer);

  final HudRenderer renderer;

  HudFonts get _fonts => renderer.fonts;

  /// About how wide and high an element is in design pixels: a graph by
  /// its own size, text measured as the renderer draws it, of [text] when
  /// given (the value now shown) else of the element's display name.
  (double, double) measureElementBox(
    Map<String, dynamic> elem,
    Map<String, dynamic> skin, {
    String? text,
  }) {
    if (elem['type'] == 'graph') {
      return (_float(elem, 'width', 300), _float(elem, 'height', 150));
    }
    final skinScale = skin['type'] != 'shape'
        ? elemNum(skin, 'scale', 1.0)
        : 1.0;
    final size =
        (elemNum(elem, 'font_size', 16) *
                skinScale *
                elemNum(elem, 'scale', 1.0))
            .truncate();
    final fontSize = size < 1 ? 1 : size;
    final font = _fonts.get(fontSize, elem['font_family'], elem['font_weight']);
    var shown = text ?? '';
    if (shown.isEmpty) {
      final field = elem['field'];
      if (field is! String) {
        // Python: KeyError.
        throw ArgumentError.value(elem, 'elem', 'no field to name it by');
      }
      shown = elementDisplayName(field);
    }
    if (shown.isEmpty) {
      shown = '0';
    }
    double or(num value) => value == 0 ? fontSize.toDouble() : value.toDouble();
    if (verticalOrientations.contains(elem['orientation'])) {
      final (_, _, w, h) = orientedTextGeometry(
        font,
        shown,
        elem['orientation'],
        fontSize,
      );
      return (or(w), or(h));
    }
    final (left, top, right, bottom) = font.getbbox(shown);
    return (or(right - left), or(bottom - top));
  }

  /// The box of an element in the skin's own pixels, where the renderer
  /// puts it in the telemetry-only mode at skin scale 1, with the
  /// renderer's sizing, alignment and fonts. [text] is the value being
  /// shown (else the field's display name), [badgeLines] the renderer's
  /// lines of a badge (else one placeholder line, so that a badge that
  /// shows nothing in the normal state can still be selected). [units] is
  /// the unit system a unit after the value is written in.
  (double, double, double, double) elementNativeBounds(
    Map<String, dynamic> elem,
    num nativeW,
    num nativeH, {
    String? text,
    List<BadgeLine>? badgeLines,
    UnitSystem units = UnitSystem.metric,
  }) {
    final x = _float(elem, 'rel_x', 0.0) * nativeW;
    final y = _float(elem, 'rel_y', 0.0) * nativeH;
    final kind = elementKind(elem);
    switch (kind) {
      case 'graph':
        return (
          x,
          y,
          x + _float(elem, 'width', 300),
          y + _float(elem, 'height', 150),
        );
      case 'tissue_bar':
        final (w, h, r) = tissueBarGeometry(elem);
        return (x - r, y, x + w, y + h + r);
      case 'ascent_chevrons':
        final (w, h, _, _) = ascentChevronGeometry(elem);
        return (x, y, x + w, y + h);
      case 'arc':
        // The drawn band only: an open-bottomed arc's empty part is no
        // part of it.
        final (w, h, thick) = arcGeometry(elem);
        final start = _float(elem, 'start_angle', 135);
        final sweep = _float(elem, 'sweep', 270);
        final cx = x + w / 2.0;
        final cy = y + h / 2.0;
        final inner = (
          math.max(0.0, w / 2.0 - thick),
          math.max(0.0, h / 2.0 - thick),
        );
        var (x0, y0, x1, y1) = (
          double.infinity,
          double.infinity,
          double.negativeInfinity,
          double.negativeInfinity,
        );
        for (var i = 0; i < 73; i++) {
          final a = (start + sweep * i / 72.0) * math.pi / 180.0;
          for (final (rx, ry) in [(w / 2.0, h / 2.0), inner]) {
            final px = cx + rx * math.cos(a);
            final py = cy + ry * math.sin(a);
            x0 = math.min(x0, px);
            y0 = math.min(y0, py);
            x1 = math.max(x1, px);
            y1 = math.max(y1, py);
          }
        }
        return (x0, y0, x1, y1);
      case 'segment_bar':
        final (w, h, _, _) = segmentBarGeometry(elem);
        return (x, y, x + w, y + h);
      case 'tank_switch_arrows':
        final (w, h, gap, count) = tankSwitchArrowsGeometry(elem);
        return (x, y, x + count * w + (count - 1) * gap, y + h);
      case 'tank_icon' when elem['style'] == 'segments':
        final (n, gap, _, pad, stroke, nose, nub) = tankSegmentsGeometry(elem);
        final totalW = n * _float(elem, 'width', 12) + (n - 1) * gap;
        return (
          x - pad - stroke,
          y - pad - stroke,
          x + totalW + pad + stroke + nose + nub,
          y + _float(elem, 'height', 23) + pad + stroke,
        );
      case 'tank_icon':
        final w = _float(elem, 'width', 20);
        final h = _float(elem, 'height', 30);
        final metrics = tankOutlineMetrics(elem);
        if (metrics == null) {
          return (x, y, x + w, y + h);
        }
        final (gap, stroke, capH) = metrics;
        final pad = gap + stroke;
        return (x - pad, y - pad - capH + stroke, x + w + pad, y + h + pad);
    }

    final family = elem['font_family'];
    final weight = elem['font_weight'];
    final align = elem['align'] ?? 'left';
    final valign = elem['valign'] ?? 'top';
    final style = elem['style'];

    if (kind == 'notice') {
      // The caption line over the message line, inside `width`; a banner
      // has its own height.
      final w = _float(elem, 'width', 400);
      if (style == 'banner' || style == 'box' || style == 'frame') {
        return (x, y, x + w, y + _float(elem, 'height', 60));
      }
      final scale = _float(elem, 'scale', 1.0);
      final size = _float(elem, 'font_size', 40) * scale;
      final cap = _float(elem, 'caption_font_size', 18) * scale;
      return (x, y, x + w, y + cap * 1.25 + size * 1.2);
    }
    if (kind == 'badge' && style == 'box') {
      return (
        x,
        y,
        x + _float(elem, 'width', 80),
        y + _float(elem, 'height', 44),
      );
    }
    if (kind == 'badge') {
      final (labelSize, valueSize) = badgeLineSizes(elem, _oneToOne);
      final lines = badgeLines == null || badgeLines.isEmpty
          ? <BadgeLine>[
              (elementDisplayName('state_badge'), (255, 255, 255), false),
            ]
          : badgeLines;
      final spacing = _float(elem, 'line_spacing', 1.2);
      var blockH = 0;
      for (final (_, _, isValue) in lines) {
        blockH += ((isValue ? valueSize : labelSize) * spacing).truncate();
      }
      final y0 =
          y -
          (valign == 'bottom'
              ? blockH
              : valign == 'middle'
              ? blockH ~/ 2
              : 0);
      var x0 = double.infinity;
      var x1 = double.negativeInfinity;
      // A badge state's value_align "center" (Shearwater safety stop) is
      // not mirrored here: the title is the widest line there, so the box
      // is the same; only a timer wider than its title would poke out.
      final unitScale = badgeUnitScaleOf(elem);
      for (final (lineText, _, isValue) in lines) {
        final lineUnits = isValue ? unitScale : null;
        final size = fittedBadgeLineSize(
          _fonts,
          elem,
          lineText,
          isValue ? valueSize : labelSize,
          1.0,
          lineUnits,
        );
        final font = _fonts.get(size, family, weight);
        final (dx, left, right) = badgeLineAnchor(
          _fonts,
          font,
          lineText,
          size,
          align,
          lineUnits,
        );
        if (x + dx + left < x0) {
          x0 = x + dx + left;
        }
        if (x + dx + right > x1) {
          x1 = x + dx + right;
        }
      }
      return (x0, y0, x1, y0 + blockH);
    }

    final scaled = (_float(elem, 'font_size', 16) * _float(elem, 'scale', 1.0))
        .truncate();
    var size = scaled < 1 ? 1 : scaled;
    final field = elem['field'] as String? ?? '';
    var value = text ?? '';
    if (value.isEmpty) {
      value = elementDisplayName(field);
    }
    if (value.isEmpty) {
      value = '0';
    }
    if (verticalOrientations.contains(elem['orientation'])) {
      final font = _fonts.get(size, family, weight);
      final (dx, dy, w, h) = orientedTextGeometry(
        font,
        value,
        elem['orientation'],
        size,
        align,
        valign,
      );
      return (x + dx, y + dy, x + dx + w, y + dy + h);
    }
    final (main, suffix, suffixScale) = textParts(field, value, elem);
    final unit = unitSuffixText(elem, field, units);
    // A `max_width` shrinks the font.
    size = renderer.fittedFontSize(
      elem,
      size,
      main,
      suffixStr: suffix,
      suffixScale: suffixScale,
      unitText: unit,
    );
    final font = _fonts.get(size, family, weight);
    var (dx, dy, (left, top, r, b)) = textAnchorShift(
      font,
      main,
      align,
      valign,
    );
    var right = r.toDouble();
    var bottom = b.toDouble();
    double? suffixX;
    HudFont? suffixFont;
    if (suffix.isNotEmpty) {
      final suffixSize = pyRound(size * suffixScale);
      suffixFont = _fonts.get(suffixSize < 1 ? 1 : suffixSize, family, weight);
      final rawDx = elem['small_suffix_dx'];
      final suffixDx = truthy(rawDx) ? (pyFloatOf(rawDx) ?? 0.0) : 0.0;
      suffixX = font.getlength(main) + suffixDx;
      right = right + suffixDx + suffixFont.getlength(suffix);
      if (align == 'center') {
        dx = -(left + right) / 2.0;
      } else if (align == 'right') {
        dx = -right;
      }
    }
    dx += renderer.unitAlignShift(
      elem,
      font,
      main,
      suffix,
      suffixFont,
      size,
      unit,
      align,
      1.0,
    );
    if (unit.isNotEmpty) {
      // The unit drawn after the value, in skin pixels (scale 1).
      final (ux, uy, unitFont, unitSize) = renderer.unitSuffixGeometry(
        elem,
        font,
        main,
        size,
        right,
        suffixX,
        1.0,
        unit,
      );
      var (_, _, ur, ub) = unitFont.getbbox(unit);
      if (verticalOrientations.contains(elem['unit_orientation'])) {
        // The box the turned or stacked unit is painted in from (ux, uy).
        final (_, _, w, h) = orientedTextGeometry(
          unitFont,
          unit,
          elem['unit_orientation'],
          unitSize,
        );
        ur = w;
        ub = h;
      }
      if (ux + ur > right) {
        right = ux + ur;
      }
      if (uy + ub > bottom) {
        bottom = uy + ub;
      }
    }
    return (x + dx + left, y + dy + top, x + dx + right, y + dy + bottom);
  }

  /// Aligns the elements at [indices] of [elements], changing their
  /// `rel_x` or `rel_y` in place. [mode] is `h_top`, `h_bottom`,
  /// `h_center`, `v_left`, `v_right` or `v_center`. Fewer than two
  /// elements, or a skin without a size, change nothing.
  void alignElements(
    List<Map<String, dynamic>> elements,
    List<int> indices,
    Map<String, dynamic> skin,
    String mode,
  ) {
    if (indices.length < 2) {
      return;
    }
    final (skinW, skinH) = skinPixelSize(skin);
    if (skinW == 0 || skinH == 0) {
      return;
    }
    final targets = [for (final i in indices) elements[i]];
    final boxes = [for (final e in targets) measureElementBox(e, skin)];
    final horizontal = mode.startsWith('h_');
    final key = horizontal ? 'rel_y' : 'rel_x';
    // Each element's start and its size along the axis, in skin fractions.
    final starts = [for (final e in targets) (e[key] as num).toDouble()];
    final sizes = [
      for (final (w, h) in boxes) horizontal ? h / skinH : w / skinW,
    ];
    double least(List<double> values) => values.reduce((a, b) => b < a ? b : a);
    double most(List<double> values) => values.reduce((a, b) => b > a ? b : a);
    final ends = [for (var i = 0; i < starts.length; i++) starts[i] + sizes[i]];
    switch (mode) {
      case 'h_top' || 'v_left':
        // The value itself, so that a whole number stays one in the file.
        final target = targets
            .map((e) => e[key] as num)
            .reduce((a, b) => b < a ? b : a);
        for (final e in targets) {
          e[key] = target;
        }
      case 'h_bottom' || 'v_right':
        final target = most(ends);
        for (final (i, e) in targets.indexed) {
          e[key] = target - sizes[i];
        }
      case 'h_center' || 'v_center':
        final center = (least(starts) + most(ends)) / 2.0;
        for (final (i, e) in targets.indexed) {
          e[key] = center - sizes[i] / 2.0;
        }
    }
  }
}
