# KVM x86 Architecture Files (Linux v6.8) -- Host OS Kernel API Dependency Audit

**Sources**:
- `arch/x86/kvm/x86.c` (13929 lines)
- `arch/x86/kvm/mmu/mmu.c` (7459 lines)
- `arch/x86/kvm/lapic.c` (3315 lines)
- `arch/x86/kvm/ioapic.c` (776 lines)

**Date**: 2026-05-18

---

## Table of Contents

1. [MEMORY](#1-memory)
2. [VCPU / CPU / MSR / PMU](#2-vcpu--cpu--msr--pmu)
3. [INTERRUPT / IRQ](#3-interrupt--irq)
4. [TIMER / CLOCK](#4-timer--clock)
5. [SYNC / LOCK](#5-sync--lock)
6. [I/O / DEVICE](#6-io--device)
7. [SIGNAL / SCHED](#7-signal--sched)
8. [VM / MM Subsystem](#8-vm--mm-subsystem)
9. [FS / USER / MISC](#9-fs--user--misc)
10. [Summary Statistics](#10-summary-statistics)

---

## 1. MEMORY

### 1.1 arch/x86/kvm/x86.c

| Kernel API | Line(s) | Description |
|---|---|---|
| `kzalloc(size, gfp)` | 5826, 6018, 6047, 6063, 6212, 6685 | Allocate zeroed kernel memory for lapic state, xsave, xcrs, sregs2, MSR filter |
| `kfree(ptr)` | 4544, 6242, 6701, 6703, 7050, 7068, 12164, 12165, 12209, 12210, 12216, 12513 | Free kernel memory: entries, buffers, irq chips, MCE banks, cpuid, HV page |
| `kvfree(ptr)` | 12216, 12714, 12715, 12727, 12739, 12831 | Free kvmalloc'd memory: cpuid entries, apic map, PMU filter, rmap, lpage_info |
| `alloc_pages_exact(size, gfp)` | (via kvm_init_mmu_notifier) | Allocate exact-size pages for MMU notifier |

### 1.2 arch/x86/kvm/mmu/mmu.c

| Kernel API | Line(s) | Description |
|---|---|---|
| `get_zeroed_page(gfp)` | 3955, 3960, 3965 | Allocate zeroed pages for PAE root, PML4 root, PML5 root page tables |
| `virt_to_page(addr)` | 2249 | Convert virtual address to struct page for shadow page table tracking |
| `set_page_private(page, val)` | 2249 | Store shadow page struct pointer in page private data |
| `page_to_pfn(page)` | 2998 | Convert struct page to pfn for page table mapping |
| `put_page(page)` | 2999 | Release reference to mapped page |
| `kvm_release_pfn_clean(pfn)` | 4451, 4528, 4604 | Release clean PFN reference after page fault handling |
| `kvm_pfn_to_refcounted_page(pfn)` | 587 | Check if PFN has a refcounted struct page |

### 1.3 arch/x86/kvm/lapic.c

| Kernel API | Line(s) | Description |
|---|---|---|
| `kzalloc(size, gfp)` | 2812 | Allocate local APIC structure |
| `kfree(ptr)` | 2483, 2849 | Free local APIC structure |
| `kvzalloc(size, gfp)` | 419 | Allocate APIC map (with vmalloc fallback) |
| `kvfree(ptr)` | 214, 435 | Free APIC map |
| `put_page(page)` | 2623 | Release page after APIC MMIO access |

### 1.4 arch/x86/kvm/ioapic.c

| Kernel API | Line(s) | Description |
|---|---|---|
| `kzalloc(size, gfp)` | 719 | Allocate IOAPIC structure |
| `kfree(ptr)` | 734, 752 | Free IOAPIC structure |

---

## 2. VCPU / CPU / MSR / PMU

### 2.1 arch/x86/kvm/x86.c

| Kernel API | Line(s) | Description |
|---|---|---|
| `wrmsrl(msr, val)` | 383, 1030, 1061, 3806, 3819, 9712, 10954, 11034, 13547 | Write 64-bit MSR: user-return MSRs, XSS, PRED_CMD, FLUSH_CMD, XFD_ERR, SPEC_CTRL |
| `rdmsrl(msr, val)` | 9712, 9717 | Read 64-bit MSR: IA32_XSS, IA32_ARCH_CAPABILITIES |
| `rdmsr_safe(msr, ...)` | 7296 | Safe MSR read (returns error instead of #GP) |
| `boot_cpu_has(feature)` | 1659, 3794, 3797, 3814, 4551, 4553, 4733, 5589, 5605, 7977, 9378, 9403, 9525, 9663, 9668, 9704, 9711, 9716, 9805 | Check host CPU feature flags (RTM, IBPB, SBPB, FLUSH_L1D, MWAIT, ARAT, XSAVE, PKU, CONSTANT_TSC, FPU, FXSR, XSAVES, ARCH_CAPABILITIES, SPLIT_LOCK_DETECT) |
| `cpu_feature_enabled(feature)` | 1033, 1046 | Check CPU feature enabled (PKU) |
| `smp_processor_id()` | 430, 444, 467, 9625, 12407 | Get current CPU ID for per-CPU operations |
| `raw_smp_processor_id()` | 9383, 9473 | Get current CPU ID (raw, preempt-unsafe) |
| `preempt_disable()` | 394, 10531, 10894 | Disable kernel preemption for per-CPU MSR access and guest entry |
| `preempt_enable()` | 400, 10554, 10938, 11059 | Re-enable kernel preemption |
| `smp_call_function_single(cpu, fn, ...)` | 4966, 9465, 9492, 9726 | Execute function on a specific CPU (WBINVD, TSC freq change, compat check) |
| `on_each_cpu_mask(mask, fn, ...)` | 8157 | Execute function on CPUs in a mask (WBINVD dirty mask) |
| `switch_fpu_return()` | 10951 | Restore host FPU state after guest exit |
| `kernel_fpu_begin()` / `kernel_fpu_end()` | (via asm/fpu/api.h include) | Save/restore FPU context for kernel FPU usage |

### 2.2 arch/x86/kvm/mmu/mmu.c

| Kernel API | Line(s) | Description |
|---|---|---|
| `boot_cpu_has(feature)` | 5041, 6031 | Check host CPU feature: GBPAGES support for page table level selection |

### 2.3 arch/x86/kvm/lapic.c

| Kernel API | Line(s) | Description |
|---|---|---|
| `rdtsc()` | 1848, 1859, 1944, 1992, 2042 | Read Time Stamp Counter for APIC timer TSC deadline mode |
| `__delay(cycles)` | 1803 | Busy-wait delay loop for APIC timer advance calibration |
| `ndelay(ns)` | 1808 | Nanosecond delay for APIC timer advance calibration |
| `div64_u64(div, divisor)` | 49, 1544 | 64-bit unsigned division for APIC timer period computation |

---

## 3. INTERRUPT / IRQ

### 3.1 arch/x86/kvm/x86.c

| Kernel API | Line(s) | Description |
|---|---|---|
| `irqchip_in_kernel(kvm)` | 5141, 5762, 6435, 6468, 6975, 12067, 12076 | Check whether IRQ chip is present in kernel |
| `kvm_set_irq(kvm, src, irq, level, ...)` | 6438 | Inject IRQ into guest via userspace IRQ source |
| `kvm_setup_default_irq_routing(kvm)` | 6992 | Set up default ISA IRQ routing table |
| `kvm_apic_set_irq(vcpu, irq, ...)` | 13381 | Inject interrupt via local APIC (NMI, etc.) |
| `kvm_apic_local_deliver(apic, lvt)` | 5239 | Deliver local APIC interrupt (CMCI on LVT CMCI) |
| `smp_send_reschedule(cpu)` | 10691 | Send reschedule IPI to target CPU for kick |

### 3.2 arch/x86/kvm/lapic.c

| Kernel API | Line(s) | Description |
|---|---|---|
| `kvm_apic_set_irq(vcpu, irq, dest_map)` | 820, 842, 1221, 1234 | Core function to inject interrupt into a vCPU via APIC |
| `kvm_apic_match_dest(vcpu, src, ...)` | 1064, 1418 | Check if vCPU matches interrupt destination (physical/logical) |
| `irqchip_in_kernel(kvm)` | 386 | Verify IRQ chip is present |

### 3.3 arch/x86/kvm/ioapic.c

| Kernel API | Line(s) | Description |
|---|---|---|
| `kvm_apic_match_dest(vcpu, ...)` | 117, 191, 299 | Check if target vCPU matches IOAPIC redirect destination |
| `kvm_irq_delivery_to_apic(kvm, src, irq, dest_map)` | 473, 477 | Deliver IOAPIC interrupt to target APIC(s) |
| `kvm_notify_irqfd_resampler(kvm, ...)` | 399 | Notify irqfd resampler when IOAPIC IRQ is deasserted |
| `kvm_io_bus_register_dev(kvm, bus, addr, len, dev)` | 729 | Register IOAPIC MMIO device on KVM MMIO bus |
| `kvm_io_bus_unregister_dev(kvm, bus, dev)` | 749 | Unregister IOAPIC MMIO device from KVM MMIO bus |

---

## 4. TIMER / CLOCK

### 4.1 arch/x86/kvm/x86.c

| Kernel API | Line(s) | Description |
|---|---|---|
| `rdtsc()` | 2575, 2807, 3075, 3210, 4259, 4984, 5080, 5703, 11018, 12403 | Read Time Stamp Counter for TSC offset/scale computation |
| `rdtsc_ordered()` | 2807 | Ordered TSC read with serialization barrier |
| `ktime_get_raw()` | 2303 | Get raw monotonic time (for pvclock offset computation) |
| `ktime_get_real_ns()` | 3293, 6915 | Get real (wall-clock) time in nanoseconds |
| `ktime_to_ns(kt)` | 2303, 2872 | Convert ktime_t to nanoseconds |
| `ktime_add(a, b)` | 2303, 2872 | Add two ktime_t values |
| `pvclock_gtod_register_notifier(nb)` | 9741 | Register notifier for guest TOD clock updates |
| `pvclock_gtod_notify(nb, ...)` | 9581 | Callback when host clocksource updates (pvclock sync) |
| `cpufreq_quick_get(cpu)` | 9383 | Get CPU frequency (TSC KHz calibration) |
| `cpufreq_register_notifier(nb, prio)` | 9541 | Register CPU frequency change notifier (TSC scaling) |
| `cpufreq_unregister_notifier(nb, prio)` | 9806 | Unregister CPU frequency notifier |
| `cpufreq_cpu_get(cpu)` | 9533 | Get cpufreq policy for a CPU |
| `cpufreq_cpu_put(policy)` | 9537 | Release cpufreq policy reference |
| `sched_clock()` | (implicit via includes) | Scheduler clock for timestamping |

### 4.2 arch/x86/kvm/mmu.c

| Kernel API | Line(s) | Description |
|---|---|---|
| *(no direct timer/clock API calls)* | -- | MMU module does not directly call timer APIs |

### 4.3 arch/x86/kvm/lapic.c

| Kernel API | Line(s) | Description |
|---|---|---|
| `hrtimer_init(timer, clock, mode)` | 2828 | Initialize high-resolution timer for APIC timer emulation |
| `hrtimer_start(timer, expire, mode)` | 1953, 2075 | Start APIC timer (one-shot or periodic) |
| `hrtimer_cancel(timer)` | 1743, 2113, 2367, 2472, 2508, 2685, 3034 | Cancel APIC timer (on reset, mode change, etc.) |
| `ktime_get()` | 1538, 1943, 1974, 1995, 2041 | Get current monotonic time for APIC timer arithmetic |
| `ktime_sub(a, b)` | 1539, 1975, 2055 | Subtract ktime_t values (remaining timer computation) |
| `ktime_to_ns(kt)` | 1540, 1543, 1976, 1979 | Convert ktime_t to nanoseconds |
| `ktime_after(a, b)` | 2065 | Compare two ktime_t values |
| `rdtsc()` | 1848, 1859, 1944, 1992, 2042 | Read TSC for TSC-deadline timer mode |

### 4.4 arch/x86/kvm/ioapic.c

| Kernel API | Line(s) | Description |
|---|---|---|
| *(no direct timer/clock API calls)* | -- | IOAPIC relies on LAPIC timers for delivery |

---

## 5. SYNC / LOCK

### 5.1 arch/x86/kvm/x86.c

| Kernel API | Line(s) | Description |
|---|---|---|
| `mutex_lock(m)` | 6275, 6345, 6356, 6366, 6382, 6406, 6463, 6608, 6620, 6637, 6667, 6771, 6847, 6956, 6972, 7015, 7091, 7117, 7139, 9395, 9467, 9556, 9787, 9823 | Acquire mutex (slots_lock, kvm->lock, pit_state.lock, kvm_lock, vendor_module_lock) |
| `mutex_unlock(m)` | 6280, 6347, 6360, 6370, 6393, 6408, 6482, 6613, 6627, 6643, 6672, 6774, 6859, 6965, 7003, 7027, 7097, 7123, 7144, 9415, 9477, 9561, 9789, 9825 | Release mutex |
| `spin_lock(l)` | 6317, 6323 | Acquire spinlock (PIC lock) |
| `spin_unlock(l)` | 6320, 6326 | Release spinlock |
| `raw_spin_lock_irqsave(l, flags)` | 2726, 5697 | Acquire raw spinlock with IRQ save (tsc_write_lock) |
| `raw_spin_unlock_irqrestore(l, flags)` | 2784, 5708 | Release raw spinlock with IRQ restore |
| `raw_spin_lock_irq(l)` | 3003 | Acquire raw spinlock with IRQ disable |
| `raw_spin_unlock_irq(l)` | 3022 | Release raw spinlock with IRQ enable |
| `srcu_read_lock(sp)` | 1806, 5071, 5910, 5916, 5946, 6179, 10613 | Acquire SRCU read lock (kvm->srcu) |
| `srcu_read_unlock(sp, idx)` | 1830, 5076, 5912, 5918, 5948, 6181, 10616 | Release SRCU read lock |
| `rcu_read_lock()` | 9981 | Acquire RCU read lock (APIC map access) |
| `rcu_read_unlock()` | 9987 | Release RCU read lock |
| `rcu_dereference(p)` | 9982 | Dereference RCU-protected pointer (apic_map) |
| `atomic_read(v)` | 2527, 2541, 2973, 9595 | Atomically read variable (online_vcpus, guest_has_master_clock) |
| `atomic_set(v, val)` | 2988, 5455, 9560 | Atomically set variable |
| `atomic_inc(v)` | 820 | Atomically increment (nmi_queued) |
| `lockdep_assert_held(l)` | 2675, 2971 | Runtime lockdep assertion (tsc_write_lock, slots_lock) |
| `WRITE_ONCE(p, v)` | 7204, 7669, 10906 | Atomic write with compiler barrier (tsc_khz, mode) |
| `READ_ONCE(p)` | 7210, 9934, 9940, 9989, 12407 | Atomic read with compiler barrier |
| `smp_store_release(p, v)` | 10906 | Store with release semantics (vcpu mode) |
| `down_read(rwsem)` | 10530 | Acquire reader semaphore (apicv_update_lock) |
| `up_read(rwsem)` | 10555 | Release reader semaphore |
| `down_write(rwsem)` | 10629 | Acquire writer semaphore (apicv_update_lock) |
| `up_write(rwsem)` | 10631 | Release writer semaphore |
| `static_branch_unlikely(key)` | 9821 | Static key branch for Xen enabled check |

### 5.2 arch/x86/kvm/mmu/mmu.c

| Kernel API | Line(s) | Description |
|---|---|---|
| `mutex_lock(m)` | 3748, 3792, 6866, 6914, 6969, 6971, 6975, 6985, 6988, 6990, 6994, 7137, 7142 | Acquire mutex (slots_arch_lock, kvm_lock, slots_lock) |
| `mutex_unlock(m)` | 3748, 3792, 6866, 6914, 6969, 6971, 6975, 6985, 6988, 6990, 6994, 7137, 7142 | Release mutex |
| `spin_lock(l)` | 2844, 2862 | Acquire spinlock (mmu_unsync_pages_lock) |
| `spin_unlock(l)` | 2862 | Release spinlock |
| `srcu_read_lock(sp)` | 6890, 7159 | Acquire SRCU read lock (kvm->srcu for memslot traversal) |
| `srcu_read_unlock(sp, idx)` | 6903, 7240 | Release SRCU read lock |
| `rcu_read_lock()` | 7167, 7232 | Acquire RCU read lock (kvm->srcu iteration) |
| `rcu_read_unlock()` | 7227, 7237 | Release RCU read lock |
| `atomic_set(v, val)` | 2137 | Atomically set variable (write_flooding_count) |
| `atomic_inc(v)` | 5721 | Atomically increment (write_flooding_count) |
| `atomic_read(v)` | 5722, 7209 | Atomically read variable |
| `lockdep_assert_held(l)` | 6250, 6463, 7365 | Runtime lockdep assertion (slots_lock) |
| `WRITE_ONCE(p, v)` | 339, 344, 393, 403, 3789 | Atomic write to SPTEs with compiler barrier |
| `READ_ONCE(p)` | 354, 1390, 2854, 3117, 3121, 3125, 3134, 5795, 6510, 7101, 7102, 7107 | Atomic read with compiler barrier |
| `smp_store_release(p, v)` | 674, 3789 | Store with release semantics (vcpu->mode, shadow_root_allocated) |

### 5.3 arch/x86/kvm/lapic.c

| Kernel API | Line(s) | Description |
|---|---|---|
| `mutex_lock(m)` | 389, 2601, 2640 | Acquire mutex (apic_map_lock, slots_lock) |
| `mutex_unlock(m)` | 402, 477, 2626, 2661 | Release mutex |
| `rcu_read_lock()` | 866, 1225, 1267, 1402 | Acquire RCU read lock (APIC map access) |
| `rcu_read_unlock()` | 876, 1238, 1280, 1426 | Release RCU read lock |
| `rcu_dereference(p)` | 867, 1226, 1268, 1403 | Dereference RCU-protected pointer (apic_map) |
| `srcu_read_lock(sp)` / `srcu_read_unlock(sp, idx)` | via kvm_vcpu_srcu_read_lock/unlock wrappers | SRCU for memslot access during APIC MMIO |
| `atomic_set(v, val)` | 1748, 2215, 2303, 2722 | Atomically set timer pending flag |
| `atomic_read(v)` | 1894, 2125, 2145, 2159, 2754, 2884 | Atomically read timer pending flag |
| `atomic_inc(v)` | 1921, 2236 | Atomically increment (timer pending, vapics_in_nmi_mode) |
| `atomic_dec(v)` | 2238 | Atomically decrement (vapics_in_nmi_mode) |
| `READ_ONCE(p)` | 664 | Atomic read (PIR vector) |
| `xchg(ptr, val)` | 667 | Atomic exchange (PIR vector clear) |
| `try_cmpxchg(ptr, old, new)` | 673 | Atomic compare-and-swap (PIR update) |

### 5.4 arch/x86/kvm/ioapic.c

| Kernel API | Line(s) | Description |
|---|---|---|
| `spin_lock(l)` | 143, 285, 492, 506, 517, 549, 584, 618, 676, 759, 769 | Acquire spinlock (ioapic->lock) |
| `spin_unlock(l)` | 145, 306, 497, 509, 527, 547, 593, 632, 689, 762, 775 | Release spinlock |
| `mutex_lock(m)` | 728, 748 | Acquire mutex (slots_lock) |
| `mutex_unlock(m)` | 731, 750 | Release mutex |

---

## 6. I/O / DEVICE

### 6.1 arch/x86/kvm/x86.c

| Kernel API | Line(s) | Description |
|---|---|---|
| `<linux/iommu.h>` include | 46 | IOMMU header included (for VT-d / AMD-Vi integration) |
| *(iommu calls are in kvm_iommu.c, not x86.c directly)* | -- | IOMMU operations delegated to kvm_iommu subsystem |

### 6.2 arch/x86/kvm/ioapic.c

| Kernel API | Line(s) | Description |
|---|---|---|
| `kvm_io_bus_register_dev(kvm, bus, addr, len, dev)` | 729 | Register IOAPIC as MMIO device on KVM MMIO bus |
| `kvm_io_bus_unregister_dev(kvm, bus, dev)` | 749 | Unregister IOAPIC from KVM MMIO bus |

---

## 7. SIGNAL / SCHED

### 7.1 arch/x86/kvm/x86.c

| Kernel API | Line(s) | Description |
|---|---|---|
| `signal_pending(current)` | 11344 | Check if a signal is pending for the current task (vCPU run loop) |
| `user_return_notifier_register(urn)` | 458 | Register user-return notifier for MSR save/restore on context switch |
| `user_return_notifier_unregister(urn)` | 377 | Unregister user-return notifier |
| `kvm_async_pf_task_wait_schedule(addr)` | (via async_pf in mmu.c) | Schedule async page fault wait |

---

## 8. VM / MM Subsystem

### 8.1 arch/x86/kvm/mmu/mmu.c

| Kernel API | Line(s) | Description |
|---|---|---|
| `pgd_offset(mm, addr)` | 3117 | Walk host page table: get PGD entry for host virtual address |
| `p4d_offset(pgd, addr)` | 3121 | Walk host page table: get P4D entry |
| `pud_offset(p4d, addr)` | 3125 | Walk host page table: get PUD entry |
| `pmd_offset(pud, addr)` | 3134 | Walk host page table: get PMD entry |
| `pgd_none(pgd)` | 3118 | Check if PGD entry is empty |
| `pud_none(pud)` | 3126 | Check if PUD entry is empty |
| `pud_present(pud)` | 3126 | Check if PUD entry is present |
| `pmd_none(pmd)` | 3135 | Check if PMD entry is empty |
| `pmd_present(pmd)` | 3135 | Check if PMD entry is present |

---

## 9. FS / USER / MISC

### 9.1 arch/x86/kvm/x86.c

| Kernel API | Line(s) | Description |
|---|---|---|
| `copy_to_user(to, from, n)` | 4541, 4572, 4852, 4858, 4861, 4883, 4905, 4911, 5777, 5836, 5904, 5931, 5975, 5996, 6006, 6026, 6055, 6071, 6197, 6218, 6881, 7046, 7082, 7108 | Copy data to userspace (ioctl results) |
| `copy_from_user(to, from, n)` | 4525, 4564, 4814, 4848, 4874, 4890, 4901, 4928, 4936, 5666, 5694, 5727, 5858, 5876, 5886, 5897, 5944, 5955, 5964, 5984, 6006, 6132, 6141, 6161, 6194, 6205, 6814, 6893, 6961, 7011, 7073, 7089, 7115, 7129, 7150, 7159, 7170, 7179, 7225, 7239, 7254, 7267, 7279 | Copy data from userspace (ioctl arguments) |
| `put_user(val, ptr)` | 4814, 5666, 6132, 6141, 4890 | Copy single value to userspace |
| `get_user(val, ptr)` | 5694, 6132 | Copy single value from userspace |
| `EXPORT_SYMBOL_GPL(sym)` | (pervasive) | Export symbol for GPL modules |
| `static_branch_unlikely(key)` | 9821 | Static key for unlikely branch (Xen enabled) |

### 9.2 arch/x86/kvm/lapic.c

| Kernel API | Line(s) | Description |
|---|---|---|
| `kvm_vcpu_srcu_read_lock(vcpu)` | 2663 | Acquire SRCU lock via KVM wrapper |
| `kvm_vcpu_srcu_read_unlock(vcpu)` | 2638 | Release SRCU lock via KVM wrapper |

---

## 10. Summary Statistics

### Per-File API Count

| File | MEMORY | VCPU/CPU | IRQ | TIMER | SYNC | IO/DEV | SIGNAL | USER/FS | VM/MM | **Total** |
|---|---|---|---|---|---|---|---|---|---|---|
| `x86.c` | 4 | 13 | 6 | 14 | 24 | 1 | 3 | 6 | 0 | **71** |
| `mmu.c` | 7 | 1 | 0 | 0 | 15 | 0 | 0 | 0 | 9 | **32** |
| `lapic.c` | 5 | 4 | 3 | 8 | 13 | 0 | 0 | 2 | 0 | **35** |
| `ioapic.c` | 2 | 0 | 5 | 0 | 4 | 2 | 0 | 0 | 0 | **13** |
| **Total** | **18** | **18** | **14** | **22** | **56** | **3** | **3** | **8** | **9** | **151** |

### Per-Category Unique API Functions

| Category | Unique Functions | Critical for Abstraction |
|---|---|---|
| **MEMORY** | kzalloc, kfree, kvfree, kvzalloc, get_zeroed_page, virt_to_page, set_page_private, page_to_pfn, put_page, kvm_release_pfn_clean, kvm_pfn_to_refcounted_page | YES -- page table allocation, shadow page tracking, PFN management |
| **VCPU/CPU** | wrmsrl, rdmsrl, rdmsr_safe, boot_cpu_has, cpu_feature_enabled, smp_processor_id, raw_smp_processor_id, preempt_disable/enable, smp_call_function_single, on_each_cpu_mask, switch_fpu_return, rdtsc, rdtsc_ordered, __delay, ndelay, div64_u64 | YES -- direct CPU MSR access, TSC reads, FPU state management |
| **IRQ** | irqchip_in_kernel, kvm_set_irq, kvm_setup_default_irq_routing, kvm_apic_set_irq, kvm_apic_match_dest, kvm_irq_delivery_to_apic, kvm_notify_irqfd_resampler, kvm_apic_local_deliver, smp_send_reschedule | YES -- virtual interrupt injection, APIC/IOAPIC routing |
| **TIMER** | rdtsc, rdtsc_ordered, ktime_get, ktime_get_raw, ktime_get_real_ns, ktime_to_ns, ktime_add, ktime_sub, ktime_after, hrtimer_init, hrtimer_start, hrtimer_cancel, pvclock_gtod_register_notifier, cpufreq_quick_get, cpufreq_register_notifier, cpufreq_unregister_notifier | YES -- APIC timer emulation, TSC virtualization, clock synchronization |
| **SYNC** | mutex_lock/unlock, spin_lock/unlock, raw_spin_lock_irqsave/unlock_irqrestore, srcu_read_lock/unlock, rcu_read_lock/unlock, rcu_dereference, atomic_read/set/inc/dec, lockdep_assert_held, WRITE_ONCE, READ_ONCE, smp_store_release, down_read/up_read, down_write/up_write, xchg, try_cmpxchg, static_branch_unlikely | PARTIAL -- primitives are universal, but integration points differ |
| **IO/DEV** | kvm_io_bus_register_dev, kvm_io_bus_unregister_dev, (iommu.h include) | YES -- MMIO bus registration, IOMMU integration |
| **SIGNAL** | signal_pending, user_return_notifier_register/unregister | MODERATE -- userspace return path for MSR management |
| **USER/FS** | copy_to_user, copy_from_user, put_user, get_user, EXPORT_SYMBOL_GPL | MODERATE -- ioctl data transfer (userspace interface) |
| **VM/MM** | pgd_offset, p4d_offset, pud_offset, pmd_offset, pgd_none, pud_none, pud_present, pmd_none, pmd_present | YES -- host page table walking for shadow/EPT management |

---

## Key Abstraction Challenges for HHAL

Based on this audit, the following host OS kernel services are deeply embedded in the x86 KVM code and would require abstraction:

1. **Timer Subsystem** (`hrtimer`, `ktime`, `cpufreq`): LAPIC timer emulation is tightly coupled to Linux hrtimers and cpufreq notifiers. A portable hypervisor would need its own timer abstraction.

2. **CPU MSR Access** (`wrmsrl`, `rdmsrl`, `boot_cpu_has`): Direct x86 MSR reads/writes and CPUID feature checks are pervasive. These are hardware operations but managed through Linux kernel APIs and scheduling constraints (preempt_disable, smp_call_function_single).

3. **Memory Management** (`get_zeroed_page`, `virt_to_page`, `set_page_private`, host page table walkers): The MMU code walks host page tables using Linux-specific PGD/P4D/PUD/PMD APIs and uses Linux page private data for shadow page tracking.

4. **FPU/XSAVE State** (`switch_fpu_return`, `kernel_fpu_begin/end`): FPU state management depends on Linux kernel FPU framework.

5. **Synchronization Primitives**: While spinlocks/mutexes/RCU are universal concepts, their Linux-specific APIs (SRCU, raw_spinlock_irqsave, user-return notifiers) need porting.

6. **Interrupt Routing** (`kvm_set_irq`, `kvm_irq_delivery_to_apic`, irqfd): The interrupt injection path relies on KVM-generic IRQ routing code which in turn depends on Linux IRQ infrastructure.

7. **Userspace Interface** (`copy_to/from_user`): The ioctl handler layer is Linux-specific but relatively straightforward to abstract with a different VMM communication mechanism.
