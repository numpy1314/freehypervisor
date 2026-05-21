# KVM `virt/kvm/` Support Files (Linux v6.8) -- Host OS Kernel API Dependency Audit

**Sources** (all from `virt/kvm/` in Linux v6.8 kernel tree):
- `eventfd.c` (~730 lines) -- irqfd and ioeventfd implementation
- `irqchip.c` (~260 lines) -- IRQ routing table management
- `vfio.c` (~380 lines) -- VFIO-KVM bridge for device passthrough
- `coalesced_mmio.c` (~180 lines) -- Coalesced MMIO ring buffer
- `async_pf.c` (~240 lines) -- Asynchronous page fault support
- `pfncache.c` (~360 lines) -- GFN-to-PFN cache

**Date**: 2026-05-18

---

## Table of Contents

1. [EVENT](#1-event)
2. [IRQ](#2-irq)
3. [MEMORY](#3-memory)
4. [DEVICE / VFIO](#4-device--vfio)
5. [SYNC](#5-sync)
6. [Per-File Summary](#6-per-file-summary)
7. [KVM ioctl Complete List (from api.rst)](#7-kvm-ioctl-complete-list)
8. [Cross-Reference: ioctl to Implementation Dependencies](#8-cross-reference-ioctl-to-implementation-dependencies)

---

## 1. EVENT

### 1.1 eventfd.c

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `eventfd_ctx_fileget(file)` | Get eventfd context from a struct file | Create (irqfd/ioeventfd assign) |
| `eventfd_ctx_fdget(fd)` | Get eventfd context from a file descriptor | Create (irqfd/ioeventfd assign) |
| `eventfd_ctx_put(ctx)` | Release eventfd context reference | Destroy (irqfd/ioeventfd deassign) |
| `eventfd_ctx_remove_wait_queue(ctx, wait, cnt)` | Remove wait queue entry and read eventfd counter | Destroy (irqfd shutdown) |
| `eventfd_signal(ctx, n)` | Signal an eventfd (increment counter, wake waiters) | Run (irqfd resampler notify, ioeventfd write) |
| `eventfd_ctx_do_read(ctx, cnt)` | Read and clear eventfd counter | Run (irqfd resampler handler) |
| `init_waitqueue_func_entry(wait, func)` | Initialize wait queue entry with custom callback | Create (irqfd poll setup) |
| `add_wait_queue_priority(wq, wait)` | Add wait queue entry at priority (head of list) | Create (irqfd poll setup) |
| `remove_wait_queue(wq, wait)` | Remove wait queue entry | Destroy (irqfd shutdown) |
| `vfs_poll(file, pt)` | Poll a file for events (POLLIN on eventfd) | Run (irqfd poll, check for events) |
| `INIT_WORK(work, fn)` | Initialize a work struct | Create (irqfd, ioeventfd) |
| `schedule_work(work)` | Schedule work on system workqueue | Run (irqfd handler, ioeventfd write) |
| `flush_work(work)` | Wait for a work to complete | Destroy (irqfd deassign) |
| `queue_work(wq, work)` | Queue work on a specific workqueue | Destroy (irqfd cleanup wq) |
| `alloc_workqueue(fmt, flags, max_active)` | Allocate a custom workqueue ("kvm-irqfd-cleanup") | Init |
| `destroy_workqueue(wq)` | Destroy a custom workqueue | Exit |
| `fdget(fd)` / `fdput(fd)` | Get/put a file descriptor reference (lightweight) | Create (irqfd/ioeventfd) |

### 1.2 irqchip.c

*(No direct event subsystem calls -- event notification is via tracepoints and the SRCU-protected routing table)*

### 1.3 vfio.c

*(No direct event subsystem calls -- VFIO event propagation uses the KVM IRQ routing layer)*

### 1.4 coalesced_mmio.c

*(No event subsystem calls -- coalesced MMIO is read via VCPU mmap ring buffer, not events)*

### 1.5 async_pf.c

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `INIT_WORK(work, fn)` | Initialize work struct for async PF completion | Create |
| `schedule_work(work)` | Schedule async page fault completion work | Run |
| `flush_work(work)` | Wait for completion work to finish | Destroy |
| `cancel_work_sync(work)` | Cancel a work and wait for it to finish | Destroy |

### 1.6 pfncache.c

*(No event subsystem calls -- cache invalidation is triggered by MMU notifiers)*

---

## 2. IRQ

### 2.1 eventfd.c

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `irq_bypass_register_producer(prod)` | Register IRQ bypass producer (posted interrupts) | Create (irqfd) |
| `irq_bypass_unregister_producer(prod)` | Unregister IRQ bypass producer | Destroy (irqfd) |
| `irq_bypass_register_consumer(cons)` | Register IRQ bypass consumer | Create (irqfd) |
| `irq_bypass_unregister_consumer(cons)` | Unregister IRQ bypass consumer | Destroy (irqfd) |
| `kvm_set_irq(kvm, src, irq, level, ...)` | Inject interrupt into guest via routing table | Run (irqfd handler) |
| `kvm_irq_map_gsi(kvm, irq, nr)` | Map GSI to interrupt routing entries | Run (irqfd resampler) |
| `kvm_irq_routing_update(kvm)` | Notify irqfd of routing table change | Run (after set routing) |
| `seqcount_t` / `raw_seqcount_begin(sc)` / `seqcount_retry(sc, seq)` | Seqcount for lock-free irqfd routing access | Run |

### 2.2 irqchip.c

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `kvm_set_irq(kvm, src, irq, level, ...)` | Core function to inject interrupt via routing table | Run |
| `kvm_irq_map_gsi(kvm, entries, n)` | Map GSI to routing entries | Run |
| `kvm_irq_map_chip_pin(kvm, irq, pin)` | Map IRQ to chip+pin (for in-kernel irqchip) | Run |
| `trace_kvm_set_irq(irq, level, r)` | Tracepoint: IRQ injection | Run |
| `trace_kvm_ack_irq(irq)` | Tracepoint: IRQ acknowledgment | Run |

### 2.3 vfio.c

*(IRQ routing is delegated to KVM generic layer; VFIO uses kvm_set_irq indirectly)*

### 2.4 coalesced_mmio.c

*(No IRQ calls -- coalesced MMIO is orthogonal to interrupt handling)*

### 2.5 async_pf.c

*(No IRQ calls -- async PF uses workqueue for completion, not IRQ injection)*

### 2.6 pfncache.c

*(No IRQ calls)*

---

## 3. MEMORY

### 3.1 eventfd.c

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `kzalloc(size, gfp)` | Allocate zeroed kernel memory (irqfd, ioeventfd structs) | Create |
| `kfree(ptr)` | Free kernel memory (irqfd, ioeventfd structs) | Destroy |
| `krealloc(ptr, new_size, gfp)` | Reallocate irqfds array on resize | Run |

### 3.2 irqchip.c

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `kzalloc(size, gfp)` | Allocate zeroed kernel memory (routing table) | Create/Run |
| `kfree(ptr)` | Free kernel memory (old routing table) | Run/Destroy |
| `array_index_nospec(index, size)` | Spectre mitigation for array index | Run |

### 3.3 vfio.c

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `kzalloc(size, gfp)` | Allocate zeroed kernel memory (kvm_vfio, kvm_vfio_group) | Create |
| `kfree(ptr)` | Free kernel memory | Destroy |

### 3.4 coalesced_mmio.c

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `alloc_page(gfp)` | Allocate a single page for ring buffer | Create |
| `free_page(addr)` | Free ring buffer page | Destroy |
| `page_address(page)` | Get kernel virtual address of ring buffer page | Create |
| `kzalloc(size, gfp)` | Allocate zeroed kernel memory (coalesced_mmio_dev) | Create |
| `kfree(ptr)` | Free kernel memory | Destroy |
| `memcpy(d, s, n)` | Copy ring entries to VCPU run buffer | Run |
| `smp_wmb()` | Write memory barrier for ring buffer producer | Run |
| `READ_ONCE(p)` | Atomic read of ring buffer indices | Run |

### 3.5 async_pf.c

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `KMEM_CACHE(struct_name, flags)` | Create slab cache for async PF structures | Init |
| `kmem_cache_destroy(cache)` | Destroy slab cache | Exit |
| `kmem_cache_zalloc(cache, gfp)` | Allocate zeroed from slab cache | Run |
| `kmem_cache_free(cache, obj)` | Free back to slab cache | Run |
| `get_user_pages_remote(mm, start, nr, flags, pages, locked)` | Pin user pages in remote mm (page fault resolution) | Run |
| `mmap_read_lock(mm)` | Acquire mm mmap read lock | Run |
| `mmap_read_unlock(mm)` | Release mm mmap read lock | Run |
| `mmget(mm)` / `mmput(mm)` | Get/put mm_struct reference | Create/Destroy |
| `current->mm` | Access current task's mm_struct | Run |
| `might_sleep()` | Debug assertion that sleeping is allowed | Run |

### 3.6 pfncache.c

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `hva_to_pfn(addr, atomic, async, writable, page)` | Convert host virtual address to PFN | Run |
| `kmap(page)` / `kunmap(page)` | Map/unmap page for kernel access | Run |
| `memremap(offset, size, flags)` | Map I/O memory region | Run |
| `memunmap(addr)` | Unmap I/O memory region | Run |
| `pfn_valid(pfn)` | Check if PFN is valid | Run |
| `pfn_to_page(pfn)` | Convert PFN to struct page | Run |
| `offset_in_page(addr)` | Get offset within a page | Run |
| `cond_resched()` | Conditional reschedule point | Run |
| `DECLARE_BITMAP(name, bits)` / `bitmap_zero(map, n)` / `__set_bit(nr, addr)` | Bitmap for cache invalidation tracking | Init/Run |
| `EXPORT_SYMBOL_GPL(sym)` | Export symbols for GPL modules | Compile |

---

## 4. DEVICE / VFIO

### 4.1 eventfd.c

*(No direct device/VFIO calls -- eventfd registers on KVM IO buses for MMIO/PIO trapping)*

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `kvm_io_bus_register_dev(kvm, bus, addr, len, dev)` | Register ioeventfd on KVM_MMIO_BUS / KVM_PIO_BUS / KVM_FAST_MMIO_BUS / KVM_VIRTIO_CCW_NOTIFY_BUS | Create |
| `kvm_io_bus_unregister_dev(kvm, bus, dev)` | Unregister ioeventfd from IO bus | Destroy |

### 4.2 irqchip.c

*(No device/VFIO calls)*

### 4.3 vfio.c

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `symbol_get(name)` | Dynamically resolve a kernel symbol (VFIO functions) | Create |
| `symbol_put(name)` | Release a dynamically resolved kernel symbol | Destroy |
| `vfio_file_set_kvm(file, kvm)` | Set KVM pointer in VFIO file (via symbol_get) | Create |
| `vfio_file_enforced_coherent(file)` | Check VFIO DMA coherency enforcement (via symbol_get) | Run |
| `vfio_file_is_valid(file)` | Validate VFIO file (via symbol_get) | Create |
| `vfio_file_iommu_group(file)` | Get IOMMU group from VFIO file (via symbol_get) | Run |
| `iommu_group_put(group)` | Release IOMMU group reference | Run |
| `fget(fd)` / `fput(file)` | Get/put file reference from fd | Create/Destroy |
| `get_file(file)` | Get additional file reference | Run |
| `fdget(fd)` / `fdput(fd)` | Lightweight fd reference | Create |
| `get_user(val, ptr)` | Copy single value from userspace | Run |
| `copy_from_user(dst, src, n)` | Copy data from userspace | Run |
| `IS_ENABLED(config)` | Check kernel config (CONFIG_SPAPR_TCE_IOMMU) | Compile |

**Note**: VFIO uses `symbol_get`/`symbol_put` for loose coupling -- KVM does NOT have a compile-time dependency on VFIO symbols. This is a deliberate design choice allowing KVM to work without VFIO loaded.

### 4.4 coalesced_mmio.c

*(No device/VFIO calls)*

### 4.5 async_pf.c

*(No device/VFIO calls)*

### 4.6 pfncache.c

*(No device/VFIO calls)*

---

## 5. SYNC

### 5.1 eventfd.c

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `spin_lock(l)` / `spin_unlock(l)` | Acquire/release spinlock (irqfd items lock) | Create/Run/Destroy |
| `mutex_lock(m)` / `mutex_unlock(m)` | Acquire/release mutex (kvm->irq_lock, kvm->lock, kvm->slots_lock) | Create/Destroy |
| `srcu_read_lock(sp)` / `srcu_read_unlock(sp, idx)` | SRCU read-side critical section (kvm->irq_srcu) | Run |
| `synchronize_srcu_expedited(sp)` | Wait for SRCU readers (irqfd list update) | Run |
| `list_add(node, head)` / `list_del(node)` / `list_for_each_entry(...)` | Linked list operations (irqfd, ioeventfd lists) | Create/Run/Destroy |
| `INIT_LIST_HEAD(head)` | Initialize linked list head | Create |
| `lockdep_assert_held(l)` | Runtime lock assertion | Run |

### 5.2 irqchip.c

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `srcu_dereference_check(p, sp, cond)` | SRCU-protected pointer dereference | Run |
| `srcu_read_lock(sp)` / `srcu_read_unlock(sp, idx)` | SRCU read-side critical section | Run |
| `synchronize_srcu_expedited(sp)` | Wait for SRCU readers (routing table swap) | Run |
| `rcu_access_pointer(p)` | Access RCU pointer without dereference | Run |
| `rcu_dereference_protected(p, cond)` | Dereference RCU pointer under lock protection | Run |
| `rcu_assign_pointer(p, v)` | Assign to RCU-protected pointer | Run |
| `mutex_lock(m)` / `mutex_unlock(m)` | Acquire/release mutex (kvm->irq_lock) | Create/Run |
| `hlist_for_each_entry(pos, head, member)` | Iterate hash list (routing table entries) | Run |
| `kzalloc(size, gfp)` / `kfree(ptr)` | Allocate/free routing table memory | Run |

### 5.3 vfio.c

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `mutex_lock(m)` / `mutex_unlock(m)` | Acquire/release mutex (kv->lock) | Create/Run/Destroy |
| `list_add(node, head)` / `list_del(node)` | Linked list operations (VFIO group list) | Create/Destroy |
| `list_for_each_entry(pos, head, member)` | Iterate VFIO group list | Run |
| `WARN_ON_ONCE(cond)` | Emit warning (invalid VFIO group ops) | Run |

### 5.4 coalesced_mmio.c

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `spin_lock(l)` / `spin_unlock(l)` | Acquire/release spinlock (ring buffer lock) | Run |
| `mutex_lock(m)` / `mutex_unlock(m)` | Acquire/release mutex (kvm->slots_lock) | Create/Destroy |
| `INIT_LIST_HEAD(head)` | Initialize linked list head | Create |
| `list_add(node, head)` / `list_del(node)` | Add/remove coalesced MMIO zone | Create/Destroy |
| `list_for_each_entry(...)` / `list_for_each_entry_safe(...)` | Iterate coalesced MMIO zones | Run |

### 5.5 async_pf.c

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `spin_lock(l)` / `spin_unlock(l)` | Acquire/release spinlock (async_pf lock) | Run |
| `trace_kvm_async_pf_completed(addr, gva, ...)` | Tracepoint for async PF completion | Run |

### 5.6 pfncache.c

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `write_lock_irq(l)` / `write_unlock_irq(l)` | Acquire/release rwlock with IRQ save (gpc->lock) | Run |
| `spin_lock(l)` / `spin_unlock(l)` | Acquire/release spinlock (gpc->refresh_lock) | Run |
| `rwlock_init(l)` | Initialize rwlock | Create |
| `mutex_init(m)` | Initialize mutex (gpc->refresh_lock) | Create |
| `smp_rmb()` | Read memory barrier | Run |
| `lockdep_assert_held(l)` / `lockdep_assert_held_write(l)` | Runtime lock assertions | Run |

---

## 6. Per-File Summary

### 6.1 Summary Statistics

| File | EVENT | IRQ | MEMORY | DEVICE/VFIO | SYNC | **Total Distinct APIs** |
|---|---|---|---|---|---|---|
| `eventfd.c` | 17 | 8 | 3 | 2 | 7 | **37** |
| `irqchip.c` | 0 | 5 | 3 | 0 | 9 | **17** |
| `vfio.c` | 0 | 0 | 2 | 9 | 4 | **15** |
| `coalesced_mmio.c` | 0 | 0 | 8 | 0 | 5 | **13** |
| `async_pf.c` | 4 | 0 | 11 | 0 | 2 | **17** |
| `pfncache.c` | 0 | 0 | 10 | 0 | 6 | **16** |
| **Total** | **21** | **13** | **37** | **11** | **33** | **115** |

### 6.2 Category-Level Analysis

| Category | Critical APIs | Abstraction Difficulty |
|---|---|---|
| **EVENT** | `eventfd_*`, `vfs_poll`, wait queue, workqueue, `alloc_workqueue` | HIGH -- deeply tied to Linux eventfd and wait queue subsystems |
| **IRQ** | `irq_bypass_*`, `kvm_set_irq`, `seqcount` | HIGH -- IRQ bypass framework for posted interrupts is Linux-specific |
| **MEMORY** | `get_user_pages_remote`, `hva_to_pfn`, `kmap/kunmap`, `memremap`, `KMEM_CACHE` | HIGH -- GUP, page mapping, and slab allocator are Linux kernel core |
| **DEVICE/VFIO** | `symbol_get/put`, `vfio_file_*`, `iommu_group_*` | MODERATE -- loose coupling via symbol_get, but VFIO API is Linux-specific |
| **SYNC** | `mutex`, `spinlock`, `SRCU`, `RCU`, `seqcount`, `rwlock`, `workqueue` | MODERATE -- concepts are universal but APIs differ across OS kernels |

---

## 7. KVM ioctl Complete List

Extracted from `Documentation/virt/kvm/api.rst` (Linux v6.8) and `include/uapi/linux/kvm.h`.

### 7.1 System ioctls (on `/dev/kvm` fd)

| ioctl | Section | Description |
|---|---|---|
| `KVM_GET_API_VERSION` | 4.1 | Returns API version (12) |
| `KVM_CREATE_VM` | 4.2 | Create a new VM, returns VM fd |
| `KVM_GET_MSR_INDEX_LIST` | 4.3 | List of MSRs that can be passed to KVM_GET/SET_MSRS |
| `KVM_CHECK_EXTENSION` | 4.4 | Check if a capability is available |
| `KVM_GET_VCPU_MMAP_SIZE` | 4.5 | Get size of VCPU mmap region |
| `KVM_GET_SUPPORTED_CPUID` | 4.46 | Get supported CPUID entries (x86) |
| `KVM_GET_EMULATED_CPUID` | 4.88 | Get emulated CPUID entries (x86) |
| `KVM_GET_MSR_FEATURE_INDEX_LIST` | 4.3b | List of MSRs that can be read via KVM_GET_MSRS |

### 7.2 VM ioctls (on VM fd)

| ioctl | Section | Description | Arch |
|---|---|---|---|
| `KVM_CREATE_VCPU` | 4.7 | Create a VCPU | Generic |
| `KVM_GET_DIRTY_LOG` | 4.8 | Get dirty page bitmap | Generic |
| `KVM_SET_USER_MEMORY_REGION` | 4.35 | Set user memory region (slot) | Generic |
| `KVM_SET_USER_MEMORY_REGION2` | 4.140 | Extended memory region (with guest_memfd) | Generic |
| `KVM_CREATE_IRQCHIP` | 4.24 | Create in-kernel IRQ chip | x86, ARM, PPC |
| `KVM_IRQ_LINE` | 4.25 | Set IRQ line level | x86, ARM, PPC |
| `KVM_GET_IRQCHIP` | 4.26 | Get IRQ chip state | x86 |
| `KVM_SET_IRQCHIP` | 4.27 | Set IRQ chip state | x86 |
| `KVM_SET_GSI_ROUTING` | 4.52 | Set GSI routing table | Generic |
| `KVM_IRQFD` | 4.75 | Route eventfd to IRQ (irqfd) | Generic |
| `KVM_IOEVENTFD` | 4.59 | Route MMIO/PIO to eventfd (ioeventfd) | Generic |
| `KVM_SIGNAL_MSI` | 4.71 | Inject MSI interrupt | x86, ARM |
| `KVM_CREATE_DEVICE` | 4.79 | Create in-kernel device | Generic |
| `KVM_SET_DEVICE_ATTR` | 4.80 | Set device attribute | Generic |
| `KVM_GET_DEVICE_ATTR` | 4.81 | Get device attribute | Generic |
| `KVM_HAS_DEVICE_ATTR` | 4.82 | Check device attribute | Generic |
| `KVM_REGISTER_COALESCED_MMIO` | 4.116 | Register coalesced MMIO zone | Generic |
| `KVM_UNREGISTER_COALESCED_MMIO` | 4.116 | Unregister coalesced MMIO zone | Generic |
| `KVM_CLEAR_DIRTY_LOG` | 4.117 | Clear dirty page bitmap | Generic |
| `KVM_SET_MEMORY_ATTRIBUTES` | 4.141 | Set memory attributes per GPA | Generic |
| `KVM_CREATE_GUEST_MEMFD` | 4.142 | Create guest memfd for private memory | Generic |
| `KVM_SET_TSS_ADDR` | 4.36 | Set TSS address | x86 |
| `KVM_SET_IDENTITY_MAP_ADDR` | 4.40 | Set identity map address | x86 |
| `KVM_SET_BOOT_CPU_ID` | 4.41 | Set boot CPU ID | x86 |
| `KVM_CREATE_PIT2` | 4.71 | Create in-kernel PIT | x86 |
| `KVM_GET_PIT2` / `KVM_SET_PIT2` | 4.72 / 4.73 | Get/set PIT state | x86 |
| `KVM_GET_LAPIC` / `KVM_SET_LAPIC` | 4.57 / 4.58 | Get/set local APIC state | x86 |
| `KVM_GET_CLOCK` / `KVM_SET_CLOCK` | 4.29 / 4.30 | Get/set guest clock | x86 |
| `KVM_XEN_HVM_SET_ATTR` / `KVM_XEN_HVM_GET_ATTR` | 4.126 / 4.127 | Set/get Xen HVM attributes | x86 |
| `KVM_XEN_HVM_EVTCHN_SEND` | 4.129 | Send Xen event channel | x86 |
| `KVM_XEN_VCPU_SET_ATTR` / `KVM_XEN_VCPU_GET_ATTR` | 4.128 / 4.128 | Set/get Xen VCPU attributes | x86 |
| `KVM_XEN_HVM_GET_ATTR` | 4.127 | Get Xen HVM attribute | x86 |
| `KVM_HYPERV_EVENTFD` | 4.113 | Set HyperV eventfd | x86 |
| `KVM_SET_PMU_EVENT_FILTER` | 4.120 | Set PMU event filter | x86 |
| `KVM_X86_SET_MSR_FILTER` | 4.97 | Set MSR access filter | x86 |
| `KVM_MEMORY_ENCRYPT_OP` | 4.110 | Platform-specific memory encrypt op | x86 |
| `KVM_MEMORY_ENCRYPT_REG_REGION` | 4.111 | Register encrypted memory region | x86 |
| `KVM_MEMORY_ENCRYPT_UNREG_REGION` | 4.112 | Unregister encrypted memory region | x86 |
| `KVM_S390_INTERRUPT` | 4.77 | Inject s390 interrupt | s390 |
| `KVM_S390_MEM_OP` | 4.89 | s390 memory operation | s390 |
| `KVM_S390_GET_SKEYS` / `KVM_S390_SET_SKEYS` | 4.90 / 4.91 | Get/set storage keys | s390 |
| `KVM_S390_IRQ` | 4.92 | Inject s390 IRQ | s390 |
| `KVM_S390_GET_IRQ_STATE` / `KVM_S390_SET_IRQ_STATE` | 4.94 / 4.95 | Get/set IRQ state | s390 |
| `KVM_S390_UCAS_MAP` / `KVM_S390_UCAS_UNMAP` | -- | Map/unmap UCAS | s390 |
| `KVM_S390_AEN_MGITATE` | -- | AEN migration | s390 |
| `KVM_ARM_PREFERRED_TARGET` | 4.83 | Get preferred CPU target | ARM |
| `KVM_ARM_VCPU_INIT` | 4.82 | Initialize ARM VCPU | ARM |
| `KVM_ARM_VCPU_FINALIZE` | 4.119 | Finalize ARM VCPU configuration | ARM |
| `KVM_ARM_SET_DEVICE_ADDR` | 4.85 | Set device address | ARM |
| `KVM_PPC_GET_PVINFO` | 4.47 | Get paravirt info | PPC |
| `KVM_PPC_ALLOCATE_HTAB` | -- | Allocate hash table | PPC |
| `KVM_CREATE_SPAPR_TCE` | 4.62 | Create SPAPR TCE table | PPC |
| `KVM_CREATE_SPAPR_TCE_64` | -- | Create SPAPR TCE table (64-bit) | PPC |
| `KVM_ALLOCATE_RMA` | 4.63 | Allocate RMA | PPC |
| `KVM_PPC_GET_HTAB_FD` | 4.78 | Get HTAB fd | PPC |
| `KVM_PPC_RTAS_DEFINE_TOKEN` | -- | Define RTAS token | PPC |

### 7.3 VCPU ioctls (on VCPU fd)

| ioctl | Section | Description | Arch |
|---|---|---|---|
| `KVM_RUN` | 4.10 | Run the VCPU | Generic |
| `KVM_GET_REGS` / `KVM_SET_REGS` | 4.11 / 4.12 | Get/set general purpose registers | x86, ARM, PPC |
| `KVM_GET_SREGS` / `KVM_SET_SREGS` | 4.13 / 4.14 | Get/set special registers | x86 |
| `KVM_GET_SREGS2` / `KVM_SET_SREGS2` | -- | Get/set special registers (v2) | x86 |
| `KVM_TRANSLATE` | 4.15 | Translate guest virtual address | x86 |
| `KVM_INTERRUPT` | 4.16 | Inject interrupt | x86, PPC |
| `KVM_GET_MSRS` / `KVM_SET_MSRS` | 4.18 / 4.19 | Get/set MSR values | x86 |
| `KVM_SET_CPUID` / `KVM_SET_CPUID2` | 4.20 | Set CPUID entries | x86 |
| `KVM_GET_CPUID2` | 4.20 | Get CPUID entries | x86 |
| `KVM_SET_SIGNAL_MASK` | 4.21 | Set signal mask for VCPU | Generic |
| `KVM_GET_FPU` / `KVM_SET_FPU` | 4.22 / 4.23 | Get/set FPU state | x86 |
| `KVM_GET_VCPU_EVENTS` / `KVM_SET_VCPU_EVENTS` | 4.31 / 4.32 | Get/set pending events | x86 |
| `KVM_GET_DEBUGREGS` / `KVM_SET_DEBUGREGS` | 4.33 / 4.34 | Get/set debug registers | x86 |
| `KVM_GET_MP_STATE` / `KVM_SET_MP_STATE` | 4.38 / 4.39 | Get/set multiprocessing state | Generic |
| `KVM_GET_XSAVE` / `KVM_SET_XSAVE` | 4.42 / 4.43 | Get/set XSAVE state | x86 |
| `KVM_GET_XSAVE2` | 4.134 | Get XSAVE state (v2) | x86 |
| `KVM_GET_XCRS` / `KVM_SET_XCRS` | 4.44 / 4.45 | Get/set extended control registers | x86 |
| `KVM_GET_SUPPORTED_CPUID` | 4.46 | Get supported CPUID | x86 |
| `KVM_SET_ONE_REG` / `KVM_GET_ONE_REG` | 4.68 / 4.69 | Set/get single register | ARM, PPC, s390 |
| `KVM_GET_REG_LIST` | 4.84 | Get register list | ARM, PPC |
| `KVM_SET_GUEST_DEBUG` | 4.87 | Set guest debug mode | Generic |
| `KVM_NMI` | 4.64 | Inject NMI | x86 |
| `KVM_SMI` | 4.96 | Inject SMI | x86 |
| `KVM_GET_NESTED_STATE` / `KVM_SET_NESTED_STATE` | 4.114 / 4.115 | Get/set nested virtualization state | x86 |
| `KVM_GET_SUPPORTED_HV_CPUID` | -- | Get supported HyperV CPUID | x86 |
| `KVM_ARM_MTE_COPY_TAGS` | 4.130 | Copy MTE tags | ARM |
| `KVM_ARM_SET_COUNTER_OFFSET` | 4.138 | Set counter offset | ARM |
| `KVM_ARM_GET_REG_WRITABLE_MASKS` | 4.139 | Get writable register masks | ARM |
| `KVM_S390_SET_INITIAL_PSW` | -- | Set initial PSW | s390 |
| `KVM_S390_INITIAL_RESET` | 4.122 | Initial CPU reset | s390 |
| `KVM_S390_CLEAR_RESET` | 4.123 | Clear reset | s390 |
| `KVM_S390_SUBSYSTEM_RESET` | 4.124 | Subsystem reset | s390 |
| `KVM_S390_SET_IRQ_STATE` | 4.95 | Set IRQ state | s390 |
| `KVM_S390_GET_IRQ_STATE` | 4.94 | Get IRQ state | s390 |
| `KVM_PPC_GET_HTAB_FD` | 4.78 | Get hash table fd | PPC |
| `KVM_PPC_SYNC_HTAB` | -- | Sync hash table | PPC |
| `KVM_DIRTY_TLB` | 4.60 | Dirty TLB | PPC |
| `KVM_XEN_VCPU_SET_ATTR` / `KVM_XEN_VCPU_GET_ATTR` | 4.128 | Set/get Xen VCPU attributes | x86 |

### 7.4 Device ioctls (on device fd, created by KVM_CREATE_DEVICE)

| ioctl | Section | Description |
|---|---|---|
| `KVM_SET_DEVICE_ATTR` | 4.80 | Set device attribute |
| `KVM_GET_DEVICE_ATTR` | 4.81 | Get device attribute |
| `KVM_HAS_DEVICE_ATTR` | 4.82 | Check device attribute exists |

Device types include: KVM_DEV_TYPE_FSL_MPIC_20, KVM_DEV_TYPE_FSL_MPIC_42, KVM_DEV_TYPE_XICS, KVM_DEV_TYPE_XIVE, KVM_DEV_TYPE_VFIO, KVM_DEV_TYPE_ARM_VGIC_V2, KVM_DEV_TYPE_ARM_VGIC_V3, KVM_DEV_TYPE_ARM_ITS, KVM_DEV_TYPE_XICS_PSERIES.

### 7.5 Capability Constants (from `include/uapi/linux/kvm.h`)

Major capabilities checked via `KVM_CHECK_EXTENSION`:

| Capability | Value | Description |
|---|---|---|
| `KVM_CAP_IRQCHIP` | 0 | In-kernel IRQ chip |
| `KVM_CAP_HLT` | 1 | HLT instruction exits |
| `KVM_CAP_USER_MEMORY` | 3 | User memory regions |
| `KVM_CAP_SET_TSS_ADDR` | 4 | TSS address setting |
| `KVM_CAP_EXT_CPUID` | 7 | Extended CPUID |
| `KVM_CAP_NR_VCPUS` | 9 | Number of VCPUs |
| `KVM_CAP_NR_MEMSLOTS` | 10 | Number of memory slots |
| `KVM_CAP_COALESCED_MMIO` | 15 | Coalesced MMIO |
| `KVM_CAP_SYNC_MMU` | 16 | Sync MMU |
| `KVM_CAP_IOMMU` | 18 | IOMMU support |
| `KVM_CAP_DESTROY_MEMORY_REGION_WORKS` | 21 | Memory region destroy |
| `KVM_CAP_IRQ_ROUTING` | 25 | IRQ routing |
| `KVM_CAP_IRQFD` | 32 | IRQFD support |
| `KVM_CAP_PIT2` | 33 | PIT2 support |
| `KVM_CAP_IOEVENTFD` | 36 | IOEVENTFD support |
| `KVM_CAP_XEN_HVM` | 38 | Xen HVM support |
| `KVM_CAP_ADJUST_CLOCK` | 39 | Clock adjustment |
| `KVM_CAP_VCPU_EVENTS` | 41 | VCPU events |
| `KVM_CAP_HYPERV` | 44 | HyperV support |
| `KVM_CAP_HYPERV_VAPIC` | 45 | HyperV virtual APIC |
| `KVM_CAP_HYPERV_SPINLOCK` | 46 | HyperV spinlock |
| `KVM_CAP_PCI_SEGMENT` | 47 | PCI segments |
| `KVM_CAP_PPC_PAIRED_SINGLES` | 48 | PPC paired singles |
| `KVM_CAP_INTR_SHADOW` | 49 | Interrupt shadow |
| `KVM_CAP_USER_NMI` | 53 | User NMI |
| `KVM_CAP_MAX_VCPUS` | 66 | Max VCPUs |
| `KVM_CAP_MAX_VCPU_ID` | 128 | Max VCPU ID |
| `KVM_CAP_PPC_HIOR` | 73 | PPC HIOR |
| `KVM_CAP_PPC_PAPR` | 74 | PAPR support |
| `KVM_CAP_SW_TLB` | 77 | Software TLB |
| `KVM_CAP_ONE_REG` | 78 | Single register ops |
| `KVM_CAP_S390_UCONTROL` | 79 | s390 user-controlled |
| `KVM_CAP_TSC_DEADLINE_TIMER` | 80 | TSC deadline timer |
| `KVM_CAP_S390_IRQCHIP` | 81 | s390 IRQ chip |
| `KVM_CAP_ARM_PSCI_0_2` | 85 | ARM PSCI 0.2 |
| `KVM_CAP_ARM_DEVICE_CTRL` | 89 | ARM device control |
| `KVM_CAP_IRQ_MPIC` | 91 | MPIC IRQ |
| `KVM_CAP_PPC_RTAS` | 92 | RTAS support |
| `KVM_CAP_SPAPR_RESIZE_HPT` | 98 | SPAPR HPT resize |
| `KVM_CAP_ARM_VM_IPA_SIZE` | 111 | ARM IPA size |
| `KVM_CAP_MANUAL_DIRTY_LOG_PROTECT2` | 119 | Manual dirty log protect |
| `KVM_CAP_XSAVE2` | 129 | XSAVE2 support |
| `KVM_CAP_SYS_ATTRIBUTES` | 131 | System attributes |
| `KVM_CAP_ARM_TE` | 134 | ARM trace |
| `KVM_CAP_MEMORY_ATTRIBUTES` | 136 | Memory attributes |
| `KVM_CAP_GUEST_MEMFD` | 137 | Guest memfd |
| `KVM_CAP_VM_DISABLE_NX_HUGE_PAGES` | 138 | Disable NX huge pages |

---

## 8. Cross-Reference: ioctl to Implementation Dependencies

### 8.1 EVENT-category ioctls and their dependency files

| ioctl | Source File | Key Linux Kernel Dependencies |
|---|---|---|
| `KVM_IRQFD` | `eventfd.c` | `eventfd_ctx_*`, `vfs_poll`, `wait_queue`, `workqueue`, `irq_bypass_*` |
| `KVM_IOEVENTFD` | `eventfd.c` | `eventfd_ctx_*`, `kvm_io_bus_register_dev`, `workqueue` |
| `KVM_HYPERV_EVENTFD` | (arch/x86/kvm) | `eventfd_ctx_*`, `kzalloc/kfree`, `mutex` |

### 8.2 IRQ-category ioctls and their dependency files

| ioctl | Source File | Key Linux Kernel Dependencies |
|---|---|---|
| `KVM_CREATE_IRQCHIP` | `irqchip.c`, arch | `kzalloc/kfree`, `mutex`, `SRCU` |
| `KVM_IRQ_LINE` | `irqchip.c` | `srcu_dereference_check`, `trace_kvm_set_irq` |
| `KVM_SET_GSI_ROUTING` | `irqchip.c` | `SRCU`, `RCU`, `mutex`, `kzalloc/kfree`, `synchronize_srcu_expedited` |
| `KVM_GET_IRQCHIP` / `KVM_SET_IRQCHIP` | arch/x86 | `copy_to/from_user`, `spin_lock`, `mutex` |
| `KVM_SIGNAL_MSI` | `irqchip.c` | `kvm_set_irq`, `SRCU` |

### 8.3 MEMORY-category ioctls and their dependency files

| ioctl | Source File | Key Linux Kernel Dependencies |
|---|---|---|
| `KVM_SET_USER_MEMORY_REGION` | `kvm_main.c` | `get_user_pages*`, `mmap_read_lock`, `mmu_notifier`, `SRCU` |
| `KVM_REGISTER_COALESCED_MMIO` | `coalesced_mmio.c` | `kzalloc/kfree`, `spin_lock`, `mutex`, `list operations` |
| `KVM_UNREGISTER_COALESCED_MMIO` | `coalesced_mmio.c` | `kfree`, `spin_lock`, `list operations` |
| `KVM_GET_DIRTY_LOG` | `kvm_main.c` | `copy_to_user`, `mutex`, `SRCU` |
| `KVM_CLEAR_DIRTY_LOG` | `kvm_main.c` | `copy_from_user`, `atomic_long_fetch_andnot`, `SRCU` |
| `KVM_SET_USER_MEMORY_REGION2` | `kvm_main.c` | Same as SET_USER_MEMORY_REGION + `guest_memfd` |
| `KVM_SET_MEMORY_ATTRIBUTES` | `kvm_main.c` | `mutex`, `SRCU`, `xarray` |
| `KVM_CREATE_GUEST_MEMFD` | `kvm_main.c` | `anon_inode_getfile`, `kzalloc` |

### 8.4 DEVICE/VFIO-category ioctls and their dependency files

| ioctl | Source File | Key Linux Kernel Dependencies |
|---|---|---|
| `KVM_CREATE_DEVICE` | `kvm_main.c` | `kzalloc`, `anon_inode_getfd`, `mutex` |
| `KVM_SET/GET/HAS_DEVICE_ATTR` | `kvm_main.c`, arch | `mutex`, `copy_to/from_user` |
| (VFIO group add/remove via KVM_SET_DEVICE_ATTR on VFIO device) | `vfio.c` | `symbol_get/put`, `vfio_file_*`, `iommu_group_*`, `fget/fput` |

### 8.5 SYNC-category ioctls (implicitly used by many operations)

| ioctl | Source File | Key Linux Kernel Dependencies |
|---|---|---|
| `KVM_RUN` | `kvm_main.c`, arch | `SRCU`, `mutex`, `preempt_notifier`, `schedule`, `copy_to/from_user`, `signal_pending` |
| `KVM_CREATE_VCPU` | `kvm_main.c` | `kmem_cache_zalloc`, `alloc_page`, `mutex`, `init_srcu_struct`, `preempt_notifier_register` |
| `KVM_CHECK_EXTENSION` | `kvm_main.c` | Simple capability lookup (no heavy dependencies) |

---

## Appendix A: Aggregate Dependency Map across All Audited Files

Combining this report with the previously audited files:

| Component | Files | Total APIs |
|---|---|---|
| `virt/kvm/` support files (this report) | 6 files | ~115 |
| `virt/kvm/kvm_main.c` | 1 file (6621 lines) | ~276 |
| `arch/x86/kvm/` (x86, mmu, lapic, ioapic) | 4 files (25479 lines) | ~151 |
| **Total (audited)** | **11 files** | **~542** |

### Unique Linux Kernel Subsystem Dependencies

| Subsystem | Key APIs | Used In |
|---|---|---|
| **eventfd** | `eventfd_ctx_*`, `eventfd_signal` | eventfd.c |
| **wait queue** | `init_waitqueue_func_entry`, `add_wait_queue_priority` | eventfd.c |
| **workqueue** | `INIT_WORK`, `schedule_work`, `alloc_workqueue` | eventfd.c, async_pf.c |
| **IRQ bypass** | `irq_bypass_register/unregister_producer/consumer` | eventfd.c |
| **SRCU** | `srcu_read_lock/unlock`, `synchronize_srcu_expedited` | All files |
| **RCU** | `rcu_read_lock/unlock`, `rcu_dereference`, `rcu_assign_pointer` | irqchip.c, kvm_main.c |
| **slab allocator** | `KMEM_CACHE`, `kmem_cache_zalloc/free` | async_pf.c, kvm_main.c |
| **page allocator** | `alloc_page`, `__get_free_page`, `get_zeroed_page` | coalesced_mmio.c, kvm_main.c, mmu.c |
| **GUP (get_user_pages)** | `get_user_pages_remote`, `get_user_pages_fast` | async_pf.c, kvm_main.c, pfncache.c |
| **MMU notifiers** | `mmu_notifier_register/unregister` | kvm_main.c |
| **hrtimer** | `hrtimer_init`, `hrtimer_start`, `hrtimer_cancel` | lapic.c |
| **VFIO dynamic linking** | `symbol_get/put`, `vfio_file_*` | vfio.c |
| **IOMMU** | `iommu_group_put` | vfio.c |
| **kmap/memremap** | `kmap`, `kunmap`, `memremap`, `memunmap` | pfncache.c, kvm_main.c |
| **VFIO file operations** | `fget/fput`, `fdget/fdput` | vfio.c, eventfd.c |
| **anonymous inode** | `anon_inode_getfd`, `anon_inode_getfile` | kvm_main.c |
| **misc device** | `misc_register`, `misc_deregister` | kvm_main.c |
| **CPU hotplug** | `cpuhp_setup_state_nocalls`, `on_each_cpu` | kvm_main.c |
| **PM/suspend** | `register_pm_notifier`, `register_syscore_ops` | kvm_main.c |
| **debugfs** | `debugfs_create_dir/file`, `debugfs_remove_recursive` | kvm_main.c |
| **perf** | `perf_register_guest_info_callbacks` | kvm_main.c |
| **cpufreq** | `cpufreq_register_notifier`, `cpufreq_quick_get` | x86.c |
| **FPU** | `switch_fpu_return`, `kernel_fpu_begin/end` | x86.c |
| **page table walker** | `pgd_offset`, `pud_offset`, `pmd_offset` | mmu.c |
| **hva_to_pfn** | `hva_to_pfn`, `pfn_valid`, `pfn_to_page` | pfncache.c |

---

## Appendix B: Key Findings for HHAL Design

1. **Loosest coupling**: `vfio.c` uses `symbol_get`/`symbol_put` to dynamically resolve VFIO symbols at runtime. This design pattern (runtime symbol resolution) could be a template for HHAL's OS-agnostic device interface.

2. **Tightest coupling**: `eventfd.c` is deeply entwined with Linux's eventfd subsystem, wait queues, and workqueues. An HHAL must provide equivalent event notification primitives.

3. **Memory management split**: Page allocation (`alloc_page`, slab caches) and GUP (`get_user_pages_remote`) are the two major memory subsystems used. These differ fundamentally between OS kernels.

4. **Synchronization is ubiquitous**: SRCU, RCU, mutexes, spinlocks, and seqcounts appear in every file. An HHAL must provide all these synchronization primitives.

5. **IRQ bypass for performance**: The `irq_bypass` framework enables posted interrupts for latency-critical IRQ injection. This is Linux-specific and would need a portable equivalent or direct hardware abstraction.

6. **Workqueue as deferred execution model**: Both `eventfd.c` (irqfd cleanup) and `async_pf.c` (page fault completion) use workqueues. An HHAL needs a deferred execution mechanism.

7. **Coalesced MMIO is self-contained**: The ring buffer in `coalesced_mmio.c` uses only basic memory allocation and synchronization -- relatively easy to abstract.
