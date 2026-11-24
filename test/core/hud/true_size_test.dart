import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/hud/image_size.dart';
import 'package:uwmedia_app/core/hud/true_size.dart';

const _templates = 'assets/overlays/templates';

/// The first page of a bundled computer: its layout's scale and its
/// picture's size.
({double scale, (int, int) skin}) _firstPage(String key) {
  final dir = Directory('$_templates/$key');
  final picture =
      dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('normal.png'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final file = picture.first;
  final json = File(file.path.replaceAll('.png', '.json')).readAsStringSync();
  final scale = RegExp(r'"scale":\s*([0-9.]+)').firstMatch(json)!.group(1)!;
  return (scale: double.parse(scale), skin: imageSize(file.readAsBytesSync())!);
}

Map<String, dynamic> _layout(double scale) => {
  'design_width': 1920,
  'hud_skin': <String, dynamic>{'type': 'image', 'scale': scale},
};

/// The width a computer's first page is drawn at on a 1920-wide frame.
double _drawn(String key) {
  final page = _firstPage(key);
  final scale = trueSizeScale(
    widthMm: bundledPictureWidthsMm[key],
    layout: _layout(page.scale),
    skinSize: page.skin,
  );
  return page.skin.$1 * page.scale * scale;
}

void main() {
  test('every bundled computer has its width, and only they', () {
    final computers = <String>[
      for (final brand in Directory(
        _templates,
      ).listSync().whereType<Directory>())
        if (!brand.path.endsWith('generic'))
          for (final c in brand.listSync().whereType<Directory>())
            '${brand.uri.pathSegments.reversed.skip(1).first}/'
                '${c.uri.pathSegments.reversed.skip(1).first}',
    ]..sort();
    expect(bundledPictureWidthsMm.keys.toList()..sort(), computers);
  });

  test('a Perdix takes a quarter of the frame, the others by their size', () {
    expect(_drawn('shearwater/perdix_3'), closeTo(480, 0.01));
    expect(_drawn('shearwater/perdix_2'), closeTo(480, 0.01));
    // 98.3 mm against 81: wider than the Perdix, where it was narrower.
    expect(_drawn('garmin/x50i'), closeTo(480 * 98.3 / 81, 0.01));
    expect(_drawn('garmin/x50i'), greaterThan(_drawn('shearwater/perdix_3')));
    // The watches are smaller than the handsets.
    for (final watch in [
      'garmin/mk3i',
      'shearwater/teric',
      'shearwater/tern',
    ]) {
      expect(_drawn(watch), lessThan(_drawn('shearwater/peregrine')));
    }
    // The same pixels a millimetre for all of them.
    for (final entry in bundledPictureWidthsMm.entries) {
      expect(_drawn(entry.key) / entry.value, closeTo(480 / 81, 1e-6));
    }
  });

  test('the scale follows the frame the template was designed for', () {
    final half = trueSizeScale(
      widthMm: 81,
      layout: {
        'design_width': 3840,
        'hud_skin': <String, dynamic>{'scale': 1.0},
      },
      skinSize: (960, 700),
    );
    expect(half, closeTo(1, 1e-9));
  });

  test("a manifest's own width wins; without one a computer keeps its "
      'size', () {
    expect(pictureWidthMm('garmin', 'x50i', const {}), 98.3);
    expect(pictureWidthMm('garmin', 'x50i', const {'width_mm': 50}), 50);
    expect(pictureWidthMm('garmin', 'x50i', const {'width_mm': 0}), 98.3);
    expect(pictureWidthMm('garmin', 'x50i', const {'width_mm': 'x'}), 98.3);
    expect(pictureWidthMm('mine', 'computer', const {}), isNull);
    expect(
      trueSizeScale(widthMm: null, layout: _layout(0.5), skinSize: (900, 600)),
      1,
    );
  });

  test('a drawn shape, or a picture of unknown size, keeps its size', () {
    expect(
      trueSizeScale(
        widthMm: 81,
        layout: {
          'hud_skin': <String, dynamic>{'type': 'shape', 'width': 400},
        },
        skinSize: null,
      ),
      1,
    );
    expect(trueSizeScale(widthMm: 81, layout: _layout(0.5), skinSize: null), 1);
    expect(
      trueSizeScale(widthMm: 81, layout: const {}, skinSize: (900, 600)),
      1,
    );
  });

  test("a working copy at its true size: the skin's scale, nothing else", () {
    final layout = <String, dynamic>{
      'design_width': 1920,
      'elements': [1, 2],
      'hud_skin': <String, dynamic>{
        'type': 'image',
        'scale': 0.5,
        'path': 'normal.png',
      },
    };
    final sized = trueSizedLayout(layout, widthMm: 98.3, skinSize: (946, 602));
    final skin = sized['hud_skin'] as Map<String, dynamic>;
    // 946 pixels drawn 98.3 mm wide where 81 mm are 480 pixels.
    expect(946 * (skin['scale'] as double), closeTo(480 * 98.3 / 81, 1e-6));
    expect(skin['path'], 'normal.png');
    expect(sized['elements'], [1, 2]);
    // The template itself is left alone.
    expect((layout['hud_skin'] as Map)['scale'], 0.5);
    // Nothing known of its size: the same layout back.
    expect(
      trueSizedLayout(layout, widthMm: null, skinSize: (946, 602)),
      same(layout),
    );
  });
}
