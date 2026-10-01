#!/usr/bin/env bash
# nvidia-m3-activate (POC, mechanism M3): select one NVIDIA driver version tree /opt/nvidia/<ver>
# via /opt/nvidia/current + /etc/ld.so.conf.d + a manifest-driven symlink farm. No overlays.
# usage: nvidia-m3-activate [auto|<version>] [--no-load]
set -Eeuo pipefail
ROOT=/opt/nvidia; STATE=/var/lib/nvidia-m3; K=$(uname -r)
ms() { echo $(( $(date +%s%N)/1000000 )); }
T0=$(ms); phase() { echo "PHASE $1 +$(( $(ms)-T0 ))ms"; }
mkdir -p $STATE /etc/nvidia-m3
NOLOAD=0; [ "${2:-}" = "--no-load" ] && NOLOAD=1

select_version() {
  if [ -n "${1:-}" ] && [ "$1" != auto ]; then echo "$1"; return; fi
  if [ -s /etc/nvidia-m3/override ]; then cat /etc/nvidia-m3/override; return; fi
  # POC policy: PB (595) only for devices no LTS (580) release supports (G7 = 10de:2c3a); else LTS.
  if lspci -n -d 10de: | awk '{print $3}' | grep -qix '10de:2c3a'; then echo 595.91.07; else echo 580.178.04; fi
}
gpu_users() { # pids (other than driver daemons) holding a /dev/nvidia* node
  local f l p pid c
  for f in /proc/[0-9]*/fd/*; do
    l=$(readlink "$f" 2>/dev/null) || continue
    [[ "$l" == /dev/nvidia* ]] || continue
    p=${f#/proc/}; pid=${p%%/*}; c=$(cat /proc/$pid/comm 2>/dev/null || true)
    [[ "$c" == nvidia-persiste* || "$c" == nvidia-cuda-mps* || "$c" == nv-hostengine ]] && continue
    echo "$pid:$c"
  done | sort -u | tr '\n' ' '
}
SEL=$(select_version "${1:-auto}")
[ -d "$ROOT/$SEL" ] || { echo "ERROR no tree $ROOT/$SEL"; exit 1; }
OLD=$(basename "$(readlink $ROOT/current 2>/dev/null)" 2>/dev/null || true)
LOADED=$(cat /sys/module/nvidia/version 2>/dev/null || true)
echo "select=$SEL current=${OLD:-none} loaded=${LOADED:-none} kernel=$K"
phase start

# 1. unload a module that does not match the selection (udev coldplug may have loaded the previous tree's .ko)
RESTART=""
if [ -n "$LOADED" ] && [ "$LOADED" != "$SEL" ]; then
  # preflight: refuse (before stopping anything) if a non-daemon process holds a GPU device node
  USERS=$(gpu_users)
  if [ -n "$USERS" ]; then echo "ERROR GPU in use by: $USERS- drain tasks first; nothing changed"; exit 5; fi
  for u in nvidia-persistenced nvidia-mps nvidia-fabricmanager set-nvidia-clocks nvidia-powerd; do
    systemctl is-active -q $u && RESTART+=" $u"
  done
  [ -n "$RESTART" ] && systemctl stop $RESTART
  for m in nvidia_peermem nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
    [ -d /sys/module/$m ] && { rmmod $m || { echo "ERROR rmmod $m failed (holders: $(ls /sys/module/$m/holders 2>/dev/null | tr '\n' ' '), refcnt $(cat /sys/module/$m/refcnt 2>/dev/null))"; exit 2; }; }
  done
  echo "unloaded $LOADED (stopped:${RESTART:- none})"
  phase unloaded
fi

# 2. flip /opt/nvidia/current atomically
if [ "$OLD" != "$SEL" ]; then ln -sfn "$ROOT/$SEL" "$ROOT/.current.tmp" && mv -T "$ROOT/.current.tmp" "$ROOT/current"; fi
phase flipped

# 3. symlink farm: every tree path except top-level /usr/lib64 (served by ld.so.conf.d) and docs,
#    plus the absolute-path consumers of top-level /usr/lib64 (Vulkan / VulkanSC ICD library_path).
ABS_LIB64=" /usr/lib64/libGLX_nvidia.so.0 /usr/lib64/libnvidia-vksc-core.so.1 "
grep -vE '^/usr/share/(doc|man|licenses)/|^/usr/lib/\.build-id/' "$ROOT/$SEL.files" | \
  awk -v ex="$ABS_LIB64" '/^\/usr\/lib64\/[^\/]+$/ { if (index(ex, " " $0 " ")) print; next } { print }' > $STATE/links.new
removed=0
if [ -f $STATE/links.active ]; then
  while read -r p; do [ -L "$p" ] && { rm -f "$p"; removed=$((removed+1)); }; done < <(comm -23 <(sort $STATE/links.active) <(sort $STATE/links.new))
fi
n=0; displaced=0
while read -r p; do
  tgt="$ROOT/current$p"
  [ -L "$p" ] && [ "$(readlink "$p")" = "$tgt" ] && continue
  if [ -e "$p" ] && [ ! -L "$p" ]; then
    mkdir -p "$STATE/displaced$(dirname "$p")"; mv "$p" "$STATE/displaced$p"; displaced=$((displaced+1)); echo "DISPLACED $p"
  fi
  mkdir -p "$(dirname "$p")"; ln -sfn "$tgt" "$p"; n=$((n+1))
done < $STATE/links.new
mv $STATE/links.new $STATE/links.active
echo "links: total=$(wc -l < $STATE/links.active) created=$n removed=$removed displaced=$displaced"
phase linked

# 4. kernel modules: one directory symlink; module names are identical across versions
[ -d "$ROOT/$SEL/lib/modules/$K/extra" ] || { echo "ERROR no kmod for kernel $K in $SEL"; exit 3; }
if [ "$(readlink /lib/modules/$K/extra/nvidia 2>/dev/null)" != "$ROOT/current/lib/modules/$K/extra" ]; then
  mkdir -p /lib/modules/$K/extra; ln -sfn "$ROOT/current/lib/modules/$K/extra" /lib/modules/$K/extra/nvidia
fi
depmod -a "$K"
phase depmod

# 5. dynamic linker cache
echo "$ROOT/current/usr/lib64" > /etc/ld.so.conf.d/nvidia-m3.conf
ldconfig
phase ldconfig

# 6. load the selected module
if [ $NOLOAD = 0 ]; then
  modprobe nvidia
  modprobe nvidia-uvm; modprobe nvidia-drm
  phase modprobe
  L2=$(cat /sys/module/nvidia/version)
  [ "$L2" = "$SEL" ] || { echo "ERROR loaded $L2 != selected $SEL"; exit 4; }
fi
systemctl daemon-reload
for u in $RESTART; do systemctl start --no-block $u; done
echo "$SEL" > $STATE/active
phase done
echo "ACTIVATED $SEL total=$(( $(ms)-T0 ))ms"
