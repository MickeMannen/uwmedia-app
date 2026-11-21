// The fast unsharp mask (lib/core/color/color_engine.dart) against the
// first port's plain one (kept here as the reference; it was checked
// against OpenCV on the colour fixture): equal bytes on random pictures of
// awkward sizes, whole and in bands of rows.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/util/py_round.dart';

final Float32List _single = Float32List(1);

double _f(double x) {
  _single[0] = x;
  return _single[0];
}

int _reflect101(int i, int n) {
  if (n == 1) {
    return 0;
  }
  var p = i;
  while (p < 0 || p >= n) {
    p = p < 0 ? -p : 2 * n - 2 - p;
  }
  return p;
}

Uint8List _reference(Uint8List rgb, int width, int height, double amount) {
  final kernel = fixedGaussianKernel(7, 1.0);
  const r = 3;
  final across = Int32List(rgb.length);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      for (var c = 0; c < 3; c++) {
        var s = 0;
        for (var k = -r; k <= r; k++) {
          s +=
              kernel[k + r] *
              rgb[(y * width + _reflect101(x + k, width)) * 3 + c];
        }
        across[(y * width + x) * 3 + c] = s;
      }
    }
  }
  final alpha = _f(1.0 + amount);
  final beta = _f(-amount);
  final out = Uint8List(rgb.length);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      for (var c = 0; c < 3; c++) {
        var s = 0;
        for (var k = -r; k <= r; k++) {
          s +=
              kernel[k + r] *
              across[(_reflect101(y + k, height) * width + x) * 3 + c];
        }
        final blurred = (s + 32768) >> 16;
        final i = (y * width + x) * 3 + c;
        out[i] = pyRound(_f(_f(rgb[i] * alpha) + _f(blurred * beta)))
            .clamp(0, 255);
      }
    }
  }
  return out;
}

void main() {
  final random = math.Random(7);
  Uint8List picture(int w, int h) => Uint8List.fromList([
    for (var i = 0; i < w * h * 3; i++) random.nextInt(256),
  ]);

  test('equal to the plain unsharp mask', () {
    for (final (w, h) in const [
      (1, 1), (2, 5), (3, 3), (7, 4), (8, 9), (33, 17), (64, 2), //
    ]) {
      final rgb = picture(w, h);
      for (final amount in const [0.47, 1.0, 2.5]) {
        expect(
          unsharp(rgb, w, h, amount),
          _reference(rgb, w, h, amount),
          reason: '$w x $h, $amount',
        );
      }
    }
  });

  test('in bands of rows, with three rows more on each side', () {
    const w = 23;
    const h = 31;
    final rgb = picture(w, h);
    final whole = unsharp(rgb, w, h, 0.47);
    for (final rows in const [1, 2, 5, 8, 31]) {
      final out = BytesBuilder();
      for (var from = 0; from < h; from += rows) {
        final to = math.min(h, from + rows);
        final top = math.max(0, from - 3);
        final bottom = math.min(h, to + 3);
        out.add(
          unsharpRows(
            Uint8List.sublistView(rgb, top * w * 3, bottom * w * 3),
            w,
            h,
            0.47,
            top,
            from,
            to,
          ),
        );
      }
      expect(out.takeBytes(), whole, reason: 'bands of $rows rows');
    }
  });
}
