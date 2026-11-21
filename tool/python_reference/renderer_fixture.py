"""Parity fixture for the overlay renderer (spec §5): what gui/hud_renderer.py
of the Python app draws, as a list of drawing operations, for every bundled
template page and variant in the states of the golden images, at moments of
the dummy dives, at other frame sizes and in the telemetry-only mode, and for
a few changed copies of the templates (outlines, turned text, alignments).

Nothing is compared pixel by pixel here. The Pillow and OpenCV calls of the
renderer are recorded with their arguments, and so is every text measurement
(`getbbox`, `getlength`, and since 0.8.1 `getmetrics` and whether a font
has a badge's arrow glyph) it asks of a font; the Dart renderer is run with the
same measurements and must ask for the same drawing. "Arial" is the bundled
Liberation Sans, as in the port (spec §5.6), not this machine's Arial.

Operations (lists, the first item is the kind; colours are [r, g, b]):

    ["skin", x, y, w, h]                      where the skin image goes
    ["clip", x0, y0, x1, y1, shape]           hud_skin.screen, after the pass
    ["blend", opacity, [operations]]          drawn on a copy, mixed in
    ["cv_rrect", x0, y0, x1, y1, colour, thickness, radius]
    ["cv_rect", x0, y0, x1, y1, colour, thickness]
    ["cv_line", x0, y0, x1, y1, colour, thickness]
    ["cv_polyline", [[x, y], ...], colour, thickness]
    ["cv_fill", [[x, y], ...], colour]
    ["cv_circle", x, y, radius, colour, thickness]
    ["text", x, y, text, font file, size, colour, stroke width, stroke colour]
    ["rtext", x, y, text, font file, size, "up" | "down", colour, outline]
    ["rect", x0, y0, x1, y1, fill, outline, width]
    ["rrect", x0, y0, x1, y1, radius, fill, outline, width]
    ["poly", [[x, y], ...], fill, outline, width]
    ["line", [[x, y], ...], colour, width, joint]
    ["ellipse", x0, y0, x1, y1, fill, outline, width]
    ["pie", x0, y0, x1, y1, start, end, fill, outline, width]
    ["arc", x0, y0, x1, y1, start, end, colour, width]

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/renderer_fixture.py \
        $APP_REPO/test/fixtures/python_reference/renderer
"""
import copy
import gzip
import json
import sys
from pathlib import Path

sys.path.insert(0, ".")
sys.path.insert(0, "tests")

import numpy as np  # noqa: E402
from PIL import ImageColor, ImageDraw, ImageFont  # noqa: E402

from utils import fonts  # noqa: E402

# "Arial" is the bundled Liberation Sans, as in the port.
fonts._system_arial_candidates = lambda: {}
fonts.registry.cache_clear()

import gui.hud_renderer as R  # noqa: E402
from test_template_sweep import CCR_MOMENTS, bundled_pages, load_page, page_is_ccr  # noqa: E402
from utils import units as U  # noqa: E402
from utils.dummy_telemetry import build_dummy_dive, forced_dive, waypoint_at  # noqa: E402
import utils.hud_rules_engine as engine  # noqa: E402

STATES = ("normal", "ndl_low", "deco_at_stop", "deco_violation", "clear", "safety_stop", "safety_paused", "fast_ascent", "critical_gas")
IMPERIAL_STATES = ("normal", "deco_at_stop", "critical_gas")
MORE_STATES = ("descent", "deco", "deco_approach", "deco_ceiling_violation", "safety_pending", "safety_done", "high_ppo2", "high_cns", "low_gas", "surfacing")
MOMENTS = (400, 510, 930, 1160, 1280, 1300, 1445, 1575, 1600, 1900)
IMPERIAL_MOMENTS = (930, 1300)


# --- recording --------------------------------------------------------------

class Recorder:
    def __init__(self):
        self.ops = []
        self.depth = 0          # inside a recorded call: its own calls are not ours
        self.frame = None       # the frame being drawn on
        self.copies = []        # (array, operations) of the copies drawn on

    def target(self, img):
        if img is self.frame:
            return self.ops
        for array, ops in self.copies:
            if array is img:
                return ops
        ops = []
        self.copies.append((img, ops))
        return ops

    def blend(self, overlay, opacity):
        for i, (array, ops) in enumerate(self.copies):
            if array is overlay:
                del self.copies[i]
                self.ops.append(["blend", float(opacity), ops])
                return
        self.ops.append(["blend", float(opacity), []])


