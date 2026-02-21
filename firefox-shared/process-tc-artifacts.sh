#!/usr/bin/env bash

# NOTE: process-tc-artifacts.sh is executed in parallel, and the step logs
#       cannot be used.

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

date

if [ -f "$PLATFORM.mozsearch-rust.zip" ]; then
  unzip -q $PLATFORM.mozsearch-rust.zip -d objdir-$PLATFORM
fi

date

if [ -f "$PLATFORM.mozsearch-scip-index.zip" ]; then
  unzip -q $PLATFORM.mozsearch-scip-index.zip -d objdir-$PLATFORM
  mv objdir-$PLATFORM/index.scip objdir-$PLATFORM/rust.scip
fi

date

if [ -f "$PLATFORM.mozsearch-java-index.zip" ]; then
  mkdir -p objdir-$PLATFORM/java_index
  unzip -q $PLATFORM.mozsearch-java-index.zip -d objdir-$PLATFORM/java_index
  scip-java index-semanticdb --no-emit-inverse-relationships --output=objdir-$PLATFORM/java.scip objdir-$PLATFORM/java_index
fi

date

# Unpack generated sources tarballs into platform-specific folder
mkdir -p generated-$PLATFORM
tar -x -z -C generated-$PLATFORM -f $PLATFORM.generated-files.tar.gz

date

# ### Normalize generated source files by rust build-scripts. ###
#
# These will look like:
#   x86_64-unknown-linux-gnu/debug/build/cranelift-codegen-17ba72a9572695af/out/binemit-x86.rs
# which can be generalized to:
#   ${RUST_PLATFORM}/${BUILD_TYPE}/build/${CRATE_NAME}-${CRATE_HASH}/out/${FILE_PATH}
# and which we want to end up with the following path scheme inside this
# platform specific directory:
#   __RUST_BUILD_SCRIPT__/${CRATE_NAME}/${FILE_PATH}
# which will in the end look like (where __linux64__ varies per platform):
#   __GENERATED__/__linux64__/__RUST_BUILD_SCRIPT__/${CRATE_NAME}/${FILE_PATH}
#
# It's also necessary for similar translations to be performed when performing
# fixups against the save-analysis files.

# Do all of this in the generated-$PLATFORM directory.
pushd generated-$PLATFORM

declare -A RUST_PLAT_DIRS
RUST_PLAT_DIRS["linux64"]="x86_64-unknown-linux-gnu"
RUST_PLAT_DIRS["linux64-opt"]="x86_64-unknown-linux-gnu"
RUST_PLAT_DIRS["macosx64"]="x86_64-apple-darwin"
RUST_PLAT_DIRS["macosx64-aarch64"]="aarch64-apple-darwin"
RUST_PLAT_DIRS["macosx64-aarch64-opt"]="aarch64-apple-darwin"
RUST_PLAT_DIRS["win64"]="x86_64-pc-windows-msvc"
RUST_PLAT_DIRS["win64-opt"]="x86_64-pc-windows-msvc"
RUST_PLAT_DIRS["android-armv7"]="thumbv7neon-linux-androideabi"
RUST_PLAT_DIRS["android-aarch64"]="aarch64-linux-android"
RUST_PLAT_DIRS["ios"]="aarch64-apple-ios"
RUST_PLATFORM=${RUST_PLAT_DIRS[$PLATFORM]}

function move_file {
    mkdir -p "$(dirname $2)"
    mv "$1" "$2"
}

# Use sed to get a list of all files that match the patterns we specify above
# and print out ONLY those files, with each resulting line containing the
# source path followed by a space followed by the target path.  We will then
# move the files to their target using the `move_file` helper from above which
# will create the directories as needed.
#
# Note that things may very well break if the paths start having spaces inside
# them.  In which case some kind of quoting an unquoting will become necessary,
# but I'm not implementing that ahead of time because it's very easy to shoot
# oneself in the foot when adding quoting.
#
# note that we use "p" to print the output which would not otherwise appear.
PATH_TRANSFORM="s#^(${RUST_PLATFORM}/(debug|release)/build/([^/]+)-[0-9a-f]+/out/(.+))\$#\1 __RUST_BUILD_SCRIPT__/\3/\4#p"
# -n: Causes no output except the "p" for print directive in the expression.
# -E: extended regexps, don't have to backslash escape things like `+`
# -e: The actual expression to run
find "$RUST_PLATFORM" -type f | sed -nEe "$PATH_TRANSFORM" | while read -r source target; do
  move_file "$source" "$target"
done

# leave the generated-$PLATFORM directory
popd

date

# If we have per-platform rustlib src/analysis data, unpack those as well.
if [ -f "$PLATFORM.mozsearch-rust-stdlib.zip" ]; then
    # These zips have a rustlib top-level folder and then contain the
    # rust stdlib src (all the zips have the same src tree) and save-analysis
    # data for the platform.  We leave the save-analysis data in
    # objdir-$PLATFORM but...
    unzip -qn $PLATFORM.mozsearch-rust-stdlib.zip -d objdir-$PLATFORM

    # ...We move the stdlib src tree into the generated-$PLATFORM directory so
    # that rust-indexer can find the source to match it up to the analysis data.
    # The collapse-generated-files.sh magic will unify the source files and the
    # analysis files for us, handling any deviations between platforms.
    #
    # All of the lib* directories live under rustlib/src/rust/src in the zip,
    # so we just move that to be the __RUST_STDLIB__ directory.
    # In rust-src-1.47 the folder structure changed to have "library" instead
    # of "src", so we try both here, since this code needs to work with rust
    # versions before and after 1.47.
    mv -f objdir-$PLATFORM/rustlib/src/rust/library generated-$PLATFORM/__RUST_STDLIB__ ||
        mv -f objdir-$PLATFORM/rustlib/src/rust/src generated-$PLATFORM/__RUST_STDLIB__
