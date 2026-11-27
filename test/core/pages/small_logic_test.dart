// Small pieces of the pages' logic against the Python app: the cases of
// its tests/test_run_timing.py and the chart cases of
// tests/test_dive_plan_engine.py, then the parity fixture made by
// tool/python_reference/small_fixture.py; and the settings text.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/config/app_settings.dart';
import 'package:uwmedia_app/core/pages/display_paths.dart';
import 'package:uwmedia_app/core/pages/run_timing.dart';
import 'package:uwmedia_app/core/plan/dive_plan.dart';
import 'package:uwmedia_app/core/plan/dive_plan_engine.dart';
import 'package:uwmedia_app/core/plan/profile_chart.dart';

import '../../helpers/python_reference.dart';

void main() {
  final reference = pythonReference('pages/small_cases.json');

  group('tests/test_run_timing.py', () {
    test('test_format_duration', () {
      expect(formatDuration(0), '0:00');
      expect(formatDuration(7.4), '0:07');
      expect(formatDuration(252), '4:12');
      expect(formatDuration(3825), '1:03:45');
    });

    test('test_estimate_extrapolates_from_fraction', () {
      var now = 100.0;
      final timer = RunTimer(() => now)..start();
      now += 60;
      expect(timer.remaining(0.25), 180);
      expect(timer.text(0.25), 'Elapsed 1:00 · about 3:00 left');
      // below a minute the estimate is exact, above it rounds up to 10 s
      now += 100;
      expect(timer.remaining(0.8), closeTo(40, 1e-9));
      expect(timer.remaining(0.5), 160);
      expect(timer.remaining(1.0), 0);
    });
  });

  group('parity with Python', () {
    test('formatDuration', () {
      expect(minFraction, reference['min_fraction']);
      expect(minElapsed, reference['min_elapsed']);
      for (final [seconds as num, want]
          in (reference['durations'] as List<dynamic>).cast<List<dynamic>>()) {
        expect(formatDuration(seconds), want, reason: '$seconds');
      }
    });

    test('RunTimer through five runs', () {
      final runs = jsonObjects(reference['timers']);
      expect(runs.length, 5);
      for (final run in runs) {
        var now = 100.0;
        final timer = RunTimer(() => now);
        final asked = jsonObjects(run['asked']).iterator;
        for (final step
            in (run['script'] as List<dynamic>).cast<List<dynamic>>()) {
          switch (step[0]) {
            case 'wait':
              now += (step[1] as num).toDouble();
            case 'start':
              timer.start();
            case 'stop':
              timer.stop();
            case 'fail':
              timer.stop(ok: false);
            case 'reset':
              timer.reset();
            case 'ask':
              asked.moveNext();
              final want = asked.current;
              final fraction = (step[1] as num?)?.toDouble();
              expect(timer.text(fraction), want['text'], reason: '$step');
              final left = timer.remaining(fraction);
              expect(
                left,
                want['remaining'] == null
                    ? isNull
                    : closeTo(want['remaining'] as num, 1e-9),
                reason: '$step',
              );
              expect(timer.elapsed, closeTo(want['elapsed'] as num, 1e-9));
              expect(timer.running, want['running']);
              expect(timer.started, want['started']);
          }
        }
        expect(asked.moveNext(), isFalse);
      }
    });

    test('shownLocation', () {
      const box =
          '/Users/x/Library/Containers/org.christersson.uwmedia/Data'
          '/Library/Application Support/org.christersson.uwmedia';
      const own = [box, ''];
      expect(shownLocation(box, own, '/Users/x'), ownFolderName);
      expect(
        shownLocation('$box/layouts', own, '/Users/x'),
        "UWMedia's own folder › layouts",
      );
      expect(
        shownLocation('$box/a/config.yaml', own, '/Users/x'),
        "UWMedia's own folder › a › config.yaml",
      );
      // Beside it, or elsewhere: the path, with the home folder short.
      expect(shownLocation('${box}x/layouts', own, null), '${box}x/layouts');
      expect(shownLocation('/Users/x/Dive', own, '/Users/x'), '~/Dive');
      expect(shownLocation('/Volumes/d', own, '/Users/x'), '/Volumes/d');
      // Windows.
      expect(
        shownLocation(r'C:\Users\d\AppData\Roaming\UWMedia\layouts', [
          r'C:\Users\d\AppData\Roaming\UWMedia',
        ], r'C:\Users\d'),
        "UWMedia's own folder › layouts",
      );
    });

    test('contractHomePath', () {
      const home = '/Users/diver';
      for (final [path, want]
          in (reference['home_paths'] as List<dynamic>).cast<List<dynamic>>()) {
        expect(
          contractHomePath((path as String?)?.replaceAll('HOME', home), home),
          (want as String?)?.replaceAll('HOME', home),
          reason: '$path',
        );
      }
      expect(contractHomePath('/a/b', null), '/a/b');
      // Windows: under a backslash too (spec §10.86).
      const windows = r'C:\Users\diver';
      expect(contractHomePath(r'C:\Users\diver\logs', windows), r'~\logs');
      expect(
        contractHomePath(r'C:\Users\diverx\logs', windows),
        r'C:\Users\diverx\logs',
      );
      expect(
        contractHomePath(r'/Users/diver\logs', home),
        r'/Users/diver\logs',
      );
    });

    test('the chart: axes, mapping and colours', () {
      final chart = reference['chart'] as Map<String, dynamic>;
      expect([
        chartMarginLeft,
        chartMarginRight,
        chartMarginTop,
        chartMarginBottom,
      ], chart['margins']);
      expect(depthHeadroom, chart['headroom']);
      expect(gasColors, chart['gas_colors']);
      expect(depthLineColor, chart['depth_line_color']);
      final plans = {
        for (final p in jsonObjects(
          (jsonDecode(
            utf8.decode(
              gzip.decode(
                File(
                  'test/fixtures/python_reference/plan/'
                  'plan_cases.json.gz',
                ).readAsBytesSync(),
              ),
            ),
          ) as Map<String, dynamic>)['plans'],
        ))
          p['name'] as String: p['plan'] as Map<String, dynamic>,
      };
      final cases = jsonObjects(chart['cases']);
      expect(cases.length, 56);
      for (final c in cases) {
        final reason = '${c['plan']} ${c['changes']} ${c['with_samples']}';
        final plan = DiveProfilePlan.fromJson({
          ...jsonDecode(jsonEncode(plans[c['plan']])) as Map<String, dynamic>,
          ...c['changes'] as Map<String, dynamic>,
        });
        final samples = (c['with_samples'] as bool) && plan.gases.isNotEmpty
            ? simulate(plan, resolutionSec: c['resolution'] as int).$1
            : <SimulatedSample>[];
        final axes = chartAxes(plan, samples);
        expect(
          axes == null ? null : [axes.$1, axes.$2],
          c['axes'] == null
              ? isNull
              : [
                  for (final v in c['axes'] as List<dynamic>)
                    closeTo(v as num, 1e-9),
                ],
          reason: reason,
        );
        expect(
          [
            for (final g in plan.gases) [g.id, gasColor(plan, g.id)],
            ['nope', gasColor(plan, 'nope')],
          ],
          c['gas_colors'],
          reason: reason,
        );
        expect(nextFreeGasColor(plan), c['next_free'], reason: reason);
        expect(
          [for (final s in samples) sampleColor(plan, s)],
          c['sample_colors'],
          reason: reason,
        );
        for (final [t as num, want]
            in (c['nearest'] as List<dynamic>).cast<List<dynamic>>()) {
          expect(
            nearestSample(samples, t)?.timeSec,
            want,
            reason: '$reason $t',
          );
        }
        if (axes == null) {
          continue;
        }
        for (final [
              t as num,
              d as num,
              w as int,
              h as int,
              want as List<dynamic>,
            ]
            in (c['points'] as List<dynamic>).cast<List<dynamic>>()) {
          final (x, y) = xyOf(t, d, w, h, axes);
          expect(x, closeTo(want[0] as num, 1e-9), reason: reason);
          expect(y, closeTo(want[1] as num, 1e-9), reason: reason);
        }
        for (final [
              x as num,
              y as num,
              w as int,
              h as int,
              want as List<dynamic>,
              time as num,
            ]
            in (c['clicks'] as List<dynamic>).cast<List<dynamic>>()) {
          final (t, d) = pointFromXy(x, y, w, h, axes);
          expect(t, closeTo(want[0] as num, 1e-9), reason: reason);
          expect(d, closeTo(want[1] as num, 1e-9), reason: reason);
          expect(timeFromX(x, w, axes.$1), closeTo(time, 1e-9), reason: reason);
        }
      }
    });
  });

  group('settings', () {
    test('defaults, a file over them, and a broken file', () {
      expect(loadSettings(null), defaultSettings());
      expect(loadSettings('{not json'), defaultSettings());
      expect(loadSettings('[1]'), defaultSettings());
      final data = loadSettings('{"units": "imperial", "new_key": 1}');
      expect(data['units'], 'imperial');
      expect(data['new_key'], 1);
      expect(data['filename_formats'], isEmpty);
      expect(loadSettings(settingsText(data)), data);
    });

    test('fields, lists and the folder a dialog starts in', () {
      var data = loadSettings(null);
      data = withField(data, 'source_input', '/media/dives');
      data = withField(data, 'hw_accel_switch', true);
      expect(settingsFields(data), {
        'source_input': '/media/dives',
        'hw_accel_switch': true,
      });
      data = withUnique(data, 'filename_formats', '%Y_Bali');
      data = withUnique(data, 'filename_formats', '%Y_Bali');
      data = withUnique(data, 'filename_formats', '%Y');
      expect(data['filename_formats'], ['%Y_Bali', '%Y']);
      // the defaults themselves are not touched
      expect(defaultSettings()['fields'], isEmpty);
      String start(String key, {bool there = true}) =>
          dialogDir(data, key, home: '/Users/diver', isFolder: (_) => there);
      expect(start('source_input'), '/media/dives');
      expect(start('source_input', there: false), '/Users/diver');
      expect(start('never_set'), '/Users/diver');
      expect(start('hw_accel_switch'), '/Users/diver');
    });

    test('a dialog starts in its start folder until a folder is kept', () {
      final data = withField(defaultSettings(), 'source_input', '/media/dives');
      String start(
        String key, {
        String? folder = '/Users/diver/Pictures',
        Set<String> there = const {'/media/dives', '/Users/diver/Pictures'},
      }) => dialogDir(
        data,
        key,
        home: '/Users/diver',
        isFolder: there.contains,
        start: folder,
      );
      // The folder kept wins; the start folder before any is kept.
      expect(start('source_input'), '/media/dives');
      expect(start('never_set'), '/Users/diver/Pictures');
      // The kept one gone: the start folder.
      expect(
        start('source_input', there: {'/Users/diver/Pictures'}),
        '/Users/diver/Pictures',
      );
      // No start folder, or none there: home.
      expect(start('never_set', folder: null), '/Users/diver');
      expect(start('never_set', folder: ''), '/Users/diver');
      expect(start('never_set', there: const {}), '/Users/diver');
    });
  });
}
