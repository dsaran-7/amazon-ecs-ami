#!/usr/bin/env bash
# nvidia-setup (Option B, EKS-parity) — reimplements the EKS "setup" unit for ECS.
#
# Preconditions (enforced by the unit ordering): nvidia-driver-resolve has pointed /opt/nvidia/current
# at the chosen tree and written .driver-flavor, and the three overlay mounts have layered the tree's
# usr/{bin,lib64,share} over the host. This script then COMMITS the driver:
#   * /etc config:    reflink-copy the tree's /etc over the host /etc (every boot, no-clobber).
#   * modules+fw:     copy the flavor's extra/*.ko and firmware into /lib/modules + /lib/firmware,
#                     then depmod (first boot only, gated by .driver-committed).
#   * module load:    modprobe nvidia then the rest of the flavor's modules (every boot).
#   * daemons:        copy all of the tree's units to /usr/lib/systemd/system, then enable+start the
#                     flavor's subset (first boot only). GRID adds nvidia-gridd.
#   * rpmdb:          rpm -i --justdb --noscripts --nodeps --nodigest --nosignature the tree's .rpms
#                     plus the flavor's .rpms (first boot only). This is the literal last step of the
#                     EKS doc; it makes the rpmdb REPORT the packages installed while their files came
#                     from the build-time unpack and their scriptlets never ran ("the rpmdb lies").
#
# This is the EKS *mechanism* reproduced on ECS's recipe, NOT a copy of EKS's code.
#
# ---------------------------------------------------------------------------------------------------
# FAILURE MODES (Option B boot path) and how this script handles them. Compare with Option A's
# nvidia-driver-select, whose failures are dnf-transaction failures with an LTS fallback:
#
#   1. OVERLAY NOT MOUNTED. If any of /usr/{bin,lib64,share} is not an overlay (mount unit failed,
#      e.g. a stale upperdir or a custom AMI already owning the path), the userspace libs/binaries are
#      missing. We verify all three are mounted before loading modules, and FAIL LOUDLY if not --
#      ecs.service then will not start a GPU host with no usable driver (defect 5), which is correct.
#   2. MODULE LOAD FAILURE. A harvested .ko that does not match the running kernel (customer unlocked
#      and updated the kernel) cannot load, and Option B has NO DKMS source to rebuild from (a
#      documented Option B drawback). We detect the modprobe failure and FAIL LOUDLY. There is no
#      in-place recovery: the fix is a new AMI with modules for the new kernel.
#   3. JUSTDB REGISTRATION FAILURE. `rpm --justdb` can fail on a corrupt rpmdb or a half-written
#      .driver-committed state (power loss between copying files and registering). We register into a
#      marker-guarded critical section: write .justdb-in-progress before, clear it after; on the next
#      boot, if the marker is present, we drop any partially-registered NEVRAs from the rpmdb and
#      re-register the full set. rpm --justdb touches ONLY the database (no files), so a failure cannot
#      corrupt the committed userspace -- unlike Option A's real dnf transaction.
#   4. DISK FULL. The first-boot copies (modules+firmware ~tens of MiB, /etc reflink) can hit ENOSPC.
#      We check each copy's exit status and FAIL LOUDLY with the failing step; nothing is half-loaded
#      because modprobe runs only after the copies succeed.
#   5. CHECKSUM / SIGNATURE. Option B does NOT run a boot-time dnf transaction, so there is no gpg/
#      checksum gate at boot (the RPMs were verified with `rpm -K` at BUILD time, in stage-nvidia-
#      optionb.sh, and justdb uses --nodigest --nosignature by design -- EKS's own flags). This is a
#      genuine difference from Option A, which verifies gpg+sha256 at boot; it is called out in the
#      A-vs-B writeup, not silently ignored.
# ---------------------------------------------------------------------------------------------------
set -Eeuo pipefail
shopt -s nullglob

