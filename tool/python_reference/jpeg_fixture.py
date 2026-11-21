"""Parity fixture for the JPEG writer (spec §7, the photo path): what
Pillow writes for `img.save(path, qtables=..., subsampling=...,
optimize=True)` and `quality=100`, the two calls of cli_main.py's photo
saves, and what it reads from a source JPEG (`img.quantization`,
`JpegImagePlugin.get_sampling`).

The pictures are computed here (ramps, noise, flat colour, a few sizes
that are not whole blocks); no photo is read. Each case holds the RGB
bytes, the tables and the file Pillow wrote, as base64.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/jpeg_fixture.py \
        | gzip -9n > $APP_REPO/test/fixtures/python_reference/image/jpeg_cases.json.gz
"""
import base64
import io
import json
import sys

import numpy as np
import PIL
from PIL import Image, JpegImagePlugin, features


def picture(kind, w, h, seed=1):
    rng = np.random.default_rng(seed)
    ys, xs = np.mgrid[0:h, 0:w]
    if kind == "ramp":
        a = np.stack([xs * 255 // max(1, w - 1), ys * 255 // max(1, h - 1), (xs + ys) * 255 // max(1, w + h - 2)], axis=2)
    elif kind == "noise":
        a = rng.integers(0, 256, size=(h, w, 3))
    elif kind == "flat":
        a = np.full((h, w, 3), (12, 200, 97))
    elif kind == "edges":
        a = np.where(((xs // 3 + ys // 5) % 2)[..., None] == 0, (255, 255, 255), (0, 0, 0)) + rng.integers(-3, 4, size=(h, w, 3))
    else:  # water: a blue-green scene with soft detail
        base = np.stack([40 + 30 * np.sin(xs / 7.0), 120 + 60 * np.cos(ys / 9.0), 170 + 50 * np.sin((xs + ys) / 11.0)], axis=2)
        a = base + rng.normal(0, 6, size=(h, w, 3))
    return np.clip(a, 0, 255).astype(np.uint8)


def tables_of(quality):
    f = io.BytesIO()
    Image.fromarray(picture("ramp", 16, 16)).save(f, "JPEG", quality=quality)
    return Image.open(io.BytesIO(f.getvalue())).quantization


Q75, Q95, Q30, Q5 = tables_of(75), tables_of(95), tables_of(30), tables_of(5)
CASES = [
    # name, kind, width, height, tables (None = quality 100), subsampling
    ("ramp_16", "ramp", 16, 16, Q75, 2), ("ramp_16_444", "ramp", 16, 16, Q75, 0), ("ramp_16_422", "ramp", 16, 16, Q75, 1),
    ("ramp_default", "ramp", 16, 16, Q75, -1), ("one_pixel", "noise", 1, 1, Q95, 2), ("one_pixel_444", "noise", 1, 1, Q95, 0),
    ("odd_420", "water", 37, 29, Q95, 2), ("odd_422", "water", 37, 29, Q95, 1), ("odd_444", "water", 37, 29, Q95, 0),
    ("even_rows_420", "water", 22, 18, Q75, 2), ("wide_420", "water", 65, 7, Q75, 2), ("tall_422", "water", 7, 65, Q75, 1),
    ("nine_420", "noise", 9, 9, Q75, 2), ("seventeen_420", "edges", 17, 17, Q30, 2), ("thirtythree_422", "edges", 33, 17, Q30, 1),
    ("noise_420", "noise", 64, 48, Q95, 2), ("noise_444", "noise", 64, 48, Q95, 0), ("noise_coarse", "noise", 48, 40, Q5, 2),
    ("flat", "flat", 40, 24, Q75, 2), ("edges_444", "edges", 48, 32, Q30, 0),
    ("quality_100_default", "water", 50, 34, None, -1), ("quality_100_444", "noise", 24, 24, None, 0),
    ("quality_100_422", "water", 31, 33, None, 1),
    ("one_table", "water", 40, 30, {0: Q75[0]}, 2), ("three_tables", "water", 40, 30, {0: Q95[0], 1: Q75[1], 2: Q30[1]}, 0),
    ("four_tables", "water", 24, 24, {0: Q95[0], 1: Q75[1], 2: Q30[1], 3: Q5[1]}, 2), ("gap_in_ids", "water", 24, 24, {0: Q75[0], 2: Q75[1]}, 2),
    ("zero_step", "water", 24, 24, {0: [0] * 64, 1: Q75[1]}, 2), ("photo_like", "water", 160, 106, Q95, 2),
    ("photo_like_422", "water", 151, 100, Q95, 1),
]


def as_lists(q):
    if q is None:
        return None
    return [list(t) for t in q] if isinstance(q, list) else {str(k): list(v) for k, v in q.items()}


def case(name, kind, w, h, q, subsampling):
    rgb = picture(kind, w, h, seed=len(name))
    f = io.BytesIO()
    if q is not None:
        Image.fromarray(rgb).save(f, "JPEG", qtables=q, subsampling=subsampling, optimize=True)
    else:
        Image.fromarray(rgb).save(f, "JPEG", quality=100, subsampling=subsampling, optimize=True)
    data = f.getvalue()
    back = Image.open(io.BytesIO(data))
    return {"name": name, "width": w, "height": h, "rgb": base64.b64encode(rgb.tobytes()).decode("ascii"),
            "qtables": as_lists(q), "subsampling": subsampling, "jpeg": base64.b64encode(data).decode("ascii"),
            "read_sampling": JpegImagePlugin.get_sampling(back), "read_quantization": as_lists(back.quantization)}


def other_sources():
    """What get_sampling and quantization say of files that are not plain
    three-component JPEGs."""
    out = []
    img = Image.fromarray(picture("water", 24, 16))
    for name, make in (("grey", lambda f: img.convert("L").save(f, "JPEG", quality=80)),
                       ("cmyk", lambda f: img.convert("CMYK").save(f, "JPEG", quality=80)),
                       ("progressive", lambda f: img.save(f, "JPEG", quality=80, progressive=True, subsampling=1)),
                       ("411", lambda f: img.save(f, "JPEG", quality=80, subsampling="4:1:1"))):
        f = io.BytesIO()
        make(f)
        back = Image.open(io.BytesIO(f.getvalue()))
        out.append({"name": name, "jpeg": base64.b64encode(f.getvalue()).decode("ascii"),
                    "read_sampling": JpegImagePlugin.get_sampling(back), "read_quantization": as_lists(back.quantization)})
    return out


if __name__ == "__main__":
    out = {"pillow": PIL.__version__, "libjpeg": features.version("jpg"), "turbo": features.check_feature("libjpeg_turbo"),
           "cases": [case(*c) for c in CASES], "sources": other_sources()}
    json.dump(out, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
