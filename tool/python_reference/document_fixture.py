"""Parity fixture for the Overlay Designer's document (spec §5):
utils/overlay_document.py's OverlayDocument on every bundled template
page (what it reads and gives back) and through a long run of edits, undo
and redo on six of them. Nothing is saved: the document only reads.

Paths in the output start with "ROOT" in place of the Python app's
overlays/templates folder.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/document_fixture.py \
        | gzip -9n > $APP_REPO/test/fixtures/python_reference/hud_designer/document_cases.json.gz
"""
import contextlib
import io
import json
import sys
from pathlib import Path

sys.path.insert(0, ".")

from utils.overlay_document import REL_DECIMALS, REL_MAX, REL_MIN, UNDO_LIMIT, OverlayDocument, TemplateRef  # noqa: E402

ROOT = Path("overlays/templates").resolve()


def plain(value):
    """JSON with the templates folder written as ROOT."""
    return json.loads(json.dumps(value, default=str).replace(str(ROOT), "ROOT"))


def facts(doc):
    return plain({
        "layout": doc.to_layout(), "dirty": doc.dirty, "can_undo": doc.can_undo, "can_redo": doc.can_redo,
        "skin_abs_path": doc.skin_abs_path, "native": [doc.native_width, doc.native_height], "skin_type": doc.skin_type,
        "native_size": list(doc.skin_native_size()), "scaled_size": list(doc.skin_scaled_size()),
        "position_px": [list(doc.element_position_px(i)) for i in (0, 1, 99)],
        "frame_box": [list(doc.frame_box(w, h)) for w, h in ((1920, 1080), (3840, 2160), (1280, 720), (1080, 1920))],
    })


def static_cases():
    out = []
    for path in sorted(ROOT.rglob("*.json")):
        if path.name == "manifest.json":
            continue
        doc = OverlayDocument.load(path)
        out.append(plain({
            "path": path, **facts(doc),
            "variant_base_path": doc.variant_base_path, "manufacturer": doc.manufacturer, "model": doc.model,
            "rules_manufacturer": doc.rules_manufacturer, "design_size": list(doc.design_size),
            "render_layout": doc.render_layout(), "design_view": [doc.design_view_layout(z) for z in (1.0, 0.5, 2.25)],
            "for_save": doc.to_layout(for_save=True),
        }))
    return out


