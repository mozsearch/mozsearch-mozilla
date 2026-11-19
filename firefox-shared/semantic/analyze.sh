#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# A try push's semantic analysis (see mozsearch's tools/src/try_delta.rs),
# for a tree indexing only linux64's analysis (firefox-try; see its setup):
# the push's stack rebased onto the indexed revision (REBASED, which
# ../../firefox-try/import-try rebased with mozsearch's
# scripts/rebase-try-push.sh), built in the tree's
# prepared build (see prepare.sh), starting from its pristine state: the
# export tier, and then, with the indexer, the translation units that include
# the files it changes (by the base's include map), writing their files'
# analysis (see select_tus.py and compile.py), with all but 8 of the cores,
# for the web server's sake.  That analysis, merged like the tree's (see
# ../process-gecko-analysis.sh), and its TypeScript's, its web analyses' (its
# JS's, pages', stylesheets'), its Python's, and the rest of the tree's (its
# IDL's, IPDL's, TOML's, semantic analysis' and moz.build files', and its
# analysis' URLs and functions' GC), is the delta's (see build-try-delta).
#
# Its steps say when they start, and how long each took when it exits (see
# ../step-times.sh); compile.py says how long the translation units took.
#
# As many pushes' analyses run at a time as the tree's try pushes' imports
# (TRY_IMPORT_WORKERS, its try_import_workers; see mozsearch's
# tools/src/try_import.rs), each in a slot of its own: a gecko worktree, a
# workspace (the objdir, from its pristine copy, and the push's directory),
# mach's state, and the artifacts, for the build's sandbox (see inbuild.sh's
# SEM_SLOT).  The first slot is SEM's own; the others, SEM/slots/N, are made
# from it the first time they're needed (see make_slot).  Their builds share
# the cores (with all but 8 each, at a lower priority than the web server's;
# on 2026-11-19, a push's 3,534 translation units' 24 jobs used 6.2 GB).
#
# Usage: analyze.sh NAME REBASED, with try_import's hook environment (see
# mozsearch's tools/src/try_import.rs): GIT_ROOT, INDEX_ROOT, CONFIG_FILE,
# TREE_NAME, MOZSEARCH_PATH and TRY_IMPORT_WORKERS (1 if it isn't set).

NAME=$1
REBASED=$2
HERE=$(cd "$(dirname "$0")" && pwd)
SEM=$INDEX_ROOT/semantic
SLOTS=${TRY_IMPORT_WORKERS:-1}
JOBS=$(nproc)
JOBS=$(( JOBS > 9 ? JOBS - 8 : 1 ))

source "$HERE/../step-times.sh"
trap 'end_steps semantic; if [[ -n ${PYTHON_PID:-} ]]; then kill "$PYTHON_PID" 2>/dev/null || true; fi' EXIT

begin_step semantic prepare "$NAME"
# (The analyses hold the lock shared.  Preparing, once per indexed revision,
# which replaces SEM, is one push's alone: an analysis which finds SEM not
# prepared takes the lock alone, waiting for the others, to prepare it.
# Taking it alone each time, as before, waited for every running analysis:
# on config8 on 2026-11-19, 4 pushes' analyses ran one at a time, and 3 of
# their imports reached their time limit waiting.)
exec 8> "$INDEX_ROOT/semantic.lock"
LOCKING=$(date +%s)
INDEXED_GIT_REV=$(git -C "$GIT_ROOT" rev-parse HEAD)
flock -s 8
if [[ "$(cat "$SEM/ready" 2>/dev/null || true)" != "$INDEXED_GIT_REV" ]]; then
    flock -u 8
    flock 8
    "$HERE/prepare.sh" "$SEM" "$GIT_ROOT" "$(jq -r .moz_source_stamp "$INDEX_ROOT/target.json")"
    flock -s 8
fi

# Its slot: the first free one, waiting for one if none is.
SLOT=""
while true; do
    for (( INDEX = 0; INDEX < SLOTS; INDEX++ )); do
        exec 9> "$INDEX_ROOT/semantic-slot-$INDEX.lock"
        if flock -n 9; then
            SLOT=$SEM
            if (( INDEX > 0 )); then
                SLOT=$SEM/slots/$INDEX
            fi
            break 2
        fi
        exec 9>&-
    done
    sleep 5
