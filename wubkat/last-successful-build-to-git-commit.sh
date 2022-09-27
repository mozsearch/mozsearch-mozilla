#!/usr/bin/env bash
# This is dpino's script from
# https://gist.github.com/dpino/b324320652bb8b758acde123f9a3dbdc
# specifically
# https://gist.githubusercontent.com/dpino/b324320652bb8b758acde123f9a3dbdc/raw/87d75cfe4ff8aa8a4d2fd7f86dfc507f18cd58fa/last-successful-build-to-git-commit.sh
#
# Many thanks to dpino!

# set -x

BUILDER_NAME=${1:-GTK-Linux-64-bit-Release-Ubuntu-LTS-Build}
if [[ -z $WEBKIT_CHECKOUT_DIR ]]; then
    WEBKIT_CHECKOUT_DIR=${2:-$(realpath $(dirname "$0"))}
fi

usage() {
    local exit_code="$1"
    local program_name=$(basename "$0")

    echo -e "Usage: $program_name BOT-NAME [WEBKIT-CHECKOUT-DIR]"
    echo -e "Returns commit of last succeessful build in BOT-NAME"

    exit $exit_code
}

fatal() {
    echo $@
    exit 1
}

get_last_successful_build_number() {
    local builder_name="$1"

    curl "https://build.webkit.org/api/v2/builders/$builder_name/builds?order=-number&limit=1&complete=true" 2>/dev/null | grep "number" | egrep -o "[0-9]+"
}

get_canonical_id_from_build_number() {
    local builder_name="$1"
    local build_number="$2"
    local step_name="clean-and-update-working-directory"

    curl "https://build.webkit.org/api/v2/builders/$builder_name/builds/$build_number/steps/$step_name" 2>/dev/null | egrep -m 1 -o "[0-9]+@main"
}

get_commit_from_canonical_id() {
    local canonical_id="$1"
    local next_commit

    next_commit=$(git log | grep -m 1 -A 2 "$canonical_id" | grep commit | cut -d " " -f 2)
    if [[ $? -eq 0 ]]; then
        git log -1 --format="%H" ${next_commit}~
        return 0
    fi
    return 1
}

update_and_move_to_main_branch() {
    git reset --hard origin/main &>/dev/null || true
    git fetch main &>/dev/null
    git checkout main &>/dev/null
    git pull &>/dev/null
}

restore_and_move_to_previous_branch() {
    git checkout - &>/dev/null
}

is_webkit_repository() {
    local dir="$1"
    local url exit_code

    pushd $dir &>/dev/null
    url=$(git config --get remote.origin.url)
    popd &>/dev/null

    url=${url,,}
    [[ "$url" == "https://github.com/webkit/webkit.git" || "$url" == "ssh://git@github.com:webkit/webkit.git" ]]
}

if ! is_webkit_repository $WEBKIT_CHECKOUT_DIR; then
    usage 1
fi

build_number=$(get_last_successful_build_number "$BUILDER_NAME")
canonical_id=$(get_canonical_id_from_build_number "$BUILDER_NAME" "$build_number")

pushd $WEBKIT_CHECKOUT_DIR &>/dev/null
update_and_move_to_main_branch
commit=$(get_commit_from_canonical_id "$canonical_id")
restore_and_move_to_previous_branch
popd &>/dev/null

echo "$commit"
