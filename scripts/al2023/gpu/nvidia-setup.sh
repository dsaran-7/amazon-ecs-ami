#!/usr/bin/env bash
# nvidia-setup (Option B, EKS-parity) — reimplements the EKS "setup" unit for ECS.
#
# Preconditions (enforced by the unit ordering): nvidia-driver-resolve has pointed /opt/nvidia/current
# at the chosen tree and written .driver-flavor, and the three overlay mounts have layered the tree's
# usr/{bin,lib64,share} over the host. This script then COMMITS the driver:
#   * /etc config:    reflink-copy the tree's /etc over the host /etc (every boot, no-clobber).
#   * modules+fw:     copy the flavor's extra/*.ko into /lib/modules and the shared tree's
#                     usr/lib/firmware (GSP blobs) into /usr/lib/firmware, then depmod
#                     (first boot only, gated by .driver-committed).
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
#      checksum gate at boot, and justdb uses --nodigest --nosignature by design (EKS's own flags).
#      stage-nvidia-optionb.sh does not run `rpm -K` or gpgcheck at build time either, so the
#      unpacked RPMs are not signature-verified anywhere. This is a genuine difference from
#      Option A, which runs `rpm -K` at build and verifies gpg+sha256 at boot; it is called out in
#      the A-vs-B writeup, not silently ignored.
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
die() { log "ERROR: $*"; try_fallback "$*"; exit 1; }
# The build stores rarely used parts of the trees compressed (the whole PB tree, and the LTS proprietary and GRID
# modules); unpack one the first time it's chosen. Unpacked into a temporary directory and renamed into place, so a
# reset part-way through just unpacks again on the next boot.
ensure_unpacked() { # ensure_unpacked DIR
  local d=$1 tmp
  [ -d "$d" ] && return 0
  [ -f "$d.tar.zst" ] || return 0
  tmp="$(dirname "$d")/.unpacking-$(basename "$d")"
  rm -rf "$tmp"; mkdir -p "$tmp"
  log "unpacking ${d#/opt/nvidia/} ($(du -h "$d.tar.zst" | cut -f1) compressed)"
  zstd -dcq -T0 "$d.tar.zst" | tar -C "$tmp" -xf - --xattrs || die "unpacking $d failed"
  mv "$tmp/$(basename "$d")" "$d" || die "unpacking $d: the archive has no $(basename "$d")"
  rmdir "$tmp"; rm -f "$d.tar.zst"; sync
}
LAYOUT=$(cat /etc/ecs/nvidia-driver-select/optionb-layout 2>/dev/null || echo overlay)
LOADED_OK=0   # set once the nvidia module is loaded; after that a failure leaves a working GPU, so no fallback
# Option C: while a first-boot commit is in progress, only this script may load nvidia. Without this, a hard
# reset after the modules and their index are written lets udev autoload that half-committed module on the
# next boot, racing this script (measured: kernel 595 with 580 libraries, ECS never started).
HOLD=/etc/modprobe.d/nvidia-optionc-commit-hold.conf

