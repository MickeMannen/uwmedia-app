# Platform check report format

The contract between the implementations of the platform check: the
Flutter app's (`integration_test/platform_check_test.dart`) and the Python
app's script. Both run the cases of `cases.json` (beside this file) and
write one report per run in this format;
`tool/platform_check/compare.dart` compares two reports.

Format name: `uwmedia-platform-check-report/1`. A change to a key, a unit
or a measurement below is a new version: update this file, both
implementations and the compare tool together.

## Files

A run writes two things into its output folder:

- `<name>.json`: the report, UTF-8 JSON (indentation free).
- `<name>/`: a folder of the same name holding the render PNGs, each under
  the name its check's `result.png` gives (`<render id>.png`).

`<name>` is `[python-]<os>[-simulator]-<yyyymmdd>-<hhmmss>`, the time being
the UTC start of the run, `python-` for the Python app's reports; `os` is
one of `macos`, `windows`, `linux`, `ios`, `android`. Example:
`macos-20261115-003246.json` and `macos-20261115-003246/`. The Flutter
driver writes into `build/platform_check/`; the Python script into the
folder it is given.

## Values

- Plain JSON: objects, arrays, strings, numbers, `true`/`false`, `null`.
  A number JSON cannot hold (NaN, an infinity) is written as the string
  `"nan"`, `"inf"` or `"-inf"`; Python writes with `allow_nan=False`.
- Numbers are written unrounded, as the language's JSON writer gives them
  (the shortest text that reads back as the same double, in Dart and in
  Python). The compare tool compares numbers as numbers (`3` equals
  `3.0`), so the text of a number does not matter, only its value.
- Times of day are the app's naive timestamps: `YYYY-MM-DDTHH:MM:SS`, with
  `.ffffff` only when there are microseconds (Python `datetime.isoformat()`,
  Dart `formatNaive`). Durations are seconds, depths metres, pressures bar,
  temperatures °C (spec §4).
- A missing value is `null`, never left out where this file lists the key.
- Hashes are lower-case hex SHA-256.
- Lengths of time measured on the machine (`time_ms`, `duration_ms`) are
  whole milliseconds and are never compared.

## The report

```json
{
 "format": "uwmedia-platform-check-report/1",
 "implementation": "dart",
 "pack_format": "uwmedia-platform-check-pack/1",
 "pack_sha256": "<SHA-256 of the bytes of cases.json>",
 "started": "2026-11-15T00:32:46.123456Z",
 "duration_ms": 9258,
 "app": {"name": "UWMedia", "version": "1.0.0", "build": "1"},
 "platform": {
  "os": "macos",
  "os_version": "Version 27.2.1 (Build 26B131)",
  "device": "Mac14,7",
  "simulator": false,
  "processors": 8,
  "dart": "3.13.5 (stable) ... on \"macos_arm64\"",
  "build_mode": "debug"
 },
 "engine": {
  "kind": "desktop",
  "engine": "ffmpeg",
  "ffmpeg": "/opt/homebrew/bin/ffmpeg",
  "ffmpeg_version": "ffmpeg version 9.0.2 Copyright (c) 2000-2026 the FFmpeg developers",
  "encoder": "hevc_videotoolbox"
 },
 "inputs": {
  "hud_rules_sha256": "<SHA-256 of the bytes of hud_rules.json used>",
  "color_yaml_sha256": "<SHA-256 of the bytes of color.yaml used>"
 },
 "summary": {"pass": 36, "fail": 0, "skip": 0},
 "checks": [ ... ]
}
```

- `implementation`: `dart` or `python`.
- `started`: the UTC start of the run, ISO 8601 with `Z`.
- `app`: `name`, `version` and `build` of the app (Python: its version,
  `build` `null`).
