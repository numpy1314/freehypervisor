# Zephyr x86_64 substrate contract inventory

## Scope and counting rule

This inventory is derived from source; it does not reuse any earlier 24/26/27/73 count.

| Input | Revision / selection |
|---|---|
| FreeHypervisor repository | `628dec483f0160cbd6035034bf3af4889f6350a4` (port base) |
| Hypervisor Core (`tgoskits`) | `534de06e3855a31ff2d74e9faa75c6cdcc2cf8d8` |
| Core features | `axvisor_core`: `default-features = false`, `svm`; `axvisor_api`: `default-features = false` |
| Target | `x86_64-unknown-none` |
| Linux host snapshot | submodule `66936b14da0f71cac105a9c4b7eb8e25032f13a0` |
| Asterinas host snapshot | `68226d2303136dc8bf851937087f4a8c61748575`, whose lockfile pins the Core revision above |

For this exact target and feature selection, the formal build-time substrate contract contains **25 operations**. The count is reproducible with:

```sh
./scripts/zephyr/audit-contract.py "$FH_CORE_SOURCE" \
  --output artifacts/zephyr/contract-inventory.tsv
```

The script parses the selected `*If` traits and evaluates the relevant target/feature guards. For example, `HostIf::exit` is excluded because `shell` is disabled; non-x86 `ArchIf` methods are excluded. A different revision, target, or feature set can legitimately produce a different count.

“Formal” means that the Rust adapter must implement the method for this build. The evidence column separately distinguishes methods exercised while booting Linux from methods tested only at the adapter level.

Abbreviations below: `C` = Core source, `L` = pinned Linux submodule, `A` = Asterinas reference, `Z` = this Zephyr port; `Linux` = exercised while the Core booted Linux 7.1.0-rc6 to userspace, `adapter` = deterministic contract test, `compile` = linked implementation but not reached by that workload.

## Host and console

| Operation | Required semantics and Core call sites | Linux / Asterinas mapping | Zephyr implementation | Evidence |
|---|---|---|---|---|
| `HostIf::get_host_cpu_num` | Stable number of online host CPUs. Defined at `axvisor_api/src/host.rs:68`; used by `axvisor_core/src/boot.rs` and `vmm/timer.rs`. | L: `axvisor_linux_host_get_cpu_num`; A: `ostd::cpu::num_cpus()` in `kernel/comps/axvisor-host/src/lib.rs`. | `fh_host_cpu_count()` → `arch_num_cpus()`. | adapter + Linux + host SMP |
| `HostIf::init_percpu` | Initialize the Core's per-CPU base on the CPU that will enable/disable virtualization. Defined at `host.rs:72`; called from Core per-CPU startup/teardown tasks. | L: `ax_percpu::init_percpu_reg` plus Linux hook; A: `arch::init_percpu()`. | `HostIfImpl` calls `ax_percpu::init_percpu_reg(fh_current_cpu_id())` using the custom Zephyr per-CPU area. | Linux; both pCPUs enable and disable SVM |
| `ConsoleIf::write_bytes` | Synchronous byte output. Defined at `console.rs:54`; `ConsoleWriter` is used by Core printing. | L: guest-console C bridge; A: `aster_console`, with early-print fallback. | `fh_console_write()` → `printk`. | Linux |
| `ConsoleIf::read_bytes` | Return the number of bytes currently read; zero is valid for the non-interactive static build. Defined at `console.rs:59`; interactive reader is shell-only in this selection. | L: proc/ring console input; A: `read_console_bytes`. | `fh_console_read()` returns zero; no shell feature is linked. | adapter; compile, not Linux runtime |

## Physical memory and addressability

