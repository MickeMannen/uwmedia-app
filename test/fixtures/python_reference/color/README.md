# Colour engine reference

Output of the Python app's `ffmpeg/color.py` (`ColorCorrectionEngine`).
Needs the Python repo and its venv at `$PYTHON_REPO`.

| File | Python commit | Made | Command |
|---|---|---|---|
| `color_cases.json.gz` | `0fdefd8` (0.7.20), NumPy 2.5.4, OpenCV 5.0.0 | 2026-11-13 | see the docstring of `tool/python_reference/color_fixture.py` |

Gzip-compressed JSON (2.8 MB unpacked):

- `profiles`: the three profiles of the Python app's `color.yaml`
  (`assets/color.yaml` here is a copy of that file) and one made up for
  the fixture that moves every parameter.
- `pictures`: seven made-up frames as the parameters of a formula (the
  generator's `picture()`; the Dart test builds the same bytes and checks
  them against `picture_sha256`), from 37x23 to 1024x768, one of a size
  that does not divide evenly when reduced. `photo`: the reviewed photo
  fixture `test/fixtures/media/photo/jpeg_3x2_2mp.jpg`, decoded by OpenCV
  and reduced to 300x200, as raw RGB.
- `cases` (32, every frame with every profile): the size and SHA-256 of
  the reduced frame, the six stages of the analysis as 64-bit numbers, the
  filter (eleven 32-bit numbers), and `apply_filter` on the top left 64x48
  of the reduced frame without sharpening (`applied`) and with the
  profile's (`applied_sharpened`).
- `luts` (9): `generate_3d_lut` as bytes, one whole (`every` 1, with the
  head, the line count and the SHA-256 of its `.cube` text), of the others
  every ninth entry.
- `lut_linear`, `lut_srgb_sha256`: the engine's sRGB tables.
- `allclose`: which filters `np.allclose(a, b, atol=0.01)` takes as the
  same (the rule that decides how many LUTs a clip gets).

`color_params_cases.json` (`tool/python_reference/color_params_fixture.py`,
Python `0fdefd8`, 2026-11-13): the Color Tuning page's slider table
(`utils/color_params.py` `PARAM_GROUPS`), its slider scale and name limit,
and the value text beside a slider for 21 values.
