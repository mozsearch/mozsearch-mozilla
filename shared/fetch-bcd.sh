#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# Download MDN's browser-compat-data (BCD,
# https://github.com/mdn/browser-compat-data): the data.json of its npm
# package's latest release, as bcd/data.json in the tree's index directory,
# where mozsearch's scripts/spec-analyze.sh looks for it.  BCD's features have
# their specs' URLs and their MDN pages', as MDN curates them, from which
# spec-analyze links WebIDL symbols to the specs' definitions which they
# reflect and to their MDN pages, and a spec tree's definitions to their MDN
# pages (see mozsearch's tools/src/spec_analyze/bcd.rs).  If it can't be
# downloaded, the indexing goes on without those links.

echo "Performing setup::fetch-bcd step for $TREE_NAME : $(date +"%Y-%m-%dT%H:%M:%S%z")"

BCD_DIR=$INDEX_ROOT/bcd
rm -rf "$BCD_DIR"
mkdir -p "$BCD_DIR"
CURL="curl -SsfL --retry 5 --retry-all-errors"

fetch_bcd() {
    local tarball
    tarball=$($CURL https://registry.npmjs.org/@mdn/browser-compat-data/latest | jq -r .dist.tarball) || return 1
    if [ -z "$tarball" ] || [ "$tarball" == "null" ]; then
        return 1
    fi
    $CURL "$tarball" | tar -xz -C "$BCD_DIR" --strip-components=1 package/data.json
}

if fetch_bcd; then
    echo "BCD $(jq -r .__meta.version "$BCD_DIR/data.json")"
else
    echo "Couldn't download BCD; the indexing goes on without its links."
    rm -rf "$BCD_DIR"
fi
