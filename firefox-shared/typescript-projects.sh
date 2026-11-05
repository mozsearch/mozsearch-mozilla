#!/usr/bin/env bash

set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# The TypeScript and JS projects of a Firefox checkout (ROOT) which its
# scip-typescript index has (see mozsearch's scripts/scip-typescript-index.sh):
# its tsconfig.json and jsconfig.json files, but those in node_modules or
# third_party, one per line, in an order which doesn't depend on the file
# system's (find's), shallower ones first, so that a file in several projects
# (ex: toolkit/jsconfig.json's and toolkit/components/ml/tsconfig.json's) has
# its most specific project's document as its analysis, the last: as both the
# tree's indexing (its build) and its try pushes' (semantic/analyze.sh) list
# them, so that a push's index of only its files has the documents the tree's
# index would.
#
# Usage: typescript-projects.sh ROOT

cd "$1"
find . \( -name node_modules -o -name third_party -o -name .git \) -prune -o \
    -name '[tj]sconfig.json' -print |
    awk -F/ '{ print NF "\t" $0 }' | LC_ALL=C sort -t $'\t' -k1,1n -k2,2 | cut -f2-
