"""Parity fixture for saving overlay templates (spec §5):
utils/template_store.py's save_template, save_template_as,
create_computer and its queries. Every scenario runs on a copy of the
bundled tree and an empty user tree in a temporary folder that is removed
again (both folder functions of utils.layouts and utils.template_store
point there); the Python repo's own templates are only read.

Paths in the output start with "bundled/" or "user/" in place of the two
roots, and with "/TMP/" for files outside them.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/store_fixture.py \
        | gzip -9n > $APP_REPO/test/fixtures/python_reference/hud_designer/store_cases.json.gz
"""
import contextlib
import hashlib
import io
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

from PIL import Image

sys.path.insert(0, ".")

import utils.layouts as layouts  # noqa: E402
import utils.template_store as store  # noqa: E402
from utils.overlay_document import OverlayDocument, TemplateRef  # noqa: E402

SOURCE = Path("overlays/templates").resolve()
PERDIX = TemplateRef("shearwater", "perdix_2", "main", "single_tank")


class World:
    """One scenario's folders."""

    def __init__(self, tmp, mode):
        self.tmp = tmp
        self.bundled = tmp / "repo" / "overlays" / "templates"
        shutil.copytree(SOURCE, self.bundled)
        self.user = tmp / "user_templates"
        self.user.mkdir()
        self.outside = tmp / "outside"
        self.outside.mkdir()
        self.mode = mode
        for module in (layouts, store):
            module.bundled_templates_dir = lambda: self.bundled
            module.user_templates_dir = lambda: self.user
        os.environ[store.ENV_TARGET] = mode
        self.calls = []
        self.initial = self.files()

    def plain(self, value):
        text = json.dumps(value, default=str)
        for root, name in ((self.bundled, "bundled"), (self.user, "user"), (self.outside, "/TMP")):
            text = text.replace(str(root), name)
        return json.loads(text)

    def files(self):
        out = {}
        for name, root in (("bundled", self.bundled), ("user", self.user), ("/TMP", self.outside)):
            for path in sorted(root.rglob("*")):
                if path.is_file():
                    out[f"{name}/{path.relative_to(root).as_posix()}"] = hashlib.sha1(path.read_bytes()).hexdigest()
        return out

    def load(self, ref):
        return OverlayDocument.load(layouts.resolve_template_state(ref.brand, ref.computer, ref.page, variant=ref.variant), ref=ref)

    def call(self, function, *args, **kwargs):
        """Run one store function and record its arguments, what it
        returned or raised, and the files it wrote."""
        before = self.files()
        by_hash = {}
        for path, digest in before.items():
            by_hash.setdefault(digest, path)
        user_before = {}
        for path in sorted(self.user.rglob("*")):
            if path.is_file():
                rel = "user/" + path.relative_to(self.user).as_posix()
                user_before[rel] = path.read_text() if path.suffix == ".json" else None
        outside = sorted("/TMP/" + p.relative_to(self.outside).as_posix() for p in self.outside.rglob("*") if p.is_file())
        # How the bundled copy differs from the Python app's tree by now:
        # the text of a changed or new JSON file, True for another file,
        # None for one that is gone.
        bundled_changes = {}
        for rel in sorted(set(self.initial) | set(before)):
            if rel.startswith("bundled/") and self.initial.get(rel) != before.get(rel):
                path = self.bundled / rel[len("bundled/"):]
                bundled_changes[rel] = None if rel not in before else path.read_text() if path.suffix == ".json" else True
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                result = ["ok", getattr(store, function)(*args, **kwargs)]
        except store.TemplateStoreError as e:
            result = ["raise", type(e).__name__, str(e)]
        written, skins = {}, {}
        for name, root in (("bundled", self.bundled), ("user", self.user)):
            for path in sorted(root.rglob("*")):
                if not path.is_file():
                    continue
                rel = f"{name}/{path.relative_to(root).as_posix()}"
                digest = hashlib.sha1(path.read_bytes()).hexdigest()
                if before.get(rel) == digest:
                    continue
                if path.suffix == ".json":
                    written[rel] = path.read_text()
                elif digest in by_hash:
                    skins[rel] = ["copy", by_hash[digest]]
                else:
                    with Image.open(path) as img:
                        skins[rel] = ["convert", list(img.size), img.mode]
        self.calls.append(self.plain({
            "function": function, "args": [a.__dict__ if isinstance(a, TemplateRef) else a for a in args], "kwargs": kwargs,
            "user_before": user_before, "bundled_changes": bundled_changes, "outside": outside, "result": result, "written": written, "skins": skins,
        }))
        return result


