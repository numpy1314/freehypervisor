# KVM `kvm_main.c` (Linux v6.8) -- Host OS Kernel API Dependency Audit

**Source**: `virt/kvm/kvm_main.c` (6621 lines)  
**Date**: 2026-05-18  

---

## 1. MEMORY

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `alloc_page(gfp)` | Allocate a single struct page (used for vcpu->run page) | Create |
| `__get_free_page(gfp)` | Allocate a free page (MMU memory cache fallback) | Run |
| `free_page(addr)` | Free a page allocated by `__get_free_page` (vcpu->run, MMU cache) | Destroy |
| `kmem_cache_alloc(cache, gfp)` | Allocate from a slab cache (MMU memory cache objects) | Run |
| `kmem_cache_free(cache, obj)` | Free object back to slab cache (MMU memory cache, vcpu) | Destroy |
| `kmem_cache_zalloc(cache, gfp)` | Allocate zeroed from slab cache (vcpu struct) | Create |
| `kmem_cache_create_usercopy(...)` | Create a slab cache for vcpu structs with usercopy region | Init |
| `kmem_cache_destroy(cache)` | Destroy the vcpu slab cache | Exit |
| `kvmalloc_array(n, size, gfp)` | Allocate array with vmalloc fallback (MMU cache objects array) | Run |
| `__vcalloc(n, size, gfp)` | Allocate zeroed array with vmalloc fallback (dirty bitmap) | Run |
| `kvfree(ptr)` | Free kvmalloc'd memory (MMU cache objects, dirty bitmap) | Destroy |
| `kmalloc(size, gfp)` | Allocate kernel memory (io_bus, uevent env, etc.) | Create/Run |
| `kzalloc(size, gfp)` | Allocate zeroed kernel memory (memslots, devices, stats, etc.) | Create/Run |
| `kcalloc(n, size, gfp)` | Allocate zeroed array (debugfs stat data) | Create |
| `kfree(ptr)` | Free kmalloc'd memory (used pervasively) | Create/Destroy |
| `memdup_user(ptr, len)` | Copy user data into newly allocated kernel memory | Run |
| `vmemdup_array_user(ptr, n, size)` | Copy user array into newly allocated kernel memory | Run |
| `get_page(page)` | Increment page refcount (vcpu fault/mmap path) | Run |
| `put_page(page)` | Decrement page refcount (gfn-to-pfn release path) | Run |
| `get_page_unless_zero(page)` | Speculatively get page ref if non-zero | Run |
| `page_to_pfn(page)` / `pfn_to_page(pfn)` | Convert between struct page and page frame number | Run |
| `page_address(page)` | Get kernel virtual address of a page | Create |
| `virt_to_page(addr)` | Get struct page from kernel virtual address | Run |
| `page_to_phys(page)` | Get physical address from struct page | Run |
| `kmap(page)` | Temporarily map a highmem page | Run |
| `kunmap(page)` | Unmap a highmem page | Run |
| `memremap(offset, size, flags)` | Map I/O memory region | Run |
| `memunmap(addr)` | Unmap I/O memory region | Run |
| `SetPageDirty(page)` | Mark page as dirty | Run |
| `PageReserved(page)` | Check if page is reserved | Run |
| `mark_page_accessed(page)` | Mark page as accessed (for LRU/reclaim) | Run |
| `is_zero_pfn(pfn)` | Check if pfn is the zero page | Run |
| `is_zone_device_page(page)` | Check if page is ZONE_DEVICE | Run |
| `page_count(page)` | Get page reference count | Run |
| `ZERO_PAGE(n)` | Get the global zero page | Run |
| `__va(addr)` | Physical to virtual address conversion | Run |
| `alloc_cpumask_var_node(ptr, gfp, node)` | Allocate per-CPU cpumask | Init |
| `free_cpumask_var(ptr)` | Free per-CPU cpumask | Exit |

---

