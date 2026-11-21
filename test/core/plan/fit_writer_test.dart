// The Dive Profile Builder's Garmin FIT log against the Python app: the
// parity fixture made by tool/python_reference/fit_writer_fixture.py holds
// the files parsers/fit_writer.py wrote for sixteen invented dives, what
// read_log_origin says of them and the plans plan_from_log rebuilds.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/parsers/fit_reader.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/core/plan/dive_plan.dart';
import 'package:uwmedia_app/core/plan/dive_plan_engine.dart';
import 'package:uwmedia_app/core/plan/dive_plan_import.dart';
import 'package:uwmedia_app/core/plan/fit_encoder.dart';
import 'package:uwmedia_app/core/plan/fit_profile_subset.dart';
import 'package:uwmedia_app/core/plan/fit_writer.dart';
import 'package:uwmedia_app/core/plan/plan_embed.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

import '../../helpers/python_reference.dart';

Map<String, dynamic> _unzip(String path) => jsonDecode(
  utf8.decode(
    gzip.decode(File('test/fixtures/python_reference/$path').readAsBytesSync()),
  ),
) as Map<String, dynamic>;

DiveProfilePlan _plan(Object? json) => DiveProfilePlan.fromJson(
  jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
);

/// Where two files first differ, for a failure's message.
String _firstDifference(Uint8List got, Uint8List want) {
  for (var i = 0; i < got.length && i < want.length; i++) {
    if (got[i] != want[i]) {
      String around(Uint8List b) => b
          .sublist(i < 8 ? 0 : i - 8, i + 16 < b.length ? i + 16 : b.length)
          .map((v) => v.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      return 'byte $i of ${got.length}/${want.length}: '
          '${around(got)} / ${around(want)}';
    }
  }
  return 'lengths ${got.length} / ${want.length}';
}

void main() {
  final reference = _unzip('plan/fit_cases.json.gz');
  final cases = jsonObjects(reference['cases']);
  final bases = reference['bases'] as Map<String, dynamic>;
  final now = parseNaive(reference['now'] as String);

  test('the constants and the profile table are the SDK\'s', () {
    final constants = reference['constants'] as Map<String, dynamic>;
    expect(tankSensorBase, constants['tank_sensor_base']);
    expect(planSoftwareVersion, constants['plan_software_version']);
    expect(fitApplicationId, constants['application_id']);
    expect(fitPlanFieldPrefix, constants['field_prefix']);
    expect(fitChunkBytes, constants['chunk_bytes']);
    final alerts = constants['dive_alert'] as Map<String, dynamic>;
    expect(alertSetpointAutoLow, alerts['setpoint_switch_auto_low']);
    expect(alertSetpointAutoHigh, alerts['setpoint_switch_auto_high']);
    expect(alertSwitchedToOpenCircuit, alerts['switched_to_open_circuit']);
    expect(alertSwitchedToClosedCircuit, alerts['switched_to_closed_circuit']);

    final profile = reference['profile'] as Map<String, dynamic>;
    expect(fitProfileVersion, profile['version']);
    final messages = profile['messages'] as Map<String, dynamic>;
    expect(fitMesgNums, {
      for (final MapEntry(:key, :value) in messages.entries)
        key: (value as Map<String, dynamic>)['num'],
    });
    messages.forEach((name, message) {
      final fields =
          (message as Map<String, dynamic>)['fields'] as Map<String, dynamic>;
      final own = fitMesgFields[message['num']]!;
      expect(own.keys, fields.keys, reason: name);
      fields.forEach((field, want) {
        final f = own[field]!;
        expect(
          {
            'num': f.num,
            'base_type': f.baseType,
            'type': f.type,
            'scale': f.scale,
            'offset': f.offset,
          },
          want,
          reason: '$name.$field',
        );
      });
    });
    expect(fitTypeValues, profile['values']);
  });

  test('every file is Python\'s, byte for byte', () {
    expect(cases.length, 16);
    for (final c in cases) {
      final plan = _plan(c['plan']);
      final (samples, _) = simulate(
        plan,
        resolutionSec: c['resolution'] as int,
      );
      final start = c['start'] as String?;
      final want = base64.decode(c['fit_base64'] as String);
      final packed = c['packed'] as String;
      // Python's zlib and Dart's give different bytes for the same text,
      // so the plan is packed with Python's here; that Dart's own packing
      // reads back is the next test.
      final got = fitBytes(
        plan,
        samples,
        startTime: start == null ? null : parseNaive(start),
        now: now,
        utcOffsetMinutes: c['utc_offset_minutes'] as int,
        deflate: (bytes) {
          expect(
            utf8.decode(zlib.decode(base64.decode(packed))),
            utf8.decode(bytes),
          );
          return base64.decode(packed);
        },
      );
      final reason = '${c['plan_name']} ${c['changes']}';
      expect(got, want, reason: '$reason: ${_firstDifference(got, want)}');
      expect(
        fitPlanChunks(plan, (_) => base64.decode(packed)).join(),
        packed,
        reason: reason,
      );
    }
  });

  test('a plan packed by this app reads back, and Python\'s does', () {
    for (final c in cases) {
      final plan = _plan(c['plan']);
      final (samples, _) = simulate(plan, resolutionSec: 60);
      final own = fitBytes(
        plan,
        samples,
        now: now,
        utcOffsetMinutes: 60,
        deflate: zlib.encode,
      );
      final origin = readLogOrigin('dive.FIT', own, inflate: zlib.decode);
      expect(origin.createdByUwmedia, isTrue);
      expect(origin.plan!.toJson(), c['plan']);

      final theirs = readLogOrigin(
        c['file_name'] as String,
        base64.decode(c['fit_base64'] as String),
        inflate: zlib.decode,
      );
      final want = c['origin'] as Map<String, dynamic>;
      expect(theirs.createdByUwmedia, want['created_by_uwmedia']);
      expect(theirs.plan?.toJson(), want['plan']);
    }
  });

  test('a written file is a dive to the Garmin parser', () {
    for (final c in cases) {
      final plan = _plan(c['plan']);
      final bytes = base64.decode(c['fit_base64'] as String);
      final dive = parseLogFile('/logs/${c['file_name']}', bytes)!.single;
      final (samples, _) = simulate(
        plan,
        resolutionSec: c['resolution'] as int,
      );
      expect(dive.waypoints.length, samples.length);
      expect(dive.startTime, parseNaive(c['local_start'] as String));
      expect(readFitMessages(bytes)['tank_summary_mesgs'], isNotEmpty);
    }
  });

  test('a plan rebuilt from a FIT log', () {
    final garmin = jsonObjects(pythonReference('dives/garmin.json')['files']);
    final logs = [
      for (final c in cases) (c, base64.decode(c['fit_base64'] as String)),
      for (final o in jsonObjects(reference['others']))
        if (o['source'] == 'dives/garmin.json')
          (
            o,
            base64.decode(garmin[o['index'] as int]['bytes_base64'] as String),
          ),
    ];
    expect(logs.length, 18);
    var rebuilt = 0;
    for (final (log, bytes) in logs) {
      final path = '/logs/${log['file_name']}';
      final dive = parseLogFile(path, bytes)!.first;
      (log['plans'] as Map<String, dynamic>).forEach((baseName, result) {
        final [status, want] = result as List<dynamic>;
        expect(status, 'ok');
        expect(
          planFromLog(path, bytes, dive, base: _plan(bases[baseName])).toJson(),
          want,
          reason: '${log['plan_name'] ?? log['name']} ($baseName)',
        );
        rebuilt++;
      });
    }
    expect(rebuilt, 36);
  });

  test('files that are not the builder\'s', () {
    for (final other in jsonObjects(reference['others'])) {
      final bytes = other['source'] == 'junk'
          ? base64.decode(other['bytes_base64'] as String)
          : base64.decode(
              jsonObjects(
                    pythonReference('dives/garmin.json')['files'],
                  )[other['index'] as int]['bytes_base64']
                  as String,
            );
      final origin = readLogOrigin(
        other['file_name'] as String,
        bytes,
        inflate: zlib.decode,
      );
      final want = other['origin'] as Map<String, dynamic>;
      expect(origin.createdByUwmedia, want['created_by_uwmedia']);
      expect(origin.plan?.toJson(), want['plan']);
    }
    // The mark without the plan: the builder's, and nothing to unpack.
    final encoder = FitEncoder()
      ..writeMesg(fitMesgNums['developer_data_id']!, {
        'developer_data_index': 0,
        'application_id': fitApplicationId,
      });
    final marked = readLogOrigin('a.fit', encoder.close());
    expect(marked.createdByUwmedia, isTrue);
    expect(marked.plan, isNull);
    // Another developer's file.
    final foreign = FitEncoder()
      ..writeMesg(fitMesgNums['developer_data_id']!, {
        'developer_data_index': 0,
        'application_id': List.filled(16, 7),
      });
    expect(readLogOrigin('a.fit', foreign.close()).createdByUwmedia, isFalse);
  });

  test('a plan that cannot be unpacked is no plan', () {
    final c = cases.first;
    final plan = _plan(c['plan']);
    final (samples, _) = simulate(plan, resolutionSec: 60);
    final bytes = fitBytes(
      plan,
      samples,
      now: now,
      utcOffsetMinutes: 0,
      deflate: zlib.encode,
    );
    // Without a way to unpack it, that is the caller's mistake.
    expect(() => readLogOrigin('a.fit', bytes), throwsArgumentError);
    final origin = readLogOrigin(
      'a.fit',
      bytes,
      inflate: (_) => throw const FormatException('not zlib'),
    );
    expect(origin.createdByUwmedia, isTrue);
    expect(origin.plan, isNull);
    // Not zlib data at all.
    final junk = fitBytes(
      plan,
      samples,
      now: now,
      utcOffsetMinutes: 0,
      deflate: (bytes) => bytes,
    );
    final unread = readLogOrigin('a.fit', junk, inflate: zlib.decode);
    expect(unread.createdByUwmedia, isTrue);
    expect(unread.plan, isNull);
  });

  test('what the writer refuses', () {
    for (final r in jsonObjects(reference['refused'])) {
      final plan = _plan(r['plan']);
      final resolution = r['resolution'] as int?;
      final samples = resolution == null
          ? <SimulatedSample>[]
          : simulate(plan, resolutionSec: resolution).$1;
      expect(r['raises'], isNotNull);
      expect(
        () => fitBytes(
          plan,
          samples,
          now: now,
          utcOffsetMinutes: 0,
          deflate: zlib.encode,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            resolution == null
                ? startsWith('No samples to write')
                : r['raises'],
          ),
        ),
      );
    }
  });

  group('the encoder', () {
    test('the checksum of the FIT protocol', () {
      // The header of every written file carries its own.
      final bytes = base64.decode(cases.first['fit_base64'] as String);
      expect(
        fitCrc(Uint8List.sublistView(bytes, 0, 12)),
        bytes[12] | bytes[13] << 8,
      );
      expect(fitCrc(bytes), 0);
    });

    test('values a field cannot hold', () {
      final record = fitMesgNums['record']!;
      FitEncoder encoder() => FitEncoder();
      expect(
        () => encoder().writeMesg(record, {'depth': double.nan}),
        throwsFormatException,
      );
      expect(
        () => encoder().writeMesg(record, {'depth': true}),
        throwsFormatException,
      );
      expect(
        () => encoder().writeMesg(record, {'depth': 'deep'}),
        throwsFormatException,
      );
      expect(
        () => encoder().writeMesg(fitMesgNums['file_id']!, {'type': 'nope'}),
        throwsFormatException,
      );
      expect(
        () => encoder().writeMesg(fitMesgNums['device_info']!, {
          'descriptor': 'x' * 255,
        }),
        throwsFormatException,
      );
      expect(
        () => encoder().writeMesg(record, {'depth': null}),
        throwsFormatException,
      );
      expect(
        () => encoder().writeMesg(record, {'altitude': 1}),
        throwsArgumentError,
      );
      expect(() => encoder().writeMesg(9999, {'x': 1}), throwsArgumentError);
    });

    test('a seventeenth kind of message takes over the first local number', () {
      // Seventeen definitions that differ in the descriptor's length.
      final encoder = FitEncoder();
      final info = fitMesgNums['device_info']!;
      for (var i = 0; i < 17; i++) {
        encoder.writeMesg(info, {'descriptor': 'x' * i});
      }
      encoder
        ..writeMesg(info, {'descriptor': 'yy'})
        ..writeMesg(info, {'descriptor': ''});
      final bytes = encoder.close();
      final messages = readFitMessages(bytes)['device_info_mesgs']!;
      expect(messages.length, 19);
      expect(messages[17]['descriptor'], 'yy');
      // An empty text is no value.
      expect(messages.last.containsKey('descriptor'), isFalse);
      // A definition is 9 bytes here; the first was written twice.
      final definitions = <int>[];
      for (var at = 14; at < bytes.length - 2;) {
        final header = bytes[at];
        if (header & 0x40 != 0) {
          definitions.add(header & 0x0F);
          at += 9;
        } else {
          at = bytes.indexOf(0, at + 1) + 1;
        }
      }
      expect(definitions, [...List.generate(16, (i) => i), 0, 1]);
    });
  });
}
