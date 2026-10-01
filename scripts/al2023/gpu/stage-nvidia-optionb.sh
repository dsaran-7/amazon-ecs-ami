#!/usr/bin/env bash
# stage-nvidia-optionb.sh — AL2023 ECS GPU AMI build step for the EKS-parity ("Option B") layout.
#
# This is a REIMPLEMENTATION of the mechanism the EKS design documents
# ("LTS and PB NVIDIA Driver Versions in Single EKS AMI", chorus.aws.dev/doc/oN8qVvlQpSti),
# applied to ECS's recipe and design requirements. It is NOT a copy of EKS's scripts (which are
# not in this repo). Where this script and the EKS doc diverge, the divergence is called out in a
# comment with the ECS reason.
#
# Unlike Option A (install-nvidia-driver.sh + stage-nvidia-pb.sh), Option B does NOT install either
# NVIDIA driver branch natively. Instead it builds, for boot-time selection by nvidia-driver-resolve
# + nvidia-setup, two self-contained per-branch mirror trees under /opt/nvidia/{lts,pb}:
#
#   1. Resolve the full userspace closure of each branch with `dnf install --downloadonly`.
#   2. Partition each closure by NEVRA into SHARED (byte-identical across the two branches) vs
#      VERSION-SPECIFIC. Install the SHARED set NATIVELY with dnf (truthful rpmdb for the base;
#      EKS measured 199 shared / 20 version-specific, none of the 199 an nvidia package).
#   3. Unpack ONLY the version-specific RPMs into the per-branch tree with `rpm2cpio | cpio -idmu`,
#      keeping the .rpm files in <tree>/.rpms/ for the boot side to register with `rpm --justdb`.
#   4. Build the kernel modules once per version x flavor (open+gdrdrv, proprietary via DKMS; GRID
#      via the EC2 vGPU runfile's kernel-open make), and harvest the .ko into
#      <tree>/flavors/<flavor>/lib/modules/<k>/extra/.
#   5. Emulate, at build time, the scriptlet effects of the version-specific packages that matter
#      (persistenced user/group; the daemon presets are done at boot by nvidia-setup).
#   6. Install the Option B boot units (nvidia-driver-resolve, nvidia-setup, the three overlay
#      mount units) and the resolve input (optionb-resolve.map derived from pb-required.devices).
#
# Full fidelity: all three flavors (open, proprietary, GRID) are built per version, matching
# install-nvidia-driver.sh, so the benchmark is not skewed by a reduced build.
#
# Only runs for the al2023gpu-optionb source. No-op otherwise.
set -Eeuo pipefail

# Only proceed for the Option B GPU AMI source.
if [[ ${AMI_TYPE:-} != "al2023gpu-optionb" ]]; then
    echo "stage-nvidia-optionb: AMI_TYPE='${AMI_TYPE:-}' is not al2023gpu-optionb; skipping"
    exit 0
fi

# -------- versions --------
# LTS: the single pin install-nvidia-driver.sh would use, read from the same NVIDIA_DRIVER_VERSION file.
NVIDIA_DRIVER_VERSION_FILE="${NVIDIA_DRIVER_VERSION_FILE:-/tmp/NVIDIA_DRIVER_VERSION}"
LTS="${NVIDIA_DRIVER_LTS_VERSION:-}"
if [[ -z "$LTS" ]]; then
    LTS=$(grep "^nvidia_driver_version_al2023" "$NVIDIA_DRIVER_VERSION_FILE" | awk -F'"' '{print $2}')
fi
[[ -n "$LTS" ]] || { echo "ERROR: could not determine LTS version" >&2; exit 1; }
# PB (Production Branch) full version comes from the Packer environment.
PB="${NVIDIA_DRIVER_PB_VERSION:?NVIDIA_DRIVER_PB_VERSION not set}"

SRC="${NVIDIA_SELECT_SRC:-/tmp/nvidia-select}"
K=$(uname -r)
NV=/opt/nvidia                 # per-branch trees baked into the AMI (EKS: /opt/nvidia)
B=/opt/optionb-build           # build scratch (removed at the end)
CONF=/etc/ecs/nvidia-driver-select

EC2_GRID_DRIVER_S3_BUCKET="ec2-linux-nvidia-drivers"

# Some regions do not have access to the GRID driver S3 bucket; skip GRID there (mirrors Option A).
skip_grid_driver=""
if [[ -n "${SKIP_GRID_DRIVER_REGIONS:-}" ]] && echo "$SKIP_GRID_DRIVER_REGIONS" | grep -q -w "${REGION:-}"; then
    skip_grid_driver="true"
    echo "Region ${REGION} is in skip-grid list; GRID flavor will be omitted"
