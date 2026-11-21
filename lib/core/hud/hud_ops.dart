/// What the overlay renderer asks to be drawn: a list of operations with
/// every position, size and colour worked out (spec §5). The Python app
/// draws with Pillow and OpenCV as it goes; the port's renderer is pure and
/// hands this list to a painter, so the same geometry serves the preview,
/// the Overlay Designer and the export, and can be compared with Python
/// call by call.
///
/// The operations keep the meaning of the Pillow and OpenCV calls they
/// stand for: a Pillow box `[x0, y0, x1, y1]` includes its last pixel row
/// and column, and a text position is the top of the font's line (its
/// ascender), not the baseline.
library;

/// A colour as red, green, blue (0 to 255).
typedef Rgb = (int r, int g, int b);

/// A point in frame pixels.
typedef HudPoint = (double x, double y);

List<int>? _rgb(Rgb? c) => c == null ? null : [c.$1, c.$2, c.$3];

List<List<double>> _points(List<HudPoint> points) => [
  for (final p in points) [p.$1, p.$2],
];

sealed class HudOp {
  const HudOp();

  /// The operation as the parity fixture writes it: a list, the kind first.
  List<Object?> toJson();
}

/// Where the skin goes: an image skin is drawn here; for a shape skin the
/// box was already drawn (a [BlendOp] before this).
class SkinOp extends HudOp {
  const SkinOp(this.x, this.y, this.width, this.height);

  final int x;
  final int y;
  final int width;
  final int height;

  @override
  List<Object?> toJson() => ['skin', x, y, width, height];
}

/// The skin's `screen`: whatever the operations after the [SkinOp] put
/// outside it is not shown.
class ClipOp extends HudOp {
  const ClipOp(this.x0, this.y0, this.x1, this.y1, this.shape);

  final int x0;
  final int y0;
  final int x1;
  final int y1;

  /// "rect" or "ellipse".
  final String shape;

  @override
  List<Object?> toJson() => ['clip', x0, y0, x1, y1, shape];
}

/// Operations drawn together and mixed into the frame at [opacity].
class BlendOp extends HudOp {
  const BlendOp(this.opacity, this.ops);

  final double opacity;
  final List<HudOp> ops;

  @override
  List<Object?> toJson() => [
    'blend',
    opacity,
    [for (final op in ops) op.toJson()],
  ];
}

/// OpenCV's rounded box of the shape skin; [thickness] -1 fills it.
class CvRoundedRectOp extends HudOp {
  const CvRoundedRectOp(
    this.x0,
    this.y0,
    this.x1,
    this.y1,
    this.color,
    this.thickness,
    this.radius,
  );

  final int x0;
  final int y0;
  final int x1;
  final int y1;
  final Rgb color;
  final int thickness;
  final int radius;

  @override
  List<Object?> toJson() => [
    'cv_rrect',
    x0,
    y0,
    x1,
    y1,
    _rgb(color),
    thickness,
    radius,
  ];
}

/// OpenCV `rectangle`; [thickness] -1 fills it. Both corners are inside.
class CvRectOp extends HudOp {
  const CvRectOp(
    this.x0,
    this.y0,
    this.x1,
    this.y1,
    this.color,
    this.thickness,
  );

  final int x0;
  final int y0;
  final int x1;
  final int y1;
  final Rgb color;
  final int thickness;

  @override
  List<Object?> toJson() => ['cv_rect', x0, y0, x1, y1, _rgb(color), thickness];
}

class CvLineOp extends HudOp {
  const CvLineOp(
    this.x0,
    this.y0,
    this.x1,
    this.y1,
    this.color,
    this.thickness,
  );

  final int x0;
  final int y0;
  final int x1;
  final int y1;
  final Rgb color;
  final int thickness;

  @override
  List<Object?> toJson() => ['cv_line', x0, y0, x1, y1, _rgb(color), thickness];
}

/// OpenCV `polylines`, open.
class CvPolylineOp extends HudOp {
  const CvPolylineOp(this.points, this.color, this.thickness);

  final List<(int, int)> points;
  final Rgb color;
  final int thickness;

  @override
  List<Object?> toJson() => [
    'cv_polyline',
    [
      for (final p in points) [p.$1, p.$2],
    ],
    _rgb(color),
    thickness,
  ];
}

/// OpenCV `fillPoly`.
class CvFillOp extends HudOp {
  const CvFillOp(this.points, this.color);

  final List<(int, int)> points;
  final Rgb color;

  @override
  List<Object?> toJson() => [
    'cv_fill',
    [
      for (final p in points) [p.$1, p.$2],
    ],
    _rgb(color),
  ];
}

/// OpenCV `circle`; [thickness] -1 fills it.
class CvCircleOp extends HudOp {
  const CvCircleOp(this.x, this.y, this.radius, this.color, this.thickness);

  final int x;
  final int y;
  final int radius;
  final Rgb color;
  final int thickness;

  @override
  List<Object?> toJson() => ['cv_circle', x, y, radius, _rgb(color), thickness];
}

/// Pillow `text`: [text] in [fontFile] at [size] px with the top of the
/// line at ([x], [y]); with [strokeWidth] an outline of that width in
/// [strokeColor] around the glyphs.
class TextOp extends HudOp {
  const TextOp(
    this.x,
    this.y,
    this.text,
    this.fontFile,
    this.size,
    this.color, {
    this.strokeWidth = 0,
    this.strokeColor,
  });

