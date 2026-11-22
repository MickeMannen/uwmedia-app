// Before and after in one picture (lib/core/engine/compare.dart, spec
// §10.94): the edge's geometry, the mixed picture, the mask and the line
// for the video engines, the wipe's timing and frame size, the names.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uwmedia_app/core/engine/compare.dart';

Uint8List _plain(int width, int height, int r, int g, int b) {
  final out = Uint8List(width * height * 4);
  for (var i = 0; i < out.length; i += 4) {
    out[i] = r;
    out[i + 1] = g;
    out[i + 2] = b;
    out[i + 3] = 255;
  }
  return out;
}

List<int> _at(Uint8List rgba, int width, int x, int y) =>
    rgba.sublist((y * width + x) * 4, (y * width + x) * 4 + 4);

void main() {
  const w = 40;
  const h = 20;
  final red = _plain(w, h, 200, 0, 0);
  final blue = _plain(w, h, 0, 0, 200);

  test('a vertical split: near left, far right, a white line between', () {
    final edge = CompareEdge.split(CompareKind.vertical, w, h);
    expect(edge.at, 20);
    expect(edge.lineWidth, 2);
    final mixed = compareMix(red, blue, edge);
    for (final y in [0, 10, 19]) {
      expect(_at(mixed, w, 0, y), [200, 0, 0, 255]);
      expect(_at(mixed, w, 17, y), [200, 0, 0, 255]);
      expect(_at(mixed, w, 19, y), [255, 255, 255, 255]);
      expect(_at(mixed, w, 20, y), [255, 255, 255, 255]);
      expect(_at(mixed, w, 22, y), [0, 0, 200, 255]);
      expect(_at(mixed, w, 39, y), [0, 0, 200, 255]);
    }
    // Without the line the two meet at the edge.
    final bare = compareMix(red, blue, edge, line: false);
    expect(_at(bare, w, 19, 5), [200, 0, 0, 255]);
    expect(_at(bare, w, 20, 5), [0, 0, 200, 255]);
  });

  test('a horizontal split: near above, far below', () {
    final edge = CompareEdge.split(CompareKind.horizontal, w, h);
    expect(edge.at, 10);
    final mixed = compareMix(red, blue, edge);
    for (final x in [0, 20, 39]) {
      expect(_at(mixed, w, x, 0), [200, 0, 0, 255]);
      expect(_at(mixed, w, x, 7), [200, 0, 0, 255]);
      expect(_at(mixed, w, x, 9), [255, 255, 255, 255]);
      expect(_at(mixed, w, x, 10), [255, 255, 255, 255]);
      expect(_at(mixed, w, x, 12), [0, 0, 200, 255]);
      expect(_at(mixed, w, x, 19), [0, 0, 200, 255]);
    }
  });

  test('a diagonal split leans: further right at the top', () {
    final edge = CompareEdge.split(CompareKind.diagonal, w, h);
    // 0.3 of the width from top to bottom: 6 pixels either side of 20.
    expect(edge.farCorners.first.$1, closeTo(26, 1e-9));
    expect(edge.farCorners.last.$1, closeTo(14, 1e-9));
    final mixed = compareMix(red, blue, edge);
    expect(_at(mixed, w, 22, 0), [200, 0, 0, 255]);
    expect(_at(mixed, w, 30, 0), [0, 0, 200, 255]);
    expect(_at(mixed, w, 10, 19), [200, 0, 0, 255]);
    expect(_at(mixed, w, 18, 19), [0, 0, 200, 255]);
    // The middle row is split in the middle.
    expect(edge.distance(19, 10) < 0 && edge.distance(20, 10) > 0, isTrue);
  });

  test('the mask and the line as pictures agree with the mix', () {
    for (final kind in CompareKind.values) {
      final edge = CompareEdge.split(kind, w, h);
      final mask = compareMask(edge);
      final line = compareLine(edge);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final m = _at(mask, w, x, y);
          expect(m[0], (edge.farShare(x, y) * 255).round(), reason: '$kind');
          expect(m, [m[0], m[0], m[0], 255]);
          final l = _at(line, w, x, y);
          expect(l[3], (edge.lineShare(x, y) * 255).round(), reason: '$kind');
          if (l[3] > 0) {
            expect(l.sublist(0, 3), [255, 255, 255]);
          }
        }
      }
    }
  });

  test('a shared pixel is mixed by its share', () {
    // The edge through the middle of pixel 20: half of each.
    final edge = CompareEdge(CompareKind.vertical, w, h, 20.5);
    expect(edge.farShare(20, 3), 0.5);
    final bare = compareMix(red, blue, edge, line: false);
    expect(_at(bare, w, 20, 3), [100, 0, 100, 255]);
    final into = Uint8List(w * h * 4);
    expect(identical(compareMix(red, blue, edge, into: into), into), isTrue);
    expect(_at(into, w, 0, 0), [200, 0, 0, 255]);
  });

  test('a wipe starts and ends outside the picture, line and all', () {
    for (final kind in CompareKind.values) {
      final start = compareMix(red, blue, CompareEdge.wipe(kind, w, h, 0));
      expect(start, blue, reason: '$kind at 0');
      final end = compareMix(red, blue, CompareEdge.wipe(kind, w, h, 1));
      expect(end, red, reason: '$kind at 1');
      final half = CompareEdge.wipe(kind, w, h, 0.5);
      expect(half.at, kind == CompareKind.horizontal ? h / 2 : w / 2);
    }
  });

  test('the wipe video: still, moving, still', () {
    expect(wipeSeconds, 4);
    expect(wipeShare(0), 0);
    expect(wipeShare(15), 0);
    expect(wipeShare(16), greaterThan(0));
    expect(wipeShare(52), closeTo(0.5, 0.02));
    expect(wipeShare(90), 1);
    expect(wipeShare(119), 1);
    final steps = wipeSteps();
    expect(steps.fold(0, (sum, step) => sum + step.$2), 120);
    expect(steps.first, (0.0, 16));
    expect(steps.last, (1.0, 30));
    // Always forward.
    for (var i = 1; i < steps.length; i++) {
      expect(steps[i].$1, greaterThan(steps[i - 1].$1));
    }
  });

  test('the wipe video frame: inside the box, never larger, even', () {
    expect(wipeFrameSize(6000, 4000), (3240, 2160));
    expect(wipeFrameSize(4000, 6000), (2160, 3240));
    expect(wipeFrameSize(1800, 1200), (1800, 1200));
    expect(wipeFrameSize(1801, 1201), (1800, 1200));
    expect(wipeFrameSize(6000, 4000, box: (1920, 1080)), (1620, 1080));
    expect(wipeFrameSize(4000, 6000, box: (1920, 1080)), (1080, 1620));
    expect(wipeFrameSize(6000, 4000, box: (720, 1280)), (1080, 720));
    // A side that fills the box exactly keeps it.
    expect(wipeFrameSize(4032, 3024).$1, 2880);
    expect(wipeFrameSize(4032, 2268), (3840, 2160));
  });

  test('a comparison is ten seconds of a video at most', () {
    expect(compareClipPart(null), (start: 0.0, end: 10.0));
    expect(compareClipPart((start: 5, end: 8)), (start: 5.0, end: 8.0));
    expect(compareClipPart((start: 5, end: 60)), (start: 5.0, end: 15.0));
  });

  test('the file is named "… compare"', () {
    expect(compareFilename('Reef.MP4'), 'Reef compare.MP4');
    expect(compareFilename('a.b/Fish.jpg'), 'a.b/Fish compare.jpg');
    expect(compareFilename('Fish.jpg', video: true), 'Fish compare.mp4');
  });

  test('the line is wider on a larger picture', () {
    expect(compareLineWidth(320, 240), 2);
    expect(compareLineWidth(1920, 1080), 3);
    expect(compareLineWidth(3840, 2160), 6);
    expect(compareLineWidth(2160, 3840), 6);
  });
}
