#!/bin/bash

# Builds the ffmpeg and ffprobe the desktop apps ship (spec §13.2,
# tool/ffmpeg/README.md): ffmpeg with libx264 and libx265 (8, 10 and 12
# bit), zlib, and the platform's hardware encoders, nothing else, static,
# from the sources pinned in versions.sh. GPL v3 (--enable-gpl
# --enable-version3); tool/ffmpeg/source.sh packs the matching source.
#
# Usage: tool/ffmpeg/build.sh <macos|linux|windows> [out folder]
#   macos   on a Mac (arm64), with Xcode's tools, cmake and pkg-config
#   linux   on x86_64 Linux, tool/ffmpeg/docker.sh linux gives the tools
#   windows cross-built on Linux with mingw-w64, tool/ffmpeg/docker.sh
#           windows gives the tools
# The binaries, their configure line and `ffmpeg -version` go into the out
# folder (default build/ffmpeg/<target>/). JOBS sets make's -j.

set -euo pipefail

target="${1:-}"
case "$target" in
macos | linux | windows) ;;
*)
    echo "usage: tool/ffmpeg/build.sh <macos|linux|windows> [out folder]" >&2
    exit 64
    ;;
esac

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
# shellcheck source=tool/ffmpeg/versions.sh
. "$here/versions.sh"

out="${2:-$repo/build/ffmpeg/$target}"
dl="$repo/build/ffmpeg/dl"
work="$repo/build/ffmpeg/work-$target"
prefix="$work/prefix"
jobs="${JOBS:-$(getconf _NPROCESSORS_ONLN)}"

rm -rf "$work"
mkdir -p "$dl" "$work/src" "$prefix/include" "$prefix/lib/pkgconfig" "$out"

sha256() {
    if command -v sha256sum >/dev/null; then
        sha256sum "$1" | cut -c1-64
    else
        shasum -a 256 "$1" | cut -c1-64
    fi
}

# fetch <url> <sha256> [file name]: into build/ffmpeg/dl/, checked.
fetch() {
    local file="$dl/${3:-$(basename "$1")}"
    if [ ! -f "$file" ]; then
        curl -sSfL --retry 3 -o "$file.part" "$1"
        mv "$file.part" "$file"
    fi
    local got
    got="$(sha256 "$file")"
    if [ "$got" != "$2" ]; then
        echo "$file: sha256 $got, expected $2" >&2
        exit 1
    fi
    echo "$file"
}

# unpack <archive> <name>: into work/src/<name>, its top folder dropped.
unpack() {
    mkdir -p "$work/src/$2"
    tar -xf "$1" -C "$work/src/$2" --strip-components 1
}

unpack "$(fetch "$FFMPEG_URL" "$FFMPEG_SHA256")" ffmpeg
unpack "$(fetch "$X264_URL" "$X264_SHA256")" x264
unpack "$(fetch "$X265_URL" "$X265_SHA256")" x265
if [ "$target" != macos ]; then
    unpack "$(fetch "$ZLIB_URL" "$ZLIB_SHA256")" zlib
fi
if [ "$target" = windows ]; then
    unpack "$(fetch "$NVCODEC_URL" "$NVCODEC_SHA256")" nvcodec
    unpack "$(fetch "$AMF_URL" "$AMF_SHA256")" amf
    unpack "$(fetch "$LIBVPL_URL" "$LIBVPL_SHA256" "$LIBVPL_FILE")" libvpl
fi

export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
unset PKG_CONFIG_PATH
cross=""
cmake_cross=()
case "$target" in
macos)
    export MACOSX_DEPLOYMENT_TARGET=12.0
    host_flags=()
    ;;
linux)
    host_flags=()
    ;;
windows)
    cross=x86_64-w64-mingw32-
    host_flags=(--host=x86_64-w64-mingw32 --cross-prefix="$cross")
    cmake_cross=(
        -DCMAKE_SYSTEM_NAME=Windows
        -DCMAKE_SYSTEM_PROCESSOR=AMD64
        -DCMAKE_C_COMPILER="${cross}gcc"
        -DCMAKE_CXX_COMPILER="${cross}g++"
        -DCMAKE_RC_COMPILER="${cross}windres"
        -DCMAKE_FIND_ROOT_PATH="$prefix"
    )
    ;;
esac

# --- zlib (macOS: the system's) -------------------------------------------
if [ "$target" = linux ]; then
    (cd "$work/src/zlib" && ./configure --static --prefix="$prefix" &&
        make -j"$jobs" install)
elif [ "$target" = windows ]; then
    (cd "$work/src/zlib" &&
        make -f win32/Makefile.gcc PREFIX="$cross" libz.a &&
        cp zlib.h zconf.h "$prefix/include/" && cp libz.a "$prefix/lib/")
fi

# --- x264 (8 and 10 bit in one library) --------------------------------------
(cd "$work/src/x264" &&
    ./configure --prefix="$prefix" ${host_flags[@]+"${host_flags[@]}"} --enable-static \
        --enable-pic --disable-cli --disable-opencl &&
    make -j"$jobs" && make install)

