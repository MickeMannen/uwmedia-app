/// The sizes, counts and shapes of the drawn overlay elements, ported from
/// `gui/hud_renderer.py` of the Python app (spec §5.3): what the renderer
/// and the Overlay Designer both work from. No fonts and no drawing here.
library;

import 'package:uwmedia_app/core/hud/hud_ops.dart';
import 'package:uwmedia_app/core/hud/hud_text.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

// Depth graph shading: `fill_color` / `fill_opacity` the area under the
// profile line, `stops_opacity` the deco-stop steps, `ceiling_opacity` the
// ceiling area, `background_color` / `background_opacity` the graph's box
// and its 1 px border; 0 hides it.
const double graphBackgroundOpacity = 0.4;
const double graphFillOpacity = 0.15;
const double graphStopsOpacity = 0.5;
const double graphCeilingOpacity = 0.4;
const double graphBandOpacity = 0.45;

/// A graph element's 0..1 shading opacity for [key], else [fallback].
double graphOpacity(Map<String, dynamic> elem, String key, double fallback) {
  if (!elem.containsKey(key)) {
    return fallback;
  }
  final value = pyFloatOf(elem[key]);
  return value == null ? fallback : value.clamp(0.0, 1.0);
}

/// A number of an element, else [fallback].
num elemNum(Map<String, dynamic> elem, String key, num fallback) {
  final value = elem[key];
  return value is num ? value : fallback;
}

/// Python `int(round(float(elem.get(key, fallback))))`.
int _rounded(Map<String, dynamic> elem, String key, num fallback) =>
    pyRound(elemNum(elem, key, fallback).toDouble());

int _max(int a, int b) => a > b ? a : b;

/// The deco stop a waypoint is logged at, on 3 m levels: the logged next
/// stop, else the stop depth rounded up to a level. 0 out of deco.
double stopDepthOf(Waypoint waypoint) {
  final next = waypoint.nextStopDepth ?? 0.0;
  if (next > 0) {
    return next;
  }
  final logged = waypoint.decoStopDepth ?? 0.0;
  return logged > 0 ? (logged / 3.0 - 1e-9).ceil() * 3.0 : 0.0;
}

/// (w, h) final pixel size of a `style: "box"` badge at [scale].
(int, int) badgeBoxSize(Map<String, dynamic> elem, double scale) => (
  _max(1, (elemNum(elem, 'width', 80) * scale).truncate()),
  _max(1, (elemNum(elem, 'height', 44) * scale).truncate()),
);

/// The Descent's "ascend to" mark as polygons: a bar with an arrow under
/// it, [cap] px tall (the height of the digits after it), its right edge at
/// [right]. Proportions from the screen.
List<List<HudPoint>> stopArrowShapes(double right, double top, double cap) {
  final width = 0.77 * cap;
  final bar = 0.13 * cap;
  final gap = 0.1 * cap;
  final head = 0.4 * cap;
  final stem = 0.27 * cap;
  final left = right - width;
  final mid = right - width / 2.0;
  final headTop = top + bar + gap;
  return [
    [(left, top), (right, top), (right, top + bar), (left, top + bar)],
    [(mid, headTop), (right, headTop + head), (left, headTop + head)],
    [
      (mid - stem / 2.0, headTop + head),
      (mid + stem / 2.0, headTop + head),
      (mid + stem / 2.0, top + cap),
      (mid - stem / 2.0, top + cap),
    ],
  ];
}

const int tankOutlineDefaultWidth = 2;
const int tankOutlineDefaultGap = 4;
const String tankOutlineDefaultColor = '#FFFFFF';

/// (gap, stroke, cap height) in native px of a tank icon's drawn outline
/// (`draw_outline`), or `null` when it draws none: a rounded rectangle
/// [gap] px outside the fill rectangle with a [stroke]-wide line, and a
/// small centred cap on top.
(int gap, int stroke, int capHeight)? tankOutlineMetrics(
  Map<String, dynamic> elem,
) {
  if (!truthy(elem['draw_outline'])) {
    return null;
  }
  var gap = tankOutlineDefaultGap;
  var stroke = tankOutlineDefaultWidth;
  final g = elem.containsKey('outline_gap')
      ? pyFloatOf(elem['outline_gap'])
      : gap.toDouble();
  final s = elem.containsKey('outline_width')
      ? pyFloatOf(elem['outline_width'])
      : stroke.toDouble();
  if (g != null && s != null) {
    gap = _max(0, pyRound(g));
    stroke = _max(1, pyRound(s));
  }
  return (gap, stroke, _max(2, gap + stroke));
}

