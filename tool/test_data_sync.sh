#!/bin/bash

# Makes the Gitea runners' test data the same as this machine's
# test_data/: the folder is copied (rsync over ssh, changed files only) to
# the server that shares it read-only on the owner's network
# (docs/local-ci.md). The pre-push hook runs this before a push to gitea.
# The data goes nowhere else.
#
# Usage: tool/test_data_sync.sh
#   TEST_DATA_HOST: the ssh host (as ~/.ssh/config has it), from the
#   environment or from tool/local.env (git-ignored, one line
#   TEST_DATA_HOST=<host>). Without it nothing is copied.

set -euo pipefail

cd "$(dirname "$0")/.."
if [ -z "${TEST_DATA_HOST:-}" ] && [ -f tool/local.env ]; then
    # shellcheck disable=SC1091
    . tool/local.env
fi
host="${TEST_DATA_HOST:-}"
if [ -z "$host" ]; then
    echo "No TEST_DATA_HOST (tool/local.env): the test data is not copied."
    exit 0
fi

if [ ! -d test_data ]; then
    echo "No test_data/ here: nothing to copy."
    exit 0
fi
rsync -a --delete --exclude .DS_Store \
    -e 'ssh -o BatchMode=yes -o ConnectTimeout=5' \
    test_data/ "$host:uwmedia_test_data/"
echo "Test data on $host is up to date."
