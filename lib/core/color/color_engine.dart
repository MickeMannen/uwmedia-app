/// The underwater colour correction, ported from `ffmpeg/color.py` of the
/// Python app (`ColorCorrectionEngine`, spec §6): the analysis of a frame
/// into eleven numbers, the correction those numbers describe, the 3D LUT
/// of that correction and its `.cube` text.
///
/// The analysis, on a copy of the frame reduced to about 200 px:
///
/// 1. colour factors: how much red and blue are missing against green;
/// 2. the black point per channel, from a histogram cut-off;
/// 3. grey-world factors, weighted towards the foreground;
/// 4. a dehaze factor from the saturation histogram;
/// 5. an exposure factor from the brightness histogram;
/// 6. the hue of the water, from a histogram of OKLab hues.
///
/// Pure Dart on byte and float lists; the frame comes in as RGB bytes.
///
/// Numbers: the Python code works in 32-bit floats where NumPy does (the
/// sRGB tables, the colour factors, the black point and the whole of
/// `apply_filter`) and in 64-bit elsewhere, and so does this port, rounding
/// to 32 bits after each step where Python's value has 32. What cannot be
/// repeated bit for bit is NumPy's own 32-bit cube root, sine, cosine and
/// arc tangent, which can differ from the rounded 64-bit ones in the last
/// bit; a corrected pixel can therefore be one level off Python's now and
/// then. The sharpening repeats OpenCV's fixed-point blur of 8-bit images.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:uwmedia_app/core/util/py_round.dart';

final Float32List _single = Float32List(1);

/// [x] rounded to a 32-bit float.
double _f(double x) {
  _single[0] = x;
  return _single[0];
}

double _clamp01(double x) => x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x);

/// C `cbrt`.
double _cbrt(double x) {
  if (x == 0.0 || x.isNaN || x.isInfinite) {
    return x;
  }
  final a = x.abs();
  var y = math.exp(math.log(a) / 3.0);
  y -= (y * y * y - a) / (3.0 * y * y);
  return x < 0 ? -y : y;
}

/// NumPy's pairwise sum of [n] values `at(i)`; [round] rounds each partial
/// sum (to 32 bits for a float32 array).
double _pairwiseSum(
  double Function(int i) at,
  int start,
  int n,
  double Function(double) round,
) {
  if (n < 8) {
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      sum = round(sum + at(start + i));
    }
    return sum;
  }
  if (n <= 128) {
    final r = List<double>.generate(8, (k) => at(start + k));
    var i = 8;
    for (; i < n - (n % 8); i += 8) {
      for (var k = 0; k < 8; k++) {
        r[k] = round(r[k] + at(start + i + k));
      }
    }
    var sum = round(
      round(round(r[0] + r[1]) + round(r[2] + r[3])) +
          round(round(r[4] + r[5]) + round(r[6] + r[7])),
    );
    for (; i < n; i++) {
      sum = round(sum + at(start + i));
    }
    return sum;
  }
  var half = n ~/ 2;
  half -= half % 8;
  return round(
    _pairwiseSum(at, start, half, round) +
        _pairwiseSum(at, start + half, n - half, round),
  );
}

double _same(double x) => x;

double _sum(Float64List values) =>
    _pairwiseSum((i) => values[i], 0, values.length, _same);

/// A colour profile: the parameters of `color.yaml`, with the Python
/// engine's fallbacks for the ones a profile leaves out.
class ColorProfile {
  const ColorProfile({
    this.cifval = 1.0,
    this.redThreshold = 0.3,
    this.redScale = 0.2,
    this.blueThreshold = 0.3,
    this.blueScale = 0.6,
    this.blackPointCutoff = 0.001,
    this.gwMaskMult = 1.5,
    this.gwMaskFallback = 0.2,
    this.gwBlurRadius = 9,
    this.gwBlurSigma = 1.8,
    this.gwIsolationThreshold = 0.07,
    this.gwIsolationMinSum = 100.0,
    this.dehazeSatCutoff = 0.1,
    this.dehazeSatScale = 0.75,
    this.dehazeMin = 0.81,
    this.dehazeMax = 1.0,
    this.exposureCdfCutoff = 0.01,
    this.exposureNumerator = 0.5,
    this.exposureMin = 1.0,
    this.exposureMax = 2.0,
    this.bhMinIdx = 155,
    this.bhMaxIdx = 218,
    this.bhDecay = 0.85,
    this.bhFallback = 0.67,
    this.sharpness = 0.0,
    this.darkness = 0.0,
    this.vibrance = 0.0,
    this.contrast = 0.0,
  });

