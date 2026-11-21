"""Parity fixture for the colour engine (spec §6): the analysis of a frame
(`ColorCorrectionEngine.get_filter_matrix` and its six stages), `apply_filter`
on a piece of each frame, the 3D LUT and the `.cube` text of the Python app's
ffmpeg/color.py, for the three bundled profiles and one made up here.

The frames: made-up pictures from a formula the Dart test repeats (so they
cost nothing to store, whatever their size), and the reviewed photo fixture
test/fixtures/media/photo/jpeg_3x2_2mp.jpg decoded here and reduced to
300x200, kept as raw RGB.

Run from the Python repo's root with its own interpreter and write the
output into this repo (nothing is written into the Python repo):

    cd $PYTHON_REPO
    PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B \
        $APP_REPO/tool/python_reference/color_fixture.py \
        $APP_REPO/test/fixtures/media/photo/jpeg_3x2_2mp.jpg \
        $APP_REPO/test/fixtures/python_reference/color
"""
import base64
import gzip
import hashlib
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, ".")

import cv2  # noqa: E402
import numpy as np  # noqa: E402
import yaml  # noqa: E402

import ffmpeg.color as color_module  # noqa: E402
from ffmpeg.color import ColorCorrectionEngine  # noqa: E402

# name: width, height, seed, (red, green, blue) base and (across, down) gain
# per channel, torch (0 or 1)
PICTURES = {
    "deep blue": (1024, 768, 11, (8, 70, 120), ((10, 4), (60, 30), (50, 70)), 1),
    "green water": (800, 600, 23, (30, 110, 70), ((20, 10), (70, 40), (30, 20)), 0),
    "shallow, balanced": (450, 300, 37, (120, 125, 130), ((60, 30), (60, 30), (60, 30)), 1),
    "dark": (640, 480, 41, (2, 12, 20), ((4, 2), (14, 6), (20, 10)), 0),
    "bright": (1001, 667, 53, (170, 200, 215), ((40, 20), (40, 10), (30, 10)), 1),
    "small": (37, 23, 67, (20, 80, 110), ((30, 30), (60, 30), (60, 60)), 0),
    "tall": (300, 1300, 71, (15, 90, 100), ((20, 60), (50, 60), (40, 90)), 1),
}
EXTRA_PROFILE = {
    "cifval": 0.85, "red_threshold": 0.2, "red_scale": 0.3, "blue_threshold": 0.1, "blue_scale": 0.5, "black_point_cutoff": 0.004,
    "gw_mask_mult": 1.2, "gw_mask_fallback": 0.4, "gw_blur_radius": 6, "gw_blur_sigma": 1.2, "gw_isolation_threshold": 0.03,
    "gw_isolation_min_sum": 3000.0, "dehaze_sat_cutoff": 0.2, "dehaze_sat_scale": 0.6, "dehaze_min": 0.5, "dehaze_max": 1.2,
    "exposure_cdf_cutoff": 0.03, "exposure_numerator": 0.6, "exposure_min": 0.8, "exposure_max": 3.0, "bh_min_idx": 120,
    "bh_max_idx": 255, "bh_decay": 0.5, "bh_fallback": 0.6, "sharpness": 1.2, "darkness": 0.15,
}


