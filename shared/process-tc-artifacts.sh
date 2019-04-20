#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

if [ $# -ne 1 ]; then
    echo "Usage: $0 <platform>"
    echo " e.g.: $0 linux64"
    exit 1
fi

PLATFORM=$1
INDEX_ROOT=$PWD

if [ ! -f "$PLATFORM.mozsearch-index.zip" ]; then
    # This platform didn't have analysis data, so let's skip it
    exit 0
fi

# Unpack the C++ analysis into a platform-specific folder
mkdir -p analysis-$PLATFORM
unzip -q $PLATFORM.mozsearch-index.zip -d analysis-$PLATFORM

# These all get unpacked into the objdir directly because the files
# are already in platform-specific subfolders inside the zipfile, so there won't be any collisions. The
# rust-indexer.rs tool will take care of combining all the analysis files correctly.
unzip -q $PLATFORM.mozsearch-rust.zip -d objdir

# If INDEX_RUSTLIB was set to "yes" during fetch-tc-artifacts.sh, then
# we'll have per-platform rustlib src/analysis data in zip files, so
# let's unpack those.
if [ -f "$PLATFORM.mozsearch-rust-stdlib.zip" ]; then
    # These zips have a rustlib top-level folder and then contain the
    # rust stdlib src (all the zips have the same src tree) and analysis
    # data for the platform. We unpack all the zips into the same
    # destination folder, implicitly merging them. And we copy the stdlib
    # src tree into the objdir and (ab)use the generated files machinery.
    unzip -qn $PLATFORM.mozsearch-rust-stdlib.zip -d .
    if [ ! -d "objdir/__RUST__" ]; then
        mkdir -p "objdir/__RUST__"
        cp -Rn rustlib/src/rust/src objdir/__RUST__/
    fi
fi

# Unpack generated sources tarballs into platform-specific folder
mkdir -p generated-$PLATFORM
tar -x -z -C generated-$PLATFORM -f $PLATFORM.generated-files.tar.gz

date

# Process the dist/include manifest and normalize away the taskcluster paths
dos2unix --quiet --force $PLATFORM.distinclude.map  # need --force because of \x1f column separator chars in the file
MAPVERSION=$(head -n 1 $PLATFORM.distinclude.map)
if [ "$MAPVERSION" != "5" ]; then
    echo "WARNING: $PLATFORM.distinclude.map had unexpected version [$MAPVERSION]; check for changes in python/mozbuild/mozpack/manifests.py."
fi
sed --in-place -e "s#/builds/worker/workspace/build/src/##g" $PLATFORM.distinclude.map
sed --in-place -e "s#z:/task_[0-9]*/build/src/##g" $PLATFORM.distinclude.map

date

# Special cases - buildid.h and mozilla-config.h show up in two places in a regular
# objdir and the analysis tarball will correspondingly also have two instances of
# the analysis file. The generated-files tarball only has one copy, so we manually
# make the other copy to make things match up. The best would be if the gecko build
# system didn't actually produce two copies of these files.
cp generated-$PLATFORM/buildid.h        generated-$PLATFORM/dist/include/buildid.h
cp generated-$PLATFORM/mozilla-config.h generated-$PLATFORM/dist/include/mozilla-config.h

# We get analysis data for generated files, some of which aren't included
# in the generated-files tarball that we get from taskcluster. Most of these
# missing files are dummy unified build files that we don't care about, and
# we can just delete those.
# If there are other such cases, then we'll get zero-byte files generated by
# output-file.rs since it won't be able to find the source file corresponding to
# the analysis file. In those cases we should ensure the generated file is
# included in the target.generated-files.tar.gz tarball that comes out of the
# taskcluster indexing job. Bug 1440879 can be used as a guide.
pushd analysis-$PLATFORM/__GENERATED__
set +x  # Turn off echoing of commands and output only relevant things to avoid bloating logfiles
find . -type f -name "Unified*" |
while read GENERATED_ANALYSIS; do
    if [ ! -f "$INDEX_ROOT/generated-$PLATFORM/$GENERATED_ANALYSIS" ]; then
        echo "Remove unified compilation generated-file $GENERATED_ANALYSIS"
        rm "$GENERATED_ANALYSIS"
    fi
done
set -x
popd

date

# On Windows, analysis for headers ends up in __GENERATED__/dist/include/...
# instead of the source version of the file. This happens because Windows doesn't
# support symlinks, and so during the build, headers are copied rather than
# symlinked into dist/include. When clang processes the source files, it therefore
# can't "dereference" the symlinks (because they're not symlinks) to find the
# original source file. This results in the misplaced analysis data. To handle
# this, we use the distinclude mapfile produced by the taskcluster job to
# squash the analysis data for such files back to the source file that it belongs
# with. The "squash" is just appending the analysis data from the dist/include
# version to the analysis data (if it exists) for the real source. The step
# to merge the analyses across platforms later in this script will deduplicate
# any redundant lines.
# Note also that this hunk of code currently does nothing on Linux/Mac, since
# don't suffer from this problem. The code is run anyway for completeness.
pushd analysis-$PLATFORM/__GENERATED__/dist/include
set +x  # Turn off echoing of commands and output only relevant things to avoid bloating logfiles
find . -type f |
while read GENERATED_ANALYSIS; do
    if [ ! -f "$INDEX_ROOT/generated-$PLATFORM/dist/include/$GENERATED_ANALYSIS" ]; then
        # Found analysis file in __GENERATED__/dist/include for which there is
        # no corresponding generated source. Let's check the mapfile to see if
        # the source is elsewhere. The awk command searches the mapfile, assuming
        # columns are separated by the \x1f character, looking for the first match
        # where the second column (with a "./" prefixed) is the same as
        # $GENERATED_ANALYSIS. If a match is found, it emits the third column, which
        # is the path of the source tree relative to the gecko-dev root (because of
        # the normalization step after downloading the file).
        REAL_SOURCE=$(awk -F '\x1f' -v KEY="$GENERATED_ANALYSIS" 'KEY == "./" $2 { print $3; exit }' ../../../../$PLATFORM.distinclude.map)
        if [ -f "$INDEX_ROOT/gecko-dev/$REAL_SOURCE" ]; then
            # Found the real source file this analysis data is for, so let's squash it over
            ANALYSIS_FOR_SOURCE="$INDEX_ROOT/analysis-$PLATFORM/$REAL_SOURCE"
            echo "Squashing analysis for __GENERATED__/dist/include/$GENERATED_ANALYSIS into analysis-$PLATFORM/$REAL_SOURCE"
            mkdir -p $(dirname "$ANALYSIS_FOR_SOURCE")
            cat "$GENERATED_ANALYSIS" >> "$ANALYSIS_FOR_SOURCE"
            rm "$GENERATED_ANALYSIS"
        else
            echo "Real source [$REAL_SOURCE] for dist/include/$GENERATED_ANALYSIS was not found or was not a file"
        fi
    fi
done
set -x
popd

date

# Also drop any directories that got emptied as a result
pushd analysis-$PLATFORM/__GENERATED__
find . -depth -type d -empty -delete
popd

pushd generated-$PLATFORM
find . -type f >> ../generated-files-$PLATFORM.list
popd

# List all the analysis files we have left. We will merge these across platforms
# after this per-platform loop is complete. Make sure to skip over the __GENERATED__
# directory
pushd analysis-$PLATFORM
find . -not \( -name __GENERATED__ -prune \) -type d >> ../analysis-dirs-$PLATFORM.list
find . -not \( -name __GENERATED__ -prune \) -type f >> ../analysis-files-$PLATFORM.list
popd
