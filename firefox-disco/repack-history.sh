#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# Fully repack the history repos at $HISTORY_ROOT (see update-history.sh), for
# reblame and costly-maintenance.
#
# Fully repacking the history makes it as small as possible to download: the
# daily indexing only repacks it geometrically (see mozsearch's
# scripts/build-history.py), which leaves it in packs which each have a whole
# copy of every journal they have versions of.  It needs about as much space
# again as the repo being repacked, and memory for every object in it (the
# full firefox history's timeline, 246M objects, took ~50 GiB besides the
# packs it maps), which is why only reblame and costly-maintenance, on big
# instances, do it.  This is the repack git gc does (the rest of what it does
# doesn't matter for these repos), plus --path-walk: most of the time goes to
# finding every object reachable from every commit, which git's path walk did
# in half the time, for a slightly smaller pack, on 4,000 recent revisions'
# timeline.  (As of git 2.55, gc doesn't use the path walk even with
# pack.usePathWalk.)  With mozsearch-git, the git the tools write the history
# with (see mozsearch's nix/mozsearch/git.nix), as for build-history.py's
# repacks.

for repo in syntax timeline; do
    du -sh "$HISTORY_ROOT/$repo/.git/objects"
    mozsearch-git -C "$HISTORY_ROOT/$repo" repack -d -l --cruft --cruft-expiration=2.weeks.ago --path-walk
    du -sh "$HISTORY_ROOT/$repo/.git/objects"
done
