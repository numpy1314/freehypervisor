# HHAL API Design Notes

## Purpose

`artifact/hhal.h` defines the **outer-layer** HHAL contract:

- **VMM -> HHAL**
- not **HHAL -> host-kernel internals**

This distinction is critical for the paper. The profiler and source audit show that a portable hypervisor needs two abstraction layers:

1. **Outer layer**: replace userspace-visible syscalls and KVM ioctls with a portable API.
2. **Inner layer**: replace Linux-specific kernel mechanisms such as GUP, MMU notifiers, SRCU, hrtimer, wait queues, and irqfd internals.

`hhal.h` only captures layer 1.

## Design Principles

The header was designed around five constraints.

1. **No Linux/KVM types at the boundary**
   The API does not expose file descriptors as VM/VCPU identity, `struct kvm_run`, `struct kvm_regs`, or Linux signal types as first-class ABI objects.

2. **Opaque execution objects**
   `hhal_vm_t` and `hhal_vcpu_t` are opaque handles so the backend can be KVM today and another host substrate later.

3. **Service-oriented, not ioctl-oriented**
   The interface groups operations by semantic service class: `VM`, `VCPU`, `MEMORY`, `IRQ`, `TIMER/CLOCK`, and event binding.

4. **Architecture-neutral core, extensible edge**
   Common operations are explicit, while architecture-specific state is carried through `hhal_state_blob` IDs starting at `*_ARCH_BASE`.

5. **Run/exit as the central execution loop**
   `hhal_vcpu_run()` and `struct hhal_run` preserve the core control-transfer pattern that every practical VMM needs.

## Coverage Against Profiled Services

The current header covers the dominant outer-layer services identified by `profiler/mapping.yaml` and `kernel_audit/unified_dependency_matrix.md`.

### VM services

- `HV_VM_CAPABILITY_QUERY` -> `hhal_get_api_version()`, `hhal_query_capability()`
- `HV_VM_CREATE` -> `hhal_vm_create()`
- `HV_VM_ENABLE_CAP` -> `hhal_vm_enable_cap()`

### Memory services

- `HV_MEM_REGISTER_GPA_RANGE` -> `hhal_vm_map_memory()`
- `HV_MEM_DIRTY_LOG_READ` -> `hhal_vm_get_dirty_log()`
- `HV_MEM_DIRTY_LOG_CLEAR` -> `hhal_vm_clear_dirty_log()`
- `HV_MEM_GVA_TO_GPA` -> `hhal_vcpu_translate_gva()`
- `HV_MEM_SET_TSS` -> `hhal_vm_set_tss_addr()`
- `HV_MEM_SET_IDENTITY_MAP` -> `hhal_vm_set_identity_map_addr()`

Important boundary choice:

- `mmap`, `munmap`, `mlock`, `madvise`, `memfd_create` are **not** folded into `hhal.h`.
- They are host-OS backing-memory services used by a VMM, but not hypervisor-substrate services in the narrow KVM-like sense.
- For the paper, they should be discussed as adjacent VMM runtime dependencies, not as mandatory VM-control primitives.

### VCPU services

- `HV_VCPU_CREATE` -> `hhal_vcpu_create()`
- `HV_VCPU_ENTER` -> `hhal_vcpu_run()`
- `HV_VCPU_GET_*` / `HV_VCPU_SET_*` families -> `hhal_vcpu_get_state()` / `hhal_vcpu_set_state()`
- `HV_VCPU_INJECT_NMI` -> `hhal_vcpu_nmi()`
- `HV_VCPU_SET_SIGNAL_MASK` -> `hhal_vcpu_signal_mask()`

Important boundary choice:

- The API uses a generic `state_blob` model rather than exporting a separate function per register family.
- This keeps the outer layer architecture-neutral while still allowing exact backend mappings.

### IRQ services

- `HV_IRQ_CHIP_CREATE` -> `hhal_vm_create_irqchip()`
- `HV_IRQ_ROUTE_CONFIG` -> `hhal_vm_set_irq_routing()`
- `HV_IRQ_BIND_EVENT` -> `hhal_vm_bind_irqfd()`
- `HV_IRQ_INJECT` -> `hhal_vcpu_interrupt()`
- `HV_IRQ_LINE_ASSERT` -> `hhal_vm_irq_line()`
- `HV_IRQ_LINE_STATUS` -> `hhal_vm_irq_line_status()`

### IO / event binding services

- `HV_IO_BIND_EVENT` -> `hhal_vm_bind_ioevent()`

Important boundary choice:

- This API includes guest-triggered event binding, but it does not attempt to abstract general host file IO.
- `read`, `write`, `openat`, `pread64`, `epoll_wait`, and similar syscalls belong to the VMM runtime environment, not to the core hypervisor control contract.