| Operation | Required semantics and Core call sites | Linux / Asterinas mapping | Zephyr implementation | Evidence |
|---|---|---|---|---|
| `MemoryIf::alloc_frame` | Allocate one owned, 4 KiB physical frame. Defined at `memory.rs:80`; used through `PhysFrame` for per-CPU HSAVE and page-table objects. | L: `alloc_pages(..., 0)` plus ownership record; A: `FrameAllocOptions::alloc_frame` plus `MEMORY_ALLOCS`. | One page from the profile-sized reserved pool. | adapter + Linux |
| `MemoryIf::alloc_contiguous_frames` | Allocate `num_frames` contiguous pages aligned to a byte alignment. Defined at `memory.rs:98`; called by `axvm/src/hal.rs`, `axvm/src/vm.rs`, and `x86_vcpu/src/svm/frame.rs`. | The pinned L bridge predates this method; no exact implementation exists in that snapshot. A: aligned `Segment` allocation/splitting. | First-fit contiguous run in the pool, with power-of-two byte alignment. | adapter + Linux (64 MiB Guest RAM, VMCB/NPT pages) |
| `MemoryIf::dealloc_frame` | Return exactly the previously owned single frame. Defined at `memory.rs:112`; used by `PhysFrame::drop`. | L: remove ownership record then `__free_pages`; A: remove tracked `HostMemory::Frame`. | `ALLOCATED → FREEING → zero → FREE`, guarded by a spinlock. | adapter + Linux teardown (HSAVE) |
| `MemoryIf::dealloc_contiguous_frames` | Return the exact base/count from contiguous allocation. Defined at `memory.rs:129`; called from `axvm`/SVM frame drops. | Missing from the pinned L API revision. A: remove tracked `HostMemory::Segment`. | Validate pool range and ownership, zero, then publish free. | adapter + Linux teardown |
| `MemoryIf::phys_to_virt` | Return a host-accessible VA for an owned/mapped PA. Defined at `memory.rs:147`; used for Guest RAM, page tables, VMCB and device access. | L: ownership lookup or explicitly registered RAM mapping; A: linear `paddr_to_vaddr`. | Pool PA → offset in `fh_pool`; out-of-pool addresses are rejected. | adapter + Linux |
| `MemoryIf::virt_to_phys` | Translate mapped kernel VA to PA. Defined at `memory.rs:165`; used by `axvm/src/vm.rs`, address-space HAL and x86 LAPIC. | L: ownership lookup or validated `__pa`; A: architecture linear-map translation. | Pool offset fast path; otherwise Zephyr x86 `arch_page_phys_get`. | adapter + Linux |

The Zephyr pool is 2 MiB aligned and profile-sized: contract tests use 4096 pages (16 MiB), while the Linux profile uses 20480 pages (80 MiB) to hold 64 MiB Guest RAM plus virtualization metadata. It is verified physically contiguous at boot by translating its first and last pages. Allocation traces record PA, page count, byte alignment and sequence number. The pool is dedicated to Core metadata, SVM HSAVE/VMCB/NPT pages and Guest RAM; it is not a general Zephyr allocator.

## Execution contexts

| Operation | Required semantics and Core call sites | Linux / Asterinas mapping | Zephyr implementation | Evidence |
|---|---|---|---|---|
| `TaskIf::spawn_task_raw` | May make the new context runnable immediately; honors stack and CPU mask. Defined at `task.rs:59`; wrapper `spawn_task` is used by Core boot and `vmm/vcpus.rs`. | L: kernel thread C bridge; A: kernel `Task` with registration barrier and `CpuSet`. | Dynamically allocated `k_thread` stack, CPU mask, trampoline and opaque handle. | adapter + Linux + host SMP |
| `TaskIf::join_task` | Wait for exit, then release context resources. Defined at `task.rs:65`; used by vCPU cleanup and patched per-CPU lifecycle. | L: task completion/join bridge; A: `TaskCompletion` wait then map removal. | Completion semaphore, `k_thread_join`, stack free and table-slot release. | adapter + Linux teardown |
| `TaskIf::current_task` | Return the substrate handle for the current adapter-created task, or `None`. Defined at `task.rs:68`; used by `axvisor_core/src/context.rs` and x86 vCPU context. | L/A: current kernel task mapped back to host handle. | Match `k_current_get()` against the adapter task table. | adapter + Linux |
| `TaskIf::yield_now` | Yield to another runnable host thread without implementing a Core scheduler. Defined at `task.rs:71`; used in Core retry/preemption paths. | L: scheduler yield; A: `Task::yield_now()`. | `k_yield()`. | adapter; SMP scheduling exercised |

## Blocking and notification

