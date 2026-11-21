# File naming and clock offset reference

Output of the Python app's `utils/clock_offset.py`,
`utils/filename_formats.py`, `utils/convert_naming.py`,
`ffmpeg/overlay_output.output_path_for` and `cli_main.py`'s
`output_filename`, `get_unique_path` and `resolve_target_path`. Needs the
Python repo and its venv at `$PYTHON_REPO`.

| File | Python commit | Made | Command |
|---|---|---|---|
| `naming_cases.json` | `0fdefd8` (0.7.20), Python 3.14.10 on macOS | 2026-11-13 | see the docstring of `tool/python_reference/naming_fixture.py` |

What is in it:

- `case_insensitive_files`: whether the file system the fixture was made
  on takes "A.jpg" for "a.jpg" (macOS: yes). The `unique` and `resolve`
  answers depend on it; the test gives its stand-in file system the same
  rule.
- `clock`: `format_offset` on 35 offsets and `parse_dive_time` on 64 texts
  (`inf` and `nan` results as text). One text is in Arabic-Indic digits,
  which Python reads and the port does not.
- `strftime`: 76 patterns on 15 dates: every date code the port knows, the
  numeric ones also with `%-`, and mixed patterns. These are the results of
  the C library of macOS; `pyStrftime` gives them on every platform (spec
  §10.22).
- `patterns`: the sample date, the Color page's presets and the labels of
  earlier versions, and `pattern_error` and `example_filename` on 21
  patterns.
- `output_filename`: 2480 names: eight source names (photo, video, no
  extension, several dots, leading and trailing dot) by 30 argument sets
  by batch run or single file, the same or another folder, a forced name,
  and dates with and without a fraction of a second.
- `paths`: `output_path_for` for the three overlay formats, the
  conversion resolutions and `convert_output_filename`.
- `unique`: five runs of `get_unique_path`, the reserved names carried
  from call to call.
- `resolve`: `resolve_target_path` for six folder situations by 20
  argument sets (what the run writes, skip, overwrite).