REC = Recorder()
MEASURES = {}


def colour(value):
    if value is None:
        return None
    if isinstance(value, str):
        return list(ImageColor.getrgb(value)[:3])
    return [int(c) for c in tuple(value)[:3]]


def bgr(value):
    return [int(value[2]), int(value[1]), int(value[0])]


def points(xy):
    flat = list(xy)
    if flat and not isinstance(flat[0], (tuple, list)):
        return [[float(flat[i]), float(flat[i + 1])] for i in range(0, len(flat), 2)]
    return [[float(x), float(y)] for x, y in flat]


def box(xy):
    pts = points(xy)
    return [pts[0][0], pts[0][1], pts[1][0], pts[1][1]]


def font_key(font):
    return Path(font.path).name, int(font.size)


def recorded(method):
    """Wrap an ImageDraw method: `method(rec_args) -> operation`."""
    def decorate(describe):
        original = getattr(ImageDraw.ImageDraw, method)

        def wrapper(self, *args, **kwargs):
            if REC.depth == 0 and REC.frame is not None:
                REC.ops.append(describe(*args, **kwargs))
            REC.depth += 1
            try:
                return original(self, *args, **kwargs)
            finally:
                REC.depth -= 1

        setattr(ImageDraw.ImageDraw, method, wrapper)
        return describe
    return decorate


@recorded("text")
def _text(xy, text, fill=None, font=None, stroke_width=0, stroke_fill=None, **kwargs):
    name, size = font_key(font)
    return ["text", float(xy[0]), float(xy[1]), text, name, size, colour(fill), int(stroke_width), colour(stroke_fill)]


@recorded("rectangle")
def _rectangle(xy, fill=None, outline=None, width=1):
    return ["rect", *box(xy), colour(fill), colour(outline), int(width)]


@recorded("rounded_rectangle")
def _rounded_rectangle(xy, radius=0, fill=None, outline=None, width=1):
    return ["rrect", *box(xy), float(radius), colour(fill), colour(outline), int(width)]


@recorded("polygon")
def _polygon(xy, fill=None, outline=None, width=1):
    return ["poly", points(xy), colour(fill), colour(outline), int(width)]


@recorded("line")
def _line(xy, fill=None, width=0, joint=None):
    return ["line", points(xy), colour(fill), int(width), joint]


@recorded("ellipse")
def _ellipse(xy, fill=None, outline=None, width=1):
    return ["ellipse", *box(xy), colour(fill), colour(outline), int(width)]


@recorded("arc")
def _arc(xy, start, end, fill=None, width=1):
    return ["arc", *box(xy), float(start), float(end), colour(fill), int(width)]


@recorded("pieslice")
def _pieslice(xy, start, end, fill=None, outline=None, width=1):
    return ["pie", *box(xy), float(start), float(end), colour(fill), colour(outline), int(width)]


def _measure(method, slot):
    original = getattr(ImageFont.FreeTypeFont, method)

    def wrapper(self, text, *args, **kwargs):
        result = original(self, text, *args, **kwargs)
        if not args and not kwargs or method == "getlength" or not kwargs.get("stroke_width"):
            entry = MEASURES.setdefault(font_key(self), {}).setdefault(text, [None, None])
            entry[slot] = [int(v) for v in result] if slot == 0 else float(result)
        return result

    setattr(ImageFont.FreeTypeFont, method, wrapper)


_measure("getbbox", 0)
_measure("getlength", 1)

# Since 0.8.1: a badge's small unit sits on the digits' baseline
# (getmetrics), and an arrow the badge font lacks is drawn in Roboto
# (_font_lacks_glyph); both answers are kept for the port's replay.
METRICS = {}
GLYPHS = {}
_getmetrics = ImageFont.FreeTypeFont.getmetrics


def _metrics(self, *args, **kwargs):
    result = _getmetrics(self, *args, **kwargs)
    name, size = font_key(self)
    METRICS[f"{name}@{size}"] = [int(v) for v in result]
    return result


