// "Shift all files" (lib/core/metadata/tag_editor.dart, spec §9.1): the
// tags one file gets for a shift, with or without a new offset, for a
// video and a photo, and when there is no date to shift.
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/metadata/tag_editor.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

void main() {
  const video = {
    'QuickTime:CreationDate': '2026:05:21 06:58:22+08:00',
    'QuickTime:CreateDate': '2026:05:20 22:58:22',
    'QuickTime:TrackCreateDate': '2026:05:20 22:58:22',
  };

  test('the shift as the page says it', () {
    expect(shiftText(-90), '-1 h 30 min');
    expect(shiftText(45), '+0 h 45 min');
    expect(shiftText(0), '+0 h 0 min');
  });

  test('a video keeps its offset and its UTC time moves along', () {
    expect(shiftUpdates(meta: video, path: '/m/a.MP4', shiftMinutes: -60), {
      'EXIF:DateTimeOriginal': '2026:05:21 05:58:22',
      'EXIF:CreateDate': '2026:05:21 05:58:22',
      'QuickTime:CreationDate': '2026:05:21 05:58:22+08:00',
      'QuickTime:CreateDate': '2026:05:20 21:58:22',
      'QuickTime:TrackCreateDate': '2026:05:20 21:58:22',
    });
  });

  test('a video given a new offset', () {
    expect(
      shiftUpdates(
        meta: video,
        path: '/m/a.mov',
        shiftMinutes: -60,
        tzMinutes: 120,
      ),
      {
        'EXIF:DateTimeOriginal': '2026:05:21 05:58:22',
        'EXIF:CreateDate': '2026:05:21 05:58:22',
        'QuickTime:CreationDate': '2026:05:21 05:58:22+02:00',
        'QuickTime:CreateDate': '2026:05:21 03:58:22',
        'QuickTime:TrackCreateDate': '2026:05:21 03:58:22',
        'QuickTime:Timezone': '+02:00',
        'QuickTime:TimeZone': '+02:00',
      },
    );
  });

  test('a video with only its UTC time: that moves by the shift', () {
    expect(
      shiftUpdates(
        meta: const {'QuickTime:CreateDate': '2026:05:20 22:58:22'},
        path: '/m/a.mp4',
        shiftMinutes: 90,
      ),
      {
        'EXIF:DateTimeOriginal': '2026:05:21 00:28:22',
        'EXIF:CreateDate': '2026:05:21 00:28:22',
        'QuickTime:CreateDate': '2026:05:21 00:28:22',
      },
    );
  });

  test('a photo: its local tags, and its offset only when one is given', () {
    const photo = {
      'EXIF:DateTimeOriginal': '2026:01:02 23:30:00',
      'EXIF:OffsetTimeOriginal': '+08:00',
    };
    expect(shiftUpdates(meta: photo, path: '/m/A.JPG', shiftMinutes: 45), {
      'EXIF:DateTimeOriginal': '2026:01:03 00:15:00',
      'EXIF:CreateDate': '2026:01:03 00:15:00',
    });
    expect(
      shiftUpdates(
        meta: photo,
        path: '/m/A.JPG',
        shiftMinutes: 0,
        tzMinutes: -330,
      ),
      {
        'EXIF:DateTimeOriginal': '2026:01:02 23:30:00',
        'EXIF:CreateDate': '2026:01:02 23:30:00',
        'EXIF:OffsetTime': '-05:30',
        'EXIF:OffsetTimeOriginal': '-05:30',
        'EXIF:OffsetTimeDigitized': '-05:30',
      },
    );
  });

  test('a date from the name or the file time; none at all', () {
    expect(
      shiftUpdates(
        meta: null,
        path: '/m/GX_20260905_143000.jpg',
        shiftMinutes: 60,
      )!['EXIF:DateTimeOriginal'],
      '2026:09:05 15:30:00',
    );
    expect(
      shiftUpdates(
        meta: const {},
        path: '/m/clip.png',
        shiftMinutes: -60,
        fileModified: naive(2026, 2, 3, 4, 5, 6),
      )!['EXIF:CreateDate'],
      '2026:02:03 03:05:06',
    );
    expect(
      shiftUpdates(meta: null, path: '/m/clip.png', shiftMinutes: 60),
      isNull,
    );
  });
}
