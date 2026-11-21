// The tank sizes the parsers read and the VSAC worked out from them after
// parsing, for logs that record none (spec §10.54). Not in the Python app.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/config/tank_config.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/parsers/fit_reader.dart';
import 'package:uwmedia_app/core/parsers/garmin.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';

import '../../helpers/python_reference.dart';
import '../../helpers/test_data.dart';

Map<String, dynamic> _case(String fixture, String name) =>
    jsonObjects(pythonReference('dives/$fixture.json')['parse'])
        .singleWhere((c) => c['name'] == name);

List<Dive> _parseCase(String fixture, String name) {
  final c = _case(fixture, name);
  return parseLogFile(
    '/logs/${c['file_name']}',
    base64Decode(c['bytes_base64'] as String),
  )!;
}

void main() {
  test('Subsurface: the cylinder sizes by tank key', () {
    final dive = _parseCase(
      'subsurface',
      'test_cylinders_live_pressures_and_sensor_names',
    ).single;
    // size='11.1 l' on the cylinder with sensor 0000001, '12.0 l' on the
    // second, none on the third.
    expect(dive.tankVolumesL, {'0000001': 11.1, '2': 12.0});
  });

  // 20 m (3 ata), 3 bar/min from a cylinder with [size]: 3.7 bar/min at
  // the surface per litre.
  Uint8List subsurfaceLog({String size = ''}) {
    final samples = [
      for (var t = 0; t <= 300; t += 10)
        "<sample time='${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')} min' "
            "depth='20.0 m' pressure0='${200.0 - t / 20.0} bar' />",
    ];
    return Uint8List.fromList(
      utf8.encode(
        "<divelog program='subsurface' version='3'><dives>"
        "<dive date='2026-01-01' time='10:00:00'>"
        "<cylinder $size o2='21.0%' description='AL80' />"
        "<divecomputer model='X'>${samples.join()}</divecomputer>"
        '</dive></dives></divelog>',
      ),
    );
  }

  test('Subsurface: VSAC from the pressures and the size', () {
    // 3 bar/min at 3 ata from an 11.1 l cylinder: 11.1 l/min.
    final dive = parseLogFile(
      '/logs/dive.ssrf',
      subsurfaceLog(size: "size='11.1 l'"),
    )!.single;
    expect(dive.tankVolumesL, {'AL80': 11.1});
    expect(dive.waypoints[3].volumeSac, isNull);
    expect(dive.waypoints.last.volumeSac, closeTo(11.1, 0.01));
  });

  group('the sizes set per tank in the app', () {
    test('give VSAC to a log without sizes; the log\'s own size wins', () {
      final none = parseLogFile('/logs/dive.ssrf', subsurfaceLog())!.single;
      expect(none.tankVolumesL, isEmpty);
      expect(none.waypoints.last.volumeSac, isNull);

      final sized = TankConfig(const {}, const {'AL80': 12.0});
      final dive = parseLogFile(
        '/logs/dive.ssrf',
        subsurfaceLog(),
        tanks: sized,
      )!.single;
      expect(dive.tankVolumesL, {'AL80': 12.0});
      expect(dive.waypoints.last.volumeSac, closeTo(12.0, 0.01));

      final own = parseLogFile(
        '/logs/dive.ssrf',
        subsurfaceLog(size: "size='11.1 l'"),
        tanks: sized,
      )!.single;
      expect(own.tankVolumesL, {'AL80': 11.1});
    });

    test('follow the serial to the name the tank is given', () {
      final config = TankConfig(
        const {'111': 'Left', '222': 'Right', '333': 'Left'},
        const {'111': 11.1, '333': 7.0, '444': 3.0},
      );
      expect(config.sizesByKey, {'Left': 11.1, '444': 3.0});
      final renamed = config.withTankName('111', 'Back');
      expect(renamed.sizes, config.sizes);
      expect(config.withTankSize('222', 12.0).sizes['222'], 12.0);
      expect(config.withTankSize('111', null).sizes.containsKey('111'), false);
      expect(config.withoutTank('111').sizes.containsKey('111'), false);
    });

    test('are kept in config.yaml next to the names', () {
      final file = ConfigFile.parse(
        "tanks:\n  '111': Left\ntank_sizes:\n  '111': 11.1\n  '222': 12\n"
        "  '333': big\n  '444': -1\nother: kept\n",
      );
      expect(file.tanks.sizes, {'111': 11.1, '222': 12.0});
      final text = file.withTanks(file.tanks.withTankSize('555', 15.0));
      final back = ConfigFile.parse(text);
      expect(back.tanks.sizes, {'111': 11.1, '222': 12.0, '555': 15.0});
      expect(back.tanks.tanks, {'111': 'Left'});
      expect(back.data.containsKey('other'), true);
      // No sizes: no section, so the file stays as Python writes it.
      final cleared = ConfigFile.parse(text).withTanks(TankConfig(const {}));
      expect(cleared.contains('tank_sizes'), false);
    });

    test(
      'Garmin: VSAC for a dive whose watch knew no tank size',
      () {
        const path = 'logs/fit/461 Sipadan, Turtle Tomb.fit';
        final file = File('${testDataDir().path}/$path');
        final bytes = file.readAsBytesSync();
        final serials = uniqueTankSerials(readFitMessages(bytes));
        expect(serials, isNotEmpty);
        final plain = parseLogFile(file.path, bytes)!.first;
        expect(plain.waypoints.any((wp) => wp.volumeSac != null), isFalse);
        final dive = parseLogFile(
          file.path,
          bytes,
          tanks: TankConfig(const {}, {for (final s in serials) s: 11.1}),
        )!.first;
        final sac = [
          for (final wp in dive.waypoints)
            if (wp.pressureSac != null && wp.volumeSac != null)
              (wp.pressureSac!, wp.volumeSac!),
        ];
        expect(sac, isNotEmpty);
      },
      skip: skipIfNoTestData('logs/fit/461 Sipadan, Turtle Tomb.fit'),
      tags: 'requires_media',
    );
  });

  test('Suunto: TankSize of the gas the cylinder breathes', () {
    final dive = _parseCase(
      'suunto',
      'EON with a Buhlmann algorithm, explicit gas numbers, a gas with a '
          'text number',
    ).single;
    // GasNumber 1.9 (gas 1) has TankSize 0.0113 m³.
    expect(dive.tankVolumesL, {'T1': 11.3});
  });

  test('UDDF: tankvolume in m³, by the tanks the samples name', () {
    final dive = _parseCase(
      'uddf',
      'written by the app: open circuit with a deco gas',
    ).first;
    expect(dive.tankVolumesL, isNotEmpty);
    final keys = {for (final wp in dive.waypoints) ...wp.tanks.keys};
    expect(keys, containsAll(dive.tankVolumesL.keys));
    for (final litres in dive.tankVolumesL.values) {
      expect(litres, inInclusiveRange(1.0, 30.0));
    }
  });

  test('the sizes survive the JSON the dives travel in', () {
    final dive = _parseCase(
      'subsurface',
      'test_cylinders_live_pressures_and_sensor_names',
    ).single;
    final back = Dive.fromJson(
      jsonDecode(jsonEncode(dive.toJson())) as Map<String, dynamic>,
    );
    expect(back.tankVolumesL, dive.tankVolumesL);
    final none = Dive.fromJson((dive.toJson()..remove('tank_volumes_l')));
    expect(none.tankVolumesL, isEmpty);
    expect(none.toJson().containsKey('tank_volumes_l'), isFalse);
  });
}
