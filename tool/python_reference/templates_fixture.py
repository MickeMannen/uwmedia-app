"""Parity fixture for finding the overlay templates (spec §5):
utils/layouts.py's list_templates, resolve_template_state and
list_layouts, on the Python app's bundled tree alone and with user trees
built in a temporary folder that is removed again. Both folder functions
of utils.layouts are pointed there; the user's real data folder is not
read or written.

Paths in the output start with "bundled/" or "user/" in place of the two
roots.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/templates_fixture.py \
        > $APP_REPO/test/fixtures/python_reference/templates/templates_cases.json
"""
import contextlib
import io
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, ".")

import utils.layouts as layouts  # noqa: E402

BUNDLED = Path("overlays/templates").resolve()
TEC = (BUNDLED / "shearwater/perdix_2/tec/normal.json").read_text()


def manifest(pages, manufacturer="Shearwater", model="Perdix 2", **more):
    return json.dumps({"manufacturer": manufacturer, "model": model, "pages": pages, **more})


# name: the files of a user tree, path -> text
USER_TREES = {
    "none": {},
    "page_beside_bundled": {
        "shearwater/perdix_2/manifest.json": manifest([{"id": "my_main", "name": "My Main"}, {"id": "main", "name": "Clash"}]),
        "shearwater/perdix_2/my_main/normal.json": TEC,
        "shearwater/perdix_2/main/normal.json": TEC,
    },
    "own_brand": {
        "custom/gopro/manifest.json": manifest([{"id": "main", "name": "Main"}], "Custom", "GoPro"),
        "custom/gopro/main/normal.json": TEC,
    },
    "variants_and_states": {
        "custom/rig/manifest.json": manifest(
            [{"id": "main", "name": "Main"}, {"id": "flat"}, {"id": "missing", "name": "No folder"}], "Custom", "Rig",
            rules_profile="Shearwater"),
        "custom/rig/main/normal.json": TEC,
        "custom/rig/main/sidemount/normal.json": TEC,
        "custom/rig/main/single_tank/normal.json": TEC,
        "custom/rig/main/single_tank/deco.json": TEC,
        "custom/rig/main/zebra/normal.json": TEC,
        "custom/rig/main/no_tank/normal.json": TEC,
        "custom/rig/main/Alpha/other.json": TEC,
        "custom/rig/flat/normal.json": TEC,
        "custom/rig/flat/deco.json": TEC,
    },
    "odd_content": {
        "broken/one/manifest.json": "{not json",
        "broken/two/readme.txt": "no manifest here",
        "broken/three/manifest.json": manifest([]),
        "broken/four/manifest.json": json.dumps({"manufacturer": "No pages"}),
        "stray.txt": "a file among the brands",
        "garmin/stray.txt": "a file among the computers",
        "garmin/x50i/manifest.json": manifest([{"id": "mine", "name": "Mine"}, {"id": "mine", "name": "Twice"}], "Garmin", "x50i"),
        "garmin/x50i/mine/normal.json": TEC,
        "Shearwater/perdix_2/manifest.json": manifest([{"id": "upper", "name": "Upper-case brand"}]),
        "Shearwater/perdix_2/upper/normal.json": TEC,
    },
}


def plain(value, roots):
    if isinstance(value, Path):
        for name, root in roots.items():
            if value == root or root in value.parents:
                return (Path(name) / value.relative_to(root)).as_posix()
        raise ValueError(value)
    if isinstance(value, dict):
        return {k: plain(v, roots) for k, v in value.items()}
    if isinstance(value, list):
        return [plain(v, roots) for v in value]
    return value


def tree_case(name, files, tmp):
    user = tmp / name
    user.mkdir()
    for path, text in files.items():
        target = user / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
    layouts.user_templates_dir = lambda: user
    roots = {"bundled": BUNDLED, "user": user}
    printed = io.StringIO()
    with contextlib.redirect_stdout(printed):
        templates = layouts.list_templates()
    resolved = []
    for brand, computers in templates.items():
        for computer, found in computers.items():
            if brand not in ("custom", "generic") and (brand, computer) not in (("shearwater", "perdix_2"), ("garmin", "x50i")):
                continue
            for page in found["pages"]:
                for variant in [None, *page["variants"], "nope"]:
                    for state in ("normal", "deco", "nope"):
                        with contextlib.redirect_stdout(io.StringIO()):
                            path = layouts.resolve_template_state(brand, computer, page["id"], variant, state)
                        resolved.append([brand, computer, page["id"], variant, state, plain(path, roots)])
    with contextlib.redirect_stdout(io.StringIO()):
        resolved.append(["nonexistent_brand", "x", "y", None, "normal",
                         plain(layouts.resolve_template_state("nonexistent_brand", "x", "y"), roots)])
        resolved.append(["shearwater", "nope", "main", None, "normal",
                         plain(layouts.resolve_template_state("shearwater", "nope", "main"), roots)])
        resolved.append(["shearwater", "perdix_2", "no_such_page", None, "normal",
                         plain(layouts.resolve_template_state("shearwater", "perdix_2", "no_such_page"), roots)])
    return {"name": name, "user_files": files, "templates": plain(templates, roots),
            "warnings": printed.getvalue().splitlines(), "resolved": resolved}


def layout_cases(tmp):
    """list_layouts for the bundled overlays folder and user folders with
    these file names."""
    out = []
    for i, names in enumerate([[], ["mine.json", "Garmin_x50_simple.zip", "notes.txt", "UPPER.ZIP", "a.b.json", "sub/inner.json"],
                               ["zz.json", "Aa.zip", "aa.json", "generic_depth_temp.json"]]):
        user = tmp / f"layouts{i}"
        user.mkdir()
        for name in names:
            (user / name).parent.mkdir(parents=True, exist_ok=True)
            (user / name).write_text("{}")
        layouts.user_layouts_dir = lambda: user
        roots = {"bundled": Path("overlays").resolve(), "user": user}
        out.append({"user_files": names, "layouts": [[name, plain(path, roots)] for name, path in layouts.list_layouts()]})
    return out


if __name__ == "__main__":
    layouts.bundled_templates_dir = lambda: BUNDLED
    with tempfile.TemporaryDirectory() as tmp_name:
        tmp = Path(tmp_name).resolve()
        out = {
            "trees": [tree_case(name, files, tmp) for name, files in USER_TREES.items()],
            "bundled_layouts": sorted(p.name for p in Path("overlays").iterdir() if p.is_file()),
            "layouts": layout_cases(tmp),
        }
    json.dump(out, sys.stdout, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    sys.stdout.write("\n")