fi

date

# ### Normalize save-analysis files ###
#
# Normalize the rust save-analysis files so that instead of having absolute
# paths they have searchfox-normalized paths where source paths have no prefix
# and objdir paths start with __GENERATED__.

# Rust stdlib looks like either "src/libstd/num.rs" on linux or
# "src\\libstd\\num.rs" on windows, prior to 1.47. 1.47 and up has "library"
# instead of "src"..  We normalize to __GENERATED__/__RUST_STDLIB__.
# We do this normalization first because there's no "src"/"library" directory at the root
# of mozilla-central, so we can safely assume that if we have a relative path
# that starts with "src/" or "library" that it's rust code.  Hopefully.  (If we did it later,
# we'd be seeing the results of other absolute path normalizations.)
#
# Note: We have now moved our pattern from `"foo` to `:"foo` because this
# naive sed transform got tricked by a rust comment which contained the example
# code `let src = fs::metadata("src")?;` and which then ends up in JSON as
# `let src = fs::metadata(\"src\")?;` and which our aggregate transforms ended
# up converting into corrupt JSON:
# `"value":"/     let src = fs::metadata(\"__GENERATED__/__RUST_STDLIB__/")?;",`
# where we ate what we thought was a trailing directory backslash but was in
# fact an escaping backslash!
#
# We do this in this manner because sed doesn't support lookaround constraints
# which means we need to actually match on the surrounding JSON.
#
# If we end up needing to do more of this stuff in the future, we should switch
# to using something that actually understands JSON, but with save-analysis
# going away, we ideally won't need to deal with that.
NORMALIZE_EXPR='s#:"src[/\\]+#:"__GENERATED__/__RUST_STDLIB__/#gI'
NORMALIZE_EXPR+=';s#:"library[/\\]+#:"__GENERATED__/__RUST_STDLIB__/#gI'
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
NORMALIZE_EXPR+=';s#z:[/\\]+task_[0-9]*[/\\]+build[/\\]+src[/\\]+obj-[-a-zA-Z0-9_]+[/\\]+#__GENERATED__/#gI'
# Windows source paths get normalized off.
NORMALIZE_EXPR+=';s#z:[/\\]+task_[0-9]*[/\\]+build[/\\]+src[/\\]+##gI'
# Windows build paths get normalized to __GENERATED__, noting we don't consume
# the trailing slash.
NORMALIZE_EXPR+=';s#z:[/\\]+task_[0-9]*[/\\]+workspace[/\\]+obj-build[/\\]+#__GENERATED__/#gI'
# Apply the equivalent of the __RUST_BUILD_SCRIPT__ transform from the preceding
# section.  The regexp is double-quote aware so that we can avoid the filename
# capture group escaping beyond the bounds of the quoted string.  To this end,
# we leverage the fact that we can mix types of quoting.  '"quoted"'"$FOO" is
# effectively the same as "\"quoted\"$foo" but we don't need to escape the
# quotes.  We wrap everything but "${RUST_PLATFORM}" in single-quotes below.
NORMALIZE_EXPR+=';s#:"__GENERATED__/'"${RUST_PLATFORM}"'/(debug|release)/build/([^/]+)-[0-9a-f]+/out/([^"]+)"#:"__GENERATED__/__RUST_BUILD_SCRIPT__/\2/\3"#g'

# We use -E in order to get extended regexp support, which is necessary to be
# able to use "+" without escaping it with a (single) backslash.
find objdir-$PLATFORM -type f -name "*.json" | parallel -q --halt now,fail=1 sed --in-place -Ee "$NORMALIZE_EXPR" {}

date


## Run the SCIP analysis here.

# Note that we specify "objdir" as the objdir_src for __GENERATED__ for source
# purposes because the only source that's in objdir-$PLATFORM is the rustlib
# source, and that's covered by the next line which does use objdir-$PLATFORM.
# (We also copy that source into ojbdir, but that action is racey.  See the
# comments where we perform the copying.)
export RUST_LOG=info
scip-indexer \
  "$CONFIG_FILE" \
  "$TREE_NAME" \
  --subtree-root "." \
  --platform "$PLATFORM" \
  "objdir-$PLATFORM/rust.scip"

date

# Only android builds will have a java.scip
if [ -f "objdir-$PLATFORM/java.scip" ]; then
  scip-indexer \
    "$CONFIG_FILE" \
    "$TREE_NAME" \
    --subtree-root "." \
    --platform "$PLATFORM" \
    "objdir-$PLATFORM/java.scip"

  date
fi

# Process the dist/include manifest and normalize away the taskcluster paths
dos2unix --quiet --force $PLATFORM.distinclude.map  # need --force because of \x1f column separator chars in the file
MAPVERSION=$(head -n 1 $PLATFORM.distinclude.map)
if [ "$MAPVERSION" != "5" ]; then
    echo "WARNING: $PLATFORM.distinclude.map had unexpected version [$MAPVERSION]; check for changes in python/mozbuild/mozpack/manifests.py."
fi
sed --in-place -Ee "$NORMALIZE_EXPR" $PLATFORM.distinclude.map

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
        if [ -f "$GIT_ROOT/$REAL_SOURCE" ]; then
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
