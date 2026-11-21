// Where an overlay instance lands on a frame (overlayPixelBox in
// lib/core/hud/hud_renderer.dart) against Python's overlay_pixel_bbox, on
// the parity fixture made by tool/python_reference/overlay_bbox_fixture.py:
// two bundled templates (as they are and scaled), shape skins and a
// layout without a skin, on five frame sizes and five placements.
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/hud/hud_renderer.dart';

import '../../helpers/python_reference.dart';

void main() {
  test('every box is Python\'s', () {
    final cases = jsonObjects(
      pythonReference('pages/overlay_bbox_cases.json')['bbox'],
    );
    expect(cases.length, 175);
    for (final c in cases) {
      final [w, h] = (c['frame'] as List<dynamic>).cast<int>();
      final [x, y, scale] = (c['placement'] as List<dynamic>).cast<num>();
      final size = (c['skin_size'] as List<dynamic>?)?.cast<int>();
      final (x0, y0, x1, y1) = overlayPixelBox(
        c['layout'] as Map<String, dynamic>,
        x.toDouble(),
        y.toDouble(),
        scale.toDouble(),
        w,
        h,
        skinSize: size == null ? null : (size[0], size[1]),
      );
      expect(
        [x0, y0, x1, y1],
        c['bbox'],
        reason: '${c['name']} $w x $h $x $y $scale',
      );
    }
  });
}
