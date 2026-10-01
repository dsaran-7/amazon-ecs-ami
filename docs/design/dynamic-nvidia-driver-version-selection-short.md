# Dynamic NVIDIA Driver Version Selection (LTS + Production Branch) for AL2023 ECS GPU AMIs — Short Version

**[Status: DRAFT — for team review. This is a condensed version of the full design doc (`dynamic-nvidia-driver-version-selection.md`). Option A is built end-to-end into the Packer recipe (`make al2023gpu`) and validated on real G7 hardware 2026-09-29: an AMI baked from the production recipe auto-selects 595 on G7 at boot with no override and no customer config.]**

## TL;DR

- **Problem.** The AMI pins one NVIDIA driver (R580). G7 (`2c3a`, Blackwell) is not qualified on R580 — NVIDIA doesn't list it and AWS documents "595 or later". But P3/P3dn/G3 (V100/M60) are legacy in R595, so moving the whole AMI to 595 isn't an option either. One AMI must carry **both** branches and choose per instance. There is also customer pressure to *offer* 595 even where 580 works, because scanners flag 580 hosts for CVEs already fixed on R580 — false warnings, not real exposure (drawback 7).
- **Recommendation: Option A.** Keep today's native 580 install unchanged for every family. Stage an offline 595 package set in the AMI and swap it in at boot **only** on hardware that needs the Production Branch (today only G7).
- **Cost.** G7 pays a one-time swap on first boot (19.2 s warm cache in the POC; 75.3 s on a fresh AMI with cold dnf cache), pre-`ecs.service`. Every later boot and every other family pays 0.17 s or nothing. Disk is 0.3–0.65 GiB. The rpmdb stays truthful and release detection is unchanged.
- **Validated.** The production recipe end-to-end on real G7 (auto-selected 595, no override); the swap on L4 stand-in and via forced override on real G7; 580 on G7/G7e; 595 GRID on G6f. 580 working on G7 is unqualified, so it is used only as a **degraded fallback**.
- **Decisions needed:** (1) Option A vs B (EKS parity) vs C (separate AMI); (2) whether to stage the reverse 580 set for stop/start away from G7 (+328 MiB); (3) the customer-override surface. Phase 0 boot-path defect fixes can ship first as a separate change.