  /// From a profile of `color.yaml` (keys as there).
  factory ColorProfile.fromMap(Map<String, dynamic> map) {
    double number(String key, double fallback) =>
        map[key] is num ? (map[key] as num).toDouble() : fallback;
    int whole(String key, int fallback) =>
        map[key] is num ? (map[key] as num).truncate() : fallback;
    const d = ColorProfile();
    return ColorProfile(
      cifval: number('cifval', d.cifval),
      redThreshold: number('red_threshold', d.redThreshold),
      redScale: number('red_scale', d.redScale),
      blueThreshold: number('blue_threshold', d.blueThreshold),
      blueScale: number('blue_scale', d.blueScale),
      blackPointCutoff: number('black_point_cutoff', d.blackPointCutoff),
      gwMaskMult: number('gw_mask_mult', d.gwMaskMult),
      gwMaskFallback: number('gw_mask_fallback', d.gwMaskFallback),
      gwBlurRadius: whole('gw_blur_radius', d.gwBlurRadius),
      gwBlurSigma: number('gw_blur_sigma', d.gwBlurSigma),
      gwIsolationThreshold: number(
        'gw_isolation_threshold',
        d.gwIsolationThreshold,
      ),
      gwIsolationMinSum: number('gw_isolation_min_sum', d.gwIsolationMinSum),
      dehazeSatCutoff: number('dehaze_sat_cutoff', d.dehazeSatCutoff),
      dehazeSatScale: number('dehaze_sat_scale', d.dehazeSatScale),
      dehazeMin: number('dehaze_min', d.dehazeMin),
      dehazeMax: number('dehaze_max', d.dehazeMax),
      exposureCdfCutoff: number('exposure_cdf_cutoff', d.exposureCdfCutoff),
      exposureNumerator: number('exposure_numerator', d.exposureNumerator),
      exposureMin: number('exposure_min', d.exposureMin),
      exposureMax: number('exposure_max', d.exposureMax),
      bhMinIdx: whole('bh_min_idx', d.bhMinIdx),
      bhMaxIdx: whole('bh_max_idx', d.bhMaxIdx),
      bhDecay: number('bh_decay', d.bhDecay),
      bhFallback: number('bh_fallback', d.bhFallback),
      sharpness: number('sharpness', d.sharpness),
      darkness: number('darkness', d.darkness),
      vibrance: number('vibrance', d.vibrance),
      contrast: number('contrast', d.contrast),
    );
  }

  /// The profile with the keys of `color.yaml`, as [ColorProfile.fromMap]
  /// reads them.
  Map<String, num> toMap() => {
    'cifval': cifval,
    'red_threshold': redThreshold,
    'red_scale': redScale,
    'blue_threshold': blueThreshold,
    'blue_scale': blueScale,
    'black_point_cutoff': blackPointCutoff,
    'gw_mask_mult': gwMaskMult,
    'gw_mask_fallback': gwMaskFallback,
    'gw_blur_radius': gwBlurRadius,
    'gw_blur_sigma': gwBlurSigma,
    'gw_isolation_threshold': gwIsolationThreshold,
    'gw_isolation_min_sum': gwIsolationMinSum,
    'dehaze_sat_cutoff': dehazeSatCutoff,
    'dehaze_sat_scale': dehazeSatScale,
    'dehaze_min': dehazeMin,
    'dehaze_max': dehazeMax,
    'exposure_cdf_cutoff': exposureCdfCutoff,
    'exposure_numerator': exposureNumerator,
    'exposure_min': exposureMin,
    'exposure_max': exposureMax,
    'bh_min_idx': bhMinIdx,
    'bh_max_idx': bhMaxIdx,
    'bh_decay': bhDecay,
    'bh_fallback': bhFallback,
    'sharpness': sharpness,
    'darkness': darkness,
    'vibrance': vibrance,
    'contrast': contrast,
  };

  /// How much of the correction is mixed in (1 = all of it).
  final double cifval;
  final double redThreshold;
  final double redScale;
  final double blueThreshold;
  final double blueScale;
  final double blackPointCutoff;
  final double gwMaskMult;
  final double gwMaskFallback;
  final int gwBlurRadius;
  final double gwBlurSigma;
  final double gwIsolationThreshold;
  final double gwIsolationMinSum;
  final double dehazeSatCutoff;
  final double dehazeSatScale;
  final double dehazeMin;
  final double dehazeMax;
  final double exposureCdfCutoff;
  final double exposureNumerator;
  final double exposureMin;
  final double exposureMax;
  final int bhMinIdx;
  final int bhMaxIdx;
  final double bhDecay;
  final double bhFallback;

  /// The strength of the unsharp mask (0 = none).
  final double sharpness;
  final double darkness;

  /// More colour, most where there is little of it and least in the
  /// water's own hues (0 = none; the OKLCH chroma times up to
  /// 1 + vibrance). Not in the Python app (spec §10.101).
  final double vibrance;

  /// An S-curve on the OKLab lightness (0 = none, 1 = a full smoothstep).
  /// Not in the Python app (spec §10.101).
  final double contrast;
}

/// The six results of the analysis, before they are packed into the eleven
/// 32-bit numbers of a filter.
class ColorAnalysis {
  const ColorAnalysis(
    this.cf,
    this.bp,
    this.gw,
    this.dehaze,
    this.exposure,
    this.blueHue,
  );

  /// Red and blue restoration.
  final (double, double) cf;

  /// Black point per channel.
  final (double, double, double) bp;

  /// Grey-world factors per channel.
  final (double, double, double) gw;
  final double dehaze;
  final double exposure;
  final double blueHue;

  /// The filter: these eleven numbers as 32-bit floats.
  Float32List get filter => Float32List.fromList([
    cf.$1,
    cf.$2,
    bp.$1,
    bp.$2,
    bp.$3,
    gw.$1,
    gw.$2,
    gw.$3,
    dehaze,
    exposure,
    blueHue,
  ]);
}

/// An RGB image, three bytes a pixel.
class RgbImage {
  RgbImage(this.width, this.height, this.rgb)
    : assert(rgb.length == width * height * 3, 'three bytes a pixel');

  final int width;
  final int height;
  final Uint8List rgb;
}

