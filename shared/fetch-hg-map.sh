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
    DATE=2019-01-01

    rm -f "$WORKING/git_hg.map.tmp"

    # We combine this and the projects branch for convenience, as they share a
    # lot of revisions.
    for tree in gecko-dev gecko-projects; do
      curl -SsfL https://mapper.mozilla-releng.net/$tree/mapfile/since/$DATE >> "$WORKING/git_hg.map.tmp"
    done

    # Remove duplicate entries from the map, which almost halves its size.
    cat "$WORKING/git_hg.map.tmp" | sort | uniq > "$WORKING/git_hg.map"
    rm -f "$WORKING/git_hg.map.tmp"
fi
