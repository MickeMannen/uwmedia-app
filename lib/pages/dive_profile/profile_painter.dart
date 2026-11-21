/// The Dive Profile Builder's chart (Python `gui/dive_profile_view.py`
/// `render_profile_image`, with `show_readout=False` as the page uses it):
/// grid lines at round depths and times, the planned max depth dashed,
/// the deco stops shaded, the profile in each gas's colour with a legend,
/// the waypoints and the cursor. Drawn in the chart's own 700 x 420 pixels.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:uwmedia_app/core/plan/dive_plan.dart';
import 'package:uwmedia_app/core/plan/dive_plan_engine.dart';
import 'package:uwmedia_app/core/plan/profile_chart.dart';
import 'package:uwmedia_app/core/units/units.dart' as u;

const _bg = Color(0xFF1F2937);
const _grid = Color(0xFF374151);
const _axisText = Color(0xFF9CA3AF);
const _depthLine = Color(0xFF0EA5A4);
const _waypoint = Color(0xFFFBBF24);
const _cursor = Color(0xFFFFFFFF);
const _decoStop = (156, 163, 175);
const _decoAlphaMin = 35;
const _decoAlphaMax = 190;
const _decoLevelM = 3.0;

/// `#RRGGBB` as a colour.
Color hexColor(String hex) {
  final value = int.tryParse(hex.replaceFirst('#', ''), radix: 16) ?? 0xFFFFFF;
  return Color(0xFF000000 | value);
}

String _mmss(num seconds) {
  final s = math.max(0, seconds.truncate());
  return '${s ~/ 60}:${'${s % 60}'.padLeft(2, '0')}';
}

class ProfilePainter extends CustomPainter {
  ProfilePainter({
    required this.plan,
    required this.samples,
    required this.units,
    this.cursorTime,
    this.waypointsOnly = false,
    this.decoSchedules = const [],
    this.decoIntervalSec = decoScheduleIntervalSec,
    this.revision = 0,
  });

  final DiveProfilePlan plan;
  final List<SimulatedSample> samples;
  final u.UnitSystem units;
  final double? cursorTime;
  final bool waypointsOnly;
  final List<(int, List<PlanStop>)> decoSchedules;
  final int decoIntervalSec;

  /// Changes whenever the plan does (the plan itself is edited in place).
  final int revision;

  static const width = 700;
  static const height = 420;