/// OpenCV `resize(..., INTER_AREA)` of an 8-bit image to a smaller size.
RgbImage resizeAreaCv(RgbImage src, int outWidth, int outHeight) {
  final w = src.width;
  final h = src.height;
  if (outWidth == w && outHeight == h) {
    return RgbImage(w, h, Uint8List.fromList(src.rgb));
  }
  final out = Uint8List(outWidth * outHeight * 3);
  final wholeX = w % outWidth == 0;
  final wholeY = h % outHeight == 0;
  if (wholeX && wholeY) {
    final fx = w ~/ outWidth;
    final fy = h ~/ outHeight;
    final scale = _f(1.0 / (fx * fy));
    for (var oy = 0; oy < outHeight; oy++) {
      for (var ox = 0; ox < outWidth; ox++) {
        for (var c = 0; c < 3; c++) {
          var sum = 0;
          for (var y = 0; y < fy; y++) {
            final row = ((oy * fy + y) * w + ox * fx) * 3 + c;
            for (var x = 0; x < fx; x++) {
              sum += src.rgb[row + 3 * x];
            }
          }
          out[(oy * outWidth + ox) * 3 + c] = fx == 2 && fy == 2
              ? (sum + 2) >> 2
              : pyRound(_f(sum * scale)).clamp(0, 255);
        }
      }
    }
    return RgbImage(outWidth, outHeight, out);
  }

  // The general case: each output pixel takes the input pixels it covers,
  // the cut ones by the part covered, summed in 32-bit floats.
  List<(int, int, double)> table(int size, int outSize) {
    final scale = size / outSize;
    final tab = <(int, int, double)>[];
    for (var d = 0; d < outSize; d++) {
      final from = d * scale;
      final to = from + scale;
      final cell = math.min(scale, size - from);
      var s1 = from.ceil();
      final s2 = math.min(to.floor(), size - 1);
      s1 = math.min(s1, s2);
      if (s1 - from > 1e-3) {
        tab.add((d, s1 - 1, _f((s1 - from) / cell)));
      }
      for (var s = s1; s < s2; s++) {
        tab.add((d, s, _f(1.0 / cell)));
      }
      if (to - s2 > 1e-3) {
        tab.add((d, s2, _f(math.min(math.min(to - s2, 1.0), cell) / cell)));
      }
    }
    return tab;
  }

  final xTab = table(w, outWidth);
  final yTab = table(h, outHeight);
  final row = Float32List(outWidth * 3);
  final sum = Float32List(outWidth * 3);
  var previous = -1;
  void flush(int dy) {
    for (var i = 0; i < sum.length; i++) {
      out[dy * outWidth * 3 + i] = pyRound(sum[i]).clamp(0, 255);
    }
  }

  for (final (dy, sy, beta) in yTab) {
    row.fillRange(0, row.length, 0);
    for (final (dx, sx, alpha) in xTab) {
      for (var c = 0; c < 3; c++) {
        final i = dx * 3 + c;
        // One rounding for the product and the sum together (a fused
        // multiply-add, as OpenCV's build does it here; not so below).
        row[i] = row[i] + src.rgb[(sy * w + sx) * 3 + c] * alpha;
      }
    }
    if (dy != previous) {
      if (previous >= 0) {
        flush(previous);
      }
      for (var i = 0; i < sum.length; i++) {
        sum[i] = beta * row[i];
      }
      previous = dy;
    } else {
      for (var i = 0; i < sum.length; i++) {
        sum[i] = sum[i] + _f(beta * row[i]);
      }
    }
  }
  if (previous >= 0) {
    flush(previous);
  }
  return RgbImage(outWidth, outHeight, out);
}

/// OpenCV `getGaussianKernel(size, sigma)` for a sigma above 0.
Float64List gaussianKernel(int size, double sigma) {
  final kernel = Float64List(size);
  final centre = (size - 1) * 0.5;
  final scale = -0.5 / (sigma * sigma);
  var sum = 0.0;
  for (var i = 0; i < size; i++) {
    final x = i - centre;
    kernel[i] = math.exp(scale * x * x);
    sum += kernel[i];
  }
  for (var i = 0; i < size; i++) {
    kernel[i] /= sum;
  }
  return kernel;
}

/// The index of a pixel [i] outside 0..[n]-1, mirrored without repeating
/// the edge (OpenCV's default border).
int _reflect101(int i, int n) {
  if (n == 1) {
    return 0;
  }
  var p = i;
  while (p < 0 || p >= n) {
    p = p < 0 ? -p : 2 * (n - 1) - p;
  }
  return p;
}

/// A separable symmetric blur of one channel plane, in 64-bit floats.
Float64List _blurPlane(Float64List plane, int w, int h, Float64List kernel) {
  final r = kernel.length ~/ 2;
  final tmp = Float64List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var s = kernel[r] * plane[y * w + x];
      for (var k = 1; k <= r; k++) {
        s +=
            kernel[r + k] *
            (plane[y * w + _reflect101(x - k, w)] +
                plane[y * w + _reflect101(x + k, w)]);
      }
      tmp[y * w + x] = s;
    }
  }
  final out = Float64List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var s = kernel[r] * tmp[y * w + x];
      for (var k = 1; k <= r; k++) {
        s +=
            kernel[r + k] *
            (tmp[_reflect101(y - k, h) * w + x] +
                tmp[_reflect101(y + k, h) * w + x]);
      }
      out[y * w + x] = s;
    }
  }
  return out;
}

// OKLab, as the Python code writes it.
const double _l1 = 0.4122214708;
const double _l2 = 0.5363325363;
const double _l3 = 0.0514459929;
const double _m1 = 0.2119034982;
const double _m2 = 0.6806995451;
const double _m3 = 0.1073969566;
const double _s1 = 0.0883024619;
const double _s2 = 0.2817188376;
const double _s3 = 0.6299787005;

/// Colours already corrected, by their 24-bit value: an open-addressed
/// table that stops taking new ones when it is two-thirds full (the rest
/// are then worked out each time).
class _ColourMemo {
  factory _ColourMemo(int pixels) {
    var bits = 10;
    while ((1 << bits) < pixels * 2 && bits < 22) {
      bits++;
    }
    return _ColourMemo._(bits);
  }

