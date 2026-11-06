#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# The anchors which the trees citing the specs (this one, and firefox-disco on
# config8) cited but the specs no longer define, as of their last indexing (see
# ../shared/upload-stale-anchors-cited.sh), looked up in the history, in its
# cache (history/stale-anchors.json, uploaded with it), which spec-analyze
# marks their citations with; see mozsearch's tools/src/spec_analyze/stale.rs.
# Only anchors not yet in the cache are looked up (by analyzing old revisions,
# with Bikeshed for Bikeshed specs), so this is quick after the first time.
# (Run by update-history.sh, in the background for the indexing's setup.)
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
