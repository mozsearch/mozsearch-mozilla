#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <config-file> <tree> <channel>"
    echo " e.g.: $0 mozilla-central dev"
    echo ""
    echo "Run this inside the VM, checked out as 'config' under mozsearch"
    echo ""
    echo "Use the channel name 'release' if you want to check the production server."
    exit 1
fi

CONFIG_FILE=$1
TREE_NAME=$2
CHANNEL=$3

if [[ $CHANNEL = "release" ]]; then
  CHANNEL_PREFIX=
else
  CHANNEL_PREFIX=${CHANNEL}.
fi

export MOZSEARCH_PATH=/vagrant
export CONFIG_REPO=/vagrant/config

INSTA_FORCE_PASS=1 $MOZSEARCH_PATH/scripts/check-index.sh $CONFIG_FILE $TREE_NAME "" "https://${CHANNEL_PREFIX}searchfox.org/"
cargo insta review --workspace-root=/vagrant/config/
