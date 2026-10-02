# Dynamic NVIDIA Driver Selection — Benchmark Handoff Summary

Current state of the Option A vs Option B benchmarking effort, written so another
assistant can continue cold. Plain prose, no raw logs. Account 974813605996,
region us-west-2, branch `dynamic-driver`.

## What Option A and Option B are

Both are AL2023 ECS GPU AMIs that carry TWO NVIDIA driver branches (LTS 580.178.04
and Production Branch 595.91.07) and select one at boot by hardware, so a single
AMI serves both PB-required GPUs (e.g. G7, PCI 10de:2c3a) and LTS GPUs (e.g. G4dn).

- **Option A** — native LTS install + offline-staged PB. `install-nvidia-driver.sh`
  installs 580 natively (all three kmod flavors). `stage-nvidia-pb.sh` stages the PB
  595 closure and a reverse-swap LTS set under `/opt/ecs/nvidia/<ver>/` as
  createrepo'd repos. At boot `nvidia-driver-select.service` resolves BY PCI DEVICE
  ID and, on a PB GPU, swaps to 595 via a real dnf transaction (gpgcheck on).
- **Option B** — EKS-parity co-resident trees + overlays. `stage-nvidia-optionb.sh`
  builds two self-contained per-branch trees under `/opt/nvidia/{lts,pb}` (shared
  base installed natively; version-specific RPMs unpacked into the tree + kept in
  `.rpms/`; all 3 kmod flavors harvested). At boot `nvidia-driver-resolve` picks the
  branch BY INSTANCE TYPE (EKS mechanism), points `/opt/nvidia/current` at the tree,
  three overlay mounts layer the tree's `/usr/{bin,lib64,share}` over the host, and
  `nvidia-setup` copies modules+firmware, modprobes, and registers the RPMs with
  `rpm -i --justdb` (rpmdb reports installed though scriptlets never ran).

This is a reimplementation of the mechanism the EKS design documents, applied to
ECS's recipe — not a copy of EKS code.

## Decision criteria (current)

Per the latest direction, evaluation is RAW NUMBERS ONLY, no recommendation for
either option. Ranked criteria: (1) picks the correct driver on every instance
type; (2) faster cold boot across the fleet; (3) smaller footprint.

## AMI IDs

- **Option A (benchmark baseline):** `ami-0ebdd539a09dfd9a8`
  (`unofficial-amzn2023-ami-ecs-gpu-hvm-2023.0.20261001bench-...`), built fresh on
  c5.large, staging verified. This is the A used in all results below.
- **Option B (original, DEFECTIVE on real G7):** `ami-07766cd3ddb8c2fca`
  (`...optionb-hvm-2023.0.20260922-...`). Missing GSP firmware at boot — see below.
- **Option B (c5.4xlarge rebuild with firmware fix):** `ami-0f196854245e015cd`
  (`...optionb-hvm-2023.0.20261002bench-...`). GPU works on G7. BUT its LTS tree is
  still 595-contaminated (see 28-vs-20). A further rebuild `20261002bench2` is
  pending to fix the LTS tree.

## Benchmark results so far (real hardware, g7.2xlarge, PCI 10de:2c3a)

All timings are seconds since KERNEL START, from systemd/journal timestamps.
"driver unit" = nvidia-driver-select (A) or nvidia-setup (B).

Option A — `ami-0ebdd539a09dfd9a8`:
- boot0 (cold):   driver unit 52.5s→107.6s; ecs.service start 111.0s;
                  nvidia-smi first 0.065s, warm median 0.062s.
- boot1 (reboot): driver unit 6.2s→6.4s;    ecs.service start 9.2s.
- boot2 (reboot): driver unit 5.6s→5.8s;    ecs.service start 8.5s.
- Driver ready BEFORE ecs.service on every boot. nvidia-smi 595.91.07 on
  0x2C3A10DE. rpm -Va nvidia* = 0.

Option B original `ami-07766cd3ddb8c2fca` — cold boot0: FAILED. Module loaded but
GSP firmware missing, so nvidia-smi "No devices were found" and ecs.service failed
(255 restart loop). Not a usable boot. (Root cause + fix below.)

Option B after live firmware hotfix (applied on the original AMI's instance, so
labeled "hotfix on ami-07766cd3ddb8c2fca"):
- boot1 (first good boot): nvidia-setup 6.7s→21.0s; ecs.service 23.6s. The ~16s is
  the one-time first successful GPU init (modprobe/RmInitAdapter).