NV=/opt/nvidia
CUR="$NV/current"
RUN=/run/nvidia-optionb
STATE=/var/lib/nvidia-optionb
K=$(uname -r)
COMMITTED="$STATE/.driver-committed"
JUSTDB_INPROGRESS="$STATE/.justdb-in-progress"
T0=$(date +%s%N)
el() { echo $(( ($(date +%s%N) - T0) / 1000000 )); }
log() { echo "[+$(el)ms] setup: $*"; }
die() { log "ERROR: $*"; exit 1; }

mkdir -p "$RUN" "$STATE"
[ -L "$CUR" ] && [ -d "$CUR" ] || die "$CUR is not a resolved tree (did nvidia-driver-resolve run?)"
FLAVOR=$(cat "$CUR/.driver-flavor" 2>/dev/null || echo open)
FLAVOR_SUBTREE="$CUR/flavors/$FLAVOR"
[ -d "$FLAVOR_SUBTREE" ] || die "flavor subtree $FLAVOR_SUBTREE missing"
log "committing tree $(readlink "$CUR") flavor=$FLAVOR kernel=$K"

# ---------- failure mode 1: verify the three overlays are actually mounted ----------
for p in /usr/bin /usr/lib64 /usr/share; do
  findmnt -no FSTYPE "$p" 2>/dev/null | grep -qx overlay || die "overlay not mounted at $p (mount unit failed); refusing to load a half-set-up driver"
done
log "all three /usr overlays mounted"

# ---------- /etc config (every boot, no-clobber reflink) ----------
if [ -d "$CUR/etc" ]; then
  cp -a -n --reflink=auto "$CUR"/etc/. /etc/ 2>/dev/null || die "copying tree /etc failed (disk full?)"
  log "reflinked tree /etc over host /etc"
fi

LIB_MODULES="/lib/modules/$K"
EXTRA_DST="$LIB_MODULES/extra"
FW_DST="/lib/firmware"

# ---------- modules + firmware (first boot only) + depmod ----------
if [ ! -e "$COMMITTED" ]; then
  mkdir -p "$EXTRA_DST"
  if [ -d "$FLAVOR_SUBTREE/lib/modules/$K/extra" ]; then
    cp -a --reflink=auto "$FLAVOR_SUBTREE/lib/modules/$K/extra/." "$EXTRA_DST/" \
      || die "copying $FLAVOR modules failed (disk full?)"       # failure mode 4
    log "copied $(ls "$EXTRA_DST" | wc -l) module files for flavor $FLAVOR"
  else
    die "no modules for flavor $FLAVOR at $FLAVOR_SUBTREE/lib/modules/$K/extra"
  fi
  # Firmware, if the tree carries any (lib/firmware/nvidia/<ver>).
  for fwsrc in "$CUR"/lib/firmware "$FLAVOR_SUBTREE"/lib/firmware; do
    [ -d "$fwsrc" ] || continue
    cp -a --reflink=auto "$fwsrc/." "$FW_DST/" || die "copying firmware from $fwsrc failed (disk full?)"
  done
  depmod "$K" || die "depmod failed"
  log "depmod done"
fi

