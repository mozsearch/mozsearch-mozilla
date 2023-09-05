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
    rm -r *.mozsearch-scip-index.zip
    rm -f *.generated-files.tar.gz
    rm -f *.distinclude.map
fi

# Download the bugzilla components file and the artifacts from each platform that
# we're indexing. But do them in parallel by emitting all the curl commands into
# a file and then feeding it to GNU parallel.

TC_TASK="https://firefox-ci-tc.services.mozilla.com/api/index/v1/task"
TC_REV_PREFIX="${TC_TASK}/gecko.v2.${REVISION}"
TC_LATEST_PREFIX="${TC_TASK}/gecko.v2.${REVISION_TREE}.latest"

# The components job periodically fails when someone adds a new file to the tree
# without ensuring there's a moz.build file that covers it, so we fail over to
# using the "latest" version of the components file in that case when we don't
# have the data for the exact revision.  This means some files may have stale or
# missing "File a bug..." UI in the navigation panel, but this is acceptable.
echo "${CURL} ${TC_REV_PREFIX}.source.source-bugzilla-info/artifacts/public/components-normalized.json -o bugzilla-components.json \
   || ${CURL} ${TC_LATEST_PREFIX}.source.source-bugzilla-info/artifacts/public/components-normalized.json -o bugzilla-components.json" > downloads.lst
echo "${CURL} ${TC_REV_PREFIX}.source.test-info-all/artifacts/public/test-info-all-tests.json -o test-info-all-tests.json || true" >> downloads.lst
# Right now the WPT metadata job explicitly only runs when files it is interested
# in have changed.  So if we can't find the specific revision of interest, let's
# just fail over to latest.  Because this is per-tree, there ideally shouldn't
# be insane inconsistencies.
echo "${CURL} ${TC_REV_PREFIX}.source.source-wpt-metadata-summary/artifacts/public/summary.json -o wpt-metadata-summary.json || \
      ${CURL} ${TC_LATEST_PREFIX}.source.source-wpt-metadata-summary/artifacts/public/summary.json -o wpt-metadata-summary.json || true" >> downloads.lst
# WPT MANIFEST.json files generated via
# https://searchfox.org/mozilla-central/source/taskcluster/ci/source-test/wpt-manifest.yml
#
# Similar to the WPT metadata jobs above, these currently only get built on changes,
# but it turns out we just aren't setting dependencies correctly in our taskcluster
# m-c jobs, so we can address this.
#
# Note that these end up in a tarball and we need to extract these, etc.
echo "${CURL} ${TC_REV_PREFIX}.source.manifest-upload/artifacts/public/manifests.tar.gz -o wpt-manifests.tar.gz || \
      ${CURL} ${TC_LATEST_PREFIX}.source.manifest-upload/artifacts/public/manifests.tar.gz -o wpt-manifests.tar.gz || true" >> downloads.lst

# Coverage data currently requires that we use the exact version or not use any
# coverage data because mozilla-central's merges will usually involve a ton of
# patches, making stale data potentially very misleading.  See Bug 1677903 for
# more discussion.
echo "${CURL} ${TC_TASK}/project.relman.code-coverage.production.repo.${REVISION_TREE}.${INDEXED_HG_REV}/artifacts/public/code-coverage-report.json -o code-coverage-report.json || true" >> downloads.lst
for PLATFORM in linux64 macosx64 win64 android-armv7 ios; do
    TC_PREFIX="${TC_REV_PREFIX}.firefox.${PLATFORM}-searchfox-debug/artifacts/public/build"
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

    # C++ analysis
    echo "${CURL} ${TC_PREFIX}/target.mozsearch-index.zip -o ${PLATFORM}.mozsearch-index.zip" >> downloads.lst
    # Rust save-analysis files
    echo "${CURL} ${TC_PREFIX}/target.mozsearch-rust.zip -o ${PLATFORM}.mozsearch-rust.zip || true" >> downloads.lst
    # Rust stdlib src and analysis data
    echo "${CURL} ${TC_PREFIX}/target.mozsearch-rust-stdlib.zip -o ${PLATFORM}.mozsearch-rust-stdlib.zip || true" >> downloads.lst
    # Rust scip files
    if [[ -n "${SCIP_OPTIONAL:-}" ]]; then
        # ESR 102 doesn't have these files, so let it be optional there.
        echo "${CURL} ${TC_PREFIX}/target.mozsearch-scip-index.zip -o ${PLATFORM}.mozsearch-scip-index.zip || true" >> downloads.lst
    else
        echo "${CURL} ${TC_PREFIX}/target.mozsearch-scip-index.zip -o ${PLATFORM}.mozsearch-scip-index.zip" >> downloads.lst
    fi
    # Generated sources tarballs
    echo "${CURL} ${TC_PREFIX}/target.generated-files.tar.gz -o ${PLATFORM}.generated-files.tar.gz" >> downloads.lst
    # Manifest for dist/include entries
    echo "${CURL} ${TC_PREFIX}/target.mozsearch-distinclude.map -o ${PLATFORM}.distinclude.map" >> downloads.lst
done # end PLATFORM loop

# Do the downloads
parallel --halt now,fail=1 < downloads.lst

# Clean out any artifacts left over from previous runs
rm -rf analysis && mkdir -p analysis
rm -rf objdir && mkdir -p objdir

# Extract the WPT MANIFEST.json files and rename them if we have them.
if [[ -f wpt-manifests.tar.gz ]]; then
    mkdir manifest-extract
    pushd manifest-extract
    tar xvzf ../wpt-manifests.tar.gz
    mv meta/MANIFEST.json ../wpt-manifest.json || true
    mv mozilla/meta/MANIFEST.json ../wpt-mozilla-manifest.json || true
    popd
    rm -rf manifest-extract
fi

popd