def scenario(name, mode, run):
    with tempfile.TemporaryDirectory() as tmp_name:
        world = World(Path(tmp_name).resolve(), mode)
        queries = run(world) or []
        return {"name": name, "mode": mode, "calls": world.calls, "queries": world.plain(queries)}


def edited(world, ref=PERDIX):
    doc = world.load(ref)
    doc.elements[0]["rel_x"] = 0.123456789
    doc.elements[0]["align"] = "right"
    return doc


def queries(world):
    refs = [("shearwater", "perdix_2", "main"), ("shearwater", "perdix_2", "nope"), ("nobody", "x", "y"), ("shearwater", "perdix_2", "my_main"),
            ("custom", "gopro", "main")]
    return [[list(r), store.template_origin(*r), store.can_save_in_place(*r)] for r in refs]


def read_only(world):
    world.call("save_template", PERDIX, world.load(PERDIX).render_layout())
    world.call("save_template", TemplateRef("shearwater", "perdix_2", "nope"), world.load(PERDIX).render_layout())
    return queries(world)


def dev_in_place(world):
    world.call("save_template", PERDIX, edited(world).render_layout())
    # a page with variants has no state of its own
    world.call("save_template", TemplateRef("shearwater", "perdix_2", "main"), world.load(PERDIX).render_layout())
    flat = TemplateRef("garmin", "x50i", "gases")
    world.call("save_template", flat, edited(world, flat).render_layout())
    shape = TemplateRef("generic", "depth_temp", "compact")
    world.call("save_template", shape, edited(world, shape).render_layout())
    return queries(world)


def dev_new_skin(world):
    flat = TemplateRef("garmin", "x50i", "gases")
    jpg = world.outside / "photo.jpg"
    Image.new("RGB", (50, 30), (200, 10, 10)).save(jpg)
    doc = world.load(flat)
    doc.set_skin_image(jpg)
    world.call("save_template", flat, doc.render_layout())
    doc = world.load(flat)
    png = world.bundled / "garmin/mk3i/gauge/normal.png"
    world.call("save_template", flat, doc.render_layout(), png)
    world.call("save_template", flat, doc.render_layout(), world.outside / "gone.png")


def save_as_user(world):
    doc = world.load(PERDIX)
    doc.elements[0]["rel_x"] = 0.4
    dst = TemplateRef("shearwater", "perdix_2", "my_main")
    world.call("save_template_as", doc.render_layout(), dst, "My Main")
    q = queries(world)
    # the same id again: allowed (overwrite), then refused
    world.call("save_template_as", doc.render_layout(), dst, "My Main, again")
    world.call("save_template_as", doc.render_layout(), dst, "No", overwrite_user=False)
    # a second page beside it
    flat = world.load(TemplateRef("garmin", "x50i", "gases"))
    world.call("save_template_as", flat.render_layout(), TemplateRef("shearwater", "perdix_2", "second"), "Second one")
    # the user's own page saved in place, and saved as a variant folder
    mine = world.load(dst)
    mine.elements[1]["rel_y"] = 0.987654321
    world.call("save_template", dst, mine.render_layout())
    world.call("save_template_as", mine.render_layout(), TemplateRef("shearwater", "perdix_2", "third", "sidemount"), "Third")
    return q + queries(world)


def save_as_refusals(world):
    layout = world.load(PERDIX).render_layout()
    for ref in (TemplateRef("shearwater", "perdix_2", "main"), TemplateRef("shearwater", "perdix_2", "My Page"),
                TemplateRef("shearwater", "perdix_2", ""), TemplateRef("Shear", "perdix_2", "x"), TemplateRef("a", "b__c", "x"),
                TemplateRef("a", "b", "_x"), TemplateRef("a", "b", "x", "Side Mount"), TemplateRef("a", "b", "x1", "side_mount")):
        world.call("save_template_as", layout, ref, "Name")
    relative = json.loads(json.dumps(layout))
    relative["hud_skin"]["path"] = "normal.png"
    world.call("save_template_as", relative, TemplateRef("a", "b", "rel"), "Relative skin")
    world.call("save_template_as", relative, TemplateRef("a", "b", "rel"), "Relative skin", world.bundled / "garmin/mk3i/gauge/normal.png")
    world.call("save_template_as", layout, TemplateRef("a", "b", "gone"), "Skin gone", world.outside / "gone.png")


