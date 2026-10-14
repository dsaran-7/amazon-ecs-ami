#!/usr/bin/env bash
# nvidia-driver-resolve (Option B, EKS-parity) — reimplements the EKS "resolve" unit for ECS.
#
# Resolve the target NVIDIA driver VERSION by matching the running instance type against a static
# support list (EKS mechanism: "g7 instances resolve to 595 and everything else resolves to 580").
# Resolve the FLAVOR by PCI subdevice, exactly as nvidia-kmod-load.sh does today (GRID for g6f/gr6f
# vGPU subdevices, proprietary for P3/P3dn/G3, open otherwise). Then point /opt/nvidia/current at the
# chosen tree and write the .driver-flavor sentinel that nvidia-setup reads.
#
# This is the EKS *mechanism* reproduced on ECS's recipe, NOT a copy of EKS's code. ECS's own
# recommended Option A resolves by PCI device ID instead (an instance-type list goes stale silently
# when a new family ships); here we deliberately follow the EKS instance-type mechanism to benchmark
# EKS parity faithfully.
set -Eeuo pipefail
shopt -s nullglob

CONF=/etc/ecs/nvidia-driver-select
OVR=/etc/ecs/nvidia-driver-select.override
NV=/opt/nvidia
RUN=/run/nvidia-optionb
STATE=/var/lib/nvidia-optionb
T0=$(date +%s%N)
el() { echo $(( ($(date +%s%N) - T0) / 1000000 )); }
log() { echo "[+$(el)ms] resolve: $*"; }
die() { log "ERROR: $*"; exit 1; }

mkdir -p "$RUN" "$STATE"
[ -r "$CONF/optionb-branches" ] || die "$CONF/optionb-branches missing"
. "$CONF/optionb-branches"
[ -n "${LTS_VERSION:-}" ] && [ -n "${PB_VERSION:-}" ] || die "optionb-branches incomplete"
# overlay = Option B (tree overlaid on /usr, resolve before local-fs); copy = Option C (tree copied into
# /usr, resolve after cloud-init). Written at build by stage-nvidia-optionb.sh.
LAYOUT=$(cat "$CONF/optionb-layout" 2>/dev/null || echo overlay)

# ---------- after an override switch: start the new tree with empty overlay upper layers ----------
# nvidia-override-apply re-pointed the tree and rebooted. Anything written through the overlays while the
# previous tree was mounted would otherwise shadow the new tree. This unit runs before the mounts.
if [ -e "$STATE/.clear-overlay-upper" ]; then
  for d in bin lib64 share; do rm -rf /var/lib/ecs/nvidia/$d/upper /var/lib/ecs/nvidia/$d/work; mkdir -p /var/lib/ecs/nvidia/$d/upper /var/lib/ecs/nvidia/$d/work; done
  rm -f "$STATE/.clear-overlay-upper"
  log "cleared overlay upper/work dirs after a driver-branch override switch"
fi

# ---------- resolve-once (EKS behavior) ----------
# EKS resolves on first boot and keeps the result; the other tree may even be deleted. We keep both
# trees (so a reboot is a true no-op and we can measure it), but we DO honor resolve-once semantics:
# once committed, we do not flip the symlink. nvidia-setup's own .driver-committed gates the heavy work.
# ---------- instance-type change (Option C only) ----------
# Resolve-once keeps the first tree. In the copy layout that strands an instance restarted as a different
# family (a G7 restarted as a P3 would keep 595). If the instance type differs from the one we resolved for,
# drop the resolve marker so the normal path below runs; if it then picks a different tree or flavor, the old
# tree is cleaned out of /usr, /lib/modules and the rpmdb before the new one is copied in.
OLD_TREE=; OLD_FLAVOR=
if [ "$LAYOUT" = copy ] && [ -L "$NV/current" ] && [ -e "$STATE/.resolved" ] && [ -s "$STATE/.resolved-itype" ]; then
  now=$(tr -d '[:space:]' </sys/devices/virtual/dmi/id/product_name 2>/dev/null || true)
  was=$(cat "$STATE/.resolved-itype")
  if [ -n "$now" ] && [ "$now" != "$was" ]; then
    OLD_TREE=$(readlink "$NV/current"); OLD_FLAVOR=$(cat "$NV/current/.driver-flavor" 2>/dev/null || echo open)
    log "instance type changed ($was -> $now); re-resolving (was $(basename "$OLD_TREE")/$OLD_FLAVOR)"
    rm -f "$STATE/.resolved"
  fi
