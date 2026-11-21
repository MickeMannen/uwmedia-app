// The Overlay Designer's document against the Python app: cases of its
// tests/test_overlay_document.py, then the parity fixture made by
// tool/python_reference/document_fixture.py (every bundled layout file as
// a document, and 72 edits, undos and redos on six of them, the whole
// state compared after each).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/hud/image_size.dart';
import 'package:uwmedia_app/core/hud/overlay_document.dart';
import 'package:uwmedia_app/core/util/json_tree.dart';

import '../../helpers/python_reference.dart';
import '../../helpers/renderer_reference.dart';

const _root = 'assets/overlays/templates';

// As the Python app has the templates (spec §10.83), which the fixture
// was made from.
String _read(String path) => asPythonText(path, File(path).readAsStringSync());

(int, int)? _sizeOf(String path) {
  final file = File(path);
  return file.existsSync() ? imageSize(file.readAsBytesSync()) : null;
}

OverlayDocument _load(String path, [TemplateRef? ref]) =>
    OverlayDocument.load(path, _read, ref: ref, imageSize: _sizeOf);

// With forward slashes on Windows too, so that it is found again in the
// JSON text.
final _absoluteRoot = Directory(_root).absolute.path.replaceAll(r'\', '/');

/// [value] as the fixture has it: JSON, the templates folder as ROOT.
Object? _plain(Object? value) => jsonDecode(
  jsonEncode(value).replaceAll(_absoluteRoot, 'ROOT').replaceAll(_root, 'ROOT'),
);

String _here(Object? path) => (path! as String).replaceFirst('ROOT', _root);

List<double> _pair((double, double) v) => [v.$1, v.$2];
List<double> _box((double, double, double, double) v) => [
  v.$1,
  v.$2,
  v.$3,
  v.$4,
];

/// What the fixture records of a document after every step.
Map<String, Object?> facts(OverlayDocument doc) =>
    _plain({
          'layout': doc.toLayout(),
          'dirty': doc.dirty,
          'can_undo': doc.canUndo,
          'can_redo': doc.canRedo,
          'skin_abs_path': doc.skinAbsPath,
          'native': [doc.nativeWidth, doc.nativeHeight],
          'skin_type': doc.skinType,
          'native_size': _pair(doc.skinNativeSize()),
          'scaled_size': _pair(doc.skinScaledSize()),
          'position_px': [
            for (final i in [0, 1, 99]) _pair(doc.elementPositionPx(i)),
          ],
          'frame_box': [
            for (final (w, h) in [
              (1920, 1080),
              (3840, 2160),
              (1280, 720),
              (1080, 1920),
            ])
              _box(doc.frameBox(w, h)),
          ],
        })!
        as Map<String, Object?>;

/// One step of the fixture on [doc]; gives what Python's method returned.
Object? apply(OverlayDocument doc, List<dynamic> step) {
  final [op as String, args as List<dynamic>, kwargs as Map<String, dynamic>] =
      step;
  final undo = kwargs['record_undo'] as bool? ?? true;
  switch (op) {
    case 'add_element':
      return doc.addElement(
        args[0] as String,
        kind: args.length > 1 ? args[1] as String : 'text',
        relX: args.length > 2 ? args[2] as num : 0.5,
        relY: args.length > 3 ? args[3] as num : 0.5,
        attrs: jsonCopyMap(kwargs),
      );
    case 'move_element':
      doc.moveElement(
        args[0] as int,
        args[1] as num,
        args[2] as num,
        recordUndo: undo,
      );
    case 'set_element_position_px':
      doc.setElementPositionPx(
        args[0] as int,
        args[1] as num,
        args[2] as num,
        recordUndo: undo,
      );
    case 'nudge_element':
      doc.nudgeElement(args[0] as int, args[1] as num, args[2] as num);
    case 'set_element_attr':
      doc.setElementAttr(args[0] as int, args[1] as String, args[2]);
    case 'duplicate_element':
      return doc.duplicateElement(args[0] as int);
    case 'reorder_element':
      return doc.reorderElement(args[0] as int, args[1] as int);
    case 'remove_element':
      return doc.removeElement(args[0] as int);
    case 'set_skin_attr':
      doc.setSkinAttr(args[0] as String, args[1]);
    case 'set_frame_position':
      doc.setFramePosition(
        args[0] as num,
        args[1] as num,
        args[2] as num,
        args[3] as num,
        recordUndo: undo,
      );
    case 'undo':
      return doc.undo();
    case 'redo':
      return doc.redo();
    case 'mark_saved':
      doc.markSaved();
    case 'set_skin_image':
      // A picked file comes with its whole path, as in Python.
      return doc.setSkinImage(
        (args[0] as String).replaceFirst('ROOT', _absoluteRoot),
      );
    default:
      fail('unknown step $op');
  }
  return null;
}

void main() {
  final reference = jsonDecode(
    utf8.decode(
      gzip.decode(
        File(
          'test/fixtures/python_reference/hud_designer/'
          'document_cases.json.gz',
        ).readAsBytesSync(),
      ),
    ),
  ) as Map<String, dynamic>;

  group('tests/test_overlay_document.py', () {
    test('test_image_skin_native_size_and_absolute_path', () {
      final doc = _load('$_root/shearwater/perdix_2/tec/normal.json');
      expect(doc.skinType, 'image');
      expect(doc.skinAbsPath, '$_root/shearwater/perdix_2/tec/normal.png');
      expect(doc.nativeWidth, greaterThan(0));
      final (w, h) = doc.skinNativeSize();
      expect((w, h), (doc.nativeWidth.toDouble(), doc.nativeHeight.toDouble()));
      final scale = (doc.skin['scale'] as num).toDouble();
      expect(doc.skinScaledSize(), (w * scale, h * scale));
      // the path in the layout stays relative
      expect(doc.layout['hud_skin'], containsPair('path', 'normal.png'));
      expect(
        (doc.renderLayout()['hud_skin'] as Map<String, dynamic>)['path'],
        doc.skinAbsPath,
      );
    });

    test('test_shape_skin_sizes', () {
      final doc = _load('$_root/generic/depth_temp/standard/normal.json');
      expect(doc.skinType, 'shape');
      expect(doc.skinAbsPath, isNull);
      expect(doc.skinNativeSize(), doc.skinScaledSize());
    });

    test('test_missing_skin_file_does_not_crash', () {
      final doc = OverlayDocument({
        'hud_skin': {'type': 'image', 'path': 'nowhere.png'},
      }, imageSize: _sizeOf);
      expect((doc.nativeWidth, doc.nativeHeight), (0, 0));
      expect(doc.skinNativeSize(), (0.0, 0.0));
    });

    test('test_to_layout_for_save_normalises_path_and_rounds', () {
      final doc = OverlayDocument({
        'hud_skin': {
          'type': 'image',
          'path': '/abs/dir/skin.png',
          'linked_elements': [
            {'field': 'depth', 'rel_x': 0.123456789, 'rel_y': 0.5},
          ],
        },
      });
      final saved = doc.toLayout(forSave: true)['hud_skin'] as Map;
      expect(saved['path'], 'skin.png');
      expect(((saved['linked_elements'] as List)[0] as Map)['rel_x'], 0.12346);
      // a copy, not in place
      expect(doc.skin['path'], '/abs/dir/skin.png');
    });

    test('test_dirty_undo_redo', () {
      final doc = _load('$_root/generic/depth_temp/standard/normal.json');
      final original = jsonCopyMap(doc.layout);
      expect(doc.dirty || doc.canUndo || doc.canRedo, isFalse);

      doc.pushUndo();
      doc.elements[0]['rel_x'] = 0.9;
      expect(doc.dirty && doc.canUndo, isTrue);

      expect(doc.undo(), isTrue);
      expect(doc.layout, original);
      expect(doc.dirty, isFalse);
      expect(doc.canRedo, isTrue);

      expect(doc.redo(), isTrue);
      expect(doc.elements[0]['rel_x'], 0.9);
      expect(doc.dirty, isTrue);

      doc.markSaved();
      expect(doc.dirty, isFalse);
      // undoing past the save point is dirty again
      expect(doc.undo(), isTrue);
      expect(doc.dirty, isTrue);
      expect(doc.undo(), isFalse); // stack exhausted
    });

    test('test_undo_stack_is_capped', () {
      final doc = OverlayDocument({
        'hud_skin': {'type': 'shape', 'linked_elements': <dynamic>[]},
      });
      for (var i = 0; i < undoLimit + 10; i++) {
        doc.pushUndo();
        doc.layout['counter'] = i;
      }
      var steps = 0;
      while (doc.undo()) {
        steps++;
      }
      expect(steps, undoLimit);
      // the oldest ten states are gone
      expect(doc.layout['counter'], 9);
    });

    test('a layout without a skin gets one, and is dirty for it', () {
      // As in Python: the snapshot is taken before the skin is looked at.
      final doc = OverlayDocument({});
      expect(doc.layout, {'hud_skin': <String, dynamic>{}});
      expect(doc.dirty, isTrue);
      expect(doc.elements, isEmpty);
      expect(doc.addElement('depth'), 0);
      expect((doc.skin['linked_elements'] as List).length, 1);
    });
  });

  group('image sizes', () {
    test('the PNG skins and the photo fixture', () {
      expect(_sizeOf('$_root/garmin/x50i/gases/normal.png'), (946, 602));
      final (w, h) = _sizeOf('test/fixtures/media/photo/jpeg_3x2_2mp.jpg')!;
      expect(w / h, closeTo(1.5, 0.01));
      expect(w * h, closeTo(2e6, 2e5));
    });

    test('what is not an image, or is cut off', () {
      final png = File('$_root/garmin/x50i/gases/normal.png').readAsBytesSync();
      expect(imageSize(Uint8List.sublistView(png, 0, 23)), isNull);
      expect(imageSize(Uint8List.sublistView(png, 0, 24)), (946, 602));
      expect(imageSize(Uint8List(0)), isNull);
      expect(imageSize(Uint8List.fromList(utf8.encode('{"a": 1}'))), isNull);
      expect(imageSize(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9])), isNull);
    });
  });

  group('parity with Python', () {
    test('the constants and the labels', () {
      expect(undoLimit, reference['undo_limit']);
      expect(relDecimals, reference['rel_decimals']);
      expect(relMin, reference['rel_min']);
      expect(relMax, reference['rel_max']);
      for (final [args as List<dynamic>, label]
          in (reference['labels'] as List<dynamic>).cast<List<dynamic>>()) {
        expect(
          TemplateRef(
            args[0] as String,
            args[1] as String,
            args[2] as String,
            args.length > 3 ? args[3] as String? : null,
          ).label,
          label,
        );
      }
    });

    test('every bundled layout file as a document', () {
      final cases = jsonObjects(reference['static']);
      expect(cases.length, 131);
      for (final c in cases) {
        final path = _here(c['path']);
        final doc = _load(path);
        final got = {
          'path': c['path'],
          ...facts(doc),
          ...(_plain({
                'variant_base_path': doc.variantBasePath,
                'manufacturer': doc.manufacturer,
                'model': doc.model,
                'rules_manufacturer': doc.rulesManufacturer,
                'design_size': [doc.designSize.$1, doc.designSize.$2],
                'render_layout': doc.renderLayout(),
                'design_view': [
                  for (final zoom in [1.0, 0.5, 2.25])
                    doc.designViewLayout(zoom),
                ],
                'for_save': doc.toLayout(forSave: true),
              })!
              as Map<String, dynamic>),
        };
        for (final key in c.keys) {
          expect(got[key], c[key], reason: '$key of $path');
        }
        expect(got.keys.toSet(), c.keys.toSet());
      }
    });

    test('edits, undo and redo, the whole state after every step', () {
      final cases = jsonObjects(reference['edits']);
      expect(cases.length, 6);
      for (final c in cases) {
        final path = _here(c['path']);
        expect(facts(_load(path)), c['start'], reason: path);
        final doc = _load(path, const TemplateRef('b', 'c', 'p'));
        for (final (i, step) in jsonObjects(c['steps']).indexed) {
          final op = step['op'] as List<dynamic>;
          final reason = '$path, step $i: $op';
          expect(apply(doc, op), step['result'], reason: reason);
          final got = {
            ...facts(doc),
            'for_save': _plain(doc.toLayout(forSave: true)),
          };
          for (final key in got.keys) {
            expect(got[key], step[key], reason: '$key after $reason');
          }
        }
      }
    });
  });
}