  _ColourMemo._(this._bits)
    : _keys = Int32List(1 << _bits)..fillRange(0, 1 << _bits, -1),
      _values = Int32List(1 << _bits),
      _limit = (1 << _bits) * 2 ~/ 3;

  final int _bits;
  final Int32List _keys;
  final Int32List _values;
  final int _limit;
  int _count = 0;

  int _slot(int key) => ((key * 0x9E3779B1) & 0xFFFFFFFF) >> (32 - _bits);

  /// The result for [key], or -1.
  int get(int key) {
    final mask = _keys.length - 1;
    var i = _slot(key);
    while (true) {
      final k = _keys[i];
      if (k == key) {
        return _values[i];
      }
      if (k < 0) {
        return -1;
      }
      i = (i + 1) & mask;
    }
  }

  void put(int key, int value) {
    if (_count >= _limit) {
      return;
    }
    final mask = _keys.length - 1;
    var i = _slot(key);
    while (_keys[i] >= 0) {
      i = (i + 1) & mask;
    }
    _keys[i] = key;
    _values[i] = value;
    _count++;
  }
}

/// The first 3D LUT size the Python app writes.
const int lutSize = 64;

/// The colour engine for one profile.
class ColorEngine {
  ColorEngine(this.profile) {
    for (var i = 0; i < 256; i++) {
      final v = i / 255.0;
      lutLinear[i] = v <= 0.04045
          ? v / 12.92
          : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    }
    for (var i = 0; i < 4096; i++) {
      final v = i / 4095.0;
      lutSrgb[i] = v <= 0.0031308
          ? v * 12.92
          : math.pow(v, 0.41666666667) * 1.055 - 0.055;
    }
  }

  final ColorProfile profile;

  /// sRGB byte to linear light.
  final Float32List lutLinear = Float32List(256);

  /// Linear light (in 4096 steps) to sRGB.
  final Float32List lutSrgb = Float32List(4096);

  // --- the analysis ---

  /// The frame reduced by powers of two until a side is 200 px or less.
  RgbImage reduced(RgbImage frame) {
    var scale = 1;
    while (frame.width / scale > 200 && frame.height / scale > 200) {
      scale *= 2;
    }
    return resizeAreaCv(frame, frame.width ~/ scale, frame.height ~/ scale);
  }

  /// The analysis of [frame] (any size).
  ColorAnalysis analyze(RgbImage frame) {
    final small = reduced(frame);
    final n = small.width * small.height;
    final linear = Float32List(n * 3);
    for (var i = 0; i < n * 3; i++) {
      linear[i] = lutLinear[small.rgb[i]];
    }
    final cf = _colorFactors(linear, n);
    // Red and blue restored from green, in 32-bit floats: what every later
    // stage starts from.
    final restored = Float32List(n * 3);
    for (var i = 0; i < n; i++) {
      final r = linear[3 * i];
      final g = linear[3 * i + 1];
      final b = linear[3 * i + 2];
      restored[3 * i] = _f(r + _f(_f(cf.$1 * _f(1.0 - r)) * g));
      restored[3 * i + 1] = g;
      restored[3 * i + 2] = _f(b + _f(_f(cf.$2 * _f(1.0 - b)) * g));
    }
    final bp = _blackPoint(restored, n);
    final gw = _greyWorld(restored, small.width, small.height, bp);
    // Black point off and balanced, clipped: the start of the last three.
    final balanced = Float64List(n * 3);
    final bps = [bp.$1, bp.$2, bp.$3];
    final gws = [gw.$1, gw.$2, gw.$3];
    for (var i = 0; i < n * 3; i++) {
      balanced[i] = _clamp01((restored[i] - bps[i % 3]) * gws[i % 3]);
    }
    final dehaze = _dehaze(balanced, n);
    final exposure = _exposure(balanced, n, dehaze);
    final blueHue = _blueHue(balanced, n, dehaze, exposure);
    return ColorAnalysis(cf, bp, gw, dehaze, exposure, blueHue);
  }

  /// The eleven numbers of [frame]'s filter.
  Float32List filterOf(RgbImage frame) => analyze(frame).filter;

  (double, double) _colorFactors(Float32List linear, int n) {
    double mean(int channel) =>
        _f(_pairwiseSum((i) => linear[3 * i + channel], 0, n, _f) / n);
    final meanR = mean(0);
    final meanG = mean(1);
    final meanB = mean(2);
    double factor(double other, double threshold, double scale) {
      if (!(meanG > other && meanG > 0)) {
        return 0.0;
      }
      final value = _f(
        _f(_f(_f(meanG - other) / meanG) - _f(threshold)) / _f(scale),
      );
      return math.max(0.0, math.min(1.0, value));
    }

    return (
      factor(meanR, profile.redThreshold, profile.redScale),
      factor(meanB, profile.blueThreshold, profile.blueScale),
    );
  }

  (double, double, double) _blackPoint(Float32List restored, int n) {
    final bp = [0.0, 0.0, 0.0];
    for (var c = 0; c < 3; c++) {
      final hist = List<int>.filled(256, 0);
      for (var i = 0; i < n; i++) {
        hist[_f(_clamp01(restored[3 * i + c]) * 255.0).truncate()]++;
      }
      var seen = 0;
      for (var level = 0; level < 256; level++) {
        seen += hist[level];
        if (seen / n > profile.blackPointCutoff) {
          bp[c] = math.max((level - 1) / 255.0, 0.0);
          break;
        }
      }
    }
    return (bp[0], bp[1], bp[2]);
  }