## 2. THREAD/VCPU

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `kthread_run(fn, data, name...)` | Create and wake a kernel thread (VM worker thread) | Run |
| `kthread_park(task)` | Park a kernel thread | Run |
| `kthread_parkme()` | Park current kernel thread | Run |
| `kthread_should_stop()` | Check if kthread should stop | Run |
| `cgroup_attach_task_all(parent, task)` | Move a task to the same cgroup as parent | Run |
| `set_user_nice(task, nice)` | Set task nice value | Run |
| `task_nice(task)` | Get task nice value | Run |
| `get_task_pid(task, type)` | Get pid struct for a task | Run |
| `get_pid_task(pid, type)` | Get task_struct from pid | Run |
| `put_pid(pid)` | Release pid reference | Destroy |
| `put_task_struct(task)` | Release task_struct reference | Run |
| `pid_nr(pid)` | Get numeric PID from pid struct | Run |
| `task_pid(task)` | Get pid struct for current task | Run |
| `task_pid_nr(task)` | Get numeric PID of a task | Create/Run |
| `yield_to(task, preempt)` | Yield current CPU to another task | Run |
| `init_completion(comp)` | Initialize a completion | Run |
| `complete(comp)` | Signal a completion | Run |
| `wait_for_completion(comp)` | Wait for a completion | Run |
| `get_cpu()` | Disable preemption and return CPU number | Run |
| `put_cpu()` | Re-enable preemption | Run |
| `preempt_disable()` | Disable kernel preemption | Run |
| `preempt_enable()` | Enable kernel preemption | Run |
| `this_cpu_read(var)` / `__this_cpu_read(var)` | Read per-CPU variable | Run |
| `this_cpu_write(var, val)` / `__this_cpu_write(var, val)` | Write per-CPU variable | Run |
| `this_cpu_cpumask_var_ptr(var)` | Get per-CPU cpumask pointer | Run |
| `preempt_notifier_register(pn)` | Register preempt notifier for vcpu | Run |
| `preempt_notifier_unregister(pn)` | Unregister preempt notifier | Run |
| `preempt_notifier_init(pn, ops)` | Initialize preempt notifier | Create |
| `preempt_notifier_inc()` | Increment preempt notifier usage count | Create |
| `preempt_notifier_dec()` | Decrement preempt notifier usage count | Destroy |
| `mmgrab(mm)` / `mmdrop(mm)` | Grab/drop mm_struct reference | Create/Destroy |
| `get_task_struct(task)` | Increment task_struct refcount | Run |
| `rcuwait_init(wait)` | Initialize rcuwait | Create |
| `rcuwait_wake_up(wait)` | Wake a waiter on rcuwait | Run |
| `prepare_to_rcuwait(wait)` | Prepare to wait on rcuwait | Run |
| `finish_rcuwait(wait)` | Finish rcuwait | Run |
| `rcuwait_active(wait)` | Check if rcuwait has waiters | Destroy |

---

