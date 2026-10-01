# Phase 1 findings (synthesized)

## Headline facts

- SCOPE AND PROVENANCE: This synthesizes w1-packages, w2-hardware (2 verifiers), w3-eks and w4-ecs, all adversarially verified. It also includes six checks I ran myself on 2026-09-28: (1) a parse of the AL2023 NVIDIA repo updateinfo (scripts/alas_branch_check.py); (2) the R580 versions named in NVIDIA CVE records (scripts/cve_r580_mentions.py); (3) the 580.95.05 release-notes date; (4) a look inside AL2023 systemd-252.23-12 for systemd-sysext; (5) the NVIDIA ALAS updateinfo; (6) a re-read of every cited repo file at 2e46ed3. Separately, I used outputs from an EARLIER session's EC2 POC in /tmp/nvpoc/ec2/{probe,repoq,e1,e1b}.out: instance i-0fee34c3053724e48 in us-west-2, the current ECS AL2023 GPU AMI (kernel 6.1.186-228.376), an 8-vCPU non-GPU type. Those are labelled MEASURED-EARLIER-SESSION: I did not re-run them and nobody verified them adversarially. No verdict anywhere was 'refuted' outright. The corrected parts of partially_correct claims are listed under REFUTED/CORRECTED.

- TOP-1 Only G7 needs the PB branch (DOCUMENTED + MEASURED, confirmed by all verifiers). This covers the in-scope x86_64 families; the AL2023 ECS GPU AMI is x86-only (al2023gpu.pkr.hcl:2).
- G7's GPU is 0x2C3A (RTX PRO 4500 Blackwell Server Edition, 10DE:21F4). It is absent from all 12 repo-published 580.x supported-gpus.json files, both 590.x files and 595.45.04. It first appears in 595.58.03.
- AWS documents G7 as needing '595 or later' (docs.aws.amazon.com/AWSEC2/latest/UserGuide/public-nvidia-driver.html).
- G4dn, G5, G6/Gr6, G6e, G7e, P4d/P4de, P5/P5e/P5en, P6-B200 and P6-B300 are all current in both 580.178.04 and 595.91.07. P6-B300 is listed only from 580.82.07.
- Consequence (INFERRED, confirmed): the PB tree needs only the open flavor. The LTS 580 tree must keep open, proprietary (G3/P3/P3dn, which are legacy in 590+) and GRID 19 (G6f/Gr6f).

- TOP-2 Two branches cannot be installed natively side by side (MEASURED with real libsolv 0.7.22; w1-C35 confirmed).
- 17 of the 18 version-specific names are shared between branches, and no package provides installonlypkg or multiversion.
- There are 92 rpm file conflicts (62 outside docs).
- An exact '= 3:V' Requires web ties each version's packages together.
- kmod-nvidia-open-dkms Conflicts with kmod-nvidia-latest-dkms.
- Installing 595 on a 580 host is solved as an upgrade (16 installs, 15 erases). Forcing multiversion makes the transaction unsolvable.
- So any single-AMI design must do one of: unpack and emulate, swap at boot, or keep one native branch plus one out-of-rpmdb branch.

- TOP-3 Today's boot path is not idempotent, and every design inherits this (DOCUMENTED code + MEASURED harness; not yet seen on hardware).
- kmod-util load always runs 'dkms ldtarball archives[0]' (kmod-util:85-93). dkms 3.4.1 load_tarball dies with exit 8 ('already added') unless --force. Under set -Eeuo pipefail (kmod-util:3), nvidia-kmod-load.service therefore fails on every boot after the first. EKS open PR #2733 documents the same bug.
- GPUs probably keep working because udev coldplug autoloads nvidia.ko (MODULE_DEVICE_TABLE class 0300/0302/0680).
- The first-boot 'dkms install' also runs 'dracut --regenerate-all --force' synchronously (post_transaction), on the path to ecs.service. That work is wasted: 99-nvidia.conf omits nvidia from the initramfs.
- dkms.service runs autoinstall every boot and installs the newest registered version of each module. It is unordered against kmod-load and takes no lock.
- MACIS has no nvidia-kmod-load is-failed check, so none of this is caught.

- TOP-4 Disk budget (INFERRED from MEASURED parts).
- w1 figure for a complete extra 595 tree with all 3 flavors: about 1155 MiB with harvested .ko, or about 1189 MiB with dkms-archive tarballs (3.8-3.9% of the 30 GiB root). Keeping the .rpm files for rpm --justdb adds 304 MiB. Header-only RPMs would be about 0.10 MB per version (untested).
- Synthesis refinement for an open-only PB tree: 851 MiB userspace + 98 MiB GSP firmware + 25 MiB stripped open .ko (built on AL2023, MEASURED-EARLIER-SESSION) = about 974 MiB (3.2%).
- Staging an offline 595 RPM set for a boot-time swap is about 304 MiB of RPMs + 25 MiB .ko = about 0.33 GiB.
- The current AMI uses 5.6 GB of its root filesystem (MEASURED-EARLIER-SESSION, df on an 80 GB volume), so a 30 GB default root has about 24 GB free.

- TOP-5 Release and security pipeline constraints.
(a) check-update-security.sh:161-163 reads INSTALLED via 'dnf repoquery --installed nvidia-driver-cuda' on the released AMI running on a non-GPU c5.large. A driver that is unpacked, or only registered at boot on GPU hosts, is invisible there, so the script exits 1 (:260-263). check-update.sh runs under set -euo pipefail (L109), so the whole InitiateRelease job aborts, including AL2 and non-GPU AL2023 (w4-C39, confirmed).
(b) NEW, MEASURED (phase1/scripts/alas_branch_check.py on the AL2023 NVIDIA updateinfo):
- ALAS names one fixed version per advisory. ALAS2023NVIDIA-2026-292/293/294 (2026-06-08) list 11 CVEs as fixed only in 595.71.05.
- NVIDIA's own CVE records for all 11 name R580 versions (580.126.09/580.159.03; phase1/data/cve_r580_mentions.txt).
- 580.159.03 appears only in ALAS-2026-309/310/311, and only for CVE-2026-24193.
- So any R580 host looks unpatched to ALAS-driven scanners. This is the documented mechanism behind Qualys/Inspector false positives on the ECS GPU AMI (AutoDubs wiki) and on EKS (ShakespeareMLCDK). An LTS-default design makes this permanent unless AL publishes per-branch advisories.

- TOP-6 G6f/Gr6f has a GRID problem today, independent of this project.
- The EC2 doc (fetched 2026-09-28) says 'G6f and Gr6f instances require GRID 18.4 to GRID 19.5'. The AMI ships a GRID 19.6 kmod: 580.178.04, NVIDIA_DRIVER_VERSION:15, since Release 20260916.
- By NVIDIA's rules, same-branch 19.x guests are compatible. EKS measured 580.178.04 as 'Licensed' on g6f (chorus V3Bo2AypTdSp). So the doc probably lags.
- GRID 20.x (R595) guests are incompatible with a vGPU 19 Manager. The host must be 19.x because AWS supports both 18.4 and 19.x guests (INFERRED).
- s3://ec2-linux-nvidia-drivers/latest/ now holds 595.91.07 (GRID 20.2) in all three partitions. AWS's own 'aws s3 cp --recursive .../latest/' install step would therefore put GRID 20.2 on G6f. No ECS build or boot path may use latest/.
- If ECS pins G6f to 19.5 (580.159.03), that is a third driver version (full userspace plus kmod), not just a GRID kmod.

- (a) BASELINE, build (DOCUMENTED, repo at 2e46ed3).
- al2023.pkr.hcl:201-212 uploads kmod-util, nvidia-kmod-load.{sh,service}, set-nvidia-clocks(.service) and nvidia-mps.service (only al2023gpu). :214-218 uploads NVIDIA_DRIVER_VERSION.
- :220-231 runs install-nvidia-driver.sh, then enable-ecs-agent-gpu-support-al2023.sh. Both self-gate on AMI_TYPE (install-nvidia-driver.sh:5-7). SKIP_GRID_DRIVER_REGIONS='eusc-de-east-1,eu-isoe-west-1' (al2023.pkr.hcl:13).
- :233-240 runs install-dcgm.sh.
- The builder is a GPU-less c5.4xlarge (variables.pkr.hcl:196-200) with a 30 GB gp3 root (variables.pkr.hcl:42-46; al2023gpu.pkr.hcl:19-24). The internal pipeline can override the builder type per region.
- There is one pinned version: nvidia_driver_version_al2023 = "580.178.04" (NVIDIA_DRIVER_VERSION:15), within nvidia_driver_major_al2023 = "580" (variables.pkr.hcl:262-266).

- (a) BASELINE, install-nvidia-driver.sh (DOCUMENTED).
- :11-12 kmod-util into /usr/bin. :16-17 a redundant /etc/dkms/nvidia.conf -j override, removed at :244. :21-28 kernel-devel/headers/modules-extra for uname -r, plus dkms. :31 versionlock kernel*. :34 enable --now dkms.
- :37 installs nvidia-release. The .repo file actually comes from nvidia-repo-s3 via a rich Requires (w1-C01/C02 confirmed), so the comment at :36 is stale.
- :56 reads the pin.
- Build order is GRID, proprietary, open (:169-173):
  - GRID :111-166: unsigned S3 list with a prefix grep and sort (:122-126); nvidia-installer --dkms --kernel-module-type open --silent (:147-150), which also installs untracked runfile userspace and enables gridd/topologyd/persistenced; rename to nvidia-grid, rebuild, archive, remove.
  - Proprietary :78-98: dnf install kmod-nvidia-latest-dkms-$V (%post compiles), rename to nvidia-proprietary, rebuild, archive, remove, dnf remove.
  - Open :101-108: dnf install kmod-nvidia-open-dkms-$V, archive, remove, rm -rf /usr/src/nvidia*. The RPM stays registered because nvidia-kmod-common Requires nvidia-kmod = 3:V.
