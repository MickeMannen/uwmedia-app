// The painter's own conventions, on a few operations: which pixels a
// Pillow box covers, what the clip keeps, how a blend mixes. The full
// comparison with the Python app's renders is hud_golden_test.dart.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/hud/hud_ops.dart';
import 'package:uwmedia_app/core/hud/image_resize.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';
import 'package:uwmedia_app/hud/hud_painter.dart';

void main() {
  final painter = HudPainter(
    TtfFonts((file) => File('assets/fonts/$file').readAsBytesSync()),
  );

  Future<Uint8List> render(WidgetTester tester, List<HudOp> ops) async {
    late Uint8List pixels;
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      painter.paint(ui.Canvas(recorder), ops);
      final image = await recorder.endRecording().toImage(20, 20);
      pixels = (await image.toByteData())!.buffer.asUint8List();
    });
    return pixels;
  }

  List<int> at(Uint8List pixels, int x, int y) =>
      pixels.sublist(4 * (y * 20 + x), 4 * (y * 20 + x) + 3);

  testWidgets('a Pillow box includes its last row and column', (tester) async {
    final pixels = await render(tester, const [
      RectOp(2, 3, 5, 6, fill: (255, 0, 0)),
    ]);
    expect(at(pixels, 2, 3), [255, 0, 0]);
    expect(at(pixels, 5, 6), [255, 0, 0]);
    expect(at(pixels, 6, 6), [0, 0, 0]);
    expect(at(pixels, 5, 7), [0, 0, 0]);
    expect(at(pixels, 1, 3), [0, 0, 0]);
  });

  testWidgets('an outline lies inside the box', (tester) async {
    final pixels = await render(tester, const [
      RoundedRectOp(2, 2, 12, 12, 0, outline: (0, 255, 0), width: 2),
    ]);
    expect(at(pixels, 2, 7), [0, 255, 0]);
    expect(at(pixels, 3, 7), [0, 255, 0]);
    expect(at(pixels, 4, 7), [0, 0, 0]);
    expect(at(pixels, 12, 7), [0, 255, 0]);
    expect(at(pixels, 13, 7), [0, 0, 0]);
  });

  testWidgets('what follows the skin is cut to the screen', (tester) async {
    final pixels = await render(tester, const [
      RectOp(0, 0, 3, 3, fill: (0, 0, 255)),
      SkinOp(0, 0, 20, 20),
      RectOp(0, 0, 19, 19, fill: (255, 255, 255)),
      ClipOp(5, 5, 10, 10, 'rect'),
    ]);
    // Before the skin: not clipped.
    expect(at(pixels, 1, 1), [0, 0, 255]);
    expect(at(pixels, 5, 5), [255, 255, 255]);
    expect(at(pixels, 9, 9), [255, 255, 255]);
    expect(at(pixels, 10, 10), [0, 0, 0]);
    expect(at(pixels, 4, 7), [0, 0, 0]);
  });

  testWidgets('a blend mixes its operations in at its opacity', (tester) async {
    final pixels = await render(tester, const [
      BlendOp(0.5, [CvRectOp(0, 0, 9, 9, (200, 100, 0), -1)]),
      BlendOp(0, [CvRectOp(10, 10, 19, 19, (200, 100, 0), -1)]),
    ]);
    expect(at(pixels, 9, 9)[0], closeTo(100, 2));
    expect(at(pixels, 9, 9)[1], closeTo(50, 2));
    expect(at(pixels, 10, 9), [0, 0, 0]);
    expect(at(pixels, 15, 15), [0, 0, 0]);
  });

  test('areaResize averages the pixels an output pixel covers', () {
    // 4x2 to 2x1: two 2x2 blocks.
    final rgba = Uint8List.fromList([
      for (final v in [0, 100, 10, 30, 200, 100, 20, 40]) ...[v, v, v, 255],
    ]);
    final half = areaResize(rgba, 4, 2, 2, 1);
    expect(half, [100, 100, 100, 255, 25, 25, 25, 255]);
    // 3 to 2: each output pixel is one whole pixel and half of the middle.
    final three = Uint8List.fromList([
      for (final v in [0, 90, 240]) ...[v, 0, 0, 255],
    ]);
    final two = areaResize(three, 3, 1, 2, 1);
    expect([two[0], two[4]], [30, 190]);
    expect(areaResize(rgba, 4, 2, 4, 2), rgba);
  });
}
