// The app's log and the problem report made of it (spec §10.76;
// lib/engine/app_log.dart, lib/core/diagnostics/report.dart).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/diagnostics/report.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/engine/app_log.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('uwmedia_log_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a line: when, where, what, on one line', () {
    expect(
      logLine(naive(2026, 11, 18, 21, 3, 9), 'Color', 'Reef.MP4: failed\n'),
      '2026-11-18 21:03:09 [Color] Reef.MP4: failed',
    );
    // What a tool printed on several lines stays one line of the log.
    expect(
      logLine(naive(2026, 1, 2), 'Error', 'first\r\n  second\n\nthird'),
      '2026-01-02 00:00:00 [Error] first | second | third',
    );
  });

  test(
    'work under way is known while it goes, and slow work is written',
    () async {
      final file = File(p.join(tmp.path, 'cache', appLogFilename));
      final log = AppLog.instance = AppLog(
        file,
        now: () => naive(2026, 11, 26),
      );
      addTearDown(() => AppLog.instance = null);
      expect(AppLog.underWay(), isEmpty);

      final gate = Completer<int>();
      final quick = AppLog.timed('Tools', 'ffmpeg -version', () => gate.future);
      final always = AppLog.timed(
        'App',
        'Finding Pictures',
        () => gate.future,
        slowMs: 0,
      );
      final failing = AppLog.timed<int>(
        'Tools',
        'exiftool -ver',
        () async => throw const FormatException('no'),
        slowMs: 0,
      );
      await expectLater(failing, throwsFormatException);
      // Two still going, each with its time so far; the failed one is done.
      expect(AppLog.underWay(), [
        matches(r'^ffmpeg -version \(\d+ ms\)$'),
        matches(r'^Finding Pictures \(\d+ ms\)$'),
      ]);
      gate.complete(7);
      expect(await quick, 7);
      expect(await always, 7);
      expect(AppLog.underWay(), isEmpty);
      // The quick one is not written; the one always written and the failed
      // one are.
      expect(log.tail(), [
        matches(r'\[Tools\] exiftool -ver failed after \d+ ms$'),
        matches(r'\[App\] Finding Pictures took \d+ ms$'),
      ]);
    },
  );

  test('lines are kept in the file, and read back', () {
    final file = File(p.join(tmp.path, 'cache', appLogFilename));
    var at = naive(2026, 11, 18, 21);
    final log = AppLog(file, now: () => at)
      ..add('App', 'Started')
      ..add('Color', '   ');
    at = naive(2026, 11, 18, 21, 0, 5);
    log.add('Color', 'Finished');
    expect(log.tail(), [
      '2026-11-18 21:00:00 [App] Started',
      '2026-11-18 21:00:05 [Color] Finished',
    ]);
    expect(log.tail(1), ['2026-11-18 21:00:05 [Color] Finished']);
    // Another start goes on in the same file.
    AppLog(file, now: () => at).add('App', 'Started again');
    expect(log.tail(), hasLength(3));
  });

  test('a large log starts anew, the one before kept beside it', () {
    final file = File(p.join(tmp.path, appLogFilename))
      ..writeAsStringSync('${'old line\n' * 9}${'x' * appLogMaxBytes}\n');
    final log = AppLog(file, now: () => naive(2026, 11, 18))..add('App', 'new');
    expect(File('${file.path}.1').existsSync(), isTrue);
    expect(file.readAsLinesSync(), ['2026-11-18 00:00:00 [App] new']);
    // The report reaches back into the one before.
    expect(log.tail(3)[1], startsWith('xxx'));
    expect(log.tail(3).last, endsWith('new'));
  });

  test('a log that cannot be written does not stop the app', () {
    final blocked = File(p.join(tmp.path, 'not_a_folder'))
      ..writeAsStringSync('x');
    final log = AppLog(File(p.join(blocked.path, appLogFilename)))
      ..add('App', 'Started');
    expect(log.tail(), isEmpty);
    // Without a running log a note goes nowhere.
    AppLog.instance = null;
    AppLog.note('Color', 'nothing');
  });

  test('the report: the facts, then the last lines', () {
    expect(
      reportText({'Version': '0.1.0', 'System': 'ios 18.1'}, ['a', 'b']),
      'UWMedia problem report\n'
      'Version: 0.1.0\n'
      'System: ios 18.1\n'
      '\n'
      'Log (last 2 lines):\n'
      'a\n'
      'b\n',
    );
    expect(reportText(const {}, const []), contains('The log is empty.'));
    final long = [for (var i = 0; i < reportLogLines + 50; i++) 'line $i'];
    final lines = reportText(const {}, long).split('\n');
    expect(lines, contains('Log (last $reportLogLines lines):'));
    expect(lines, isNot(contains('line 49')));
    expect(lines, contains('line 50'));
  });
}
