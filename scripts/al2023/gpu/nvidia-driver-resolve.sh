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

# ---------- resolve-once (EKS behavior) ----------
# EKS resolves on first boot and keeps the result; the other tree may even be deleted. We keep both
# trees (so a reboot is a true no-op and we can measure it), but we DO honor resolve-once semantics:
# once committed, we do not flip the symlink. nvidia-setup's own .driver-committed gates the heavy work.
if [ -L "$NV/current" ] && [ -e "$STATE/.resolved" ]; then
  log "already resolved to $(readlink "$NV/current") (resolve-once); nothing to do"
  exit 0
fi

# ---------- version by instance type (IMDSv2) ----------
imds_token() { curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true; }
instance_type() {
  local tok; tok=$(imds_token)
  if [ -n "$tok" ]; then
    curl -sf -H "X-aws-ec2-metadata-token: $tok" \
      "http://169.254.169.254/latest/meta-data/instance-type" 2>/dev/null && return 0
  fi
  # IMDS unreachable (e.g. air-gapped test): allow a test override.
  echo "${NVOPTIONB_TEST_INSTANCE_TYPE:-}"
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
[ -d "$TREE/flavors/$flavor" ] || die "tree $TREE has no $flavor flavor built"

# ---------- commit the symlink + sentinel ----------
ln -sfn "$TREE" "$NV/current"
printf '%s\n' "$flavor" >"$NV/current/.driver-flavor"
printf 'branch=%s\nversion=%s\nflavor=%s\ntree=%s\ninstance_type=%s\n' \
  "$branch" "$version" "$flavor" "$TREE" "${ITYPE:-unknown}" >"$RUN/resolved"
touch "$STATE/.resolved"
log "resolved -> $branch/$version flavor=$flavor ($reason); /opt/nvidia/current -> $TREE in $(el) ms"
