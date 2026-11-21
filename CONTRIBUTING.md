# Contributing to the UWMedia app

## Setup

Flutter 3.47 or newer on the stable channel (Dart 3.13.5 or newer, see
`environment.sdk` in `pubspec.yaml`). Desktop targets need the platform
toolchain `flutter doctor` lists; the desktop engines also need ffmpeg,
ffprobe and exiftool on `PATH` once they exist (the packaged app bundles
them).

```bash
flutter pub get
git config core.hooksPath .githooks      # once per clone, see below
```

## Tests

There are three levels of testing. The first one is the minimum for every
commit. The runner is `tool/run_tests.sh`; with no argument it asks, with a
number it runs that suite without asking (use the number in scripts and
agents).

| When | Command | What runs |
|---|---|---|
| Before every commit | `tool/run_tests.sh 1` | `dart format` check, `flutter analyze --fatal-infos`, and every test except `golden` and `release` |
| A quicker check while working | `tool/run_tests.sh 2` | The same without the `render` tests |
| Before a release | `tool/run_tests.sh 4` | Everything, including the `release` tests on the full media and the overlay golden images |
| Before a release | `tool/perf_check.sh` | The speed check: the platform check's timed runs held to this machine's baseline ("Speed check" below) |

`tool/run_tests.sh 3` runs only the `release` tests.

The default suite also runs on GitHub Actions (`.github/workflows/tests.yml`)
on macOS, Windows and Linux for every push to `main` and every release tag;
the macOS job adds the golden images. `.gitea/workflows/tests.yml` is the
same suite for every branch push on the owner's self-hosted runners
(`docs/local-ci.md`).

Coverage: `flutter test --coverage` writes `coverage/lcov.info`; the Linux
CI job uploads it as an artifact.

### Pre-commit hook (recommended)

A hook in `.githooks/` runs the default suite before each commit and stops the
commit if a check fails. Turn it on once per clone:

```bash
git config core.hooksPath .githooks
```

It skips commits that only touch Markdown files. To commit anyway in an
emergency, use `git commit --no-verify`, then fix the tests in the next
commit.

### Test tags

Tags are declared in `dart_test.yaml` and set per file or per test with
`@Tags(['render'])` / `tags: ['render']`:

- `render`: encodes the fixture media through a media engine (slower).
- `release`: pre-release validation on the full-size media in `test_data/`.
- `golden`: `test/hud/hud_golden_test.dart` draws every bundled overlay
  page in the Python golden test's states and compares it with the Python
  app's own renders in `test/fixtures/python_reference/overlay_golden/`,
  within the limits its header explains (the rasteriser and, for "Arial",
  the font differ). Font rasterising differs between machines, so it runs
  on macOS only until the bundled fonts are confirmed to render alike
  everywhere. `HUD_GOLDEN_ONLY=<part of a name>` writes golden | port |
  difference images into `build/hud_golden/`. The goldens were made by
  the Python app, which is no longer maintained (2026-11-19): they are
  kept here as they are and never regenerated.
- `requires_media`: reads `test_data/`; the test skips itself when the
  folder is missing (`skipIfNoTestData()` in `test/helpers/test_data.dart`).
- Platform-only checks use `skip:` with a `Platform` condition, not a tag.

The default run excludes `golden` and `release` (`tool/run_tests.sh`,
`.githooks/pre-commit` and the workflows pass `--exclude-tags`).

### Test data

- `test_data/` holds the owner's private media and dive logs. It is not in
  git, so on a fresh clone the tests that need it skip themselves rather
  than fail. To use a copy stored somewhere else, set
  `UWMEDIA_TEST_DATA=/path/to/test_data` (the Python app's `test_data/`
  works as it is).
- The self-hosted runners read the data from a read-only share on the
  owner's network, kept in step by the pre-push hook
  (`tool/test_data_sync.sh`) and connected by each job
  (`tool/ci_test_data.sh`); `docs/local-ci.md` has the details.