  void _text(Canvas canvas, String text, Offset at, Color color, double size) {
    (TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: size),
      ),
      textDirection: TextDirection.ltr,
    )..layout()).paint(canvas, at);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..scale(size.width / width, size.height / height)
      ..drawRect(
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..color = _bg,
      );
    final axes = chartAxes(plan, samples);
    if (axes == null) {
      _text(
        canvas,
        'Click in the chart to place the first waypoint',
        const Offset(chartMarginLeft + 0.0, chartMarginTop + 0.0),
        _axisText,
        14,
      );
      canvas.restore();
      return;
    }
    final (maxTime, maxDepth) = axes;
    double x(num t) => xyOf(t, 0, width, height, axes).$1;
    double y(num d) => xyOf(0, d, width, height, axes).$2;
    final gridPaint = Paint()
      ..color = _grid
      ..strokeWidth = 1;
    const left = chartMarginLeft + 0.0;
    const right = width - chartMarginRight + 0.0;
    const top = chartMarginTop + 0.0;
    const bottom = height - chartMarginBottom + 0.0;

    // Depth lines at round numbers of the unit system in force.
    final imperial = units == u.UnitSystem.imperial;
    final double step;
    if (imperial) {
      final maxFt = u.depth(maxDepth, units);
      step = maxFt <= 60 ? 10 : (maxFt <= 150 ? 20 : 50);
    } else {
      step = maxDepth <= 30 ? 5 : 10;
    }
    for (var shown = 0.0; ; shown += step) {
      final d = imperial ? u.depthToMetres(shown, units) : shown;
      if (d > maxDepth) {
        break;
      }
      final yy = y(d);
      canvas.drawLine(Offset(left, yy), Offset(right, yy), gridPaint);
      _text(
        canvas,
        '${shown.truncate()}${u.depthLabel(units)}',
        Offset(4, yy - 7),
        _axisText,
        11,
      );
    }
    final timeStep = maxTime <= 1800 ? 300 : 600;
    for (var t = 0; t <= maxTime; t += timeStep) {
      final xx = x(t);
      canvas.drawLine(Offset(xx, top), Offset(xx, bottom), gridPaint);
      _text(canvas, _mmss(t), Offset(xx - 12, bottom + 5), _axisText, 11);
    }
    final planned = plan.maxDepthM;
    if (planned != null && planned > 0) {
      final yy = y(planned);
      final dash = Paint()
        ..color = _axisText
        ..strokeWidth = 1;
      for (var x0 = left; x0 < right; x0 += 12) {
        canvas.drawLine(
          Offset(x0, yy),
          Offset(math.min(x0 + 6, right), yy),
          dash,
        );
      }
    }
    if (samples.isEmpty && plan.waypoints.isEmpty) {
      _text(
        canvas,
        'Click to place a waypoint · drag a point to move it · right-click '
        'to delete',
        const Offset(left + 8, top + 8),
        _axisText,
        14,
      );
    }

    if (waypointsOnly) {
      final path = Path()..moveTo(x(0), y(0));
      for (final wp in plan.sortedWaypoints()) {
        path.lineTo(x(wp.runtimeSec), y(wp.depthM));
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = _depthLine
          ..style = PaintingStyle.stroke,
      );
    } else {
      if (decoSchedules.isNotEmpty) {
        _decoShading(canvas, x, y);
      }
      final line = Paint()
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i + 1 < samples.length; i++) {
        canvas.drawLine(
          Offset(x(samples[i].timeSec), y(samples[i].depthM)),
          Offset(x(samples[i + 1].timeSec), y(samples[i + 1].depthM)),
          line..color = hexColor(sampleColor(plan, samples[i + 1])),
        );
      }
      _legend(canvas, right - 8, bottom - 8);
    }

    for (final wp in plan.sortedWaypoints()) {
      final c = Offset(x(wp.runtimeSec), y(wp.depthM));
      canvas
        ..drawCircle(c, 4, Paint()..color = _waypoint)
        ..drawCircle(
          c,
          4,
          Paint()
            ..color = _bg
            ..style = PaintingStyle.stroke,
        );
    }

    final cursor = waypointsOnly ? null : cursorTime;
    if (cursor != null) {
      final nearest = nearestSample(samples, cursor);
      if (nearest != null) {
        final xx = x(nearest.timeSec);
        canvas
          ..drawLine(
            Offset(xx, top),
            Offset(xx, bottom),
            Paint()..color = _cursor,
          )
          ..drawCircle(
            Offset(xx, y(nearest.depthM)),
            5,
            Paint()
              ..color = _cursor
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2,
          );
      }
    }
    canvas.restore();
  }

  // Every planned stop over time: the 3 m level above each stop, darker
  // for longer stops (against the longest in the dive).
  void _decoShading(
    Canvas canvas,
    double Function(num) x,
    double Function(num) y,
  ) {
    var longest = 0;
    for (final (_, stops) in decoSchedules) {
      for (final (_, duration, _) in stops) {
        longest = math.max(longest, duration);
      }
    }
    if (longest <= 0) {
      return;
    }
    for (final (t, stops) in decoSchedules) {
      final x0 = x(t);
      final x1 = x(t + decoIntervalSec);
      final perDepth = <double, int>{};
      for (final (depth, duration, _) in stops) {
        perDepth[depth] = (perDepth[depth] ?? 0) + duration;
      }
      perDepth.forEach((depth, duration) {
        final alpha =
            _decoAlphaMin +
            (_decoAlphaMax - _decoAlphaMin) * math.min(1.0, duration / longest);
        canvas.drawRect(
          Rect.fromLTRB(
            x0,
            y(math.max(0.0, depth - _decoLevelM)),
            math.max(x0 + 1, x1 - 1),
            y(depth),
          ),
          Paint()
            ..color = Color.fromARGB(
              alpha.truncate(),
              _decoStop.$1,
              _decoStop.$2,
              _decoStop.$3,
            ),
        );
      });
    }
  }

  // A swatch and name per gas breathed (per tank of a sidemount pair),
  // and one for the deco shading, stacked up from the bottom right.
  void _legend(Canvas canvas, double right, double bottom) {
    final used = {for (final s in samples) s.gasId};
    final pair = plan.sidemountTanks();
    final rows = <(String, Color, bool)>[];
    for (final g in plan.gases) {
      if (pair != null && (identical(g, pair.$1) || identical(g, pair.$2))) {
        if (used.contains(pair.$1.id)) {
          final side = g.side == 'left' ? 'L' : 'R';
          rows.add((
            '${g.id} (${g.tankRef} $side)',
            hexColor(gasColor(plan, g.id)),
            false,
          ));
        }
      } else if (used.contains(g.id)) {
        rows.add((g.id, hexColor(gasColor(plan, g.id)), false));
      }
    }
    if (decoSchedules.isNotEmpty) {
      rows.add((
        'Deco stops',
        Color.fromARGB(255, _decoStop.$1, _decoStop.$2, _decoStop.$3),
        true,
      ));
    }
    if (rows.isEmpty) {
      return;
    }
    const rowH = 16.0;
    final painters = [
      for (final (label, _, _) in rows)
        TextPainter(
          text: TextSpan(
            text: label,
            style: const TextStyle(color: _axisText, fontSize: 11),
          ),
          textDirection: TextDirection.ltr,
        )..layout(),
    ];
    final namesW = painters.map((t) => t.width).reduce(math.max);
    final left = right - namesW - 28;
    final top = bottom - rowH * rows.length - 4;
    canvas
      ..drawRect(
        Rect.fromLTRB(left - 6, top - 4, right + 4, bottom + 2),
        Paint()..color = _bg,
      )
      ..drawRect(
        Rect.fromLTRB(left - 6, top - 4, right + 4, bottom + 2),
        Paint()
          ..color = _grid
          ..style = PaintingStyle.stroke,
      );
    for (final (i, (_, color, filled)) in rows.indexed) {
      final yy = top + i * rowH + rowH / 2;
      if (filled) {
        canvas.drawRect(
          Rect.fromLTRB(left, yy - 5, left + 18, yy + 5),
          Paint()..color = color,
        );
      } else {
        canvas.drawLine(
          Offset(left, yy),
          Offset(left + 18, yy),
          Paint()
            ..color = color
            ..strokeWidth = 3,
        );
      }
      painters[i].paint(canvas, Offset(left + 24, yy - 7));
    }
  }

  @override
  bool shouldRepaint(ProfilePainter old) => true;
}
