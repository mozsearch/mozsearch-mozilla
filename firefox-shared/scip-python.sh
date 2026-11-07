#!/usr/bin/env bash

set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# A firefox tree's scip-python step (firefox-disco's and firefox-try's builds
# run it in the background, beside scip-typescript, while the Gecko analysis
# is processed, as it needs only the checkout), as firefox-main's build runs
# it (see there for its two chunks, the web-platform-tests and the rest, what
# the rest excludes, and its memory): its projects are python-configs.sh's,
# in the checkout, which they go from once it's done.  With mozsearch's
# scip-python-index.sh, the rest is indexed in chunks side by side, and the
# web-platform-tests beside them: one process for the rest took 12.1 minutes
# on the 2026-11-05 config8 run, and the web-platform-tests 1.5 after it,
# which the build waited 7.3 minutes for after the Gecko analysis.  (It took
# 10.6 minutes for firefox-main on 2026-10-31.)
#
# Usage: scip-python.sh, with the build's environment.

echo "Performing build::scip-python step for $TREE_NAME : $(date +"%Y-%m-%dT%H:%M:%S%z")"
cd "$GIT_ROOT"
"$CONFIG_REPO/firefox-shared/python-configs.sh" .
if [ -x "$MOZSEARCH_PATH/scripts/scip-python-index.sh" ]; then
    NODE_OPTIONS="--max-old-space-size=10240" SCIP_PYTHON_CHUNKS=1 \
      "$MOZSEARCH_PATH/scripts/scip-python-index.sh" . __pyright_wpt.json \
      "$INDEX_ROOT/python2.scip" --project-name python &
    WPT_PID=$!
    NODE_OPTIONS="--max-old-space-size=10240" \
      "$MOZSEARCH_PATH/scripts/scip-python-index.sh" . pyrightconfig.json \
      "$INDEX_ROOT/python.scip" --project-name python
    wait $WPT_PID
else
    NODE_OPTIONS="--max-old-space-size=10240" scip-python index --show-progress-rate-limit 0 --project-name python --output python.scip
    mv python.scip "$INDEX_ROOT"
    mv __pyright_wpt.json pyrightconfig.json
    NODE_OPTIONS="--max-old-space-size=10240" scip-python index --show-progress-rate-limit 0 --project-name python --output python2.scip
    mv python2.scip "$INDEX_ROOT"
fi
rm -f pyrightconfig.json __pyright_wpt.json
echo "build::scip-python done for $TREE_NAME : $(date +"%Y-%m-%dT%H:%M:%S%z")"