fi

t() { local s rc; s=$(date +%s%N); set +e; "$@"; rc=$?; set -e; echo "TIME $(( ($(date +%s%N) - s) / 1000000 ))ms rc=$rc: $*"; return $rc; }
step() { echo; echo "=== $(date -u +%T) $*"; }

# -------- 0. build tools + kernel headers (Option B installs nothing nvidia natively) --------
step "0 build prerequisites"
RUNNING_KERNEL=$(uname -r)
t sudo dnf install -y \
    "dnf-command(versionlock)" \
    "dnf-command(download)" \
    "kernel-devel-${RUNNING_KERNEL}" \
    "kernel-headers-${RUNNING_KERNEL}" \
    "kernel-modules-extra-${RUNNING_KERNEL}" \
    "kernel-modules-extra-common-${RUNNING_KERNEL}" \
    dkms rpm-build cpio createrepo_c pciutils
sudo dnf versionlock 'kernel*'

# Parallel DKMS compile (same optimization as install-nvidia-driver.sh), removed before the AMI is sealed.
sudo mkdir -p /etc/dkms
echo "MAKE[0]=\"'make' -j$(nproc --all) modules\"" | sudo tee /etc/dkms/nvidia.conf >/dev/null

# nvidia-release gives us /etc/yum.repos.d/amazonlinux-nvidia.repo (the branch RPMs live there).
t sudo dnf install -y nvidia-release
if [[ -n "${AIR_GAPPED:-}" ]]; then
    sudo sed -i 's/\$dualstack//g' /etc/yum.repos.d/amazonlinux-nvidia.repo
fi

# nvidia-container-toolkit is version-independent (not tied to the driver branch) and is required by the
# ECS GPU agent-support step (enable-ecs-agent-gpu-support-al2023.sh runs `nvidia-ctk`). Option A gets it
# via install-nvidia-driver.sh's native install; Option B installs no driver natively, so install it here.
t sudo dnf install -y nvidia-container-toolkit

# The version-specific userspace package names (EKS's 20, minus the two kmod DKMS source pkgs which are
# build inputs, handled separately). egl-wayland is 595-side only as egl-wayland2; both are downloaded.
# These are the names whose RPMs get UNPACKED into the tree and justdb-registered at boot.
VS_NAMES=(libnvidia-cfg libnvidia-fbc libnvidia-gpucomp libnvidia-ml nvidia-driver nvidia-driver-cuda
    nvidia-driver-cuda-libs nvidia-driver-libs nvidia-fabricmanager nvidia-imex nvidia-kmod-common
    nvidia-libXNVCtrl nvidia-libXNVCtrl-devel nvidia-modprobe nvidia-persistenced nvidia-settings
    nvidia-xconfig xorg-x11-nvidia)
specs() { local n; for n in "${VS_NAMES[@]}"; do echo "$n-$1"; done; }

# -------- download both closures --------
# EKS downloads the FULL closure of the version-specific set for each branch, then splits shared vs
# version-specific by NEVRA. We do the same with `dnf install --downloadonly`.
#
# IMPORTANT: kmod-nvidia-open-dkms and kmod-nvidia-latest-dkms *Conflict* with each other, so they
# cannot both be resolved in one dnf transaction. They are DKMS SOURCE packages (build inputs), not
# part of the registered userspace set, so we download them SEPARATELY with plain `dnf download`
# (which does no conflict resolution) into <dest>/../kmod-<version>/, and keep them out of the
# userspace closure entirely. This mirrors EKS, which downloads each kmod source package on its own.
dl_closure() { # dl_closure VERSION USERSPACE_DEST KMOD_DEST
    local v=$1 dest=$2 kdest=$3
    sudo rm -rf "$dest" "$kdest"; sudo mkdir -p "$dest" "$kdest"
    # dnf5 `install --downloadonly` ignores --downloaddir and only caches packages. The dnf5-correct
    # way to materialize the ADDED closure to a known directory is `dnf download --resolve --destdir`
    # (WITHOUT --alldeps): it downloads each package plus only its NOT-already-installed dependencies.
    # That is exactly EKS's `install --downloadonly` delta -- the nvidia userspace additions (X libs,
    # mesa, etc.) -- NOT the entire base OS. (With --alldeps it would drag in glibc/systemd/kernel and
    # the native shared-install would then try to reinstall the running base, which fails.)
    #
    # We do NOT exclude the kmod sources: nvidia-kmod-common Requires nvidia-kmod, so resolve fails if
    # no kmod provider is allowed. The resolver pulls ONE kmod provider; we delete whatever
    # kmod-nvidia-*-dkms it dropped afterward, because the kmods are build inputs harvested separately
    # (downloaded below into $kdest) and must never be partitioned or unpacked into the tree.
    t sudo dnf -y download --resolve --disableplugin=versionlock \
        --destdir="$dest" \
        $(specs "$v") egl-wayland egl-wayland2
    sudo rm -f "$dest"/kmod-nvidia-*-dkms-*.rpm
    # Plain download (no dependency/conflict resolution) of the two conflicting kmod source rpms.
    t sudo dnf -y download --disableplugin=versionlock --destdir="$kdest" \
        "kmod-nvidia-open-dkms-$v" "kmod-nvidia-latest-dkms-$v"
}
step "1 resolve LTS $LTS closure"
dl_closure "$LTS" "$B/dl/lts" "$B/kmod/lts"
step "1 resolve PB $PB closure"
dl_closure "$PB" "$B/dl/pb" "$B/kmod/pb"

