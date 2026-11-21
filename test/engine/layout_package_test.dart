// The older .zip HUD packages (lib/engine/layout_package.dart) as the
// Python app's CLI reads them: hud_layout.json with its skin beside it, a
// variant layout's base inside the package too, and Python's messages for
// a package that is missing, has no layout or is no zip.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/engine/desktop/overlay_batch.dart';
import 'package:uwmedia_app/engine/layout_package.dart';

const _templates = 'assets/overlays/templates/shearwater/tern/main';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('uwmedia_package_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String zip(String name, Map<String, List<int>> files) {
    final archive = Archive();
    files.forEach((path, bytes) {
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    });
    return (File(
      p.join(tmp.path, name),
    )..writeAsBytesSync(ZipEncoder().encode(archive))).path;
  }

  final skin = File('$_templates/normal.png').readAsBytesSync();
  Map<String, dynamic> layout() =>
      jsonDecode(File('$_templates/normal.json').readAsStringSync())
          as Map<String, dynamic>;

  test('the layout and its skin from inside the package', () {
    final data = layout();
    (data['hud_skin'] as Map<String, dynamic>)['path'] = 'images/tern.png';
    final path = zip('Tern.zip', {
      'hud_layout.json': utf8.encode(jsonEncode(data)),
      'images/tern.png': skin,
    });
    for (final source in [layerOfPackage(path), OverlayBatch.layerOf(path)]) {
      expect(source.layout, data);
      expect(source.skinBytes, skin);
    }
  });

  test('a variant layout finds its base in the package', () {
    final base = layout();
    (base['hud_skin'] as Map<String, dynamic>)['path'] = 'normal.png';
    final path = zip('Variant.zip', {
      'base/normal.json': utf8.encode(jsonEncode(base)),
      // Beside the base, which names it.
      'base/normal.png': skin,
      'hud_layout.json': utf8.encode(jsonEncode({'base': 'base/normal.json'})),
    });
    final source = layerOfPackage(path);
    List<Object?> fields(Map<String, dynamic> layout) => [
      for (final e in ((layout['hud_skin'] as Map)['linked_elements'] as List))
        (e as Map)['field'],
    ];
    expect(fields(source.layout), fields(base));
    expect(source.skinBytes, skin);
  });

  test("Python's messages", () {
    expect(
      () => layerOfPackage(p.join(tmp.path, 'gone.zip')),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'HUD package ${p.join(tmp.path, 'gone.zip')} not found.',
        ),
      ),
    );
    final empty = zip('empty.zip', {'readme.txt': utf8.encode('hi')});
    expect(
      () => layerOfPackage(empty),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'HUD package missing hud_layout.json',
        ),
      ),
    );
    final notZip = (File(
      p.join(tmp.path, 'text.zip'),
    )..writeAsStringSync('no zip at all')).path;
    expect(
      () => layerOfPackage(notZip),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          startsWith('Could not read HUD package text.zip: '),
        ),
      ),
    );
    expect(isLayoutPackage('/a/B.ZIP'), isTrue);
    expect(isLayoutPackage('/a/b.json'), isFalse);
  });
}
