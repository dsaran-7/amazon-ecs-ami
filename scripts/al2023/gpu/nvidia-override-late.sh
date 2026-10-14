#!/usr/bin/env bash
# nvidia-override-late (Option C, lean build) — after cloud-init.
#
# The lean build picks the tree before cloud-init, so the customer override (written from user data) isn't visible
# then. If an override asks for a different branch than the one just committed, switch to it in this boot:
# resolve --late cleans the old tree out of /usr, /lib/modules and the rpmdb, then the new tree is copied in and
# committed. The unit only runs when the override file exists, and exits at once when the override matches.
set -Eeuo pipefail
STATE=/var/lib/nvidia-optionb
RUN=/run/nvidia-optionb
CUR=/opt/nvidia/current
log() { echo "override-late: $*"; }

mkdir -p "$RUN"; rm -f "$RUN/late-switch"
/usr/libexec/nvidia-optionb/nvidia-driver-resolve --late
[ -e "$RUN/late-switch" ] || { log "the committed tree already matches the override; nothing to do"; exit 0; }
log "switching to $(readlink "$CUR") for the customer override"
for d in bin lib64 share; do
  [ -d "$CUR/usr/$d" ] || continue
  cp -a --reflink=auto "$CUR/usr/$d/." "/usr/$d/"
  touch "$STATE/.usr-$d-copied"
done
/sbin/ldconfig
exec /usr/libexec/nvidia-optionb/nvidia-setup