- `platform`: `os` as above; `os_version` the system's own version text;
  `device` a model name or identifier when the system gives one without a
  plugin (`sysctl hw.model` on macOS, the DMI product name on Linux,
  `getprop` on Android, `sysctl hw.machine` on an iPhone such as
  `iPhone19,7`, the simulator's model on a simulator), else `null`;
  `simulator` true on an iOS simulator (its `hw.machine` is the Mac's
  processor, not a phone model) or Android emulator. Python writes
  `python` (its version) in place of `dart`, and leaves out `build_mode`.
  No host names, user names or serial numbers.
- `engine`: `kind` `desktop` (ffmpeg as a process) or `mobile` (the phone
  engine). Desktop: `engine` `"ffmpeg"`, `ffmpeg` the path of the binary
  run (the home folder as `~`), `ffmpeg_version` the first line of
  `ffmpeg -version`, `encoder` the HEVC encoder the app picks with hardware
  acceleration on. Phone: `engine` `AVFoundation` or `Media3 Transformer`.
  No ffmpeg found: `engine` `null` and the engine checks skipped.
- `inputs`: the rules and colour profiles the run used; the compare tool
  warns when two reports differ here.
- `summary`: the number of checks per status.

## Checks

`checks` lists every check in the order of `cases.json`: the dives, the
rules, the colour cases, the renders, then the engine checks
(`engine/ffmpeg_generate`, `engine/source_clip`, the runs). Each:

```json
{"area": "renders", "id": "renders/<case id>", "status": "pass",
 "reason": null, "time_ms": 128, "result": { ... }}
```

- `area`: `dives`, `rules`, `color`, `renders`, `engine`, or `setup` (an
  implementation's own preparation, such as the Flutter test loading its
  fonts; never compared, listed by the compare tool only when it failed).
- `id`: `<area>/<case id>` with the case ids of `cases.json`; the colour
  cases are `color/<frame id>/<profile>`.
- `status`: `pass` (ran, and its own checks held), `fail` (`reason` says
  what; `result` holds what was measured before it failed, or `null`),
  `skip` (not run on this platform; `reason` says why, `result` `null`).
  One check failing never stops the others.
- `result`: per area, below. Key order does not matter.

### dives

One check per log of `dives.logs`. The log's bytes (base64 in the pack)
are parsed by the parser registry under the log's `file_name` (Dart
`parseLogFile`; Python `parsers.registry.parse_log_file` on the bytes
written to a temporary file of that name).

```json
{
 "bytes_sha256": "<SHA-256 of the decoded log bytes>",
 "format": "fit",
 "dive_count": 1,
 "dives": [{
  "start_time": "2026-05-02T10:00:00",
  "end_time": "2026-05-02T10:53:14",
  "duration_s": 3194,
  "max_depth": 38.0,
  "waypoints": 161,
  "device": "descent_mk3i",
  "manufactor": "garmin",
  "timezone": "UTC+08:00",
  "is_ccr": false,
  "gf_low": null,
  "gf_high": null,
  "log_format": "fit",
  "samples": [
   {"at_s": 798, "timestamp": "2026-05-02T10:13:20", "depth": 38.0, "temp": 28.0,
    "max_depth": 38.0, "ndl": null, "tts": 482, "ceiling": 5.185721460395358,
    "deco_stop_depth": 9.0, "next_stop_depth": 9.0, "next_stop_time": 60,
    "cns": 4, "po2": 1.01, "gf": 0.0, "surf_gf": 110.9, "divemode": null,
    "time_since_start": 800, "tanks": {"100001": 118.1}}
  ]
 }]
}
```

- `format`: the registry's format key for the file (`detect_log_format`).
- Per dive: `duration_s` is `Dive.duration`, `max_depth` `Dive.max_depth`,
  `waypoints` the number of waypoints, `is_ccr` `Dive.is_ccr`; the other
  dive keys are the model's fields of that name.
- `samples`: one per entry of the log's `sample_seconds`, in that order:
  the waypoint `Dive.get_waypoint_at(start_time + at_s seconds)` gives;
  its `timestamp` and each field of `dives.fields` as the waypoint's JSON
  dump has it (Python `model_dump(mode="json")`, Dart `toJson()`); `tanks`
  is `{tank key: pressure_bar}`. A field the dump does not have is `null`.

The check fails when `format` is not the log's `expect_format` or no dive
was parsed.

### rules

One check per computer of `rules.computers`, on the dummy dive
`build_dummy_dive(variant, ccr)` of `rules.dive`.

```json
{
 "timeline": [
  {"t": 840, "time_since_start": 840, "state": "deco",
   "stop_phase": ["deco", "approach", null, 6.0],
   "safety_stop_status": [false, 180], "deco_clear_seconds": null,
   "ndl_before_clear": null, "safety_text": ""}
 ],
 "forced": {"normal": "normal", "ndl_low": "ndl_low", "...": "..."}
}
```