## 3. SYNC

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `DEFINE_MUTEX(lock)` | Statically define a mutex (kvm_lock) | Init |
| `mutex_init(m)` | Initialize a mutex (kvm->lock, slots_lock, irq_lock, etc.) | Create |
| `mutex_lock(m)` | Acquire mutex (pervasive: kvm_lock, slots_lock, vcpu->mutex, etc.) | Create/Run/Destroy |
| `mutex_unlock(m)` | Release mutex | Create/Run/Destroy |
| `mutex_lock_killable(m)` | Acquire mutex, interruptible by kill signal (vcpu->mutex in ioctl) | Run |
| `spin_lock_init(s)` | Initialize a spinlock (mn_invalidate_lock, gpc_lock) | Create |
| `spin_lock(s)` | Acquire spinlock (mn_invalidate_lock) | Run |
| `spin_unlock(s)` | Release spinlock | Run |
| `init_srcu_struct(srcu)` | Initialize SRCU struct (kvm->srcu, kvm->irq_srcu) | Create |
| `cleanup_srcu_struct(srcu)` | Destroy SRCU struct | Destroy |
| `srcu_read_lock(srcu)` / `srcu_read_unlock(srcu, idx)` | Enter/exit SRCU read-side critical section | Run |
| `synchronize_srcu_expedited(srcu)` | Wait for SRCU readers (memslot swap, io_bus update) | Run |
| `synchronize_rcu()` | Wait for RCU grace period (vcpu pid change) | Run |
| `rcu_read_lock()` / `rcu_read_unlock()` | Enter/exit RCU read-side critical section | Run |
| `rcu_dereference(p)` | Dereference RCU-protected pointer | Run |
| `rcu_access_pointer(p)` | Access RCU pointer without dereference | Run |
| `rcu_assign_pointer(p, v)` | Assign to RCU-protected pointer (memslots, pid) | Run/Destroy |
| `rcu_dereference_protected(p, cond)` | Dereference RCU pointer under lock | Destroy |
| `rcu_dereference_check(p, cond)` | Conditionally dereference RCU pointer | Run |
| `xa_init(xa)` | Initialize xarray (vcpu_array, mem_attr_array) | Create |
| `xa_destroy(xa)` | Destroy xarray | Destroy |
| `xa_reserve(xa, index, gfp)` | Reserve entry in xarray | Create |
| `xa_store(xa, index, ptr, gfp)` | Store entry in xarray | Create |
| `xa_release(xa, index)` | Release reserved xarray entry | Create |
| `xa_erase(xa, index)` | Erase xarray entry | Destroy |
| `xa_err(entry)` | Extract error from xarray entry | Run |
| `xa_mk_value(v)` / `xa_to_value(entry)` | Convert value to/from xarray entry | Run |
| `refcount_set(r, v)` | Set refcount value | Create |
| `refcount_inc(r)` | Increment refcount | Create/Run |
| `refcount_inc_not_zero(r)` | Increment refcount if non-zero | Run |
| `refcount_dec_and_test(r)` | Decrement refcount, return true if zero | Destroy |
| `atomic_set(a, v)` / `atomic_read(a)` | Atomic set/read (online_vcpus, etc.) | Create/Run |
| `atomic_inc(a)` | Atomic increment | Run |
| `atomic_long_set(a, v)` / `atomic_long_read(a)` | Atomic long set/read (last_used_slot) | Create/Run |
| `atomic_long_fetch_andnot(mask, p)` | Atomic fetch-and-not (dirty bitmap) | Run |
| `lockdep_assert_held(l)` / `lockdep_assert_held_write(l)` | Runtime lock assertions | Run |
| `lockdep_assert_not_held(l)` | Assert lock is NOT held | Suspend |
| `lockdep_assert_irqs_disabled()` | Assert IRQs are disabled | Suspend |
| `KVM_MMU_LOCK(kvm)` / `KVM_MMU_UNLOCK(kvm)` | MMU lock/unlock (arch-specific: spinlock or write_lock) | Run |
| `smp_wmb()` / `smp_rmb()` | SMP memory barriers | Run |
| `smp_wmb()` | Store-store barrier | Run |
| `smp_call_function_many(cpus, fn, data, wait)` | Call function on multiple CPUs (IPI kick) | Run |
| `WRITE_ONCE(var, val)` / `READ_ONCE(var)` | Atomic-like volatile access | Run |
| `init_wait_entry(wq, flags)` | Initialize wait queue entry | (via rcuwait) |

---

## 4. EVENT

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `set_current_state(state)` | Set current task state (TASK_INTERRUPTIBLE, TASK_UNINTERRUPTIBLE) | Run |
| `schedule()` | Yield CPU to scheduler (vcpu block, memslot swap wait) | Run |
| `signal_pending(task)` | Check if signal is pending for task | Run |
| `kvm_vcpu_wake_up(vcpu)` | Wake vcpu from wait (via rcuwait) | Run |
| `smp_send_reschedule(cpu)` | Send reschedule IPI to a CPU (vcpu kick) | Run |
| `eventfd_signal(eventfd, n)` | Signal an eventfd (irqfd/ioeventfd -- via eventfd.c) | Run |
| `add_uevent_var(env, fmt, ...)` | Add variable to uevent environment | Create/Destroy |
| `kobject_uevent_env(kobj, action, envp)` | Send uevent to userspace | Create/Destroy |
| `vmf->page` / vm_fault_t | Page fault handler return (vcpu mmap fault) | Run |
| `vma_pages(vma)` | Get number of pages in a VMA | Run |

