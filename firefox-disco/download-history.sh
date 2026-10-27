#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# Download the uploaded history (firefox-shared-history.tar.lz4; see
# update-history.sh and upload) to $HISTORY_ROOT.  setup runs this in the
# background while the git repos are downloaded and updated, before
# update-history.sh, which runs it itself if $HISTORY_ROOT doesn't exist (ex:
# for reblame).

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
echo "setup::download-history done for $TREE_NAME : $(date +"%Y-%m-%dT%H:%M:%S%z")"
