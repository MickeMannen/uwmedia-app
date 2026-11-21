// The dates of a page's source files, read in the background
// (lib/pages/shared/source_dates.dart).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';
import 'package:uwmedia_app/engine/desktop/ffmpeg_tools.dart';
import 'package:uwmedia_app/pages/shared/source_dates.dart';

void main() {
  // Each file's tags are given when the test lets its reading end.
  late Map<String, Completer<MediaTags?>> asked;
  late int reading;
  late int most;
  late int said;

  Future<MediaTags?> metadata(String path) async {
    reading++;
    most = reading > most ? reading : most;
    final tags = await (asked[path] = Completer<MediaTags?>()).future;
    reading--;
    return tags;
  }

  SourceDates dates() =>
      SourceDates(reader: () async => metadata, onRead: () => said++);

  MediaTags taken(int day) => {
    'EXIF:DateTimeOriginal':
        '2026:11:${day.toString().padLeft(2, '0')} 10:00:00',
  };

  setUp(() {
    asked = {};
    reading = 0;
    most = 0;
    said = 0;
  });

  test('four at a time, said once, a file read before not again', () async {
    final d = dates();
    final files = [for (var i = 1; i <= 6; i++) '/media/$i.jpg'];
    final load = d.load(files);
    await pumpEventQueue();
    expect(asked.keys, files.take(sourceDateReads));
    expect(d.dates, isNull);
    expect(d.reading, isTrue);
    for (var i = 1; i <= 6; i++) {
      // The last has no date to be had: it matches no dive.
      asked['/media/$i.jpg']!.complete(i == 6 ? null : taken(i));
      await pumpEventQueue();
    }
    await load;
    expect(most, sourceDateReads);
    expect(said, 1);
    // In the order asked for; the file with no date has none.
    expect(d.dates, {
      for (var i = 1; i <= 5; i++) '/media/$i.jpg': naive(2026, 11, i, 10),
      '/media/6.jpg': null,
    });
    expect(d.reading, isFalse);

    // Two of them again with a new one: only that one is read.
    asked.clear();
    final again = d.load(['/media/2.jpg', '/media/9.jpg', '/media/1.jpg']);
    await pumpEventQueue();
    expect(asked.keys, ['/media/9.jpg']);
    asked['/media/9.jpg']!.complete(taken(9));
    await again;
    expect(said, 2);
    expect(d.dates!.keys, ['/media/2.jpg', '/media/9.jpg', '/media/1.jpg']);
    expect(d.dates!.values, [
      naive(2026, 11, 2, 10),
      naive(2026, 11, 9, 10),
      naive(2026, 11, 1, 10),
    ]);

    // All read before: there at once, with nothing to say.
    await d.load(['/media/9.jpg']);
    expect(d.dates!.values, [naive(2026, 11, 9, 10)]);
    expect(said, 2);
  });

  test('a new load ends the one before; dispose ends it for good', () async {
    final d = dates();
    final first = d.load(['/media/a.jpg']);
    await pumpEventQueue();
    final second = d.load(['/media/b.jpg']);
    await pumpEventQueue();
    asked['/media/a.jpg']!.complete(taken(1));
    await first;
    expect(said, 0);
    expect(d.dates, isNull);
    asked['/media/b.jpg']!.complete(taken(2));
    await second;
    expect(said, 1);
    expect(d.dates!.values, [naive(2026, 11, 2, 10)]);

    final third = d.load(['/media/c.jpg']);
    await pumpEventQueue();
    d.dispose();
    asked['/media/c.jpg']!.complete(taken(3));
    await third;
    expect(said, 1);
  });

  test('no reader to be had: nothing is said of the files', () async {
    final d = SourceDates(
      reader: () async => throw const EngineException('exiftool not found'),
      onRead: () => said++,
    );
    await d.load(['/media/a.jpg']);
    expect(d.dates, isNull);
    expect(d.reading, isFalse);
    expect(said, 0);
  });
}
