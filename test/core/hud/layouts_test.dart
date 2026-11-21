// The template layout files against the Python app: the cases of its
// tests/test_layouts.py that are about the files' content (the folder
// listing is the app's, with its asset list and data folder).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';

const _templates = 'assets/overlays/templates';

String _read(String path) => File(path).readAsStringSync();
Map<String, dynamic> _json(String path) =>
    jsonDecode(_read(path)) as Map<String, dynamic>;
List<Map<String, dynamic>> _elements(Map<String, dynamic> layout) => [
  for (final e
      in (layout['hud_skin'] as Map<String, dynamic>)['linked_elements']
          as List<dynamic>)
    e as Map<String, dynamic>,
];

Map<String, dynamic> _tinyBase() => {
  'manufacturer': 'Garmin',
  'model': 'x',
  'design_width': 1920,
  'design_height': 1080,
  'hud_skin': {
    'type': 'image',
    'path': 'normal.png',
    'scale': 0.5,
    'linked_elements': [
      {
        'id': 'depth',
        'field': 'depth',
        'rel_x': 0.1,
        'rel_y': 0.1,
        'font_size': 20,
      },
      {
        'id': 'ndl',
        'field': 'ndl',
        'rel_x': 0.2,
        'rel_y': 0.2,
        'font_size': 20,
      },
    ],
  },
};

