// The dive model against the Python app: the cases of its tests/test_models.py
// and the model cases of tests/test_ccr.py, then the parity fixture made by
// tool/python_reference/model_fixture.py.
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

import '../../helpers/python_reference.dart';

final _start = naive(2026, 1, 1, 10);

Waypoint _wp(
  int t,
  double? depth, {
  Map<String, TankData>? tanks,
  String? divemode,
  double? gasO2Percent,
  double? gasHePercent,
  double? diluentO2Percent,
  double? diluentHePercent,
}) => Waypoint(
  timestamp: _start.add(Duration(seconds: t)),
  depth: depth,
  timeSinceStart: t,
  diveTime: t,
  tanks: tanks,
  divemode: divemode,
  gasO2Percent: gasO2Percent,
  gasHePercent: gasHePercent,
  diluentO2Percent: diluentO2Percent,
  diluentHePercent: diluentHePercent,
);

Dive _dive(List<Waypoint> waypoints) => Dive(
  startTime: waypoints.first.timestamp,
  endTime: waypoints.last.timestamp,
  waypoints: waypoints,
);

void main() {
  group('tests/test_models.py', () {
    test('test_waypoint_model', () {
      final wp = Waypoint(
        timestamp: _start,
        depth: 10.5,
        temp: 24.0,
        timeSinceStart: 60,
        tanks: {'1': TankData(pressureBar: 200, o2Percent: 21.0)},
      );
      expect(wp.depth, 10.5);
      expect(wp.tanks['1']!.pressureBar, 200);
    });

    test('test_primary_secondary_tank_properties', () {
      final noTanks = Waypoint(timestamp: _start, timeSinceStart: 0);
      expect(noTanks.primaryTankName, isNull);
      expect(noTanks.secondaryTankPressure, isNull);
      expect(noTanks.secondaryTankName, isNull);

      final single = Waypoint(
        timestamp: _start,
        timeSinceStart: 0,
        tanks: {
          'Micke01': TankData(
            pressureBar: 200,
            o2Percent: 21.0,
            name: 'Micke01',
          ),
        },
      );
      expect(single.primaryTankName, 'Micke01');
      expect(single.secondaryTankPressure, isNull);
      expect(single.secondaryTankName, isNull);

      final sidemount = Waypoint(
        timestamp: _start,
        timeSinceStart: 0,
        tanks: {
          'Left': TankData(pressureBar: 180, o2Percent: 21.0),
          'Right': TankData(
            pressureBar: 190,
            o2Percent: 21.0,
            name: 'Right Tank',
          ),
        },
      );
      // The name falls back to the key when the tank has none.
      expect(sidemount.primaryTankName, 'Left');
      expect(sidemount.secondaryTankName, 'Right Tank');
      expect(sidemount.secondaryTankPressure, 190);
    });

    test('test_ccr_and_gas_switch_fields_default_to_none', () {
      final wp = Waypoint(timestamp: _start, timeSinceStart: 0);
      expect(wp.clearedGasMix, isNull);
      expect(wp.po2_1, isNull);
      expect(wp.po2_2, isNull);
      expect(wp.po2_3, isNull);

      final ccr = Waypoint(
        timestamp: _start,
        timeSinceStart: 0,
        clearedGasMix: 'EAN50',
        po2_1: 1.2,
        po2_2: 1.21,
        po2_3: 1.19,
      );
      expect(ccr.clearedGasMix, 'EAN50');
      expect(ccr.po2_1, 1.2);
      expect(ccr.po2_2, 1.21);
      expect(ccr.po2_3, 1.19);
    });

    test('test_dive_duration', () {
      final dive = Dive(
        startTime: naive(2023, 10, 1, 10),
        endTime: naive(2023, 10, 1, 11),
        waypoints: [],
      );
      expect(dive.duration, 3600);
    });
  });

  group('tests/test_ccr.py, the model cases', () {
    test('test_circuit_labels_and_the_ccr_flag', () {
      final loop = _wp(
        0,
        10,
        divemode: 'closedcircuit',
        diluentO2Percent: 21.0,
        diluentHePercent: 0.0,
        gasO2Percent: 21.0,
        gasHePercent: 0.0,
      );
      final bailout = _wp(60, 10, divemode: 'opencircuit', gasO2Percent: 50.0);
      final dive = _dive([loop, bailout]);
      expect(dive.isCcr, isTrue);
      expect((loop.circuit, bailout.circuit), ('CC', 'BO'));

      final oc = _dive([_wp(0, 10, divemode: 'opencircuit')]);
      expect(oc.isCcr, isFalse);
      expect(oc.waypoints.first.circuit, 'OC');
      // No mode logged: OC.
      expect(_wp(0, 10).circuit, 'OC');
      expect(_wp(0, 10, divemode: 'semiclosedcircuit').circuit, 'SC');
    });

    test('test_breathed_gas_and_diluent_po2_apart_from_the_tanks', () {
      Map<String, TankData> tanks() => {
        'O2': TankData(pressureBar: 180, o2Percent: 100.0),
        'T1': TankData(pressureBar: 190, o2Percent: 18.0, hePercent: 45.0),
      };
      final wp = _wp(
        0,
        30,
        tanks: tanks(),
        divemode: 'closedcircuit',
        gasO2Percent: 18.0,
        gasHePercent: 45.0,
        diluentO2Percent: 18.0,
      );
      // Not the O2 cylinder listed first.
      expect(wp.gasmix, '18/45');
      expect(wp.diluentPo2, 0.72);
      // No gas named: the first tank.
      expect(_wp(0, 30, tanks: tanks()).gasmix, 'Nx100');
      expect(_wp(0, 30).diluentPo2, isNull);
    });
  });

  group('parity with the Python model', () {
    final reference = pythonReference('model/model_cases.json');

    for (final c in jsonObjects(reference['dives'])) {
      final name = c['name'] as String;
      final json = c['dive'] as Map<String, dynamic>;
      final expected = c['expected'] as Map<String, dynamic>;

      test('$name: JSON round trip keeps every field', () {
        expect(Dive.fromJson(json).toJson(), json);
      });

      test('$name: computed values', () {
        final dive = Dive.fromJson(json);
        expect(dive.isCcr, expected['is_ccr']);
        expect(dive.maxDepth, expected['max_depth']);
        expect(dive.duration, expected['duration']);

        final waypoints = jsonObjects(expected['waypoints']);
        expect(dive.waypoints, hasLength(waypoints.length));
        for (var i = 0; i < waypoints.length; i++) {
          final wp = dive.waypoints[i];
          expect(
            {
              'gasmix': wp.gasmix,
              'gas_percent': wp.gasPercent,
              'circuit': wp.circuit,
              'diluent_po2': wp.diluentPo2,
              'primary_tank_pressure': wp.primaryTankPressure,
              'primary_tank_name': wp.primaryTankName,
              'secondary_tank_pressure': wp.secondaryTankPressure,
              'secondary_tank_name': wp.secondaryTankName,
              'log_filename': wp.logFilename,
            },
            waypoints[i],
            reason: 'waypoint $i',
          );
        }
      });

      test('$name: getWaypointAt', () {
        final dive = Dive.fromJson(json);
        for (final lookup in jsonObjects(expected['lookups'])) {
          final at = lookup['at'] as String;
          final found = dive.getWaypointAt(parseNaive(at));
          expect(
            found == null ? null : dive.waypoints.indexOf(found),
            lookup['index'],
            reason: 'at $at',
          );
        }
      });
    }

    test('gasmix rounds half to even and reads O2 first', () {
      for (final c in jsonObjects(reference['gasmix'])) {
        final o2 = (c['o2'] as num).toDouble();
        final he = (c['he'] as num?)?.toDouble();
        final named = _wp(0, 0, gasO2Percent: o2, gasHePercent: he);
        final fromTank = _wp(
          0,
          0,
          tanks: {
            '1': TankData(pressureBar: 200, o2Percent: o2, hePercent: he ?? 0),
          },
        );
        expect(named.gasmix, c['from_gas_fields'], reason: 'gas $o2/$he');
        expect(fromTank.gasmix, c['from_first_tank'], reason: 'tank $o2/$he');
        expect(
          named.gasPercent,
          c['percent_from_gas_fields'],
          reason: 'percent, gas $o2/$he',
        );
        expect(
          fromTank.gasPercent,
          c['percent_from_first_tank'],
          reason: 'percent, tank $o2/$he',
        );
      }
      expect(_wp(0, 0).gasmix, 'N/A');
      expect(_wp(0, 0).gasPercent, '--');
    });

    // tests/test_models.py test_gas_percent_names_the_breathed_gas_the_
    // perdix_3_way (Perdix 3 manual Rev B p.27).
    test('test_gas_percent_names_the_breathed_gas_the_perdix_3_way', () {
      Waypoint wp({
        Map<String, TankData>? tanks,
        double? gasO2Percent,
        double? gasHePercent,
      }) => _wp(
        0,
        0,
        tanks: tanks,
        gasO2Percent: gasO2Percent,
        gasHePercent: gasHePercent,
      );
      expect(wp().gasPercent, '--');
      expect(
        wp(tanks: {'T1': TankData(pressureBar: 200, o2Percent: 32.0)})
            .gasPercent,
        '32%',
      );
      expect(
        wp(tanks: {'T1': TankData(pressureBar: 200, o2Percent: 21.0)})
            .gasPercent,
        '21%',
      );
      expect(wp(gasO2Percent: 18.0, gasHePercent: 50.0).gasPercent, '18/50');
      expect(wp(gasO2Percent: 18.0, gasHePercent: 50.0).gasmix, '18/50');
      expect(
        wp(tanks: {'T1': TankData(pressureBar: 200, o2Percent: 21.0)}).gasmix,
        'AIR',
      );
    });

    test('diluentPo2', () {
      for (final c in jsonObjects(reference['diluent_po2'])) {
        final wp = _wp(
          0,
          (c['depth'] as num?)?.toDouble(),
          diluentO2Percent: (c['diluent_o2_percent'] as num).toDouble(),
        );
        expect(wp.diluentPo2, c['expected'], reason: '$c');
      }
    });
  });

  test('a waypoint added after the dive was built has no dive', () {
    // As in Python, where only the constructor sets the back-reference.
    final dive = _dive([_wp(0, 1, divemode: 'closedcircuit')]);
    final late = _wp(5, 1, divemode: 'opencircuit');
    dive.waypoints.add(late);
    expect(late.circuit, 'OC');
    expect(dive.waypoints.first.circuit, 'CC');
  });

  test('getWaypointAt follows the list after invalidateTimestampCache', () {
    final dive = _dive([_wp(0, 1), _wp(10, 2)]);
    expect(
      dive.getWaypointAt(_start.add(const Duration(seconds: 9))),
      dive.waypoints[1],
    );
    dive.waypoints[1].timestamp = _start.add(const Duration(seconds: 100));
    dive.invalidateTimestampCache();
    expect(
      dive.getWaypointAt(_start.add(const Duration(seconds: 9))),
      dive.waypoints[0],
    );
  });

  test('getWaypointNear: none away from the dive (spec §10.10)', () {
    final dive = _dive([_wp(0, 1), _wp(10, 2)]);
    DateTime at(int seconds) => _start.add(Duration(seconds: seconds));
    expect(dive.getWaypointNear(at(5)), dive.getWaypointAt(at(5)));
    // Within a minute of the first or the last sample: the nearest.
    expect(dive.getWaypointNear(at(-60)), dive.waypoints.first);
    expect(dive.getWaypointNear(at(70)), dive.waypoints.last);
    // Further: none, where getWaypointAt still gives the end's.
    expect(dive.getWaypointNear(at(-61)), isNull);
    expect(dive.getWaypointNear(at(71)), isNull);
    expect(dive.getWaypointAt(at(-1800)), dive.waypoints.first);
    expect(dive.getWaypointNear(at(-1800)), isNull);
  });

  test('before the descent the depth is not shown (spec §10.87)', () {
    // As the owner's Descent logged a dive (2026-06-26): the entry's dip
    // to 1.2 m starts it, then a minute at the surface, then down.
    final dive = _dive([
      _wp(0, 1.209),
      _wp(1, 0.937),
      _wp(14, 0.013),
      _wp(75, 0.01),
      _wp(84, 0.316),
      _wp(87, 1.05),
      _wp(99, 3.682),
      _wp(140, 7.5),
      _wp(200, 0.2),
    ]);
    DateTime at(int seconds) => _start.add(Duration(seconds: seconds));
    expect(dive.samplesBeforeDescent, 5);
    // The entry and the surface: the sample's other values, no depth.
    for (final t in [0, 1, 14, 60, 84]) {
      final shown = dive.getWaypointNear(at(t))!;
      expect(shown.depth, isNull, reason: '$t s');
      expect(shown.diveTime, dive.getWaypointAt(at(t))!.diveTime);
    }
    // The same object for the same sample: a video's frames stay one run.
    expect(
      identical(dive.getWaypointNear(at(14)), dive.getWaypointNear(at(20))),
      isTrue,
    );
    // After the last surface sample (0.3 m is the surface), the depth as
    // logged; the logged
    // samples themselves are not changed.
    expect(dive.getWaypointNear(at(87))!.depth, 1.05);
    expect(dive.getWaypointNear(at(200))!.depth, 0.2);
    expect(dive.waypoints.first.depth, 1.209);

    // Never at the surface before 3 m, or never at 3 m: as logged.
    expect(_dive([_wp(0, 1.5), _wp(10, 4)]).samplesBeforeDescent, 0);
    expect(_dive([_wp(0, 0.1), _wp(10, 2)]).samplesBeforeDescent, 0);
    expect(
      _dive([_wp(0, 5), _wp(10, 0.1), _wp(20, 6)]).samplesBeforeDescent,
      0,
    );
  });
}
