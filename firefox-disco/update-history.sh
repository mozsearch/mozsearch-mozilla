#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# Download (if we don't already have it) and update the token-centric history
# ("hyperblame", bug 1517978) at $HISTORY_ROOT for the given branch of the
# shared firefox git repo.  The history consists of:
# - syntax/: git repo built by build-syntax-token-tree
# - timeline/: git repo built by build-timeline-tree
# - rev-summaries/: per-revision JSON summaries built by build-timeline-tree
#
# The history is derived starting from the revision in history/config.toml
# because deriving it for all of firefox-main's history (back to 1998) isn't
# practical yet.  Changing the start revision (or the history attributes of
# revisions already processed) requires regenerating the history, which
# build-syntax-token-tree will refuse to do incrementally.
#
# For testing, the environment variable COMMIT_LIMIT (see build-syntax-token-tree
# and build-timeline-tree) can limit how many revisions are processed, and
# HISTORY_CONFIG can name a different history configuration directory (ex: one
# with a note limiting which paths get history).

if [ $# -ne 1 ]; then
    echo "Usage: $0 <branch>"
    exit 1
fi

BRANCH=$1
HISTORY_CONFIG=${HISTORY_CONFIG:-$CONFIG_REPO/firefox-disco/history}
# See ../firefox-shared/checkout-gecko-repos.sh.
SHARED_BARE_GIT_ROOT=$SHARED_ROOT/git

echo "Performing setup::download-history step for $TREE_NAME : $(date +"%Y-%m-%dT%H:%M:%S%z")"
mkdir -p $SHARED_ROOT
pushd $SHARED_ROOT
if [ ! -d "$HISTORY_ROOT" ]; then
    # We use the "aws" command for download throughput; see
    # ../firefox-shared/checkout-gecko-repos.sh.  The tarball won't exist until
    # the first successful upload, in which case we build from scratch.
    if aws s3 cp s3://searchfox.repositories/firefox-shared-history.tar.lz4 . --no-sign-request; then
        lz4 -dc firefox-shared-history.tar.lz4 | tar -x
        rm firefox-shared-history.tar.lz4
    else
        echo "No firefox-shared-history.tar.lz4 is available; building the history from scratch."
    fi
fi
popd

for REPO in syntax timeline; do
    if [ ! -d "$HISTORY_ROOT/$REPO/.git" ]; then
        mkdir -p "$HISTORY_ROOT/$REPO"
        # The tools write to refs/heads/$BRANCH, so make that HEAD.
        git init -q -b "$BRANCH" "$HISTORY_ROOT/$REPO"
    fi
done
mkdir -p "$HISTORY_ROOT/rev-summaries"

# Like blame, we record the old gecko-dev revisions ("oldrevs") of revisions
# using the old git-cinnabar repo (downloaded by checkout-gecko-repos.sh) and,
# for CVS-era revisions which no longer exist in the new repo, a mapping file.
echo "Performing setup::download-old-revision-map step for $TREE_NAME : $(date +"%Y-%m-%dT%H:%M:%S%z")"
OLD_REVISION_MAP=$SHARED_ROOT/firefox-cvs-new-revisions-and-related-old-revisions.txt
if [ ! -f "$OLD_REVISION_MAP" ]; then
    aws s3 cp s3://searchfox.repositories/firefox-cvs-new-revisions-and-related-old-revisions.txt "$OLD_REVISION_MAP" --no-sign-request
fi
OLD_REVISION_ARGS=(--old-revision-map "$OLD_REVISION_MAP")
if [ -d "$SHARED_ROOT/oldgit" ]; then
    OLD_REVISION_ARGS+=(--old-cinnabar-repo-path "$SHARED_ROOT/oldgit")
fi

# The history is derived from the shared bare repo (like blame), which has the
# git-cinnabar metadata that lets build-syntax-token-tree record each
# revision's hg revision, which is needed to recognize hg-era backouts and to
# find the old revisions.
echo "Performing setup::build-syntax-token-tree step for $TREE_NAME : $(date +"%Y-%m-%dT%H:%M:%S%z")"
BLAME_REF="refs/heads/$BRANCH" build-syntax-token-tree "$SHARED_BARE_GIT_ROOT" "$HISTORY_ROOT/syntax" "$HISTORY_CONFIG" "${OLD_REVISION_ARGS[@]}"

echo "Performing setup::build-timeline-tree step for $TREE_NAME : $(date +"%Y-%m-%dT%H:%M:%S%z")"
BLAME_REF="refs/heads/$BRANCH" build-timeline-tree "$SHARED_BARE_GIT_ROOT" "$HISTORY_ROOT/syntax" "$HISTORY_ROOT/timeline" "$HISTORY_ROOT/rev-summaries"
