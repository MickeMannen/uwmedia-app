// A video's dates written on disk (lib/engine/mp4_file.dart) on clips
// ffmpeg makes: patched where the file lies, grown at the end, rewritten
// when the picture data moves, or copied to a new file; exiftool reads the
// new dates and every frame decodes as before.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uwmedia_app/engine/mp4_file.dart';

import '../helpers/tools.dart';

Future<void> _clip(String path, {bool faststart = false}) async {
  final run = await Process.run('ffmpeg', [
    '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=64x48:rate=10', //
    '-t', '2', '-pix_fmt', 'yuv420p', '-c:v', 'libx264',
    '-metadata', 'creation_time=2026-03-14T09:30:00Z',
    if (faststart) ...['-movflags', '+faststart'],
    path, '-y',
  ]);
  expect(run.exitCode, 0, reason: '${run.stderr}');
}

Future<String> _frames(String path) async {
  final run = await Process.run('ffmpeg', [
    '-v',
    'error',
    '-i',
    path,
    '-map',
    '0:v',
    '-f',
    'framemd5',
    '-',
  ]);
  expect(run.exitCode, 0, reason: '${run.stderr}');
  expect(run.stderr, isEmpty);
  return (run.stdout as String)
      .split('\n')
      .where((line) => !line.startsWith('#'))
      .join('\n');
}

Future<Map<String, String>> _dates(String path) async {
  final run = await Process.run('exiftool', [
    '-s',
    '-s',
    '-QuickTime:CreateDate',
    '-QuickTime:CreationDate',
    '-QuickTime:TrackCreateDate',
    path,
  ]);
  return {
    // Windows ends exiftool's lines with \r\n.
    for (final line in const LineSplitter().convert(
      (run.stdout as String).trim(),
    ))
      if (line.contains(': '))
        line.substring(0, line.indexOf(': ')): line.substring(
          line.indexOf(': ') + 2,
        ),
  };
}

void main() {
  if (!hasTool('ffmpeg') || !hasTool('exiftool')) {
    test('needs ffmpeg and exiftool on the PATH', () {}, skip: true);
    return;
  }
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('uwmedia_mp4_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('header dates: patched where the file lies', () async {
    final path = p.join(tmp.path, 'a.mp4');
    await _clip(path);
    final frames = await _frames(path);
    final size = File(path).lengthSync();
    final done = writeMp4Dates(path, {
      'QuickTime:CreateDate': '2026:03:14 08:30:00',
      'QuickTime:TrackCreateDate': '2026:03:14 08:30:00',
    });
    expect(done.mode, Mp4WriteMode.patched);
    expect(File(path).lengthSync(), size);
    expect(await _dates(path), {
      'CreateDate': '2026:03:14 08:30:00',
      'TrackCreateDate': '2026:03:14 08:30:00',
    });
    expect(await _frames(path), frames);
    // The same again: nothing to do.
    expect(
      writeMp4Dates(path, {'QuickTime:CreateDate': '2026:03:14 08:30:00'}).mode,
      Mp4WriteMode.unchanged,
    );
  });

  test('a new key with the movie header last: the file grows', () async {
    final path = p.join(tmp.path, 'b.mp4');
    await _clip(path);
    final frames = await _frames(path);
    final size = File(path).lengthSync();
    final done = writeMp4Dates(path, {
      'QuickTime:CreationDate': '2026:03:14 10:30:00+01:00',
    });
    expect(done.mode, Mp4WriteMode.patched);
    expect(File(path).lengthSync(), greaterThan(size));
    expect((await _dates(path))['CreationDate'], '2026:03:14 10:30:00+01:00');
    expect(await _frames(path), frames);
  });

  test('a new key with the movie header first: rewritten', () async {
    final path = p.join(tmp.path, 'c.mp4');
    await _clip(path, faststart: true);
    final frames = await _frames(path);
    final done = writeMp4Dates(path, {
      'QuickTime:CreationDate': '2026:03:14 10:30:00+01:00',
      'QuickTime:CreateDate': '2026:03:14 09:30:00',
    });
    expect(done.mode, Mp4WriteMode.rewritten);
    expect(File('$path.new').existsSync(), isFalse);
    expect(await _dates(path), {
      'CreateDate': '2026:03:14 09:30:00',
      'CreationDate': '2026:03:14 10:30:00+01:00',
      'TrackCreateDate': '2026:03:14 09:30:00',
    });
    expect(await _frames(path), frames);
  });

  test('a corrected copy; the source as it was', () async {
    final path = p.join(tmp.path, 'd.mp4');
    await _clip(path);
    final before = File(path).readAsBytesSync();
    for (final (name, tags) in [
      ('dates.mp4', {'QuickTime:CreateDate': '2026:03:14 07:30:00'}),
      ('key.mp4', {'QuickTime:CreationDate': '2026:03:14 08:30:00+01:00'}),
    ]) {
      final copy = p.join(tmp.path, name);
      writeMp4Dates(path, tags, output: copy);
      expect(File(path).readAsBytesSync(), before);
      final read = await _dates(copy);
      for (final MapEntry(:key, :value) in tags.entries) {
        expect(read[key.split(':').last], value);
      }
      expect(await _frames(copy), await _frames(path));
    }
  });
}
