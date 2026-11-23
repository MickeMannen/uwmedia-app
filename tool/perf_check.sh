#!/bin/bash
# The release speed check on this desktop: the platform check run
# unattended with each timed run done three times, then its times held to
# this machine's baseline (tool/platform_check/perf_gate.dart).
#
# Usage: tool/perf_check.sh [--update]
#   --update  record this run's times as the machine's baseline instead
#
# On a Mac, PERF_ENGINE=native times the runner's media engine in ffmpeg's
# place (docs/design/macos-remove-ffmpeg.md step 8), held to a baseline of its own in
# tool/platform_check/perf_baselines/engine/.
#
# A phone: run the platform check on it (CONTRIBUTING.md, "Platform check")
# with --dart-define=PERF_REPEATS=3, then
# dart run tool/platform_check/perf_gate.dart <its report>.
set -euo pipefail
cd "$(dirname "$0")/.."

case "$(uname -s)" in
    Darwin) device=macos ;;
    Linux) device=linux ;;
    MINGW*|MSYS*|CYGWIN*) device=windows ;;
    *) echo "Unknown desktop: $(uname -s)"; exit 2 ;;
esac

# Times only mean something on a quiet machine: an IDE indexing or another
# test run makes the overlay runs two to seven times slower (2026-11-15,
# load 7.9 on 8 cores). PERF_IGNORE_LOAD=1 runs anyway.
if [ "$device" != windows ] && [ "${PERF_IGNORE_LOAD:-0}" != 1 ]; then
    if [ "$device" = macos ]; then
        cores=$(sysctl -n hw.ncpu)
        load=$(sysctl -n vm.loadavg | awk '{print $2}')
    else
        cores=$(nproc)
        load=$(awk '{print $1}' /proc/loadavg)
    fi
    if awk -v l="$load" -v c="$cores" 'BEGIN { exit !(l > c / 2) }'; then
        echo "The machine is busy (load $load on $cores cores; at most $((cores / 2)) for a timed run)."
        echo "Close what is using it (IDEs, other test runs) and try again, or set PERF_IGNORE_LOAD=1."
        exit 1
    fi
fi

# Timed with the ffmpeg the apps ship with, not the system's.
. tool/own_tools.sh

marker=$(mktemp)
trap 'rm -f "$marker"' EXIT
engine_args=()
gate_args=()
if [ "${PERF_ENGINE:-}" = native ]; then
    if [ "$device" != macos ]; then
        echo "PERF_ENGINE=native is a Mac's."
        exit 2
    fi
    engine_args=(--dart-define=ENGINE=native)
    gate_args=(--baselines tool/platform_check/perf_baselines/engine)
fi
flutter drive --driver=test_driver/integration_test.dart \
    --target=integration_test/platform_check_test.dart -d "$device" \
    --dart-define=WAIT=0 --dart-define=PERF_REPEATS=3 \
    ${engine_args[@]+"${engine_args[@]}"}

report=$(find build/platform_check -maxdepth 1 -name "$device-*.json" -newer "$marker" | sort | tail -1)
if [ -z "$report" ]; then
    echo "The run wrote no report."
    exit 1
fi
echo "Report: $report"
dart run tool/platform_check/perf_gate.dart "$report" \
    ${gate_args[@]+"${gate_args[@]}"} "$@"
