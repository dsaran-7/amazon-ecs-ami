#!/bin/bash
# Re-install only the boot-time pieces from /tmp/m4proto (after a prototype fix).
set -e; P=/tmp/m4proto
install -D -m755 "$P/nvidia-driver-select.sh" /usr/libexec/nvidia-driver-select/nvidia-driver-select
install -D -m755 "$P/kmod-load-condition.sh" /usr/libexec/nvidia-driver-select/kmod-load-condition
install -D -m644 "$P/nvidia-driver-select.service" /etc/systemd/system/nvidia-driver-select.service
install -D -m644 "$P/10-nvidia-driver-select.conf" /etc/systemd/system/nvidia-kmod-load.service.d/10-nvidia-driver-select.conf
for u in nvidia-gridd nvidia-topologyd; do install -D -m644 "$P/10-nvidia-driver-select-ltsonly.conf" /etc/systemd/system/$u.service.d/10-nvidia-driver-select.conf; done
install -D -m755 "$P/poc-gpu-ready.sh" /usr/local/bin/poc-gpu-ready
install -D -m644 "$P/poc-gpu-ready.service" /etc/systemd/system/poc-gpu-ready.service
systemctl daemon-reload; echo installed; md5sum /usr/libexec/nvidia-driver-select/nvidia-driver-select
