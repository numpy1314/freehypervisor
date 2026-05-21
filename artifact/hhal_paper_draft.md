# HHAL: A Portable Outer-Layer Hypervisor Host Abstraction

## Abstract

Virtual machine monitors are commonly written against Linux/KVM-specific control surfaces, which makes backend portability difficult even when guest-facing execution semantics are largely shared across hosts. We present HHAL, a Hypervisor Host Abstraction Layer that targets the outer, VMM-visible boundary between a userspace VMM and the host hypervisor substrate. HHAL provides opaque VM and VCPU objects, a normalized run/exit model, guest memory registration, interrupt control, timer and clock operations, and extensible architecture-specific state transport through typed state identifiers. We implement a Linux/KVM backend and validate it on a real x86_64 host. The artifact demonstrates successful VM/VCPU lifecycle control, minimal guest execution, round-trip transport for multiple x86 state families, IRQ routing, signal-mask programming, and guest-observable interrupt delivery. These results show that the outer hypervisor boundary can be made explicit, compact, and executable without collapsing into raw Linux/KVM interfaces.

## 1. Introduction

Portable VMM construction remains difficult not because virtualization APIs are absent, but because real VMMs depend on a broad, irregular control surface. In practice, a usable host interface must support VM creation, VCPU entry, guest memory registration, state transport across multiple CPU subfamilies, interrupt delivery and routing, timekeeping, and a run/exit protocol that can sustain userspace device emulation. On Linux, these needs are expressed largely through KVM ioctls and associated payload structures. The result is that VMM logic often becomes entangled with Linux/KVM-specific object identities, state layouts, and execution conventions.

This paper argues that the VMM-visible host boundary should be treated as an explicit abstraction problem. We call the resulting interface HHAL, the Hypervisor Host Abstraction Layer. HHAL is intentionally scoped to the outer layer of the portability problem: the part that separates a VMM from the host hypervisor control plane. It does not attempt to abstract away all host-kernel implementation mechanisms. In particular, inner-layer mechanisms such as GUP, MMU notifiers, SRCU, wait queues, and hrtimer internals remain outside the artifact’s implementation scope.

The key motivation is pragmatic. If the outer layer can be named precisely and made executable, then a VMM can be retargeted against a smaller, more stable contract. At the same time, that contract must still be rich enough to express the real services that practical KVM-based VMMs already need. HHAL therefore aims to be neither a theoretical lowest-common-denominator interface nor a direct renaming of KVM ioctls. Instead, it is a service-oriented contract derived from real backend requirements and tested against a functioning Linux/KVM implementation.

This paper makes three contributions:

1. It defines a concrete outer-layer hypervisor abstraction centered on opaque VM and VCPU handles, normalized run/exit semantics, memory registration, interrupt control, and extensible state transport.
2. It shows that this abstraction maps cleanly onto Linux/KVM through a thin backend, rather than requiring a large semantic translation layer.
3. It validates the resulting artifact on a real x86_64 KVM host using executable tests that cover both control-plane and guest-observable behavior.

Figure 1 sketches the intended layering.

```text
                +---------------------------+
                |        Userspace VMM      |
                +-------------+-------------+
                              |
                              |  HHAL API
                              v
                +---------------------------+
                |   HHAL Outer-Layer API    |
                |   VM / VCPU / MEM / IRQ   |
                |   RUN / CLOCK / STATE     |
                +-------------+-------------+
                              |
                              | backend binding
                              v
                +---------------------------+
                |    Linux/KVM Backend      |
                |  ioctl + run translation  |
                +-------------+-------------+
                              |
                              | kernel internals
                              v
                +---------------------------+
                | Linux kernel mechanisms   |
                | GUP / MMU notifier / SRCU |
                | wait queues / hrtimer     |
                +---------------------------+
```

## 2. Related Work

HHAL is closest in spirit to existing userspace hypervisor interfaces such as KVM, which already provide a structured separation between host kernel virtualization support and userspace VMM logic. However, those interfaces are still host-specific. A VMM built directly against KVM inherits KVM’s fd-centric object model, state layouts, interrupt control style, and run-loop conventions.

