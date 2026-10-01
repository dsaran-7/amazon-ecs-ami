#!/bin/bash
# POC measurement: poll nvidia-smi until it works (max 300 s); log uptime + driver version.
start=$(cut -d' ' -f1 /proc/uptime); first=""
for i in $(seq 1 600); do
  if out=$(nvidia-smi --query-gpu=driver_version,name --format=csv,noheader 2>&1); then
    echo "$(date -u +%FT%TZ) boot=$(cat /proc/sys/kernel/random/boot_id) GPU-READY uptime=$(cut -d' ' -f1 /proc/uptime) probe_start=$start polls=$i first_err='${first}' -> $out" | tee -a /var/log/poc-gpu-ready.log
    exit 0
  fi
  [ -z "$first" ] && first=$(echo "$out" | head -1)
  sleep 0.5
done
echo "$(date -u +%FT%TZ) GPU-NOT-READY after 300s: $first" | tee -a /var/log/poc-gpu-ready.log; exit 1
