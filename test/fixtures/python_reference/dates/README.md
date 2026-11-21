# Date and timezone reference

Output of the Python app's `metadata/exif.py` (`_parse_timezone`,
`get_timezone_offset`, `get_standardized_creation_date`,
`get_local_creation_date`, the timezone tags of `copy_all`) and
`utils/tag_editor.py`, fed with invented metadata dicts in the shape of
exiftool's JSON. exiftool is not run and no media file is read. Needs the
Python repo and its venv at `$PYTHON_REPO`.

| File | Python commit | Made | Command |
|---|---|---|---|
| `dates_cases.json` | `0fdefd8` (0.7.20), Python 3.14.10 | 2026-11-13 | see the docstring of `tool/python_reference/dates_fixture.py` |

Results are `["ok", value]` or `["raise", exception type]`.

- `parse_timezone`: 37 values (texts, minutes as numbers, offsets of a day
  or more, which raise) and the minutes each stands for.
- `metas`: 72 tag sets (Sony and DJI video, photos with subseconds,
  ungrouped names, unreadable and zero dates, the `Timezone` tags) with
  the timezone offset, the UTC time and the local time. The files do not
  exist, so the "file's modification time" step fails in every case.
- `copy_all`: the tags written after a copy for ten tag sets by nine
  forced offsets (none included).
- `tag_guide`, `extensions`, `tz_modes`, `tz_offsets`: the Tag Editor's
  lists.
- `dji`: `calculate_dji_datetimes` for six names by eleven tag sets.
- `filename_dates`: `parse_date_from_filename` on 16 names.
- `batch`: `apply_batch_timezone_to_file` for 19 tag sets by five names,
  both modes and four offsets: the tags it hands to `set_tags`, or `false`.
  `get_tags` is stood in for by a lookup in the tag set (the full name,
  else the same name in another group).
- `filter`: `filter_metadata_rows`.