# --- x265 (8 bit with 10 and 12 bit linked in) -----------------------------
x265_build() { # <folder> <cmake options...>
    mkdir -p "$work/x265/$1"
    (cd "$work/x265/$1" &&
        cmake "$work/src/x265/source" ${cmake_cross[@]+"${cmake_cross[@]}"} \
            -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="$prefix" -DENABLE_SHARED=OFF \
            -DENABLE_CLI=OFF "${@:2}" &&
        make -j"$jobs")
}
x265_build 12bit -DHIGH_BIT_DEPTH=ON -DMAIN12=ON -DEXPORT_C_API=OFF
x265_build 10bit -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF
mkdir -p "$work/x265/8bit"
cp "$work/x265/10bit/libx265.a" "$work/x265/8bit/libx265_main10.a"
cp "$work/x265/12bit/libx265.a" "$work/x265/8bit/libx265_main12.a"
x265_build 8bit -DEXTRA_LIB="x265_main10.a;x265_main12.a" \
    -DEXTRA_LINK_FLAGS=-L. -DLINKED_10BIT=ON -DLINKED_12BIT=ON
(cd "$work/x265/8bit" && make install)
(cd "$work/x265/8bit" && mv libx265.a libx265_main.a &&
    if [ "$target" = macos ]; then
        libtool -static -o libx265.a libx265_main.a libx265_main10.a \
            libx265_main12.a
    else
        printf 'CREATE libx265.a\nADDLIB libx265_main.a\nADDLIB libx265_main10.a\nADDLIB libx265_main12.a\nSAVE\nEND\n' |
            "${cross}ar" -M
    fi &&
    cp libx265.a "$prefix/lib/libx265.a")
# The C++ runtime as the static link needs it, not CMake's guess (which
# names libgcc_s, a shared library).
case "$target" in
macos) cxx_libs="-lc++" ;;
linux) cxx_libs="-lstdc++ -lm -lpthread -ldl" ;;
windows) cxx_libs="-lstdc++" ;;
esac
sed -i.bak "s|^Libs.private:.*|Libs.private: $cxx_libs|" \
    "$prefix/lib/pkgconfig/x265.pc"

# --- Windows: NVIDIA, AMD and Intel encoder interfaces ----------------------
if [ "$target" = windows ]; then
    make -C "$work/src/nvcodec" PREFIX="$prefix" install
    cp -R "$work/src/amf/AMF" "$prefix/include/"
    mkdir -p "$work/libvpl"
    (cd "$work/libvpl" &&
        cmake "$work/src/libvpl" ${cmake_cross[@]+"${cmake_cross[@]}"} \
            -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
            -DBUILD_SHARED_LIBS=OFF -DBUILD_TOOLS=OFF -DBUILD_EXAMPLES=OFF \
            -DBUILD_TESTS=OFF -DINSTALL_EXAMPLES=OFF &&
        make -j"$jobs" install)
    # Its static library is C++: the runtime it needs, for the link.
    sed -i.bak 's|^Libs:\(.*\)$|Libs:\1 -lstdc++|' \
        "$prefix/lib/pkgconfig/vpl.pc"
fi

# --- ffmpeg ------------------------------------------------------------------
# `ffmpeg -version` shows the configure line. On a Mac pkg-config alone
# finds the libraries (zlib is the system's), so no folder of the machine
# is in it; Linux and Windows name the prefix, /repo/... in docker.sh's
# container. The prefix is never installed to.
config=(
    --prefix=/opt/uwmedia-ffmpeg
    --pkg-config=pkg-config
    --pkg-config-flags=--static
    --extra-version=uwmedia
    --enable-gpl
    --enable-version3
    --disable-debug
    --disable-doc
    --disable-ffplay
    --disable-autodetect
    --enable-zlib
    --enable-libx264
    --enable-libx265
)
case "$target" in
macos)
    config+=(
        --enable-pthreads
        --enable-videotoolbox
        --enable-audiotoolbox
        --extra-cflags=-mmacosx-version-min=12.0
        --extra-ldflags=-mmacosx-version-min=12.0
    )
    ;;
linux)
    config+=(
        --enable-pthreads
        --extra-cflags="-I$prefix/include"
        --extra-ldflags="-static -L$prefix/lib"
    )
    ;;
windows)
    config+=(
        --target-os=mingw32
        --arch=x86_64
        --cross-prefix="$cross"
        --enable-w32threads
        --enable-d3d11va
        --enable-dxva2
        --enable-ffnvcodec
        --enable-nvenc
        --enable-nvdec
        --enable-cuvid
        --enable-amf
        --enable-libvpl
        --extra-cflags="-I$prefix/include"
        --extra-ldflags="-static -L$prefix/lib"
    )
    ;;
esac
(cd "$work/src/ffmpeg" && ./configure "${config[@]}" &&
    make -j"$jobs")

exe=""
[ "$target" = windows ] && exe=.exe
for tool in ffmpeg ffprobe; do
    cp "$work/src/ffmpeg/$tool$exe" "$out/$tool$exe"
    "${cross}strip" "$out/$tool$exe" 2>/dev/null || strip "$out/$tool$exe"
done
printf '%s\n' "${config[@]}" >"$out/configure.txt"
{
    echo "ffmpeg $FFMPEG_VERSION, x264 $X264_COMMIT, x265 $X265_VERSION"
    echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ) by tool/ffmpeg/build.sh $target"
} >"$out/build.txt"
echo "Built $out/ffmpeg$exe and $out/ffprobe$exe."
