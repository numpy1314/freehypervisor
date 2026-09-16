# Linux and Asterinas host-port reference trace

## Evidence sources

| Component | Revision | Location used for this trace |
|---|---|---|
| Hypervisor Core | `534de06e3855a31ff2d74e9faa75c6cdcc2cf8d8` | `tgoskits/virtualization/{axvisor_core,axvm,x86_vcpu,axvisor_api}` |
| Linux host | `66936b14da0f71cac105a9c4b7eb8e25032f13a0` | `linux-host-kernel/drivers/virt/axvisor/` |
| Asterinas host | `68226d2303136dc8bf851937087f4a8c61748575` | `kernel/comps/axvisor-host/src/lib.rs` on `axvisor-host` |

Asterinas' `Cargo.lock` pins the exact Core revision. The Linux submodule contains an earlier vendored API snapshot; its semantic mappings are useful, but its interface set must not be counted as if it were the current Core. The exact discrepancy is recorded in `contract-inventory.md`.

## End-to-end ownership split

The static VMM and vCPU state machine remain in `axvisor_core`; architectural entry/exit, VMCB/NPT construction and per-CPU SVM state remain in `axvm`/`x86_vcpu`. A host adapter supplies execution, blocking, physical ownership, addressability, time, interrupt ingress and topology. Neither Linux, Asterinas nor Zephyr owns a second vCPU loop.

| Capability | Core behavior | Linux reference | Asterinas reference | Zephyr mapping |
|---|---|---|---|---|
| Physical ownership | `axvm` asks for frames/segments; SVM uses `PhysFrame` and contiguous frames; Core constructs NPT. | Linux pages plus an allocation-record table; explicitly registered Guest RAM may be mapped. Current contiguous methods are absent from the pinned older bridge. | OSTD `Frame`/`Segment`, aligned splitting, and `MEMORY_ALLOCS` ownership map. | Dedicated 16 MiB physically contiguous pool with per-page ownership states. |
| Execution contexts | Core creates per-CPU initialization tasks and one task per vCPU; the host scheduler owns dispatch. | Kernel threads/kthreads through the C bridge. | OSTD kernel `Task`, CPU affinity and a publication barrier. | `k_thread` with dynamic stack, CPU mask, completion and opaque handle. |
| Blocking/notification | `VMVCpus` and global VMM each own an API `WaitQueue`; conditions are checked in Core, sleeping/waking is host-provided. | Kernel wait queues and predicate trampoline. | OSTD `WaitQueue`/`Waiter`. | Generation-based `k_sem` wait queue with install/recheck. |
| Time | Core reads monotonic nanoseconds and submits absolute one-shot deadlines. | `ktime_get_ns` plus high-resolution timer. | Asterinas monotonic clock plus architecture one-shot. | Zephyr uptime ticks converted to nanoseconds plus one-shot `k_timer`. |
| Interrupt ingress / kick | Core dispatches VM-exit interrupt vectors and queues virtual interrupts. A host kick only has to cause/observe progress; it must not replace Core exit handling. | Linux IRQ registration/dispatch and host notification mechanisms. | OSTD x86 external IRQ path and IOAPIC routing. | API handler table plus dedicated APIC IPI vector 240, distinct from scheduler 34 and TLB 35. |
| Platform/CPU discovery | Core enumerates pCPUs, pins lifecycle tasks, initializes per-CPU state and asks for x86 TSC frequency. | CPU topology/per-CPU bridge and architecture hook. | `ostd::cpu`, `arch::init_percpu`, `ostd::arch::tsc_freq`. | `arch_num_cpus`, current Zephyr CPU ID, custom `ax-percpu` base, Zephyr cycle frequency. |

## vCPU and virtualization flow

