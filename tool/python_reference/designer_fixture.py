"""Parity fixture for the Overlay Designer's geometry (spec §5):
utils/hud_designer.py on every bundled template page and on changed copies
of them (the renderer fixture's "turned", "aligned" and "scaled"), with
Pillow's text measurements so that the port can be held to the same
numbers. "Arial" is the bundled Liberation Sans, as in the port.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/designer_fixture.py \
        | gzip -9n > $APP_REPO/test/fixtures/python_reference/hud_designer/designer_cases.json.gz
"""
import copy
import json
import sys
from pathlib import Path

sys.path.insert(0, ".")
sys.path.insert(0, "tests")
sys.path.insert(0, str(Path(__file__).resolve().parent))

import renderer_fixture as RF  # noqa: E402  (pins the fonts, records the measurements)

import gui.hud_renderer as R  # noqa: E402
from test_template_sweep import bundled_pages, load_page, page_is_ccr  # noqa: E402
from utils import hud_designer as D  # noqa: E402
from utils import units as U  # noqa: E402
from utils.dummy_telemetry import build_dummy_dive, forced_dive, waypoint_at  # noqa: E402
from utils.hud_rules_engine import rule_overrides  # noqa: E402


def anchor_cases():
    out = []
    for anchor in [*D.ANCHORS, "nonsense", "MIDDLE_CENTER"]:
        for ref in ((10.0, 20.0), (-5.5, 0.0)):
            out.append([anchor, *ref, 1920, 1080, 400.0, 200.5, list(D.resolve_anchor_position(anchor, *ref, 1920, 1080, 400.0, 200.5))])
    skins = [{"anchor": "BOTTOM_RIGHT", "ref_offset_x": -5.0, "ref_offset_y": -7.0}, {"ref_offset_x": 3, "ref_offset_y": 4},
             {"ref_offset_x": 3, "x_pct": 0.25, "y_pct": 0.5}, {}, {"anchor": "CENTER", "ref_offset_x": 0, "ref_offset_y": 0},
             {"x_pct": 0.1}, {"ref_offset_x": None, "ref_offset_y": 2, "y_pct": 0.3}]
    sizes = [{"type": "shape"}, {"type": "shape", "width": 50, "height": 60}, {"native_width": 100, "native_height": 40, "scale": 1.5},
             {"native_width": None, "native_height": None}, {"native_width": 640, "native_height": 480}, {"type": "image", "width": 5}]
    return {
        "anchors": out,
        "skin_positions": [[s, list(D.resolve_skin_position(s, 400.0, 200.0, 1920, 1080))] for s in skins],
        "skin_sizes": [[s, list(D.skin_pixel_size(s))] for s in sizes],
    }


def element_cases():
    kinds = [{"field": "depth"}, {"field": "depth_graph"}, {"field": "x", "type": "graph"}, {"type": "unknown"}, {"type": "text"},
             *[{"field": "f", "type": k} for k in D.ELEMENT_KINDS], {}]
    parse = [
        {"linked_elements": [{"type": k, "rel_x": 0, "rel_y": 0} for k in D.ELEMENT_KINDS] + [{"rel_x": 0.3, "rel_y": 0.4}]},
        {"linked_elements": [
            {"field": "depth", "rel_x": 0.1, "rel_y": 0.2, "align": "right", "font_family": "Roboto", "outline": False},
            {"field": "state_badge", "type": "badge", "rel_x": 0.3, "rel_y": 0.4, "font_size": 20, "value_font_size": 44},
            {"field": "depth_graph", "rel_x": 0.0, "rel_y": 0.0, "ceiling_color": "#123456"},
            {"field": "", "type": "notice", "rel_x": 0.0, "rel_y": 0.0, "width": 7},
            {"field": None, "type": "tank_icon", "rel_x": 1, "rel_y": 1, "extra": {"kept": [1, 2]}}]},
        {}, {"linked_elements": []},
    ]
    names = ["custom:Hello", "tank_pressure:T1", "tank_name:Deco", "depth_graph", "state_badge", "time_of_day", "depth", "",
             "custom:custom:x", "tank_pressure:"]
    return {
        "kinds": [[e, D.element_kind(e)] for e in kinds],
        "defaults": [[k, f, D.element_defaults(k, f)] for k in [*D.ELEMENT_KINDS, "other"] for f in ("depth", "depth_graph")],
        "parse": [[skin, D.parse_layout_elements(skin)] for skin in parse],
        "names": [[n, D.element_display_name(n)] for n in names],
        "fields": D.available_telemetry_fields(),
        "fields_single": D.available_telemetry_fields(build_dummy_dive("single_tank")),
        "fields_sidemount": D.available_telemetry_fields(build_dummy_dive("sidemount")),
        "fields_ccr": D.available_telemetry_fields(build_dummy_dive("single_tank", ccr=True)),
        "anchors": D.ANCHORS, "marker_styles": D.MARKER_STYLES, "element_kinds": list(D.ELEMENT_KINDS),
    }


