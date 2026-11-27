// The layout sweep over every bundled template, ported from the Python
// app's tests/test_template_sweep.py (simulator.md A4): each page and
// variant is laid out in every forced state of the Overlay Designer and at
// a few moments of the dummy dive (a rebreather page also at moments of the
// rebreather dive), in both unit systems, and every text, badge and notice
// element must stay inside the skin (or its screen, round or square) and
// clear of the others, of the icons and bars, and of an arc gauge's band.
// The geometry is the designer's elementNativeBounds, the same mirror of
// the renderer the designer's hit boxes use, so nothing is drawn.
//
// The oracle is tool/python_reference/template_sweep_fixture.py: Python's
// report per page and unit system before the known-issue list is applied,
// that list itself (tests/template_sweep_known.json, verbatim) and Pillow's
// text measurements. The port's report must equal Python's, string for
// string, first with Pillow's measurements replayed (the sweep's own
// logic) and then with the port's own font reader (what the app measures).
// The sweep proper then fails on any issue the known list does not accept,
// on every bundled page, the app's own simple overlays included; the known
// list is read from the fixture, so it changes only with the Python app's.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/hud/dummy_telemetry.dart';
import 'package:uwmedia_app/core/hud/hud_designer.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/hud_text.dart';
import 'package:uwmedia_app/core/hud/image_size.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/hud/template_tree.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/rules/hud_notices.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

import '../../helpers/renderer_reference.dart';
import 'template_tree_test.dart' show bundledFolder;

const _assets = 'assets/overlays/templates';

/// Issues accepted on this app's own pages, which the Python app's known
/// list (read from the fixture, and frozen with it) cannot name. Each with
/// its reason.
const _ownKnown = <String, Map<String, String>>{
  'tusa/tc1/simple': {
    // The nitrogen level runs along the lower rim of a round screen: the
    // band itself is inside the screen (radius 195 of 220), the corners
    // of the box round a wide arc never are.
    'n2 leaves the round screen': 'an arc along the rim of a round screen',
  },
};

/// Px of overlap or overhang that counts as touching, not colliding
/// (tests/test_template_sweep.py `SLACK`).
const _slack = 2.0;

/// Bottom, high PPO2, fast ascent, missed stop, reserve
/// (`DUMMY_MOMENTS`).
const _dummyMoments = [400, 930, 1160, 1300, 1600];

/// A CC page ("dive": "ccr" in its manifest) also at these moments of the
/// rebreather dive: low setpoint, high setpoint, a cell out of the vote,
/// bailout at the stop, the setpoint switch back down (`CCR_MOMENTS`).
const _ccrMoments = [20, 600, 930, 1300, 1580];

typedef _Page = (String brand, String computer, String page, String? variant);
typedef _Box = (double, double, double, double);
typedef _Report = Map<String, List<String>>;

/// A report as [key, details] pairs, so a comparison checks the order of
/// the keys too (Python's dict order: the first issue's order).
List<List<Object>>? _ordered(_Report? report) => report == null
    ? null
    : [
        for (final MapEntry(:key, :value) in report.entries) [key, value],
      ];

/// `_page_key`: "brand/computer/page[/variant]".
String _pageKey(_Page page) =>
    [page.$1, page.$2, page.$3, ?page.$4].where((s) => s.isNotEmpty).join('/');

/// `bundled_pages()`: every bundled page and variant that has a state.
List<_Page> _bundledPages(TemplateTree tree) => [
  for (final MapEntry(key: brand, value: computers) in tree.brands.entries)
    for (final MapEntry(key: computer, value: manifest) in computers.entries)
      if (manifest['origin'] == originBundled)
        for (final page
            in (manifest['pages'] as List<dynamic>? ?? const [])
                .cast<Map<String, dynamic>>())
          for (final variant in [
            ...?(page['variants'] as List<dynamic>?)?.cast<String?>(),
            if ((page['variants'] as List<dynamic>? ?? const []).isEmpty) null,
          ])
            if (tree.resolveState(
                  brand,
                  computer,
                  page['id'] as String,
                  variant: variant,
                ) !=
                null)
              (brand, computer, page['id'] as String, variant),
];

