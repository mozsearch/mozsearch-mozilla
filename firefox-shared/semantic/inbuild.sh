#!/usr/bin/env bash

set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# Run a command in a bubblewrap sandbox laid out like taskcluster's
# linux64-searchfox-debug task (see prepare.sh), for building a try push's
# Gecko with the indexer: the checkout at /builds/worker/checkouts/gecko, the
# task's toolchains at /builds/worker/fetches (read-only), and the objdir and
# the indexer's outputs in /builds/worker/workspace, so that configure and the
# build see the task's paths, and the analysis is like the task's.  Only the
# system's directories and the checkout's git repository (the tree's shared
# one, whose worktree it is) are visible besides (read-only), there's no
# network (unless --net), and the environment is the task's (SEM/env).
#
# Usage: inbuild.sh SEM [--net] COMMAND...

SEM=$1
shift
NET=(--unshare-net)
if [ "${1:-}" = "--net" ]; then
    NET=()
    shift
fi
mkdir -p "$SEM/workspace" "$SEM/artifacts" "$SEM/mozbuild"

ROOT=()
for ENTRY in /usr /bin /sbin /lib /lib32 /lib64 /libx32 /etc; do
    if [ -L "$ENTRY" ]; then
        ROOT+=(--symlink "$(readlink "$ENTRY")" "$ENTRY")
    elif [ -d "$ENTRY" ]; then
        ROOT+=(--ro-bind "$ENTRY" "$ENTRY")
    fi
done
GIT_COMMON=$(git -C "$SEM/gecko" rev-parse --path-format=absolute --git-common-dir)
ENV=()
while IFS= read -r LINE; do
    if [ -n "$LINE" ]; then
        ENV+=(--setenv "${LINE%%=*}" "${LINE#*=}")
    fi
done < "$SEM/env"

exec bwrap "${ROOT[@]}" \
    --dev /dev --proc /proc --tmpfs /tmp \
    --bind "$SEM/gecko" /builds/worker/checkouts/gecko \
    --ro-bind "$SEM/fetches" /builds/worker/fetches \
    --bind "$SEM/workspace" /builds/worker/workspace \
    --bind "$SEM/artifacts" /builds/worker/artifacts \
    --bind "$SEM/mozbuild" /builds/worker/.mozbuild \
    --ro-bind "$GIT_COMMON" "$GIT_COMMON" \
    --ro-bind "$(cd "$(dirname "$0")" && pwd)" /builds/worker/semantic \
    --chdir /builds/worker/checkouts/gecko \
    "${NET[@]}" --unshare-pid --unshare-ipc --unshare-uts \
    --die-with-parent --new-session \
    --clearenv "${ENV[@]}" \
    "$@"
