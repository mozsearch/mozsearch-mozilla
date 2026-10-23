#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# Update the wubspecs tree's forest repository and its token-centric history
# ("hyperblame", bug 1517978), for setup and reblame.
#
# - The forest ($GIT_ROOT) is one repository whose top-level directories are
#   the web specs' upstream repositories (see specs.toml), with a commit for
#   each of their first-parent commits; see mozsearch's build-spec-forest and
#   tools/src/spec_forest.rs.  It's kept (and uploaded) with the history,
#   since the history records its commits, and appending to it isn't the same
#   as building it from scratch (ex: a newly configured spec's whole history is
#   appended at the tip).
# - The history ($HISTORY_ROOT) is the syntax/ and timeline/ repos and
#   rev-summaries/, as for firefox-disco (see ../firefox-disco/update-history.sh),
#   back to each spec's start (the HTML Standard's in 2006), and the commit
#   index.
# - The stale anchors' cache, history/stale-anchors.json (see the stale-anchors
#   step).
#
# HISTORY_STATUS_COMMAND can name a command to report progress to (see
# build-history.py's --status-command), ex: reblame's.  COMMIT_LIMIT (see
# build-history.py) can limit how many revisions are processed, for testing.

echo "Performing setup::build-spec-forest step for $TREE_NAME : $(date +"%Y-%m-%dT%H:%M:%S%z")"

# (Fetches each spec's branch from upstream, with the system's git, which
# detects SHA-1 collisions in what it fetches.)
build-spec-forest --fetch $CONFIG_REPO/$TREE_NAME/specs.toml $GIT_ROOT

echo "Performing setup::build-history step for $TREE_NAME : $(date +"%Y-%m-%dT%H:%M:%S%z")"

mkdir -p "$HISTORY_ROOT/rev-summaries"
for REPO in syntax timeline; do
    if [ ! -d "$HISTORY_ROOT/$REPO/.git" ]; then
        mkdir -p "$HISTORY_ROOT/$REPO"
        # (The tools write to the branch HEAD is, as in the forest, whose
        # branch is main; with mozsearch-git, the git the tools write the
        # history with.)
        mozsearch-git init -q -b main "$HISTORY_ROOT/$REPO"
    fi
done

# In chunks of 500 revisions, with the history repos repacked between them
# (see build-history.py), and with 4 compute threads for
# build-syntax-token-tree rather than 15: it keeps 10 revisions in flight per
# thread, and the HTML Standard's revisions until 2012 each rewrote 3 files of
# 2-8 MB (its `source`, and the `index` and `complete.html` it generated),
# whose tokens take ~0.8 GB per revision, so 15 threads took 77 GB.
# (build-timeline-tree's threads, which the history's speed is limited by, are
# as usual: with 4, the first reblame's timeline had its 4 threads busy and 77%
# of an m8id.8xlarge idle.)  The timeline's runs are up to 10,000 revisions
# (mozsearch Part 531): each run's start and end take a while, which in runs of
# 500 was ~15% of the 2026-10-23 reblame's timeline, and it still ends a run
# early once it has written MAX_WRITTEN_BYTES (see build-history.py).
SYNTAX_COMPUTE_THREADS=${SYNTAX_COMPUTE_THREADS:-4} \
    $MOZSEARCH_PATH/scripts/build-history.py --chunk-size 500 --timeline-chunk-size 10000 \
    ${HISTORY_STATUS_COMMAND:+--status-command "$HISTORY_STATUS_COMMAND"} \
    "$GIT_ROOT" "$HISTORY_ROOT"

echo "Performing setup::build-commit-index step for $TREE_NAME : $(date +"%Y-%m-%dT%H:%M:%S%z")"

# (Of HEAD, since the tree has no `git_branch`.)
build-commit-index "$GIT_ROOT" "$HISTORY_ROOT/commit-index"

echo "Performing setup::stale-anchors step for $TREE_NAME : $(date +"%Y-%m-%dT%H:%M:%S%z")"

# The anchors which the trees citing the specs (this one, and firefox-disco on
# config8) cited but the specs no longer define, as of their last indexing (see
# ../shared/upload-stale-anchors-cited.sh), looked up in the history, in its
# cache (history/stale-anchors.json, uploaded with it), which spec-analyze
# marks their citations with; see mozsearch's tools/src/spec_analyze/stale.rs.
# Only anchors not yet in the cache are looked up (by analyzing old revisions,
# with Bikeshed for Bikeshed specs), so this is quick after the first time.
if [ -n "${HISTORY_STATUS_COMMAND:-}" ]; then
    $HISTORY_STATUS_COMMAND "looking up stale anchors in the history"
fi
CITED_DIR=$(mktemp -d)
CITED=()
for CITING_TREE in wubspecs firefox-disco; do
    if aws s3 cp s3://searchfox.repositories/$CITING_TREE-stale-anchors-cited.json \
        $CITED_DIR/$CITING_TREE.json --no-sign-request; then
        CITED+=("$CITED_DIR/$CITING_TREE.json")
    fi
done
stale-anchors $CONFIG_REPO/$TREE_NAME/specs.toml "$GIT_ROOT" "$HISTORY_ROOT" ${CITED[@]+"${CITED[@]}"}
rm -rf "$CITED_DIR"
