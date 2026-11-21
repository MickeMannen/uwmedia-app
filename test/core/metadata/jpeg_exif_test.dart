// The pure-Dart JPEG date writer (lib/core/metadata/jpeg_exif.dart)
// against exiftool: a camera photo's dates overwritten in place, offsets
// it lacks added, a photo without EXIF given a block; every other tag as
// it was, the image data byte for byte, and exiftool's own check clean.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/metadata/jpeg_exif.dart';

import '../../helpers/tools.dart';

const _sony = 'test/fixtures/media/photo/jpeg_3x2_2mp.jpg';

const _new = {
  'EXIF:ModifyDate': '2026:01:02 03:04:05',
  'EXIF:DateTimeOriginal': '2026:01:02 03:04:05',
  'EXIF:CreateDate': '2026:01:02 03:04:05',
  'EXIF:OffsetTime': '-05:30',
  'EXIF:OffsetTimeOriginal': '-05:30',
  'EXIF:OffsetTimeDigitized': '-05:30',
};

// Everything from the start-of-scan marker on: the image data.
Uint8List _imageData(Uint8List jpeg) {
  for (var i = 2; i + 1 < jpeg.length; i++) {
    if (jpeg[i] == 0xFF && jpeg[i + 1] == 0xDA) {
      return Uint8List.sublistView(jpeg, i);
    }
  }
  throw StateError('no image data');
}

Future<Map<String, Object?>> _exiftool(String path) async {
  final run = await Process.run('exiftool', [
    '-j', '-a', '-G1', '-s', '-n', //
    '-x', 'System:all', '-x', 'File:all', '-x', 'ExifTool:all',
    '-x', 'Composite:all', path,
  ]);
  expect(run.exitCode, 0, reason: '${run.stderr}');
  final list = jsonDecode(run.stdout as String) as List<dynamic>;
  return (list.single as Map<String, dynamic>)..remove('SourceFile');
}

