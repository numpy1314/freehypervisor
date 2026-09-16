# HelenOS port feasibility (architecture study only)

## Recommendation

Do not begin a HelenOS implementation until the Zephyr branch is reproduced on native hardware. For HelenOS, place the reusable Hypervisor Core and privileged VMX/SVM entry path in kernel space (or a tightly scoped privileged kernel component), while exposing an optional userspace control-plane server through IPC. Putting architectural entry/exit entirely in an ordinary userspace server would require new kernel mechanisms for privileged instructions, per-CPU state, interrupt delivery and physical mappings; that is a HelenOS kernel project, not a host adapter alone.

## Authority placement

| Question | Feasible first answer | Reason / required investigation |
|---|---|---|
| Where does the Core live? | Kernel component linked into the HelenOS kernel. | Core directly executes privileged virtualization instructions and expects low-latency per-CPU/vCPU context. A userspace server is viable only after a kernel virtualization facility exists. |
| Where do VMX/SVM operations live? | Core architecture backend in privileged kernel context. | Keep entry/exit and VMCS/VMCB ownership where they are; do not reproduce them in a HelenOS-specific server. |
| Does control plane cross IPC? | Yes, optionally: a userspace VMM/service sends create/run/map/inject requests to a narrow kernel endpoint. | IPC belongs above the substrate contract. The static minimal-Guest phase can avoid it entirely. |
| Who owns physical pages? | Kernel physical-memory manager grants explicitly tracked contiguous/aligned frames to the adapter. | VMXON/VMCS or HSAVE/VMCB, nested page tables and Guest RAM need known PAs and kernel-accessible mappings. |
| Who owns vCPU contexts? | HelenOS kernel threads scheduled by the native scheduler. | Preserves the same “host scheduler owns CPUs” contract used by Linux, Asterinas and Zephyr. |
| How does notification cross boundaries? | Kernel IRQ/IPI path for vCPU kicks; IPC notification only for control-plane completion. | A userspace IPC round trip must not be required inside every VM-exit or pre-entry window. |

## Contract mapping questions to answer from HelenOS source

1. Which kernel API creates a pinned/schedulable thread and joins it safely?
2. Which wait primitive supports condition-install-recheck without stale wake credits?
3. Can the frame allocator provide 4 KiB pages and larger contiguous byte alignment with explicit ownership?
4. What are the kernel PA↔VA rules for normal RAM, high memory and MMIO?
5. Which monotonic clock and absolute/relative timer facilities are safe in the required contexts?
6. How are dedicated local-APIC IPIs allocated without colliding with scheduler/TLB vectors?
7. Can every online CPU execute initialization/teardown on that exact CPU?
8. What kernel/user IPC object model would expose control without leaking HelenOS types into the Core?

## Suggested phases

| Phase | Deliverable | Gate |
|---|---|---|
| H0 | Source-derived HelenOS authority map and privilege analysis | No Core code changes. |
| H1 | Kernel baseline: SMP, threads, wait/wake, timer, PA↔VA, dedicated IPI | All primitives independently pass. |
| H2 | Static Core link plus adapter contract tests | Exact feature-derived contract implemented. |
| H3 | Capability probe and per-CPU virtualization lifecycle | Native enable/disable on every target pCPU. |
| H4 | Minimal static Guest entry/exit | Guest instruction evidence and decoded exit. |
| H5 | Optional userspace control server | IPC overhead/authority measured separately from substrate sufficiency. |

## Principal risks

- HelenOS may not expose safe generic hooks for virtualization enable/disable or dedicated vectors; kernel changes would then be measurable port cost.
- Physical memory authority may be split across kernel and userspace pagers, making Guest RAM ownership the central design issue.
- IPC in the vCPU hot path could change the concurrency/lifetime model and should not be introduced merely to preserve a userspace placement preference.
- A Linux KVM-compatible frontend or Firecracker should not be an initial goal; it is independent of proving that the Core's host contract maps to HelenOS.

This document is deliberately a feasibility decision, not an implementation claim. No HelenOS code or test result is included in the Zephyr milestones.
