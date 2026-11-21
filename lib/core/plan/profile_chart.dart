/// The Dive Profile Builder's chart without its drawing (Python
/// `gui/dive_profile_view.py`): the axes, the mapping between a point of
/// the chart and a time and depth, and the colour of the profile line.
library;

import 'package:uwmedia_app/core/plan/dive_plan.dart';
import 'package:uwmedia_app/core/plan/dive_plan_engine.dart';

const depthLineColor = '#0EA5A4';

/// The line colours a gas can have, picked to stay apart from the grey
/// shading of the deco stops, the yellow waypoint handles and the white
/// cursor.
const gasColors = [
  '#0EA5A4', // teal
  '#3B82F6', // blue
  '#22C55E', // green
  '#A855F7', // purple
  '#F97316', // orange
  '#EC4899', // pink
  '#84CC16', // lime
  '#06B6D4', // cyan
  '#EF4444', // red
];

const chartMarginLeft = 50;
const chartMarginRight = 16;
const chartMarginTop = 26;
const chartMarginBottom = 28;

/// So that the line does not hug the bottom axis.
const depthHeadroom = 1.1;

/// The gas's own colour, or a colour by its place in the plan's list of
/// gases (so that older plans without colours still differ).
String gasColor(DiveProfilePlan plan, String gasId) {
  for (final (i, gas) in plan.gases.indexed) {
    if (gas.id == gasId) {
      final own = gas.color ?? '';
      return own.isNotEmpty ? own : gasColors[i % gasColors.length];
    }
  }
  return depthLineColor;
}

/// The colour of the profile line at a sample: the gas breathed, or on a
/// sidemount dive the colour of the tank in use, so that each change of
/// side shows.
String sampleColor(DiveProfilePlan plan, SimulatedSample sample) {
  if (plan.sidemountTanks() != null) {
    final tankGas = plan.gasForTank(sample.tankRef);
    if (tankGas != null && plan.breathedGas(tankGas).id == sample.gasId) {
      return gasColor(plan, tankGas.id);
    }
  }
  return gasColor(plan, sample.gasId);
}

/// The first colour no gas of the plan has yet.
String nextFreeGasColor(DiveProfilePlan plan) {
  final used = {for (final g in plan.gases) gasColor(plan, g.id)};
  return gasColors.where((c) => !used.contains(c)).firstOrNull ??
      gasColors[plan.gases.length % gasColors.length];
}

/// The greatest time (seconds) and depth (metres) the chart is drawn
/// with, shared by the drawing and the click mapping so that a click
/// lands where it was drawn. The plan's own planned depth and runtime fix
/// the axes before any waypoint exists; they only grow when the profile
/// does. `null` when there is nothing to scale from.
(double maxTime, double maxDepth)? chartAxes(
  DiveProfilePlan plan,
  List<SimulatedSample> samples,
) {
  final runtime = plan.plannedRuntimeSec ?? 0;
  final planned = plan.maxDepthM ?? 0.0;
  if (samples.isEmpty && !(runtime != 0 && planned != 0)) {
    return null;
  }
  var maxTime = runtime;
  var maxDepth = planned != 0 ? planned : double.negativeInfinity;
  var any = planned != 0;
  for (final s in samples) {
    maxTime = s.timeSec > maxTime ? s.timeSec : maxTime;
    maxDepth = s.depthM > maxDepth ? s.depthM : maxDepth;
    any = true;
  }
  for (final wp in plan.waypoints) {
    maxTime = wp.runtimeSec > maxTime ? wp.runtimeSec : maxTime;
    maxDepth = wp.depthM > maxDepth ? wp.depthM : maxDepth;
    any = true;
  }
  final depth = any ? maxDepth : 1.0;
  return (
    (maxTime == 0 ? 1 : maxTime).toDouble(),
    (depth > 5.0 ? depth : 5.0) * depthHeadroom,
  );
}

(int, int) _plot(int width, int height) {
  final w = width - chartMarginLeft - chartMarginRight;
  final h = height - chartMarginTop - chartMarginBottom;
  return (w < 1 ? 1 : w, h < 1 ? 1 : h);
}

/// Where a time and depth are on a chart of this size.
(double x, double y) xyOf(
  num timeSec,
  num depthM,
  int width,
  int height,
  (double, double) axes,
) {
  final (plotW, plotH) = _plot(width, height);
  return (
    chartMarginLeft + (timeSec / axes.$1) * plotW,
    chartMarginTop + (depthM / axes.$2) * plotH,
  );
}

double _unit(double x) => x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x);

/// The time and depth of a point of the chart, held within the plotted
/// range: the inverse of [xyOf].
(double timeSec, double depthM) pointFromXy(
  num x,
  num y,
  int width,
  int height,
  (double, double) axes,
) {
  final (plotW, plotH) = _plot(width, height);
  return (
    _unit((x - chartMarginLeft) / plotW) * axes.$1,
    _unit((y - chartMarginTop) / plotH) * axes.$2,
  );
}

/// The dive time of a chart x, held within the plotted range.
double timeFromX(num x, int width, double maxTimeSec) =>
    _unit((x - chartMarginLeft) / _plot(width, 0).$1) * maxTimeSec;

/// The sample nearest a time; the earlier of two equally near.
SimulatedSample? nearestSample(List<SimulatedSample> samples, num timeSec) {
  SimulatedSample? best;
  for (final s in samples) {
    if (best == null ||
        (s.timeSec - timeSec).abs() < (best.timeSec - timeSec).abs()) {
      best = s;
    }
  }
  return best;
}
