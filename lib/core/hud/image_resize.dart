/// Shrinking an image by area averaging, as OpenCV's `INTER_AREA` does it
/// and the Python app scales a skin (spec §5.2): every output pixel is the
/// mean of the input pixels it covers, each weighted by the part of it
/// that is covered, every channel on its own.
library;

import 'dart:typed_data';

/// [rgba] ([width] x [height], four bytes a pixel) at [outWidth] x
/// [outHeight]. Meant for making an image smaller; a larger size repeats
/// pixels.
Uint8List areaResize(
  Uint8List rgba,
  int width,
  int height,
  int outWidth,
  int outHeight,
) {
  if (outWidth == width && outHeight == height) {
    return Uint8List.fromList(rgba);
  }
  // Per output column and row: the input pixels it covers and how much of
  // each.
  (List<int>, List<int>, Float64List) spans(int size, int outSize) {
    final scale = size / outSize;
    final starts = <int>[];
    final counts = <int>[];
    final weights = <double>[];
    for (var o = 0; o < outSize; o++) {
      final from = o * scale;
      final to = from + scale;
      final first = from.floor();
      var count = 0;
      for (var i = first; i < to && i < size; i++) {
        final covered = (i + 1 < to ? i + 1 : to) - (i > from ? i : from);
        if (covered > 1e-9) {
          weights.add(covered / scale);
          count++;
        }
      }
      starts.add(first);
      counts.add(count);
    }
    return (starts, counts, Float64List.fromList(weights));
  }

  final (xStart, xCount, xWeight) = spans(width, outWidth);
  final (yStart, yCount, yWeight) = spans(height, outHeight);
  // Columns first, then rows.
  final narrow = Float64List(outWidth * height * 4);
  for (var y = 0; y < height; y++) {
    var w = 0;
    for (var ox = 0; ox < outWidth; ox++) {
      var r = 0.0;
      var g = 0.0;
      var b = 0.0;
      var a = 0.0;
      final start = 4 * (y * width + xStart[ox]);
      for (var k = 0; k < xCount[ox]; k++) {
        final weight = xWeight[w++];
        final i = start + 4 * k;
        r += rgba[i] * weight;
        g += rgba[i + 1] * weight;
        b += rgba[i + 2] * weight;
        a += rgba[i + 3] * weight;
      }
      final o = 4 * (y * outWidth + ox);
      narrow[o] = r;
      narrow[o + 1] = g;
      narrow[o + 2] = b;
      narrow[o + 3] = a;
    }
  }
  final out = Uint8List(outWidth * outHeight * 4);
  var w = 0;
  for (var oy = 0; oy < outHeight; oy++) {
    final count = yCount[oy];
    for (var ox = 0; ox < outWidth; ox++) {
      var r = 0.0;
      var g = 0.0;
      var b = 0.0;
      var a = 0.0;
      for (var k = 0; k < count; k++) {
        final weight = yWeight[w + k];
        final i = 4 * ((yStart[oy] + k) * outWidth + ox);
        r += narrow[i] * weight;
        g += narrow[i + 1] * weight;
        b += narrow[i + 2] * weight;
        a += narrow[i + 3] * weight;
      }
      final o = 4 * (oy * outWidth + ox);
      out[o] = r.round().clamp(0, 255);
      out[o + 1] = g.round().clamp(0, 255);
      out[o + 2] = b.round().clamp(0, 255);
      out[o + 3] = a.round().clamp(0, 255);
    }
    w += count;
  }
  return out;
}
