// The canvas of a telemetry-only render against the Python app's
// overlay_canvas: the parity fixture made by
// tool/python_reference/overlay_canvas_fixture.py.
import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/engine/overlay_canvas.dart';
import 'package:uwmedia_app/core/naming/output_naming.dart';

import '../../helpers/python_reference.dart';

void main() {
  final reference = pythonReference('engine/overlay_canvas_cases.json');

  test('sizes, formats and even sides', () {
    expect(overlaySizes, reference['sizes']);
    expect(overlayFormats, reference['formats']);
    expect(overlayFormatHevc, reference['default_format']);
    (reference['has_alpha'] as Map<String, dynamic>).forEach((format, alpha) {
      expect(overlayHasAlpha(format), alpha, reason: format);
    });
    for (final [value as num, want]
        in (reference['even'] as List<dynamic>).cast<List<dynamic>>()) {
      expect(evenSide(value), want, reason: '$value');
    }
  });

  test('the canvas of every layout, size and mode', () {
    final cases = jsonObjects(reference['cases']);
    expect(cases.length, 100);
    for (final c in cases) {
      final layout = c['layout'] as Map<String, dynamic>;
      final before = '$layout';
      final skin = (c['skin_size'] as List<dynamic>?)?.cast<int>();
      final canvas = overlayCanvas(
        layout,
        size: c['size'] as String?,
        fullFrame: c['full_frame'] as bool,
        skinSize: skin == null ? null : (skin[0], skin[1]),
      );
      final reason = '${c['name']} ${c['size']} full ${c['full_frame']}';
      expect(
        (canvas.width, canvas.height),
        (c['width'], c['height']),
        reason: reason,
      );
      expect(canvas.renderLog, c['render_log'], reason: reason);
      expect(canvas.layout, c['out'], reason: reason);
      // The caller's layout is left alone.
      expect('$layout', before, reason: reason);
    }
  });
}
