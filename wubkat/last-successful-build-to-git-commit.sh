#!/usr/bin/env bash

# This is evolved from dpino's script from:
# https://gist.github.com/dpino/b324320652bb8b758acde123f9a3dbdc
# with the evolution process happening there, which you can read if you like!
# Many thanks to dpino!

# Debugging this? Uncomment the following to see the commands as they run!
#set -x

BUILDER_NAME=${1:-GTK-Linux-64-bit-Release-Ubuntu-LTS-Build}

# Ask Buildbot for the newest build that has finished successfully:
# - complete=true excludes builds that are still running.
# - results=0 selects successful builds.  Buildbot uses numeric result codes;
#   I've manually verified that a failed build had results=2.
# - property=got_revision asks Buildbot to include the got_revision property
#   in the response, which tells us the exact source revision that was checked
#   out for the build.
#
# curl flags:
# - -f / --fail: return a non-zero exit status for HTTP error responses.
# - -s / --silent: suppress the progress meter and normal curl diagnostics.
# - -S / --show-error: when used with --silent, still print errors if curl
#   itself fails.
BUILD_INFO=$(
    curl -fsS \
        "https://build.webkit.org/api/v2/builders/$BUILDER_NAME/builds?order=-number&limit=1&complete=true&results=0&property=got_revision"
)

BUILD_REV=$(
    jq -er '.builds[0].properties.got_revision[0]' <<< "$BUILD_INFO"
)

echo "$BUILD_REV"
