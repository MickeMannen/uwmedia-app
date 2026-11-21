#!/bin/bash

# Runs tool/ffmpeg/build.sh for Linux or Windows in a Debian container with
# the tools it needs (Windows: cross-built with mingw-w64), on any machine
# with Docker. The repo is mounted, so the binaries land in
# build/ffmpeg/<target>/ as with build.sh itself.
#
# Usage: tool/ffmpeg/docker.sh <linux|windows>
#   The Linux build is x86_64 and is made on an x86_64 machine (elsewhere
#   Docker emulates one, which is slow). JOBS sets make's -j.

set -euo pipefail

target="${1:-}"
case "$target" in
linux) packages="build-essential cmake nasm pkg-config" platform=linux/amd64 ;;
windows) packages="gcc libc6-dev make cmake nasm pkg-config gcc-mingw-w64-x86-64-posix g++-mingw-w64-x86-64-posix binutils-mingw-w64-x86-64" platform="" ;;
*)
    echo "usage: tool/ffmpeg/docker.sh <linux|windows>" >&2
    exit 64
    ;;
esac

repo="$(cd "$(dirname "$0")/../.." && pwd)"
image=debian:bookworm-20251117

# The Windows tools posix-threaded (libvpl needs std::thread), and the
# files handed back to the user who runs this.
docker run --rm ${platform:+--platform "$platform"} \
    -v "$repo:/repo" -w /repo -e JOBS="${JOBS:-}" "$image" bash -c "
    set -e
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        ca-certificates curl git xz-utils bzip2 $packages >/dev/null
    if [ $target = windows ]; then
        update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-posix
        update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix
    fi
    status=0
    tool/ffmpeg/build.sh $target || status=\$?
    chown -R $(id -u):$(id -g) build/ffmpeg/dl build/ffmpeg/$target build/ffmpeg/work-$target
    exit \$status
"
