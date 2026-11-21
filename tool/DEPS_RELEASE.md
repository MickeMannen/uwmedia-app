# The tools' release ("deps")

The desktop builds ship ffmpeg, ffprobe and exiftool (spec §13.2).
`tool/fetch_tools.dart` downloads them from a GitHub release of this
repo, `MickeMannen/uwmedia-app`, tagged as `deps_release_tag` in
`assets/licenses/BINARY_MANIFEST.json`, and checks each file against the
sha256 written there. `UWMEDIA_DEPS_URL` names another place to download
from, and `build/tools_cache/` keeps what was downloaded.

## deps-2026.11 (now)

https://github.com/MickeMannen/uwmedia-app/releases/tag/deps-2026.11,
made 2026-11-21, a pre-release so that it is not taken for an app
release:

| File | For |
|---|---|
| `ffmpeg-macos-arm64`, `ffprobe-macos-arm64` | macOS |
| `ffmpeg-windows-amd64.exe`, `ffprobe-windows-amd64.exe` | Windows |
| `ffmpeg-linux-amd64`, `ffprobe-linux-amd64` | Linux |
| `ffmpeg-9.0.2-uwmedia-source.tar` | the Corresponding Source of the six above |
| `exiftool-unix-13.59.tar.gz` | macOS and Linux |
| `exiftool-windows-13.59.zip` | Windows |
| `FFMPEG_LICENSE.txt`, `EXIFTOOL_LICENSE.txt`, `GPLV3_LICENSE.txt` | the licences |

ffmpeg and ffprobe 9.0.2 are built by this project (`tool/ffmpeg/`),
from the "ffmpeg" workflow's run 44853071427; the exiftool packages are
upstream's, unchanged, as in the earlier `deps-2026.09` (the Python app's
release, `MickeMannen/UWMedia`).

## A new release

A new tag every time (`deps-<year>.<month>`); an old tag is never
changed, as builds of older versions still fetch it.

1. **ffmpeg** (only when a newer one brings a feature the app wants,
   `tool/ffmpeg/README.md`): change `tool/ffmpeg/versions.sh`, run the
   "ffmpeg" workflow (`.github/workflows/ffmpeg.yml`), check its builds,
   and download its four artifacts. Name the binaries as in the table.
2. **exiftool**: the new upstream packages from https://exiftool.org/,
   named as in the table with the new version.
3. Files not changed are copied over from the release before. Make the
   release with all of them and the licence files:

       gh release create deps-<tag> --repo MickeMannen/uwmedia-app \
         --target main --prerelease --title "Bundled tools (deps-<tag>)" \
         --notes-file <notes> <files> assets/licenses/FFMPEG_LICENSE.txt \
         assets/licenses/EXIFTOOL_LICENSE.txt assets/licenses/GPLV3_LICENSE.txt

4. In `BINARY_MANIFEST.json`: each changed file's sha256, version and
   source, and `deps_release_tag` and `deps_release_url`. If ffmpeg
   changed, `assets/licenses/FFMPEG_LICENSE.txt` names the new version and
   source file.
5. Try it: `rm -rf build/tools_cache && dart run tool/fetch_tools.dart
   macos build/tools_check` fetches from the new release and checks the
   sums; then a Dev release on Gitea to see the apps start with them.
