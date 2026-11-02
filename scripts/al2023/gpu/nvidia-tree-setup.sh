#!/usr/bin/env bash
# Put the resolved NVIDIA driver branch's tree in place: copy /opt/nvidia/<branch>/usr over /usr, once per instance.
#
# Runs after nvidia-branch-resolve.sh and before nvidia-kmod-load, so the GSP firmware under /usr/lib/firmware is in
# place before the kernel module loads. The default branch is the native install, so there's nothing to copy. Nothing
# runs this yet: the AMI doesn't install it, and nvidia_driver_trees_al2023 is off by default.
set -Eeuo pipefail

CONF=${NVIDIA_TREES_CONF:-/etc/nvidia-driver-trees}
NV=${NVIDIA_TREES_DIR:-/opt/nvidia}
RUN=${NVIDIA_TREES_RUN:-/run/nvidia-driver-trees}
STATE=${NVIDIA_TREES_STATE:-/var/lib/nvidia-driver-trees}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

branch=$(cat "$RUN/branch") || die "no branch in $RUN/branch"
default=$(awk '$1 !~ /^#/ && NF {print $1; exit}' "$CONF/nvidia-branches")
if [[ $branch == "$default" ]]; then
    echo "nvidia-tree-setup: $branch is the default branch, nothing to copy"
    exit 0
fi
if [[ -e $STATE/$branch.copied ]]; then
    echo "nvidia-tree-setup: the $branch tree is already in place"
    exit 0
fi

# The marker is written only after the copy and ldconfig finish, so an interrupted copy is redone on the next boot.
t0=$(date +%s%N)
cp -a --reflink=auto "$NV/$branch/usr/." /usr/
ldconfig
mkdir -p "$STATE"
touch "$STATE/$branch.copied"
echo "nvidia-tree-setup: copied the $branch tree in $((($(date +%s%N) - t0) / 1000000)) ms"
