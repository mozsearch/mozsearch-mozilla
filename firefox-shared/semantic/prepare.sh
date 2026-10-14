#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# Prepare a tree's semantic analysis of try pushes (see analyze.sh) for its
# indexed revision, in SEM, unless it's ready: a gecko worktree of the tree's
# shared repo at the revision, the toolchains of the revision's
# linux64-searchfox-debug task, and the task's build, as far as the build's
# export tier and the clang plugin with the indexer (inside inbuild.sh), with
# its compile database, the files each translation unit includes (deps.py),
# a copy of the generated sources, and a pristine copy of the objdir and
# mach's state, from which each push's build starts.  A few minutes, once per
# indexed revision.
#
# The plugin is built with mozsearch-plugin-only-files.patch, whose
# MOZSEARCH_ONLY_FILES makes the indexer only write the files a push's
# analysis needs, if it applies (it doesn't change the indexer's analysis
# otherwise).
#
# Usage: prepare.sh SEM GIT_ROOT INDEXED_HG_REV

SEM=$1
GIT_ROOT=$2
INDEXED_HG_REV=$3
HERE=$(cd "$(dirname "$0")" && pwd)
INDEXED_GIT_REV=$(git -C "$GIT_ROOT" rev-parse HEAD)
if [ "$(cat "$SEM/ready" 2>/dev/null || true)" = "$INDEXED_GIT_REV" ]; then
    exit 0
fi
JOBS=$(nproc)

echo "Performing semantic::check-sandbox step : $(date +"%Y-%m-%dT%H:%M:%S%z")"
# (Try pushes' builds run their code; see inbuild.sh.  Unprivileged bwrap
# needs user namespaces, which Ubuntu 24.04 only allows programs with
# AppArmor profiles saying so; see install-sandbox.sh.)
if ! bwrap --ro-bind / / --unshare-net --unshare-pid true; then
    echo "ERROR: bwrap can't make a sandbox here, so try pushes can't be built."
    exit 1
fi

echo "Performing semantic::worktree step : $(date +"%Y-%m-%dT%H:%M:%S%z")"
SHARED_GIT=$(git -C "$GIT_ROOT" rev-parse --path-format=absolute --git-common-dir)
if [ -d "$SEM/gecko" ]; then
    git -C "$SHARED_GIT" worktree remove --force "$SEM/gecko" || true
fi
rm -rf "$SEM"
mkdir -p "$SEM/fetches"
git -C "$SHARED_GIT" worktree add --detach "$SEM/gecko" "$INDEXED_GIT_REV"

echo "Performing semantic::fetch-toolchains step : $(date +"%Y-%m-%dT%H:%M:%S%z")"
TC=https://firefox-ci-tc.services.mozilla.com/api
TASK_ID=$(curl -SsfL "$TC/index/v1/task/gecko.v2.mozilla-central.revision.$INDEXED_HG_REV.firefox.linux64-searchfox-debug" | jq -r .taskId)
curl -SsfL "$TC/queue/v1/task/$TASK_ID" > "$SEM/task.json"
jq -r '.payload.env.MOZ_FETCHES | fromjson | .[] | "\(.task) \(.artifact)"' "$SEM/task.json" |
    while read -r TASK ARTIFACT; do
        case "$ARTIFACT" in
            *.tar.zst) EXTRACT="tar --use-compress-program=unzstd -x" ;;
            *.tar.xz) EXTRACT="tar -xJ" ;;
            *.tar.gz | *.tgz) EXTRACT="tar -xz" ;;
            *) EXTRACT="" ;;
        esac
        if [ -z "$EXTRACT" ]; then
            echo "echo 'WARNING: not extracting $ARTIFACT'"
            continue
        fi
        echo "curl -SsfL '$TC/queue/v1/task/$TASK/artifacts/$ARTIFACT' | (cd '$SEM/fetches' && $EXTRACT)"
    done > "$SEM/fetches.lst"
parallel --halt now,fail=1 < "$SEM/fetches.lst"

# The task's environment, with its paths (see inbuild.sh).
jq -r '.payload.env | to_entries[]
    | select(.key | test("^(MOZ_AUTOMATION|MOZ_SCM_LEVEL|SCCACHE_DISABLE|MOZSEARCH_PLATFORM|MOZ_BUILD_DATE|MOZ_SOURCE_REPO|MOZ_SOURCE_CHANGESET|MOZ_SOURCE_GIT_REPO|MOZ_SOURCE_GIT_CHANGESET)$"))
    | "\(.key)=\(.value)"' "$SEM/task.json" > "$SEM/env"
cat >> "$SEM/env" <<EOF
HOME=/builds/worker
PATH=/builds/worker/fetches/python/bin:/usr/local/bin:/usr/bin:/bin
LANG=C.UTF-8
TERM=dumb
MOZ_FETCHES_DIR=/builds/worker/fetches
MOZ_PYTHON_HOME=/builds/worker/fetches/python
MOZ_OBJDIR=/builds/worker/workspace/obj-build
UPLOAD_PATH=/builds/worker/artifacts
MOZCONFIG=/builds/worker/checkouts/gecko/$(jq -r .payload.env.MOZCONFIG "$SEM/task.json")
EOF

echo "Performing semantic::build-export step : $(date +"%Y-%m-%dT%H:%M:%S%z")"
if git -C "$SEM/gecko" apply --check "$HERE/mozsearch-plugin-only-files.patch"; then
    git -C "$SEM/gecko" apply "$HERE/mozsearch-plugin-only-files.patch"
    touch "$SEM/only-files"
else
    echo "WARNING: mozsearch-plugin-only-files.patch doesn't apply, so builds will write all the files' analysis."
fi
# (The revision's own code, so with the network, ex: for mach's virtualenvs.)
"$HERE/inbuild.sh" "$SEM" --net python3 ./mach --no-interactive configure
"$HERE/inbuild.sh" "$SEM" --net python3 ./mach --no-interactive build pre-export export -j$JOBS
"$HERE/inbuild.sh" "$SEM" --net gmake -C /builds/worker/workspace/obj-build/build/clang-plugin host -j$JOBS
"$HERE/inbuild.sh" "$SEM" --net python3 ./mach --no-interactive build-backend -b CompileDB
git -C "$SEM/gecko" checkout -- .

echo "Performing semantic::include-map step : $(date +"%Y-%m-%dT%H:%M:%S%z")"
"$HERE/inbuild.sh" "$SEM" python3 /builds/worker/semantic/deps.py /builds/worker/workspace/deps.json -j $JOBS
python3 -I "$HERE/resolve_deps.py" "$SEM/workspace/obj-build" "$SEM/workspace/deps.json" "$SEM/deps-resolved.json"

echo "Performing semantic::snapshot step : $(date +"%Y-%m-%dT%H:%M:%S%z")"
# (The generated C/C++, which pushes' builds compare theirs with.)
mkdir -p "$SEM/gen-base"
(cd "$SEM/workspace/obj-build" && find . -type f | grep -E '\.(h|hh|hpp|c|cc|cpp|inc|def|msg)$' |
    grep -v '^\./mozsearch_index/' | cpio -pdm --quiet "$SEM/gen-base")
mkdir -p "$SEM/pristine"
rsync -a --delete "$SEM/workspace/obj-build/" "$SEM/pristine/obj-build/"
rsync -a --delete "$SEM/mozbuild/" "$SEM/pristine/mozbuild/"

echo "$INDEXED_GIT_REV" > "$SEM/ready"
