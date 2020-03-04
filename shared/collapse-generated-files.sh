#!/usr/bin/env bash

set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# Given a generated file, this script checks to see if the file was the same
# for all platforms where it was generated. If so, it merges the analysis data
# from all the platforms. If not, it keeps copies of the generated file
# and their analysis data in platform-specific folders.

if [ $# -ne 1 ]; then
    echo "Usage: $0 <generated-file>"
    exit 1
fi

GENERATED_FILE=$1


function move_file {
    mkdir -p "$(dirname $2)"
    mv "$1" "$2"
}

# Check that all the files (provided as arguments) are the same, after normalizing
# Windows line endings and paths to UNIX. At least one argument must be provided.
# If all the files match, the name of the first one is echo'd, otherwise the empty
# string is echo'd.
function check_all_same {
    if [ $# -eq 0 ]; then
        # At least one arg must be provided
        return 1;
    fi
    FIRSTFILE=$1; shift;
    # Normalize to UNIX in-place. The z: absolute path comes from the taskcluster
    # working directory for Windows.
    dos2unix --quiet "$FIRSTFILE"
    sed --in-place -e "s#z:/task_[0-9]*/#/builds/worker/workspace/#gI" "$FIRSTFILE"
    while [ $# -gt 0 ]; do
        NEXTFILE=$1; shift;
        dos2unix --quiet "$NEXTFILE"
        sed --in-place -e "s#z:/task_[0-9]*/#/builds/worker/workspace/#gI" "$NEXTFILE"
        cmp --quiet "$FIRSTFILE" "$NEXTFILE"
        if [ $? -ne 0 ]; then
            # Files aren't the same, echo empty string
            echo ""
            return 0;
        fi
    done
    # All files are the same, echo any one of them
    echo "$FIRSTFILE"
    return 0;
}


ALL_SAME_AS=$(check_all_same generated-*/$GENERATED_FILE)
if [ "$ALL_SAME_AS" != "" ]; then
    echo "Generated file $GENERATED_FILE was identical across platforms where it was created"
    move_file "$ALL_SAME_AS" "objdir/$GENERATED_FILE"
    # Also merge the analyses files
    MERGED_ANALYSIS="analysis/__GENERATED__/$GENERATED_FILE"
    mkdir -p "$(dirname $MERGED_ANALYSIS)"
    RUST_LOG=info $MOZSEARCH_PATH/tools/target/release/merge-analyses analysis-*/__GENERATED__/$GENERATED_FILE > $MERGED_ANALYSIS
    exit 0
fi

# The generated file was not the same across all platforms, so
# put the different versions in __$PLATFORM__ subfolders.
for PLATFORM in linux64 macosx64 win64 android-armv7; do
    if [ ! -f "generated-$PLATFORM/$GENERATED_FILE" ]; then
        exit 0
    fi
    echo "Taking generated file $GENERATED_FILE from $PLATFORM"
    move_file "generated-$PLATFORM/$GENERATED_FILE" "objdir/__${PLATFORM}__/$GENERATED_FILE"
    if [ -f "analysis-$PLATFORM/__GENERATED__/$GENERATED_FILE" ]; then
        # Move the analysis file as well
        move_file "analysis-$PLATFORM/__GENERATED__/$GENERATED_FILE" "analysis/__GENERATED__/__${PLATFORM}__/$GENERATED_FILE"
    fi
done
