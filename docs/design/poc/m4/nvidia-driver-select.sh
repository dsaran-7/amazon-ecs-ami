#!/usr/bin/env bash
# nvidia-driver-select (POC, mechanism M4)
#
# Pick the NVIDIA driver branch for the attached GPUs and, if the natively installed branch differs,
# swap the version-specific RPM set OFFLINE from the local repo baked at AMI build time
# (/opt/ecs/nvidia/<version>/{rpms,repodata,manifest.install}).
#
#  * Selection: NVIDIA display/3D PCI device IDs are read from sysfs (no lspci column parsing).
#    Any device listed in pb-required.devices => PB, else LTS (LTS-first, policy R5).
#    Optional override /etc/ecs/nvidia-driver-select.override: NVIDIA_DRIVER_BRANCH=auto|lts|pb
#    (validated against <branch>-supported.devices generated from each version's supported-gpus.json).
#  * Swap: one dnf transaction, local repo only, inside 'unshare --net' (proves no network is needed),
#    with DKMS calls inside RPM scriptlets suppressed via a PATH stub (%_install_script_path), so no
#    kernel-module compile or dracut can happen at boot. The PB kmod provider is a locally built
#    'kmod-nvidia-open-prebuilt' RPM (Provides nvidia-kmod = 3:<ver>, prebuilt .ko in updates/).
#  * Stale-module guard: modprobe of nvidia* is blocked via /run/modprobe.d during the swap and any
#    already-loaded nvidia module of the wrong version is unloaded.
#  * Afterwards the dnf versionlock is rewritten to the selected NEVRAs (+ nvidia-imex/libnvidia-nscq).
#  * No-op path (installed == selected) only reads sysfs + rpmdb and re-checks the lock.
set -Eeuo pipefail
shopt -s nullglob

CONF=/etc/ecs/nvidia-driver-select
STAGE=/opt/ecs/nvidia
RUN=/run/nvidia-driver-select
STATE=/var/lib/nvidia-driver-select
OVERRIDE=/etc/ecs/nvidia-driver-select.override
LOCK=/etc/dnf/plugins/versionlock.list
BLOCK=/run/modprobe.d/00-nvidia-driver-select-block.conf
K=$(uname -r)
T0=$(date +%s%N)
el() { echo $(( ($(date +%s%N) - T0) / 1000000 )); }
log() { echo "[+$(el)ms] $*"; }
die() { log "ERROR: $*"; exit 1; }

# Version-specific names whose lock lines this script owns (today's lock globs: nvidia* kmod* libnvidia* xorg*).
LOCK_NAMES=(libnvidia-cfg libnvidia-fbc libnvidia-gpucomp libnvidia-ml nvidia-driver nvidia-driver-cuda
  nvidia-driver-cuda-libs nvidia-driver-libs nvidia-fabricmanager nvidia-kmod-common nvidia-libXNVCtrl
  nvidia-modprobe nvidia-persistenced nvidia-settings xorg-x11-nvidia kmod-nvidia-open-dkms
  kmod-nvidia-latest-dkms kmod-nvidia-open-prebuilt)
# Not installed, but must follow the selected branch (Phase 1 hazard: 'dnf install nvidia-imex' pulls 595 on 580).
LOCK_EXTRA=(nvidia-imex libnvidia-nscq)
NV_MODS=(nvidia_peermem nvidia_uvm nvidia_drm nvidia_modeset nvidia)

mkdir -p "$RUN" "$STATE"
[ -r "$CONF/branches" ] || die "$CONF/branches missing"
. "$CONF/branches"
[ -n "${LTS_VERSION:-}" ] && [ -n "${PB_VERSION:-}" ] || die "branches file incomplete"

