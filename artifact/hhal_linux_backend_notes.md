# HHAL Linux Backend Notes

## Scope of `hhal_linux.c`

`artifact/hhal_linux.c` is a **minimal backend skeleton**, not a production implementation.

Its role is to validate that the proposed HHAL boundary is executable against Linux/KVM with a small amount of glue code.

## Implemented Paths

The current skeleton provides real implementations for:

- `hhal_get_api_version()`
- `hhal_query_capability()`
- `hhal_vm_create()` / `hhal_vm_destroy()`
- `hhal_vm_enable_cap()`
- `hhal_vm_set_tss_addr()`
- `hhal_vm_set_identity_map_addr()`
- `hhal_vm_map_memory()` / `hhal_vm_unmap_memory()`
- `hhal_vm_get_dirty_log()`
- `hhal_vm_clear_dirty_log()` when supported by host headers
- `hhal_vm_create_irqchip()`
- `hhal_vm_set_irq_routing()` for `IRQCHIP` and `MSI` route types
- `hhal_vm_irq_line()`
- `hhal_vm_irq_line_status()` when supported by host headers
- `hhal_vm_bind_irqfd()`
- `hhal_vm_bind_ioevent()`
- `hhal_vm_create_pit()` when supported by host headers
- `hhal_vm_get_clock()` / `hhal_vm_set_clock()`
- `hhal_vcpu_create()` / `hhal_vcpu_destroy()`
- `hhal_vcpu_run()`
- `hhal_vcpu_translate_gva()`
- `hhal_vcpu_interrupt()`
- `hhal_vcpu_nmi()`
- `hhal_vcpu_signal_mask()`

## Explicitly Unimplemented Paths

The following currently return `HHAL_ERR_UNSUPPORTED`:

- `hhal_vcpu_get_state()` / `hhal_vcpu_set_state()` for state IDs outside the current minimal subset

This is intentional. Those paths need more policy and data-model decisions than the lifecycle/run loop primitives.

## Current Minimal State Support

The Linux backend now implements a minimal `state blob` subset:

- `HHAL_VCPU_STATE_REGS`
- `HHAL_VCPU_STATE_SREGS`
- `HHAL_VCPU_STATE_CPUID`
- `HHAL_VCPU_STATE_MSRS`
- `HHAL_VCPU_STATE_FPU`
- `HHAL_VCPU_STATE_LAPIC`
- `HHAL_VCPU_STATE_MP`
- `HHAL_VCPU_STATE_EVENTS`
- `HHAL_VCPU_STATE_DEBUG`
- `HHAL_VCPU_STATE_XSAVE`
- `HHAL_VCPU_STATE_XCRS`
- `HHAL_VCPU_STATE_SIGNAL_MASK` via `set_state()` only

Current backend-specific payload convention:

- `HHAL_VCPU_STATE_REGS` uses `struct kvm_regs`
- `HHAL_VCPU_STATE_SREGS` uses `struct kvm_sregs`
- `HHAL_VCPU_STATE_CPUID` uses `struct kvm_cpuid2` plus trailing `struct kvm_cpuid_entry2[]`
- `HHAL_VCPU_STATE_MSRS` uses `struct kvm_msrs` plus trailing `struct kvm_msr_entry[]`
- `HHAL_VCPU_STATE_FPU` uses `struct kvm_fpu`
- `HHAL_VCPU_STATE_LAPIC` uses `struct kvm_lapic_state`
- `HHAL_VCPU_STATE_MP` uses `struct kvm_mp_state`
- `HHAL_VCPU_STATE_EVENTS` uses `struct kvm_vcpu_events`
- `HHAL_VCPU_STATE_DEBUG` uses `struct kvm_debugregs`
- `HHAL_VCPU_STATE_XSAVE` uses `struct kvm_xsave`
- `HHAL_VCPU_STATE_XCRS` uses `struct kvm_xcrs`
- `HHAL_VCPU_STATE_SIGNAL_MASK` currently uses one `uint64_t` word for the Linux/x86_64 `KVM_SET_SIGNAL_MASK` payload validated by this artifact

This should be read as a **backend implementation convention**, not as the final portable HHAL ABI.

One asymmetry is intentional:

- `HHAL_VCPU_STATE_SIGNAL_MASK` is write-only in the current Linux backend
- `hhal_vcpu_get_state(... SIGNAL_MASK ...)` returns `HHAL_ERR_UNSUPPORTED`

Reason:

- Linux/KVM exposes `KVM_SET_SIGNAL_MASK`
- it does not expose a matching `KVM_GET_SIGNAL_MASK`

Current artifact constraint:

- on the validated x86_64 host path, `KVM_SET_SIGNAL_MASK` accepted a one-word payload
- a two-word payload failed with `EINVAL`
- the backend therefore currently requires exactly one `uint64_t` word for this Linux/KVM artifact path

## Linux/x86 Helper Layer

`artifact/hhal_linux_x86_helpers.h` and `artifact/hhal_linux_x86_helpers.c` provide a tiny convenience layer for the current backend.

Current helpers:

- CPUID buffer sizing/allocation
- MSR buffer sizing/allocation
- supported CPUID query via `KVM_GET_SUPPORTED_CPUID`