---

## 5. TIMER

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `ktime_get()` | Get current monotonic time (halt-poll timing) | Run |
| `ktime_to_ns(kt)` | Convert ktime to nanoseconds | Run |
| `ktime_add_ns(kt, ns)` | Add nanoseconds to ktime | Run |
| `ktime_sub(a, b)` | Subtract two ktime values | Run |
| `cpu_relax()` | CPU relaxation hint for busy-wait (halt polling) | Run |
| `kvm_cpu_has_pending_timer(vcpu)` | Check for pending timer interrupts (arch callback) | Run |

---

## 6. IRQ

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `cpus_read_lock()` / `cpus_read_unlock()` | CPU hotplug read lock (hardware enable/disable) | Create/Destroy |
| `cpuhp_setup_state_nocalls(state, name, online, offline)` | Register CPU hotplug callbacks | Init |
| `cpuhp_remove_state_nocalls(state)` | Remove CPU hotplug callbacks | Exit |
| `on_each_cpu(fn, data, wait)` | Execute function on all CPUs (hardware enable/disable) | Init/Run/Destroy |
| `raw_smp_processor_id()` | Get current CPU ID (hardware enable failure log) | Run |
| `cpu_online(cpu)` | Check if CPU is online | Run |
| `nr_cpu_ids` | Number of possible CPU IDs | Run |
| `register_syscore_ops(ops)` | Register system core operations (suspend/resume/shutdown) | Init |
| `unregister_syscore_ops(ops)` | Unregister system core operations | Exit |
| `system_state` | Global system state (halt/poweroff/restart check) | Create |
| `lockdep_assert_irqs_disabled()` | Assert IRQs are disabled | Suspend |

---

## 7. IO (User-Kernel Data Transfer)

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `copy_to_user(dst, src, n)` | Copy data from kernel to userspace | Run |
| `copy_from_user(dst, src, n)` | Copy data from userspace to kernel | Run |
| `__copy_to_user(dst, src, n)` | Unchecked copy to user (guest read/write) | Run |
| `__copy_from_user(dst, src, n)` | Unchecked copy from user (guest read/write) | Run |
| `__copy_from_user_inatomic(dst, src, n)` | Atomic copy from user (guest atomic read) | Run |
| `access_ok(addr, size)` | Verify user space address is valid | Create |
| `untagged_addr(addr)` | Remove tag from tagged address | Create |
| `pagefault_disable()` / `pagefault_enable()` | Disable/enable page fault handling | Run |
| `compat_ptr(uptr)` | Convert compat pointer to user pointer | Run |
| `get_compat_sigset(set, compat)` | Get compat signal set | Run |
| `is_compat_task()` | Check if current task is in compat (32-bit) mode | Run |

---

## 8. FILE/FS

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `anon_inode_getfd(name, fops, priv, flags)` | Create anonymous inode fd (vcpu fd, device fd) | Create |
| `anon_inode_getfile(name, fops, priv, flags)` | Create anonymous inode file (stats fd) | Create |
| `get_unused_fd_flags(flags)` | Allocate an unused file descriptor | Create |
| `put_unused_fd(fd)` | Release unused file descriptor (error path) | Create |
| `fd_install(fd, file)` | Install file into fd table | Create |
| `misc_register(mdev)` | Register misc character device (/dev/kvm) | Init |
| `misc_deregister(mdev)` | Deregister misc character device | Exit |
| `file_operations` | File operations struct (vm_fops, vcpu_fops, device_fops, chardev_ops) | Init |
| `noop_llseek` / `no_llseek` | No-op llseek implementations | Init |
| `IS_ERR(ptr)` / `PTR_ERR(ptr)` | Error pointer checking | Create |
| `fmode_t` flags (`FMODE_PREAD`) | File mode flags | Create |
| `dentry_path_raw(dentry, buf, size)` | Get path string of a dentry | Run |
| `DEFINE_SIMPLE_ATTRIBUTE(fops, get, set, fmt)` | Define simple debugfs file operations | Init |
| `simple_attr_open/release/read/write` | Simple attribute file operations | Init |