# -------- 2. partition shared vs version-specific --------
# EKS's rule: an RPM present with the SAME filename (NEVRA) in both closures is shared and installed
# natively; anything else is version-specific and unpacked into the tree. We also always treat the
# nvidia kmod DKMS source packages as build-only (never shared, never staged).
step "2 partition shared vs version-specific"
SHARED=$B/shared
sudo rm -rf "$SHARED"; sudo mkdir -p "$SHARED"
# A file is shared iff its exact basename exists in both closures AND it is not a kmod-nvidia-*-dkms
# (those are build inputs) AND it is not an nvidia/libnvidia/xorg-x11-nvidia package (defensive: EKS
# measured none of the 199 shared is an nvidia package, so we enforce it).
is_nvidia_pkg() { case "$1" in nvidia-*|libnvidia-*|xorg-x11-nvidia-*|kmod-nvidia-*|egl-wayland*|nvidia_*) return 0;; *) return 1;; esac; }
shared_count=0
for rpm in "$B/dl/lts"/*.rpm; do
    base=$(basename "$rpm")
    [[ -e "$B/dl/pb/$base" ]] || continue          # not in PB closure -> version-specific
    case "$base" in kmod-nvidia-*-dkms-*) continue;; esac
    if is_nvidia_pkg "$base"; then continue; fi      # defensive guard (should never fire)
    sudo cp "$rpm" "$SHARED/"
    shared_count=$((shared_count + 1))
done
echo "shared RPMs identified: $shared_count"
# Install the shared base natively. The rpmdb is TRUTHFUL for these (EKS: 199 shared, no nvidia pkg).
step "2 install shared base natively (dnf)"
if [[ $shared_count -gt 0 ]]; then
    t sudo dnf -y install --disableplugin=versionlock --setopt=install_weak_deps=False "$SHARED"/*.rpm
fi

# -------- 3. build + harvest kernel modules per version x flavor --------
# EKS modules per dkms.conf for 580/595: nvidia nvidia-uvm nvidia-drm nvidia-modeset nvidia-peermem,
# plus gdrdrv built alongside open. All three flavors are built (full fidelity).
build_open_kmods() { # build_open_kmods VERSION TREE   (open flavor + gdrdrv)
    local v=$1 tree=$2 src ko extra
    extra="$tree/flavors/open/lib/modules/$K/extra"
    sudo mkdir -p "$extra"
    # Unpack the DKMS source rpm at / so dkms finds it (EKS: cpio -idmu into /).
    sudo bash -c "rpm2cpio '$B/kmod/$3'/kmod-nvidia-open-dkms-$v-*.rpm | (cd / && cpio -idmu --quiet)"
    sudo dkms add -m nvidia -v "$v" 2>/dev/null || true
    t sudo dkms build -m nvidia -v "$v" -k "$K"
    src=/var/lib/dkms/nvidia/$v/$K/$(uname -m)/module
    for ko in "$src"/*.ko*; do sudo cp "$ko" "$extra/"; done
    sudo dkms remove -m nvidia -v "$v" --all 2>/dev/null || true
    sudo rm -rf /usr/src/nvidia-"$v"
    sudo strip -g "$extra"/*.ko 2>/dev/null || true
    echo "harvested open kmods for $v -> $extra ($(ls "$extra" | wc -l) files)"
}
build_proprietary_kmods() { # build_proprietary_kmods VERSION TREE CLOSURE
    local v=$1 tree=$2 src ko extra
    extra="$tree/flavors/proprietary/lib/modules/$K/extra"
    sudo mkdir -p "$extra"
    sudo bash -c "rpm2cpio '$B/kmod/$3'/kmod-nvidia-latest-dkms-$v-*.rpm | (cd / && cpio -idmu --quiet)"
    # Rename to nvidia-proprietary to avoid clashing with the open build (mirrors install-nvidia-driver.sh).
    sudo sed -i 's/PACKAGE_NAME="nvidia"/PACKAGE_NAME="nvidia-proprietary"/' /usr/src/nvidia-"$v"/dkms.conf
    sudo mv /usr/src/nvidia-"$v" /usr/src/nvidia-proprietary-"$v"
    sudo dkms add -m nvidia-proprietary -v "$v" 2>/dev/null || true
    t sudo dkms build -m nvidia-proprietary -v "$v" -k "$K"
    src=/var/lib/dkms/nvidia-proprietary/$v/$K/$(uname -m)/module
    for ko in "$src"/*.ko*; do sudo cp "$ko" "$extra/"; done
    sudo dkms remove -m nvidia-proprietary -v "$v" --all 2>/dev/null || true
    sudo rm -rf /usr/src/nvidia-proprietary-"$v"
    sudo strip -g "$extra"/*.ko 2>/dev/null || true
    echo "harvested proprietary kmods for $v -> $extra ($(ls "$extra" | wc -l) files)"
}
build_grid_kmods() { # build_grid_kmods VERSION TREE   (GRID via EC2 vGPU runfile kernel-open make)
    local v=$1 tree=$2 extra tmp extract key runfile
    extra="$tree/flavors/grid/lib/modules/$K/extra"
    sudo mkdir -p "$extra"
    tmp=$(mktemp -d); extract="$tmp/extract"
    # Anchor to grid-*/ prefixes so we match the GRID runfile, not latest/ (release-pipeline note).
    key=$(aws s3 ls --recursive "s3://${EC2_GRID_DRIVER_S3_BUCKET}/" --no-sign-request \
        | grep "grid-.*NVIDIA-Linux-x86_64-${v}-grid" | sort -k1,2 | tail -1 | awk '{print $4}')
    [[ -n "$key" ]] || { echo "ERROR: no GRID runfile for $v in S3" >&2; return 1; }
    runfile=$(basename "$key")
    aws s3 cp "s3://${EC2_GRID_DRIVER_S3_BUCKET}/${key}" "$tmp/$runfile" --no-sign-request
    chmod +x "$tmp/$runfile"
    sudo "$tmp/$runfile" --extract-only --target "$extract"
    # EKS: make -C <runfile>/kernel-open modules, then harvest the .ko.
    t sudo make -C "$extract/kernel-open" -j"$(nproc)" SYSSRC="/lib/modules/$K/build" modules
    sudo find "$extract/kernel-open" -name '*.ko' -exec cp {} "$extra/" \;
    sudo strip -g --strip-unneeded "$extra"/*.ko 2>/dev/null || true
    # GRID license-server bits that live only in the runfile (EKS copies 3 files into the tree).
    sudo install -D -m0755 "$extract/nvidia-gridd" "$tree/grid-extra/usr/bin/nvidia-gridd"
    sudo install -D -m0644 "$extract/init-scripts/systemd/nvidia-gridd.service" \
        "$tree/grid-extra/usr/lib/systemd/system/nvidia-gridd.service" 2>/dev/null || true
    sudo install -D -m0644 "$extract/gridd.conf.template" "$tree/grid-extra/etc/nvidia/gridd.conf.template" 2>/dev/null || true
    sudo rm -rf "$tmp"
    echo "harvested grid kmods for $v -> $extra ($(ls "$extra" | wc -l) files)"
}

# -------- 4. per-branch tree: unpack version-specific RPMs + .rpms/ for justdb --------
build_tree() { # build_tree VERSION TREENAME CLOSURE
    local v=$1 name=$2 closure=$3 base
    local tree="$NV/$name"
    step "tree '$name' ($v): unpack version-specific RPMs"
    sudo rm -rf "$tree"; sudo mkdir -p "$tree/.rpms"
    # Version-specific = in this closure but NOT in $SHARED (by basename), excluding kmod DKMS sources.
    for rpm in "$B/dl/$closure"/*.rpm; do
        base=$(basename "$rpm")
        case "$base" in kmod-nvidia-*-dkms-*) continue;; esac   # build inputs, not registered
        [[ -e "$SHARED/$base" ]] && continue                     # shared, installed natively
        # Unpack files into the tree (EKS: rpm2cpio | cpio -idmu), keep the .rpm for justdb.
        sudo bash -c "rpm2cpio '$rpm' | (cd '$tree' && cpio -idmu --quiet)"
        sudo cp "$rpm" "$tree/.rpms/"
    done
    echo "tree '$name': $(ls "$tree/.rpms" | wc -l) version-specific RPMs unpacked + staged for justdb"

    step "tree '$name' ($v): build + harvest kmods (open, proprietary$([[ -z $skip_grid_driver ]] && echo , grid))"
    build_open_kmods "$v" "$tree" "$closure"
    build_proprietary_kmods "$v" "$tree" "$closure"
    if [[ -z "$skip_grid_driver" ]]; then build_grid_kmods "$v" "$tree"; fi

    # Record the branch's NEVRA manifest (the boot side registers exactly these with --justdb).
    (cd "$tree/.rpms" && for r in *.rpm; do
        rpm -qp --qf '%{NAME}-%{EPOCH}:%{VERSION}-%{RELEASE}.%{ARCH}\n' "$r" 2>/dev/null | sed 's/-(none):/-0:/'
    done) | sort | sudo tee "$tree/manifest.install" >/dev/null
    echo "tree '$name' manifest: $(wc -l <"$tree/manifest.install") packages"
}
build_tree "$LTS" lts lts
build_tree "$PB" pb pb

# -------- 5. scriptlet emulation at build time (EKS audited all 20; we reproduce the needed effects) --------
# nvidia-persistenced %pre creates the group+user. The daemon presets, boot-update skip, dkms skip and
# hibernate skip are handled at boot by nvidia-setup (which enables the chosen daemon subset explicitly).
step "5 emulate build-time scriptlet effects (persistenced user/group)"
sudo getent group nvidia-persistenced >/dev/null || sudo groupadd -r nvidia-persistenced
sudo getent passwd nvidia-persistenced >/dev/null || \
    sudo useradd -r -g nvidia-persistenced -d / -s /sbin/nologin -c "NVIDIA Persistence Daemon" nvidia-persistenced

# -------- 6. resolve input + boot units --------
# EKS resolves by INSTANCE TYPE against a static support list ("g7 -> 595, else 580"). We reproduce that
# mechanism. The resolve map is derived from pb-required.devices for provenance, but resolve matches the
# running instance type (via IMDS) against the family list below. (ECS's own Option A resolves by PCI
# device ID; here we deliberately follow EKS's instance-type mechanism to benchmark EKS parity faithfully.)
step "6 install resolve map + boot units"
sudo mkdir -p "$CONF"
# Families that resolve to PB. Kept minimal (today only g7) to mirror the EKS static list.
printf 'g7\n' | sudo tee "$CONF/optionb-pb-families" >/dev/null
printf 'LTS_VERSION=%s\nPB_VERSION=%s\n' "$LTS" "$PB" | sudo tee "$CONF/optionb-branches" >/dev/null
# Keep the PCI-device provenance file alongside, for cross-referencing with Option A.
sudo cp "$SRC/pb-required.devices" "$CONF/" 2>/dev/null || true

sudo install -D -m0755 "$SRC/nvidia-driver-resolve.sh" /usr/libexec/nvidia-optionb/nvidia-driver-resolve
sudo install -D -m0755 "$SRC/nvidia-setup.sh" /usr/libexec/nvidia-optionb/nvidia-setup
sudo install -D -m0644 "$SRC/nvidia-driver-resolve.service" /etc/systemd/system/nvidia-driver-resolve.service
sudo install -D -m0644 "$SRC/nvidia-setup.service" /etc/systemd/system/nvidia-setup.service
for m in usr-bin usr-lib64 usr-share; do
    sudo install -D -m0644 "$SRC/$m.mount" "/etc/systemd/system/$m.mount"
done
# Upperdir/workdir roots for the three overlays (ECS path, mirrors EKS /var/lib/eks/nvidia).
sudo mkdir -p /var/lib/ecs/nvidia/{bin,lib64,share}/{upper,work}

sudo systemctl daemon-reload
sudo systemctl enable nvidia-driver-resolve.service nvidia-setup.service
sudo systemctl enable usr-bin.mount usr-lib64.mount usr-share.mount

# -------- 7. sizes + cleanup --------
step "7 sizes + cleanup"
sudo du -sh "$NV"/* 2>/dev/null || true
sudo du -sh "$NV" 2>/dev/null || true
sudo rm -f /etc/dkms/nvidia.conf
sudo rm -rf "$B"
echo "stage-nvidia-optionb: done"
