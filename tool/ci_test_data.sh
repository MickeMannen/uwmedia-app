#!/bin/bash

# For the Gitea runners: points the tests at the private test data, which
# is on a read-only SMB share on the LAN (tool/test_data_sync.sh keeps it
# the same as the development machine's test_data/). Never in git.
#
# Usage: tool/ci_test_data.sh [release]
#   release: the full-size media of the release tests too (the nightly
#   run); only the Linux job, which copies the data, makes a difference.
#
# TEST_DATA_SHARE (//host/share) and TEST_DATA_USER come from the repo's
# Actions variables, TEST_DATA_PASSWORD from its secret of that name.
# Without them nothing is done and the tests that need the data skip
# themselves, as on a fresh clone.
#
# macOS: the share is mounted (once; it stays) and read where it is.
# Linux: the job's container may not mount, so the data is copied into it
# with smbclient. Windows: the workflow connects the share itself.

set -euo pipefail

release="${1:-}"
share="${TEST_DATA_SHARE:-}"
user="${TEST_DATA_USER:-}"

if [ -z "${TEST_DATA_PASSWORD:-}" ] || [ -z "$share" ] || [ -z "$user" ]; then
    echo "No TEST_DATA_SHARE, TEST_DATA_USER or TEST_DATA_PASSWORD: the tests that need the data will skip."
    exit 0
fi

case "$(uname -s)" in
Darwin)
    dest="${TEST_DATA_MOUNT:-$HOME/.cache/uwmedia_test_data_share}"
    if ! mount | grep -qF " on $dest ("; then
        mkdir -p "$dest"
        # Never asking, and given up after half a minute: a question on a
        # screen nobody sees (macOS's "allow local network access" the
        # first time) would hold the job for good.
        if ! perl -e 'alarm 30; exec @ARGV' mount_smbfs -N -o rdonly \
            "//$user:$TEST_DATA_PASSWORD@${share#//}" "$dest"; then
            echo "Could not mount $share (is the runner allowed on the local network?)." >&2
            exit 1
        fi
    fi
    ;;
Linux)
    dest="${RUNNER_TEMP:-/tmp}/uwmedia_test_data"
    rm -rf "$dest"
    mkdir -p "$dest"
    tar_args=(-TcX - release_test)
    if [ "$release" = release ]; then
        tar_args=(-Tc -)
    fi
    # tar stops at the archive's end; cat takes what smbclient pads it with.
    (cd "$dest" && smbclient "$share" -U "$user%$TEST_DATA_PASSWORD" \
        "${tar_args[@]}" 2>/dev/null | {
        tar -x 2>/dev/null
        cat >/dev/null
    }) || true
    ;;
*)
    echo "Not a system this script connects the share on: $(uname -s)" >&2
    exit 1
    ;;
esac

if [ -z "$(ls -A "$dest" 2>/dev/null)" ]; then
    echo "The share $share gave nothing (wrong password, or the server is down)." >&2
    exit 1
fi
echo "Test data: $dest"
if [ -n "${GITHUB_ENV:-}" ]; then
    echo "UWMEDIA_TEST_DATA=$dest" >>"$GITHUB_ENV"
fi
