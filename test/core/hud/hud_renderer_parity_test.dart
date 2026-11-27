// The overlay renderer against the Python app: for every case of the
// fixture made by tool/python_reference/renderer_fixture.py (every bundled
// template page and variant in the golden images' states and more, at
// moments of the dummy dives, on other frames, in the telemetry-only mode,
// placed and resized, and with changed elements) the port must ask for the
// same drawing operations as Python's Pillow and OpenCV calls: once given
// Pillow's own text measurements (the geometry alone), once measuring the
// text itself from the bundled fonts (what the app does).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/core/rules/hud_rules_engine.dart';
import 'package:uwmedia_app/core/units/units.dart';

import '../../helpers/renderer_reference.dart';
import 'template_tree_test.dart' show isOwnTemplate;

void main() {
  final reference = RendererReference.load();
  final rules = HudRules(
    jsonDecode(File('assets/hud_rules.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  final renderers = {
    'Pillow\'s measurements': HudRenderer(reference.fonts, rules),
    'the port\'s font reader': HudRenderer(
      TtfFonts(
        (file) => File('assets/fonts/$file').readAsBytesSync(),
        inkTables: InkTables.parse(
          File('assets/fonts/ink_tables.bin').readAsBytesSync(),
        ),
      ),
      rules,
    ),
  };

  final byTemplate = <String, List<Map<String, dynamic>>>{};
  for (final c in reference.cases) {
    byTemplate
        .putIfAbsent(
          (c['template'] as List<dynamic>).whereType<String>().join('/'),
          () => [],
        )
        .add(c);
  }

  test('the fixture covers every bundled page', () {
    final pages = Directory('assets/overlays/templates')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('normal.json'))
        // Forward slashes on Windows too.
        .map(
          (f) => f.parent.path.replaceAll(r'\', '/').split('templates/').last,
        )
        // This app's own overlays are not in the Python app, so not in
        // its fixture either (simple_overlays_test.dart and
        // tusa_overlays_test.dart have them).
        .where((page) => !isOwnTemplate(page))
        .toSet();
    // A page with variants has a shared base that is no page of its own.
    final bases = {
      for (final page in pages)
        if (pages.any((other) => other.startsWith('$page/'))) page,
    };
    expect(byTemplate.keys.toSet(), pages.difference(bases));
  });

  for (final MapEntry(key: measuring, value: renderer) in renderers.entries) {
    group('with $measuring:', () {
      for (final MapEntry(key: name, value: cases) in byTemplate.entries) {
        test('$name (${cases.length} cases)', () {
          final failures = <String>[];
          for (final c in cases) {
            final template = c['template'] as List<dynamic>;
            var layout = reference.layout(template);
            if (c['changed'] case final String change) {
              layout = changedLayout(layout, change);
            }
            final size = c['size'] as List<dynamic>? ?? const [1920, 1080];
            if (c['placed'] case [final num x, final num y, final num scale]) {
              layout = resolveOverlayInstanceLayout(
                layout,
                x.toDouble(),
                y.toDouble(),
                scale.toDouble(),
                size[0] as int,
                size[1] as int,
              );
            }
            final (waypoint, history) = reference.situation(c);
            final what =
                '${c['situation']}'
                '${c['units'] == null ? '' : ', ${c['units']}'}'
                '${c['size'] == null ? '' : ', ${size[0]}x${size[1]}'}'
                '${c['render_log'] == true ? ', telemetry only' : ''}'
                '${c['placed'] == null ? '' : ', placed'}'
                '${c['changed'] == null ? '' : ', ${c['changed']}'}';
            final String? difference;
            try {
              final ops = renderer.drawHud(
                frameWidth: size[0] as int,
                frameHeight: size[1] as int,
                layout: layout,
                waypoint: waypoint,
                waypoints: history,
                skinSize: reference.skinSize(template),
                renderLog: c['render_log'] == true,
                units: normalizeUnits(c['units']),
              );
              difference = firstOpDifference([
                for (final op in ops) op.toJson(),
              ], c['ops'] as List<dynamic>);
            } on StateError catch (e) {
              failures.add('$what: ${e.message}');
              continue;
            }
            if (difference != null) {
              failures.add('$what: $difference');
            }
          }
          expect(
            failures,
            isEmpty,
            reason:
                '${failures.length} of ${cases.length} cases differ; the first:\n'
                '${failures.take(3).join('\n')}',
          );
        });
      }
    });
  }
}