  (double, double, double) _greyWorld(
    Float32List restored,
    int w,
    int h,
    (double, double, double) bp,
  ) {
    final n = w * h;
    final r = Float64List(n);
    final g = Float64List(n);
    final b = Float64List(n);
    for (var i = 0; i < n; i++) {
      r[i] = _clamp01(restored[3 * i] - bp.$1);
      g[i] = _clamp01(restored[3 * i + 1] - bp.$2);
      b[i] = _clamp01(restored[3 * i + 2] - bp.$3);
    }
    var size = profile.gwBlurRadius;
    if (size.isEven) {
      size++;
    }
    final kernel = gaussianKernel(size, profile.gwBlurSigma);
    final blurG = _blurPlane(g, w, h, kernel);
    final blurB = _blurPlane(b, w, h, kernel);

    final weightR = Float64List(n);
    final weightG = Float64List(n);
    final weightB = Float64List(n);
    final weight = Float64List(n);
    final isoR = Float64List(n);
    final isoG = Float64List(n);
    final isoB = Float64List(n);
    final iso = Float64List(n);
    for (var i = 0; i < n; i++) {
      final f = b[i] < g[i] * profile.gwMaskMult ? 1.0 : profile.gwMaskFallback;
      weight[i] = f;
      weightR[i] = r[i] * f;
      weightG[i] = f * g[i];
      weightB[i] = f * b[i];
      if ((g[i] - blurG[i]).abs() + (b[i] - blurB[i]).abs() >
          profile.gwIsolationThreshold) {
        iso[i] = f;
        isoR[i] = weightR[i];
        isoG[i] = weightG[i];
        isoB[i] = weightB[i];
      }
    }
    // A channel with nothing in it (an all-black frame) keeps its level:
    // Python divides 0 by 0 there, and the NaN makes the frame's filter
    // and LUT unusable (spec §10.55).
    (double, double, double) ratios(double x, double y, double z) {
      final least = math.min(x, math.min(y, z));
      double ratio(double mean) => mean == 0 ? 1.0 : least / mean;
      return (ratio(x), ratio(y), ratio(z));
    }

    final isolated = _sum(iso);
    if (isolated > profile.gwIsolationMinSum) {
      return ratios(
        _sum(isoR) / isolated,
        _sum(isoG) / isolated,
        _sum(isoB) / isolated,
      );
    }
    final all = _sum(weight);
    return ratios(
      _sum(weightR) / all,
      _sum(weightG) / all,
      _sum(weightB) / all,
    );
  }

  /// The first level from 255 down to 2 at which the share of pixels at or
  /// above it passes [cutoff], as a fraction of 255; [otherwise] if none.
  static double _fromTheTop(
    List<int> hist,
    int n,
    double cutoff,
    double otherwise,
  ) {
    var share = 0.0;
    for (var i = 255; i > 1; i--) {
      share += hist[i] / n;
      if (share > cutoff) {
        return i / 255.0;
      }
    }
    return otherwise;
  }

  double _dehaze(Float64List balanced, int n) {
    final hist = List<int>.filled(256, 0);
    for (var i = 0; i < n; i++) {
      final r = (balanced[3 * i] * 255.0).truncate();
      final g = (balanced[3 * i + 1] * 255.0).truncate();
      final b = (balanced[3 * i + 2] * 255.0).truncate();
      final high = math.max(r, math.max(g, b));
      final low = math.min(r, math.min(g, b));
      hist[high == 0 ? 0 : pyRound((high - low) / high * 255.0)]++;
    }
    final f = _fromTheTop(hist, n, profile.dehazeSatCutoff, 0.0);
    return math.max(
      profile.dehazeMin,
      math.min(profile.dehazeMax, f / profile.dehazeSatScale),
    );
  }

  /// A balanced pixel with the dehaze curve and an exposure applied.
  static void _dehazed(
    Float64List balanced,
    int i,
    double dehaze,
    double exposure,
    List<double> out,
  ) {
    final r = balanced[3 * i];
    final g = balanced[3 * i + 1];
    final b = balanced[3 * i + 2];
    final high = math.max(r, math.max(g, b));
    final curve = high / dehaze + 1.0 - high;
    out[0] = _clamp01(exposure * (curve * (r - 1.0) + 1.0));
    out[1] = _clamp01(exposure * (curve * (g - 1.0) + 1.0));
    out[2] = _clamp01(exposure * (curve * (b - 1.0) + 1.0));
  }

  double _exposure(Float64List balanced, int n, double dehaze) {
    final hist = List<int>.filled(256, 0);
    final v = [0.0, 0.0, 0.0];
    for (var i = 0; i < n; i++) {
      _dehazed(balanced, i, dehaze, 1.0, v);
      final r = (v[0] * 255.0).truncate();
      final g = (v[1] * 255.0).truncate();
      final b = (v[2] * 255.0).truncate();
      hist[pyRound(
        (math.max(r, math.max(g, b)) + math.min(r, math.min(g, b))) / 2.0,
      )]++;
    }
    final f = _fromTheTop(hist, n, profile.exposureCdfCutoff, 0.5);
    return math.min(
      profile.exposureMax,
      math.max(profile.exposureMin, profile.exposureNumerator / f),
    );
  }

