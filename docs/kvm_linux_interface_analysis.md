# KVM 与 Linux 内核接口函数分类分析

> 本文档统计 KVM (Kernel-based Virtual Machine) 作为 Type-2 Hypervisor 与底层 Linux 内核之间的关键接口函数。
> 源码基于 Linux 6.x (torvalds/linux master 分支)。
> 源码位置: `linux-kvm-reference/` 子目录。

---

## 目录

1. [内存管理 (Memory)](#1-内存管理-memory)
2. [时钟 (Timer)](#2-时钟-timer)
3. [主机信息 (Host)](#3-主机信息-host)
4. [虚拟机管理 (Virtual Machine Manage)](#4-虚拟机管理-virtual-machine-manage)
5. [架构相关 (Arch)](#5-架构相关-arch)

---

## 1. 内存管理 (Memory)

### 1.1 Guest 内存区域管理

#### `kvm_set_memory_region()`
- **源码**: `virt/kvm/kvm_main.c:1994`
- **语义**: 设置/创建/删除/移动 guest 的内存区域 (memslot)。将用户空间内存映射到 guest 物理地址空间。
- **关键逻辑**:
  - 验证 `kvm_userspace_memory_region2` 参数
  - 通过 `id_to_memslot()` 查找已有 slot
  - 根据 `npages` 判断是 CREATE/DELETE/MOVE/FLAGS_ONLY
  - 调用 `kvm_set_memslot()` 完成实际切换

```c
// virt/kvm/kvm_main.c:1994
static int kvm_set_memory_region(struct kvm *kvm,
                 const struct kvm_userspace_memory_region2 *mem)
{
    struct kvm_memory_slot *old, *new;
    struct kvm_memslots *slots;
    enum kvm_mr_change change;
    unsigned long npages;
    gfn_t base_gfn;
    int as_id, id;
    int r;

    lockdep_assert_held(&kvm->slots_lock);
    r = check_memory_region_flags(kvm, mem);
    if (r) return r;

    as_id = mem->slot >> 16;
    id = (u16)mem->slot;
    // ...参数校验...
    base_gfn = (mem->guest_phys_addr >> PAGE_SHIFT);
    npages = (mem->memory_size >> PAGE_SHIFT);
    // ...
    r = kvm_set_memslot(kvm, old, new, change);
    return r;
}
```

#### `gfn_to_memslot()` / `kvm_vcpu_gfn_to_memslot()`
- **源码**: `virt/kvm/kvm_main.c:2628` / `virt/kvm/kvm_main.c:2634`
- **语义**: 根据 GFN (Guest Frame Number) 查找对应的 memory slot。vCPU 版本带有 per-vCPU 缓存优化。

```c
// virt/kvm/kvm_main.c:2628
struct kvm_memory_slot *gfn_to_memslot(struct kvm *kvm, gfn_t gfn)
{
    return __gfn_to_memslot(kvm_memslots(kvm), gfn);
}
```

#### `kvm_is_visible_gfn()`
- **源码**: `virt/kvm/kvm_main.c:2668`
- **语义**: 检查给定 GFN 是否属于用户可见的 memslot（非内部 slot）。

### 1.2 GFN -> HVA/PFN 转换

#### `gfn_to_hva_memslot()` / `gfn_to_hva()` / `kvm_vcpu_gfn_to_hva()`
- **源码**: `virt/kvm/kvm_main.c:2734-2751`
- **语义**: 将 Guest 物理页帧号 (GFN) 转换为 Host 虚拟地址 (HVA)。这是 KVM 内存管理链路的核心一步。

```c
// virt/kvm/kvm_main.c:2734
unsigned long gfn_to_hva_memslot(struct kvm_memory_slot *slot, gfn_t gfn)
{
    return gfn_to_hva_many(slot, gfn, NULL);
}
```

#### `hva_to_pfn()` — HVA 到物理页帧号转换
- **源码**: `virt/kvm/kvm_main.c:2985`
- **语义**: 将宿主机虚拟地址转换为物理页帧号 (PFN)。这是 KVM 使用 GUP (Get User Pages) 子系统的核心入口。
- **调用链**: `hva_to_pfn_fast()` -> `hva_to_pfn_slow()` -> `hva_to_pfn_remapped()`

```c
// virt/kvm/kvm_main.c:2985
kvm_pfn_t hva_to_pfn(struct kvm_follow_pfn *kfp)
{
    struct vm_area_struct *vma;
    kvm_pfn_t pfn;
    int npages, r;
    might_sleep();
    if (WARN_ON_ONCE(!kfp->refcounted_page))
        return KVM_PFN_ERR_FAULT;
    if (hva_to_pfn_fast(kfp, &pfn))  // 快速路径
        return pfn;
    npages = hva_to_pfn_slow(kfp, &pfn);  // 慢速路径
    if (npages == 1) return pfn;
    // ... mmap_read_lock 降级处理 ...
    mmap_read_lock(current->mm);
    vma = vma_lookup(current->mm, kfp->hva);
    // ...
}
```

### 1.3 页面锁定 (Pin/Lock)

#### `pin_user_pages_fast()` — 快速锁定用户页面
- **源码**: `mm/gup.c` (内核核心), KVM 调用在 `virt/kvm/kvm_main.c:2867`
- **语义**: 高效地将用户空间页面锁定在内存中，防止被 swap out。用于 KVM 需要直接访问 guest 内存页的场景。

```c
// virt/kvm/kvm_main.c:2851 (hva_to_pfn_fast)
static bool hva_to_pfn_fast(struct kvm_follow_pfn *kfp, kvm_pfn_t *pfn)
{
    struct page *page;
    bool r;
    if (!((kfp->flags & FOLL_WRITE) || kfp->map_writable))
        return false;
    if (kfp->pin)
        r = pin_user_pages_fast(kfp->hva, 1, FOLL_WRITE, &page) == 1;
    else
        r = get_user_page_fast_only(kfp->hva, FOLL_WRITE, &page);
    // ...
}
```

#### `pin_user_pages_unlocked()` — 慢速路径锁定
- **源码**: `mm/gup.c`, KVM 调用在 `virt/kvm/kvm_main.c:2901`
- **语义**: 当快速路径失败时，通过完整的 GUP 路径锁定页面，支持 NUMA hinting fault。

#### `unpin_user_page()` — 解锁页面
- **源码**: `mm/gup.c`, KVM 调用在 `virt/kvm/kvm_main.c:3163` (`kvm_vcpu_unmap`)
- **语义**: 释放之前通过 `pin_user_pages_*` 锁定的页面。

### 1.4 Guest 页面映射

#### `__kvm_faultin_pfn()` — Guest 页错误时获取 PFN
- **源码**: `virt/kvm/kvm_main.c:3049`
- **语义**: 当 guest 发生 page fault 时，KVM 调用此函数将 GFN 解析为 PFN。是 guest page fault 处理的核心入口。

```c
// virt/kvm/kvm_main.c:3049
kvm_pfn_t __kvm_faultin_pfn(const struct kvm_memory_slot *slot, gfn_t gfn,
                unsigned int foll, bool *writable,
                struct page **refcounted_page)
{
    struct kvm_follow_pfn kfp = {
        .slot = slot,
        .gfn = gfn,
        .flags = foll,
        .map_writable = writable,
        .refcounted_page = refcounted_page,
    };
    *writable = false;
    *refcounted_page = NULL;
    return kvm_follow_pfn(&kfp);
}
```

#### `__gfn_to_page()` — GFN 转为 struct page
- **源码**: `virt/kvm/kvm_main.c:3095`
- **语义**: 获取 guest 页面对应的 `struct page`，增加引用计数。

#### `__kvm_vcpu_map()` / `kvm_vcpu_unmap()` — 映射/解除映射 guest 页面到内核地址空间
- **源码**: `virt/kvm/kvm_main.c:3110` / `virt/kvm/kvm_main.c:3144`
- **语义**: 临时将 guest 的一个物理页映射到内核地址空间（通过 `kmap()` 或 `memremap()`），用于直接读写 guest 内存。

```c
// virt/kvm/kvm_main.c:3110
int __kvm_vcpu_map(struct kvm_vcpu *vcpu, gfn_t gfn, struct kvm_host_map *map,
           bool writable)
{
    struct kvm_follow_pfn kfp = {
        .slot = kvm_vcpu_gfn_to_memslot(vcpu, gfn),
        .gfn = gfn,
        .flags = writable ? FOLL_WRITE : 0,
        .refcounted_page = &map->pinned_page,
        .pin = true,  // 需要锁定
    };
    map->pfn = kvm_follow_pfn(&kfp);
    // ...
    if (pfn_valid(map->pfn)) {
        map->page = pfn_to_page(map->pfn);
        map->hva = kmap(map->page);  // 映射到内核空间
    }
    return map->hva ? 0 : -EFAULT;
}
```

### 1.5 Guest 内存读写

#### `kvm_read_guest()` / `kvm_write_guest()`
- **源码**: `virt/kvm/kvm_main.c:3235` / `virt/kvm/kvm_main.c:3346`
- **语义**: 从 guest 物理内存读取/写入数据。内部通过 `gfn_to_hva()` + `__copy_{from,to}_user()` 实现。

### 1.6 脏页追踪 (Dirty Page Tracking)

#### `kvm_get_dirty_log()`
- **源码**: `virt/kvm/kvm_main.c:2197`
- **语义**: 获取指定 memslot 的脏页位图，用于 live migration。

#### `mark_page_dirty_in_slot()` / `mark_page_dirty()`
- **源码**: `virt/kvm/kvm_main.c:3536` / `virt/kvm/kvm_main.c:3545`
- **语义**: 标记某个 guest 页面为脏页。如果启用了 dirty bitmap 则设置对应位；如果启用了 dirty ring 则写入 ring buffer。

```c
// virt/kvm/kvm_main.c:3536
void mark_page_dirty_in_slot(struct kvm *kvm,
        const struct kvm_memory_slot *memslot, gfn_t gfn)
{
    if (kvm->dirty_ring_size)
        kvm_dirty_ring_push(vcpu, memslot, gfn);
    else if (memslot->dirty_bitmap)
        set_bit_le(rel_gfn, memslot->dirty_bitmap);
}
```

### 1.7 MMU Notifier（反向映射同步）

#### `kvm_mmu_notifier_ops` 结构体
- **源码**: `virt/kvm/kvm_main.c:878`
- **语义**: 注册到 Linux mm 子系统的通知回调。当宿主机进程的地址空间发生变化（页面回收、munmap、COW 等）时，KVM 需要同步清理 shadow page table / EPT 中的对应映射。

```c
// virt/kvm/kvm_main.c:878
static const struct mmu_notifier_ops kvm_mmu_notifier_ops = {
    .invalidate_range_start = kvm_mmu_notifier_invalidate_range_start,
    .invalidate_range_end   = kvm_mmu_notifier_invalidate_range_end,
    .clear_flush_young      = kvm_mmu_notifier_clear_flush_young,
    .clear_young            = kvm_mmu_notifier_clear_young,
    .test_young             = kvm_mmu_notifier_test_young,
    .release                = kvm_mmu_notifier_release,
};
```

#### `mmu_notifier_register()` — 注册 MMU 通知器
- **源码**: `mm/mmu_notifier.c`, KVM 调用在 `virt/kvm/kvm_main.c:889`
- **语义**: 将 KVM 的 `mmu_notifier` 注册到当前进程的 `mm_struct`，使得 KVM 能收到该进程地址空间变更的通知。

### 1.8 TLB 刷新

#### `kvm_flush_remote_tlbs()`
- **源码**: `virt/kvm/kvm_main.c:296`
- **语义**: 请求所有 vCPU 刷新其 TLB（通常是 shadow page table 或 EPT 变更后）。通过 `kvm_make_all_cpus_request(KVM_REQ_TLB_FLUSH)` 发送 IPI 实现。

---

## 2. 时钟 (Timer)

### 2.1 hrtimer 接口

#### `hrtimer_start()` — 启动高精度定时器
- **源码**: `include/linux/hrtimer.h`, KVM 使用在:
  - `arch/x86/kvm/lapic.c:2089` — LAPIC 定时器
  - `arch/x86/kvm/i8254.c:361` — PIT 定时器
- **语义**: 启动一个高精度定时器，用于模拟 guest 的定时器设备。

#### `hrtimer_cancel()` — 取消定时器
- **KVM 使用位置**: `arch/x86/kvm/lapic.c:2268`, `arch/x86/kvm/i8254.c:229`
- **语义**: 取消一个已启动的 hrtimer。

#### `hrtimer_setup()` — 初始化定时器
- **KVM 使用位置**: `arch/x86/kvm/i8254.c:762` (PIT 初始化)
- **语义**: 初始化 hrtimer 结构并绑定回调函数。

### 2.2 LAPIC 定时器模拟

#### `struct kvm_timer` — KVM 定时器核心数据结构
- **源码**: `arch/x86/kvm/lapic.h:49`
- **语义**: KVM 中 guest 定时器的核心抽象，封装了 hrtimer、TSC deadline、定时器模式等。

```c
// arch/x86/kvm/lapic.h:49
struct kvm_timer {
    struct hrtimer timer;           // 底层 Linux hrtimer
    s64 advance_expire_delta;       // 定时器提前量
    u64 expired_tscdeadline;        // 已过期的 TSC deadline
    u64 tscdeadline;                // 目标 TSC deadline
    u64 expired_target_expiration;  // 周期模式下已过期的目标
    u32 timer_advance_ns;           // 定时器提前量 (ns)
    atomic_t pending;               // 是否有待处理的中断
    bool hv_timer_in_use;           // 是否使用硬件虚拟化定时器
};
```

#### `start_hv_timer()` — 启动硬件虚拟化定时器
- **源码**: `arch/x86/kvm/lapic.c:2251`
- **语义**: 使用 CPU 的 VMX preemption timer 或 AMD 等价机制来模拟 guest 定时器，比软件 hrtimer 精度更高、开销更小。回退到 `start_sw_timer()`。

#### `start_sw_timer()` — 启动软件定时器
- **源码**: `arch/x86/kvm/lapic.c:2293`
- **语义**: 当硬件定时器不可用时，回退使用 Linux hrtimer 模拟 guest 定时器。

#### `apic_timer_expired()` — 定时器到期回调
- **源码**: `arch/x86/kvm/lapic.c:2025`
- **语义**: 当 guest 定时器到期时，向 guest 注入定时器中断。支持 posted interrupt 优化。

```c
// arch/x86/kvm/lapic.c:2025
static void apic_timer_expired(struct kvm_lapic *apic, bool from_timer_fn)
{
    struct kvm_vcpu *vcpu = apic->vcpu;
    struct kvm_timer *ktimer = &apic->lapic_timer;
    if (atomic_read(&apic->lapic_timer.pending)) return;
    if (!from_timer_fn && apic->apicv_active) {
        kvm_apic_inject_pending_timer_irqs(apic);
        return;
    }
    if (kvm_use_posted_timer_interrupt(apic->vcpu)) {
        __kvm_wait_lapic_expire(vcpu);
        kvm_apic_inject_pending_timer_irqs(apic);
        return;
    }
    atomic_inc(&apic->lapic_timer.pending);
    kvm_make_request(KVM_REQ_UNBLOCK, vcpu);
    if (from_timer_fn) kvm_vcpu_kick(vcpu);
}
```

#### `start_sw_tscdeadline()` — TSC deadline 模式的软件定时器
- **源码**: `arch/x86/kvm/lapic.c:2063`
- **语义**: 计算从当前 TSC 到 deadline 的时间差，转换为纳秒后启动 hrtimer。

```c
// arch/x86/kvm/lapic.c:2063
static void start_sw_tscdeadline(struct kvm_lapic *apic)
{
    u64 guest_tsc, tscdeadline = ktimer->tscdeadline;
    u64 ns = 0;
    ktime_t expire;
    now = ktime_get();
    guest_tsc = kvm_read_l1_tsc(vcpu, rdtsc());
    ns = (tscdeadline - guest_tsc) * 1000000ULL;
    do_div(ns, this_tsc_khz);
    expire = ktime_add_ns(now, ns);
    expire = ktime_sub_ns(expire, ktimer->timer_advance_ns);
    hrtimer_start(&ktimer->timer, expire, HRTIMER_MODE_ABS_HARD);
}
```

### 2.3 PIT (i8254) 定时器模拟

#### `pit_timer_fn()` — PIT 定时器回调
- **源码**: `arch/x86/kvm/i8254.c:268`
- **语义**: PIT (Programmable Interval Timer) 的 hrtimer 回调函数，周期模式下自动重新加载。

### 2.4 TSC 虚拟化

#### `kvm_read_l1_tsc()` — 读取 L1 TSC
- **源码**: `arch/x86/kvm/x86.c`
- **语义**: 读取当前 TSC 值并应用 L1 的 TSC offset/scaling，用于 guest 定时器计算。

#### `get_kvmclock_ns()` — 获取 kvmclock 纳秒时间
- **源码**: `arch/x86/kvm/x86.h:460`
- **语义**: 获取基于 kvmclock (pvclock) 的当前时间，用于 guest 时间同步。

### 2.5 定时器中断注入

#### `kvm_cpu_has_pending_timer()` — 检查是否有待处理的定时器中断
- **源码**: `arch/x86/kvm/irq.c:27`
- **语义**: 检查 LAPIC/PIT 是否有待注入 guest 的定时器中断。

#### `kvm_inject_pending_timer_irqs()` — 注入待处理的定时器中断
- **源码**: `arch/x86/kvm/irq.c:169`
- **语义**: 将所有待处理的定时器中断注入到 guest 中。

#### `__kvm_migrate_timers()` — 迁移定时器到当前 CPU
- **源码**: `arch/x86/kvm/irq.c:177`
- **语义**: 当 vCPU 被迁移到新的物理 CPU 时，将其定时器也迁移过去，避免不必要的 IPI。

### 2.6 时间获取接口

#### `ktime_get()` — 获取单调时间
- **语义**: KVM 广泛使用此函数获取当前时间戳，用于定时器计算、halt polling 等。

#### `rdtsc()` — 读取时间戳计数器
- **语义**: 直接读取 CPU 的 TSC 寄存器，用于高精度时间测量和 guest TSC 模拟。

---

## 3. 主机信息 (Host)

### 3.1 CPU 特性检测

#### `boot_cpu_data` — 引导 CPU 信息
- **源码**: `arch/x86/kernel/cpu/common.c`
- **KVM 使用**: `arch/x86/kvm/mmu/spte.c:50-64`, `arch/x86/kvm/cpuid.c:707`, `arch/x86/kvm/svm/svm.c`
- **语义**: 全局 `cpuinfo_x86` 结构体，包含 CPU 厂商、型号、物理地址位数、特性位图等信息。KVM 用它来检测宿主机 CPU 能力。

```c
// KVM 使用示例 (arch/x86/kvm/mmu/spte.c:50)
// 获取宿主机物理地址位数
if (likely(boot_cpu_data.extended_cpuid_level >= 0x80000008))
    // ...
return boot_cpu_data.x86_phys_bits;

// arch/x86/kvm/cpuid.c:707
const u32 *kernel_cpu_caps = boot_cpu_data.x86_capability;
```

#### `cpu_feature_enabled()` — 运行时 CPU 特性检测
- **源码**: `arch/x86/include/asm/cpufeature.h`
- **KVM 使用**: `arch/x86/kvm/svm/avic.c:1247`, `arch/x86/kvm/mmu/spte.c:295`
- **语义**: 使用 static key 优化的运行时特性检测。编译时 + 运行时双重检查，是检查 x86 特性的推荐方式。

```c
// arch/x86/kvm/svm/avic.c:1247
if (cpu_feature_enabled(X86_FEATURE_ZEN4) || boot_cpu_data.x86 >= 0x1A)
    // 启用 AVIC 特性
```

#### `kvm_cpu_cap_has()` / `kvm_cpu_cap_set()` / `kvm_cpu_cap_clear()` — KVM 特性掩码管理
- **源码**: `arch/x86/kvm/cpuid.c`
- **语义**: KVM 维护自己的 CPU 特性掩码，决定哪些特性暴露给 guest。这些函数用于查询/设置/清除该掩码。

### 3.2 CPU 数量和拓扑

#### `num_online_cpus` / `cpu_online_mask`
- **源码**: `include/linux/cpumask.h`
- **KVM 使用**: `virt/kvm/kvm_main.c:3838`
- **语义**: 获取在线 CPU 数量和掩码。KVM 用于判断 vCPU 应该在哪些物理 CPU 上运行。

#### `nr_cpu_ids`
- **语义**: 系统中可能的最高 CPU ID + 1。KVM 在 kick vCPU 时用于边界检查。

```c
// virt/kvm/kvm_main.c:3838
if (cpu != me && (unsigned int)cpu < nr_cpu_ids && cpu_online(cpu))
    smp_send_reschedule(cpu);
```

### 3.3 CPU 热插拔

#### `cpuhp_setup_state()` — 注册 CPU 热插拔回调
- **源码**: `kernel/cpu.c`, KVM 调用在 `virt/kvm/kvm_main.c:5696`
- **语义**: KVM 注册 `CPUHP_AP_KVM_ONLINE` 状态回调，当 CPU 上线/下线时启用/禁用虚拟化扩展。

```c
// virt/kvm/kvm_main.c:5696
r = cpuhp_setup_state(CPUHP_AP_KVM_ONLINE, "kvm/cpu:online",
                      kvm_online_cpu, kvm_offline_cpu);
```

#### `on_each_cpu()` — 在所有 CPU 上执行函数
- **KVM 使用**: `virt/kvm/kvm_main.c:5647` (`kvm_disable_virtualization_cpu`)
- **语义**: 关闭虚拟化时在所有 CPU 上禁用硬件虚拟化扩展。

### 3.4 内存拓扑

#### `kvm_host_page_size()` — 获取宿主机页面大小
- **源码**: `virt/kvm/kvm_main.c:2684`
- **语义**: 查询给定 GFN 对应的宿主机页面大小（可能支持 transparent huge pages）。

```c
// virt/kvm/kvm_main.c:2684
unsigned long kvm_host_page_size(struct kvm_vcpu *vcpu, gfn_t gfn)
{
    mmap_read_lock(current->mm);
    vma = find_vma(current->mm, addr);
    size = vma_kernel_pagesize(vma);
    mmap_read_unlock(current->mm);
    return size;
}
```

### 3.5 虚拟化能力检测

#### `kvm_x86_ops` — 架构相关操作函数表
- **源码**: `arch/x86/kvm/x86.c` (全局定义)
- **语义**: 一个包含所有 x86 厂商特定操作的函数指针表（VMX 或 SVM）。这是 KVM 与硬件虚拟化扩展交互的核心接口。

```c
// KVM x86 ops 包含的关键操作:
// - hardware_setup/hardware_unsetup: 硬件初始化
// - vcpu_load/vcpu_put: vCPU 加载/卸载
// - run: 进入 guest 模式
// - handle_exit: 处理 VM exit
// - set_hv_timer/cancel_hv_timer: 硬件定时器
// - flush_remote_tlbs: TLB 刷新
```

---

## 4. 虚拟机管理 (Virtual Machine Manage)

> KVM 将每个 vCPU 视为一个标准的 Linux 线程 (task_struct)，由 Linux CFS 调度器统一调度。

### 4.1 vCPU 线程生命周期

#### `kvm_vcpu_init()` — 初始化 vCPU 结构
- **源码**: `virt/kvm/kvm_main.c:1221`
- **语义**: 初始化 vCPU 结构体，设置 mutex、wait queue、preempt notifier 等。

```c
// virt/kvm/kvm_main.c:1221
static void kvm_vcpu_init(struct kvm_vcpu *vcpu, struct kvm *kvm, unsigned id)
{
    mutex_init(&vcpu->mutex);
    vcpu->cpu = -1;
    vcpu->kvm = kvm;
    vcpu->vcpu_id = id;
    vcpu->pid = NULL;
    preempt_notifier_init(&vcpu->preempt_notifier, &kvm_preempt_ops);
}
```

#### `kvm_vcpu_destroy()` — 销毁 vCPU
- **源码**: `virt/kvm/kvm_main.c:1247`
- **语义**: 释放 vCPU 资源，调用架构相关的销毁函数，释放 `pid` 引用、`run` 页面等。

### 4.2 抢占通知 (Preemption Notification)

#### `preempt_notifier` — 抢占通知器
- **源码**: `include/linux/preempt.h`, KVM 使用在 `include/linux/kvm_host.h` (vcpu 结构体成员)
- **语义**: KVM 注册抢占通知器，当 vCPU 线程被调度器换入/换出时收到回调。这是 KVM 调度机制的核心。

```c
// include/linux/kvm_host.h (kvm_vcpu 结构体中)
#ifdef CONFIG_PREEMPT_NOTIFIERS
    struct preempt_notifier preempt_notifier;
#endif
```

#### `vcpu_load()` / `vcpu_put()` — 加载/卸载 vCPU 上下文
- **源码**: `virt/kvm/kvm_main.c:164` / `virt/kvm/kvm_main.c:175`
- **语义**: 在操作 vCPU 前加载其上下文（注册抢占通知器、调用架构 vcpu_load），操作完成后卸载。

```c
// virt/kvm/kvm_main.c:164
void vcpu_load(struct kvm_vcpu *vcpu)
{
    int cpu = get_cpu();
    __this_cpu_write(kvm_running_vcpu, vcpu);
    preempt_notifier_register(&vcpu->preempt_notifier);  // 注册抢占通知
    kvm_arch_vcpu_load(vcpu, cpu);                         // 架构相关加载
    put_cpu();
}

void vcpu_put(struct kvm_vcpu *vcpu)
{
    preempt_disable();
    kvm_arch_vcpu_put(vcpu);                                 // 架构相关卸载
    preempt_notifier_unregister(&vcpu->preempt_notifier);   // 注销抢占通知
    __this_cpu_write(kvm_running_vcpu, NULL);
    preempt_enable();
}
```

### 4.3 vCPU 唤醒与踢出 (Kick/Wake)

#### `kvm_vcpu_wake_up()` — 唤醒休眠的 vCPU
- **源码**: `virt/kvm/kvm_main.c:3793`
- **语义**: 通过 `rcuwait_wake_up()` 唤醒处于 halt 状态的 vCPU 线程。

#### `__kvm_vcpu_kick()` — 踢出运行中的 vCPU
- **源码**: `virt/kvm/kvm_main.c:3809`
- **语义**: 强制 vCPU 退出 guest 模式。如果 vCPU 正在运行，发送 IPI 或 RESCHEDULE IPI。

```c
// virt/kvm/kvm_main.c:3809
void __kvm_vcpu_kick(struct kvm_vcpu *vcpu, bool wait)
{
    if (kvm_vcpu_wake_up(vcpu)) return;  // 先尝试唤醒
    me = get_cpu();
    if (vcpu == __this_cpu_read(kvm_running_vcpu)) {
        if (vcpu->mode == IN_GUEST_MODE)
            WRITE_ONCE(vcpu->mode, EXITING_GUEST_MODE);
        goto out;
    }
    if (kvm_arch_vcpu_should_kick(vcpu)) {
        cpu = READ_ONCE(vcpu->cpu);
        if (cpu != me && cpu_online(cpu)) {
            if (wait)
                smp_call_function_single(cpu, ack_kick, NULL, wait);
            else
                smp_send_reschedule(cpu);  // 发送 RESCHEDULE IPI
        }
    }
    put_cpu();
}
```

### 4.4 vCPU Halt/Wait

#### `kvm_vcpu_halt()` — vCPU 进入 halt 状态
- **源码**: `virt/kvm/kvm_main.c` (通过 `kvm_vcpu_block()` 调用)
- **语义**: 当 guest 执行 HLT 指令时，vCPU 线程进入 halt polling 然后睡眠。包含自适应的 halt polling 机制。

#### Halt Polling 自适应机制
- **源码**: `virt/kvm/kvm_main.c:3750` 附近
- **语义**: vCPU halt 时先短时间 polling（忙等），如果很快被唤醒则减少上下文切换开销；polling 超时后真正睡眠。

### 4.5 vCPU Yield (让出 CPU)

#### `kvm_vcpu_yield_to()` — 让出 CPU 给目标 vCPU
- **源码**: `virt/kvm/kvm_main.c:3858`
- **语义**: 当一个 vCPU 在 spin loop 中等待锁时，主动让出 CPU 给持有锁的 vCPU。使用 Linux 的 `yield_to()` 实现。

```c
// virt/kvm/kvm_main.c:3858
int kvm_vcpu_yield_to(struct kvm_vcpu *target)
{
    struct task_struct *task = NULL;
    if (target->pid)
        task = get_pid_task(target->pid, PIDTYPE_PID);
    if (!task) return 0;
    ret = yield_to(task, 1);  // 调用 Linux 调度器 yield_to
    put_task_struct(task);
    return ret;
}
```

#### `kvm_vcpu_on_spin()` — PLE (Pause Loop Exit) 处理
- **源码**: `virt/kvm/kvm_main.c:4033`
- **语义**: 当检测到 guest 在 spin loop 中（通过 PAUSE 指令拦截或 PLE），在 overcommit 场景下进行 directed yield。

### 4.6 vCPU 请求机制

#### `kvm_make_all_cpus_request()` — 向所有 vCPU 发送请求
- **源码**: `virt/kvm/kvm_main.c:273`
- **语义**: 向 VM 的所有 vCPU 发送请求（如 TLB flush、VM shutdown 等），必要时发送 IPI。

```c
// virt/kvm/kvm_main.c:273
bool kvm_make_all_cpus_request(struct kvm *kvm, unsigned int req)
{
    kvm_for_each_vcpu(i, vcpu, kvm)
        kvm_make_vcpu_request(vcpu, req, cpus, me);
    called = kvm_kick_many_cpus(cpus, !!(req & KVM_REQUEST_WAIT));
    return called;
}
```

### 4.7 进程关联接口

#### `get_pid_task()` / `put_task_struct()` — 通过 PID 获取 task_struct
- **语义**: KVM 通过 vCPU 的 `pid` 成员获取对应的 Linux task_struct，用于调度操作。

#### `yield_to()` — 让出 CPU 给指定任务
- **源码**: `kernel/sched/core.c`
- **语义**: Linux CFS 调度器提供的 directed yield 机制，KVM 用于 spin lock 优化。

### 4.8 锁与同步

#### `kvm->lock` / `kvm->slots_lock` / `kvm->irq_lock` — KVM 三级锁层次
- **语义**: KVM 定义的锁层次：`kvm->lock` -> `kvm->slots_lock` -> `kvm->irq_lock`。保护 VM 级别的状态变更。

#### `spinlock_t` / `struct mutex` / `struct srcu_struct`
- **语义**: KVM 广泛使用 Linux 的各种锁原语：
  - `spinlock` (mmu_lock): 保护 shadow page table / EPT
  - `mutex` (slots_lock): 保护 memslot 变更
  - `SRCU` (kvm->srcu): 保护 memslot 读取

### 4.9 Workqueue 与异步操作

#### `schedule_work()` / `queue_work()` — 延迟工作队列
- **语义**: KVM 使用 workqueue 处理不需要在 vCPU 线程上下文中执行的工作（如 async page fault）。

### 4.10 Guest 上下文进入/退出

#### `guest_state_enter_irqoff()` / `guest_state_exit_irqoff()`
- **源码**: `include/linux/kvm_host.h`
- **语义**: 进入/退出 guest 模式时的上下文管理。处理 RCU、lockdep、中断追踪等内核状态。

```c
// include/linux/kvm_host.h
static __always_inline void guest_state_enter_irqoff(void)
{
    instrumentation_begin();
    trace_hardirqs_on_prepare();
    lockdep_hardirqs_on_prepare();
    instrumentation_end();
    guest_context_enter_irqoff();  // RCU quiescent state
    lockdep_hardirqs_on(CALLER_ADDR0);
}
```

---

## 5. 架构相关 (Arch)

> 以 x86_64 为主，涵盖 VMX (Intel) 和 SVM (AMD) 两种实现。

### 5.1 硬件虚拟化启用/禁用

#### `kvm_enable_virtualization()` / `kvm_disable_virtualization()`
- **源码**: `virt/kvm/kvm_main.c:5685`
- **语义**: 在所有 CPU 上启用/禁用硬件虚拟化扩展（VMX/SVM）。通过 `cpuhp_setup_state()` 和 `on_each_cpu()` 实现。

```c
// virt/kvm/kvm_main.c:5685
static int kvm_enable_virtualization(void)
{
    guard(mutex)(&kvm_usage_lock);
    if (kvm_usage_count++) return 0;
    kvm_arch_enable_virtualization();
    r = cpuhp_setup_state(CPUHP_AP_KVM_ONLINE, "kvm/cpu:online",
                          kvm_online_cpu, kvm_offline_cpu);
    register_syscore(&kvm_syscore);
    // ...
}
```

### 5.2 VMX/SVM 操作

#### Intel VMX
- **源码目录**: `arch/x86/kvm/vmx/`
- **核心文件**: `vmx.c`, `vmcs12.c`, `nested.c`, `posted_intr.c`, `tdx.c`
- **关键操作**:
  - `vmx_vcpu_load()` / `vmx_vcpu_put()` — 加载/卸载 VMCS
  - `vmx_run()` — 通过 VMLAUNCH/VMRESUME 进入 guest
  - `vmx_handle_exit()` — 处理 VM exit 事件

#### AMD SVM
- **源码目录**: `arch/x86/kvm/svm/`
- **核心文件**: `svm.c`, `nested.c`, `avic.c`, `sev.c`
- **关键操作**:
  - `svm_vcpu_load()` / `svm_vcpu_put()` — 加载/卸载 VMCB
  - `svm_vcpu_run()` — 通过 VMRUN 进入 guest
  - `svm_handle_exit()` — 处理 #VMEXIT 事件

### 5.3 MSR (Model Specific Register) 模拟

#### `kvm_get_msr()` / `kvm_set_msr()` — 读写 guest MSR
- **源码**: `arch/x86/kvm/x86.c`
- **语义**: 拦截 guest 的 RDMSR/WRMSR 指令，返回模拟值或存储模拟状态。不同 MSR 有不同的处理策略（透传、模拟、拒绝）。

#### `kvm_is_supported_user_return_msr()` — 检查 MSR 是否支持
- **源码**: `arch/x86/kvm/x86.c`
- **语义**: 检查给定 MSR 是否可以通过 KVM 的 user return MSR 机制安全切换。

### 5.4 CPUID 模拟

#### `kvm_emulate_cpuid()` — 模拟 CPUID 指令
- **源码**: `arch/x86/kvm/cpuid.c`
- **语义**: 当 guest 执行 CPUID 指令时，根据 KVM 的特性掩码返回过滤后的 CPUID 信息。决定 guest 看到哪些 CPU 特性。

```c
// arch/x86/kvm/cpuid.c — CPUID 特性过滤机制
// KVM 维护自己的 CPU capability mask:
// kvm_cpu_cap_init() — 初始化，从 boot_cpu_data 复制
// kvm_cpu_cap_set() — 允许暴露给 guest
// kvm_cpu_cap_clear() — 不允许暴露给 guest
// kvm_cpu_cap_has() — 检查是否允许
```

### 5.5 中断注入

#### `kvm_queue_interrupt()` — 排队中断
- **源码**: `arch/x86/kvm/x86.c`
- **语义**: 将中断排队等待注入 guest。在下一次 guest entry 时检查并注入。

#### `kvm_inject_page_fault()` — 注入页错误
- **源码**: `arch/x86/kvm/x86.c:973`
- **语义**: 当 guest 发生 page fault 需要注入到 guest 时调用。

#### `kvm_inject_nmi()` — 注入 NMI
- **源码**: `arch/x86/kvm/x86.c:1012`
- **语义**: 向 guest 注入不可屏蔽中断。

#### `kvm_queue_exception()` / `kvm_inject_emulated_page_fault()`
- **源码**: `arch/x86/kvm/x86.c:902` / `arch/x86/kvm/x86.c:990`
- **语义**: 向 guest 排队/注入异常。

### 5.6 EPT (Extended Page Table) / NPT (Nested Page Table) 管理

#### `kvm_init_shadow_ept_mmu()` — 初始化 EPT shadow MMU
- **源码**: `arch/x86/kvm/mmu/mmu.c:5945`
- **语义**: 为 Intel EPT 初始化 shadow MMU 结构，设置 EPT 的权限位掩码。

#### `kvm_init_shadow_npt_mmu()` — 初始化 NPT shadow MMU
- **源码**: `arch/x86/kvm/mmu/mmu.c:5894`
- **语义**: 为 AMD NPT 初始化 shadow MMU 结构。

#### `kvm_mmu_set_ept_masks()` — 设置 EPT SPTE 掩码
- **源码**: `arch/x86/kvm/mmu/spte.c:492`
- **语义**: 根据硬件 EPT 能力（如 A/D bits、execute-only）设置 SPTE 的位掩码。

### 5.7 APIC (Advanced Programmable Interrupt Controller) 模拟

#### `kvm_apic_has_interrupt()` — 检查 APIC 是否有待处理中断
- **源码**: `arch/x86/kvm/lapic.c`
- **语义**: 检查 local APIC 的 IRR (Interrupt Request Register) 是否有 pending 中断。

#### APIC 寄存器模拟
- **源码**: `arch/x86/kvm/lapic.c`
- **语义**: 模拟 local APIC 的全部寄存器，包括 ICR、IRR、ISR、LVT 等。

### 5.8 Hypercall 处理

#### `kvm_emulate_hypercall()` — 模拟 hypercall
- **源码**: `arch/x86/kvm/x86.c`
- **语义**: 当 guest 执行 VMCALL (Intel) 或 VMMCALL (AMD) 时，KVM 拦截并处理 hypercall。支持 KVM hypercall、Hyper-V hypercall 等。

### 5.9 PIO (Port I/O) 和 MMIO 模拟

#### `kvm_io_bus_write()` / `kvm_io_bus_read()`
- **源码**: `virt/kvm/kvm_main.c:5898` / `virt/kvm/kvm_main.c:5967`
- **语义**: 当 guest 执行 PIO 或 MMIO 访问时，KVM 在注册的 IO bus 设备上分发读写请求。

### 5.10 Nested Virtualization (嵌套虚拟化)

#### `struct kvm_x86_ops.nested_ops`
- **源码**: `arch/x86/kvm/vmx/nested.c`, `arch/x86/kvm/svm/nested.c`
- **语义**: 嵌套虚拟化操作函数表，支持在 guest 中运行另一个 hypervisor。

### 5.11 PMU (Performance Monitoring Unit) 模拟

#### `kvm_pmu_is_valid_msr()` / `kvm_pmu_get_msr()` / `kvm_pmu_set_msr()`
- **源码**: `arch/x86/kvm/pmu.c`
- **语义**: 模拟 PMU 的 MSR，允许 guest 使用性能计数器。

---

## 总结：KVM-Linux 接口层次

```
+----------------------------------------------------------+
|                    Guest (用户态)                          |
+----------------------------------------------------------+
                    | KVM API (ioctl)
                    v
+----------------------------------------------------------+
|              KVM Module (内核模块)                         |
|                                                           |
|  +-- virt/kvm/kvm_main.c (架构无关核心)                   |
|  |     - VM/vCPU 生命周期管理                              |
|  |     - 内存 slot 管理                                    |
|  |     - GFN<->HVA<->PFN 转换                             |
|  |     - 脏页追踪                                         |
|  |     - vCPU 调度 (halt/kick/yield)                      |
|  |     - MMU Notifier 注册                                 |
|                                                           |
|  +-- arch/x86/kvm/ (x86 架构相关)                         |
|  |     +-- x86.c (公共 x86 代码)                           |
|  |     +-- vmx/ (Intel VMX 实现)                           |
|  |     +-- svm/ (AMD SVM 实现)                             |
|  |     +-- mmu/ (EPT/NPT/shadow page table)               |
|  |     +-- lapic.c (APIC 定时器模拟)                       |
|  |     +-- cpuid.c (CPUID 过滤)                            |
|  |     +-- i8254.c (PIT 定时器模拟)                        |
+----------------------------------------------------------+
          |              |              |              |
          v              v              v              v
   +-----------+  +-----------+  +-----------+  +-----------+
   | 内存管理   |  | 进程调度   |  | 时钟系统   |  | 硬件虚拟化 |
   | mm/       |  | kernel/   |  | hrtimer   |  | VMX/SVM   |
   | GUP       |  | sched/    |  | TSC       |  | CPU 特性   |
   | mmap      |  | preempt   |  | kvmclock  |  | MSR/CPUID |
   | MMU notif |  | signal    |  | PIT/RTC   |  | EPT/NPT   |
   +-----------+  +-----------+  +-----------+  +-----------+
```

---

## 源码参考位置

| 类别 | 关键文件 |
|------|----------|
| **通用核心** | `virt/kvm/kvm_main.c`, `include/linux/kvm_host.h` |
| **内存管理** | `virt/kvm/pfncache.c`, `virt/kvm/guest_memfd.c`, `arch/x86/kvm/mmu/` |
| **时钟** | `arch/x86/kvm/lapic.c`, `arch/x86/kvm/i8254.c` |
| **主机信息** | `arch/x86/kvm/cpuid.c`, `arch/x86/kvm/mmu/spte.c` |
| **VM 管理** | `virt/kvm/kvm_main.c` (vcpu_load/put, kick, yield, halt) |
| **VMX** | `arch/x86/kvm/vmx/vmx.c`, `arch/x86/kvm/vmx/nested.c` |
| **SVM** | `arch/x86/kvm/svm/svm.c`, `arch/x86/kvm/svm/nested.c` |
| **中断** | `arch/x86/kvm/irq.c`, `arch/x86/kvm/lapic.c`, `arch/x86/kvm/ioapic.c` |
| **IO** | `arch/x86/kvm/x86.c` (MMIO/PIO), `virt/kvm/coalesced_mmio.c` |