- boot2 (reboot): nvidia-setup 6.9s→7.1s; ecs.service 9.3s.
- boot3 (reboot): nvidia-setup 8.1s→8.2s; ecs.service 10.7s.
- nvidia-smi first ~0.073s. 595.91.07 on 0x2C3A10DE, ecs active, 0 RmInitAdapter
  failures.

Option B firmware-fix rebuild `ami-0f196854245e015cd` — cold boot0:
- nvidia-driver-resolve 29.6s→30.0s; nvidia-setup 31.1s→88.2s; ecs.service 89.7s.
  nvidia-setup internal: depmod ~29s, modprobe/first-GPU-init ~21s, justdb ~8s
  (total 58s). nvidia-smi first 0.063s, warm median 0.062s. 595.91.07 on
  0x2C3A10DE, all three overlays mounted, GSP firmware present, ecs.service active.

nvidia-smi latency is ~0.06s warm on both options; it is not a differentiator.

Reboot path is a near-no-op for both (driver already committed to disk): A's
selector ~0.2s, B's setup ~0.2s. Cold boot carries the one-time cost in both: A
pays cold-EBS fault-in + the PB dnf swap; B pays depmod + first GPU init + justdb.

## Option A dnf5 staging verification result

The dnf5 hypothesis (that `install --downloadonly --downloaddir` silently fails on
dnf5) is REFUTED. On AL2023 the live `dnf --version` is 4.14.0 (not dnf5), measured
on the G7 host. The fresh Option A build log shows step 1 (--downloadonly
--downloaddir) rc=0, step 2 make-modules rc=0 (proves the dkms RPM landed in dl/),
manifests 595=17 / 580=16, and VALIDATION OK. On the live A host:
`ls /opt/ecs/nvidia/*/rpms | wc -l` = 35, and `rpm -K` on every staged RPM returned
"digests signatures OK". Option A staging is INTACT. Do not repeat the dnf5 claim.

## 28-vs-20 version-specific finding (Option B LTS-tree contamination)

PB tree manifest = 20 version-specific RPMs, all 595.91.07 (correct). LTS tree
manifest = 28, containing BOTH 580 and 595 copies of 8 names:
libnvidia-cfg, libnvidia-gpucomp, libnvidia-ml, nvidia-driver, nvidia-driver-libs,
nvidia-kmod-common, nvidia-modprobe, xorg-x11-nvidia. The name SET is identical to
PB (20 unique names); the extra 8 are 595 duplicates wrongly in the LTS tree.

Impact (confirmed on a no-GPU verifier of ami-0f196854245e015cd): unversioned
symlinks in the LTS tree resolve to the wrong version — libnvidia-ml.so.1 -> 595,
libnvidia-cfg.so.1 -> 595, nvidia-modprobe binary is 595, nvidia_drv.so is 595,
while the LTS kernel modules are 580. A real LTS-resolving host would get a
580 module + 595 NVML mismatch. This is latent on G7 (resolves to the clean PB
tree) and was invisible in the G7 benchmark.

Cause (evidence-backed): `dl_closure` in `stage-nvidia-optionb.sh` runs
`dnf download --resolve` with the roots pinned to the tree version but the nvidia
userspace inter-dependencies declared UNVERSIONED; with versionlock disabled,
--resolve satisfies those with the NEWEST provider (595), dropping 595 copies into
the LTS closure. The ~195 shared non-nvidia packages come from this same --resolve
output, so --resolve must be kept. The agreed fix (diff proposed, NOT yet applied):
after download, delete every RPM whose name is in VS_NAMES and whose version != the
tree version (logging each deletion = cause evidence), plus a strengthened
build-time guard in build_tree that requires each VS_NAMES name present exactly
once at VERSION=tree version (die on missing/duplicate/wrong, nullglob so an empty
dir cannot pass). Awaiting approval, then rebuild as 20261002bench2.

## Task status (original 9-item plan)

- Task 1 (map Option A flow): DONE (prior session).
- Tasks 2-4 (design/build Option B units + build the AMI): DONE
  (ami-07766cd3ddb8c2fca original; firmware-fix rebuild ami-0f196854245e015cd).
- Task 5 (rebuild Option A + dnf5 staging verification): DONE. A =
  ami-0ebdd539a09dfd9a8; staging intact; dnf5 hypothesis refuted.
- Task 6 (benchmark both on real G7): DONE for G7 (numbers above). The current
  (replacement) plan EXTENDS this to a 12-instance matrix across g7.2xlarge and
  g4dn.xlarge — NOT yet run.
- Task 7 (metrics incl. first-boot vs reboot): partially done for G7; the g4dn
  arm and the 3-fresh-instances-per-cell matrix are REMAINING.