  double _blueHue(Float64List balanced, int n, double dehaze, double exposure) {
    final hist = List<int>.filled(256, 0);
    final v = [0.0, 0.0, 0.0];
    for (var i = 0; i < n; i++) {
      _dehazed(balanced, i, dehaze, exposure, v);
      final l = _cbrt(_l1 * v[0] + _l2 * v[1] + _l3 * v[2]);
      final m = _cbrt(_m1 * v[0] + _m2 * v[1] + _m3 * v[2]);
      final s = _cbrt(_s1 * v[0] + _s2 * v[1] + _s3 * v[2]);
      final a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
      final b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
      var hue = math.atan2(b, a) / (2.0 * math.pi);
      if (hue < 0.0) {
        hue += 1.0;
      }
      hist[(_clamp01(hue) * 255.0).truncate()]++;
    }
    var best = 0.0;
    var target = 0;
    final maxIdx = math.min(profile.bhMaxIdx, 255);
    var minIdx = math.min(profile.bhMinIdx, 254);
    if (minIdx >= maxIdx) {
      minIdx = maxIdx - 1;
    }
    double share(int i) => hist[i < 0 ? i + 256 : i] / n;
    for (var i = minIdx; i < maxIdx; i++) {
      final f =
          share(i) +
          (share(i - 1) * profile.bhDecay) +
          (share(i + 1) * profile.bhDecay);
      if (f > best) {
        target = i;
        best = f;
      }
    }
    return best > 0.04 ? target / 255.0 : profile.bhFallback;
  }

  // --- the correction ---

  static void _toOklch(List<double> v, List<double> out) {
    final l = _f(
      _cbrt(
        _f(_f(_f(_f(_l1) * v[0]) + _f(_f(_l2) * v[1])) + _f(_f(_l3) * v[2])),
      ),
    );
    final m = _f(
      _cbrt(
        _f(_f(_f(_f(_m1) * v[0]) + _f(_f(_m2) * v[1])) + _f(_f(_m3) * v[2])),
      ),
    );
    final s = _f(
      _cbrt(
        _f(_f(_f(_f(_s1) * v[0]) + _f(_f(_s2) * v[1])) + _f(_f(_s3) * v[2])),
      ),
    );
    double mix(double a, double b, double c) =>
        _f(_f(_f(_f(a) * l) + _f(_f(b) * m)) + _f(_f(c) * s));
    final lightness = mix(0.2104542553, 0.7936177850, -0.0040720468);
    final a = mix(1.9779984951, -2.4285922050, 0.4505937099);
    final b = mix(0.0259040371, 0.7827717662, -0.8086757660);
    var hue = _f(_f(math.atan2(b, a)) / _f(2.0 * math.pi));
    if (hue < 0.0) {
      hue = _f(hue + 1.0);
    }
    out[0] = lightness;
    out[1] = _f(math.sqrt(_f(_f(a * a) + _f(b * b))));
    out[2] = hue;
  }

  static void _toRgb(List<double> lch, List<double> out) {
    final angle = _f(_f(2.0 * math.pi) * lch[2]);
    final a = _f(lch[1] * _f(math.cos(angle)));
    final b = _f(lch[1] * _f(math.sin(angle)));
    double cubed(double x, double y) {
      final v = _f(_f(lch[0] + _f(_f(x) * a)) + _f(_f(y) * b));
      return _f(_f(v * v) * v);
    }

    final l = cubed(0.3963377774, 0.2158037573);
    final m = cubed(-0.1055613458, -0.0638541728);
    final s = cubed(-0.0894841775, -1.2914855480);
    double mix(double x, double y, double z) =>
        _f(_f(_f(_f(x) * l) + _f(_f(y) * m)) + _f(_f(z) * s));
    out[0] = mix(4.0767416621, -3.3077115913, 0.2309699292);
    out[1] = mix(-1.2684380046, 2.6097574011, -0.3413193965);
    out[2] = mix(-0.0041960863, -0.7034186147, 1.7076147010);
  }

  /// The profile's contrast and vibrance on an OKLCH colour, in place
  /// (spec §6 and §10.101). [scratch] is working room of three numbers.
  ///
  /// The contrast is an S-curve on the lightness. The vibrance scales the
  /// chroma, most for weak colours and not at all from [_vibranceFull] up;
  /// a colour pushed out of sRGB is brought back along its chroma, so its
  /// hue and lightness stay. `shaders/color_correct.frag` does the same.
  void _look(List<double> lch, List<double> scratch) {
    final contrast = profile.contrast;
    if (contrast != 0.0) {
      final l = _clamp01(lch[0]);
      final curved = l * l * (3.0 - 2.0 * l);
      lch[0] = l + contrast * (curved - l);
    }
    final vibrance = profile.vibrance;
    if (vibrance == 0.0) {
      return;
    }
    final before = lch[1];
    final room = 1.0 - _clamp01(before / _vibranceFull);
    // The water's own hues get a third of it: the reef and the fish are to
    // stand out from the water, not the water to turn neon.
    final fromWater = (lch[2] - profile.bhFallback).abs();
    final away = _clamp01((fromWater - 0.07) / 0.10);
    final weight = 0.35 + 0.65 * away * away * (3.0 - 2.0 * away);
    final wanted = before * (1.0 + vibrance * weight * room);
    bool inGamut(double chroma) {
      lch[1] = chroma;
      _toRgb(lch, scratch);
      for (var c = 0; c < 3; c++) {
        if (scratch[c] < -0.0005 || scratch[c] > 1.0005) {
          return false;
        }
      }
      return true;
    }

    if (inGamut(wanted)) {
      return;
    }
    var low = before;
    var high = wanted;
    for (var i = 0; i < 6; i++) {
      final mid = (low + high) / 2.0;
      if (inGamut(mid)) {
        low = mid;
      } else {
        high = mid;
      }
    }
    lch[1] = low;
  }

  /// The OKLCH chroma from which the vibrance adds nothing.
  static const double _vibranceFull = 0.3;

