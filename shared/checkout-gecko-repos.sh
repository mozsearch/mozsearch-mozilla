#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

if [ $# -ne 3 ]; then
    echo "Usage: $0 <tree> <branch> <hg-rev>"
    echo " e.g.: $0 mozilla-central master 26bd1e060c5bf1f2f3f3c7f34fae152380cda29c"
    exit 1
fi

REVISION_TREE=$1
BRANCH=$2
INDEXED_HG_REV=$3

echo Downloading Gecko
pushd $INDEX_ROOT
$CONFIG_REPO/shared/fetch-gecko-tarball.sh gecko $PWD
popd

date

echo Downloading Gecko blame
pushd $INDEX_ROOT
$CONFIG_REPO/shared/fetch-gecko-tarball.sh gecko-blame $PWD
popd

date

echo Updating git
pushd $GIT_ROOT
# Fetch the m-c repos that we care about with non-grafted cinnabar, so it will have all the necessary hg metadata.
# This could be simplified by using mozilla-unified, but currently mozilla-unified is updated with some amount
# of latency and that can still leave us with stale data. It's better to pull from the individual source-of-truth
# repos directly. Note we only pull the "default/tip" branch from these remotes, rather than all the random tags
# and offshoot branches/closed heads that have accumulated in these repos.
# If we need to fetch project branches in the future, we can fetch those also with cinnabar here.
# Note that this repo may still have a 'projects' and a 'cinnabar' remote left over that we don't use any more.
git config remote.central.url || git remote add -t branches/default/tip central hg::https://hg.mozilla.org/mozilla-central
git config remote.pine.url || git remote add -t branches/default/tip pine hg::https://hg.mozilla.org/projects/pine
git config remote.beta.url || git remote add -t branches/default/tip beta hg::https://hg.mozilla.org/releases/mozilla-beta
git config remote.release.url || git remote add -t branches/default/tip release hg::https://hg.mozilla.org/releases/mozilla-release
git config remote.esr102.url || git remote add -t branches/default/tip esr102 hg::https://hg.mozilla.org/releases/mozilla-esr102
git config remote.esr91.url || git remote add -t branches/default/tip esr91 hg::https://hg.mozilla.org/releases/mozilla-esr91
git config remote.esr78.url || git remote add -t branches/default/tip esr78 hg::https://hg.mozilla.org/releases/mozilla-esr78
git config remote.esr68.url || git remote add -t branches/default/tip esr68 hg::https://hg.mozilla.org/releases/mozilla-esr68
git config remote.esr60.url || git remote add -t branches/default/tip esr60 hg::https://hg.mozilla.org/releases/mozilla-esr60
git config remote.esr45.url || git remote add -t branches/default/tip esr45 hg::https://hg.mozilla.org/releases/mozilla-esr45
git config remote.esr31.url || git remote add -t branches/default/tip esr31 hg::https://hg.mozilla.org/releases/mozilla-esr31
git config remote.esr17.url || git remote add -t branches/default/tip esr17 hg::https://hg.mozilla.org/releases/mozilla-esr17
git config cinnabar.graft false
git config fetch.prune true
git fetch --multiple central pine beta release esr102 esr91 esr78 esr68 esr60 esr45 esr31 esr17

# If a try push was specified, pull it in non-graft mode so we actually pull those changes.
if [ "$REVISION_TREE" == "try" ]; then
    git cinnabar fetch hg::https://hg.mozilla.org/try $INDEXED_HG_REV
fi

INDEXED_GIT_REV=$(git cinnabar hg2git $INDEXED_HG_REV)

# If INDEXED_GIT_REV gets set to 40*"0", that means the gecko-dev repo is lagging
# lagging behind the canonical hg repo, and we don't have the source corresponding
# to the indexing run on taskcluster. In that case we error out and abort.

if [ "$INDEXED_GIT_REV" == "0000000000000000000000000000000000000000" ]; then
    echo "ERROR: Unable to find git equivalent for hg rev $INDEXED_HG_REV; please fix cinnabar and retry."
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
$MOZSEARCH_PATH/tools/target/release/build-blame $GIT_ROOT $BLAME_ROOT

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