- `timeline`: one entry per `rules.times_s`: `w = waypoint_at(dive, t)`
  (the first waypoint at or after `t` seconds of dive time) and the dive's
  waypoints as the history `wps`; `time_since_start` of `w`; `state`
  `resolve_state(m, mo, w, wps)`, `stop_phase` `stop_phase(m, mo, w, wps)`
  as a 4-array, `safety_stop_status` `safety_stop_status(m, mo, w, wps)` as
  a 2-array or `null`, `deco_clear_seconds` `deco_clear_seconds(m, mo, w,
  wps)`, `ndl_before_clear` `get_ndl_before_clear(m, mo, w, wps)`,
  `safety_text` `get_safety_stop_text(m, mo, w)`; `m` and `mo` the
  computer's manufacturer and model.
- `forced`: per state of `rules.forced_states`,
  `(wp, history) = forced_dive(waypoint_at(dive, forced_from_s), state)`
  and `resolve_state(m, mo, wp, history)`.

### color

One check per frame of `color.frames` and profile of `color.profiles`. The
frame is computed by the formula in `cases.json` (RGB, row by row).

```json
{
 "frame_size": [1024, 768],
 "frame_sha256": "<SHA-256 of the frame's RGB bytes>",
 "filter": [1.0, 0.0, 0.054901961237192154, "... 11 values"],
 "corrected_mean": [106.36972427368164, 125.28329722086589, 135.82935587565103],
 "corrected_sha256": "<SHA-256 of the corrected frame's RGB bytes>"
}
```

- `filter`: `get_filter_matrix(frame)`, the 11 float32 values as doubles.
- The corrected frame is `apply_filter(frame, filter)`, sharpening
  included; `corrected_mean` the mean of each channel over all its pixels.

### renders

