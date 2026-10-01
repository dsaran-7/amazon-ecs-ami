#!/usr/bin/env bash
# stage-nvidia-pb.sh — AL2023 ECS GPU AMI build step for dynamic NVIDIA driver *version* selection.
#
# Runs AFTER install-nvidia-driver.sh has natively installed the LTS branch (all three flavors).
# On top of that native LTS install it stages, for boot-time selection by nvidia-driver-select.service:
#   1. the PB version-specific RPM closure (open flavor only) under /opt/ecs/nvidia/<PB>/
#   2. a locally built kmod-nvidia-open-prebuilt RPM (Provides nvidia-kmod = 3:<PB>, prebuilt .ko, no DKMS)
#   3. the LTS version-specific set under /opt/ecs/nvidia/<LTS>/ (for the reverse swap)
#   4. createrepo_c metadata + a manifest.install per version; signed RPMs are checked with rpm -K
#      (the boot swap keeps gpgcheck=1), the locally built kmod RPM gets a SHA256SUMS under local/
#   5. reviewed device lists derived from each version's supported-gpus.json (validates pb-required.devices)
#   6. the nvidia-driver-select boot unit + nvidia-kmod-load/gridd/topologyd ExecCondition drop-ins, enabled
#
# Only runs for al2023*gpu. No-op otherwise. Adapted from docs/design/poc/m4/build-m4-stage.sh.
set -Eeuo pipefail

# Only proceed for AL2023 GPU AMIs (mirrors install-nvidia-driver.sh:5-7)
if [[ ${AMI_TYPE:-} != "al2023"*"gpu" ]]; then
    echo "stage-nvidia-pb: AMI_TYPE='${AMI_TYPE:-}' is not an al2023 GPU AMI; skipping"
    exit 0
fi

# LTS version: single source of truth is the NVIDIA_DRIVER_VERSION file, the same file
# install-nvidia-driver.sh reads (uploaded by Packer to /tmp/NVIDIA_DRIVER_VERSION). An explicit
# NVIDIA_DRIVER_LTS_VERSION env var, if set, overrides it (used by tests). This guarantees the
# reverse-swap set staged here matches the natively installed LTS branch and cannot drift.
NVIDIA_DRIVER_VERSION_FILE="${NVIDIA_DRIVER_VERSION_FILE:-/tmp/NVIDIA_DRIVER_VERSION}"
LTS="${NVIDIA_DRIVER_LTS_VERSION:-}"
if [[ -z "$LTS" ]]; then
    LTS=$(grep "^nvidia_driver_version_al2023" "$NVIDIA_DRIVER_VERSION_FILE" | awk -F'"' '{print $2}')
fi
if [[ -z "$LTS" ]]; then
    echo "ERROR: Could not determine LTS version (NVIDIA_DRIVER_LTS_VERSION unset and nvidia_driver_version_al2023 not in $NVIDIA_DRIVER_VERSION_FILE)" >&2
    exit 1
fi

# PB (Production Branch) full version comes from the Packer environment; it has no other home.
PB="${NVIDIA_DRIVER_PB_VERSION:?NVIDIA_DRIVER_PB_VERSION not set}"

# Prototype/runtime files were uploaded here by the Packer file provisioner.
SRC="${NVIDIA_SELECT_SRC:-/tmp/nvidia-select}"

K=$(uname -r)
ST=/opt/ecs/nvidia          # staged per-version repos live here, baked into the AMI
B=/opt/poc-build            # build scratch (removed at the end)
CONF=/etc/ecs/nvidia-driver-select

# The 15 version-specific runtime packages (egl-wayland vs egl-wayland2 handled separately below).
NAMES=(libnvidia-cfg libnvidia-fbc libnvidia-gpucomp libnvidia-ml nvidia-driver nvidia-driver-cuda
  nvidia-driver-cuda-libs nvidia-driver-libs nvidia-fabricmanager nvidia-kmod-common nvidia-libXNVCtrl
  nvidia-modprobe nvidia-persistenced nvidia-settings xorg-x11-nvidia)

t() { local s rc; s=$(date +%s%N); set +e; "$@"; rc=$?; set -e; echo "TIME $(( ($(date +%s%N) - s) / 1000000 ))ms rc=$rc: $*"; return $rc; }
step() { echo; echo "=== $(date -u +%T) $*"; }
specs() { local n; for n in "${NAMES[@]}"; do echo "$n-$1"; done; }
nevra() { rpm -qp --qf '%{NAME}-%{EPOCH}:%{VERSION}-%{RELEASE}.%{ARCH}\n' "$@" 2>/dev/null | sed 's/-(none):/-0:/'; }

