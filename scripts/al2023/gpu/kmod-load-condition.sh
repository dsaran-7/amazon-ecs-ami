#!/bin/sh
# ExecCondition for LTS-only units (POC M4): nvidia-kmod-load.service (today's archive loader, kmod-util load)
# and the untracked 580 GRID runfile daemons nvidia-gridd/nvidia-topologyd. On PB the prebuilt kmod RPM owns
# the modules; loading the 580 archive there would put a 580 .ko under 595 userspace, and the 580 gridd binary
# fails against a 595 RM ("Failed to initialise RM client", measured).
if grep -qx 'branch=pb' /run/nvidia-driver-select/selected 2>/dev/null; then
  echo "nvidia-driver-select chose PB; skipping LTS-only unit"
  exit 1
fi
exit 0
