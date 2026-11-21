# Python reference fixtures

Output of the Python app, never edited by hand and never derived from the
Dart code. Each folder has a README that says which Python commit made the
files and how. In those commands and in `tool/python_reference/`,
`$PYTHON_REPO` is a clone of the Python app
(https://github.com/MickeMannen/UWMedia) with its venv in `.venv`, and
`$APP_REPO` is this repo.

**Frozen since 2026-11-19** (owner): the Python app is no longer
maintained, so these files and the golden images are this project's own
regression reference, as the Python app's last followed release (0.8.2)
made them. They are not made again. Where this app is changed on purpose
away from what they record, the change is a spec §10 entry and the test
says so: a changed bundled template is listed in `templateDifferences`
(`test/helpers/renderer_reference.dart`), which gives the tests the
template the fixtures were made from. The generators
(`tool/python_reference/`, the `/fixtures` skill) still run against the
Python repo for a module that is yet to be ported.

| Folder | What | Status |
|---|---|---|
| `overlay_golden/` | the Python HUD renderer's output for every bundled template in nine states, three of them also imperial, plus the rebreather pages at five moments | mirrored 2026-11-14 (Python 0.8.0) |
| `model/` | the dive model and the dive manager on invented values: computed properties, rounding, waypoint lookup, same-dive ranking | generated 2026-11-12 (Python 0.7.20) |
| `deco/` | the deco engine, SAC and gas time, and the parsers' deco pass on invented profiles | generated 2026-11-12 (Python 0.7.20) |
| `dives/` | parsed `Dive`/`Waypoint` JSON from synthetic logs, per parser | all six formats and the format detection generated 2026-11-12; `fit_edit_cases.json.gz` (the Log Viewer's "Adjust time" and "Merge dives" on invented FIT files) 2026-11-13 |
| `dates/` | the creation date and timezone logic and the Tag Editor's, on invented exiftool tag sets | generated 2026-11-13 (Python 0.7.20) |
| `rules/` | the rules engine: every lookup, the colour and tank rules, and the states and phases per waypoint over ten invented dives, per brand | generated 2026-11-12 (Python 0.7.20) |
| `renderer/` | the HUD renderer's drawing operations for every bundled template in 53 or 58 situations each, with Pillow's text measurements | generated 2026-11-14 (Python 0.8.0) |
| `color/` | the colour engine: the analysis of eight frames with four profiles, corrected pixels, 3D LUTs and a `.cube` text | generated 2026-11-13 (Python 0.7.20) |
| `mp4/` | exiftool's reading of 19 small synthetic MP4/MOV files (as base64) and of the same files after it wrote date tags to them | generated 2026-11-13 (exiftool 13.55) |
| `config/` | `config.yaml` (tank names) and `color.yaml` (colour profiles) read, changed and written, the tuning parameters, and PyYAML's text for a range of values | generated 2026-11-13 (Python 0.7.20) |
| `templates/` | the template tree: bundled and user templates merged, the state file per page, variant and state, the legacy packages | generated 2026-11-14 (Python 0.8.0) |
| `hud_designer/` | the Overlay Designer's logic: the sample dive and its forced states, element bounds and alignment with Pillow's measurements, the document through edits and undo, saving templates, and the template layout sweep's issues per page | designer and document cases generated 2026-11-14 (Python 0.8.0), the sweep 2026-11-15 (`d3ecc09`), the rest 2026-11-13 (Python 0.7.20) |
| `plan/` | the Dive Profile Builder's plan model and engine on 30 plans: gases by depth, the profile per second, the simulation, the planned ascent and the deco timeline; the UDDF, Subsurface and FIT logs it writes, the plan in them and a plan rebuilt from a log | generated 2026-11-13 (Python 0.7.20) |
| `engine/` | the desktop engine's ffmpeg and ffprobe command lines, how probe answers are read, the overlay layers (segments, matte, canvas, concat list, filter graph) and the progress lines | generated 2026-11-13 (Python 0.7.20) |
| `pages/` | the elapsed and remaining line of a long run, home-folder contraction, and the Dive Profile Builder's chart mapping and gas colours; what the Log Viewer shows of a dive | generated 2026-11-13 (Python 0.7.20) |
| `image/` | the JPEG files Pillow writes with a source's own quantisation tables and subsampling, on computed pictures | generated 2026-11-13 (Pillow 13.0.0) |
| `naming/` | output file names (patterns, presets, `_1/_2`, skip and overwrite), the date codes of `strftime`, conversion names and the camera clock offset | generated 2026-11-13 (Python 0.7.20) |