OTHER_SKIN = ROOT / "garmin/x50i/gases/normal.png"
OPS = [
    ["add_element", ["depth"], {}],
    ["add_element", ["depth_graph", "graph", 0.1, 0.2], {}],
    ["add_element", ["state_badge", "badge", 2.0, -3.0], {"font_size": 22, "extra": {"a": [1]}}],
    ["add_element", ["x", "tissue_bar"], {}],
    ["add_element", ["notice", "notice", 0.123456789, 0.987654321], {}],
    ["move_element", [0, 0.25, 0.75], {}],
    ["move_element", [0, 9, -9], {"record_undo": False}],
    ["move_element", [999, 0.1, 0.1], {}],
    ["set_element_position_px", [1, 10.5, 20.25], {}],
    ["set_element_position_px", [1, 3, 4], {"record_undo": False}],
    ["nudge_element", [1, 1, -1], {}],
    ["nudge_element", [999, 1, 1], {}],
    ["set_element_attr", [0, "font_size", 44], {}],
    ["set_element_attr", [0, "font_size", 44], {}],
    ["set_element_attr", [0, "font_size", 44.0], {}],
    ["set_element_attr", [0, "align", "right"], {}],
    ["set_element_attr", [0, "align", None], {}],
    ["set_element_attr", [0, "align", None], {}],
    ["set_element_attr", [0, "field", None], {}],
    ["set_element_attr", [0, "rel_x", None], {}],
    ["set_element_attr", [0, "type", "badge"], {}],
    ["set_element_attr", [0, "rel_x", 7], {}],
    ["set_element_attr", [0, "rel_y", -0.25], {}],
    ["set_element_attr", [0, "field", "depth_graph"], {}],
    ["set_element_attr", [0, "field", "ndl"], {}],
    ["set_element_attr", [0, "field", "state_badge"], {}],
    ["set_element_attr", [0, "field", "tts"], {}],
    ["set_element_attr", [0, "colors", {"a": [1, 2]}], {}],
    ["set_element_attr", [0, "colors", {"a": [1, 2.0]}], {}],
    ["set_element_attr", [999, "x", 1], {}],
    ["duplicate_element", [0], {}],
    ["duplicate_element", [999], {}],
    ["reorder_element", [0, 2], {}],
    ["reorder_element", [0, -5], {}],
    ["reorder_element", [1, 0], {}],
    ["reorder_element", [1, 99], {}],
    ["reorder_element", [999, 1], {}],
    ["remove_element", [1], {}],
    ["remove_element", [999], {}],
    ["set_skin_attr", ["anchor", "CENTER"], {}],
    ["set_skin_attr", ["anchor", "NOPE"], {}],
    ["set_skin_attr", ["type", "shape"], {}],
    ["set_skin_attr", ["path", "x.png"], {}],
    ["set_skin_attr", ["linked_elements", []], {}],
    ["set_skin_attr", ["scale", 0.8], {}],
    ["set_skin_attr", ["scale", 0.8], {}],
    ["set_skin_attr", ["opacity", 0.5], {}],
    ["set_skin_attr", ["ref_offset_x", 12], {}],
    ["set_frame_position", [100, 200, 1920, 1080], {}],
    ["set_frame_position", [50.4, 60.6, 3840, 2160], {"record_undo": False}],
    ["set_skin_attr", ["anchor", "BOTTOM_RIGHT"], {}],
    ["set_frame_position", [1000, 700, 1920, 1080], {}],
    ["set_skin_attr", ["anchor", "MIDDLE_LEFT"], {}],
    ["set_frame_position", [-20, 333.3, 1280, 720], {}],
    ["undo", [], {}], ["undo", [], {}], ["undo", [], {}],
    ["redo", [], {}], ["redo", [], {}],
    ["undo", [], {}],
    ["add_element", ["cns", "text", 0.3, 0.3], {"color": "#FF0000"}],
    ["redo", [], {}],
    ["mark_saved", [], {}],
    ["undo", [], {}],
    ["redo", [], {}],
    ["set_skin_image", [OTHER_SKIN], {}],
    ["set_skin_image", [ROOT / "no_such_skin.png"], {}],
    ["undo", [], {}],
    ["redo", [], {}],
    ["mark_saved", [], {}],
    ["set_skin_attr", ["scale", 1.25], {}],
    ["undo", [], {}],
]
EDITED = ["garmin/mk3i/main/single_tank/normal.json", "garmin/x50i/gases/normal.json", "generic/depth_temp/compact/normal.json",
          "generic/dive_profile/main/normal.json", "shearwater/perdix_2/main/sidemount/normal.json",
          "shearwater/teric/main/normal.json"]


def edit_cases():
    out = []
    for name in EDITED:
        doc = OverlayDocument.load(ROOT / name, TemplateRef("b", "c", "p"))
        steps = []
        for op, args, kwargs in OPS:
            with contextlib.redirect_stdout(io.StringIO()):
                result = getattr(doc, op)(*args, **kwargs)
            steps.append({"op": plain([op, args, kwargs]), "result": result, **facts(doc), "for_save": plain(doc.to_layout(for_save=True))})
        out.append({"path": "ROOT/" + name, "start": facts(doc.load(ROOT / name)), "steps": steps})
    return out


if __name__ == "__main__":
    out = {
        "undo_limit": UNDO_LIMIT, "rel_decimals": REL_DECIMALS, "rel_min": REL_MIN, "rel_max": REL_MAX,
        "labels": [[args, TemplateRef(*args).label] for args in (["b", "c", "p"], ["b", "c", "p", "v"], ["b", "c", "p", ""], ["b", "c", "p", None])],
        "static": static_cases(),
        "edits": edit_cases(),
    }
    json.dump(out, sys.stdout, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    sys.stdout.write("\n")
    print(len(out["static"]), "documents,", sum(len(e["steps"]) for e in out["edits"]), "edit steps", file=sys.stderr)