- :178-188 dnf userspace at exactly $V (plus pciutils, xorg-x11-server-Xorg, nvidia-container-toolkit). :192 versionlock 'nvidia*' 'kmod*' 'libnvidia*' 'xorg*'. :195-196 gridd.conf EnableUI=FALSE. :200-206 libibumad, infiniband-diags, nvlsm, ib_umad. :212-240 install and enable nvidia-kmod-load, set-nvidia-clocks, nvidia-mps, fabricmanager, persistenced.
- Totals per version (w4-C02 corrected): 5 compiles (4 DKMS plus 1 by nvidia-installer itself) and about 10 synchronous dracut runs.
- Baked state: three archives under /var/lib/dkms-archive/{nvidia-grid,nvidia-proprietary,nvidia}/<pkg>-580.178.04-kernel<k>-x86_64.dkms.tar.gz, each with source plus built .ko. The DKMS tree is empty and no nvidia.ko is installed.

- (a) BASELINE, boot (DOCUMENTED).
- nvidia-kmod-load.service:1-11 is a oneshot, Before=nvidia-fabricmanager, nvidia-persistenced and ecs.service, with no After=, WantedBy=multi-user.target.
- nvidia-kmod-load.sh:
  - exit 0 if there is no NVIDIA device (:6-9);
  - nvidia-grid if any lspci -n -mm device-ID:subsystem-device-ID tuple ($4:$7, :33) is 27b8:1733/1735/1737 (:12-16, :53-54);
  - else nvidia-proprietary for 1db1:1212 (P3), 1db5:1249 (P3dn) or 13f2:113a (G3) (:17-21, :55-56);
  - else nvidia, the open flavor (:57-58);
  - then 'exec kmod-util load' (:62).
- kmod-util load: lock, 'dkms ldtarball archives[0]' (:85-93), module-version = 'dkms status -m NAME | head -n 1' (:68), 'dkms install' (:98). dkms install copies the .ko, runs depmod, runs modprobe_on_install (modprobe of all modaliases plus a restart of systemd-modules-load), then runs synchronous dracut.
- nvidia-mps.service:4-7 is Wants/After nvidia-kmod-load, Before ecs. set-nvidia-clocks.service:2-6 is After/Requires persistenced.
- GPU enablement: ECS_ENABLE_GPU_SUPPORT=true goes into /var/lib/ecs/ecs.config (enable-ecs-agent-gpu-support-al2023.sh:11-12). /etc/docker-runtimes.d/nvidia execs nvidia-container-runtime (:19-22), with the runtime mode left at its default.
- DCGM is skipped today: install-dcgm.sh:15-18 needs /usr/libexec/dcgm-init, which is absent from ecs-init 1.107.0. The datacenter-gpu-manager* lock at :24 is therefore not in effect (w4-C04 corrected).

