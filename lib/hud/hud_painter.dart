/// Draws the overlay renderer's operations (`lib/core/hud/hud_ops.dart`) on
/// a Flutter canvas: the one place where the overlay becomes pixels, for
/// the preview, the Overlay Designer and the export alike.
///
/// The operations carry the meaning of the Pillow and OpenCV calls of the
/// Python app, and the painter keeps it: a Pillow box includes its last
/// pixel row and column, shapes are drawn without anti-aliasing (text
/// with), an outline lies inside its shape, a text position is the top of
/// the font's line, and what is drawn after the skin is cut to the skin's
/// `screen`. Text is set in the bundled font files, one Flutter font family
/// per file (named after the file, see `pubspec.yaml`).
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:uwmedia_app/core/hud/hud_ops.dart';
import 'package:uwmedia_app/core/hud/ttf_font.dart';

/// The Flutter font family of a bundled font file.
String fontFamilyOf(String fontFile) => fontFile.replaceAll('.ttf', '');

class HudPainter {
  HudPainter(this.fonts);

  /// For the line top of each font and the ink of a turned text.
  final TtfFonts fonts;

  /// Draws [ops] on [canvas]. [skin] is the skin image for the [SkinOp]
  /// (none for a shape skin) and [skinOpacity] the layout's
  /// `hud_skin.opacity`.
  void paint(
    ui.Canvas canvas,
    List<HudOp> ops, {
    ui.Image? skin,
    double skinOpacity = 1.0,
  }) {
    final clip = ops.whereType<ClipOp>().firstOrNull;
    var clipped = false;
    for (final op in ops) {
      switch (op) {
        case SkinOp():
          if (skin != null) {
            canvas.drawImageRect(
              skin,
              ui.Rect.fromLTWH(
                0,
                0,
                skin.width.toDouble(),
                skin.height.toDouble(),
              ),
              ui.Rect.fromLTWH(
                op.x.toDouble(),
                op.y.toDouble(),
                op.width.toDouble(),
                op.height.toDouble(),
              ),
              ui.Paint()
                ..filterQuality = ui.FilterQuality.medium
                ..color = ui.Color.fromRGBO(0, 0, 0, skinOpacity.clamp(0, 1)),
            );
          }
          if (clip != null) {
            // Everything from here to the ClipOp stays inside the screen.
            canvas.save();
            clipped = true;
            final rect = ui.Rect.fromLTRB(
              clip.x0.toDouble(),
              clip.y0.toDouble(),
              clip.x1.toDouble(),
              clip.y1.toDouble(),
            );
            if (clip.shape == 'ellipse') {
              canvas.clipPath(ui.Path()..addOval(rect), doAntiAlias: false);
            } else {
              canvas.clipRect(rect, doAntiAlias: false);
            }
          }
        case ClipOp():
          if (clipped) {
            canvas.restore();
            clipped = false;
          }
        default:
          _draw(canvas, op);
      }
    }
    if (clipped) {
      canvas.restore();
    }
  }

  static ui.Color _color(Rgb c) => ui.Color.fromARGB(255, c.$1, c.$2, c.$3);

  static ui.Paint _fill(Rgb c) => ui.Paint()
    ..color = _color(c)
    ..isAntiAlias = false;

  static ui.Paint _stroke(Rgb c, num width) => ui.Paint()
    ..color = _color(c)
    ..isAntiAlias = false
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = width.toDouble();

  /// An OpenCV line: one pixel wide for a thickness of 1; a thicker one
  /// takes every pixel whose centre is within half the thickness of the
  /// line, its ends rounded, which is a pixel more than the thickness.
  static ui.Paint _cvStroke(Rgb c, int thickness) => thickness <= 1
      ? (_stroke(c, 1)..strokeCap = ui.StrokeCap.square)
      : (_stroke(c, thickness + 1)
          ..strokeCap = ui.StrokeCap.round
          ..strokeJoin = ui.StrokeJoin.round);

  /// A Pillow box as the rectangle of the pixels it covers.
  static ui.Rect _box(double x0, double y0, double x1, double y1) =>
      ui.Rect.fromLTRB(
        x0.floorToDouble(),
        y0.floorToDouble(),
        x1.floorToDouble() + 1,
        y1.floorToDouble() + 1,
      );

  /// A path through pixel centres.
  static ui.Path _path(Iterable<(num, num)> points, {required bool close}) {
    final path = ui.Path();
    var first = true;
    for (final (x, y) in points) {
      if (first) {
        path.moveTo(x + 0.5, y + 0.5);
        first = false;
      } else {
        path.lineTo(x + 0.5, y + 0.5);
      }
    }
    if (close) {
      path.close();
    }
    return path;
  }