- Task 8 (extensibility): NOT done (and the current scope says raw numbers only).
- Task 9 (writeup into design doc): NOT done; current scope says no doc edits
  beyond this handoff.

## Current (replacement) plan phases

- Phase 1: fix Option B LTS tree (code, no commit) — diff proposed, awaiting
  approval; then rebuild as 20261002bench2 and confirm LTS manifest = 20 entries
  all 580.178.04 and the new guard passed.
- Phase 2 (after new AMI approved): matrix. A = ami-0ebdd539a09dfd9a8, B = the
  Phase 1 AMI. Types g7.2xlarge (expect 595.91.07) and g4dn.xlarge (expect
  580.178.04). 3 fresh one-time-Spot instances per (AMI,type), each measured on
  first boot; reboot one of the three once and remeasure. 12 instances total, max
  2 running at once, re-vend before each launch, terminate after measure. Record
  correct-driver (csv match or FAIL), flavor (modinfo -F license nvidia; A and B
  must match on the same type), nvidia-smi exit code, driver-ready + ecs.service
  start from kernel start, pre-driver-unit time and driver-unit run time. Save full
  journal per boot under ~/bench-results/matrix/<ami>/<type>/<run>/. One table per
  instance type, every run listed, plus medians; flag FAILs at top.
- Phase 3 (no launch): per AMI, root volume size (describe-images), root snapshot
  FullSnapshotSizeInBytes (describe-snapshots), and df -h / plus
  du -sh /opt/ecs/nvidia /opt/nvidia captured on each AMI's first g4dn boot.

## Credential-cap workaround

Isengard Admin role caps sessions at ~60 min regardless of requested duration
(measured: a 720-min request yielded ~60 min). Re-vend fresh creds at the start of
each phase and immediately before every long step (build, each Spot launch, each
reboot cycle), and print the Expiration before starting Packer. Never design a run
that outlives one window. If Packer dies on expiry mid-snapshot, run describe-images
for the target AMI before rebuilding — the AMI usually registers anyway. (Note: one
earlier "creds expired mid-build" diagnosis was WRONG; that failure was the GRID
runfile extraction, see open issues.)

## Open issues / surprises

- Option B firmware bug (FIXED in code, uncommitted): `nvidia-setup.sh` copied
  firmware from `$CUR/lib/firmware`, but the GSP blobs live at
  `$CUR/usr/lib/firmware`. The fix points the copy at usr/lib/firmware and adds a
  version-pinned "no GSP firmware" loud die. This change is in the working tree,
  UNCOMMITTED, and is what ami-0f196854245e015cd was built from. sha256 of that
  file at build time: fac3e6f464c871a6750501e3dabd49b989463e4ad7e263a21308a0749745f0c1.
- nvidia-setup reports success even when the GPU is dead (it only checks the module
  loaded, not GPU health). Neither this port nor EKS probes nvidia-smi after setup.
- Build-time RAM/tmpfs trap: full-fidelity Option B must build on c5.4xlarge, NOT
  c5.large. AL2023 /tmp is a tmpfs at ~50% of RAM (~2 GiB on c5.large), too small to
  extract the GRID runfile; the GRID step fails with a generic "Extraction failed."
  c5.4xlarge (~16 GiB /tmp) succeeds.
- rpmdb is boot-path-dependent on Option B: on a no-GPU host, `rpm -q
  nvidia-driver-cuda` reports NOT installed and `rpm -Va nvidia*` is nonzero
  (justdb only runs when the GPU path commits), whereas Option A's rpmdb is baked at
  build time. (Flagged out of current scope but relevant to any rpm/dnf tooling.)
- ldconfig cache on Option B: `ldconfig -p | grep -c libcuda` = 0 on every B boot
  (even healthy ones) vs 5 on A — the overlay places the lib files but the ldconfig
  cache was not rebuilt for the overlaid /usr/lib64.
- Packer AMI-name collisions: build via direct `./packer build` with a CLI
  `-var "ami_version_al2023=<unique>"`. PKR_VAR_ env vars do NOT override
  *.auto.pkrvars.hcl (precedence: CLI -var > auto pkrvars > PKR_VAR_ env > default).
- Build networking: builds use the pre-existing BPA bidirectional exclusion on
  subnet-0ef864cac88a6bb45 (us-west-2d) with plain SSH; set `ulimit -n 8192` before
  Packer. Do not create/delete BPA exclusions.
- Bench-host SSH from the Cloud Desktop needed the SG opened to 0.0.0.0/0 on 22
  (a /32 of the desktop's reported IP did not match its real egress). The bench SG
  is sg-0813bca1510bfb449 and key pair bench-g7-20261002; both are to be deleted at
  the very end of the effort.
