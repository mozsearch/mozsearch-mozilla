#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

if [ $# -ne 2 ]; then
    echo "Usage: $0 <branch> <git-rev>"
    echo " e.g.: $0 master 26bd1e060c5bf1f2f3f3c7f34fae152380cda29c"
    echo " If the git rev is an empty string, we assume that the git equivalent"
    echo " for the target HG revision could not be found, and we error out."
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
# Fetch projects. Currently unused but makes it easier to index project branches when needed
git remote show projects || git remote add projects https://github.com/mozilla/gecko-projects.git
git fetch projects
# Fetch hg metadata and graft it to the gecko repository using cinnabar. If we want to index
# project branches we'll want to add the equivalent hg repos and graft metadata from those as
# well.
git remote show cinnabar || git remote add cinnabar hg::https://hg.mozilla.org/mozilla-unified
git config cinnabar.graft true
git remote update cinnabar 2> >(grep -v "WARNING Cannot graft" >&2) # Filter stderr to remove warnings we don't care about

if [ -z "$INDEXED_GIT_REV" ]; then
    echo "ERROR: Unable to find git equivalent for hg rev $INDEXED_HG_REV; please fix the mapper and retry."
    exit 1
fi

git checkout -B "$BRANCH" $INDEXED_GIT_REV
popd

date

# Generate the blame information after checking out the GIT_ROOT to appropriate
# revision above, so that the blame repo's head matches the git repo's head.
echo "Generating blame information..."
pushd $BLAME_ROOT
git reset --soft "$BRANCH"
popd
CINNABAR=1 python $MOZSEARCH_PATH/blame/transform-repo.py $GIT_ROOT $BLAME_ROOT

date

# Point the blame repo's HEAD to the commit matching what we have in in the src repo. Note
# that we use `git reset --soft` because we don't need anything in the repo's working dir.
pushd $BLAME_ROOT
BLAME_REV=$(git log -1 --grep=$INDEXED_GIT_REV --pretty=format:%H)
if [ -z "$BLAME_REV" ]; then
    echo "Unable to find blame rev for $INDEXED_GIT_REV"
    exit 1;
fi
git reset --soft $BLAME_REV
popd