def plain_lines(lines):
    return None if lines is None else [[text, None if color is None else [int(c) for c in color], bool(is_value)]
                                       for text, color, is_value in lines]


def page_bounds(layout, size, wp, history):
    """What the designer backend's _native_bounds_for gives: per element
    the text or badge lines it measured and the box; None for an element
    Python fails on."""
    native_w, native_h = size
    elements = D.parse_layout_elements(layout["hud_skin"])
    manufacturer = layout.get("rules_profile") or layout.get("manufacturer", "Shearwater")
    out = []
    with rule_overrides(layout.get("rules")):
        for elem in elements:
            kind = D.element_kind(elem)
            text = lines = None
            if wp is not None:
                if kind == "text":
                    text, raw = R.resolve_element_text(layout, elem.get("field", ""), wp, history)
                    text = str(R.apply_value_format(elem, text, raw)) if text not in (None, "") else None
                elif kind == "badge":
                    lines = R.badge_lines(manufacturer, layout.get("model", "Perdix2"), elem, wp, history)
            try:
                bounds = [float(v) for v in D.element_native_bounds(elem, native_w, native_h, text=text, badge_lines=lines)]
            except Exception as e:  # noqa: BLE001
                bounds = "raise " + type(e).__name__
            box = [float(v) for v in D.measure_element_box(elem, layout["hud_skin"], text)]
            out.append({"text": text, "lines": plain_lines(lines), "bounds": bounds, "box": box})
    return out


ALIGN_MODES = ("h_top", "h_bottom", "h_center", "v_left", "v_right", "v_center", "nonsense")


def aligned(layout, indices, mode):
    elements = D.parse_layout_elements(copy.deepcopy(layout["hud_skin"]))
    D.align_elements(elements, indices, layout["hud_skin"], mode)
    return [[e["rel_x"], e["rel_y"]] for e in elements]


def page_cases():
    dives = {False: build_dummy_dive("single_tank"), True: build_dummy_dive("single_tank", ccr=True)}
    out = []
    for n, page in enumerate(bundled_pages()):
        layout, size = load_page(*page)
        # the fixture's layouts carry the skin's file name, not this machine's path
        if layout["hud_skin"].get("path"):
            layout["hud_skin"]["path"] = Path(layout["hud_skin"]["path"]).name
        dive = dives[page_is_ccr(*page[:3])]
        base = waypoint_at(dive, 12 * 60)
        situations = {"none": (None, None), "dive@1230": (waypoint_at(dive, 1230), dive.waypoints),
                      "critical_gas": forced_dive(base, "critical_gas"), "safety_stop": forced_dive(base, "safety_stop")}
        variants = {"": layout}
        if n % 3 == 0:
            variants.update({change: RF.changed(layout, change) for change in ("turned", "aligned", "scaled")})
        for change, changed in variants.items():
            case = {"page": list(page), "changed": change, "size": list(size), "layout": changed if change else None,
                    "elements": D.parse_layout_elements(changed["hud_skin"]), "bounds": {}}
            for name, (wp, history) in situations.items():
                for units in (("metric", "imperial") if name == "dive@1230" and n % 2 == 0 else ("metric",)):
                    with U.units_override(units):
                        case["bounds"][f"{name} {units}"] = page_bounds(changed, size, wp, history)
            count = len(case["elements"])
            if not change:
                with U.units_override("metric"):
                    case["align"] = [[indices, mode, aligned(changed, indices, mode)]
                                     for indices in ([0, 1, 2][:count], list(range(count)), [count - 1, 0], [0])
                                     for mode in ALIGN_MODES]
            out.append(case)
    return out


