// The Tank Sensor Names window's editor (spec §10.54, §10.104): the
// sensors of the kept logs, the names, the sides and the sizes (litres, or
// cubic feet at a rated pressure), saved into config.yaml.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/config/config_store.dart';
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/parsers/fit_reader.dart';
import 'package:uwmedia_app/core/parsers/garmin.dart';
import 'package:uwmedia_app/core/units/units.dart';
import 'package:uwmedia_app/pages/shared/tank_names.dart';

final Map<String, dynamic> _sources =
    (jsonDecode(
          utf8.decode(
            gzip.decode(
              File(
                'test/fixtures/python_reference/dives/'
                'fit_edit_cases.json.gz',
              ).readAsBytesSync(),
            ),
          ),
        ) as Map<String, dynamic>)['sources']
        as Map<String, dynamic>;

void main() {
  late Directory tmp;
  late ConfigStore config;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tank_names');
    config = ConfigStore(() => Directory(p.join(tmp.path, 'config')));
    config.saveConfigYaml(
      'tanks:\n  "111": Tank 111\n  "222": Tank 222\n  "333": Tank 333\n',
    );
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('a size typed in is saved; a wrong one stops Save', () {
    final editor = TankNamesEditor(config: config)..open();
    editor.setSize('111', '11,1');
    expect(editor.sizeOf('111'), 11.1);
    expect(editor.sizeText('111', UnitSystem.metric), '11.1');
    editor.setSize('222', 'big');
    expect(editor.badSize('222'), isTrue);
    expect(editor.canSave, isFalse);
    editor.setSize('222', '');
    expect(editor.canSave, isTrue);
    editor.setSize('999', '12');
    expect(editor.save(), isNotNull);

    final again = TankNamesEditor(config: config)..open();
    expect(again.sizeOf('111'), 11.1);
    expect(again.sizeOf('222'), isNull);
    final saved = config.tankConfig().tanks;
    expect(saved.sizes, {'111': 11.1});
    expect(saved.workingBar, isEmpty, reason: 'litres need no pressure');
    expect(saved.tanks.keys, ['111', '222', '333']);
  });

  test('imperial: cubic feet at the rated pressure, kept as litres', () {
    final editor = TankNamesEditor(config: config)..open();
    // An AL80: 77.4 cu ft at 3000 psi.
    expect(editor.workingText('111'), '3000');
    editor.setSize('111', '77.4', units: UnitSystem.imperial);
    expect(editor.sizeOf('111'), closeTo(10.6, 0.005));
    expect(editor.sizeText('111', UnitSystem.imperial), '77.4');
    // A steel 100 at 3442 psi: the pressure first, then the size.
    editor
      ..setWorkingPsi('222', '3442')
      ..setSize('222', '100', units: UnitSystem.imperial);
    expect(editor.sizeOf('222'), closeTo(11.93, 0.005));
    expect(editor.sizeText('222', UnitSystem.imperial), '100');
    // The pressure changed afterwards: the cubic feet stay, the litres
    // follow.
    editor
      ..setSize('333', '80', units: UnitSystem.imperial)
      ..setWorkingPsi('333', '2640');
    expect(editor.sizeText('333', UnitSystem.imperial), '80');
    expect(editor.sizeOf('333'), closeTo(12.45, 0.01));

    editor.setWorkingPsi('333', '12');
    expect(editor.badWorking('333'), isTrue);
    expect(editor.canSave, isFalse);
    editor.setWorkingPsi('333', '2640');
    expect(editor.canSave, isTrue);
    expect(editor.save(), isNotNull);

    final saved = config.tankConfig().tanks;
    expect(saved.workingBar['111'], closeTo(206.84, 0.01));
    expect(saved.workingBar['222'], closeTo(237.32, 0.01));
    final again = TankNamesEditor(config: config)..open();
    expect(again.sizeText('111', UnitSystem.imperial), '77.4');
    expect(again.workingText('222'), '3442');
    expect(again.sizeText('111', UnitSystem.metric), '10.6');
    // Cleared: the pressure goes with the size.
    again
      ..setSize('111', '', units: UnitSystem.imperial)
      ..save();
    expect(config.tankConfig().tanks.workingBar.keys, ['222', '333']);
  });

  test('the name and the side in sidemount, and the order', () {
    final editor = TankNamesEditor(config: config)..open();
    editor
      ..setName('111', ' Micke01 ')
      ..setSidemountName('111', ' Left ')
      ..setSide('111', TankSide.left)
      ..setName('222', 'Micke02')
      ..setSidemountName('222', 'Right')
      ..setSide('222', TankSide.right)
      ..setSidemountName('333', 'x')
      ..setSidemountName('333', '  ')
      ..setSide('333', TankSide.left)
      ..setSide('333', null)
      ..reorder(2, 0);
    expect(editor.rows.map((r) => r.serial), ['333', '111', '222']);
    expect(editor.rows[1].side, TankSide.left);
    expect(editor.save(), isNotNull);

    final saved = config.tankConfig().tanks;
    expect(saved.tanks, {
      '333': 'Tank 333',
      '111': 'Micke01',
      '222': 'Micke02',
    });
    expect(saved.tanks.keys, ['333', '111', '222']);
    expect(saved.sidemountNames, {'111': 'Left', '222': 'Right'});
    expect(saved.sides, {'111': TankSide.left, '222': TankSide.right});
    expect(saved.sidemountNamesByKey, {'Micke01': 'Left', 'Micke02': 'Right'});
    expect(saved.sidesByKey, {
      'Micke01': TankSide.left,
      'Micke02': TankSide.right,
    });
    final text = File(config.configYamlPath).readAsStringSync();
    expect(text, contains('tank_sidemount_names:'));
    expect(text, contains('tank_sides:'));
    expect(text, isNot(contains('tank_sizes')));
  });

  test('the sensors of the kept logs, with where they were seen', () async {
    final kept = Directory(p.join(tmp.path, 'dive_logs'))..createSync();
    final expected = <String, int>{};
    for (final name in ['air', 'nitrox_30_min_later', 'ccr_1_h_later']) {
      final bytes = base64.decode(_sources[name] as String);
      File(p.join(kept.path, '$name.fit')).writeAsBytesSync(bytes);
      for (final serial in uniqueTankSerials(readFitMessages(bytes))) {
        expected[serial] = (expected[serial] ?? 0) + 1;
      }
    }
    File(p.join(kept.path, 'broken.fit')).writeAsStringSync('not a log');
    expect(expected, isNotEmpty, reason: 'the fixture has tank sensors');

    final seen = keptTankSensors(kept.path);
    expect({for (final e in seen.entries) e.key: e.value.dives}, expected);
    for (final sensor in seen.values) {
      expect(sensor.last, isNotNull);
      expect(seenText(sensor), matches(r'^\d+ dives?, last \d{4}-\d\d-\d\d$'));
    }
    expect(keptTankSensors(p.join(tmp.path, 'none')), isEmpty);
    expect(seenText(null), 'not in your dive logs');
    expect(seenText(null, reading: true), '');

    final editor = TankNamesEditor(config: config)..open();
    await editor.readKept(kept.path);
    expect(editor.reading, isFalse);
    expect(editor.rows.take(3).map((r) => r.serial), ['111', '222', '333']);
    expect(
      editor.rows.skip(3).map((r) => r.serial),
      expected.keys.toList()..sort(),
    );
    expect(editor.rows.first.seen, isNull);
    expect(editor.rows.last.seen!.dives, expected[editor.rows.last.serial]);
    expect(editor.statusText, contains('${expected.length} new sensor(s)'));
    // Opened again: the saved ones only, until the logs are read.
    editor.open();
    expect(editor.rows.length, 3);
    editor.dispose();
  });
}
