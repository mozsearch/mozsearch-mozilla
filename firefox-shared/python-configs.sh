#!/usr/bin/env bash

set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# The pyright projects which scip-python indexes firefox's Python as (see
# scip-python.sh), as configuration files in CHECKOUT, whose paths are
# relative to it:
# - pyrightconfig.json, its Python but the web-platform-tests' and that of the
#   directories below (whose examples, tests and vendored copies either don't
#   parse or would be indexed twice; and node_modules, scip-typescript's npm
#   install's, beside it: the 2026-11-05 run indexed its node-gyp's), each
#   directory with Python files an extraPaths one (so that imports resolve as
#   the build's sys.path has them);
# - __pyright_wpt.json, the web-platform-tests', with their own paths.
# Try pushes' analysis takes them as the projects of the files they change
# (see semantic/analyze.sh, and mozsearch's scripts/try-analyze-python.sh).
#
# Usage: python-configs.sh CHECKOUT

CHECKOUT=$1
cd "$CHECKOUT"
cat <<EOF > __pyright_exclude_paths.txt
node_modules
testing/web-platform
third_party/chromium/build
third_party/libwebrtc
third_party/python/aiohttp/examples
third_party/python/cbor2
third_party/python/dlmanager/examples
third_party/python/gyp/test
third_party/python/pip/pip/_internal
third_party/python/pip/pip/_vendor
third_party/python/ply/example
third_party/python/python-hglib/examples
third_party/python/pyyaml/examples
third_party/python/setuptools/setuptools/_vendor
third_party/python/setuptools/setuptools/_distutils/tests
third_party/rust
EOF
git ls-files '*.py' | xargs -n1 dirname | sort | uniq | grep -vf __pyright_exclude_paths.txt |
    python3 -I -c '
import json, sys
exclude = open("__pyright_exclude_paths.txt").read().split()
dirs = sys.stdin.read().split()
json.dump({"verboseOutput": False, "include": ["."], "extraPaths": dirs, "exclude": exclude},
          open("pyrightconfig.json", "w"))
json.dump({"verboseOutput": False, "include": ["testing/web-platform"],
           "extraPaths": ["testing/web-platform"]}, open("__pyright_wpt.json", "w"))
'
rm -f __pyright_exclude_paths.txt