fi

if [ -L "$NV/current" ] && [ -e "$STATE/.resolved" ]; then
  # $RUN is tmpfs, so re-derive $RUN/resolved from the kept symlink. nvidia-setup reads it on any boot
  # before its first commit, which includes the boot right after an nvidia-override-apply switch.
  TREE=$(readlink "$NV/current"); branch=$(basename "$TREE")
  case "$branch" in lts) version=$LTS_VERSION ;; pb) version=$PB_VERSION ;; *) die "unknown tree $TREE" ;; esac
  flavor=$(cat "$NV/current/.driver-flavor" 2>/dev/null || echo open)
  ITYPE=$(tr -d '[:space:]' </sys/devices/virtual/dmi/id/product_name 2>/dev/null || true)
  printf 'branch=%s\nversion=%s\nflavor=%s\ntree=%s\ninstance_type=%s\n' \
    "$branch" "$version" "$flavor" "$TREE" "${ITYPE:-unknown}" >"$RUN/resolved"
  log "already resolved to $TREE (resolve-once); nothing to do"
  exit 0
fi

# ---------- version by instance type (DMI) ----------
# Read from DMI product_name, as EKS does, NOT IMDS: this unit runs right after local-fs.target, before
# networking, so the three /usr overlays can mount early without an ordering cycle (see the .service).
# On Nitro, product_name is the instance type (e.g. g7.2xlarge).
DMI_PRODUCT_NAME="${NVOPTIONB_DMI_PRODUCT_NAME:-/sys/devices/virtual/dmi/id/product_name}"
instance_type() {
  if [ -n "${NVOPTIONB_TEST_INSTANCE_TYPE:-}" ]; then echo "$NVOPTIONB_TEST_INSTANCE_TYPE"; return 0; fi
  [ -r "$DMI_PRODUCT_NAME" ] && tr -d '[:space:]' <"$DMI_PRODUCT_NAME"
}
ITYPE=$(instance_type)
FAMILY="${ITYPE%%.*}"
log "instance-type=${ITYPE:-unknown} family=${FAMILY:-unknown}"

branch=lts; version=$LTS_VERSION; reason="default (LTS-first)"
if [ -n "$FAMILY" ] && [ -r "$CONF/optionb-pb-families" ]; then
  if grep -qiE "^${FAMILY}[[:space:]]*$" "$CONF/optionb-pb-families"; then
    branch=pb; version=$PB_VERSION; reason="family $FAMILY in optionb-pb-families"
  fi
fi

TREE="$NV/$branch"
[ -d "$TREE" ] || die "resolved tree $TREE does not exist"

