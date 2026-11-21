// The Log Viewer's two FIT tools against the Python app: the parity
// fixture made by tool/python_reference/fit_edit_fixture.py holds invented
// FIT files, and for each "Adjust time" and "Merge dives" on them the
// length and SHA-256 of the file parsers/fit_time.py and
// parsers/fit_merge.py wrote, or why they refused.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/pages/log_viewer_tools.dart';
import 'package:uwmedia_app/core/parsers/fit_merge.dart';
import 'package:uwmedia_app/core/parsers/fit_records.dart';
import 'package:uwmedia_app/core/parsers/fit_time.dart';
import 'package:uwmedia_app/core/parsers/registry.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

import '../../helpers/python_reference.dart';

void main() {
  final reference = jsonDecode(
    utf8.decode(
      gzip.decode(
        File('test/fixtures/python_reference/dives/fit_edit_cases.json.gz')
            .readAsBytesSync(),
      ),
    ),
  ) as Map<String, dynamic>;
  final sources = {
    for (final MapEntry(:key, :value)
        in (reference['sources'] as Map<String, dynamic>).entries)
      key: base64.decode(value as String),
  };
  Map<String, Object> digest(Uint8List bytes) => {
    'length': bytes.length,
    'sha256': sha256.convert(bytes).toString(),
  };

  test('the message and field numbers are the profile\'s', () {
    final constants = Map<String, dynamic>.of(
      reference['constants'] as Map<String, dynamic>,
    );
    expect([
      for (final (mesg, field) in fitDateTimeFields) [mesg, field],
    ], unorderedEquals(constants.remove('TIME_DATE_TIME_FIELDS') as List));
    expect(
      fitActivityLocalTimestamp,
      constants.remove('ACTIVITY_LOCAL_TIMESTAMP'),
    );
    expect(
      fitMergeSkippedFromSecond,
      unorderedEquals(constants.remove('SKIPPED_FROM_SECOND') as List),
    );
    expect(
      fitMergeStreamFromSecond,
      unorderedEquals(constants.remove('STREAM_FROM_SECOND') as List),
    );
    expect(fitMergeConstants, constants);
  });

  test('Adjust time: every file is Python\'s', () {
    final cases = jsonObjects(reference['adjust']);
    expect(cases.length, 18);
    var written = 0;
    for (final c in cases) {
      final reason = '${c['source']} ${c['local_start']}';
      final source = sources[c['source']]!;
      final before = Uint8List.fromList(source);
      final activity = c['activity_time'] as List<dynamic>;
      if (activity.first == 'raise') {
        expect(
          () => fitActivityTime(source),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              activity[2],
            ),
          ),
          reason: reason,
        );
      } else {
        final (:utc, :utcOffsetMinutes) = fitActivityTime(source);
        expect(utc, parseNaive(activity[0] as String), reason: reason);
        expect(utcOffsetMinutes, activity[1], reason: reason);
      }
      ({Uint8List bytes, int shiftSeconds}) run() => adjustFitTime(
        source,
        parseNaive(c['local_start'] as String),
        c['utc_offset_minutes'] as int,
      );
      final raises = c['raises'] as List<dynamic>?;
      if (raises != null) {
        expect(
          run,
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              raises[1],
            ),
          ),
          reason: reason,
        );
      } else {
        final (:bytes, :shiftSeconds) = run();
        expect(shiftSeconds, c['delta'], reason: reason);
        expect(digest(bytes), c['result'], reason: reason);
        final after = fitActivityTime(bytes);
        final want = c['result_activity_time'] as List<dynamic>;
        expect(after.utc, parseNaive(want[0] as String), reason: reason);
        expect(after.utcOffsetMinutes, want[1], reason: reason);
        written++;
      }
      // The source is never touched.
      expect(source, before, reason: reason);
    }
    expect(written, 10);
  });

  test('Merge dives: every file is Python\'s', () {
    final cases = jsonObjects(reference['merge']);
    expect(cases.length, 44);
    var written = 0;
    for (final c in cases) {
      final reason = '${c['first']} + ${c['second']}, close ${c['close_gap']}';
      final first = sources[c['first']]!;
      final second = sources[c['second']]!;
      final before = (Uint8List.fromList(first), Uint8List.fromList(second));
      ({Uint8List bytes, FitMergeResult result}) run() => mergeFitDives(
        first,
        second,
        closeGap: c['close_gap'] as bool,
        firstName: c['first_name'] as String,
        secondName: c['second_name'] as String,
      );
      final raises = c['raises'] as List<dynamic>?;
      if (raises != null) {
        expect(
          run,
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              raises[1],
            ),
          ),
          reason: reason,
        );
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
      expect(first, before.$1, reason: reason);
      expect(second, before.$2, reason: reason);
    }
    expect(written, 21);
  });

  test('a merged and an adjusted log are dives to the Garmin parser', () {
    final first = sources['air']!;
    final second = sources['nitrox_30_min_later']!;
    final d1 = parseLogFile('/logs/a.fit', first)!.single;
    final d2 = parseLogFile('/logs/b.fit', second)!.single;

    final kept = mergeFitDives(first, second, closeGap: false);
    final merged = parseLogFile('/logs/m.fit', kept.bytes)!.single;
    expect(merged.startTime, d1.startTime);
    expect(merged.endTime, d2.endTime);
    expect(
      merged.waypoints.length,
      d1.waypoints.length + kept.result.filledSamples + d2.waypoints.length,
    );
    expect(fitCrc(kept.bytes), 0);

    final closed = mergeFitDives(first, second, closeGap: true);
    final joined = parseLogFile('/logs/m.fit', closed.bytes)!.single;
    expect(joined.waypoints.length, d1.waypoints.length + d2.waypoints.length);
    expect(
      joined.endTime,
      d2.endTime.add(Duration(seconds: closed.result.shiftSeconds)),
    );

    final adjusted = adjustFitTime(first, naive(2026, 3, 5, 14, 23, 7), 420);
    final moved = parseLogFile('/logs/a.fit', adjusted.bytes)!.single;
    expect(moved.startTime, naive(2026, 3, 5, 14, 23, 7));
    expect(moved.timezone, 'UTC+07:00');
    expect(moved.waypoints.length, d1.waypoints.length);
    expect(
      [for (final wp in moved.waypoints) wp.depth],
      [for (final wp in d1.waypoints) wp.depth],
    );
    expect(adjusted.bytes.length, first.length);
    expect(fitCrc(adjusted.bytes), 0);
  });

  group('the dialogs', () {
    final viewer = reference['viewer'] as Map<String, dynamic>;
    List<List<dynamic>> rows(String key) =>
        (viewer[key] as List<dynamic>).cast<List<dynamic>>();

    test('the start and the offset as text', () {
      for (final [text as String, want as List<dynamic>] in rows(
        'parse_local_start',
      )) {
        if (want.first == 'raise') {
          expect(
            () => parseLocalStart(text),
            throwsFormatException,
            reason: text,
          );
        } else {
          expect(
            parseLocalStart(text),
            parseNaive(want[1] as String),
            reason: text,
          );
        }
      }
      for (final [text as String, want as List<dynamic>] in rows(
        'parse_utc_offset',
      )) {
        // Only the digits 0-9 are digits here (spec §10.27).
        if (want.first == 'raise' || text.contains(RegExp('[^ -~]'))) {
          expect(
            () => parseUtcOffset(text),
            throwsFormatException,
            reason: '"$text"',
          );
        } else {
          expect(parseUtcOffset(text), want[1], reason: '"$text"');
        }
      }
      for (final [minutes as int, want] in rows('format_utc_offset')) {
        expect(formatUtcOffset(minutes), want);
      }
    });

    test('the name a result is saved under', () {
      for (final [path as String, adjusted, merged] in rows('names')) {
        expect(adjustedName(path, context: p.posix), adjusted);
        expect(mergedName(path, context: p.posix), merged);
      }
      expect(
        adjustedName(r'C:\logs\Dive 12.fit', context: p.windows),
        r'C:\logs\Dive 12 (adjusted).fit',
      );
      expect(maxMergeGapSeconds, viewer['max_gap_seconds']);
    });

    test('the dives a dive can be merged with', () {
      final candidates = jsonObjects(viewer['candidates']);
      final names = [for (final c in candidates) c['dive'] as String];
      final dives = <Dive>[
        for (final name in names)
          parseLogFile('/logs/Dive $name.fit', sources[name]!)!.single
            ..logPath = '/logs/Dive $name.fit'
            ..logFilename = 'Dive $name.fit'
            ..logFormat = 'fit',
      ];
      for (final (i, c) in candidates.indexed) {
        final found = mergeCandidates(dives, dives[i], fileExists: (_) => true);
        expect(
          [for (final d in found) names[dives.indexOf(d)]],
          c['candidates'],
          reason: names[i],
        );
        expect([
          for (final d in found) candidateLabel(dives[i], d),
        ], c['labels']);
      }
      // A log that is gone, or not FIT, is no candidate.
      expect(
        mergeCandidates(dives, dives[0], fileExists: (_) => false),
        isEmpty,
      );
      dives[1].logFormat = 'uddf';
      expect(
        mergeCandidates(
          dives,
          dives[0],
          fileExists: (_) => true,
        ).contains(dives[1]),
        isFalse,
      );
      dives[2].logFilename = null;
      expect(
        candidateLabel(dives[0], dives[2]),
        (candidates[0]['labels'] as List<dynamic>)[0],
      );
    });
  });
}
