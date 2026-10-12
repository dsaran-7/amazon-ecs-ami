#!/usr/bin/env bash
# nvidia-type-change-hold (Option C) — runs before udev coldplug on every boot.
#
# A stop/start onto another instance type can change the driver tree or flavor. The previous commit's modules
# and module index are still in /lib/modules, so udev would autoload them at coldplug, before
# nvidia-driver-resolve can clean them out, and nvidia-setup then can't unload them (measured on g6f.large ->
# g6.xlarge: the GRID module stayed loaded and the open flavor was never committed). When the instance type
# differs from the one recorded at the last resolve, write nvidia-setup's commit hold so that only nvidia-setup
# loads nvidia this boot; nvidia-setup removes the hold when it finishes. Reads local files only (DMI, /var).
set -u
STATE=/var/lib/nvidia-optionb
HOLD=/etc/modprobe.d/nvidia-optionc-commit-hold.conf

now=$(tr -d '[:space:]' </sys/devices/virtual/dmi/id/product_name 2>/dev/null || true)
was=$(cat "$STATE/.resolved-itype" 2>/dev/null || true)
[ -n "$now" ] && [ -n "$was" ] && [ "$now" != "$was" ] || exit 0
printf '# written by nvidia-type-change-hold after an instance-type change; removed by nvidia-setup\ninstall nvidia /bin/false\n' >"$HOLD"
sync
echo "type-change-hold: instance type changed ($was -> $now); holding nvidia autoload until nvidia-setup commits"