  /// [rgb] (three bytes a pixel) corrected by [filter], without the
  /// sharpening.
  Uint8List correct(Uint8List rgb, Float32List filter) {
    final out = Uint8List(rgb.length);
    final cfR = filter[0];
    final cfB = filter[1];
    final bp = [filter[2], filter[3], filter[4]];
    final gw = [filter[5], filter[6], filter[7]];
    final dehaze = filter[8];
    final exposure = _f(filter[9] * _f(1.0 - profile.darkness));
    final hueShift = _f(_f(profile.bhFallback) - filter[10]);
    final cif = profile.cifval;
    final keep = _f(1.0 - cif);
    final v = [0.0, 0.0, 0.0];
    final original = [0.0, 0.0, 0.0];
    final lch = [0.0, 0.0, 0.0];
    // A pixel's result depends on its colour alone: each colour is worked
    // out once (a photo has far fewer colours than pixels).
    final memo = _ColourMemo(rgb.length ~/ 3);
    for (var p = 0; p < rgb.length; p += 3) {
      final key = rgb[p] << 16 | rgb[p + 1] << 8 | rgb[p + 2];
      final known = memo.get(key);
      if (known >= 0) {
        out[p] = known >> 16;
        out[p + 1] = (known >> 8) & 0xFF;
        out[p + 2] = known & 0xFF;
        continue;
      }
      for (var c = 0; c < 3; c++) {
        original[c] = lutLinear[rgb[p + c]];
      }
      // Red and blue restored from green.
      v[0] = _f(
        original[0] + _f(_f(cfR * _f(1.0 - original[0])) * original[1]),
      );
      v[1] = original[1];
      v[2] = _f(
        original[2] + _f(_f(cfB * _f(1.0 - original[2])) * original[1]),
      );
      // The black point off, then the balance.
      for (var c = 0; c < 3; c++) {
        v[c] = _clamp01(_f(_f(v[c] - bp[c]) * gw[c]));
      }
      // The dehaze curve, the exposure and the darkness.
      final high = math.max(v[0], math.max(v[1], v[2]));
      final curve = _f(_f(_f(high / dehaze) + 1.0) - high);
      for (var c = 0; c < 3; c++) {
        v[c] = _clamp01(_f(exposure * _f(_f(curve * _f(v[c] - 1.0)) + 1.0)));
      }
      // The hue moved towards the reference water colour, less so for
      // hues away from blue.
      _toOklch(v, lch);
      var damping = 1.0;
      if (lch[2] > _f(0.81)) {
        damping = _f(1.0 + _f(_f(lch[2] - _f(0.81)) / _f(0.07)));
      }
      if (lch[2] < _f(0.65)) {
        damping = _f(1.0 + _f(_f(_f(0.65) - lch[2]) / _f(0.07)));
      }
      damping = math.min(damping, 1.5);
      var hue = _f(lch[2] + _f(hueShift / damping));
      if (hue > 1.0) {
        hue = _f(hue - 1.0);
      }
      if (hue < 0.0) {
        hue = _f(hue + 1.0);
      }
      lch[2] = hue;
      if (profile.vibrance != 0.0 || profile.contrast != 0.0) {
        _look(lch, v);
      }
      _toRgb(lch, v);
      for (var c = 0; c < 3; c++) {
        v[c] = _clamp01(v[c]);
      }
      if (cif != 1.0) {
        // Mixed with the uncorrected pixel.
        for (var c = 0; c < 3; c++) {
          v[c] = _f(_f(v[c] * _f(cif)) + _f(original[c] * keep));
        }
        _toOklch(v, lch);
        _toRgb(lch, v);
        for (var c = 0; c < 3; c++) {
          v[c] = _clamp01(v[c]);
        }
      }
      for (var c = 0; c < 3; c++) {
        final index = _f(_f(v[c] * 4095.0) + 0.5).clamp(0, 4095).truncate();
        out[p + c] = _f(_clamp01(lutSrgb[index]) * 255.0).truncate();
      }
      memo.put(key, out[p] << 16 | out[p + 1] << 8 | out[p + 2]);
    }
    return out;
  }

  /// Python `apply_filter`: [image] corrected by [filter], then sharpened
  /// when the profile asks for it.
  RgbImage applyFilter(RgbImage image, Float32List filter) {
    final corrected = correct(image.rgb, filter);
    return RgbImage(
      image.width,
      image.height,
      profile.sharpness > 0.0
          ? unsharp(corrected, image.width, image.height, profile.sharpness)
          : corrected,
    );
  }

  // --- the LUT ---

  /// The 3D LUT of [filter]: [size]³ entries of three bytes, red changing
  /// fastest, then green, then blue.
  ///
  /// The correction alone, without the profile's sharpening (owner,
  /// 2026-11-19; spec §10.21). Python makes the table with `apply_filter`
  /// on the entries laid out as one row, so its sharpening sharpens each
  /// entry against the next steps of red: no sharpening of the picture,
  /// but a video's colours up to some 30 levels off a photo's with the
  /// same profile. A video is not sharpened either way.
  Uint8List lut3d(Float32List filter, {int size = lutSize}) {
    final steps = [
      for (var i = 0; i < size; i++)
        i == size - 1 ? 255 : (i * (255.0 / (size - 1))).truncate(),
    ];
    final grid = Uint8List(size * size * size * 3);
    var p = 0;
    for (final b in steps) {
      for (final g in steps) {
        for (final r in steps) {
          grid[p++] = r;
          grid[p++] = g;
          grid[p++] = b;
        }
      }
    }
    return correct(grid, filter);
  }
}

/// The `.cube` text of a LUT of [size]³ byte triples (red fastest).
String cubeFileText(Uint8List lut, int size, {String title = 'UWMedia'}) {
  final levels = [
    for (var i = 0; i < 256; i++) pyFormatFixed(_f(i / 255.0), 6),
  ];
  final buffer = StringBuffer()
    ..write('TITLE "$title"\n')
    ..write('LUT_3D_SIZE $size\n\n');
  for (var p = 0; p < lut.length; p += 3) {
    buffer.write(
      '${levels[lut[p]]} ${levels[lut[p + 1]]} ${levels[lut[p + 2]]}\n',
    );
  }
  return buffer.toString();
}

