# HHAL to Linux/KVM Mapping

## Purpose

This document maps the abstract HHAL API in `artifact/hhal.h` to a concrete Linux/KVM backend.

It serves two roles:

1. **Paper artifact**
   Reviewers can inspect whether the proposed HHAL boundary is grounded in real KVM control paths.

2. **Implementation guide**
   A future `hhal_linux.c` backend can be built directly from this table.

This is explicitly an **outer-layer mapping**:

- `VMM -> HHAL`
- `HHAL -> Linux/KVM userspace-visible interface`

It is not a mapping of Linux kernel internals such as SRCU, MMU notifiers, GUP, or hrtimer internals.

## Mapping Table

| HHAL API / Type | Linux/KVM binding | Profiled service | Portability note |
|---|---|---|---|
| `hhal_get_api_version()` | `ioctl(/dev/kvm, KVM_GET_API_VERSION)` | `HV_VM_CAPABILITY_QUERY` | Direct KVM feature probe; safe outer-layer primitive |
| `hhal_query_capability()` | `ioctl(/dev/kvm, KVM_CHECK_EXTENSION)` and selected global queries | `HV_VM_CAPABILITY_QUERY`, `HV_VCPU_CPUID_QUERY` | Abstract capability query hides KVM-specific probing style |
| `hhal_vm_create()` | `ioctl(/dev/kvm, KVM_CREATE_VM)` | `HV_VM_CREATE` | KVM returns a VM fd; HHAL returns an opaque handle |
| `hhal_vm_destroy()` | `close(vm_fd)` and backend teardown | no single `HV_*` entry | Destruction is fd-lifetime-driven in KVM; HHAL makes it explicit |
| `hhal_vm_enable_cap()` | `ioctl(vm_fd, KVM_ENABLE_CAP, ...)` | `HV_VM_ENABLE_CAP` | Good example of capability-gated extension point |
| `hhal_vm_set_tss_addr()` | `ioctl(vm_fd, KVM_SET_TSS_ADDR, ...)` | `HV_MEM_SET_TSS` | x86-centric boot plumbing; should remain optional by arch/capability |
| `hhal_vm_set_identity_map_addr()` | `ioctl(vm_fd, KVM_SET_IDENTITY_MAP_ADDR, ...)` | `HV_MEM_SET_IDENTITY_MAP` | Another x86-centric VM bootstrap hook |
| `hhal_vm_map_memory()` | `ioctl(vm_fd, KVM_SET_USER_MEMORY_REGION, ...)` or legacy `KVM_SET_MEMORY_REGION` | `HV_MEM_REGISTER_GPA_RANGE` | Core portable primitive: register guest GPA range backed by host memory |
| `hhal_vm_unmap_memory()` | `KVM_SET_USER_MEMORY_REGION` with `memory_size = 0` for the slot | `HV_MEM_REGISTER_GPA_RANGE` | KVM encodes unmap as a special case of map/update |
| `hhal_vm_get_dirty_log()` | `ioctl(vm_fd, KVM_GET_DIRTY_LOG, ...)` | `HV_MEM_DIRTY_LOG_READ` | Required for migration/checkpoint-style flows |
| `hhal_vm_clear_dirty_log()` | `ioctl(vm_fd, KVM_CLEAR_DIRTY_LOG, ...)` | `HV_MEM_DIRTY_LOG_CLEAR` | Capability-gated on newer KVM behavior |
| `hhal_vcpu_translate_gva()` | `ioctl(vcpu_fd, KVM_TRANSLATE, ...)` | `HV_MEM_GVA_TO_GPA` | Translation is naturally vCPU-scoped; this is cleaner than a VM-level API |
| `hhal_vm_create_irqchip()` | `ioctl(vm_fd, KVM_CREATE_IRQCHIP)` | `HV_IRQ_CHIP_CREATE` | Optional split between in-kernel irqchip and userspace models |
| `hhal_vm_set_irq_routing()` | `ioctl(vm_fd, KVM_SET_GSI_ROUTING, ...)` | `HV_IRQ_ROUTE_CONFIG` | Good abstraction point across KVM-like backends |
| `hhal_vm_irq_line()` | `ioctl(vm_fd, KVM_IRQ_LINE, ...)` | `HV_IRQ_LINE_ASSERT` | Basic level-set primitive |
| `hhal_vm_irq_line_status()` | `ioctl(vm_fd, KVM_IRQ_LINE_STATUS, ...)` when available | `HV_IRQ_LINE_STATUS` | Exposes the status-return path observed in profiling |
| `hhal_vm_bind_irqfd()` | `ioctl(vm_fd, KVM_IRQFD, ...)` | `HV_IRQ_BIND_EVENT` | Fast path still leaks Linux `eventfd` model through `fd` |
| `hhal_vm_bind_ioevent()` | `ioctl(vm_fd, KVM_IOEVENTFD, ...)` | `HV_IO_BIND_EVENT` | Same portability leak as irqfd; pragmatic for QEMU compatibility |
| `hhal_vm_create_pit()` | `ioctl(vm_fd, KVM_CREATE_PIT2, ...)` | `HV_TIMER_PIT_CREATE` | x86 legacy timer; should be capability/arch scoped |
| `hhal_vm_get_clock()` | `ioctl(vm_fd, KVM_GET_CLOCK, ...)` | `HV_CLOCK_GET` | Portable notion exists; KVM struct details are backend-private |
| `hhal_vm_set_clock()` | `ioctl(vm_fd, KVM_SET_CLOCK, ...)` | `HV_CLOCK_SET` | Useful for restore/migration flows |
| `hhal_vcpu_create()` | `ioctl(vm_fd, KVM_CREATE_VCPU, ...)` | `HV_VCPU_CREATE` | KVM returns a vCPU fd; HHAL returns an opaque handle |
| `hhal_vcpu_destroy()` | `close(vcpu_fd)` and backend teardown | no single `HV_*` entry | Same lifetime normalization as VM destroy |
| `hhal_vcpu_run()` | `ioctl(vcpu_fd, KVM_RUN)` plus backend-maintained `mmap`ed run structure | `HV_VCPU_ENTER` | Central execution primitive for any KVM-like backend |
| `struct hhal_run` | `struct kvm_run` exit payload | `KVM_RUN` return path | HHAL intentionally re-expresses KVM exits without exposing `struct kvm_run` directly |
| `hhal_vcpu_get_state()` | family of `KVM_GET_*` ioctls | `HV_VCPU_GET_REGS`, `HV_VCPU_GET_SREGS`, `HV_VCPU_GET_MSRS`, `HV_VCPU_GET_FPU`, `HV_VCPU_GET_MP_STATE`, `HV_VCPU_GET_EVENTS`, `HV_VCPU_GET_DEBUGREGS`, `HV_VCPU_GET_XSAVE`, `HV_VCPU_GET_XCRS`, `HV_IRQ_LAPIC_GET` | Unified state API compresses many ioctl families into one abstract contract |
| `hhal_vcpu_set_state()` | family of `KVM_SET_*` ioctls plus `KVM_SET_SIGNAL_MASK` for `SIGNAL_MASK` | `HV_VCPU_SET_REGS`, `HV_VCPU_SET_SREGS`, `HV_VCPU_SET_MSRS`, `HV_VCPU_SET_FPU`, `HV_VCPU_SET_MP_STATE`, `HV_VCPU_SET_EVENTS`, `HV_VCPU_SET_DEBUGREGS`, `HV_VCPU_SET_XSAVE`, `HV_VCPU_SET_XCRS`, `HV_IRQ_LAPIC_SET`, `HV_VCPU_SET_CPUID` | Most architecture-specific binding surface is concentrated here |
| `hhal_vcpu_interrupt()` | `ioctl(vcpu_fd, KVM_INTERRUPT, ...)` | `HV_IRQ_INJECT` | Models direct interrupt injection to a target vCPU |
| `hhal_vcpu_nmi()` | `ioctl(vcpu_fd, KVM_NMI)` | `HV_VCPU_INJECT_NMI` | x86-oriented but still representable as a capability-gated primitive |
| `hhal_vcpu_signal_mask()` | `ioctl(vcpu_fd, KVM_SET_SIGNAL_MASK, ...)` | `HV_VCPU_SET_SIGNAL_MASK` | Strongly Linux-centric, but operationally useful for a KVM backend |

