# Linux Host Kernel Collaborator Handoff

`linux-host-kernel` is a modified Linux source checkout used by the Linux-host
tests. It must be distributed separately from the `freehypervisor` repository:
the checkout is about 4.1 GB locally, and most of that size is generated build
output or Git object storage rather than source required by a collaborator.

## Contents to publish

Publish these together:

1. A dedicated fork or source snapshot of `linux-host-kernel`, based on commit
   `492c780f31518bfb7e7fcb2e3e381dedba9bd737`.
2. The local changes captured by the handoff package, committed in that
   dedicated kernel fork. At the time of this inventory, they affect:
   - `drivers/virt/axvisor/axvisor_kvm_axvisor_backend.c`
   - `drivers/virt/axvisor/axvisor_kvm_backend.c`
   - `drivers/virt/axvisor/axvisor_kvm_backend.h`
   - `drivers/virt/axvisor/axvisor_kvm_main.c`
   - `drivers/virt/axvisor/axvisor_kvm_x86_bridge.rs`
   - `drivers/virt/axvisor/vendor/upstream/axvm/src/vm.rs`
   - `drivers/virt/axvisor/vendor/upstream/x86_vcpu/src/vmx/vcpu.rs`
   - `drivers/virt/axvisor/vendor/upstream/x86_vlapic/src/timer.rs`
   - `kernel/smp.c`
3. This `freehypervisor` repository, including `tools/` and the Linux-host
   runbook.

The reproducible source handoff package can be created locally with:

```bash
bash tools/package-linux-host-kernel-source.sh
```

It writes a source archive, a binary-safe patch for current local changes, and
a manifest to `/tmp/freehypervisor-linux-host-kernel-package`. The archive is
for transfer or release assets; it must not be committed to this repository.

## Contents to exclude

Do not publish or commit any of the following as source control content:

- `linux-host-kernel/.git/`
- `linux-host-kernel/build-axvisor/`
- `linux-host-kernel/build-axvisor-*`
- `.config`, `Image`, `vmlinux`, `*.ko`, `*.o`, Rust build artifacts, and
  generated headers
- rootfs images and temporary archives under `/tmp`

These files are reproducible outputs. The build directories alone account for
roughly 2 GB in the current checkout.

## Recommended repository layout

Create a separate repository such as `freehypervisor-linux-host-kernel`, push
the Linux source and AxVisor commits there, then use it as a Git submodule at
`linux-host-kernel` in this repository. Keep the submodule pinned to the exact
tested commit. This preserves reviewable kernel history and avoids importing a
large Linux history into `freehypervisor`.

The collaborator then checks out the main repository with submodules:

```bash
git clone --recurse-submodules <freehypervisor-repository-url>
cd freehypervisor
bash tools/configure-riscv-linux-host-kernel.sh
bash tools/build-riscv-linux-host-module.sh
bash tools/verify-riscv-linux-host-linux-smoke.sh
```

The command prerequisites, kernel configuration, rootfs creation, and QEMU
launch sequence are documented in `docs/axvisor-linux-qemu-host-runbook.md`.
The current scripts contain machine-specific Nix tool paths; before external
handoff, replace those paths with documented toolchain setup or a pinned Nix
environment so collaborators can reproduce the build outside this machine.