# Unload nvidia and every module that depends on it, holders first. On failure, log what still holds it (the
# NVIDIA daemons are ordered after this unit, so none of them should have a device open yet).
unload_nvidia() {
  local m h p users=
  rm_tree() {
    for h in /sys/module/"$1"/holders/*; do rm_tree "$(basename "$h")"; done
    [ -e "/sys/module/$1" ] || return 0
    err=$(rmmod "$1" 2>&1) || log "rmmod $1: $err"
  }
  for m in nvidia_drm nvidia_peermem nvidia_uvm nvidia_modeset nvidia; do rm_tree "$m"; done
  [ -e /sys/module/nvidia ] || return 0
  for p in /proc/[0-9]*; do [ -n "$(ls -l "$p/fd" 2>/dev/null | grep /dev/nvidia)" ] && users+="$(cat "$p/comm" 2>/dev/null)[${p#/proc/}] "; done
  log "nvidia still loaded: refcnt=$(cat /sys/module/nvidia/refcnt 2>/dev/null) holders=[$(ls /sys/module/nvidia/holders 2>/dev/null | tr '\n' ' ')] users=[${users}] loaded=[$(lsmod | awk '/^nvidia/{printf "%s(%s) ", $1, $3}')]"
  return 1
}

# ---------- fallback to the LTS tree (Option C only) ----------
# Option A falls back to LTS 580 when the PB swap or load fails; Option B has no fallback, and a failed setup
# leaves a host that joins ECS with no GPU (measured on G7 with a corrupted module). In the copy layout the
# swap is safe within this boot: only the PB tree's own files were copied into /usr (the version-specific
# packages are never installed natively), so they are removed by path before the LTS tree is copied in. Runs
# at most once per instance. LTS drives every PB-required device today (2c3a, measured), with a warning.
try_fallback() {
  [ "$LAYOUT" = copy ] && [ "$LOADED_OK" = 0 ] || return 0
  [ -e "$STATE/.fallback-attempted" ] && return 0
  local cur; cur=$(basename "$(readlink "$CUR" 2>/dev/null)" 2>/dev/null || true)
  [ "$cur" = pb ] || return 0
  ensure_unpacked "$NV/lts/flavors/${FLAVOR:-open}"
  [ -d "$NV/lts/flavors/${FLAVOR:-open}" ] || { log "fallback: LTS tree has no ${FLAVOR:-open} flavor; not falling back"; return 0; }
  touch "$STATE/.fallback-attempted"; sync
  . /etc/ecs/nvidia-driver-select/optionb-branches
  log "WARNING: UNQUALIFIED configuration: PB setup failed ($1); falling back to LTS $LTS_VERSION"
  if ! unload_nvidia; then
    log "fallback: nvidia $(cat /sys/module/nvidia/version 2>/dev/null) is still loaded and cannot be unloaded; not falling back"
    return 0
  fi
  local d f
  for d in bin lib64 share; do
    [ -d "$NV/pb/usr/$d" ] || continue
    (cd "$NV/pb/usr/$d" && find . ! -type d -print0) | (cd "/usr/$d" && xargs -0 -r rm -f --)
  done
  for f in "$NV/pb/flavors/${FLAVOR:-open}/lib/modules/$K/extra"/*; do rm -f "/lib/modules/$K/extra/$(basename "$f")"; done
  ln -sfn "$NV/lts" "$CUR"
  printf '%s\n' "${FLAVOR:-open}" >"$CUR/.driver-flavor"
  printf 'branch=lts\nversion=%s\nflavor=%s\ntree=%s\nfallback=from-pb\n' "$LTS_VERSION" "${FLAVOR:-open}" "$NV/lts" >"$RUN/resolved"
  for d in bin lib64 share; do
    [ -d "$NV/lts/usr/$d" ] || continue
    # Clear the LTS tree's own paths first: an interrupted earlier attempt can leave entries there that
    # cp can't overwrite (a symlink loop was seen after a hard reset).
    (cd "$NV/lts/usr/$d" && find . ! -type d -print0) | (cd "/usr/$d" && xargs -0 -r rm -f --)
    err=$(cp -a --reflink=auto "$NV/lts/usr/$d/." "/usr/$d/" 2>&1) || { log "fallback: copying the LTS tree into /usr/$d failed: $(head -c 300 <<<"$err")"; exit 1; }
  done
  /sbin/ldconfig || true
  rm -f "$COMMITTED"; sync
  log "fallback: /opt/nvidia/current -> $NV/lts; re-running setup once"
  exec "$0"
}

mkdir -p "$RUN" "$STATE"
# nvidia-override-apply re-pointed /opt/nvidia/current and requested a reboot; the overlays still hold the
# previous tree, so committing now would commit the wrong one.
if [ -e "$RUN/override-reboot-pending" ]; then log "reboot pending to apply the driver-branch override; skipping"; exit 0; fi
[ -L "$CUR" ] && [ -d "$CUR" ] || die "$CUR is not a resolved tree (did nvidia-driver-resolve run?)"
FLAVOR=$(cat "$CUR/.driver-flavor" 2>/dev/null || echo open)
FLAVOR_SUBTREE="$CUR/flavors/$FLAVOR"
[ -d "$FLAVOR_SUBTREE" ] || die "flavor subtree $FLAVOR_SUBTREE missing"
REGISTERED="$STATE/.packages-registered"
LEAN=0; [ -e /etc/ecs/nvidia-driver-select/optionc-lean ] && LEAN=1
# ---------- versionlock (written with the registration) ----------
# The version-specific packages are registered, not installed, so nothing pins them: without a lock a
# customer's `dnf update` replaces them (measured: nvidia-fabricmanager 595 -> nvidia-fabric-manager 570).
# Lock every registered NEVRA, plus the packages that aren't installed but must follow the committed branch.
# Lines for any tree's package names are dropped first, so a fallback or type change re-points the lock.
LOCK=/etc/dnf/plugins/versionlock.list
LOCK_EXTRA=(nvidia-imex libnvidia-nscq)
write_lock() {
  local re tmp n
  re=$(rpm -qp --qf '%{NAME}\n' "$NV"/{lts,pb}/.rpms/*.rpm "$NV"/{lts,pb}/flavors/*/.rpms/*.rpm 2>/dev/null |
    sort -u | paste -sd'|' -)
  re="${re:+$re|}$(IFS='|'; echo "${LOCK_EXTRA[*]}")"
  tmp=$(mktemp "$LOCK.XXXXXX") || { log "WARNING: versionlock not written (mktemp failed)"; return 0; }
  {
    { grep -vE "^(${re})-[0-9]+:" "$LOCK" 2>/dev/null || true; } | grep -v '^# nvidia-setup' || true
    echo "# nvidia-setup: $(basename "$(readlink "$CUR")") $loaded"
    rpm -qp --qf '%{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.*\n' "${RPMS[@]}" 2>/dev/null
    for n in "${LOCK_EXTRA[@]}"; do echo "$n-0:$loaded-*"; done
  } >"$tmp"
  chmod 644 "$tmp"; mv -f "$tmp" "$LOCK"
  log "versionlock written: ${#RPMS[@]} registered packages + ${LOCK_EXTRA[*]} at $loaded"
}

# ---------- rpmdb registration via --justdb ----------
# failure mode 3: guarded by .justdb-in-progress so a power loss mid-registration self-heals.
register_packages() {
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
      write_lock || log "WARNING: versionlock not written"
    else
      # justdb touches only the database, never files -- the committed userspace is intact. Fail loudly
      # so the state is visible, but the GPU is already usable (modules loaded, libs overlaid).
      rm -f "$JUSTDB_INPROGRESS"
      die "rpm --justdb registration failed; rpmdb left inconsistent (userspace is intact: modules loaded, libs overlaid)"
    fi
  fi
  touch "$REGISTERED"; sync
}

if [ "${1:-}" = --register-only ]; then
  LOADED_OK=1   # the driver is already up; a registration failure must not trigger the LTS fallback
  loaded=$(cat /sys/module/nvidia/version 2>/dev/null || true)
  [ -n "$loaded" ] || { log "register: nvidia isn't loaded yet; nothing to record"; exit 1; }
  [ -e "$REGISTERED" ] && { log "register: already recorded"; exit 0; }
  RPMS=("$CUR"/.rpms/*.rpm "$FLAVOR_SUBTREE"/.rpms/*.rpm)
  register_packages
  log "register: done in $(el) ms"
  exit 0
fi
log "committing tree $(readlink "$CUR") flavor=$FLAVOR kernel=$K"

# ---------- failure mode 1: verify the three overlays are actually mounted ----------
LAYOUT=$(cat /etc/ecs/nvidia-driver-select/optionb-layout 2>/dev/null || echo overlay)
if [ "$LAYOUT" = copy ]; then
  # Option C: nvidia-usr-copy@{bin,lib64,share} copied the tree into /usr and left a sentinel each.
  for d in bin lib64 share; do
    [ -e "$STATE/.usr-$d-copied" ] || die "tree usr/$d not copied into /usr (nvidia-usr-copy@$d failed); refusing to load a half-set-up driver"
  done
  log "tree copied into /usr/{bin,lib64,share}"
else
  for p in /usr/bin /usr/lib64 /usr/share; do
    findmnt -no FSTYPE "$p" 2>/dev/null | grep -qx overlay || die "overlay not mounted at $p (mount unit failed); refusing to load a half-set-up driver"
  done
  log "all three /usr overlays mounted"
fi

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
  # An earlier first-boot attempt that was interrupted (power loss, hard reset), or a commit for another
  # instance type, can leave its modules and module index in place, and udev then autoloads that nvidia module
  # before this unit runs (nvidia-type-change-hold blocks the type-change case). Unload it, so the version
  # loaded below is the one committed now.
  if [ "$LAYOUT" = copy ] && [ -e /sys/module/nvidia ]; then
    log "nvidia $(cat /sys/module/nvidia/version 2>/dev/null) already loaded before commit (interrupted attempt or type change); unloading"
    unload_nvidia || die "cannot unload the nvidia module loaded before this commit"
  fi
  if [ "$LAYOUT" = copy ]; then
    printf '# written by nvidia-setup during a first-boot commit; removed when it completes\ninstall nvidia /bin/false\n' >"$HOLD"
    sync
  fi
  mkdir -p "$EXTRA_DST"
  if [ -d "$FLAVOR_SUBTREE/lib/modules/$K/extra" ]; then
    cp -a --reflink=auto "$FLAVOR_SUBTREE/lib/modules/$K/extra/." "$EXTRA_DST/" \
      || die "copying $FLAVOR modules failed (disk full?)"       # failure mode 4
    log "copied $(ls "$EXTRA_DST" | wc -l) module files for flavor $FLAVOR"
  else
    die "no modules for flavor $FLAVOR at $FLAVOR_SUBTREE/lib/modules/$K/extra"
  fi
  # Version-specific GSP firmware (gsp_*.bin) lives in the shared tree's usr/lib/firmware/nvidia/<ver>,
  # unpacked there by nvidia-kmod-common. On AL2023 /lib -> usr/lib and /usr/lib/firmware is a plain
  # dir, so FW_DST=/lib/firmware writes to /usr/lib/firmware where the kernel loader looks.
  for fwsrc in "$CUR"/usr/lib/firmware "$FLAVOR_SUBTREE"/usr/lib/firmware; do
    [ -d "$fwsrc" ] || continue
    err=$(cp -a --reflink=auto "$fwsrc/." "$FW_DST/" 2>&1) || die "copying firmware from $fwsrc failed: $(head -c 300 <<<"$err")"
  done
  # Fail loudly if the resolved flavor needs GSP firmware but the resolved version's blobs did not land
  # (the exact silent bug: module loads, RmInitAdapter fails "No firmware image found", nvidia-smi shows
  # no devices). All Turing+ GPUs need it; GRID's GSP comes from the same shared tree, so it is covered.
  VER=$(sed -n 's/^version=//p' "$RUN/resolved" 2>/dev/null || true)
  [ -n "$VER" ] || die "cannot read resolved version from $RUN/resolved (did nvidia-driver-resolve run?)"
  case "$FLAVOR" in
    open|proprietary|grid)
      compgen -G "$FW_DST/nvidia/$VER/gsp_*.bin" >/dev/null \
        || die "no GSP firmware for $VER at $FW_DST/nvidia/$VER (flavor=$FLAVOR); GPU init would fail"
      ;;
  esac
  # Option C: use the build-time module index when this instance's module set is exactly the one it was
  # built for (same files, same sizes); otherwise fall back to depmod. Only directory metadata is read.
  IDX="$FLAVOR_SUBTREE/depmod"
  if [ "$LAYOUT" = copy ] && [ -s "$IDX/manifest" ] && \
     [ "$(cd "$LIB_MODULES" && find . -name '*.ko*' -printf '%P %s\n' | LC_ALL=C sort | sha256sum | cut -d' ' -f1)" = "$(cat "$IDX/manifest")" ]; then
    cp -a "$IDX"/modules.* "$LIB_MODULES/" || die "copying the prebuilt module index failed (disk full?)"
    log "prebuilt module index copied (depmod skipped)"
  else
    depmod "$K" || die "depmod failed"
    log "depmod done"
  fi
fi

# ---------- module load (every boot) ----------
# failure mode 2: a .ko that does not match the running kernel will fail here; no DKMS to rebuild.
load_mod() { modprobe "$1" 2>&1 | sed "s/^/  modprobe $1| /" || return 1; }
modprobe --ignore-install nvidia || die "modprobe nvidia failed (kernel mismatch? Option B has no DKMS source to rebuild)"
for ko in "$EXTRA_DST"/*.ko*; do
  m=$(basename "$ko"); m="${m%%.ko*}"
  case "$m" in nvidia | nvidia-peermem) continue ;; esac   # nvidia loaded above; peermem optional (needs IB)
  modprobe --ignore-install "$m" 2>/dev/null || log "note: modprobe $m skipped/failed (optional on this hardware)"
done
/usr/bin/nvidia-modprobe -c 0 -u 2>/dev/null || true
loaded=$(cat /sys/module/nvidia/version 2>/dev/null || true)
[ -n "$loaded" ] || die "nvidia module not loaded after modprobe"
want=$(sed -n 's/^version=//p' "$RUN/resolved" 2>/dev/null || true)
if [ "$LAYOUT" = copy ] && [ -n "$want" ] && [ "$loaded" != "$want" ]; then
  die "loaded nvidia $loaded but the committed tree is $want (kernel/user-space mismatch)"
fi
LOADED_OK=1
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
  # One unit per call: a single call fails as a whole when any one unit can't be enabled, which left every
  # daemon disabled, so they ran on first boot only (measured: nvidia-gridd inactive after a reboot).
  for u in "${DAEMONS[@]}"; do
    err=$(systemctl enable "$u" 2>&1) || log "note: enabling $u failed: $(head -c 200 <<<"$err")"
    systemctl start --no-block "$u" 2>/dev/null || log "note: $u did not start (expected on hw without NVSwitch/vGPU)"
  done
  # After a type change off a GRID host, the license daemon an earlier commit enabled must not keep starting.
  [ "$FLAVOR" = grid ] || systemctl disable nvidia-gridd.service 2>/dev/null || true
  log "enabled+started daemon subset: $(for u in "${DAEMONS[@]}"; do printf '%s=%s ' "${u%.service}" "$(systemctl is-enabled "$u" 2>/dev/null)"; done)"
fi


# Lean build: the package records are written by nvidia-package-register after the driver is up, off the path
# to nvidia-smi and ECS (rpm --justdb took 11-13 s on a fresh instance). The default build writes them here.
if [ "$LEAN" = 1 ]; then
  [ -e "$REGISTERED" ] || { systemctl start --no-block nvidia-package-register.service; log "package records: handed to nvidia-package-register"; }
elif [ ! -e "$COMMITTED" ]; then
  register_packages
fi

touch "$COMMITTED"; rm -f "$HOLD"; sync
echo "$(date -u +%FT%TZ) committed $(readlink "$CUR") flavor=$FLAVOR nvidia=$loaded" >>"$STATE/history"
log "done (committed $FLAVOR $loaded) in $(el) ms"
