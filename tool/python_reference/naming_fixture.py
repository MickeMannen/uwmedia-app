"""Parity fixture for the file names the app writes and the camera clock
offset (spec §2, §7): utils/clock_offset.py, utils/filename_formats.py,
utils/convert_naming.py, ffmpeg/overlay_output.output_path_for and
cli_main.py's output_filename, get_unique_path and resolve_target_path.

The files get_unique_path and resolve_target_path look at are made in a
temporary folder that is removed again. Whether that folder's file system
tells "A.jpg" from "a.jpg" is recorded, since the answers depend on it.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/naming_fixture.py \
        > $APP_REPO/test/fixtures/python_reference/naming/naming_cases.json
"""
import contextlib
import io
import json
import math
import sys
import tempfile
from argparse import Namespace
from datetime import datetime
from pathlib import Path

sys.path.insert(0, ".")

import cli_main  # noqa: E402
from cli_main import output_filename, resolve_target_path, get_unique_path  # noqa: E402
from ffmpeg.overlay_output import FORMATS, output_path_for  # noqa: E402
from utils.clock_offset import format_offset, parse_dive_time  # noqa: E402
from utils.convert_naming import CONVERT_RESOLUTIONS, convert_output_filename  # noqa: E402
from utils.filename_formats import EXAMPLE_DATETIME, example_filename, pattern_error  # noqa: E402
from uwmedia.backends.color_backend import FILENAME_FORMAT_PRESETS, LEGACY_PRESET_LABELS  # noqa: E402


def quiet(fn, *a, **kw):
    with contextlib.redirect_stdout(io.StringIO()):
        return fn(*a, **kw)


def plain(value):
    return value if value is None or math.isfinite(value) else str(value)


def clock_cases():
    offsets = [0, 0.4, 0.5, -0.5, 1.5, 2.5, -1.5, 1, -1, 37, -37, 59, 59.5, 60, 61, 119.5, 125, -125, 3599, 3599.5, 3600,
               -3600, 3601, 3660, 3661, 7214, -7214, 86399, 86400, 90061, -90061, 360000, 1e7, 0.49999, -0.49999]
    texts = ["12:34", "1:02:03", "12.34", "754", "12m34s", " 0:05 ", "12:70", "abc", "", "   ", "0", "0:00", "00:00:00",
             "1:60:00", "1:59:59", "99:59", "100:00", "1:2:3:4", ":", "12:", ":34", "1::3", "12.3", "12.345", "12.60",
             "12.59", "1.2.3", ".34", "12.", "-5", "+5", "1e3", "inf", "nan", "1_000", "5.5", "12M34S", "1H", "1h2m3s",
             "1h3s", "2m", "45s", "m", "s", "h", "ms", "1m2", "3s2m", "1 h 2 m 3 s", "12 : 34", "1h 70m", "90s", "1.5m",
             "12:34s", "0x10", "١٢:٣٤", "12,34", "1:02:60", "001:002:003", "\t12:34\n", "1h2", "12:3a", "007", "7."]
    return {
        "format_offset": [[v, format_offset(v)] for v in offsets],
        # inf and nan as text: JSON has no such numbers
        "parse_dive_time": [[t, plain(parse_dive_time(t))] for t in texts],
    }


DATES = [
    datetime(2026, 9, 5, 14, 30, 0), datetime(2026, 9, 5, 4, 3, 7, 123456), datetime(2026, 1, 1, 0, 0, 0),
    datetime(2026, 12, 31, 23, 59, 59, 999999), datetime(2024, 2, 29, 12, 0, 0, 1000), datetime(2021, 1, 3, 12, 5, 9),
    datetime(2020, 12, 28, 11, 0, 0), datetime(2019, 12, 30, 0, 30, 0), datetime(2023, 1, 1, 13, 0, 0),
    datetime(2018, 12, 31, 12, 0, 0), datetime(2016, 1, 3, 1, 0, 0), datetime(1999, 7, 4, 12, 0, 0, 500),
    datetime(1970, 1, 1, 0, 0, 0), datetime(905, 3, 9, 9, 9, 9), datetime(2000, 10, 10, 10, 10, 10, 10),
]
CODES = "aAbBcCdDeFgGhHIjklmMnprRStTuUVwWxXyYzZ%f"
NUMERIC = "CdegGHIjklmMSuUVwWyY"
PATTERNS = (["%" + c for c in CODES] + ["%-" + c for c in NUMERIC] + [
    "%Y%m%d_%H%M%S", "%Y%m%d_%H%M%S_Bali", "%Y-%m-%d", "%Y%m%d_%H%M%S_{hud}", "{filename}_color", "100%%", "%%Y", "",
    "plain", "åäö %B é", "%Y%%%m", "%Ey", "%Od", "%EY%Om", "%H.%M.%S,%f", "%j-%U-%W-%V-%G-%g-%u-%w",
])


def strftime_cases():
    return {
        "dates": [d.isoformat() for d in DATES],
        "patterns": [[p, [d.strftime(p) for d in DATES]] for p in PATTERNS],
    }


