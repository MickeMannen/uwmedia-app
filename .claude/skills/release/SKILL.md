---
name: release
model: sonnet
description: The owner's "prepare a release" workflow for the UWMedia app - pick the version and the target (Gitea or GitHub, never both by default), turn the Unreleased changelog section into release notes, bump pubspec.yaml, make the release commit and tag, push to the named remote, write the short release notes. Use only when the owner asks to prepare a release.
---

# Prepare a release

Run only when the owner asks ("prepare a release", "prepare for release
0.1.1 on GitHub"). The work is checked and the release prepared on
`development`; `main` then gets the release as one commit (AGENTS.md,
Git: `main` has a history of its own and nothing is merged between the
two). Stop before anything the owner did not ask for.

**The target.** A release goes to one remote, the one the owner names:
`gitea` (the owner's server, for releases kept in-house) or `github`
(the public repo). Never both unless the owner says both. When the
request does not name one, ask before step 1. Gitea's "Dev release" builds of `development` are not releases and
are not made here.

Refuse and say why if any of these holds: the tree is dirty; the
Everything suite (`tool/run_tests.sh 4`) has not passed in this session;
the speed check (`tool/perf_check.sh`, on this desktop) has not passed in
this session; the version already exists as a tag (`git tag --list 'v*'`,
and `git ls-remote --tags <target>`); the branch is not `development`.

The speed check holds the platform check's timed runs (colour, colour +
overlay, overlay-only per format, on the 20 s perf clip) to this
machine's baseline in `tool/platform_check/perf_baselines/`. When it
reports a run SLOWER, stop and show the owner its table; only the owner
decides that a slowdown is accepted, and then `tool/perf_check.sh
--update` records the new times (a commit of its own, before the release
commit). A machine without a baseline gets one the same way, on the
owner's word. When it reports a run faster, say so; lowering the baseline
is again the owner's call.

For the releases of v0.1.0 (desktop, then the phones) the speed work is
moved to v0.2.0, section G (owner, 2026-11-21): run the speed check and
report its table, but a slower run does not stop the release, and the
baseline is not changed. From v0.2.0 on the rule above holds again.

1. **Pick the version**: the one the owner named, else the next patch
   after the newest tag (`git tag --sort=-v:refname | head -1`). Say
   which one you chose, and the target.
2. **Changelog and version**: rename `## [Unreleased]` in `CHANGELOG.md`
   to `## [<version>] - <today, YYYY-MM-DD>` and tidy the bullets into
   release notes without adding anything that is not in the tree. In
   `pubspec.yaml` set `version: <version>+<build>` where build is the
   previous build number plus one. Show the changelog section to the
   owner before going on.
3. **On `development`**: commit those two files with the message
   `Release <version>` and push it: `git push gitea development`.
4. **On `main`**: one commit whose tree is `development`'s, then the tag,
   then the push to the target only. These are the commits the no-commit
   rule allows for a release.
   - A later release:
     ```
     git checkout main
     git read-tree -u --reset development
     git commit -m "UWMedia <version>"
     git tag v<version>
     git push <target> main v<version>
     git checkout development
     ```
   - The first release (2026-11): `main` still holds the old scaffold
     commit and is started again, with no parent:
     ```
     git checkout --orphan release-root development
     git commit -m "UWMedia <version>"
     git branch -f main release-root && git checkout main && git branch -D release-root
     git tag v<version>
     ```
     Pushing it replaces the old `main` on Gitea (a force push,
     `git push --force gitea main v<version>`): say so and push only on
     the owner's word. On GitHub, `main` is new.
   - When the second remote gets the same release later, push the same
     `main` and tag there; both remotes always hold the same `main`.
5. **Release notes**: a brief overview, not the changelog: one sentence
   on what the release is about, then at most 8 bullets for what a user
   notices most, most noticeable first, one short line each, no headings,
   sub-bullets or implementation detail. End with
   `Full notes: <repo URL>/blob/v<version>/CHANGELOG.md` (GitHub) or
   `<repo URL>/src/tag/v<version>/CHANGELOG.md` (Gitea). Write the notes
   file in the session scratchpad.
   - **GitHub:**
     ```
     gh release create v<version> --title "UWMedia <version>" --notes-file <scratchpad>/notes.md --repo MickeMannen/uwmedia-app
     ```
   - **Gitea:** the owner creates the release from the tag in Gitea's web
     page (Releases, New release) with the notes file's text, unless they
     gave a token for this session; never make a token.
6. **Report the release URL (or the notes file) and stop.** The builds
   are the owner's to start. GitHub: the "Release Build" workflow from the
   tag (Actions, "Run workflow", "Use workflow from" set to the tag,
   "Attach to the GitHub Release" checked). Claude does not trigger it.
