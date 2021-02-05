#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# Helper script to download the gecko or gecko-blame tarball from S3
# into the working dir if it hasn't already been downloaded,
# and then unpack it into the specified destination folder.
# This is a shared helper because we have multiple repos that
# download the same tarball which takes time/bandwidth; doing
# it once and reusing it saves about 3 minutes/7.5 Gb per
# additional repo that uses it.

if [ $# -ne 2 ]; then
    echo "Usage: $0 <gecko|gecko-blame> <destination>"
    echo " e.g.: $0 gecko-blame \$PWD"
    exit 1
fi

TARBALL="$1"
DESTDIR="$2"

# This is a bit of a hack, but there are only two allowed values for
# TARBALL so it's not terrible. And anyway (almost) no other repo
# respects this convention of having the top-level folder inside the
# tarball match the tarball name, since most repos use "git" and "blame"
# folders inside their tarballs, and someday the gecko tarballs will
# as well.
if [[ "$TARBALL" == "gecko" ]]; then
    TARBALL_FOLDER="gecko-dev"
elif [[ "$TARBALL" == "gecko-blame" ]]; then
    TARBALL_FOLDER="gecko-blame"
fi

if [ -d "${DESTDIR}/${TARBALL_FOLDER}" ]; then
    echo "Found pre-existing folder at ${DESTDIR}/${TARBALL_FOLDER}, skipping re-download..."
    exit 0
fi

if [ ! -f "$WORKING/${TARBALL}.tar" ]; then
    delete_partial_download() {
        rm -f "$WORKING/${TARBALL}.tar"
        exit 1
    }

    # This download can take a long time. If the user interrupts with ctrl-c, then
    # clean up the partial download or it can cause trouble the next time the script
    # is run.
    trap "delete_partial_download" SIGINT
    pushd "$WORKING"
    wget -nv "https://s3-us-west-2.amazonaws.com/searchfox.repositories/${TARBALL}.tar"
    popd
    trap - SIGINT   # clear trap now that download is done
fi

tar xf "$WORKING/${TARBALL}.tar" -C "$DESTDIR"