  /// A shape filled and outlined the Pillow way: the outline, [width] px,
  /// lies inside the shape's box.
  void _shape(
    ui.Canvas canvas,
    ui.Rect box,
    void Function(ui.Rect rect, ui.Paint paint) draw, {
    Rgb? fill,
    Rgb? outline,
    int width = 1,
  }) {
    if (fill != null) {
      draw(box, _fill(fill));
    }
    if (outline != null && width > 0) {
      draw(box.deflate(width / 2), _stroke(outline, width));
    }
  }

  void _draw(ui.Canvas canvas, HudOp op) {
    switch (op) {
      case SkinOp() || ClipOp():
        break;
      case BlendOp():
        if (op.opacity <= 0) {
          return;
        }
        canvas.saveLayer(
          null,
          ui.Paint()
            ..color = ui.Color.fromRGBO(0, 0, 0, op.opacity.clamp(0, 1)),
        );
        for (final inner in op.ops) {
          _draw(canvas, inner);
        }
        canvas.restore();
      case CvRoundedRectOp():
        final rect = ui.RRect.fromRectAndRadius(
          ui.Rect.fromLTRB(
            op.x0.toDouble(),
            op.y0.toDouble(),
            op.x1 + 1.0,
            op.y1 + 1.0,
          ),
          ui.Radius.circular(op.radius.toDouble()),
        );
        canvas.drawRRect(
          rect,
          op.thickness < 0 ? _fill(op.color) : _stroke(op.color, op.thickness),
        );
      case CvRectOp():
        final rect = ui.Rect.fromLTRB(
          math.min(op.x0, op.x1).toDouble(),
          math.min(op.y0, op.y1).toDouble(),
          math.max(op.x0, op.x1) + 1.0,
          math.max(op.y0, op.y1) + 1.0,
        );
        if (op.thickness < 0) {
          canvas.drawRect(rect, _fill(op.color));
        } else {
          canvas.drawRect(
            rect.deflate(0.5),
            _stroke(op.color, math.max(1, op.thickness)),
          );
        }
      case CvLineOp():
        canvas.drawLine(
          ui.Offset(op.x0 + 0.5, op.y0 + 0.5),
          ui.Offset(op.x1 + 0.5, op.y1 + 0.5),
          _cvStroke(op.color, op.thickness),
        );
      case CvPolylineOp():
        canvas.drawPath(
          _path(op.points, close: false),
          _cvStroke(op.color, op.thickness),
        );
      case CvFillOp():
        final path = _path(op.points, close: true);
        canvas
          ..drawPath(path, _fill(op.color))
          // OpenCV fills the outline's pixels too.
          ..drawPath(path, _stroke(op.color, 1));
      case CvCircleOp():
        final centre = ui.Offset(op.x + 0.5, op.y + 0.5);
        if (op.thickness < 0) {
          canvas.drawCircle(centre, op.radius + 0.5, _fill(op.color));
        } else {
          canvas.drawCircle(
            centre,
            op.radius.toDouble(),
            _stroke(op.color, math.max(1, op.thickness))..isAntiAlias = true,
          );
        }
      case TextOp():
        _text(
          canvas,
          op.text,
          op.fontFile,
          op.size,
          op.x,
          op.y,
          op.color,
          strokeWidth: op.strokeWidth,
          strokeColor: op.strokeColor,
        );
      case RotatedTextOp():
        _rotatedText(canvas, op);
      case RectOp():
        _shape(
          canvas,
          _box(op.x0, op.y0, op.x1, op.y1),
          canvas.drawRect,
          fill: op.fill,
          outline: op.outline,
          width: op.width,
        );
      case RoundedRectOp():
        final radius = ui.Radius.circular(op.radius);
        _shape(
          canvas,
          _box(op.x0, op.y0, op.x1, op.y1),
          (rect, paint) => canvas.drawRRect(
            ui.RRect.fromRectAndRadius(
              rect,
              paint.style == ui.PaintingStyle.stroke
                  ? ui.Radius.circular(
                      math.max(0, op.radius - paint.strokeWidth / 2),
                    )
                  : radius,
            ),
            paint,
          ),
          fill: op.fill,
          outline: op.outline,
          width: op.width,
        );
      case PolygonOp():
        final path = _path(op.points, close: true);
        final fill = op.fill;
        if (fill != null) {
          canvas
            ..drawPath(path, _fill(fill))
            ..drawPath(path, _stroke(fill, 1));
        }
        final outline = op.outline;
        if (outline != null && op.width > 0) {
          if (op.width == 1) {
            canvas.drawPath(path, _stroke(outline, 1));
          } else {
            // Pillow keeps a wide outline inside the polygon.
            canvas
              ..save()
              ..clipPath(path, doAntiAlias: false)
              ..drawPath(
                path,
                _stroke(outline, op.width * 2 - 1)
                  ..strokeJoin = ui.StrokeJoin.miter,
              )
              ..restore();
          }
        }
      case LineOp():
        canvas.drawPath(
          _path(op.points, close: false),
          _stroke(op.color, math.max(1, op.width))
            ..strokeJoin = op.joint == 'curve'
                ? ui.StrokeJoin.round
                : ui.StrokeJoin.miter
            ..strokeCap = ui.StrokeCap.butt
            ..isAntiAlias = op.joint == 'curve',
        );
      case EllipseOp():
        _shape(
          canvas,
          _box(op.x0, op.y0, op.x1, op.y1),
          canvas.drawOval,
          fill: op.fill,
          outline: op.outline,
          width: op.width,
        );
      case PieSliceOp():
        const degree = math.pi / 180;
        var sweep = op.end - op.start;
        while (sweep <= 0) {
          sweep += 360;
        }
        _shape(
          canvas,
          _box(op.x0, op.y0, op.x1, op.y1),
          (rect, paint) => canvas.drawArc(
            rect,
            op.start * degree,
            sweep * degree,
            true,
            paint,
          ),
          fill: op.fill,
          outline: op.outline,
          width: op.width,
        );
      case ArcOp():
        // Pillow: the band lies inside the box, [width] px wide; a sweep
        // of a full turn or more is the whole ring. A sweep of a fraction
        // of a degree paints a radial stub in Pillow and next to nothing
        // here (an arc gauge one second into a long range).
        const degree = math.pi / 180;
        var sweep = op.end - op.start;
        if (sweep >= 360) {
          sweep = 360;
        } else {
          sweep = (op.end % 360) - (op.start % 360);
          if (sweep < 0) {
            sweep += 360;
          }
        }
        if (sweep <= 0 || op.width <= 0) {
          return;
        }
        canvas.drawArc(
          _box(op.x0, op.y0, op.x1, op.y1).deflate(op.width / 2),
          op.start * degree,
          sweep * degree,
          false,
          _stroke(op.color, op.width)..strokeCap = ui.StrokeCap.butt,
        );
    }
  }

