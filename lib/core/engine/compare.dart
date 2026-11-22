/// Before and after the colour correction in one picture (spec §10.94):
/// the picture split by an edge with the original on one side and the
/// corrected one on the other, and for a photo a short video in which
/// the edge moves across and uncovers the corrected picture (a wipe; the
/// picture itself stays still).
///
/// Here is the geometry every engine shares: where the edge lies, how
/// much of a pixel is on its far side, the divider line drawn on it, the
/// mask and the line as pictures (for the video engines), the two
/// pictures mixed (a photo, and the frames of the wipe), and the wipe's
/// timing.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// How the edge between the original and the corrected picture lies.
enum CompareKind {
  /// From top to bottom: the sides are left and right.
  vertical,

  /// From left to right: the sides are above and below.
  horizontal,

  /// Leaning ([compareSlant]): left and right, the edge further right at
  /// the top.
  diagonal,
}

/// A comparison a run writes: a split picture, or with [wipe] a photo's
/// video of the edge moving across.
class Compare {
  const Compare(this.kind, {this.wipe = false});

  final CompareKind kind;

  /// A photo as a video ([wipeSeconds] long) instead of a split photo.
  final bool wipe;

  @override
  bool operator ==(Object other) =>
      other is Compare && other.kind == kind && other.wipe == wipe;

  @override
  int get hashCode => Object.hash(kind, wipe);
}

/// The longest video a comparison writes, in seconds.
const compareMaxSeconds = 10.0;

/// How far a diagonal edge leans from its top to its bottom, as a share
/// of the picture's width.
const compareSlant = 0.3;

/// The wipe video of a photo: its frame rate, the still original at its
/// start, the edge's way across and the still corrected picture at its
/// end, in seconds.
const wipeFps = 30.0;
const wipeLead = 0.5;
const wipeMove = 2.5;
const wipeTail = 1.0;
const wipeSeconds = wipeLead + wipeMove + wipeTail;

/// The box a wipe video's frame fits in when no output size is chosen
/// (its longer side, its shorter side): a photo has more pixels than a
/// video encoder takes.
const wipeMaxLong = 3840;
const wipeMaxShort = 2160;

/// The part of a video a comparison writes: [part], or the video from
/// its start, no longer than [compareMaxSeconds].
({double start, double end}) compareClipPart(
  ({double start, double end})? part,
) {
  final start = part?.start ?? 0.0;
  final end = part?.end ?? start + compareMaxSeconds;
  return (
    start: start,
    end: end - start > compareMaxSeconds ? start + compareMaxSeconds : end,
  );
}

/// The name of a comparison's file for a run's output name [filename]:
/// "NAME compare" with its ending, `.mp4` for a [video] made of a
/// photo.
String compareFilename(String filename, {bool video = false}) {
  final ending = video ? '.mp4' : p.extension(filename);
  return '${p.withoutExtension(filename)} compare$ending';
}

/// The width of the divider line on a [width] by [height] picture: two
/// pixels at least, six on a 4K frame.
int compareLineWidth(int width, int height) =>
    math.max(2, (math.min(width, height) / 360).round());

/// The size of a wipe video's frame for a [width] by [height] picture:
/// the picture's shape inside [box] (the way up the picture is; without
/// one [wipeMaxLong] by [wipeMaxShort]), never larger than the picture,
/// both sides even.
(int, int) wipeFrameSize(int width, int height, {(int, int)? box}) {
  final long = math.max(box?.$1 ?? wipeMaxLong, box?.$2 ?? wipeMaxShort);
  final short = math.min(box?.$1 ?? wipeMaxLong, box?.$2 ?? wipeMaxShort);
  final (maxW, maxH) = width >= height ? (long, short) : (short, long);
  final scale = math.min(1.0, math.min(maxW / width, maxH / height));
  // A side that fills the box comes out a hair under it in floating
  // point: it is not to lose two pixels for that.
  int even(double value) => math.max(2, ((value + 1e-6) / 2).floor() * 2);
  return (even(width * scale), even(height * scale));
}

/// How far the wipe's edge has come at [frame] of the video (0 before it
/// starts, 1 when it is across), slow at both ends.
double wipeShare(int frame) {
  final u = ((frame / wipeFps - wipeLead) / wipeMove).clamp(0.0, 1.0);
  return u * u * (3 - 2 * u);
}

/// The wipe video's frames as runs of the same picture: how far the edge
/// has come and for how many frames.
List<(double share, int frames)> wipeSteps() {
  final steps = <(double, int)>[];
  final total = (wipeSeconds * wipeFps).round();
  for (var frame = 0; frame < total; frame++) {
    final share = wipeShare(frame);
    if (steps.isNotEmpty && steps.last.$1 == share) {
      steps[steps.length - 1] = (share, steps.last.$2 + 1);
    } else {
      steps.add((share, 1));
    }
  }
  return steps;
}

/// The edge on a picture: the near side is left of it (above it for a
/// horizontal one), the far side right of it (below it).
class CompareEdge {
  CompareEdge(this.kind, this.width, this.height, this.at)
    : lineWidth = compareLineWidth(width, height);

  /// The edge of a split picture: through the middle.
  factory CompareEdge.split(CompareKind kind, int width, int height) =>
      CompareEdge(
        kind,
        width,
        height,
        kind == CompareKind.horizontal ? height / 2 : width / 2,
      );

