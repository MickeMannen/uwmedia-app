// The colour engine against the Python app: the fixture made by
// tool/python_reference/color_fixture.py (the analysis of eight frames with
// four profiles, the correction of a piece of each, nine LUTs and a .cube
// text). The made-up frames are built here by the generator's own formula.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/color/color_engine.dart';
import 'package:uwmedia_app/core/color/color_profiles.dart';

final Map<String, dynamic> _reference = jsonDecode(
  utf8.decode(
    gzip.decode(
      File('test/fixtures/python_reference/color/color_cases.json.gz')
          .readAsBytesSync(),
    ),
  ),
) as Map<String, dynamic>;

/// `picture()` of the generator: a gradient per channel, noise from a hash
/// of the position, and a bright disc.
RgbImage _picture(List<dynamic> spec) {
  final [width as int, height as int, seed as int, base, gain, torch] = spec;
  final rgb = Uint8List(width * height * 3);
  final radius = (width < height ? width : height) ~/ 6;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final dx = x - width ~/ 3;
      final dy = y - height ~/ 2;
      final disc = dx * dx + dy * dy < radius * radius;
      for (var c = 0; c < 3; c++) {
        final noise =
            ((x * 73856093) ^
                    (y * 19349663) ^
                    ((c + 1) * 83492791) ^
                    (seed * 2654435761)) %
                41 -
            20;
        final g = (gain as List<dynamic>)[c] as List<dynamic>;
        var value =
            ((base as List<dynamic>)[c] as int) +
            (x * (g[0] as int)) ~/ width +
            (y * (g[1] as int)) ~/ height +
            noise;
        if (torch == 1 && disc) {
          value += 70 - 10 * c;
        }
        rgb[(y * width + x) * 3 + c] = value.clamp(0, 255);
      }
    }
  }
  return RgbImage(width, height, rgb);
}

final Map<String, RgbImage> _frames = {
  for (final e in (_reference['pictures'] as Map<String, dynamic>).entries)
    e.key: _picture(e.value as List<dynamic>),
  'photo': () {
    final photo = _reference['photo'] as Map<String, dynamic>;
    final size = photo['size'] as List<dynamic>;
    return RgbImage(
      size[0] as int,
      size[1] as int,
      base64Decode(photo['rgb'] as String),
    );
  }(),
};

final Map<String, ColorEngine> _engines = {
  for (final e in (_reference['profiles'] as Map<String, dynamic>).entries)
    e.key: ColorEngine(ColorProfile.fromMap(e.value as Map<String, dynamic>)),
};

/// How many bytes differ, and by how much at most.
(int, int) _byteDifference(Uint8List a, Uint8List b) {
  expect(a.length, b.length);
  var count = 0;
  var worst = 0;
  for (var i = 0; i < a.length; i++) {
    final d = (a[i] - b[i]).abs();
    if (d != 0) {
      count++;
      if (d > worst) worst = d;
    }
  }
  return (count, worst);
}

