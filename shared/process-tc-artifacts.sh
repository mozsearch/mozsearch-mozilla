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

# Unpack the rust save-analysis files into a platform-specific folder.  These
# are not analysis files (yet) and these came from an objdir, so we call it an
# objdir.
#
# Note that the paths inside the zip files are already platform-specific, so
# we're not worried about collisions.  The issue is that the identifiers used
# inside the save-analysis files are not globally unique, so if rust-indexer.rs
# is presented with different save-analysis files for multiple platforms then
# the result will end up corrupt if there were any differences between the
# platforms.
#
# By splitting the rust files up into separate directories, we make it easier
# to both normalize these JSON files (they include absolute file paths) and
# run rust-indexer.rs on them without having to perform complicated path
# filtering.
mkdir -p objdir-$PLATFORM
unzip -q $PLATFORM.mozsearch-rust.zip -d objdir-$PLATFORM

# If we have per-platform rustlib src/analysis data, unpack those as well.
if [ -f "$PLATFORM.mozsearch-rust-stdlib.zip" ]; then
    # These zips have a rustlib top-level folder and then contain the
    # rust stdlib src (all the zips have the same src tree) and save-analysis
    # data for the platform.  We copy the stdlib src tree into the
    # (non-platform-specific) objdir to (ab)use the generated files machinery.
    unzip -qn $PLATFORM.mozsearch-rust-stdlib.zip -d objdir-$PLATFORM
    # Attempt to deal with the other platforms racing against us on this by
    # using the act of creation of the directory as creating a lock on copying
    # the files over.
    #
    # Note: The rust-indexer job intentionally is not consulting the source
    # files in this directory, this is only being done for the benefit of the
    # output-file machinery which runs after all of the parallel invocations of
    # this script complete.
    mkdir "objdir/__RUST__" && cp -Rn objdir-$PLATFORM/rustlib/src/rust/src/* objdir/__RUST__/ || true
fi

# Unpack generated sources tarballs into platform-specific folder
mkdir -p generated-$PLATFORM
tar -x -z -C generated-$PLATFORM -f $PLATFORM.generated-files.tar.gz

date

# Normalize the rust save-analysis files so that instead of having absolute
# paths they have searchfox-normalized paths where source paths have no prefix
# and objdir paths start with __GENERATED__.

# Rust stdlib looks like either "src/libstd/num.rs" on linux or
# "src\\libstd\\num.rs" on windows.  We normalize to __GENERATED__/__RUST__.
# We do this normalization first because there's no "src" directory at the root
# of mozilla-central, so we can safely assume that if we have a relative path
# that starts with "src/" that it's rust code.  Hopefully.  (If we did it later,
# we'd be seeing the results of other absolute path normalizations.)
NORMALIZE_EXPR='s#"src[/\\]#"__GENERATED__/__RUST__/#gI'
# For some reason we see generated paths under checkouts like:
# /builds/worker/checkouts/gecko/obj-arm-unknown-linux-androideabi/dist/xpcrs/rt/nsIChannel.rs
# Handle this, and do it before we do the source normalization in the next line.
NORMALIZE_EXPR+=';s#/builds/worker/checkouts/gecko/obj-[-a-zA-Z0-9_]+/#__GENERATED__/#g'
# Non-windows source paths get normalized off.
NORMALIZE_EXPR+=';s#/builds/worker/checkouts/gecko/##g'
# Non-windows build paths get normalized to __GENERATED__.
NORMALIZE_EXPR+=';s#/builds/worker/workspace/obj-build/#__GENERATED__/#g'
# I haven't actually seen the same weird source path with "obj-*" under it on
# Windows yet, but let's proactively assume such a thing will happen and add
# the following regexp just in case.  But right now nsIChannel.rs on Windows
# looks like: "z:/task_1589882903/workspace/obj-build/dist/xpcrs/rt/nsIChannel.rs"
# Note that the '+' needs a backslash because sed.
NORMALIZE_EXPR+=';s#z:[/\\]task_[0-9]*[/\\]build[/\\]src[/\\]obj-[-a-zA-Z0-9_]+[/\\]#__GENERATED__/#gI'
# Windows source paths get normalized off.
NORMALIZE_EXPR+=';s#z:[/\\]task_[0-9]*[/\\]build[/\\]src[/\\]##gI'
# Windows build paths get normalized to __GENERATED__, noting we don't consume
# the trailing slash.
NORMALIZE_EXPR+=';s#z:[/\\]task_[0-9]*[/\\]workspace[/\\]obj-build[/\\]#__GENERATED__/#gI'
# We use -E in order to get extended regexp support, which is necessary to be
# able to use "+" without escaping it with a (single) backslash.
find objdir-$PLATFORM -type f -name "*.json" | parallel -q --halt now,fail=1 sed --in-place -Ee "$NORMALIZE_EXPR" {}

date

# Run the rust analysis here.
# Note that we specify "objdir" as the objdir_src for __GENERATED__ for source
# purposes because the only source that's in objdir-$PLATFORM is the rustlib
# source, and that's covered by the next line which does use objdir-$PLATFORM.
# (We also copy that source into ojbdir, but that action is racey.  See the
# comments where we perform the copying.)
export RUST_LOG=info
$MOZSEARCH_PATH/scripts/rust-analyze.sh \
  "$CONFIG_FILE" \
  "$TREE_NAME" \
  "objdir-$PLATFORM" \
  "generated-$PLATFORM" \
  "objdir-$PLATFORM/rustlib/src/rust/src" \
  "$INDEX_ROOT/analysis-$PLATFORM"

date

# Process the dist/include manifest and normalize away the taskcluster paths
dos2unix --quiet --force $PLATFORM.distinclude.map  # need --force because of \x1f column separator chars in the file
MAPVERSION=$(head -n 1 $PLATFORM.distinclude.map)
if [ "$MAPVERSION" != "5" ]; then
    echo "WARNING: $PLATFORM.distinclude.map had unexpected version [$MAPVERSION]; check for changes in python/mozbuild/mozpack/manifests.py."
fi
sed --in-place -e "$NORMALIZE_EXPR" $PLATFORM.distinclude.map

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
