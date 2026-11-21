// Writing a template save (lib/engine/template_files.dart) into a
// temporary folder: the text files in one step with no temporary file
// left, a skin copied as it is or converted to PNG, and a skin that cannot
// be read.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/hud/image_size.dart';
import 'package:uwmedia_app/core/hud/template_store.dart';
import 'package:uwmedia_app/engine/template_files.dart';

const _skin = 'assets/overlays/templates/shearwater/tern/main/normal.png';

Future<Uint8List> _redPng() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const ui.Rect.fromLTWH(0, 0, 3, 2),
    ui.Paint()..color = const ui.Color(0xFFFF0000),
  );
  final image = await recorder.endRecording().toImage(3, 2);
  final raw = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  return raw.buffer.asUint8List();
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('uwmedia_save_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<Uint8List?> read(String path) async {
    final file = File(path);
    return file.existsSync() ? file.readAsBytesSync() : null;
  }

  testWidgets('texts and a copied skin, nothing left over', (tester) async {
    final state = p.join(tmp.path, 'b', 'c', 'page', 'normal.json');
    final skin = p.join(tmp.path, 'b', 'c', 'page', 'normal.png');
    final manifest = p.join(tmp.path, 'b', 'c', 'manifest.json');
    File(manifest)
      ..createSync(recursive: true)
      ..writeAsStringSync('old');
    await tester.runAsync(
      () => carryOutTemplateSave((
        statePath: state,
        ops: [
          CopySkinOp(_skin, skin, convert: false),
          WriteTextOp(state, '{"a": 1}'),
          WriteTextOp(manifest, 'new'),
        ],
      ), readBytes: read),
    );
    expect(File(state).readAsStringSync(), '{"a": 1}');
    expect(File(manifest).readAsStringSync(), 'new');
    expect(File(skin).readAsBytesSync(), File(_skin).readAsBytesSync());
    expect(
      tmp.listSync(recursive: true).where((f) => f.path.endsWith('.new')),
      isEmpty,
    );
  });

  testWidgets('a skin re-encoded as PNG', (tester) async {
    final source = p.join(tmp.path, 'in.img');
    final skin = p.join(tmp.path, 'out', 'normal.png');
    await tester.runAsync(() async {
      File(source).writeAsBytesSync(await _redPng());
      await carryOutTemplateSave((
        statePath: '',
        ops: [CopySkinOp(source, skin, convert: true)],
      ), readBytes: read);
    });
    final bytes = File(skin).readAsBytesSync();
    expect(bytes.sublist(1, 4), 'PNG'.codeUnits);
    expect(imageSize(bytes), (3, 2));
  });

  testWidgets('a skin that cannot be read', (tester) async {
    final state = p.join(tmp.path, 'page', 'normal.json');
    Object? error;
    await tester.runAsync(() async {
      try {
        await carryOutTemplateSave((
          statePath: state,
          ops: [
            CopySkinOp(p.join(tmp.path, 'gone.png'), 'x.png', convert: false),
            WriteTextOp(state, '{}'),
          ],
        ), readBytes: read);
      } on Object catch (e) {
        error = e;
      }
    });
    expect(error, isA<TemplateStoreError>());
    // The state is not written when its skin is missing.
    expect(File(state).existsSync(), isFalse);
  });
}
