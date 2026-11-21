// The Tank Sensor Names window's sizes (spec §10.54): typed in litres,
// checked, and saved into config.yaml with the names.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/pages/shared/tank_names.dart';

void main() {
  late Directory tmp;
  late ConfigStore config;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tank_names');
    config = ConfigStore(() => Directory(p.join(tmp.path, 'config')));
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('a size typed in is saved; a wrong one stops Save', () {
    final editor = TankNamesEditor(config: config, home: tmp.path)..open();
    editor
      ..addSerial('111')
      ..addSerial('222')
      ..addSerial('333');
    editor.setSize('111', '11,1');
    expect(editor.sizeOf('111'), 11.1);
    editor.setSize('222', 'big');
    expect(editor.badSize('222'), isTrue);
    expect(editor.canSave, isFalse);
    editor.setSize('222', '');
    expect(editor.canSave, isTrue);
    editor.setSize('333', '12');
    editor.remove('333');
    expect(editor.save(), isNotNull);

    final again = TankNamesEditor(config: config, home: tmp.path)..open();
    expect(again.sizeOf('111'), 11.1);
    expect(again.sizeOf('222'), isNull);
    expect(config.tankConfig().tanks.sizes, {'111': 11.1});
    expect(config.tankConfig().tanks.tanks.keys, ['111', '222']);
  });
}