ImageFont.FreeTypeFont.getmetrics = _metrics


class Cv2Proxy:
    """cv2 as the renderer sees it: the drawing calls are recorded."""

    def __init__(self, real):
        self._real = real

    def __getattr__(self, name):
        return getattr(self._real, name)

    def rectangle(self, img, pt1, pt2, color, thickness=1, *args):
        if REC.depth == 0:
            REC.target(img).append(["cv_rect", int(pt1[0]), int(pt1[1]), int(pt2[0]), int(pt2[1]), bgr(color), int(thickness)])
        return self._real.rectangle(img, pt1, pt2, color, thickness, *args)

    def line(self, img, pt1, pt2, color, thickness=1, *args):
        if REC.depth == 0:
            REC.target(img).append(["cv_line", int(pt1[0]), int(pt1[1]), int(pt2[0]), int(pt2[1]), bgr(color), int(thickness)])
        return self._real.line(img, pt1, pt2, color, thickness, *args)

    def polylines(self, img, pts, closed, color, thickness=1, *args):
        if REC.depth == 0:
            REC.target(img).append(["cv_polyline", [[int(x), int(y)] for x, y in pts[0]], bgr(color), int(thickness)])
        # OpenCV refuses a thickness of 0 (a frame under 960 px wide); so
        # would the Python app. Not reached by the cases here.
        return self._real.polylines(img, pts, closed, color, thickness, *args)

    def fillPoly(self, img, pts, color, *args):
        if REC.depth == 0:
            REC.target(img).append(["cv_fill", [[int(x), int(y)] for x, y in pts[0]], bgr(color)])
        return self._real.fillPoly(img, pts, color, *args)

    def circle(self, img, center, radius, color, thickness=1, *args):
        if REC.depth == 0:
            REC.target(img).append(["cv_circle", int(center[0]), int(center[1]), int(radius), bgr(color), int(thickness)])
        return self._real.circle(img, center, radius, color, thickness, *args)

    def addWeighted(self, src1, alpha, src2, beta, gamma, dst=None, *args):
        if REC.depth == 0 and dst is REC.frame:
            REC.blend(src1, alpha)
        return self._real.addWeighted(src1, alpha, src2, beta, gamma, dst, *args)


R.cv2 = Cv2Proxy(R.cv2)

_draw_rounded_rect = R.draw_rounded_rect


def draw_rounded_rect(img, pt1, pt2, color, thickness, r, d):
    REC.target(img).append(["cv_rrect", int(pt1[0]), int(pt1[1]), int(pt2[0]), int(pt2[1]), bgr(color), int(thickness), int(r)])
    REC.depth += 1
    try:
        return _draw_rounded_rect(img, pt1, pt2, color, thickness, r, d)
    finally:
        REC.depth -= 1


R.draw_rounded_rect = draw_rounded_rect

_font_lacks_glyph = R._font_lacks_glyph


def font_lacks_glyph(path, char):
    lacks = bool(_font_lacks_glyph(path, char))
    GLYPHS.setdefault(Path(path).name, {})[char] = lacks
    return lacks


R._font_lacks_glyph = font_lacks_glyph

_draw_oriented_text = R.draw_oriented_text


def draw_oriented_text(pil_img, draw, text, font, orientation, x, y, align, valign, color_rgb, outline, size):
    if orientation == "stacked":
        return _draw_oriented_text(pil_img, draw, text, font, orientation, x, y, align, valign, color_rgb, outline, size)
    # A turned line is drawn on a tile and pasted: one operation, at the
    # tile's corner, with the outline distance (0 without an outline).
    dx, dy, _, _ = R.oriented_text_geometry(font, text, orientation, size, align, valign)
    o_dist = max(1, int(size / 20))
    name, font_size = font_key(font)
    REC.ops.append(["rtext", int(round(x + dx)) - (o_dist + 1), int(round(y + dy)) - (o_dist + 1), text, name, font_size, orientation,
                    colour(color_rgb), o_dist if outline else 0])
    REC.depth += 1
    try:
        return _draw_oriented_text(pil_img, draw, text, font, orientation, x, y, align, valign, color_rgb, outline, size)
    finally:
        REC.depth -= 1


