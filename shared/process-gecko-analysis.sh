#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# No arguments needed to this script. It just needs $CONFIG_REPO
# and $MOZSEARCH_PATH defined in the environment.

# Process the downloads for each platform in parallel
echo "linux64 macosx64 win64 android-armv7" | tr " " "\n" |
parallel --halt now,fail=1 "$CONFIG_REPO/shared/process-tc-artifacts.sh {}"

# Combine the per-platform list files
cat generated-files-*.list > generated-files.list
cat analysis-files-*.list > analysis-files.list
cat analysis-dirs-*.list > analysis-dirs.list

date

# Special case: xptdata.cpp is a giant file and is different for each platform, but
# the differences are not particularly relevant so let's just keep the Linux one.
for PLATFORM in macosx64 win64 android-armv7; do
    rm -f generated-${PLATFORM}/xpcom/reflect/xptinfo/xptdata.cpp
    rm -f analysis-${PLATFORM}/__GENERATED__/xpcom/reflect/xptinfo/xptdata.cpp
done

# For each generated file, if all platforms generated the same thing (or didn't
# generate the file at all due to being a platform-specific feature), copy it to
# the merged objdir.
sort generated-files.list | uniq | parallel --halt now,fail=1 "$CONFIG_REPO/shared/collapse-generated-files.sh {}"

date

# Throw away any leftover per-platform generated files, and the analysis data
# for generated files. The above loop should have extracted all the useful
# information from these folders into the objdir/ and analysis/__GENERATED__/
# folders.
rm -rf generated-*
rm -rf analysis-*/__GENERATED__

# Finally, merge the analysis files for the non-generated source files. All the files
# are going to be listed in the analysis-files.list, possibly duplicated across
# platforms, so we deduplicate the filenames and merge each filename across platforms.
sort analysis-dirs.list | uniq | parallel --halt now,fail=1 'mkdir -p analysis/{}'
sort analysis-files.list | uniq | parallel --halt now,fail=1 "RUST_LOG=info $MOZSEARCH_PATH/tools/target/release/merge-analyses analysis-*/{} > analysis/{}"

date

# Free up disk space, we don't need these per-platform analysis files any more.
rm -rf analysis-*