The broader systems literature also includes interface layers and SDK-style abstractions that attempt to separate execution semantics from host details. HHAL differs in scope. It does not try to provide a universal virtualization runtime, nor does it attempt to abstract unrelated VMM runtime dependencies such as general file IO, threading, or polling APIs. Its target is narrower and more operational: the VMM-visible hypervisor control boundary.

The design also reflects common engineering practice in mature VMMs. Real implementations often accumulate ad hoc wrappers around guest memory registration, state marshaling, exit decoding, and interrupt handling. HHAL makes those recurring dependencies explicit and elevates them into a named interface contract.

## 3. HHAL Design

HHAL is designed around five principles.

First, it does not expose Linux/KVM object identities as part of the portable API. VM and VCPU instances are represented as opaque `hhal_vm_t` and `hhal_vcpu_t` handles rather than file descriptors.

Second, the interface is service-oriented rather than ioctl-oriented. The exported operations are grouped by semantic function: VM management, VCPU management, memory, interrupts, timing, and state transport.

Third, the core is architecture-neutral while the edge is extensible. Common execution services are explicit, but architecture-specific CPU state is carried through `hhal_state_blob` identifiers, allowing the backend to support x86-oriented state families without hardwiring all future architectures into the top-level API surface.

Fourth, run/exit remains the central control loop. The `hhal_vcpu_run()` entry point and the normalized `struct hhal_run` exit structure preserve the essential control-transfer semantics that real VMMs require.

Fifth, the abstraction is intentionally outer-layer only. HHAL captures `VMM -> HHAL`, not `HHAL -> host-kernel internals`.

### 3.1 Service Coverage

The current HHAL interface covers the main VMM-visible service families:

- VM creation, destruction, capability probing, and capability enablement
- guest memory mapping, unmapping, and dirty-log access
- VCPU creation, destruction, execution, and guest-virtual-address translation
- interrupt routing, interrupt line control, direct interrupt injection, and NMI injection
- timer and clock control
- architecture-specific register and control state through `hhal_state_blob`

This coverage is sufficient for a meaningful KVM-grounded outer layer while remaining small enough to audit.

Table 1 summarizes the service split.

| Service Class | Representative HHAL APIs |
|---|---|
| VM lifecycle | `hhal_vm_create()`, `hhal_vm_destroy()`, `hhal_vm_enable_cap()` |
| Memory | `hhal_vm_map_memory()`, `hhal_vm_get_dirty_log()`, `hhal_vcpu_translate_gva()` |
| VCPU execution | `hhal_vcpu_create()`, `hhal_vcpu_run()` |
| Interrupts | `hhal_vm_set_irq_routing()`, `hhal_vm_irq_line()`, `hhal_vcpu_interrupt()` |
| Timer/clock | `hhal_vm_create_pit()`, `hhal_vm_get_clock()`, `hhal_vm_set_clock()` |
| State transport | `hhal_vcpu_get_state()`, `hhal_vcpu_set_state()` |

### 3.2 State Model

The state model is intentionally uniform. Rather than exporting a separate API entry for every CPU register family, HHAL uses `hhal_vcpu_get_state()` and `hhal_vcpu_set_state()` with typed state identifiers. In the Linux backend, this model currently covers:

- `REGS`
- `SREGS`
- `CPUID`
- `MSRS`
- `FPU`
- `LAPIC`
- `MP`
- `EVENTS`
- `DEBUG`
- `XSAVE`
- `XCRS`
- `SIGNAL_MASK` through set-only support

This design compresses a large family of KVM `GET_*` and `SET_*` ioctls into one abstract mechanism while preserving backend-specific realizability.

### 3.3 Boundary Decisions

Several exclusions are deliberate.

Host backing-memory syscalls such as `mmap`, `munmap`, `mlock`, and `memfd_create` are not part of HHAL. They belong to VMM runtime provisioning rather than to the hypervisor control contract itself. Similarly, general runtime services such as `read`, `write`, `openat`, or `epoll_wait` are not treated as HHAL responsibilities.

The main remaining Linux-colored parts of the current API are eventfd-based bindings and signal-mask handling. These are retained because they are operationally important for a Linux/KVM backend, but they remain explicit pressure points for future portability refinement.

## 4. Linux/KVM Backend

The Linux backend in `artifact/hhal_linux.c` is intentionally small, but it is not a compile-only stub. It realizes the HHAL interface through real KVM control paths:

- `/dev/kvm` opening and API probing
- `KVM_CREATE_VM` and `KVM_CREATE_VCPU`
- `KVM_SET_USER_MEMORY_REGION`
- `KVM_RUN`
- multiple `KVM_GET_*` and `KVM_SET_*` state families
- irqchip creation and GSI routing
- direct interrupt and NMI injection
- timer and clock control

The backend also translates selected `struct kvm_run` exit families into a backend-neutral `struct hhal_run`. This is an important design point: the VMM sees a stable exit contract rather than raw KVM unions.

From an implementation standpoint, the backend demonstrates that HHAL can be realized as a thin semantic layer rather than a large emulation framework. The translation logic is concentrated primarily in state dispatch, exit decoding, and a small number of control-plane helper paths.

Figure 2 summarizes the backend mapping pattern.

```text
HHAL VM/VCPU objects
    -> opaque handles
    -> Linux backend structs
    -> /dev/kvm, vm_fd, vcpu_fd

HHAL run/exit
    -> hhal_vcpu_run()
    -> KVM_RUN
    -> struct kvm_run
    -> struct hhal_run

HHAL state blobs
    -> state ID dispatch
    -> KVM_GET_* / KVM_SET_*
```

## 5. Methodology

The artifact follows a build-and-validate methodology rather than a paper-only design methodology. The process has three parts.

First, we define the outer-layer API contract in `hhal.h` and its companion design notes. This stage identifies which services are part of the VMM-visible boundary and which remain outside the scope of the abstraction.

Second, we construct a thin Linux/KVM backend that implements the selected control paths directly enough to test semantic adequacy. The goal is not feature completeness, but executability.

Third, we validate the backend on a real KVM host using purpose-built host-side programs. These programs are structured to test increasingly strong claims: object lifecycle, CPU state transport, minimal guest entry, interrupt routing, signal-mask control, and finally guest-observable interrupt handling.

This methodology is intentionally incremental. Each failure mode encountered during validation is treated as evidence about the adequacy of the abstraction boundary and the backend conventions required to realize it.

## 6. Evaluation

The evaluation goal is not performance measurement. Instead, it is to test whether the proposed abstraction survives contact with a real Linux/KVM host and supports real execution paths beyond object construction.

### 6.1 Experimental Setting

All reported results were obtained on a real x86_64 host with `/dev/kvm` present. Because the user account was not in the `kvm` group, the binaries were executed with `sudo`. This is relevant because it confirms that the artifact was not evaluated in a mocked or simulator-only environment.

### 6.2 Validation Programs

The artifact currently includes six runnable host-side programs:

1. A smoke test for KVM API probing, VM/VCPU lifecycle, and basic register-family round-trips.
2. A minimal guest execution test that maps guest memory, initializes minimal x86 state, enters the guest, and reaches `HLT`.
3. An extended state test that validates additional x86-oriented state families.
4. An IRQ routing test that validates irqchip setup and GSI route installation.
5. A signal-mask test that validates both state-based and helper-based signal-mask programming.
6. A guest interrupt delivery test that validates guest-observable interrupt handling.

Table 2 summarizes the validation matrix.

| Program | Main purpose | Host result |
|---|---|---|
| `hhal_linux_smoke_test` | lifecycle + basic state | pass |
| `hhal_linux_minimal_guest` | guest entry + `HLT` exit | pass |
| `hhal_linux_extended_state_test` | extended x86 state families | pass |
| `hhal_linux_irq_routing_test` | irqchip + routing control plane | pass |
| `hhal_linux_signal_mask_test` | signal-mask control | pass after payload fix |
| `hhal_linux_irq_delivery_guest` | guest-observable interrupt delivery | pass |

### 6.3 Results

The smoke test passed on the real host, demonstrating that:

- `/dev/kvm` could be opened
- VM and VCPU creation succeeded
- `REGS`, `SREGS`, and `MP` round-trips succeeded

The minimal guest test also passed, demonstrating that:

- guest RAM registration succeeded
- minimal x86 state initialization was sufficient for guest entry
- one `KVM_RUN` could reach guest code and return cleanly through `HLT`

The extended state test passed for:

- `FPU`
- `LAPIC`
- `EVENTS`
- `DEBUG`
- `XSAVE`
- `XCRS`