R.draw_oriented_text = draw_oriented_text

_draw_telemetry = R.draw_telemetry_on_frame


def draw_telemetry_on_frame(frame, layout, waypoint, skin_info, waypoints=None):
    REC.ops.append(["skin", skin_info["x"], skin_info["y"], skin_info["w"], skin_info["h"]])
    return _draw_telemetry(frame, layout, waypoint, skin_info, waypoints=waypoints)


R.draw_telemetry_on_frame = draw_telemetry_on_frame

_clip_to_screen = R._clip_to_screen


def clip_to_screen(frame, before, screen, shape):
    REC.ops.append(["clip", *[int(v) for v in screen], shape])
    return _clip_to_screen(frame, before, screen, shape)


R._clip_to_screen = clip_to_screen


def render(layout, wp, history, size=(1920, 1080), render_log=False, units="metric"):
    frame = np.zeros((size[1], size[0], 3), dtype=np.uint8)
    REC.ops, REC.frame, REC.copies, REC.depth = [], frame, [], 0
    engine._timeline_cache.clear()
    with U.units_override(units):
        R.draw_hud(frame, layout, wp, waypoints=history, render_log=render_log)
    REC.frame = None
    return REC.ops


# --- cases --------------------------------------------------------------------

def dump_wp(wp):
    return wp.model_dump(mode="json", exclude_defaults=True)


class Histories:
    """The dives and the forced histories, each stored once."""

    def __init__(self):
        self.dives = {name: build_dummy_dive(variant, ccr=ccr) for name, variant, ccr in
                      (("single_tank", "single_tank", False), ("sidemount", "sidemount", False), ("ccr", "single_tank", True))}
        self.stored = {}
        self.objects = {}

    def forced(self, dive_name, state):
        """(history key or None, waypoint index, waypoint, history)."""
        key = f"{dive_name}/{state}"
        if key not in self.objects:
            wp, history = forced_dive(waypoint_at(self.dives[dive_name], 12 * 60), state)
            self.objects[key] = (wp, history)
            self.stored[key] = {"dive": dive_name, "waypoints": [dump_wp(w) for w in (history or [wp])], "alone": history is None}
        wp, history = self.objects[key]
        return key, (len(history) - 1 if history else 0), wp, history

    def moment(self, dive_name, seconds):
        dive = self.dives[dive_name]
        wp = waypoint_at(dive, seconds)
        return dive_name, dive.waypoints.index(wp), wp, dive.waypoints


