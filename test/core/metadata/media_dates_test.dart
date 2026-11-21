// The date and timezone logic against the Python app: the cases of its
// tests/test_exif_coverage.py that feed hand-made metadata (the ones that
// run exiftool on files belong to the engine) and of tests/test_metadata.py,
// then the sweeps of the parity fixture made by
// tool/python_reference/dates_fixture.py.
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/metadata/tag_editor.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

import '../../helpers/python_reference.dart';

/// Python's `datetime.isoformat()` of an aware UTC time, as the fixture
/// has it.
String utcText(DateTime time) => '${formatNaive(time)}+00:00';

void main() {
  final reference = pythonReference('dates/dates_cases.json');

  group('tests/test_exif_coverage.py', () {
    test('test_parse_timezone', () {
      final cases = <Object, int>{
        '+02:00': 120,
        '02:00': 120,
        '+0530': 330,
        '-03:30': -210,
        '-00:00': 0,
        480: 480,
        -150.0: -150,
      };
      cases.forEach((value, minutes) {
        expect(parseTimezone(value), minutes, reason: '$value');
      });
    });

    test('test_parse_timezone_unparseable', () {
      for (final value in [null, '', 'Z', 'UTC', '+2']) {
        expect(parseTimezone(value), isNull, reason: '$value');
      }
    });

    test('test_parse_timezone_zero_minutes_is_utc', () {
      expect(parseTimezone(0), 0);
    });

    test('test_timezone_offset_from_date_difference', () {
      // CreationDate without an offset: local minus UTC, to 15 minutes
      expect(
        timezoneOffsetMinutes({
          'QuickTime:CreateDate': '2025:10:19 02:21:31',
          'QuickTime:CreationDate': '2025:10:19 07:52:20',
        }),
        330,
      );
    });

    test('test_timezone_offset_negative_difference_ungrouped_keys', () {
      expect(
        timezoneOffsetMinutes({
          'CreateDate': '2025:10:19 02:00:00',
          'CreationDate': '2025:10:18 22:00:00',
        }),
        -240,
      );
    });

    test('test_timezone_offset_sony_timezone_fallback', () {
      // Dates unreadable: the TimeZone tag decides
      expect(
        timezoneOffsetMinutes({
          'QuickTime:CreateDate': 'garbage',
          'QuickTime:CreationDate': 'also garbage',
          'QuickTime:TimeZone': '-05:00',
        }),
        -300,
      );
      expect(timezoneOffsetMinutes({'Timezone': '+09:30'}), 570);
    });

    test('test_timezone_offset_nothing_found', () {
      expect(timezoneOffsetMinutes(null), isNull);
      expect(timezoneOffsetMinutes({'QuickTime:TimeZone': 'local'}), isNull);
    });

    test('test_standardized_creation_date_falls_back_to_create_date', () {
      // CreationDate without an offset can't be converted; CreateDate is UTC
      final want = DateTime.utc(2025, 10, 19, 2, 21, 31);
      expect(
        standardizedCreationDate({
          'CreationDate': '2025:10:19 10:21:31',
          'CreateDate': '2025:10:19 02:21:31',
        }),
        want,
      );
      expect(
        standardizedCreationDate({
          'QuickTime:CreationDate': 'broken',
          'QuickTime:CreateDate': '2025:10:19 02:21:31',
        }),
        want,
      );
    });

    test('test_standardized_creation_date_errors', () {
      expect(
        () => standardizedCreationDate(null),
        throwsA(
          isFormatException.having(
            (e) => e.message,
            'message',
            contains('Could not extract'),
          ),
        ),
      );
      expect(
        () => standardizedCreationDate({'File:FileName': 'x.mp4'}),
        throwsA(
          isFormatException.having(
            (e) => e.message,
            'message',
            contains('No valid creation date'),
          ),
        ),
      );
    });

    test('test_standardized_creation_date_with_subseconds', () {
      expect(
        standardizedCreationDate({
          'QuickTime:CreationDate': '2025:10:19 10:21:31.98+08:00',
        }),
        DateTime.utc(2025, 10, 19, 2, 21, 31),
      );
    });

    test('test_local_creation_date_subseconds_in_string', () {
      expect(
        localCreationDate({
          'EXIF:DateTimeOriginal': '2025:12:03 09:15:48.05',
          'EXIF:SubSecTimeOriginal': '999', // the string's own wins
        }),
        naive(2025, 12, 3, 9, 15, 48, 50),
      );
    });

    test('test_local_creation_date_other_subsec_tags', () {
      expect(
        localCreationDate({
          'DateTimeOriginal': '2025:12:03 09:15:48',
          'SubSecTime': 7,
        }),
        naive(2025, 12, 3, 9, 15, 48, 700),
      );
      // A subsecond tag with no digits is ignored
      expect(
        localCreationDate({
          'EXIF:CreateDate': '2025:12:03 09:15:48',
          'EXIF:SubSecTimeDigitized': '  ',
        }),
        naive(2025, 12, 3, 9, 15, 48),
      );
    });

    test('test_local_creation_date_from_utc_and_timezone', () {
      // No local date tag (or an unreadable one): UTC CreateDate shifted
      // by TimeZone
      expect(
        localCreationDate({
          'QuickTime:CreationDate': '0000:00:00 00:00:00',
          'QuickTime:CreateDate': '2025:10:19 22:21:31',
          'TimeZone': '+08:00',
        }),
        naive(2025, 10, 20, 6, 21, 31),
      );
      // Without a time zone the UTC time is returned as is
      expect(
        localCreationDate({'CreateDate': '2025:10:19 22:21:31'}),
        naive(2025, 10, 19, 22, 21, 31),
      );
    });

    test('test_local_creation_date_falls_back_to_mtime', () {
      // Zero CreateDate (ffmpeg's default) or no dates at all: the file's
      // modification time
      final mtime = naive(2024, 2, 29, 12, 30, 15);
      for (final meta in [
        {'File:FileName': 'notes.txt'},
        {'QuickTime:CreateDate': '0000:00:00 00:00:00'},
        {'QuickTime:CreateDate': '2025:99:99 00:00:00'},
      ]) {
        expect(localCreationDate(meta, fileModified: mtime), mtime);
      }
    });

    test('test_local_creation_date_errors', () {
      expect(
        () => localCreationDate(null, fileModified: naive(2024)),
        throwsA(
          isFormatException.having(
            (e) => e.message,
            'message',
            contains('Could not extract'),
          ),
        ),
      );
      // Metadata without dates and a file that is gone
      expect(
        () => localCreationDate({'File:FileName': 'x.mp4'}),
        throwsA(
          isFormatException.having(
            (e) => e.message,
            'message',
            contains('No valid creation date'),
          ),
        ),
      );
    });
  });

  group('tests/test_metadata.py', () {
    test('test_dji_timezone_calculation', () {
      final calculated = calculateDjiDatetimes(
        'DJI_20260502110658_0002_D_A001.MP4',
        {
          'QuickTime:OriginalFilePath': '/mnt/media_rw/sd/DCIM/DJI_001/DJI_20260502100659_0002_D_A001.MP4',
          'QuickTime:CreateDate': '2026:05:02 03:06:59',
          'CreateDate': '2026:05:02 03:06:59',
        },
      );
      expect(calculated, {
        'QuickTime:CreationDate': '2026:05:02 10:06:59+07:00',
        'QuickTime:CreateDate': '2026:05:02 03:06:59',
        'EXIF:DateTimeOriginal': '2026:05:02 10:06:59',
        'EXIF:CreateDate': '2026:05:02 10:06:59',
      });
    });

    test('test_batch_timezone_setting', () {
      // The photo of the Python test: DateTimeOriginal with subseconds.
      final updates = batchTimezoneUpdates(
        meta: {
          'EXIF:DateTimeOriginal': '2025:12:03 09:15:48',
          'EXIF:SubSecTimeOriginal': 980,
        },
        path: '/tmp/test_photo.jpg',
        mode: tzModeKeepLocal,
        tzMinutes: parseTimezone('-05:00')!,
      );
      expect(updates, {
        'EXIF:DateTimeOriginal': '2025:12:03 09:15:48',
        'EXIF:CreateDate': '2025:12:03 09:15:48',
        'EXIF:OffsetTime': '-05:00',
        'EXIF:OffsetTimeOriginal': '-05:00',
        'EXIF:OffsetTimeDigitized': '-05:00',
      });
    });

    test('test_metadata_viewer_filter', () {
      final rows = [
        (tag: 'EXIF:DateTimeOriginal', value: '2026:05:21 06:58:22'),
        (tag: 'EXIF:Make', value: 'Sony'),
        (tag: 'EXIF:Model', value: 'ILCE-6700'),
        (tag: 'QuickTime:CreateDate', value: '2026:05:20 22:58:22'),
      ];
      expect(filterMetadataRows(rows, 'Sony'), hasLength(1));
      expect(filterMetadataRows(rows, ''), hasLength(4));
    });

    test('the file time stands in when the tags and the name have no date', () {
      final mtime = naive(2024, 2, 29, 12, 30, 15);
      for (final mode in tzModeOptions) {
        expect(
          batchTimezoneUpdates(
            meta: null,
            path: 'clip.mp4',
            mode: mode,
            tzMinutes: 60,
            fileModified: mtime,
          )!['QuickTime:CreationDate'],
          '2024:02:29 12:30:15+01:00',
        );
      }
    });

    test('localTzOffsetString', () {
      expect(localTzOffsetString(const Duration(hours: 8)), '+08:00');
      expect(localTzOffsetString(const Duration(minutes: -210)), '-03:30');
      expect(localTzOffsetString(Duration.zero), '+00:00');
    });
  });

  group('parity with Python', () {
    test('parseTimezone', () {
      final cases = (reference['parse_timezone'] as List<dynamic>)
          .cast<List<dynamic>>();
      expect(cases.length, greaterThan(30));
      for (final [value, result] in cases) {
        final [status, want] = result as List<dynamic>;
        if (status == 'raise') {
          expect(
            () => parseTimezone(value),
            throwsFormatException,
            reason: '$value',
          );
        } else {
          expect(parseTimezone(value), want, reason: '$value');
        }
      }
    });

    test('the offset, the UTC time and the local time of invented tags', () {
      final cases = jsonObjects(reference['metas']);
      expect(cases.length, greaterThan(70));
      for (final c in cases) {
        final meta = c['meta'] as Map<String, dynamic>?;
        final [offsetStatus, offset] = c['timezone_offset'] as List<dynamic>;
        // Python raises on a Timezone tag of a day or more; no answer here.
        expect(
          timezoneOffsetMinutes(meta),
          offsetStatus == 'raise' ? isNull : offset,
          reason: 'offset of $meta',
        );

        final [utcStatus, utc] = c['standardized'] as List<dynamic>;
        if (utcStatus == 'raise') {
          expect(
            () => standardizedCreationDate(meta),
            throwsFormatException,
            reason: 'UTC of $meta',
          );
        } else {
          final got = standardizedCreationDate(meta);
          expect(got.isUtc, isTrue);
          expect(utcText(got), utc, reason: 'UTC of $meta');
        }

        final [localStatus, local] = c['local'] as List<dynamic>;
        if (localStatus == 'raise') {
          expect(
            () => localCreationDate(meta),
            throwsFormatException,
            reason: 'local of $meta',
          );
        } else {
          expect(
            formatNaive(localCreationDate(meta)),
            local,
            reason: 'local of $meta',
          );
        }
      }
    });

    test('the timezone tags after a copy', () {
      final cases = jsonObjects(reference['copy_all']);
      expect(cases.length, 90);
      for (final c in cases) {
        final meta = c['meta'] as Map<String, dynamic>?;
        final forced = c['forced'] as int?;
        final [status, want] = c['want'] as List<dynamic>;
        if (status == 'raise') {
          expect(
            () => timezoneTagsAfterCopy(meta, forcedTzMinutes: forced),
            throwsFormatException,
            reason: '$c',
          );
        } else {
          expect(
            timezoneTagsAfterCopy(meta, forcedTzMinutes: forced),
            want,
            reason: '$c',
          );
        }
      }
    });

    test('the tag guide and the lists of the page', () {
      expect([
        for (final g in tagGuide)
          {'tag': g.tag, 'tz': g.tz, 'example': g.example, 'hint': g.hint},
      ], reference['tag_guide']);
      expect(tagEditorExtensions.toList()..sort(), reference['extensions']);
      expect(tzModeOptions, reference['tz_modes']);
      expect(tzOffsets, reference['tz_offsets']);
    });

    test('calculateDjiDatetimes', () {
      final cases = jsonObjects(reference['dji']);
      expect(cases.length, 66);
      for (final c in cases) {
        expect(
          calculateDjiDatetimes(
            c['name'] as String,
            c['tags'] as Map<String, dynamic>,
          ),
          c['want'],
          reason: '$c',
        );
      }
    });

    test('parseDateFromFilename', () {
      for (final [name, want]
          in (reference['filename_dates'] as List<dynamic>)
              .cast<List<dynamic>>()) {
        final got = parseDateFromFilename('/media/$name');
        expect(got == null ? null : formatNaive(got), want, reason: '$name');
      }
    });

    test('batchTimezoneUpdates', () {
      final cases = jsonObjects(reference['batch']);
      expect(cases.length, 760);
      for (final c in cases) {
        final [status, want] = c['want'] as List<dynamic>;
        expect(status, 'ok');
        expect(
          batchTimezoneUpdates(
            meta: c['meta'] as Map<String, dynamic>?,
            path: '/gone/${c['name']}',
            mode: c['mode'] as String,
            tzMinutes: c['minutes'] as int,
          ),
          want == false ? isNull : want,
          reason: '$c',
        );
      }
    });

    test('filterMetadataRows', () {
      final filter = reference['filter'] as Map<String, dynamic>;
      final rows = [
        for (final row in jsonObjects(filter['rows']))
          (tag: row['tag'] as String, value: row['value']),
      ];
      for (final [text, want]
          in (filter['filters'] as List<dynamic>).cast<List<dynamic>>()) {
        expect(
          [
            for (final row in filterMetadataRows(rows, text as String?))
              row.tag,
          ],
          want,
          reason: '$text',
        );
      }
    });
  });
}
