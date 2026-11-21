// The spike's native engine on a simulator or a phone, without the UI:
// each call on a clip ffmpeg made on the Mac (the simulator reads the
// Mac's files). Run: flutter test integration_test -d <simulator>
// --dart-define=CLIP=/path/to/clip.mp4
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';

const _engine = MethodChannel('uwmedia.spike/engine');
const _clip = String.fromEnvironment('CLIP');
// Where the outputs go: a folder of the Mac's on a simulator, else the
// app's temporary folder.
const _out = String.fromEnvironment('OUT');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every engine call on a clip', (tester) async {
    expect(_clip, isNotEmpty, reason: 'pass --dart-define=CLIP=...');
    final info = await _engine.invokeMapMethod<String, Object?>('deviceInfo');
    debugPrint('device $info');
    final facts = await _engine.invokeMapMethod<String, Object?>('videoInfo', {
      'path': _clip,
    });
    debugPrint('facts $facts');
    expect(facts!['width'], 1920);
    expect(facts['height'], 1080);

    final png = await _engine.invokeMethod<Uint8List>('frameAt', {
      'path': _clip,
      'seconds': 2.0,
    });
    expect(png!.sublist(1, 4), 'PNG'.codeUnits);

    final tmp = _out.isNotEmpty ? _out : (await getTemporaryDirectory()).path;
    final down = await _engine.invokeMapMethod<String, Object?>('transcode', {
      'path': _clip,
      'out': '$tmp/down.mp4',
      'height': 1080,
    });
    debugPrint('downscale $down');
    expect(File('$tmp/down.mp4').lengthSync(), greaterThan(1000));

    // A LUT that turns everything red: the output frame must be red.
    const size = 8;
    final lut = Uint8List(size * size * size * 3);
    for (var i = 0; i < lut.length; i += 3) {
      lut[i] = 255;
    }
    final coloured = await _engine.invokeMapMethod<String, Object?>(
      'transcode',
      {'path': _clip, 'out': '$tmp/lut.mp4', 'lut': lut, 'lutSize': size},
    );
    debugPrint('lut $coloured');
    final redPng = await _engine.invokeMethod<Uint8List>('frameAt', {
      'path': '$tmp/lut.mp4',
      'seconds': 1.0,
    });
    expect(redPng, isNotNull);

    // The app's own LUT size goes through too.
    final engine = ColorEngine(const ColorProfile());
    final grey = Uint8List(16 * 16 * 3)..fillRange(0, 16 * 16 * 3, 100);
    final appLut = engine.lut3d(engine.analyze(RgbImage(16, 16, grey)).filter);
    final big = await _engine.invokeMapMethod<String, Object?>('transcode', {
      'path': _clip,
      'out': '$tmp/lut64.mp4',
      'lut': appLut,
      'lutSize': lutSize,
    });
    debugPrint('lut64 $big');

    // Overlays: two pictures, one a second.
    final dir = Directory('$tmp/ov')..createSync(recursive: true);
    for (var i = 0; i < 8; i++) {
      File('$tmp/ov/o_${i.toString().padLeft(5, '0')}.png')
          .writeAsBytesSync(png);
    }
    final over = await _engine.invokeMapMethod<String, Object?>('transcode', {
      'path': _clip,
      'out': '$tmp/over.mp4',
      'overlayDir': dir.path,
      'overlayCount': 8,
      'overlayX': 0.04,
      'overlayY': 0.04,
    });
    debugPrint('overlay $over');
    expect(File('$tmp/over.mp4').lengthSync(), greaterThan(1000));
  });
}