const double tissueBarMaxPercent = 120.0;
const List<Map<String, dynamic>> tissueBarDefaultBands = [
  {'max': 80, 'color': '#00FF00'},
  {'min': 80, 'max': 100, 'color': '#FFC000'},
  {'min': 100, 'color': '#FF0000'},
];

/// (width, height, marker radius) in native px of a tissue-load bar.
(int, int, int) tissueBarGeometry(Map<String, dynamic> elem) => (
  _max(2, _rounded(elem, 'width', 12)),
  _max(4, _rounded(elem, 'height', 33)),
  _max(1, _rounded(elem, 'marker_size', 4)),
);

/// The "pointer" marker's two shapes, back to front, as (half height, left
/// edge, tip, colour) in px from the bar's left edge at the marker's
/// height, for a marker size of [size] px: the black ring that cuts into
/// the bar, then the white tab.
List<(double half, double left, double tip, Rgb color)> tissuePointerShapes(
  double size,
) => [
  (1.3 * size, -0.62 * size, 1.9 * size, (0, 0, 0)),
  (0.62 * size, -0.62 * size, 1.3 * size, (255, 255, 255)),
];

/// 0.0 (bottom) to 1.0 (top): where the marker sits for a tissue load in
/// percent, linear up to [tissueBarMaxPercent]. No value is 0.
double tissueBarMarkerFraction(Object? value) {
  final v = value == null ? null : pyFloatOf(value);
  return v == null ? 0.0 : (v / tissueBarMaxPercent).clamp(0.0, 1.0);
}

const double ascentFullScaleMPerMin = 12.0;
const double ascentDeadbandMPerMin = 0.5;
const List<Map<String, dynamic>> ascentDefaultBands = [
  {'max': 7.9, 'color': '#00FF00'},
  {'min': 7.9, 'max': 10.1, 'color': '#FFC000'},
  {'min': 10.1, 'color': '#FF0000'},
];
const Rgb chevronUnlit = (138, 138, 138);
const Rgb chevronSolidUnlit = (164, 164, 164);

// The "solid" style's shapes, in px on a 24 px wide indicator (a Descent
// X50i's screen): the apex's rise, a chevron's thickness, the step from
// one chevron to the next, the body of the flat-sided one next to the bar,
// the space either side of the bar and the bar itself.
const double solidChevronArrow = 8.0;
const double solidChevronThick = 12.0;
const double solidChevronPitch = 17.0;
const double solidChevronBody = 8.0;
const double solidChevronBarGap = 3.5;
const double solidChevronBar = 5.5;

/// A shape of the "solid" ascent indicator: [direction] "up", "down" or
/// "bar"; [kind] "chevron", "flat" (the flat-sided one next to the bar) or
/// "bar".
typedef SolidChevronShape = (
  String direction,
  String kind,
  double top,
  double bottom,
);

/// The "solid" style's shapes, top to bottom, in the units above, and the
/// total height.
(List<SolidChevronShape>, double) solidChevronLayout(
  int up,
  int down, {
  required bool showBar,
}) {
  const flatH = solidChevronArrow + solidChevronBody;
  const chevronH = solidChevronArrow + solidChevronThick;
  final shapes = <SolidChevronShape>[];
  var y = 0.0;
  for (var i = 0; i < up; i++) {
    final last = i == up - 1;
    final flat = last && showBar;
    final height = flat ? flatH : chevronH;
    shapes.add(('up', flat ? 'flat' : 'chevron', y, y + height));
    y += last ? height : solidChevronPitch;
  }
  if (showBar) {
    y += up != 0 ? solidChevronBarGap : 0.0;
    shapes.add(('bar', 'bar', y, y + solidChevronBar));
    y += solidChevronBar + (down != 0 ? solidChevronBarGap : 0.0);
  }
  for (var i = 0; i < down; i++) {
    final flat = i == 0 && showBar;
    // Mirrored: the first one's flat (or notched) side is at its top.
    final top = i == 0
        ? y
        : y + (showBar ? flatH : chevronH) + i * solidChevronPitch - chevronH;
    shapes.add((
      'down',
      flat ? 'flat' : 'chevron',
      top,
      top + (flat ? flatH : chevronH),
    ));
  }
  if (down != 0) {
    y += (showBar ? flatH : chevronH) + (down - 1) * solidChevronPitch;
  }
  return (shapes, y);
}

