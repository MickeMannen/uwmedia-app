# Renderer reference

What the Python app's `gui/hud_renderer.py` draws, as lists of drawing
operations, with the dives they were drawn for and every text measurement
Pillow gave on the way. Needs the Python repo and its venv at
`$PYTHON_REPO`.

| File | Python commit | Made | Command |
|---|---|---|---|
| `renderer_cases.json.gz` | `7e62799` (0.8.2) | 2026-11-15 | see the docstring of `tool/python_reference/renderer_fixture.py`, run in a clean `git archive 7e62799` of the Python repo in place of its root (about 13 minutes) |
| `font_measures.json` | `0fdefd8` (0.7.20), Pillow 13.0.0, FreeType 2.14.3, Raqm 0.11.0 | 2026-11-13 | see the docstring of `tool/python_reference/font_ink_tables.py` (it also writes `assets/fonts/ink_tables.bin`) |

It is gzip-compressed JSON (17.6 MB unpacked); `test/helpers/renderer_reference.dart`
reads it.

- `cases` (6160): per bundled page and variant (115), the nine states and
  three imperial states of the golden images, the five rebreather moments
  of the CC pages, ten more forced states, ten moments of the dummy dive
  the page is for (single tank, sidemount or rebreather; two also in
  imperial), two moments on a 3840x2160 and a 1280x720 frame and in the
  telemetry-only mode, one placed and resized copy on a 2704x1520 frame,
  and four changed copies of the layout (`changed`: outlines, turned text,
  alignments, scales) at two moments and one imperial state. Each has
  `template` [brand, computer, page, variant], `situation`, `history` and
  `index` (which waypoint of which dive or forced history), the options,
  and `ops`.
- `ops`: the recorded Pillow and OpenCV calls; the kinds are listed in the
  generator's docstring and are what `HudOp.toJson()` gives in
  `lib/core/hud/hud_ops.dart`.
- `dives`: the three dummy dives of `utils/dummy_telemetry.py` (invented
  data). `histories`: the short forced histories, each on one of them.
- `skins`: the pixel size of each page's skin image.
- `measures`: per font file and size, per text, Pillow's `getbbox` and
  `getlength` (either may be missing: only what the renderer asked for is
  kept). "Arial" was the bundled Liberation Sans for this run, as in the
  port, not the Mac's Arial of the golden images. 7264 texts at 0.8.0,
  13613 at `d3ecc09`, 13349 at `7e62799`.
  Since 0.8.0 the recorder also takes Pillow's `arc` (the arc gauge):
  `["arc", x0, y0, x1, y1, start, end, colour, width]`.
- `metrics` (since `d3ecc09`): Pillow's `getmetrics()` per
  `<file>@<size>` the renderer asked for (a badge's small units sit on
  the ascent); `glyphs`: per font file and character, whether
  `_font_lacks_glyph` found it missing (Roboto Condensed lacks ↑ and ↓).

The templates themselves are not in the fixture: the test loads them from
`assets/overlays/templates/` with the port's own loader, so a template
that changes in the Python app must be copied here before the fixture is
made again.

`font_measures.json`: Pillow's `getbbox` and `getlength` of 73 texts
(`texts`) in each of the twelve bundled font files at seventeen sizes
(`sizes`), keyed `<file>@<size>` under `measures` like the renderer
fixture's. `test/core/hud/ttf_font_test.dart` holds the port's own font
reader to both.

`assets/fonts/ink_tables.bin` is made by the same script and is an asset of
the app, not a fixture: how far each character's ink reaches above and
below the baseline per font and size once FreeType has hinted it. It has
to be made again when a font file changes or when the Python app's Pillow
(its FreeType) does; the script stops if Pillow's ascent is not the one
the port computes.
