# AxVisor x86 Linux-host Phase 1 Plan

## Goal

Phase 1 proves that AxVisor can run on an Intel x86_64 Linux host and boot
Linux guests through two separated layers:

1. Phase 1A: Linux host -> AxVisor native x86 path -> Linux guest.
2. Phase 1B: Linux host -> `axvisor_kvm.ko` -> `/dev/kvm` -> unmodified
   Firecracker -> Linux guest.

Phase 1A is the required baseline before Phase 1B is treated as meaningful.
Phase 1A proves the AxVisor x86 backend. Phase 1B proves the minimal KVM ABI
compatibility layer for Firecracker.

## Fixed Environment

- Host architecture: Intel x86_64 with VMX.
- Test topology: real Linux host with `/dev/kvm`, QEMU/KVM nested VMX, inner
  Linux host loads AxVisor modules.
- Scope is limited to the current development machine and current nested QEMU
  environment.
- AMD SVM is out of scope for Phase 1.
- Pure QEMU TCG is out of scope because the inner AxVisor needs VMX.

## Phase 1A Acceptance

Phase 1A passes only when a single command can boot an initramfs-only Linux guest
through AxVisor's native x86 path and produce deterministic evidence:

- Guest prints `AXVISOR_X86_GUEST_PASS=1`.
- Guest behavior is correct: it reaches userspace, executes the initramfs test,
  and requests shutdown or reaches a verifier-controlled end state.
- Guest serial output is captured to a host-side log file.
- AxVisor logs show the expected major flow: VM created, vCPU entered guest,
  COM1/PIO output handled, timer/interrupt behavior is explainable, and final
  halt/shutdown path is explainable.
- Logs must not contain critical反模式: panic, oops, fail-entry, internal
  error, or an unexplained infinite timer/vCPU loop.

Phase 1A uses:

- Intel VMX only.
- Single vCPU.
- Fixed guest RAM, preferably 128 MiB; 256 MiB is acceptable if placement needs
  more space.
- `bzImage` + initramfs via Linux boot protocol.
- Fixed guest memory layout and boot parameters.
- `acpi=off pci=off nomodule` style boot arguments.
- Legacy COM1 serial through PIO port `0x3f8`.
- Minimal PIO device behavior: COM1 output is required; unknown PIO is logged
  and answered conservatively.
- Existing AxVisor control surface, such as config files and shell commands.
  AxVisor's native interface must not be redesigned for Phase 1A.

## Phase 1B Acceptance

Phase 1B passes only after Phase 1A passes. It requires a single command that
runs an unmodified Firecracker binary through `/dev/kvm` provided by
`axvisor_kvm.ko` and produces deterministic evidence:

- Firecracker is not patched.
- Firecracker opens `/dev/kvm`; debug-only names such as `/dev/axvisor-kvm` are
  not acceptance targets.
- The inner Linux host does not load or share Linux's native KVM module for this
  test. `/dev/kvm` is provided by `axvisor_kvm.ko`.
- Firecracker guest prints `AXVISOR_FIRECRACKER_GUEST_PASS=1`.
- Verifier exits deterministically with PASS or FAIL and captures Firecracker
  serial output, Firecracker stderr, inner-host dmesg, and AxVisor logs.

Phase 1B uses:

- Unmodified Firecracker with fixed version/configuration.
- `--no-api --no-seccomp`.
- Single vCPU.
- 128 MiB memory.
- Initramfs-only Linux guest.
- No disk and no network.
- Minimal KVM capabilities only. `KVM_CHECK_EXTENSION` must not advertise
  features that are not actually implemented.
- Minimal irqchip/timer semantics sufficient for the fixed guest to boot.

## Non-goals

Phase 1 does not require:

- AMD SVM.
- Multi-vCPU guests.
- Virtio block, virtio net, real rootfs, or arbitrary disk images.
- Snapshot, migration, dirty logging, or production Firecracker feature parity.
- ACPI, PCI, firmware, generic bootloader compatibility, or arbitrary guest
  kernels.
- Production security posture such as jailer, seccomp profiles, cgroup, or
  namespace integration.
- Performance targets.
- Cross-machine stability.
- Coexistence with Linux native KVM inside the same inner host.

## Implementation Order

1. Build or reuse the x86 host kernel/module artifacts needed for nested VMX.
2. Add Phase 1A verifier infrastructure following the RISC-V Linux-host smoke
   structure: build inputs, launch QEMU, load AxVisor, start guest, collect logs,
   and emit PASS/FAIL.
3. Implement the minimal x86 native guest boot path needed by Phase 1A.
4. Verify Phase 1A with the guest marker and AxVisor log checks.
5. Only then continue Phase 1B and debug the current Firecracker stop around
   early x86 serial output.