void main() {
  final cases = [
    for (final c in _reference['cases'] as List<dynamic>)
      c as Map<String, dynamic>,
  ];

  test('assets/color.yaml has the Python app\'s default and vivid as the '
      'fixture has them, and punchy (spec §10.101)', () {
    final text = File('assets/color.yaml').readAsStringSync();
    // Python's third profile, subtle, is not bundled (owner, 2026-11-24).
    expect(text, isNot(contains('subtle:')));
    // punchy: default with vivid's red restore and the look.
    final bundled = mergedColorProfiles(text, null);
    expect(bundled.keys, ['default', 'vivid', 'punchy']);
    expect(bundled['punchy'], {
      ...bundled['default']!,
      'red_threshold': bundled['vivid']!['red_threshold'],
      'red_scale': bundled['vivid']!['red_scale'],
      'vibrance': 0.7,
      'contrast': 0.3,
    });
    for (final name in ['default', 'vivid']) {
      // Neither has the look, so both correct as the Python app does.
      expect(bundled[name]!.keys, isNot(contains('vibrance')));
      expect(bundled[name]!.keys, isNot(contains('contrast')));
      expect(text, contains('\n$name:\n'.substring(name == 'default' ? 1 : 0)));
      final profile =
          (_reference['profiles'] as Map<String, dynamic>)[name]
              as Map<String, dynamic>;
      // Every value of the profile stands in the file under its name.
      final block = text.substring(text.indexOf('$name:\n'));
      for (final e in profile.entries) {
        expect(block, contains('  ${e.key}: ${e.value}\n'), reason: e.key);
      }
    }
  });

  test('the look: vibrance and contrast (spec §10.101)', () {
    // A filter that changes nothing, so that only the look is seen.
    final filter = Float32List.fromList([0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0.67]);
    Uint8List through(ColorProfile profile, List<int> rgb) =>
        ColorEngine(profile).correct(Uint8List.fromList(rgb), filter);
    int spread(List<int> c) =>
        c.reduce((a, b) => a > b ? a : b) - c.reduce((a, b) => a < b ? a : b);
    const plain = ColorProfile();
    const vibrant = ColorProfile(vibrance: 1.0);
    const dull = [150, 120, 100]; // a weak warm colour
    const water = [90, 130, 170]; // a weak blue
    const strong = [255, 40, 0]; // as much colour as there is
    // Greys stay grey, and none of it without the parameters.
    for (final grey in [0, 60, 128, 200, 255]) {
      expect(
        through(vibrant, [grey, grey, grey]),
        through(plain, [grey, grey, grey]),
      );
    }
    // A weak warm colour gains most, the water's hue less, a full colour
    // nothing; none leaves the byte range by being cut (the hue's order
    // of channels stays).
    final warmGain =
        spread(through(vibrant, dull)) - spread(through(plain, dull));
    final waterGain =
        spread(through(vibrant, water)) - spread(through(plain, water));
    expect(warmGain, greaterThan(20));
    expect(waterGain, greaterThan(0));
    expect(waterGain, lessThan(warmGain));
    expect(through(vibrant, strong), through(plain, strong));
    final more = through(const ColorProfile(vibrance: 2.0), dull);
    expect(more[0], greaterThan(more[1]));
    expect(more[1], greaterThan(more[2]));
    expect(spread(more), greaterThan(spread(through(vibrant, dull))));
    // The contrast: darks darker, lights lighter, the ends where they were.
    const contrasty = ColorProfile(contrast: 1.0);
    expect(
      through(contrasty, [60, 60, 60])[0],
      lessThan(through(plain, [60, 60, 60])[0]),
    );
    expect(
      through(contrasty, [220, 220, 220])[0],
      greaterThan(through(plain, [220, 220, 220])[0]),
    );
    expect(through(contrasty, [0, 0, 0]), [0, 0, 0]);
    expect(through(contrasty, [255, 255, 255]), [255, 255, 255]);
    // Both are read from a profile and written back.
    final read = ColorProfile.fromMap(const {'vibrance': 0.7, 'contrast': 0.3});
    expect(read.vibrance, 0.7);
    expect(read.toMap()['contrast'], 0.3);
    expect(plain.vibrance, 0.0);
    expect(plain.contrast, 0.0);
  });

  test('a profile leaves out what it likes', () {
    const d = ColorProfile();
    final p = ColorProfile.fromMap(const {'cifval': 0.5, 'bh_min_idx': 120.9});
    expect(p.cifval, 0.5);
    expect(p.bhMinIdx, 120);
    expect(p.redThreshold, d.redThreshold);
    expect(p.gwBlurRadius, 9);
    expect(p.sharpness, 0.0);
  });

  test('the made-up frames are the generator\'s', () {
    final hashes = _reference['picture_sha256'] as Map<String, dynamic>;
    for (final e in _frames.entries) {
      expect(
        sha256.convert(e.value.rgb).toString(),
        hashes[e.key],
        reason: e.key,
      );
    }
  });

  test('the sRGB tables', () {
    final engine = _engines['default']!;
    final linear = _reference['lut_linear'] as List<dynamic>;
    for (var i = 0; i < 256; i++) {
      expect(engine.lutLinear[i], linear[i], reason: 'level $i');
    }
    expect(
      sha256.convert(engine.lutSrgb.buffer.asUint8List()).toString(),
      _reference['lut_srgb_sha256'],
    );
  });

  test('the reduced frame is OpenCV\'s (INTER_AREA)', () {
    final engine = _engines['default']!;
    final seen = <String>{};
    for (final c in cases) {
      if (!seen.add(c['picture'] as String)) {
        continue;
      }
      final small = engine.reduced(_frames[c['picture']]!);
      expect(
        [small.width, small.height],
        c['small_size'],
        reason: '${c['picture']}',
      );
      expect(
        sha256.convert(small.rgb).toString(),
        c['small_sha256'],
        reason: '${c['picture']}',
      );
    }
  });

  group('the analysis', () {
    for (final c in cases) {
      test('${c['picture']}, profile ${c['profile']}', () {
        final engine = _engines[c['profile']]!;
        final a = engine.analyze(_frames[c['picture']]!);
        void near(Object got, Object? want, String what) {
          final g = switch (got) {
            (final double x, final double y) => [x, y],
            (final double x, final double y, final double z) => [x, y, z],
            _ => [got as double],
          };
          final w = want is List<dynamic> ? want : [want];
          for (var i = 0; i < g.length; i++) {
            expect(g[i], closeTo(w[i] as num, 1e-12), reason: '$what $i');
          }
        }

        near(a.cf, c['cf'], 'colour factor');
        near(a.bp, c['bp'], 'black point');
        near(a.gw, c['gw'], 'grey world');
        near(a.dehaze, c['dehaze'], 'dehaze');
        near(a.exposure, c['exposure'], 'exposure');
        near(a.blueHue, c['blue_hue'], 'blue hue');
        expect(a.filter, c['filter']);
      });
    }
  });

  test('an all-black frame gives a filter that changes nothing (Python: '
      'NaN gains, spec §10.55)', () {
    for (final engine in _engines.values) {
      final black = RgbImage(240, 160, Uint8List(240 * 160 * 3));
      final a = engine.analyze(black);
      expect(a.gw, (1.0, 1.0, 1.0));
      expect(a.filter.every((v) => v.isFinite), isTrue, reason: '${a.filter}');
      expect(
        engine.applyFilter(black, a.filter).rgb.every((v) => v == 0),
        isTrue,
      );
      expect(engine.lut3d(a.filter, size: 4), hasLength(4 * 4 * 4 * 3));
    }
  });

  test('the correction of a piece of each frame', () {
    var bytes = 0;
    var different = 0;
    var worst = 0;
    var sharpDifferent = 0;
    var sharpWorst = 0;
    var sharpBytes = 0;
    for (final c in cases) {
      final engine = _engines[c['profile']]!;
      final small = engine.reduced(_frames[c['picture']]!);
      final [w as int, h as int] = c['piece_size'] as List<dynamic>;
      final piece = Uint8List(w * h * 3);
      for (var y = 0; y < h; y++) {
        piece.setRange(
          y * w * 3,
          (y + 1) * w * 3,
          small.rgb,
          y * small.width * 3,
        );
      }
      final filter = Float32List.fromList([
        for (final v in c['filter'] as List<dynamic>) (v as num).toDouble(),
      ]);
      final plain = engine.correct(piece, filter);
      final (count, most) = _byteDifference(
        plain,
        base64Decode(c['applied'] as String),
      );
      bytes += plain.length;
      different += count;
      if (most > worst) worst = most;
      final sharpened = c['applied_sharpened'] as String?;
      if (sharpened != null) {
        final got = engine.applyFilter(RgbImage(w, h, piece), filter);
        final (sharpCount, sharpMost) = _byteDifference(
          got.rgb,
          base64Decode(sharpened),
        );
        sharpBytes += got.rgb.length;
        sharpDifferent += sharpCount;
        if (sharpMost > sharpWorst) sharpWorst = sharpMost;
      }
    }
    // ignore: avoid_print
    print(
      'corrected: $different of $bytes bytes differ, by at most $worst; '
      'sharpened: $sharpDifferent of $sharpBytes, by at most $sharpWorst',
    );
    expect(worst, lessThanOrEqualTo(1));
    expect(different / bytes, lessThan(0.001));
    expect(sharpWorst, lessThanOrEqualTo(3));
    expect(sharpDifferent / sharpBytes, lessThan(0.01));
  });

  test('the 3D LUTs and the .cube text', () {
    for (final l in _reference['luts'] as List<dynamic>) {
      final entry = l as Map<String, dynamic>;
      final c = cases.firstWhere(
        (c) =>
            c['picture'] == entry['picture'] &&
            c['profile'] == entry['profile'],
      );
      final engine = _engines[entry['profile']]!;
      final filter = Float32List.fromList([
        for (final v in c['filter'] as List<dynamic>) (v as num).toDouble(),
      ]);
      final made = engine.lut3d(filter);
      expect(made.length, 64 * 64 * 64 * 3);
      // The table is the correction alone (spec §10.21, owner
      // 2026-11-19); Python's has the profile's sharpening on it, laid
      // out as one row. Put on ours, it gives Python's.
      final sharpness = engine.profile.sharpness;
      final lut = sharpness > 0
          ? unsharp(made, 64 * 64 * 64, 1, sharpness)
          : made;
      if (sharpness > 0) {
        expect(made, isNot(lut));
      }
      final every = entry['every'] as int;
      final want = base64Decode(entry['lut'] as String);
      final got = every == 1
          ? lut
          : Uint8List.fromList([
              for (var i = 0; i < 64 * 64 * 64; i += every)
                ...lut.sublist(3 * i, 3 * i + 3),
            ]);
      final (count, worst) = _byteDifference(got, want);
      final what = '${entry['picture']}, ${entry['profile']}';
      expect(worst, lessThanOrEqualTo(1), reason: what);
      expect(count / got.length, lessThan(0.001), reason: what);
      if (entry.containsKey('cube_head')) {
        final text = cubeFileText(lut, 64);
        final lines = const LineSplitter().convert(text);
        expect(lines.take(6), entry['cube_head']);
        expect(lines.length, entry['cube_lines']);
        if (count == 0) {
          expect(
            sha256.convert(utf8.encode(text)).toString(),
            entry['cube_sha256'],
          );
        }
      }
    }
  });

  test('which filters are close enough to share a LUT', () {
    final close = _reference['allclose'] as Map<String, dynamic>;
    Float32List filter(Object? values) => Float32List.fromList([
      for (final v in values! as List<dynamic>) (v as num).toDouble(),
    ]);
    final filters = [
      for (final f in close['filters'] as List<dynamic>) filter(f),
    ];
    for (var i = 0; i < filters.length; i++) {
      for (var j = 0; j < filters.length; j++) {
        expect(
          filtersClose(filters[i], filters[j]),
          ((close['close'] as List<dynamic>)[i] as List<dynamic>)[j],
          reason: '$i against $j',
        );
      }
    }
    final nudged = [
      for (final f in close['nudged'] as List<dynamic>) filter(f),
    ];
    expect([
      for (final n in nudged) filtersClose(n, filters[0]),
    ], close['close_nudged']);
    // A clip's filters: the first, then each that left the one before.
    final kept = distinctFilters(
      [0, 100, 200, 300, 400],
      [nudged[0], nudged[1], nudged[4], nudged[4], nudged[0]],
    );
    expect([for (final k in kept) k.$1], [0, 200, 400]);
  });
}