One check per case of `renders.cases`, drawn as described there (the
golden test's way). The halved picture is written as an 8-bit RGB or
opaque RGBA PNG named `<case id>.png`.

```json
{
 "png": "garmin__x50i__main__single_tank__normal.png",
 "box": [16, 763, 473, 301],
 "size": [236, 150],
 "mean": [38.189, 37.525, 36.939],
 "rgb_sha256": "<SHA-256 of the halved picture's RGB bytes>"
}
```

- `box`: x, y, width and height of the crop in the 1920x1080 frame.
- `size`: the halved picture's width and height.
- `mean`, `rgb_sha256`: of the halved picture's RGB bytes, row by row
  (Python: the OpenCV frame is BGR; reverse the channels first).

The check fails when the box is smaller than 4x4 pixels.

### engine

Two clips, both beside `cases.json`. Correctness is measured on
`engine.clip.file`, the 2 s 1280x720 clip. It is the same bytes on every
platform, and a phone has it built into the test.

Performance is measured on `engine.perf.clip.file`, `perf_clip.mp4`: 20 s,
1920x1080, 30 fps, H.264 with an AAC tone, 4.8 MB. It is the same file on
every platform and is never made again. A desktop build finds it in the
repo it was built in (the Python script reads it there too). A phone gets
it through the system file picker, from a copy the owner puts on the
phone once. `PERF_CLIP=<path>` names it outright, which a simulator can use
for a path on the Mac. Its SHA-256 is checked against
`engine.perf.clip.sha256` before any timed run.

On the desktop the tools are the ones the app itself finds (its bundled
copy, then the PATH, then the system's folders). On a phone the phone
engine is used.

The engine checks, in this order:

| id | What | Phone |
|---|---|---|
| `engine/ffmpeg_generate` | the 2 s clip made again with its `ffmpeg_args` | skipped |
| `engine/source_clip` | the 2 s clip read as the outputs are read (the baseline) | yes |
| `engine/color` | colour correction alone | yes |
| `engine/color_overlay` | colour correction with the run's overlays | yes |
| `engine/overlay/<format>` | the Overlay Generator's render of the overlay alone, per format (`prores`, `png`, `hevc`) | skipped (a desktop page) |
| `engine/perf/clip` | the perf clip found or picked, its SHA-256 checked, its facts read | yes |
| `engine/perf/<run id>` | each run of `engine.perf.runs` on the perf clip, timed | `color` and `color_overlay` yes; `overlay/<format>` skipped |

Without a perf clip (none found or picked, or `PERF=0`), `engine/perf/clip`
and the timed runs are skipped with the reason. With a clip whose SHA-256
is not the pack's, `engine/perf/clip` fails and the timed runs are
skipped.

What each run kind calls:

- `color`: the Color page's video run without overlays. Desktop Dart
  `ColorRun.processVideoLut`; Python
  `ColorCorrectionEngine(FfmpegClass(hw_accel), profile).process_video_lut(input, output, creation_date)`;
  phone `MobileVideoRun.process` with the colour engine and no layers.
- `color_overlay`: the same with the run's `overlays`. Desktop Dart
  `OverlayRun.processVideo`; Python `process_video(..., dive=..., overlay_instances=[...], color_correct=True, match_date=...)`;
  phone `MobileVideoRun.process` with the layers. An overlay is the
  bundled template's `normal.json`, placed at `x` and `y` (fractions of
  the frame) with `scale`.
- `overlay`: the Overlay Generator's video render for the clip's length
  (Python `cli_main.py --render-video-log`): the run's `overlay` template
  (its skin is the frame, as with the page's "1080p (template size)":
  `size` `1080p`, `full_frame` false), in `format`. Desktop Dart
  `TelemetryRun.render(source, dive, start: match_date, fps, totalFrames,
  format, target, size, fullFrame)`, with fps and frame count probed
  before the render. Python: the render loop of `process_single_file`'s
  `args.render_video_log` branch (`overlay_canvas`, `render_frame`,
  `FrameSink`). The output is `.mov` (ProRes 4444 with alpha) for
  `prores`, a folder of `frame_000001.png` ... for `png`, and `.mp4`
  (HEVC on black) for `hevc`.

In every run the dive is the dummy dive of `engine.dive`;
`creation_date` and `match_date` are as in the pack.

**Timing.** `run_ms` is the wall-clock time of the run call itself, in
whole milliseconds. Probing the input before the run is outside it, and
so are probing and measuring the output afterwards. For `overlay` the fps
and frame count are probed before the clock starts. The Flutter app
loads the overlay template and its skin before the clock as well; Python's
`process_video` reads them inside the call, so its `color_overlay` time
includes that read (milliseconds, a known difference). The colour runs'
analysis of the clip is inside it (it is part of the run).

`engine/ffmpeg_generate`:

```json
{"sha256": "<of the file made>", "same_as_pack_clip": true, "run_ms": 798,
 "encoder": "libx264", "codec": "h264", "width": 1280, "height": 720,
 "frames": 61, "duration_s": 2.033333}
```

It fails when the size or the frame count is not the pack's. A different
`sha256` (another ffmpeg or x264 build) is only reported.

`engine/source_clip` and the correctness runs:

```json
{
 "codec": "hevc", "width": 1280, "height": 720, "frames": 61,
 "duration_s": 2.033333, "bytes": 285139,
 "frames_at": [
  {"t": 0.5, "size": [1280, 720], "mean": [136.97, 120.61, 137.62],
   "grid": [[124.88, 66.46, 45.11], "... 16 cells"]}
 ],
 "run_ms": 1522, "encoder": "hevc_videotoolbox", "hw_accel": true,
 "source_frames": 61, "samples": 2, "layers": 1
}
```

- **Probing.** On the desktop the output is probed with the ffprobe the
  app found:
  `ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=codec_name,width,height,nb_read_frames:format=duration -of json <file>`.
  This gives `codec` (the `codec_name`), `frames` (`nb_read_frames` as a
  whole number) and `duration_s` (the format's duration, as a number).
  On a phone, the engine's own probe gives `codec` `hevc` or `h264` from
  the MIME type, and `frames` is `null` when the file does not say.
- **A PNG sequence** is probed as follows: `codec` `"png"`, `width` and
  `height` those of `frame_000001.png`, `frames` the number of
  `frame_*.png` files, `duration_s` that number divided by the clip's
  fps, `bytes` the total of the files.
- **`frames_at`** has one entry per `engine.frame_times_s`: the frame at
  `t` seconds as RGB, at the output's size.
  - Desktop:
    `ffmpeg -nostdin -loglevel error -ss <t with 6 decimals> -i <file> -frames:v 1 -vf scale=<w>:<h>:flags=area -f rawvideo -pix_fmt rgb24 -`.
    For a PNG sequence the same command runs on `frame_<floor(t * fps) + 1>.png`
    with `-ss 0.000000`. The alpha of a ProRes or PNG output is dropped by
    the conversion to `rgb24`.
  - Phone: the engine's exact frame grab.
  - `size` is [w, h] and `mean` the mean of each channel.
  - `grid` holds the means of each cell of an `engine.grid` x
    `engine.grid` split, row by row from the top left. Cell (gx, gy)
    covers the columns `gx * w // grid` up to (not including)
    `(gx + 1) * w // grid`, and the rows likewise.
  - A frame that cannot be read is `{"t": t, "missing": true}`.
- **`bytes`** is the output's size (a folder's files added up).
- **`run_ms`, `encoder`, `hw_accel`.** The timing is as above. `encoder`
  is the video encoder that wrote the output: the app's HEVC choice (for
  example `hevc_videotoolbox`), `prores_ks`, `png`, or on a phone
  `AVFoundation` or `Media3 Transformer`.
