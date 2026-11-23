# Rules for the Claude agent

`AGENTS.md` below holds the rules shared by every coding agent (files and data, git, tests, changelog); tests and test data are described in `CONTRIBUTING.md`, and `docs/README.md` lists the documents. What this file adds for Claude:

- **Writes outside the repo:** reading outside it is fine (the Python source, its `test_data/`, real media to look at); the rule is about writes and deletes, and `.claude/settings.json` denies edits under the Python repo for that reason. For live or manual testing use `test/fixtures/`, a synthetic log written at run time, or the session scratchpad. If a test genuinely needs app state outside the repo, stop and ask first instead of doing it and reverting afterward. One folder outside the repo may be written (owner, 2026-11-21): the website's images of this app, `~/development/app_web/src/assets/uwmedia/` (screenshots made here for the site, allowed in `.claude/settings.json`); nothing else in `app_web`.
- **Commits:** editing, staging and describing changes is fine; the commit itself is the owner's. Standing permission (owner, 2026-11-12): on the `v0.1` branch, commit after a round of work once the default suite passes, and push the branch to `gitea`. Everything else (`main`, tags, `move_github`, GitHub, releases) still needs the owner's word each time. Push with exactly `git push gitea v0.1`, with no option before the remote (no `-q`, no `-u`): that form is allowed without a prompt in `.claude/settings.json`, while `git push -…` and every other push is set to ask there.
- **Remotes:** `gitea` (the owner's server; `git remote get-url gitea`, and `docs/local-ci.private.md` on the owner's Mac) and `github` (https://github.com/MickeMannen/uwmedia-app.git, also `origin`). A push or a release goes to the one the owner names, never to both by default (AGENTS.md, Git). The GitHub hold is lifted (owner, 2026-11-21); each push there still needs the owner's word.
- **Test data:** `test_data/` in this repo is a local copy of what the tests need from the Python repo's `test_data/` (the owner's private media and dive logs). It is git-ignored and never committed; copy more over when a test needs it, never the other way.

@AGENTS.md

# What this repo is

UWMedia for Windows, macOS, Linux, iPhone and Android, in Flutter. It follows the Python/Qt desktop app of the same name (`~/development/uwmedia`, GitHub `MickeMannen/UWMedia`), which is no longer maintained. The desktop keeps every feature by running the bundled ffmpeg and exiftool as subprocesses (or, on a Mac, the system's own media engine); the phones get the subset decided in the spec, on their own media engines.

- **`docs/spec.md` is the design record and the spec.** Its sections are the contract: §0 product scope and the desktop/mobile split, §4 the dive data model whose field names stay verbatim in Dart, §5 the overlay template schema and renderer behaviour, §6 the colour engine maths, §10 the deliberate differences from the Python app and the decisions since, §11 and §12 open items, §13 the app identity and the install, config, data and cache paths per platform. Read the relevant section before changing a feature, and update the spec when a decision changes it.
- **The spec is the contract; the Python code is background.** When the two disagree, the spec and this app's own tests decide, and a doubt goes to the owner (2026-11-19). The Python repo stays a read-only reference for how something was done (the `python-reference` agent reads it; the `port-reviewer` agent and the `/port-module` skill are for a module that is still brought over, such as the FIT `hr` merge of spec §10.18). The fixtures and golden images made from it (`test/fixtures/python_reference/`) are this project's own and kept as they are; `docs/archive/python-sync.md` is the closed record of following it.

# Code rules

- Pure logic first, no I/O in it: parsers, deco engine, rules engine, renderer geometry and the colour maths are plain Dart with no `dart:io`, `dart:ui` platform calls or plugins inside, so they run in `dart test` on every platform. Media engines, file pickers and process handling sit behind interfaces with one desktop and one mobile implementation.
- Model names, field names, defaults and units stay as in spec §4 (metres, °C, bar, seconds, naive local timestamps). A missing value is `null`, never `0` or `1.2` (spec §10.8). Naive timestamps are UTC-flagged `DateTime` values built and parsed only through `lib/core/util/naive_time.dart` (never `DateTime.now()`, `DateTime(...)`, `toLocal()` or `toUtc()` on them); where Python used `round()`, use `lib/core/util/py_round.dart` (half to even).
- Paths: `lib/core/app_paths.dart` wraps `path_provider`; read spec §13 before changing it.
- Processes: kill the whole tree on Stop (`taskkill /T /F` on Windows), never `pkill` (spec §10.2). Probe encoders instead of assuming NVENC on Windows (§10.1).
- Platform split: desktop-only pages and engines are behind a capability check, not `Platform.isX` scattered through widgets.
- Formatting and lints: `dart format` and `flutter analyze --fatal-infos` with `analysis_options.yaml` must pass; a hook formats every Dart file you edit.

# Changelog and releases

After every round of work (before the round is called done): add the round's user-facing changes as bullets under `## [Unreleased]` at the top of `CHANGELOG.md` (Keep a Changelog: `### Added` / `### Changed` / `### Fixed` subsections; each bullet leads with the page, feature or platform it concerns, e.g. "Color:", "Tag Editor:", "Android:"): what a user notices and why it matters, one to three lines each, no implementation detail, no bullet for docs-only or internal changes. Create the section or subsection if it is missing.

Releases are the owner's workflow: only when the owner says "prepare a release" (or "prepare for release 0.1.1"), follow the `/release` skill; an agent working for any other contributor skips it. The owner names where the release goes, Gitea or GitHub; when that is not said, ask. The version in `pubspec.yaml` is bumped in the release commit and nowhere else. The internal builds of `v0.1` (Gitea's "Dev release" workflow) are not releases and have no version.
