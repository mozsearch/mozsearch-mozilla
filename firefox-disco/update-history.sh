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
# The history is derived starting from the revision in history/config.toml, if
# it has one (it doesn't, so the history covers all of firefox-main's, back to
# 1998).  Changing the start revision (or the history attributes of revisions
# already processed) requires regenerating the history, which
# build-syntax-token-tree will refuse to do incrementally.
#
# For testing, the environment variable COMMIT_LIMIT (see mozsearch's
# scripts/build-history.py) can limit how many revisions are processed, and
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

# (setup downloads it in the background, earlier.)
if [ ! -d "$HISTORY_ROOT" ]; then
    $CONFIG_REPO/firefox-disco/download-history.sh
fi

for REPO in syntax timeline; do
    if [ ! -d "$HISTORY_ROOT/$REPO/.git" ]; then
        mkdir -p "$HISTORY_ROOT/$REPO"
        # The tools write to refs/heads/$BRANCH, so make that HEAD.  (With
        # mozsearch-git, the git the tools write the history with; see
        # mozsearch's nix/mozsearch/git.nix.)
        mozsearch-git init -q -b "$BRANCH" "$HISTORY_ROOT/$REPO"
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

# The history's dates are when revisions landed (see mozsearch's
# tools/src/hyperblame/landing.rs), and hg's commit dates were their authors',
# so for hg-era revisions they're when they were first pushed, from
# hg.mozilla.org's pushlogs (archived once; see mozsearch's scripts/pushlog/).
# build-timeline-tree reads PUSH_DATES, and build-commit-index --push-dates.
echo "Performing setup::download-push-dates step for $TREE_NAME : $(date +"%Y-%m-%dT%H:%M:%S%z")"
PUSH_DATES=$SHARED_ROOT/firefox-hg-push-dates.tsv
if [ ! -f "$PUSH_DATES" ]; then
    aws s3 cp s3://searchfox.repositories/firefox-hg-push-dates.tsv.gz "$PUSH_DATES.gz" --no-sign-request
    gunzip -f "$PUSH_DATES.gz"
fi
export PUSH_DATES

# The history is derived from the shared bare repo (like blame), which has the
# git-cinnabar metadata that lets build-syntax-token-tree record each
# revision's hg revision (needed to find the old revisions) and lets
# build-timeline-tree find the git revisions of the hg revisions in hg-era
# backout messages.  The history repos record the revisions they've processed
# in git notes (refs/notes/mozsearch-source-mapping-$BRANCH), which are part of
# the uploaded history.  build-history.py runs build-syntax-token-tree and then
# build-timeline-tree in chunks of revisions, repacking the history repos
# after each chunk, which keeps the number of packs down.
# HISTORY_STATUS_COMMAND can name a command to report progress to (see
# build-history.py's --status-command), ex: reblame's.
echo "Performing setup::build-history step for $TREE_NAME : $(date +"%Y-%m-%dT%H:%M:%S%z")"
BLAME_REF="refs/heads/$BRANCH" $MOZSEARCH_PATH/scripts/build-history.py \
    ${HISTORY_STATUS_COMMAND:+--status-command "$HISTORY_STATUS_COMMAND"} \
    "$SHARED_BARE_GIT_ROOT" "$HISTORY_ROOT" "$HISTORY_CONFIG" "${OLD_REVISION_ARGS[@]}"

# Revisions whose rev-summaries have totals rather than file deltas (those
# changing over 1,000 files) have token indexes, which history greps read to
# check only their files where the tokens changed (see mozsearch's
# tools/src/file_format/history/rev_token_index.rs).  build-timeline-tree writes
# them for the revisions it processes; index-mass-revisions writes those of the
# history's earlier ones, once (~3 minutes for the 502 of firefox's history,
# on 32 threads), and then says so in rev-summaries/token-indexes-complete,
# after which it does nothing.
echo "Performing setup::index-mass-revisions step for $TREE_NAME : $(date +"%Y-%m-%dT%H:%M:%S%z")"
index-mass-revisions "$HISTORY_ROOT" "$SHARED_BARE_GIT_ROOT" --branch "$BRANCH"

# The commit index maps bugs and Phabricator revisions to the commits which
# mention them (see mozsearch's tools/src/commit_index.rs).  It's kept (and
# uploaded) with the history so that updating it only processes new commits,
# but it covers the whole branch rather than the history's revisions.  Each
# branch has its own, in commit-index/$BRANCH, like the history repos' branches.
echo "Performing setup::build-commit-index step for $TREE_NAME : $(date +"%Y-%m-%dT%H:%M:%S%z")"
build-commit-index "$SHARED_BARE_GIT_ROOT" "$HISTORY_ROOT/commit-index" "refs/heads/$BRANCH" \
    --push-dates "$PUSH_DATES"
