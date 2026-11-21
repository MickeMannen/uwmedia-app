// The phone's media engine in the runner (MediaEngine.kt, the iOS
// runner's MediaEngine) on a simulator or a phone, without the pages: each
// call on a clip ffmpeg made on the Mac (a simulator reads the Mac's
// files), and the pictures of the result looked at. Run:
//   flutter test integration_test/media_engine_test.dart -d <device> \
//     [--dart-define=CLIP=/path/clip.mp4] [--dart-define=OUT=/folder]
// The clip: 1920x1080, 4 s or longer, with sound. A simulator is given the
// Mac's path; on a phone, without CLIP, the test asks for one with the
// file picker: the platform check's perf_clip.mp4, already on the phone,
// will do.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/engine/media_file_dates.dart';
import 'package:uwmedia_app/engine/mobile_engine.dart';
import 'package:uwmedia_app/engine/mobile_video_run.dart';

import 'platform_check/screens.dart';

const _clipArg = String.fromEnvironment('CLIP');

/// The clip: CLIP, or the one picked on the phone (once, by the first test
/// that needs it).
String? _picked;

Future<String> _clipPath(WidgetTester tester) async {
  if (_clipArg.isNotEmpty) {
    return _clipArg;
  }
  if (_picked == null) {
    final picked = Completer<String?>();
    _picked = await waitOnScreen<String?>(
      tester,
      PickClipScreen(picked, fileName: 'a 1080p clip'),
      picked,
      timeout: const Duration(minutes: 5),
      onTimeout: () => null,
    );
  }
  return _picked ?? (throw StateError('no clip: pass CLIP or pick one'));
}

const _out = String.fromEnvironment('OUT');

// More clips for the fit, each optional: any sizes (a 4K one, one taken
// upright with a rotation, one with sound an MP4 cannot hold).
const _more = String.fromEnvironment('MORE');

/// A LUT of [size]³ that makes every colour ([r], [g], [b]).
Uint8List _flatLut(int size, int r, int g, int b) {
  final lut = Uint8List(size * size * size * 3);
  for (var i = 0; i < lut.length; i += 3) {
    lut[i] = r;
    lut[i + 1] = g;
    lut[i + 2] = b;
  }
  return lut;
}

/// A LUT that makes white where red is over half and black elsewhere:
/// a red pixel goes black if the engine reads the table in another order.
/// Grey reads the same whatever YUV matrix a frame is read with (the
/// frame grab reads with BT.601 as Python does, the engine works in the
/// clip's own), where a swap of colours would not.
Uint8List _redStepLut(int size) {
  final lut = Uint8List(size * size * size * 3);
  var o = 0;
  for (var b = 0; b < size; b++) {
    for (var g = 0; g < size; g++) {
      for (var r = 0; r < size; r++) {
        final v = 2 * r >= size ? 255 : 0;
        lut[o++] = v;
        lut[o++] = v;
        lut[o++] = v;
      }
    }
  }
  return lut;
}

/// A pixel of [image], away from its edges, whose 5x5 square all passes
/// [test]; `null` when there is none.
(int, int)? _findPixel(
  RgbImage image,
  bool Function(int r, int g, int b) test,
) {
  bool steady(int x, int y) {
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        final (r, g, b) = _pixel(image, x + dx, y + dy);
        if (!test(r, g, b)) {
          return false;
        }
      }
    }
    return true;
  }

  for (var y = 8; y < image.height - 8; y += 4) {
    for (var x = 8; x < image.width - 8; x += 4) {
      if (steady(x, y)) {
        return (x, y);
      }
    }
  }
  return null;
}

Future<Uint8List> _whitePng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return png!.buffer.asUint8List();
}

