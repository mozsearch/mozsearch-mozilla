#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# Helper script to download a recent git-hg mapping from the
# mapper releng tool if it hasn't already been downloaded.
# This is a shared helper because we have multiple repos that
# download the same thing on a given indexer.

if [ ! -f "$WORKING/git_hg.map" ]; then
    rm -f "$WORKING/git_hg.map.tmp"

    # We combine this and the projects branch for convenience, as they share a
    # lot of revisions.
    for tree in gecko-dev gecko-projects; do
      curl -SsfL https://moz-vcssync.s3-us-west-2.amazonaws.com/mapping/$tree/git-mapfile.tar.bz2 | tar -xOj >> "$WORKING/git_hg.map.tmp"
    done

    # Remove duplicate entries from the map, which almost halves its size.
    cat "$WORKING/git_hg.map.tmp" | sort | uniq > "$WORKING/git_hg.map"
    rm -f "$WORKING/git_hg.map.tmp"
fi