  ui.Paragraph _paragraph(
    String text,
    String fontFile,
    int size, {
    ui.Color? color,
    ui.Paint? foreground,
  }) {
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(textDirection: ui.TextDirection.ltr),
          )
          ..pushStyle(
            ui.TextStyle(
              fontFamily: fontFamilyOf(fontFile),
              fontSize: size.toDouble(),
              color: color,
              foreground: foreground,
            ),
          )
          ..addText(text);
    return builder.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
  }

  /// [text] with the top of its line (the font's ascender, in whole
  /// pixels, as Pillow has it) at ([x], [y]).
  void _text(
    ui.Canvas canvas,
    String text,
    String fontFile,
    int size,
    double x,
    double y,
    Rgb color, {
    int strokeWidth = 0,
    Rgb? strokeColor,
  }) {
    if (text.isEmpty) {
      return;
    }
    final ascent = fonts.font(size, fontFile).ascent;
    ui.Offset at(ui.Paragraph p) =>
        ui.Offset(x, y + ascent - p.alphabeticBaseline);
    if (strokeWidth > 0 && strokeColor != null) {
      final outline = _paragraph(
        text,
        fontFile,
        size,
        foreground: ui.Paint()
          ..color = _color(strokeColor)
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = strokeWidth * 2.0
          ..strokeJoin = ui.StrokeJoin.round,
      );
      canvas.drawParagraph(outline, at(outline));
    }
    final paragraph = _paragraph(text, fontFile, size, color: _color(color));
    canvas.drawParagraph(paragraph, at(paragraph));
  }

  /// A line turned on its side: drawn flat on a tile with a margin around
  /// its ink, the tile turned a quarter and put with its corner at the
  /// operation's position.
  void _rotatedText(ui.Canvas canvas, RotatedTextOp op) {
    final (left, top, right, bottom) = fonts
        .font(op.size, op.fontFile)
        .getbbox(op.text);
    final distance = math.max(1, op.size ~/ 20);
    final margin = distance + 1;
    final tileW = right - left + 2 * margin;
    final tileH = bottom - top + 2 * margin;
    canvas.save();
    if (op.orientation == 'up') {
      // A quarter turn against the clock: the tile's right edge is on top.
      canvas
        ..translate(op.x.toDouble(), op.y + tileW.toDouble())
        ..rotate(-math.pi / 2);
    } else {
      canvas
        ..translate(op.x + tileH.toDouble(), op.y.toDouble())
        ..rotate(math.pi / 2);
    }
    final x = (margin - left).toDouble();
    final y = (margin - top).toDouble();
    if (op.outline > 0) {
      for (final (dx, dy) in [(-1, -1), (1, -1), (-1, 1), (1, 1)]) {
        _text(
          canvas,
          op.text,
          op.fontFile,
          op.size,
          x + dx * op.outline,
          y + dy * op.outline,
          (0, 0, 0),
        );
      }
    }
    _text(canvas, op.text, op.fontFile, op.size, x, y, op.color);
    canvas.restore();
  }
}