Future<String> _validate(String path) async {
  final run = await Process.run('exiftool', [
    '-validate',
    '-warning',
    '-a',
    '-s',
    path,
  ]);
  return run.stdout as String;
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('uwmedia_exif_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('reads the camera photo as exiftool does', () {
    expect(readJpegDates(File(_sony).readAsBytesSync()), {
      'EXIF:ModifyDate': '2025:12:03 09:15:48',
      'EXIF:DateTimeOriginal': '2025:12:03 09:15:48',
      'EXIF:CreateDate': '2025:12:03 09:15:48',
      'EXIF:OffsetTime': '+08:00',
      'EXIF:OffsetTimeOriginal': '+08:00',
      'EXIF:OffsetTimeDigitized': '+08:00',
      // Which camera, read with the dates (spec §10.72).
      'EXIF:Make': 'SONY',
      'EXIF:Model': 'ILCE-6700',
    });
  });

  test('written values read back; refusals', () {
    final source = File(_sony).readAsBytesSync();
    final written = writeJpegDates(source, _new);
    expect(readJpegDates(written), {
      ..._new,
      'EXIF:Make': 'SONY',
      'EXIF:Model': 'ILCE-6700',
    });
    expect(_imageData(written), _imageData(source));
    expect(written.length, source.length);
    expect(
      () => writeJpegDates(source, {'EXIF:Make': 'x'}),
      throwsFormatException,
    );
    expect(
      () => writeJpegDates(Uint8List.fromList([1, 2, 3, 4]), _new),
      throwsFormatException,
    );
  });

  group(
    'with exiftool',
    () {
      test('a camera photo: dates and offsets overwritten in place', () async {
        final before = p.join(tmp.path, 'before.jpg');
        File(_sony).copySync(before);
        final after = p.join(tmp.path, 'after.jpg');
        File(after).writeAsBytesSync(
          writeJpegDates(File(before).readAsBytesSync(), _new),
        );
        final old = await _exiftool(before);
        final now = await _exiftool(after);
        expect(now['IFD0:ModifyDate'], _new['EXIF:ModifyDate']);
        expect(now['ExifIFD:DateTimeOriginal'], _new['EXIF:DateTimeOriginal']);
        expect(now['ExifIFD:CreateDate'], _new['EXIF:CreateDate']);
        expect(now['ExifIFD:OffsetTimeOriginal'], '-05:30');
        // Every other tag as it was.
        for (final key in [
          'IFD0:ModifyDate',
          'ExifIFD:DateTimeOriginal',
          'ExifIFD:CreateDate',
          'ExifIFD:OffsetTime',
          'ExifIFD:OffsetTimeOriginal',
          'ExifIFD:OffsetTimeDigitized',
        ]) {
          old.remove(key);
          now.remove(key);
        }
        expect(now, old);
        expect(await _validate(after), await _validate(before));
      });

      test('offsets the photo lacks are added', () async {
        final path = p.join(tmp.path, 'bare.jpg');
        File(_sony).copySync(path);
        final strip = await Process.run('exiftool', [
          '-OffsetTime=',
          '-OffsetTimeOriginal=',
          '-OffsetTimeDigitized=',
          '-overwrite_original',
          path,
        ]);
        expect(strip.exitCode, 0, reason: '${strip.stderr}');
        final source = File(path).readAsBytesSync();
        expect(readJpegDates(source).containsKey('EXIF:OffsetTime'), isFalse);
        final old = await _exiftool(path);
        final after = p.join(tmp.path, 'after.jpg');
        final written = writeJpegDates(source, {
          'EXIF:DateTimeOriginal': '2026:01:02 03:04:05',
          'EXIF:OffsetTime': '+08:00',
          'EXIF:OffsetTimeOriginal': '+08:00',
          'EXIF:OffsetTimeDigitized': '+08:00',
        });
        File(after).writeAsBytesSync(written);
        expect(_imageData(written), _imageData(source));
        final now = await _exiftool(after);
        expect(now['ExifIFD:OffsetTime'], '+08:00');
        expect(now['ExifIFD:OffsetTimeOriginal'], '+08:00');
        expect(now['ExifIFD:OffsetTimeDigitized'], '+08:00');
        expect(now['ExifIFD:DateTimeOriginal'], '2026:01:02 03:04:05');
        for (final key in [
          'ExifIFD:DateTimeOriginal',
          'ExifIFD:OffsetTime',
          'ExifIFD:OffsetTimeOriginal',
          'ExifIFD:OffsetTimeDigitized',
        ]) {
          now.remove(key);
          old.remove(key);
        }
        // The maker notes and the thumbnail still found where they were.
        expect(now, old);
        expect(await _validate(after), isNot(contains('Error')));
      });

      test('a photo without EXIF gets a block of its own', () async {
        final path = p.join(tmp.path, 'plain.jpg');
        final made = await Process.run('ffmpeg', [
          '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=64x48', //
          '-frames:v', '1', path, '-y',
        ]);
        expect(made.exitCode, 0, reason: '${made.stderr}');
        final source = File(path).readAsBytesSync();
        expect(readJpegDates(source), isEmpty);
        final after = p.join(tmp.path, 'dated.jpg');
        final written = writeJpegDates(source, _new);
        File(after).writeAsBytesSync(written);
        expect(_imageData(written), _imageData(source));
        final now = await _exiftool(after);
        expect(now['ExifIFD:DateTimeOriginal'], '2026:01:02 03:04:05');
        expect(now['ExifIFD:CreateDate'], '2026:01:02 03:04:05');
        expect(now['ExifIFD:OffsetTimeOriginal'], '-05:30');
        // No IFD0 date to overwrite, so none is added.
        expect(now.containsKey('IFD0:ModifyDate'), isFalse);
        expect(readJpegDates(written), {
          for (final MapEntry(:key, :value) in _new.entries)
            if (key != 'EXIF:ModifyDate') key: value,
        });
        expect(await _validate(after), isNot(contains('Error')));
        // A directory made new carries ExifVersion, as every one must.
        final version = await Process.run('exiftool', [
          '-s',
          '-s',
          '-s',
          '-ExifIFD:ExifVersion',
          after,
        ]);
        expect((version.stdout as String).trim(), '0232');
        expect(await _validate(after), isNot(contains('ExifVersion')));
      });
    },
    skip: hasTool('exiftool') && hasTool('ffmpeg')
        ? null
        : 'needs exiftool and ffmpeg on the PATH',
  );
}