done
if (( $(date +%s) - LOCKING > 0 )); then
    echo "Waited $(( $(date +%s) - LOCKING )) s for another push's semantic analysis."
fi
echo "Its semantic analysis's slot: $INDEX of $SLOTS ($SLOT)."
export SEM_SLOT=$SLOT
PUSH=$SLOT/workspace/push

# Make a slot (but SEM's own) for the indexed revision, unless it is: a gecko
# worktree of the shared repo at the revision, whose files are as old as the
# prepared checkout's were when its objdir was built (see prepare.sh), so that
# the build doesn't take them for changed since then (and mach doesn't
# clobber the objdir, as a CLOBBER newer than its own would make it), and the
# workspace's files besides the objdir (ex: Rust's replay of its cargo check).
# (The objdir and mach's state come from their pristine copies for each push,
# as SEM's do.)
make_slot() {
    if [[ "$SLOT" == "$SEM" ]] || [[ "$(cat "$SLOT/ready" 2>/dev/null || true)" == "$INDEXED_GIT_REV" ]]; then
        return
    fi
    begin_step semantic make-slot "$NAME"
    local shared_git
    shared_git=$(git -C "$GIT_ROOT" rev-parse --path-format=absolute --git-common-dir)
    if [ -d "$SLOT/gecko" ]; then
        git -C "$shared_git" worktree remove --force "$SLOT/gecko" || true
    fi
    rm -rf "$SLOT"
    mkdir -p "$SLOT/workspace" "$SLOT/artifacts" "$SLOT/mozbuild"
    # (Slots are only made on the web server, after the index's upload, and
    # kept for its life; but a half-made one's worktree would still be
    # registered.)
    git -C "$shared_git" worktree prune
    git -C "$shared_git" worktree add --detach "$SLOT/gecko" "$INDEXED_GIT_REV"
    # (fetches.lst, which prepare.sh writes right after its worktree's
    # checkout and before the build.)
    local checked_out
    checked_out=$(stat -c %Y "$SEM/fetches.lst")
    (cd "$SLOT/gecko" && git ls-files -z | xargs -0 touch -h -m -d "@$checked_out")
    git -C "$SLOT/gecko" update-index -q --refresh || true
    rsync -a --exclude=/obj-build --exclude=/push "$SEM/workspace/" "$SLOT/workspace/"
    echo "$INDEXED_GIT_REV" > "$SLOT/ready"
}
make_slot

BASE=$(git -C "$GIT_ROOT" rev-parse HEAD)
rsync -a --delete "$SEM/pristine/obj-build/" "$SLOT/workspace/obj-build/"
rsync -a --delete "$SEM/pristine/mozbuild/" "$SLOT/mozbuild/"
# (Only the files the push changes get new times, or else the build rebuilds
# everything, and the checkout's CLOBBER being newer than the objdir's makes
# mach clobber the objdir, with its compile database and plugin.  So git's
# index has to know that the other files are unchanged even if their stat
# data changed, ex: after the index's copy from its volume to the web server's
# disk, which doesn't keep their inodes.)
git -C "$SLOT/gecko" update-index -q --refresh || true
git -C "$SLOT/gecko" checkout -q --detach -f "$REBASED"
# (But the npm packages the TypeScript analysis installs; see below.)
git -C "$SLOT/gecko" clean -q -fdx -e /node_modules
rm -rf "$PUSH"
mkdir -p "$PUSH"
git -C "$GIT_ROOT" diff --name-only "$BASE" "$REBASED" > "$PUSH/changed.lst"

begin_step semantic build-export "$NAME"
touch "$PUSH/export-marker"
sleep 1
"$HERE/inbuild.sh" "$SEM" python3 ./mach --no-interactive build pre-export export -j$JOBS
# The generated C/C++ the push changes (relative to the base's; see
# prepare.sh).
(cd "$SLOT/workspace/obj-build" && find . -newer "$PUSH/export-marker" -type f | sed 's#^\./##') |
    { grep -E '\.(h|hh|hpp|c|cc|cpp|inc|def|msg)$' || true; } |
    { grep -vE '^(buildid\.h|build/application\.ini\.h)$' || true; } |
    while read -r FILE; do
        if ! cmp -s "$SEM/gen-base/$FILE" "$SLOT/workspace/obj-build/$FILE"; then
            echo "__GENERATED__/$FILE"
        fi
    done >> "$PUSH/changed.lst"

