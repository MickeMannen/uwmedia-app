// The time a Color run has left (spec §10.97): by the files' sizes, the
// pace of the files that ended last, and a video's own encoding.
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/pages/run_estimate.dart';
import 'package:uwmedia_app/core/pages/run_timing.dart';

void main() {
  var now = 0.0;
  setUp(() => now = 0);
  RunFile video(double weight) => (weight: weight, video: true);
  RunFile photo(double weight) => (weight: weight, video: false);
  RunEstimate of(Map<String, RunFile> files, {int? total}) =>
      RunEstimate(() => now, files, total: total);

  test('one video: nothing while it is looked at, then its encoding', () {
    final run = of({'a.mp4': video(500)})..begun('a.mp4');
    now = 10;
    run.progress('a.mp4', 5);
    expect(run.remaining(), isNull);
    // The encoding begins after 20 seconds, however small the share of
    // the percent before it is.
    now = 20;
    run.progress('a.mp4', 14);
    expect(run.remaining(), isNull);
    // 43 points in 20 seconds: 43 more take 20.
    now = 40;
    run.progress('a.mp4', 57);
    expect(run.remaining(), closeTo(20, 0.001));
    // Between two reports the clock goes on.
    now = 45;
    expect(run.remaining(), closeTo(15, 0.001));
    now = 60;
    run.ended('a.mp4', counted: true);
    expect(run.remaining(), 0);
  });

  test('a file counts by its size', () {
    final run = of({'a.mp4': video(100), 'b.mp4': video(900)})..begun('a.mp4');
    now = 10;
    run.ended('a.mp4', counted: true);
    // Ten seconds for 100: the nine times larger one takes 90, not ten.
    expect(run.remaining(), closeTo(90, 0.001));
    run.begun('b.mp4');
    now = 20;
    run.progress('b.mp4', 7);
    // Half of what comes before the encoding is done; no encoding has
    // been seen, so that is taken as 14 % of the file.
    expect(run.remaining(), closeTo(90 * 0.14 * 0.5 + 90 * 0.86, 0.001));
  });

  test('the pace is that of the files that ended last', () {
    final names = [for (var i = 0; i < 12; i++) 'p$i.jpg'];
    final run = of({for (final name in names) name: photo(10)});
    // The first photo is slow (the run's start), the others take 2 s.
    for (final (i, name) in names.take(recentFiles + 1).indexed) {
      run.begun(name);
      now += i == 0 ? 60 : 2;
      run.ended(name, counted: true);
    }
    // Three are left, at the pace of the last eight: 2 s each.
    expect(run.remaining(), closeTo(6, 0.001));
  });

  test('several at once: the time is shared among them', () {
    final names = [for (var i = 0; i < 12; i++) 'p$i.jpg'];
    final run = of({for (final name in names) name: photo(10)});
    names.take(4).forEach(run.begun);
    expect(run.remaining(), isNull);
    now = 8;
    for (final name in names.take(4)) {
      run.ended(name, counted: true);
    }
    names.skip(4).take(4).forEach(run.begun);
    // Four in work with 8 s each to go, four waiting: 64 s of work on
    // four lanes.
    expect(run.remaining(), closeTo(16, 0.001));
    now = 12;
    expect(run.remaining(), closeTo(12, 0.001));
  });

  test('the last file alone is not shared', () {
    final run = of({'a.jpg': photo(10), 'b.jpg': photo(10), 'c.jpg': photo(30)})
      ..begun('a.jpg')
      ..begun('b.jpg');
    now = 4;
    run
      ..ended('a.jpg', counted: true)
      ..ended('b.jpg', counted: true)
      ..begun('c.jpg');
    expect(run.remaining(), closeTo(12, 0.001));
  });

  test('a skipped or failed file says nothing of the others', () {
    final run = of({
      'a.mp4': video(100),
      'b.mp4': video(100),
      'c.mp4': video(100),
    })..begun('a.mp4');
    now = 0.1;
    run.ended('a.mp4', counted: false);
    expect(run.remaining(), isNull);
    run.begun('b.mp4');
    now = 30.1;
    run.ended('b.mp4', counted: true);
    expect(run.remaining(), closeTo(30, 0.001));
  });

  test('videos and photos have each their pace; a kind not seen yet goes by '
      'the other', () {
    final run = of({
      'a.jpg': photo(10),
      'b.jpg': photo(10),
      'c.mp4': video(1000),
      'd.mp4': video(1000),
    })..begun('a.jpg');
    now = 5;
    run.ended('a.jpg', counted: true);
    // 0.5 s a unit for all of them, for want of a video's pace.
    expect(run.remaining(), closeTo(5 + 500 + 500, 0.001));
    run.begun('c.mp4');
    now = 105;
    run.ended('c.mp4', counted: true);
    expect(run.remaining(), closeTo(5 + 100, 0.001));
  });

  test('how long a video is looked at is measured, not 14 %', () {
    final run = of({'a.mp4': video(100), 'b.mp4': video(100)})..begun('a.mp4');
    now = 40;
    run.progress('a.mp4', 14);
    now = 100;
    run.ended('a.mp4', counted: true);
    run.begun('b.mp4');
    // 40 of the first one's 100 seconds came before its encoding.
    now = 120;
    run.progress('b.mp4', 7);
    expect(run.remaining(), closeTo(100 * 0.4 * 0.5 + 100 * 0.6, 0.001));
  });

  test('files the run knows of beyond the list count as the mean', () {
    final run = of({'a.jpg': photo(10)}, total: 3)..begun('a.jpg');
    now = 4;
    run.ended('a.jpg', counted: true);
    expect(run.remaining(), closeTo(8, 0.001));
    run.begun('x.jpg');
    expect(run.remaining(), closeTo(8, 0.001));
  });

  test("the timer's line with the run's own estimate", () {
    final timer = RunTimer(() => now)..start();
    now = 3;
    expect(timer.textWithLeft(200), 'Elapsed 0:03');
    now = 30;
    expect(timer.textWithLeft(null), 'Elapsed 0:30');
    expect(timer.textWithLeft(41), 'Elapsed 0:30 · about 0:41 left');
    expect(timer.textWithLeft(571), 'Elapsed 0:30 · about 9:40 left');
    timer.stop();
    expect(timer.textWithLeft(571), 'Finished in 0:30');
  });
}
