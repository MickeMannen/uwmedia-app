// The dives a page's files are matched to, and what the page says of
// them (owner, 2026-11-17).
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/model/dive_manager.dart';
import 'package:uwmedia_app/core/pages/dive_matches.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

Dive _dive(DateTime start, String? log) => Dive(
  startTime: start,
  endTime: start.add(const Duration(minutes: 40)),
  waypoints: const [],
  logFilename: log,
);

// Files named by their place in [times].
Map<String, DateTime?> _files(List<DateTime?> times) => {
  for (final (i, time) in times.indexed) '/media/$i.jpg': time,
};

void main() {
  final morning = _dive(naive(2026, 10, 29, 9, 30), '520 Arild.fit');
  final noon = _dive(naive(2026, 10, 29, 12), '521 Arild.fit');
  final manager = DiveManager()..addDives([noon, morning]);

  test('each file to its dive, a dive once, those with none counted', () {
    final matches = matchDives(
      manager,
      _files([
        naive(2026, 10, 29, 12, 5),
        naive(2026, 10, 29, 12, 30),
        // Within the half hour before the dive, as a run takes it.
        naive(2026, 10, 29, 9, 10),
        naive(2026, 10, 29, 11),
        // No date to be had: no dive.
        null,
      ]),
    );
    // By start, not in the order found.
    expect(matches.dives, [morning, noon]);
    expect((matches.files, matches.unmatched), (5, 2));
    // A row for each file, in the files' order.
    expect(
      [for (final row in matches.rows) (row.file, row.dive)],
      [
        ('/media/0.jpg', noon),
        ('/media/1.jpg', noon),
        ('/media/2.jpg', morning),
        ('/media/3.jpg', null),
        ('/media/4.jpg', null),
      ],
    );
    expect(matches.rows[3].time, naive(2026, 10, 29, 11));
    expect(matches.rows[4].time, isNull);
    expect(diveMatchLabel(matches), 'Dive logs: 2 of 5 not matched');
    expect(
      diveMatchText(matches),
      '2 dive logs: 2026-10-29 09:30 (520 Arild.fit), '
      '2026-10-29 12:00 (521 Arild.fit). 2 of 5 files match no dive log.',
    );
  });

  test('what the button says', () {
    final none = matchDives(manager, const {});
    expect(diveMatchLabel(none), '');
    expect(diveMatchText(none), '');
    final one = matchDives(manager, _files([naive(2026, 10, 29, 12, 5)]));
    expect(diveMatchLabel(one), 'Dive log: matched');
    expect(diveMatchText(one), 'Dive log: 2026-10-29 12:00 (521 Arild.fit)');
    final lost = matchDives(manager, _files([naive(2025)]));
    expect(diveMatchLabel(lost), 'Dive log: not matched');
    expect(diveMatchText(lost), 'No dive log matches this file');
    final both = matchDives(manager, _files([naive(2025), naive(2024)]));
    expect(diveMatchLabel(both), 'Dive logs: none of 2 matched');
    expect(diveMatchText(both), 'No dive log matches these 2 files');
    expect(
      diveMatchLabel(
        matchDives(
          manager,
          _files([naive(2026, 10, 29, 12, 5), naive(2026, 10, 29, 9, 40)]),
        ),
      ),
      'Dive logs: all 2 matched',
    );
    // A dive that is not from a file has no name; more than three dives
    // are counted.
    final many = DiveManager()
      ..addDives([
        for (var day = 1; day <= 5; day++)
          _dive(naive(2026, 11, day, 10), null),
      ]);
    expect(diveLabel(many.dives.values.first), '2026-11-01 10:00');
    expect(
      diveMatchText(
        matchDives(
          many,
          _files([
            for (var day = 1; day <= 5; day++) naive(2026, 11, day, 10, 5),
          ]),
        ),
      ),
      '5 dive logs: 2026-11-01 10:00, 2026-11-02 10:00, 2026-11-03 10:00 '
      'and 2 more',
    );
  });
}
