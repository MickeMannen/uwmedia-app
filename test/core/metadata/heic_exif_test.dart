// The pure-Dart HEIC date writer (lib/core/metadata/heic_exif.dart) on a
// HEIC macOS's sips makes from the reviewed fixture photo, against
// exiftool: dates overwritten where they are (nothing else changes),
// offsets added in a moved Exif item (only iloc's fields change in the
// rest), every other tag as it was, exiftool's check clean, and the
// picture decoding to the same pixels. macOS only (sips).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/core/metadata/heic_exif.dart';

import '../../helpers/tools.dart';

const _sony = 'test/fixtures/media/photo/jpeg_3x2_2mp.jpg';

Future<void> _run(String tool, List<String> args) async {
  final run = await Process.run(tool, args);
  expect(run.exitCode, 0, reason: '$tool: ${run.stderr}');
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

Future<String> _validate(String path) async =>
    (await Process.run('exiftool', [
          '-validate',
          '-warning',
          '-a',
          '-s',
          path,
        ])).stdout
        as String;

// The picture, decoded by sips.
Future<Uint8List> _pixels(String heic, Directory tmp) async {
  final png = p.join(tmp.path, '${p.basenameWithoutExtension(heic)}.bmp');
  await _run('sips', ['-s', 'format', 'bmp', heic, '--out', png]);
  return File(png).readAsBytesSync();
}

void main() {
  final skip = Platform.isMacOS && hasTool('sips') && hasTool('exiftool')
      ? null
      : 'needs macOS sips and exiftool';
  late Directory tmp;
  late String heic;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('uwmedia_heic_');
    heic = p.join(tmp.path, 'photo.heic');
    if (skip == null) {
      await _run('sips', ['-s', 'format', 'heic', _sony, '--out', heic]);
    }
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('reads the dates as exiftool does', () {
    expect(readHeicDates(File(heic).readAsBytesSync()), {
      'EXIF:ModifyDate': '2025:12:03 09:15:48',
      'EXIF:DateTimeOriginal': '2025:12:03 09:15:48',
      'EXIF:CreateDate': '2025:12:03 09:15:48',
      'EXIF:OffsetTime': '+08:00',
      'EXIF:OffsetTimeOriginal': '+08:00',
      'EXIF:OffsetTimeDigitized': '+08:00',
      'EXIF:Make': 'SONY',
      'EXIF:Model': 'ILCE-6700',
    });
    expect(
      () => readHeicDates(File(_sony).readAsBytesSync()),
      throwsFormatException,
    );
  }, skip: skip);

  test('dates overwritten where they are; nothing else changes', () async {
    final source = File(heic).readAsBytesSync();
    final written = writeHeicDates(source, {
      'EXIF:DateTimeOriginal': '2026:01:02 03:04:05',
      'EXIF:CreateDate': '2026:01:02 03:04:05',
      'EXIF:OffsetTimeOriginal': '-05:30',
    });
    expect(written.length, source.length);
    final changed = [
      for (var i = 0; i < source.length; i++)
        if (source[i] != written[i]) i,
    ];
    // Only bytes of the TIFF block, which lies in the last 64 KB at most.
    expect(changed.length, lessThan(64));
    final out = p.join(tmp.path, 'out.heic');
    File(out).writeAsBytesSync(written);
    final old = await _exiftool(heic);
    final now = await _exiftool(out);
    expect(now['ExifIFD:DateTimeOriginal'], '2026:01:02 03:04:05');
    expect(now['ExifIFD:CreateDate'], '2026:01:02 03:04:05');
    expect(now['ExifIFD:OffsetTimeOriginal'], '-05:30');
    for (final key in [
      'ExifIFD:DateTimeOriginal',
      'ExifIFD:CreateDate',
      'ExifIFD:OffsetTimeOriginal',
    ]) {
      old.remove(key);
      now.remove(key);
    }
    expect(now, old);
  }, skip: skip);

  test('offsets added: the Exif item moves to the end', () async {
    final bare = p.join(tmp.path, 'bare.heic');
    File(heic).copySync(bare);
    await _run('exiftool', [
      '-OffsetTime=',
      '-OffsetTimeOriginal=',
      '-OffsetTimeDigitized=',
      '-overwrite_original',
      bare,
    ]);
    final source = File(bare).readAsBytesSync();
    expect(readHeicDates(source).containsKey('EXIF:OffsetTime'), isFalse);
    final written = writeHeicDates(source, {
      'EXIF:OffsetTime': '+08:00',
      'EXIF:OffsetTimeOriginal': '+08:00',
      'EXIF:OffsetTimeDigitized': '+08:00',
    });
    expect(written.length, greaterThan(source.length));
    // In the old part only iloc's offset and length of the item change.
    final changed = [
      for (var i = 0; i < source.length; i++)
        if (source[i] != written[i]) i,
    ];
    expect(changed.length, lessThanOrEqualTo(8));
    final out = p.join(tmp.path, 'dated.heic');
    File(out).writeAsBytesSync(written);
    final old = await _exiftool(bare);
    final now = await _exiftool(out);
    expect(now['ExifIFD:OffsetTime'], '+08:00');
    expect(now['ExifIFD:OffsetTimeOriginal'], '+08:00');
    expect(now['ExifIFD:OffsetTimeDigitized'], '+08:00');
    for (final key in [
      'ExifIFD:OffsetTime',
      'ExifIFD:OffsetTimeOriginal',
      'ExifIFD:OffsetTimeDigitized',
    ]) {
      now.remove(key);
    }
    // exiftool's size and place of the last media data box: here the new
    // one holding the moved item. The file's layout, not a tag of the
    // photo.
    for (final key in [
      'QuickTime:MediaDataSize',
      'QuickTime:MediaDataOffset',
    ]) {
      now.remove(key);
      old.remove(key);
    }
    expect(now, old);
    expect(await _validate(out), isNot(contains('Error')));
    expect(await _pixels(out, tmp), await _pixels(bare, tmp));
  }, skip: skip);

  test('a last box that runs to the end of the file is closed first', () async {
    // A "free" box of size 0 (to the end of the file) after the media data.
    final source = Uint8List.fromList([
      ...File(heic).readAsBytesSync(),
      0, 0, 0, 0, 0x66, 0x72, 0x65, 0x65, 1, 2, 3, 4, //
    ]);
    final bare = writeHeicDates(source, const {});
    expect(bare, source);
    final stripped = p.join(tmp.path, 'stripped.heic');
    File(stripped).writeAsBytesSync(source);
    await _run('exiftool', ['-OffsetTime=', '-overwrite_original', stripped]);
    final before = File(stripped).readAsBytesSync();
    final written = writeHeicDates(before, {'EXIF:OffsetTime': '+01:00'});
    expect(written.length, greaterThan(before.length));
    expect(readHeicDates(written)['EXIF:OffsetTime'], '+01:00');
    final out = p.join(tmp.path, 'closed.heic');
    File(out).writeAsBytesSync(written);
    expect((await _exiftool(out))['ExifIFD:OffsetTime'], '+01:00');
    expect(await _validate(out), isNot(contains('Error')));
  }, skip: skip);
}
