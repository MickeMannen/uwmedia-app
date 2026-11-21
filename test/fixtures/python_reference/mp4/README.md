# MP4 date reference

What exiftool reads from small MP4 and MOV files, and what it reads after
writing date tags to them, called the way the Python app's
`MetadataHandler` calls it (`get_metadata`, `set_quicktime_tags`). The
oracle for the port's own reader and writer in
`lib/core/metadata/mp4_dates.dart`. Needs the Python repo and its venv at
`$PYTHON_REPO`, and ffmpeg and exiftool.

| File | Made with | Made | Command |
|---|---|---|---|
| `mp4_cases.json` | Python app `0fdefd8` (0.7.20), exiftool 13.55, ffmpeg 8 | 2026-11-13 | see the docstring of `tool/python_reference/mp4_fixture.py` |

The files are synthetic: one frame of ffmpeg's test pattern (and a second
of a sine tone in the two-track ones), 2 to 6 kB each, kept as base64
inside the JSON. No camera footage and no video file is in git.

- `sources`: 19 files with `file`, `base64` and the `tags` exiftool reads
  (of the names in `claimed`). Twelve are made by ffmpeg and exiftool:
  bare, ffmpeg's `creation_time`, moov before the data (`faststart`), two
  tracks, MOV with QuickTime keys written by ffmpeg (in `udta`) and
  without, and exiftool's own writes (all dates; keys with make, model and
  software; a creation date in UTC, without a zone, with subseconds; a
  late and an early date). Seven are changed copies: 64-bit headers, the
  tracks' dates apart, and movie dates around the value under which
  exiftool counts from 1970 instead of 1904.
- `write_sets`: seven tag sets the Python app writes (after a copy, the
  batch timezone change, the Tag Editor's fields, all six header dates,
  zero dates, a UTC creation date, one with subseconds).
- `writes`: for every source and write set, the tags exiftool reads after
  writing the set to a copy.

The fixture's ffmpeg bytes are not reproducible bit for bit across ffmpeg
versions; regenerating replaces all of it at once.