def odd_cases():
    """Elements a bundled page does not have."""
    elements = [
        {"field": "depth", "rel_x": 0.5, "rel_y": 0.5, "font_size": 60, "scale": 1.0},
        {"field": "depth", "rel_x": 0.5, "rel_y": 0.5, "font_size": 60, "align": "right", "valign": "bottom"},
        {"field": "depth", "rel_x": 0.5, "rel_y": 0.5, "font_size": 60, "scale": 2.0, "align": "center", "valign": "middle"},
        {"field": "ndl", "rel_x": 0.2, "rel_y": 0.2, "font_size": 40, "align": "center"},
        {"field": "ndl", "rel_x": 0.2, "rel_y": 0.2, "font_size": 40, "align": "right", "small_suffix_dx": 3},
        {"field": "depth", "rel_x": 0.1, "rel_y": 0.1, "font_size": 50, "small_suffix": "decimals", "align": "right"},
        {"field": "depth", "rel_x": 0.1, "rel_y": 0.1, "font_size": 50, "unit_suffix": True},
        {"field": "depth", "rel_x": 0.1, "rel_y": 0.1, "font_size": 50, "unit_suffix": True, "unit_orientation": "stacked", "unit_scale": 0.5},
        {"field": "primary_tank_pressure", "rel_x": 0.1, "rel_y": 0.1, "font_size": 50, "unit_suffix": True, "unit_position": "below",
         "max_width": 60},
        {"field": "depth", "rel_x": 0.3, "rel_y": 0.3, "font_size": 30, "orientation": "stacked"},
        {"field": "depth", "rel_x": 0.3, "rel_y": 0.3, "font_size": 30, "orientation": "up", "align": "center", "valign": "middle"},
        {"field": "depth", "rel_x": 0.3, "rel_y": 0.3, "font_size": 30, "orientation": "down", "font_family": "Roboto",
         "font_weight": "bold"},
        {"field": "custom:Hello there", "rel_x": 0.0, "rel_y": 0.0, "font_size": 0.4},
        {"field": "", "rel_x": 0.0, "rel_y": 0.0},
        {"type": "badge", "style": "box", "rel_x": 0.0, "rel_y": 0.0},
        {"type": "badge", "style": "box", "rel_x": 0.0, "rel_y": 0.0, "width": 10, "height": 5},
        {"type": "badge", "field": "state_badge", "rel_x": 0.5, "rel_y": 0.5, "font_size": 16, "value_font_size": 32},
        {"type": "badge", "field": "state_badge", "rel_x": 0.5, "rel_y": 0.5, "font_size": 16, "value_font_size": 32, "valign": "middle",
         "align": "right"},
        {"type": "badge", "field": "state_badge", "rel_x": 0.5, "rel_y": 0.5, "font_size": 20, "valign": "bottom", "align": "center",
         "scale": 1.5},
        {"type": "tank_icon", "rel_x": 0.0, "rel_y": 0.0, "width": 19, "height": 34},
        {"type": "tank_icon", "rel_x": 0.2, "rel_y": 0.2, "draw_outline": True},
        {"type": "tank_icon", "rel_x": 0.2, "rel_y": 0.2, "draw_outline": True, "outline_gap": 5, "outline_width": 3},
        {"type": "tank_icon", "rel_x": 0.2, "rel_y": 0.2, "style": "segments"},
        {"type": "tank_icon", "rel_x": 0.2, "rel_y": 0.2, "style": "segments", "segments": 7, "segment_gap": 4, "width": 9, "height": 31},
        {"type": "tissue_bar", "rel_x": 0.4, "rel_y": 0.4}, {"type": "tissue_bar", "rel_x": 0.4, "rel_y": 0.4, "width": 1, "marker_size": 9},
        {"type": "ascent_chevrons", "rel_x": 0.4, "rel_y": 0.4}, {"type": "ascent_chevrons", "rel_x": 0.4, "rel_y": 0.4, "width": 30.6},
        {"type": "tank_switch_arrows", "rel_x": 0.4, "rel_y": 0.4}, {"type": "tank_switch_arrows", "rel_x": 0.4, "rel_y": 0.4, "count": 4},
        {"type": "notice", "rel_x": 0.1, "rel_y": 0.1}, {"type": "notice", "rel_x": 0.1, "rel_y": 0.1, "style": "banner"},
        {"type": "notice", "rel_x": 0.1, "rel_y": 0.1, "style": "frame", "height": 90, "width": 300},
        {"type": "notice", "rel_x": 0.1, "rel_y": 0.1, "scale": 0.5, "font_size": 30, "caption_font_size": 12},
        {"type": "graph", "rel_x": 0.1, "rel_y": 0.5, "width": 300, "height": 150}, {"field": "depth_graph", "rel_x": 0.1, "rel_y": 0.5},
        {"type": "arc", "rel_x": 0.5, "rel_y": 0.5}, {"type": "arc", "rel_x": 0.2, "rel_y": 0.1, "start_angle": 0, "sweep": 360},
        {"type": "arc", "rel_x": 0.2, "rel_y": 0.1, "width": 80, "height": 60, "thickness": 30, "start_angle": -90, "sweep": 180},
        {"type": "arc", "rel_x": 0.1, "rel_y": 0.1, "width": 10, "height": 10, "thickness": 20, "start_angle": 200, "sweep": -90},
        {"type": "segment_bar", "rel_x": 0.3, "rel_y": 0.3},
        {"type": "segment_bar", "rel_x": 0.3, "rel_y": 0.3, "orientation": "horizontal", "width": 100.5, "height": 10, "segments": 3},
    ]
    lines = [None, [("DECO", (255, 0, 0), False), ("↑6", (255, 0, 0), True), ("03:00", (255, 0, 0), True)],
             [("STOP", None, False), ("3:00", None, True)], [("", None, False)], []]
    texts = [None, "24.0", "99+", "1", "123.4", "", "Wg"]
    out = []
    skins = [{"type": "shape"}, {"type": "image", "scale": 0.5}, {}]
    for elem in elements:
        kind = D.element_kind(elem)
        for units in ("metric", "imperial"):
            with U.units_override(units):
                for text in (texts if kind == "text" else [None]):
                    for badge in (lines if kind == "badge" else [None]):
                        try:
                            bounds = [float(v) for v in D.element_native_bounds(elem, 400, 200, text=text, badge_lines=badge)]
                        except Exception as e:  # noqa: BLE001
                            bounds = "raise " + type(e).__name__
                        boxes = []
                        for skin in skins:
                            try:
                                boxes.append([float(v) for v in D.measure_element_box(elem, skin, text)])
                            except Exception as e:  # noqa: BLE001
                                boxes.append("raise " + type(e).__name__)
                        out.append({"elem": elem, "units": units, "text": text, "lines": plain_lines(badge), "bounds": bounds,
                                    "boxes": boxes})
    return out