| Operation | Required semantics and Core call sites | Linux / Asterinas mapping | Zephyr implementation | Evidence |
|---|---|---|---|---|
| `SyncIf::create_wait_queue` | Allocate an independent blocking object. Defined at `sync.rs:80`; `WaitQueue::new` is used by the VMM and each `VMVCpus`. | L: allocated kernel wait queue; A: `Arc<WaitQueue>` registry. | Fixed handle table containing a `k_sem`, spinlock, generation and waiter count. | adapter + Linux |
| `SyncIf::destroy_wait_queue` | Close, wake and drain waiters before reusing the handle. Defined at `sync.rs:83`; called by `WaitQueue::drop`. | L/A: remove registered queue after lifetime synchronization. | Set `closed`, advance generation, wake all, wait for waiter count zero, then release slot. | adapter + Linux cleanup |
| `SyncIf::wait_queue_wait` | Block until a post-install notification or close. Defined at `sync.rs:86`. | L: kernel wait; A: enqueue `Waiter`, then wait. | Generation snapshot plus `k_sem_take`. | adapter close/drain test |
| `SyncIf::wait_queue_wait_until` | Check condition, install waiter, recheck, then sleep; no lost wakeup. Defined at `sync.rs:89`; used by VMM/vCPU waits. | L: predicate trampoline around kernel wait; A: `WaitQueue::wait_until`. | Predicate check → locked generation/waiter publication → predicate recheck → semaphore sleep. | adapter race tests + Linux |
| `SyncIf::wait_queue_wake_one` | Publish a new generation and wake at most one installed waiter. Defined at `sync.rs:92`; last vCPU wakes the VMM. | L/A: native wake-one. | Generation increment under spinlock, then one semaphore give. | adapter + Linux |
| `SyncIf::wait_queue_wake_all` | Publish and wake every installed waiter. Defined at `sync.rs:95`; VM shutdown wakes vCPUs. | L/A: native wake-all. | Generation increment and one semaphore give per registered waiter. | adapter + Linux/host SMP |

## Time, IRQ ingress and x86 discovery

| Operation | Required semantics and Core call sites | Linux / Asterinas mapping | Zephyr implementation | Evidence |
|---|---|---|---|---|
| `TimeIf::current_time_nanos` | Monotonic nanosecond domain. Defined at `time.rs:72`; used by boot selection, vLAPIC/PIT and timer code. | L: `ktime_get_ns`; A: `aster_time::read_monotonic_time`. | `k_uptime_ticks()` converted with `k_ticks_to_ns_floor64`. | adapter + Linux |
| `TimeIf::set_oneshot_timer` | Program an absolute deadline in the same domain. Defined at `time.rs:78`; used by Core timer/rearm paths. | L: high-resolution timer; A: architecture one-shot timer. | Convert absolute deadline to relative `K_NSEC` and start a one-shot `k_timer`; expiry defers Core event checking to `k_work` thread context. | adapter timer test + Linux timer progress |
| `IrqIf::handle_irq` | Dispatch a vector through registered host handlers, returning whether handled. Defined at `irq.rs:25`; Core calls it on external-interrupt VM-exits. | L: Linux IRQ bridge; A: OSTD external-interrupt dispatch on x86. | 256-slot handler table and `fh_irq_handle`. | adapter dispatch test + Linux timer/interrupt path |
| `IrqIf::register_irq_handler` | Install at most one handler for a vector and report collision/failure. Defined at `irq.rs:30`; x86 device setup registers forwarding handlers when configured. | L: IRQ registration/trampoline; A: IOAPIC/GSI route plus handler registry. | Rust atomic handler slot plus dynamically connected C vector-table dispatch. | adapter registration test + Linux |
| `ArchIf::host_tsc_frequency_mhz` | Return nonzero x86 host TSC MHz when known. Defined at `arch.rs:70`; consumed by x86 CPUID emulation. | The pinned L bridge has a hook but its x86 C implementation returns zero (revision gap); A: `ostd::arch::tsc_freq()/1_000_000`. | Zephyr hardware cycle rate divided by one million. | adapter; CPUID VM-exit path exercised |

The dedicated hypervisor kick (`fh_hv_ipi_send`, vector 240), pool-inspection functions, test pause hooks, Rust allocator functions, and `fh_rust_*` entry points are adapter/build extensions. They are **not** counted as formal substrate operations. Likewise, `task::spawn_task`, `WaitQueue` methods and `Drop`, `time::current_time`, `PhysFrame`, and `AxMmHalApiImpl` are Core-side wrappers/helpers, not additional host operations.

## Linux revision gap

The Linux submodule is a real implementation reference, but its vendored `axvisor_api` predates Core `534de06e…`: it contains older host methods while its `MemoryIf` lacks the two current contiguous-allocation methods. Therefore this document does not claim that the pinned Linux bridge can be linked unchanged against the exact current Core. Asterinas and Zephyr implement the exact 25-operation selection; Linux supplies the corresponding kernel-semantic reference where its revision overlaps. Updating Linux to the current API is separate work and was not hidden inside the Zephyr port.
