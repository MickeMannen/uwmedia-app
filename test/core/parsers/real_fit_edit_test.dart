// "Adjust time" on each of the owner's real Garmin logs and "Merge dives"
// on each with the next one, against the files the Python app writes.
// Neither the logs nor the reference are in git: they are under
// test_data/ (see CONTRIBUTING.md), and the reference is made by
// `tool/python_reference/fit_edit_fixture.py --real`. Without them the
// tests skip themselves.
@Tags(['requires_media'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/parsers/fit_merge.dart';
import 'package:uwmedia_app/core/parsers/fit_time.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

import '../../helpers/test_data.dart';

void main() {
  const referencePath = 'python_reference/fit_edit.json';
  final skip = skipIfNoTestData(referencePath) ?? skipIfNoTestData('logs/fit');
  Map<String, dynamic> reference() => jsonDecode(
    File('${testDataDir().path}/$referencePath').readAsStringSync(),
  ) as Map<String, dynamic>;
  Uint8List? log(Object? name) {
    final file = File('${testDataDir().path}/logs/fit/$name');
    return file.existsSync() ? file.readAsBytesSync() : null;
  }

  Map<String, Object> digest(Uint8List bytes) => {
    'length': bytes.length,
    'sha256': sha256.convert(bytes).toString(),
  };
  Matcher refusal(List<dynamic> raises) => throwsA(
    isA<FormatException>().having((e) => e.message, 'message', raises[1]),
  );

  test('every real FIT log is adjusted as Python adjusts it', () {
    var written = 0;
    (reference()['adjust'] as Map<String, dynamic>).forEach((name, value) {
      final bytes = log(name);
      if (bytes == null) {
        return;
      }
      final c = value as Map<String, dynamic>;
      final activity = c['activity_time'] as List<dynamic>;
      if (activity.first != 'raise') {
        final (:utc, :utcOffsetMinutes) = fitActivityTime(bytes);
        expect(utc, parseNaive(activity[0] as String), reason: name);
        expect(utcOffsetMinutes, activity[1], reason: name);
      }
      ({Uint8List bytes, int shiftSeconds}) run() => adjustFitTime(
        bytes,
        parseNaive(c['local_start'] as String),
        c['utc_offset_minutes'] as int,
      );
      final raises = c['raises'] as List<dynamic>?;
      if (raises != null) {
        expect(run, refusal(raises), reason: name);
      } else {
        final result = run();
        expect(result.shiftSeconds, c['delta'], reason: name);
        expect(digest(result.bytes), c['result'], reason: name);
        written++;
      }
    });
    expect(written, greaterThan(0));
  }, skip: skip);

  test('every real pair of FIT logs is merged as Python merges it', () {
    var written = 0;
    for (final value in reference()['merge'] as List<dynamic>) {
      final c = value as Map<String, dynamic>;
      final first = log(c['first']);
      final second = log(c['second']);
      if (first == null || second == null) {
        continue;
      }
      final reason = '${c['first']} + ${c['second']}, close ${c['close_gap']}';
      ({Uint8List bytes, FitMergeResult result}) run() => mergeFitDives(
        first,
        second,
        closeGap: c['close_gap'] as bool,
        firstName: c['first'] as String,
        secondName: c['second'] as String,
      );
      final raises = c['raises'] as List<dynamic>?;
      if (raises != null) {
        expect(run, refusal(raises), reason: reason);
      } else {
        final (:bytes, :result) = run();
        expect(
          {
            'gap_seconds': result.gapSeconds,
            'shift_seconds': result.shiftSeconds,
            'filled_samples': result.filledSamples,
            'gases_added': result.gasesAdded,
          },
          c['merge'],
          reason: reason,
        );
        expect(digest(bytes), c['result'], reason: reason);
        written++;
      }
    }
    expect(written, greaterThan(0));
  }, skip: skip);

  // tests/test_fit_merge.py test_real_descent_logs: the merged log read
  // back as a dive.
  for (final closeGap in [false, true]) {
    test(
      'test_real_descent_logs, close gap $closeGap',
      () {
        const firstName = '450 Tioman Island, Palau Labas.fit';
        const secondName = '451 Tioman Island, Palau Labas.fit';
        final first = log(firstName)!;
        final second = log(secondName)!;
        Dive parse(String name, Uint8List bytes) =>
            parseLogFile(name, bytes)!.single;
        final d1 = parse(firstName, first);
        final d2 = parse(secondName, second);
        final (:bytes, :result) = mergeFitDives(
          first,
          second,
          closeGap: closeGap,
          firstName: firstName,
          secondName: secondName,
        );
        final merged = parse('merged.fit', bytes);
        expect(merged.startTime, d1.startTime);
        expect(
          merged.maxDepth,
          [d1.maxDepth, d2.maxDepth].reduce((a, b) => a > b ? a : b),
        );
        expect(merged.device, d1.device);
        expect(
          merged.waypoints.length,
          d1.waypoints.length + d2.waypoints.length + result.filledSamples,
        );
        if (closeGap) {
          expect(result.filledSamples, 0);
          expect(
            merged.endTime,
            d2.endTime.add(Duration(seconds: result.shiftSeconds)),
          );
        } else {
          expect(result.filledSamples, greaterThan(0));
          expect(merged.endTime, d2.endTime);
          // Mid-interval the merged log shows the surface, as the first dive
          // ended.
          final at = merged.getWaypointAt(
            d1.endTime.add(const Duration(minutes: 10)),
          );
          expect(at!.depth, d1.waypoints.last.depth);
        }
      },
      skip:
          skip ??
          skipIfNoTestData('logs/fit/450 Tioman Island, Palau Labas.fit'),
    );
  }
}
