# Contract sufficiency assessment

## Claim supported by this experiment

For the pinned Core, x86_64 target, static Linux Guest, and existing SVM backend, the source-derived 25-operation substrate contract is sufficient to move host authority from Linux/Asterinas-style environments to Zephyr without introducing a Zephyr-specific Core API.

This is a bounded claim. It is supported by executable evidence through Guest entry/exit under QEMU's SVM model, not by native KVM execution in the current environment. It does not establish sufficiency for arbitrary device passthrough, control/KVM frontends, other Core features, or other ISAs.

| Required authority | Zephyr realization | Implemented | Independently tested | Used during Core/Guest run |
|---|---|:---:|:---:|:---:|
| Execution context | `k_thread`, CPU mask, dynamic stack, join | yes | yes | yes |
| Blocking/notification | generation-checked `k_sem` wait queue | yes | yes, including forced race/negative control | yes |
| Physical ownership | profile-sized reserved pool with page-state ownership (80 MiB for Linux) | yes | yes, including free/reallocate handoff | yes |
| Addressability | pool offset PA↔VA plus x86 MMU VA→PA query | yes | yes | yes |
| Monotonic time/deadline | uptime ticks→ns, per-pCPU `k_timer`, thread-context Core callback | yes | yes | yes; drives Linux PIT/APIC progress |
| Interrupt ingress | handler registry plus installation into free Zephyr x86 vectors | yes | yes | yes: Linux setup registers the forwarding range and the external-interrupt path dispatches vector 240; a physical passthrough IRQ is not claimed |
| Cross-CPU notification | dedicated local-APIC vector 240 | yes, as adapter extension | yes, CPU1→CPU0 in Guest marker window | yes for progress test, outside formal contract |
| Platform discovery | CPU count/current CPU/custom per-CPU base/TSC rate | yes | yes | yes |
| Architectural virtualization | existing Core SVM, VMCB and NPT | Core-owned | capability probe and TCG execution | yes |

## Why no new operation was needed

Every failure was resolved without giving the Core new host authority:

- eager scheduling required correcting Core publication order, not an OS-specific “spawn-but-do-not-run” call;
- scalar SVM IO required correcting backend decode, not a Zephyr exit hook;
- static teardown composed existing task/join/per-CPU operations and Core `hardware_disable`;
- Linux teardown quiesces Core-owned vLAPIC timers and drops late events at the VM close boundary, without a host cancellation hook;
- notification testing used a dedicated adapter IPI but did not make it a Core dependency;
- Guest RAM, VMCB, NPT and HSAVE all fit the existing physical allocation/addressability authority.

That distinction matters to the research question. A port that “works” only by adding `zephyr_*` calls to the Core would not demonstrate a sufficient substrate contract; this port does not do that.

## Evidence chain

1. Source audit selects 25 operations for the exact target/features and lists every definition and mapping.
2. Baseline proves Zephyr SMP, MMU, thread scheduling, semaphore, spinlock, timer, VA→PA and directed IPI independently of the Core.
3. Contract/lifetime tests force the critical blocking and ownership handoff windows.
4. The architecture path (plus five documented host-neutral fixes) allocates per-pCPU HSAVE, 64 MiB Linux RAM, VMCB/NPT and starts a vCPU thread.
5. Linux 7.1.0-rc6 crosses real/protected/long-mode setup, initializes IOAPIC/PIT/serial, mounts its initramfs, and runs PID 1. PID 1 executes `uname`, reports `pid=1 result=PASS`, then uses scalar I/O to request `SystemDown` through the Core.
6. Cleanup joins the vCPU and disables SVM on both pCPUs.
7. Supplemental micro-Guest runs cover directed IPI and four-vCPU/two-pCPU scheduler stress; they are not substituted for the Linux acceptance run.

## What remains unproven

- native VMX or SVM entry/exit, because `/dev/kvm` and host virtualization flags are absent;
- hardware-accurate interrupt exit timing; the IPI test is under TCG;
- end-to-end physical host-IRQ passthrough through one of the Linux-registered forwarding vectors;
- direct Firecracker execution, because Zephyr has no Linux userspace/KVM device ABI;
- physical-device passthrough semantics beyond the emulated serial/IOAPIC/PIT Linux workload;
- all possible lifetime interleavings or any owner-state enum not present in the pinned source;
- general sufficiency for `shell`, `control`, AArch64, RISC-V or LoongArch feature selections.

The correct conclusion is therefore “implemented and software-execution verified; native-hardware verification blocked,” not an unconditional cross-platform proof.
