// Saving overlay templates against the Python app: the parity fixture made
// by tool/python_reference/store_fixture.py replays 46 calls of
// save_template, save_template_as and create_computer in nine scenarios
// (the user's folder and the Python app's own mode of saving into the
// bundled tree), each with the folders as Python had them before the call;
// and cases of its tests/test_template_store.py.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/hud/overlay_document.dart';
import 'package:uwmedia_app/core/hud/template_store.dart';
import 'package:uwmedia_app/core/hud/template_tree.dart';

import '../../helpers/python_reference.dart';

const _assets = 'assets/overlays/templates';

final List<String> _assetFiles = [
  for (final file in Directory(
    _assets,
  ).listSync(recursive: true).whereType<File>())
    file.path.substring(_assets.length + 1).replaceAll(r'\', '/'),
];

/// The bundled tree as the fixture names it, with what earlier calls of a
/// scenario changed in Python's copy: a text for a changed or new JSON
/// file, `true` for another new or changed file, `null` for one gone.
TemplateFolder bundledFolder([Map<String, dynamic> changes = const {}]) {
  final relative = {
    for (final MapEntry(:key, :value) in changes.entries)
      key.substring('bundled/'.length): value,
  };
  return ListedTemplateFolder(
    'bundled',
    {
      ..._assetFiles.where((file) => !relative.containsKey(file)),
      for (final MapEntry(:key, :value) in relative.entries)
        if (value != null) key,
    },
    (path) => relative[path] is String
        ? relative[path] as String
        : File('$_assets/$path').readAsStringSync(),
  );
}

TemplateFolder userFolder(Map<String, dynamic> files) => ListedTemplateFolder(
  'user',
  files.keys.map((path) => path.substring('user/'.length)),
  (path) => files['user/$path'] as String?,
);

TemplateRef refOf(Map<String, dynamic> json) => TemplateRef(
  json['brand'] as String,
  json['computer'] as String,
  json['page'] as String,
  json['variant'] as String?,
);

void main() {
  final reference = jsonDecode(
    utf8.decode(
      gzip.decode(
        File(
          'test/fixtures/python_reference/hud_designer/'
          'store_cases.json.gz',
        ).readAsBytesSync(),
      ),
    ),
  ) as Map<String, dynamic>;

  group('tests/test_template_store.py', () {
    test('test_slugify', () {
      expect(slugify('My Camera HUD'), 'my_camera_hud');
      expect(slugify('  Perdix 2  '), 'perdix_2');
      expect(slugify(null), '');
    });

    test('test_bundled_pages_are_read_only_in_release_mode', () {
      final store = TemplateStore(
        bundled: bundledFolder(),
        user: userFolder({}),
      );
      expect(store.templateOrigin('shearwater', 'perdix_2', 'main'), 'bundled');
      expect(store.templateOrigin('shearwater', 'perdix_2', 'nope'), 'missing');
      expect(store.canSaveInPlace('shearwater', 'perdix_2', 'main'), isFalse);
      expect(store.isDevMode, isFalse);
      expect(store.writeRoot, 'user');
      expect(
        () => store.saveTemplate(
          const TemplateRef('shearwater', 'perdix_2', 'tec'),
          {},
        ),
        throwsA(isA<ReadOnlyTemplateError>()),
      );
    });

    test('test_save_as_shape_skin_writes_no_png', () {
      final store = TemplateStore(
        bundled: bundledFolder(),
        user: userFolder({}),
      );
      final save = store.saveTemplateAs(
        {
          'hud_skin': {
            'type': 'shape',
            'path': 'left over.png',
            'linked_elements': [
              {'field': 'depth', 'rel_x': 0.123456789, 'rel_y': 1},
            ],
          },
        },
        const TemplateRef('custom', 'shapes', 'mine'),
        'Mine',
      );
      expect(save.statePath, 'user/custom/shapes/mine/normal.json');
      expect(save.ops.whereType<CopySkinOp>(), isEmpty);
      final written = {
        for (final op in save.ops.whereType<WriteTextOp>()) op.path: op.text,
      };
      expect(written.keys, [
        'user/custom/shapes/manifest.json',
        'user/custom/shapes/mine/normal.json',
      ]);
      expect(jsonDecode(written['user/custom/shapes/manifest.json']!), {
        'manufacturer': 'Custom',
        'model': 'Shapes',
        'pages': [
          {'id': 'mine', 'name': 'Mine'},
        ],
      });
      expect(
        written['user/custom/shapes/mine/normal.json'],
        '{\n'
        '  "hud_skin": {\n'
        '    "type": "shape",\n'
        '    "linked_elements": [\n'
        '      {\n'
        '        "field": "depth",\n'
        '        "rel_x": 0.12346,\n'
        '        "rel_y": 1\n'
        '      }\n'
        '    ]\n'
        '  }\n'
        '}\n',
      );
    });

    test('a picked image that is not a PNG is converted', () {
      final store = TemplateStore(
        bundled: bundledFolder(),
        user: userFolder({}),
        fileExists: (path) => path == '/photos/skin.JPG',
      );
      final save = store.saveTemplateAs(
        {
          'hud_skin': {'type': 'image', 'path': '/photos/skin.JPG'},
        },
        const TemplateRef('custom', 'cam', 'main'),
        'Main',
      );
      final copy = save.ops.whereType<CopySkinOp>().single;
      expect(
        (copy.source, copy.path, copy.convert),
        ('/photos/skin.JPG', 'user/custom/cam/main/normal.png', true),
      );
    });

    test('displayRoot', () {
      expect(
        displayRoot('/Users/me/Library/templates', '/Users/me'),
        '~/Library/templates',
      );
      expect(
        displayRoot('/Volumes/x/templates', '/Users/me'),
        '/Volumes/x/templates',
      );
      expect(displayRoot('/Users/me', null), '/Users/me');
    });

    test('the text of a template file', () {
      expect(templateJsonText({}), '{}\n');
      expect(
        templateJsonText({
          'a': <dynamic>[],
          'b': <String, dynamic>{},
          'c': [1, 1.0, 0.00001, 1e16, true, null, 'é "x"\n'],
        }),
        '{\n'
        '  "a": [],\n'
        '  "b": {},\n'
        '  "c": [\n'
        '    1,\n'
        '    1.0,\n'
        '    1e-05,\n'
        '    1e+16,\n'
        '    true,\n'
        '    null,\n'
        '    "é \\"x\\"\\n"\n'
        '  ]\n'
        '}\n',
      );
    });
  });

  group('parity with Python', () {
    test('the constants and slugify', () {
      expect({
        'skin': skinFilename,
        'state': stateFilename,
        'manifest': manifestFilename,
        'custom_brand': customBrand,
        'custom_manufacturer': customManufacturer,
      }, reference['constants']);
      for (final [name, slug]
          in (reference['slugs'] as List<dynamic>).cast<List<dynamic>>()) {
        expect(slugify(name as String?), slug, reason: '$name');
      }
    });

    test('every call: what is written, copied or refused', () {
      var calls = 0;
      var refusedAfterWriting = 0;
      for (final scenario in jsonObjects(reference['scenarios'])) {
        final target = scenario['mode'] == 'repo'
            ? TemplateTarget.repo
            : TemplateTarget.user;
        for (final (i, call) in jsonObjects(scenario['calls']).indexed) {
          calls++;
          final reason = '${scenario['name']}, call $i (${call['function']})';
          final userBefore = call['user_before'] as Map<String, dynamic>;
          final changes = call['bundled_changes'] as Map<String, dynamic>;
          final outside = (call['outside'] as List<dynamic>).toSet();
          final bundled = bundledFolder(changes);
          final store = TemplateStore(
            bundled: bundled,
            user: userFolder(userBefore),
            target: target,
            fileExists: outside.contains,
          );
          final args = call['args'] as List<dynamic>;
          final kwargs = call['kwargs'] as Map<String, dynamic>;

          TemplateSave run() => switch (call['function']) {
            'save_template' => store.saveTemplate(
              refOf(args[0] as Map<String, dynamic>),
              args[1] as Map<String, dynamic>,
              skinSource: args.length > 2 ? args[2] as String? : null,
            ),
            'save_template_as' => store.saveTemplateAs(
              args[0] as Map<String, dynamic>,
              refOf(args[1] as Map<String, dynamic>),
              args[2] as String,
              skinSource: args.length > 3 ? args[3] as String? : null,
              manufacturer: kwargs['manufacturer'] as String?,
              model: kwargs['model'] as String?,
              rulesProfile: kwargs['rules_profile'] as String?,
              overwriteUser: kwargs['overwrite_user'] as bool? ?? true,
            ),
            'create_computer' => store.createComputer(
              args[0] as String,
              args[1] as String,
              args[2] as String,
              args[3] as String,
              rulesProfile: args.length > 4 ? args[4] as String? : null,
            ),
            final other => fail('unknown function $other'),
          };

          final result = call['result'] as List<dynamic>;
          final written = call['written'] as Map<String, dynamic>;
          if (result[0] == 'raise') {
            final Object error;
            try {
              run();
              fail('Python refuses, the port does not: $reason');
            } on TemplateStoreError catch (e) {
              error = e;
            }
            expect(
              (error.runtimeType.toString(), '$error'),
              (result[1], result[2]),
              reason: reason,
            );
            // Python has sometimes written the manifest before it refuses;
            // the port gives nothing to write then.
            if (written.isNotEmpty) {
              refusedAfterWriting++;
              expect(written.keys.single, endsWith('/manifest.json'));
            }
            continue;
          }

          final save = run();
          expect(save.statePath, result[1], reason: reason);
          // What was there before, to tell a rewrite of the same content.
          String? before(String path) => path.startsWith('user/')
              ? userBefore[path] as String?
              : bundled.readText(path.substring('bundled/'.length));
          final texts = {
            for (final op in save.ops.whereType<WriteTextOp>())
              op.path: op.text,
          };
          written.forEach((path, text) {
            expect(texts[path], text, reason: '$path, $reason');
          });
          for (final MapEntry(:key, :value) in texts.entries) {
            if (!written.containsKey(key)) {
              // Python's file did not change: the port writes the same.
              expect(value, before(key), reason: 'rewrite of $key, $reason');
            }
          }

          final skins = call['skins'] as Map<String, dynamic>;
          final copies = {
            for (final op in save.ops.whereType<CopySkinOp>()) op.path: op,
          };
          skins.forEach((dest, how) {
            final op = copies[dest];
            expect(op, isNotNull, reason: 'skin $dest, $reason');
            final [kind, ...] = how as List<dynamic>;
            expect(op!.convert, kind == 'convert', reason: '$dest, $reason');
            if (kind == 'copy') {
              // Python's copy is named by its bytes; several pages share
              // one image.
              String asset(String path) =>
                  path.replaceFirst('bundled', _assets);
              if (op.source.startsWith('user/')) {
                // The user's own image, which the fixture does not carry.
                expect(userBefore, contains(op.source), reason: reason);
              } else {
                expect(
                  File(asset(op.source)).readAsBytesSync(),
                  File(asset(how[1] as String)).readAsBytesSync(),
                  reason: 'skin $dest from ${op.source}, $reason',
                );
              }
            } else {
              expect(outside, contains(op.source));
            }
          });
          for (final dest in copies.keys) {
            if (!skins.containsKey(dest)) {
              // The same image was there already.
              expect(
                userBefore.containsKey(dest) ||
                    bundled.isFile(dest.substring('bundled/'.length)),
                isTrue,
                reason: 'copy over $dest, $reason',
              );
            }
          }
        }

        // The questions asked of the scenario's last state.
        final queries = (scenario['queries'] as List<dynamic>)
            .cast<List<dynamic>>();
        if (queries.isNotEmpty) {
          final last = jsonObjects(scenario['calls']).last;
          expect(queries.length % 5, 0);
          // Only the last five are about the state after the last call
          // that wrote nothing more; replay it from the call's own record.
          final after = {
            ...last['user_before'] as Map<String, dynamic>,
            ...last['written'] as Map<String, dynamic>,
          };
          final store = TemplateStore(
            bundled: bundledFolder({
              ...last['bundled_changes'] as Map<String, dynamic>,
              for (final MapEntry(:key, :value) in after.entries)
                if (key.startsWith('bundled/')) key: value,
            }),
            user: userFolder({
              for (final MapEntry(:key, :value) in after.entries)
                if (key.startsWith('user/')) key: value,
            }),
            target: target,
          );
          for (final [ref as List<dynamic>, origin, canSave] in queries.sublist(
            queries.length - 5,
          )) {
            final [brand as String, computer as String, page as String] = ref;
            expect(
              store.templateOrigin(brand, computer, page),
              origin,
              reason: '${scenario['name']} $ref',
            );
            expect(
              store.canSaveInPlace(brand, computer, page),
              canSave,
              reason: '${scenario['name']} $ref',
            );
          }
        }
      }
      expect(calls, 46);
      expect(refusedAfterWriting, 2);
    });
  });
}
