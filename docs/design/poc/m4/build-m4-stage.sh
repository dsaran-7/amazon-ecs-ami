#!/usr/bin/env bash
# POC M4 build step (simulates what the AMI build would add on top of today's native 580 install):
#  1. stage the 595.91.07 version-specific closure (download-only resolve against the installed 580 set)
#  2. build 595.91.07 open kmods for the running kernel from kmod-nvidia-open-dkms sources, strip -g
#  3. rpmbuild kmod-nvidia-open-prebuilt-3:595.91.07 (Provides nvidia-kmod = 3:595.91.07, no DKMS)
#  4. stage the 580.178.04 set (16 runtime + kmod-nvidia-open-dkms) for the reverse swap
#  5. createrepo_c + manifest.install per version under /opt/ecs/nvidia/<ver>/
#  6. device lists from both supported-gpus.json + validation of pb-required.devices
#  7. install nvidia-driver-select.service (+ nvidia-kmod-load drop-in, POC probe unit)
# Bundle is expected at /tmp/m4proto. Log: /var/log/poc-m4-build.log
set -Eeuo pipefail
P=/tmp/m4proto
K=$(uname -r)
LTS=580.178.04
PB=595.91.07
ST=/opt/ecs/nvidia
B=/opt/poc-build
CONF=/etc/ecs/nvidia-driver-select
NAMES=(libnvidia-cfg libnvidia-fbc libnvidia-gpucomp libnvidia-ml nvidia-driver nvidia-driver-cuda
  nvidia-driver-cuda-libs nvidia-driver-libs nvidia-fabricmanager nvidia-kmod-common nvidia-libXNVCtrl
  nvidia-modprobe nvidia-persistenced nvidia-settings xorg-x11-nvidia)
t() { local s rc; s=$(date +%s%N); set +e; "$@"; rc=$?; set -e; echo "TIME $(( ($(date +%s%N) - s) / 1000000 ))ms rc=$rc: $*"; return $rc; }
step() { echo; echo "=== $(date -u +%T) $*"; }
specs() { local n; for n in "${NAMES[@]}"; do echo "$n-$1"; done; }
nevra() { rpm -qp --qf '%{NAME}-%{EPOCH}:%{VERSION}-%{RELEASE}.%{ARCH}\n' "$@" 2>/dev/null | sed 's/-(none):/-0:/'; }

step "0 build tools (build-time only)"
t dnf -y -q install rpm-build createrepo_c

step "1 stage PB $PB closure"
rm -rf "$B/$PB" "$ST/$PB"; mkdir -p "$B/$PB/dl" "$ST/$PB/rpms"
t dnf -y install --downloadonly --disableplugin=versionlock --setopt=install_weak_deps=False \
  --downloaddir="$B/$PB/dl" $(specs $PB) egl-wayland2