/// NumPy `allclose(a, b, atol=0.01)` on two filters: every number of [a]
/// within 0.01 (and a hundred-thousandth of its size) of [b]'s.
bool filtersClose(Float32List a, Float32List b) {
  for (var i = 0; i < a.length; i++) {
    final limit = _f(_f(0.01) + _f(_f(1e-5) * b[i].abs()));
    if (!(_f(a[i] - b[i]).abs() <= limit)) {
      return false;
    }
  }
  return true;
}

/// The filters of a clip worth a LUT of their own: each one that is not
/// close to the one kept before it, with the frame index it starts at.
List<(int, Float32List)> distinctFilters(
  List<int> frameIndices,
  List<Float32List> filters,
) {
  final out = <(int, Float32List)>[];
  for (var i = 0; i < filters.length; i++) {
    if (out.isEmpty || !filtersClose(filters[i], out.last.$2)) {
      out.add((frameIndices[i], filters[i]));
    }
  }
  return out;
}

/// OpenCV's fixed-point Gaussian kernel for 8-bit images: [size] weights
/// in 1/256ths that add up to 256, the rounding error passed along from
/// the edge to the centre.
List<int> fixedGaussianKernel(int size, double sigma) {
  final exact = gaussianKernel(size, sigma);
  final kernel = List<int>.filled(size, 0);
  var error = 0.0;
  var used = 0;
  for (var i = 0; i < size ~/ 2; i++) {
    final wanted = exact[i] * 256.0 + error;
    final weight = pyRound(wanted);
    error = wanted - weight;
    kernel[i] = weight;
    kernel[size - 1 - i] = weight;
    used += 2 * weight;
  }
  kernel[size ~/ 2] = 256 - used;
  return kernel;
}

/// The Python app's unsharp mask on corrected bytes: the image plus
/// [amount] times its difference from a Gaussian blur of sigma 1 (seven
/// pixels wide, in OpenCV's 8-bit fixed-point arithmetic).
Uint8List unsharp(Uint8List rgb, int width, int height, double amount) =>
    unsharpRows(rgb, width, height, amount, 0, 0, height);

/// [unsharp] for rows [from] to [to] (not included) of an image [height]
/// rows high, of which [band] holds the rows from [bandTop] on: enough of
/// them for the blur (three more on each side, where there are any). The
/// rows of the result, in the same layout as [band]'s.
Uint8List unsharpRows(
  Uint8List band,
  int width,
  int height,
  double amount,
  int bandTop,
  int from,
  int to,
) {
  final kernel = fixedGaussianKernel(7, 1.0);
  final k0 = kernel[0], k1 = kernel[1], k2 = kernel[2], k3 = kernel[3];
  const r = 3;
  final rowBytes = width * 3;
  final bandRows = band.length ~/ rowBytes;
  // The blur across, for every row of the band.
  final across = Int32List(band.length);
  // Where each column's seven taps lie (the edges reflected).
  final taps = Int32List(width * 7);
  for (var x = 0; x < width; x++) {
    for (var k = -r; k <= r; k++) {
      taps[x * 7 + k + r] = _reflect101(x + k, width) * 3;
    }
  }
  for (var y = 0; y < bandRows; y++) {
    final row = y * rowBytes;
    for (var x = 0; x < width; x++) {
      final t = x * 7;
      if (x >= r && x < width - r) {
        // Inside: the neighbours lie three bytes apart.
        for (var c = 0; c < 3; c++) {
          final i = row + x * 3 + c;
          across[i] =
              k0 * (band[i - 9] + band[i + 9]) +
              k1 * (band[i - 6] + band[i + 6]) +
              k2 * (band[i - 3] + band[i + 3]) +
              k3 * band[i];
        }
      } else {
        for (var c = 0; c < 3; c++) {
          var sum = 0;
          for (var k = 0; k < 7; k++) {
            sum += kernel[k] * band[row + taps[t + k] + c];
          }
          across[row + x * 3 + c] = sum;
        }
      }
    }
  }
  final alpha = _f(1.0 + amount);
  final beta = _f(-amount);
  // The result depends on the byte and its blur alone (both 0 to 255):
  // worked out once for every pair.
  final result = Uint8List(256 * 256);
  for (var v = 0; v < 256; v++) {
    final scaled = _f(v * alpha);
    for (var b = 0; b < 256; b++) {
      result[v << 8 | b] = pyRound(_f(scaled + _f(b * beta))).clamp(0, 255);
    }
  }
  // The rows down the image each output row takes, as rows of the band.
  final out = Uint8List((to - from) * rowBytes);
  final rows = Int32List(7);
  for (var y = from; y < to; y++) {
    for (var k = -r; k <= r; k++) {
      rows[k + r] = (_reflect101(y + k, height) - bandTop) * rowBytes;
    }
    final at = (y - bandTop) * rowBytes;
    final o = (y - from) * rowBytes;
    final r0 = rows[0], r1 = rows[1], r2 = rows[2], r3 = rows[3];
    final r4 = rows[4], r5 = rows[5], r6 = rows[6];
    for (var j = 0; j < rowBytes; j++) {
      final s =
          k0 * (across[r0 + j] + across[r6 + j]) +
          k1 * (across[r1 + j] + across[r5 + j]) +
          k2 * (across[r2 + j] + across[r4 + j]) +
          k3 * across[r3 + j];
      out[o + j] = result[band[at + j] << 8 | (s + 32768) >> 16];
    }
  }
  return out;
}
