#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# Upload the anchors this tree's files cite which the specs no longer define
# (stale-anchors-cited.json, which mozsearch's scripts/spec-analyze.sh writes
# in its index directory; see tools/src/spec_analyze/stale.rs), as
# $TREE_NAME-stale-anchors-cited.json, for the wubspecs tree's next history
# update to look up in the specs' history (see ../wubspecs/update-history.sh).

echo "Performing upload::stale-anchors-cited step for $TREE_NAME : $(date +"%Y-%m-%dT%H:%M:%S%z")"
if [ -f $INDEX_ROOT/stale-anchors-cited.json ]; then
    aws s3 cp $INDEX_ROOT/stale-anchors-cited.json \
        s3://searchfox.repositories/$TREE_NAME-stale-anchors-cited.json --acl public-read
fi
