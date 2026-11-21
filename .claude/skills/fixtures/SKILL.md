---
name: fixtures
model: sonnet
description: Generate or refresh the parity fixtures the Dart port is tested against, using the Python UWMedia app as the oracle (parsed dives, date/timezone results, colour filter vectors and LUTs, HUD renders), and bring reviewed media fixtures over under the repo's data rules. Use when a ported module has no fixture yet or the Python reference changed.
---

# Parity fixtures from the Python app

The oracle is the Python repo, `~/development/uwmedia`, run
with its own interpreter: `~/development/uwmedia/.venv/bin/python`.
Run it from that repo's root (it imports by path) but write every output
into **this** repo or the scratchpad. Nothing is written into the Python
repo, ever.

Destination: `test/fixtures/python_reference/<area>/`, one JSON (or PNG)
per case, named for what it is (`garmin_synthetic_oc.json`,
`get_filter_matrix_jpeg_3x2_2mp.json`, `hud_perdix2_standard_deco_t0600.png`).
Each area has a `README.md` row per file: Python commit (`git -C
~/development/uwmedia rev-parse --short HEAD`), the command
that made it, the input, and the date.

## What goes in git, what does not

- **Dive logs never.** FIT, UDDF, SSRF, Shearwater XML/CSV carry serial
  numbers and personal IDs. A parsed-dive fixture is made from a
  **synthetic** log written by the Python writers
  (`tests/conftest.py` `write_synthetic_log()` / the `synthetic_logs`
  fixture; `parsers/fit_writer.py`, `uddf_writer.py`,
  `subsurface_writer.py`) into the scratchpad. The parsed JSON is kept, and so
  is the synthetic log itself, as base64 inside the fixture JSON, so the
  Dart test parses exactly what Python parsed (owner, 2026-11-12: a log
  made by the app's writers from an invented plan, or written by hand
  with invented values, has no serial or personal data and may be
  committed that way; never as a loose log file, and never a real log). Results from the owner's real logs in `test_data/` go to a
  `requires_media` test that reads `UWMEDIA_TEST_DATA` and skips without
  it; their fixture JSON may be committed only if it holds no serials,
  device IDs, GPS or names (check every field).
- **Media only after the owner's review.** The three reviewed files from
  the Python repo's `tests/fixtures/media/` are already in
  `test/fixtures/media/` with their rows (copied 2026-10-17; the owner
  approved copying the Python repo's test content). Any new or rebuilt
  media file: prepare it in the scratchpad, list size, content and
  metadata, and wait for an OK per file.
- Fonts, template JSON and skin PNGs from `overlays/templates/` and
  `resources/fonts/` are source data and can be copied (keep the
  licences in `resources/licenses/`).

## Recipes (write a small script in the scratchpad; print JSON to stdout)

- **Parsed dives**: for each synthetic log, parse with the matching parser
  and dump every `Waypoint` field (pydantic `model_dump(mode="json")`),
  `Dive` metadata and `get_waypoint_at()` for a few timestamps.
- **Deco**: `utils/deco_engine.py` on the profiles in
  `tests/deco_reference/` (those references are already clean).
- **Dates**: `metadata/exif.py` `get_local_creation_date` and
  `get_timezone_offset` for every media fixture.
- **Colour**: `ffmpeg/color.py` `get_filter_matrix` for each media
  fixture frame (and the first/last frame of the videos), per profile in
  `color.yaml`; the `.cube` of one filter; `apply_filter` on a small
  pixel grid for a per-pixel check.
- **Rules**: `resolve_state` / `stop_phase` per waypoint over a synthetic
  dive, per brand.
- **HUD renders**: the Python repo's `tests/test_template_golden.py`
  output (every template in nine states, halved crop) is already in
  `test/fixtures/python_reference/overlay_golden/`. Never regenerate them
  yourself: `pytest tests/test_template_golden.py -m golden --update-golden`
  writes into the Python repo, so the owner runs it and reviews the diff
  there. To refresh, check that the Python tree is clean (`git -C
  ~/development/uwmedia status --short tests/fixtures/overlay_golden`),
  then mirror the folder here (PNGs added, changed and removed) and update
  the commit and count in its README. For other timestamps or the
  render_log mode, call `gui/hud_renderer.py` `draw_hud` directly. These
  depend on fonts; note the machine and the font files used.
- **Filenames**: `utils/filename_formats.py` cases from its tests.

Keep the generator script in `tool/python_reference/` in this repo so a
refresh is one command, and note in the README that it needs the Python
repo and its venv at the paths above.
