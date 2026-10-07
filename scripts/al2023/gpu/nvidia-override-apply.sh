#!/usr/bin/env bash
# nvidia-override-apply (Option B) — honor the customer driver-branch override on Option B.
#
# Option B chooses its tree in nvidia-driver-resolve, right after local-fs.target. That has to be early
# (the /usr overlays depend on it), so it runs before cloud-init has written any customer file. This unit
# runs AFTER cloud-init.service, reads the same override contract as Option A's nvidia-driver-select
# (/etc/ecs/nvidia-driver-select.override, NVIDIA_DRIVER_BRANCH=auto|lts|pb), and, if the override is
# valid and differs from the resolved tree, re-points /opt/nvidia/current and reboots ONCE so the overlays
# mount the requested tree. It runs before nvidia-setup, so nothing has been committed yet on that boot.
#
# Validation mirrors Option A:
#   pb  rejected if the GPU needs the GRID or proprietary flavor (the PB tree is open-only);
#   lts always accepted; on a PB-family instance (today g7) it logs UNQUALIFIED configuration.
# Prototype limitation: applied only before the first commit (.driver-committed). A change made after
# the driver is committed is logged and NOT applied (Option B resolves once).
set -Eeuo pipefail

OVR=/etc/ecs/nvidia-driver-select.override
CONF=/etc/ecs/nvidia-driver-select
NV=/opt/nvidia
RUN=/run/nvidia-optionb
STATE=/var/lib/nvidia-optionb
T0=$(date +%s%N)
el() { echo $(( ($(date +%s%N) - T0) / 1000000 )); }
log() { echo "[+$(el)ms] override: $*"; }

mkdir -p "$RUN" "$STATE"
req=auto
[ -r "$OVR" ] && req=$(sed -n 's/^NVIDIA_DRIVER_BRANCH=//p' "$OVR" | tail -1 | tr -d '[:space:]')
case "$req" in
  auto | "") log "no override (auto)"; exit 0 ;;
  lts | pb) ;;
  *) log "WARNING: ignoring invalid NVIDIA_DRIVER_BRANCH=$req"; exit 0 ;;
esac

[ -L "$NV/current" ] || { log "ERROR: $NV/current not resolved; cannot apply override"; exit 1; }
cur=$(basename "$(readlink "$NV/current")")
flavor=$(cat "$NV/current/.driver-flavor" 2>/dev/null || echo open)
family=$(tr -d '[:space:]' </sys/devices/virtual/dmi/id/product_name 2>/dev/null | cut -d. -f1)

if [ "$req" = pb ] && [ "$flavor" != open ]; then
  log "WARNING: override NVIDIA_DRIVER_BRANCH=pb rejected (GPU needs the $flavor flavor; PB tree is open-only); keeping $cur"
  exit 0
fi
if [ "$req" = lts ] && [ -n "$family" ] && grep -qiE "^${family}[[:space:]]*$" "$CONF/optionb-pb-families" 2>/dev/null; then
  log "WARNING: UNQUALIFIED configuration: override lts accepted on $family (PB-required family)"
fi

if [ "$req" = "$cur" ]; then
  log "override $req matches the resolved tree; nothing to do"
  rm -f "$STATE"/.override-rebooted-*
  exit 0
fi
if [ -e "$STATE/.driver-committed" ]; then
  log "WARNING: override $req differs from committed tree $cur; not applied (driver already committed; resolve-once)"
  exit 0
fi
if [ -e "$STATE/.override-rebooted-$req" ]; then
  log "ERROR: still on $cur after rebooting once for override $req; giving up"
  exit 1
fi
[ -d "$NV/$req/flavors/$flavor" ] || { log "ERROR: tree $NV/$req has no $flavor flavor"; exit 1; }

ln -sfn "$NV/$req" "$NV/current"
printf '%s\n' "$flavor" >"$NV/current/.driver-flavor"
touch "$STATE/.override-rebooted-$req" "$STATE/.clear-overlay-upper" "$RUN/override-reboot-pending"
sync
log "override $req applied: /opt/nvidia/current -> $NV/$req (was $cur); rebooting once to mount it"
systemctl reboot --no-block
