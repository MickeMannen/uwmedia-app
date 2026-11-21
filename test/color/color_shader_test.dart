// The preview's shaders (lib/color/color_shader.dart) against the colour
// engine: the same frames corrected by both, with each bundled profile
// (with and without sharpening, with the correction mixed in partly).
// integration_test/color_shader_test.dart runs the same on a device, with
// its graphics card.
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/color/color_shader.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/color/color_profiles.dart';

/// An underwater-looking frame: gradients, noise from a hash of the
/// position, a bright disc, and bands of black, white and grey.
RgbImage _frame(int width, int height, int seed) {
  final rgb = Uint8List(width * height * 3);
  final radius = height ~/ 4;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final dx = x - width ~/ 3;
      final dy = y - height ~/ 2;
      final disc = dx * dx + dy * dy < radius * radius;
      for (var c = 0; c < 3; c++) {
        final noise =
            ((x * 73856093) ^ (y * 19349663) ^ ((c + 1) * 83492791) ^ seed) %
                41 -
            20;
        var value =
            [20, 90, 120][c] +
            x * [40, 90, 60][c] ~/ width +
            y * [10, 40, 70][c] ~/ height +
            noise +
            (disc ? 90 - 15 * c : 0);
        if (y < 4) {
          // Every grey from black to white.
          value = x * 255 ~/ (width - 1);
        }
        rgb[(y * width + x) * 3 + c] = value.clamp(0, 255);
      }
    }
  }
  return RgbImage(width, height, rgb);
}

Future<ui.Image> _imageOf(RgbImage rgb) async {
  final rgba = Uint8List(rgb.width * rgb.height * 4);
  for (var i = 0, o = 0; i < rgb.rgb.length; i += 3, o += 4) {
    rgba[o] = rgb.rgb[i];
    rgba[o + 1] = rgb.rgb[i + 1];
    rgba[o + 2] = rgb.rgb[i + 2];
    rgba[o + 3] = 255;
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: rgb.width,
    height: rgb.height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  return (await codec.getNextFrame()).image;
}

void main() {
  testWidgets('the shaders correct a frame as the engine does', (tester) async {
    await tester.runAsync(() async {
      final shader = await ColorShader.load();
      expect(shader, isNotNull);
      final profiles = mergedColorProfiles(
        await rootBundle.loadString('assets/color.yaml'),
        null,
      );
      expect(profiles.keys, containsAll(['default', 'vivid', 'subtle']));
      for (final MapEntry(key: name, value: values) in profiles.entries) {
        final profile = ColorProfile.fromMap(values.cast<String, dynamic>());
        final engine = ColorEngine(profile);
        for (final (width, height, seed) in [(320, 180, 7), (97, 131, 99)]) {
          final frame = _frame(width, height, seed);
          final filter = engine.analyze(frame).filter;
          final want = engine.applyFilter(frame, filter).rgb;
          final source = await _imageOf(frame);
          final image = shader!.apply(source, profile, filter);
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawStraightRgba,
          ))!.buffer.asUint8List();
          source.dispose();
          image.dispose();
          var worst = 0;
          var different = 0;
          var sum = 0;
          for (var i = 0, o = 0; i < want.length; i += 3, o += 4) {
            expect(data[o + 3], 255);
            for (var c = 0; c < 3; c++) {
              final d = (data[o + c] - want[i + c]).abs();
              sum += d;
              if (d > 0) different++;
              if (d > worst) worst = d;
            }
          }
          final what =
              '$name ${width}x$height: $different of ${want.length} bytes '
              'differ, by at most $worst, mean ${sum / want.length}';
          // ignore: avoid_print
          print(what);
          // The correction changes the frame a lot, so this is no empty
          // comparison.
          var changed = 0;
          for (var i = 0; i < want.length; i++) {
            changed += (want[i] - frame.rgb[i]).abs();
          }
          expect(changed / want.length, greaterThan(5), reason: what);
          expect(worst, lessThanOrEqualTo(2), reason: what);
          expect(sum / want.length, lessThan(0.1), reason: what);
        }
      }
      if (TestWidgetsFlutterBinding.instance
          is! LiveTestWidgetsFlutterBinding) {
        return;
      }
      // On a device: a preview frame's size, timed (for the output; no
      // limit).
      final profile = ColorProfile.fromMap(
        profiles['default']!.cast<String, dynamic>(),
      );
      final engine = ColorEngine(profile);
      final frame = _frame(1920, 1080, 3);
      final filter = engine.analyze(frame).filter;
      final source = await _imageOf(frame);
      final watch = Stopwatch()..start();
      final image = shader!.apply(source, profile, filter);
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      final shaderMs = watch.elapsedMilliseconds;
      watch.reset();
      engine.applyFilter(frame, filter);
      // ignore: avoid_print
      print(
        '1920x1080: the shaders $shaderMs ms (read back), the engine '
        '${watch.elapsedMilliseconds} ms',
      );
      expect(data, isNotNull);
      source.dispose();
      image.dispose();
    });
  });
}
