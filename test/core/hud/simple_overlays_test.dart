// The simple overlays bundled for every platform (generic/simple, user
// story U9.5): a row, a column, a box and two rows for portrait frames,
// each light and dark, with the NDL giving way to the deco stop while the
// dive is in deco; those with a tank also for a sidemount pair.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/hud/dummy_telemetry.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/template_tree.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';

import 'template_tree_test.dart' show bundledFolder;

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
  final pair = buildDummyDive(variant: 'sidemount');

  List<String> variants(String page) => [
    for (final entry
        in (tree.brands['generic']!['simple']!['pages'] as List<dynamic>)
            .cast<Map<String, dynamic>>())
      if (entry['id'] == page) ...(entry['variants'] as List).cast<String>(),
  ];

  List<String> pages() => [
    for (final page
        in (tree.brands['generic']!['simple']!['pages'] as List<dynamic>)
            .cast<Map<String, dynamic>>())
      page['id'] as String,
  ];

  String drawn(String page, int seconds, {int width = 1920, String? variant}) {
    variant ??= variants(page).firstOrNull;
    final path = tree.resolveState(
      'generic',
      'simple',
      page,
      variant: variant,
    )!;
    final layout = jsonDecode(
      File(path.replaceFirst('bundled/', 'assets/overlays/templates/'))
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    final ops = renderer.drawHud(
      frameWidth: width,
      frameHeight: width * 9 ~/ 16,
      layout: layout,
      waypoint: waypointAt(variant == 'sidemount' ? pair : dive, seconds),
      waypoints: (variant == 'sidemount' ? pair : dive).waypoints,
    );
    return jsonEncode([for (final op in ops) op.toJson()]);
  }

  test('four looks, each light and dark', () {
    expect(tree.brands['generic']!['simple']!['model'], 'Simple');
    expect(pages(), [
      'row_dark',
      'row_light',
      'column_dark',
      'column_light',
      'box_dark',
      'box_light',
      'block_dark',
      'block_light',
    ]);
  });

  test('before deco the NDL shows, in deco the stop takes its place', () {
    for (final page in pages()) {
      final normal = drawn(page, 600);
      expect(normal, contains('"NDL"'), reason: page);
      expect(normal, isNot(contains('"STOP"')), reason: page);
      expect(normal, contains('"DEPTH"'), reason: page);
      final deco = drawn(page, 900);
      expect(deco, contains('"STOP"'), reason: page);
      expect(deco, isNot(contains('"NDL"')), reason: page);
    }
  });

  test('the row and column carry gas and tank pressure, the box does not', () {
    for (final page in pages()) {
      final ops = drawn(page, 600);
      final full = !page.startsWith('box_');
      expect(ops.contains('"GAS"'), full, reason: page);
      expect(ops.contains('"TANK"'), full, reason: page);
    }
  });

  test(
    'with a tank: one tank, or a sidemount pair under the tanks\' names',
    () {
      for (final page in pages()) {
        if (page.startsWith('box_')) {
          expect(variants(page), isEmpty, reason: page);
          continue;
        }
        expect(variants(page), ['single_tank', 'sidemount'], reason: page);
        final one = drawn(page, 600, variant: 'single_tank');
        expect(one, contains('"TANK"'), reason: page);
        final two = drawn(page, 600, variant: 'sidemount');
        expect(two, isNot(contains('"TANK"')), reason: page);
        expect(two, contains('"Left"'), reason: page);
        expect(two, contains('"Right"'), reason: page);
        expect(two, contains('"GAS"'), reason: page);
      }
    },
  );
}