def changed(layout, name):
    """A copy of a layout with one thing changed in every element."""
    layout = copy.deepcopy(layout)
    elements = layout["hud_skin"].get("linked_elements", [])
    for i, elem in enumerate(elements):
        is_text = "type" not in elem
        if name == "outline":
            elem["outline"] = True
        elif name == "turned" and is_text:
            elem["orientation"] = ("stacked", "up", "down")[i % 3]
            if i % 2:
                elem["unit_orientation"] = ("up", "down", "stacked")[i % 3]
        elif name == "aligned":
            elem["align"] = ("left", "center", "right")[i % 3]
            elem["valign"] = ("middle", "bottom", "top")[(i // 3) % 3]
            if is_text and i % 4 == 0:
                elem["unit_suffix"] = True
                elem.pop("unit_position", None)
            if is_text and i % 5 == 0:
                elem["max_width"] = 40
        elif name == "scaled":
            elem["scale"] = (0.5, 1.3, 2.0)[i % 3]
            if elem.get("type") == "badge":
                elem["value_align"] = "center"
                elem["title_box"] = i % 2 == 0
            if elem.get("type") == "graph":
                elem["marker_style"] = ("cross", "bold_cross", "dot")[i % 3]
                elem["stop_label"] = True
                elem["reveal_profile"] = not elem.get("reveal_profile")
    return layout


def cases():
    histories = Histories()
    pages = bundled_pages()
    out = []
    skins = {}

    def add(page, layout, situation, key, index, wp, history, **options):
        brand, computer, page_id, variant = page
        ops = render(layout, wp, history, options.get("size", (1920, 1080)), options.get("render_log", False), options.get("units", "metric"))
        out.append({"template": [brand, computer, page_id, variant], "situation": situation, "history": key, "index": index, **options, "ops": ops})

    for page in pages:
        brand, computer, page_id, variant = page
        layout, size = load_page(*page)
        if layout["hud_skin"].get("type", "image") != "shape":
            skins["/".join(p for p in page if p)] = [int(size[0]), int(size[1])]
        ccr = page_is_ccr(brand, computer, page_id)
        base_dive = "ccr" if ccr else "single_tank"
        # The golden images' cases.
        for state in STATES:
            add(page, layout, state, *histories.forced(base_dive, state))
        for state in IMPERIAL_STATES:
            add(page, layout, state, *histories.forced(base_dive, state), units="imperial")
        if ccr:
            for t in CCR_MOMENTS:
                add(page, layout, f"ccr@{t}", *histories.moment("ccr", t))
        # The other forced states, and moments of the dive the page is for.
        for state in MORE_STATES:
            add(page, layout, state, *histories.forced(base_dive, state))
        own_dive = "ccr" if ccr else "sidemount" if variant == "sidemount" else "single_tank"
        for t in MOMENTS:
            add(page, layout, f"dive@{t}", *histories.moment(own_dive, t))
        for t in IMPERIAL_MOMENTS:
            add(page, layout, f"dive@{t}", *histories.moment(own_dive, t), units="imperial")
        # Other frames, the telemetry-only mode, a placed and resized copy.
        for t in (930, 1300):
            add(page, layout, f"dive@{t}", *histories.moment(own_dive, t), size=(3840, 2160))
            add(page, layout, f"dive@{t}", *histories.moment(own_dive, t), size=(1280, 720))
            add(page, layout, f"dive@{t}", *histories.moment(own_dive, t), render_log=True)
        placed = R.resolve_overlay_instance_layout(layout, 0.31, 0.17, 1.7, 2704, 1520)
        add(page, placed, "dive@1300", *histories.moment(own_dive, 1300), size=(2704, 1520), placed=[0.31, 0.17, 1.7])
        for change in ("outline", "turned", "aligned", "scaled"):
            for t in (930, 1300):
                add(page, changed(layout, change), f"dive@{t}", *histories.moment(own_dive, t), changed=change)
            add(page, changed(layout, change), "deco_at_stop", *histories.forced(base_dive, "deco_at_stop"), changed=change, units="imperial")

    dives = {name: dive.model_dump(mode="json", exclude_defaults=True) for name, dive in histories.dives.items()}
    return {"dives": dives, "histories": histories.stored, "skins": skins, "cases": out}


def changed_layouts():
    """The changed copies, for the Dart test to make the same ones."""
    return {"outline": "every element: outline true",
            "turned": "text element i: orientation stacked/up/down by i % 3; odd i: unit_orientation up/down/stacked by i % 3",
            "aligned": "element i: align left/center/right by i % 3, valign middle/bottom/top by (i // 3) % 3; text with i % 4 == 0: "
                       "unit_suffix true and no unit_position; text with i % 5 == 0: max_width 40",
            "scaled": "element i: scale 0.5/1.3/2.0 by i % 3; badge: value_align center, title_box for even i; graph: marker_style "
                      "cross/bold_cross/dot by i % 3, stop_label true, reveal_profile flipped"}


if __name__ == "__main__":
    folder = Path(sys.argv[1])
    data = cases()
    data["changed"] = changed_layouts()
    data["measures"] = {f"{name}@{size}": texts for (name, size), texts in sorted(MEASURES.items())}
    data["metrics"] = dict(sorted(METRICS.items()))
    data["glyphs"] = {name: dict(sorted(chars.items())) for name, chars in sorted(GLYPHS.items())}
    raw = json.dumps(data, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    with open(folder / "renderer_cases.json.gz", "wb") as f:
        with gzip.GzipFile(fileobj=f, mode="wb", mtime=0, compresslevel=9) as gz:
            gz.write(raw)
    print(len(data["cases"]), "cases,", len(raw), "bytes of JSON,", sum(len(v) for v in data["measures"].values()), "measured texts", file=sys.stderr)