def pattern_cases():
    patterns = ["%Y%m%d_%H%M%S_Bali", "%Y-%m-%d", "", "   ", "dive/%Y", "dive\\%Y", "no_codes_here", "%Y", "%%", "{filename}",
                "{filename}_%H", "%S", " %d ", "%Y%m%d_%H%M%S_{hud}", "%p", "%z", "%Z", "%n", "100%%", "%f", "%a %b"]
    return {
        "example_datetime": EXAMPLE_DATETIME.isoformat(),
        "presets": [list(p) for p in FILENAME_FORMAT_PRESETS],
        "legacy_labels": LEGACY_PRESET_LABELS,
        "patterns": [[p, pattern_error(p), example_filename(p)] for p in patterns],
    }


def args_of(source_is_dir, **overrides):
    args = dict(
        render_video_log=False, original_layout_stem=None, render_log_filename_format="{filename}_{hud}",
        filename_format=None, keep_filename=False, color="default", layout=None, no_overwrite=False, overwrite=False,
        overlay_instances=None, overlay_format="hevc",
    )
    args.update(overrides)
    return args


def output_filename_cases(tmp):
    """Every case: the source path, the output folder, whether the run's
    source is a folder, the arguments that differ from args_of(), the date
    taken, the forced name, and the name Python gives."""
    batch = tmp / "raw"
    batch.mkdir()
    taken = [datetime(2026, 9, 5, 14, 30, 0, 123456), datetime(2026, 9, 5, 14, 30, 0), datetime(2026, 9, 5, 14, 30, 0, 999),
             datetime(2026, 9, 5, 14, 30, 0, 7000)]
    overlays = [{"layout_path": "/tmp/x/garmin_mk3i_main.json"}, {"layout_path": "/tmp/x/shearwater_perdix.json"}]
    arg_sets = [
        {}, {"keep_filename": True}, {"filename_format": "%Y%m%d_Bali"}, {"filename_format": "{filename}_color"},
        {"filename_format": "%Y%m%d_{filename}"}, {"filename_format": "%Y%m%d_%H%M%S_{hud}"},
        {"filename_format": "%Y%m%d_%H%M%S_{hud}", "overlay_instances": overlays},
        {"filename_format": "%Y%m%d_%H%M%S_{hud}", "original_layout_stem": "my_hud"},
        {"filename_format": "%Y%m%d_%H%M%S_{hud}", "original_layout_stem": "my_hud", "overlay_instances": overlays},
        {"filename_format": "{hud}_%H%M"}, {"filename_format": "%H%M-{hud}-x {hud}"}, {"filename_format": "{hud}"},
        {"filename_format": "%H%M {hud}", "overlay_instances": [{"layout_path": "packs/my.layout.json"}]},
        {"filename_format": "%Y_{filename}_{hud}", "original_layout_stem": "{filename}"},
        {"filename_format": "%Y%m%d_%H%M%S_color"}, {"filename_format": ""}, {"filename_format": "%f_%j"},
        {"filename_format": "fixed"}, {"filename_format": "%Y.%m"},
        {"render_video_log": True}, {"render_video_log": True, "original_layout_stem": "my_hud"},
        {"render_video_log": True, "original_layout_stem": "my_hud", "overlay_format": "prores"},
        {"render_video_log": True, "original_layout_stem": "my_hud", "overlay_format": "png"},
        {"render_video_log": True, "original_layout_stem": "my_hud",
         "render_log_filename_format": "{datetaken:%Y%m%d_%H%M%S}_{hud}"},
        {"render_video_log": True, "render_log_filename_format": "{datetaken}"},
        {"render_video_log": True, "render_log_filename_format": "{{{filename}}}_{hud}{hud}", "overlay_format": "png"},
        {"render_video_log": True, "render_log_filename_format": "{nope}", "original_layout_stem": "h"},
        {"render_video_log": True, "render_log_filename_format": "{filename", "original_layout_stem": "h"},
        {"render_video_log": True, "render_log_filename_format": "plain.name", "overlay_format": "prores"},
        {"render_video_log": True, "render_log_filename_format": "{filename}_{hud}", "keep_filename": True,
         "filename_format": "%Y"},
    ]
    sources = ["DSC06641.JPG", "C0012.MP4", "clip.final.MoV", "noext", "photo.ARW", "über tauchgang.m4v", ".hidden",
               "trailing."]
    cases = []
    for name in sources:
        source = batch / name
        for overrides in arg_sets:
            for source_is_dir, out_dir, forced in [(True, tmp / "out", None), (False, batch, None),
                                                   (False, tmp / "out", None), (False, tmp / "out", "Forced Name.JPG"),
                                                   (False, batch, "sub/forced.tar.GZ")]:
                for date in (taken if not overrides else taken[:2]):
                    args = Namespace(source=batch if source_is_dir else source, **args_of(source_is_dir, **overrides))
                    got = quiet(output_filename, source, out_dir, args, date, forced)
                    cases.append({
                        "source": "raw/" + name, "output_dir": str(out_dir.relative_to(tmp)), "source_is_dir": source_is_dir,
                        "args": overrides, "taken": date.isoformat(), "forced": forced, "want": got,
                    })
    return cases


