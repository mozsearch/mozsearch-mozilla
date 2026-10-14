#!/usr/bin/env bash

set -x # Show commands
set -eu # Errors/undefined vars are fatal
set -o pipefail # Check all commands in a pipeline

# Install what building try pushes in a sandbox needs (see inbuild.sh): GNU
# make (which mach runs from the system), bubblewrap, and an AppArmor profile
# letting bwrap make the unprivileged user namespaces its sandbox needs (Ubuntu
# 24.04 only allows programs whose profiles say so, and it has none for bwrap;
# later releases do), and with --prepare, what prepare.sh also needs.  On the
# indexer (firefox-try's setup, for prepare.sh) and the web server (its
# web-server-setup, for analyze.sh).
#
# Usage: install-sandbox.sh [--prepare]

PACKAGES=(bubblewrap make)
if [ "${1:-}" = "--prepare" ]; then
    PACKAGES+=(zstd cpio rsync curl jq parallel)
fi
sudo apt-get update -q
sudo apt-get install -y -q "${PACKAGES[@]}"

if [ -d /etc/apparmor.d ] && ! [ -f /etc/apparmor.d/bwrap ]; then
    sudo tee /etc/apparmor.d/bwrap > /dev/null <<"EOF"
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,

  include if exists <local/bwrap>
}
EOF
    sudo apparmor_parser -r /etc/apparmor.d/bwrap
fi

# (prepare.sh checks this too, so that try pushes aren't built unsandboxed.)
bwrap --ro-bind / / --unshare-net --unshare-pid true