---

## 9. SIGNAL

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `sigprocmask(how, set, oldset)` | Change signal mask (vcpu sigset activate/deactivate) | Run |
| `sigemptyset(set)` | Empty a signal set | Run |
| `sigdelsetmask(set, mask)` | Delete signals from set (remove SIGKILL/SIGSTOP) | Run |
| `sigmask(signo)` | Create signal mask for a signal number | Run |
| `signal_pending(task)` | Check if a signal is pending | Run |
| `vcpu_valid_wakeup(vcpu)` | Validate vcpu wakeup (arch-specific, may check spurious) | Run |
| `current->real_blocked` | Task's real blocked signal mask | Run |
| `current->on_rq` | Task runqueue state (preemption detection) | Run |

---

## 10. MMU/PAGETABLE

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `mmu_notifier_register(mn, mm)` | Register MMU notifier for address space tracking | Create |
| `mmu_notifier_unregister(mn, mm)` | Unregister MMU notifier | Destroy |
| `mmu_notifier_range_blockable(range)` | Check if MMU notifier range is blockable | Run |
| `mmap_read_lock(mm)` / `mmap_read_unlock(mm)` | Acquire/release mm mmap read lock | Run |
| `find_vma(mm, addr)` | Find VMA containing address | Run |
| `vma_lookup(mm, addr)` | Look up VMA at exact address | Run |
| `vma_kernel_pagesize(vma)` | Get kernel page size for VMA | Run |
| `vma_is_valid(vma, write)` | Check VMA flags (VM_READ/VM_WRITE) | Run |
| `get_user_pages(addr, n, flags, pages)` | Pin user pages (hwpoison check) | Run |
| `get_user_page_fast_only(addr, flags, page)` | Fast-path pin single user page (fast GUP) | Run |
| `get_user_pages_unlocked(addr, n, pages, flags)` | Pin user pages without mmap_lock (slow GUP) | Run |
| `get_user_pages_fast_only(addr, n, flags, pages)` | Fast pin multiple user pages | Run |
| `follow_pte(mm, addr, ptep, ptlp)` | Follow page table entry for a virtual address | Run |
| `fixup_user_fault(mm, addr, flags, unlocked)` | Handle user-space page fault | Run |
| `pfn_valid(pfn)` | Check if pfn is valid | Run |
| `pfn_to_page(pfn)` / `page_to_pfn(page)` | PFN <-> struct page conversion | Run |
| `pte_pfn(pte)` | Extract PFN from PTE | Run |
| `pte_write(pte)` | Check if PTE is writable | Run |
| `ptep_get(ptep)` | Get PTE value | Run |
| `pte_unmap_unlock(ptep, ptl)` | Unmap and unlock PTE | Run |
| `access_ok(addr, size)` | Verify user address range is accessible | Create |
| `might_sleep()` | Debug assertion that sleeping is allowed | Run |
| `RB_ROOT` / `RB_ROOT_CACHED` | Red-black tree root initialization | Create |
| `rb_link_node(node, parent, rb_link)` | Link node into red-black tree | Run |
| `rb_insert_color(node, root)` | Rebalance after red-black tree insert | Run |
| `rb_erase(node, root)` | Remove node from red-black tree | Run |
| `rb_replace_node(old, new, root)` | Replace node in red-black tree | Run |
| `interval_tree_insert(node, root)` | Insert into interval tree | Run |
| `interval_tree_remove(node, root)` | Remove from interval tree | Run |
| `interval_tree_iter_first/next(root, start, last)` | Iterate interval tree | Run |
| `hash_init(ht)` / `hash_add(ht, node, key)` / `hash_del(node)` | Hash table operations | Run |
| `hash_for_each_safe(ht, bkt, tmp, obj, member)` | Safe hash table iteration | Destroy |
| `bitmap_set(map, start, n)` / `set_bit_le(nr, addr)` | Set bits in bitmap | Run |
| `xchg(addr, new)` | Atomic exchange | Run |