- `test_data/release_test/` is the full-size media of the `release` tests
  (`test/release/release_test.dart`): the Python app's
  `test_data/release_test` copied over as it is (two clips, six photos,
  433 MB), with `test_data/logs/fit` and `logs/ssrf` for the dives. The
  test runs colour and colour with overlays on it and checks that each
  overlay is drawn; its outputs stay in `build/release_test/` for a look
  (the one test output kept in the repo folder, git-ignored with
  `build/`).
- `test_data/python_reference/` (local, never committed) holds what the
  Python app's parsers make of the real logs in `test_data/logs/`; make it
  with `tool/python_reference/real_logs_fixture.py` (its docstring has the
  command). `test/core/parsers/real_logs_test.dart` compares the Dart
  parsers with it, file by file, and skips itself without it. Run the
  generator again when a parser is ported or the Python app changes.
  `fit_plans.json` beside it is what the Python app's Dive Profile
  Builder rebuilds from each real FIT log
  (`tool/python_reference/fit_writer_fixture.py --real`), compared by
  `test/core/plan/real_fit_plans_test.dart`.
  `fit_edit.json` is what "Adjust time" and "Merge dives" write for the
  real FIT logs (`tool/python_reference/fit_edit_fixture.py --real`),
  compared by `test/core/parsers/real_fit_edit_test.dart`.
- `test/fixtures/` holds the small files that are in git; its `README.md`
  lists each file and its review. `media/` has the three reviewed media
  files copied from the Python repo (the owner approved copying its test
  content, 2026-10-17); `deco_reference/` has the Subsurface planner
  references for the deco engine. The render tests use the media with
  synthetic logs written at run time by the app's own writers.
- `test/fixtures/python_reference/` holds JSON and PNG fixtures generated
  by the Python app (`/fixtures` skill): parsed dives from synthetic logs,
  date and timezone results per media fixture, colour filter vectors and
  `.cube` LUTs for sample frames, HUD renders at fixed timestamps. They
  were the parity oracle while the app was brought over; the Python app is
  no longer maintained (2026-11-19), so they are kept as they are, never
  edited by hand and never regenerated from the Dart output. `overlay_golden/`
  there holds the Python renderer's output for every template and state
  (its README says how they were made), and `renderer/` its drawing
  operations and text measurements, which the port's renderer and font
  reader are held to exactly.
- **Dive logs are never committed.** FIT, UDDF, SSRF, Shearwater XML/CSV and
  other dive-profile files contain device serial numbers and personal IDs.
  A test that needs a log builds a synthetic one at run time.
- **Photos and videos go into git only after the owner has reviewed them**,
  including their metadata (EXIF/XMP can hold camera serial numbers, names
  and GPS). The reviewed media fixtures from the Python repo
  (`tests/fixtures/media/`, listed in its `README.md` with checksums) are
  copied over with their review rows; anything else needs a new review.

### Writing tests

- Pure-logic modules (`lib/core/`, parsers, deco, rules, renderer geometry,
  colour maths) get plain `test()` cases that need no Flutter binding and
  compare with the Python reference fixtures.
- Write output to a temporary directory
  (`Directory.systemTemp.createTempSync('uwmedia_')`, deleted in
  `tearDown`), never into the repo or `test_data/`.
- Never write to the real app folders (Application Support, `~/.config`,
  caches). Tests that touch `app_paths.dart` point it at a temporary
  folder through its override hook.
- Tests run in parallel (`flutter test` uses several isolates), so a test
  must not depend on another test or share a fixed file path with one.
  Use `flutter test -j1` to run serially, e.g. under a debugger.