## State Blob Decoding

`hhal_vcpu_get_state()` and `hhal_vcpu_set_state()` are backed by multiple KVM ioctl families.

Suggested baseline mapping:

| `hhal_state_blob.id` | Linux/KVM ioctl family |
|---|---|
| `HHAL_VCPU_STATE_REGS` | `KVM_GET_REGS` / `KVM_SET_REGS` |
| `HHAL_VCPU_STATE_SREGS` | `KVM_GET_SREGS`, `KVM_SET_SREGS`, or `KVM_GET_SREGS2`, `KVM_SET_SREGS2` |
| `HHAL_VCPU_STATE_CPUID` | `KVM_GET_CPUID2` / `KVM_SET_CPUID2` |
| `HHAL_VCPU_STATE_MSRS` | `KVM_GET_MSRS` / `KVM_SET_MSRS` |
| `HHAL_VCPU_STATE_FPU` | `KVM_GET_FPU` / `KVM_SET_FPU` |
| `HHAL_VCPU_STATE_LAPIC` | `KVM_GET_LAPIC` / `KVM_SET_LAPIC` |
| `HHAL_VCPU_STATE_MP` | `KVM_GET_MP_STATE` / `KVM_SET_MP_STATE` |
| `HHAL_VCPU_STATE_EVENTS` | `KVM_GET_VCPU_EVENTS` / `KVM_SET_VCPU_EVENTS` |
| `HHAL_VCPU_STATE_DEBUG` | `KVM_GET_DEBUGREGS` / `KVM_SET_DEBUGREGS` |
| `HHAL_VCPU_STATE_XSAVE` | `KVM_GET_XSAVE` / `KVM_SET_XSAVE` |
| `HHAL_VCPU_STATE_XCRS` | `KVM_GET_XCRS` / `KVM_SET_XCRS` |
| `HHAL_VCPU_STATE_SIGNAL_MASK` | `KVM_SET_SIGNAL_MASK` only; no symmetric get path in KVM. Current validated Linux/x86_64 artifact path uses one 64-bit word. |

