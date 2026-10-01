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
#    lts-fallback.devices lists devices LTS drives in measured tests although NVIDIA does not list them
#    (today 2c3a/G7): an 'lts' override is accepted there with an "unqualified" warning, and a failed PB
#    swap or load falls back to LTS instead of leaving the GPU without a driver.
#  * Swap: one dnf transaction, local repos only, inside 'unshare --net' (proves no network is needed),
#    gpgcheck=1 for the AL/NVIDIA-signed RPMs; the locally built kmod RPM (local/) is sha256-verified.
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
[ -n "${LTS_VERSION:-}" ] && [ -n "${PB_VERSION:-}" ] && [ -n "${GPGKEYS:-}" ] || die "branches file incomplete"

# ---------- 1. hardware identity ----------
# vGPU (GRID) guests: same device ID as the bare-metal GPU (L4 27b8), told apart by subsystem device ID.
# Mirrors NVIDIA_GRID_SUBDEVICES in nvidia-kmod-load.sh. The PB set has no GRID flavor, so these stay on LTS.
GRID_SUBDEVICES=(27b8:1733 27b8:1735 27b8:1737)
devs=()
subs=()
for d in /sys/bus/pci/devices/*; do
  [ "$(<"$d/vendor")" = 0x10de ] || continue
  case "$(<"$d/class")" in 0x0300* | 0x0302*) ;; *) continue ;; esac
  id=$(<"$d/device")
  devs+=("${id#0x}")
  subs+=("${id#0x}:$(sed 's/^0x//' "$d/subsystem_device")")
done
# Test hook (never set by the unit): pretend these device IDs are attached, to exercise selection off-GPU.
# Entries are <device> or <device>:<subsystem device>.
if [ -n "${NVSEL_TEST_DEVICES:-}" ]; then
  read -ra subs <<<"$NVSEL_TEST_DEVICES"
  devs=("${subs[@]%%:*}")
  log "TEST: devices forced to ${subs[*]}"
fi
if [ ${#devs[@]} -eq 0 ]; then
  log "no NVIDIA display/3D controller; nothing to do"
  printf 'branch=none\n' >"$RUN/selected"
  exit 0
fi

listed() { grep -qiE "^$1([[:space:]]|#|$)" "$2" 2>/dev/null; }
has_grid() { local s g; for s in "${subs[@]}"; do for g in "${GRID_SUBDEVICES[@]}"; do [ "$s" != "$g" ] || return 0; done; done; return 1; }
all_supported() {
  local id
  [ "$1" = lts ] || ! has_grid || return 1
  for id in "${devs[@]}"; do listed "$id" "$CONF/$1-supported.devices" || return 1; done
}
# LTS can drive every device, counting reviewed measured-but-unqualified devices (lts-fallback.devices).
lts_drivable() {
  local id
  for id in "${devs[@]}"; do
    listed "$id" "$CONF/lts-supported.devices" || listed "$id" "$CONF/lts-fallback.devices" || return 1
  done
}
unqualified_lts() { ! all_supported lts; }

branch=lts
reason="default (LTS-first)"
for id in "${devs[@]}"; do
  if listed "$id" "$CONF/pb-required.devices"; then branch=pb; reason="device $id in pb-required.devices"; fi
done
req=auto
[ -r "$OVERRIDE" ] && req=$(sed -n 's/^NVIDIA_DRIVER_BRANCH=//p' "$OVERRIDE" | tail -1)
case "$req" in
  pb)
    if all_supported pb; then branch=pb; reason="override NVIDIA_DRIVER_BRANCH=pb"
    else log "WARNING: override NVIDIA_DRIVER_BRANCH=pb rejected (devices ${subs[*]}: not all in pb-supported.devices, or a vGPU/GRID guest); keeping $branch"; fi ;;
  lts)
    if all_supported lts; then branch=lts; reason="override NVIDIA_DRIVER_BRANCH=lts"
    elif lts_drivable; then
      branch=lts; reason="override NVIDIA_DRIVER_BRANCH=lts"
      log "WARNING: UNQUALIFIED configuration: override lts accepted for devices ${devs[*]} via lts-fallback.devices (NVIDIA does not list them for $LTS_VERSION)"
    else log "WARNING: override NVIDIA_DRIVER_BRANCH=lts rejected (devices ${devs[*]} not all in lts-supported/lts-fallback.devices); keeping $branch"; fi ;;
  auto | "") ;;
  *) log "WARNING: ignoring invalid NVIDIA_DRIVER_BRANCH=$req" ;;
esac
select_branch() {
  branch=$1
  if [ "$branch" = pb ]; then V=$PB_VERSION; else V=$LTS_VERSION; fi
  printf 'branch=%s\nversion=%s\ndevices=%s\n' "$branch" "$V" "${devs[*]}" >"$RUN/selected"
}
select_branch "$branch"
installed=$(rpm -q --qf '%{VERSION}\n' nvidia-driver 2>/dev/null | sort -u | paste -sd,) || installed=none
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
    unload_nvidia || { log "cannot unload nvidia $lv (in use)"; return 1; }
  fi
  [ "$branch" = pb ] || return 0 # LTS: nvidia-kmod-load.service (today's archive loader) loads the flavor
  modprobe nvidia || { log "modprobe nvidia failed"; return 1; }
  modprobe nvidia_uvm || true
  modprobe nvidia_drm || true
  /usr/bin/nvidia-modprobe -c 0 -u 2>/dev/null || true
  lv=$(loaded_version)
  [ "$lv" = "$V" ] || { log "loaded nvidia '$lv' != $V after modprobe"; return 1; }
  log "nvidia $lv loaded ($(modinfo -F filename nvidia))"
}

# ---------- 2. no-op path ----------
# Complete = every NEVRA of the staged manifest is installed, no other version of a version-specific package
# is, and no swap was interrupted (INPROGRESS survives a power loss mid-transaction); falls back to the
# nvidia-driver version if the staged repo was removed.
INPROGRESS=$STATE/swap-in-progress
installed_nevras() {
  { rpm -q --qf '%{NAME} %{NAME}-%{EPOCH}:%{VERSION}-%{RELEASE}.%{ARCH}\n' "${LOCK_NAMES[@]}" 2>/dev/null || true; } |
    grep -v 'is not installed' | sed 's/-(none):/-0:/'
}
set_complete() {
  local m=$STAGE/$1/manifest.install
  [ ! -e "$INPROGRESS" ] || return 1
  if [ -s "$m" ]; then
    rpm -q $(sed -E 's/-[0-9]+:/-/' "$m") >/dev/null 2>&1 && [ -z "$(installed_nevras | cut -d' ' -f2 | grep -vxF -f "$m")" ]
  else [ "$installed" = "$1" ]; fi
}
if set_complete "$V" && ensure_lock && ensure_modules; then
  log "installed branch matches selection; no swap"
  log "done (no-op) in $(el) ms"
  exit 0
fi

# ---------- 3. offline swap ----------
# Read files in 4 MiB chunks, 32 at a time. A volume restored from an EBS snapshot is loaded lazily on first
# read, and deep parallel reads hydrate it far faster than the transaction's sequential reads (measured on a
# fresh c5.2xlarge: whole cold swap 60.7 s -> 27.7 s, prefetch itself 4.6 s for 312 MiB).
prefetch() {
  find "$@" -type f -printf '%s %p\n' | awk '{ for (o = 0; o < $1; o += 4194304) print o / 4194304, substr($0, index($0, " ") + 1) }' |
    xargs -r -P32 -L1 sh -c 'dd if="$1" of=/dev/null bs=4M skip="$0" count=1 status=none' || true
}
run_dnf() { # run_dnf REPO dnf-args...; offline, local repos only
  local repo=$1 rc
  local local_repo=()
  shift
  [ -d "$repo/local/repodata" ] && local_repo=(--repofrompath="nvsel-local,$repo/local" --enablerepo=nvsel-local --setopt=nvsel-local.gpgcheck=0)
  set +e
  HOME="$RUN/home" unshare --net -- dnf -y --noplugins --disablerepo='*' \
    --repofrompath="nvsel,$repo" --enablerepo=nvsel --setopt=nvsel.gpgcheck=1 --setopt=nvsel.gpgkey="$GPGKEYS" \
    "${local_repo[@]}" --setopt=install_weak_deps=False --setopt=cachedir="$RUN/dnfcache" --setopt=keepcache=0 \
    --allowerasing "$@" 2>&1 | tee "$RUN/dnf.log" | sed -u 's/^/  dnf| /'
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}
# An interrupted transaction leaves old and new NEVRAs of one name registered side by side, and files of
# either version on disk. Drop the non-target duplicates from the rpmdb, delete their files that no package
# owns any more, and reinstall the target NEVRAs that are registered (their files may have been overwritten).
recover_interrupted() {
  local repo=$1 dups f reinst
  log "recovering from an interrupted swap ($(cat "$INPROGRESS" 2>/dev/null))"
  dups=$(installed_nevras | awk '{n[NR]=$1; e[NR]=$2; c[$1]++} END {for (i = 1; i <= NR; i++) if (c[n[i]] > 1) print e[i]}' |
    grep -vxF -f "$repo/manifest.install" | sed -E 's/-[0-9]+:/-/' || true)
  if [ -n "$dups" ]; then
    log "dropping duplicate rpmdb entries: $(echo $dups)"
    rpm -ql $dups 2>/dev/null | sort -u >"$RUN/dup-files"
    rpm -e --justdb --nodeps --noscripts --notriggers $dups || return 1
    while IFS= read -r f; do
      if [ -f "$f" ] || [ -L "$f" ]; then rpm -qf "$f" >/dev/null 2>&1 || rm -f "$f"; fi
    done <"$RUN/dup-files"
  fi
  reinst=$(installed_nevras | cut -d' ' -f2 | grep -xF -f "$repo/manifest.install" | sed -E 's/-[0-9]+:/-/' || true)
  [ -z "$reinst" ] || run_dnf "$repo" reinstall $reinst || return 1
}
# swap_to VERSION: switch the rpm set to the staged VERSION. Returns non-zero (never exits) so the caller
# can fall back.
swap_to() {
  local v=$1 repo=$STAGE/$1 rc t now
  [ -s "$repo/manifest.install" ] && [ -d "$repo/repodata" ] || { log "staged repo $repo missing"; return 1; }
  if [ -d "$repo/local" ]; then
    (cd "$repo/local" && sha256sum --quiet --strict -c SHA256SUMS) || { log "sha256 check of $repo/local failed"; return 1; }
  fi
  t=$(el); prefetch "$repo" /var/lib/rpm; log "prefetched staged repo + rpmdb in $(( $(el) - t )) ms"
  if [ -e "$INPROGRESS" ]; then recover_interrupted "$repo" || { log "recovery failed"; return 1; }; fi
  log "offline dnf transaction -> $v ($(wc -l <"$repo/manifest.install") packages) from $repo"
  echo "$(date -u +%FT%TZ) $installed -> $v" >"$INPROGRESS"; sync
  t=$(el)
  rc=0
  # shellcheck disable=SC2046
  run_dnf "$repo" install $(cat "$repo/manifest.install") || rc=$?
  log "dnf rc=$rc took $(( $(el) - t )) ms"
  # rpm changes nothing before the "Running transaction" step; a failure before it leaves the host clean.
  if [ "$rc" -ne 0 ]; then
    grep -qx 'Running transaction' "$RUN/dnf.log" || rm -f "$INPROGRESS"
    return 1
  fi
  now=$(rpm -q --qf '%{VERSION}\n' nvidia-driver | paste -sd,)
  [ "$now" = "$v" ] || { log "nvidia-driver is $now after transaction, expected $v"; return 1; }
  rm -f "$INPROGRESS"; sync
  purge_dkms_nvidia
  t=$(el); depmod -a "$K"; log "depmod took $(( $(el) - t )) ms"
}

mkdir -p /run/modprobe.d "$RUN/stub" "$RUN/home"
printf 'install %s /bin/false\n' "${NV_MODS[@]}" >"$BLOCK"
trap 'rm -f "$BLOCK"' EXIT
cat >"$RUN/stub/dkms" <<'STUB'
#!/bin/sh
echo "nvidia-driver-select: suppressed RPM-scriptlet call: dkms $*" >&2
exit 0
STUB
chmod 755 "$RUN/stub/dkms"
echo "%_install_script_path $RUN/stub:/sbin:/bin:/usr/sbin:/usr/bin" >"$RUN/home/.rpmmacros"

need_reboot=0
lv=$(loaded_version)
if [ -n "$lv" ] && [ "$lv" != "$V" ]; then
  if unload_nvidia; then log "unloaded stale nvidia $lv (udev coldplug had loaded it)"
  else log "WARNING: stale nvidia $lv busy; will reboot after swap"; need_reboot=1; fi
fi

# PB swap or load failed: fall back to LTS where LTS can drive every device (incl. lts-fallback.devices),
# else fail the unit loudly. On LTS, nvidia-kmod-load.service (no longer skipped) loads the 580 archive.
fall_back() {
  log "ERROR: $1"
  if [ "$branch" = pb ] && lts_drivable; then
    unqualified_lts && log "WARNING: UNQUALIFIED configuration: falling back to LTS $LTS_VERSION on devices ${devs[*]}"
    log "WARNING: falling back to LTS $LTS_VERSION"
    select_branch lts
    unload_nvidia || true
    if set_complete "$V" || swap_to "$V"; then
      rm -f "$BLOCK"
      ensure_lock
      echo "$(date -u +%FT%TZ) $installed -> $V branch=lts devices=${devs[*]} (fallback: $1)" >>"$STATE/history"
      log "done (fallback to LTS $V) in $(el) ms"
      exit 0
    fi
    die "LTS fallback failed too; no usable NVIDIA driver"
  fi
  die "$1; no fallback for devices ${devs[*]}"
}

swap_to "$V" || fall_back "offline swap to $branch/$V failed; system left on $installed"
rm -f "$BLOCK"
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
ensure_modules || fall_back "cannot load nvidia $V"
log "done (swapped $installed -> $V) in $(el) ms"
