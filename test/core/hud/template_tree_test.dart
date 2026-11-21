// Finding the templates against the Python app: the cases of its
// tests/test_layouts.py about the template tree, then the parity fixture
// made by tool/python_reference/templates_fixture.py (the bundled tree
// alone and with five user trees).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/hud/layouts.dart';
import 'package:uwmedia_app/core/hud/template_tree.dart';

import '../../helpers/python_reference.dart';

const _assets = 'assets/overlays/templates';

/// The overlays this app bundles that the Python app does not have (spec
/// §10.48: the simple overlays of user story U9.5).
const _ownTemplates = 'generic/simple/';

/// The bundled templates as the fixture names them: root "bundled".
/// [asPython] leaves out the app's own, for comparing with the Python
/// app's tree.
TemplateFolder bundledFolder({bool asPython = false}) {
  final files = [
    for (final file in Directory(
      _assets,
    ).listSync(recursive: true).whereType<File>())
      file.path.substring(_assets.length + 1).replaceAll(r'\', '/'),
  ].where((file) => !asPython || !file.startsWith(_ownTemplates)).toList();
  return ListedTemplateFolder(
    'bundled',
    files,
    (path) => File('$_assets/$path').readAsStringSync(),
  );
}

TemplateFolder userFolder(Map<String, String> files) =>
    ListedTemplateFolder('user', files.keys, (path) => files[path]);

String _manifest(
  List<Map<String, String>> pages, {
  String manufacturer = 'Shearwater',
  String model = 'Perdix 2',
}) =>
    jsonEncode({'manufacturer': manufacturer, 'model': model, 'pages': pages});

void main() {
  final bundled = bundledFolder();

  group('tests/test_layouts.py', () {
    final tree = TemplateTree(bundled: bundled);
    Map<String, Map<String, dynamic>> pagesOf(
      Map<String, dynamic> manifest,
    ) => {
      for (final page
          in (manifest['pages'] as List<dynamic>).cast<Map<String, dynamic>>())
        page['id'] as String: page,
    };

    test('test_list_templates_finds_bundled_shearwater_perdix_2', () {
      final perdix = tree.brands['shearwater']!['perdix_2']!;
      expect(perdix['manufacturer'], 'Shearwater');
      expect(perdix['model'], 'Perdix 2');
      final pages = pagesOf(perdix);
      expect(pages['main']!['name'], 'Main Screen');
      expect(pages['main']!['variants'], ['single_tank', 'sidemount']);
      expect(pages['tec']!['variants'], isEmpty);
    });

    test('test_list_templates_finds_bundled_generic_depth_temp', () {
      final depthTemp = tree.brands['generic']!['depth_temp']!;
      expect(depthTemp['manufacturer'], 'Generic');
      expect(pagesOf(depthTemp).keys.toSet(), {'standard', 'compact'});
    });

    test('test_list_templates_finds_bundled_generic_dive_profile', () {
      final profile = tree.brands['generic']!['dive_profile']!;
      expect(profile['manufacturer'], 'Generic');
      expect(pagesOf(profile).keys, ['main']);
      final state = tree.resolveState('generic', 'dive_profile', 'main');
      expect(state, 'bundled/generic/dive_profile/main/normal.json');
      expect(tree.readText(state!), contains('hud_skin'));
    });

    test('test_list_templates_finds_bundled_garmin_x50i', () {
      final x50i = tree.brands['garmin']!['x50i']!;
      expect(x50i['manufacturer'], 'Garmin');
      expect(x50i['model'], 'x50i');
      final pages = pagesOf(x50i);
      expect(pages['main']!['variants'], ['single_tank', 'sidemount']);
      expect(pages['gases']!['variants'], isEmpty);
    });

    test('test_resolve_template_state_returns_existing_path', () {
      final path = tree.resolveState(
        'shearwater',
        'perdix_2',
        'main',
        variant: 'single_tank',
      );
      expect(path, endsWith('/main/single_tank/normal.json'));
    });

    test('test_resolve_template_state_missing_combination_returns_none', () {
      expect(tree.resolveState('nonexistent_brand', 'x', 'y'), isNull);
      expect(
        tree.resolveState('shearwater', 'perdix_2', 'no_such_page'),
        isNull,
      );
      expect(
        tree.resolveState(
          'shearwater',
          'perdix_2',
          'main',
          variant: 'single_tank',
          state: 'deco',
        ),
        isNull,
      );
      // main has no state file directly under the page dir
      expect(tree.resolveState('shearwater', 'perdix_2', 'main'), isNull);
      expect(tree.resolveState('garmin', 'x50i', 'main'), isNull);
    });

    test('test_user_pages_are_added_beside_bundled_pages', () {
      final tec = bundled.readText('shearwater/perdix_2/tec/normal.json')!;
      final manifest = _manifest([
        {'id': 'my_main', 'name': 'My Main'},
        {'id': 'main', 'name': 'Clash'},
      ]);
      final warnings = <String>[];
      final tree = TemplateTree(
        bundled: bundled,
        user: userFolder({
          'shearwater/perdix_2/manifest.json': manifest,
          'shearwater/perdix_2/my_main/normal.json': tec,
          'shearwater/perdix_2/main/normal.json': tec,
        }),
        warn: warnings.add,
      );
      final perdix = tree.brands['shearwater']!['perdix_2']!;
      final pages = pagesOf(perdix);
      final bundledIds = [
        for (final page
            in (jsonDecode(
                  bundled.readText('shearwater/perdix_2/manifest.json')!,
                ) as Map<String, dynamic>)['pages']
                as List<dynamic>)
          (page as Map<String, dynamic>)['id'],
      ];
      // bundled first, user appended, no duplicate
      expect(pages.keys, [...bundledIds, 'my_main']);
      expect(pages['main']!['name'], 'Main Screen');
      expect(pages['main']!['origin'], 'bundled');
      expect(pages['my_main']!['origin'], 'user');
      expect(pages['my_main']!['path'], 'user/shearwater/perdix_2/my_main');
      expect(perdix['origin'], 'bundled');
      expect(perdix['user_path'], 'user/shearwater/perdix_2');
      expect(perdix['manufacturer'], 'Shearwater');
      expect(warnings.single, contains('collides with a bundled page'));

      expect(
        tree.resolveState('shearwater', 'perdix_2', 'my_main'),
        'user/shearwater/perdix_2/my_main/normal.json',
      );
      expect(
        tree.resolveState(
          'shearwater',
          'perdix_2',
          'main',
          variant: 'single_tank',
        ),
        startsWith('bundled/'),
      );
      expect(pageDisplayName(pages['my_main']!), 'My Main · yours');
      expect(pageDisplayName(pages['main']!), 'Main Screen');
    });

    test('test_user_only_computer_and_brand_are_added_whole', () {
      final tree = TemplateTree(
        bundled: bundled,
        user: userFolder({
          'custom/gopro/manifest.json': _manifest(
            [
              {'id': 'main', 'name': 'Main'},
            ],
            manufacturer: 'Custom',
            model: 'GoPro',
          ),
          'custom/gopro/main/normal.json': '{}',
        }),
      );
      final gopro = tree.brands['custom']!['gopro']!;
      expect(gopro['origin'], 'user');
      expect(pagesOf(gopro)['main']!['origin'], 'user');
      expect(gopro['user_path'], 'user/custom/gopro');
      // bundled brands unaffected
      final perdix = tree.brands['shearwater']!['perdix_2']!;
      expect(perdix['origin'], 'bundled');
      expect(perdix.containsKey('user_path'), isFalse);
    });

    test('test_list_templates_finds_bundled_generic_dive_profile_deco', () {
      final deco = tree.brands['generic']!['dive_profile_deco']!;
      expect(deco['manufacturer'], 'Generic');
      expect(deco['model'], 'Dive Profile Deco');
      expect(
        tree.resolveState('generic', 'dive_profile_deco', 'main'),
        isNotNull,
      );
    });

    test('every state file of the tree loads as a layout', () {
      var loaded = 0;
      tree.brands.forEach((brand, computers) {
        computers.forEach((computer, manifest) {
          for (final page in pagesOf(manifest).values) {
            final variants = page['variants'] as List<dynamic>;
            for (final variant in variants.isEmpty ? [null] : variants) {
              final path = tree.resolveState(
                brand,
                computer,
                page['id'] as String,
                variant: variant as String?,
              );
              expect(path, isNotNull, reason: '$brand/$computer/$page');
              final layout = loadLayoutFile(
                path!,
                (file) => tree.readText(file)!,
              );
              expect(layout['hud_skin'], isA<Map<String, dynamic>>());
              loaded++;
            }
          }
        });
      });
      // The Python app's 115 and the simple overlays of this app: two
      // boxes, and six pages for one tank and for a sidemount pair.
      expect(loaded, 115 + 2 + 6 * 2);
    });

    test('a manifest that is not one is passed over', () {
      final tree = TemplateTree(
        user: userFolder({
          'a/list/manifest.json': '[1, 2]',
          'a/no_id/manifest.json': '{"pages": [{"name": "x"}]}',
          'a/pages_text/manifest.json': '{"pages": "none"}',
          'a/fine/manifest.json': '{"pages": [{"id": "p"}]}',
        }),
      );
      expect(tree.brands['a']!.keys, ['fine']);
    });
  });

  group('parity with Python', () {
    final reference = pythonReference('templates/templates_cases.json');

    test('the trees and every state file asked for', () {
      final trees = jsonObjects(reference['trees']);
      expect(trees.length, 5);
      for (final c in trees) {
        final files = (c['user_files'] as Map<String, dynamic>)
            .cast<String, String>();
        final warnings = <String>[];
        final tree = TemplateTree(
          bundled: bundledFolder(asPython: true),
          user: userFolder(files),
          warn: warnings.add,
        );
        expect(tree.brands, c['templates'], reason: '${c['name']}');
        expect(tree.brands.keys, (c['templates'] as Map<String, dynamic>).keys);
        expect(warnings, c['warnings'], reason: '${c['name']}');
        final resolved = (c['resolved'] as List<dynamic>).cast<List<dynamic>>();
        expect(resolved.length, greaterThan(140));
        for (final [brand, computer, page, variant, state, want] in resolved) {
          expect(
            tree.resolveState(
              brand as String,
              computer as String,
              page as String,
              variant: variant as String?,
              state: state as String,
            ),
            want,
            reason: '${c['name']}: $brand/$computer/$page/$variant/$state',
          );
        }
      }
    });

    test('the legacy packages', () {
      final bundledFiles = [
        for (final name in reference['bundled_layouts'] as List<dynamic>)
          'bundled/$name',
      ];
      for (final c in jsonObjects(reference['layouts'])) {
        final userFiles = [
          for (final name in c['user_files'] as List<dynamic>)
            // list_layouts looks at the folder's own files only
            if (!(name as String).contains('/')) 'user/$name',
        ];
        expect([
          for (final (name, path) in listLayouts(bundledFiles, userFiles))
            [name, path],
        ], c['layouts']);
      }
    });
  });

  test('a file named with Windows\' separator is read (spec §10.86)', () {
    // A document on Windows names the page-level state its variants share
    // by `\`; the tree's paths have `/`.
    final asked = <String>[];
    final tree = TemplateTree(
      user: _AskedFolder(r'C:\Users\d\templates', asked),
    );
    expect(tree.readText(r'C:\Users\d\templates\b\c\main\normal.json'), 'text');
    expect(tree.readText(r'C:\Users\d\templates/b/c/main/normal.json'), 'text');
    expect(asked, [r'b\c\main\normal.json', 'b/c/main/normal.json']);
    expect(tree.readText(r'C:\Users\d\templatesX\a.json'), isNull);
    expect(tree.readText(r'D:\other\a.json'), isNull);
  });
}

/// An empty folder that answers every read with "text" and remembers the
/// paths asked for.
class _AskedFolder implements TemplateFolder {
  _AskedFolder(this.root, this.asked);

  @override
  final String root;
  final List<String> asked;

  @override
  List<String> folders(String path) => [];

  @override
  bool isFile(String path) => false;

  @override
  String? readText(String path) {
    asked.add(path);
    return 'text';
  }
}
