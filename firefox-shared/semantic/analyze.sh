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
# ../process-gecko-analysis.sh), and its TypeScript's, its web analyses' (its
# JS's, pages', stylesheets'), its Python's, and the rest of the tree's (its
# IDL's, IPDL's, TOML's, semantic analysis' and moz.build files', and its
# analysis' URLs and functions' GC), is the delta's (see build-try-delta).
#
# Its steps say when they start, and how long each took when it exits (see
# ../step-times.sh); compile.py says how long the translation units took.
#
# Usage: analyze.sh NAME HEAD_REV, with try_import's hook environment (see
# mozsearch's tools/src/try_import.rs): GIT_ROOT, INDEX_ROOT, CONFIG_FILE,
# TREE_NAME, and MOZSEARCH_PATH; and PUSH_REVS, the push's stack's commits,
# oldest first (see rebase-try-push.sh), if known.

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
# (But the npm packages the TypeScript analysis installs; see below.)
git -C "$SEM/gecko" clean -q -fdx -e /node_modules
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
if [ -x "$MOZSEARCH_PATH/scripts/try-analyze-rust.sh" ] && [ -f "$SEM/workspace/rust-analyzer-replay.json" ]; then
    begin_step semantic rust "$NAME"
    try-rust-files "$CONFIG_FILE" "$TREE_NAME" "$SEM/gecko" "$PUSH/changed.lst" > "$PUSH/rust-files"
    if [ -s "$PUSH/rust-files" ]; then
        REPLAY=/builds/worker/workspace/rust-analyzer-replay.json
        if grep -qE '(^|/)(Cargo\.toml|Cargo\.lock|build\.rs)$' "$PUSH/changed.lst"; then
            "$HERE/inbuild.sh" "$SEM" sh -c "$(cat "$SEM/workspace/cargo-check.cmd")" \
                > "$PUSH/cargo-check.json" 2> "$PUSH/cargo-check.log" ||
                echo "WARNING: The push's cargo check failed for some crates (see its cargo-check.log)."
            jq '.cargo.buildScripts.overrideCommand = ["cat", "/builds/worker/workspace/push/cargo-check.json"]' \
                "$SEM/workspace/rust-analyzer-replay.json" > "$PUSH/rust-analyzer-replay.json"
            REPLAY=/builds/worker/workspace/push/rust-analyzer-replay.json
        fi
        # (Offline, with prepare.sh's cargo home, which has the standard
        # library's dependencies.)
        if "$HERE/inbuild.sh" "$SEM" --nix env CARGO=/builds/worker/fetches/rustc/bin/cargo \
            RUSTC=/builds/worker/fetches/rustc/bin/rustc CARGO_HOME=/builds/worker/.mozbuild/cargo-home \
            CARGO_NET_OFFLINE=true "$(realpath "$(command -v rust-analyzer)")" \
            scip . --config-path "$REPLAY" --only-files /builds/worker/workspace/push/rust-files \
            --output /builds/worker/workspace/push/rust.scip > "$PUSH/rust-analyzer.log" 2>&1; then
            "$MOZSEARCH_PATH/scripts/try-analyze-rust.sh" "$CONFIG_FILE" "$TREE_NAME" "$SEM/gecko" \
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
    NPM_STAMP=$(cat "$SEM/gecko/package.json" "$SEM/gecko/package-lock.json" 2>/dev/null | sha256sum | cut -d' ' -f1)
    if [ ! -d "$SEM/gecko/node_modules" ] || [ "$(cat "$SEM/npm-stamp" 2>/dev/null)" != "$NPM_STAMP" ]; then
        rm -f "$SEM/npm-stamp"
        if (cd "$SEM/gecko" && npm install --no-audit --no-fund); then
            echo "$NPM_STAMP" > "$SEM/npm-stamp"
        else
            echo "WARNING: npm install failed in the semantic analysis's checkout."
        fi
    fi
    "$HERE/../typescript-projects.sh" "$SEM/gecko" > "$PUSH/typescript-projects"
    if ! "$MOZSEARCH_PATH/scripts/try-analyze-typescript.sh" "$CONFIG_FILE" "$TREE_NAME" \
        "$SEM/gecko" "$PUSH/typescript-projects" "$PUSH/changed.lst" "$PUSH/tip"; then
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
        "$INDEX_ROOT" "$SEM/gecko" "$PUSH/changed.lst" "$PUSH/tip"
elif [ -x "$MOZSEARCH_PATH/scripts/try-analyze-js.sh" ]; then
    begin_step semantic js "$NAME"
    # (Its web-platform-tests' custom properties are each file's own, as the
    # tree's are; see mozsearch's scripts/js-analyze.sh.)
    TESTS_ROOT=$(jq -r --arg tree "$TREE_NAME" '.trees[$tree].wpt_root // "-"' "$CONFIG_FILE") \
        "$MOZSEARCH_PATH/scripts/try-analyze-js.sh" "$INDEX_ROOT" "$SEM/gecko" "$PUSH/changed.lst" "$PUSH/tip"
fi
# And its Python, with scip-python, in the tree's projects (see
# ../python-configs.sh and mozsearch's scripts/try-analyze-python.sh).
if [ -x "$MOZSEARCH_PATH/scripts/try-analyze-python.sh" ]; then
    begin_step semantic python "$NAME"
    "$HERE/../python-configs.sh" "$SEM/gecko"
    "$MOZSEARCH_PATH/scripts/try-analyze-python.sh" "$CONFIG_FILE" "$TREE_NAME" "$SEM/gecko" \
        "$PUSH/changed.lst" "$PUSH/tip" "$SEM/gecko/pyrightconfig.json" "$SEM/gecko/__pyright_wpt.json" ||
        echo "WARNING: The push's Python analysis failed."
    rm -f "$SEM/gecko/pyrightconfig.json" "$SEM/gecko/__pyright_wpt.json"
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
    "$MOZSEARCH_PATH/scripts/try-analyze-rest.sh" "$CONFIG_FILE" "$TREE_NAME" "$INDEX_ROOT" "$SEM/gecko" \
        "$SEM/workspace/obj-build" "$PUSH/changed.lst" "$PUSH/tip" "$PUSH/incomplete.lst" ||
        echo "WARNING: The rest of the push's analyses failed."
fi

begin_step semantic delta "$NAME"
{ grep '^__GENERATED__/' "$PUSH/changed.lst" || true; } > "$PUSH/changed-generated.lst"
# (A stack on a newer trunk revision which needs its changes is analyzed with
# them, and the delta says what the stack itself changes; see
# rebase-try-push.sh.)
STACK_BASE=$(git -C "$GIT_ROOT" rev-parse -q --verify "refs/try-stack-base/$NAME" || true)
build-try-delta "$CONFIG_FILE" "$TREE_NAME" "$NAME" "$REBASED" "$PUSH/tip" \
    --incomplete "$PUSH/incomplete.lst" --objdir "$SEM/workspace/obj-build" \
    --changed-generated "$PUSH/changed-generated.lst" --threads "$JOBS" \
    ${STACK_BASE:+--stack-base "$STACK_BASE"}

# (The worktree goes back to the base for the next push; the objdir and mach's
# state go back to their pristine copies then.)
git -C "$SEM/gecko" checkout -q --detach -f "$BASE"
rm -rf "$PUSH"
