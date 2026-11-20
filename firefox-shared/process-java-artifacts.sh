#!/usr/bin/env bash

# NOTE: like process-tc-artifacts.sh, this may run in parallel, and the step
#       logs cannot be used.

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# A platform's Java and Kotlin analysis alone (process-tc-artifacts.sh's Java
# step), for a tree that indexes other platforms' C++ but this platform's
# Java and Kotlin, which only its build compiles: firefox-try, whose C++ is
# linux64's, and whose Java and Kotlin are android-aarch64's (see
# GECKO_JAVA_PLATFORMS in process-gecko-analysis.sh).  Its analysis-<platform>
# then only has Java and Kotlin files, so merging it with the other
# platforms' (which have none) changes nothing else.
#
# Usage: process-java-artifacts.sh <platform>

if [ $# -ne 1 ]; then
    echo "Usage: $0 <platform>"
    exit 1
fi

PLATFORM=$1

if [ ! -f "$PLATFORM.mozsearch-java-index.zip" ]; then
    echo "WARNING: no $PLATFORM.mozsearch-java-index.zip, so no Java or Kotlin analysis."
    exit 0
fi

mkdir -p objdir-$PLATFORM/java_index analysis-$PLATFORM
unzip -q $PLATFORM.mozsearch-java-index.zip -d objdir-$PLATFORM/java_index
if [ -d objdir-$PLATFORM/java_index/META-INF/semanticdb ]; then
    scip-java-semanticdb index-semanticdb --no-emit-inverse-relationships --output=objdir-$PLATFORM/java.scip objdir-$PLATFORM/java_index
else
    scip-java aggregate --no-emit-inverse-relationships --output=objdir-$PLATFORM/java.scip objdir-$PLATFORM/java_index
fi

RUST_LOG=info scip-indexer \
    "$CONFIG_FILE" \
    "$TREE_NAME" \
    --subtree-root "." \
    --platform "$PLATFORM" \
    "objdir-$PLATFORM/java.scip"

# (process-gecko-analysis.sh merges the platforms' listed files.)
pushd analysis-$PLATFORM
find . -not \( -name __GENERATED__ -prune \) -type d >> ../analysis-dirs-$PLATFORM.list
find . -not \( -name __GENERATED__ -prune \) -type f >> ../analysis-files-$PLATFORM.list
popd
touch generated-files-$PLATFORM.list