def hit_cases():
    bounds = [(0, 0, 100, 100), (50, 50, 150, 150), (-10.5, 20, -5, 30)]
    points = [(75, 75), (10, 10), (151, 151), (160, 160), (152, 152), (152.1, 100), (-12.5, 25), (-12.6, 25), (102, 49.9), (48, 48)]
    return {"bounds": [list(b) for b in bounds],
            "hits": [[x, y, slack, D.hit_test_bounds(x, y, bounds, slack)] for x, y in points for slack in (2.0, 0, 10)]
            + [[10, 10, 2.0, D.hit_test_bounds(10, 10, [])]]}


if __name__ == "__main__":
    RF.MEASURES.clear()
    RF.GLYPHS.clear()
    with U.units_override("metric"):
        out = {"geometry": anchor_cases(), "elements": element_cases(), "hit": hit_cases(), "skins": [{"type": "shape"}, {"type": "image", "scale": 0.5}, {}]}
    out["pages"] = page_cases()
    out["odd"] = odd_cases()
    out["measures"] = {f"{name}@{size}": texts for (name, size), texts in sorted(RF.MEASURES.items())}
    out["glyphs"] = {name: dict(sorted(chars.items())) for name, chars in sorted(RF.GLYPHS.items())}
    json.dump(out, sys.stdout, separators=(",", ":"), ensure_ascii=False)
    sys.stdout.write("\n")
    print(len(out["pages"]), "page cases,", len(out["odd"]), "odd cases,", sum(len(v) for v in out["measures"].values()),
          "measured texts", file=sys.stderr)
