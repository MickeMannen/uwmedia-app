---
name: test
description: Run the UWMedia app's test levels (default, quick, release, everything) the way CONTRIBUTING.md defines them, and report the outcome. Use before calling work done, before a release, or when asked to "run the tests".
---

# Running the tests

The runner is `tool/run_tests.sh`. Always pass it a number; without one it
asks on a terminal you do not have.

| Choice | What runs | When |
|---|---|---|
| `1` | `dart format` check, `flutter analyze --fatal-infos`, `flutter test --exclude-tags "golden,release"` | before saying work is done (the pre-commit hook runs this too) |
| `2` | as 1, tests also exclude `render` | while iterating |
| `3` | `flutter test --tags release` | the pre-release media checks only |
| `4` | 1 + `release` + `golden` | before a release; needs `test_data/` or `UWMEDIA_TEST_DATA` |

Single targets: `flutter test test/<file>_test.dart`, `--plain-name
"<test name>"`, `-j1` for serial runs.

Steps:
1. Run the level asked for (default `1`) through the `test-runner` agent,
   every level: it runs on a small model and keeps the output out of your
   context. Run a command yourself only for a single test while debugging.
2. Read the result as it is. A failing test is reported with its name,
   file and the assertion text; a skipped `requires_media` test is reported
   as skipped, not as passing.
3. Never make a run green by weakening it: no `skip`, no loosened
   tolerance, no regenerated golden, no deleted assertion. If a golden
   changed on purpose, look at the new render, say what changed, and only
   then regenerate with `flutter test --tags golden --update-goldens`.
4. If `flutter analyze` reports an info-level lint, fix the code, not the
   lint set, unless the rule is wrong for the whole project (then change
   `analysis_options.yaml` and say so).
5. Report: command, exit code, totals, failures verbatim, skips.
