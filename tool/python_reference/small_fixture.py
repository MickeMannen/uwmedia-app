"""Parity fixture for small pieces of the pages' logic: utils/run_timing.py
(the elapsed and remaining line of a long run), utils/display_paths.py and
the chart mapping of gui/dive_profile_view.py (axes, pixel to time and
depth, gas colours).

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 QT_QPA_PLATFORM=offscreen .venv/bin/python -B \
        $APP_REPO/tool/python_reference/small_fixture.py \
        > $APP_REPO/test/fixtures/python_reference/pages/small_cases.json
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, ".")
sys.path.insert(0, str(Path(__file__).resolve().parent))

import plan_fixture as P  # noqa: E402

import gui.dive_profile_view as view  # noqa: E402
from utils import display_paths, run_timing  # noqa: E402
from utils import dive_plan_engine as E  # noqa: E402


class Clock:
    def __init__(self):
        self.now = 100.0

    def __call__(self):
        return self.now


def timer_runs():
    """Scripts of [op, value]: "wait" seconds, "start", "stop", "fail",
    "reset", and "ask" a fraction, which records what the timer says."""
    scripts = [
        [["ask", 0.0], ["start"], ["wait", 4], ["ask", 0.5], ["wait", 6], ["ask", 0.01], ["ask", 0.03], ["ask", None]],
        [["start"], ["wait", 60], ["ask", 0.25], ["wait", 100], ["ask", 0.8], ["ask", 0.5], ["ask", 1.0], ["ask", 1.7], ["ask", 0.029]],
        [["start"], ["wait", 821], ["stop"], ["wait", 500], ["ask", 1.0], ["start"], ["wait", 130], ["fail"], ["ask", 0.3], ["reset"],
         ["ask", 0.3]],
        [["start"], ["wait", 5.0], ["ask", 0.03], ["wait", 0.4], ["ask", 0.0834], ["wait", 3594.6], ["ask", 0.5], ["ask", 0.999],
         ["wait", 40000], ["ask", 0.6]],
        [["stop"], ["ask", 0.5], ["start"], ["wait", 61.5], ["ask", 0.5], ["ask", 0.506], ["stop"], ["stop"], ["ask", 0.5]],
    ]
    out = []
    for script in scripts:
        clock = Clock()
        timer = run_timing.RunTimer(clock)
        steps = []
        for op, *value in script:
            if op == "wait":
                clock.now += value[0]
            elif op == "start":
                timer.start()
            elif op == "stop":
                timer.stop()
            elif op == "fail":
                timer.stop(ok=False)
            elif op == "reset":
                timer.reset()
            else:
                steps.append({"fraction": value[0], "text": timer.text(value[0]), "remaining": timer.remaining(value[0]),
                              "elapsed": timer.elapsed, "running": timer.running, "started": timer.started})
        out.append({"script": script, "asked": steps})
    return out


def chart_cases():
    out = []
    for name in ("simple", "deco_three_gases", "sidemount", "ccr", "no_waypoints", "legacy_keys", "shallow"):
        for changes in ({}, {"max_depth_m": 40, "planned_runtime_sec": 3600}, {"max_depth_m": 3}, {"planned_runtime_sec": 60}):
            data = {**P.PLANS[name], **changes}
            plan = P.fresh(data)
            samples = E.simulate(plan, resolution_sec=30)[0] if plan.gases else []
            for use_samples in (True, False):
                shown = samples if use_samples else []
                axes = view.chart_axes(plan, shown)
                case = {"plan": name, "changes": changes, "resolution": 30, "with_samples": use_samples,
                        "axes": list(axes) if axes else None,
                        "gas_colors": [[g.id, view.gas_color(plan, g.id)] for g in plan.gases] + [["nope", view.gas_color(plan, "nope")]],
                        "next_free": view.next_free_gas_color(plan),
                        "sample_colors": [view.sample_color(plan, s) for s in shown],
                        "nearest": [[t, getattr(view.nearest_sample(shown, t), "time_sec", None)] for t in (0, 44.9, 45, 45.1, 10 ** 6, -3)]}
                if axes:
                    case["points"] = [[t, d, w, h, list(view.xy_of(t, d, w, h, axes))] for t, d in ((0, 0), (1234, 27.5), (axes[0], axes[1]))
                                      for w, h in ((700, 420), (60, 40), (1920, 300))]
                    case["clicks"] = [[x, y, w, h, list(view.point_from_xy(x, y, w, h, axes)), view.time_from_x(x, w, axes[0])]
                                      for x, y in ((50, 26), (0, 0), (375.5, 200.25), (5000, 5000), (684, 392)) for w, h in ((700, 420), (60, 40))]
                out.append(case)
    return out


if __name__ == "__main__":
    home = str(Path.home())
    out = {
        "min_fraction": run_timing.MIN_FRACTION, "min_elapsed": run_timing.MIN_ELAPSED,
        "durations": [[s, run_timing.format_duration(s)] for s in (0, 7.4, 7.5, 8.5, 59.5, 60, 252, 3599.4, 3599.5, 3825, 86400, -5, 0.49, 359999)],
        "timers": timer_runs(),
        "home_paths": [[p.replace(home, "HOME"), display_paths.contract_home_path(p).replace(home, "HOME") if p else p]
                       for p in (home, home + "/Movies/dive", home + "x/other", "/Volumes/card", "", "relative/" + home, home + "/")]
        + [[None, None]],
        "chart": {"margins": [view.MARGIN_LEFT, view.MARGIN_RIGHT, view.MARGIN_TOP, view.MARGIN_BOTTOM], "headroom": view.DEPTH_HEADROOM,
                  "gas_colors": list(view.GAS_COLORS), "depth_line_color": view.DEPTH_LINE_COLOR, "cases": chart_cases()},
    }
    json.dump(out, sys.stdout, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    sys.stdout.write("\n")
