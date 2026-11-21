// config.yaml (the tank names), color.yaml (the colour profiles) and the
// YAML text itself against the Python app: the cases of its
// tests/test_config.py, then the sweeps of the parity fixture made by
// tool/python_reference/config_fixture.py.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/color/color_profiles.dart';
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/config/yaml_text.dart';
import 'package:uwmedia_app/core/util/py_parse.dart';

import '../../helpers/python_reference.dart';

/// The tank mapping the way the fixture lists it.
List<List<String>> pairs(TankConfig tanks) => [
  for (final MapEntry(:key, :value) in tanks.tanks.entries) [key, value],
];

void main() {
  final reference = pythonReference('config/config_cases.json');

  group('tests/test_config.py', () {
    test('test_nothing_to_load', () {
      final config = ConfigFile.parse(null);
      expect(config.tanks.tanks, isEmpty);
      expect(config.tanks.mapTankName('123'), '123');
    });

    test('test_save_adds_new_serials_and_keeps_names', () {
      final config = ConfigFile.parse("tanks: {'200': Left}\nother: kept\n");
      final text = config.withTanks(
        config.tanks.withSerials(['300', '200', '100']),
      );
      final saved = ConfigFile.parse(text);
      // the tank order is kept, new serials go last
      expect(pairs(saved.tanks), [
        ['200', 'Left'],
        ['100', 'Tank 100'],
        ['300', 'Tank 300'],
      ]);
      expect(yamlValue(saved.data['other']), 'kept');
    });

    test('test_tank_order_is_the_mapping_order', () {
      final tanks = TankConfig({'222': 'Left', '111': 'Right', '333': 'Left'});
      final saved = ConfigFile.parse(ConfigFile.parse(null).withTanks(tanks));
      expect(pairs(saved.tanks), [
        ['222', 'Left'],
        ['111', 'Right'],
        ['333', 'Left'],
      ]);
      // by name (what the parsers key a tank by); unlisted tanks last
      expect(saved.tanks.orderTanks(['9', 'Right', '5', 'Left']), [
        'Left',
        'Right',
        '9',
        '5',
      ]);
      expect(saved.tanks.orderTanks([]), isEmpty);
    });

    test('test_rename_and_remove_write_through', () {
      var config = ConfigFile.parse(null);
      config = ConfigFile.parse(
        config.withTanks(config.tanks.withTankName('555', 'Stage')),
      );
      expect(config.tanks.tanks, {'555': 'Stage'});
      config = ConfigFile.parse(
        config.withTanks(
          config.tanks.withoutTank('555').withoutTank('never-there'),
        ),
      );
      expect(config.tanks.tanks, isEmpty);
      expect(config.withTanks(config.tanks), 'tanks: {}\n');
    });

    test('test_broken_yaml_loads_as_empty', () {
      expect(ConfigFile.parse('tanks: [unclosed').tanks.tanks, isEmpty);
    });

    test('test_unquoted_numeric_serials_are_text', () {
      var config = ConfigFile.parse(
        "tanks:\n  3456789: Left\n  '100': Right\n",
      );
      expect(config.tanks.tanks, {'3456789': 'Left', '100': 'Right'});
      config = ConfigFile.parse(
        config.withTanks(
          config.tanks.withTankName('3456789', 'Main').withoutTank('100'),
        ),
      );
      expect(config.tanks.tanks, {'3456789': 'Main'});
    });

    test('an unquoted serial keeps the text of the file', () {
      // PyYAML reads 0123 as the octal number 83 and 1:30 as 90.
      final config = ConfigFile.parse(
        'tanks:\n  0123: yes\n  1:30: 007\n  5: ~\n',
      );
      expect(config.tanks.tanks, {'0123': 'yes', '1:30': '007', '5': 'None'});
      expect(
        config.withTanks(config.tanks),
        "tanks:\n  '0123': 'yes'\n  '1:30': '007'\n  '5': None\n",
      );
    });
  });

  group('YAML text, parity with PyYAML', () {
    final dump = reference['dump'] as Map<String, dynamic>;

    test('text as a value, as a key and in a list', () {
      final cases = (dump['strings'] as List<dynamic>).cast<List<dynamic>>();
      expect(cases.length, greaterThan(80));
      for (final [text as String, asValue, asKey, inList] in cases) {
        final value = writeYaml({'k': text});
        final key = writeYaml({text: 1});
        final list = writeYaml([text]);
        if (text.contains('\n')) {
          // PyYAML: single quotes over several lines; here "\n".
          expect(value, 'k: "multi\\nline"\n');
        } else {
          expect(value, asValue, reason: text);
          expect(list, inList, reason: text);
        }
        // PyYAML writes an empty or odd key as "? key" and ": value".
        if (!(asKey as String).startsWith('? ')) {
          expect(key, asKey, reason: text);
        }
        // And all of it reads back as the same text.
        expect('${(readYaml(value)! as Map)['k']}', text, reason: value);
        expect((readYaml(key)! as Map).keys.single, text, reason: key);
        expect('${(readYaml(list)! as List).single}', text, reason: list);
      }
    });

    test('numbers, bools and null', () {
      for (final [value, text]
          in (dump['values'] as List<dynamic>).cast<List<dynamic>>()) {
        final number = switch (value) {
          'inf' => double.infinity,
          '-inf' => double.negativeInfinity,
          _ => value,
        };
        expect(writeYaml({'k': number}), text);
      }
      expect(writeYaml({'k': double.nan}), 'k: .nan\n');
      expect(pyFloatRepr(-0.0), '-0.0');
      expect(pyFloatRepr(1e22), '1e+22');
      expect(pyFloatRepr(123456.7), '123456.7');
      expect(pyFloatRepr(5e-324), '5e-324');
    });

    test('nested maps and lists', () {
      var checked = 0;
      for (final [object, text]
          in (dump['objects'] as List<dynamic>).cast<List<dynamic>>()) {
        if (object != null) {
          expect(writeYaml(object), text);
          checked++;
        }
      }
      expect(checked, 7);
    });

    test('unquoted scalars go back as they stand', () {
      const text =
          'a: yes\nb: 010\nc: 1:30\nd: 2026-01-01\ne: 1.50\nf: ~\n'
          'g:\n- on\n- 0x1F\n';
      expect(writeYaml(readYaml(text)), text);
      final data = readYaml(text)! as Map<String, Object?>;
      expect(yamlValue(data['e']), 1.5);
      expect(yamlValue(data['f']), isNull);
    });

    test('what is not YAML', () {
      expect(() => readYaml('a: [unclosed'), throwsFormatException);
      expect(readYaml(''), isNull);
      expect(readYamlMap('- a\n- b\n'), isEmpty);
      expect(readYamlMap('just text'), isEmpty);
      expect(() => writeYaml({'k': Object()}), throwsArgumentError);
    });
  });

  group('config.yaml, parity with Python', () {
    final ops = <String, TankConfig Function(TankConfig)>{
      'save': (t) => t.withSerials(['300', '200', '100']),
      'save_none': (t) => t.withSerials([]),
      'rename': (t) => t.withTankName('200', 'Stage'),
      'rename_new': (t) => t.withTankName('555', 'New: tank'),
      'remove': (t) => t.withoutTank('200'),
      'remove_missing': (t) => t.withoutTank('never-there'),
      'replace': (_) =>
          TankConfig({'222': 'Left', '111': 'Right', '333': 'Left'}),
      'replace_empty': (_) => TankConfig(),
    };

    test('the mapping and every change to it', () {
      final cases = jsonObjects(reference['tanks']);
      expect(cases.length, 14);
      for (final c in cases) {
        final text = c['text'] as String?;
        final config = ConfigFile.parse(text);
        if (c.containsKey('raise')) {
          // Not a map, or tanks that are not one: Python fails, the port
          // has no tanks.
          expect(config.tanks.tanks, isEmpty, reason: '$text');
          continue;
        }
        expect(pairs(config.tanks), c['mapping'], reason: '$text');
        for (final [serial as String, name]
            in (c['names'] as List<dynamic>).cast<List<dynamic>>()) {
          expect(config.tanks.mapTankName(serial), name);
        }
        expect(
          config.tanks.orderTanks([
            '9',
            'Right',
            '5',
            'Left',
            'One',
            'Stage',
            'Zero',
          ]),
          c['order'],
          reason: '$text',
        );
        for (final [name as String, written, mapping]
            in (c['ops'] as List<dynamic>).cast<List<dynamic>>()) {
          final tanks = ops[name]!(config.tanks);
          expect(config.withTanks(tanks), written, reason: '$name on $text');
          expect(pairs(tanks), mapping, reason: '$name on $text');
          expect(
            pairs(ConfigFile.parse(written as String).tanks),
            mapping,
            reason: 'reading back $name on $text',
          );
        }
      }
    });
  });

  group('color.yaml, parity with Python', () {
    final color = reference['color'] as Map<String, dynamic>;

    test('the bundled file is the Python app\'s', () {
      expect(File('assets/color.yaml').readAsStringSync(), color['bundled']);
    });

    test('bundled and user profiles merged', () {
      final cases = jsonObjects(color['merged']);
      expect(cases.length, 28);
      for (final c in cases) {
        final merged = mergedColorProfiles(
          c['bundled'] as String?,
          c['user'] as String?,
        );
        // An entry that is not a set of parameters is left out here.
        final want = {
          for (final MapEntry(:key, :value)
              in (c['profiles'] as Map<String, dynamic>).entries)
            if (value is Map) key: value,
        };
        expect(
          merged,
          want.isEmpty ? {'default': <String, Object?>{}} : want,
          reason: '${c['user']}',
        );
        expect(merged.keys, want.isEmpty ? ['default'] : want.keys);
      }
    });

    test('a merged profile feeds the engine', () {
      final merged = mergedColorProfiles(
        color['bundled'] as String,
        'default:\n  sharpness: 1.25\n',
      );
      expect(merged.keys, ['default', 'vivid', 'subtle']);
      // The user's default replaces the bundled one as a whole.
      final profile = ColorProfile.fromMap(merged['default']!);
      expect(profile.sharpness, 1.25);
      expect(profile.darkness, 0.0);
      expect(ColorProfile.fromMap(merged['vivid']!).redThreshold, 0.25);
    });

    test('saving a user profile', () {
      final cases = jsonObjects(color['saved']);
      expect(cases.length, 28);
      for (final c in cases) {
        expect(
          withUserProfile(
            c['user'] as String?,
            c['name'] as String,
            c['values'] as Map<String, dynamic>,
          ),
          c['text'],
          reason: '${c['name']} into ${c['user']}',
        );
      }
    });

    test('the tuning parameters', () {
      expect([
        for (final (group, params) in colorParamGroups)
          [
            group,
            [
              for (final p in params)
                [p.key, p.label, p.min, p.max, p.fallback, p.isInt],
            ],
          ],
      ], reference['param_groups']);
      expect(colorParamsByKey.length, 26);
      // Every parameter is one the engine's profile knows, with the same
      // fallback.
      const defaults = ColorProfile();
      expect(colorParamsByKey['sharpness']!.fallback, defaults.sharpness);
      expect(colorParamsByKey['bh_max_idx']!.fallback, defaults.bhMaxIdx);
      expect(colorParamsByKey['dehaze_min']!.fallback, defaults.dehazeMin);
    });
  });
}