This helper layer is intentionally outside `hhal.h`.

Reason:

- it is Linux/KVM specific
- it improves x86 bring-up ergonomics
- it should not contaminate the portable HHAL core contract

## What the Skeleton Demonstrates

This backend is enough to support the paper’s main claim:

- the outer-layer HHAL API is not hand-wavy
- most major HHAL calls map to one KVM ioctl family or a thin wrapper
- the core object model (`VM`, `VCPU`, `RUN`, memory registration) survives translation cleanly

## What It Does Not Yet Demonstrate

It does not yet prove:

- full state round-trip fidelity
- full IRQ routing fidelity across richer topologies
- migration-ready dirty logging semantics across all kernels
- architecture-generic handling across non-x86 backends
- a complete end-to-end guest boot through HHAL

## Next Implementation Steps

The most valuable next coding steps are:

1. continue reducing the remaining gaps in `hhal_vcpu_get_state()` / `hhal_vcpu_set_state()`
   Suggested next subset:
   - `HHAL_VCPU_STATE_SIGNAL_MASK` helper coverage strategy
   - typed non-KVM-native payload helpers where portability pressure is highest

2. broaden IRQ routing coverage if needed beyond the current `IRQCHIP` and `MSI` paths, or validate actual in-guest interrupt delivery

3. add a tiny backend self-test
   A compile-only artifact is useful, but a smoke test that opens `/dev/kvm`, creates a VM, creates a VCPU, and tears them down would be stronger.

## Smoke Test

`artifact/hhal_linux_smoke_test.c` provides a minimal backend smoke test.

It validates this control path:

1. query KVM API version
2. create VM
3. create VCPU
4. round-trip `REGS`
5. round-trip `SREGS`
6. round-trip `MP` state
7. destroy VCPU and VM

This test is intentionally narrow:

- it does not boot a guest
- it does not run `KVM_RUN`
- it only validates object creation and the minimal state subset

In the current sandbox environment, `/dev/kvm` is absent, so the smoke test can be compiled but not executed here.

## Extended State Test

`artifact/hhal_linux_extended_state_test.c` validates additional x86-oriented state families on a real KVM host.

Current validated families:

- `FPU`
- `LAPIC`
- `EVENTS`
- `DEBUG`
- `XSAVE`
- `XCRS`

This test was especially useful because it exposed real x86/KVM ordering constraints around:

- `KVM_SET_TSS_ADDR`
- `KVM_CREATE_IRQCHIP`
- VCPU creation order relative to irqchip setup

## IRQ Routing Test

`artifact/hhal_linux_irq_routing_test.c` validates the current routing/control-plane implementation on a real KVM host.

Current validated paths:

- `hhal_vm_set_tss_addr()`
- `hhal_vm_create_irqchip()`
- `hhal_vm_set_irq_routing()` with:
  - `HHAL_IRQ_ROUTE_IRQCHIP`
  - `HHAL_IRQ_ROUTE_MSI`
- `hhal_vm_irq_line()` on a routed GSI

This is still a control-plane validation, not proof that a guest OS receives and handles the interrupt correctly.

## Signal Mask Test

`artifact/hhal_linux_signal_mask_test.c` validates the host-side signal-mask control path.

Current validated paths:

- `hhal_vcpu_set_state()` with `HHAL_VCPU_STATE_SIGNAL_MASK`
- `hhal_vcpu_signal_mask()` direct helper path

This validates successful ioctl submission, not guest-visible signal behavior during a long-running `KVM_RUN`.

## Guest IRQ Delivery Test

`artifact/hhal_linux_irq_delivery_guest.c` is the strongest interrupt-path artifact in the current backend.

It validates this end-to-end path:

1. create VM
2. set x86 TSS address
3. create in-kernel irqchip
4. install a routed `GSI 0 -> PIC master pin 0` mapping
5. configure a real-mode guest with an IVT entry for interrupt vector `0x08`
6. assert/deassert `GSI 0`
7. enter the guest with `KVM_RUN`
8. observe the guest interrupt handler mutate guest RAM and halt

This goes beyond control-plane validation and provides guest-observable evidence that routed interrupt delivery works through the current HHAL Linux/KVM backend.

Validated guest-observable outcome:

- the guest interrupt handler executed successfully via routed IRQ0

## Minimal Guest Demo

`artifact/hhal_linux_minimal_guest.c` is the first end-to-end bring-up artifact.

It validates this stronger path:

1. allocate one guest memory page
2. install one-byte guest code: `hlt`
3. create VM and VCPU
4. optionally fetch supported CPUID through the Linux/x86 helper and apply it to the vCPU
5. map guest memory at GPA 0
6. initialize minimal real-mode `SREGS`
7. initialize minimal `REGS` with `RIP = 0`, `RFLAGS = 0x2`
8. call `hhal_vcpu_run()`
9. expect `HHAL_EXIT_HLT`

This is still intentionally minimal:

- no guest kernel
- no paging
- no device model
- no IRQ routing

But it is the first artifact that demonstrates a genuine guest execution path through HHAL rather than only object creation and state round-trip.

For actual host-side execution instructions, see:

- `artifact/run_on_kvm_host.md`
- `artifact/build_kvm_host_artifacts.sh`
