# Contract sufficiency assessment

## Claim supported by this experiment

For the pinned Core, x86_64 target, static no-device Guest, and existing SVM backend, the source-derived 25-operation substrate contract is sufficient to move host authority from Linux/Asterinas-style environments to Zephyr without introducing a Zephyr-specific Core API.

This is a bounded claim. It is supported by executable evidence through Guest entry/exit under QEMU's SVM model, not by native KVM execution in the current environment. It does not establish sufficiency for arbitrary device passthrough, control/KVM frontends, other Core features, or other ISAs.

| Required authority | Zephyr realization | Implemented | Independently tested | Used during Core/Guest run |
|---|---|:---:|:---:|:---:|
| Execution context | `k_thread`, CPU mask, dynamic stack, join | yes | yes | yes |
| Blocking/notification | generation-checked `k_sem` wait queue | yes | yes, including forced race/negative control | yes |
| Physical ownership | 16 MiB reserved pool with page-state ownership | yes | yes, including free/reallocate handoff | yes |
| Addressability | pool offset PA↔VA plus x86 MMU VA→PA query | yes | yes | yes |
| Monotonic time/deadline | uptime ticks→ns and one-shot `k_timer` | yes | yes | current time yes; timer path linked |
| Interrupt ingress | handler registry/dispatch | yes | yes | architectural external-IRQ path linked; minimal Guest has no device IRQ |
| Cross-CPU notification | dedicated local-APIC vector 240 | yes, as adapter extension | yes, CPU1→CPU0 in Guest marker window | yes for progress test, outside formal contract |
| Platform discovery | CPU count/current CPU/custom per-CPU base/TSC rate | yes | yes | yes |
| Architectural virtualization | existing Core SVM, VMCB and NPT | Core-owned | capability probe and TCG execution | yes |

## Why no new operation was needed

Every failure was resolved without giving the Core new host authority:

- eager scheduling required correcting Core publication order, not an OS-specific “spawn-but-do-not-run” call;
- scalar SVM IO required correcting backend decode, not a Zephyr exit hook;
- static teardown composed existing task/join/per-CPU operations and Core `hardware_disable`;
- notification testing used a dedicated adapter IPI but did not make it a Core dependency;
- Guest RAM, VMCB, NPT and HSAVE all fit the existing physical allocation/addressability authority.

That distinction matters to the research question. A port that “works” only by adding `zephyr_*` calls to the Core would not demonstrate a sufficient substrate contract; this port does not do that.

## Evidence chain

1. Source audit selects 25 operations for the exact target/features and lists every definition and mapping.
2. Baseline proves Zephyr SMP, MMU, thread scheduling, semaphore, spinlock, timer, VA→PA and directed IPI independently of the Core.
3. Contract/lifetime tests force the critical blocking and ownership handoff windows.
4. The unchanged architecture path (plus three documented host-neutral fixes) allocates per-pCPU HSAVE, Guest RAM, VMCB/NPT and starts a vCPU thread.
5. Guest markers demonstrate execution on the far side of `VMRUN`; CPUID, RDTSC, VMMCALL and scalar IO cause decoded exits; `SystemDown` returns control through the Core.
6. Cleanup joins the vCPU and disables SVM on both pCPUs.
7. Four vCPUs on two Zephyr CPUs complete in repeated oversubscription runs.

## What remains unproven

- native VMX or SVM entry/exit, because `/dev/kvm` and host virtualization flags are absent;
- hardware-accurate interrupt exit timing; the IPI test is under TCG;
- direct Firecracker execution, because Zephyr has no Linux userspace/KVM device ABI;
- passthrough/MMIO/device IRQ semantics beyond adapter registration/dispatch;
- all possible lifetime interleavings or any owner-state enum not present in the pinned source;
- general sufficiency for `shell`, `control`, AArch64, RISC-V or LoongArch feature selections.

The correct conclusion is therefore “implemented and software-execution verified; native-hardware verification blocked,” not an unconditional cross-platform proof.
