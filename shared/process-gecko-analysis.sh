#!/usr/bin/env bash

# This is the pre-https://github.com/mozilla-firefox/firefox support

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# No arguments needed to this script. It just needs $CONFIG_REPO
# and $MOZSEARCH_PATH defined in the environment.

# Process the downloads for each platform in parallel
echo "Performing build::process-tc-artifacts step for $TREE_NAME : $(date +"%Y-%m-%dT%H:%M:%S%z")"
echo "linux64 linux64-opt macosx64 macosx64-aarch64 macosx64-aarch64-opt win64 win64-opt android-armv7 android-aarch64 ios" | tr " " "\n" |
parallel --halt now,fail=1 "$CONFIG_REPO/shared/process-tc-artifacts.sh {}"

# Combine the per-platform list files
cat generated-files-*.list > generated-files.list
cat analysis-files-*.list > analysis-files.list
cat analysis-dirs-*.list > analysis-dirs.list

# Special case: xptdata.cpp is a giant file and is different for each platform, but
# the differences are not particularly relevant so let's just keep the Linux one.
echo "Performing build::rm-xptdata step for $TREE_NAME : $(date +"%Y-%m-%dT%H:%M:%S%z")"
for PLATFORM in linux64-opt macosx64 macosx64-aarch64 macosx64-aarch64-opt win64 win64-opt android-armv7 android-aarch64; do
    rm -f generated-${PLATFORM}/xpcom/reflect/xptinfo/xptdata.cpp
    rm -f analysis-${PLATFORM}/__GENERATED__/xpcom/reflect/xptinfo/xptdata.cpp
done

# For each generated file, if all platforms generated the same thing (or didn't
# generate the file at all due to being a platform-specific feature), copy it to
# the merged objdir.
echo "Performing build::collapse-generated-files step for $TREE_NAME : $(date +"%Y-%m-%dT%H:%M:%S%z")"
sort generated-files.list | uniq | parallel --halt now,fail=1 "$CONFIG_REPO/shared/collapse-generated-files.sh {}"

# Finally, merge the analysis files for the non-generated source files. All the files
# are going to be listed in the analysis-files.list, possibly duplicated across
# platforms, so we deduplicate the filenames and merge each filename across platforms.
echo "Performing build::merge-analyses step for $TREE_NAME : $(date +"%Y-%m-%dT%H:%M:%S%z")"
sort analysis-dirs.list | uniq | parallel --halt now,fail=1 'mkdir -p analysis/{}'
sort analysis-files.list | uniq | parallel --halt now,fail=1 "RUST_LOG=info merge-analyses analysis-*/{} > analysis/{}"

# Delete the generated-* and analysis-* directories, but retain the tarballs
# for ease of investigation.  (The tarballs are still available from taskcluster
# though, and fetch-tc-artifcats.sh knows how to re-fetch them, so if we don't
# want to waste the space, we could just make it easier to re-fetch them so
# there's a one-liner in mozsearch's `docs/aws.md`.)
echo "Performing build::rm-generated-and-analysis step for $TREE_NAME : $(date +"%Y-%m-%dT%H:%M:%S%z")"
rm -rf generated-*/
rm -rf analysis-*/
