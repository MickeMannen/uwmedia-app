# ffmpeg for the desktop builds

The desktop apps ship ffmpeg and ffprobe (spec §13.2). They are built
here, by this project, so that the exact source of every binary can be
published beside it, as the GNU GPL asks (owner, 2026-11-21). A user who
wants another ffmpeg can use their own: the app takes the machine's when
none is shipped (`lib/engine/desktop/tool_finder.dart`).

What is in them, and nothing more: ffmpeg's own codecs and filters,
libx264 and libx265 (8, 10 and 12 bit), zlib (PNG), and each platform's
hardware encoders and decoders (the app's `ffmpeg_commands.dart` asks for
them):

| | Hardware | Built on |
|---|---|---|
| macOS (arm64) | VideoToolbox, AudioToolbox | a Mac, macOS 12 or later to run |
| Windows (x64) | NVENC/NVDEC (driver 531 or later), AMF, Quick Sync (libvpl), D3D11VA, DXVA2 | Linux, cross-built with mingw-w64 |
| Linux (x64) | none (software only) | Linux; fully static, any distribution |

Licence: GPL version 3 or later (`--enable-gpl --enable-version3`, for
libx264 and libx265).

## Files

- `versions.sh`: every source archive, pinned by its sha256.
- `build.sh <macos|linux|windows>`: downloads and checks the archives
  into `build/ffmpeg/dl/`, builds into `build/ffmpeg/<target>/`
  (`ffmpeg`, `ffprobe`, `configure.txt`, `build.txt`).
- `docker.sh <linux|windows>`: `build.sh` in a Debian container with the
  tools (the Linux build on an x86_64 machine).
- `source.sh`: packs the archives and these scripts into
  `build/ffmpeg/ffmpeg-<version>-uwmedia-source.tar`, the Corresponding
  Source, for the deps release.
- `.github/workflows/ffmpeg.yml`: all three builds and the source on
  GitHub's runners, by hand.

## Versions

FFmpeg 9.0.2 (2026-09), and it stays there until a newer one brings a
feature the app wants (owner, 2026-11-21): a new version is not taken
for its own sake. 9.1 came out on 2026-11-20 and was tried the
next day: with it, the watermark run of
`test/engine/desktop/color_batch_test.dart` ("a folder, again with skip,
a single file, a copy, Stop") smears the picture right of the mark
(a pixel 14 px away off by 52 levels where 9.0.2 stays within 4), with
the same x264 and x265. Not yet looked into; 9.1 waits until it is.

## A new ffmpeg

Change `versions.sh` (the new archive's URL and sha256), build all
three, check them (`ffmpeg -version`, `ffmpeg -encoders | grep -E
'x26[45]|nvenc|amf|qsv|videotoolbox'`, the default suite and the
platform check on each system), then make a new deps release with the
binaries and the source (`tool/DEPS_RELEASE.md`).
