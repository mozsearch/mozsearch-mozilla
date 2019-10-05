#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# Helper script to download the gecko-dev or gecko-blame tarball from S3
# into the working dir if it hasn't already been downloaded,
# and then unpack it into the specified destination folder.
# This is a shared helper because we have multiple repos that
# download the same tarball which takes time/bandwidth; doing
# it once and reusing it saves about 3 minutes/7.5 Gb per
# additional repo that uses it.

if [ $# -ne 2 ]; then
    echo "Usage: $0 <gecko-dev|gecko-blame> <destination>"
    echo " e.g.: $0 gecko-blame \$PWD"
    exit 1
fi

TARBALL="$1"
DESTDIR="$2"

if [ -d "${DESTDIR}/${TARBALL}" ]; then
    echo "Found pre-existing folder at ${DESTDIR}/${TARBALL}, skipping re-download..."
    exit 0
fi

if [ ! -f "$WORKING/${TARBALL}.tar" ]; then
    pushd "$WORKING"
    wget -nv "https://s3-us-west-2.amazonaws.com/searchfox.repositories/${TARBALL}.tar"
    popd
fi

tar xf "$WORKING/${TARBALL}.tar" -C "$DESTDIR"
rm "$WORKING/${TARBALL}.tar"
