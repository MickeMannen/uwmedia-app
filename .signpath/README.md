# Code signing with SignPath

**Not in use.** SignPath Foundation declined the project's application on
2026-11-22 (too little public visibility yet; a new application is
welcome later). The Windows downloads are unsigned, the workflow's
SignPath steps are switched off, and the README's signing policy says
so. What follows is kept for a later application.

The Windows releases are signed through SignPath Foundation (the README's
"Code signing policy"; roadmap E12). These files are the project's record
of what is signed; SignPath keeps its own copy of each configuration,
pasted in its web app, and the two are kept the same.

## Artifact configurations

| SignPath slug | File | Signs |
|---|---|---|
| `uwmedia-app` | `artifact-configurations/uwmedia-app.xml` | `uwmedia.exe`, the plugins' `*_plugin.dll` and `dartjni.dll` |
| `uwmedia-installer` | `artifact-configurations/uwmedia-installer.xml` | the installer, `UWMedia-windows-x64-<version>-setup.exe` |

Never signed: `flutter_windows.dll` (the Flutter project's), ffmpeg,
ffprobe and exiftool (third parties'; the release workflow adds them only
after the first request, so they are not in it).

## A release, on Windows (`.github/workflows/build.yml`)

1. `flutter build windows`, then the `Release` folder uploaded as an
   artifact, without the tools.
2. First signing request: artifact configuration `uwmedia-app`, signing
   policy `release-signing`. The owner approves it in SignPath.
3. The signed files downloaded over the unsigned ones; ffmpeg, ffprobe
   and exiftool added (`tool/bundle_tools.sh`); the installer built from
   the result (`windows/installer/uwmedia.iss`) and uploaded.
4. Second signing request: artifact configuration `uwmedia-installer`.
   The owner approves it; the signed installer is the release's download.

The workflow needs the repository secret `SIGNPATH_API_TOKEN` (a SignPath
CI user's token) and the variable `SIGNPATH_ORGANIZATION_ID`; the project
slug is `uwmedia`.

The steps are in the workflow since 2026-11-21 ("Sign the Windows build",
off by default until SignPath has approved the project;
`signpath/github-action-submit-signing-request@v3`), not yet run. Each request waits two hours at most for its approval. The
unsigned files are uploaded as the workflow artifacts
`unsigned-windows-app` and `unsigned-windows-installer` (SignPath takes
its input from there); they are kept a day and are not attached to the
release. After each request the workflow checks that the files came back
with a valid signature.

## When a file is added

A new plugin's DLL is signed without a change here (`*_plugin.dll`). A
new kind of executable of our own needs a line in `uwmedia-app.xml`, the
same change pasted into SignPath, and the README's policy brought up to
date if it changes what is signed.