  /// The edge of a wipe that has come [share] of its way: from just
  /// outside the picture on the near side to just outside it on the far
  /// side, the line with it.
  factory CompareEdge.wipe(
    CompareKind kind,
    int width,
    int height,
    double share,
  ) {
    final line = compareLineWidth(width, height);
    final margin =
        line / 2 +
        1.5 +
        (kind == CompareKind.diagonal ? compareSlant * width / 2 : 0);
    final way = kind == CompareKind.horizontal ? height : width;
    return CompareEdge(
      kind,
      width,
      height,
      -margin + (way + 2 * margin) * share,
    );
  }

  final CompareKind kind;
  final int width;
  final int height;

  /// Where the edge is, in pixels: from the left (a diagonal one at half
  /// the height), or from the top for a horizontal one.
  final double at;

  /// The divider line's width in pixels.
  final int lineWidth;

  bool get _acrossRows => kind == CompareKind.horizontal;

  /// The far side as a shape on the picture, its corners in order: the
  /// first and the last are the edge's two ends (for a preview that
  /// draws the split itself).
  List<(double x, double y)> get farCorners {
    final w = width.toDouble();
    final h = height.toDouble();
    final lean = kind == CompareKind.diagonal ? compareSlant * width / 2 : 0.0;
    return _acrossRows
        ? [(0, at), (0, h), (w, h), (w, at)]
        : [(at + lean, 0), (w, 0), (w, h), (at - lean, h)];
  }

  // The distance from the edge of the pixels of row [y], less the
  // pixel's own place in the row (which counts for an edge that is not
  // horizontal).
  double _rowOffset(int y) => switch (kind) {
    CompareKind.vertical => -at,
    CompareKind.horizontal => y + 0.5 - at,
    CompareKind.diagonal =>
      -at + ((y + 0.5) / height - 0.5) * compareSlant * width,
  };

  /// How far the middle of pixel ([x], [y]) is beyond the edge, in
  /// pixels: negative on the near side.
  double distance(int x, int y) => _rowOffset(y) + (_acrossRows ? 0 : x + 0.5);

  /// The share of pixel ([x], [y]) that is on the far side.
  double farShare(int x, int y) => _far(distance(x, y));

  /// How much of pixel ([x], [y]) the divider line covers.
  double lineShare(int x, int y) => _line(distance(x, y));

  double _far(double distance) => (distance + 0.5).clamp(0.0, 1.0);

  double _line(double distance) =>
      (lineWidth / 2 + 0.5 - distance.abs()).clamp(0.0, 1.0);

  // The pixels of row [y] that the edge or its line touches, from [lo]
  // up to [hi]: those before are all near, those from [hi] on all far.
  (int lo, int hi) _band(int y) {
    final offset = _rowOffset(y);
    final reach = lineWidth / 2 + 1.5;
    if (_acrossRows) {
      if (offset.abs() < reach) {
        return (0, width);
      }
      return offset < 0 ? (width, width) : (0, 0);
    }
    // The pixel whose middle is on the edge is at -offset - 0.5.
    final middle = -offset - 0.5;
    final lo = (middle - reach).floor().clamp(0, width);
    final hi = (middle + reach).ceil().clamp(lo, width);
    return (lo, hi);
  }
}

/// [near] and [far] (RGBA pictures of [edge]'s size) in one picture:
/// [near] on the edge's near side, [far] on its far side, with the white
/// divider line on the edge when [line]. Written into [into] when given
/// (a picture of the same size), else into a new one.
Uint8List compareMix(
  Uint8List near,
  Uint8List far,
  CompareEdge edge, {
  bool line = true,
  Uint8List? into,
}) {
  final width = edge.width;
  final height = edge.height;
  final out = into ?? Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    final row = y * width * 4;
    final (lo, hi) = edge._band(y);
    if (lo > 0) {
      out.setRange(row, row + lo * 4, near, row);
    }
    if (hi < width) {
      out.setRange(row + hi * 4, row + width * 4, far, row + hi * 4);
    }
    for (var x = lo; x < hi; x++) {
      final distance = edge.distance(x, y);
      final share = edge._far(distance);
      final white = line ? edge._line(distance) : 0.0;
      final i = row + x * 4;
      for (var c = 0; c < 3; c++) {
        final mixed = near[i + c] * (1 - share) + far[i + c] * share;
        out[i + c] = (mixed * (1 - white) + 255 * white).round();
      }
      out[i + 3] = 255;
    }
  }
  return out;
}

/// The mask of [edge] as an RGBA picture for a video engine: white where
/// the far side is, black on the near side, grey where a pixel is shared.
Uint8List compareMask(CompareEdge edge) {
  final width = edge.width;
  final out = Uint8List(width * edge.height * 4);
  for (var y = 0; y < edge.height; y++) {
    final row = y * width * 4;
    final (lo, hi) = edge._band(y);
    for (var x = 0; x < width; x++) {
      final i = row + x * 4;
      final grey = x < lo
          ? 0
          : x >= hi
          ? 255
          : (edge.farShare(x, y) * 255).round();
      out[i] = grey;
      out[i + 1] = grey;
      out[i + 2] = grey;
      out[i + 3] = 255;
    }
  }
  return out;
}

/// The divider line of [edge] as an RGBA picture laid over the frame:
/// white on the edge, clear elsewhere (the alpha not multiplied in).
Uint8List compareLine(CompareEdge edge) {
  final width = edge.width;
  final out = Uint8List(width * edge.height * 4);
  for (var y = 0; y < edge.height; y++) {
    final row = y * width * 4;
    final (lo, hi) = edge._band(y);
    for (var x = lo; x < hi; x++) {
      final alpha = (edge.lineShare(x, y) * 255).round();
      if (alpha == 0) {
        continue;
      }
      final i = row + x * 4;
      out[i] = 255;
      out[i + 1] = 255;
      out[i + 2] = 255;
      out[i + 3] = alpha;
    }
  }
  return out;
}