# ---------- flavor by PCI subdevice (same rule as nvidia-kmod-load.sh) ----------
NVIDIA_VENDOR_ID="10de"
GRID_SUBDEVICES=(27b8:1733 27b8:1735 27b8:1737)
PROPRIETARY_SUBDEVICES=(1db1:1212 1db5:1249 13f2:113a)
subs=()
for d in /sys/bus/pci/devices/*; do
  [ "$(<"$d/vendor")" = 0x10de ] || continue
  case "$(<"$d/class")" in 0x0300* | 0x0302*) ;; *) continue ;; esac
  subs+=("$(sed 's/^0x//' "$d/device"):$(sed 's/^0x//' "$d/subsystem_device")")
done
[ -n "${NVOPTIONB_TEST_DEVICES:-}" ] && read -ra subs <<<"$NVOPTIONB_TEST_DEVICES"
match_sub() { local s g; for s in "${subs[@]}"; do for g in $1; do [ "$s" != "$g" ] || return 0; done; done; return 1; }

flavor=open
if match_sub "${GRID_SUBDEVICES[*]}"; then flavor=grid
elif match_sub "${PROPRIETARY_SUBDEVICES[*]}"; then flavor=proprietary
fi
# PB tree is open-only (Blackwell is open-only in every branch). If PB resolved but the flavor is not
# open, that is an unsupported combination; fall back to LTS, which carries all three flavors.
if [ "$branch" = pb ] && [ "$flavor" != open ]; then
  log "WARNING: PB resolved but flavor=$flavor (PB tree is open-only); falling back to LTS $LTS_VERSION"
  branch=lts; version=$LTS_VERSION; TREE="$NV/lts"; reason="PB has no $flavor flavor; LTS-first"
fi
# ---------- customer override (Option C only) ----------
# Option C resolves after cloud-init, so a cloud-config write_files override already exists and applies in this
# boot. Same contract and validation as Option A and Option B's nvidia-override-apply: pb is rejected when the
# GPU needs the GRID or proprietary flavor (the PB tree is open-only); lts on a PB-required family is accepted
# with an UNQUALIFIED warning. Option B can't do this here: it resolves before cloud-init has run.
if [ "$LAYOUT" = copy ] && [ -r "$OVR" ]; then
  req=$(sed -n 's/^NVIDIA_DRIVER_BRANCH=//p' "$OVR" | tail -1 | tr -d '[:space:]')
  case "$req" in
    auto | "") log "override: none (auto)" ;;
    lts)
      [ "$branch" = pb ] && log "WARNING: UNQUALIFIED configuration: override lts accepted on ${FAMILY:-unknown} (PB-required family)"
      branch=lts; version=$LTS_VERSION; TREE="$NV/lts"; reason="customer override lts" ;;
    pb)
      if [ "$flavor" != open ]; then
        log "WARNING: override NVIDIA_DRIVER_BRANCH=pb rejected (GPU needs the $flavor flavor; PB tree is open-only); keeping $branch"
      else
        branch=pb; version=$PB_VERSION; TREE="$NV/pb"; reason="customer override pb"
      fi ;;
    *) log "WARNING: ignoring invalid NVIDIA_DRIVER_BRANCH=$req" ;;
  esac
fi
[ -d "$TREE/flavors/$flavor" ] || die "tree $TREE has no $flavor flavor built"

# ---------- after a type change: clean out the old tree if the choice changed ----------
if [ -n "$OLD_TREE" ]; then
  if [ "$OLD_TREE" = "$TREE" ] && [ "$OLD_FLAVOR" = "$flavor" ]; then
    log "re-resolve kept $(basename "$TREE")/$flavor; nothing to clean"
  else
    for d in bin lib64 share; do
      [ -d "$OLD_TREE/usr/$d" ] || continue
      (cd "$OLD_TREE/usr/$d" && find . ! -type d -print0) | (cd "/usr/$d" && xargs -0 -r rm -f --)
      rm -f "$STATE/.usr-$d-copied"
    done
    for f in "$OLD_TREE/flavors/$OLD_FLAVOR/lib/modules/$(uname -r)/extra"/*; do rm -f "/lib/modules/$(uname -r)/extra/$(basename "$f")"; done
    olds=()
    for r in "$OLD_TREE"/.rpms/*.rpm "$OLD_TREE/flavors/$OLD_FLAVOR"/.rpms/*.rpm; do
      [ -e "$r" ] && olds+=("$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$r" 2>/dev/null)")
    done
    [ ${#olds[@]} -gt 0 ] && rpm -e --justdb --nodeps --noscripts --notriggers "${olds[@]}" 2>/dev/null || true
    rm -f "$STATE/.driver-committed" "$STATE/.fallback-attempted" "$STATE/.packages-registered"
    log "cleaned $(basename "$OLD_TREE")/$OLD_FLAVOR out of /usr, /lib/modules and the rpmdb (${#olds[@]} packages)"
  fi
fi

# ---------- commit the symlink + sentinel ----------
ln -sfn "$TREE" "$NV/current"
printf '%s\n' "$flavor" >"$NV/current/.driver-flavor"
printf 'branch=%s\nversion=%s\nflavor=%s\ntree=%s\ninstance_type=%s\n' \
  "$branch" "$version" "$flavor" "$TREE" "${ITYPE:-unknown}" >"$RUN/resolved"
touch "$STATE/.resolved"
[ -n "${ITYPE:-}" ] && printf '%s\n' "$ITYPE" >"$STATE/.resolved-itype"
log "resolved -> $branch/$version flavor=$flavor ($reason); /opt/nvidia/current -> $TREE in $(el) ms"