def save_as_custom(world):
    doc = world.load(PERDIX)
    world.call("save_template_as", doc.render_layout(), TemplateRef("custom", "gopro_hud", "main"), "Main")
    world.call("save_template_as", doc.render_layout(), TemplateRef("custom", "rig", "main"), "Main", manufacturer="Acme", model="",
               rules_profile="Garmin")
    world.call("save_template_as", doc.render_layout(), TemplateRef("custom", "rig", "two"), "Two", model="Other", rules_profile="Shearwater")
    shape = world.load(TemplateRef("generic", "depth_temp", "standard"))
    world.call("save_template_as", shape.render_layout(), TemplateRef("custom", "shapes", "mine"), "Mine", manufacturer="Custom", model="Shapes")
    variant = world.load(TemplateRef("garmin", "x50i", "main", "sidemount"))
    world.call("save_template_as", variant.render_layout(), TemplateRef("garmin", "x50i", "my_main"), "My Main")
    own_skin = world.load(TemplateRef("shearwater", "perdix_3", "main", "sidemount"))
    world.call("save_template_as", own_skin.render_layout(), TemplateRef("shearwater", "perdix_3", "my_side"), "My side")
    return queries(world)


def dev_save_as(world):
    doc = world.load(PERDIX)
    world.call("save_template_as", doc.render_layout(), TemplateRef("shearwater", "perdix_2", "tec"), "Tec")
    world.call("save_template_as", doc.render_layout(), TemplateRef("shearwater", "perdix_2", "new_page"), "New page")
    world.call("save_template_as", doc.render_layout(), TemplateRef("shearwater", "perdix_2", "new_page"), "Again")
    world.call("save_template_as", doc.render_layout(), TemplateRef("custom", "dev", "main"), "Main")
    return queries(world)


def computers(world):
    world.call("create_computer", "custom", "gopro", "Custom", "GoPro")
    world.call("create_computer", "custom", "gopro", "Custom", "GoPro")
    world.call("create_computer", "custom", "rig", "Acme", "Rig", "Garmin")
    world.call("create_computer", "shearwater", "perdix_2", "Shearwater", "Perdix 2")
    world.call("create_computer", "Custom", "x", "A", "B")
    world.call("create_computer", "custom", "", "A", "B")
    doc = world.load(PERDIX)
    world.call("save_template_as", doc.render_layout(), TemplateRef("custom", "gopro", "main"), "Main")
    return queries(world)


def dev_variants(world):
    ref = TemplateRef("garmin", "x50i", "main", "sidemount")
    doc = world.load(ref)
    next(e for e in doc.elements if e.get("id") == "depth")["rel_y"] = 0.41111
    next(e for e in doc.elements if e.get("id") == "secondary_tank_pressure")["rel_x"] = 0.66666
    doc.elements.append({"field": "custom:NEW", "rel_x": 0.5, "rel_y": 0.5, "color": "#FFFFFF", "font_size": 12, "scale": 1.0})
    doc.remove_element(2)
    world.call("save_template", ref, doc.render_layout())
    ref = TemplateRef("shearwater", "perdix_3", "main", "sidemount")
    doc = world.load(ref)
    next(e for e in doc.elements if e.get("id") == "label_max")["rel_x"] = 0.62
    doc.set_skin_attr("opacity", 0.75)
    world.call("save_template", ref, doc.render_layout())
    # the base gone
    ref = TemplateRef("garmin", "mk3i", "main", "single_tank")
    doc = world.load(ref)
    (world.bundled / "garmin/mk3i/main/normal.json").unlink()
    world.call("save_template", ref, doc.render_layout())


SLUGS = ["GoPro HUD", "  Perdix 2  ", "a__b", "_x_", "Ünïcode Näme", "", None, "already_fine", "A-B.C/D", "123", "__"]

if __name__ == "__main__":
    out = {
        "constants": {"skin": store.SKIN_FILENAME, "state": store.STATE_FILENAME, "manifest": store.MANIFEST_FILENAME,
                      "custom_brand": store.CUSTOM_BRAND, "custom_manufacturer": store.CUSTOM_MANUFACTURER},
        "slugs": [[s, store.slugify(s)] for s in SLUGS],
        "scenarios": [
            scenario("read_only", "user", read_only), scenario("dev_in_place", "repo", dev_in_place),
            scenario("dev_new_skin", "repo", dev_new_skin), scenario("save_as_user", "user", save_as_user),
            scenario("save_as_refusals", "user", save_as_refusals), scenario("save_as_custom", "user", save_as_custom),
            scenario("dev_save_as", "repo", dev_save_as), scenario("computers", "user", computers),
            scenario("dev_variants", "repo", dev_variants),
        ],
    }
    os.environ.pop(store.ENV_TARGET, None)
    json.dump(out, sys.stdout, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    sys.stdout.write("\n")
    print(sum(len(s["calls"]) for s in out["scenarios"]), "calls", file=sys.stderr)
