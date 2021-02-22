#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

if [[ -z $MOZSEARCH_PATH ]]; then
    echo "MOZSEARCH_PATH needs to be defined for this script" > /dev/stderr
    exit 1
fi

# Options
UPLOAD=no
UPLOAD_INPLACE=no
GIT_REPO_DIR=git
BLAME_REPO_DIR=blame
TARBALL_BASE=
BRANCHES=

# PArse command-line options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            set +x
            (
                echo "$0 --tarball-base <base> [--git-repo-dir <dir>] [--blame-repo-dir <dir>]"
                echo "   [--upload [--in-place]] [--branches 'branch1 branch2 [...]']"
                echo ""
                echo "This script downloads the git tarball from the S3 bucket and builds a corresponding blame"
                echo "repo tarball, optionally uploading it back to the S3 bucket."
                echo "Arguments:"
                echo "  --tarball-base The base name of the git repo tarball. e.g. provide 'foo' if the tarball"
                echo "           holding the git repo is called foo.tar. The generated blame tarball will then"
                echo "           be named foo-blame.tar. This argument is required"
                echo "  --git-repo-dir The folder holding the git repo inside the git tarball. Defaults to 'git'"
                echo "  --blame-repo-dir The folder to hold the blame repo inside the blame tarball. Defaults to 'blame'"
                echo "  --upload Flag that enables re-uploading of the generated blame tarball back to the S3 bucket."
                echo "           See also the --in-place option for details on the upload."
                echo "  --in-place If this flag is specified, any pre-existing blame tarball in the S3 bucket will be"
                echo "           copied to the backups/ folder, and then the newly generated blame tarball will"
                echo "           overwrite the original."
                echo "           If this flag is not specified, the blame tarball will be uploaded as <base>-blame-new.tar,"
                echo "           so that it does not clobber the existing blame tarball."
                echo "  --branches A space-separate ordered list of branches to build blame for, after the HEAD"
                echo "           branch is built"
                echo ""
            )>/dev/stderr
            set -x
            exit 0
            ;;
        --tarball-base)
            TARBALL_BASE="$2"
            shift
            shift
            ;;
        --git-repo-dir)
            GIT_REPO_DIR="$2"
            shift
            shift
            ;;
        --blame-repo-dir)
            BLAME_REPO_DIR="$2"
            shift
            shift
            ;;
        --upload)
            UPLOAD=yes
            shift
            ;;
        --in-place)
            UPLOAD_INPLACE=yes
            shift
            ;;
        --branches)
            BRANCHES="$2"
            shift
            shift
            ;;
        *)
            echo "Unknown argument $1. Try running $0 --help" > /dev/stderr
            exit 1
            ;;
    esac
done

if [[ -z "$TARBALL_BASE" ]]; then
    echo "No tarball base provided. Try running $0 --help" > /dev/stderr
    exit 1
fi

curl -sSfL "https://s3-us-west-2.amazonaws.com/searchfox.repositories/${TARBALL_BASE}.tar" -o "${TARBALL_BASE}.tar"
tar xf "${TARBALL_BASE}.tar"

# Init a new blame repo
mkdir "${BLAME_REPO_DIR}"
pushd "${BLAME_REPO_DIR}"
git init .
popd

# Build blame for HEAD, i.e. master branch
"${MOZSEARCH_PATH}/tools/target/release/build-blame" "${GIT_REPO_DIR}" "${BLAME_REPO_DIR}"

LASTBRANCH="HEAD"
for BRANCH in $BRANCHES; do
    # Start the new branch in the blame repo, using the last done
    # branch as the starting point so as to maximally reuse previous
    # results.
    pushd "${BLAME_REPO_DIR}"
    git branch "${BRANCH}" "${LASTBRANCH}"
    popd

    echo "Generating blame information for ${BRANCH}..."
    BLAME_REF="refs/heads/${BRANCH}" "${MOZSEARCH_PATH}/tools/target/release/build-blame" "${GIT_REPO_DIR}" "${BLAME_REPO_DIR}"

    LASTBRANCH="${BRANCH}"
done

pushd "${BLAME_REPO_DIR}"
git gc --aggressive
popd

tar cf "${TARBALL_BASE}-blame.tar" "${BLAME_REPO_DIR}"
rm -rf "${GIT_REPO_DIR}" "${BLAME_REPO_DIR}"

if [[ "$UPLOAD" == "yes" ]]; then
    if [[ "$UPLOAD_INPLACE" == "yes" ]]; then
        # Copy the existing blame tarball into the backups folder
        aws s3 cp "s3://searchfox.repositories/${TARBALL_BASE}-blame.tar" "s3://searchfox.repositories/backups/${TARBALL_BASE}-blame.tar" --acl public-read || true
        aws s3 cp "./${TARBALL_BASE}-blame.tar" "s3://searchfox.repositories/${TARBALL_BASE}-blame.tar" --acl public-read
    else
        aws s3 cp "./${TARBALL_BASE}-blame.tar" "s3://searchfox.repositories/${TARBALL_BASE}-blame-new.tar" --acl public-read
    fi
fi
