// What the Log Viewer shows of a dive, against the Python app: the parity
// fixture made by tool/python_reference/log_viewer_fixture.py runs the
// page's functions on the 160 dives the parser fixtures hold as Python's
// own dumps.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/pages/log_viewer.dart';
import 'package:uwmedia_app/core/units/units.dart';

import '../../helpers/python_reference.dart';

void main() {
  final reference = jsonDecode(
    utf8.decode(
      gzip.decode(
        File(
          'test/fixtures/python_reference/pages/'
          'log_viewer_cases.json.gz',
        ).readAsBytesSync(),
      ),
    ),
  ) as Map<String, dynamic>;
  final constants = reference['constants'] as Map<String, dynamic>;

  test('the constants', () {
    expect(tableColumns, constants['table_columns']);
    expect(maxChartPoints, constants['max_chart_points']);
    expect(maxEventLines, constants['max_event_lines']);
    expect(formatNames, constants['format_names']);
    expect([
      for (final (attribute, label, _) in channels) [attribute, label],
    ], constants['channel_labels']);
    expect(ignoredAlerts, constants['ignored_alerts']);
    expect(lastFolderField, constants['last_folder_field']);
  });

  test('numbers, times and gas names', () {
    for (final [value, unit as String, digits as int, metric, imperial]
        in (reference['numbers'] as List<dynamic>).cast<List<dynamic>>()) {
      final number = (value as num?)?.toDouble();
      expect(
        displayNumber(number, UnitSystem.metric, unit: unit, digits: digits),
        metric,
        reason: '$value $unit',
      );
      expect(
        displayNumber(number, UnitSystem.imperial, unit: unit, digits: digits),
        imperial,
        reason: '$value $unit',
      );
    }
    for (final [seconds as int, minutes, clock]
        in (reference['minutes'] as List<dynamic>).cast<List<dynamic>>()) {
      expect(minutesText(seconds), minutes);
      expect(clockText(seconds), clock);
    }
    expect(minutesText(null), '');
    for (final [o2 as num, he as num, name]
        in (reference['mix_names'] as List<dynamic>).cast<List<dynamic>>()) {
      expect(viewerMixName(o2.toDouble(), he.toDouble()), name);
    }
  });

  test('every dive as the page shows it', () {
    final sources = <String, Map<String, dynamic>>{};
    final cases = jsonObjects(reference['cases']);
    expect(cases.length, 160);
    var imperial = 0;
    for (final c in cases) {
      final source = sources.putIfAbsent(
        c['source'] as String,
        () => pythonReference(c['source'] as String),
      );
      final dump =
          ((jsonObjects(source[c['key']])[c['index'] as int]['dives']
                  as List<dynamic>)[c['dive'] as int])
              as Map<String, dynamic>;
      final dive = Dive.fromJson(dump);
      final reverseMap = (c['reverse_map'] as Map<String, dynamic>)
          .cast<String, String>();
      final reason = '${c['source']} ${c['key']} ${c['index']}.${c['dive']}';

      for (final (name, units) in [
        ('metric', UnitSystem.metric),
        ('imperial', UnitSystem.imperial),
      ]) {
        final want = c[name] as Map<String, dynamic>?;
        if (want == null) {
          continue;
        }
        imperial += units == UnitSystem.imperial ? 1 : 0;
        expect(tableHeaders(units), want['headers']);
        expect(diveRow(dive, units).toJson(), want['row'], reason: reason);
        expect(
          diveDetails(dive, reverseMap, units).toJson(),
          want['details'],
          reason: '$reason ($name)',
        );
        final rows = sampleRows(dive, reverseMap, units);
        expect(rows, want['rows'], reason: '$reason ($name)');
        (want['filters'] as Map<String, dynamic>).forEach((text, kept) {
          expect(filterSampleRows(rows, text), [
            for (final i in (kept as List<dynamic>).cast<int>()) rows[i],
          ], reason: '$reason ($name) "$text"');
        });
      }

      // The limits made small, so that these short dives are thinned too.
      final small = c['small'] as Map<String, dynamic>;
      final details = diveDetails(
        dive,
        reverseMap,
        UnitSystem.metric,
        maxPoints: constants['small_chart'] as int,
        maxLines: constants['small_events'] as int,
      ).toJson();
      for (final key in small.keys) {
        expect(details[key], small[key], reason: '$reason small $key');
      }
    }
    expect(imperial, 56);
  });

  test('no filter keeps every line', () {
    final rows = [
      {'time': '10:00:00', 'gas': 'Nx32'},
      {'time': '10:00:10', 'gas': 'AIR'},
    ];
    expect(filterSampleRows(rows, null), rows);
    expect(filterSampleRows(rows, ''), rows);
    expect(filterSampleRows(rows, 'nx'), [rows.first]);
  });
}