- **Run counts, where the implementation gives them.** The colour runs
  give `source_frames`, `samples` (the frames the analysis looked at) and
  `luts` or `layers`; `overlay` gives `pictures` (the distinct overlay
  pictures drawn). Leave them out when they cannot be had; the compare
  tool then shows them as not reported.
- **`messages`** (phone only): the lines the run gave.

A `color` or `color_overlay` run fails when its output is not the clip's
size or a frame cannot be read. An `overlay` run fails when it does not
have the clip's frame count, has no size, or has a frame that cannot be
read.

`engine/perf/clip`:

```json
{"codec": "h264", "width": 1920, "height": 1080, "frames": 600,
 "duration_s": 20.0, "fps": 30.0, "bytes": 4793938,
 "sha256": "371bf1bb8129f6761ff3b20fdc578e1d769700989c72543d5d9c6f4b1c9a693f"}
```

It is the probe of the file, as above. `fps` is the app's own reading of
it (desktop `FfmpegTools.fps`; phone the engine's probe), and `sha256` is
the file's own. The check fails when the SHA-256 is not the pack's.

`engine/perf/<run id>`: the run done `repeats` times on the perf clip
(`engine.perf.repeats`; the Flutter test also takes
`--dart-define=PERF_REPEATS=<n>`), its output removed before each
repeat.

```json
{
 "input": {"<the engine/perf/clip result>": "..."},
 "output": {"codec": "hevc", "width": 1920, "height": 1080, "frames": 600,
            "duration_s": 20.0, "bytes": 4912345},
 "encoder": "hevc_videotoolbox", "hw_accel": true,
 "repeats": 1, "run_ms": [7360], "run_ms_median": 7360.0,
 "source_frames": 600, "samples": 11, "luts": 2
}
```

- `run_ms` lists every repeat in order. `run_ms_median` is their median
  (for an even count, the mean of the two middle values).
- `output` is probed as above, without `frames_at`.
- A perf run fails when its output has a frame count other than the perf
  clip's (a phone may give none; then it is not checked), is more than
  0.1 s off its length, or (for a colour run) is not its size.
- Outputs are written in the work folder and removed after each repeat.

## Summary text

At the end every implementation prints a plain-text summary for pasting.
It goes to the console (the Flutter test's log, the Python script's
standard output) and into `<name>.txt` beside the report. The Flutter test
also shows it on a screen with a Copy button and waits for Done (up to 30
minutes; `WAIT=0` does not wait). The layout, line by line:

```
UWMedia platform check
implementation: flutter 1.0.0+1
os: macos Version 27.2.1 (Build 26B131)
device: Mac14,7, 8 CPUs
engine: ffmpeg 9.0.2, hevc_videotoolbox, hw accel on
clip: perf_clip.mp4 371bf1bb8129, 20.0 s 1920x1080 30 fps
checks: 40 pass, 0 fail, 0 skip
perf: median of 1, seconds of the run itself, x realtime
  color               7.36 s    2.72x  1920x1080 hevc 4.9 MB
  overlay/png     skipped: the Overlay Generator is a desktop page (spec §0)
started: 2026-11-15T01:12:57.718964Z
```

- `implementation:` is `flutter` or `python`, then the app's version (the
  Flutter app's `version+build`, the Python app's version).
