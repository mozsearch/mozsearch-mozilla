#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# Helper script to download the gecko-dev tarball from S3
# into the working dir if it hasn't already been downloaded,
# and then unpack it into the specified destination folder.
# This is a shared helper because we have multiple repos that
# download the same tarball which takes time/bandwidth; doing
# it once and reusing it saves about 3 minutes/7.5 Gb per
# additional repo that uses it.

DESTDIR="$1"

if [ ! -f "$WORKING/gecko-dev.tar" ]; then
    pushd "$WORKING"
    wget -nv https://s3-us-west-2.amazonaws.com/searchfox.repositories/gecko-dev.tar
    popd
fi

tar xf "$WORKING/gecko-dev.tar" -C "$DESTDIR"