# (If the build clobbered the objdir anyway, ex: for a push changing CLOBBER,
# the plugin and the compile database have to be built again; see
# prepare.sh.)
if [ ! -e "$SLOT/workspace/obj-build/compile_commands.json" ]; then
    begin_step semantic rebuild-plugin "$NAME"
    if [ -e "$SEM/only-files" ]; then
        git -C "$SLOT/gecko" apply "$HERE/mozsearch-plugin-only-files.patch"
    fi
    "$HERE/inbuild.sh" "$SEM" gmake -C /builds/worker/workspace/obj-build/build/clang-plugin host -j$JOBS
    "$HERE/inbuild.sh" "$SEM" python3 ./mach --no-interactive build-backend -b CompileDB
    git -C "$SLOT/gecko" checkout -- .
fi

begin_step semantic build-analysis "$NAME"
python3 -I "$HERE/select_tus.py" "$SEM/deps-resolved.json" \
    "$SLOT/workspace/obj-build/compile_commands.json" "$PUSH"
"$HERE/inbuild.sh" "$SEM" env MOZSEARCH_ONLY_FILES=/builds/worker/workspace/push/emit.lst \
    python3 /builds/worker/semantic/compile.py /builds/worker/workspace/push/raw "$JOBS" \
    /builds/worker/workspace/push/tus.lst

# And its Rust, as the tree's is the task's rust-analyzer's SCIP index (see
# ../process-tc-artifacts.sh): the files whose analysis it can change
# (mozsearch's try-rust-files: those it changes, and the tree's files using
# their symbols), indexed by mozsearch's rust-analyzer (whose --only-files
# the task's doesn't have) in the build's sandbox, with the task's
# configuration, replaying prepare.sh's cargo check of the build scripts'
# outputs and proc macros, or, if the push changes a Cargo.toml, Cargo.lock
# or build.rs file, a cargo check of its own (in the sandbox, without the
# network); their analysis joins the compilation's (see mozsearch's
# scripts/try-analyze-rust.sh, which revisions before Part 710 don't have).
# (On firefox at config8's 2026-11-06 revision, 4 files took 12.6 s, and
# 134 files 17.2 s, 4.3 GB; 6,729 of the 4 files' 6,738 records were the
# task's rust-analyzer's, the others with hovers' types the task's lacks.)
if [ -x "$MOZSEARCH_PATH/scripts/try-analyze-rust.sh" ] && [ -f "$SLOT/workspace/rust-analyzer-replay.json" ]; then
    begin_step semantic rust "$NAME"
    try-rust-files "$CONFIG_FILE" "$TREE_NAME" "$SLOT/gecko" "$PUSH/changed.lst" > "$PUSH/rust-files"
    if [ -s "$PUSH/rust-files" ]; then
        REPLAY=/builds/worker/workspace/rust-analyzer-replay.json
        if grep -qE '(^|/)(Cargo\.toml|Cargo\.lock|build\.rs)$' "$PUSH/changed.lst"; then
            # (As prepare.sh's: the crates which failed, which some always
            # do, are left out.)
            if ! "$HERE/inbuild.sh" "$SEM" sh -c "$(cat "$SLOT/workspace/cargo-check.cmd")" \
                    > "$PUSH/cargo-check.json" 2> "$PUSH/cargo-check.log"; then
                echo "The push's cargo check: these crates failed, and are left out: $(grep -oE '(failed to run custom build command for|could not compile) `[^`]+`' "$PUSH/cargo-check.log" | cut -d'`' -f2 | cut -d' ' -f1 | sort -u | paste -sd ' ') (see its cargo-check.log)."
            fi
            if ! grep -q '"reason":"compiler-artifact"' "$PUSH/cargo-check.json"; then
                echo "WARNING: The push's cargo check built none of the crates (see its cargo-check.log)."
            fi
            jq '.cargo.buildScripts.overrideCommand = ["cat", "/builds/worker/workspace/push/cargo-check.json"]' \
                "$SLOT/workspace/rust-analyzer-replay.json" > "$PUSH/rust-analyzer-replay.json"
            REPLAY=/builds/worker/workspace/push/rust-analyzer-replay.json
        fi
        # (Offline, with prepare.sh's cargo home, which has the standard
        # library's dependencies.)
        if "$HERE/inbuild.sh" "$SEM" --nix env CARGO=/builds/worker/fetches/rustc/bin/cargo \
            RUSTC=/builds/worker/fetches/rustc/bin/rustc CARGO_HOME=/builds/worker/.mozbuild/cargo-home \
            CARGO_NET_OFFLINE=true "$(realpath "$(command -v rust-analyzer)")" \
            scip . --config-path "$REPLAY" --only-files /builds/worker/workspace/push/rust-files \
            --output /builds/worker/workspace/push/rust.scip > "$PUSH/rust-analyzer.log" 2>&1; then
            "$MOZSEARCH_PATH/scripts/try-analyze-rust.sh" "$CONFIG_FILE" "$TREE_NAME" "$SLOT/gecko" \
                "$PUSH/rust.scip" "$PUSH/rust-files" "$PUSH/raw"
        else
            tail -5 "$PUSH/rust-analyzer.log"
            echo "WARNING: rust-analyzer failed for the push's Rust, so it isn't analyzed."
        fi
    fi