- Widget tests cover pages. `integration_test/` holds the tests that need
  a phone's runner; they are not part of `tool/run_tests.sh`.
  `media_engine_test.dart` runs the phones' media engine on a simulator
  or a phone, on clips made with ffmpeg (its header says how):
  `flutter test integration_test -d <device> --dart-define=CLIP=<clip>`.
  Run it after a change to `MediaEngine.kt` or the iOS runner's
  `MediaEngine`. `hud_golden_test.dart` runs the overlay golden test on a
  desktop app's own engine:
  `flutter test integration_test/hud_golden_test.dart -d macos --dart-define=REPO=$PWD`.
  `color_shader_test.dart` runs the preview's shaders against the colour
  engine on a device's graphics card (the default suite runs the same
  comparison in the test runner's software renderer):
  `flutter test integration_test/color_shader_test.dart -d <device>`.
  `photos_album_test.dart` writes a made-up picture into the Photos
  library of whoever runs it, so it runs only when named, with the album:
  `flutter test integration_test/photos_album_test.dart -d macos --dart-define=ALBUM=uwmedia_test`.
  `native_desktop_test.dart` runs Color and Resize on a Mac by ffmpeg, by
  the runner's media engine, and as the Mac App Store build does with
  neither ffmpeg nor exiftool, side by side, on a clip of yours (the
  phones' `media_engine_test.dart` runs on a Mac too):
  `flutter test integration_test/native_desktop_test.dart -d macos --dart-define=CLIP=<clip>`.

### Platform check

`integration_test/platform_check_test.dart` runs one set of cases
(`integration_test/platform_check/cases.json`) on whatever it runs on and
writes a report: seven synthetic dive logs parsed, the rules engine on the
sample dive for a Garmin, a Shearwater and a Suunto, the colour engine on
computed frames, sixteen overlay renders in the golden test's states, and
the platform's own media engine (ffmpeg on a desktop, the phone engine on
a phone). The engine part runs colour alone, colour with an overlay, and
on the desktop the Overlay Generator's overlay alone in each of its
formats (ProRes 4444, PNG sequence, HEVC), measured on a 2-second
invented clip. The same runs are then timed on `perf_clip.mp4` (20 s,
1080p, 4.8 MB, beside `cases.json`), the same file on every platform and
in the Python app's check, so the times compare. A desktop build finds it
in the repo. A phone asks for it with the file picker, so copy it to the
phone once (AirDrop, Files, USB). A simulator can be given the Mac's path
with `--dart-define=PERF_CLIP=$PWD/integration_test/platform_check/perf_clip.mp4`.

At the end a screen shows the summary (the timings and the counts) as
text with a Copy button, for pasting, and waits for Done. The summary is
also printed in the run's output and saved as `<report>.txt`.

The `--dart-define` switches:
- `WAIT=0`: no picking and no waiting (unattended runs).
- `PERF=0`: the timed runs left out.
- `PERF_REPEATS=<n>`: each timed run done n times, with the median kept.

A whole desktop run takes under a minute on an M2 Mac. Each check passes,
fails or is skipped with its reason; one failing does not stop the
others, and the run fails at the end when any did. Nothing is written
outside a temporary folder, the app's own folders included.

Run it from the repo, one device at a time (`flutter devices` lists
them; a phone or a simulator gets the app installed over any UWMedia
already there):

```bash
# macOS, Windows, Linux (on that machine; ffmpeg found as the app finds it)
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/platform_check_test.dart -d macos   # or windows, linux
# iPhone or iOS simulator, Android phone or emulator
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/platform_check_test.dart -d <device id>
```

The driver saves `build/platform_check/<platform>-<time>.json` and the
renders in the folder of the same name (`REPORT_FORMAT.md` beside
`cases.json` describes both). On a desktop, `flutter test
integration_test/platform_check_test.dart -d macos
--dart-define=OUT=$PWD/build/platform_check` writes the same without the
driver. A real iPhone needs the app signed for it, as for any run on it.