/// `page_is_ccr`: the manifest marks the page as a rebreather screen.
bool _pageIsCcr(TemplateTree tree, _Page page) =>
    tree.page(page.$1, page.$2, page.$3)?['dive'] == 'ccr';

/// `load_page`: the flat layout and the skin's size (a shape skin's own,
/// else the image's, read from the file beside the state file).
(Map<String, dynamic>, (double, double)) _loadPage(
  TemplateTree tree,
  _Page page,
) {
  final path = tree.resolveState(page.$1, page.$2, page.$3, variant: page.$4)!;
  final layout = stripVariantMarkers(
    loadLayoutFile(path, (file) => tree.readText(file)!),
  );
  final skin = layout['hud_skin'] as Map<String, dynamic>;
  if (skin['type'] == 'shape') {
    return (
      layout,
      (
        skin.containsKey('width') ? pyFloatOf(skin['width'])! : 400.0,
        skin.containsKey('height') ? pyFloatOf(skin['height'])! : 200.0,
      ),
    );
  }
  // The tree's paths start with its root, "bundled".
  final file = p.posix.normalize(
    p.posix.join(p.posix.dirname(path), skin['path'] as String),
  );
  final (w, h) = imageSize(
    File('$_assets/${file.substring('bundled/'.length)}').readAsBytesSync(),
  )!;
  return (layout, (w.toDouble(), h.toDouble()));
}

/// Python `str()` of a JSON value used as a name.
String _pyStr(Object? value) => switch (value) {
  null => 'None',
  true => 'True',
  false => 'False',
  _ => '$value',
};

/// Python `x in (value or ())` for a list or a string.
bool _pyIn(String x, Object? value) => switch (value) {
  final List<dynamic> list => list.contains(x),
  final String text => text.contains(x),
  _ => false,
};

/// Python `f"{x:.0f}"`.
String _f0(double x) => pyFormatFixed(x, 0);

/// `situations()`: (name, waypoint, history) per forced state of the
/// designer, then per moment of the dummy dive.
Iterable<(String, Waypoint?, List<Waypoint>?)> _situations(bool ccr) sync* {
  // Python's sample dive, without the port's SAC (spec §10.54).
  final dive = buildDummyDive(ccr: ccr, sac: false);
  final base = waypointAt(dive, 12 * 60);
  for (final state in stateOptions) {
    if (state == 'auto') {
      continue;
    }
    final (wp, history) = forcedDive(base, state);
    yield (state, wp, history);
  }
  for (final t in [..._dummyMoments, if (ccr) ..._ccrMoments]) {
    yield ('dive@$t', waypointAt(dive, t), dive.waypoints);
  }
}

/// `_overlap`: the overlap (width, height) of two boxes beyond the slack,
/// or `null`.
(double, double)? _overlap(_Box a, _Box b) {
  final w = math.min(a.$3, b.$3) - math.max(a.$1, b.$1) - _slack;
  final h = math.min(a.$4, b.$4) - math.max(a.$2, b.$2) - _slack;
  return w > 0 && h > 0 ? (w, h) : null;
}

/// Python `a % b` for a positive [b].
double _pyMod(double a, double b) => a - b * (a / b).floorToDouble();

