// DiveManager against the Python app: the manager cases of its
// tests/test_alternative_formats.py, then the parity fixture made by
// tool/python_reference/model_fixture.py.
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/model/dive_manager.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

import '../../helpers/python_reference.dart';

Dive _dive(DateTime start, String? format, {String? maker, int samples = 10}) {
  final waypoints = [
    for (var i = 0; i < samples; i++)
      Waypoint(
        timestamp: start.add(Duration(seconds: i)),
        depth: 1.0,
        timeSinceStart: i,
      ),
  ];
  return Dive(
    startTime: start,
    endTime: waypoints.last.timestamp,
    waypoints: waypoints,
    logFormat: format,
    manufactor: maker,
    logPath: '/logs/$format-$samples',
  );
}

void main() {
  final start = naive(2025, 10, 19, 11, 42, 39);
  const shearwater = 'Shearwater Research, Inc';

  group('tests/test_alternative_formats.py', () {
    test('test_manager_keeps_richest_copy_of_a_dive', () {
      final manager = DiveManager();
      manager.addDives([_dive(start, 'subsurface_csv', samples: 50)]);
      manager.addDives([
        _dive(
          start.add(const Duration(seconds: 8)),
          'shearwater_csv',
          maker: shearwater,
        ),
      ]);
      manager.addDives([_dive(start, 'subsurface_xml', maker: 'Shearwater')]);
      expect(manager.dives.values.single.logFormat, 'shearwater_csv');
      // Equal rank: more samples wins.
      manager.addDives([_dive(start, 'uddf', maker: shearwater, samples: 5)]);
      manager.addDives([
        _dive(start, 'shearwater_xml', maker: shearwater, samples: 20),
      ]);
      expect(manager.dives.values.single.logFormat, 'shearwater_xml');
    });

    test('test_manager_merges_only_dives_from_different_log_files', () {
      final manager = DiveManager();
      final sameFile = [
        _dive(start, 'fit', samples: 5),
        _dive(start, 'fit', samples: 6),
      ];
      sameFile[1].logPath = sameFile[0].logPath;
      final later = start.add(const Duration(hours: 3));
      manager.addDives([
        ...sameFile,
        _dive(later, null),
        _dive(later.add(const Duration(seconds: 5)), null, samples: 4),
      ]);
      expect(manager.dives, hasLength(4));
    });

    test('test_manager_keeps_two_computers_on_one_dive', () {
      final manager = DiveManager();
      manager.addDives([
        _dive(start, 'fit', maker: 'garmin'),
        _dive(start, 'uddf', maker: shearwater, samples: 12),
      ]);
      manager.addDives([
        _dive(start.add(const Duration(hours: 2)), 'uddf', maker: shearwater),
      ]);
      expect(manager.dives, hasLength(3));
    });
  });

  group('parity with the Python manager', () {
    final cases = jsonObjects(
      pythonReference('model/model_cases.json')['manager'],
    );
    for (final c in cases) {
      test(c['name'] as String, () {
        final manager = DiveManager();
        for (final batch in c['batches'] as List<dynamic>) {
          manager.addDives([
            for (final dive in jsonObjects(batch)) Dive.fromJson(dive),
          ]);
        }
        final expected = c['expected'] as Map<String, dynamic>;
        expect([
          for (final entry in manager.dives.entries)
            {
              'start_time': formatNaive(entry.key.$1),
              'end_time': formatNaive(entry.key.$2),
              'log_format': entry.value.logFormat,
              'log_path': entry.value.logPath,
            },
        ], expected['kept']);
        for (final find in jsonObjects(expected['finds'])) {
          final at = find['at'] as String;
          expect(
            manager.findDiveForTimestamp(parseNaive(at))?.logPath,
            find['log_path'],
            reason: 'at $at',
          );
        }
      });
    }
  });

  // The port's addition to Python (spec §10.14): what was dropped is
  // reported.
  group('dropped dives are reported', () {
    test('a poorer copy that arrives later', () {
      final manager = DiveManager();
      final rich = _dive(start, 'uddf', maker: shearwater);
      final poor = _dive(start, 'subsurface_csv');
      expect(manager.addDives([rich]), isEmpty);
      final dropped = manager.addDives([poor]).single;
      expect(dropped.dropped, same(poor));
      expect(dropped.kept, same(rich));
      expect(dropped.reason, DroppedDiveReason.poorerCopy);
    });

    test('a held copy replaced by a richer one', () {
      final manager = DiveManager();
      final poor = _dive(start, 'subsurface_csv');
      final rich = _dive(start, 'uddf', maker: shearwater);
      manager.addDives([poor]);
      final dropped = manager.addDives([rich]).single;
      expect(dropped.dropped, same(poor));
      expect(dropped.kept, same(rich));
      expect(dropped.reason, DroppedDiveReason.poorerCopy);
    });

    test('a dive with the same start and end as one held', () {
      final manager = DiveManager();
      final first = _dive(start, null);
      final second = _dive(start, null);
      manager.addDives([first]);
      final dropped = manager.addDives([second]).single;
      expect(dropped.dropped, same(first));
      expect(dropped.kept, same(second));
      expect(dropped.reason, DroppedDiveReason.sameStartAndEnd);
      expect(manager.addDives([second]), isEmpty);
    });

    test('an equally rich copy takes the place of the one held', () {
      final manager = DiveManager();
      final first = _dive(start, 'uddf', maker: shearwater);
      final second = _dive(start, 'fit', maker: shearwater)
        ..logPath = '/logs/second';
      manager.addDives([first]);
      final dropped = manager.addDives([second]).single;
      expect(dropped.dropped, same(first));
      expect(dropped.kept, same(second));
      expect(manager.dives.values.single, same(second));
    });

    test('a richer copy that also lands on another dive\'s key', () {
      final manager = DiveManager();
      // Held: a poorer copy 30 s later, and an in-memory dive with the very
      // start and end the new dive has.
      final poorer = _dive(
        start.add(const Duration(seconds: 30)),
        'subsurface_csv',
      );
      final sameKey = _dive(start, null);
      manager.addDives([poorer, sameKey]);
      final rich = _dive(start, 'uddf', maker: shearwater);
      final dropped = manager.addDives([rich]);
      expect(
        [for (final d in dropped) (d.dropped, d.reason)],
        [
          (poorer, DroppedDiveReason.poorerCopy),
          (sameKey, DroppedDiveReason.sameStartAndEnd),
        ],
      );
      expect(manager.dives.values.single, same(rich));
    });
  });
}