---

## 11. DEVICE

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `misc_register(&kvm_dev)` | Register `/dev/kvm` misc device | Init |
| `misc_deregister(&kvm_dev)` | Deregister `/dev/kvm` misc device | Exit |
| `kvm_dev.this_device` | Access the device struct for uevents | Run |
| `perf_register_guest_info_callbacks(cbs)` | Register perf guest callbacks (Intel PT) | Init |
| `perf_unregister_guest_info_callbacks(cbs)` | Unregister perf guest callbacks | Exit |

---

## 12. NOTIFIER

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `register_pm_notifier(nb)` | Register PM suspend/resume notifier | Create |
| `unregister_pm_notifier(nb)` | Unregister PM notifier | Destroy |
| `register_syscore_ops(ops)` | Register syscore ops for suspend/resume/shutdown | Init |
| `unregister_syscore_ops(ops)` | Unregister syscore ops | Exit |
| `notifier_block` / `notifier_call` | Notifier callback infrastructure | Create |

---

## 13. DEBUG/TRACE (Additional Category)

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `debugfs_create_dir(name, parent)` | Create debugfs directory | Init/Create |
| `debugfs_create_file(name, mode, parent, data, fops)` | Create debugfs file | Init/Create |
| `debugfs_remove_recursive(dentry)` | Recursively remove debugfs entries | Destroy/Exit |
| `debugfs_lookup(name, parent)` | Look up existing debugfs entry | Create |
| `debugfs_initialized()` | Check if debugfs is initialized | Create |
| `dput(dentry)` | Release dentry reference | Create |
| `pr_info(fmt, ...)` / `pr_err(fmt, ...)` | Kernel print at info/error level | Init/Run |
| `pr_warn_ratelimited(fmt, ...)` | Rate-limited warning print | Create |
| `WARN_ON(cond)` / `WARN_ON_ONCE(cond)` | Emit warning with stack trace | Run |
| `BUG_ON(cond)` / `BUG()` | Fatal assertion (kernel panic) | Run |
| `BUILD_BUG_ON(cond)` | Compile-time assertion | Compile |
| `trace_kvm_*` | KVM tracepoints (via trace/events/kvm.h) | Run |
| `MODULE_AUTHOR/AUTHOR/LICENSE` | Module metadata | Compile |
| `module_param(name, type, perm)` | Define module parameter | Compile |
| `EXPORT_SYMBOL_GPL(sym)` | Export symbol for GPL modules | Compile |
| `THIS_MODULE` | Reference to current module | Init |
| `print_tainted()` | Check kernel taint state (via WARN) | Run |
| `kvm_err(fmt, ...)` | KVM-specific error print | Run |

---

## 14. INIT/BOOT (Additional Category)