/// `_on_ring`: whether [box] touches an arc gauge's band (between its
/// inner and outer radius, within its sweep), sampled on a 9 x 9 grid over
/// the box; [_slack] px of tolerance on the radii.
bool _onRing(_Box box, Map<String, dynamic> elem, (double, double) size) {
  final (w, h) = size;
  double num(String key, double fallback) =>
      elem.containsKey(key) ? pyFloatOf(elem[key])! : fallback;
  final x = num('rel_x', 0.0) * w;
  final y = num('rel_y', 0.0) * h;
  final rx = num('width', 120) / 2.0;
  final ry = num('height', 120) / 2.0;
  final cx = x + rx;
  final cy = y + ry;
  final thick = num('thickness', 12);
  final start = num('start_angle', 135);
  final sweep = num('sweep', 270);
  final (x0, y0, x1, y1) = box;
  for (var i = 0; i < 9; i++) {
    for (var j = 0; j < 9; j++) {
      final px = x0 + (x1 - x0) * i / 8.0;
      final py = y0 + (y1 - y0) * j / 8.0;
      // The radius along this direction, as a fraction of the ellipse's.
      final dx = (px - cx) / rx;
      final dy = (py - cy) / ry;
      // Python math.hypot, correctly rounded; this can be an ulp off.
      final dist = math.sqrt(dx * dx + dy * dy);
      final rPx = dist * math.min(rx, ry);
      final inner = math.min(rx, ry) - thick;
      if (!(inner + _slack < rPx && rPx < math.min(rx, ry) - _slack)) {
        continue;
      }
      final angle = _pyMod(math.atan2(dy, dx) * (180.0 / math.pi) - start, 360);
      if (angle <= sweep) {
        return true;
      }
    }
  }
  return false;
}

/// `_inside_ellipse`: every corner of [box] inside the ellipse filling
/// [screen], with [_slack] px of tolerance on the radii.
bool _insideEllipse(_Box box, _Box screen) {
  final (x0, y0, x1, y1) = box;
  final (sx0, sy0, sx1, sy1) = screen;
  final cx = (sx0 + sx1) / 2.0;
  final cy = (sy0 + sy1) / 2.0;
  final rx = (sx1 - sx0) / 2.0 + _slack;
  final ry = (sy1 - sy0) / 2.0 + _slack;
  return [(x0, y0), (x1, y0), (x0, y1), (x1, y1)].every((c) {
    final ex = (c.$1 - cx) / rx;
    final ey = (c.$2 - cy) / ry;
    return ex * ex + ey * ey <= 1.0;
  });
}