step "0 build tools (build-time only)"
t sudo dnf -y -q install rpm-build createrepo_c

step "1 stage PB $PB closure (open flavor)"
sudo rm -rf "$B/$PB" "$ST/$PB"; sudo mkdir -p "$B/$PB/dl" "$ST/$PB/rpms"
t sudo dnf -y install --downloadonly --disableplugin=versionlock --setopt=install_weak_deps=False \
  --downloaddir="$B/$PB/dl" $(specs "$PB") egl-wayland2
sudo mv "$B/$PB"/dl/kmod-nvidia-*.rpm "$B/$PB/"   # DKMS source pkg: build input only, never staged
sudo cp "$B/$PB"/dl/*.rpm "$ST/$PB/rpms/"

step "2 build $PB open kmods for $K ($(nproc) cpus)"
sudo mkdir -p "$B/$PB/src"
(cd "$B/$PB/src" && sudo bash -c "rpm2cpio '$B/$PB'/kmod-nvidia-open-dkms-$PB-*.rpm | cpio -idm --quiet")
SRC_KMOD=$B/$PB/src/usr/src/nvidia-$PB
# NOTE: pipe the log through `sudo tee`. $B is root-owned (sudo mkdir), so a plain
# ">$B/.../make.log" redirect runs in the non-root provisioner shell and fails with EACCES
# before make even runs. `sudo tee` writes as root; PIPESTATUS[0] carries make's real status.
_s=$(date +%s%N); set +e
sudo make -s -C "$SRC_KMOD" KERNEL_UNAME="$K" SYSSRC=/usr/src/kernels/"$K" \
  IGNORE_PREEMPT_RT_PRESENCE=1 IGNORE_XEN_PRESENCE=1 modules -j"$(nproc)" 2>&1 | sudo tee "$B/$PB/make.log" >/dev/null
_rc=${PIPESTATUS[0]}; set -e
echo "TIME $(( ($(date +%s%N) - _s) / 1000000 ))ms rc=$_rc: make modules $PB"
[ "$_rc" -eq 0 ] || { sudo tail -30 "$B/$PB/make.log"; exit 1; }
sudo mkdir -p "$B/$PB/ko"; sudo find "$SRC_KMOD" -name '*.ko' -exec cp {} "$B/$PB/ko/" \;
sudo strip -g "$B/$PB"/ko/*.ko
sudo modinfo -F version "$B/$PB/ko/nvidia.ko"

step "3 rpmbuild kmod-nvidia-open-prebuilt"
R=$B/rpmbuild; sudo rm -rf "$R"; sudo mkdir -p "$R"/{SOURCES,SPECS,BUILD,RPMS,SRPMS,BUILDROOT}
sudo cp "$B/$PB"/ko/*.ko "$R/SOURCES/"; sudo cp "$SRC/kmod-nvidia-open-prebuilt.spec" "$R/SPECS/"
KREL=$(echo "${K%.x86_64}" | tr - _)
_s=$(date +%s%N); set +e
sudo rpmbuild -bb --define "_topdir $R" --define "kver $K" --define "krel $KREL" --define "nvver $PB" \
  "$R/SPECS/kmod-nvidia-open-prebuilt.spec" 2>&1 | sudo tee "$B/rpmbuild.log" >/dev/null
_rc=${PIPESTATUS[0]}; set -e
echo "TIME $(( ($(date +%s%N) - _s) / 1000000 ))ms rc=$_rc: rpmbuild $PB"
[ "$_rc" -eq 0 ] || { sudo tail -30 "$B/rpmbuild.log"; exit 1; }
# Built here, so not AL/NVIDIA-signed: staged as a separate local repo, verified at boot by sha256.
sudo mkdir -p "$ST/$PB/local/rpms"
sudo cp "$R"/RPMS/x86_64/kmod-nvidia-open-prebuilt-*.rpm "$ST/$PB/local/rpms/"
(cd "$ST/$PB/local" && sudo sha256sum rpms/*.rpm | sudo tee SHA256SUMS)

step "4 stage LTS $LTS set (reverse swap)"
sudo rm -rf "$ST/$LTS"; sudo mkdir -p "$ST/$LTS/rpms"
t sudo dnf -q download --disableplugin=versionlock --repo amazonlinux-nvidia --destdir "$ST/$LTS/rpms" \
  $(specs "$LTS") kmod-nvidia-open-dkms-"$LTS"

step "5 signatures + createrepo + manifests"
# Keys the boot swap trusts (gpgcheck=1): the ones the AL2023 and NVIDIA repos configured on this image use.
GPGKEYS=$(sed -n 's/^gpgkey=//p' /etc/yum.repos.d/amazonlinux.repo /etc/yum.repos.d/amazonlinux-nvidia.repo | tr ' ' '\n' | sort -u | paste -sd' ')
echo "GPGKEYS=$GPGKEYS"
shopt -s nullglob
for v in "$PB" "$LTS"; do
  echo "--- rpm -K $v (every staged AL/NVIDIA RPM must carry a valid signature)"
  sigs=$(rpm -K "$ST/$v"/rpms/*.rpm) || { echo "$sigs"; echo "ERROR: signature check failed in $ST/$v/rpms" >&2; exit 1; }
  echo "$sigs"
  if grep -qv ': digests signatures OK$' <<<"$sigs"; then echo "ERROR: unsigned RPM in $ST/$v/rpms" >&2; exit 1; fi
  # --pkglist keeps the unsigned local/ RPM out of the signed repo (createrepo_c recurses otherwise)
  (cd "$ST/$v" && ls rpms/*.rpm | sudo tee pkglist >/dev/null)
  t sudo createrepo_c -q --pkglist "$ST/$v/pkglist" "$ST/$v"
  sudo rm -f "$ST/$v/pkglist"
  if [ -d "$ST/$v/local" ]; then t sudo createrepo_c -q "$ST/$v/local"; fi
  nevra "$ST/$v"/rpms/*.rpm "$ST/$v"/local/rpms/*.rpm | sort | sudo tee "$ST/$v/manifest.install" >/dev/null
  echo "--- $v manifest ($(wc -l <"$ST/$v/manifest.install"))"
done
shopt -u nullglob
echo "--- validate: staged LTS manifest == baked native install"
rpm -q $(sed -E 's/-[0-9]+:/-/' "$ST/$LTS/manifest.install") >/dev/null && echo "LTS manifest fully installed: OK"

step "6 device lists + validation"
sudo mkdir -p "$CONF" "$B/json"
(cd "$B/json" && sudo bash -c "rpm2cpio '$ST/$PB'/rpms/nvidia-driver-$PB-*.rpm | cpio -idm --quiet ./usr/share/doc/nvidia-driver/supported-gpus.json")
sudo cp "$B/json/usr/share/doc/nvidia-driver/supported-gpus.json" "$B/json/pb.json"
sudo cp /usr/share/doc/nvidia-driver/supported-gpus.json "$B/json/lts.json"
sudo cp "$SRC/pb-required.devices" "$SRC/lts-fallback.devices" "$CONF/"
sudo python3 "$SRC/gen-device-lists.py" "$B/json/lts.json" "$B/json/pb.json" "$CONF"
printf 'LTS_VERSION=%s\nPB_VERSION=%s\nGPGKEYS="%s"\n' "$LTS" "$PB" "$GPGKEYS" | sudo tee "$CONF/branches" >/dev/null

step "7 install boot units"
sudo install -D -m755 "$SRC/nvidia-driver-select.sh" /usr/libexec/nvidia-driver-select/nvidia-driver-select
sudo install -D -m755 "$SRC/kmod-load-condition.sh" /usr/libexec/nvidia-driver-select/kmod-load-condition
sudo install -D -m644 "$SRC/nvidia-driver-select.service" /etc/systemd/system/nvidia-driver-select.service
sudo install -D -m644 "$SRC/10-nvidia-driver-select.conf" /etc/systemd/system/nvidia-kmod-load.service.d/10-nvidia-driver-select.conf
for u in nvidia-gridd nvidia-topologyd; do
  sudo install -D -m644 "$SRC/10-nvidia-driver-select-ltsonly.conf" /etc/systemd/system/$u.service.d/10-nvidia-driver-select.conf
done
sudo systemctl daemon-reload
sudo systemctl enable nvidia-driver-select.service

step "8 sizes + cleanup"
sudo du -sh "$ST"/* || true
sudo rm -rf "$B"
echo "stage-nvidia-pb: done"