For checks by hand on a phone, build with
`--dart-define=TEST_ALBUM=test_data_results`: every run then saves into
that one album instead of a new `UWMedia <date>` album, so the test
results sit together and can be deleted at once. A run in a profile build
(`flutter run --profile`) also prints the engine's steps (`uwmedia
engine: ...`) to the terminal, for following an export the phone
interrupted.

Compare two reports (two platforms, or the Flutter app against the
Python app's report of the same machine):

```bash
dart run tool/platform_check/compare.dart build/platform_check/<A>.json build/platform_check/<B>.json
```

It prints identical / within tolerance / known deviation / different /
failed / skipped / missing per check, with the largest differences
(`--all` for every one), then a performance table of the timed runs (A,
B, B / A; times never fail it), and exits 1 on a difference; the tolerances are
in its header and in `REPORT_FORMAT.md`. The Python app wrote the same
report with a script of its own (the prompt that asked for it is
`docs/archive/python-platform-check-prompt.md`).

After changing `cases.json` or the clip, run `dart run
tool/platform_check/embed_pack.dart`: the test carries both in
`pack.g.dart` (so a phone needs nothing else and the app ships neither),
and `test/tool/platform_check_test.dart` fails while they are out of step.
The logs in `cases.json` are the synthetic ones of
`test/fixtures/python_reference/dives/`. `clip.mp4` and `perf_clip.mp4`
are ffmpeg's test pattern and a sine tone, made by the commands in
`cases.json` (no camera, no dates, no metadata beyond the encoder's;
`clip.mp4` is tagged BT.709 as a camera's clip is, so that ffmpeg and the
phones' engines read its colours the same way). The
owner approved both for git (2026-11-15), and `.gitignore` lets exactly
these two through. `pack.g.dart` carries the 2 s clip again as base64;
the perf clip is not built into anything, and the app ships neither.

#### Speed check

`tool/perf_check.sh` guards against slowdowns between releases. It runs
the platform check unattended on this desktop with each timed run done
three times (`WAIT=0`, `PERF_REPEATS=3`), then
`tool/platform_check/perf_gate.dart` holds the medians of the
`engine/perf/` runs (colour, colour + overlay, overlay-only per format)
to this machine's baseline, `tool/platform_check/perf_baselines/<os>-<device>.json`.
A run that takes more than 15 % and more than 150 ms longer is SLOWER,
and a run whose encoder or build mode differs from the baseline's is not
comparable; either fails the check. Faster runs pass.

On a Mac `PERF_ENGINE=native tool/perf_check.sh` times the runner's media
engine in ffmpeg's place, held to a baseline of its own in
`tool/platform_check/perf_baselines/engine/`.

Times mean something only on a quiet machine (an IDE indexing during a
run made the overlay runs two to seven times slower), so the script
refuses to start while the load average is above half the cores (macOS
and Linux; `PERF_IGNORE_LOAD=1` runs anyway). Close IDEs and other test
runs first, the Python app's included.

Times only compare on one machine, so each machine that does releases has
its own baseline, recorded from a passing run with `tool/perf_check.sh
--update` and committed. Recording a slower baseline is the owner's
decision after a slowdown that is accepted; after a speed-up, lowering it
keeps a later slowdown from hiding in the gain. A phone: run the platform
check on it with `--dart-define=PERF_REPEATS=3`, then `dart run
tool/platform_check/perf_gate.dart <report> [--update]`. Simulators and
emulators are not timed.

Against the Python app (macOS, M2, 2026-11-15): colour and colour +
overlay about level, the overlay-only renders 1.5 to 2.6 times faster in
the Flutter app.

## Code rules

- Every writable path comes from `lib/core/app_paths.dart`
  (`userConfigDir()`, `userDataDir()`, `userCacheDir()`, `appTempDir()`);
  never build one elsewhere. They resolve to the platform's standard
  folders (macOS Application Support / Caches, Windows `%APPDATA%` /
  `%LOCALAPPDATA%`, Linux XDG, the sandbox on mobile), never the install
  folder.
- `dart format` and `flutter analyze --fatal-infos` are part of the default
  suite; `analysis_options.yaml` has the project's lint set.
- User-facing changes get a bullet under `## [Unreleased]` in
  `CHANGELOG.md` (Keep a Changelog style: `### Added` / `### Changed` /
  `### Fixed`; each bullet starts with the page or feature it concerns).

### The Mac App Store build

The Mac App Store variant (no ffmpeg, no exiftool, in the App Sandbox) is
built by `tool/build_store.sh`: with nothing set it is signed ad hoc, to
try the sandbox on this Mac. Starting it makes the app's container in your
Library.

## Branches

Development happens on `development`, on the owner's own Git server,
and stays there. `main` holds the releases, one commit each, and is the
branch the public repository has; while the GitHub workflows are being
set up, the temporary branch `move_github` is there too.
