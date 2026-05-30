# KVM 与 Linux 内核接口函数分类分析

> 本文档统计 KVM (Kernel-based Virtual Machine) 作为 Type-2 Hypervisor 与底层 Linux 内核之间的关键接口函数。
> 源码基于 Linux 6.x (torvalds/linux master 分支)。
> 源码位置: `code/linux-kvm-reference/` 子目录。
> 
> **分类框架**: 7 维度统一框架 + 横切标签
> **接口粒度**: 三级分层（L1 外部 API / L2 内部支撑 / L3 数据结构）
> **条目模板**: 9 字段（签名、位置、语义、示例、OS 子系统、调用上下文/provider-consumer、hot path、边界类型、接口契约）

---

## 目录

1. [维度 1: 内存管理](#dim1-memory)
2. [维度 2: vCPU 管理](#dim2-vcpu)
3. [维度 3: I/O 模型](#dim3-io)
4. [维度 4: 中断与事件](#dim4-interrupt)
5. [维度 5: 时钟与定时器](#dim5-clock)
6. [维度 6: 调度与同步](#dim6-sched)
7. [维度 7: 安全与隔离](#dim7-security)
8. [附录: 旧 5 分类映射表](#appendix-mapping)

---

## 1. 维度 1: 内存管理 {#dim1-memory}

> **覆盖内容**: 地址空间、GPA→HPA 映射、页面锁定  
> **横切标签**: host 资源（文件/镜像加载）、PCI/IOMMU/DMA（EPT/NPT 地址翻译）

### 1.1 Guest 内存区域管理

#### `kvm_set_memory_region()` [L1]
- **源码**: `virt/kvm/kvm_main.c:1994`
- **语义**: 设置/创建/删除/移动 guest 的内存区域 (memslot)。将用户空间内存映射到 guest 物理地址空间。
- **调用上下文**: 用户态 VMM 通过 `KVM_SET_USER_MEMORY_REGION` ioctl 触发
- **边界类型**: `kernel KPI`（内部）
- **接口契约**: 输入 `kvm_userspace_memory_region2`；返回值 0 成功 / 负 errno；持有 `kvm->slots_lock`
- **hot path**: 否（配置路径）

```c
// virt/kvm/kvm_main.c:1994
static int kvm_set_memory_region(struct kvm *kvm,
                 const struct kvm_userspace_memory_region2 *mem)
{
    struct kvm_memory_slot *old, *new;
    enum kvm_mr_change change;
    unsigned long npages;
    gfn_t base_gfn;
    int as_id, id;

    lockdep_assert_held(&kvm->slots_lock);
    r = check_memory_region_flags(kvm, mem);
    if (r) return r;
    as_id = mem->slot >> 16;
    id = (u16)mem->slot;
    base_gfn = (mem->guest_phys_addr >> PAGE_SHIFT);
    npages = (mem->memory_size >> PAGE_SHIFT);
    r = kvm_set_memslot(kvm, old, new, change);
    return r;
}
```

#### `gfn_to_memslot()` / `kvm_vcpu_gfn_to_memslot()` [L2]
- **源码**: `virt/kvm/kvm_main.c:2628` / `virt/kvm/kvm_main.c:2634`
- **语义**: 根据 GFN (Guest Frame Number) 查找对应的 memory slot。vCPU 版本带有 per-vCPU 缓存优化。
- **调用上下文**: 被 `hva_to_pfn()`、`__kvm_faultin_pfn()` 等调用
- **边界类型**: `kernel KPI`
- **接口契约**: 输入 gfn，返回 `kvm_memory_slot*` 或 NULL
- **hot path**: 是（每次 guest page fault 都会调用）

```c
struct kvm_memory_slot *gfn_to_memslot(struct kvm *kvm, gfn_t gfn)
{
    return __gfn_to_memslot(kvm_memslots(kvm), gfn);
}
```

#### `kvm_is_visible_gfn()` [L2]
- **源码**: `virt/kvm/kvm_main.c:2668`
- **语义**: 检查给定 GFN 是否属于用户可见的 memslot（非内部 slot）。用于区分普通 guest 内存和内部 memslot（如 APIC access page）。
- **调用上下文**: consumer — 被 MMU page fault handler 和 dirty logging 路径调用
- **边界类型**: `kernel KPI`
- **接口契约**: 输入 kvm + gfn；返回 bool；内部遍历所有 memslot 比较 GFN 范围
- **hot path**: 否

### 1.2 GFN → HVA/PFN 转换

#### `kvm_memslots()` / `__gfn_to_memslot()` [L2]
- **源码**: `virt/kvm/kvm_main.c`
- **语义**: `kvm_memslots()` 获取指定地址空间的 memslot 数组（RCU 保护），`__gfn_to_memslot()` 在其中二分搜索 GFN 对应的 slot。
- **调用上下文**: provider — 为 `gfn_to_memslot()` 提供底层 memslot 索引；被所有 GFN 转换路径调用
- **边界类型**: `kernel KPI`
- **接口契约**: `kvm_memslots()` 返回 `struct kvm_memslots*`；调用者必须在 RCU read-side critical section 内
- **hot path**: 是

#### `kvm_set_memslot()` [L2]
- **源码**: `virt/kvm/kvm_main.c`
- **语义**: 原子性地安装新 memslot（或更新/删除），处理新旧 slot 的切换。
- **调用上下文**: consumer — 由 `kvm_set_memory_region()` 调用
- **边界类型**: `kernel KPI`
- **接口契约**: 持有 `kvm->slots_lock`；通过 RCU 机制更新；安装后调用 `kvm_arch_commit_memory_region()` 和 `kvm_flush_remote_tlbs()`
- **hot path**: 否（配置路径）

#### `check_memory_region_flags()` [L2]
- **源码**: `virt/kvm/kvm_main.c`
- **语义**: 验证 `kvm_userspace_memory_region2` 参数合法性（标志位检查、对齐检查、重叠检测）。
- **调用上下文**: consumer — 由 `kvm_set_memory_region()` 入口调用
- **边界类型**: `kernel KPI`
- **接口契约**: 输入 kvm + mem；返回 0 成功 / 负 errno（-EINVAL 参数无效）；持有 `kvm->slots_lock`
- **hot path**: 否

#### `gfn_to_hva_memslot()` / `gfn_to_hva()` / `kvm_vcpu_gfn_to_hva()` [L1]
- **源码**: `virt/kvm/kvm_main.c:2734-2751`
- **语义**: 将 Guest 物理页帧号 (GFN) 转换为 Host 虚拟地址 (HVA)。这是 KVM 内存管理链路的核心一步。
- **边界类型**: `kernel KPI`
- **接口契约**: 输入 GFN，输出 HVA（unsigned long）；基于 memslot 的 `userspace_addr` 计算偏移
- **hot path**: 是

```c
unsigned long gfn_to_hva_memslot(struct kvm_memory_slot *slot, gfn_t gfn)
{
    return gfn_to_hva_many(slot, gfn, NULL);
}
```

#### `kvm_follow_pfn()` [L2] — GFN→PFN 的统一入口
- **源码**: `virt/kvm/kvm_main.c`
- **语义**: 封装 `hva_to_pfn()`，将 `kvm_follow_pfn` 结构体转换为 kvm_pfn_t。合并快速/慢速/remapped 三条路径。
- **调用上下文**: consumer — 由 `__kvm_faultin_pfn()` 和 `__kvm_vcpu_map()` 调用
- **边界类型**: `kernel KPI`
- **接口契约**: 输入 `kvm_follow_pfn*`；返回 kvm_pfn_t 或错误；可能睡眠
- **hot path**: 是（guest page fault 路径）

#### `hva_to_pfn_fast()` [L2] — 快速 GUP 路径
- **源码**: `virt/kvm/kvm_main.c:2851`
- **语义**: 尝试通过 `pin_user_pages_fast()` 或 `get_user_page_fast_only()` 快速获取 PFN，不阻塞。
- **调用上下文**: consumer — 由 `hva_to_pfn()` 首先调用；失败后回退到 `hva_to_pfn_slow()`
- **边界类型**: `kernel KPI`
- **接口契约**: 返回 true 表示成功（pfn 已填充），false 表示需要走慢速路径；不持有 mmap_lock
- **hot path**: 是

#### `hva_to_pfn_slow()` [L2] — 慢速 GUP 路径
- **源码**: `virt/kvm/kvm_main.c`
- **语义**: 通过 `pin_user_pages_unlocked()` 完成完整 GUP 流程，支持 NUMA hinting fault 和页面 swap-in。
- **调用上下文**: consumer — 由 `hva_to_pfn()` 在快速路径失败后调用
- **边界类型**: `kernel KPI`
- **接口契约**: 输入 kfp；返回锁定的页数（1 成功）；内部获取/释放 mmap_read_lock；可能阻塞 I/O
- **hot path**: 否（fallback，仅在快速路径失败时触发）

#### `hva_to_pfn()` — HVA 到物理页帧号转换 [L1]
- **源码**: `virt/kvm/kvm_main.c:2985`
- **语义**: 将宿主机虚拟地址转换为物理页帧号 (PFN)。KVM 使用 GUP (Get User Pages) 子系统的核心入口。
- **调用上下文**: 在 `kvm_follow_pfn()` 中被调用；由 `__kvm_faultin_pfn()` 和 `__kvm_vcpu_map()` 间接触发
- **调用链**: `hva_to_pfn_fast()` → `hva_to_pfn_slow()` → `hva_to_pfn_remapped()`
- **边界类型**: `kernel KPI`
- **接口契约**: 输入 `kvm_follow_pfn*`（含 hva、flags、refcounted_page）；返回 kvm_pfn_t；可能睡眠（`might_sleep`）
- **hot path**: 是（guest page fault 路径上）

```c
kvm_pfn_t hva_to_pfn(struct kvm_follow_pfn *kfp)
{
    struct vm_area_struct *vma;
    kvm_pfn_t pfn;
    int npages, r;
    might_sleep();
    if (hva_to_pfn_fast(kfp, &pfn))  // 快速路径: pin_user_pages_fast
        return pfn;
    npages = hva_to_pfn_slow(kfp, &pfn);  // 慢速路径: GUP
    if (npages == 1) return pfn;
    mmap_read_lock(current->mm);
    vma = vma_lookup(current->mm, kfp->hva);
    // ...
}
```

### 1.3 页面锁定 (Pin/Lock)

#### `pin_user_pages_fast()` [L1] — 快速锁定用户页面
- **源码**: `mm/gup.c`, KVM 调用在 `virt/kvm/kvm_main.c:2867`
- **语义**: 高效地将用户空间页面锁定在内存中，防止被 swap out。
- **边界类型**: `kernel KPI`（Linux mm 子系统）
- **接口契约**: 输入 hva、nr_pages、flags、pages 数组；返回锁定页数；调用者持有 mmap_read_lock
- **hot path**: 是

#### `pin_user_pages_unlocked()` [L1] — 慢速路径锁定
- **源码**: `mm/gup.c`, KVM 调用在 `virt/kvm/kvm_main.c:2901`
- **语义**: 当快速路径失败时，通过完整的 GUP 路径锁定页面，支持 NUMA hinting fault。内部获取/释放 mmap_read_lock。
- **调用上下文**: consumer — 由 `hva_to_pfn_slow()` 在快速路径失败时调用
- **边界类型**: `kernel KPI`（Linux mm 子系统）
- **接口契约**: 输入 mm、start、nr_pages、gup_flags、pages；返回锁定页数或负 errno；获取 mmap_read_lock
- **hot path**: 否（fallback；仅在快速路径失败时触发）

#### `unpin_user_page()` [L1] — 解锁页面
- **源码**: `mm/gup.c`, KVM 调用在 `virt/kvm/kvm_main.c:3163`
- **语义**: 释放之前通过 `pin_user_pages_*` 锁定的页面，减少引用计数。
- **调用上下文**: consumer — 由 `kvm_vcpu_unmap()` 和 KVM MMU 页面释放路径调用
- **边界类型**: `kernel KPI`（Linux mm 子系统）
- **接口契约**: 输入 struct page*；减少 page refcount；当 refcount=0 时可能触发页面回收
- **hot path**: 否

### 1.4 Guest 页面映射

#### `__kvm_faultin_pfn()` [L1] — Guest 页错误时获取 PFN
- **源码**: `virt/kvm/kvm_main.c:3049`
- **语义**: 当 guest 发生 page fault 时，KVM 调用此函数将 GFN 解析为 PFN。是 guest page fault 处理的核心入口。
- **调用上下文**: consumer — 由架构相关的 EPT/NPT page fault handler 调用（如 `kvm_mmu_do_page_fault()`）；内部调用 `kvm_follow_pfn()`
- **边界类型**: `kernel KPI`
- **接口契约**: 输入 slot + gfn + foll flags；输出 pfn + writable 标志 + refcounted_page；返回 kvm_pfn_t（PAGE 或错误码）
- **hot path**: 是

#### `__gfn_to_page()` [L2] — GFN 转为 struct page
- **源码**: `virt/kvm/kvm_main.c:3095`
- **语义**: 获取 guest 页面对应的 `struct page`，增加引用计数。
- **边界类型**: `kernel KPI`
- **hot path**: 是

#### `__kvm_vcpu_map()` / `kvm_vcpu_unmap()` [L1] — 映射/解除映射 guest 页面到内核地址空间
- **源码**: `virt/kvm/kvm_main.c:3110` / `virt/kvm/kvm_main.c:3144`
- **语义**: 临时将 guest 物理页映射到内核地址空间（通过 `kmap()` / `memremap()`），用于直接读写 guest 内存。
- **边界类型**: `kernel KPI`
- **接口契约**: `__kvm_vcpu_map` 返回 0 成功 / -EFAULT 失败；pin 操作；调用者负责 `kvm_vcpu_unmap`
- **hot path**: 否（仅在需要直接读写 guest 内存时使用）

### 1.5 Guest 内存读写

#### `kvm_read_guest()` / `kvm_write_guest()` [L1]
- **源码**: `virt/kvm/kvm_main.c:3235` / `virt/kvm/kvm_main.c:3346`
- **语义**: 从 guest 物理内存读取/写入数据。内部通过 `gfn_to_hva()` + `__copy_{from,to}_user()` 实现。
- **边界类型**: `kernel KPI`
- **hot path**: 否（在特定 I/O 模拟路径上）

### 1.6 脏页追踪 (Dirty Page Tracking) [横切: host 资源]

#### `__kvm_read_guest_page()` / `__kvm_write_guest_page()` [L2]
- **源码**: `virt/kvm/kvm_main.c`
- **语义**: 单页粒度的 guest 内存读写。通过 `gfn_to_hva()` + `__copy_from_user()`/`__copy_to_user()` 逐页操作。`kvm_read_guest()` 和 `kvm_write_guest()` 的多页包装。
- **调用上下文**: consumer — 被 `kvm_read_guest()` / `kvm_write_guest()` 和架构相关代码调用
- **边界类型**: `kernel KPI`
- **接口契约**: 输入 kvm + gfn + 偏移 + buf + len；处理跨页边界；返回已拷贝字节数或负 errno
- **hot path**: 否

#### `kvm_get_dirty_log()` [L1]
- **源码**: `virt/kvm/kvm_main.c:2197`
- **语义**: 获取指定 memslot 的脏页位图，用于 live migration。
- **边界类型**: `kernel KPI`
- **hot path**: 否（migration 路径）

#### `mark_page_dirty_in_slot()` / `mark_page_dirty()` [L2]
- **源码**: `virt/kvm/kvm_main.c:3536` / `virt/kvm/kvm_main.c:3545`
- **语义**: 标记 guest 页面为脏页。dirty bitmap 或 dirty ring。
- **边界类型**: `kernel KPI`
- **hot path**: 否

### 1.7 MMU Notifier（反向映射同步）[横切: PCI/IOMMU/DMA]

#### `kvm_mmu_notifier_ops` 结构体 [L3]
- **源码**: `virt/kvm/kvm_main.c:878`
- **语义**: 注册到 Linux mm 子系统的通知回调。宿主进程地址空间变更时 KVM 同步清理 shadow page table / EPT。
- **边界类型**: `kernel KPI`
- **接口契约**: 6 个回调函数；由 Linux mm 子系统在内存回收/munmap/COW 时调用

#### `mmu_notifier_register()` [L1]
- **源码**: `mm/mmu_notifier.c`, KVM 调用在 `virt/kvm/kvm_main.c:889`
- **语义**: 将 KVM 的 mmu_notifier 注册到当前进程的 `mm_struct`。
- **边界类型**: `kernel KPI`（Linux mm 子系统）
- **hot path**: 否（初始化路径）

### 1.8 TLB 刷新

#### `kvm_arch_commit_memory_region()` [L2] — 架构相关 memslot 安装
- **源码**: `arch/x86/kvm/x86.c`
- **语义**: memslot 变更后通知架构相关代码。x86 上处理 MTRR 更新和 KVM zap 旧的 MMU 映射。
- **调用上下文**: consumer — 由 `kvm_set_memslot()` 在 slot 安装完成后调用
- **边界类型**: `kernel KPI`
- **接口契约**: 输入 kvm + old + new + change type；返回 void（错误已在更早阶段处理）；可能触发 shadow MMU 重建
- **hot path**: 否

#### `kvm_flush_remote_tlbs()` [L1]
- **源码**: `virt/kvm/kvm_main.c:296`
- **语义**: 请求所有 vCPU 刷新 TLB。通过 `kvm_make_all_cpus_request(KVM_REQ_TLB_FLUSH)` 发送 IPI。
- **边界类型**: `kernel KPI`
- **接口契约**: 通过 IPI 向所有运行中的 vCPU 发送 TLB flush 请求；异步
- **hot path**: 否（内存布局变更后调用）

### 1.9 EPT/NPT 管理 [横切: PCI/IOMMU/DMA]

#### `kvm_init_shadow_ept_mmu()` / `kvm_init_shadow_npt_mmu()` [L2]
- **源码**: `arch/x86/kvm/mmu/mmu.c:5945` / `arch/x86/kvm/mmu/mmu.c:5894`
- **语义**: 为 Intel EPT / AMD NPT 初始化 shadow MMU 结构，设置权限位掩码。
- **边界类型**: `kernel KPI`
- **hot path**: 否（初始化）

#### `kvm_mmu_set_ept_masks()` [L2]
- **源码**: `arch/x86/kvm/mmu/spte.c:492`
- **语义**: 根据硬件 EPT 能力（A/D bits、execute-only）设置 SPTE 位掩码。
- **边界类型**: `kernel KPI`
- **hot path**: 否

#### `kvm_host_page_size()` [L2]
- **源码**: `virt/kvm/kvm_main.c:2684`
- **语义**: 查询给定 GFN 对应的宿主机页面大小（可能支持 transparent huge pages）。
- **边界类型**: `kernel KPI`
- **hot path**: 否

---

## 2. 维度 2: vCPU 管理 {#dim2-vcpu}

> **覆盖内容**: 创建/销毁、运行/暂停、寄存器访问、硬件能力发现  
> **子维度**: vCPU 生命周期、vCPU 能力发现  
> **横切标签**: 控制面生命周期

### 2.1 vCPU 生命周期 [子维度: vCPU 生命周期]

#### `kvm_vcpu_init()` [L1]
- **源码**: `virt/kvm/kvm_main.c:1221`
- **语义**: 初始化 vCPU 结构体，设置 mutex、wait queue、preempt notifier 等。
- **边界类型**: `kernel KPI`
- **接口契约**: 输入 kvm、vcpu_id；初始化后 vcpu->cpu = -1
- **hot path**: 否

#### `kvm_vcpu_destroy()` [L1]
- **源码**: `virt/kvm/kvm_main.c:1247`
- **语义**: 释放 vCPU 资源，释放 `pid` 引用、`run` 页面等。
- **边界类型**: `kernel KPI`
- **hot path**: 否

### 2.2 vCPU 能力发现 [子维度: vCPU 能力发现]

> 从宿主机硬件能力 → KVM 过滤策略 → Guest CPUID 暴露的完整链路。

#### `boot_cpu_data` [L3]
- **源码**: `arch/x86/kernel/cpu/common.c`
- **语义**: 全局 `cpuinfo_x86` 结构体，包含 CPU 厂商、型号、物理地址位数、特性位图。KVM 用它检测宿主机 CPU 能力。
- **边界类型**: `kernel KPI`
- **调用上下文**: 被 `kvm_cpu_cap_init()` 读取以初始化 KVM 特性掩码
- **可替代性**: 任何 hypervisor 都需要等效的硬件能力探测机制

#### `cpu_feature_enabled()` [L2]
- **源码**: `arch/x86/include/asm/cpufeature.h`
- **语义**: 使用 static key 优化的运行时特性检测。
- **边界类型**: `kernel KPI`
- **hot path**: 是（在某些 VM exit 处理路径上）

#### `kvm_cpu_cap_has()` / `kvm_cpu_cap_set()` / `kvm_cpu_cap_clear()` [L2]
- **源码**: `arch/x86/kvm/cpuid.c`
- **语义**: KVM 维护自己的 CPU 特性掩码，决定哪些特性暴露给 guest。
- **边界类型**: `kernel KPI`
- **hot path**: 否（初始化/配置路径）

#### `kvm_emulate_cpuid()` [L1]
- **源码**: `arch/x86/kvm/cpuid.c`
- **语义**: 当 guest 执行 CPUID 指令时，根据 KVM 的特性掩码返回过滤后的 CPUID 信息。
- **边界类型**: `kernel KPI`
- **hot path**: 否（guest 执行 CPUID 时触发 VM exit）

#### `kvm_get_msr()` / `kvm_set_msr()` [L1]
- **源码**: `arch/x86/kvm/x86.c`
- **语义**: 拦截 guest 的 RDMSR/WRMSR 指令。不同 MSR 有不同处理策略（透传/模拟/拒绝）。
- **边界类型**: `kernel KPI`
- **hot path**: 否
- **横切标签**: 配置与资源限制

#### `kvm_is_supported_user_return_msr()` [L2]
- **源码**: `arch/x86/kvm/x86.c`
- **语义**: 检查给定 MSR 是否可以通过 KVM 的 user return MSR 机制安全切换。
- **边界类型**: `kernel KPI`

#### `kvm_x86_ops` [L3]
- **源码**: `arch/x86/kvm/x86.c`
- **语义**: x86 厂商特定操作的函数指针表（VMX 或 SVM）。KVM 与硬件虚拟化扩展交互的核心接口。
- **边界类型**: `kernel KPI`
- **接口契约**: 包含 ~50 个函数指针；在模块初始化时设置为 vmx_x86_ops 或 svm_x86_ops

### 2.3 硬件虚拟化启用/禁用 [子维度: vCPU 生命周期]

#### `kvm_enable_virtualization()` / `kvm_disable_virtualization()` [L1]
- **源码**: `virt/kvm/kvm_main.c:5685`
- **语义**: 在所有 CPU 上启用/禁用硬件虚拟化扩展（VMX/SVM）。
- **边界类型**: `kernel KPI`
- **接口契约**: 通过 `cpuhp_setup_state()` 注册 CPU 热插拔回调；引用计数（kvm_usage_count）
- **hot path**: 否

#### `cpuhp_setup_state()` [L1]
- **源码**: `kernel/cpu.c`, KVM 调用在 `virt/kvm/kvm_main.c:5696`
- **语义**: KVM 注册 `CPUHP_AP_KVM_ONLINE` 回调，CPU 上线/下线时启用/禁用虚拟化扩展。
- **调用上下文**: consumer — 由 `kvm_enable_virtualization()` 在模块初始化时调用
- **边界类型**: `kernel KPI`（Linux CPU 热插拔子系统）
- **接口契约**: 注册 online/offline 回调；返回状态码；在 CPU 热插拔事件时内核回调 KVM
- **hot path**: 否

#### `on_each_cpu()` [L2]
- **KVM 使用**: `virt/kvm/kvm_main.c:5647`
- **语义**: 关闭虚拟化时在所有 CPU 上禁用硬件虚拟化扩展。
- **边界类型**: `kernel KPI`

### 2.4 CPU 拓扑信息

#### `num_online_cpus` / `cpu_online_mask` [L2]
- **源码**: `include/linux/cpumask.h`
- **语义**: 获取在线 CPU 数量和掩码。KVM 用于判断 vCPU 应该在哪些物理 CPU 上运行。
- **边界类型**: `kernel KPI`
- **hot path**: 否（配置/调度路径）

#### `nr_cpu_ids` [L2]
- **语义**: 系统中可能的最高 CPU ID + 1。KVM 在 kick vCPU 时用于边界检查。
- **边界类型**: `kernel KPI`

### 2.5 VMX/SVM 操作

#### Intel VMX 操作集 [L1]
- **源码位置**: `arch/x86/kvm/vmx/vmx.c` 等
- **语义**: Intel VMX 硬件虚拟化操作实现。通过 `kvm_x86_ops` 函数表（设置为 `vmx_x86_ops`）提供：VMCS 加载/卸载、VMLAUNCH/VMRESUME guest entry、VM exit 处理、EPT 管理等。
- **调用上下文**: provider — 被 KVM 通用核心通过 `kvm_x86_ops->*` 调用
- **边界类型**: `kernel KPI`
- **接口契约**: 全部通过 `struct kvm_x86_ops` 函数指针表暴露；编译时选择（CONFIG_KVM_INTEL）；返回约定：0 成功 / 负 errno
- **hot path**: 是（`vmx_run()` 和 `vmx_handle_exit()` 在每次 guest entry/exit 时执行）

#### AMD SVM 操作集 [L1]
- **源码位置**: `arch/x86/kvm/svm/svm.c` 等
- **语义**: AMD SVM 硬件虚拟化操作实现。通过 `kvm_x86_ops` 函数表（设置为 `svm_x86_ops`）提供：VMCB 加载/卸载、VMRUN guest entry、#VMEXIT 处理、NPT 管理、AVIC 中断虚拟化、SEV 加密虚拟化等。
- **调用上下文**: provider — 被 KVM 通用核心通过 `kvm_x86_ops->*` 调用
- **边界类型**: `kernel KPI`
- **接口契约**: 全部通过 `struct kvm_x86_ops` 函数指针表暴露；编译时选择（CONFIG_KVM_AMD）；支持 SEV-ES/SEV-SNP 扩展
- **hot path**: 是

### 2.6 PMU 模拟

#### `kvm_pmu_is_valid_msr()` / `kvm_pmu_get_msr()` / `kvm_pmu_set_msr()` [L2]
- **源码**: `arch/x86/kvm/pmu.c`
- **语义**: 模拟 PMU 的 MSR，允许 guest 使用性能计数器。
- **边界类型**: `kernel KPI`
- **hot path**: 否
- **横切标签**: 可观测性

---

## 3. 维度 3: I/O 模型 {#dim3-io}

> **覆盖内容**: 设备模拟、PIO/MMIO、virtio  
> **子维度**: 3a. I/O 资源访问（PIO/MMIO trap、设备注册）、3b. I/O 设备协议（virtio、NVMe、AHCI）  
> **注意**: KVM 在用户态 QEMU 中做 I/O 设备模拟，内核侧主要处理 I/O 指令拦截和分发。以下仅覆盖 KVM 内核需要的内核接口。

### 3.1 I/O 资源访问 [子维度 3a]

#### `kvm_io_bus_write()` / `kvm_io_bus_read()` [L1]
- **源码**: `virt/kvm/kvm_main.c:5898` / `virt/kvm/kvm_main.c:5967`
- **语义**: 当 guest 执行 PIO 或 MMIO 访问时，KVM 在注册的 IO bus 设备上分发读写请求。
- **边界类型**: `kernel KPI`
- **hot path**: 否（I/O 路径上，频率取决于 guest I/O 模式）

### 3.2 Hypercall 处理 [子维度 3a]

#### `kvm_emulate_hypercall()` [L1]
- **源码**: `arch/x86/kvm/x86.c`
- **语义**: 拦截 guest 的 VMCALL (Intel) / VMMCALL (AMD)，处理 hypercall。支持 KVM hypercall、Hyper-V hypercall 等。
- **边界类型**: `kernel KPI`
- **hot path**: 否

---

## 4. 维度 4: 中断与事件 {#dim4-interrupt}

> **覆盖内容**: 中断注入、事件通知、信号、eventfd/irqfd

### 4.1 中断注入

#### `kvm_queue_interrupt()` [L1]
- **源码**: `arch/x86/kvm/x86.c`
- **语义**: 将中断排队等待注入 guest。在下一次 guest entry 时检查并注入。
- **边界类型**: `kernel KPI`
- **接口契约**: 设置 vcpu->arch.interrupt 相关字段；在下一次 VM entry 时由硬件虚拟化扩展注入
- **hot path**: 否

#### `kvm_inject_page_fault()` [L1]
- **源码**: `arch/x86/kvm/x86.c:973`
- **语义**: 当 guest 发生 page fault 需要注入到 guest 时调用。
- **边界类型**: `kernel KPI`
- **hot path**: 是（page fault 处理路径上）

#### `kvm_inject_nmi()` [L1]
- **源码**: `arch/x86/kvm/x86.c:1012`
- **语义**: 向 guest 注入不可屏蔽中断。
- **边界类型**: `kernel KPI`
- **hot path**: 否

#### `kvm_queue_exception()` / `kvm_inject_emulated_page_fault()` [L1]
- **源码**: `arch/x86/kvm/x86.c:902` / `arch/x86/kvm/x86.c:990`
- **语义**: 向 guest 排队/注入异常。
- **边界类型**: `kernel KPI`

### 4.2 APIC 模拟

#### `kvm_apic_has_interrupt()` [L1]
- **源码**: `arch/x86/kvm/lapic.c`
- **语义**: 检查 local APIC 的 IRR 是否有 pending 中断。
- **边界类型**: `kernel KPI`
- **hot path**: 是（每次 VM entry 前检查）

#### APIC 寄存器模拟 [L2]
- **源码**: `arch/x86/kvm/lapic.c`
- **语义**: 模拟 local APIC 的全部寄存器，包括 ICR、IRR、ISR、LVT 等。
- **边界类型**: `kernel KPI`

### 4.3 定时器中断 [横切: 时钟与定时器]

#### `kvm_cpu_has_pending_timer()` [L2]
- **源码**: `arch/x86/kvm/irq.c:27`
- **语义**: 检查 LAPIC/PIT 是否有待注入 guest 的定时器中断。
- **边界类型**: `kernel KPI`
- **hot path**: 是

#### `kvm_inject_pending_timer_irqs()` [L1]
- **源码**: `arch/x86/kvm/irq.c:169`
- **语义**: 将所有待处理的定时器中断注入到 guest 中。
- **边界类型**: `kernel KPI`
- **hot path**: 是

#### `apic_timer_expired()` [L2]
- **源码**: `arch/x86/kvm/lapic.c:2025`
- **语义**: 当 guest 定时器到期时，向 guest 注入定时器中断。支持 posted interrupt 优化。
- **调用上下文**: 由 hrtimer 回调 / VMX preemption timer 触发
- **边界类型**: `kernel KPI`
- **hot path**: 否

### 4.4 vCPU 请求机制

#### `kvm_make_all_cpus_request()` [L1]
- **源码**: `virt/kvm/kvm_main.c:273`
- **语义**: 向 VM 的所有 vCPU 发送请求（如 TLB flush、VM shutdown），必要时发送 IPI。
- **调用上下文**: consumer — 被 TLB flush、内存布局变更等触发
- **边界类型**: `kernel KPI`
- **接口契约**: 遍历所有 vCPU；设置请求位；调用 `kvm_kick_many_cpus()` 发送 IPI
- **hot path**: 否（管理路径，但在 TLB flush 场景频率较高）

#### `kvm_make_vcpus_request_mask()` [L2] — 向 CPU 掩码子集发送请求
- **源码**: `virt/kvm/kvm_main.c`
- **语义**: 向指定 CPU 掩码范围内运行中的 vCPU 发送请求。是 `kvm_make_all_cpus_request()` 的底层实现。
- **调用上下文**: consumer — 被 `kvm_make_all_cpus_request()` 和 `kvm_flush_remote_tlbs()` 等调用
- **边界类型**: `kernel KPI`
- **接口契约**: 输入 kvm + req + cpu_mask；遍历掩码对应的 vCPU；按需发送 IPI；返回是否实际 kick 了任何 vCPU
- **hot path**: 否

#### `kvm_make_vcpu_request()` [L2] — 向单个 vCPU 发送请求
- **源码**: `virt/kvm/kvm_main.c`
- **语义**: 向单个 vCPU 设置请求位，如果需要（vCPU 在 guest 模式或在其他 CPU 上运行）则发送 kick。更细粒度的请求机制。
- **调用上下文**: consumer — 被 `kvm_make_vcpus_request_mask()` 遍历每个 vCPU 时调用
- **边界类型**: `kernel KPI`
- **接口契约**: 输入 vcpu + req + kick flag；设置 vcpu->requests 位；按需调用 `kvm_vcpu_kick()`；在持有 vcpu->mutex 或不需锁定的原子上下文中调用
- **hot path**: 否

---

## 5. 维度 5: 时钟与定时器 {#dim5-clock}

> **覆盖内容**: 高精度时钟、定时器源、时钟虚拟化

### 5.1 hrtimer 接口

#### `hrtimer_start()` [L1] — 启动高精度定时器
- **源码**: `include/linux/hrtimer.h`, KVM 使用在 LAPIC/PIT 定时器
- **语义**: 启动一个高精度定时器，用于模拟 guest 的定时器设备。
- **边界类型**: `kernel KPI`（Linux hrtimer 子系统）
- **接口契约**: 输入 hrtimer、到期时间(ktime_t)、模式(HRTIMER_MODE_ABS_HARD)；在硬中断上下文回调
- **hot path**: 否

#### `hrtimer_cancel()` [L1]
- **语义**: 取消一个已启动的 hrtimer。
- **边界类型**: `kernel KPI`
- **hot path**: 否

#### `hrtimer_setup()` [L1]
- **语义**: 初始化 hrtimer 结构并绑定回调函数。
- **边界类型**: `kernel KPI`
- **hot path**: 否

### 5.2 LAPIC 定时器模拟

#### `struct kvm_timer` [L3] — KVM 定时器核心数据结构
- **源码**: `arch/x86/kvm/lapic.h:49`
- **语义**: KVM 中 guest 定时器的核心抽象，封装了 hrtimer、TSC deadline、定时器模式等。
- **边界类型**: 内部数据结构

#### `start_hv_timer()` [L1] — 启动硬件虚拟化定时器
- **源码**: `arch/x86/kvm/lapic.c:2251`
- **语义**: 使用 VMX preemption timer 或 AMD 等价机制模拟 guest 定时器。比软件 hrtimer 精度更高、开销更小。回退到 `start_sw_timer()`。
- **边界类型**: `kernel KPI`
- **hot path**: 否

#### `start_sw_timer()` [L2] — 启动软件定时器
- **源码**: `arch/x86/kvm/lapic.c:2293`
- **语义**: 当硬件定时器不可用时，回退使用 Linux hrtimer 模拟 guest 定时器。
- **边界类型**: `kernel KPI`
- **hot path**: 否

#### `start_sw_tscdeadline()` [L2] — TSC deadline 模式的软件定时器
- **源码**: `arch/x86/kvm/lapic.c:2063`
- **语义**: 计算从当前 TSC 到 deadline 的时间差，转换为纳秒后启动 hrtimer。
- **边界类型**: `kernel KPI`
- **hot path**: 否

### 5.3 PIT 定时器模拟

#### `pit_timer_fn()` [L2]
- **源码**: `arch/x86/kvm/i8254.c:268`
- **语义**: PIT 的 hrtimer 回调函数，周期模式下自动重新加载。
- **边界类型**: `kernel KPI`
- **hot path**: 否

### 5.4 TSC 虚拟化

#### `kvm_read_l1_tsc()` [L2]
- **源码**: `arch/x86/kvm/x86.c`
- **语义**: 读取当前 TSC 值并应用 L1 的 TSC offset/scaling。
- **边界类型**: `kernel KPI`
- **hot path**: 是（在 guest entry/exit 和定时器计算中使用）

#### `get_kvmclock_ns()` [L1]
- **源码**: `arch/x86/kvm/x86.h:460`
- **语义**: 获取基于 kvmclock (pvclock) 的当前时间，用于 guest 时间同步。
- **边界类型**: `kernel KPI`
- **hot path**: 否

### 5.5 时间获取

#### `ktime_get()` [L1]
- **语义**: KVM 广泛使用此函数获取当前时间戳，用于定时器计算、halt polling 等。
- **边界类型**: `kernel KPI`（Linux 时间子系统）
- **hot path**: 是（在 halt polling 和事件循环中使用）

#### `rdtsc()` [L1]
- **语义**: 直接读取 CPU TSC 寄存器，用于高精度时间测量和 guest TSC 模拟。
- **边界类型**: 硬件指令（x86）
- **hot path**: 是

### 5.6 定时器迁移

#### `__kvm_migrate_timers()` [L2]
- **源码**: `arch/x86/kvm/irq.c:177`
- **语义**: 当 vCPU 被迁移到新的物理 CPU 时，将其定时器也迁移过去，避免不必要的 IPI。
- **边界类型**: `kernel KPI`
- **hot path**: 否

---

## 6. 维度 6: 调度与同步 {#dim6-sched}

> **覆盖内容**: 线程模型、抢占、锁  
> **核心概念**: KVM 将每个 vCPU 视为一个标准的 Linux 线程 (task_struct)，由 Linux CFS 调度器统一调度。

### 6.1 抢占通知 (Preemption Notification)

#### `preempt_notifier` [L3]
- **源码**: `include/linux/preempt.h`, KVM 使用在 vcpu 结构体成员
- **语义**: KVM 注册抢占通知器，当 vCPU 线程被调度器换入/换出时收到回调。KVM 调度机制的核心。
- **边界类型**: `kernel KPI`（Linux 调度器子系统）

#### `vcpu_load()` / `vcpu_put()` [L1] — 加载/卸载 vCPU 上下文
- **源码**: `virt/kvm/kvm_main.c:164` / `virt/kvm/kvm_main.c:175`
- **语义**: 操作 vCPU 前加载上下文（注册抢占通知器），完成后卸载。
- **边界类型**: `kernel KPI`
- **接口契约**: `vcpu_load` 注册 preempt_notifier + 架构 vcpu_load；`vcpu_put` 相反
- **hot path**: 是（每次 vCPU 操作前都要调用）

### 6.2 vCPU 唤醒与踢出 (Kick/Wake)

#### `kvm_vcpu_wake_up()` [L1]
- **源码**: `virt/kvm/kvm_main.c:3793`
- **语义**: 通过 `rcuwait_wake_up()` 唤醒处于 halt 状态的 vCPU 线程。
- **边界类型**: `kernel KPI`
- **接口契约**: 调用 `rcuwait_wake_up()`；被 `__kvm_vcpu_kick()` 调用
- **hot path**: 否

#### `__kvm_vcpu_kick()` [L1]
- **源码**: `virt/kvm/kvm_main.c:3809`
- **语义**: 强制 vCPU 退出 guest 模式。如果 vCPU 正在运行，发送 IPI 或 RESCHEDULE IPI。
- **调用上下文**: 在需要立即中断 guest 执行时调用（中断注入、TLB flush 等）
- **边界类型**: `kernel KPI`
- **接口契约**: 输入 vcpu + wait 标志；先尝试唤醒，再发送 IPI；可能等待 ACK（wait=true）
- **hot path**: 否（管理路径）

### 6.3 vCPU Halt/Wait

#### `kvm_vcpu_halt()` / `kvm_vcpu_block()` [L1]
- **源码**: `virt/kvm/kvm_main.c`
- **语义**: guest 执行 HLT 时 vCPU 线程进入 halt polling 然后睡眠。含自适应 polling 机制。
- **调用上下文**: consumer — 由 `kvm_emulate_hlt()` (x86) 或 guest HLT VM exit 触发
- **边界类型**: `kernel KPI`
- **接口契约**: 先 halt polling（忙等），超时后调用 `schedule()` 真正睡眠；polling 时长自适应
- **hot path**: 是（guest idle 时频繁进入）

#### `kvm_vcpu_check_block()` [L2] — block 前条件检查
- **源码**: `virt/kvm/kvm_main.c`
- **语义**: vCPU 进入 sleep 前检查是否有 pending 中断或请求，避免竞态（检查到有事件则不睡眠）。
- **调用上下文**: consumer — 由 `kvm_vcpu_block()` 在调用 `schedule()` 前调用
- **边界类型**: `kernel KPI`
- **接口契约**: 检查 pending interrupts、requests、posted interrupts；返回 >0 表示不应 block，0 表示继续睡眠
- **hot path**: 是

### 6.4 vCPU Yield

#### `kvm_vcpu_yield_to()` [L1]
- **源码**: `virt/kvm/kvm_main.c:3858`
- **语义**: 当一个 vCPU 在 spin loop 中等待锁时，主动让出 CPU 给持有锁的 vCPU。
- **边界类型**: `kernel KPI`
- **接口契约**: 通过 `get_pid_task()` → `yield_to()` 实现；返回 0/1 表示是否成功
- **hot path**: 否（仅在 overcommit + spin lock 场景触发）

#### `kvm_vcpu_on_spin()` [L1] — PLE 处理
- **源码**: `virt/kvm/kvm_main.c:4033`
- **语义**: 检测到 guest spin loop 时，在 overcommit 场景进行 directed yield。
- **边界类型**: `kernel KPI`
- **hot path**: 否

### 6.5 进程关联接口

#### `get_pid_task()` / `put_task_struct()` [L2]
- **语义**: KVM 通过 vCPU 的 `pid` 获取 Linux task_struct，用于调度操作。
- **边界类型**: `kernel KPI`（Linux 进程管理）

#### `yield_to()` [L1]
- **源码**: `kernel/sched/core.c`
- **语义**: Linux CFS 调度器的 directed yield 机制。
- **边界类型**: `kernel KPI`（Linux 调度器子系统）
- **hot path**: 否

### 6.6 锁与同步

#### `kvm->lock` / `kvm->slots_lock` / `kvm->irq_lock` [L3] — KVM 三级锁层次
- **语义**: KVM 定义的锁层次：`kvm->lock` → `kvm->slots_lock` → `kvm->irq_lock`。
- **边界类型**: 内部锁机制

#### `spinlock_t` / `struct mutex` / `struct srcu_struct` [L3]
- **语义**: KVM 使用的 Linux 锁原语。`spinlock_t`（mmu_lock）保护 shadow page table / EPT；`struct mutex`（slots_lock）保护 memslot 变更；`struct srcu_struct`（kvm->srcu）保护 memslot 无锁读取。
- **边界类型**: `kernel KPI`（Linux 锁子系统）
- **调用上下文**: provider — Linux 内核锁 API，被 KVM 所有子系统使用
- **接口契约**: spinlock 用于短临界区（不可睡眠）；mutex 用于可能睡眠的路径；SRCU 用于读多写少场景，读者不阻塞写者

### 6.7 Workqueue 与异步操作

#### `schedule_work()` / `queue_work()` [L1]
- **语义**: KVM 使用 workqueue 处理不需要在 vCPU 线程上下文中执行的工作（如 async page fault）。
- **边界类型**: `kernel KPI`（Linux workqueue 子系统）

### 6.8 Guest 上下文进入/退出

#### `guest_state_enter_irqoff()` / `guest_state_exit_irqoff()` [L1]
- **源码**: `include/linux/kvm_host.h`
- **语义**: 进入/退出 guest 模式时的上下文管理。处理 RCU、lockdep、中断追踪等。
- **边界类型**: `kernel KPI`
- **接口契约**: 进入时标记 RCU quiescent state、通知 lockdep、更新中断追踪状态
- **hot path**: 是（每次 VM entry/exit）

---

## 7. 维度 7: 安全与隔离 {#dim7-security}

> **覆盖内容**: 权限模型、沙箱、资源限制  
> **注意**: KVM 内核层面的安全接口较少——大部分安全机制在用户态 QEMU 层实现。以下列出 KVM 内核涉及的安全相关接口。

### 7.1 Nested Virtualization [横切: 控制面生命周期]

#### `struct kvm_x86_ops.nested_ops` [L2]
- **源码**: `arch/x86/kvm/vmx/nested.c`, `arch/x86/kvm/svm/nested.c`
- **语义**: 嵌套虚拟化操作函数表，支持在 guest 中运行另一个 hypervisor。涉及额外的 VMCS/VMCB 验证和权限检查。
- **边界类型**: `kernel KPI`
- **hot path**: 否

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

## 接口数量统计（按新 7 维度 + 边界类型）

| 维度 | L1 接口 | L2 接口 | L3 数据结构 | 合计 | 主要边界类型 |
|------|---------|---------|-----------|------|-------------|
| 1. 内存管理 | 10 | 11 | 1 | 22 | kernel KPI |
| 2. vCPU 管理 | 8 | 10 | 3 | 21 | kernel KPI |
| 3. I/O 模型 | 2 | 0 | 0 | 2 | kernel KPI |
| 4. 中断与事件 | 7 | 4 | 0 | 11 | kernel KPI |
| 5. 时钟与定时器 | 8 | 5 | 1 | 14 | kernel KPI / 硬件指令 |
| 6. 调度与同步 | 9 | 4 | 4 | 17 | kernel KPI |
| 7. 安全与隔离 | 0 | 1 | 0 | 1 | kernel KPI |
| **总计** | **46** | **35** | **7** | **88** | — |

> L1 ≥ 15 ✅ | L2 ≥ 35 ✅ | L3 随文附带

---

## 附录 A: 旧 5 分类 → 新 7 维度映射表 {#appendix-mapping}

| 旧分类 | 新维度 | 关键条目去向 |
|--------|--------|-------------|
| 1. 内存管理 | 维度 1 | 直接映射（21 条） |
| 2. 时钟 | 维度 5（主要）+ 维度 4（中断部分） | `hrtimer_*`、`start_sw_tscdeadline` → 维度 5；`apic_timer_expired`、`kvm_inject_pending_timer_irqs` → 维度 4 |
| 3. 主机信息 | 维度 2（主要）+ 维度 1（内存拓扑） | `boot_cpu_data`、`kvm_cpu_cap_*`、`kvm_x86_ops` → 维度 2；`kvm_host_page_size` → 维度 1 |
| 4. 虚拟机管理 | 维度 6（调度）+ 维度 2（生命周期）+ 维度 4（请求） | `vcpu_load/put`、`kvm_vcpu_kick`、`kvm_vcpu_yield_to` → 维度 6；`kvm_vcpu_init/destroy` → 维度 2；`kvm_make_all_cpus_request` → 维度 4 |
| 5. 架构相关 | 维度 1/2/3/4/7 | EPT/NPT → 维度 1；VMX/SVM/MSR/CPUID/PMU → 维度 2；PIO/MMIO/Hypercall → 维度 3；中断注入/APIC → 维度 4；Nested virt → 维度 7 |

## 附录 B: 源码参考位置

| 新维度 | 关键文件 |
|--------|----------|
| 通用核心 | `virt/kvm/kvm_main.c`, `include/linux/kvm_host.h` |
| 1. 内存管理 | `virt/kvm/kvm_main.c`, `arch/x86/kvm/mmu/` |
| 2. vCPU 管理 | `arch/x86/kvm/x86.c`, `arch/x86/kvm/cpuid.c`, `arch/x86/kvm/vmx/vmx.c`, `arch/x86/kvm/svm/svm.c` |
| 3. I/O 模型 | `arch/x86/kvm/x86.c`, `virt/kvm/coalesced_mmio.c` |
| 4. 中断与事件 | `arch/x86/kvm/irq.c`, `arch/x86/kvm/lapic.c`, `arch/x86/kvm/ioapic.c` |
| 5. 时钟与定时器 | `arch/x86/kvm/lapic.c`, `arch/x86/kvm/i8254.c`, `arch/x86/kvm/x86.c` |
| 6. 调度与同步 | `virt/kvm/kvm_main.c` (vcpu_load/put, kick, yield, halt) |
| 7. 安全与隔离 | `arch/x86/kvm/vmx/nested.c`, `arch/x86/kvm/svm/nested.c` |

## 附录 C: 横切标签使用分布

| 横切标签 | 涉及的接口条目 | 说明 |
|----------|--------------|------|
| 控制面生命周期 | `kvm_vcpu_init/destroy`, `kvm_enable_virtualization`, nested ops | VM/vCPU 创建销毁 |
| fd/device node | `/dev/kvm` (未在本文档详述，属于用户态 API) | 设备节点操作 |
| host 资源 | `kvm_get_dirty_log`, `kvm_set_memory_region` | 镜像加载/migration |
| PCI/IOMMU/DMA | EPT/NPT 管理函数 | 地址翻译硬件 |
| 可观测性 | `kvm_pmu_*` | PMU 计数器 |
| 配置与资源限制 | `kvm_get_msr/set_msr`, `kvm_cpu_cap_*` | MSR 访问控制 |