/// Ascent rate in m/min, positive when getting shallower: the waypoint's
/// own logged value (Garmin), else from the previous waypoint's depth in
/// [waypoints]. `null` when it cannot be told.
double? ascentRateFor(Waypoint? waypoint, [List<Waypoint>? waypoints]) {
  if (waypoint == null) {
    return null;
  }
  final rate = waypoint.ascentRate;
  if (rate != null) {
    return rate;
  }
  final depth = waypoint.depth;
  if (waypoints == null || waypoints.isEmpty || depth == null) {
    return null;
  }
  final t = waypoint.timeSinceStart;
  Waypoint? prev;
  for (final wp in waypoints) {
    if (wp.timeSinceStart >= t) {
      break;
    }
    prev = wp;
  }
  final prevDepth = prev?.depth;
  if (prev == null || prevDepth == null) {
    return null;
  }
  final dt = t - prev.timeSinceStart;
  if (dt <= 0) {
    return null;
  }
  return (prevDepth - depth) / dt * 60.0;
}

/// (width, height, up count, down count) of an ascent indicator, in native
/// px and counts.
(int, int, int, int) ascentChevronGeometry(Map<String, dynamic> elem) {
  final w = _max(4, _rounded(elem, 'width', 16));
  final h = _max(8, _rounded(elem, 'height', 47));
  var up = _max(0, elemNum(elem, 'up_count', 4).truncate());
  final down = _max(0, elemNum(elem, 'down_count', 1).truncate());
  if (up + down == 0) {
    up = 1;
  }
  return (w, h, up, down);
}

/// How many upward chevrons light for [rate] m/min (0 when level or
/// descending). Garmin (no [perChevron]): one at the deadband, then
/// linearly to all at full scale. With [perChevron] (the Perdix 2's "1
/// arrow per 3 m/min") one more arrow for every [perChevron] m/min.
int ascentLitCount(double? rate, int upCount, [Object? perChevron]) {
  if (rate == null || rate < ascentDeadbandMPerMin || upCount <= 0) {
    return 0;
  }
  final int lit;
  if (truthy(perChevron)) {
    lit = (rate / pyFloatOf(perChevron)!).ceil();
  } else {
    lit = (rate / ascentFullScaleMPerMin * upCount).truncate() + 1;
  }
  return lit.clamp(1, upCount);
}

const int tankSegmentsDefault = 5;
const int tankSegmentGapDefault = 2;
const double tankFullBarDefault = 200.0;
const Rgb tankSegmentUnlit = (58, 58, 58);
const String tankSegmentOutlineDefault = '#9A9A9A';

/// (segments, gap, full bar, pad, stroke, nose, nub) in native px of a tank
/// icon in the "segments" style: Shearwater's horizontal cylinder with N
/// pressure slots, a rounded shoulder and a valve nub on the right.
(int n, int gap, double fullBar, int pad, int stroke, int nose, int nub)
tankSegmentsGeometry(Map<String, dynamic> elem) {
  final n = _max(1, elemNum(elem, 'segments', tankSegmentsDefault).truncate());
  final gap = _max(0, _rounded(elem, 'segment_gap', tankSegmentGapDefault));
  final full = elem.containsKey('full_bar')
      ? pyFloatOf(elem['full_bar'])
      : tankFullBarDefault;
  final fullBar = full == null ? tankFullBarDefault : (full < 1.0 ? 1.0 : full);
  final pad = _max(0, _rounded(elem, 'outline_gap', 3));
  final stroke = _max(1, _rounded(elem, 'outline_width', 2));
  final h = _max(1, elemNum(elem, 'height', 30).truncate());
  final nose = _max(2, pyRound(h * 0.45));
  final nub = _max(2, pyRound(h * 0.18));
  return (n, gap, fullBar, pad, stroke, nose, nub);
}

/// How many of [segments] light for [pressure] bar (none without one); a
/// half rounds up.
int tankSegmentsLit(Object? pressure, double fullBar, int segments) {
  final value = pressure == null ? null : pyFloatOf(pressure);
  if (value == null) {
    return 0;
  }
  final frac = value / fullBar;
  if (frac <= 0) {
    return 0;
  }
  return (frac * segments + 0.5).truncate().clamp(1, segments);
}

