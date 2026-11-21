/// The Log Viewer's two charts (Python `qml/ProfileChart.qml` and
/// `qml/Po2Chart.qml`): the depth profile with the deco ceiling where the
/// log has one, and a rebreather dive's PO2 strip with the setpoint, the
/// three cells and the bailout stretches shaded. Both hide themselves for
/// fewer than two samples and share their left and right margins, so that
/// they line up.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:uwmedia_app/app/theme.dart';
import 'package:uwmedia_app/core/pages/log_viewer.dart';

const _axis = Color(0xFF444444);
const _ceiling = Color(0xFFF59E0B);
const _po2 = Color(0xFFE5E7EB);
const _setpoint = Color(0xFF22C55E);
const _cells = [Color(0xFF38BDF8), Color(0xFFA78BFA), Color(0xFFF472B6)];
const _bailout = Color(0xFF3A3418);

Widget _legend(List<(String, Color)> items) => Wrap(
  spacing: 12,
  children: [
    for (final (text, color) in items)
      Text(text, style: TextStyle(color: color, fontSize: 11)),
  ],
);

void _label(Canvas canvas, String text, Offset at) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: const TextStyle(color: mutedText, fontSize: 10),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  // [at] is the text's baseline start, as a canvas 2D fillText.
  painter.paint(
    canvas,
    at -
        Offset(
          0,
          painter.computeDistanceToActualBaseline(TextBaseline.alphabetic),
        ),
  );
}

/// The depth profile.
class ProfileChart extends StatelessWidget {
  const ProfileChart({
    super.key,
    required this.samples,
    required this.depthUnit,
    required this.showCeiling,
  });

  final List<ChartSample> samples;
  final String depthUnit;
  final bool showCeiling;

  @override
  Widget build(BuildContext context) {
    if (samples.length < 2) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        _legend([
          ('Depth profile', mutedText),
          ('● depth', accent),
          if (showCeiling) ('● ceiling', _ceiling),
        ]),
        SizedBox(
          height: 180,
          child: CustomPaint(
            painter: _ProfilePainter(samples, depthUnit, showCeiling),
          ),
        ),
      ],
    );
  }
}

class _ProfilePainter extends CustomPainter {
  _ProfilePainter(this.samples, this.unit, this.showCeiling);

  final List<ChartSample> samples;
  final String unit;
  final bool showCeiling;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 44.0, right = 12.0, top = 10.0, bottom = 20.0;
    final w = size.width - left - right;
    final h = size.height - top - bottom;
    if (samples.length < 2 || w <= 0 || h <= 0) {
      return;
    }
    final t0 = samples.first.time;
    var maxTime = (samples.last.time - t0).toDouble();
    var maxDepth = samples.map((s) => s.depth).reduce(math.max);
    if (maxDepth <= 0) {
      maxDepth = 1;
    }
    if (maxTime <= 0) {
      maxTime = 1;
    }
    double x(int t) => left + (t - t0) / maxTime * w;
    double y(double d) => top + d / maxDepth * h;

    canvas.drawPath(
      Path()
        ..moveTo(left, top)
        ..lineTo(left, top + h)
        ..lineTo(left + w, top + h),
      Paint()
        ..color = _axis
        ..style = PaintingStyle.stroke,
    );
    final depth = Path();
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      i == 0
          ? depth.moveTo(x(s.time), y(s.depth))
          : depth.lineTo(x(s.time), y(s.depth));
    }
    canvas.drawPath(
      depth,
      Paint()
        ..color = accent
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
    if (showCeiling) {
      // Only where there is one, in separate runs.
      final ceiling = Path();
      var drawing = false;
      for (final s in samples) {
        if (s.ceiling <= 0) {
          drawing = false;
          continue;
        }
        drawing
            ? ceiling.lineTo(x(s.time), y(s.ceiling))
            : ceiling.moveTo(x(s.time), y(s.ceiling));
        drawing = true;
      }
      canvas.drawPath(
        ceiling,
        Paint()
          ..color = _ceiling
          ..strokeWidth = 1.2
          ..style = PaintingStyle.stroke,
      );
    }
    _label(canvas, '0 $unit', const Offset(4, top + 8));
    _label(
      canvas,
      '${maxDepth.toStringAsFixed(unit == 'ft' ? 0 : 1)} $unit',
      Offset(4, top + h),
    );
    _label(
      canvas,
      // JavaScript's Math.round, as the Python page's chart.
      '${(maxTime / 60 + 0.5).floor()} min',
      Offset(left + w - 30, size.height - 4),
    );
  }

  @override
  bool shouldRepaint(_ProfilePainter old) =>
      old.samples != samples ||
      old.unit != unit ||
      old.showCeiling != showCeiling;
}

