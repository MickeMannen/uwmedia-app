import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/model/dive.dart';
import 'package:uwmedia_app/core/model/dive_manager.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

void main() {
  test('arithmetic stays on the wall clock', () {
    final time = parseNaive('2026-03-29T01:59:59');
    expect(time, naive(2026, 3, 29, 1, 59, 59));
    // One second later is 02:00:00, also on a machine whose own zone skips
    // that hour.
    expect(
      formatNaive(time.add(const Duration(seconds: 1))),
      '2026-03-29T02:00:00',
    );
  });

  test('the text form is Python isoformat()', () {
    expect(formatNaive(naive(2026, 1, 1, 10)), '2026-01-01T10:00:00');
    for (final text in [
      '2026-01-01T10:01:35.250000',
      '2026-01-01T10:01:04.900000',
      '0987-12-31T23:59:59.000001',
    ]) {
      expect(formatNaive(parseNaive(text)), text);
    }
    expect(
      formatNaive(parseNaive('2026-01-01T10:00:00.5')),
      endsWith('.500000'),
    );
  });

  test('parseNaive refuses anything else', () {
    for (final text in [
      '2026-01-01T10:00:00Z',
      '2026-01-01T10:00:00+01:00',
      '2026-01-01T10:00:00-0500',
      '2026-01-01 10:00:00',
      '2026-01-01',
      '20260101T100000',
      '2026-02-30T10:00:00',
      '2026-01-01T10:00:00.1234567',
      '',
    ]) {
      expect(() => parseNaive(text), throwsFormatException, reason: text);
    }
  });

  test('a local DateTime is refused by the model', () {
    final local = DateTime(2026, 1, 1, 10);
    final start = naive(2026, 1, 1, 10);
    expect(
      () => Waypoint(timestamp: local, timeSinceStart: 0),
      throwsAssertionError,
    );
    expect(
      () => Dive(startTime: local, endTime: start, waypoints: []),
      throwsAssertionError,
    );
    final dive = Dive(startTime: start, endTime: start, waypoints: []);
    expect(() => dive.getWaypointAt(local), throwsAssertionError);
    expect(
      () => DiveManager().findDiveForTimestamp(local),
      throwsAssertionError,
    );
    expect(() => formatNaive(local), throwsAssertionError);
  });
}
