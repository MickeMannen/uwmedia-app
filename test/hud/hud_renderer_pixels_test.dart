// The pixel cases of the Python app's tests/test_hud_renderer.py: the
// overlay drawn by the port's renderer and painter (PhotoRun.paintLayout,
// what the app draws) and the pixels checked. Each test carries the name
// of the Python test it ports.
//
// The port's rasteriser is not Pillow's and OpenCV's (no hinting, glyphs a
// little heavier, other anti-aliased edges; "Arial" is Liberation Sans,
// spec §5.6), so the checks keep each Python test's intent with the port's
// own tolerances: something drawn, a colour present or absent, which way a
// marker moves, ink boxes compared with each other. Shapes are drawn
// without anti-aliasing, so exact colours are still counted for them.
// Python's colours are BGR; here they are written as RGB.
//
// Not in this file:
// - Covered without pixels in test/core/hud/hud_text_test.dart:
//   test_resolve_element_text_matches_renderer_paths,
//   test_badge_lines_none_for_normal_and_three_lines_for_deco,
//   test_rules_profile_borrows_another_brands_rules (its renders compared
//   as drawing operations, which is stricter than pixels),
//   test_graph_stop_label_text, test_perdix_badge_phases_from_the_manual,
//   test_sac_formats_like_the_perdix, test_teric_badge_lines_follow_its_manual,
//   test_ndl_shows_the_last_minute_as_00_and_99_plus_only_above_99_minutes,
//   test_garmin_clear_badge_keeps_the_cleared_stops_depth_and_flashes_it;
//   and the badge lines of test_perdix_3_badge_lines_and_boxed_title (its
//   boxed-title render is here).
// - The other ten without pixels (bounds, defaults, badge states, the
//   bundled pages' variants): test/core/hud/hud_renderer_cases_test.dart,
//   which names the two of them the designer fixture in
//   test/core/hud/hud_designer_test.dart already covers.
// - test_hud_renderer_text_scaling, test_hud_renderer_user_scale and
//   test_hud_renderer_badge_value_font_size_independent_of_label patch
//   Pillow's get_font to see the sizes asked for; here the same sizes are
//   read from the renderer's text operations instead.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/hud/hud_fonts.dart';
import 'package:uwmedia_app/core/hud/hud_geometry.dart';
import 'package:uwmedia_app/core/hud/hud_ops.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/engine/photo_run.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

final _rules = HudRules(
  jsonDecode(File('assets/hud_rules.json').readAsStringSync())
      as Map<String, dynamic>,
);
final _fonts = TtfFonts(
  (file) => File('assets/fonts/$file').readAsBytesSync(),
  inkTables: InkTables.parse(
    File('assets/fonts/ink_tables.bin').readAsBytesSync(),
  ),
);
final _renderer = HudRenderer(_fonts, _rules);
final _run = PhotoRun(renderer: _renderer, painter: HudPainter(_fonts));
final _t0 = naive(2026, 1, 1, 10);

typedef _Rgb = (int, int, int);

/// A rendered frame's RGB pixels.
class _Frame {
  _Frame(this.width, this.height, this.rgba);

  final int width;
  final int height;
  final Uint8List rgba;

  _Rgb at(int x, int y) {
    final i = 4 * (y * width + x);
    return (rgba[i], rgba[i + 1], rgba[i + 2]);
  }

  /// numpy's `frame[y0:y1, x0:x1]`.
  _Frame crop(int x0, int y0, int x1, int y1) {
    final w = x1 - x0;
    final out = Uint8List(w * (y1 - y0) * 4);
    for (var y = y0; y < y1; y++) {
      final from = 4 * (y * width + x0);
      out.setRange(4 * (y - y0) * w, 4 * (y - y0 + 1) * w, rgba, from);
    }
    return _Frame(w, y1 - y0, out);
  }

