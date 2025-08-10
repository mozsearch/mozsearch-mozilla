#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

GIT_BARE_REPO_DIR="$1"

if [[ $(date +%A) == "Saturday" ]]; then
    date
    git --git-dir="${GIT_BARE_REPO_DIR}" gc
    date
    git --git-dir="${GIT_BARE_REPO_DIR}" cinnabar fsck || true
    date
fi