| | |
|---|---|
| Doc owner | Dhruv Saran |
| Related work | EKS "LTS and PB NVIDIA Driver Versions in Single EKS AMI" (amazon-eks-ami PR #2819, v20260917) |
| POC evidence | `docs/design/poc/` (code + data), raw logs in `docs/design/poc/raw/` |

## Key Decisions

- The released **flavor-selection** design (proprietary / open / GRID at one driver version) is the foundation; this project adds **version** selection on top and must not regress it.
- Default policy is **LTS-first**: every instance runs R580 unless R580 cannot drive an attached GPU. Today that is only G7.
- Recommended mechanism: **native LTS install + offline, pre-staged PB package set swapped in at boot only on PB-required hardware** (Option A). Alternatives are EKS-style co-resident trees + overlays (Option B) and a separate AMI per branch (Option C).
- The PB tree carries **only the open kernel-module flavor**. P3/P3dn/G3 (proprietary-only) and G6f/Gr6f (GRID) are hard-pinned to LTS.
- A **customer-facing runtime override is required**: a customer can force a branch at launch (boot-time config surface, not a build variable). Automatic selection is the default; a compatible override takes precedence; an incompatible override is rejected, logged, and falls back to the safe automatic choice. Open question is *which* surface.
- Fix pre-existing boot-path defects found in the POC as a **separate, earlier change (Phase 0)**.
- **2026-09-29:** G7/G7e validated on Spot hardware — 580 works on both (unqualified on G7); the forced 580→595 swap works on G7 (19.2 s). **GRID 20.2 (595) works on G6f** (Licensed, CUDA PASS, survives reboot); it stays on LTS 580 GRID under LTS-first because PB carries no GRID flavor. **580 is an acceptable degraded fallback on G7** via a reviewed `lts-fallback.devices` list (today only `2c3a`).
- **2026-09-29:** Option A is integrated into the Packer recipe and validated end-to-end on real G7 — the automatic path, not a forced override. `make al2023gpu` bakes `stage-nvidia-pb.sh` on top of the unchanged native 580 install; a G7 launched from that AMI auto-detected the device and swapped to 595 at boot with no config. Evidence: `docs/design/poc/raw/g7-595-validation-20260929.log`.

## Background

### Why one version no longer works

NVIDIA publishes three branch kinds: **LTSB** (R580, supported to June 2028), **PB** (R595, to March 2027) and short-lived **NFB** (R590/610/615). The AL2023 NVIDIA repo mirrors only 570, 580 and 595.

The problem is caught between two hardware constraints:
- **G7 (RTX PRO 4500 Blackwell, PCI `10de:2c3a`)** is absent from every repo-published R580 `supported-gpus.json`. It first appears in `595.58.03`; AWS documents G7 as "595 or later".
- **P3/P3dn (V100) and G3 (M60)** are `legacybranch: 580.xx` in every 590+ release. R580 is the last branch to support Maxwell/Pascal/Volta, so moving to 595 would drop them.
- **G6f/Gr6f vGPU guests** need a GRID driver. GRID 20.2 (595) was measured working on G6f on 2026-09-29, so 595 is no longer a hard blocker there — but under LTS-first they stay on 580 GRID and the PB tree carries no GRID flavor.

Beyond hardware, there is **customer security-reporting pressure to offer 595 even where 580 works**. Scanners flag 580 hosts for CVEs (ALAS2023NVIDIA-2026-283/285/286/287/289/292/293) whose ALAS "fixed-in" version is `595.71.05`, even though NVIDIA bulletin 5821 shows the same CVEs fixed on R580 at `580.159.03`. This is a reporting artifact, not a real exposure. Being able to run 595 on demand gives these customers a way to clear the noise. EKS reached the same two-branch conclusion and shipped in v20260917.

### Hardware compatibility matrix (x86_64 families in scope)

| Family | GPU (arch) | PCI | Proposed (branch / flavor) |
|---|---|---|---|
| G3 | M60 (Maxwell) | 13F2 | **580 / proprietary** (dead end at R580 EOL) |
| P3 / P3dn | V100 (Volta) | 1DB1 / 1DB5 | **580 / proprietary** (dead end) |
| G4dn | T4 (Turing) | 1EB8 | 580 / open |
| G5 | A10G (Ampere) | 2237 | 580 / open |
| G6 / Gr6 | L4 (Ada) | 27B8 | 580 / open |
| G6f / Gr6f | L4 vGPU | 27B8 | **580 / GRID** (595 GRID works but not needed) |
| G6e | L40S (Ada) | 26B9 | 580 / open |
| **G7** | **RTX PRO 4500 BSE (Blackwell)** | **2C3A** | **595 / open** |
| G7e | RTX PRO 6000 BSE (Blackwell) | 2BB5 | 580 / open |
| P4d / P4de | A100 (Ampere) | 20B0 / 20B2 | 580 / open |
| P5 / P5e / P5en | H100 / H200 (Hopper) | 2330 / 2335 | 580 / open |
| P6-B200 / P6-B300 | B200 / B300 (Blackwell) | 2901 / 3182 | 580 / open |

Takeaways: **Only G7 needs the PB branch today.** Blackwell is open-only in every branch, so the PB branch needs only the open flavor. **CUDA compatibility:** 580 ships CUDA 13.0 and 595 ships CUDA 13.2; CUDA 13.x apps run on R580 through minor-version compatibility (a 13.2 container compiled and ran vectorAdd on L4 with 580.178.04, both SASS and PTX JIT), so LTS-first doesn't strand customers on newer CUDA minors.

### Glossary

- **LTSB / PB / NFB:** NVIDIA Long-Term Support, Production and New Feature branches.
- **Flavor:** kernel-module variant — open (`nvidia`), proprietary (`nvidia-proprietary`) or GRID (`nvidia-grid`). The released design selects a flavor.
- **Branch / version:** R580 (`580.178.04`) or R595 (`595.91.07`). This design selects a branch.
- **Version-specific set:** the 18 RPMs whose NEVRA differs between 580 and 595 (16 runtime packages plus `kmod-nvidia-open-dkms` and `kmod-nvidia-latest-dkms`).
- **DKMS / dracut:** Dynamic Kernel Module Support and the initramfs generator DKMS runs after each transaction.

## Scope

**In scope:** selecting the driver **branch** per instance for AL2023 GPU AMIs (x86_64), composed with existing flavor selection; build-time PB payload; boot-time selection; **release-pipeline changes to track two versions independently** (detect, gate, pin, tag, publish both); correctness across reboots and stop/start type changes; a **required customer-facing branch override** at launch; all shipping regions including GRID-skip and air-gapped — **selection must be fully offline**.

**Out of scope:** AL2 GPU AMIs (EOL June 30 2026); arm64 GPU families (no AL2023 arm64 GPU AMI); changing flavor-selection rules.

**Future scope:** auto-generating/validating PCI device lists in CI; additional override surfaces (IMDS tag, SSM parameter); moving the PB branch forward and folding G7 into the next LTSB.

## Success Criteria

1. A single AL2023 ECS GPU AMI at the existing SSM path boots a working driver on **every** in-scope family including **G7**, with **no customer configuration**.
2. Every family except G7 keeps today's branch (580), flavor and boot path with no added latency.
3. Selection works **offline** and is **idempotent** across reboots and stop/start type changes.
4. `ecs-init` GPU discovery succeeds and the agent registers `ecs.capability.gpu-driver-version=<selected version>`.
5. A **customer runtime override** forces a branch at launch: compatible overrides take precedence; incompatible ones are rejected, logged, and fall back to automatic — the instance never boots a driver the GPU can't run.
6. The release pipeline detects, gates and publishes both branches independently; release notes list both versions.
7. A documented stance on version-locking / security-update / in-place-upgrade tradeoffs.
8. MACIS covers per-branch and per-flavor selection, the override (including invalid-override rejection), and reboot idempotency.

## How the system works today (the "before")

**Build** (`al2023.pkr.hcl`, `install-nvidia-driver.sh`, on a GPU-less c5.4xlarge): install kernel-devel/headers plus `dkms`; read the single pin; build and archive all three kernel-module flavors (GRID from the EC2 S3 runfile, proprietary, open) via `dkms build/install` → `kmod-util archive`; `dnf install` userspace at the pin; versionlock `nvidia* kmod* libnvidia* xorg* kernel*`; enable the NVIDIA units. Measured: `install-nvidia-driver.sh` takes 431 s; dracut runs 11 times for 68 s producing an initramfs with **zero** NVIDIA files (suppressing DKMS `post_transaction` saves 65 s / 15%).

**Boot** (`nvidia-kmod-load.service`): the flavor is chosen from `lspci` device:subsystem tuples; `kmod-util load` runs `dkms ldtarball` then `dkms install`.

**Release** (`check-update-security.sh`): every weekday it reads the pinned major (`580`), intersects newest repo versions with GRID runfile versions across partitions, compares to the version installed on the released AMI (`dnf repoquery --installed` on a c5.large), and rewrites the single `nvidia_driver_version_al2023` key.

### Pre-existing defects (all designs inherit them)

Measured on a g6.xlarge on the current AMI:
1. **`nvidia-kmod-load.service` fails on every boot after the first** (`already added`). GPU still works because the `.ko` is autoloaded early. No MACIS check for this.
2. **First boot is slow:** `nvidia-kmod-load` takes 42.7 s on cold EBS (`ldtarball` + synchronous dracut).
3. **Flavor split-brain across a flavor change:** the loaded flavor lags the selected flavor by one boot; recovery needs `dkms remove`.
4. **Versionlock gaps:** `dnf install nvidia-imex` still pulls `595.91.07`.
5. **ecs-init with no usable driver** exits 255 and `ecs.service` restart-loops — so any version switch must finish **before** `ecs.service`.

**Recommendation: fix 1–4 first as "Phase 0"** in a separate CR: make the loader idempotent, suppress DKMS dracut, purge conflicting flavor registrations, add `nvidia-imex*` / `libnvidia-nscq*` to the lock.

## Recommended Solution — Option A: Native LTS + offline PB swap at boot

The build bakes **both** versions into one AMI — 580 installed as default, 595 staged and ready — and each instance picks the one its GPU needs at boot.

### Build-time changes

1. **Leave the LTS build unchanged** (R580, all three flavors, native).
2. **Stage the PB set** in `/opt/ecs/nvidia/595.91.07/` (new `stage-nvidia-pb.sh`): `dnf download` the 16 version-specific runtime RPMs at `595.91.07`; build the **open** modules only from `kmod-nvidia-open-dkms-595.91.07` against the locked kernel (59 s on 16 vCPU) and package them as a local RPM `kmod-nvidia-open-prebuilt` (owns the `.ko` files, `Provides: nvidia-kmod = 3:595.91.07`, `%post` runs only `depmod` — **no DKMS compile / dracut at boot**); generate local repo metadata with `createrepo_c`.
3. **Optionally stage the 580 set** the same way for the reverse swap (G7 → other family after a stop/start type change).
4. **Generate the PB device list** at build with `gen-device-lists.py` from a reviewed `pb-required.devices` map (today only `2c3a`); the build fails if an entry is missing from PB's `supported-gpus.json`, is legacy, lacks `kernelopen`, or is already supported by LTS (guards against the EKS ffc658f8 legacy-list bug).

**Disk:** the staged PB set is 312 MiB plus ~11 MiB of `.ko` files; the reverse 580 set adds 328 MiB. Both together ~0.65 GiB (2% of the 30 GB root). EKS keeps a 1.7 GB tree.

### Boot-time selection

`nvidia-driver-select.service` is a new oneshot unit (prototype in `docs/design/poc/m4/`):

- **Ordering:** `After=cloud-init.service` (so a cloud-config override applies and DKMS autoinstall can't race); `Before=` every driver consumer (`nvidia-kmod-load`, `nvidia-persistenced`, `nvidia-fabricmanager`, `docker`, `ecs`, `cloud-final`, etc.). A drop-in makes `nvidia-kmod-load` skip itself when PB was selected.
- **Selection:** read `lspci -n -d 10de:` device IDs; choose PB if any device is in `pb-required.devices`, else LTS; apply an optional override only if **every** attached device is supported by the requested branch; exception: an `lts` override is accepted for devices in a reviewed `lts-fallback.devices` list (today only `2c3a`), with a logged unqualified-configuration warning.
- **No-op path** (installed branch == selected): verify versionlock and exit — 89 ms (0.17 s unit time).
- **Swap path:** (1) unload any stale coldplug-loaded `nvidia` module; (2) purge DKMS `nvidia*` registrations and `.ko` files directly, without `dkms`/`dracut`; (3) run **one** dnf transaction against the local repo only, inside `unshare --net` (proves offline), with native scriptlets; (4) rewrite `versionlock.list` to the selected NEVRAs including `nvidia-imex*` / `libnvidia-nscq*`; (5) `depmod`, then `modprobe`.

### POC results (g6.xlarge / L4 as PB stand-in)

On L4 both branches are supported, so forcing `pb` exercises every step except the G7 hardware itself; the forward swap was later repeated on real G7 with matching numbers.

| Scenario | Unit time | GPU ready | Result |
|---|---|---|---|
| LTS no-op (auto) | — | 9.5 s | 580.178.04, vectorAdd PASS |
| **Forward swap 580 → 595** (override `pb`) | **18.5 s** | 25.9 s | 595.91.07, CUDA 13.2, vectorAdd PASS, `dnf check` rc=0 |
| PB no-op (second boot) | **0.17 s** | 8.1 s | 595.91.07, PASS |
| **Reverse swap 595 → 580** | **23.0 s** | 43.5 s | 580.178.04, PASS; includes one dracut run |

Other observations: the swap works with **no network** (`unshare --net`) and no scriptlet hung (addresses the neuron-inf1 #602 offline-stall lesson); the **rpmdb stays truthful** (`rpm -qa` shows 595, `dnf check` rc=0, native file triggers ran); `nvidia-kmod-common`'s `%post` rewrites `grub.cfg` on every swap and the reverse swap triggers one dracut run (~8 s); `ecs-init` GPU discovery works after a swap; `nvidia-gridd` is skipped on PB via a drop-in.

### Resolution policy

- **Default: LTS-first.** PB only when LTS can't drive every attached GPU. Matches EKS.
- **Device lists:** a reviewed PCI device-ID map validated in CI against each shipped version's `supported-gpus.json` (not a raw generated list, not an instance-type table).
- **GRID / legacy:** unchanged flavor rules; GRID and proprietary devices hard-pinned to LTS.
- **Unknown devices:** LTS-open (today's behavior), logged.
- **Commit semantics:** re-resolve on every boot; the no-op check is cheap (0.17 s), so a changed PCI identity after stop/start is handled automatically if the reverse set is staged.
- **Customer override (required):** proposed contract is `/etc/ecs/nvidia-driver-select.override` with `NVIDIA_DRIVER_BRANCH=auto|lts|pb`, written via cloud-config `write_files` (resolver needs only `After=cloud-init.service`). It must **not** come from `ecs.config` written by user-data (that runs in `cloud-final`, after the driver load). An incompatible override is rejected, logged, and falls back to automatic; `lts` on G7 is accepted with a warning (measured working on `2c3a`). Open question is the surface, not whether. EKS declined an override (#2417); ECS requires one.
- **Scheduling:** the agent already registers `ecs.capability.gpu-driver-version=<v>` (undocumented); documenting it enables placement constraints.

### Release-pipeline changes

Today the automation is built around a **single** version: read the one pinned major, find the newest in-major driver (intersected with GRID runfile versions), compare to the released AMI, rewrite the single key; surface the version via the AMI `NvidiaDriverVersion` tag, release notes and SSM path. With **both** branches:

- **Two pins:** `variables.pkr.hcl` gains `nvidia_driver_major_al2023_pb = "595"`; `NVIDIA_DRIVER_VERSION` gains `nvidia_driver_version_al2023_pb`. The two pins advance independently.
- **`check-update-security.sh`:** loop over both majors. The PB branch is **not** GRID-gated (no GRID flavor). LTS installed version is still visible via the rpmdb on a non-GPU c5.large; the PB installed version comes from staged repo metadata or an AMI tag (a key advantage over Option B, whose unpacked trees make INSTALLED undetectable and would abort InitiateRelease under `set -euo pipefail`).
- **`check-update.sh`, `generate-release-notes.sh`, AMI tags, SSM value:** emit and publish both versions.
- **GRID key selection:** anchor the runfile match to `grid-*/` prefixes (today's match also hits `latest/`).

### Drawbacks

1. **Boot-time package mutation on PB hardware.** G7 runs a local rpm transaction on first boot before `ecs.service` (19.2 s on G7). New behavior; only precedent is the Neuron inf1 downgrade. A half-way failure leaves a mixed rpmdb, so the unit must verify its result, fall back to LTS and log loudly where safe (on G7, 580 works), else fail loudly. Failure injection was **not** tested.
2. **First boot on G7 is slower** (GPU ready ~26 s vs ~9.5 s on LTS); every later boot is 0.17 s.
3. **Reverse swap cost and disk.** Stop/start from G7 to another family needs the 580 set staged (+328 MiB), ~23 s + one dracut run each. Not staging it leaves a G7-first instance on 595 after a type change — fine everywhere except P3/G3 (595 can't work) and G6f (PB has no GRID flavor). A decision is needed.
4. **Scriptlet side effects at boot:** `nvidia-boot-update` regenerates `grub.cfg` on every swap (harmless on AL2023). CI must diff scriptlets between staged versions (Phase 1 found 580 and 595 identical).
5. **New packaging to own:** `kmod-nvidia-open-prebuilt`, built per kernel × driver version.
6. **Kernel coupling (as today):** prebuilt PB modules exist only for the build kernel; if a customer updates the kernel there's no DKMS source. Mitigation: also stage `kmod-nvidia-open-dkms-595` (+76 MiB) as a DKMS fallback.
7. **Security-scanner false positives continue on LTS hosts.** ALAS publishes one fixed-in version per advisory (`595.71.05` for this CVE set), even though NVIDIA bulletin 5821 gives `580.159.03` on R580 — so scanners flag 580 hosts for already-fixed CVEs. **This is a reporting artifact, not a real 580 vulnerability, and this design does not change it:** the scanner keys on the *installed* NEVRA, and Option A stages but does not install 595 on non-G7 families, so those hosts report installed=580 and carry exactly today's finding. Only G7 (595 actually installed) clears it, as a side effect. A real fix needs per-branch advisories or an AL driver-provisioning change. Tracked in [P486933997 / ALOL-2599](https://t.corp.amazon.com/P486933997), Shepherd [P509379304](https://t.corp.amazon.com/P509379304), customer request [D527074374](https://t.corp.amazon.com/D527074374).
8. **Two patch surfaces:** each NVIDIA bulletin must land on both branches; LTS cadence is additionally limited by GRID runfile availability across 3 partitions (upload lag 1–71 days).
9. **PB lifecycle churn:** R595 is EOL March 2027 and won't become an LTSB; a yearly PB migration must be budgeted.
10. **Divergence from EKS:** two code paths across two teams; bugs fixed in one aren't fixed in the other.

## Alternative Designs

### Option B: EKS parity — co-resident trees + overlay mounts

Both branches' RPMs are unpacked with `rpm2cpio` into `/opt/nvidia/{lts,pb}`; at boot a resolver selects a tree, `usr-{bin,lib64,share}.mount` overlays it over `/usr`, `nvidia-setup` copies `/etc` and `.ko`/firmware and runs `depmod`/`modprobe`, and packages are registered `rpm -i --justdb --noscripts --nodeps`. Measured on published EKS AMI v20260923: resolve 0.06 s, setup 6.7 s first boot / 0.8 s reboot, justdb 2.4 s, tree 1.7 GB kept.

- **Pros:** proven at EKS, reusable code, one AMI with no boot rpm transaction, fast steady state, removes the DKMS/ldtarball path (fixes defects 1–3), parity/shared ownership.
- **Cons:** the **rpmdb lies** (justdb, dnf triggers never fire — the ld.so.cache regression #2834 is this bug class; v20260923 had zero NVIDIA ld.so.cache entries and `rpm -V` drift); **release detection breaks** (unpacked driver invisible on a non-GPU host); bigger disk (1.0–1.7 GB/tree); overlay constraints (one overlay per path conflicts with customer overlays; covers only 71/77 switch paths); harvested `.ko` fail on any kernel change; large change (+1245/−591 over 23 files); resolve-once stranded a stopped/started node on the wrong tree.

### Option C: Separate AMI per branch

Keep `al2023gpu` on 580 (all flavors); add `al2023gpu-pb` on 595 (open only) at a new SSM path; customers pick per family.

- **Pros:** simplest runtime (native install, truthful rpmdb, no boot mechanism, no extra disk); isolated failures; per-AMI release detection keeps working; small recipe change (~150–250 lines).
- **Cons:** mixed fleets need two launch templates (selection burden moves to the customer); wide internal plumbing (build/publish pipelines, MACIS, region info, docs, a new SSM namespace — GPU work doubles per region); a G7 on the default AMI runs 580 **as its normal state** — unqualified, with no signal unless a guard is added; naming must survive PB churn; doesn't match EKS (#2417).

### Option D: Co-resident trees switched by `ld.so.conf.d` + symlinks (no overlays)

Both versions unpacked under `/opt/nvidia/<ver>`; a `current` symlink; `ld.so.conf.d/nvidia.conf` points at `current/usr/lib64`; fixed symlinks for `/usr/bin`, ICDs, firmware, units; activation runs `ldconfig`/`depmod`/`modprobe` (2.3–4.1 s). Toolkit JIT-CDI discovered libraries via ld.so.cache and vectorAdd passed. Hazards: flipping without `ldconfig`+module swap gives NVML mismatch; SELinux `module_load` AVC denials for modules in `/opt`; an inconclusive MPS `maxerr=2 FAIL` needing a rerun.

**Why not D:** it has all of Option B's downsides (rpmdb lies, release detection breaks, two trees) and lacks B's one advantage — EKS precedent and parity. B beats D on precedent; A beats D on correctness.

### Rejected

| Option | Reason |
|---|---|
| **Status quo / LTS-only** | 580 runs G7 but only unqualified; NVIDIA doesn't list `2c3a`, AWS documents "595 or later", no guarantee later 580 point releases keep working. Acceptable as fallback, not default. |
| **Move whole AMI to 595** | P3/P3dn/G3 are `legacybranch: 580.xx` in every 590+ release; and R595 is EOL March 2027 (whole fleet on a branch with ~6 months left). G6f is not a blocker (GRID 20.2 works). |
| **Native side-by-side 580 + 595** | 92 rpm file conflicts, exact `= 3:V` Requires chains, `kmod-nvidia-open-dkms` Conflicts with `kmod-nvidia-latest-dkms`; the resolver treats the second version as an upgrade. |
| **systemd-sysext image per branch** | While merged, `/usr` and `/opt` become read-only, so `dnf` breaks on a general-purpose host. |
| **Download PB at first boot** | Requires network at boot, breaks air-gapped regions, adds a boot-time DKMS compile. |

### Comparison

| | A (rec.) | B: EKS trees + overlays | C: Separate AMI | D: Trees + ld.so.conf.d |
|---|---|---|---|---|
| Non-G7 families unchanged | **Yes** | No | Yes | No |
| One AMI / SSM path | Yes | Yes | **No** | Yes |
| rpmdb truthful / native scriptlets | **Yes** | No (justdb) | Yes | No |
| Release detection unchanged | **Yes** (LTS) | No | Yes | No |
| Extra disk | 0.33–0.65 GiB | ~1.7 GB | 0 | ~2 trees |
| First-boot cost on G7 | 19.2 s swap | ~7 s setup | 0 | ~2–4 s |
| Steady-state cost | 0.17 s | 0.8 s | 0 | ~2–4 s |
| Stop/start family change | Yes (if 580 staged) | **No** (resolve-once) | n/a | Yes |
| Production precedent | Neuron inf1 (smaller) | **EKS** | al2023neu, kepler | None |
| EKS parity | No | **Yes** | No | No |

### Why Option A and not EKS parity (Option B)

Parity is a real benefit, but three ECS-specific reasons rule out Option B here:

1. **ECS's release automation depends on a truthful rpmdb; EKS's does not.** ECS reads the installed version from the rpmdb on a non-GPU c5.large under `set -euo pipefail`. Option B's justdb registration makes the driver invisible there, aborting the whole InitiateRelease run. Option A installs LTS natively, so that pipeline keeps working.
2. **Different blast radius.** Option B puts the **entire** GPU fleet (the 580-open g4dn/g5/g6 install base) onto the new trees-plus-overlay path. Option A leaves every non-G7 family byte-identical to today; only G7 (no install base) gets new code.
3. **We measured EKS's mechanism carrying real defects, not hypothetical ones** — zero NVIDIA ld.so.cache entries, `rpm -V` drift, resolve-once stranding a stopped/started node. Option A keeps the rpmdb authoritative, so this bug class doesn't exist.

Where EKS is the right reference, this design follows it: LTS-first, a reviewed device map (not a raw list — EKS shipped the ffc658f8 bug we guard against), the same branch pair. The divergence is in the switch mechanism only, driven by ECS's pipeline and fleet.

## Testing

### POC performed (2026-09-28 – 2026-09-29, dev account)

Current ECS AMI on g6.xlarge (first boot, reboots, forced flavor switch, recovery, NVML/module-missing failure modes, CUDA 13.0/13.2 containers on 580); Option A prototype on g6.xlarge (LTS no-op, forward swap ×3, PB no-op, reverse swap ×2, baked-state rehearsal); EKS v20260923 on g6→g4dn (timings, overlays, ld cache, rpmdb, resolve-once); Option D prototype; build mechanics on 2× c5.4xlarge (full install replica, dracut suppression, real dnf closures, justdb, versionlock).

### G7 / G7e hardware validation (2026-09-29)

Previously blocked by `InsufficientInstanceCapacity`; unblocked with one-time Spot instances.

- **580.178.04 drives G7 (`2c3a`)** although no R580 `supported-gpus.json` lists it — driver binds, `nvidia-smi` works, CUDA passes in containers. **Still unqualified**; doesn't change the default (G7 selects PB) but makes 580 an acceptable degraded fallback.
- **The forced Option A swap works on real G7 and matches L4:** selected `pb/595.91.07`, unloaded the coldplug 580 module, purged 6 DKMS registrations, ran an offline 17-package transaction; total unit time **19.2 s**, GPU ready at **26.05 s**. `nvidia-kmod-load` skipped, prebuilt 595 module loaded, `ecs.service` at 28.6 s, `dnf check` rc=0, no `rpm -Va` drift, lock rewritten to 595. Build-time validation: `2c3a` absent from `lts-supported.devices` (449 IDs), present in `pb-supported.devices` (293 IDs).
- **G7e (`2bb5`) on 580 works** as predicted; needs no PB.
- **Phase 0 defect 1 reproduced on the public ECS GPU AMI** (G7e `nvidia-kmod-load.service` failed on every reboot).

Remaining gaps: reverse swap (595→580) and a second no-op boot on 595 not run on G7 hardware; only `2xlarge` (1 GPU) tested; the G7e container test used a locally imported minimal image (no internet egress).

### End-to-end recipe validation on real G7 (2026-09-29)

`stage-nvidia-pb.sh` and two provisioners were wired into `al2023.pkr.hcl` and a full AMI baked with `make al2023gpu` (`ami-025efa3c1e7460927`). Launched on a **g7.2xlarge Spot** (`10de:2c3a`) with **no override**, `nvidia-driver-select.service` selected `pb/595.91.07`, ran the offline transaction and loaded the prebuilt module: `done (swapped 580.178.04 -> 595.91.07) in 75313 ms`. Post-boot: `nvidia-smi` = 595.91.07 (RTX PRO 4500), unit `active`/success, `dnf check` clean, a CUDA 13.2 container enumerated the GPU. This proves the headline criterion — G7 gets 595 automatically with no config — on a natively built image. The automatic swap took **75.3 s** here (72.8 s cold dnf cache) vs 19.2 s in the warm-cache POC; a one-time first-boot cost on G7 only. Pre-warming the dnf cache at build time would close most of the gap. A cosmetic build-time defect (a sudo-vs-shell-redirect bug in `stage-nvidia-pb.sh`) was found and fixed. Evidence: `docs/design/poc/raw/g7-595-validation-20260929.log`.

### G6f on GRID 20 (2026-09-29)

Re-tested on a g6f.large with `grid-20.2/…595.91.07-grid-aws.run`: install passed, open modules loaded, `nvidia-smi` shows L4-3Q / 595.91.07 / CUDA 13.2; `nvidia-gridd` active and Licensed (survives reboot); vectorAdd PASS before and after reboot (unified memory not available, standard for vGPU). **Implication:** G6f is no longer a hard blocker for 595, but the design is unchanged — under LTS-first G6f stays on 580 GRID and PB carries only open. Gr6f untested; EC2 still documents GRID 18.4–19.5. **Follow-up:** share with the EKS team, whose roadmap claims 595 "breaks G6F".

### Shepherd / advisory-surface verification (2026-09-30)

Checked directly on the baked Option A AMI (launched on a non-GPU t3.large, staged-but-not-swapped state). `dnf updateinfo` is a faithful local stand-in for Shepherd's ALAS-derived scan input. Measured: installed driver is **580 only** (22 packages); the 595 set is **staged, not installed** (files under `/opt`, absent from the rpmdb); `dnf updateinfo list --security 'nvidia*'` lists exactly the seven pre-existing 580 advisories with **zero** lines from the staged 595 set; `dnf check` rc=0. **Conclusion:** staging 595 alongside installed 580 is scan-invisible — an Option A AMI shows the same pre-existing 580 false positives as a single-branch 580 AMI, neither creating nor clearing findings. This confirms Drawback 7. **Remaining ToD:** confirm Shepherd's own pipeline matches by scanning a baked AMI in a Shepherd-enrolled account.

### Proposed test plan

- **MACIS:** units not failed after boot and reboot (catches defect 1); per-family expected (branch, flavor, version); staged PB repo present and gpg-verifiable; `pb-required.devices` consistent with `supported-gpus.json`; versionlock matches selected NEVRAs incl. `nvidia-imex*` / `libnvidia-nscq*`; `dnf check` rc=0.
- **ToD instance matrix:** g4dn, g5, g6, g6e, **g7**, g7e, p4d, p5, p6 (open); p3/g3 (proprietary); g6f **and gr6f** (GRID); **multi-GPU** g7/g7e sizes — each with a CUDA container through the ECS task path and one reboot.
- **Stop/start type-change:** g6 → g7 → g6, and g7 → p3 (the LTS-only guard).
- **Failure injection:** corrupted staged RPM, interrupted swap, full disk, unlocked-and-updated kernel — on G7 each must end on a working 580 fallback with the warning logged.
- **G7 `lts` override:** accepted with a warning, boots 580, CUDA passes; the same override on a device outside `lts-fallback.devices` is still rejected.
- **Offline:** run the swap on an instance with no egress.

## Security Considerations

- **AppSec engagement required:** a package transaction now runs at boot — update the threat model.
- **Supply chain:** staged PB RPMs are the same AL/NVIDIA-signed RPMs; production **must keep `gpgcheck=1`** (prototype used 0). The only locally built artifact is `kmod-nvidia-open-prebuilt`, built from signed source; record its provenance (hashes in AMI tags / release notes).
- **Offline by construction:** the swap runs in a network namespace with no interfaces, using only the local repo.
- **Patch surface doubles:** both branches must track NVIDIA bulletins and the pipeline must gate on both.
- **Kernel modules:** unsigned, taint the kernel as today; Option A loads from `/lib/modules/<k>/updates` (standard), avoiding Option D's `/opt` SELinux AVC denials.
- **Versionlock:** rewritten at boot to the selected NEVRAs; must keep excluding obsoleters and cover `nvidia-imex*` / `libnvidia-nscq*`.

## Open Questions

1. Mechanism: comfortable with a boot-time rpm transaction on G7 (A)? Or value EKS parity (B) or zero boot mechanism (C) more?
2. Stage the reverse (580) set for stop/start away from G7 (+328 MiB)?
3. Customer override surface (required — the question is the surface): cloud-config `write_files` file, or also an IMDS-tag / SSM-parameter path? (`ecs.config` via user-data is ruled out.)
4. G6f/Gr6f: pin GRID 19.5 or update the docs? Which vGPU manager version do G6f hosts run? When will EC2 list GRID 20?
5. PB lifecycle: when R595 is EOL (March 2027), move to the next PB or fold G7 into the next LTSB?
6. Phase 0 defects: agree to fix them first as a separate change?
7. Adopt EKS's G4dn/G5 → proprietary + GSP-off rule? (Out of scope, affects the flavor matrix.)
8. Footprint: can `nvidia-settings` + Xorg be dropped from a headless ECS AMI? (saves 155–158 packages, 260–267 MiB.)
9. ~~Should 580 be an acceptable degraded fallback on G7?~~ **Resolved 2026-09-29: yes**, with a warning, for a failed PB swap or a customer `lts` override; PB remains the default.

## Artifacts

- **Prototype code** (`docs/design/poc/`): Option A (`m4/`): `nvidia-driver-select.{sh,service}`, `build-m4-stage.sh`, `kmod-nvidia-open-prebuilt.spec`, `gen-device-lists.py`, `pb-required.devices`, drop-ins; Option D (`m3/`); data matrices (`data/`).
- **Raw POC logs** (`docs/design/poc/raw/`): `p2-baseline/`, `p2-m4swap/`, `p2-eksref/`, `p2-m3ldso/`, `p2-mechanics/`; Phase 1 in `phase1/` and `PHASE1-FINDINGS.md`.
- **References:** Harish Senthilkumar, "Dynamic NVIDIA Driver Selection for AL2023 ECS GPU AMIs"; EKS "LTS and PB NVIDIA Driver Versions in Single EKS AMI" and amazon-eks-ami PRs #2819, #2835, #2417; AWS EC2 NVIDIA driver docs; NVIDIA driver lifecycle and vGPU 19/20 release notes.
- **CRs / PRs:** none yet; implementation follows review.
