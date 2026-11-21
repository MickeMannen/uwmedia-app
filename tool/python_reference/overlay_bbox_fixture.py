"""Parity fixture for the Color page's overlay box (gui/hud_renderer.py
`overlay_pixel_bbox`: where an overlay instance lands on a frame, for the
preview's hit test and handles) and the Add Overlay seed position
(backends/color_backend.py `_resolve_new_color_overlay`: bottom left).

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 QT_QPA_PLATFORM=offscreen .venv/bin/python -B \
        $APP_REPO/tool/python_reference/overlay_bbox_fixture.py \
        > $APP_REPO/test/fixtures/python_reference/pages/overlay_bbox_cases.json
"""
import copy
import json
import sys
from pathlib import Path

import cv2

sys.path.insert(0, ".")

import gui.hud_renderer as R  # noqa: E402

TEMPLATES = Path("overlays/templates")
# Layouts of the bundled tree with an image skin (relative path), and the
# frame sizes the preview and the runs use.
LAYOUTS = [
    "garmin/mk3i/main/normal.json",
    "garmin/mk3i/gauge/normal.json",
]
FRAMES = [(1920, 1080), (1920, 1440), (3840, 2160), (528, 297), (1080, 1920)]
PLACEMENTS = [(0.0, 0.0, 1.0), (0.25, 0.6, 0.5), (-0.3, 1.2, 2.3), (0.123, 0.456, 0.1), (1.5, -0.5, 0.75)]


def slim(layout):
    """The keys the box depends on: the design width and the skin's type,
    size, scale and path."""
    out = {k: v for k, v in layout.items() if k == "design_width"}
    out["hud_skin"] = {k: v for k, v in layout.get("hud_skin", {}).items()
                       if k in ("type", "width", "height", "scale", "path")}
    return out


def skin_size(layout, base):
    path = layout.get("hud_skin", {}).get("path")
    if not path:
        return None
    image = cv2.imread(str(base / path), cv2.IMREAD_UNCHANGED)
    return None if image is None else [image.shape[1], image.shape[0]]


def cases():
    out = []
    variants = []
    for rel in LAYOUTS:
        path = TEMPLATES / rel
        layout = json.loads(path.read_text())
        variants.append((rel, layout, path.parent))
        scaled = copy.deepcopy(layout)
        scaled["hud_skin"]["scale"] = 0.73
        scaled["design_width"] = 1280
        variants.append((rel + " scaled", scaled, path.parent))
    shape = {"design_width": 1920, "hud_skin": {"type": "shape", "width": 420, "height": 180}}
    variants.append(("shape", shape, Path(".")))
    variants.append(("shape default", {"hud_skin": {"type": "shape"}}, Path(".")))
    variants.append(("no skin", {"hud_skin": {"type": "image"}}, Path(".")))
    for name, layout, base in variants:
        size = skin_size(layout, base)
        absolute = copy.deepcopy(layout)
        if absolute.get("hud_skin", {}).get("path"):
            absolute["hud_skin"]["path"] = str((base / absolute["hud_skin"]["path"]).resolve())
        for w, h in FRAMES:
            for x, y, scale in PLACEMENTS:
                out.append({
                    "name": name,
                    "layout": slim(layout),
                    "skin_size": size,
                    "frame": [w, h],
                    "placement": [x, y, scale],
                    "bbox": list(R.overlay_pixel_bbox(absolute, x, y, scale, w, h)),
                })
    return out


def seeds(boxes):
    """The bottom-left seed of a new overlay on a preview frame: the box at
    0,0 and scale 1, then x 0 and y 1 - its height (never below 0)."""
    out = []
    for case in boxes:
        x, y, scale = case["placement"]
        if (x, y, scale) != (0.0, 0.0, 1.0):
            continue
        w, h = case["frame"]
        x0, y0, x1, y1 = case["bbox"]
        seed_h = (y1 - y0) / h if h else 0.0
        out.append({"name": case["name"], "frame": [w, h], "seed": [0.0, max(0.0, 1.0 - seed_h)]})
    return out


boxes = cases()
json.dump({"bbox": boxes, "seeds": seeds(boxes)}, sys.stdout, indent=1)
sys.stdout.write("\n")