This is the densest part of the backend binding and the clearest place where architecture-specific variation should be isolated behind HHAL.

## Exit Mapping

`struct hhal_run` is a normalized form of selected `struct kvm_run` exits.

Suggested mapping:

| `hhal_run.exit_reason` | KVM exit source |
|---|---|
| `HHAL_EXIT_IO` | `KVM_EXIT_IO` |
| `HHAL_EXIT_MMIO` | `KVM_EXIT_MMIO` |
| `HHAL_EXIT_INTR` | `KVM_EXIT_INTR` |
| `HHAL_EXIT_HLT` | `KVM_EXIT_HLT` |
| `HHAL_EXIT_SHUTDOWN` | `KVM_EXIT_SHUTDOWN` |
| `HHAL_EXIT_SYSTEM_EVENT` | `KVM_EXIT_SYSTEM_EVENT` |
| `HHAL_EXIT_FAIL_ENTRY` | `KVM_EXIT_FAIL_ENTRY` |
| `HHAL_EXIT_INTERNAL_ERROR` | `KVM_EXIT_INTERNAL_ERROR` |
| `HHAL_EXIT_HYPERCALL` | `KVM_EXIT_HYPERCALL` if available, otherwise backend-specific synthesis |
| `HHAL_EXIT_DEBUG` | `KVM_EXIT_DEBUG` |

Two deliberate simplifications:

1. HHAL does not expose the whole `struct kvm_run` union.
2. HHAL only preserves exits that are meaningful to a portable VMM control loop.

## What This Mapping Intentionally Leaves Out

### Host backing-memory syscalls

Not mapped here:

- `mmap`
- `munmap`
- `mlock`
- `memfd_create`
- `madvise`

Reason:

- these belong to VMM runtime memory provisioning
- they are not part of the KVM hypervisor control plane itself

### Linux kernel internal dependencies

Not mapped here:

- MMU notifier
- GUP
- SRCU/RCU
- wait queues
- hrtimer internals

Reason:

- these are backend implementation mechanics
- they belong to the future inner-layer HHAL discussion

### Rare KVM optimizations not yet modeled

Not mapped here:

- `KVM_REGISTER_COALESCED_MMIO`
- VFIO bridging details
- arch-specific debug/profiling controls

Reason:

- they are not required for the MVP portable contract

## Immediate Implications for `hhal_linux.c`

A minimal Linux backend can be built in four layers.

1. **Object layer**
   Wrap `/dev/kvm`, VM fds, and VCPU fds inside opaque HHAL handle structs.

2. **Run layer**
   During `hhal_vcpu_create()`, issue `KVM_GET_VCPU_MMAP_SIZE`, `mmap()` the run structure, and translate `struct kvm_run` to `struct hhal_run`.

3. **State layer**
   Implement blob-id dispatch over the `KVM_GET_*` / `KVM_SET_*` ioctl families.

4. **Capability layer**
   Route `hhal_query_capability()` and `hhal_vm_enable_cap()` through `KVM_CHECK_EXTENSION` and `KVM_ENABLE_CAP`.

## Open Issues Exposed by This Mapping

This mapping also makes the current API weaknesses concrete.

### 1. `signal_mask` and `fd`-based event binding remain Linux-colored

These are acceptable for a Linux/KVM backend, but they are the two clearest portability pressure points in the current outer-layer contract.

## Conclusion

The current `hhal.h` is a credible KVM-grounded outer-layer abstraction:

- nearly every major API can be realized by one KVM ioctl family or a small wrapper around it
- Linux-specific runtime and kernel-internal dependencies are intentionally excluded
- the remaining portability pressure points are explicit and manageable

That is exactly what a paper artifact should demonstrate.
