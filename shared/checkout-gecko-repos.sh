#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

if [ $# -ne 2 ]; then
    echo "Usage: $0 <branch> <git-rev>"
    echo " e.g.: $0 master 26bd1e060c5bf1f2f3f3c7f34fae152380cda29c"
    echo " e.g.: $0 beta ''"
    echo " If the git rev is an empty string, defaults to origin/<branch>"
    exit 1
fi

BRANCH=$1
INDEXED_GIT_REV=$2

echo Downloading Gecko
pushd $INDEX_ROOT
$CONFIG_REPO/shared/fetch-gecko-tarball.sh gecko-dev $PWD
popd

date

echo Downloading Gecko blame
pushd $INDEX_ROOT
$CONFIG_REPO/shared/fetch-gecko-tarball.sh gecko-blame $PWD
popd

date

echo Downloading git to hg map
$CONFIG_REPO/shared/fetch-hg-map.sh

date

echo Updating git
pushd $GIT_ROOT
git fetch origin
if [ -n "$INDEXED_GIT_REV" ]; then
    git checkout $INDEXED_GIT_REV
else
    git checkout -B "$BRANCH" "origin/$BRANCH"
fi
popd

date

# Generate the blame information after checking out the GIT_ROOT to appropriate
# revision above, so that the blame repo's head matches the git repo's head.
echo "Generating blame information..."
pushd $BLAME_ROOT
git reset --soft "$BRANCH"
popd
python $MOZSEARCH_PATH/blame/transform-repo.py $GIT_ROOT $BLAME_ROOT $WORKING/git_hg.map

date

# Point the blame repo's HEAD to the commit matching what we have in in the src repo. Note
# that we use `git reset --soft` because we don't need anything in the repo's working dir.
if [ -n "$INDEXED_GIT_REV" ]; then
    pushd $BLAME_ROOT
    BLAME_REV=$(git log -1 --grep=$INDEXED_GIT_REV --pretty=format:%H)
    if [ -z "$BLAME_REV" ]; then
        echo "Unable to find blame rev for $INDEXED_GIT_REV"
        exit 1;
    fi
    git reset --soft $BLAME_REV
    popd
fi
