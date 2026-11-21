"""Parity fixture for the template layout sweep (tests/test_template_sweep.py
of the Python app): what the sweep reports for every bundled page and
variant, in both unit systems, before the known-issue list is applied, the
known-issue list itself (tests/template_sweep_known.json, verbatim), and
Pillow's text measurements, so the port can replay them and be held to the
same issue strings. `synthetic` holds the sweep's reports on a few
invented shape layouts that reach what no bundled page does (text on an
arc's band, a round screen, a name from an empty field, elements hidden
by state, circuit or notice). "Arial" is the bundled Liberation Sans, as
in the port (the renderer fixture's pinning, imported from
renderer_fixture.py).

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/template_sweep_fixture.py \
        | gzip -9n > $APP_REPO/test/fixtures/python_reference/hud_designer/template_sweep.json.gz
"""
import copy
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, ".")
sys.path.insert(0, "tests")
sys.path.insert(0, str(Path(__file__).resolve().parent))

import renderer_fixture as RF  # noqa: E402  (pins the fonts, records the measurements)

import test_template_sweep as S  # noqa: E402
from utils import units as U  # noqa: E402


def synthetic_layouts():
    """Invented layouts on a 400 x 200 shape skin: (name, layout, ccr, units)."""
    els = [
        {"type": "arc", "id": "ring", "field": "ndl", "rel_x": 0.3, "rel_y": 0.2, "width": 120, "height": 120, "thickness": 12},
        {"field": "depth", "rel_x": 0.33, "rel_y": 0.3, "font_size": 30},
        {"field": "ndl", "label": "corner", "rel_x": 0.1, "rel_y": 0.1, "font_size": 24},
        {"field": "dive_time", "rel_x": 0.38, "rel_y": 0.45, "font_size": 20},
        {"type": "badge", "field": "state_badge", "rel_x": 0.7, "rel_y": 0.5, "font_size": 18, "value_font_size": 30},
        {"type": "notice", "rel_x": 0.05, "rel_y": 0.6, "width": 420},
        {"type": "tank_icon", "rel_x": 0.72, "rel_y": 0.55},
        {"field": "temp", "rel_x": 0.95, "rel_y": 0.92, "font_size": 28, "hide_in_states": ["deco"]},
        {"type": "arc", "rel_x": 0.6, "rel_y": 0.05, "width": 80, "height": 60, "thickness": 30, "start_angle": -90, "sweep": 180},
        {"field": "custom:XX", "rel_x": 0.75, "rel_y": 0.1, "font_size": 20},
        {"field": "", "rel_x": 0.0, "rel_y": 0.0},
        {"field": "max_depth", "id": "under_notice", "rel_x": 0.7, "rel_y": 0.58, "font_size": 20, "hide_when_notice": True},
        {"field": "ppo2", "id": "loop_only", "rel_x": 0.71, "rel_y": 0.6, "font_size": 20, "hide_in_circuits": ["OC"]},
        {"type": "graph", "field": "depth_graph", "rel_x": 0.0, "rel_y": 0.0, "width": 400, "height": 200},
    ]
    skin = {"manufacturer": "Shearwater", "model": "Perdix2",
            "hud_skin": {"type": "shape", "width": 400, "height": 200, "linked_elements": els}}
    round_ = copy.deepcopy(skin)
    round_["hud_skin"]["screen"] = {"x0": 0.1, "y0": 0.05, "x1": 0.9, "y1": 0.95, "shape": "ellipse"}
    square = copy.deepcopy(skin)
    square["hud_skin"]["screen"] = {"x0": 0.05, "y0": 0.05, "x1": 0.95, "y1": 0.95}
    return [("skin", skin, False, "metric"), ("skin_imperial", skin, False, "imperial"), ("round", round_, False, "metric"),
            ("square_ccr", square, True, "metric")]


def main():
    RF.MEASURES.clear()
    RF.METRICS.clear()
    RF.GLYPHS.clear()
    pages = S.bundled_pages()
    reports = {}
    sizes = {}
    for page in pages:
        layout, size = S.load_page(*page)
        key = S._page_key(*page)
        sizes[key] = list(size)
        ccr = S.page_is_ccr(*page[:3])
        for units in U.UNIT_SYSTEMS:
            with U.units_override(units):
                reports[f"{key}@{units}"] = S.sweep_report(layout, size, ccr=ccr)
    synthetic = {}
    for name, layout, ccr, units in synthetic_layouts():
        with U.units_override(units):
            synthetic[name] = {"layout": layout, "ccr": ccr, "units": units,
                               "report": S.sweep_report(copy.deepcopy(layout), (400.0, 200.0), ccr=ccr)}
    commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
    out = {
        "python_commit": commit,
        "unit_systems": list(U.UNIT_SYSTEMS),
        "slack": S.SLACK,
        "pages": [list(p) for p in pages],
        "ccr_pages": [S._page_key(*p) for p in pages if S.page_is_ccr(*p[:3])],
        "sizes": sizes,
        "reports": reports,
        "synthetic": synthetic,
        "known": json.loads(S.KNOWN.read_text()),
        "measures": {f"{name}@{size}": texts for (name, size), texts in sorted(RF.MEASURES.items())},
        "metrics": dict(sorted(RF.METRICS.items())),
        "glyphs": {name: dict(sorted(chars.items())) for name, chars in sorted(RF.GLYPHS.items())},
    }
    json.dump(out, sys.stdout, separators=(",", ":"), ensure_ascii=False, sort_keys=False)
    sys.stdout.write("\n")
    issues = sum(len(r) for r in reports.values())
    print(len(pages), "pages,", len(reports), "reports,", issues, "issue keys,",
          sum(len(v) for v in out["measures"].values()), "measured texts", file=sys.stderr)


if __name__ == "__main__":
    main()
