# The sources of the ffmpeg and ffprobe the desktop builds ship (spec
# §13.2, tool/ffmpeg/README.md): each one pinned by its file's sha256.
# A new version is a change here, a new build, and a new deps release.
# shellcheck shell=bash disable=SC2034

FFMPEG_VERSION=9.0.2
FFMPEG_URL=https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e

# x264 has no release tarballs: the stable branch's head, as VideoLAN's
# GitLab packs it.
X264_COMMIT=b35605ace3ddf7c1a5d67a2eb553f034aef41d55
X264_URL=https://code.videolan.org/videolan/x264/-/archive/$X264_COMMIT/x264-$X264_COMMIT.tar.bz2
X264_SHA256=6eeb82934e69fd51e043bd8c5b0d152839638d1ce7aa4eea65a3fedcf83ff224

X265_VERSION=4.3
X265_URL=https://github.com/Multicorewareinc/x265/releases/download/4.3/x265_4.3.tar.gz
X265_SHA256=83c53e4c8bbb8f1e33ed59e10a7d621d1d7801ca853910c3eb41f038b8ffb121

ZLIB_URL=https://zlib.net/fossils/zlib-1.3.1.tar.gz
ZLIB_SHA256=9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23

# Windows' hardware encoders. NVIDIA's headers 12.1 need a driver of
# 531 or later (2023); 13.x would need a newer one.
NVCODEC_URL=https://github.com/FFmpeg/nv-codec-headers/releases/download/n12.1.14.1/nv-codec-headers-12.1.14.1.tar.gz
NVCODEC_SHA256=043e46265517855f13bcb98b3a225b2761b2a83983b1645fa1d05876f1c3a781
AMF_URL=https://github.com/GPUOpen-LibrariesAndSDKs/AMF/releases/download/v1.5.3/AMF-headers-v1.5.3.tar.gz
AMF_SHA256=0f521ad98041f8001147cded4a660127f18b1c27a801a5cd691bda1fa48381be
LIBVPL_URL=https://github.com/intel/libvpl/archive/refs/tags/v2.17.0.tar.gz
LIBVPL_FILE=libvpl-2.17.0.tar.gz
LIBVPL_SHA256=4de3e2faf1e8307fb282e4a43f443191810f6a6b0a484fffa7995ba1c814c6ec

# Every archive as "url sha256 file", for tool/ffmpeg/source.sh.
SOURCES=(
    "$FFMPEG_URL $FFMPEG_SHA256 $(basename "$FFMPEG_URL")"
    "$X264_URL $X264_SHA256 $(basename "$X264_URL")"
    "$X265_URL $X265_SHA256 $(basename "$X265_URL")"
    "$ZLIB_URL $ZLIB_SHA256 $(basename "$ZLIB_URL")"
    "$NVCODEC_URL $NVCODEC_SHA256 $(basename "$NVCODEC_URL")"
    "$AMF_URL $AMF_SHA256 $(basename "$AMF_URL")"
    "$LIBVPL_URL $LIBVPL_SHA256 $LIBVPL_FILE"
)