ls -la "$B/$PB/dl"
mv "$B/$PB"/dl/kmod-nvidia-*.rpm "$B/$PB/" # DKMS source package: build input only, never staged
cp "$B/$PB"/dl/*.rpm "$ST/$PB/rpms/"

step "2 build $PB open kmods for $K ($(nproc) cpus)"
mkdir -p "$B/$PB/src"; (cd "$B/$PB/src" && rpm2cpio "$B/$PB"/kmod-nvidia-open-dkms-$PB-*.rpm | cpio -idm --quiet)
SRC=$B/$PB/src/usr/src/nvidia-$PB
t make -s -C "$SRC" KERNEL_UNAME="$K" SYSSRC=/usr/src/kernels/"$K" IGNORE_PREEMPT_RT_PRESENCE=1 \
  IGNORE_XEN_PRESENCE=1 modules -j"$(nproc)" >"$B/$PB/make.log" 2>&1
mkdir -p "$B/$PB/ko"; find "$SRC" -name '*.ko' -exec cp {} "$B/$PB/ko/" \;
echo "unstripped:"; du -cb "$B/$PB"/ko/*.ko
cp -a "$B/$PB/ko" "$B/$PB/ko-su"; strip -g --strip-unneeded "$B/$PB"/ko-su/*.ko
echo "strip -g --strip-unneeded total:"; du -cb "$B/$PB"/ko-su/*.ko | tail -1
strip -g "$B/$PB"/ko/*.ko
echo "strip -g (packaged):"; du -cb "$B/$PB"/ko/*.ko
modinfo -F version "$B/$PB/ko/nvidia.ko"; modinfo -F vermagic "$B/$PB/ko/nvidia.ko"

step "3 rpmbuild kmod-nvidia-open-prebuilt"
R=$B/rpmbuild; rm -rf "$R"; mkdir -p "$R"/{SOURCES,SPECS,BUILD,RPMS,SRPMS,BUILDROOT}
cp "$B/$PB"/ko/*.ko "$R/SOURCES/"; cp "$P/kmod-nvidia-open-prebuilt.spec" "$R/SPECS/"
KREL=$(echo "${K%.x86_64}" | tr - _)
t rpmbuild -bb --define "_topdir $R" --define "kver $K" --define "krel $KREL" --define "nvver $PB" \
  "$R/SPECS/kmod-nvidia-open-prebuilt.spec" >"$B/rpmbuild.log" 2>&1 || { tail -30 "$B/rpmbuild.log"; exit 1; }
cp "$R"/RPMS/x86_64/kmod-nvidia-open-prebuilt-*.rpm "$ST/$PB/rpms/"
F=$(ls "$ST/$PB"/rpms/kmod-nvidia-open-prebuilt-*.rpm)
ls -la "$F"; echo "-- provides"; rpm -qp --provides "$F"; echo "-- requires"; rpm -qp --requires "$F"
echo "-- conflicts"; rpm -qp --conflicts "$F"; echo "-- files"; rpm -qpl "$F"; echo "-- scripts"; rpm -qp --scripts "$F"

step "4 stage LTS $LTS set (reverse swap)"
rm -rf "$ST/$LTS"; mkdir -p "$ST/$LTS/rpms"
t dnf -q download --disableplugin=versionlock --repo amazonlinux-nvidia --destdir "$ST/$LTS/rpms" \
  $(specs $LTS) kmod-nvidia-open-dkms-$LTS
ls -la "$ST/$LTS/rpms"

step "5 createrepo + manifests"
for v in $PB $LTS; do
  t createrepo_c -q "$ST/$v"
  nevra "$ST/$v"/rpms/*.rpm | sort >"$ST/$v/manifest.install"
  echo "--- $v manifest ($(wc -l <"$ST/$v/manifest.install"))"; cat "$ST/$v/manifest.install"
done

echo "--- validate: staged LTS manifest == baked native install"
rpm -q $(sed -E 's/-[0-9]+:/-/' "$ST/$LTS/manifest.install") && echo "LTS manifest fully installed: OK"

step "6 device lists + validation"
mkdir -p "$CONF" "$B/json"
(cd "$B/json" && rpm2cpio "$ST/$PB"/rpms/nvidia-driver-$PB-*.rpm | cpio -idm --quiet ./usr/share/doc/nvidia-driver/supported-gpus.json)
cp "$B/json/usr/share/doc/nvidia-driver/supported-gpus.json" "$B/json/pb.json"
cp /usr/share/doc/nvidia-driver/supported-gpus.json "$B/json/lts.json"
cp "$P/pb-required.devices" "$CONF/"
python3 "$P/gen-device-lists.py" "$B/json/lts.json" "$B/json/pb.json" "$CONF"
printf 'LTS_VERSION=%s\nPB_VERSION=%s\n' "$LTS" "$PB" >"$CONF/branches"
grep -iE '^(2c3a|27b8|1eb8|2237|26b9|2bb5|20b0|2330|2335|2901|3182|1db1|1db5|13f2)$' "$CONF/lts-supported.devices" | tr '\n' ' '; echo " <- lts-supported (selected ids)"
grep -iE '^(2c3a|27b8|1eb8|2237|26b9|2bb5|20b0|2330|2335|2901|3182|1db1|1db5|13f2)$' "$CONF/pb-supported.devices" | tr '\n' ' '; echo " <- pb-supported (selected ids)"

step "7 install boot units"
install -D -m755 "$P/nvidia-driver-select.sh" /usr/libexec/nvidia-driver-select/nvidia-driver-select
install -D -m755 "$P/kmod-load-condition.sh" /usr/libexec/nvidia-driver-select/kmod-load-condition
install -D -m644 "$P/nvidia-driver-select.service" /etc/systemd/system/nvidia-driver-select.service
install -D -m644 "$P/10-nvidia-driver-select.conf" /etc/systemd/system/nvidia-kmod-load.service.d/10-nvidia-driver-select.conf
for u in nvidia-gridd nvidia-topologyd; do install -D -m644 "$P/10-nvidia-driver-select-ltsonly.conf" /etc/systemd/system/$u.service.d/10-nvidia-driver-select.conf; done
install -D -m755 "$P/poc-gpu-ready.sh" /usr/local/bin/poc-gpu-ready
install -D -m644 "$P/poc-gpu-ready.service" /etc/systemd/system/poc-gpu-ready.service
systemctl daemon-reload
systemctl enable nvidia-driver-select.service poc-gpu-ready.service
systemd-analyze verify /etc/systemd/system/nvidia-driver-select.service 2>&1 | head -20 || true
systemctl show nvidia-kmod-load.service -p After -p Wants -p ExecCondition | cut -c1-300

step "8 sizes"
du -sh "$ST"/*; du -sh "$ST"/*/rpms; du -sh "$ST"; df -BM / | tail -1
echo BUILD-DONE