def picture(width, height, seed, base, gain, torch):
    """A made-up frame: a gradient per channel, noise from a hash of the
    position, and a bright disc. Whole numbers only, so the Dart test makes
    the same bytes."""
    y, x = np.mgrid[0:height, 0:width].astype(np.int64)
    out = np.zeros((height, width, 3), dtype=np.int64)
    disc = ((x - width // 3) ** 2 + (y - height // 2) ** 2) < (min(width, height) // 6) ** 2
    for c in range(3):
        noise = ((x * 73856093) ^ (y * 19349663) ^ ((c + 1) * 83492791) ^ (seed * 2654435761)) % 41 - 20
        value = base[c] + (x * gain[c][0]) // width + (y * gain[c][1]) // height + noise
        if torch:
            value = value + np.where(disc, 70 - 10 * c, 0)
        out[..., c] = np.clip(value, 0, 255)
    return out.astype(np.uint8)


def b64(array):
    return base64.b64encode(np.ascontiguousarray(array).tobytes()).decode("ascii")


def stages(engine, frame):
    h, w, _ = frame.shape
    scale = 1
    while w / scale > 200 and h / scale > 200:
        scale *= 2
    small = cv2.resize(frame, (w // scale, h // scale), interpolation=cv2.INTER_AREA)
    linear = engine.lut_linear[small]
    cf = engine.calculate_color_factors(linear)
    bp = engine.calculate_black_point(linear, cf)
    gw = engine.calculate_grey_world_factors(linear, cf, bp)
    dh = engine.calculate_dehaze_factor(linear, cf, bp, gw)
    ex = engine.calculate_exposure_factor(linear, cf, bp, gw, dh)
    bh = engine.calculate_blue_hue(linear, cf, bp, gw, dh, ex)
    return small, {
        "small_size": [int(small.shape[1]), int(small.shape[0])],
        "small_sha256": hashlib.sha256(small.tobytes()).hexdigest(),
        "cf": [float(v) for v in cf], "bp": [float(v) for v in bp], "gw": [float(v) for v in gw],
        "dehaze": float(dh), "exposure": float(ex), "blue_hue": float(bh),
        "filter": [float(v) for v in engine.get_filter_matrix(frame)],
    }


if __name__ == "__main__":
    photo_path, folder = Path(sys.argv[1]), Path(sys.argv[2])
    profiles = yaml.safe_load(Path("color.yaml").read_text())
    profiles["made up"] = EXTRA_PROFILE
    # The engine reads its profiles from color.yaml files: give it one.
    with tempfile.TemporaryDirectory() as tmp:
        merged = Path(tmp) / "color.yaml"
        merged.write_text(yaml.safe_dump(profiles))
        color_module.load_merged_color_profiles = lambda: yaml.safe_load(merged.read_text())
        engines = {name: ColorCorrectionEngine(None, name) for name in profiles}

    photo = cv2.cvtColor(cv2.imread(str(photo_path), cv2.IMREAD_COLOR), cv2.COLOR_BGR2RGB)
    photo = cv2.resize(photo, (300, 200), interpolation=cv2.INTER_AREA)
    frames = {name: picture(*spec) for name, spec in PICTURES.items()}
    frames["photo"] = photo

    cases = []
    luts = []
    for frame_name, frame in frames.items():
        for profile_name, engine in engines.items():
            small, result = stages(engine, frame)
            filt = engine.get_filter_matrix(frame)
            # apply_filter on the top left of the reduced frame, with the
            # profile's sharpness and without.
            piece = np.ascontiguousarray(small[:48, :64])
            sharp = engine.apply_filter(piece, filt)
            keep, engine.sharpness = engine.sharpness, 0.0
            plain = engine.apply_filter(piece, filt)
            engine.sharpness = keep
            result.update(picture=frame_name, profile=profile_name, piece_size=[int(piece.shape[1]), int(piece.shape[0])],
                          applied=b64(plain), applied_sharpened=b64(sharp) if keep > 0 else None)
            cases.append(result)
            if frame_name in ("deep blue", "photo", "shallow, balanced") and profile_name in ("default", "subtle", "made up"):
                lut = engine.generate_3d_lut(filt)
                levels = np.round(lut * 255.0).astype(np.uint8).reshape(-1, 3)
                whole = frame_name == "photo" and profile_name == "default"
                # One LUT whole, of the others every ninth entry.
                entry = {"picture": frame_name, "profile": profile_name, "every": 1 if whole else 9,
                         "lut": b64(levels if whole else levels[::9])}
                if whole:
                    cube = Path(tempfile.gettempdir()) / "uwmedia_fixture.cube"
                    engine.write_cube_file(lut, cube)
                    text = cube.read_text()
                    cube.unlink()
                    entry.update(cube_sha256=hashlib.sha256(text.encode()).hexdigest(), cube_head=text.splitlines()[:6],
                                 cube_lines=len(text.splitlines()))
                luts.append(entry)

    rng_filters = [cases[i]["filter"] for i in (0, 4, 8, 12)]
    close = [[bool(np.allclose(np.array(a, dtype=np.float32), np.array(b, dtype=np.float32), atol=0.01)) for b in rng_filters] for a in rng_filters]
    nudged = [[v + d for v in rng_filters[0]] for d in (0.0, 0.004, 0.0099, 0.0101, 0.02, -0.0099, -0.0102)]
    close_nudged = [bool(np.allclose(np.array(n, dtype=np.float32), np.array(rng_filters[0], dtype=np.float32), atol=0.01)) for n in nudged]

    data = {
        "profiles": profiles,
        "pictures": {name: list(spec) for name, spec in PICTURES.items()},
        "picture_sha256": {name: hashlib.sha256(frame.tobytes()).hexdigest() for name, frame in frames.items()},
        "photo": {"size": [300, 200], "rgb": b64(photo)},
        "lut_linear": [float(v) for v in engines["default"].lut_linear],
        "lut_srgb_sha256": hashlib.sha256(engines["default"].lut_srgb.astype("<f4").tobytes()).hexdigest(),
        "cases": cases,
        "luts": luts,
        "allclose": {"filters": rng_filters, "close": close, "nudged": nudged, "close_nudged": close_nudged},
    }
    raw = json.dumps(data, separators=(",", ":")).encode()
    with open(folder / "color_cases.json.gz", "wb") as f:
        with gzip.GzipFile(fileobj=f, mode="wb", mtime=0, compresslevel=9) as gz:
            gz.write(raw)
    print(len(cases), "cases,", len(luts), "LUTs,", len(raw), "bytes of JSON", file=sys.stderr)