fi

# (Merged like the tree's, whose only platform is linux64.)
begin_step semantic merge "$NAME"
mkdir -p "$PUSH/raw" "$PUSH/tip"
ln -s raw "$PUSH/analysis-linux64"
(cd "$PUSH/raw" && find . -type f | sed 's#^\./##') |
    (cd "$PUSH" && parallel --halt now,fail=1 \
        'mkdir -p "$(dirname tip/{})" && merge-analyses analysis-linux64/{} > tip/{}')

# And its Python, with scip-python, in the tree's projects (see
# ../python-configs.sh and mozsearch's scripts/try-analyze-python.sh): in the
# background, beside its TypeScript and web analyses, which analyze other
# files, as scip-python takes a while (21 s for one file on 2026-11-09, mostly
# starting), until the rest of its analyses (which read all of its files'),
# its output shown then.  (Stopped if this exits before.)
PYTHON_PID=
if [ -x "$MOZSEARCH_PATH/scripts/try-analyze-python.sh" ]; then
    echo "Performing semantic::python step for $NAME, in the background : $(date +"%Y-%m-%dT%H:%M:%S%z")"
    PYTHON_START=$(date +%s)
    (
        "$HERE/../python-configs.sh" "$SLOT/gecko"
        "$MOZSEARCH_PATH/scripts/try-analyze-python.sh" "$CONFIG_FILE" "$TREE_NAME" "$SLOT/gecko" \
            "$PUSH/changed.lst" "$PUSH/tip" "$SLOT/gecko/pyrightconfig.json" "$SLOT/gecko/__pyright_wpt.json" ||
            echo "WARNING: The push's Python analysis failed."
        rm -f "$SLOT/gecko/pyrightconfig.json" "$SLOT/gecko/__pyright_wpt.json"
    ) > "$PUSH/python.log" 2>&1 &
    PYTHON_PID=$!
fi

# And its TypeScript and JS, which the compilation doesn't analyze, as the
# tree's are: with scip-typescript, the files the projects at its head include
# (listed as the tree's build lists them; see mozsearch's
# scripts/try-analyze-typescript.sh, which revisions before Part 669 don't
# have), with the checkout's npm packages, installed for the first push, and
# again for a push whose package.json or package-lock.json differ from those
# they were installed for; if that fails, those files' JS is js-analyze's, as
# the others' is (see mozsearch's scripts/try-analyze-js.sh, which revisions
# before Part 667 don't have).
if [ -x "$MOZSEARCH_PATH/scripts/try-analyze-typescript.sh" ]; then
    begin_step semantic typescript "$NAME"
    NPM_STAMP=$(cat "$SLOT/gecko/package.json" "$SLOT/gecko/package-lock.json" 2>/dev/null | sha256sum | cut -d' ' -f1)
    if [ ! -d "$SLOT/gecko/node_modules" ] || [ "$(cat "$SLOT/npm-stamp" 2>/dev/null)" != "$NPM_STAMP" ]; then
        rm -f "$SLOT/npm-stamp"
        if (cd "$SLOT/gecko" && npm install --no-audit --no-fund); then
            echo "$NPM_STAMP" > "$SLOT/npm-stamp"
        else
            echo "WARNING: npm install failed in the semantic analysis's checkout."
        fi
    fi
    "$HERE/../typescript-projects.sh" "$SLOT/gecko" > "$PUSH/typescript-projects"
    if ! "$MOZSEARCH_PATH/scripts/try-analyze-typescript.sh" "$CONFIG_FILE" "$TREE_NAME" \
        "$SLOT/gecko" "$PUSH/typescript-projects" "$PUSH/changed.lst" "$PUSH/tip"; then
        echo "WARNING: The push's TypeScript analysis failed, so its JS is js-analyze's."
    fi
