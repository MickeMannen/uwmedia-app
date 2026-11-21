# Page logic reference

Small pieces of the Python pages' logic: `utils/run_timing.py`
(`format_duration`, `RunTimer`), `utils/display_paths.py` and the chart
mapping of `gui/dive_profile_view.py` (`chart_axes`, `xy_of`,
`point_from_xy`, `time_from_x`, `nearest_sample`, the gas colours). Needs
the Python repo and its venv at `$PYTHON_REPO`.

| File | Python commit | Made | Command |
|---|---|---|---|
| `small_cases.json` | `0fdefd8` (0.7.20) | 2026-11-13 | see the docstring of `tool/python_reference/small_fixture.py` |
| `log_viewer_cases.json.gz` | `249e1e9` (0.8.1) | 2026-11-14 | see the docstring of `tool/python_reference/log_viewer_fixture.py` |
| `overlay_bbox_cases.json` | `0fdefd8` (0.7.20) | 2026-11-13 | see the docstring of `tool/python_reference/overlay_bbox_fixture.py` |

- `durations`, `timers`: `format_duration` on 14 values; five scripts of a
  `RunTimer` on a clock that is moved by hand, with what it says each time
  it is asked.
- `home_paths`: `contract_home_path` (the home folder written as `HOME`).
- `chart`: margins, headroom and palette; 56 cases (seven plans of
  `plan/plan_cases.json.gz` by four sets of planned depth and runtime,
  with and without the simulated samples): the axes, each gas's colour,
  the next free colour, each sample's colour, the nearest sample for six
  times, and points and clicks mapped both ways on three chart sizes.

`log_viewer_cases.json.gz` (gzip-compressed JSON; the display logic of
`uwmedia/backends/log_viewer_backend.py`):

- `cases`: the 160 dives of `dives/{uddf,subsurface,shearwater,
  subsurface_csv,garmin}.json` (named by fixture, list, case and dive; the
  Dart test reads the same Python dump), each with a made-up tank-name
  mapping (`reverse_map`) and, in metres (`metric`) and for every third
  in feet too (`imperial`): the table's headings, `dive_row`,
  `dive_details`, `sample_rows` and, for nine filter texts, which lines
  the table keeps. `small` is the chart, the PO2 strip and the events
  with the limits set to 7 points and 2 lines, so that the thinning and
  the cut happen on these short dives.
- `numbers`, `minutes`, `mix_names`: the small formatters.
- `constants`: the columns, limits, format names and channel labels.


`overlay_bbox_cases.json` (the Color page's overlay box, `gui/hud_renderer.py`
`overlay_pixel_bbox`): `bbox`, 175 cases of two bundled templates (as they
are and with another skin scale and design width), two shape skins and a
layout without a skin, on five frame sizes and five placements, with the
skin picture's size; `seeds`, the bottom-left start of a new overlay.