(int, int, int) _pixel(RgbImage image, int x, int y) {
  final i = (y * image.width + x) * 3;
  return (image.rgb[i], image.rgb[i + 1], image.rgb[i + 2]);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const engine = PlatformMediaEngine();

  testWidgets('a conversion keeps the whole picture, fitted and padded', (
    tester,
  ) async {
    final tmp = _out.isNotEmpty ? _out : (await getTemporaryDirectory()).path;
    Directory(tmp).createSync(recursive: true);
    for (final source in _more.split(',').where((path) => path.isNotEmpty)) {
      final clip = await engine.probe(source);
      final name = source.split('/').last.split('.').first;
      final output = '$tmp/fit_$name.mp4';
      const box = (1280, 720);
      await MobileVideoRun(
        engine: engine,
        tempDir: (prefix) => Directory(tmp).createTempSync(prefix),
      ).convert(input: source, output: output, size: box, bitrate: 6000000);
      final made = await engine.probe(output);
      debugPrint('fit $name ${clip.width}x${clip.height}');
      expect((made.width, made.height), box);
      // The source as it should lie in the box, and the output.
      final scale = [
        box.$1 / clip.width,
        box.$2 / clip.height,
      ].reduce((a, b) => a < b ? a : b);
      final w = (clip.width * scale).round();
      final h = (clip.height * scale).round();
      final x0 = (box.$1 - w) ~/ 2;
      final y0 = (box.$2 - h) ~/ 2;
      final want = (await engine.frameAt(
        source,
        0.5,
        maxWidth: w,
        maxHeight: h,
        exact: true,
      ))!;
      final got = (await engine.frameAt(
        output,
        0.5,
        maxWidth: box.$1,
        maxHeight: box.$2,
        exact: true,
      ))!;
      expect((got.width, got.height), box);
      // A point may lie on the pattern's fine lines, which the two
      // scalings draw differently: all but one must agree.
      var agree = 0;
      const points = [
        (0.1, 0.1),
        (0.9, 0.1),
        (0.1, 0.9),
        (0.9, 0.9),
        (0.5, 0.5),
        (0.3, 0.7),
      ];
      for (final (fx, fy) in points) {
        final x = (fx * (want.width - 1)).round();
        final y = (fy * (want.height - 1)).round();
        final a = _pixel(want, x, y);
        final b = _pixel(got, x0 + x, y0 + y);
        debugPrint('  at $fx,$fy: source $a output $b');
        if ([
          a.$1 - b.$1,
          a.$2 - b.$2,
          a.$3 - b.$3,
        ].every((d) => d.abs() < 16)) {
          agree++;
        }
      }
      debugPrint('fit $name: $agree of ${points.length} agree, at $x0,$y0');
      expect(agree, greaterThanOrEqualTo(points.length - 1), reason: name);
      if (x0 > 8) {
        expect(_pixel(got, 2, box.$2 ~/ 2).$1, lessThan(24), reason: 'padding');
      }
    }
  });

  testWidgets('a crop: the layer on what is kept, the fit after, H.264', (
    tester,
  ) async {
    final clipFile = await _clipPath(tester);
    final tmp = (await getTemporaryDirectory()).path;
    final clip = await engine.probe(clipFile);
    // The right-hand 9:16 window of the picture, halved.
    final h = clip.height;
    final w = (h * 9 / 16).round() ~/ 2 * 2;
    final x = clip.width - w;
    final picture = File('$tmp/crop_layer.png')
      ..writeAsBytesSync(await _whitePng(100, 60));
    final output = '$tmp/cropped.mp4';
    await engine.encode(
      EncodeJob(
        input: clipFile,
        output: output,
        frameWidth: clip.width,
        frameHeight: clip.height,
        crop: (x: x, y: 0, width: w, height: h),
        fit: (w ~/ 2, h ~/ 2),
        h264: true,
        bitrate: 4000000,
        layers: [
          (x: 20, y: 20, pictures: [(path: picture.path, seconds: 0.0)]),
        ],
      ),
    );
    final made = await engine.probe(output);
    debugPrint('cropped ${made.width}x${made.height} ${made.mime}');
    expect((made.width, made.height), (w ~/ 2, h ~/ 2));
    expect(made.mime, 'video/avc');
    final got = (await engine.frameAt(
      output,
      1,
      maxWidth: w ~/ 2,
      maxHeight: h ~/ 2,
      exact: true,
    ))!;
    final source = (await engine.frameAt(
      clipFile,
      1,
      maxWidth: clip.width ~/ 2,
      maxHeight: clip.height ~/ 2,
      exact: true,
    ))!;
    // The layer lies at (20, 20) of the kept part, 100 by 60: halved,
    // (10, 10) to (60, 40).
    final inside = _pixel(got, 35, 25);
    debugPrint(
      'layer $inside, source there ${_pixel(source, x ~/ 2 + 35, 25)}',
    );
    expect([inside.$1, inside.$2, inside.$3], everyElement(greaterThan(225)));
    // Elsewhere the kept part is the source's right end.
    var agree = 0;
    const points = [(100, 200), (200, 400), (250, 100), (50, 500), (150, 300)];
    for (final (px, py) in points) {
      final a = _pixel(got, px, py);
      final b = _pixel(source, x ~/ 2 + px, py);
      if ((a.$1 - b.$1).abs() < 40 &&
          (a.$2 - b.$2).abs() < 40 &&
          (a.$3 - b.$3).abs() < 40) {
        agree++;
      }
    }
    debugPrint('crop: $agree of ${points.length} agree');
    expect(agree, greaterThanOrEqualTo(points.length - 1));
  });

  testWidgets('probe, frames, and every kind of encode', (tester) async {
    final clipFile = await _clipPath(tester);
    final tmp = _out.isNotEmpty ? _out : (await getTemporaryDirectory()).path;
    Directory(tmp).createSync(recursive: true);

    final clip = await engine.probe(clipFile);
    debugPrint(
      'clip ${clip.width}x${clip.height} ${clip.durationSeconds}s '
      '${clip.fps} fps ${clip.bitrate} b/s ${clip.mime} hdr ${clip.hdr}',
    );
    expect((clip.width, clip.height), (1920, 1080));
    expect(clip.durationSeconds, greaterThanOrEqualTo(4));
    expect(clip.hdr, isFalse);

    // A frame keeps its shape inside the box asked for.
    final frame = await engine.frameAt(
      clipFile,
      1,
      maxWidth: 480,
      maxHeight: 480,
      exact: true,
    );
    expect((frame!.width, frame.height), (480, 270));
    final (sr, sg, sb) = _pixel(frame, 60, 200);

    Future<RgbImage> frameOf(String path, double seconds) async => (await engine
        .frameAt(path, seconds, maxWidth: 1920, maxHeight: 1080, exact: true))!;

    // The table's order: white where red is over half. A red pixel turns
    // white, a green or blue one black.
    final stepped = '$tmp/step.mp4';
    await engine.encode(
      EncodeJob(
        input: clipFile,
        output: stepped,
        frameWidth: clip.width,
        frameHeight: clip.height,
        bitrate: 8000000,
        luts: [(seconds: 0.0, lut: _redStepLut(lutSize))],
      ),
    );
    final big = await frameOf(clipFile, 1);
    final step = await frameOf(stepped, 1);
    final redAt = _findPixel(big, (r, g, b) => r > 200 && g < 60 && b < 60);
    final notRedAt = _findPixel(
      big,
      (r, g, b) => r < 60 && (g > 200 || b > 200),
    );
    expect(redAt, isNotNull, reason: 'the clip needs a red patch');
    expect(notRedAt, isNotNull, reason: 'the clip needs a green or blue patch');
    for (final ((x, y), want) in [(redAt!, 255), (notRedAt!, 0)]) {
      final (r, g, b) = _pixel(step, x, y);
      debugPrint(
        'source at ($x, $y) ${_pixel(big, x, y)} (small $sr $sg $sb) '
        'stepped $r $g $b',
      );
      for (final v in [r, g, b]) {
        expect(v, closeTo(want, 24));
      }
    }

    // LUTs at their times (red, then blue from 2 s), with an overlay
    // picture from 1 s on, its top-left corner at (200, 100).
    final picture = File('$tmp/white.png')
      ..writeAsBytesSync(await _whitePng(300, 120));
    final empty = File('$tmp/clear.png')
      ..writeAsBytesSync(
        await (() async {
          final recorder = ui.PictureRecorder();
          ui.Canvas(recorder);
          final image = await recorder.endRecording().toImage(300, 120);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          return png!.buffer.asUint8List();
        })(),
      );
    final timed = '$tmp/timed.mp4';
    final percents = <double>[];
    final result = await engine.encode(
      EncodeJob(
        input: clipFile,
        output: timed,
        frameWidth: clip.width,
        frameHeight: clip.height,
        bitrate: 8000000,
        luts: [
          (seconds: 0.0, lut: _flatLut(lutSize, 255, 0, 0)),
          (seconds: 2.0, lut: _flatLut(lutSize, 0, 0, 255)),
        ],
        layers: [
          (
            x: 200,
            y: 100,
            pictures: [
              (path: empty.path, seconds: 0.0),
              (path: picture.path, seconds: 1.0),
            ],
          ),
        ],
      ),
      onProgress: percents.add,
    );
    debugPrint('timed $result progress $percents');
    final out = await engine.probe(timed);
    expect((out.width, out.height), (1920, 1080));
    expect(out.mime, 'video/hevc');
    expect(out.durationSeconds, closeTo(clip.durationSeconds, 0.2));

    bool red((int, int, int) c) => c.$1 > 180 && c.$2 < 70 && c.$3 < 70;
    bool blue((int, int, int) c) => c.$3 > 180 && c.$1 < 70 && c.$2 < 70;
    bool white((int, int, int) c) => c.$1 > 200 && c.$2 > 200 && c.$3 > 200;
    final early = await frameOf(timed, 0.5);
    final middle = await frameOf(timed, 1.5);
    final late = await frameOf(timed, 3);
    expect(red(_pixel(early, 1000, 600)), isTrue);
    expect(red(_pixel(early, 300, 150)), isTrue, reason: 'no overlay yet');
    expect(red(_pixel(middle, 1000, 600)), isTrue);
    expect(white(_pixel(middle, 300, 150)), isTrue, reason: 'the overlay');
    expect(blue(_pixel(late, 1000, 600)), isTrue);
    // The overlay's edges: inside at (205, 105) and (495, 215), outside
    // just beyond them.
    expect(white(_pixel(late, 205, 105)), isTrue);
    expect(white(_pixel(late, 495, 215)), isTrue);
    expect(blue(_pixel(late, 190, 105)), isTrue);
    expect(blue(_pixel(late, 205, 90)), isTrue);
    expect(blue(_pixel(late, 510, 215)), isTrue);
    expect(blue(_pixel(late, 495, 230)), isTrue);

    // A part of the clip (spec §10.71): from 1 s to 3.5 s, the LUTs' and
    // the picture's times counted from its start.
    final cut = '$tmp/part.mp4';
    await engine.encode(
      EncodeJob(
        input: clipFile,
        output: cut,
        frameWidth: clip.width,
        frameHeight: clip.height,
        bitrate: 8000000,
        part: (start: 1.0, end: 3.5),
        luts: [
          (seconds: 0.0, lut: _flatLut(lutSize, 255, 0, 0)),
          (seconds: 1.5, lut: _flatLut(lutSize, 0, 0, 255)),
        ],
        layers: [
          (
            x: 200,
            y: 100,
            pictures: [
              (path: empty.path, seconds: 0.0),
              (path: picture.path, seconds: 0.8),
            ],
          ),
        ],
      ),
    );
    final part = await engine.probe(cut);
    debugPrint('part ${part.durationSeconds}s ${part.totalFrames} frames');
    expect(part.durationSeconds, closeTo(2.5, 0.15));
    final partEarly = await frameOf(cut, 0.4);
    final partMiddle = await frameOf(cut, 1.1);
    final partLate = await frameOf(cut, 2.2);
    expect(red(_pixel(partEarly, 1000, 600)), isTrue);
    expect(red(_pixel(partEarly, 300, 150)), isTrue, reason: 'no overlay yet');
    expect(red(_pixel(partMiddle, 1000, 600)), isTrue);
    expect(white(_pixel(partMiddle, 300, 150)), isTrue);
    expect(blue(_pixel(partLate, 1000, 600)), isTrue);

    // A conversion: fitted and padded, with the source's dates.
    final small = '$tmp/small.mp4';
    final lines =
        await MobileVideoRun(
          engine: engine,
          tempDir: (prefix) => Directory(tmp).createTempSync(prefix),
        ).convert(
          input: clipFile,
          output: small,
          size: (854, 480),
          bitrate: 2000000,
        );
    debugPrint('convert $lines ${File(small).lengthSync()} bytes');
    final converted = await engine.probe(small);
    expect((converted.width, converted.height), (854, 480));
    final seconds = converted.durationSeconds;
    expect(File(small).lengthSync() * 8 / seconds, lessThan(4000000));
    expect(
      readFileDates(small)['QuickTime:CreateDate'],
      readFileDates(clipFile)['QuickTime:CreateDate'],
    );

    // Stop: the encode ends and its file is gone.
    final stopped = '$tmp/stopped.mp4';
    final going = engine.encode(
      EncodeJob(
        input: clipFile,
        output: stopped,
        frameWidth: clip.width,
        frameHeight: clip.height,
        luts: [(seconds: 0.0, lut: _flatLut(lutSize, 0, 255, 0))],
      ),
    );
    final ended = expectLater(going, throwsA(isA<Exception>()));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await engine.cancel();
    await ended;
    expect(File(stopped).existsSync(), isFalse);
  });
}
