"""Parity fixture for the canvas of a telemetry-only render (spec §2):
cli_main.py's overlay_canvas (--overlay-size, --overlay-full-frame) and
ffmpeg/overlay_output.py's small helpers. No image is read: cv2.imread is
replaced by a table of sizes per path.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/overlay_canvas_fixture.py \
        > $APP_REPO/test/fixtures/python_reference/engine/overlay_canvas_cases.json
"""
import json
import sys
from types import SimpleNamespace

sys.path.insert(0, ".")

import numpy as np  # noqa: E402

import cli_main as C  # noqa: E402
from ffmpeg import overlay_output as O  # noqa: E402

SIZES = {"watch.png": (692, 922), "wide.png": (1001, 333), "tiny.png": (1, 1), "odd.png": (641, 361)}


def fake_imread(path, *_args):
    size = SIZES.get(str(path))
    return None if size is None else np.zeros((size[1], size[0], 4), dtype=np.uint8)


C.cv2.imread = fake_imread

LAYOUTS = {
    "image": {"hud_skin": {"type": "image", "path": "watch.png", "scale": 0.5, "anchor": "BOTTOM_LEFT", "ref_offset_x": 16.0,
                           "ref_offset_y": -16.0, "linked_elements": [{"field": "depth", "rel_x": 0.5, "rel_y": 0.5}]}},
    "image_no_scale": {"hud_skin": {"path": "wide.png"}},
    "image_odd": {"hud_skin": {"path": "odd.png", "scale": 1.0}},
    "image_tiny": {"hud_skin": {"path": "tiny.png", "scale": 0.3}},
    "image_missing": {"hud_skin": {"type": "image", "path": "gone.png", "scale": 2.0}},
    "image_no_path": {"hud_skin": {"type": "image"}},
    "shape": {"hud_skin": {"type": "shape", "width": 401, "height": 199.5, "scale": 1.5}},
    "shape_defaults": {"hud_skin": {"type": "shape"}},
    "no_skin": {"design_width": 1280},
    "own_design": {"design_width": 2560, "design_height": 1441, "hud_skin": {"type": "shape", "width": 300, "height": 100}},
}
OPTIONS = [(size, full) for size in (None, "1080p", "4k", "4K", "8k") for full in (False, True)]

if __name__ == "__main__":
    cases = []
    for name, layout in LAYOUTS.items():
        for size, full in OPTIONS:
            original = json.loads(json.dumps(layout))
            width, height, render_log, out = C.overlay_canvas(layout, SimpleNamespace(overlay_size=size, overlay_full_frame=full))
            assert layout == original  # the caller's layout is left alone
            path = (layout.get("hud_skin") or {}).get("path")
            cases.append({"name": name, "layout": layout, "size": size, "full_frame": full,
                          "skin_size": list(SIZES[path]) if path in SIZES else None,
                          "width": width, "height": height, "render_log": render_log, "out": out})
    out = {
        "sizes": C.OVERLAY_SIZES,
        "formats": list(O.FORMATS), "default_format": O.DEFAULT_FORMAT,
        "has_alpha": {f: O.has_alpha(f) for f in O.FORMATS},
        "even": [[v, C._even(v)] for v in (0, 0.4, 1, 1.5, 2, 2.5, 3, 3.5, 4.49, 346.0, 345.5, 346.5, 1921)],
        "cases": cases,
    }
    json.dump(out, sys.stdout, indent=1, ensure_ascii=False)
    sys.stdout.write("\n")
