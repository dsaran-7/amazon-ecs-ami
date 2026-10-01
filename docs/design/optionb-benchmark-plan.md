# Option B Build + Benchmark Plan — session handoff brief

**Purpose.** This file is a self-contained handoff so a fresh Kiro session (e.g. on the Cloud Desktop) can continue the work without the originating chat. Read this first, then `docs/design/dynamic-nvidia-driver-version-selection.md` and `scripts/al2023/gpu/`.

## Goal

Build a **full-fidelity Option B** (EKS-parity: co-resident mirror trees + overlay mounts + `rpm --justdb` registration) AL2023 ECS GPU AMI, and **benchmark it head-to-head against Option A** (native LTS 580 + offline-staged PB 595 swapped at boot). Option A is already built/validated; this effort produces measured numbers to defend the Option-A recommendation (or revise it) instead of arguing from the design doc alone.

This is a **reimplementation of the mechanism the EKS doc describes, applied to ECS's recipe and design requirements** — not a copy of EKS's code (their scripts are not in this repo). Label the EKS comparison accordingly: we reproduce *the mechanism EKS documents*, not their exact implementation.

## Key decisions already made

- **Full fidelity** (not minimal). Build all three kernel-module flavors (open, proprietary, GRID) per version, and emulate the full scriptlet set the EKS doc lists for the ~20 version-specific packages. Rationale: a reduced build could skew the benchmark numbers.
- **Run on the Cloud Desktop** (`dev-dsk-dhsaran-2a-...us-west-2`), Isengard account **974813605996**, region **us-west-2**. The agent drives execution end-to-end (build + G7 launch + benchmark).
- **EKS resolves by instance type** (confirmed from the EKS doc); ECS Option A resolves by **PCI device ID**. Keep that distinction straight in any comparison.

## Metrics to compare (A vs B)

1. **Speed / time-to-driver-available** — uptime at which the NVIDIA driver is usable, first boot and reboot (no-op) paths.
2. **`nvidia-smi` execution latency** — wall time to run `nvidia-smi` once the driver is up.
3. **Driver ready BEFORE `ecs.service`** — confirm the driver is committed before ecs-init runs (ecs-init exits 255 / restart-loops without NVML). Capture the unit-start and ecs.service-start uptimes.
4. **Extensibility** (qualitative/architectural, label as judgment not measurement) — what it takes in each design to add a new driver branch, a new module flavor, or more userspace functionality on one AMI. Note Option B's overlay-path-count limit (71 of 77 switch paths per the EKS measurement) vs. Option A's staged-repo additions.
5. **dnf/yum error handling** — `dnf install` can fail (transaction error, checksum/gpg failure, disk-full, interrupted transaction). Both options' boot paths need explicit handling; capture and compare behavior under injected failures.

## Benchmark method (apples-to-apples)

- Same region, same instance types, same measurement harness for both AMIs.
- Rebuild Option A fresh (hardened recipe) so its numbers are directly comparable, rather than reusing the 2026-09-29/30 figures.
- Real G7 (`g7.2xlarge`, `10de:2c3a`) via **one-time Spot** (On-Demand G7 is capacity-gated / `InsufficientInstanceCapacity`).
- Capture first-boot (cold EBS) and reboot (warm, no-op) separately; note that Option A's cold first boot is dominated by lazy EBS snapshot loading (mitigated by a 4 MiB/32-parallel prefetch).

## Build-environment workarounds (REQUIRED on the desktop)

- `ulimit -n 8192` **before** any `make validate` / Packer build, or Packer fails with "too many open files".
- Account-level **VPC Block Public Access (BPA)** blocks public SSH to the Packer builder; create a BPA **allow-bidirectional exclusion** on the build subnet, and use **plain SSH** (recipe default — do NOT set `ssh_interface`; SSM Session Manager can't work: the AL2023 Minimal source AMI ships no ssm-agent).
- Build command shape: `REGION=us-west-2 PKR_VAR_subnet_id=<excluded-subnet> make al2023gpu` (and the new `al2023gpu-optionb` target once added).

## Task plan (9 items)

1. Map the Option A integration + boot flow so Option B mirrors repo conventions. **(DONE on the Mac — see below.)**
2. Design the Option B build: new source + recipe + `make al2023gpu-optionb` target + `stage-nvidia-optionb.sh` (split closure into shared [dnf-installed] vs version-specific [unpacked into `/opt/nvidia/{lts,pb}` mirror trees], build+harvest all 3 flavors' kmods, emulate scriptlets).
3. Write Option B boot units: `nvidia-driver-resolve` (instance-type) + `nvidia-setup` (3 overlay mounts over `/usr/{bin,lib64,share}`, copy `.ko`/firmware, `depmod`/`modprobe`, `rpm -i --justdb --noscripts` registration), ordered `Before=ecs.service` and the same consumers Option A orders before.
4. Add robust dnf/yum error handling to both boot paths; document failure modes.
5. Build the Option B AMI in us-west-2 (BPA + fd-limit workarounds).
6. Rebuild Option A fresh for the baseline.
7. Benchmark both on a real G7: driver-available time, `nvidia-smi` latency, driver-before-ecs ordering; first-boot vs reboot.
8. Evaluate extensibility of each approach.
9. Write up the comparison and fold findings into the design doc (`.md` and `.chorus.md`).

## What task 1 established (so the desktop doesn't redo it)

Option A integration in `al2023.pkr.hcl`: after the native install (`install-nvidia-driver.sh`) and `install-dcgm.sh`, three provisioner blocks (gated `only=["amazon-ebs.al2023gpu"]`) create `/tmp/nvidia-select`, upload the Option A assets, and run `stage-nvidia-pb.sh` with env `NVIDIA_DRIVER_PB_VERSION=${var.nvidia_driver_version_al2023_pb}`. The boot unit `nvidia-driver-select.service` is `After=cloud-init.service` and `Before=` nvidia-kmod-load / persistenced / fabricmanager / mps / set-nvidia-clocks / powerd / gridd / topologyd / cdi-refresh / dcgm / docker / **ecs** / cloud-final. Option B's units MUST order before the same set for a fair boot-before-ECS comparison. Native install builds+archives 3 flavors via `kmod-util` + DKMS; Option B instead harvests `.ko` per flavor into trees. `gen-device-lists.py` validates the device lists; the LTS flavor loader is `nvidia-kmod-load.sh` (GRID/proprietary/open by PCI subdevice).

## Status / artifacts so far

- Branch `dynamic-driver` on fork `https://github.com/dsaran-7/amazon-ecs-ami` (origin = upstream `aws/amazon-ecs-ami`, read-only for us).
- Option A validated AMIs (dev acct, us-west-2): `ami-025efa3c1e7460927` (2026-09-29), hardened `ami-0c7256dba826427c1` (2026-09-30).
- Raw POC logs (`docs/design/poc/raw/`) were intentionally NOT committed to this branch (bulk); they exist only on the Mac.
- The EKS source doc is `chorus.aws.dev/doc/oN8qVvlQpSti` — hand it to the desktop session for grounding the comparison (not in the repo).
