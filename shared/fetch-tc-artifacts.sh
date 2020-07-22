#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

if [ $# -ne 3 ]; then
    echo "Usage: $0 <revision-tree> <hg-rev> <pre-existing-hg-rev>"
    echo " e.g.: $0 mozilla-central 588208caeaf863f2207792eeb1bd97e6c8fceed4 ''"
    exit 1
fi

REVISION_TREE=$1
INDEXED_HG_REV=$2
PREEXISTING_HG_REV=$3

# Allow caller to override what we use to download, but
# have a sane default:
# -s AKA --silent: No progress or error messages unless...
# -S AKA --show-error: Show an error message despite --silent
# -f AKA --fail: Emit nothing to standard out on server errors (which would
#                usually be a boring HTML page), returning error code 22.
# -L AKA --location: Follow redirects (using the "Location" header)
#
# Want it to be an optional call that doesn't fail the build if the file isn't
# there?  Then try:
# ${CURL} url -o outut-location || true
CURL=${CURL:-"curl -SsfL --compressed"}

# Rewrite REVISION to be a specific revision in case the "latest" pointer changes while
# we're in the midst of downloading stuff. Using a specific revision id is safer.
REVISION="${REVISION_TREE}.revision.${INDEXED_HG_REV}"

pushd $INDEX_ROOT

if [[ -n $PREEXISTING_HG_REV && $PREEXISTING_HG_REV != $INDEXED_HG_REV ]]; then
    echo "New hg revision $INDEXED_HG_REV doesn't match pre-existing hg revision $PREEXISTING_HG_REV, deleting old artifacts..."
    rm -f bugzilla-components.json
    rm -f *.mozsearch-index.zip
    rm -f *.mozsearch-rust.zip
    rm -f *.mozsearch-rust-stdlib.zip
    rm -f *.generated-files.tar.gz
    rm -f *.distinclude.map
fi

# Download the bugzilla components file and the artifacts from each platform that
# we're indexing. But do them in parallel by emitting all the curl commands into
# a file and then feeding it to GNU parallel.
echo "${CURL} https://firefox-ci-tc.services.mozilla.com/api/index/v1/task/gecko.v2.$REVISION.source.source-bugzilla-info/artifacts/public/components-normalized.json > bugzilla-components.json" > downloads.lst
echo "${CURL} https://firefox-ci-tc.services.mozilla.com/api/index/v1/task/gecko.v2.$REVISION.source.test-info-all/artifacts/public/test-info-all-tests.json -o test-info-all-tests.json || true" >> downloads.lst
echo "${CURL} https://firefox-ci-tc.services.mozilla.com/api/index/v1/task/gecko.v2.$REVISION.source.source-wpt-metadata-summary/artifacts/public/summary.json -o wpt-metadata-summary.json || true" >> downloads.lst
for PLATFORM in linux64 macosx64 win64 android-armv7; do
    TC_PREFIX="https://firefox-ci-tc.services.mozilla.com/api/index/v1/task/gecko.v2.${REVISION}.firefox.${PLATFORM}-searchfox-debug/artifacts/public/build"
    # First check that the searchfox job exists for the platform and revision we want. Otherwise emit a warning and skip it. This
    # file is small so it's cheap to download as a check that the analysis data for the platform exists.
    #
    # Also check for moz_source_stamp, to handle tasks that exists but failed. We rely on this field for resolve-gecko-revs.sh already.
    if ! (${CURL} "${TC_PREFIX}/target.json" | grep moz_source_stamp); then
        echo "WARNING: Unable to find analysis for $PLATFORM for hg rev $INDEXED_HG_REV; skipping analysis merge step for this platform."
        continue
    fi

    if [ -f "${PLATFORM}.mozsearch-index.zip" ]; then
        echo "Found pre-existing ${PLATFORM}.mozsearch-index.zip tarball, skipping re-download of this platform."
        continue
    fi

    TC_PREFIX="https://firefox-ci-tc.services.mozilla.com/api/index/v1/task/gecko.v2.${REVISION}.firefox.${PLATFORM}-searchfox-debug/artifacts/public/build"
    # C++ analysis
    echo "${CURL} ${TC_PREFIX}/target.mozsearch-index.zip > ${PLATFORM}.mozsearch-index.zip" >> downloads.lst
    # Rust save-analysis files
    echo "${CURL} ${TC_PREFIX}/target.mozsearch-rust.zip > ${PLATFORM}.mozsearch-rust.zip" >> downloads.lst
    # Rust stdlib src and analysis data
    echo "${CURL} ${TC_PREFIX}/target.mozsearch-rust-stdlib.zip > ${PLATFORM}.mozsearch-rust-stdlib.zip" >> downloads.lst
    # Generated sources tarballs
    echo "${CURL} ${TC_PREFIX}/target.generated-files.tar.gz > ${PLATFORM}.generated-files.tar.gz" >> downloads.lst
    # Manifest for dist/include entries
    echo "${CURL} ${TC_PREFIX}/target.mozsearch-distinclude.map > ${PLATFORM}.distinclude.map" >> downloads.lst
done # end PLATFORM loop

# Do the downloads
parallel --halt now,fail=1 < downloads.lst

# Clean out any artifacts left over from previous runs
rm -rf analysis && mkdir -p analysis
rm -rf objdir && mkdir -p objdir

popd