- (a) BASELINE, observed on a real instance of the current AMI (MEASURED-EARLIER-SESSION, /tmp/nvpoc/ec2/probe.out):
- 'dnf versionlock list' shows 7 kernel* lines plus exactly 27 driver-related lines: nvidia* 14, kmod* 3 (including AL2023's own kmod and kmod-libs), libnvidia* 6, xorg* 4. This matches w1-C42's emulation line for line.
- xorg-x11-nvidia-3:580.178.04 is installed and locked, confirming w1-C09's prediction via Supplements.
- nvidia-powerd, nvidia-hibernate, nvidia-resume, nvidia-suspend and nvidia-suspend-then-hibernate are all 'enabled', confirming w1-C32's preset side effect.
- nvidia-gridd and nvidia-topologyd are enabled (runfile post-install). nvidia-cdi-refresh.path/.service are enabled. No DCGM units exist. 'dkms status' is empty.
- Archive sizes: nvidia 34,831,957 B, nvidia-grid 23,627,026 B, nvidia-proprietary 181,474,431 B (228.8 MiB total).
- ecs.service After= includes nvidia-kmod-load, nvidia-mps, docker and cloud-final.
- /etc/yum.repos.d/amazonlinux-nvidia.repo is the S3 dualstack mirrorlist variant.

- (a) BASELINE, release-time version resolution (DOCUMENTED).
- check-update-security.sh al2023_gpu runs every weekday via InitiateRelease cron.
- It reads the pinned major (:144-152). It launches the released SSM AMI on a c5.large and runs 'dnf repoquery --installed' (INSTALLED) plus repo versions within the major (:161-163).
- It intersects those with GRID runfile versions from us-east-1, us-gov-east-1 and cn-north-1 (:271-292; the gate was added by #768 after the #769 revert on 2026-08-19). It emits 'true nvidia:<max>' only if that is newer (:296-312).
- check-update.sh:62-66 seds the single key. generate-release-notes.sh:19,45 takes a single --al2023-gpu-nvidia-ver.
- Pin history (MEASURED git): 580.159.03 from 2026-05-14; 580.178.04 on 2026-08-18, reverted 2026-08-19; 580.178.04 again from 2026-09-16.
- Where Harish's released design differs from the code (w4-C15 confirmed):
  - Names: the doc body uses nvidia / nvidia-open / nvidia-open-grid; the code uses nvidia (open) / nvidia-proprietary / nvidia-grid.
  - Selection: the doc uses supported-devices files with proprietary as default; the code uses a proprietary allowlist with open as default.
  - Build order differs.
  - GRID source: the doc builds with GRID_BUILD=1; the code uses the runfile (927c5e8).
  - The code pins an exact version and versionlocks it; the doc says 'we do not version lock'.
  - vm.overcommit_memory is not set by default.
  - Clocks, MPS, DCGM, CDI and P6 support are missing from the doc.

- (b) VERIFIED, packages 1/3 (w1; confirmed unless marked).
- The AL2023 NVIDIA repo (amazonlinux-nvidia, repomd revision 1788538253) carries nvidia-driver 555.42.02/.06, twelve 580.x releases up to 580.178.04, and 595.58.03/.71.05/.91.07. It lacks 590.x, 595.45.04, 610.x and 615.x. Neither the AL2023 repo nor NVIDIA's contains any GRID or vGPU package (MEASURED).
- It also has 570.x builds of nvidia-driver-cuda and the kmod packages (MEASURED-EARLIER-SESSION repoquery).
- download.nvidia.com has 595.99.02 and 595.104.02, but they are in neither the repo nor the GRID bucket (w3 verifier).
- It is a NEAR-subset of NVIDIA's amzn2023 repo (partially_correct, corrected): 2309 of 2310 common NEVRAs are byte-identical (nvlsm-2025.03.1-1 differs), and cccl-13-3-13.3.3.3.1-1 exists only in AL2023.
- The ECS build gets nvidia-repo-s3 (mirrorlist al2023-repos-$awsregion-de612dc2.s3$dualstack...). The S3 and CDN repomd files are byte-identical.
- dnf install_weak_deps defaults to true (libdnf 0.69.0 ConfigMain.cpp:230), so xorg-x11-nvidia arrives via rich Supplements, which exclude_from_weak_autodetect cannot suppress.
- Closure (partially_correct, corrected): the workstream's roots give 222 packages (26 NVIDIA-repo + 196 core), reproduced package for package by libsolv. Adding the omitted install-nvidia-driver.sh:200 roots (libibumad, infiniband-diags, nvlsm) gives 225 packages (27 from the NVIDIA repo), and the shared set becomes 207. A faithful sequential replay gives a 218-package GPU delta. Quote the partition, not the absolute size.

- (b) VERIFIED, packages 2/3.
- Partition: 204 shared (196 core + 8 NVIDIA-repo: DCGM core and -proprietary, container-toolkit and -base, libnvidia-container1 and -tools, egl-gbm, egl-x11) and 18 version-specific per version = 16 runtime + kmod-nvidia-open-dkms + kmod-nvidia-latest-dkms.
- The 16 runtime packages: egl-wayland (580) / egl-wayland2 (595), libnvidia-cfg, -fbc, -gpucomp, -ml, nvidia-driver, -driver-cuda, -driver-cuda-libs, -driver-libs, -fabricmanager, -kmod-common, -libXNVCtrl, -modprobe, -persistenced, -settings, xorg-x11-nvidia.
- Verifier addition (MEASURED): egl-wayland and egl-wayland2 install side by side with 0 erasures, so 15 runtime packages are truly version-specific.
- EKS's root list reproduces 201/20 with EKS's exact 20 names (EKS published 199/20). 'None of the 199 is an nvidia package' holds only by name (egl-gbm and egl-x11 come from the NVIDIA repo).
- The driver's dependency on the shared egl-* packages is one-directional and unpinned ('>= min'). One shared copy therefore suffices if it satisfies both branches' minimums, which 1.1.3 and 1.0.5 do (C15 corrected).
- Only the exact-version Requires web changes between branches, by one item: config(nvidia-kmod-common) disappears because 595 drops /etc/modprobe.d/nvidia-modeset.conf.
- DCGM-4 (4.6.1) and the container toolkit (1.19.1) have no driver dependency of any kind (MEASURED). Upstream DCGM 4.7.0 splits into about 12 new subpackages not yet mirrored in AL2023.
- With no driver in the rpmdb, customer installs of cuda-runtime-13-0, cuda-13-0, nvidia-xconfig, nvidia-fs-dkms, gdrcopy-kmod, nvidia-imex, libnvidia-nscq, cuda-drivers, nvidia-open or nvlink5 pull 595.91.07 driver RPMs natively (MEASURED libsolv).
- Pre-existing hazard, measured on today's locked 580 AMI: 'dnf install nvidia-imex' installs nvidia-imex-595.91.07.

- (b) VERIFIED, packages 3/3 (files, scriptlets, versionlock).
- File sets: 77 switch paths (62 differ, 4 only in 580, 11 only in 595), 37 identical, 73 version-suffixed paths that coexist. This is the ECS-only variant; data/rerun.log's 'with_extras' variant has 82.
- Where the switch paths live: /usr/bin 14, /usr/lib64 34, /usr/share 23, /usr/lib/systemd 5, /etc 1. None in /usr/sbin, /usr/libexec or /usr/include. No NVIDIA package ships an ld.so.conf.d entry.
- EKS's three overlays cover 71 paths. The other 6: nvidia-modeset.conf, nvidia-powerd.service, and four 595-only suspend drop-ins.
- 19 byte-identical host files lie outside the overlays, including /usr/lib/modprobe.d/nvidia.conf (softdep nvidia post: nvidia-uvm nvidia-drm; NVreg options) and /usr/lib/udev/rules.d/60-nvidia.rules (runs nvidia-modprobe). EKS never places these. Their blacklist lines have no effect on AL2023 because the kernel ships no nouveau.ko (MEASURED).
- The Vulkan and VulkanSC ICDs hard-code /usr/lib64 absolute paths. nvidia_layers.json hard-codes libnvidia-present.so.<V>. fabricmanager.cfg is %config(noreplace) and differs (595 adds PARTITION_RAIL_POLICY=greedy).
- Scriptlets: 6 of the 18 packages have them, 4 in the runtime set. After version normalisation they are identical between 580 and 595 (only nvlink5 differs, and it is not installed). None has pretrans, posttrans or file triggers. The EKS package set has 7, because it adds nvidia-imex.
- The dnf versionlock plugin (dnf-plugins-core 4.3.0-13.amzn2023.0.6, byte-identical to upstream):
  - it matches rpmdb first and falls back to available packages only when nothing matches;
  - it never excludes @System packages;
  - it excludes obsoleters, which is the only thing stopping nvidia-fabric-manager-570.211.01 (unversioned Obsoletes) from replacing nvidia-fabricmanager-580.
- Versionlock outcomes: an unpacked design gets 11 lock lines and no driver lock. A justdb registration with those 11 lines lets 'dnf upgrade' move all 16 runtime packages to 595. A static lock list holding both versions also allows that upgrade (MEASURED).

- (b) VERIFIED, hardware and lifecycle (w2).
- V100 (1DB1/1DB5) and M60 (13F2) are legacybranch=580.xx in every 590+ JSON. R580 is the last branch for Maxwell, Pascal and Volta (forum post, architecture matrix, 595 README Appendix A).
- The 595 proprietary flavor covers Turing through Hopper only. Blackwell is open-only in every branch.
- EKS resolves by PCI-ID lists, not by instance type. Only G7 reaches PB (MEASURED simulations by w2, w3 and both verifiers).
- The 580 open probe (nv-pci.c:1357 to osapi.c:3692) rejects only non-display, non-NVIDIA or legacy IDs. 580 may therefore bind on G7 without being qualified. Unverified.
- vGPU compatibility (vGPU 20/19 KVM release notes): 20.x guests are incompatible with Manager 19.x or older; 19.x guests are incompatible with Manager 18.x or older. A 19.x Manager also accepts 16.x (R535 LTSB) guests.
- Support lifecycle:
  - R580 LTSB: EOL June 2028 (vGPU 19: July 2028).
  - R595 PB: EOL March 2027. Its 6-month LTSB-designation window has passed, so it will not become an LTSB.
  - 590, 610 and 615 are New Feature Branches. R610's EOL (Aug 2026) has already passed.
  - No successor PB exists as of 2026-09-28.
- CUDA by branch: 580 = 13.0, 590 = 13.1, 595 = 13.2, 610 = 13.3, 615 = 13.4.
- CUDA 13.x applications run on drivers >= 580 via minor-version compatibility. Caveats: no JIT of newer PTX, SASS required, cudaErrorCallRequiresNewerDriver. cuda-compat-13-2 works on 580+ data-center GPUs.
- 615 no longer ships kmod-nvidia-latest-dkms (the proprietary RPM).
- supported-gpus.json ships byte-identically in nvidia-driver.x86_64 and in the 59 KB noarch nvidia-driver-assistant RPM. It is not refreshed every release: 580.126.16 through 580.178.04 are identical.

- (b) VERIFIED, security and GRID cadence (w2, with corrections).
- There were 6 High GPU Display Driver bulletins: 2025-01-22, 04-24, 07-24, 10-09, 2026-01-28 and 05-19. None has been published since 2026-05-19.
- Linux fixed versions from CVE records:
  - Oct 2025: 535.274.02, 570.195.03, 580.95.05.
  - Jan 2026: 535.288.01, 570.211.01, 580.126.09 (all 2026-01-13), plus 590.48.01.
  - May 2026: 535.309.01, 580.159.03, 595.71.05 (all 2026-04-28).
- The H1-2025 records list affected branches only, so co-release cannot be shown for them.
- I fetched the 580.95.05 release notes myself: 'Linux driver release date: 10/01/2025'. releases.json misdates it as 2025-09-02. So the Oct 2025 fixes were co-released within about a day, not 'four weeks apart'.
- Some CVEs are fixed only on the LTSB line, e.g. CVE-2026-24193 (R580/R535).
- GRID runfile coverage: 7 of 12 R580 releases and 3 of 3 R595 releases.
- Upload lag after NVIDIA's release in us-east-1 is 1-39 days. The slowest partition adds up to 71 days (grid-19.3 in us-gov-east-1), or 31 days for 19.6/20.2. cn-north-1 has no grid-20.0.
- Because of the 3-partition gate (check-update-security.sh:271-292), the LTS tree's effective release cadence is the GRID cadence.

- (b) VERIFIED, ECS integration (w4).
- GPU discovery happens in ecs-init pre-start (engine.go:136-142, 218-235) when ECS_ENABLE_GPU_SUPPORT is set in the merged /var/lib/ecs/ecs.config and /etc/ecs/ecs.config.
  - It waits up to 10 x 3 s for /dev/nvidia*, in every LoadEnvVars call (worst case about 90 s). The retry applies only to the /var/lib entry.
  - It runs NVML Init via go-nvml dlopen('libnvidia-ml.so.1') and writes /var/lib/ecs/gpu/nvidia-gpu-info.json.
- On NVML failure (driver not loaded, or 'Driver/library version mismatch'), pre-start exits -1 (255). ecs.service (Restart=on-failure, RestartSec=10s, RestartPreventExitStatus=5) then loops and the instance never registers.
- The agent registers PlatformDevices plus ecs.capability.nvidia-driver-version.<v> (name-only) and ecs.capability.gpu-driver-version=<v> (agent >= 1.75.0; agent_capability_unix.go:115-127). The attribute is absent from the ECS docs.
- Cloud-init on AL2023 (22.2.2): bootcmd and write_files run in cloud-init.service; user-data scripts and runcmd run in cloud-final. ecs.service is After=docker and cloud-final. nvidia-kmod-load has no After=.
- Toolkit >= 1.18 in auto mode uses JIT-CDI and does not read /var/run/cdi/nvidia.yaml (w4-C11 corrected). ECS tasks use Runtime=nvidia plus NVIDIA_VISIBLE_DEVICES (task.go:2291), so they do not race the static CDI spec. They do need host libraries switched before container create.
- Toolkit-base 1.20.1 ships a drop-in ordering nvidia-cdi-refresh Before=docker with TimeoutStartSec=90s (w3 verifier, MEASURED payload). Whether ECS's 1.19.1 has it was not checked.
- Latent hazard: lspci -mm is parsed by position. pciutils >= 3.8 always prints -pXX, which would shift $7 and silently route GRID and proprietary devices to open. AL2023 ships 3.7.0 and does not versionlock it.

- (b) VERIFIED, kmod-util and dkms behavior (w4 harness + code; w3).
- With two versions under one DKMS name:
  - load always takes archives[0] (580), and remove takes the first version.
  - Top-level 'kmod-util module-version' (build time, install-nvidia-driver.sh:81/104) intermittently returns rc=141 with empty output (19/200 runs), because pipefail catches SIGPIPE from head. Inside load/remove/archive/build it never fails: $() clears -e, so those paths silently return the lexically first version (C18 corrected).
- dkms 3.4.1 status order is a deterministic lexical glob, and its warnings go to stderr (w3-C32 corrected).
- Per-version DKMS names fix first boot, but switching version across reboots produces split-brain (udev has already loaded the previous .ko) and later rc=8.
- A POC kmod-util.v2 (version argument, idempotent, uninstalls conflicting packages) passes V1-V3, provided udev autoload of a stale .ko is prevented.
- Stop/start g5 -> p3 -> g5 on today's AMI leaves both DKMS packages installed, rc=8 on the way back, and the proprietary .ko loaded on g5 (harness S6, consistent with real dkms code).
- The first ldtarball copies about 120 MB of source back to /usr/src.
- The kernel-install hook runs 'dkms kernel_postinst' (autoinstall) for the NEW kernel only (C30 corrected).
- The ECS al2023neu precedent: neuron-inf1-downgrade.service swaps cached RPMs at boot. It hung 5 minutes offline (#602) and was fixed with a scriptlet PATH override (#604). Lesson: any boot-time switch must work offline.

- (b) VERIFIED, EKS reference (w3).
- Squash commit be7adc2e (PR #2819, +1245/-591, 23 files) merged 2026-09-15 and first shipped in v20260917. The tag points at ffc658f8, which already contains the legacy-list fix.
- Build: per-tree version = min(newest kmod-nvidia-open-dkms in repo, newest GRID runfile in S3). No cross-partition check is made.
- Open and proprietary kmods: dkms add+build, then harvest by BUILT_MODULE_NAME into /opt/nvidia/<tree>/flavors/<flavor>/lib/modules/<k>/extra, then dkms remove and rm /usr/src.
- GRID kmods: runfile --extract-only, make -C kernel-open, strip. Only nvidia-gridd, its unit and gridd.conf.template are harvested.
- Userspace: 'dnf install --downloadonly' closures per tree, split by identical RPM basename. Shared packages are dnf-installed; the rest are rpm2cpio'd into the tree and also copied to <tree>/.rpms. The only scriptlet emulated is persistenced's useradd.
- Boot:
  - nvidia-driver-resolve.service: DefaultDependencies=no, After=local-fs.target, once (ConditionPathExists=!.driver-flavor). It reads DMI product_name offline and chooses LTS-open, else PB-open, else LTS-proprietary. Then a GRID override for 27b8:1733/1735/1737, then g4dn/g5/g5g forced to LTS proprietary with NVreg_EnableGpuFirmware=0. It mv's the chosen tree to /opt/nvidia/current and rm -rf's the others in the background.
  - Overlays on /usr/{bin,lib64,share} with upperdir under /var/lib/eks/nvidia.
  - nvidia-setup.service: copies /etc with cp -a -n every boot; on first boot copies .ko and firmware and runs depmod; runs modprobe every boot; on first boot installs units and enables persistenced, fabricmanager, clocks, and gridd for the grid flavor.
  - nvidia-ldcache-update.service runs ldconfig (#2835).
  - nvidia-package-install.service (Before=cloud-final) runs 'rpm -i --justdb --noscripts --nodeps --nodigest --nosignature'.
- Versionlocks: none on NVIDIA packages. EKS locks kernel*, amazon-ec2-net-utils and containerd-* (C18 corrected).
- There is no customer override (#2417 declined).
- Tests: validate.sh at build plus manual /ci runs. No unit tests exist for resolve or setup.

- (b) EKS KNOWN ISSUES AND LESSONS (DOCUMENTED, w3 + verifier).
(1) #2816 dropped boot-time ldconfig. It shipped in v20260917 and NVML legacy consumers failed with ERROR_LIBRARY_NOT_FOUND (#2834: GPU Operator with toolkit 1.17.4, arm64 g5g). Fixed by #2835 (a2a561ba, 2026-09-25), which is not in v20260923. Root cause: glibc-common's transfiletrigger never fires for rpm2cpio'd files, and --noscripts sets NOPOSTTRANS, so justdb registration cannot rebuild the cache either.
(2) ffc658f8 (2026-09-17): the PB list had been generated with a kernelopen-only filter and included M60/V100. It existed on main for about 26 h next to the dual resolver and was never in a tagged dual-driver release.
(3) v20260917 release notes lost the driver rows (#2833). The v20260923 notes already had them via a mechanism outside the repo. #2830 (merged 2026-09-28, in no release) writes '.nvidia[<tree>]'.
(4) SELinux: tree content was labelled usr_t (#2820, #2811). ECS runs permissive and has no SELinux config.
(5) Cleanup: #2813 frees about 1.7 GB, and the rm took about 3 s in the blocking path, so #2814 moved it to the background. If the node stops mid-delete, the tree is never cleaned up (INFERRED).
(6) modprobe.d/nvidia.conf and 60-nvidia.rules are never placed on the host.
(7) GRID nodes register nvidia-kmod-common with no nvidia-kmod provider (hidden by --nodeps).
(8) Resolve-once plus deletion: a g6-baked custom AMI relaunched on g7 keeps 580. A forced re-run gives 580-proprietary, because the PB tree is gone. The EKS user guide documents this.
(9) Harvested .ko exist only for the build kernel. setup exits 1 on any kernel change, and there is no DKMS source left to rebuild.
(10) The module stream is set to '<major>-open' even on proprietary and grid nodes. NVreg_CoherentGPUMemoryMode=driver is written unconditionally.
(11) nvidia-ldcache-update has no Before= edge against its consumers.
(12) The static device lists are stale: generated from 580.82.07 and 595.71.05.
(13) The chorus design doc oN8qVvlQpSti differs from the code in three explicit places (instance-type table vs PCI lists; symlink vs mv; the .driver-committed gate) and is silent on ldconfig.
(14) No internal doc explains why overlays were chosen, and no boot-time measurement exists anywhere.
(15) The EKS doc says nvidia-powerd 'fails on current AMI'. On ECS it is enabled today (MEASURED-EARLIER-SESSION).

- (b') REFUTED OR CORRECTED: these must NOT be quoted as facts.
- w1-C04 'strict byte-identical subset': it is a near-subset (2 AL2023 RPMs have no byte-identical upstream twin).
- w1-C08 'exactly what the scripts install': the root set omits nvlsm and friends. The correct figures are 225 packages (27 NVIDIA-repo) and 207 shared.
- w1-C10 '126 attributable to nvidia-settings': a drop test removes 131 packages (163 with Xorg).
- w1-C15 'unpinned >= relationships of the 8 shared packages to the driver': only the egl packages are coupled, in the direction driver -> egl.
- w1-C23 'header-only 0.19 MB': it is 0.10 MB per version.
- w1-C28 '25 flipped links': 22 top-level soname links are affected, 20 of which differ.
- w1-C33 '103 lib64 files': that is the union over both versions; per version it is 68/69.
- w2-C04 'stale kernelopen': the flag is spurious; the features were rewritten to exactly ['kernelopen']. 'EKS shipped this bug' is overstated: it was never in a tagged dual-driver release.
- w2-C11 'change could not be dated; Wayback offline': captures show '18.4 or later' in Aug/Oct 2025 and Feb/Mar 2026, and '18.4 to 19.5' from 2026-06-23. No capture has Harish's 'no 19.0+' wording.
- w2-C24 'every 2025-26 bulletin co-released': this is shown only for Oct 2025, Jan 2026 and May 2026.
- w2-C26 '7-39 days': the lag is 1-39 days, the worst partition adds up to 71 days, and 580.95.05's releases.json date is wrong.
- w2-C29 '31 L4 profiles': there are 32.
- w3-C11 '0x2C3A absent from every 580.x': desktop 580.142 (2026-03-05) listed it and 580.159.03+ dropped it. The claim holds only for repo- and GRID-published releases.
- w3-C18 'only kernel* locked': EKS also locks amazon-ec2-net-utils and containerd-*.
- w3-C27 '#2830 restored release notes': the v20260923 notes already had the rows.
- w3-C28 'chorus doc says no ldconfig': the doc is silent on ldconfig.
- w3-C32 'WARNING text returned / arbitrary order': with dkms 3.4.1 the order is deterministic lexical and warnings go to stderr.
- w4-C02 '5 DKMS compiles': 4 are DKMS compiles and 1 is nvidia-installer's own build.
- w4-C04 'DCGM lock in effect': it is not applied today.
- w4-C07 '27b8 is a subsystem ID': 27b8 is the device ID.
- w4-C11 'CDI race affects ECS tasks': it does not by default (JIT-CDI).
- w4-C18 'SIGPIPE in load paths': the SIGPIPE failure happens only in the top-level CLI call.
- w4-C27 'constraint works': it is untested.
- w4-C30 'kernel-install hook contends on the running kernel': it builds for the new kernel.
- w4-C31 'EKS resolve Before=cloud-init': there is no such explicit edge.
- w4-C35 'no plumbing change for a 2-in-1 AMI': MACIS, release-notes and check-update changes are still needed.
- w4-C36 build-time deltas: the macOS proxy was poor.
- w1-C20/C21 .ko sizes: the Arch-built proxy is about 30% above a stripped AL2023 6.1 build (MEASURED-EARLIER-SESSION: open 25 MiB, proprietary 107 MiB, GRID 25 MiB vs Arch 33.7 / ~138.9 / ~33.7).

- (c) HARDWARE x BRANCH x FLAVOR (full table in /tmp/nvpoc/phase1/data/hw_branch_flavor_matrix.csv). PCI IDs are mapped by product name and are INFERRED; none were verified with lspci.
- G3 (M60 13F2), P3 (V100 1DB1) and P3dn (V100 1DB5): 580 proprietary only. They are legacy in 595. GRID 17+ is unsupported on G3. Dead end when R580 goes EOL in June 2028.
- G4dn (T4 1EB8), G5 (A10G 2237), G6/Gr6 (L4 27B8, bare-metal subsystems 16CA/16EE), G6e (L40S 26B9), P4d/P4de (A100 20B0/20B2), P5 (H100 2330), P5e/P5en (H200 2335): 580 and 595, open and proprietary. ECS today uses 580 open. EKS forces g4dn and g5 onto 580 proprietary with GSP off.
- G6f/Gr6f (27B8 with vGPU subsystems 1733 L4-3Q / 1735 L4-6Q / 1737 L4-12Q): GRID only, 580/GRID 19 only. The documented range is 18.4-19.5; the AMI ships 19.6. GRID 20 is incompatible. NVIDIA defines 32 L4 vGPU profiles, so a new G6f size would silently fall through to open.
- G7 (2C3A:21F4): 595 open only. Blackwell is open-only, and GRID is not documented for G7. ECS today would load unqualified 580 open.
- G7e (RTX PRO 6000 BSE 2BB5), P6-B200 (B200 2901; 0x2909 exists only in 595.58.03+) and P6-B300 (B300 3182, from 580.82.07): open only, 580 or 595.
- The arm64 families (G5g, P6e-GB200/GB300) are out of scope. Note that GB300 0x31C3 exists only in 595 lists.
- A known issue shared by 580.178.04 and 595.91.07: Hopper subrevision 3 with VBIOS < 96.00.68.00 fails to initialize.
- ECS docs name only p2, p3, p4d, p5, g3, g4, g5, g6, g6e, g6f, gr6 and gr6f.

- (d) NUMBERS.
- Closure and partition: see (b). nvidia-settings costs 131 core packages, and nvidia-settings plus Xorg cost 163 of 196.
- Version-specific RPMs:

| | download | installed |
|---|---|---|
| 580.178.04 | 408.2 MiB | 1268.3 MiB |
| 595.91.07 | 397.6 MiB | 1181.0 MiB |
| shared set | 154.3 MiB | 672.0 MiB |

- 595 installed bytes by destination: /usr/lib64 741.7, /usr/src 232.0, firmware 98.2, /usr/share 58.1, bin+sbin 48.4 MiB.
- Largest downloads (580/595): nvidia-driver-libs 144.2/106.3, kmod-nvidia-latest-dkms 80.0/76.0, nvidia-kmod-common 72.5/71.5, nvidia-driver-cuda-libs 58.9/84.1 MiB.
- w4's independent figure (15 names + egl-wayland2) is 1112.7 MB for 595, consistent after scoping.
- .ko on AL2023 6.1.186, 595.91.07, make -j8 (MEASURED-EARLIER-SESSION, /tmp/nvpoc/ec2/e1.out):
  - unstripped: open 97.2, proprietary 178.3, GRID 97.1 MiB (nvidia-uvm alone about 59 MB unstripped);
  - after strip -g --strip-unneeded: 25, 107, 25 MiB;
  - dkms default is 'strip -g' only.
  - Build wall time on 8 vCPU: open 100 s, proprietary 46 s, GRID kernel-open 46 s.
- Today's archives (MEASURED on the AMI): 33.2 / 22.5 / 173.1 MiB = 228.8 MiB. The w1 model gave 246.6 MiB because it over-estimated GRID.
- EKS per-tree size: 1473/1381 MiB including RPM copies, excluding .ko.
- Build downloads per version: 415-426 MB of version-specific RPMs plus a 403 MB (580) or 429 MB (595) GRID runfile.
- Collisions: 92 rpm file conflicts (62 non-doc).
- Host file triggers that unpack or justdb skip: ldconfig (68/69 files), systemd (9/13), udev (1), man-db (5), desktop-file-utils (1).

- (f) ECS CONSTRAINTS ON ANY MULTI-VERSION DESIGN (INFERRED from verified facts).
1. The switch must complete before nvidia-persistenced, fabricmanager, gridd, mps, dcgm, nvidia-cdi-refresh, docker and ecs.service, and before any user-data GPU use. Otherwise NVML mismatch sends ecs-init into a restart loop.
2. It must work offline (the neuron #602 lesson; ISO/ADC regions; GRID-skip regions).
3. Exactly one nvidia* DKMS registration per kernel, or no DKMS at all. Neutralise dkms.service autoinstall (/etc/dkms/no-autoinstall or single registration) and suppress post_transaction dracut.
4. Guard against udev autoloading a stale nvidia.ko whenever the version or flavor changes.
5. ldconfig must run after the library switch, because transfiletriggers don't fire. Docker plus nvidia-container-runtime in legacy mode and the MPS daemon use ld.so.cache.
6. rpmdb and versionlock must reflect the selected branch, written at boot, and must lock nvidia-imex* and libnvidia-nscq*. Otherwise customer dnf installs pull 595 natively.
7. Release detection and release notes must be per-branch and must not depend on the released AMI's rpmdb on a non-GPU host.
8. Customer override surfaces:
   - cloud-config write_files/bootcmd needs only After=cloud-init.service (seconds);
   - /etc/ecs/ecs.config written by a user-data script needs After=cloud-final, which serializes the driver load and breaks GPU use in user-data;
   - IMDS tags need InstanceMetadataTags=enabled (off by default);
   - SSM needs ssm:GetParameter, which the managed ECS role lacks (it has ec2:DescribeTags);
   - the kernel cmdline cannot be set at launch.
9. Placement: ecs.capability.gpu-driver-version already exposes the loaded version (undocumented).
10. Stop/start changes of instance type between families are possible, so resolve-once vs re-resolve must be decided explicitly.

- (f) MULTI-VERSION CHANGE POINTS (full table in /tmp/nvpoc/phase1/data/change_points.tsv).
- Versions and release:
  - NVIDIA_DRIVER_VERSION:15 and variables.pkr.hcl:262-266 need per-branch keys and majors.
  - check-update-security.sh:144-152, 161-163 and 257-263 (INSTALLED via rpmdb), :271-303 (GRID mandatory; make it optional for PB) and :305-312 (single token).
  - check-update.sh:20-79 and 109-114.
  - generate-release-notes.sh:19,45.
  - al2023.pkr.hcl:214-231 and al2023gpu.pkr.hcl:3-10 (tags).
- install-nvidia-driver.sh:
  - :56-61 single version; :78-98 and :101-108, where module-version nvidia (:81, :104) picks the wrong version when two are registered and 'rm -rf /usr/src/nvidia*' (:107) deletes every version.
  - :111-166 nvidia-installer userspace and gridd (replace with make -C kernel-open and a 3-file harvest).
  - :122-126 prefix grep (also matches latest/).
  - :178-188 EQ-pinned dnf userspace.
  - :192 glob versionlock, which misses imex/nscq and protects nothing unpacked.
  - :17,244 redundant -j override.
- kmod-util: :65-77 (head -n 1), :80-100 (archives[0], not idempotent), :103-136 (first-version selection), :165-174 (CLI has no VERSION argument).
- Boot units: nvidia-kmod-load.sh:11-62 (flavor-only decision; positional lspci parse); nvidia-kmod-load.service (no After=, no input); nvidia-mps.service:4-7 and set-nvidia-clocks.service:2-6 (ordering); install-dcgm.sh:15-24.
- Docs and tests: README.md:74-107; MACIS archived_kmods_test.go (3 hard-coded names; GPU tests only on g4dn/g5; no reboot test); MadisonGithubUtils ssm-publish-value.jq (no driver field).
- No change needed: agent_capability_unix.go:115-127.

- (g) INFEASIBLE COMBINATIONS (reasons in the verified facts).
- Native dnf side-by-side of 580 and 595 (TOP-2).
- A single branch at 595 for the whole AMI: G3/P3/P3dn are legacy, G6f/Gr6f cannot run GRID 20 against a vGPU 19 host, and 595 has no successor PB.
- Mixing one branch's kmod with the other's userspace: NVML version mismatch and an ecs.service loop.
- A symlink farm of both branches' .so in one ld search directory: glibc 2.34 ldconfig makes 595 win (_dl_cache_libcmp = -15) after every rpm transaction.
- A GRID flavor in the PB tree: no consumer.
- A 595 proprietary flavor: no ECS consumer, since the proprietary allowlist devices are all legacy.
- A PCI policy that filters on kernelopen without checking legacybranch: sends G3/P3/P3dn to 595.
- Subsystem-exact matching against supported-gpus.json: entries are subsystem-qualified, and the G6f subsystems are absent.
- A customer override that selects PB on G3/P3/P3dn/G6f/Gr6f: must be rejected.
- An override read from ecs.config written by a user-data script, with the resolver ordered before cloud-final.
- EKS-style resolve-once with tree deletion, combined with stop/start family changes or GPU-baked custom AMIs.
- systemd-sysext combined with customer or agent dnf use (read-only /usr).
- A boot-time RPM swap on every boot. It is feasible only on first boot or when the hardware identity changes.

- SAFETY / OPS NOTE (MEASURED-EARLIER-SESSION artifacts; no action taken by me).
- /tmp/nvpoc/ec2/ shows that an earlier session launched EC2 instance i-0fee34c3053724e48 in us-west-2 with poc-launch.sh. It is tagged Project=nvidia-version-poc and Owner=dhsaran, has an 80 GB gp3 root, and uses the packer-ssm-builder profile.
- Its user-data sets a 240-minute self-shutdown with instance-initiated-shutdown-behavior=terminate. The instance clock read about 19:13 UTC at 12:13 PDT.
- It is expected to self-terminate around 16:13 PDT on 2026-09-28. AWS credentials are expired, so I could not and did not check it or change it.
- The user should confirm it has terminated (poc-terminate.sh refuses untagged IDs).

## Candidate solutions

### MECHANISM M1: separate AMI per branch (e.g. existing al2023gpu = LTS 580 with 3 flavors; new al2023gpu-pb = 595 open-only)

Parameterize today's recipe by major and publish a second GPU AMI variant and SSM namespace.
- Each AMI is a native dnf install of one version, with kmod-util and boot logic as today, fixed for the rc=8 and dracut issues.
- The PB AMI builds only kmod-nvidia-open-dkms and skips the GRID gate.
- Each AMI's nvidia-kmod-load refuses hardware it cannot serve and says so: the PB AMI refuses G3/P3/P3dn/G6f/Gr6f, and the LTS AMI flags G7.
- Customers pick the AMI per instance family through the SSM parameter.

**Pros**
- No new boot-path mechanism. rpmdb, versionlock, scriptlets, file triggers, ldconfig, udev and modprobe.d all stay native (none of the w1-C27/C33 emulation gaps).
- Release detection keeps working per AMI; check-update-security.sh needs only a per-major loop.
- The PB AMI is GRID-free, so it avoids the 3-partition GRID lag (up to 71 days) and the cn-north-1 grid-20.0 gap.
- Smallest recipe delta: about 150-250 lines, with public precedents al2023neu and al2kernel5dot10gpu (w4-C33/C35).
- Zero extra disk per AMI, and no first-boot resolution cost.
- Failures stay isolated: a bad PB bump cannot break LTS instances.

**Cons**
- Customers running mixed families (g6 + g7) in one ASG or capacity provider need two launch templates. ECS's per-family selection moves onto the customer.
- Wide internal plumbing: UGShinkansenLpt variant list and ADC map, about 8 MadisonGithubUtils scripts (SSM_AMI_TYPE, name patterns), MACIS data.go/tests, MadisonHuckleberry, ECSAgentRegionInfoPythonUtils, docs in all locales, and a new public SSM path (w4-C34). Per-region GPU builds, tests and publishes double.
- PB lifecycle churn: 595 goes EOL in March 2027, no successor PB exists yet, and the next LTSB is unannounced. The variant's name and SSM path must survive branch changes.
- G7 on the default (LTS) AMI stays silently unqualified unless a guard is added (w2-C28). 580 open may still bind (w2-C08), which makes the failure mode unclear.
- It does not fix the ALAS false-positive issue for the LTS AMI.
- Customers must learn a new AMI type. EKS explicitly declined per-driver AMI variants (#2417).

### MECHANISM M2: co-resident trees + overlay mounts (EKS parity, amazon-eks-ami be7adc2e/607e8be4)

Port EKS nearly as-is, renaming /etc/eks and /var/lib/eks.
- Build: both closures via dnf --downloadonly. dnf-install the shared set (about 204-207 packages). rpm2cpio the version-specific packages into /opt/nvidia/{lts,pb}. Harvest per-flavor .ko (PB open-only). GRID via make -C kernel-open plus 3 gridd files.
- Boot: a resolver (DMI and PCI, offline) selects a tree. Overlay /usr/{bin,lib64,share} with upperdir. A setup unit copies /etc, .ko and firmware, runs depmod and modprobe, installs units, and runs ldconfig. rpm --justdb registers the selected RPMs. A versionlock is written for the selected NEVRAs.
- ECS additions: install the version-invariant /usr/lib/{modprobe.d,udev/rules.d,dracut,systemd} and /usr/sbin files on the host; handle the 6 uncovered switch paths and fabricmanager.cfg; order before ecs.service.
- Variant M2b: keep LTS natively dnf-installed and overlay only a PB tree when PB is selected. LTS hosts then stay identical to today, but on PB hosts the rpmdb says 580, and 580-only files leak through the lower layer.

**Pros**
- Proven in production at EKS since v20260917. The build and boot code, validate.sh checks and resolver skeleton are reusable almost verbatim. Offline, and no network or IMDS needed (DMI).
- One AMI and one SSM path: no internal pipeline variant or new namespace.
- Removes nvidia-installer, the DKMS renames, the boot-time DKMS/ldtarball rc=8 path and the first-boot dracut run (TOP-3).
- Covers 71 of the 77 switch paths. The scriptlet surface is small and identical for 580/595 (w1-C30/C31), so emulation is bounded and CI-diffable.
- Customers can move between LTS and PB instance families without changing AMI.

**Cons**
- Disk: about 0.95 GiB for an open-only PB tree, 1.13-1.16 GiB for a 3-flavor tree, plus 0.3 GiB if .rpm files are kept for --justdb (header-only RPMs untested). EKS measured about 1.4-1.5 GiB per tree including RPMs.
- The emulation gap is real. EKS shipped the #2834 ldconfig regression. modprobe.d/nvidia.conf, 60-nvidia.rules, the powerd/suspend units and the persistenced user all have to be handled deliberately.
- rpmdb is faked with --justdb --nodeps (GRID nodes have no nvidia-kmod provider). A versionlock written at boot must reproduce the obsoleter exclusion. Release detection breaks and aborts the whole InitiateRelease job (w4-C39).
- Harvested .ko exist for the build kernel only, so any kernel change fails hard (EKS C39). ECS today can at least rebuild from DKMS sources.
- Resolve-once with tree deletion breaks stop/start family changes and GPU-baked custom AMIs. Keeping both trees avoids that but costs disk.
- Only one overlay per path, so customer or custom-AMI overlays on /usr/lib64 conflict. Boot time is unmeasured (#2811 acknowledges a regression). SELinux relabel is needed if it is ever enforcing.
- Large change: EKS was +1245/-591 lines over 23 files. MACIS and release notes still need changes.

### MECHANISM M3: co-resident trees in per-version directories selected by /etc/ld.so.conf.d + fixed symlinks (no overlays)

Unpack each branch's version-specific payload into /opt/nvidia/<ver>/, which is never on a default search path.
- At boot, point /opt/nvidia/current (a symlink) at the chosen version.
- /etc/ld.so.conf.d/nvidia.conf lists /opt/nvidia/current/usr/lib64 and its subdirectories. Run ldconfig.
- Create about 30 fixed symlinks for absolute-path consumers (Vulkan and VulkanSC ICD targets, nvidia_layers.json, gbm, xorg modules, vdpau) and for the 14 /usr/bin binaries.
- Put the version-invariant host files natively on the host. Copy .ko and firmware and run depmod as in EKS. Register with rpm --justdb and write the versionlock at boot.
- Hybrid option: LTS native in /usr, and PB only in /opt, activated by ld.so.conf.d plus symlinks.

**Pros**
- No overlay mounts: no mount-ordering cycle, no upperdir, no conflict with customer overlays.
- Avoids the ldconfig newest-wins hazard (w1-C28), because only one version's .so files are ever in a search directory.
- Switching is a symlink flip plus ldconfig plus a module reload, so re-resolving on every boot or on PCI-identity change is cheap if both trees are kept. This supports stop/start family changes.
- Makes the full switch set explicit, which aids auditing and CI diffing of the 77 paths.

**Cons**
- Unproven (INFERRED). NVIDIA Container Toolkit JIT-CDI and libnvidia-container library discovery from non-/usr/lib64 paths must be verified. ctk >= 1.20 searches /usr/lib64 before ldcache (w3-C22).
- Unowned or justdb-registered symlinks in /usr/lib64 and /usr/bin: rpm -V noise, and a later native dnf install of any nvidia-driver* would clobber them.
- It inherits all of M2's rpmdb, versionlock, release-detection, kernel-coupling and scriptlet-emulation issues.
- More bespoke than M2, with no production precedent. Each future NVIDIA branch can add absolute-path consumers (for example the implicit-layer file) that need new symlinks.

### MECHANISM M4: native LTS install + PB as an offline local RPM repo swapped in at first boot (only on PB hardware)

Build today's native 580 AMI with all 3 flavors. Additionally stage the 16 PB runtime RPMs (about 304 MiB), plus prebuilt 595 open .ko (about 25 MiB stripped) or a locally built kmod RPM that provides nvidia-kmod = 3:595 without a %post compile, in /opt/ecs/nvidia/595 with repo metadata.
- On first boot, only if the resolver selects PB (G7 today), run an offline transaction before persistenced and ecs.service: dnf with --disablerepo='*' --repofrompath, or rpm -Uvh as in the neuron-inf1-downgrade precedent. Then place the .ko, run depmod and modprobe, and rewrite the versionlock to 595 NEVRAs.
- Swap back if the hardware identity changes.

**Pros**
- rpmdb is truthful and scriptlets and file triggers run natively (ldconfig, systemd, udev, persistenced user), so there is no emulation gap. Customer 'dnf install cuda-*' resolves correctly (w1-C38).
- Release detection is unchanged: the LTS version is in the rpmdb on non-GPU hosts. LTS instances (all families except G7) boot exactly as today.
- Smallest co-resident disk cost: about 0.33 GiB staged (vs about 0.95-1.2 GiB for trees).
- An in-repo precedent exists (al2023neu neuron-inf1-downgrade, Before=cloud-init/ecs). One AMI, no plumbing changes.

**Cons**
- Boot-time rpm transaction on PB hardware: about 1.18 GB installed payload, unmeasured. Reading the staged RPMs from a lazily-loaded EBS snapshot on first boot may be slow (INFERRED).
- Must be strictly offline-safe (#602: a scriptlet hung for 5 minutes without internet). nvidia-kmod-common %post runs nvidia-boot-update, which calls grub2-mkconfig. The kmod-nvidia-open-dkms %post would DKMS-compile at boot, so the kmod RPM needs repackaging, --justdb or --noscripts, and some emulation comes back.
- Swapping back on stop/start family change is a second transaction. dkms autoinstall and a stale udev-loaded .ko must be neutralized (TOP-3).
- Versionlock rewrite at boot must keep the obsoleter protection (nvidia-fabric-manager-570.211.01). A mutating-rpmdb boot path needs new MACIS coverage.
- The ALAS false-positive issue on LTS hosts is unchanged.

### MECHANISM M5: single-branch policy (M5a: stay LTS-only; M5b: bump whole AMI to 595)

M5a: keep the single 580 AMI and declare G7 unsupported until an LTSB lists 0x2C3A (next LTSB unannounced; mid/late 2027 INFERRED). Add a boot guard that logs or fails loudly on G7, and optionally document a customer self-build path (the recipe variables nvidia_driver_major_al2023 and NVIDIA_DRIVER_VERSION already exist).
M5b: move the only AMI to 595.

**Pros**
- M5a: zero new mechanism and zero risk to existing fleets. Engineering effort can go to the baseline bugs instead (rc=8, dracut, autoinstall, lspci parse, G6f pin).
- M5a: CUDA 13.2 containers still run on 580 via minor-version compatibility (w2-C20), so the only hard gap is G7 hardware enablement.

**Cons**
- M5a: G7 (GA 2026-06-18) stays unsupported on the ECS GPU AMI for about a year or more. NVIDIA listed 0x2C3A once, in desktop 580.142, then withdrew it, so an R580 point release is unlikely to add it.
- M5a: the self-build path is awkward. check-update-security, GRID gating and the pin all assume 580, and a 595 self-build would also try to build 595 proprietary and GRID-20.
- M5b is INFEASIBLE as a single AMI: G3/P3/P3dn have no 595 support (legacybranch 580), G6f/Gr6f cannot run GRID 20 against a vGPU 19 host, and 595 goes EOL in March 2027 with no successor PB. It is feasible only if those families are dropped or split into a legacy AMI, which is M1 with the roles reversed.

### MECHANISM M6 (found in synthesis, likely rejected): systemd-sysext image per branch

Package each branch's version-specific /usr payload as a system-extension image under /var/lib/extensions (with a matching extension-release file). At boot, enable exactly one image; systemd-sysext.service merges it over /usr as a read-only overlay. MEASURED: AL2023 systemd-252.23-12 ships /usr/bin/systemd-sysext and systemd-sysext.service, which has DefaultDependencies=no, After=local-fs.target and Before=sysinit.target.

**Pros**
- A native systemd mechanism already shipped in AL2023. It covers all of /usr, including lib/modprobe.d, udev rules, systemd units and sbin, which closes the 6 + 19 path gaps of the EKS overlays. The merge is atomic and ordered very early in boot.

**Cons**
- DOCUMENTED in AL2023's systemd-sysext(8): 'the host /usr/ and /opt/ hierarchies become read-only too while they are activated'. Any dnf install or update touching /usr (customer user data, ecs-init updates, security patching) fails while merged. That effectively disqualifies it for a general-purpose ECS host.
- /etc is not covered (confext needs systemd >= 254). ID and VERSION_ID matching must follow AL2023 releases. ldconfig, rpmdb and versionlock issues remain. Unproven on AL2023.

### POLICY R1: instance-type table (DMI /sys/devices/virtual/dmi/id/product_name, offline)

Use a reviewed map from instance family to (branch, flavor). Example: g7 -> 595/open; g6f and gr6f -> 580/grid; g3, p3 and p3dn -> 580/proprietary; everything else -> 580/open. Optionally encode EKS's rule forcing g4dn and g5 to 580 proprietary with GSP off.

**Pros**
- Simple, deterministic, reviewable and offline. It mirrors AWS's per-family minimum-driver documentation.
- It classifies G6f/Gr6f at family level, which is robust to vGPU profiles beyond the 3 allow-listed subsystem IDs (32 exist).

**Cons**
- Every new family needs a table change, or it takes the default. The table can go stale silently.
- It ignores device-level facts such as dual device IDs. EKS's own design doc claimed this policy while the code used PCI lists (w3-C28).

### POLICY R2: PCI device-ID lists generated at build from each shipped version's supported-gpus.json (EKS ordering LTS-open -> PB-open -> LTS-proprietary + GRID override)

At build, extract supported-gpus.json for each exact driver version. It is available cheaply from the 59 KB noarch nvidia-driver-assistant RPM. Emit per-branch device-ID lists after excluding legacybranch entries. At boot, match lspci device IDs only, ignoring subsystem, except for the GRID tuples.

**Pros**
- Tracks NVIDIA qualification automatically. Devices added inside a branch are picked up, e.g. 0x3182 in 580.82.07.
- For today's families the result equals R1: only G7 reaches PB.

**Cons**
- Pitfall: every 590+ JSON rewrites the features of all 305 legacy-580 entries to exactly ['kernelopen']. A naive filter yields 455 device IDs instead of 293 and routes G3/P3/P3dn to 595 (EKS ffc658f8). Even nvidia-driver-assistant --json-hints gets this wrong.
- The fallback to LTS-proprietary for unknown devices is silent. The JSON is not refreshed every release, and entries are subsystem-qualified. It does not encode GRID (the G6f subsystems are absent) or GSP rules. EKS's lists are already stale.

### POLICY R3: explicit reviewed PCI-ID -> (branch, flavor) map, cross-checked in CI against supported-gpus.json

Check in a map keyed by device ID, plus GRID subsystem tuples, plus optional family rules. The build fails if any mapped device is not current and legacy-free in the target branch's JSON, or if a mapped flavor is unsupported (for example proprietary on Blackwell). Unknown devices get an explicit, logged default, or the boot fails loudly.

**Pros**
- Combines R1's reviewability with device precision and R2's automatic validation. It would have caught the ffc658f8 class of bug at build time.
- Explicit GRID and GSP rules and explicit unknown-device behavior. Easy to unit-test offline, as EKS's resolver harness showed.

**Cons**
- Needs manual maintenance and real lspci ground truth for every family (the G7, Gr6f, P5e and P6 IDs are INFERRED today).
- The unknown-device default is a product decision: LTS-open, which is today's ECS behavior, or refuse.

### POLICY R4: customer override (e.g. ECS_NVIDIA_DRIVER_BRANCH=lts|pb or an explicit version)

Let the customer pick the branch at launch. Surface options, in order of ordering cost:
- cloud-config write_files/bootcmd (cloud-init.service; resolver After=cloud-init.service);
- /etc/ecs/ecs.config written by a user-data script (resolver After=cloud-final.service);
- IMDS instance tags (needs InstanceMetadataTags=enabled);
- DescribeTags or SSM (network plus IAM; the managed ECS role lacks ssm:GetParameter).
Applies only to single-AMI mechanisms (M2/M3/M4). In M1 the override is simply the choice of AMI.

**Pros**
- Lets customers who need PB features (e.g. JIT of CUDA 13.2 PTX, newer driver-only APIs) opt in on families both branches support.
- ecs.capability.gpu-driver-version already lets schedulers see the outcome.

**Cons**
- The support matrix grows, and invalid combinations (PB on G3/P3/P3dn/G6f/Gr6f) must be rejected. EKS declined overrides (#2417).
- The ecs.config surface serializes the driver load after cloud-final and breaks GPU use in user data. Overrides interact badly with resolve-once and tree-deletion semantics.
- Each extra surface is a new public contract and a new test matrix.

### POLICY R5: default preference (LTS-first vs PB-when-supported)

LTS-first: pick PB only when the LTS branch cannot drive every attached GPU (EKS behavior; today only G7). PB-when-supported: prefer PB on every family both branches support.

**Pros**
- LTS-first: 3-year support, maximum fleet stability, only the G7 minority takes the PB path. It matches EKS, so behavior is consistent across AWS container AMIs.
- LTS-first: security fixes are co-released on both lines, so there is no security penalty (w2-C24). CUDA 13.2 containers run on 580 via minor-version compatibility.

**Cons**
- LTS-first: LTS hosts keep the ALAS false positives, because ALAS names PB fixed versions (TOP-5).
- PB-when-supported: forces yearly major migrations across the whole fleet (595 EOL March 2027, no successor PB), new-branch regressions, and GRID/legacy exceptions anyway.

### POLICY R6: commit semantics (resolve-once + delete other tree vs re-resolve on hardware-identity change vs every boot)

Resolve-once: the EKS sentinel plus deletion of the other tree. Re-resolve on change: persist the PCI and DMI identity and re-run selection only when it differs. Every boot: always re-run selection. All require an idempotent loader.

**Pros**
- Resolve-once reclaims about 1-1.7 GB after first boot and has the simplest steady state.
- Re-resolve on change supports stop/start family changes (ECS already attempts per-boot flavor switching today) and GPU-baked custom AMIs, while costing nothing on normal reboots.

**Cons**
- Resolve-once breaks stop/start family changes and custom AMIs baked on GPU instances. A g6-baked AMI on g7 keeps 580 (w3-C14). An interrupted background rm leaves junk forever.
- Re-resolve needs both trees or packages retained, an idempotent kmod path (kmod-util.v2-like) and stale-udev-.ko handling (w4-C21/C23). With M4 each change costs an rpm transaction.

## Remaining POC needs

- P1 [GPU: g5.xlarge or g6.xlarge; current ECS AL2023 GPU AMI] Baseline reboot idempotency and first-boot cost. Steps: launch; after boot run 'systemctl status nvidia-kmod-load', 'journalctl -b -u nvidia-kmod-load -o short-monotonic' (time ldtarball, install and dracut separately), 'systemd-analyze blame' and 'systemd-analyze critical-chain ecs.service', 'nvidia-smi', 'cat /proc/driver/nvidia/params', 'lsmod | grep nvidia', 'systemctl is-active nvidia-powerd', and 'curl localhost:51678/v1/metadata'. Then 'sudo reboot' and repeat. Expected: first boot active (exited) with dracut visible in the journal; after reboot the unit is failed with status=8 and 'nvidia/580.178.04 is already added! Aborting.', while nvidia-smi still works via udev autoload and the agent registers ecs.capability.gpu-driver-version=580.178.04. Also record whether nvidia-powerd fails (EKS doc says it does).

- P2 [GPU: g7 smallest size; current AMI, then 595] Ground truth for the only PB consumer. Steps: 'lspci -nn -d 10de:' and 'lspci -vmm -nn -d 10de:' (expected 10de:2c3a, subsystem 10de:21f4); on the current 580 AMI capture 'dmesg | grep -iE "nvrm|nvidia"', 'nvidia-smi', 'journalctl -u ecs'. Expected outcomes are RmInitAdapter failure or 'No devices were found' (then ecs-init NVML fails and ecs.service loops), or it works unqualified (w2-C08). Then install 595.91.07 natively, or via the M2/M4 prototype, and run 'docker run --rm --runtime nvidia -e NVIDIA_VISIBLE_DEVICES=all nvidia/cuda:13.2.0-base-amzn2023 nvidia-smi'. Expected: works and reports 595.91.07.

- P3 [GPU: g6f.large, g6f.2xlarge, g6f.4xlarge, gr6f.4xlarge] GRID pin decision. Steps: 'lspci -nn -vmm -d 10de:' (expected 27b8 with subsystems 1733/1735/1737; gr6f.4xlarge 1737); on the current AMI (GRID 19.6) run 'nvidia-smi -q | grep -iA3 licens' and 'systemctl status nvidia-gridd'. Expected: Licensed, as EKS measured. Repeat with a 580.159.03 (GRID 19.5) build and with the GRID 20.2 runfile (595.91.07). Expected: 19.5 and 19.6 work; 20.2 fails to initialize or license (vGPU 19 host). Ask EC2 for the host vGPU Manager version.

- P4 [Linux builder: AL2023 c5.4xlarge, no GPU] Real closures and build-time baseline. Steps: 'dnf install --downloadonly --setopt=install_weak_deps=True --downloaddir=/tmp/c580 <exact roots incl. libibumad infiniband-diags nvlsm>-580.178.04' and the same for 595.91.07; diff basenames. Expected: 18 version-specific per version; shared about 207 on the w1 baseline, or the GPU delta of about 218 on a sequential baseline. Then time today's full install-nvidia-driver.sh with 'time', and again with /etc/dkms/framework.conf.d/zz-nodracut.conf containing post_transaction="". Expected: about 10 fewer dracut runs; quantify the minutes saved. Also measure dkms-default 'strip -g' .ko sizes for 595 open, proprietary and GRID (the earlier session measured 25/107/25 MiB after --strip-unneeded).

- P5 [Linux: AL2023 container or instance, no GPU] rpmdb registration and lock semantics. Steps: (a) build header-only RPM files (lead, signature and header bytes from <rpm:header-range>), then 'rpm -i --justdb --noscripts --nodeps --nodigest --nosignature *.rpm'. Expected: success, or an explicit payload error; this decides whether 0.10 MB replaces 304 MiB. (b) On a justdb-registered 580 set, run 'dnf versionlock add nvidia* libnvidia* kmod-nvidia*' after registration, then 'dnf upgrade --assumeno' and 'dnf install --assumeno cuda-runtime-13-0 nvidia-imex'. Expected: no driver upgrade, the lock pins imex to 580, and the obsoleter nvidia-fabric-manager-570 stays excluded. (c) Register a GRID-style set with no nvidia-kmod provider and run 'dnf check' and 'dnf install --assumeno cuda-runtime-13-0'. Expected: an unsatisfied nvidia-kmod dependency surfaces.

- P6 [GPU: g5 (LTS) and g7 (PB); prototype M2, EKS parity port] Measure:
- AMI size delta ('df -BM /').
- First-boot and reboot 'systemd-analyze critical-chain ecs.service' (resolve, mounts, setup, ldconfig).
- 'ldconfig -p | grep libnvidia-ml.so.1' pointing at the selected version.
- ecs-init NVML success and the agent attribute.
- In /var/log/ecs/nvidia-container-runtime.log, confirm the runtime mode resolves to jit-cdi, and that the CUDA container from P2 runs.
- /dev/nvidia-uvm and nvidia-drm presence, and /proc/driver/nvidia/params, with and without /usr/lib/modprobe.d/nvidia.conf and 60-nvidia.rules. Expected: PreserveVideoMemoryAllocations and softdep loading differ.
- The docker start delay caused by nvidia-cdi-refresh (drop-in TimeoutStartSec=90s in toolkit 1.20.x; check whether 1.19.1 has it).

- P7 [GPU: g5 and g7; prototype M3] Steps: build /opt/nvidia/{580,595}, add /etc/ld.so.conf.d/nvidia.conf -> /opt/nvidia/current/usr/lib64, and create the symlink set; flip and run ldconfig. Verify:
- 'ldconfig -p | grep libcuda.so.1' resolves into /opt.
- 'nvidia-ctk cdi generate --mode=nvml' lists /opt paths, and JIT-CDI containers get the right libraries.
- Vulkan ICD resolution ('vulkaninfo --summary' if installed).
- The time to re-resolve (flip, ldconfig, modprobe -r/modprobe) is under N seconds.
Expected risk point: toolkit library discovery outside /usr/lib64.

- P8 [GPU: g7; prototype M4 offline swap] Steps: stage the 16 PB runtime RPMs and a prebuilt 595 open .ko (or a repackaged kmod RPM). Block egress (no route to S3 or repos). On first boot time the 'rpm -Uvh' or 'dnf --disablerepo=* --repofrompath' transaction, check journalctl for scriptlet stalls (nvidia-boot-update calling grub2-mkconfig), confirm the ldconfig trigger fired ('ldconfig -p') and that the versionlock was rewritten, and confirm ecs registers 595.91.07. Then stop/start to g6 and time the swap back. Expected: completes offline with no hang; wall time to be established.

- P9 [GPU: stop/start family change on the current AMI: g5.xlarge -> p3.2xlarge -> g5.xlarge] Validate harness S6. Expected: on p3 the proprietary install succeeds. Back on g5: kmod-util ldtarball rc=8, both DKMS names installed, and '/proc/driver/nvidia/version' or 'modinfo nvidia | grep -i license' shows the proprietary module loaded on g5. This decides how much of the switching logic must be rewritten regardless of mechanism.

- P10 [GPU: one of each: g4dn, g5, g6, g6e, g7e, p4d, p5, p5e, p6-b200, p6-b300] Run 'lspci -nn -vmm -d 10de:' to replace the INFERRED device-ID mapping with ground truth (expected 1EB8, 2237, 27B8, 26B9, 2BB5, 20B0, 2330, 2335, 2901, 3182). Also run 'lspci -n -mm -d 10de:' raw to check whether any GPU prints -rXX/-pXX fields that shift the $4:$7 parse. Confirm pciutils 3.7.0 with 'rpm -q pciutils'.

- P11 [GPU: g4dn and g5] EKS GSP-off rule. Run the same CUDA workload and 'nvidia-smi -q -d PERFORMANCE' under 580 open (GSP on, ECS today) and under 580 proprietary with 'options nvidia NVreg_EnableGpuFirmware=0' (EKS). Look for the issue EKS works around (init latency, Xid errors, hangs). Expected: either a justification for ECS's divergence or a reason to adopt EKS's rule.

- P12 [GPU: g5 + g7 with DCGM] Install datacenter-gpu-manager-4-core 4.6.1 with the nv-hostengine override from install-dcgm.sh. Run 'dcgmi discovery -l' and 'dcgmi diag -r 1' on 580 (g5) and 595 (g7). Also start nvidia-mps and run an MPS task on 595. Expected: both work. DCGM has no driver dependency, but runtime compatibility is unverified.

- P13 [ECS cluster with credentials] Register a g5 and a g7 instance. Run a task with the placement constraint memberOf(attribute:ecs.capability.gpu-driver-version =~ 595\\..*). Expected: it lands only on g7. Confirms w4-C27 (untested).

- P14 [any GPU instance on 580.178.04] Run an Amazon Inspector (or Qualys) scan. Expected: findings for ALAS2023NVIDIA-2026-292/293/294 (fixed-in 595.71.05), even though NVIDIA's CVE records list 580.159.03 as fixed. Confirms the false-positive mechanism (TOP-5) for the AL team.

- P15 [GPU: g7 and g5] Kernel-change resilience for whichever kmod model is chosen. Unlock and install a newer AL2023 kernel, reboot, and observe: dkms kernel_postinst (40-dkms.install) behavior with one vs two registered nvidia* names, and whether the chosen mechanism rebuilds or hard-fails (EKS harvest: setup exits 1). Expected: DKMS-source models rebuild; harvested-.ko models fail.

## Open questions

- Product scope: is G7 the only family the PB path must serve (the evidence says yes today)? Is an opt-in PB for families both branches support (a customer override) in scope, given EKS declined it (#2417)?
- Mechanism appetite: a separate AMI variant (low boot risk; internal plumbing across ~6 packages and a new SSM namespace) or one AMI with co-resident branches (boot-path complexity; no new namespace)? Who owns the UGShinkansenLpt, MadisonGithubUtils, MACIS and Huckleberry changes?
- G6f/Gr6f GRID: pin GRID 19.5 (580.159.03), which is a third driver version, per the EC2 doc's '18.4 to 19.5' range? Or keep 19.6 (580.178.04), which EKS measured as Licensed, and get EC2 to update the doc? Also ask EC2 which vGPU Manager the G6f hosts run and when they will move to vGPU 20 or the next LTSB (vGPU 19 EOL July 2028).
- Commit semantics: must the AMI support stop/start instance-type changes across branch or flavor (g6 to g7), and custom AMIs baked on GPU instances? That decides resolve-once (EKS) vs re-resolve on hardware-identity change, and whether both trees or packages stay on disk.
- Customer override contract: if offered, which surface? cloud-config write_files is cheap; ecs.config is familiar but forces After=cloud-final. Will ECS document ecs.capability.gpu-driver-version as a supported placement attribute?
- PB lifecycle: R595 goes EOL in March 2027. It will not become an LTSB, and no successor PB exists yet (610 and 615 are NFBs). What is the policy if the PB goes EOL before an LTSB lists 0x2C3A: move to the next PB, or fold G7 into the next LTSB? How often is a PB migration budgeted?
- Security reporting: ALAS publishes one fixed-in version per advisory (the May-2026 CVEs are listed as fixed only in 595.71.05), so LTS hosts show scanner false positives today (AutoDubs on ECS, ShakespeareMLCDK on EKS). Will the AL team publish per-branch advisories, or does ECS document the exception?
- Should the pre-existing baseline defects be fixed first, as a separate change? They are: the nvidia-kmod-load rc=8 on every reboot, the synchronous first-boot dracut, dkms.service autoinstall, the positional lspci -mm parse, the latest/ prefix match on the GRID key, the imex/nscq versionlock gap, and presets that enable nvidia-powerd and the suspend units.
- g4dn/g5: should ECS adopt EKS's forced LTS-proprietary with NVreg_EnableGpuFirmware=0 (in place since 2024-08), or keep open with GSP on? What is the original EKS issue? Note that proprietary RPMs disappear from 615 onward.
- Kernel coupling: keep DKMS sources so modules can rebuild after a kernel change (today's resilience, more disk), or harvest .ko only as EKS does (hard failure on kernel change)? Kernel packages are versionlocked, but customers can unlock them.
- Footprint: can nvidia-settings (131 core packages) and xorg-x11-server-Xorg / xorg-x11-nvidia (163 of 196 core packages together) be dropped from a headless ECS AMI? That shrinks every design and reduces the lock list.
- Release engineering: how should two branches be detected and gated? Options are per-branch repo plus GRID intersection, or no GRID gate for PB (cn-north-1 lacks 595.58.03). What release-notes format and SSM value fields should be used? The detector must not read the released AMI's rpmdb on a non-GPU host.
- CI capacity: can MACIS and Huckleberry obtain g7, p3/p3dn, g3 and g6f/gr6f capacity for per-branch and per-flavor tests plus a reboot test? Today al2023gpu is tested only on g4dn and g5, which exercises only the open flavor.
- DCGM: dcgm-init exists only on ecs-agent feature/gpu-metrics, so DCGM is skipped in today's AMI. Will DCGM ship before or with this project, and must it be validated on both branches? Upstream DCGM 4.7.0 splits into about 12 new subpackages that AL2023 does not yet mirror.
- Operations: an earlier session launched POC instance i-0fee34c3053724e48 (us-west-2, tagged Project=nvidia-version-poc) with a 240-minute self-terminate TTL. Please confirm it has terminated. I could not check because credentials are expired.
- Harness: subagents cannot write REPORT.md or PHASE1-FINDINGS.md. Should the orchestrator, or the user's main session, render this structured output into the design-doc findings file?