fi
# And its web analyses, as the tree's (see mozsearch's
# scripts/try-analyze-web.sh, which revisions before Part 704 don't have, whose
# push analysis is try-analyze-js.sh's): its JS environments' (with
# scip-typescript, its pages' inline scripts' too), its JS's and pages'
# markup's (js-analyze's), its stylesheets', and its web-platform-tests'
# links.
if [ -x "$MOZSEARCH_PATH/scripts/try-analyze-web.sh" ]; then
    begin_step semantic web "$NAME"
    JS_ENVIRONMENTS_JOBS=$JOBS "$MOZSEARCH_PATH/scripts/try-analyze-web.sh" "$CONFIG_FILE" "$TREE_NAME" \
        "$INDEX_ROOT" "$SLOT/gecko" "$PUSH/changed.lst" "$PUSH/tip"
elif [ -x "$MOZSEARCH_PATH/scripts/try-analyze-js.sh" ]; then
    begin_step semantic js "$NAME"
    # (Its web-platform-tests' custom properties are each file's own, as the
    # tree's are; see mozsearch's scripts/js-analyze.sh.)
    TESTS_ROOT=$(jq -r --arg tree "$TREE_NAME" '.trees[$tree].wpt_root // "-"' "$CONFIG_FILE") \
        "$MOZSEARCH_PATH/scripts/try-analyze-js.sh" "$INDEX_ROOT" "$SLOT/gecko" "$PUSH/changed.lst" "$PUSH/tip"
fi
# (Its Python's, once that's done; see above.)
if [[ -n $PYTHON_PID ]]; then
    begin_step semantic python "$NAME"
    wait "$PYTHON_PID" || echo "WARNING: The push's Python analysis failed."
    PYTHON_PID=
    cat "$PUSH/python.log"
    echo "(Its Python analysis took $(( $(date +%s) - PYTHON_START )) s, beside its TypeScript and web analyses.)"
fi
# And the rest of its analyses, as the tree's (see mozsearch's
# scripts/try-analyze-rest.sh, which revisions before Part 708 don't have):
# its XPIDL's, WebIDL's and IPDL's (with its build's generated files, and its
# compilation's analysis of their C++ over the tree's), its TOML's, its
# semantic analysis' and its moz.build files'; and then its analysis' URLs
# and functions' GC, as the tree's last steps add them, so that the files
# whose records it doesn't change have the tree's.
if [ -x "$MOZSEARCH_PATH/scripts/try-analyze-rest.sh" ]; then
    begin_step semantic rest "$NAME"
    "$MOZSEARCH_PATH/scripts/try-analyze-rest.sh" "$CONFIG_FILE" "$TREE_NAME" "$INDEX_ROOT" "$SLOT/gecko" \
        "$SLOT/workspace/obj-build" "$PUSH/changed.lst" "$PUSH/tip" "$PUSH/incomplete.lst" ||
        echo "WARNING: The rest of the push's analyses failed."
fi

begin_step semantic delta "$NAME"
# (Pushes whose stacks rebase to the same head have the same delta, whose
# directory one at a time writes.)
mkdir -p "$SEM/delta-locks"
exec 7> "$SEM/delta-locks/$REBASED"
flock 7
{ grep '^__GENERATED__/' "$PUSH/changed.lst" || true; } > "$PUSH/changed-generated.lst"
build-try-delta "$CONFIG_FILE" "$TREE_NAME" "$NAME" "$REBASED" "$PUSH/tip" \
    --incomplete "$PUSH/incomplete.lst" --objdir "$SLOT/workspace/obj-build" \
    --changed-generated "$PUSH/changed-generated.lst" --threads "$JOBS"
exec 7>&-

# (The worktree goes back to the base for the next push; the objdir and mach's
# state go back to their pristine copies then.)
git -C "$SLOT/gecko" checkout -q --detach -f "$BASE"
rm -rf "$PUSH"
