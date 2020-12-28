#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

if [[ -z $MOZSEARCH_PATH ]]; then
    echo "MOZSEARCH_PATH needs to be defined for this script" > /dev/stderr
    exit 1
fi

# Run this in a working dir on a disk with at least ~120G free space.
# The initial master branch blame-build operation creates a ~75G git
# repo that packs down to ~3G with the `git gc`, but we still need
# that space for the operation to complete.

# Get the gecko-dev tarball, which has all the various gecko branches
# that we want to build blame for.
wget -nv "https://s3-us-west-2.amazonaws.com/searchfox.repositories/gecko-dev.tar"
tar xf gecko-dev.tar

# Init a new blame repo
mkdir gecko-blame
pushd gecko-blame
git init .
popd

# Build blame for HEAD, i.e. master branch
"${MOZSEARCH_PATH}/tools/target/release/build-blame" gecko-dev gecko-blame
pushd gecko-blame
git gc
popd

# Build blame for the other branches. For each branch, we create
# a branch in the blame repo from the previous completed branch, so
# as to minimize the amount of new work needed. The order of branches
# in the loop is also selected to reduce unnecessary work; changing the
# order should not affect correctness but may increase redundant work.
LASTBRANCH=master
for BRANCH in beta release esr78 esr68 esr60 esr45 esr31 esr17; do
    # Start the new branch in the blame repo, using the last done
    # branch as the starting point so as to maximally reuse previous
    # results.
    pushd gecko-blame
    git branch $BRANCH $LASTBRANCH
    popd

    echo "Generating blame information for $BRANCH..."

    BLAME_REF="refs/heads/$BRANCH" "${MOZSEARCH_PATH}/tools/target/release/build-blame" gecko-dev gecko-blame
    pushd gecko-blame
    git gc
    popd

    LASTBRANCH=$BRANCH
done