/// 0..1 of a `fill_level` tank icon's height that is filled for a pressure
/// in bar: linear from `empty_bar` (0 unless set) to `full_bar` (200).
double tankFillFraction(Object? value, Map<String, dynamic> elem) {
  final full = elem.containsKey('full_bar')
      ? pyFloatOf(elem['full_bar'])
      : 200.0;
  final empty = elem.containsKey('empty_bar')
      ? pyFloatOf(elem['empty_bar'])
      : 0.0;
  final v = value == null ? null : pyFloatOf(value);
  if (full == null || empty == null || v == null) {
    return 0.0;
  }
  if (full <= empty) {
    return 1.0;
  }
  return ((v - empty) / (full - empty)).clamp(0.0, 1.0);
}

/// (triangle width, height, gap, count) in native px of a
/// `tank_switch_arrows` element: the Descent X50i's two triangles between
/// the sidemount pressures.
(int, int, int, int) tankSwitchArrowsGeometry(Map<String, dynamic> elem) => (
  _max(2, _rounded(elem, 'width', 23)),
  _max(2, _rounded(elem, 'height', 44)),
  _max(0, _rounded(elem, 'gap', 13)),
  _max(1, elemNum(elem, 'count', 2).truncate()),
);

/// Brightness of the triangle nearest the target tank and of the one
/// behind it, second by second: a march towards the tank.
const List<(double, double)> tankSwitchArrowPhases = [
  (1.0, 0.0),
  (0.6, 0.38),
  (1.0, 1.0),
  (1.0, 0.6),
];

/// Brightness 0..1 of each triangle, nearest the target first. Without a
/// clock all are lit.
List<double> tankSwitchArrowLevels(num? elapsed, int count) {
  if (elapsed == null) {
    return List.filled(count, 1.0);
  }
  final phase =
      tankSwitchArrowPhases[elapsed.truncate() % tankSwitchArrowPhases.length];
  return [for (var i = 0; i < count; i++) i == 0 ? phase.$1 : phase.$2];
}

// --- arc gauge and segment bar (Python gui/hud_renderer.py ARC_DEFAULTS,
// SEGMENT_BAR_DEFAULTS, arc_geometry, segment_bar_geometry, gauge_fraction)

/// The fields whose colour bands are a hud_rules.json list of their own.
const Map<String, String> gaugeBandRules = {
  'ascent_rate': 'ascent_rate',
  'n2_tissue_load': 'tissue_load',
};

/// An arc gauge's defaults: a 270-degree ring open at the bottom.
const Map<String, Object> arcDefaults = {
  'width': 120,
  'height': 120,
  'thickness': 12,
  'start_angle': 135,
  'sweep': 270,
  'range_min': 0,
  'range_max': 100,
  'segments': 1,
  'segment_gap': 0,
  'track_color': '#303030',
};

/// A segment bar's defaults: five segments, 2 m/min of ascent rate each.
const Map<String, Object> segmentBarDefaults = {
  'width': 12,
  'height': 60,
  'segments': 5,
  'segment_gap': 2,
  'range_min': 0,
  'range_max': 10,
  'track_color': '#303030',
};

double _float(Map<String, dynamic> elem, String key, Map<String, Object> d) =>
    elemNum(elem, key, d[key]! as num).toDouble();

/// (width, height, thickness) of an arc element in skin px.
(double, double, double) arcGeometry(Map<String, dynamic> elem) => (
  _float(elem, 'width', arcDefaults),
  _float(elem, 'height', arcDefaults),
  _float(elem, 'thickness', arcDefaults),
);

/// (width, height, segments, gap) of a segment bar in skin px.
(double, double, int, double) segmentBarGeometry(Map<String, dynamic> elem) => (
  _float(elem, 'width', segmentBarDefaults),
  _float(elem, 'height', segmentBarDefaults),
  _max(1, elemNum(elem, 'segments', 5).truncate()),
  _float(elem, 'segment_gap', segmentBarDefaults),
);

/// [value] as 0-1 of the element's range_min..range_max (raw units:
/// seconds for an NDL, bar for a tank, m/min for an ascent rate); 0
/// without a value or with an empty range.
double gaugeFraction(
  Map<String, dynamic> elem,
  double? value,
  Map<String, Object> defaults,
) {
  if (value == null) {
    return 0.0;
  }
  final low = _float(elem, 'range_min', defaults);
  final high = _float(elem, 'range_max', defaults);
  if (high <= low) {
    return 0.0;
  }
  return ((value - low) / (high - low)).clamp(0.0, 1.0);
}
