// The port's own MP4 date reader and writer against exiftool, called the
// way the Python app calls it: the fixture made by
// tool/python_reference/mp4_fixture.py holds small synthetic files, what
// exiftool reads from them, and what it reads after writing date tags to
// them. When exiftool and ffmpeg are installed, the files the port writes
// are also read back with exiftool and decoded with ffmpeg.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/metadata/media_dates.dart';
import 'package:uwmedia_app/core/metadata/mp4_dates.dart';
import 'package:uwmedia_app/core/util/naive_time.dart';

import '../../helpers/python_reference.dart';
import '../../helpers/sony_mp4.dart';

bool hasTool(String name) {
  try {
    return Process.runSync(name, ['-version']).exitCode == 0 ||
        Process.runSync(name, ['-ver']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// The tags of [tags] the port writes: QuickTime's, the timezone tags
/// aside.
Map<String, String> writable(Map<String, dynamic> tags) => {
  for (final MapEntry(:key, :value) in tags.entries)
    if (key.startsWith('QuickTime:') && !key.toLowerCase().endsWith('zone'))
      key: value as String,
};

void main() {
  final reference = pythonReference('mp4/mp4_cases.json');
  final sources = reference['sources'] as Map<String, dynamic>;
  final writeSets = reference['write_sets'] as Map<String, dynamic>;
  Uint8List bytesOf(String name) => base64.decode(
    (sources[name] as Map<String, dynamic>)['base64'] as String,
  );
  Mp4Movie movie(String name) => Mp4Movie.read(MemoryBytes(bytesOf(name)));

  group('reading', () {
    test('every file gives the tags exiftool reads', () {
      expect(sources.length, 19);
      sources.forEach((name, source) {
        expect(
          readMp4Tags(MemoryBytes(bytesOf(name))),
          (source as Map<String, dynamic>)['tags'],
          reason: name,
        );
      });
    });

    test('a Sony camera\'s timezone, as exiftool reads it', () {
      // 2025-10-19 02:21:31 UTC, in seconds from 1904.
      const created = 1760840491 + 2082844800;
      for (final (minutes, text) in [(480, '+08:00'), (-210, '-03:30')]) {
        final bytes = sonyMp4(created: created, zoneMinutes: minutes);
        final tags = readMp4Tags(MemoryBytes(bytes));
        expect(tags['QuickTime:CreateDate'], '2025:10:19 02:21:31');
        expect(tags['QuickTime:TimeZone'], text);
        expect(timezoneOffsetMinutes(tags), minutes);
        expect(
          localCreationDate(tags),
          naive(2025, 10, 19, 2, 21, 31).add(Duration(minutes: minutes)),
        );
        if (hasTool('exiftool')) {
          final dir = Directory.systemTemp.createTempSync('uwmedia_sony_');
          addTearDown(() => dir.deleteSync(recursive: true));
          final file = File('${dir.path}/clip.mp4')..writeAsBytesSync(bytes);
          final read = Process.runSync('exiftool', [
            '-s3',
            '-QuickTime:TimeZone',
            '-QuickTime:CreateDate',
            file.path,
          ]);
          expect(
            // Windows ends exiftool's lines with \r\n.
            const LineSplitter().convert((read.stdout as String).trim()),
            unorderedEquals([text, '2025:10:19 02:21:31']),
          );
        }
      }
    });

    test('the tags feed the date logic like exiftool\'s own', () {
      final tags = movie('mov_keys').tags;
      expect(localCreationDate(tags), naive(2025, 10, 19, 10, 21, 31));
      expect(
        standardizedCreationDate(tags),
        DateTime.utc(2025, 10, 19, 2, 21, 31),
      );
      // "0000:…" counts as a CreateDate, so the offset at the end of
      // CreationDate is read (spec §10.23 b).
      expect(timezoneOffsetMinutes(tags), 480);
      expect(
        localCreationDate(movie('ffmpeg_creation_time').tags),
        naive(2025, 10, 19, 2, 21, 31),
      );
    });

    test('the keys as stored', () {
      expect(movie('exiftool_keys').keys, {
        'com.apple.quicktime.creationdate': '2025-10-19T10:21:31.98-0330',
        'com.apple.quicktime.make': 'Sony',
        'com.apple.quicktime.model': 'ILCE-6700',
        'com.apple.quicktime.software': 'ILCE-6700 v2.00',
      });
      expect(movie('bare').keys, isEmpty);
    });

    test('a file that is not an MP4 is refused', () {
      for (final bytes in [
        Uint8List(0),
        Uint8List.fromList(utf8.encode('not a film at all, just text')),
        Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 74, 70, 73, 70]),
        Uint8List.sublistView(bytesOf('bare'), 0, 1200), // cut off
        Uint8List.sublistView(bytesOf('bare'), 0, 40), // no moov
      ]) {
        expect(
          () => Mp4Movie.read(MemoryBytes(bytes)),
          throwsA(isA<Mp4Exception>()),
        );
      }
    });

    test('only the headers and the moov box are read', () {
      final bytes = bytesOf('bare');
      final reads = <(int, int)>[];
      final movie = Mp4Movie.read(_Watched(bytes, reads));
      final mdat = movie.boxes.firstWhere((box) => box.type == 'mdat');
      for (final (offset, count) in reads) {
        final inData =
            offset < mdat.offset + mdat.size &&
            offset + count > mdat.offset + 16;
        expect(inData, isFalse, reason: 'read $count at $offset');
      }
    });
  });

  group('the reviewed media fixtures (tests/test_exif_coverage.py)', () {
    Mp4Movie clip(String name) => Mp4Movie.read(
      MemoryBytes(File('test/fixtures/media/video/$name').readAsBytesSync()),
    );
    final sony = clip('h264_10bit_422_720p_2s.mp4');
    final dji = clip('hevc_10bit_420_720p_2s.mp4');

    test('test_get_metadata_reads_grouped_tags', () {
      expect(sony.tags['QuickTime:CreationDate'], '2025:10:19 10:21:31+08:00');
      expect(sony.tags['QuickTime:CreateDate'], '2025:10:19 02:21:31');
    });

    test('test_timezone_offset_from_fixtures', () {
      expect(timezoneOffsetMinutes(sony.tags), 480);
      expect(timezoneOffsetMinutes(dji.tags), 420);
    });

    test('test_standardized_creation_date_from_fixtures', () {
      expect(
        standardizedCreationDate(sony.tags),
        DateTime.utc(2025, 10, 19, 2, 21, 31),
      );
      expect(
        standardizedCreationDate(dji.tags),
        DateTime.utc(2026, 5, 2, 3, 6, 59),
      );
    });

    test('test_local_creation_date_from_fixtures', () {
      expect(localCreationDate(sony.tags), naive(2025, 10, 19, 10, 21, 31));
      expect(localCreationDate(dji.tags), naive(2026, 5, 2, 10, 6, 59));
    });

    test('test_copy_all_forced_negative_offset, with the port\'s writer', () {
      // What copy_all writes for a forced -03:30, put into the clip.
      final tags = timezoneTagsAfterCopy(sony.tags, forcedTzMinutes: -210)!;
      expect(tags['QuickTime:CreationDate'], '2025:10:19 10:21:31-03:30');
      final rewrite = sony.write(tags);
      expect(rewrite.ignored, ['QuickTime:Timezone', 'QuickTime:TimeZone']);
      final after = Mp4Movie.read(MemoryBytes(rewrite.apply(sony.source)));
      expect(timezoneOffsetMinutes(after.tags), -210);
      expect(localCreationDate(after.tags), naive(2025, 10, 19, 10, 21, 31));
      // Same length of text: nothing moved.
      expect(rewrite.keepsOffsets, isTrue);
      expect(after.chunkOffsets, sony.chunkOffsets);
    });
  });

  group('writing', () {
    final cases = jsonObjects(reference['writes']);
    final exiftool = hasTool('exiftool');
    final ffmpeg = hasTool('ffmpeg');

    test('every write reads back as after exiftool\'s', () {
      expect(cases.length, 133);
      for (final c in cases) {
        final name = c['source'] as String;
        final tags = writeSets[c['write']] as Map<String, dynamic>;
        final source = MemoryBytes(bytesOf(name));
        final before = Mp4Movie.read(source);
        final rewrite = before.write(tags.cast<String, String>());
        expect(
          rewrite.ignored,
          tags.keys.where((key) => !writable(tags).containsKey(key)),
          reason: '$name ${c['write']}',
        );
        final written = rewrite.apply(source);
        expect(written.length, rewrite.length);
        final after = Mp4Movie.read(MemoryBytes(written));
        expect(after.tags, c['tags'], reason: '$name ${c['write']}');

        // The picture and sound data is where the tracks say it is.
        final was = before.chunkOffsets;
        final now = after.chunkOffsets;
        expect(now.length, was.length);
        for (var t = 0; t < was.length; t++) {
          expect(now[t].length, was[t].length);
          for (var i = 0; i < was[t].length; i++) {
            expect(
              written.sublist(now[t][i], now[t][i] + 32),
              source.bytes.sublist(was[t][i], was[t][i] + 32),
              reason: '$name ${c['write']}: chunk $i of track $t',
            );
          }
        }
        // Everything but the moov box is the source's, byte for byte.
        for (final box in before.boxes.where((b) => b.type == 'mdat')) {
          final moved = after.boxes.firstWhere((b) => b.type == 'mdat');
          expect(
            written.sublist(moved.offset, moved.offset + moved.size),
            source.bytes.sublist(box.offset, box.offset + box.size),
          );
        }
      }
    });

    test('header dates are changed where they are', () {
      for (final name in ['bare', 'faststart', 'two_tracks', 'version_1']) {
        final source = MemoryBytes(bytesOf(name));
        final rewrite = Mp4Movie.read(source).write({
          'QuickTime:CreateDate': '2026:05:20 22:58:22',
          'TrackModifyDate': '2026:05:20 22:58:25',
          'QuickTime:MediaCreateDate': zeroDate,
        });
        expect(rewrite.keepsOffsets, isTrue, reason: name);
        expect(rewrite.length, source.length);
        // Applying the patches to the file gives the same bytes.
        final patched = Uint8List.fromList(source.bytes);
        for (final (offset, bytes) in rewrite.patches) {
          patched.setRange(offset, offset + bytes.length, bytes);
        }
        expect(patched, rewrite.apply(source));
        final differing = [
          for (var i = 0; i < patched.length; i++)
            if (patched[i] != source.bytes[i]) i,
        ];
        expect(differing, isNotEmpty);
        expect(differing.length, lessThan(40));
      }
    });

    test('a new key at the end of the file leaves the rest alone', () {
      final source = MemoryBytes(bytesOf('bare'));
      final before = Mp4Movie.read(source);
      final rewrite = before.write({
        'QuickTime:CreationDate': '2025:10:19 10:21:31+08:00',
      });
      expect(rewrite.keepsOffsets, isTrue);
      expect(rewrite.length, greaterThan(source.length));
      final moov = before.boxes.last;
      expect(moov.type, 'moov');
      expect(rewrite.patches.single.$1, moov.offset);
    });

    test('a new key before the picture data moves it, offsets and all', () {
      for (final name in ['faststart', 'two_tracks_faststart']) {
        final source = MemoryBytes(bytesOf(name));
        final before = Mp4Movie.read(source);
        final rewrite = before.write({
          'QuickTime:CreationDate': '2025:10:19 10:21:31+08:00',
        });
        expect(rewrite.keepsOffsets, isFalse, reason: name);
        final after = Mp4Movie.read(MemoryBytes(rewrite.apply(source)));
        final delta = rewrite.length - source.length;
        expect(delta, greaterThan(0));
        expect(after.chunkOffsets, [
          for (final track in before.chunkOffsets)
            [for (final offset in track) offset + delta],
        ]);
      }
    });

    test('a free box after the moov box takes a change of size', () {
      // exiftool's own output has moov before the data; give it room.
      final original = bytesOf('exiftool_dates');
      final first = Mp4Movie.read(MemoryBytes(original));
      final moov = first.boxes.firstWhere((box) => box.type == 'moov');
      final end = moov.offset + moov.size;
      final room = Uint8List(64)
        ..buffer.asByteData().setUint32(0, 64)
        ..setRange(4, 8, ascii.encode('free'));
      final padded = Uint8List.fromList([
        ...original.sublist(0, end),
        ...room,
        ...original.sublist(end),
      ]);
      // The chunk offsets of this hand-made file are 64 short; only the
      // layout matters here.
      final source = MemoryBytes(padded);
      final movie = Mp4Movie.read(source);
      for (final (value, kept) in [
        ('2025:10:19 10:21:31.123456+08:00', true), // 7 longer: no room
        ('2025:10:19 10:21:31.12345678+08:00', true), // 9 longer
        ('2025:10:19 10:21:31Z', true), // 4 shorter
      ]) {
        final rewrite = movie.write({'QuickTime:CreationDate': value});
        final delta = value.length - '2025:10:19 10:21:31+08:00'.length;
        if (delta == 7) {
          // 64 - 7 leaves a free box of 57: fine.
        }
        expect(rewrite.keepsOffsets, kept, reason: value);
        expect(rewrite.length, padded.length, reason: value);
        final after = Mp4Movie.read(MemoryBytes(rewrite.apply(source)));
        expect(after.tags['QuickTime:CreationDate'], value);
        expect(after.chunkOffsets, movie.chunkOffsets);
        expect(after.boxes.map((box) => box.type), [
          'ftyp',
          'free',
          'moov',
          'free',
          'mdat',
        ]);
      }
    });

    test('a shorter key before the data leaves a free box behind', () {
      final source = MemoryBytes(bytesOf('exiftool_keys'));
      final movie = Mp4Movie.read(source);
      final rewrite = movie.write({'Keys:Software': 'v2'});
      expect(rewrite.keepsOffsets, isTrue);
      expect(rewrite.length, source.length);
      final after = Mp4Movie.read(MemoryBytes(rewrite.apply(source)));
      expect(after.tags['QuickTime:Software'], 'v2');
      expect(after.chunkOffsets, movie.chunkOffsets);
    });

    test('the same values again change nothing', () {
      final source = MemoryBytes(bytesOf('exiftool_dates'));
      final movie = Mp4Movie.read(source);
      final rewrite = movie.write(movie.tags.cast<String, String>());
      expect(rewrite.apply(source), source.bytes);
      expect(rewrite.ignored, isEmpty);
    });

    test('dates that cannot be stored are refused', () {
      final movie = Mp4Movie.read(MemoryBytes(bytesOf('bare')));
      for (final tags in [
        {'QuickTime:CreateDate': '2026-05-20 22:58:22'},
        {'QuickTime:CreateDate': '2026:05:20 22:58:22+08:00'},
        {'QuickTime:CreateDate': '1969:12:31 23:59:59'},
        {'QuickTime:CreateDate': '2040:02:06 06:28:16'},
        {'QuickTime:TrackCreateDate': '2026:02:30 00:00:00'},
        {'QuickTime:CreationDate': 'yesterday'},
        {'QuickTime:CreationDate': '2026-05-21T06:58:22+0800'},
      ]) {
        expect(() => movie.write(tags), throwsFormatException, reason: '$tags');
      }
      expect(fitsMp4Header(naive(2040, 2, 6, 6, 28, 15)), isTrue);
      expect(fitsMp4Header(naive(2040, 2, 6, 6, 28, 16)), isFalse);
      expect(fitsMp4Header(naive(1970)), isFalse);
      // A 64-bit header takes the later date.
      final wide = Mp4Movie.read(MemoryBytes(bytesOf('version_1')));
      final source = MemoryBytes(bytesOf('version_1'));
      final after = Mp4Movie.read(
        MemoryBytes(
          wide.write({'CreateDate': '2140:02:06 06:28:16'}).apply(source),
        ),
      );
      expect(after.tags['QuickTime:CreateDate'], '2140:02:06 06:28:16');
    });

    test(
      'exiftool reads the port\'s files the same, and ffmpeg decodes them',
      () {
        final folder = Directory.systemTemp.createTempSync('uwmedia_mp4_');
        addTearDown(() => folder.deleteSync(recursive: true));
        final claimed = (reference['claimed'] as List<dynamic>).toSet();
        // Every file first, then one exiftool run over the folder.
        final decodable = <String>[];
        for (final (i, c) in cases.indexed) {
          final name = c['source'] as String;
          final tags = writeSets[c['write']] as Map<String, dynamic>;
          final source = MemoryBytes(bytesOf(name));
          final rewrite = Mp4Movie.read(source)
              .write(tags.cast<String, String>());
          final extension =
              ((sources[name] as Map<String, dynamic>)['file'] as String)
                  .split('.')
                  .last;
          final path =
              '${folder.path}/${i.toString().padLeft(3, '0')}.$extension';
          File(path).writeAsBytesSync(rewrite.apply(source));
          // ffmpeg on the files whose size changed: the others differ from
          // their sources in a few header bytes only.
          if (rewrite.length != source.length) {
            decodable.add(path);
          }
        }
        final read = Process.runSync('exiftool', [
          '-j',
          '-G',
          '-n',
          folder.path,
        ]);
        expect(read.exitCode, 0, reason: '${read.stderr}');
        final answers = {
          for (final answer in jsonObjects(jsonDecode(read.stdout as String)))
            (answer['SourceFile'] as String).split('/').last.split('.').first:
                answer,
        };
        expect(answers.length, cases.length);
        for (final (i, c) in cases.indexed) {
          final name = c['source'] as String;
          final all = answers[i.toString().padLeft(3, '0')]!;
          expect(
            // The epoch_ sources hold a date counted from 1970, which
            // exiftool remarks on in the source too.
            all.entries
                .where(
                  (e) =>
                      e.key.contains('Warning') && !name.startsWith('epoch_'),
                )
                .toList(),
            isEmpty,
            reason: '$name ${c['write']}',
          );
          expect(
            {
              for (final MapEntry(:key, :value) in all.entries)
                if (key.startsWith('QuickTime:') &&
                    claimed.contains(key.split(':')[1]))
                  key: value,
            },
            c['tags'],
            reason: '$name ${c['write']}',
          );
        }
        if (ffmpeg) {
          expect(decodable.length, greaterThan(50));
          // Every fourth is enough for the decoder; that covers each source.
          for (final path in [
            for (var i = 0; i < decodable.length; i += 4) decodable[i],
          ]) {
            final decode = Process.runSync('ffmpeg', [
              '-v',
              'error',
              '-i',
              path,
              '-f',
              'null',
              '-',
            ]);
            expect('${decode.exitCode} ${decode.stderr}', '0 ', reason: path);
          }
        }
      },
      skip: exiftool ? false : 'exiftool is not installed',
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}

class _Watched implements ByteSource {
  _Watched(this.bytes, this.reads);

  final Uint8List bytes;
  final List<(int, int)> reads;

  @override
  int get length => bytes.length;

  @override
  Uint8List read(int offset, int count) {
    reads.add((offset, count));
    return Uint8List.sublistView(bytes, offset, offset + count);
  }
}