void main() {
  test('every bundled manifest names pages that exist, and their skins', () {
    for (final manifest
        in Directory(_templates)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('manifest.json'))) {
      final data = _json(manifest.path);
      expect(data['manufacturer'], isA<String>(), reason: manifest.path);
      // Forward slashes on Windows too, as the layout loader reads them.
      final folder = manifest.parent.path.replaceAll(r'\', '/');
      for (final page in data['pages'] as List<dynamic>) {
        final dir = Directory(
          '$folder/${(page as Map<String, dynamic>)['id']}',
        );
        expect(dir.existsSync(), isTrue, reason: dir.path);
        final variants = sortVariants([
          for (final d in dir.listSync().whereType<Directory>())
            d.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
        ]);
        for (final state
            in variants.isEmpty
                ? ['${dir.path}/normal.json']
                : [for (final v in variants) '${dir.path}/$v/normal.json']) {
          final layout = loadLayoutFile(state, _read);
          final skin = layout['hud_skin'] as Map<String, dynamic>;
          if (skin['type'] != 'shape') {
            final image = File('${File(state).parent.path}/${skin['path']}')
                .absolute;
            expect(
              image.existsSync(),
              isTrue,
              reason: '$state: ${skin['path']}',
            );
          }
        }
      }
    }
  });

  test('variant names and labels', () {
    expect(sortVariants(['sidemount', 'zebra', 'single_tank', 'alpha']), [
      'single_tank',
      'sidemount',
      'alpha',
      'zebra',
    ]);
    expect(variantDisplayName('single_tank'), 'Single tank');
    expect(variantDisplayName('twin_set'), 'Twin Set');
    expect(
      pageDisplayName(const {'id': 'main', 'name': 'Main Screen'}),
      'Main Screen',
    );
    expect(
      pageDisplayName(const {
        'id': 'mine',
        'name': 'My Main',
        'origin': 'user',
      }),
      'My Main · yours',
    );
    expect(pageDisplayName(const {'id': 'gases'}), 'gases');
  });

  group('tests/test_layouts.py', () {
    for (final computer in ['x50i', 'mk3i']) {
      test('test_garmin_main_variants_share_one_base[$computer]', () {
        final page = '$_templates/garmin/$computer/main';
        final base = _json('$page/normal.json');
        final baseElements = _elements(base);
        final ids = [for (final e in baseElements) e['id']];
        expect(ids.toSet().length, ids.length);
        expect(
          baseElements.any(
            (e) =>
                (e['field'] as String).startsWith('primary_tank') ||
                (e['field'] as String).startsWith('secondary_tank'),
          ),
          isFalse,
        );
        expect(File('$page/normal.png').existsSync(), isTrue);
        final merged = <String, List<Map<String, dynamic>>>{};
        for (final variant in ['single_tank', 'sidemount']) {
          final raw = _json('$page/$variant/normal.json');
          expect(raw['base'], '../normal.json');
          expect(raw.containsKey('hud_skin'), isFalse);
          expect(File('$page/$variant/normal.png').existsSync(), isFalse);
          final layout = loadLayoutFile('$page/$variant/normal.json', _read);
          expect(layout[layoutBaseKey], '$page/normal.json');
          expect(
            (layout['hud_skin'] as Map<String, dynamic>)['path'],
            '../normal.png',
          );
          final elements = _elements(layout);
          expect(
            [
              for (final e in elements)
                if (e[elementOriginKey] == 'base') e,
            ],
            [
              for (final e in baseElements) {...e, elementOriginKey: 'base'},
            ],
          );
          merged[variant] = elements;
        }
        Set<Object?> block(String variant) => {
          for (final e in merged[variant]!)
            if (e[elementOriginKey] == 'variant') e['field'],
        };
        expect(block('single_tank'), {
          'primary_tank_name',
          'primary_tank_pressure',
        });
        expect(
          block('sidemount'),
          containsAll(['secondary_tank_name', 'secondary_tank_pressure']),
        );
      });
    }

    test('test_flat_state_files_load_unchanged', () {
      const path = '$_templates/garmin/x50i/gases/normal.json';
      expect(loadLayoutFile(path, _read), _json(path));
    });

    test('test_merge_applies_overrides_removals_and_adds_variant_elements', () {
      final merged = mergeVariantLayout(
        _tinyBase(),
        {
          'base': '../normal.json',
          'linked_elements': [
            {
              'id': 'tank',
              'field': 'primary_tank_pressure',
              'rel_x': 0.5,
              'rel_y': 0.5,
            },
          ],
          'overrides': {
            'depth': {'rel_x': 0.15},
          },
          'remove': ['ndl'],
        },
        '/tmp/page',
        '/tmp/page/sidemount',
      );
      final elements = _elements(merged);
      expect(
        [for (final e in elements) (e['id'], e[elementOriginKey])],
        [('depth', 'override'), ('tank', 'variant')],
      );
      expect(elements[0]['rel_x'], 0.15);
      expect(elements[0]['font_size'], 20);
      final skin = merged['hud_skin'] as Map<String, dynamic>;
      expect(skin['path'], '../normal.png');
      expect(skin['scale'], 0.5);
      expect(merged['manufacturer'], 'Garmin');
    });

    test('test_split_puts_shared_edits_in_the_base_and_variant_edits_in_the_'
        'overlay', () {
      final base = _tinyBase();
      final merged = mergeVariantLayout(
        base,
        {
          'base': '../normal.json',
          'linked_elements': [
            {
              'id': 'tank',
              'field': 'primary_tank_pressure',
              'rel_x': 0.5,
              'rel_y': 0.5,
            },
          ],
          'overrides': {
            'depth': {'rel_x': 0.15},
          },
        },
        '/tmp/page',
        '/tmp/page/sidemount',
      );
      final skin = merged['hud_skin'] as Map<String, dynamic>;
      final elements = skin['linked_elements'] as List<dynamic>;
      // ndl (shared) moved: to the base.
      (elements[1] as Map<String, dynamic>)['rel_y'] = 0.25;
      // depth (overridden) moved: the overrides gain rel_y, the base keeps
      // 0.1.
      (elements[0] as Map<String, dynamic>)['rel_y'] = 0.12;
      // tank (the variant's) moved: to the overlay.
      (elements[2] as Map<String, dynamic>)['rel_x'] = 0.55;
      // New while editing: to the overlay.
      elements.add(<String, dynamic>{
        'field': 'tts',
        'rel_x': 0.9,
        'rel_y': 0.9,
      });
      // The skin is shared: to the base.
      skin['scale'] = 0.6;
      final (newBase, newOverlay) = splitVariantLayout(merged, base);
      expect(newBase.containsKey(layoutBaseKey), isFalse);
      expect((newBase['hud_skin'] as Map<String, dynamic>)['scale'], 0.6);
      final newElements = _elements(newBase);
      expect([for (final e in newElements) e['id']], ['depth', 'ndl']);
      expect(newElements[0], _elements(base)[0]);
      expect(newElements[1]['rel_y'], 0.25);
      expect(newOverlay['overrides'], {
        'depth': {'rel_x': 0.15, 'rel_y': 0.12},
      });
      final own = [
        for (final e in newOverlay['linked_elements'] as List<dynamic>)
          e as Map<String, dynamic>,
      ];
      expect([for (final e in own) e['id'] ?? e['field']], ['tank', 'tts']);
      expect(own[0]['rel_x'], 0.55);
      expect(newOverlay.containsKey('remove'), isFalse);
      expect(own.every((e) => !e.containsKey(elementOriginKey)), isTrue);

      // ndl deleted while editing this variant.
      elements.removeAt(1);
      expect(splitVariantLayout(merged, base).$2['remove'], ['ndl']);
    });

    test(
      'test_a_variant_with_its_own_skin_keeps_it_through_merge_and_split',
      () {
        final base = _tinyBase();
        final merged = mergeVariantLayout(
          base,
          {
            'base': '../normal.json',
            'skin': 'normal.png',
            'linked_elements': <dynamic>[],
          },
          '/tmp/page',
          '/tmp/page/sidemount',
        );
        final skin = merged['hud_skin'] as Map<String, dynamic>;
        expect(skin['path'], 'normal.png');
        expect(merged[layoutVariantSkinKey], isTrue);
        expect(merged.containsKey('skin'), isFalse);
        expect(
          stripVariantMarkers(merged).containsKey(layoutVariantSkinKey),
          isFalse,
        );
        // Absolute, as the Designer saves it.
        skin['path'] = '/tmp/page/sidemount/normal.png';
        final (newBase, newOverlay) = splitVariantLayout(merged, base);
        expect(
          (newBase['hud_skin'] as Map<String, dynamic>)['path'],
          'normal.png',
        );
        expect(newBase.containsKey(layoutVariantSkinKey), isFalse);
        expect(newOverlay['skin'], 'normal.png');
        // A variant without one follows the base's image.
        final (_, plain) = splitVariantLayout(
          mergeVariantLayout(
            base,
            {'base': '../normal.json'},
            '/tmp/page',
            '/tmp/page/x',
          ),
          base,
        );
        expect(plain.containsKey('skin'), isFalse);
      },
    );

    for (final page in ['main', 'standard']) {
      test('test_perdix_3_sidemount_pages_use_a_skin_without_the_t1_slot'
          '[$page]', () {
        final dir = '$_templates/shearwater/perdix_3/$page';
        final single = loadLayoutFile('$dir/single_tank/normal.json', _read);
        final side = loadLayoutFile('$dir/sidemount/normal.json', _read);
        expect(
          (single['hud_skin'] as Map<String, dynamic>)['path'],
          '../normal.png',
        );
        expect(
          (side['hud_skin'] as Map<String, dynamic>)['path'],
          'normal.png',
        );
        expect(File('$dir/sidemount/normal.png').existsSync(), isTrue);
        expect(
          {for (final e in _elements(side)) e['field']},
          containsAll([
            'primary_tank_pressure',
            'secondary_tank_pressure',
            'custom:T1',
            'custom:T2',
            'max_depth',
          ]),
        );
      });
    }
  });
}
