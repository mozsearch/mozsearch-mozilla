#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

if [ $# -ne 3 -a $# -ne 4 ]; then
    echo "Usage: $0 <tree> <branch> <hg-rev> [<git-rev>]"
    echo " e.g.: $0 mozilla-central master 26bd1e060c5bf1f2f3f3c7f34fae152380cda29c"
    echo "For the following, pass <hg-rev> only."
    echo "  * hg-based repository"
    echo "  * git-based which has the corresponding hg repository"
    echo "For the following, pass <git-rev>, with passing '-' to <hg-rev>"
    echo "  * pure git-based repository"
    exit 1
fi

REVISION_TREE=$1
BRANCH=$2
INDEXED_HG_REV=$3
INDEXED_GIT_REV=${4:-}

# --- Ensure shared resources are downloaded
#
# We now use the "aws" command to perform the download for performance reasons
# since it knows how to parallelize and otherwise leverage when it is running on
# an EC2 node.
#
# We use `--no-sign-request` to force an anonymous request so this works everywhere
# (because we mark the resources public).
mkdir -p $SHARED_ROOT
pushd $SHARED_ROOT
date

if [ ! -d git ]; then
    # firefox-shared/git comes from firefox-shared-git.tar.lz4
    if [[ ! -f "firefox-shared-git.tar.lz4" ]]; then
        aws s3 cp s3://searchfox.repositories/firefox-shared-git.tar.lz4 . --no-sign-request
    fi
    lz4 -dc firefox-shared-git.tar.lz4 | tar -x
    rm firefox-shared-git.tar.lz4
    # Since this is the first time we have extracted this repo, it's possible
    # someone may have tarballed the git tree with worktrees present from their
    # local system.  These will now be stale, so let's prune those.
    git -C ./git worktree prune
fi
date

if [ ! -d blame ]; then
    # firefox-shared/blame comes from firefox-shared-blame.tar.lz4
    if [[ ! -f "firefox-shared-blame.tar.lz4" ]]; then
        aws s3 cp s3://searchfox.repositories/firefox-shared-blame.tar.lz4 . --no-sign-request
    fi
    lz4 -dc firefox-shared-blame.tar.lz4 | tar -x
    rm firefox-shared-blame.tar.lz4
    # Since this is the first time we have extracted this repo, it's possible
    # someone may have tarballed the git tree with worktrees present from their
    # local system.  These will now be stale, so let's prune those.
    git -C ./blame worktree prune
fi
date

if [ ! -d oldgit ]; then
    # firefox-shared/oldgit comes from firefox-shared-oldgit.tar.lz4
    if [[ ! -f "firefox-shared-oldgit.tar.lz4" ]]; then
        aws s3 cp s3://searchfox.repositories/firefox-shared-oldgit.tar.lz4 . --no-sign-request
    fi
    lz4 -dc firefox-shared-oldgit.tar.lz4 | tar -x
    rm firefox-shared-oldgit.tar.lz4
    # Since this is the first time we have extracted this repo, it's possible
    # someone may have tarballed the git tree with worktrees present from their
    # local system.  These will now be stale, so let's prune those.
    git -C ./oldgit worktree prune
fi
date

popd

# --- Update git and oldgit
# Note that only $SHARED_BARE_GIT_ROOT diverges from the worktree $GIT_ROOT.
# We use these paths for clarity/consistency that we're working in bare-repo space.
SHARED_BARE_GIT_ROOT=$SHARED_ROOT/git
SHARED_BARE_OLDGIT_ROOT=$SHARED_ROOT/oldgit
SHARED_BARE_BLAME_ROOT=$SHARED_ROOT/blame

echo "Updating new shared bare git"
date
pushd $SHARED_BARE_GIT_ROOT
# Note that this fetch is only updating remotes/origin/*, not our local tracking
# branches (ex: refs/heads/main).
git fetch
# So we update the references here; note that because "main" is the name for
# "central", we manually do that outside the loop.  We do this:
# - For idiomatic / convenience reasons.
# - Because our blame ingestion wants to use the same ref scheme for every
#   git repository (for simplicity).
git update-ref refs/heads/main refs/remotes/origin/bookmarks/central
# We don't use BRANCH as a var here because we would clobber the script arg.
for REFBRANCH in beta release esr140 esr128 esr115; do
    git update-ref "refs/heads/$REFBRANCH" "refs/remotes/origin/bookmarks/$REFBRANCH"
done

# Put enterprise-firefox repository to the shared tarball, and also pull the
# specified revision when indexing the enterprise-firefox repository.
#
# This is necessary also for "mozilla-central" because firefox-main/setup script
# refers the branch.
#
# TODO: Update the enterprise-firefox for REVISION_TREE comparison to
#       enterprise-main once the taskcluster is updated.
if [[ "$REVISION_TREE" == "mozilla-central" || \
      "$REVISION_TREE" == "enterprise-firefox.branch.enterprise-main" ]]; then
    git config remote.enterprise-firefox.url \
        || git remote add -t enterprise-main enterprise-firefox https://github.com/mozilla/enterprise-firefox.git

    if [[ "$REVISION_TREE" == "mozilla-central" ]]; then
        git fetch enterprise-firefox enterprise-main
        git update-ref "refs/heads/enterprise-main" "refs/remotes/enterprise-firefox/enterprise-main"
    else
        git fetch enterprise-firefox $INDEXED_GIT_REV
        git update-ref "refs/heads/enterprise-main" $INDEXED_GIT_REV
    fi
fi

# If a try push was specified, pull it in non-graft mode so we actually pull those changes.
if [ "$REVISION_TREE" == "try" ]; then
    git config cinnabar.graft false
    git cinnabar fetch hg::https://hg.mozilla.org/try $INDEXED_HG_REV
fi

if [[ "$INDEXED_GIT_REV" == "" ]]; then
    INDEXED_GIT_REV=$(git cinnabar hg2git $INDEXED_HG_REV)
fi

# If INDEXED_GIT_REV gets set to 40*"0", that means the gecko-dev repo is lagging
# lagging behind the canonical hg repo, and we don't have the source corresponding
# to the indexing run on taskcluster. In that case we error out and abort.

if [ "$INDEXED_GIT_REV" == "0000000000000000000000000000000000000000" ]; then
    echo "ERROR: Unable to find git equivalent for hg rev $INDEXED_HG_REV; please fix cinnabar and retry."
    exit 1
fi

popd
date

echo "Updating old shared bare git"
date
pushd $SHARED_BARE_OLDGIT_ROOT
# Fetch the m-c repos that we care about with non-grafted cinnabar, so it will have all the necessary hg metadata.
# This could be simplified by using mozilla-unified, but currently mozilla-unified is updated with some amount
# of latency and that can still leave us with stale data. It's better to pull from the individual source-of-truth
# repos directly. Note we only pull the "default/tip" branch from these remotes, rather than all the random tags
# and offshoot branches/closed heads that have accumulated in these repos.
# If we need to fetch project branches in the future, we can fetch those also with cinnabar here.
# Note that this repo may still have a 'projects' and a 'cinnabar' remote left over that we don't use any more.
# Note: the pine branch used to be in here, but was removed in bug 1841395.
# If the pine branch gets reset for a new project and we want to
# add it back in here, we might need to manually update the tarball to
# strip the existing pine branch. I don't know if it will work otherwise.
git config remote.central.url || git remote add -t branches/default/tip central hg::https://hg.mozilla.org/mozilla-central
git config remote.elm.url || git remote add -t branches/default/tip elm hg::https://hg.mozilla.org/projects/elm
git config remote.cedar.url || git remote add -t branches/default/tip cedar hg::https://hg.mozilla.org/projects/cedar
git config remote.cypress.url || git remote add -t branches/default/tip cypress hg::https://hg.mozilla.org/projects/cypress
git config remote.beta.url || git remote add -t branches/default/tip beta hg::https://hg.mozilla.org/releases/mozilla-beta
git config remote.release.url || git remote add -t branches/default/tip release hg::https://hg.mozilla.org/releases/mozilla-release
git config remote.esr140.url || git remote add -t branches/default/tip esr140 hg::https://hg.mozilla.org/releases/mozilla-esr140
git config remote.esr128.url || git remote add -t branches/default/tip esr128 hg::https://hg.mozilla.org/releases/mozilla-esr128
git config remote.esr115.url || git remote add -t branches/default/tip esr115 hg::https://hg.mozilla.org/releases/mozilla-esr115
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
git -c cinnabar.check=traceback fetch --multiple central elm cedar cypress beta release esr140 esr128 esr115 esr102 esr91 esr78 esr68 esr60 esr45 esr31 esr17
popd
date

# --- Perform the checkout using a worktree
# Currently we do need/want a full checkout for "files_path", so we need to
# create a worktree for that (and "git_path" can't just be the bare git repo),
# but note that for "oldgit" and "blame" we can and do just use the shared bare
# repositories.

echo "Checking out the revision in new git as a worktree"
date
pushd $SHARED_BARE_GIT_ROOT
# If we are being run by a dev locally, it's possible the worktree may already
# exist and be valid, so forcibly clean up the old work tree and start fresh.
# (Although we run "git worktree prune" on download, we won't be doing a fresh
# download in this case and the worktree's path would be valid, so prune would
# not prune it.)
if [ -d "$GIT_ROOT" ]; then
    git worktree remove --force "$GIT_ROOT"
fi
# We use a detached HEAD for our checkout because we inevitably are going to be
# on an older commit than the current tip of the branch[1] and this lets us leave
# the branch reflecting reality.  If we used `-B "$BRANCH"`, then the ref would
# be moved to this revision and our "build-blame" invocation would be limited to
# this commit, thereby limiting what our /rev/ endpoint can serve.
#
# 1: This is because for firefox-main we pick our revision based on the most
# recent coverage data we have, which unfortunately can time-warp, and for other
# firefox-* branches we're similarly dependent on the most recent searchfox
# indexer runs.
git worktree add --detach "$GIT_ROOT" "$INDEXED_GIT_REV"
popd
date

# --- Ensure we have up-to-date blame for this branch
# Note that the firefox-main "setup" script will also try and generate blame for
# all supported branches because only the firefox-main tree has an "upload"
# script that uploads things.  But because this script is invoked by firefox-main's
# setup script before it does that, this logic will run before that logic (and
# so that logic should end up as a no-op when it runs for the "main" branch).
echo "Generating blame information for $BRANCH..."
date

build-blame "$SHARED_BARE_GIT_ROOT" "$SHARED_BARE_BLAME_ROOT" --blame-ref "refs/heads/$BRANCH" --old-cinnabar-repo-path "$SHARED_BARE_OLDGIT_ROOT"

date

# We used to reset the blame branch so that its HEAD matches up with the indexed
# revision, but now that we use a single shared blame repo for multiple searchfox
# trees, we can't depend on HEAD for any of them.
#
# The only benefit to having lined up the revisions was that `index_blame`
# wouldn't load information about revisions more recent than the indexed
# revision, but this:
# - Isn't much of a memory savings.
# - Is counterproductive; it's nice to be able to use searchfox for more recent
#   revisions.  We might want to explicitly ingest new firefox-main revisions
#   as they land even though we won't have the semantic data for them.