  final double x;
  final double y;
  final String text;
  final String fontFile;
  final int size;
  final Rgb color;
  final int strokeWidth;
  final Rgb? strokeColor;

  @override
  List<Object?> toJson() => [
    'text',
    x,
    y,
    text,
    fontFile,
    size,
    _rgb(color),
    strokeWidth,
    _rgb(strokeColor),
  ];
}

/// A line of text turned on its side: drawn flat on a tile with a margin
/// of `outline + 1` px around its ink (1 px without an outline: the margin
/// is `max(1, size ~/ 20) + 1` either way), turned a quarter ("up" reads
/// bottom to top, "down" top to bottom) and put with the tile's corner at
/// ([x], [y]). [outline] is the distance of the four black copies, 0 for
/// none.
class RotatedTextOp extends HudOp {
  const RotatedTextOp(
    this.x,
    this.y,
    this.text,
    this.fontFile,
    this.size,
    this.orientation,
    this.color,
    this.outline,
  );

  final int x;
  final int y;
  final String text;
  final String fontFile;
  final int size;
  final String orientation;
  final Rgb color;
  final int outline;

  @override
  List<Object?> toJson() => [
    'rtext',
    x,
    y,
    text,
    fontFile,
    size,
    orientation,
    _rgb(color),
    outline,
  ];
}

/// Pillow `rectangle`.
class RectOp extends HudOp {
  const RectOp(
    this.x0,
    this.y0,
    this.x1,
    this.y1, {
    this.fill,
    this.outline,
    this.width = 1,
  });

  final double x0;
  final double y0;
  final double x1;
  final double y1;
  final Rgb? fill;
  final Rgb? outline;
  final int width;

  @override
  List<Object?> toJson() => [
    'rect',
    x0,
    y0,
    x1,
    y1,
    _rgb(fill),
    _rgb(outline),
    width,
  ];
}

/// Pillow `rounded_rectangle`.
class RoundedRectOp extends HudOp {
  const RoundedRectOp(
    this.x0,
    this.y0,
    this.x1,
    this.y1,
    this.radius, {
    this.fill,
    this.outline,
    this.width = 1,
  });

  final double x0;
  final double y0;
  final double x1;
  final double y1;
  final double radius;
  final Rgb? fill;
  final Rgb? outline;
  final int width;

  @override
  List<Object?> toJson() => [
    'rrect',
    x0,
    y0,
    x1,
    y1,
    radius,
    _rgb(fill),
    _rgb(outline),
    width,
  ];
}

/// Pillow `polygon`.
class PolygonOp extends HudOp {
  const PolygonOp(this.points, {this.fill, this.outline, this.width = 1});

  final List<HudPoint> points;
  final Rgb? fill;
  final Rgb? outline;
  final int width;

  @override
  List<Object?> toJson() => [
    'poly',
    _points(points),
    _rgb(fill),
    _rgb(outline),
    width,
  ];
}

/// Pillow `line` through [points]; [joint] "curve" rounds the corners.
class LineOp extends HudOp {
  const LineOp(this.points, this.color, this.width, {this.joint});

  final List<HudPoint> points;
  final Rgb color;
  final int width;
  final String? joint;

  @override
  List<Object?> toJson() => [
    'line',
    _points(points),
    _rgb(color),
    width,
    joint,
  ];
}

/// Pillow `ellipse` inside a box.
class EllipseOp extends HudOp {
  const EllipseOp(
    this.x0,
    this.y0,
    this.x1,
    this.y1, {
    this.fill,
    this.outline,
    this.width = 1,
  });

  final double x0;
  final double y0;
  final double x1;
  final double y1;
  final Rgb? fill;
  final Rgb? outline;
  final int width;

  @override
  List<Object?> toJson() => [
    'ellipse',
    x0,
    y0,
    x1,
    y1,
    _rgb(fill),
    _rgb(outline),
    width,
  ];
}

/// Pillow `pieslice`: the slice of the ellipse in the box from [start] to
/// [end] degrees, clockwise from three o'clock.
class PieSliceOp extends HudOp {
  const PieSliceOp(
    this.x0,
    this.y0,
    this.x1,
    this.y1,
    this.start,
    this.end, {
    this.fill,
    this.outline,
    this.width = 1,
  });

  final double x0;
  final double y0;
  final double x1;
  final double y1;
  final double start;
  final double end;
  final Rgb? fill;
  final Rgb? outline;
  final int width;

  @override
  List<Object?> toJson() => [
    'pie',
    x0,
    y0,
    x1,
    y1,
    start,
    end,
    _rgb(fill),
    _rgb(outline),
    width,
  ];
}

/// Pillow `arc`: the band [width] px wide inside the ellipse of the box,
/// from [start] to [end] degrees, clockwise from three o'clock.
class ArcOp extends HudOp {
  const ArcOp(
    this.x0,
    this.y0,
    this.x1,
    this.y1,
    this.start,
    this.end, {
    required this.color,
    this.width = 1,
  });

  final double x0;
  final double y0;
  final double x1;
  final double y1;
  final double start;
  final double end;
  final Rgb color;
  final int width;

  @override
  List<Object?> toJson() => [
    'arc',
    x0,
    y0,
    x1,
    y1,
    start,
    end,
    _rgb(color),
    width,
  ];
}