1. `boot::enable_virtualization_on_all_cores` creates one host task pinned to every pCPU.
2. Inside that task, `HostIf::init_percpu` selects the Core's per-CPU area; `AxVMPerCpu::hardware_enable` allocates that CPU's HSAVE page and sets `EFER.SVME`/`VM_HSAVE_PA`.
3. `vmm::init` creates the VM and Core-owned NPT/VMCB state, then `setup_vm_primary_vcpu` publishes `VMVCpus` and creates a host task for the vCPU.
4. The vCPU task blocks through the substrate until `vm.boot()` publishes the running state and wakes it.
5. `vcpu_run` drains queued virtual interrupts, calls Core `vm.run_vcpu`, receives the architectural SVM exit, and handles it in the Core loop.
6. `SystemDown` changes the VM state, wakes peers and lets the last vCPU wake the global VMM waiter.
7. Static teardown joins all vCPU tasks, then creates one pinned exit task per pCPU to execute Core `hardware_disable`, clear SVM state and free the HSAVE page.

VM entry/exit is therefore not in `ports/zephyr`: the adapter never executes `VMRUN`, decodes an exit, builds NPT, or emulates Guest instructions.

## Actual concurrency/lifetime windows in the pinned Core

The pinned source does **not** contain an explicit enum named `Blocked / Pre-entry / Post-commit / InGuest / Exit`. Those earlier labels must not be presented as a state machine that this revision does not have. The real obligations found by tracing `axvisor_core/src/vmm/vcpus.rs` and the host APIs are:

| Window | Producer/owner ordering | Preserved invariant and evidence |
|---|---|---|
| VM-vCPU owner publication | The `VMVCpus` registry must exist before `spawn_task_raw` can schedule the vCPU closure. | Core patch 0001 changes publication order; eager Zephyr scheduling no longer observes a missing owner. |
| Condition-to-block | Consumer checks condition, installs itself and captures generation, rechecks, then sleeps. Producer updates state before advancing generation/waking. | Forced post-install/pre-sleep race passes; stale pre-install wake credit is rejected; deliberately broken negative control loses the wake as expected. |
| Pre-entry interrupt drain | Producer queues an interrupt under the Core lock and wakes; owner drains pending interrupts before each `vm.run_vcpu`. | Source trace; minimal no-device Guest does not claim full device-interrupt coverage. |
| Guest execution | Owner is inside Core SVM `VMRUN`; a host IPI can arrive on the owning pCPU without borrowing or freeing the vCPU. | Three vector-240 IPIs are observed between Guest markers, followed by another Guest marker and clean exit. |
| Exit/close/teardown | Shutdown publishes stopping, wakes all, each vCPU exits, last vCPU wakes VMM, host joins tasks, wait queues drain, then per-CPU SVM is disabled. | Single and 4-vCPU runs show join completion and two independent SVM-off events. |

The tests establish no lost wakeup, no stale wake credit, no task use after join, no allocation reuse while zeroing, in-Guest notification progress, and eventual shutdown. They do not prove every possible interleaving or a nonexistent named owner-state protocol.

## Address translation distinctions

| Object kind | Linux | Asterinas | Zephyr |
|---|---|---|---|
| Adapter-owned frame/segment | Ownership record → page VA/PA | tracked `Frame`/`Segment` in linear map | reserved pool offset mapping |
| Guest RAM | explicitly registered/mapped host pages | tracked segment, linear mapping | 2 MiB-aligned pool allocation; Core maps GPA→HPA in NPT |
| HSAVE/VMCB/NPT | allocated physical frames | allocated host frames/segments | 4 KiB-aligned pool pages |
| General kernel object | validated kernel mapping | architecture mapping | `arch_page_phys_get`, used only by `virt_to_phys`; not accepted by `phys_to_virt` |
| MMIO | explicit `ioremap`/device ownership | architecture/device mapping | not part of the minimal no-device Guest; no arbitrary-MMIO fallback |

This narrower Zephyr mapping is intentional: the adapter grants the Core access only to memory it owns, except for VA→PA discovery needed for already mapped kernel objects.