### Timer / clock services

- `HV_TIMER_PIT_CREATE` -> `hhal_vm_create_pit()`
- `HV_CLOCK_GET` -> `hhal_vm_get_clock()`
- `HV_CLOCK_SET` -> `hhal_vm_set_clock()`

## Why Some Profiled Services Are Not in `hhal.h`

The profiler intentionally observed a wider dependency surface than the core HHAL contract should expose. That is useful analytically, but it should not be copied mechanically into the API.

The following classes are intentionally excluded from this header.

### 1. Host runtime syscalls

Examples:

- `HV_IO_OPEN`
- `HV_IO_READ`
- `HV_IO_WRITE`
- `HV_EVENT_POLL_WAIT`
- `HV_THREAD_CREATE`

Reason:

- These are part of a VMM process runtime or userspace support library.
- They matter to portability, but they are not specific to the hypervisor substrate.
- If they are included directly, HHAL becomes a general-purpose libc/event/runtime wrapper, which dilutes the paper’s core claim.

### 2. Inner-layer kernel mechanisms

Examples from the audit:

- GUP
- MMU notifier
- SRCU/RCU
- hrtimer internals
- wait queues
- page table walkers

Reason:

- These are essential to a backend implementation.
- They belong to `HHAL -> host-kernel` abstraction, not `VMM -> HHAL`.

### 3. Rare or backend-specific optimizations

Examples:

- coalesced MMIO registration
- VFIO bridge details
- host-specific debug hooks

Reason:

- These should be added only after the minimal portable contract is validated.

## Key API Choices

### Opaque handles instead of fd semantics

KVM uses fd-centric control. HHAL deliberately does not.

Rationale:

- fd identity is Linux-specific.
- another host may not model VM/VCPU as file descriptors at all.
- event binding still uses `fd` today because eventfd-like integration is an interoperability edge with existing VMMs.

### Unified state access

`hhal_vcpu_get_state()` and `hhal_vcpu_set_state()` take a typed blob:

- good for cross-architecture extensibility
- good for capability-gated state groups
- avoids exploding the public API

Tradeoff:

- less type-safe than per-state functions
- requires a companion document that specifies each blob layout

This tradeoff is acceptable for a paper artifact and early backend experimentation.

### Separate `map_memory()` and backing memory management

`hhal_vm_map_memory()` only installs guest-visible mappings.

It does not:

- allocate host backing memory
- pin host pages directly
- create memfds

Rationale:

- allocation and pinning policies vary widely across VMM designs
- the actual hard portability problem is the registration and invalidation contract at the hypervisor boundary

## Known Gaps in the Current Header

These are the most obvious next refinements.

### 1. State layout is documented, but not yet encoded as typed public C structs

`hhal_state_blob` now has a companion layout note, but the common state payloads are still described in markdown rather than exported as strongly typed public C structs.

Needed next:

- optionally add typed public structs for the most common state groups
- keep blob escape hatches for architecture-private extensions

### 2. No VM lifecycle for pause/reset

The current API includes create/destroy/run, but not:

- reset
- pause
- resume
- snapshot hooks

This is acceptable for MVP scope but will matter for a practical backend.

### 3. No explicit userspace-exit completion API

`hhal_vcpu_run()` reports exits, but the protocol for re-enter after IO/MMIO emulation is still implicit in the state carried in `struct hhal_run`.

This is likely still sufficient for a KVM-like backend, but the completion contract should be stated more explicitly in a later revision.

### 4. Event model still leaks Linux assumptions

`struct hhal_ioevent` and `struct hhal_irqfd` still use integer file descriptors.

This is a pragmatic compromise:

- it keeps Linux/QEMU mapping simple
- but it is the least portable part of the current interface

If the paper wants a stricter portability story, a future revision should replace raw `fd` with abstract event handles plus backend import/export hooks.

## Recommended Next Step

The next artifact should be a backend mapping note:

- `artifact/hhal_linux_kvm_mapping.md`

It should contain a table like:

| HHAL API | Linux/KVM binding |
|---|---|
| `hhal_vm_create()` | `KVM_CREATE_VM` |
| `hhal_vm_map_memory()` | `KVM_SET_USER_MEMORY_REGION` |
| `hhal_vcpu_create()` | `KVM_CREATE_VCPU` |
| `hhal_vcpu_run()` | `KVM_RUN` |
| `hhal_vm_bind_irqfd()` | `KVM_IRQFD` |
| `hhal_vm_bind_ioevent()` | `KVM_IOEVENTFD` |

That document will make the artifact directly auditable by reviewers: they can inspect both the abstract contract and its concrete KVM realization.
