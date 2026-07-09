# x86 AxVisor Test Matrix

This matrix defines the x86-only evidence path for AxVisor on a Linux base.
RISC-V Firecracker tests are intentionally excluded from this matrix.

## Scope

The matrix validates two layers:

1. Layer1: x86 Linux host -> AxVisor Linux-host adapter -> x86 Linux guest.
2. Layer2: unmodified x86 Firecracker -> `/dev/kvm` provided by `axvisor_kvm.ko`
   -> AxVisor backend -> x86 Linux guest.

Passing this matrix proves the tested x86 boot paths work. It does not claim
full production KVM parity.

## Test Cases

| ID | Layer | Test | Acceptance marker | Primary script |
|---|---|---|---|---|
| X86-L1-ROOTFS | Layer1 | AxVisor boots an x86 Linux guest from ext4 rootfs | `AXVISOR_X86_NATIVE_GUEST_PASS=1`, ext4 root mounted, write test passes | `tools/verify-x86-linux-host-linux-smoke.sh` |
| X86-L1-INITRAMFS | Layer1 | AxVisor boots an x86 Linux guest from initramfs | `AXVISOR_X86_NATIVE_GUEST_PASS=1` | `tools/verify-x86-linux-host-linux-smoke.sh` |
| X86-L2-KVM-INIT | Layer2 | `axvisor_kvm.ko` exposes the Firecracker-required KVM init ABI | `AXVISOR_KVM_X86_FIRECRACKER_INIT_QEMU_PASS=1` | `tools/verify-axvisor-kvm-x86-firecracker-init-smoke.sh` |
| X86-L2-FC-RUN | Layer2 | Unmodified x86 Firecracker opens `/dev/kvm` from AxVisor and boots an x86 Linux initramfs guest | `AXVISOR_FIRECRACKER_GUEST_PASS=1` decoded from AxVisor KVM PIO serial exits | `tools/verify-axvisor-kvm-x86-firecracker-run.sh` |
| X86-L2-FC-ROOTFS-TINY | Layer2 | Unmodified x86 Firecracker opens `/dev/kvm` from AxVisor, mounts an ext4 rootfs, and reaches a static tiny init | `TINY_PASS=1`, rootfs mode recorded in `firecracker-result.txt` | `tools/verify-axvisor-kvm-x86-firecracker-run.sh` with `FIRECRACKER_GUEST_BOOT_MODE=rootfs FIRECRACKER_ROOTFS_INIT_KIND=tiny` |

## Default Execution

Run:

```bash
bash tools/run-x86-axvisor-test-matrix.sh
```

For a fast rerun using existing build artifacts:

```bash
NATIVE_SKIP_BUILD=1 KVM_INIT_SKIP_BUILD=1 FIRECRACKER_SKIP_BUILD=1 \
bash tools/run-x86-axvisor-test-matrix.sh
```

The script writes preserved evidence to:

```text
output/x86-axvisor-test-matrix-<timestamp>/
```

The output directory contains:

- `summary.txt`: machine-readable pass/fail summary.
- `README.md`: human-readable evidence explanation.
- `X86-L1-ROOTFS/`: rootfs guest logs and extracted guest result.
- `X86-L1-INITRAMFS/`: initramfs guest logs.
- `X86-L2-KVM-INIT/`: KVM init ABI smoke logs.
- `X86-L2-FC-RUN/`: Firecracker run logs.
- `X86-L2-FC-ROOTFS-TINY/`: Firecracker rootfs/tiny-init diagnostic logs.
- `SHA256SUMS`: checksums for preserved evidence files.

## Extended Stability

For repeated Layer1 stability, run the existing regression separately:

```bash
ROOTFS_REPEAT=20 RUN_INITRAMFS=1 TIMEOUT_SECS=240 \
REGRESSION_ID=x86-stability-$(date +%Y%m%d-%H%M%S) \
bash tools/verify-x86-linux-host-linux-regression.sh
```

The default matrix deliberately keeps the run short enough for routine
development validation. The 20-repeat regression is a stability test, not a
required step for every functional check.

## Current Claim Boundary

The x86 Firecracker case uses an unmodified external Firecracker binary and
requires `/dev/kvm` inside the Linux host guest to be provided by
`axvisor_kvm.ko`.

This matrix distinguishes the rootfs/tiny-init diagnostic from the full
BusyBox/shell rootfs test. `X86-L2-FC-ROOTFS-TINY` proves the Firecracker
rootfs path reaches first userspace code through AxVisor. It does not prove a
complete shell-based rootfs userspace.

This matrix does not cover:

- complete shell-based Firecracker rootfs userspace.
- virtio-net in Firecracker.
- multi-vCPU Firecracker guests.
- snapshot, restore, migration, or jailer.
- full KVM performance parity.
- RISC-V Firecracker fork validation.
