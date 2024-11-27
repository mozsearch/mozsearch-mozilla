#!/usr/bin/env bash
# This is evolved from dpino's script from:
# https://gist.github.com/dpino/b324320652bb8b758acde123f9a3dbdc
# with the evolution process happening there, which you can read if you like!
# Many thanks to dpino!

# Debugging this?  Uncomment the following to see the commands as they run!
#set -x

BUILDER_NAME=${1:-GTK-Linux-64-bit-Release-Ubuntu-2204-Build}
BUILD_INFO=$(curl "https://build.webkit.org/api/v2/builders/$BUILDER_NAME/builds?order=-number&limit=1&complete=true&state_string=build%20successful" 2>/dev/null)
NUMBER=$(jq -Mr '.builds[0].number' <<< "$BUILD_INFO")
BUILDER_ID=$(jq -Mr '.builds[0].builderid' <<< "$BUILD_INFO")
CHANGES_INFO=$(curl "https://build.webkit.org/api/v2/builders/$BUILDER_ID/builds/$NUMBER/changes" 2>/dev/null)
BUILD_REV=$(jq -Mr '.changes[0].revision' <<< "$CHANGES_INFO")

echo "$BUILD_REV"