| Kernel API | Description | Lifecycle Phase |
|---|---|---|
| `for_each_possible_cpu(cpu)` | Iterate over all possible CPUs | Init/Exit |
| `cpu_to_node(cpu)` | Get NUMA node for a CPU | Init |
| `nr_cpu_ids` | Total number of CPU IDs | Run |
| `ARRAY_SIZE(arr)` | Compute array size (compile-time) | Compile |
| `offsetof(type, member)` / `offsetofend(type, member)` | Structure layout macros | Compile |
| `sizeof_field(type, member)` | Get size of struct field | Compile |
| `IS_ENABLED(config)` | Check if kernel config is enabled | Run |
| `container_of(ptr, type, member)` | Get enclosing struct from member pointer | Run |
| `list_add(node, head)` / `list_del(node)` | Linked list operations | Create/Destroy |
| `list_for_each_entry(pos, head, member)` | Iterate linked list | Run |
| `list_for_each_entry_safe(pos, tmp, head, member)` | Safe list iteration | Destroy |
| `INIT_LIST_HEAD(head)` / `INIT_HLIST_HEAD(head)` | Initialize list head | Create |
| `struct_size(ptr, member, n)` | Calculate size of flexible array struct | Run |
| `flex_array_size(ptr, member, n)` | Calculate flexible array size | Run |
| `array_index_nospec(index, size)` | Speculation barrier for array index | Run |
| `snprintf(buf, size, fmt, ...)` | Format string to buffer | Create |
| `memset(s, c, n)` | Fill memory with constant byte | Run |
| `memcpy(d, s, n)` | Copy memory | Run |
| `bsearch(key, base, n, size, cmp)` | Binary search (IO bus lookup) | Run |
| `sort(base, n, size, cmp, swap)` | Sort array (IO bus sort) | Run |
| `PAGE_SIZE` / `PAGE_SHIFT` / `PAGE_ALIGNED(x)` | Page-related constants/macros | Compile/Run |
| `TASK_INTERRUPTIBLE` / `TASK_UNINTERRUPTIBLE` | Task state constants | Run |
| `GFP_KERNEL` / `GFP_KERNEL_ACCOUNT` / `GFP_ATOMIC` / `GFP_ZERO` | Allocation flags | Run |
| `SLAB_ACCOUNT` | Slab accounting flag | Init |
| `O_RDWR` / `O_RDONLY` / `O_CLOEXEC` | File open flags | Create |
| `EFAULT` / `ENOMEM` / `EINVAL` / `ENOENT` / etc. | Standard error codes | Run |

---

## Summary Statistics

| Category | Count of Distinct APIs |
|---|---|
| 1. MEMORY | 34 |
| 2. THREAD/VCPU | 36 |
| 3. SYNC | 45 |
| 4. EVENT | 10 |
| 5. TIMER | 6 |
| 6. IRQ | 11 |
| 7. IO | 11 |
| 8. FILE/FS | 14 |
| 9. SIGNAL | 8 |
| 10. MMU/PAGETABLE | 39 |
| 11. DEVICE | 4 |
| 12. NOTIFIER | 5 |
| 13. DEBUG/TRACE | 20 |
| 14. INIT/BOOT | 33 |
| **Total** | **~276** |

---

## Key Observations for HHAL (Hypervisor Hardware Abstraction Layer)

1. **Heaviest dependency classes**: SYNC (45), MMU/PAGETABLE (39), THREAD/VCPU (36), MEMORY (34). These four categories represent the core of what an OS-agnostic abstraction layer must provide.

2. **Critical path dependencies for VM lifecycle**:
   - **Create VM**: `mmgrab`, `mutex_init`, `init_srcu_struct`, `mmu_notifier_register`, `misc_register`, `anon_inode_getfd`, `alloc_page`, `kmem_cache_zalloc`, `register_pm_notifier`, `preempt_notifier_inc`
   - **Run VCPU**: `get_user_pages*`, `mmap_read_lock`, `follow_pte`, `fixup_user_fault`, `copy_to/from_user`, `mutex_lock`, `srcu_read_lock`, `schedule`, `ktime_get`, `signal_pending`, `smp_send_reschedule`
   - **Destroy VM**: `mmdrop`, `cleanup_srcu_struct`, `mmu_notifier_unregister`, `kfree`, `kvfree`, `free_page`, `kmem_cache_free`, `unregister_pm_notifier`, `preempt_notifier_dec`

3. **Linux-specific constructs that are deeply embedded**:
   - **RCU/SRCU**: Used extensively for lock-free memslot access, vcpu pid management
   - **MMU notifiers**: Core mechanism for shadow page table invalidation
   - **Preempt notifiers**: Used for vcpu load/put scheduling hooks
   - **anon_inodes**: File descriptor management for VM and VCPU fds
   - **miscdevice**: `/dev/kvm` character device registration
   - **CPU hotplug (cpuhp)**: Hardware virtualization enable/disable on CPU online/offline
   - **syscore_ops**: Suspend/resume/shutdown hooks
   - **xarray**: VCPU array and memory attribute tracking