- `os:` is the report's `platform.os` and `platform.os_version`.
- `device:` is `platform.device` (or `unknown`), then
  `<platform.processors> CPUs`.
- `engine:` depends on the platform:
  - Desktop: `ffmpeg <the third word of ffmpeg_version>, <encoder>, hw accel on`.
  - Phone: the engine's name.
  - No engine: `none`.
- `clip:` is `perf_clip.mp4 <the first 12 hex digits of its SHA-256>,
  <duration_s with 1 decimal> s <width>x<height> <fps rounded> fps`, from
  `engine/perf/clip`. Without it: `none (<the check's reason>)`.
- `checks:` counts the statuses of every check except `engine/perf/*`.
- `perf:` reads `median of <repeats>, seconds of the run itself, x realtime`,
  where `<repeats>` is that of the first timed run that passed, and 0 when
  none did.
- One line per `engine/perf/<run id>` (not `clip`), in report order. Each
  starts with two spaces and the run id left-aligned in 16 characters. A
  passed run continues with:
  - the median in seconds, 2 decimals, right-aligned in 8, then ` s`;
  - the clip's 20.0 s divided by that, 2 decimals, right-aligned in 8,
    then `x`;
  - two spaces, then `<width>x<height> <codec> <bytes / 1e6 with 1 decimal> MB`
    of the output.

  A run that did not pass continues with `skipped: <reason>` or
  `failed: <reason>`.
- `started:` is the report's `started`.
- Every line ends with a newline, including the last.

`integration_test/platform_check/summary.dart` writes it (Python:
`f"  {name:<16}{seconds:8.2f} s{speed:8.2f}x  {w}x{h} {codec} {mb:.1f} MB"`).

## Comparing

`dart run tool/platform_check/compare.dart <A.json> <B.json>` compares the
checks by `id`. A check is *identical*, *within tolerance*, a *known
deviation* (a leaf that differs as `cases.json` `known_differences` lists,
from the spec's §10; only against the Python app), *different*, *failed*
(on either side), *skipped* (on either side) or *missing* (in one report).
The leaves are compared as follows:

| What | Rule |
|---|---|
| Text, booleans, whole numbers, sizes, codecs, frame counts | exact |
| `dives`, `rules` decimals | within 1e-6 |
| `color` `filter` | within 1e-6 (float32 values) |
| `color` `corrected_mean` | within 0.05 |
| `color` `corrected_sha256` | exact Dart against Dart; shown only against Python (the colour parity test allows 1 level on 0.1 % of the bytes, 3 after sharpening) |
| `renders` PNGs | over the area both have: the mean absolute difference and the share of pixels off by more than 40 in a channel. Against Python 5.0 and 4 % (the port's golden test limits); Dart against Dart 5.0 and 6 % (the platforms rasterise text differently: macOS desktop against the iOS simulator, 2026-11-15, glyph edges only, worst 3.3 and 4.3 %) |
| `renders` `size` / `box` | within 1 / 2 px; `mean` and `rgb_sha256` shown only |
| `engine` `duration_s` | within 0.05 s |
| `engine/source_clip` frame `mean` / `grid` cells | within 4.0 / 12.0 per channel (the platforms' YUV to RGB conversions) |
| `engine/color`, `engine/color_overlay` frame `mean` / `grid` | compared as the change from the same report's `engine/source_clip` frame at the same time (`mean_change` within 3.0, `grid_change` within 8.0: the encoders differ); the absolute values shown only. Without a `source_clip` on both sides, absolute within 4.0 / 12.0 |
| `engine/overlay/<format>` frame `mean` / `grid` | absolute, within 4.0 / 12.0 |
| `engine` `bytes`, `encoder`, `sha256`, `same_as_pack_clip`, `messages`, an optional count one side does not report | shown only |
| `run_ms`, `run_ms_median`, `repeats` | never compared; listed in the performance table |
| `time_ms`, `duration_ms`, `platform`, the `engine` header, `setup/` checks | not compared |

After the checks the tool prints a **performance table**. It has one row
per engine check with a `run_ms` (the median for a perf run), showing A's
time, B's time, B / A and the two encoders. Times never fail a
comparison.

The tool exits with 1 when any check is different, failed or missing.