/// `sweep_page`: (key, detail) per issue of one page in one situation.
List<(String, String)> _sweepPage(
  HudDesigner designer,
  HudContext ctx,
  Map<String, dynamic> layout,
  (double, double) size,
  String situation,
  Waypoint? wp,
  List<Waypoint>? waypoints,
) {
  final manufacturer = ctx.manufacturer;
  final model = ctx.model;
  final hudSkin = layout['hud_skin'] as Map<String, dynamic>;
  final elements = (hudSkin['linked_elements'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  final state = ctx.rules.resolveState(manufacturer, model, wp, waypoints);
  final notice = activeNotice(
    ctx.rules,
    manufacturer,
    model,
    wp,
    waypoints: waypoints,
    units: ctx.units,
  );
  final boxes = <(String, String, _Box)>[];
  // An arc gauge: text may sit inside it, not on its band.
  final rings = <(String, Map<String, dynamic>)>[];
  final circuit = truthy(wp?.circuit) ? wp!.circuit : 'OC';
  final hideAll =
      notice != null &&
      elements.any((e) => e['type'] == 'notice' && truthy(e['hide_others']));
  for (final elem in elements) {
    final kind = elementKind(elem);
    if (hideAll && kind != 'notice') {
      continue;
    }
    if (_pyIn(state, elem['hide_in_states']) ||
        _pyIn(circuit, elem['hide_in_circuits'])) {
      continue;
    }
    if (notice != null && truthy(elem['hide_when_notice'])) {
      continue;
    }
    final name = _pyStr(
      truthy(elem['id'])
          ? elem['id']
          : truthy(elem['label'])
          ? elem['label']
          : elem.containsKey('field')
          ? elem['field']
          : kind,
    );
    String? text;
    List<BadgeLine>? lines;
    switch (kind) {
      case 'text':
        final (shown, raw) = resolveElementText(
          ctx,
          elem.containsKey('field') ? elem['field'] as String? ?? '' : '',
          wp,
          waypoints,
        );
        if (shown == null || shown.isEmpty) {
          continue;
        }
        text = _pyStr(applyValueFormat(elem, shown, raw, ctx.units));
      case 'badge':
        lines = badgeLines(ctx, elem, wp, waypoints);
        if (lines == null || lines.isEmpty) {
          continue;
        }
      case 'notice':
        if (notice == null) {
          continue;
        }
      case 'graph':
        continue;
      case 'arc':
        rings.add((name, elem));
    }
    final (x0, y0, x1, y1) = designer.elementNativeBounds(
      elem,
      size.$1,
      size.$2,
      text: text,
      badgeLines: lines,
      units: ctx.units,
    );
    boxes.add((
      name,
      kind,
      (x0.toDouble(), y0.toDouble(), x1.toDouble(), y1.toDouble()),
    ));
  }

  final issues = <(String, String)>[];
  final (w, h) = size;
  final screen = hudSkin['screen'];
  final _Box glass;
  final String where;
  if (screen is Map<String, dynamic>) {
    // The computer's screen inside the skin: text must stay on the glass.
    double at(String key, double d) => pyFloatOf(screen[key])! * d;
    glass = (at('x0', w), at('y0', h), at('x1', w), at('y1', h));
    where = 'the screen';
  } else {
    glass = (0.0, 0.0, w, h);
    where = 'the skin';
  }
  final roundScreen =
      screen is Map<String, dynamic> && screen['shape'] == 'ellipse';
  final (sx0, sy0, sx1, sy1) = glass;
  for (final (name, _, box) in boxes) {
    final (x0, y0, x1, y1) = box;
    if (x0 < sx0 - _slack ||
        y0 < sy0 - _slack ||
        x1 > sx1 + _slack ||
        y1 > sy1 + _slack) {
      issues.add((
        '$name leaves $where',
        '$situation: (${_f0(x0)},${_f0(y0)})-(${_f0(x1)},${_f0(y1)}) '
            'of (${_f0(sx0)},${_f0(sy0)})-(${_f0(sx1)},${_f0(sy1)})',
      ));
    } else if (roundScreen && !_insideEllipse(box, glass)) {
      // A round screen (Descent Mk3i, Teric, Tern): the box's corners must
      // be on the glass too, not only inside its bounding rectangle.
      issues.add((
        '$name leaves the round screen',
        '$situation: (${_f0(x0)},${_f0(y0)})-(${_f0(x1)},${_f0(y1)}) '
            'of the ellipse in '
            '(${_f0(sx0)},${_f0(sy0)})-(${_f0(sx1)},${_f0(sy1)})',
      ));
    }
  }
  const textKinds = ['text', 'badge', 'notice'];
  final textual = [
    for (final b in boxes)
      if (textKinds.contains(b.$2)) b,
  ];
  final graphics = [
    for (final b in boxes)
      if (!textKinds.contains(b.$2) && b.$2 != 'arc') b,
  ];
  for (final (i, (na, ka, ba)) in textual.indexed) {
    // Text against text, and text against an icon, a bar or chevrons.
    for (final (nb, _, bb) in [...textual.skip(i + 1), ...graphics]) {
      final over = _overlap(ba, bb);
      if (over != null) {
        issues.add((
          '$na overlaps $nb',
          '$situation: by ${_f0(over.$1)}x${_f0(over.$2)} px',
        ));
      }
    }
    for (final (nb, ring) in rings) {
      // A pop-up covers whatever is under it, as on the device.
      if (ka != 'notice' && _onRing(ba, ring, size)) {
        issues.add(('$na overlaps $nb', '$situation: on its band'));
      }
    }
  }
  return issues;
}

/// `sweep_report`: {issue key: [details]} over every situation.
_Report _sweepReport(
  HudDesigner designer,
  HudRules rules,
  Map<String, dynamic> layout,
  (double, double) size,
  UnitSystem units, {
  bool ccr = false,
}) {
  // Not HudContext.of: Python's sweep runs every helper in the unit system
  // under test (units_override), never in a layout's own `units`.
  final ctx = HudContext(
    rules.withOverrides(layout['rules']),
    rulesManufacturer(layout),
    layout.containsKey('model') ? layout['model'] as String? : 'Perdix2',
    units,
  );
  final report = <String, List<String>>{};
  for (final (situation, wp, waypoints) in _situations(ccr)) {
    for (final (key, detail) in _sweepPage(
      designer,
      ctx,
      layout,
      size,
      situation,
      wp,
      waypoints,
    )) {
      report.putIfAbsent(key, () => []).add(detail);
    }
  }
  return report;
}

void main() {
  final fixture = jsonDecode(
    utf8.decode(
      gzip.decode(
        File(
          'test/fixtures/python_reference/hud_designer/'
          'template_sweep.json.gz',
        ).readAsBytesSync(),
      ),
    ),
  ) as Map<String, dynamic>;
  final rules = HudRules(
    jsonDecode(File('assets/hud_rules.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  final replay = HudDesigner(
    HudRenderer(
      ReplayFonts(
        fixture['measures'] as Map<String, dynamic>,
        metrics: fixture['metrics'] as Map<String, dynamic>,
        glyphs: fixture['glyphs'] as Map<String, dynamic>,
      ),
      rules,
    ),
  );
  final own = HudDesigner(
    HudRenderer(
      TtfFonts(
        (file) => File('assets/fonts/$file').readAsBytesSync(),
        inkTables: InkTables.parse(
          File('assets/fonts/ink_tables.bin').readAsBytesSync(),
        ),
      ),
      rules,
    ),
  );
  final known = fixture['known'] as Map<String, dynamic>;
  final pythonReports = fixture['reports'] as Map<String, dynamic>;
  _Report reportOf(Object? json) => {
    for (final MapEntry(:key, :value) in (json as Map<String, dynamic>).entries)
      key: (value as List<dynamic>).cast<String>(),
  };

  // The Python app's tree (without this app's own overlays) and the whole
  // bundled tree.
  final pythonTree = TemplateTree(bundled: bundledFolder(asPython: true));
  final tree = TemplateTree(bundled: bundledFolder());

  /// The port's report per "page@units" with the port's own fonts, made
  /// once for the parity test and the sweep.
  final ownReports = <String, _Report>{};
  _Report ownReport(_Page page) {
    final key = _pageKey(page);
    if (!ownReports.containsKey('$key@metric')) {
      final (layout, size) = _loadPage(tree, page);
      for (final units in UnitSystem.values) {
        ownReports['$key@${units.key}'] = _sweepReport(
          own,
          rules,
          layout,
          size,
          units,
          ccr: _pageIsCcr(tree, page),
        );
      }
    }
    return ownReports['$key@metric']!;
  }

  group('parity with the Python sweep', () {
    test('the same pages, rebreather pages and skin sizes', () {
      final pages = _bundledPages(pythonTree);
      expect([
        for (final page in pages) [page.$1, page.$2, page.$3, page.$4],
      ], fixture['pages']);
      expect(fixture['unit_systems'], [
        for (final units in UnitSystem.values) units.key,
      ]);
      expect(fixture['slack'], _slack);
      expect([
        for (final page in pages)
          if (_pageIsCcr(pythonTree, page)) _pageKey(page),
      ], fixture['ccr_pages']);
      final sizes = fixture['sizes'] as Map<String, dynamic>;
      for (final page in pages) {
        final (_, (w, h)) = _loadPage(pythonTree, page);
        expect([w, h], sizes[_pageKey(page)], reason: _pageKey(page));
      }
    });

    test("every page's report, Pillow's measurements replayed", () {
      for (final page in _bundledPages(pythonTree)) {
        final (layout, size) = _loadPage(pythonTree, page);
        for (final units in UnitSystem.values) {
          final key = '${_pageKey(page)}@${units.key}';
          expect(
            _ordered(
              _sweepReport(
                replay,
                rules,
                layout,
                size,
                units,
                ccr: _pageIsCcr(pythonTree, page),
              ),
            ),
            _ordered(reportOf(pythonReports[key])),
            reason: key,
          );
        }
      }
    });

    test('invented layouts: arc bands, round screens, hidden elements', () {
      final synthetic = fixture['synthetic'] as Map<String, dynamic>;
      expect(synthetic, hasLength(4));
      synthetic.forEach((name, value) {
        final c = value as Map<String, dynamic>;
        final layout = c['layout'] as Map<String, dynamic>;
        final units = UnitSystem.values.byName(c['units'] as String);
        final want = reportOf(c['report']);
        expect(want, isNotEmpty);
        for (final (fonts, designer) in [('replay', replay), ('own', own)]) {
          expect(
            _ordered(
              _sweepReport(
                designer,
                rules,
                layout,
                (400.0, 200.0),
                units,
                ccr: c['ccr'] as bool,
              ),
            ),
            _ordered(want),
            reason: '$name, $fonts fonts',
          );
        }
      });
    });

    test("every page's report, the port's own fonts", () {
      for (final page in _bundledPages(pythonTree)) {
        ownReport(page);
      }
      for (final MapEntry(:key, :value) in pythonReports.entries) {
        expect(
          _ordered(ownReports[key]),
          _ordered(reportOf(value)),
          reason: key,
        );
      }
    });
  });

  group('tests/test_template_sweep.py', () {
    // test_bundled_page_lays_out_in_every_state, for every page of the
    // whole bundled tree and both unit systems. A known issue applies to
    // both unless the entry is keyed `<page>@imperial`.
    test('test_bundled_page_lays_out_in_every_state', () {
      final failures = <String>[];
      final pages = _bundledPages(tree);
      for (final page in pages) {
        ownReport(page);
        final pageKey = _pageKey(page);
        for (final units in UnitSystem.values) {
          final accepted = {
            ...?_ownKnown[pageKey],
            ...?known[pageKey] as Map<String, dynamic>?,
            if (units == UnitSystem.imperial)
              ...?known['$pageKey@imperial'] as Map<String, dynamic>?,
          };
          final key = '$pageKey@${units.key}';
          final fresh = {
            for (final MapEntry(key: issue, value: details)
                in ownReports[key]!.entries)
              if (!accepted.containsKey(issue)) issue: details,
          };
          if (fresh.isNotEmpty) {
            failures.add(
              '$key: ${fresh.length} new layout issue(s) - check them by '
              'eye in the Overlay Designer (State list) and either fix the '
              'template or add the key to the Python app\'s '
              'tests/template_sweep_known.json with a note:\n  '
              '${[for (final MapEntry(:key, :value) in fresh.entries) '$key  (${value.length} situation(s), e.g. ${value.first})'].join('\n  ')}',
            );
          }
        }
      }
      expect(pages.length, greaterThan(115));
      expect(failures, isEmpty, reason: failures.join('\n'));
    });

    test('test_known_issue_list_only_names_bundled_pages', () {
      final keys = {for (final page in _bundledPages(tree)) _pageKey(page)};
      final stale = [
        for (final key in known.keys)
          if (!key.startsWith('_') &&
              !keys.contains(
                key.endsWith('@imperial')
                    ? key.substring(0, key.length - '@imperial'.length)
                    : key,
              ))
            key,
      ];
      expect(
        stale,
        isEmpty,
        reason:
            'the known list names pages that no '
            'longer exist',
      );
    });
  });
}