def path_cases():
    paths = ["/out/DSC06641_my_hud.mp4", "clip.MOV", "a/b.c/noext", "a/b.c/two.dots.jpg", "C0012", "x.tar.gz"]
    convert = ["Dive 4K.MP4", "Dive.MP4", "dive_4k_final.mov", "Dive 2160P 4k.mp4", "4k.mp4", "Dive-4K.mp4", "a 1080p.MKV",
               "Reef_720p_480p.mp4", "Dive 4Kx.mp4", "noext 360p", "Dive  4K.mp4"]
    return {
        "output_path_for": [[fmt, p, is_video, str(output_path_for(fmt, Path(p), is_video))]
                            for fmt in FORMATS for p in paths for is_video in (True, False)],
        "convert_resolutions": [list(r) for r in CONVERT_RESOLUTIONS],
        "convert_output_filename": [[p, res, convert_output_filename(Path("/media") / p, res)]
                                    for p in convert for res in ("1080p", "360p")],
    }


def unique_cases(tmp):
    """Runs of get_unique_path: the files that exist, the calls in order
    (path, lower_suffix) and what each returned. The reserved names carry
    over between the calls of one run, as in one run of the CLI."""
    runs = [
        ([], [("a.jpg", True), ("a.jpg", True), ("A.JPG", True), ("a.jpg", True), ("A.JPG", False), ("A.JPG", False)]),
        (["a.jpg", "a_1.jpg"], [("a.jpg", True), ("a.JPG", True), ("a_1.jpg", True)]),
        (["A.JPG"], [("a.jpg", True), ("A.JPG", False), ("b.JPG", False), ("b.jpg", True)]),
        (["clip", "clip_1", "two.dots.mp4"], [("clip", True), ("two.dots.MP4", True), ("two.dots.mp4", True), ("CLIP", True)]),
        (["a_1.jpg"], [("a.jpg", True), ("a.jpg", True), ("a.jpg", True)]),
    ]
    out = []
    for i, (existing, calls) in enumerate(runs):
        folder = tmp / f"unique{i}"
        folder.mkdir()
        for name in existing:
            (folder / name).write_bytes(b"x")
        cli_main._reserved_paths.clear()
        got = [[name, lower, get_unique_path(folder / name, lower).name] for name, lower in calls]
        out.append({"existing": existing, "calls": got})
    cli_main._reserved_paths.clear()
    return out


def resolve_cases(tmp):
    """resolve_target_path once per case, each a run of its own: the files
    that exist in the folder, the source and the target (names in it), the
    arguments, and the (name, skipped) it returned."""
    flag_sets = []
    for names_output in ({"color": "default"}, {"color": None}, {"color": None, "layout": "x.json"},
                         {"color": None, "overlay_instances": [{"layout_path": "x.json"}]},
                         {"color": None, "render_video_log": True}):
        for no_overwrite in (False, True):
            for overwrite in (False, True):
                flag_sets.append({**names_output, "no_overwrite": no_overwrite, "overwrite": overwrite})
    layouts = [
        (["DSC1.JPG"], "DSC1.JPG", "DSC1.jpg"), (["DSC1.JPG"], "DSC1.JPG", "DSC1.JPG"), (["DSC1.JPG"], "DSC1.JPG", "out.jpg"),
        (["DSC1.JPG", "out.jpg"], "DSC1.JPG", "out.jpg"), (["DSC1.JPG", "out.jpg"], "DSC1.JPG", "OUT.JPG"),
        (["DSC1.JPG", "DSC1_1.jpg"], "DSC1.JPG", "DSC1.JPG"),
    ]
    out = []
    n = 0
    for existing, source, target in layouts:
        for flags in flag_sets:
            folder = tmp / f"resolve{n}"
            n += 1
            folder.mkdir()
            for name in existing:
                (folder / name).write_bytes(b"x")
            cli_main._reserved_paths.clear()
            args = Namespace(source=folder, **args_of(True, **flags))
            path, skipped = quiet(resolve_target_path, folder / target, folder / source, args)
            out.append({"existing": existing, "source": source, "target": target, "args": flags,
                        "want": [path.name, skipped]})
    cli_main._reserved_paths.clear()
    return out


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as tmp_name:
        tmp = Path(tmp_name).resolve()
        (tmp / "Case.txt").write_bytes(b"x")
        out = {
            "case_insensitive_files": (tmp / "case.TXT").exists(),
            "clock": clock_cases(),
            "strftime": strftime_cases(),
            "patterns": pattern_cases(),
            "output_filename": output_filename_cases(tmp),
            "paths": path_cases(),
            "unique": unique_cases(tmp),
            "resolve": resolve_cases(tmp),
        }
    json.dump(out, sys.stdout, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    sys.stdout.write("\n")