# ---------- module load (every boot) ----------
# failure mode 2: a .ko that does not match the running kernel will fail here; no DKMS to rebuild.
load_mod() { modprobe "$1" 2>&1 | sed "s/^/  modprobe $1| /" || return 1; }
modprobe nvidia || die "modprobe nvidia failed (kernel mismatch? Option B has no DKMS source to rebuild)"
for ko in "$EXTRA_DST"/*.ko*; do
  m=$(basename "$ko"); m="${m%%.ko*}"
  case "$m" in nvidia | nvidia-peermem) continue ;; esac   # nvidia loaded above; peermem optional (needs IB)
  modprobe "$m" 2>/dev/null || log "note: modprobe $m skipped/failed (optional on this hardware)"
done
/usr/bin/nvidia-modprobe -c 0 -u 2>/dev/null || true
loaded=$(cat /sys/module/nvidia/version 2>/dev/null || true)
[ -n "$loaded" ] || die "nvidia module not loaded after modprobe"
log "nvidia $loaded loaded ($(modinfo -F filename nvidia 2>/dev/null))"

# ---------- daemons (first boot only) ----------
if [ ! -e "$COMMITTED" ]; then
  # Copy ALL of the tree's units (so a customer can enable nvidia-imex etc. later), then enable the subset.
  if ls "$CUR"/usr/lib/systemd/system/*.service >/dev/null 2>&1; then
    install -m0644 "$CUR"/usr/lib/systemd/system/*.service /usr/lib/systemd/system/ || die "installing tree units failed"
  fi
  # GRID license daemon bits live in the tree's grid-extra (harvested from the runfile at build).
  if [ "$FLAVOR" = grid ] && [ -d "$CUR/grid-extra" ]; then
    cp -a --reflink=auto "$CUR/grid-extra/." / || die "installing grid-extra failed"
  fi
  DAEMONS=(nvidia-persistenced.service set-nvidia-clocks.service)
  # fabricmanager only where present (NVSwitch); it fails on non-NVSwitch hardware as on every AMI.
  [ -e /usr/lib/systemd/system/nvidia-fabricmanager.service ] && DAEMONS+=(nvidia-fabricmanager.service)
  [ "$FLAVOR" = grid ] && DAEMONS+=(nvidia-gridd.service)
  systemctl daemon-reload
  systemctl enable "${DAEMONS[@]}" 2>/dev/null || log "note: some daemons could not be enabled: ${DAEMONS[*]}"
  systemctl start --no-block "${DAEMONS[@]}" 2>/dev/null || log "note: some daemons did not start (expected on hw without NVSwitch/vGPU)"
  log "enabled+started daemon subset: ${DAEMONS[*]}"
fi

# ---------- rpmdb registration via --justdb (first boot only) ----------
# failure mode 3: guarded by .justdb-in-progress so a power loss mid-registration self-heals.
if [ ! -e "$COMMITTED" ]; then
  RPMS=("$CUR"/.rpms/*.rpm "$FLAVOR_SUBTREE"/.rpms/*.rpm)
  if [ ${#RPMS[@]} -gt 0 ]; then
    # Recover a prior interrupted registration: drop any of these NEVRAs already in the rpmdb, then re-add.
    if [ -e "$JUSTDB_INPROGRESS" ]; then
      log "recovering from an interrupted justdb registration"
      names=$(for r in "${RPMS[@]}"; do rpm -qp --qf '%{NAME}\n' "$r" 2>/dev/null; done | sort -u)
      # shellcheck disable=SC2086
      rpm -e --justdb --nodeps --noscripts --notriggers $names 2>/dev/null || true
    fi
    : >"$JUSTDB_INPROGRESS"; sync
    if rpm -i --justdb --noscripts --nodeps --nodigest --nosignature "${RPMS[@]}" 2>&1 | sed 's/^/  rpm| /'; then
      rm -f "$JUSTDB_INPROGRESS"; sync
      log "registered ${#RPMS[@]} version-specific RPMs in the rpmdb (--justdb; rpmdb now reports them installed)"
    else
      # justdb touches only the database, never files -- the committed userspace is intact. Fail loudly
      # so the state is visible, but the GPU is already usable (modules loaded, libs overlaid).
      rm -f "$JUSTDB_INPROGRESS"
      die "rpm --justdb registration failed; rpmdb left inconsistent (userspace is intact: modules loaded, libs overlaid)"
    fi
  fi
fi

touch "$COMMITTED"; sync
echo "$(date -u +%FT%TZ) committed $(readlink "$CUR") flavor=$FLAVOR nvidia=$loaded" >>"$STATE/history"
log "done (committed $FLAVOR $loaded) in $(el) ms"