/// A rebreather dive's PO2 strip.
class Po2Chart extends StatelessWidget {
  const Po2Chart({super.key, required this.samples});

  final List<Po2Sample> samples;

  @override
  Widget build(BuildContext context) {
    if (samples.length < 2) {
      return const SizedBox.shrink();
    }
    final hasCells = samples.any((s) => s.c1 >= 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        _legend([
          ('PO₂ (bar)', mutedText),
          ('● PO₂', _po2),
          ('● setpoint', _setpoint),
          if (hasCells) ('● cells', _cells.first),
          ('▇ bailout', const Color(0xFF8A7A2A)),
        ]),
        SizedBox(
          height: 110,
          child: CustomPaint(painter: _Po2Painter(samples)),
        ),
      ],
    );
  }
}

class _Po2Painter extends CustomPainter {
  _Po2Painter(this.samples);

  final List<Po2Sample> samples;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 44.0, right = 12.0, top = 6.0, bottom = 14.0;
    final w = size.width - left - right;
    final h = size.height - top - bottom;
    if (samples.length < 2 || w <= 0 || h <= 0) {
      return;
    }
    final t0 = samples.first.time;
    final maxTime = math.max(1, samples.last.time - t0).toDouble();
    var maxPo2 = 1.6;
    for (final s in samples) {
      for (final v in [s.po2, s.setpoint, s.c1, s.c2, s.c3]) {
        maxPo2 = math.max(maxPo2, v);
      }
    }
    double x(int t) => left + (t - t0) / maxTime * w;
    double y(double v) => top + h - v / maxPo2 * h;

    final shade = Paint()..color = _bailout;
    for (var i = 0; i < samples.length - 1; i++) {
      if (samples[i].bailout) {
        final from = x(samples[i].time);
        canvas.drawRect(
          Rect.fromLTWH(
            from,
            top,
            math.max(1, x(samples[i + 1].time) - from),
            h,
          ),
          shade,
        );
      }
    }
    canvas.drawPath(
      Path()
        ..moveTo(left, top)
        ..lineTo(left, top + h)
        ..lineTo(left + w, top + h),
      Paint()
        ..color = _axis
        ..style = PaintingStyle.stroke,
    );
    void series(double Function(Po2Sample) value, Color color, double width) {
      final path = Path();
      var drawing = false;
      for (final s in samples) {
        final v = value(s);
        if (v < 0) {
          drawing = false;
          continue;
        }
        drawing ? path.lineTo(x(s.time), y(v)) : path.moveTo(x(s.time), y(v));
        drawing = true;
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = width
          ..style = PaintingStyle.stroke,
      );
    }

    series((s) => s.c1, _cells[0], 1);
    series((s) => s.c2, _cells[1], 1);
    series((s) => s.c3, _cells[2], 1);
    series((s) => s.setpoint, _setpoint, 1.5);
    series((s) => s.po2, _po2, 1.2);
    _label(canvas, maxPo2.toStringAsFixed(1), const Offset(4, top + 8));
    _label(canvas, '0', Offset(4, top + h));
  }

  @override
  bool shouldRepaint(_Po2Painter old) => old.samples != samples;
}
