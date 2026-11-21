#!/bin/bash

# Packs the Corresponding Source of the ffmpeg builds (GPL v3 §6): every
# source archive build.sh uses, unchanged, and the build scripts
# themselves, into build/ffmpeg/ffmpeg-<version>-uwmedia-source.tar. It
# goes onto the deps release beside the binaries (tool/DEPS_RELEASE.md).
#
# Usage: tool/ffmpeg/source.sh

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
# shellcheck source=tool/ffmpeg/versions.sh
. "$here/versions.sh"

name="ffmpeg-$FFMPEG_VERSION-uwmedia-source"
stage="$repo/build/ffmpeg/$name"
rm -rf "$stage"
mkdir -p "$stage/sources" "$stage/scripts"

# Each archive from build/ffmpeg/dl/ (downloaded when missing), checked.
mkdir -p "$repo/build/ffmpeg/dl"
for entry in "${SOURCES[@]}"; do
    read -r url sum file <<<"$entry"
    dest="$repo/build/ffmpeg/dl/$file"
    [ -f "$dest" ] || curl -sSfL --retry 3 -o "$dest" "$url"
    got="$( (command -v sha256sum >/dev/null && sha256sum "$dest") ||
        shasum -a 256 "$dest")"
    if [ "${got:0:64}" != "$sum" ]; then
        echo "$dest: wrong sha256" >&2
        exit 1
    fi
    cp "$dest" "$stage/sources/"
done
cp "$here"/*.sh "$here/README.md" "$stage/scripts/"

cat >"$stage/README.txt" <<EOF
The Corresponding Source of the ffmpeg and ffprobe programs shipped with
UWMedia's desktop builds (GNU General Public License version 3).

sources/  the unmodified source archives, as downloaded; their sha256 is
          in scripts/versions.sh
scripts/  the scripts that built the programs from them:
          build.sh <macos|linux|windows>, docker.sh for Linux and Windows

To build again: put scripts/ at tool/ffmpeg/ of a folder, the archives
in build/ffmpeg/dl/ beside it, and run tool/ffmpeg/build.sh <target>.

UWMedia: https://github.com/MickeMannen/uwmedia-app
EOF

(cd "$repo/build/ffmpeg" && tar -cf "$name.tar" "$name")
rm -rf "$stage"
echo "Wrote build/ffmpeg/$name.tar ($(du -h "$repo/build/ffmpeg/$name.tar" | cut -f1))."
