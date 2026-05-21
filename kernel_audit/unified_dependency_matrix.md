# Unified Host Service Dependency Matrix

**Project**: FreeHypervisor — HHAL (Hypervisor Host Abstraction Layer)
**Date**: 2026-05-18
**Kernel Version**: Linux v6.8
**Methodology**: Static source audit (11 KVM source files, ~32,000 LOC) + Dynamic strace profiling (QEMU/KVM, 40,509 events)

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Methodology & Scope](#2-methodology--scope)
3. [High-Level Dependency Matrix](#3-high-level-dependency-matrix)
4. [Per-Class Detailed Breakdown](#4-per-class-detailed-breakdown)
5. [KVM ioctl → Kernel Dependency Cross-Reference](#5-kvm-ioctl--kernel-dependency-cross-reference)
6. [Abstraction Difficulty Assessment](#6-abstraction-difficulty-assessment)
7. [Key Findings for HHAL Design](#7-key-findings-for-hhal-design)
8. [Appendix: Complete Linux Kernel Subsystem Map](#8-appendix-complete-linux-kernel-subsystem-map)

---

## 1. Executive Summary

This document answers the question: **"What host OS services does a hypervisor actually need?"**

### Core Numbers

| Dimension | Count |
|---|---:|
| KVM source files audited | 11 |
| Lines of kernel code analyzed | ~32,000 |
| Unique Linux kernel APIs used by KVM | **~542** |
| Linux kernel subsystems involved | 25+ |
| KVM ioctls (VMM→kernel boundary) | 8 System + 50+ VM + 40+ VCPU |
| Dynamic events captured (QEMU run) | 40,509 |
| Unique VMM→kernel service interactions | 82 |
| Service classes identified | 14 |

### Top-Level Finding

KVM's host OS dependencies are dominated by four kernel subsystem classes that account for **58%** of all API dependencies:

| Rank | Service Class | APIs | % of Total |
|---|---|---:|---:|
| 1 | SYNC (synchronization primitives) | 101 | 18.6% |
| 2 | MMU/PAGETABLE (memory management) | 58 | 10.7% |
| 3 | THREAD/VCPU (scheduling & CPU state) | 54 | 10.0% |
| 4 | MEMORY (allocation & page management) | 53 | 9.8% |

These four classes represent the **core of what any OS-agnostic hypervisor abstraction must provide**.

### Two-Layer Dependency Architecture

The audit reveals a two-layer dependency structure:

```
┌─────────────────────────────────────────────────────────┐
│  VMM Userspace (QEMU)                                   │
│  ─────────────────────                                  │
│  Boundary: syscalls + KVM ioctls                        │
│  Dynamic profiling: 40,509 events, 82 unique services   │
│  mapping.yaml: 117 mapping rules                        │
├─────────────────────────────────────────────────────────┤
│  Host OS Kernel (Linux)                                  │
│  ─────────────────────                                  │
│  Boundary: kernel-internal API calls                    │
│  Static audit: ~542 unique APIs                         │
│  25+ kernel subsystems                                  │
│  NOT visible to dynamic profiling                       │
└─────────────────────────────────────────────────────────┘
```

The VMM→kernel boundary (syscalls + ioctls) captures only the **tip of the iceberg**. The static audit reveals ~6.6x more dependencies at the kernel-internal layer.

---

## 2. Methodology & Scope

### 2.1 Static Source Audit

Audited 11 source files from Linux v6.8 KVM subsystem:

| File | Lines | APIs | Report |
|---|---:|---:|---|
| `virt/kvm/kvm_main.c` | 6,621 | 276 | `kvm_main_c_audit.md` |
| `arch/x86/kvm/x86.c` | 13,929 | 71 | `arch_x86_kvm_audit.md` |
| `arch/x86/kvm/mmu/mmu.c` | 7,459 | 32 | `arch_x86_kvm_audit.md` |
| `arch/x86/kvm/lapic.c` | 3,315 | 35 | `arch_x86_kvm_audit.md` |
| `arch/x86/kvm/ioapic.c` | 776 | 13 | `arch_x86_kvm_audit.md` |
| `virt/kvm/eventfd.c` | ~730 | 37 | `virt_kvm_audit.md` |
| `virt/kvm/irqchip.c` | ~260 | 17 | `virt_kvm_audit.md` |
| `virt/kvm/vfio.c` | ~380 | 15 | `virt_kvm_audit.md` |
| `virt/kvm/coalesced_mmio.c` | ~180 | 13 | `virt_kvm_audit.md` |
| `virt/kvm/async_pf.c` | ~240 | 17 | `virt_kvm_audit.md` |
| `virt/kvm/pfncache.c` | ~360 | 16 | `virt_kvm_audit.md` |
| **Total** | **~32,250** | **~542** | |

### 2.2 Dynamic Profiling

| Parameter | Value |
|---|---|
| VMM | QEMU 9.2.4 |
| Configuration | x86_64, 512MB RAM, 1 vCPU, KVM acceleration |
| Collection tool | strace `-ff -tt -T -s 256` (no filter, full capture) |
| Guest | Linux vmlinuz-6.8.0-111 (initrd boot, panics early) |
| Lifecycle phases covered | VM_CREATE, VM_BOOT (STEADY_IDLE/STEADY_IO/VM_DESTROY empty due to guest panic) |
| Total raw events | 40,602 |
| Mapped events | 40,509 (99.77%) |

### 2.3 Coverage Gap Analysis

| Aspect | Dynamic Only | Static Only | Both |
|---|---|---|---|
| **Userspace syscalls** | Full (40,509 events) | — | 26 syscall types |
| **KVM ioctls** | 35 distinct ioctls observed | ~100 total from docs | 35 |
| **Kernel-internal APIs** | NOT visible | ~542 unique APIs | — |

Dynamic profiling covers the VMM→kernel boundary well (99.77% mapping rate) but is blind to kernel-internal dependencies. The static audit provides the ground truth for what the kernel KVM module requires from its host OS.

---

## 3. High-Level Dependency Matrix

### 3.1 Service Class × Lifecycle Phase (Dynamic Profiling)

| Service Class | VM_CREATE | VM_BOOT | STEADY_IDLE | STEADY_IO | VM_DESTROY | **Total Events** | **Unique Services** |
|---|---:|---:|---:|---:|---:|---:|---:|
| VCPU | 15,197 | 2,552 | 0 | 0 | 0 | 17,749 | 28 |
| IRQ | 4,594 | 7,939 | 0 | 0 | 0 | 12,533 | 9 |
| EVENT | 853 | 2,939 | 0 | 0 | 0 | 3,792 | 3 |
| SYNC | 1,060 | 1,011 | 0 | 0 | 0 | 2,071 | 1 |
| IO | 1,169 | 1,099 | 0 | 0 | 0 | 2,268 | 13 |
| MEMORY | 1,646 | 118 | 0 | 0 | 0 | 1,764 | 10 |
| THREAD | 10 | 2 | 0 | 0 | 0 | 12 | 2 |
| TIMER | 60 | 12 | 0 | 0 | 0 | 72 | 9 |
| VM | 82 | 2 | 0 | 0 | 0 | 84 | 3 |
| SIGNAL | 48 | 4 | 0 | 0 | 0 | 52 | 2 |
| **Total** | **24,719** | **15,678** | **0** | **0** | **0** | **40,397** | **80** |

### 3.2 Service Class × Kernel API Count (Static Audit)

| Service Class | kvm_main.c | x86.c | mmu.c | lapic.c | ioapic.c | eventfd.c | irqchip.c | vfio.c | coalesced_mmio.c | async_pf.c | pfncache.c | **Total APIs** |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| SYNC | 45 | 24 | 15 | 13 | 4 | 7 | 9 | 4 | 5 | 2 | 6 | **101** |
| MEMORY | 34 | 4 | 7 | 5 | 2 | 3 | 3 | 2 | 8 | 11 | 10 | **53** |
| MMU/PAGETABLE | 39 | 0 | 9 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | **48** |
| THREAD/VCPU | 36 | 13 | 1 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | **54** |
| TIMER/CLOCK | 6 | 14 | 0 | 8 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | **22** |
| EVENT | 10 | 0 | 0 | 0 | 0 | 17 | 0 | 0 | 0 | 4 | 0 | **21** |
| IRQ | 11 | 6 | 0 | 3 | 5 | 8 | 5 | 0 | 0 | 0 | 0 | **13** |
| IO/USER | 11 | 6 | 0 | 0 | 2 | 0 | 0 | 0 | 0 | 0 | 0 | **13** |
| DEVICE/VFIO | 4 | 1 | 0 | 0 | 0 | 2 | 0 | 9 | 0 | 0 | 0 | **11** |
| FILE/FS | 14 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | **14** |
| SIGNAL | 8 | 3 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | **11** |
| NOTIFIER | 5 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | **6** |
| DEBUG/TRACE | 20 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | **20** |
| INIT/BOOT | 33 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | **33** |

> Note: Cross-file deduplication is approximate. APIs appearing in multiple files (e.g., `mutex_lock`) are counted in each file's column but only once in the "Total APIs" column after deduplication.

### 3.3 Combined View: VMM Boundary + Kernel Internal

| Service Class | VMM Boundary Services (Dynamic) | Kernel Internal APIs (Static) | Abstraction Priority |
|---|---:|---:|---|
| **SYNC** | 1 (futex) | 101 | CRITICAL |
| **VCPU** | 28 | 54 | CRITICAL |
| **MEMORY** | 10 | 53 | CRITICAL |
| **MMU/PAGETABLE** | 0 (kernel-internal only) | 48 | CRITICAL |
| **TIMER/CLOCK** | 9 | 22 | HIGH |
| **IRQ** | 9 | 13 | HIGH |
| **EVENT** | 3 | 21 | HIGH |
| **IO** | 13 | 13 | HIGH |
| **DEVICE/VFIO** | 0 (kernel-internal only) | 11 | MODERATE |
| **THREAD** | 2 | 54 | HIGH |
| **FILE/FS** | 0 (kernel-internal only) | 14 | MODERATE |
| **SIGNAL** | 2 | 11 | MODERATE |
| **NOTIFIER** | 0 (kernel-internal only) | 6 | MODERATE |
| **VM** | 3 | 0 (handled via FILE/FS) | LOW |

---

## 4. Per-Class Detailed Breakdown

### 4.1 SYNC — Synchronization Primitives

**Kernel Internal APIs: 101 | VMM Boundary Services: 1 | Abstraction Difficulty: MODERATE**

KVM uses virtually every Linux synchronization primitive. Concepts are universal, but API details differ across OS kernels.

| Subcategory | Key APIs | Used In | Abstraction Approach |
|---|---|---|---|
| **Mutex** | `mutex_init`, `mutex_lock`, `mutex_unlock`, `mutex_lock_killable` | All files | Standard primitive — direct mapping |
| **Spinlock** | `spin_lock`, `spin_unlock`, `raw_spin_lock_irqsave` | kvm_main, x86, lapic, ioapic, eventfd, coalesced_mmio, pfncache | Standard primitive — direct mapping |
| **SRCU** | `init_srcu_struct`, `srcu_read_lock/unlock`, `synchronize_srcu_expedited` | All major files | OS-specific — needs adapter |
| **RCU** | `rcu_read_lock/unlock`, `rcu_dereference`, `rcu_assign_pointer` | kvm_main, x86, mmu, lapic, irqchip | OS-specific — needs adapter |
| **RW semaphore** | `down_read/up_read`, `down_write/up_write`, `write_lock_irq` | x86, pfncache | Standard primitive — direct mapping |
| **Atomic ops** | `atomic_set/read/inc/dec`, `atomic_long_*`, `refcount_*`, `WRITE_ONCE/READ_ONCE` | All files | Universal — direct mapping |
| **Seqcount** | `raw_seqcount_begin`, `seqcount_retry` | eventfd | OS-specific — needs adapter |
| **Wait/completion** | `init_completion`, `complete`, `wait_for_completion`, `rcuwait_*` | kvm_main, eventfd | Standard primitive — direct mapping |
| **Xarray** | `xa_init/destroy/store/erase/release/reserve` | kvm_main | OS-specific — needs data structure port |
| **Data structures** | `RB_ROOT`, `interval_tree_*`, `hash_*`, `list_*`, `hlist_*` | kvm_main | Standard algorithms — direct port |

**VMM Boundary**: `futex` syscall (2,071 events) — userspace synchronization.

### 4.2 MEMORY — Memory Allocation & Page Management

**Kernel Internal APIs: 53 | VMM Boundary Services: 10 | Abstraction Difficulty: HIGH**

Memory management is the deepest and most OS-specific dependency. KVM relies on Linux's slab allocator, page allocator, GUP, and page lifecycle management.

| Subcategory | Key APIs | Purpose | Lifecycle Phase |
|---|---|---|---|
| **Page allocator** | `alloc_page`, `__get_free_page`, `get_zeroed_page`, `free_page` | Page table pages, vcpu->run page, ring buffers | Create/Destroy |
| **Slab allocator** | `kmem_cache_*`, `kzalloc`, `kmalloc`, `kfree`, `kvfree`, `kvmalloc_array` | VCPU structs, MMU cache, routing tables, APIC state | Create/Run/Destroy |
| **Page lifecycle** | `get_page`, `put_page`, `mark_page_accessed`, `SetPageDirty` | Guest page reference tracking | Run |
| **Page mapping** | `kmap`, `kunmap`, `memremap`, `memunmap`, `page_address` | Map guest pages for kernel access | Run |
| **PFN management** | `pfn_valid`, `pfn_to_page`, `page_to_pfn`, `page_to_phys` | Guest physical address translation | Run |
| **GUP (pin user pages)** | `get_user_pages`, `get_user_pages_fast`, `get_user_pages_unlocked`, `get_user_pages_remote`, `follow_pte`, `fixup_user_fault` | Pin VMM memory for DMA, device passthrough | Run |
| **Page flags** | `PageReserved`, `is_zero_pfn`, `is_zone_device_page`, `page_count` | Page type detection for MMU decisions | Run |
| **Memory attributes** | `virt_to_page`, `set_page_private`, `offset_in_page` | Shadow page tracking metadata | Run |

**VMM Boundary** (10 services, 1,764 events):
- `mmap` (444) → `HV_MEM_ALLOC_BACKING`
- `mprotect` (450) → `HV_MEM_PROTECT`
- `madvise` (633) → `HV_MEM_ADVISE`
- `munmap` (24) → `HV_MEM_FREE_BACKING`
- `brk` (119) → `HV_MEM_HEAP_ADJUST`
- `memfd_create` (3) → `HV_MEM_MEMFD_CREATE`
- `KVM_SET_USER_MEMORY_REGION` (88) → `HV_MEM_REGISTER_GPA_RANGE`
- `KVM_GET_DIRTY_LOG` (2) → `HV_MEM_DIRTY_LOG_READ`
- `KVM_SET_TSS_ADDR` (1) → `HV_MEM_SET_TSS`
- `KVM_SET_IDENTITY_MAP_ADDR` (1) → `HV_MEM_SET_IDENTITY_MAP`

### 4.3 MMU/PAGETABLE — Virtual Memory & Page Table Management

**Kernel Internal APIs: 48 | VMM Boundary Services: 0 | Abstraction Difficulty: CRITICAL**

This is the most OS-coupled subsystem. KVM walks host page tables using Linux-specific APIs and registers MMU notifiers for reverse mapping.

| Subcategory | Key APIs | Purpose | Abstraction Challenge |
|---|---|---|---|
| **MMU notifiers** | `mmu_notifier_register/unregister`, `mmu_notifier_range_blockable` | Track VMM address space changes for shadow/EPT invalidation | Linux-specific callback infrastructure |
| **Host page table walk** | `pgd_offset`, `p4d_offset`, `pud_offset`, `pmd_offset` | Walk host page tables to find guest page mappings | Linux-specific page table layout macros |
| **Page table entry ops** | `pgd_none`, `pud_none/present`, `pmd_none/present`, `pte_pfn`, `pte_write`, `ptep_get`, `pte_unmap_unlock` | Inspect and manipulate host PTEs | Tightly coupled to arch page table format |
| **VMA operations** | `find_vma`, `vma_lookup`, `vma_kernel_pagesize`, `vma_is_valid` | Validate VMM memory regions during guest faults | Linux VMA abstraction is unique |
| **mmap lock** | `mmap_read_lock/unlock` | Protect address space operations during GUP | Standard rwlock, but tied to Linux mm subsystem |
| **Reverse mapping** | `RB_ROOT`, `interval_tree_*`, `hash_*` | Track which SPTEs map a given GFN | Standard data structures — portable |
| **Dirty bitmap** | `bitmap_set`, `set_bit_le`, `atomic_long_fetch_andnot` | Track modified guest pages for live migration | Standard bit manipulation — portable |

**No VMM boundary representation** — MMU/PAGETABLE is entirely kernel-internal. An HHAL must provide these as internal primitives, not as VMM-visible services.

### 4.4 THREAD/VCPU — CPU Scheduling & State Management

**Kernel Internal APIs: 54 | VMM Boundary Services: 28 | Abstraction Difficulty: HIGH**

| Subcategory | Key APIs | Purpose |
|---|---|---|
| **Kernel threads** | `kthread_run/park/parkme/should_stop` | VM worker threads |
| **Task management** | `get_task_struct`, `put_task_struct`, `get_task_pid`, `put_pid`, `pid_nr` | VCPU task reference tracking |
| **Scheduling** | `yield_to`, `set_user_nice`, `cgroup_attach_task_all` | VCPU scheduling hints |
| **Preemption control** | `preempt_disable/enable`, `get_cpu/put_cpu`, `preempt_notifier_*` | Per-CPU MSR access, vcpu load/put hooks |
| **Per-CPU data** | `this_cpu_read/write`, `__this_cpu_read/write`, `this_cpu_cpumask_var_ptr` | Per-VCPU state |
| **CPU feature detection** | `boot_cpu_has`, `cpu_feature_enabled`, `wrmsrl`, `rdmsrl` | Host CPU capability checks |
| **Cross-CPU calls** | `smp_call_function_single`, `smp_call_function_many`, `on_each_cpu_mask` | IPIs for TLB flush, MSR sync |
| **FPU** | `switch_fpu_return`, `kernel_fpu_begin/end` | Host/guest FPU state switch |
| **Completion/wait** | `init_completion`, `complete`, `wait_for_completion`, `rcuwait_*` | VCPU blocking/waking |

**VMM Boundary** (28 services, 17,749 events — highest count):
- `KVM_RUN` (17,695) → `HV_VCPU_ENTER` — dominates all events
- `KVM_CREATE_VCPU` (1) → `HV_VCPU_CREATE`
- 26 register/state ioctls (GET/SET_REGS, MSRS, SREGS, FPU, XSAVE, XCRS, etc.)

### 4.5 TIMER/CLOCK — Timer & Clock Services

**Kernel Internal APIs: 22 | VMM Boundary Services: 9 | Abstraction Difficulty: HIGH**

LAPIC timer emulation is tightly coupled to Linux `hrtimer` and `cpufreq` notifiers.

| Subcategory | Key APIs | Purpose | OS Coupling |
|---|---|---|---|
| **hrtimer** | `hrtimer_init`, `hrtimer_start`, `hrtimer_cancel` | APIC timer emulation | HIGH — Linux hrtimer subsystem |
| **ktime** | `ktime_get`, `ktime_get_raw`, `ktime_get_real_ns`, `ktime_to_ns`, `ktime_add`, `ktime_sub`, `ktime_after` | Time arithmetic | MODERATE — standard timekeeping |
| **TSC** | `rdtsc`, `rdtsc_ordered` | TSC offset/scale computation | LOW — hardware instruction |
| **cpufreq** | `cpufreq_register/unregister_notifier`, `cpufreq_quick_get`, `cpufreq_cpu_get/put` | TSC frequency change notification | HIGH — Linux cpufreq subsystem |
| **pvclock** | `pvclock_gtod_register_notifier`, `pvclock_gtod_notify` | Guest TOD clock sync | HIGH — Linux clocksource subsystem |
| **Delay** | `__delay`, `ndelay`, `cpu_relax` | Busy-wait for calibration | LOW — hardware primitives |

**VMM Boundary** (9 services, 72 events):
- `clock_nanosleep` (58) → `HV_TIMER_SLEEP`
- `KVM_CREATE_PIT2` (1), `KVM_GET/SET_PIT2` (7), `KVM_GET/SET_CLOCK` (3), `KVM_GET/SET_TSC_KHZ` (3), `KVM_KVMCLOCK_CTRL` (1)

### 4.6 IRQ — Interrupt Management

**Kernel Internal APIs: 13 | VMM Boundary Services: 9 | Abstraction Difficulty: HIGH**

| Subcategory | Key APIs | Purpose |
|---|---|---|
| **IRQ injection** | `kvm_set_irq`, `kvm_apic_set_irq`, `kvm_irq_delivery_to_apic` | Inject interrupts into guest |
| **IRQ routing** | `kvm_irq_map_gsi`, `kvm_irq_map_chip_pin`, `kvm_setup_default_irq_routing` | Route GSI to destination |
| **IRQ bypass** | `irq_bypass_register/unregister_producer/consumer` | Posted interrupts (performance optimization) |
| **CPU hotplug** | `cpus_read_lock/unlock`, `cpuhp_setup_state_nocalls`, `on_each_cpu` | Hardware virt enable/disable on CPU online/offline |
| **APIC** | `kvm_apic_match_dest`, `kvm_apic_local_deliver` | APIC destination matching |

**VMM Boundary** (9 services, 12,533 events):
- `KVM_IRQ_LINE_STATUS` (12,518) — dominates IRQ events (high-frequency tick)
- `KVM_IRQFD` (4), `KVM_SET_GSI_ROUTING` (5), `KVM_CREATE_IRQCHIP` (1), etc.

### 4.7 EVENT — Event Notification

**Kernel Internal APIs: 21 | VMM Boundary Services: 3 | Abstraction Difficulty: HIGH**

| Subcategory | Key APIs | Purpose |
|---|---|---|
| **eventfd** | `eventfd_ctx_fileget/fdget/put`, `eventfd_signal`, `eventfd_ctx_do_read`, `eventfd_ctx_remove_wait_queue` | irqfd/ioeventfd event signaling |
| **Wait queue** | `init_waitqueue_func_entry`, `add_wait_queue_priority`, `remove_wait_queue` | Custom wait queue callbacks for irqfd |
| **Poll** | `vfs_poll` | Poll eventfd for IRQ events |
| **Workqueue** | `INIT_WORK`, `schedule_work`, `flush_work`, `queue_work`, `alloc_workqueue`, `destroy_workqueue` | Deferred event processing |
| **Uevent** | `add_uevent_var`, `kobject_uevent_env` | VM create/destroy notifications |
| **Page fault (VM)** | `vmf->page`, `vma_pages` | VCPU mmap page fault handling |

**VMM Boundary** (3 services, 3,792 events):
- `ppoll` (3,781) → `HV_EVENT_POLL_WAIT`
- `eventfd2` (9) → `HV_EVENT_CREATE`
- `epoll_create1` (2) → `HV_EVENT_POLL_INIT`

### 4.8 IO — I/O & Data Transfer

**Kernel Internal APIs: 13 | VMM Boundary Services: 13 | Abstraction Difficulty: MODERATE**

| Subcategory | Key APIs | Purpose |
|---|---|---|
| **User-kernel copy** | `copy_to/from_user`, `__copy_to/from_user`, `__copy_from_user_inatomic` | ioctl data transfer |
| **Address validation** | `access_ok`, `untagged_addr` | Verify user space addresses |
| **Page fault control** | `pagefault_disable/enable` | Atomic guest memory access |
| **Compat** | `compat_ptr`, `get_compat_sigset`, `is_compat_task` | 32-bit compat ioctl handling |

**VMM Boundary** (13 services, 2,268 events):
- File I/O syscalls: `writev` (1,390), `read` (304), `write` (199), `openat` (126), etc.
- KVM ioctls: `KVM_IOEVENTFD` (12), `KVM_REGISTER/UNREGISTER_COALESCED_MMIO` (32), `KVM_GET_DEVICE_ATTR` (4)

### 4.9 DEVICE/VFIO — Device Passthrough

**Kernel Internal APIs: 11 | VMM Boundary Services: 0 | Abstraction Difficulty: MODERATE**

| Key APIs | Purpose | Coupling Pattern |
|---|---|---|
| `symbol_get`/`symbol_put` | Dynamic VFIO symbol resolution | **Loosest coupling** — runtime binding |
| `vfio_file_set_kvm`, `vfio_file_enforced_coherent`, `vfio_file_is_valid`, `vfio_file_iommu_group` | VFIO-KVM bridge operations | Via symbol_get — no compile-time dep |
| `iommu_group_put` | IOMMU group management | Standard refcounting |
| `kvm_io_bus_register_dev/unregister_dev` | MMIO/PIO bus device registration | KVM-internal API |

**No direct VMM boundary** — VFIO is entirely kernel-internal. QEMU interacts with VFIO via its own `/dev/vfio/*` interface, not through KVM ioctls.

### 4.10 FILE/FS — Filesystem & Device Registration

**Kernel Internal APIs: 14 | VMM Boundary Services: 0 | Abstraction Difficulty: MODERATE**

| Key APIs | Purpose |
|---|---|
| `anon_inode_getfd`, `anon_inode_getfile` | Create anonymous inodes for VM/VCPU/device fds |
| `get_unused_fd_flags`, `put_unused_fd`, `fd_install` | File descriptor lifecycle |
| `misc_register`, `misc_deregister` | Register `/dev/kvm` character device |
| `debugfs_create_dir/file`, `debugfs_remove_recursive`, `debugfs_lookup` | Debug filesystem entries |

### 4.11 SIGNAL — Signal Handling

**Kernel Internal APIs: 11 | VMM Boundary Services: 2 | Abstraction Difficulty: MODERATE**

| Key APIs | Purpose |
|---|---|
| `sigprocmask`, `sigemptyset`, `sigdelsetmask`, `sigmask` | VCPU signal mask management (KVM_SET_SIGNAL_MASK) |
| `signal_pending` | Check for pending signals in VCPU run loop |
| `user_return_notifier_register/unregister` | MSR save/restore on userspace return |

**VMM Boundary** (2 services, 52 events):
- `rt_sigprocmask` (44) → `HV_SIGNAL_MASK`
- `rt_sigaction` (8) → `HV_SIGNAL_HANDLER_SET`

### 4.12 NOTIFIER — System Event Notifications

**Kernel Internal APIs: 6 | VMM Boundary Services: 0 | Abstraction Difficulty: MODERATE**

| Key APIs | Purpose |
|---|---|
| `register_pm_notifier`/`unregister_pm_notifier` | PM suspend/resume hooks |
| `register_syscore_ops`/`unregister_syscore_ops` | System suspend/resume/shutdown hooks |
| `pvclock_gtod_register_notifier` | Host clocksource change notification |
| `cpufreq_register_notifier` | CPU frequency change notification |
| `perf_register_guest_info_callbacks` | Intel PT guest callbacks |
| `preempt_notifier_register/unregister` | VCPU scheduling hooks |

---

## 5. KVM ioctl → Kernel Dependency Cross-Reference

### 5.1 System ioctls (on `/dev/kvm`)

| ioctl | HHAL Service | Key Kernel Dependencies |
|---|---|---|
| `KVM_GET_API_VERSION` | `HV_VM_CAPABILITY_QUERY` | Simple constant return |
| `KVM_CREATE_VM` | `HV_VM_CREATE` | `kzalloc`, `mmgrab`, `mutex_init`, `init_srcu_struct`, `mmu_notifier_register`, `anon_inode_getfd`, `alloc_page` |
| `KVM_CHECK_EXTENSION` | `HV_VM_CAPABILITY_QUERY` | Simple capability lookup |
| `KVM_GET_VCPU_MMAP_SIZE` | `HV_VCPU_MMAP_SIZE_QUERY` | Compile-time constant |
| `KVM_GET_SUPPORTED_CPUID` | `HV_VCPU_CPUID_QUERY` | `boot_cpu_has`, CPU feature enumeration |
| `KVM_GET_MSR_INDEX_LIST` | `HV_VCPU_MSR_LIST_QUERY` | Static MSR list |
| `KVM_GET_MSR_FEATURE_INDEX_LIST` | `HV_VCPU_MSR_FEATURE_QUERY` | MSR capability check |

### 5.2 VM ioctls — Top-10 by Dynamic Frequency

| ioctl | Events | HHAL Service | Key Kernel Dependencies |
|---|---:|---|---|
| `KVM_IRQ_LINE_STATUS` | 12,518 | `HV_IRQ_LINE_STATUS` | `kvm_set_irq`, SRCU, `trace_kvm_set_irq` |
| `KVM_SET_USER_MEMORY_REGION` | 88 | `HV_MEM_REGISTER_GPA_RANGE` | `get_user_pages*`, `mmap_read_lock`, MMU notifiers, SRCU |
| `KVM_IOEVENTFD` | 12 | `HV_IO_BIND_EVENT` | `eventfd_ctx_*`, `kvm_io_bus_register_dev`, workqueue |
| `KVM_REGISTER_COALESCED_MMIO` | 22 | `HV_IO_MMIO_COALESCED_REGISTER` | `kzalloc`, `spin_lock`, `list_add` |
| `KVM_IRQFD` | 4 | `HV_IRQ_BIND_EVENT` | `eventfd_ctx_*`, wait queue, `irq_bypass_*`, workqueue |
| `KVM_SET_GSI_ROUTING` | 5 | `HV_IRQ_ROUTE_CONFIG` | SRCU, RCU, `kzalloc/kfree`, `synchronize_srcu_expedited` |
| `KVM_ENABLE_CAP` | 6 | `HV_VM_ENABLE_CAP` | Capability-specific (may involve IOMMU, etc.) |
| `KVM_CREATE_IRQCHIP` | 1 | `HV_IRQ_CHIP_CREATE` | `kzalloc`, `mutex`, SRCU, arch callbacks |
| `KVM_SET_IRQCHIP` | 3 | `HV_IRQ_CHIP_SET` | `copy_from_user`, `spin_lock`, mutex |
| `KVM_CREATE_PIT2` | 1 | `HV_TIMER_PIT_CREATE` | `kzalloc`, `hrtimer_init`, mutex |

### 5.3 VCPU ioctls — Top-5 by Dynamic Frequency

| ioctl | Events | HHAL Service | Key Kernel Dependencies |
|---|---:|---|---|
| `KVM_RUN` | 17,695 | `HV_VCPU_ENTER` | SRCU, preempt_notifier, `schedule`, `signal_pending`, `copy_to/from_user`, `get_user_pages`, arch VM entry/exit |
| `KVM_SET_MSRS` | 8 | `HV_VCPU_SET_MSRS` | `wrmsrl`, `rdmsrl`, `preempt_disable`, `copy_from_user` |
| `KVM_SMI` | 11 | `HV_VCPU_INJECT_SMI` | `kvm_apic_set_irq`, `kvm_queue_exception` |
| `KVM_GET_MSRS` | 14 | `HV_VCPU_GET_MSRS` | `rdmsrl`, `preempt_disable`, `copy_to_user` |
| `KVM_SET_SREGS2` | 3 | `HV_VCPU_SET_SREGS` | `kvm_mmu_reset_context`, arch register loading |

---

## 6. Abstraction Difficulty Assessment

### 6.1 Difficulty Matrix

| Service Class | API Count | Conceptual Universality | API Portability | Integration Depth | **Overall Difficulty** |
|---|---:|---|---|---|---|
| SYNC | 101 | HIGH | LOW (SRCU/RCU/xarray) | DEEP (every file) | **MODERATE** |
| MEMORY | 53 | HIGH | LOW (slab/GUP/memremap) | DEEP (core path) | **HIGH** |
| MMU/PAGETABLE | 48 | MODERATE | LOW (Linux PTE walk) | VERY DEEP (mmu.c) | **CRITICAL** |
| THREAD/VCPU | 54 | HIGH | MODERATE (kthread/preempt) | DEEP (run loop) | **HIGH** |
| TIMER/CLOCK | 22 | HIGH | LOW (hrtimer/cpufreq/pvclock) | DEEP (lapic.c) | **HIGH** |
| EVENT | 21 | MODERATE | LOW (eventfd/waitqueue) | MODERATE (eventfd.c) | **HIGH** |
| IRQ | 13 | HIGH | MODERATE (irq_bypass is Linux-specific) | MODERATE | **HIGH** |
| IO | 13 | HIGH | HIGH (copy_to/from_user are standard) | SHALLOW | **MODERATE** |
| DEVICE/VFIO | 11 | MODERATE | MODERATE (symbol_get pattern is portable) | SHALLOW (loose coupling) | **MODERATE** |
| FILE/FS | 14 | MODERATE | LOW (anon_inode/misc_device) | SHALLOW | **MODERATE** |
| SIGNAL | 11 | HIGH | MODERATE | SHALLOW | **MODERATE** |
| NOTIFIER | 6 | HIGH | LOW (Linux notifier chains) | SHALLOW | **LOW** |

### 6.2 Critical Abstraction Path

The following dependencies form the **minimum viable abstraction** for a portable hypervisor:

```
┌───────────────────────────────────────────────────────────┐
│              HHAL Minimum Viable Abstraction               │
├───────────────────────────────────────────────────────────┤
│                                                           │
│  1. Page Management (MEMORY + MMU/PAGETABLE)              │
│     - alloc_page, free_page, get_zeroed_page              │
│     - GUP (pin user pages)                                │
│     - Page table walk (pgd/pud/pmd/pte)                   │
│     - MMU notifier (reverse mapping invalidation)         │
│     - kmap/memremap (I/O memory mapping)                  │
│                                                           │
│  2. CPU State (THREAD/VCPU)                               │
│     - Kernel thread creation/management                   │
│     - Preemption control + per-CPU data                   │
│     - MSR read/write + CPUID feature detection            │
│     - FPU state save/restore                              │
│     - Cross-CPU function calls (IPI)                      │
│                                                           │
│  3. Timer (TIMER/CLOCK)                                   │
│     - High-resolution timer (hrtimer equivalent)          │
│     - Monotonic/wall-clock time sources                   │
│     - CPU frequency change notification                   │
│     - TSC access + virtualization                         │
│                                                           │
│  4. Interrupt (IRQ)                                       │
│     - Interrupt injection (IRQ routing + APIC)            │
│     - Eventfd + IRQ bypass for fast path                  │
│     - CPU hotplug for hardware virt enable/disable         │
│                                                           │
│  5. Synchronization (SYNC)                                │
│     - Mutex, spinlock, RW lock                            │
│     - RCU/SRCU or equivalent                              │
│     - Atomic operations + memory barriers                 │
│     - Completion, wait queue                              │
│                                                           │
│  6. Device Interface (DEVICE + FILE/FS)                   │
│     - Character device registration                       │
│     - Anonymous inode for VM/VCPU fd                      │
│     - VFIO bridge (device passthrough)                    │
│     - MMIO/PIO bus registration                           │
│                                                           │
└───────────────────────────────────────────────────────────┘
```

---

## 7. Key Findings for HHAL Design

### 7.1 Two-Layer Architecture Is Mandatory

The VMM→kernel boundary (syscalls + ioctls) is necessary but **insufficient** for understanding hypervisor OS dependencies. Dynamic profiling shows only 82 unique VMM→kernel service interactions, while the static audit reveals **~542 unique kernel API dependencies** — a 6.6x gap.

An HHAL must abstract both layers:
- **Outer layer**: VMM→HHAL (replaces syscalls + KVM ioctls)
- **Inner layer**: HHAL→OS kernel (replaces direct kernel API calls)

### 7.2 Memory Management Is the Hardest Problem

48 MMU/PAGETABLE APIs + 53 MEMORY APIs = **101 memory-related dependencies**. KVM walks host page tables, pins user pages, manages shadow page tables, and receives MMU notifier callbacks. Any HHAL must provide:

1. A portable page allocation interface (wrapping slab/page allocators)
2. A GUP abstraction (pinning VMM memory for guest use)
3. A portable page table walker (or abstract the concept entirely)
4. A reverse mapping notification mechanism (replacing MMU notifiers)

### 7.3 Timer Subsystem Coupling Is Deeper Than Expected

The LAPIC timer uses 8 distinct `hrtimer` APIs plus 7 `ktime` APIs and 4 `cpufreq` notifier APIs. TSC virtualization depends on cpufreq notifications and pvclock gtod notifiers. A portable hypervisor needs its own timer abstraction layer.

### 7.4 SRCU/RCU Is a Core Dependency

SRCU appears in virtually every KVM file for lock-free memslot access and IRQ routing table updates. RCU is used for APIC map access. These are not simple spinlocks — they are Linux-specific read-copy-update mechanisms with specific semantics. An HHAL must either:
- Provide SRCU/RCU-compatible primitives, or
- Redesign the locking strategy for memslot/routing table access

### 7.5 VFIO Shows the Best Coupling Pattern

`vfio.c` uses `symbol_get`/`symbol_put` for runtime symbol resolution — KVM has **zero compile-time dependency** on VFIO. This loose coupling pattern is an excellent template for HHAL's device passthrough interface.

### 7.6 Userspace Interface Is the Easiest to Abstract

The 28 VCPU register/state ioctls, 10 memory ioctls, and file I/O syscalls are relatively straightforward to abstract — they are simple data marshaling operations (`copy_to/from_user` + struct manipulation). The challenge is not the interface itself but the kernel machinery behind it.

### 7.7 Dynamic vs. Static Coverage Comparison

| Aspect | Dynamic (strace) | Static (source audit) | Gap |
|---|---|---|---|
| Syscalls observed | 26 types | — | Complete |
| KVM ioctls observed | 35 | ~100 from docs | 65 missing (rare/arch-specific ioctls not exercised by QEMU config) |
| Kernel-internal APIs | 0 (invisible) | ~542 | Complete gap |
| Service classes | 10 | 14 | 4 missing: MMU/PAGETABLE, DEVICE, FILE/FS, NOTIFIER |
| Lifecycle phases | 2 of 5 | All 5 (from code analysis) | 3 phases empty due to guest panic |

### 7.8 CPU Architecture Coupling

The x86 KVM code contains **direct hardware access** that goes through Linux kernel APIs:
- `wrmsrl`/`rdmsrl` — x86 MSR read/write (via kernel with preempt control)
- `rdtsc`/`rdtsc_ordered` — TSC read (hardware instruction)
- `boot_cpu_has` — CPUID feature flag checks
- `smp_call_function_single` — Cross-CPU IPI for MSR updates

These are x86-specific but go through Linux kernel scheduling/serialization. On another OS, the HHAL would need equivalent CPU-local execution guarantees.

---

## 8. Appendix: Complete Linux Kernel Subsystem Map

All 25+ kernel subsystems used by KVM, ranked by number of distinct APIs:

| # | Kernel Subsystem | API Count | Key APIs | Used In |
|---|---|---:|---|---|
| 1 | Synchronization (mutex/spinlock) | ~30 | `mutex_*`, `spin_*`, `raw_spin_*` | All files |
| 2 | Memory allocator (slab/page) | ~25 | `kzalloc`, `kmem_cache_*`, `alloc_page`, `__get_free_page` | All files |
| 3 | RCU/SRCU | ~15 | `srcu_read_lock/unlock`, `rcu_dereference`, `synchronize_srcu_expedited` | All major files |
| 4 | User-kernel data transfer | ~12 | `copy_to/from_user`, `__copy_*`, `access_ok` | kvm_main, x86 |
| 5 | Page table management | ~10 | `pgd_offset`, `pud_offset`, `pmd_offset`, `pte_*` | mmu.c |
| 6 | GUP (pin user pages) | ~8 | `get_user_pages*`, `follow_pte`, `fixup_user_fault` | kvm_main, async_pf |
| 7 | Atomic operations | ~15 | `atomic_*`, `refcount_*`, `WRITE_ONCE/READ_ONCE`, `xchg` | All files |
| 8 | Timer (hrtimer/ktime) | ~10 | `hrtimer_*`, `ktime_*` | lapic.c, x86.c |
| 9 | eventfd | ~7 | `eventfd_ctx_*`, `eventfd_signal` | eventfd.c |
| 10 | Workqueue | ~6 | `INIT_WORK`, `schedule_work`, `alloc_workqueue` | eventfd.c, async_pf.c |
| 11 | Kernel thread | ~6 | `kthread_run/park/stop`, `set_user_nice` | kvm_main.c |
| 12 | MMU notifier | ~4 | `mmu_notifier_register/unregister` | kvm_main.c |
| 13 | CPU hotplug | ~4 | `cpuhp_setup_state_nocalls`, `on_each_cpu` | kvm_main.c |
| 14 | CPU frequency | ~4 | `cpufreq_register_notifier`, `cpufreq_quick_get` | x86.c |
| 15 | Filesystem (anon_inode) | ~5 | `anon_inode_getfd/getfile`, `fd_install` | kvm_main.c |
| 16 | Character device (misc) | ~3 | `misc_register/deregister` | kvm_main.c |
| 17 | VFIO dynamic linking | ~4 | `symbol_get/put`, `vfio_file_*` | vfio.c |
| 18 | IOMMU | ~2 | `iommu_group_put` | vfio.c |
| 19 | IRQ bypass | ~4 | `irq_bypass_register/unregister_*` | eventfd.c |
| 20 | CPU feature detection | ~4 | `boot_cpu_has`, `cpu_feature_enabled` | x86.c, mmu.c |
| 21 | MSR access | ~4 | `wrmsrl`, `rdmsrl`, `rdmsr_safe` | x86.c |
| 22 | FPU framework | ~3 | `switch_fpu_return`, `kernel_fpu_begin/end` | x86.c |
| 23 | Preempt notifier | ~4 | `preempt_notifier_register/unregister/init` | kvm_main.c |
| 24 | PM/suspend notifier | ~3 | `register_pm_notifier`, `register_syscore_ops` | kvm_main.c |
| 25 | User-return notifier | ~2 | `user_return_notifier_register/unregister` | x86.c |
| 26 | pvclock | ~2 | `pvclock_gtod_register_notifier` | x86.c |
| 27 | Perf/PMU | ~2 | `perf_register_guest_info_callbacks` | kvm_main.c |
| 28 | Debug filesystem | ~5 | `debugfs_create_*`, `debugfs_remove_*` | kvm_main.c |
| 29 | Wait queue | ~4 | `init_waitqueue_func_entry`, `add_wait_queue_priority` | eventfd.c |
| 30 | Page mapping | ~5 | `kmap/kunmap`, `memremap/memunmap` | pfncache.c, kvm_main.c |

---

## Document Metadata

- **Generated by**: Static source audit (3 parallel agents) + Dynamic strace profiling
- **Audit scope**: Linux v6.8 KVM subsystem (`virt/kvm/` + `arch/x86/kvm/`)
- **Dynamic scope**: QEMU 9.2.4 x86_64, 512MB RAM, 1 vCPU, KVM acceleration
- **Total effort**: 11 source files, ~32,000 LOC analyzed, 40,509 dynamic events captured