This test was particularly valuable because it exposed real x86/KVM ordering constraints. In particular, successful LAPIC access required the test sequence to establish `KVM_SET_TSS_ADDR`, create an irqchip, and only then create the VCPU in the updated flow.

The IRQ routing test passed for both:

- one `IRQCHIP` route
- one `MSI` route

It also confirmed that a routed GSI could be driven through assert/deassert.

The signal-mask test initially failed when a two-word payload was used. On the validated x86_64 host, `KVM_SET_SIGNAL_MASK` rejected that payload with `EINVAL`. After tightening the Linux backend to the one-word payload accepted on this host, both the state-based and helper-based signal-mask paths passed. This is a useful artifact result because it surfaces a concrete host-side constraint rather than hiding it behind a generic API description.

Finally, the guest interrupt delivery test passed. The final test configuration used repeated `KVM_RUN` re-entry together with host-side interrupt injection until the guest handler mutated a designated memory flag. The successful result provides guest-observable evidence that interrupt delivery through the current backend is not merely a control-plane fiction.

### 6.4 Interpretation

Taken together, these results support the main paper claim: HHAL is executable as a real outer-layer abstraction. The backend is still narrow, but it already supports:

- object lifecycle
- run-loop control
- a non-trivial set of CPU state families
- minimal guest execution
- interrupt routing and delivery
- signal-mask programming

This is substantially stronger than a pure design document, because the abstraction has been forced through real host behavior and several host-specific failure modes.

One useful outcome of this methodology is that failures were informative rather than incidental. For example, validation exposed:

- page-alignment requirements for guest memory registration
- ordering constraints between `KVM_SET_TSS_ADDR`, irqchip creation, and LAPIC access
- the one-word signal-mask constraint accepted on the validated Linux/x86_64 host path
- timing sensitivities in guest-observable interrupt delivery tests

These findings are important because they show that the artifact is not only executable, but also precise enough to surface host-side semantic constraints that a portability layer must eventually represent.

## 7. Discussion

The artifact demonstrates that a portable outer-layer contract can be both compact and operational. The key strength is not breadth, but coherence: the same interface supports VM/VCPU control, state transport, guest entry, interrupt handling, and host-visible validation programs without exposing raw KVM object identity as the public model.

At the same time, the evaluation also reveals where portability pressure concentrates. State transport remains the densest part of the interface. Eventfd-based bindings and signal-mask semantics remain Linux-colored. Interrupt delivery works in the validated artifact path, but richer topologies and device-linked delivery remain unproven.

These are acceptable limitations for the paper stage because the central claim is not that HHAL is finished, but that the VMM-visible hypervisor boundary can be isolated and made executable.

## 8. Threats to Validity

The current evaluation is based on one validated Linux/KVM host path. This is enough to demonstrate executability, but not enough to establish robustness across kernels, CPUs, or host operating systems.

The artifact is also biased toward x86_64 because that is where the backend and validation work are currently deepest. As a result, the strongest claims in this paper should be read as claims about the outer-layer abstraction and its KVM-grounded realizability, not about universal cross-architecture maturity.

Finally, some backend conventions remain implementation-shaped rather than fully abstract. In particular, several state families still use KVM-like layouts internally, and signal-mask handling reflects a Linux-specific control path. These do not invalidate the artifact, but they do limit how strongly one should interpret the current portability story.

## 9. Limitations

The current artifact does not yet prove:

- portability across non-Linux hosts
- a complete migration or restore workflow
- full state-family coverage across all architectures
- robust guest boot beyond minimal handcrafted execution paths
- rich device-model integration
- a coded inner-layer abstraction

In addition, the Linux backend still uses KVM-shaped payload conventions for several state families. This is acceptable as an implementation convention, but it is not yet a final portable ABI.

## 10. Conclusion

HHAL demonstrates that the VMM-facing hypervisor boundary can be made explicit, compact, and executable. The Linux/KVM backend shows that this abstraction is grounded in real host control paths rather than invented for exposition, and the host-side evaluation confirms that the interface supports real execution rather than only object creation. The artifact therefore supports a credible paper claim: a practical outer-layer hypervisor host abstraction can be defined, implemented, and validated without collapsing back into direct Linux/KVM programming.
