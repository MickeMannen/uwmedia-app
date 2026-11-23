#!/bin/bash
# Puts the ffmpeg, ffprobe and exiftool the desktop apps ship with first
# on the PATH, so that a test or a timed run on a desktop uses the tools
# a user gets and not Homebrew's, a distribution's or another build's
# (owner, 2026-11-23). Sourced by tool/run_tests.sh and
# tool/perf_check.sh from the repo's top folder:
#
#   . tool/own_tools.sh
#
# The tools are this repo's deps release (tool/fetch_tools.dart, each file
# checked against its sha256), kept in build/own_tools; the downloads stay
# in build/tools_cache, so only the first run fetches. When they cannot be
# fetched (no network and nothing kept) it says so and the PATH stays as
# it is. UWMEDIA_SYSTEM_TOOLS=1 leaves the PATH alone on purpose.
if [ "${UWMEDIA_SYSTEM_TOOLS:-0}" != 1 ]; then
    case "$(uname -s)" in
        Darwin) own_os=macos ;;
        Linux) own_os=linux ;;
        MINGW* | MSYS* | CYGWIN*) own_os=windows ;;
        *) own_os= ;;
    esac
    if [ -n "$own_os" ]; then
        own_dir="$PWD/build/own_tools"
        if dart run tool/fetch_tools.dart "$own_os" "$own_dir" >/dev/null; then
            PATH="$own_dir:$PATH"
            export PATH
            echo "The app's own tools first on the PATH: $("$own_dir/ffmpeg" -version 2>/dev/null | head -1 | cut -c1-60)"
        else
            echo "WARNING: the app's own ffmpeg, ffprobe and exiftool could not be fetched;"
            echo "         the tests run the tools the PATH has."
        fi
    fi
    unset own_os own_dir
fi
