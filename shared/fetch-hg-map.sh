#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# Helper script to download a recent git-hg mapping from the
# mapper releng tool if it hasn't already been downloaded.
# This is a shared helper because we have multiple repos that
# download the same thing on a given indexer.

if [ ! -f "$WORKING/git_hg.map" ]; then
    # We only need "recent" mapfile entries and attempting to download the full mapfile
    # results in a 503 error so we just get the map entries from some fixed recent date.
    wget -O "${WORKING}/git_hg.map" -nv https://mapper.mozilla-releng.net/gecko-dev/mapfile/since/2019-01-01
fi