# ---------- 1. hardware identity ----------
devs=()
for d in /sys/bus/pci/devices/*; do
  [ "$(<"$d/vendor")" = 0x10de ] || continue
  case "$(<"$d/class")" in 0x0300* | 0x0302*) ;; *) continue ;; esac
  id=$(<"$d/device")
  devs+=("${id#0x}")
done
if [ ${#devs[@]} -eq 0 ]; then
  log "no NVIDIA display/3D controller; nothing to do"
  printf 'branch=none\n' >"$RUN/selected"
  exit 0
fi

listed() { grep -qiE "^$1([[:space:]]|#|$)" "$2" 2>/dev/null; }
all_supported() { local id; for id in "${devs[@]}"; do listed "$id" "$CONF/$1-supported.devices" || return 1; done; }

branch=lts
reason="default (LTS-first)"
for id in "${devs[@]}"; do
  if listed "$id" "$CONF/pb-required.devices"; then branch=pb; reason="device $id in pb-required.devices"; fi
done
req=auto
[ -r "$OVERRIDE" ] && req=$(sed -n 's/^NVIDIA_DRIVER_BRANCH=//p' "$OVERRIDE" | tail -1)
case "$req" in
  lts | pb)
    if all_supported "$req"; then branch=$req; reason="override NVIDIA_DRIVER_BRANCH=$req"
    else log "WARNING: override NVIDIA_DRIVER_BRANCH=$req rejected (devices ${devs[*]} not all in $req-supported.devices); keeping $branch"; fi ;;
  auto | "") ;;
  *) log "WARNING: ignoring invalid NVIDIA_DRIVER_BRANCH=$req" ;;
esac
if [ "$branch" = pb ]; then V=$PB_VERSION; else V=$LTS_VERSION; fi
installed=$(rpm -q --qf '%{VERSION}' nvidia-driver 2>/dev/null) || installed=none
printf 'branch=%s\nversion=%s\ndevices=%s\n' "$branch" "$V" "${devs[*]}" >"$RUN/selected"
log "devices=${devs[*]} selected=$branch/$V ($reason) installed=$installed kernel=$K"

# ---------- helpers ----------
loaded_version() { cat /sys/module/nvidia/version 2>/dev/null || true; }
unload_nvidia() {
  local m
  for m in "${NV_MODS[@]}"; do
    if [ -d "/sys/module/$m" ]; then rmmod "$m" || return 1; fi
  done
}
purge_dkms_nvidia() {
  local n=0 p
  for p in /var/lib/dkms/nvidia /var/lib/dkms/nvidia-* /lib/modules/"$K"/extra/nvidia*.ko /lib/modules/"$K"/extra/nvidia*.ko.xz; do
    [ -e "$p" ] || continue
    rm -rf "$p"; n=$((n + 1))
  done
  log "purged $n DKMS nvidia registrations/installed .ko (no dkms/dracut invoked)"
}
ensure_lock() {
  [ -f "$LOCK" ] || return 0
  local re tmp n
  re=$(IFS='|'; echo "${LOCK_NAMES[*]}|${LOCK_EXTRA[*]}")
  tmp=$(mktemp "$LOCK.XXXXXX")
  grep -vE "^(${re})-[0-9]+:" "$LOCK" | grep -v '^# nvidia-driver-select' >"$tmp" || true
  {
    echo "# nvidia-driver-select: branch=$branch version=$V"
    # rpm -q exits with the number of names not installed; not an error here
    { rpm -q --qf '%{NAME}-%{EPOCH}:%{VERSION}-%{RELEASE}.*\n' "${LOCK_NAMES[@]}" 2>/dev/null || true; } |
      grep -v 'is not installed' | sed 's/-(none):/-0:/'
    for n in "${LOCK_EXTRA[@]}"; do echo "$n-0:$V-*"; done
  } >>"$tmp"
  if cmp -s "$tmp" "$LOCK"; then rm -f "$tmp"; log "versionlock already matches $branch/$V"
  else chmod 644 "$tmp"; mv -f "$tmp" "$LOCK"; log "versionlock rewritten for $branch/$V"; fi
}
ensure_modules() {
  local lv
  lv=$(loaded_version)
  if [ -n "$lv" ] && [ "$lv" != "$V" ]; then
    log "loaded nvidia $lv != $V; unloading"
    unload_nvidia || die "cannot unload nvidia $lv (in use)"
  fi
  [ "$branch" = pb ] || return 0 # LTS: nvidia-kmod-load.service (today's archive loader) loads the flavor
  modprobe nvidia
  modprobe nvidia_uvm || true
  modprobe nvidia_drm || true
  /usr/bin/nvidia-modprobe -c 0 -u 2>/dev/null || true
  lv=$(loaded_version)
  [ "$lv" = "$V" ] || die "loaded nvidia '$lv' != $V after modprobe"
  log "nvidia $lv loaded ($(modinfo -F filename nvidia))"
}

# ---------- 2. no-op path ----------
# Complete = every NEVRA of the staged manifest is installed (catches a transaction interrupted mid-way);
# falls back to the nvidia-driver version if the staged repo was removed.
set_complete() {
  local m=$STAGE/$1/manifest.install
  if [ -s "$m" ]; then rpm -q $(sed -E 's/-[0-9]+:/-/' "$m") >/dev/null 2>&1
  else [ "$installed" = "$1" ]; fi
}
if set_complete "$V"; then
  log "installed branch matches selection; no swap"
  ensure_lock
  ensure_modules
  log "done (no-op) in $(el) ms"
  exit 0
fi

# ---------- 3. offline swap ----------
REPO=$STAGE/$V
[ -s "$REPO/manifest.install" ] && [ -d "$REPO/repodata" ] || die "staged repo $REPO missing; cannot select $branch/$V"
mkdir -p /run/modprobe.d "$RUN/stub" "$RUN/home"
printf 'install %s /bin/false\n' "${NV_MODS[@]}" >"$BLOCK"
trap 'rm -f "$BLOCK"' EXIT
need_reboot=0
lv=$(loaded_version)
if [ -n "$lv" ] && [ "$lv" != "$V" ]; then
  if unload_nvidia; then log "unloaded stale nvidia $lv (udev coldplug had loaded it)"
  else log "WARNING: stale nvidia $lv busy; will reboot after swap"; need_reboot=1; fi
fi
purge_dkms_nvidia
cat >"$RUN/stub/dkms" <<'STUB'
#!/bin/sh
echo "nvidia-driver-select: suppressed RPM-scriptlet call: dkms $*" >&2
exit 0
STUB
chmod 755 "$RUN/stub/dkms"
echo "%_install_script_path $RUN/stub:/sbin:/bin:/usr/sbin:/usr/bin" >"$RUN/home/.rpmmacros"

log "offline dnf transaction -> $V ($(wc -l <"$REPO/manifest.install") packages) from $REPO"
t=$(el)
set +e
# shellcheck disable=SC2046
HOME="$RUN/home" unshare --net -- dnf -y --noplugins --disablerepo='*' \
  --repofrompath="nvsel,$REPO" --enablerepo=nvsel --setopt=nvsel.gpgcheck=0 \
  --setopt=install_weak_deps=False --setopt=cachedir="$RUN/dnfcache" --setopt=keepcache=0 \
  --allowerasing install $(cat "$REPO/manifest.install") 2>&1 | sed -u 's/^/  dnf| /'
rc=${PIPESTATUS[0]}
set -e
log "dnf rc=$rc took $(( $(el) - t )) ms"
[ "$rc" -eq 0 ] || die "offline transaction failed (rc=$rc); system left on $installed"
now=$(rpm -q --qf '%{VERSION}' nvidia-driver)
[ "$now" = "$V" ] || die "nvidia-driver is $now after transaction, expected $V"
rm -f "$BLOCK"
t=$(el); depmod -a "$K"; log "depmod took $(( $(el) - t )) ms"
ensure_lock
echo "$(date -u +%FT%TZ) $installed -> $V branch=$branch devices=${devs[*]}" >>"$STATE/history"
if [ "$need_reboot" = 1 ]; then
  if [ ! -e "$STATE/rebooted-for-$V" ]; then
    touch "$STATE/rebooted-for-$V"; log "rebooting once to drop the busy stale module"
    systemctl reboot --no-block; exit 0
  fi
  die "stale module still busy after one reboot"
fi
rm -f "$STATE"/rebooted-for-*
ensure_modules
log "done (swapped $installed -> $V) in $(el) ms"
