# Engine reference

The ffmpeg and ffprobe command lines and the layer logic of the Python
app's video runs: `ffmpeg/ffmpeg_class.py`, the ffmpeg half of
`ffmpeg/color.py`, `ffmpeg/hud_layers.py`, `ffmpeg/overlay_output.py` and
`utils/progress_lines.py`. Needs the Python repo and its venv at
`$PYTHON_REPO`. No ffmpeg, ffprobe or video runs: the
probes answer with canned values and the command that would be run is
recorded.

| File | Python commit | Made | Command |
|---|---|---|---|
| `ffmpeg_cases.json.gz` | `0fdefd8` (0.7.20) | 2026-11-13 | see the docstring of `tool/python_reference/ffmpeg_fixture.py` |
| `tools_cases.json` | `0fdefd8` (0.7.20) | 2026-11-13 | see the docstring of `tool/python_reference/tools_fixture.py` |
| `exiftool_cases.json` | `0fdefd8` (0.7.20), pyexiftool 0.5.6 | 2026-11-13 | see the docstring of `tool/python_reference/exiftool_fixture.py` |
| `overlay_canvas_cases.json` | `0fdefd8` (0.7.20) | 2026-11-13 | see the docstring of `tool/python_reference/overlay_canvas_fixture.py` |

Gzip-compressed JSON:

- `encoders`: the encoder and its quality flags per system, hardware
  switch and whether NVENC opens.
- `process_video`: 88 convert and passthrough commands.
- `probes`: per probe method the ffprobe command and what it makes of
  canned answers (37 cases, with the ones it fails on).
- `ten_bit`: which pixel formats the colour runs keep 10 bits for.
- `sample_frames`: the frames analysed, for twelve clips.
- `lut_filters`: runs of filters (float32) with the `-vf` value and the
  sendcmd text.
- `color_args`: input and output arguments of the colour runs (112).
- `overlay_graphs`: the overlay filter graph.
- `full_commands`: the colour-only and overlay commands, whole (24).
- `segments`: the runs of frames per dive sample on the sample dive.
- `mattes`: BGR pictures on black and white (base64) and the BGRA matte.
- `canvas`: a layer's cropped canvas per layout, frame and widening step;
  `_canvas_design_width`; which drawings reach the canvas edge.
- `concat`: which pictures a layer's stream keeps and the concat list.
- `sinks`: the frame sink's commands for telemetry-only videos.
- `progress`, `run_progress`: the line buffer, the end status, and the
  progress lines `run_command` prints for streams of ffmpeg progress.

Paths of temporary files start with `/WORK`.

`tools_cases.json`: `get_installation_instructions` of
`utils/dependency_check.py` for every set of missing tools (ffmpeg,
ffprobe, exiftool) on each of the three systems, 21 texts.

`exiftool_cases.json`: the argument lists `metadata/exif.py` sends to
exiftool through pyexiftool, recorded without running exiftool (the
recorder answers a read with the case's metadata): `copies` (23 runs of
`copy_all`: with and without a timezone, a forced one, custom tags,
Sony's XML tags in 17 forms), `reads` (`get_metadata`, `get_tags` and
what they return) and `writes` (`set_tags`, `set_quicktime_tags`). The
paths and values are made up.

`overlay_canvas_cases.json`: `overlay_canvas` of `cli_main.py` on ten
layouts by five sizes and both modes (100 canvases: size, draw mode and
the layout to draw), the rounding to even sides, and the formats of
`ffmpeg/overlay_output.py`. No image is read: the skin sizes are a table
in the generator.