  Iterable<(int, int, _Rgb)> get pixels sync* {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        yield (x, y, at(x, y));
      }
    }
  }

  int count(bool Function(_Rgb c) test) =>
      pixels.where((px) => test(px.$3)).length;

  int countRgb(_Rgb c) => count((px) => px == c);

  /// The sum of every channel, numpy's `frame.sum()`.
  int get sum {
    var s = 0;
    for (var i = 0; i < rgba.length; i += 4) {
      s += rgba[i] + rgba[i + 1] + rgba[i + 2];
    }
    return s;
  }

  bool get isBlack => sum == 0;

  bool sameAs(_Frame other) {
    if (width != other.width || height != other.height) {
      return false;
    }
    for (var i = 0; i < rgba.length; i += 4) {
      if (rgba[i] != other.rgba[i] ||
          rgba[i + 1] != other.rgba[i + 1] ||
          rgba[i + 2] != other.rgba[i + 2]) {
        return false;
      }
    }
    return true;
  }

  /// (x0, y0, x1, y1) of the pixels that pass [test], inclusive.
  (int, int, int, int) box(bool Function(_Rgb c) test) {
    var x0 = width;
    var y0 = height;
    var x1 = -1;
    var y1 = -1;
    for (final (x, y, c) in pixels) {
      if (test(c)) {
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
    expect(x1, greaterThanOrEqualTo(0), reason: 'no such pixel');
    return (x0, y0, x1, y1);
  }

  /// The columns where some pixel passes [test].
  List<int> columns(bool Function(_Rgb c) test) => {
    for (final (x, _, c) in pixels)
      if (test(c)) x,
  }.toList()..sort();
}

int _max3(_Rgb c) => [c.$1, c.$2, c.$3].reduce((a, b) => a > b ? a : b);

Future<void>? _fontsLoaded;

Future<void> _loadFonts() async {
  for (final family in fontRegistry.values) {
    for (final file in family.values) {
      final loader = FontLoader(fontFamilyOf(file))
        ..addFont(
          Future.value(
            ByteData.sublistView(File('assets/fonts/$file').readAsBytesSync()),
          ),
        );
      await loader.load();
    }
  }
}

final _skins = <String, HudSkinPixels>{};

Future<HudSkinPixels?> _skinOf(Map<String, dynamic> layout) async {
  final hudSkin = layout['hud_skin'] as Map<String, dynamic>;
  final path = hudSkin['path'];
  if (hudSkin['type'] == 'shape' || path is! String) {
    return null;
  }
  if (_skins[path] case final skin?) {
    return skin;
  }
  final codec = await ui.instantiateImageCodec(File(path).readAsBytesSync());
  final image = (await codec.getNextFrame()).image;
  final data = await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  final skin = HudSkinPixels(
    data!.buffer.asUint8List(),
    image.width,
    image.height,
  );
  image.dispose();
  return _skins[path] = skin;
}

/// Python's `draw_hud(frame, layout, waypoint, ...)` on a frame of
/// [background] (black, as `np.zeros`).
Future<_Frame> _render(
  WidgetTester tester,
  Map<String, dynamic> layout,
  Waypoint? waypoint, {
  List<Waypoint>? waypoints,
  bool renderLog = false,
  int width = 1920,
  int height = 1080,
  _Rgb background = (0, 0, 0),
}) async {
  late _Frame frame;
  await tester.runAsync(() async {
    await (_fontsLoaded ??= _loadFonts());
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..drawRect(
        ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        ui.Paint()
          ..color = ui.Color.fromARGB(
            255,
            background.$1,
            background.$2,
            background.$3,
          ),
      );
    await _run.paintLayout(
      canvas,
      layout,
      await _skinOf(layout),
      waypoint ?? Waypoint(timestamp: _t0, timeSinceStart: 0),
      waypoints,
      width,
      height,
      renderLog: renderLog,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    final data = await image.toByteData();
    image.dispose();
    frame = _Frame(width, height, data!.buffer.asUint8List());
  });
  return frame;
}

/// The font sizes the renderer asks for (Python's `get_font` calls).
Set<int> _textSizes(
  Map<String, dynamic> layout,
  Waypoint waypoint, {
  bool renderLog = false,
  (int, int)? skinSize,
}) => {
  for (final op in _renderer.drawHud(
    frameWidth: 1920,
    frameHeight: 1080,
    layout: layout,
    waypoint: waypoint,
    skinSize: skinSize,
    renderLog: renderLog,
  ))
    if (op is TextOp) op.size else if (op is RotatedTextOp) op.size,
};

Waypoint _wp({
  int t = 0,
  DateTime? timestamp,
  double? depth,
  double maxDepth = 0.0,
  double? temp,
  int? diveTime,
  int? ndl,
  int? tts,
  int? airRemaining,
  double? volumeSac,
  double? pressureSac,
  double? po2,
  double? gf,
  int? cns,
  String? divemode,
  double? decoStopDepth,
  double? nextStopDepth,
  int? nextStopTime,
  double? ceiling,
  double? ascentRate,
  double? n2TissueLoad,
  List<String>? diveAlerts,
  Map<String, TankData>? tanks,
}) => Waypoint(
  timestamp: timestamp ?? _t0.add(Duration(seconds: t)),
  timeSinceStart: t,
  depth: depth,
  maxDepth: maxDepth,
  temp: temp,
  diveTime: diveTime,
  ndl: ndl,
  tts: tts,
  airRemaining: airRemaining,
  volumeSac: volumeSac,
  pressureSac: pressureSac,
  po2: po2,
  gf: gf,
  cns: cns,
  divemode: divemode,
  decoStopDepth: decoStopDepth,
  nextStopDepth: nextStopDepth,
  nextStopTime: nextStopTime,
  ceiling: ceiling,
  ascentRate: ascentRate,
  n2TissueLoad: n2TissueLoad,
  diveAlerts: diveAlerts,
  tanks: tanks,
);

TankData _tank(double bar, {double o2 = 21.0, double he = 0.0, String? name}) =>
    TankData(pressureBar: bar, o2Percent: o2, hePercent: he, name: name);

/// Python's `_shape_layout`.
Map<String, dynamic> _shapeLayout(
  List<Map<String, dynamic>> elements, [
  String manufacturer = 'Garmin',
  String model = 'x50i',
]) => {
  'design_width': 1000,
  'design_height': 800,
  'manufacturer': manufacturer,
  'model': model,
  'hud_skin': {
    'type': 'shape',
    'width': 200,
    'height': 100,
    'anchor': 'TOP_LEFT',
    'linked_elements': elements,
  },
};

/// A layout of one element on an invisible shape skin of [w] x [h] on a
/// full-HD design, for the telemetry-only renders.
Map<String, dynamic> _clearLayout(
  Map<String, dynamic> elem, {
  int w = 200,
  int h = 200,
  String? manufacturer,
  String? model,
}) => {
  'design_width': 1920,
  'design_height': 1080,
  'manufacturer': ?manufacturer,
  'model': ?model,
  'hud_skin': {
    'type': 'shape',
    'width': w,
    'height': h,
    'anchor': 'TOP_LEFT',
    'opacity': 0.0,
    'linked_elements': [elem],
  },
};

/// The bundled page as Python's `_load_*_layout`: the variant's state,
/// stripped, its skin path made absolute.
Map<String, dynamic> _template(
  String brand,
  String model,
  String page, [
  String? variant,
]) {
  // With forward slashes on every system, as the loader reads a path
  // unless told otherwise (a variant's base is found from it).
  final path = [
    'assets/overlays/templates',
    brand,
    model,
    page,
    ?variant,
    'normal.json',
  ].join('/');
  final layout = stripVariantMarkers(
    loadLayoutFile(path, (f) => File(f).readAsStringSync()),
  );
  final hudSkin = layout['hud_skin'] as Map<String, dynamic>;
  hudSkin['path'] = p.normalize(
    p.absolute(p.dirname(path), hudSkin['path'] as String),
  );
  return layout;
}

Map<String, dynamic> _perdix3(String page, [String? variant]) => _template(
  'shearwater',
  'perdix_3',
  page,
  variant ??
      (const ['main', 'standard', 'tec', 'info_ai'].contains(page)
          ? 'single_tank'
          : null),
);

List<Map<String, dynamic>> _elements(Map<String, dynamic> layout) => [
  for (final e
      in (layout['hud_skin'] as Map<String, dynamic>)['linked_elements']
          as List<dynamic>)
    e as Map<String, dynamic>,
];

Map<String, dynamic> _element(Map<String, dynamic> layout, String field) =>
    _elements(layout).firstWhere((e) => e['field'] == field);

// --- the graph alone (Python calls draw_depth_graph on a 100x50 frame
// with the skin at 0,0 and a res_scale of 1) ---

Future<_Frame> _graph(
  WidgetTester tester,
  Map<String, dynamic> elem,
  Waypoint waypoint,
  List<Waypoint> waypoints, {
  _Rgb background = (0, 0, 0),
}) => _render(
  tester,
  _clearLayout({'type': 'graph', 'field': 'depth_graph', ...elem}, w: 1, h: 1),
  waypoint,
  waypoints: waypoints,
  renderLog: true,
  width: 100,
  height: 50,
  background: background,
);

/// Python's `_deco_waypoints`.
List<Waypoint> _decoWaypoints() {
  Waypoint wp(
    int t,
    double d, [
    double? stop,
    double? ceiling,
    int? stopTime,
    int? ndl,
  ]) => _wp(
    t: t,
    timestamp: naive(2026, 1, 1).add(Duration(seconds: t)),
    depth: d,
    nextStopDepth: stop,
    ceiling: ceiling,
    nextStopTime: stopTime,
    ndl: ndl,
  );
  return [
    wp(0, 0, null, null, null, 5940),
    wp(10, 20, null, null, null, 600),
    wp(20, 20, 3.0, 1.0, 60),
    wp(30, 20, 6.0, 4.0, 120),
    wp(40, 12, 6.0, 3.0, 60),
    wp(50, 6, 3.0, 1.0, 60),
    wp(60, 3, 3.0, 0.5, 30),
    wp(70, 0, null, null, null, 5940),
  ];
}

const _decoElem = <String, dynamic>{
  'width': 100,
  'height': 50,
  'rel_x': 0.0,
  'rel_y': 0.0,
  'color': '#0000FF',
  'stops_color': '#00FF00',
  'ceiling_color': '#FF0000',
};

bool _green150(_Rgb c) => c.$2 > 150 && c.$1 < 60 && c.$3 < 60;
bool _green180(_Rgb c) => c.$2 > 180 && c.$1 < 60 && c.$3 < 60;

void main() {
  group('tests/test_hud_renderer.py', () {
    test('test_hud_renderer_text_scaling (sizes asked for)', () {
      final layout = <String, dynamic>{
        'design_width': 1000,
        'design_height': 800,
        'hud_skin': {
          'type': 'shape',
          'width': 200,
          'height': 100,
          'anchor': 'TOP_LEFT',
          'linked_elements': [
            {
              'field': 'depth',
              'font_size': 20,
              'scale': 1.5,
              'rel_x': 0.1,
              'rel_y': 0.2,
            },
          ],
        },
      };
      final wp = _wp(depth: 12.5);
      // int(20 * 1.92 * 1.5) on the frame, int(20 * 1.5) telemetry only.
      expect(_textSizes(layout, wp), contains(57));
      expect(_textSizes(layout, wp, renderLog: true), contains(30));
    });

    test('test_hud_renderer_user_scale (sizes asked for)', () {
      final layout = <String, dynamic>{
        'design_width': 1000,
        'design_height': 800,
        'hud_skin': {
          'type': 'image',
          'path': 'dummy_path.png',
          'scale': 0.5,
          'anchor': 'TOP_LEFT',
          'linked_elements': [
            {
              'field': 'depth',
              'font_size': 20,
              'scale': 1.5,
              'rel_x': 0.1,
              'rel_y': 0.2,
            },
          ],
        },
      };
      final wp = _wp(depth: 12.5);
      expect(_textSizes(layout, wp, skinSize: (100, 100)), contains(28));
      expect(
        _textSizes(layout, wp, skinSize: (100, 100), renderLog: true),
        contains(15),
      );
    });

    testWidgets('test_hud_renderer_depth_graph', (tester) async {
      final waypoints = [
        _wp(depth: 0.0),
        _wp(t: 10, depth: 10.0),
        _wp(t: 20, depth: 15.0),
        _wp(t: 30, depth: 12.5),
      ];
      final wp = _wp(t: 30, depth: 12.5);
      for (final marker in ['dot', 'cross', 'bold_cross']) {
        final layout = <String, dynamic>{
          'design_width': 1000,
          'design_height': 800,
          'hud_skin': {
            'type': 'shape',
            'width': 200,
            'height': 100,
            'anchor': 'TOP_LEFT',
            'linked_elements': [
              {
                'field': 'depth_graph',
                'type': 'graph',
                'width': 100,
                'height': 50,
                'color': '#00FF00',
                'rel_x': 0.1,
                'rel_y': 0.2,
                'marker_style': marker,
                'marker_size': 10,
              },
            ],
          },
        };
        final frame = await _render(tester, layout, wp, waypoints: waypoints);
        expect(frame.isBlack, isFalse, reason: marker);
      }
    });

    testWidgets(
      'test_depth_graph_deco_ceiling_reveals_progressively_and_never_retracts',
      (tester) async {
        Waypoint wp(int t, double d, [double? ceiling]) =>
            _wp(t: t, depth: d, decoStopDepth: ceiling);
        final waypoints = [
          wp(0, 0),
          wp(10, 10),
          wp(20, 20),
          wp(30, 20, 10.0),
          wp(40, 20, 15.0),
          wp(50, 15, 10.0),
          wp(60, 10, 10.0),
          wp(70, 0),
        ];
        const elem = <String, dynamic>{
          'width': 100,
          'height': 50,
          'rel_x': 0.0,
          'rel_y': 0.0,
          'color': '#FF0000',
          'reveal_profile': true,
        };
        // Blue is 0 where only the red line and fill are, and a grey tint
        // where the ceiling band is blended in.
        const early = (45, 15);
        const deep = (58, 30);
        const later = (85, 15);
        int blue(_Frame f, (int, int) at) => f.at(at.$1, at.$2).$3;

        final whole = await _graph(
          tester,
          {...elem, 'reveal_profile': false},
          wp(25, 20),
          waypoints,
        );
        for (final at in [early, deep, later]) {
          expect(blue(whole, at), greaterThan(0), reason: '$at');
        }

        var frame = await _graph(tester, elem, wp(25, 20), waypoints);
        for (final at in [early, deep, later]) {
          expect(blue(frame, at), 0, reason: 'no ceiling yet at $at');
        }

        frame = await _graph(tester, elem, wp(45, 20), waypoints);
        expect(blue(frame, early), greaterThan(0));
        expect(blue(frame, deep), greaterThan(0));
        expect(blue(frame, later), 0);

        frame = await _graph(tester, elem, wp(70, 0), waypoints);
        expect(blue(frame, early), greaterThan(0));
        expect(blue(frame, deep), greaterThan(0), reason: 'never retracted');
        expect(blue(frame, later), greaterThan(0));
      },
    );

    const badge = <String, dynamic>{
      'type': 'badge',
      'field': 'state_badge',
      'font_size': 20,
      'rel_x': 0.1,
      'rel_y': 0.1,
    };

    testWidgets('test_hud_renderer_badge_normal_state_draws_nothing', (
      tester,
    ) async {
      final normal = _wp(depth: 5.0, decoStopDepth: 0.0);
      final withBadge = await _render(tester, _shapeLayout([badge]), normal);
      final skinOnly = await _render(tester, _shapeLayout([]), normal);
      expect(withBadge.sameAs(skinOnly), isTrue);
    });

    testWidgets('test_hud_renderer_badge_deco_state_draws_badge', (
      tester,
    ) async {
      final deco = _wp(
        depth: 20.0,
        decoStopDepth: 6.0,
        nextStopDepth: 6.0,
        nextStopTime: 120,
      );
      final withBadge = await _render(tester, _shapeLayout([badge]), deco);
      final skinOnly = await _render(tester, _shapeLayout([]), deco);
      expect(withBadge.sameAs(skinOnly), isFalse);
    });

    testWidgets('test_hud_renderer_badge_safety_stop_from_alert_event', (
      tester,
    ) async {
      final wp = _wp(depth: 5.0, diveAlerts: ['safety_stop_started']);
      final withBadge = await _render(tester, _shapeLayout([badge]), wp);
      final skinOnly = await _render(tester, _shapeLayout([]), wp);
      expect(withBadge.sameAs(skinOnly), isFalse);
    });

    testWidgets('test_garmin_x50i_main_single_tank_renders', (tester) async {
      final frame = await _render(
        tester,
        _template('garmin', 'x50i', 'main', 'single_tank'),
        _wp(
          t: 754,
          depth: 18.4,
          maxDepth: 22.1,
          temp: 27.0,
          diveTime: 754,
          ndl: 1380,
          airRemaining: 1620,
          volumeSac: 14.2,
          tanks: {'Micke01': _tank(142, name: 'Micke01')},
        ),
      );
      expect(frame.isBlack, isFalse);
    });

    testWidgets('test_garmin_x50i_main_sidemount_renders', (tester) async {
      final frame = await _render(
        tester,
        _template('garmin', 'x50i', 'main', 'sidemount'),
        _wp(
          t: 754,
          depth: 18.4,
          maxDepth: 22.1,
          temp: 27.0,
          diveTime: 754,
          ndl: 1380,
          tts: 95,
          airRemaining: 1620,
          volumeSac: 14.2,
          tanks: {
            'Micke01': _tank(142, name: 'Micke01'),
            'Micke02': _tank(138, name: 'Micke02'),
          },
        ),
      );
      expect(frame.isBlack, isFalse);
    });

    testWidgets('test_garmin_x50i_gases_renders', (tester) async {
      final frame = await _render(
        tester,
        _template('garmin', 'x50i', 'gases'),
        _wp(
          t: 754,
          depth: 18.4,
          maxDepth: 22.1,
          temp: 27.0,
          diveTime: 754,
          po2: 1.12,
          gf: 0.62,
          cns: 18,
          tanks: {'Micke01': _tank(142, name: 'Micke01')},
        ),
      );
      expect(frame.isBlack, isFalse);
    });

    testWidgets('test_hud_renderer_time_of_day_field', (tester) async {
      final wp = _wp(timestamp: naive(2024, 1, 1, 14, 30), depth: 5.0);
      final frame = await _render(
        tester,
        _shapeLayout([
          {'field': 'time_of_day', 'font_size': 20, 'rel_x': 0.1, 'rel_y': 0.1},
        ]),
        wp,
      );
      final skinOnly = await _render(tester, _shapeLayout([]), wp);
      expect(frame.sameAs(skinOnly), isFalse);
    });

    testWidgets('test_hud_renderer_tank_icon_fill_color_by_pressure', (
      tester,
    ) async {
      final layout = _shapeLayout([
        {
          'type': 'tank_icon',
          'field': 'primary_tank_pressure',
          'rel_x': 0.3,
          'rel_y': 0.3,
          'width': 30,
          'height': 40,
        },
      ]);
      Future<_Frame> forPressure(double? bar) => _render(
        tester,
        layout,
        _wp(depth: 5.0, tanks: bar == null ? null : {'Back': _tank(bar)}),
      );
      final skinOnly = await _render(tester, _shapeLayout([]), _wp());

      // No reading: nothing beyond the bare skin.
      expect((await forPressure(null)).sameAs(skinOnly), isTrue);
      // Low pressure: a red fill.
      final red = await forPressure(30);
      expect(red.sameAs(skinOnly), isFalse);
      expect(red.count((c) => c.$1 == 255), greaterThan(0));
      expect(red.count((c) => c.$2 == 255), 0);
      // Healthy: the X50i's blue fill (0,170,255), no red.
      final blue = await forPressure(180);
      expect(blue.sameAs(skinOnly), isFalse);
      expect(blue.countRgb((0, 170, 255)), greaterThan(0));
      expect(blue.count((c) => c.$1 == 255), 0);
    });

    test('test_hud_renderer_badge_value_font_size_independent_of_label '
        '(sizes asked for)', () {
      Map<String, dynamic> layout(int valueSize) => _shapeLayout([
        {...badge, 'value_font_size': valueSize},
      ]);
      final wp = _wp(
        depth: 20.0,
        decoStopDepth: 6.0,
        nextStopDepth: 6.0,
        nextStopTime: 120,
      );
      final small = _textSizes(layout(20), wp);
      final big = _textSizes(layout(80), wp);
      // The label size is in both; the big value adds a much larger size.
      expect(small.intersection(big), isNotEmpty);
      expect(
        big.reduce((a, b) => a > b ? a : b),
        greaterThan(small.reduce((a, b) => a > b ? a : b)),
      );
    });

    testWidgets('test_perdix3_main_renders', (tester) async {
      final frame = await _render(
        tester,
        _perdix3('main'),
        _wp(
          t: 33 * 60 + 58,
          depth: 18.2,
          maxDepth: 33.5,
          temp: 23.0,
          diveTime: 33 * 60 + 58,
          ndl: 12 * 60,
          tanks: {'T1': _tank(125)},
        ),
      );
      expect(frame.isBlack, isFalse);
    });

    testWidgets('test_perdix3_standard_renders', (tester) async {
      final layout = _perdix3('standard');
      final frame = await _render(
        tester,
        layout,
        _wp(
          t: 24 * 60 + 31,
          depth: 24.3,
          maxDepth: 33.5,
          temp: 23.0,
          diveTime: 24 * 60 + 31,
          ndl: 10 * 60,
          tanks: {'T1': _tank(82)},
        ),
      );
      expect(frame.isBlack, isFalse);
      expect(
        _element(layout, 'depth')['font_size'] as num,
        lessThan(_element(_perdix3('main'), 'depth')['font_size'] as num),
      );
    });

    testWidgets('test_perdix3_tec_renders_ndl_state', (tester) async {
      final frame = await _render(
        tester,
        _perdix3('tec'),
        _wp(
          t: 21 * 60 + 27,
          depth: 59.3,
          maxDepth: 59.3,
          temp: 20.0,
          diveTime: 21 * 60 + 27,
          ndl: 18 * 60,
          po2: 0.94,
          gf: 48.0,
          tts: 0,
          divemode: 'OC',
          tanks: {'T1': _tank(248, o2: 18.0, he: 45.0)},
        ),
      );
      expect(frame.isBlack, isFalse);
    });

    testWidgets('test_perdix3_tec_renders_deco_state', (tester) async {
      final layout = _perdix3('tec');
      final deco = await _render(
        tester,
        layout,
        _wp(
          t: 34 * 60,
          depth: 27.0,
          maxDepth: 59.3,
          temp: 18.0,
          diveTime: 34 * 60,
          decoStopDepth: 27.0,
          nextStopDepth: 27.0,
          nextStopTime: 60,
          po2: 1.24,
          gf: 231.0,
          tts: 48 * 60,
          divemode: 'OC',
          tanks: {'T1': _tank(180, o2: 18.0, he: 45.0)},
        ),
      );
      final ndl = await _render(
        tester,
        layout,
        _wp(t: 34 * 60, depth: 27.0, ndl: 5 * 60),
      );
      expect(deco.sameAs(ndl), isFalse);
    });

    testWidgets('test_perdix3_tec_renders_clear_state', (tester) async {
      final frame = await _render(
        tester,
        _perdix3('tec'),
        _wp(
          t: 40 * 60,
          depth: 26.6,
          maxDepth: 59.3,
          temp: 18.0,
          diveTime: 40 * 60,
          decoStopDepth: 27.0,
          nextStopDepth: 0.0,
          nextStopTime: 0,
          po2: 1.1,
          gf: 90.0,
          tts: 5 * 60,
          divemode: 'OC',
          tanks: {'T1': _tank(140, o2: 18.0, he: 45.0)},
        ),
      );
      expect(frame.isBlack, isFalse);
    });

    testWidgets('test_perdix3_tec_renders_safety_stop_state', (tester) async {
      final frame = await _render(
        tester,
        _perdix3('tec'),
        _wp(
          t: 44 * 60,
          depth: 5.0,
          maxDepth: 27.0,
          temp: 22.0,
          diveTime: 44 * 60,
          diveAlerts: ['safety_stop_started'],
          nextStopDepth: 5.0,
          nextStopTime: 180,
          po2: 0.5,
          gf: 10.0,
          tts: 3 * 60,
          divemode: 'OC',
          tanks: {'T1': _tank(110)},
        ),
      );
      expect(frame.isBlack, isFalse);
    });

    testWidgets('test_perdix2_main_single_tank_renders', (tester) async {
      final frame = await _render(
        tester,
        _template('shearwater', 'perdix_2', 'main', 'single_tank'),
        _wp(
          t: 35 * 60 + 51,
          depth: 15.7,
          maxDepth: 15.7,
          temp: 27.0,
          diveTime: 35 * 60 + 51,
          ndl: 22 * 60,
          airRemaining: 21 * 60,
          tanks: {'T1': _tank(210)},
        ),
      );
      expect(frame.isBlack, isFalse);
    });

    testWidgets(
      'test_perdix2_main_single_tank_safety_stop_badge_and_tank_fill',
      (tester) async {
        // Below 50 bar the tank icon turns red.
        final layout = _template(
          'shearwater',
          'perdix_2',
          'main',
          'single_tank',
        );
        Waypoint at(double bar) => _wp(
          t: 35 * 60 + 51,
          depth: 5.0,
          maxDepth: 15.7,
          temp: 27.0,
          diveTime: 35 * 60 + 51,
          ndl: 22 * 60,
          airRemaining: 21 * 60,
          nextStopTime: 180,
          tanks: {'T1': _tank(bar)},
        );
        final low = await _render(tester, layout, at(45));
        expect(low.count((c) => c.$1 == 255), greaterThan(0));
        // And it is the fill: the same page at a healthy pressure has
        // less pure red.
        final healthy = await _render(tester, layout, at(210));
        expect(
          low.countRgb((255, 0, 0)),
          greaterThan(healthy.countRgb((255, 0, 0)) + 20),
        );
      },
    );

    testWidgets('test_perdix2_main_sidemount_renders', (tester) async {
      final frame = await _render(
        tester,
        _template('shearwater', 'perdix_2', 'main', 'sidemount'),
        _wp(
          t: 35 * 60 + 51,
          depth: 15.7,
          maxDepth: 15.7,
          temp: 27.0,
          diveTime: 35 * 60 + 51,
          ndl: 22 * 60,
          airRemaining: 45 * 60,
          tanks: {'T1': _tank(210), 'T2': _tank(207)},
        ),
      );
      expect(frame.isBlack, isFalse);
    });

    testWidgets('test_perdix2_tec_renders', (tester) async {
      final frame = await _render(
        tester,
        _template('shearwater', 'perdix_2', 'tec'),
        _wp(
          t: 22 * 60,
          depth: 67.0,
          maxDepth: 67.0,
          temp: 20.0,
          diveTime: 22 * 60,
          decoStopDepth: 39.0,
          nextStopTime: 60,
          po2: 1.15,
          gf: 164.0,
          ndl: 8 * 60,
          tts: 56 * 60,
          divemode: 'OC',
          tanks: {'T1': _tank(153, o2: 15.0, he: 40.0)},
        ),
      );
      expect(frame.isBlack, isFalse);
    });

    // --- schema v2 text attributes ---

    /// Python's `_ink_bbox`: one 60 px depth value at the centre of a
    /// 400x200 invisible skin, telemetry only; (x0, x1, y0, y1) of its
    /// ink, and the frame.
    Future<(int, int, int, int, _Frame)> inkBox(
      WidgetTester tester, {
      String align = 'left',
      String valign = 'top',
      String? family,
      Map<String, dynamic> extra = const {},
    }) async {
      final frame = await _render(
        tester,
        _clearLayout({
          'field': 'depth',
          'font_size': 60,
          'rel_x': 0.5,
          'rel_y': 0.5,
          'color': '#FFFFFF',
          'align': align,
          'valign': valign,
          'outline': false,
          'font_family': ?family,
          ...extra,
        }, w: 400),
        _wp(depth: 12.5),
        renderLog: true,
      );
      final (x0, y0, x1, y1) = frame.box((c) => c.$3 > 128);
      return (x0, x1, y0, y1, frame);
    }

    testWidgets('test_align_and_valign_move_the_ink_box_onto_the_anchor', (
      tester,
    ) async {
      // The anchor is (200, 100).
      final (lx0, lx1, ly0, ly1, _) = await inkBox(tester);
      expect(lx0, greaterThanOrEqualTo(200));
      expect(ly0, greaterThanOrEqualTo(100));
      final (cx0, cx1, _, _, _) = await inkBox(tester, align: 'center');
      expect(((cx0 + cx1) / 2 - 200).abs(), lessThanOrEqualTo(3));
      final (rx0, rx1, _, _, _) = await inkBox(tester, align: 'right');
      expect((rx1 - 200).abs(), lessThanOrEqualTo(6));
      expect(rx0, lessThan(200));
      final (_, _, my0, my1, _) = await inkBox(tester, valign: 'middle');
      expect(((my0 + my1) / 2 - 100).abs(), lessThanOrEqualTo(3));
      final (_, _, by0, by1, _) = await inkBox(tester, valign: 'bottom');
      expect((by1 - 100).abs(), lessThanOrEqualTo(3));
      expect(by0, lessThan(100));
      // Alignment keeps the size; a half-pixel position may smear the
      // anti-aliased edge by one pixel.
      expect(((cx1 - cx0) - (lx1 - lx0)).abs(), lessThanOrEqualTo(1));
      expect(((by1 - by0) - (ly1 - ly0)).abs(), lessThanOrEqualTo(1));
    });

    testWidgets(
      'test_font_family_changes_rendering_and_unknown_family_falls_back',
      (tester) async {
        final (_, _, _, _, plain) = await inkBox(tester);
        final (_, _, _, _, roboto) = await inkBox(tester, family: 'Roboto');
        final (_, _, _, _, dseg) = await inkBox(
          tester,
          family: 'DSEG7 Classic',
        );
        final (_, _, _, _, unknown) = await inkBox(
          tester,
          family: 'No Such Family',
        );
        expect(plain.sameAs(roboto), isFalse);
        expect(plain.sameAs(dseg), isFalse);
        expect(plain.sameAs(unknown), isTrue);
        final (_, _, _, _, bold) = await inkBox(
          tester,
          extra: const {'font_weight': 'bold'},
        );
        expect(plain.sameAs(bold), isFalse);
      },
    );

    testWidgets('test_outline_false_draws_no_black_halo', (tester) async {
      final black = <bool, int>{};
      for (final outline in [true, false]) {
        final frame = await _render(
          tester,
          {
            'design_width': 1920,
            'design_height': 1080,
            'hud_skin': {
              'type': 'shape',
              'width': 400,
              'height': 200,
              'anchor': 'TOP_LEFT',
              'opacity': 1.0,
              'color': '#808080',
              'linked_elements': [
                {
                  'field': 'depth',
                  'font_size': 60,
                  'rel_x': 0.2,
                  'rel_y': 0.2,
                  'color': '#FFFFFF',
                  'outline': outline,
                },
              ],
            },
          },
          _wp(depth: 12.5),
          renderLog: true,
        );
        // Inside the rounded rectangle (its corners are frame black).
        black[outline] = frame.crop(30, 30, 370, 170).countRgb((0, 0, 0));
      }
      expect(black[true], greaterThan(0));
      expect(black[false], 0);
    });

    testWidgets(
      'test_small_suffix_splits_and_renders_smaller_top_aligned_suffix',
      (tester) async {
        Future<_Frame> render(Map<String, dynamic> extra) => _render(
          tester,
          _clearLayout({
            'field': 'dive_time',
            'font_size': 60,
            'rel_x': 0.1,
            'rel_y': 0.2,
            'color': '#FFFFFF',
            'outline': false,
            ...extra,
          }, w: 600),
          _wp(t: 754, depth: 12.5, diveTime: 754),
          renderLog: true,
        );
        bool ink(_Rgb c) => c.$3 > 128;
        final plain = await render(const {});
        final small = await render(const {
          'small_suffix': 'seconds',
          'small_suffix_scale': 0.33,
        });
        expect(plain.sameAs(small), isFalse);
        final (_, py0, px1, _) = plain.box(ink);
        final (_, sy0, sx1, _) = small.box(ink);
        // The suffix run is narrower than the plain "12:34" ...
        expect(sx1, lessThan(px1));
        // ... and its top edge is the main digits', which did not change.
        expect(sy0, py0);
        // Right-aligned: the whole run's right edge on the anchor (300).
        final right = await render(const {
          'small_suffix': 'seconds',
          'align': 'right',
          'rel_x': 0.5,
        });
        final (_, _, rx1, _) = right.box(ink);
        expect((rx1 - 300).abs(), lessThanOrEqualTo(6));
      },
    );

    testWidgets(
      'test_tank_icon_drawn_outline_is_optional_and_independent_of_pressure',
      (tester) async {
        expect(tankOutlineMetrics(const {'type': 'tank_icon'}), isNull);
        expect(
          tankOutlineMetrics(const {'type': 'tank_icon', 'draw_outline': true}),
          (4, 2, 6),
        );
        expect(
          tankOutlineMetrics(const {
            'type': 'tank_icon',
            'draw_outline': true,
            'outline_gap': 0,
            'outline_width': 3,
          }),
          (0, 3, 3),
        );
        Future<_Frame> render(Map<String, dynamic> extra, Waypoint wp) =>
            _render(
              tester,
              _clearLayout(
                {
                  'field': 'primary_tank_pressure',
                  'type': 'tank_icon',
                  'rel_x': 0.25,
                  'rel_y': 0.25,
                  'width': 20,
                  'height': 40,
                  ...extra,
                },
                manufacturer: 'Garmin',
                model: 'mk3i',
              ),
              wp,
              renderLog: true,
            );
        final noTank = _wp(depth: 10.0);
        final full = _wp(depth: 10.0, tanks: {'T1': _tank(180.0)});

        expect((await render(const {}, noTank)).sum, 0);
        expect((await render(const {}, full)).sum, greaterThan(0));
        final outlineOnly = await render(const {'draw_outline': true}, noTank);
        expect(outlineOnly.sum, greaterThan(0));
        bool ink(_Rgb c) => _max3(c) > 128;
        // The fill box is (50,50)-(70,90); the outline sits 4 gap + 2
        // stroke outside it, the cap above.
        final (x0, y0, x1, y1) = outlineOnly.box(ink);
        expect(x0, lessThanOrEqualTo(45));
        expect(x1, greaterThanOrEqualTo(75));
        expect(y0, lessThan(44));
        expect(y1, greaterThanOrEqualTo(95));
        // White.
        expect(
          outlineOnly.count(
            (c) => ink(c) && (c.$1 < 200 || c.$2 < 200 || c.$3 < 200),
          ),
          0,
        );
        final red = await render(const {
          'draw_outline': true,
          'outline_color': '#FF0000',
        }, noTank);
        final redInk = [
          for (final (_, _, c) in red.pixels)
            if (ink(c)) c,
        ];
        expect(
          redInk.map((c) => c.$1).reduce((a, b) => a > b ? a : b),
          greaterThan(200),
        );
        expect(redInk.map((c) => c.$2).reduce((a, b) => a > b ? a : b), 0);
        final both = await render(const {'draw_outline': true}, full);
        expect(both.sum, greaterThan(outlineOnly.sum));
      },
    );

    testWidgets('test_tissue_bar_draws_bands_and_moves_marker_with_load', (
      tester,
    ) async {
      expect(tissueBarGeometry(const {'type': 'tissue_bar'}), (12, 33, 4));
      expect(tissueBarMarkerFraction(null), 0.0);
      expect(tissueBarMarkerFraction(60), closeTo(0.5, 1e-9));
      expect(tissueBarMarkerFraction(500), 1.0);
      Future<_Frame> render(double? load) => _render(
        tester,
        _clearLayout(
          {
            'field': 'n2_tissue_load',
            'type': 'tissue_bar',
            'rel_x': 0.5,
            'rel_y': 0.25,
            'width': 12,
            'height': 40,
            'marker_size': 4,
          },
          manufacturer: 'Garmin',
          model: 'x50i',
        ),
        _wp(depth: 10.0, n2TissueLoad: load),
        renderLog: true,
      );
      final zero = await render(0.0);
      // The bar at x 100..112, y 50..90: green bottom, yellow, red top.
      expect(zero.at(106, 88), (0, 255, 0));
      expect(zero.at(106, 52), (255, 0, 0));
      final yellow = zero.at(106, (50 + 40 * (1 - 90 / 120)).truncate() + 1);
      expect(yellow.$1, greaterThan(150));
      expect(yellow.$2, greaterThan(150));
      // The white marker left of the bar: at the bottom for 0 %, higher
      // with the load.
      double markerY(_Frame f) {
        final ys = [
          for (final (x, y, c) in f.pixels)
            if (x >= 90 && x < 104 && c.$1 > 240 && c.$2 > 240 && c.$3 > 240) y,
        ];
        expect(ys, isNotEmpty);
        return ys.reduce((a, b) => a + b) / ys.length;
      }

      final y0 = markerY(zero);
      final y60 = markerY(await render(60.0));
      final y119 = markerY(await render(119.0));
      expect(y0, greaterThan(y60));
      expect(y60, greaterThan(y119));
      // Drawn even without a value.
      expect((await render(null)).sum, greaterThan(0));
    });

    testWidgets(
      'test_ascent_chevrons_light_with_rate_and_derive_rate_when_missing',
      (tester) async {
        expect(ascentChevronGeometry(const {'type': 'ascent_chevrons'}), (
          16,
          47,
          4,
          1,
        ));
        expect(ascentLitCount(null, 4), 0);
        expect(ascentLitCount(0.2, 4), 0);
        expect(ascentLitCount(1.0, 4), 1);
        expect(ascentLitCount(6.0, 4), 3);
        expect(ascentLitCount(11.0, 4), 4);
        expect(ascentLitCount(40.0, 4), 4);
        expect(ascentLitCount(-5.0, 4), 0);
        // Derived from the depth change when the log has no rate.
        final wps = [
          _wp(timestamp: _t0, depth: 20.0),
          _wp(timestamp: _t0, t: 30, depth: 17.0),
          _wp(timestamp: _t0, t: 60, depth: 18.0),
        ];
        expect(ascentRateFor(wps[1], wps), closeTo(6.0, 1e-9));
        expect(ascentRateFor(wps[2], wps), closeTo(-2.0, 1e-9));
        expect(ascentRateFor(wps[0], wps), isNull);
        expect(
          ascentRateFor(_wp(timestamp: _t0, depth: 10.0, ascentRate: 9.0), wps),
          9.0,
        );

        Future<_Frame> render(double? rate) async => (await _render(
          tester,
          _clearLayout(
            {
              'field': 'ascent_rate',
              'type': 'ascent_chevrons',
              'rel_x': 0.25,
              'rel_y': 0.25,
              'width': 16,
              'height': 48,
            },
            manufacturer: 'Garmin',
            model: 'x50i',
          ),
          _wp(timestamp: _t0, depth: 10.0, ascentRate: rate),
          renderLog: true,
        )).crop(50, 50, 66, 98);
        const grey = (138, 138, 138);
        const white = (255, 255, 255);
        const green = (0, 255, 0);
        const red = (255, 0, 0);

        final level = await render(0.0);
        // Grey chevrons and the white bar.
        expect(level.countRgb(grey), greaterThan(100));
        expect(level.countRgb(green), 0);
        expect(level.countRgb(white), greaterThan(10));
        final slow = await render(3.0);
        final fast = await render(12.0);
        // One green chevron against four red ones.
        expect(slow.countRgb(green), greaterThan(0));
        expect(slow.countRgb(green), lessThan(fast.countRgb(red)));
        expect(slow.countRgb(grey), greaterThan(fast.countRgb(grey)));
        // The yellow band, #FFC000.
        expect((await render(9.0)).countRgb((255, 192, 0)), greaterThan(0));
        // The down chevron lit white.
        expect(
          (await render(-3.0)).countRgb(white),
          greaterThan(level.countRgb(white)),
        );
        expect((await render(null)).sum, greaterThan(0));
      },
    );

    testWidgets('test_tissue_bar_fill_style_frames_and_fills_by_value', (
      tester,
    ) async {
      Future<_Frame> render(double? value) async => (await _render(
        tester,
        _clearLayout(
          {
            'field': 'gf',
            'type': 'tissue_bar',
            'style': 'fill',
            'rel_x': 0.25,
            'rel_y': 0.25,
            'width': 20,
            'height': 60,
            'outline_color': '#00ADED',
          },
          manufacturer: 'Shearwater',
          model: 'Perdix 2',
        ),
        _wp(depth: 10.0, gf: value),
        renderLog: true,
      )).crop(48, 48, 72, 112);
      const green = (0, 255, 0);

      final empty = await render(0.0);
      // The blue frame.
      expect(empty.countRgb((0, 173, 237)), greaterThan(40));
      expect(empty.countRgb(green), 0);
      final half = await render(60.0);
      expect(half.countRgb(green), greaterThan(0));
      expect(
        half.countRgb(green),
        lessThan((await render(75.0)).countRgb(green)),
      );
      // The yellow and the red band.
      expect((await render(90.0)).countRgb((255, 192, 0)), greaterThan(0));
      expect((await render(110.0)).countRgb((255, 0, 0)), greaterThan(0));
      // It fills from the bottom.
      final ys = [
        for (final (_, y, c) in half.pixels)
          if (c == green) y,
      ];
      expect(ys.reduce((a, b) => a > b ? a : b), greaterThan(40));
      expect(ys.reduce((a, b) => a < b ? a : b), greaterThan(20));
      // The frame is drawn without a value.
      expect((await render(null)).sum, greaterThan(0));
    });

    testWidgets(
      'test_tank_icon_segments_style_lights_by_pressure_and_draws_its_outline',
      (tester) async {
        final geometry = tankSegmentsGeometry(const {
          'type': 'tank_icon',
          'height': 23,
        });
        expect((geometry.$1, geometry.$2, geometry.$3), (5, 2, 200.0));
        expect(tankSegmentsLit(null, 200, 5), 0);
        expect(tankSegmentsLit(0, 200, 5), 0);
        expect(tankSegmentsLit(10, 200, 5), 1);
        expect(tankSegmentsLit(100, 200, 5), 3);
        expect(tankSegmentsLit(200, 200, 5), 5);
        expect(tankSegmentsLit(500, 200, 5), 5);

        Future<_Frame> render(
          double? bar, [
          String manufacturer = 'Shearwater',
          String model = 'Perdix 2',
        ]) async => (await _render(
          tester,
          _clearLayout(
            {
              'field': 'primary_tank_pressure',
              'type': 'tank_icon',
              'style': 'segments',
              'rel_x': 0.1,
              'rel_y': 0.25,
              'width': 12,
              'height': 23,
              'segments': 5,
              'segment_gap': 2,
              'full_bar': 200,
            },
            h: 100,
            manufacturer: manufacturer,
            model: model,
          ),
          _wp(depth: 10.0, tanks: bar == null ? null : {'T1': _tank(bar)}),
          renderLog: true,
        )).crop(10, 10, 130, 60);
        const unlit = (58, 58, 58);
        const white = (255, 255, 255);

        final empty = await render(null);
        // Five unlit segments in a grey outline (#9A9A9A).
        expect(empty.countRgb(unlit), greaterThan(5 * 200));
        expect(empty.countRgb((154, 154, 154)), greaterThan(50));
        final full = await render(200.0);
        // Shearwater: white when comfortable.
        expect(full.countRgb(white), greaterThan(5 * 200));
        expect(full.countRgb(unlit), 0);
        // 2.5 of 5 segments rounds up to 3 (a segment is about 276 px).
        final half = await render(100.0);
        expect(half.countRgb(white), inExclusiveRange(2 * 276, 4 * 276));
        expect(half.countRgb(unlit), greaterThan(300));
        // The red band, one segment.
        final low = await render(40.0);
        expect(low.countRgb((255, 0, 0)), greaterThan(100));
        expect(low.countRgb(white), 0);
        // Garmin keeps green; the X50i's own rule is blue.
        expect(
          (await render(200.0, 'Garmin', 'mk3i')).countRgb((0, 255, 0)),
          greaterThan(5 * 200),
        );
        expect(
          (await render(200.0, 'Garmin', 'x50i')).countRgb((0, 170, 255)),
          greaterThan(5 * 200),
        );
      },
    );

    // --- graph deco mode (stops_color), reveal_profile, stop_label ---

    // x = 100 * t / 70; y = depth * 50 / 22.
    const sixMStopOnly = (47, 10); // t~33, ~4.4 m: under the 6 m stop only
    const ceilingPx = (44, 4); // t~31, ~1.8 m: under both

    testWidgets('test_deco_graph_shades_stops_and_ceiling_separately_and_keeps_'
        'cleared_stops', (tester) async {
      final wps = _decoWaypoints();
      // Without reveal_profile the whole dive's stops show from the
      // start.
      var frame = await _graph(tester, _decoElem, wps[3], wps);
      expect(frame.at(sixMStopOnly.$1, sixMStopOnly.$2).$2, greaterThan(0));
      // With it a stop shows once the dive reaches it.
      frame = await _graph(
        tester,
        {..._decoElem, 'reveal_profile': true},
        wps[3],
        wps,
      );
      expect(frame.at(sixMStopOnly.$1, sixMStopOnly.$2).$2, 0);

      frame = await _graph(tester, _decoElem, wps.last, wps);
      // The stops colour alone, kept after the stop cleared.
      final (r, g, _) = frame.at(sixMStopOnly.$1, sixMStopOnly.$2);
      expect(g, greaterThan(0));
      expect(r, 0);
      // The ceiling blended over the stop.
      final (cr, cg, _) = frame.at(ceilingPx.$1, ceilingPx.$2);
      expect(cg, greaterThan(0));
      expect(cr, greaterThan(0));
    });

    testWidgets('test_reveal_profile_draws_line_only_up_to_the_cursor', (
      tester,
    ) async {
      final wps = _decoWaypoints();
      const elem = <String, dynamic>{
        'width': 100,
        'height': 50,
        'rel_x': 0.0,
        'rel_y': 0.0,
        'color': '#0000FF',
        'marker_size': 1,
      };
      const lateBottom = (40, 45); // t~28 on the 20 m line
      var frame = await _graph(
        tester,
        {...elem, 'reveal_profile': true},
        wps[1],
        wps,
      );
      expect(frame.at(lateBottom.$1, lateBottom.$2).$3, 0);
      // The default still draws the whole dive.
      frame = await _graph(tester, elem, wps[1], wps);
      expect(frame.at(lateBottom.$1, lateBottom.$2).$3, greaterThan(0));
    });

    testWidgets('test_stop_label_is_drawn_in_the_text_pass', (tester) async {
      final wps = _decoWaypoints();
      Map<String, dynamic> layout(bool label) => _shapeLayout([
        {
          ..._decoElem,
          'type': 'graph',
          'field': 'depth_graph',
          'width': 180,
          'height': 90,
          'stop_label': ?(label ? true : null),
        },
      ]);
      final without = await _render(
        tester,
        layout(false),
        wps[3],
        waypoints: wps,
      );
      final withLabel = await _render(
        tester,
        layout(true),
        wps[3],
        waypoints: wps,
      );
      expect(without.sameAs(withLabel), isFalse);
    });

    for (final variant in ['single_tank', 'sidemount']) {
      testWidgets(
        'test_garmin_mk3i_main_renders_stop_states_in_the_ndl_slot[$variant]',
        (tester) async {
          final layout = _template('garmin', 'mk3i', 'main', variant);
          final elems = _elements(layout);
          final badge = elems.firstWhere((e) => e['type'] == 'badge');
          expect(
            (badge['depth_font'], badge['timer_format']),
            ('label', 'm:ss'),
          );
          // The NDL label is one word turned upwards (a real Mk3i
          // screenshot), not three stacked letters.
          for (final field in ['ndl', 'custom:NDL']) {
            expect(
              (_element(layout, field)['hide_in_states'] as List).toSet(),
              {'safety_stop', 'deco', 'clear'},
            );
          }
          expect(_element(layout, 'custom:NDL')['orientation'], 'up');
          final frame = await _render(
            tester,
            layout,
            _wp(
              t: 1500,
              depth: 12.0,
              maxDepth: 40.0,
              temp: 27.0,
              diveTime: 1500,
              decoStopDepth: 6.0,
              nextStopDepth: 6.0,
              nextStopTime: 180,
              ndl: 0,
              tanks: {'T1': _tank(150, o2: 32.0), 'T2': _tank(140, o2: 32.0)},
            ),
          );
          expect(frame.isBlack, isFalse);
        },
      );
    }

    testWidgets('test_perdix2_main_variants_share_a_base_and_the_sidemount_row_'
        'highlights_the_tank_to_switch_to', (tester) async {
      const page = 'assets/overlays/templates/shearwater/perdix_2/main';
      final base = jsonDecode(
        File('$page/normal.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(
        [for (final e in _elements(base)) e['id']],
        [
          'depth',
          'label_time',
          'dive_time',
          'state_badge',
          'label_ndl',
          'ndl',
          'n2_bar',
          'ascent_rate',
          'notice',
          'persistent_notice',
        ],
      );
      List<Object?> variantRow(String variant) => [
        for (final e in _elements(
          loadLayoutFile(
            '$page/$variant/normal.json',
            (f) => File(f).readAsStringSync(),
          ),
        ))
          if (e[elementOriginKey] == 'variant') e['field'],
      ];
      final singleRow = variantRow('single_tank');
      final sideRow = variantRow('sidemount');
      expect(singleRow.first, 'gasmix');
      expect(singleRow, contains('air_remaining'));
      expect(
        sideRow,
        containsAll(['pressure_sac', 'custom:SM', 'secondary_tank_pressure']),
      );
      expect(File('$page/sidemount/normal.png').existsSync(), isFalse);
      expect(File('$page/normal.png').existsSync(), isTrue);

      final layout = _template('shearwater', 'perdix_2', 'main', 'sidemount');
      Waypoint at(double t1, double t2) => _wp(
        t: 2151,
        depth: 15.7,
        maxDepth: 15.7,
        temp: 23.0,
        diveTime: 2151,
        ndl: 22 * 60,
        airRemaining: 45 * 60,
        pressureSac: 1.1,
        gf: 40.0,
        tanks: {'T1': _tank(t1), 'T2': _tank(t2)},
      );
      // The switch highlight (#00C800 behind T1) adds a green patch.
      final green = (await _render(
        tester,
        layout,
        at(175, 153),
      )).count(_green180);
      final even = (await _render(
        tester,
        layout,
        at(170, 165),
      )).count(_green180);
      expect(green, greaterThan(even + 50));
    });

    for (final computer in ['teric', 'tern']) {
      testWidgets(
        'test_watch_templates_replace_the_ndl_with_the_stop_badge[$computer]',
        (tester) async {
          final layout = _template('shearwater', computer, 'main');
          expect(_elements(layout).any((e) => e['type'] == 'badge'), isTrue);
          for (final field in ['ndl', 'custom:NDL']) {
            expect(
              (_element(layout, field)['hide_in_states'] as List).toSet(),
              {'safety_stop', 'deco', 'clear'},
            );
          }
          final frame = await _render(
            tester,
            layout,
            _wp(
              t: 1500,
              depth: 12.0,
              maxDepth: 30.0,
              temp: 27.0,
              diveTime: 1500,
              decoStopDepth: 9.0,
              nextStopDepth: 9.0,
              nextStopTime: 120,
              ndl: 0,
              tts: 600,
              tanks: {'T1': _tank(150, o2: 32.0)},
            ),
          );
          expect(frame.isBlack, isFalse);
        },
      );
    }

    for (final page in ['tec', 'info_ai', 'main', 'standard']) {
      testWidgets(
        'test_perdix_3_sidemount_pages_show_both_tanks_and_box_the_one_to_'
        'breathe[$page]',
        (tester) async {
          final layout = _perdix3(page, 'sidemount');
          final elems = _elements(layout);
          expect({
            for (final e in elems) e['tank_switch_highlight'],
          }, containsAll(['primary', 'secondary']));
          expect({
            for (final e in elems) e['field'],
          }, containsAll(['primary_tank_pressure', 'secondary_tank_pressure']));
          Future<int> green(double t1, double t2) async => (await _render(
            tester,
            layout,
            _wp(
              t: 600,
              depth: 18.0,
              ndl: 20 * 60,
              tanks: {'T1': _tank(t1), 'T2': _tank(t2)},
            ),
          )).count(_green150);
          expect(
            await green(170, 130),
            greaterThan(await green(170, 165) + 200),
          );
        },
      );
    }

    testWidgets('test_perdix_3_badge_lines_and_boxed_title (the boxed title)', (
      tester,
    ) async {
      // The boxed title paints a green block behind "SAFETY".
      final layout = _perdix3('main');
      final counting = _wp(
        depth: 5.0,
        maxDepth: 20.0,
        diveTime: 0,
        diveAlerts: ['safety_stop_started'],
        nextStopDepth: 5.0,
        nextStopTime: 202,
      );
      final block = (await _render(tester, layout, counting)).count(_green180);
      final normal = (await _render(
        tester,
        layout,
        _wp(depth: 18.0, ndl: 12 * 60),
      )).count(_green180);
      expect(block, greaterThan(normal + 200));
    });

    testWidgets('test_shearwater_safety_stop_time_is_centred_under_the_title', (
      tester,
    ) async {
      // hud_rules.json centres the Shearwater safety stop's value: the
      // timer's ink ("✓ 2:30") under "SAFETY STOP".
      final frame = await _render(
        tester,
        _shapeLayout(
          [
            {
              'type': 'badge',
              'field': 'state_badge',
              'font_size': 28,
              'value_font_size': 38,
              'rel_x': 0.1,
              'rel_y': 0.1,
              'outline': false,
            },
          ],
          'Shearwater',
          'Perdix 2',
        ),
        _wp(
          depth: 5.0,
          maxDepth: 20.0,
          diveTime: 0,
          diveAlerts: ['safety_stop_started'],
          nextStopDepth: 5.0,
          nextStopTime: 150,
        ),
      );
      // "SAFETY STOP" in #00C800, "✓ 2:30" in white.
      final title = frame.columns((c) => c.$2 > 150 && c.$1 < 80 && c.$3 < 80);
      final timer = frame.columns(
        (c) => c.$1 > 200 && c.$2 > 200 && c.$3 > 200,
      );
      expect(title, isNotEmpty);
      expect(timer, isNotEmpty);
      final titleCentre = (title.first + title.last) / 2;
      final timerCentre = (timer.first + timer.last) / 2;
      expect((titleCentre - timerCentre).abs(), lessThanOrEqualTo(3));
      // Not on the left anchor any more.
      expect(timer.first, greaterThan(title.first + 20));
      // The span counts the check mark drawn in front of the title.
      final font = _fonts.font(28, fontFile(null, null));
      final plain = badgeTitleInkSpan(_fonts, font, 'SAFETY STOP', 28);
      final checked = badgeTitleInkSpan(_fonts, font, '✓ SAFETY STOP', 28);
      expect(checked.$2 - checked.$1, greaterThan(plain.$2 - plain.$1));
    });

    testWidgets('test_badge_line_spacing_max_width_and_mid_line_check_mark '
        '(line_spacing; the rest in test/core/hud/hud_text_test.dart)', (
      tester,
    ) async {
      Future<int> valueTop(double spacing) async {
        final frame = await _render(
          tester,
          _shapeLayout(
            [
              {
                'type': 'badge',
                'field': 'state_badge',
                'font_size': 28,
                'value_font_size': 60,
                'rel_x': 0.1,
                'rel_y': 0.1,
                'outline': false,
                'line_spacing': spacing,
              },
            ],
            'Shearwater',
            'Perdix 2',
          ),
          _wp(
            depth: 5.0,
            maxDepth: 20.0,
            diveTime: 0,
            diveAlerts: ['safety_stop_started'],
            nextStopDepth: 5.0,
            nextStopTime: 150,
          ),
        );
        return frame.box((c) => c.$1 > 200 && c.$2 > 200 && c.$3 > 200).$2;
      }

      expect(await valueTop(0.6), lessThan(await valueTop(1.2)));
    });

    testWidgets('test_vertical_text_orientations_stack_or_turn_the_label', (
      tester,
    ) async {
      Future<_Frame> render(
        String orientation, [
        Map<String, dynamic> extra = const {},
      ]) => _render(
        tester,
        _shapeLayout([
          {
            'field': 'custom:SAFETY',
            'font_size': 40,
            'rel_x': 0.3,
            'rel_y': 0.2,
            'outline': false,
            'orientation': orientation,
            ...extra,
          },
        ]),
        _wp(depth: 5.0),
      );
      (int, int, int, int) inkBox(_Frame f) => f.box((c) => _max3(c) > 40);

      final flat = inkBox(await render('horizontal'));
      expect(flat.$3 - flat.$1, greaterThan(flat.$4 - flat.$2));
      for (final orientation in ['stacked', 'up', 'down']) {
        final (x0, y0, x1, y1) = inkBox(await render(orientation));
        expect(y1 - y0, greaterThan(x1 - x0), reason: orientation);
      }
      final up = await render('up');
      final down = await render('down');
      // Mirrored reading directions, the same box.
      expect(up.sameAs(down), isFalse);
      final bu = inkBox(up);
      final bd = inkBox(down);
      expect(((bu.$3 - bu.$1) - (bd.$3 - bd.$1)).abs(), lessThanOrEqualTo(2));
      expect(((bu.$4 - bu.$2) - (bd.$4 - bd.$2)).abs(), lessThanOrEqualTo(2));
      // An outline adds a halo and keeps it vertical.
      final (hx0, hy0, hx1, hy1) = inkBox(
        await render('stacked', const {'outline': true}),
      );
      expect(hy1 - hy0, greaterThan(hx1 - hx0));
    });

    testWidgets('test_shearwater_ascent_arrows_follow_the_perdix_manual', (
      tester,
    ) async {
      Future<_Frame> render(
        double? rate, [
        Map<String, dynamic> extra = const {},
      ]) async => (await _render(
        tester,
        _clearLayout(
          {
            'field': 'ascent_rate',
            'type': 'ascent_chevrons',
            'rel_x': 0.25,
            'rel_y': 0.25,
            'width': 16,
            'height': 48,
            'up_count': 6,
            'down_count': 0,
            ...extra,
          },
          manufacturer: 'Shearwater',
          model: 'Perdix 2',
        ),
        _wp(timestamp: _t0, depth: 10.0, ascentRate: rate),
        renderLog: true,
      )).crop(50, 50, 66, 98);
      const grey = (138, 138, 138);
      const white = (255, 255, 255);
      const yellow = (255, 255, 0);
      const red = (255, 0, 0);

      // Six grey arrows, no bar.
      final level = await render(0.0);
      expect(level.countRgb(grey), greaterThan(100));
      expect(level.countRgb(white), 0);
      // Two white arrows.
      final slow = await render(5.0);
      expect(slow.countRgb(white), greaterThan(0));
      expect(slow.countRgb(yellow), 0);
      // Four yellow.
      expect(
        (await render(12.0)).countRgb(yellow),
        greaterThan(slow.countRgb(white)),
      );
      // All six red, the blink colour at a whole second.
      final fast = await render(20.0);
      expect(fast.countRgb(red), greaterThan(0));
      expect(fast.countRgb(yellow), 0);
      expect(resolveBlinkColor('#8A8A8A', '#FF0000', 3.0), '#FF0000');
      expect(resolveBlinkColor('#8A8A8A', '#FF0000', 3.75), '#8A8A8A');
      // An element can put the bar back.
      expect(
        (await render(0.0, const {'bar': true})).countRgb(white),
        greaterThan(10),
      );
    });

    testWidgets('test_graph_shading_colour_and_opacity_are_element_keys', (
      tester,
    ) async {
      final wps = _decoWaypoints();
      const underLine = (30, 40); // t~21, ~17.6 m: under the bottom line
      const plain = <String, dynamic>{
        'width': 100,
        'height': 50,
        'rel_x': 0.0,
        'rel_y': 0.0,
        'color': '#0000FF',
      };
      _Rgb at(_Frame f, (int, int) xy) => f.at(xy.$1, xy.$2);

      // The default fill: a faint blue tint.
      var frame = await _graph(tester, plain, wps.last, wps);
      expect(at(frame, underLine).$3, greaterThan(0));
      // No fill at all.
      frame = await _graph(
        tester,
        {...plain, 'fill_opacity': 0},
        wps.last,
        wps,
      );
      expect(at(frame, underLine), (0, 0, 0));
      // Solid, in the fill colour.
      frame = await _graph(
        tester,
        {...plain, 'fill_color': '#00FF00', 'fill_opacity': 1.0},
        wps.last,
        wps,
      );
      expect(at(frame, underLine), (0, 255, 0));

      frame = await _graph(
        tester,
        {..._decoElem, 'stops_opacity': 0, 'ceiling_opacity': 0},
        wps.last,
        wps,
      );
      expect(at(frame, sixMStopOnly).$2, 0);
      expect(at(frame, ceilingPx).$1, 0);
      // Solid stops colour.
      frame = await _graph(
        tester,
        {
          ..._decoElem,
          'fill_opacity': 0,
          'stops_opacity': 1.0,
          'ceiling_opacity': 0,
        },
        wps.last,
        wps,
      );
      expect(at(frame, sixMStopOnly), (0, 255, 0));
    });

    testWidgets('test_graph_background_box_colour_and_opacity', (tester) async {
      final wps = _decoWaypoints();
      const plain = <String, dynamic>{
        'width': 100,
        'height': 50,
        'rel_x': 0.0,
        'rel_y': 0.0,
        'color': '#0000FF',
        'fill_opacity': 0,
      };
      // Inside the box, above the 20 m bottom, no ceiling band there.
      const corner = (30, 10);
      const grey = (200, 200, 200);
      // The default: a black box at 0.4 over the grey.
      var frame = await _graph(tester, plain, wps.last, wps, background: grey);
      expect(frame.at(corner.$1, corner.$2).$3, inExclusiveRange(100, 140));
      // No box at all.
      frame = await _graph(
        tester,
        {...plain, 'background_opacity': 0},
        wps.last,
        wps,
        background: grey,
      );
      expect(frame.at(corner.$1, corner.$2), grey);
      // Solid, in the box colour.
      frame = await _graph(
        tester,
        {...plain, 'background_color': '#FF0000', 'background_opacity': 1.0},
        wps.last,
        wps,
        background: grey,
      );
      expect(frame.at(corner.$1, corner.$2), (255, 0, 0));
    });

    testWidgets('test_box_pad_sets_the_highlight_box_margin', (tester) async {
      // Python draws _draw_text_box alone; here a Perdix 2 tank pressure
      // below the reserve gets its yellow box, with box_pad 0.15 and 0.04.
      Future<int> boxHeight(double padShare) async {
        final frame = await _render(
          tester,
          _shapeLayout(
            [
              {
                'field': 'primary_tank_pressure',
                'rel_x': 0.1,
                'rel_y': 0.2,
                'font_size': 100,
                'font_family': 'Roboto Condensed',
                'color': '#FFFFFF',
                'outline': false,
                'box_pad': padShare,
              },
            ],
            'Shearwater',
            'Perdix 2',
          ),
          _wp(depth: 10.0, tanks: {'T1': _tank(40)}),
          // The shape layout's own 1000 x 800 design: scale 1, so the box
          // is drawn at font size 100 as in Python's call.
          width: 1000,
          height: 800,
        );
        final (_, y0, _, y1) = frame.box(
          (c) => c.$1 > 200 && c.$2 > 200 && c.$3 < 60,
        );
        return y1 - y0;
      }

      expect(
        await boxHeight(0.15) - await boxHeight(0.04),
        greaterThanOrEqualTo(20),
      );
    });

    testWidgets('test_perdix_3_safety_timer_clears_its_title_box', (
      tester,
    ) async {
      // The timer's ink starts below the green SAFETY box, with black
      // between.
      final layout = _perdix3('main');
      final counting = _wp(
        depth: 5.0,
        maxDepth: 20.0,
        diveTime: 0,
        diveAlerts: ['safety_stop_started'],
        nextStopDepth: 5.0,
        nextStopTime: 120,
      );
      final frame = await _render(tester, layout, counting);
      bool green(_Rgb c) => c.$2 > 150 && c.$1 < 80 && c.$3 < 80;
      final perRow = List<int>.filled(frame.height, 0);
      for (final (_, y, c) in frame.pixels) {
        if (green(c)) {
          perRow[y]++;
        }
      }
      final rows = [
        for (var y = 0; y < frame.height; y++)
          if (perRow[y] > 0) y,
      ];
      final widest = perRow.reduce((a, b) => a > b ? a : b);
      final boxRows = [
        for (final y in rows)
          if (perRow[y] > widest * 0.8) y,
      ];
      final boxEnd = boxRows.last;
      final afterBox = [
        for (final y in rows)
          if (y > boxEnd) y,
      ];
      expect(afterBox, isNotEmpty);
      expect(afterBox.first, greaterThan(boxEnd + 1));
    });

    testWidgets(
      'test_notice_with_hide_others_takes_the_screen_and_draws_last',
      (tester) async {
        final layout = _shapeLayout([
          {
            'type': 'notice',
            'field': 'notice',
            'style': 'box',
            'rel_x': 0.0,
            'rel_y': 0.0,
            'width': 200,
            'height': 50,
            'hide_others': true,
          },
          {
            'field': 'depth',
            'rel_x': 0.0,
            'rel_y': 0.6,
            'font_size': 30,
            'color': '#FF0000',
            'outline': false,
          },
        ]);
        final quiet = _wp(depth: 20.0, t: 600);
        final alert = _wp(depth: 20.0, t: 600, diveAlerts: ['ndl_reached']);
        Future<int> red(Waypoint wp) async => (await _render(
          tester,
          layout,
          wp,
          width: 1000,
          height: 800,
        )).count((c) => c.$1 > 200 && c.$2 < 60);
        expect(await red(quiet), greaterThan(50));
        expect(await red(alert), 0);
      },
    );
  });

  // The gauges of Python 0.8.0 (tests/test_hud_renderer.py and the drawing
  // cases of tests/test_suunto_rules.py), on Python's `_gauge_frame`: a
  // 400x200 transparent shape skin in the telemetry-only mode.
  group('arc gauge, segment bar and the Suunto texts', () {
    Map<String, dynamic> gaugeLayout(
      List<Map<String, dynamic>> elements, [
      String model = 'EON Core',
    ]) => {
      'design_width': 400,
      'design_height': 200,
      'manufacturer': 'Suunto',
      'model': model,
      'hud_skin': {
        'type': 'shape',
        'width': 400,
        'height': 200,
        'anchor': 'TOP_LEFT',
        'opacity': 0.0,
        'linked_elements': elements,
      },
    };

    Future<_Frame> gaugeFrame(
      WidgetTester tester,
      List<Map<String, dynamic>> elements,
      Waypoint waypoint, {
      List<Waypoint>? waypoints,
      String model = 'EON Core',
    }) => _render(
      tester,
      gaugeLayout(elements, model),
      waypoint,
      waypoints: waypoints,
      renderLog: true,
      width: 400,
      height: 200,
    );

    const grey = (64, 64, 64);

    testWidgets('test_arc_fills_from_its_start_in_proportion_to_the_value', (
      tester,
    ) async {
      // A half-circle from 9 o'clock over the top to 3 o'clock, 0-250
      // bar, blue on a grey track.
      const elem = <String, dynamic>{
        'type': 'arc',
        'field': 'primary_tank_pressure',
        'rel_x': 0.0,
        'rel_y': 0.0,
        'width': 100,
        'height': 100,
        'thickness': 10,
        'start_angle': 180,
        'sweep': 180,
        'range_max': 250,
        'color': '#0000FF',
        'track_color': '#404040',
        'bands': [
          {'color': '#0000FF'},
        ],
      };
      Future<_Frame> frameAt(double? bar) => gaugeFrame(tester, [
        elem,
      ], _wp(depth: 10.0, tanks: bar == null ? null : {'T1': _tank(bar)}));

      final half = await frameAt(125.0);
      // 9, 12 and 3 o'clock on the ring.
      expect(half.at(4, 50), (0, 0, 255));
      expect(half.at(96, 50), grey);
      final top = half.at(50, 4);
      expect(top.$3 > 200 || top == grey, isTrue, reason: '$top');
      expect((await frameAt(250.0)).at(96, 50), (0, 0, 255));
      // The track is drawn without a value.
      expect((await frameAt(null)).at(4, 50), grey);
    });

    testWidgets('test_segment_bar_lights_whole_segments_from_the_bottom', (
      tester,
    ) async {
      const elem = <String, dynamic>{
        'type': 'segment_bar',
        'field': 'ascent_rate',
        'rel_x': 0.0,
        'rel_y': 0.0,
        'width': 10,
        'height': 98,
        'segments': 5,
        'segment_gap': 2,
        'range_max': 10,
        'track_color': '#404040',
        'bands': [
          {'max': 8, 'color': '#00FF00'},
          {'min': 8, 'max': 10, 'color': '#FFFF00'},
          {'min': 10, 'color': '#FF0000'},
        ],
      };
      // The rate is derived from the depth 10 s before, as for a log
      // without one.
      Future<_Frame> frameAt(
        double rate, [
        Map<String, dynamic> extra = const {},
      ]) {
        final wps = [_wp(depth: 20.0), _wp(t: 10, depth: 20.0 - rate / 6.0)];
        return gaugeFrame(
          tester,
          [
            {...elem, ...extra},
          ],
          wps[1],
          waypoints: wps,
        );
      }

      // Segment middles, bottom to top (18.8 px segments, 2 px gaps).
      const centres = [88, 68, 48, 28, 8];
      List<bool> lit(_Frame frame) => [
        for (final y in centres) frame.at(5, y) != grey,
      ];
      // 2 m/min a segment, whole ones.
      final five = await frameAt(5.0);
      expect(lit(five), [true, true, false, false, false]);
      expect(lit(await frameAt(0.0)), List.filled(5, false));
      expect(five.at(5, 88), (0, 255, 0));
      // Every lit segment in the value's red.
      final fast = await frameAt(12.0);
      expect(lit(fast), List.filled(5, true));
      expect(fast.at(5, 88), (255, 0, 0));
      // Each by its place: 8-10 m/min is yellow.
      final placed = await frameAt(12.0, {'color_mode': 'position'});
      expect(placed.at(5, 88), (0, 255, 0));
      expect(placed.at(5, 8), (255, 255, 0));
    });

    testWidgets('test_suunto_minute_formats_and_text_box (the box)', (
      tester,
    ) async {
      final frame = await gaugeFrame(tester, [
        {
          'field': 'dive_time',
          'rel_x': 0.1,
          'rel_y': 0.1,
          'font_size': 30,
          'color': '#FFFFFF',
          'box_color': '#FF8000',
        },
      ], _wp(depth: 10.0, diveTime: 170));
      // The box behind the value.
      expect(frame.countRgb((255, 128, 0)), greaterThan(200));
    });

    testWidgets('test_segment_bar_takes_the_brand_ascent_bands '
        '(tests/test_suunto_rules.py)', (tester) async {
      final wps = [_wp(depth: 20.0), _wp(t: 10, depth: 20.0 - 9.0 / 6.0)];
      final frame = await gaugeFrame(
        tester,
        [
          {
            'type': 'segment_bar',
            'field': 'ascent_rate',
            'rel_x': 0.0,
            'rel_y': 0.0,
            'width': 10,
            'height': 98,
            'segments': 5,
            'segment_gap': 2,
            'range_max': 10,
            'track_color': '#404040',
          },
        ],
        wps[1],
        waypoints: wps,
      );
      // Yellow at 9 m/min: 8-10 m/min (EON Core manual p.15).
      expect(frame.at(5, 88), (255, 255, 0));
    });

    testWidgets('test_uppercase_baseline_suffix_and_prime_timer '
        '(tests/test_suunto_rules.py, the baseline)', (tester) async {
      const elem = <String, dynamic>{
        'field': 'depth',
        'rel_x': 0.1,
        'rel_y': 0.1,
        'font_size': 80,
        'color': '#FFFFFF',
        'outline': false,
        'small_suffix': 'decimals',
        'small_suffix_scale': 0.5,
      };
      // The small decimal's ink rows: its bottom on the digits' baseline,
      // not level with their tops.
      Future<(int, int)> suffixRows(Map<String, dynamic> e) async {
        final frame = await gaugeFrame(tester, [e], _wp(depth: 36.6));
        final right = frame.columns((c) => _max3(c) > 0).last;
        final (_, y0, _, y1) = frame
            .crop(right - 15, 0, right + 1, frame.height)
            .box((c) => _max3(c) > 0);
        return (y0, y1);
      }

      final topAligned = await suffixRows(elem);
      final baseline = await suffixRows({
        ...elem,
        'small_suffix_align': 'baseline',
      });
      expect(baseline.$1, greaterThan(topAligned.$1 + 10));
      expect(baseline.$2, greaterThan(topAligned.$2 + 10));
    });

    testWidgets('test_horizontal_segment_bar_and_ndl_zero_in_the_page_format '
        '(tests/test_suunto_rules.py)', (tester) async {
      var frame = await gaugeFrame(
        tester,
        [
          {
            'type': 'segment_bar',
            'orientation': 'horizontal',
            'field': 'primary_tank_pressure',
            'rel_x': 0.0,
            'rel_y': 0.0,
            'width': 100,
            'height': 10,
            'segments': 1,
            'segment_gap': 0,
            'range_min': 0,
            'range_max': 200,
            'step': false,
            'bands': [
              {'color': '#0000FF'},
            ],
            'track_color': '#404040',
          },
        ],
        _wp(depth: 20.0, tanks: {'T1': _tank(100)}),
        model: 'Nautic',
      );
      // Filled from the left to half.
      expect(frame.at(25, 5), (0, 0, 255));
      expect(frame.at(75, 5), grey);
      // In deco the Nautic's NDL reads 0 in the page's own format ("0′").
      const ndl = <String, dynamic>{
        'field': 'ndl',
        'value_format': 'minutes_prime',
        'rel_x': 0.1,
        'rel_y': 0.1,
        'font_size': 30,
        'color': '#FFFFFF',
      };
      final deco = _wp(depth: 20.0, nextStopDepth: 6.0, decoStopDepth: 6.0);
      frame = await gaugeFrame(tester, [ndl], deco, model: 'Nautic');
      expect(frame.isBlack, isFalse);
      // What it draws: "0′".
      final ops = _renderer.drawHud(
        frameWidth: 400,
        frameHeight: 200,
        layout: gaugeLayout([ndl], 'Nautic'),
        waypoint: deco,
        renderLog: true,
      );
      expect(
        {
          for (final op in ops)
            if (op is TextOp) op.text,
        },
        {'0′'},
      );
    });
  });
}
