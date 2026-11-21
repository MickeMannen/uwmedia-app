# The tools' release ("deps")

The desktop builds ship ffmpeg, ffprobe and exiftool (spec §13.2).
`tool/fetch_tools.dart` downloads them from a GitHub release of this
repo, `MickeMannen/uwmedia-app`, tagged as `deps_release_tag` in
`assets/licenses/BINARY_MANIFEST.json` (now `deps-2026.09`), and checks
each file against the sha256 written there. Until 2026-11-19 the files
came from the Python app's release of the same tag
(`MickeMannen/UWMedia`); the Python app is no longer maintained, so the
release moves here with the same files, byte for byte.

The release is not made on this repo yet. Until it is, a build fetches from the old place with
`UWMEDIA_DEPS_URL=https://github.com/MickeMannen/UWMedia/releases/download/deps-2026.09`,
or from `build/tools_cache/` when the files are there already.

## Making the release (the owner, once)

The eight files, the same in name and content as the Python release's:

| File | For |
|---|---|
| `ffmpeg-macos-arm64`, `ffprobe-macos-arm64` | macOS |
| `ffmpeg-windows-amd64.exe`, `ffprobe-windows-amd64.exe` | Windows |
| `ffmpeg-linux-amd64`, `ffprobe-linux-amd64` | Linux |
| `exiftool-unix-13.59.tar.gz` | macOS and Linux |
| `exiftool-windows-13.59.zip` | Windows |

1. Download them from the old release into an empty folder:

       mkdir -p /tmp/deps && cd /tmp/deps
       gh release download deps-2026.09 --repo MickeMannen/UWMedia

2. Check every file against the manifest (each line must say OK):

       cd $APP_REPO
       python3 -c 'import json,hashlib,os
       m=json.load(open("assets/licenses/BINARY_MANIFEST.json"))
       for t in ("ffmpeg","exiftool"):
           for os_,e in m[t]["platforms"].items():
               for a,s in ((e["asset"],e["sha256"]),(e.get("ffprobe_asset"),e.get("ffprobe_sha256"))):
                   if a: print(a, "OK" if hashlib.sha256(open("/tmp/deps/"+a,"rb").read()).hexdigest()==s else "WRONG")'

3. Make the release on this repo, as a pre-release so that it is not
   taken for an app release, with the licences beside the files:

       gh release create deps-2026.09 --repo MickeMannen/uwmedia-app \
         --prerelease --title "Bundled tools (deps-2026.09)" \
         --notes "ffmpeg, ffprobe and exiftool for the desktop builds; sha256 in assets/licenses/BINARY_MANIFEST.json. Licences: assets/licenses/." \
         /tmp/deps/* assets/licenses/FFMPEG_LICENSE.txt \
         assets/licenses/EXIFTOOL_LICENSE.txt assets/licenses/GPLV3_LICENSE.txt

4. Try it: `rm -rf build/tools_cache && dart run tool/fetch_tools.dart
   macos build/tools_check` fetches from the new release and checks the
   sums. The repo must be public for the release workflow and other
   machines to download without a token.

## deps-2026.11: our own ffmpeg (to make, the owner)

From this release on, ffmpeg and ffprobe are built by this project
(`tool/ffmpeg/README.md`, owner 2026-11-21) and the release carries
their Corresponding Source:

1. Run the "ffmpeg" workflow (`.github/workflows/ffmpeg.yml`) and
   download its four artifacts.
2. Name the binaries as before (`ffmpeg-macos-arm64`,
   `ffmpeg-windows-amd64.exe`, `ffmpeg-linux-amd64` and the `ffprobe-`
   ones) and make the release `deps-2026.11` with them, the two exiftool
   files of `deps-2026.09`, `ffmpeg-9.0.2-uwmedia-source.tar` and the
   licence files, as in step 3 above.
3. In `assets/licenses/BINARY_MANIFEST.json`: the new sha256, version
   `9.0.2-uwmedia` and source for each ffmpeg and ffprobe,
   `deps_release_tag` and `deps_release_url` to `deps-2026.11`; then
   step 4 above, and a Dev release on Gitea to see the apps start with
   them.

Until then the builds still ship `deps-2026.09`'s ffmpeg, while
`assets/licenses/FFMPEG_LICENSE.txt` already describes the new one; no
release is made from this repo in between.

## A new version of a tool

Make a new tag (`deps-<year>.<month>`) with all eight files (the ones
not changed copied over), write each new file's sha256, version and
source into `BINARY_MANIFEST.json`, set `deps_release_tag` and
`deps_release_url` to the new tag, and check that the HEVC encoders are
there (`ffmpeg -encoders`) as the manifest's `hevc_verified` notes say.
An old tag is never changed: builds of older versions still fetch it.
