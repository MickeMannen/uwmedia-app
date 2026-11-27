// The TUSA computers' overlays (spec §10.107), which the Python app does
// not have: the TC1's Normal and Simple displays and the DC Solar Link's
// basic display, drawn from their manuals on a picture of each, its screen
// emptied.
// What each shows in a normal moment, a safety stop and deco, and that a
// monochrome screen has one ink.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/hud/dummy_telemetry.dart';
import 'package:uwmedia_app/core/hud/hud_ops.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/hud/template_tree.dart';
import 'package:uwmedia_app/core/hud/true_size.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/units/units.dart';

import 'template_tree_test.dart' show bundledFolder;

const _assets = 'assets/overlays/templates';

/// The TC1's ink and screen, and the DC Solar Link's (the pictures'
/// colours).
const _tc1Ink = (51, 53, 74);
const _tc1Screen = (238, 238, 244);
const _solarInk = (22, 50, 60);
const _solarScreen = (162, 166, 165);

/// The skins' sizes in pixels.
const _skinSizes = {'tc1': (803, 847), 'iq1204': (827, 836)};

void main() {
  final tree = TemplateTree(bundled: bundledFolder());
  final renderer = HudRenderer(
    TtfFonts(
      (file) => File('assets/fonts/$file').readAsBytesSync(),
      inkTables: InkTables.parse(
        File('assets/fonts/ink_tables.bin').readAsBytesSync(),
      ),
    ),
    HudRules(
      jsonDecode(File('assets/hud_rules.json').readAsStringSync())
          as Map<String, dynamic>,
    ),
  );
  final dive = buildDummyDive();

  Map<String, dynamic> layoutOf(String computer, String page) {
    final path = tree.resolveState('tusa', computer, page)!;
    return stripVariantMarkers(
      loadLayoutFile(
        path.replaceFirst('bundled/', '$_assets/'),
        (file) => File(file).readAsStringSync(),
      ),
    );
  }

  /// The texts drawn on [page] in a forced [state], with their colours.
  List<TextOp> texts(
    String computer,
    String page,
    String state, {
    UnitSystem units = UnitSystem.metric,
  }) {
    final (waypoint, history) = forcedDive(waypointAt(dive, 600), state);
    List<TextOp> of(List<HudOp> ops) => [
      for (final op in ops)
        if (op is TextOp) op else if (op is BlendOp) ...of(op.ops),
    ];
    return of(
      renderer.drawHud(
        frameWidth: 1920,
        frameHeight: 1080,
        layout: layoutOf(computer, page),
        waypoint: waypoint,
        waypoints: history,
        skinSize: _skinSizes[computer],
        units: units,
      ),
    );
  }

  Set<String> words(String computer, String page, String state) => {
    for (final op in texts(computer, page, state)) op.text,
  };

  test('two computers: the TC1 with two displays, the DC Solar Link', () {
    final brand = tree.brands['tusa']!;
    expect(brand.keys.toSet(), {'tc1', 'iq1204'});
    expect(brand['tc1']!['manufacturer'], 'Tusa');
    expect(brand['tc1']!['model'], 'TC1');
    expect(
      [
        for (final page in brand['tc1']!['pages'] as List<dynamic>)
          (page as Map<String, dynamic>)['id'],
      ],
      ['normal', 'simple'],
    );
    expect(brand['iq1204']!['model'], 'DC Solar Link');
    expect(
      [
        for (final page in brand['iq1204']!['pages'] as List<dynamic>)
          (page as Map<String, dynamic>)['id'],
      ],
      ['main'],
    );
  });

  test('each page has its skin, and says what is assumed', () {
    for (final (computer, page) in [
      ('tc1', 'normal'),
      ('tc1', 'simple'),
      ('iq1204', 'main'),
    ]) {
      final skin = layoutOf(computer, page)['hud_skin'] as Map<String, dynamic>;
      expect(skin['type'], 'image', reason: '$computer/$page');
      expect(
        File('$_assets/tusa/$computer/$page/${skin['path']}').existsSync(),
        isTrue,
        reason: '$computer/$page',
      );
      // The TC1's screen is round, the DC Solar Link's a rounded square.
      expect(
        (skin['screen'] as Map<String, dynamic>)['shape'],
        computer == 'tc1' ? 'ellipse' : 'rect',
      );
      final notes =
          tree.brands['tusa']![computer]!['notes'] as Map<String, dynamic>;
      expect(
        (notes['assumed'] as List<dynamic>).join(' '),
        contains('a picture of'),
        reason: computer,
      );
    }
    // Drawn true to life beside the others: both are watches.
    expect(bundledPictureWidthsMm['tusa/tc1'], 51);
    expect(bundledPictureWidthsMm['tusa/iq1204'], 53);
  });

  test('TC1 Normal: NDL, ascent rate and clock; a stop takes their place', () {
    final normal = words('tc1', 'normal', 'normal');
    expect(normal, containsAll(['NDL', '07', '10:10']));
    expect(normal, isNot(contains('STOP')));
    expect(normal, isNot(contains('CEILING')));

    final stop = words('tc1', 'normal', 'safety_stop');
    expect(stop, containsAll(['STOP', '02:50', 'CEILING']));
    expect(stop, isNot(contains('NDL')));
    // The safety stop's depth: 5 m (the manual, p.20).
    expect(stop, contains('5'));

    final deco = words('tc1', 'normal', 'deco_at_stop');
    expect(deco, containsAll(['STOP', 'CEILING', '6']));
    expect(deco, isNot(contains('NDL')));

    expect(words('tc1', 'normal', 'clear'), contains('CLEAR'));
  });

  test('TC1 Simple: the depth in its box, NDL, and the stop\'s tags', () {
    final normal = words('tc1', 'simple', 'normal');
    expect(normal, containsAll(['DEPTH', 'NDL', '07', '10:00']));
    expect(normal, isNot(contains('COUNT')));

    final stop = words('tc1', 'simple', 'safety_stop');
    expect(stop, containsAll(['COUNT', '2:50', 'DEPTH']));
    // Stacked beside the box, a letter each.
    expect(stop, containsAll(['S', 'F', 'T', 'Y', 'O', 'P']));
    expect(stop, isNot(contains('NDL')));

    final deco = words('tc1', 'simple', 'deco');
    expect(deco, containsAll(['COUNT', 'CEILG', 'DEPTH', '6']));
    expect(deco, containsAll(['D', 'E', 'C', 'O']));

    expect(words('tc1', 'simple', 'clear'), contains('CLEAR'));
  });

  test('DC Solar Link: NDL in the centre; in a stop the depth is there', () {
    final normal = words('iq1204', 'main', 'normal');
    // Dive time in minutes, depth, NDL, maximum depth, temperature.
    expect(normal, containsAll(['10', '30.0', '07', 'NDL', '23.4', 'm']));
    expect(normal, isNot(contains('DECO')));

    final stop = words('iq1204', 'main', 'safety_stop');
    expect(stop, containsAll(['2:50', '5.0']));
    expect(stop, isNot(contains('NDL')));

    final deco = words('iq1204', 'main', 'deco');
    expect(deco, containsAll(['DECO', '20.0']));
    expect(deco.any((text) => text.contains('6m')), isTrue);
    expect(deco, isNot(contains('NDL')));
  });

  test('a monochrome screen: one ink in every state, in both units', () {
    for (final (computer, page, ink, screen) in [
      ('tc1', 'normal', _tc1Ink, _tc1Screen),
      ('tc1', 'simple', _tc1Ink, _tc1Screen),
      ('iq1204', 'main', _solarInk, _solarScreen),
    ]) {
      for (final state in stateOptions) {
        if (state == 'auto') {
          continue;
        }
        for (final units in UnitSystem.values) {
          for (final op in texts(computer, page, state, units: units)) {
            // A tag is the screen's colour on a box of ink.
            expect(
              op.color,
              anyOf(ink, screen),
              reason: '$computer/$page $state ${units.key}: "${op.text}"',
            );
          }
        }
      }
    }
  });

  test('TC1 Simple: the nitrogen dots light from the left, the arc\'s end', () {
    // The arc runs with the clock from the right (40 degrees) to the
    // left (150); `fill_from: "end"` lights it from 150 backwards.
    final layout = layoutOf('tc1', 'simple');
    final (waypoint, history) = forcedDive(waypointAt(dive, 600), 'normal');
    List<ArcOp> of(List<HudOp> ops) => [
      for (final op in ops)
        if (op is ArcOp) op else if (op is BlendOp) ...of(op.ops),
    ];
    final arcs = of(
      renderer.drawHud(
        frameWidth: 1920,
        frameHeight: 1080,
        layout: layout,
        waypoint: waypoint!..n2TissueLoad = 30,
        waypoints: history,
        skinSize: _skinSizes['tc1'],
      ),
    );
    final lit = [
      for (final arc in arcs)
        if (arc.color == _tc1Ink) arc,
    ];
    // 30 % of ten dots: the three nearest the arc's end (150 degrees).
    expect(lit, hasLength(3));
    expect(
      lit.map((arc) => arc.end).reduce((a, b) => a > b ? a : b),
      closeTo(150, 1e-6),
    );
    expect(lit.every((arc) => arc.start > 110), isTrue);
  });

  test('feet and Fahrenheit where the units say so', () {
    final feet = {
      for (final op in texts(
        'iq1204',
        'main',
        'normal',
        units: UnitSystem.imperial,
      ))
        op.text,
    };
    expect(feet, contains('ft'));
    expect(feet, isNot(contains('m')));
  });
}
