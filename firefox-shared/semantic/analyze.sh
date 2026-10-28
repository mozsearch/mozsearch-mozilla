#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# A try push's semantic analysis (see mozsearch's tools/src/try_delta.rs),
# for a tree indexing only linux64's analysis (firefox-try; see its setup):
# rebase the push's stack onto the indexed revision
# (mozsearch's scripts/rebase-try-push.sh), and build it in the tree's
# prepared build (see prepare.sh), starting from its pristine state: the
# export tier, and then, with the indexer, the translation units that include
# the files it changes (by the base's include map), writing their files'
# analysis (see select_tus.py and compile.py), with all but 8 of the cores,
# for the web server's sake.  That analysis, merged like the tree's (see
# ../process-gecko-analysis.sh), is the delta's (see build-try-delta).
#
# Its steps say when they start, and how long each took when it exits (see
# ../step-times.sh); compile.py says how long the translation units took.
#
# Usage: analyze.sh NAME HEAD_REV, with try_import's hook environment (see
# mozsearch's tools/src/try_import.rs): GIT_ROOT, INDEX_ROOT, CONFIG_FILE,
# TREE_NAME, and MOZSEARCH_PATH.

NAME=$1
HEAD_REV=$2
HERE=$(cd "$(dirname "$0")" && pwd)
SEM=$INDEX_ROOT/semantic
PUSH=$SEM/workspace/push
JOBS=$(nproc)
JOBS=$(( JOBS > 9 ? JOBS - 8 : 1 ))

source "$HERE/../step-times.sh"
trap 'end_steps semantic' EXIT

begin_step semantic prepare "$NAME"
# (One at a time, like try imports.)
exec 9> "$INDEX_ROOT/semantic.lock"
LOCKING=$(date +%s)
flock 9
if (( $(date +%s) - LOCKING > 0 )); then
    echo "Waited $(( $(date +%s) - LOCKING )) s for another push's semantic analysis."
fi

"$HERE/prepare.sh" "$SEM" "$GIT_ROOT" "$(jq -r .moz_source_stamp "$INDEX_ROOT/target.json")"

begin_step semantic rebase "$NAME"
BASE=$(git -C "$GIT_ROOT" rev-parse HEAD)
if ! REBASED=$("$MOZSEARCH_PATH/scripts/rebase-try-push.sh" "$GIT_ROOT" "$NAME" "$HEAD_REV"); then
    echo "ERROR: The push's changes conflict with the indexed revision's, so it can't be analyzed semantically until it's rebased."
    exit 1
fi
rsync -a --delete "$SEM/pristine/obj-build/" "$SEM/workspace/obj-build/"
rsync -a --delete "$SEM/pristine/mozbuild/" "$SEM/mozbuild/"
# (Only the files the push changes get new times, or else the build rebuilds
# everything, and the checkout's CLOBBER being newer than the objdir's makes
# mach clobber the objdir, with its compile database and plugin.  So git's
# index has to know that the other files are unchanged even if their stat
# data changed, ex: after the index's copy from its volume to the web server's
# disk, which doesn't keep their inodes.)
git -C "$SEM/gecko" update-index -q --refresh || true
git -C "$SEM/gecko" checkout -q --detach -f "$REBASED"
git -C "$SEM/gecko" clean -q -fdx
rm -rf "$PUSH"
mkdir -p "$PUSH"
git -C "$GIT_ROOT" diff --name-only "$BASE" "$REBASED" > "$PUSH/changed.lst"

begin_step semantic build-export "$NAME"
touch "$PUSH/export-marker"
sleep 1
"$HERE/inbuild.sh" "$SEM" python3 ./mach --no-interactive build pre-export export -j$JOBS
# The generated C/C++ the push changes (relative to the base's; see
# prepare.sh).
(cd "$SEM/workspace/obj-build" && find . -newer "$PUSH/export-marker" -type f | sed 's#^\./##') |
    { grep -E '\.(h|hh|hpp|c|cc|cpp|inc|def|msg)$' || true; } |
    { grep -vE '^(buildid\.h|build/application\.ini\.h)$' || true; } |
    while read -r FILE; do
        if ! cmp -s "$SEM/gen-base/$FILE" "$SEM/workspace/obj-build/$FILE"; then
            echo "__GENERATED__/$FILE"
        fi
    done >> "$PUSH/changed.lst"

# (If the build clobbered the objdir anyway, ex: for a push changing CLOBBER,
# the plugin and the compile database have to be built again; see
# prepare.sh.)
if [ ! -e "$SEM/workspace/obj-build/compile_commands.json" ]; then
    begin_step semantic rebuild-plugin "$NAME"
    if [ -e "$SEM/only-files" ]; then
        git -C "$SEM/gecko" apply "$HERE/mozsearch-plugin-only-files.patch"
    fi
    "$HERE/inbuild.sh" "$SEM" gmake -C /builds/worker/workspace/obj-build/build/clang-plugin host -j$JOBS
    "$HERE/inbuild.sh" "$SEM" python3 ./mach --no-interactive build-backend -b CompileDB
    git -C "$SEM/gecko" checkout -- .
fi

begin_step semantic build-analysis "$NAME"
python3 -I "$HERE/select_tus.py" "$SEM/deps-resolved.json" \
    "$SEM/workspace/obj-build/compile_commands.json" "$PUSH"
"$HERE/inbuild.sh" "$SEM" env MOZSEARCH_ONLY_FILES=/builds/worker/workspace/push/emit.lst \
    python3 /builds/worker/semantic/compile.py /builds/worker/workspace/push/raw "$JOBS" \
    /builds/worker/workspace/push/tus.lst
# (Merged like the tree's, whose only platform is linux64.)
begin_step semantic merge "$NAME"
mkdir -p "$PUSH/raw" "$PUSH/tip"
ln -s raw "$PUSH/analysis-linux64"
(cd "$PUSH/raw" && find . -type f | sed 's#^\./##') |
    (cd "$PUSH" && parallel --halt now,fail=1 \
        'mkdir -p "$(dirname tip/{})" && merge-analyses analysis-linux64/{} > tip/{}')

begin_step semantic delta "$NAME"
{ grep '^__GENERATED__/' "$PUSH/changed.lst" || true; } > "$PUSH/changed-generated.lst"
build-try-delta "$CONFIG_FILE" "$TREE_NAME" "$NAME" "$REBASED" "$PUSH/tip" \
    --incomplete "$PUSH/incomplete.lst" --objdir "$SEM/workspace/obj-build" \
    --changed-generated "$PUSH/changed-generated.lst" --threads "$JOBS"

# (The worktree goes back to the base for the next push; the objdir and mach's
# state go back to their pristine copies then.)
git -C "$SEM/gecko" checkout -q --detach -f "$BASE"
rm -rf "$PUSH"
