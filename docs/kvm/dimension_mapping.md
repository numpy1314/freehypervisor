# KVM 接口分类映射表：旧 5 分类 → 新 7 维度

> AC-7 质量门 — 接口清单（重构前评审用）
> 此文件作为 KVM 分析文档的附录

## 映射规则

| 旧分类 | 新维度 | 说明 |
|--------|--------|------|
| 内存管理 | 维度 1：内存管理 | **直接映射** |
| 时钟 | 维度 5：时钟与定时器 | **直接映射**（定时器中断注入部分归入维度 4） |
| 主机信息 | 维度 2：vCPU 管理 | **拆分**：CPU 特性检测/MSR/CPUID/拓扑/热插拔归入"vCPU 能力发现"子节；内存拓扑归入维度 1 |
| 虚拟机管理 | 维度 2 + 维度 6 + 维度 4 | **拆分**：vCPU 生命周期归入维度 2；抢占/调度/kick/wake/yield/halt/锁归入维度 6；请求机制归入维度 4 |
| 架构相关 | 维度 1/2/3/4/7 | **拆分最多**：EPT/NPT 归入维度 1；VMX/SVM/MSR/CPUID/PMU 归入维度 2；PIO/MMIO/Hypercall 归入维度 3；中断注入/APIC 归入维度 4；Nested virt 归入维度 7 |

---

## 详细映射表

### 旧 1 → 新 1：内存管理（直接映射）

| 原条目 | 原位置 | 新归入 |
|--------|--------|--------|
| `kvm_set_memory_region()` | 1.1 Guest 内存区域管理 | 维度 1 — GPA→HVA 映射 |
| `gfn_to_memslot()` / `kvm_vcpu_gfn_to_memslot()` | 1.1 | 维度 1 — GFN 查找 |
| `kvm_is_visible_gfn()` | 1.1 | 维度 1 — GFN 可见性 |
| `gfn_to_hva_memslot()` / `gfn_to_hva()` | 1.2 GFN→HVA/PFN | 维度 1 — 地址转换 |
| `hva_to_pfn()` | 1.2 | 维度 1 — GUP 核心入口 |
| `pin_user_pages_fast()` | 1.3 页面锁定 | 维度 1 — 页面锁定 |
| `pin_user_pages_unlocked()` | 1.3 | 维度 1 — 慢速锁定 |
| `unpin_user_page()` | 1.3 | 维度 1 — 解锁 |
| `__kvm_faultin_pfn()` | 1.4 Guest 页面映射 | 维度 1 — Page fault 处理 |
| `__gfn_to_page()` | 1.4 | 维度 1 — GFN→page |
| `__kvm_vcpu_map()` / `kvm_vcpu_unmap()` | 1.4 | 维度 1 — Guest 内存映射 |
| `kvm_read_guest()` / `kvm_write_guest()` | 1.5 Guest 内存读写 | 维度 1 — 内存读写 |
| `kvm_get_dirty_log()` | 1.6 脏页追踪 | 维度 1 — Live migration |
| `mark_page_dirty_in_slot()` / `mark_page_dirty()` | 1.6 | 维度 1 — 脏页标记 |
| `kvm_mmu_notifier_ops` | 1.7 MMU Notifier | 维度 1 — 反向映射同步 |
| `mmu_notifier_register()` | 1.7 | 维度 1 — MMU 通知注册 |
| `kvm_flush_remote_tlbs()` | 1.8 TLB 刷新 | 维度 1 — TLB 刷新 |

### 旧 2 → 新 5：时钟与定时器（直接映射 + 部分到维度 4）

| 原条目 | 原位置 | 新归入 |
|--------|--------|--------|
| `hrtimer_start()` | 2.1 hrtimer 接口 | 维度 5 — 高精度定时器 |
| `hrtimer_cancel()` | 2.1 | 维度 5 — 取消定时器 |
| `hrtimer_setup()` | 2.1 | 维度 5 — 初始化定时器 |
| `struct kvm_timer` | 2.2 LAPIC 定时器 | 维度 5 — 定时器抽象 |
| `start_hv_timer()` | 2.2 | 维度 5 — 硬件虚拟化定时器 |
| `start_sw_timer()` | 2.2 | 维度 5 — 软件定时器回退 |
| `apic_timer_expired()` | 2.2 | 维度 4 — 定时器中断注入 |
| `start_sw_tscdeadline()` | 2.2 | 维度 5 — TSC deadline |
| `pit_timer_fn()` | 2.3 PIT 定时器 | 维度 5 — PIT 回调 |
| `kvm_read_l1_tsc()` | 2.4 TSC 虚拟化 | 维度 5 — TSC 读取 |
| `get_kvmclock_ns()` | 2.4 | 维度 5 — kvmclock |
| `kvm_cpu_has_pending_timer()` | 2.5 定时器中断 | 维度 4 — 中断检查 |
| `kvm_inject_pending_timer_irqs()` | 2.5 | 维度 4 — 中断注入 |
| `__kvm_migrate_timers()` | 2.5 | 维度 5 — 定时器迁移 |
| `ktime_get()` | 2.6 时间获取 | 维度 5 — 时间获取 |
| `rdtsc()` | 2.6 | 维度 5 — TSC 读取 |

### 旧 3 → 新 2：主机信息（归入 vCPU 管理 + 部分到维度 1）

| 原条目 | 原位置 | 新归入 |
|--------|--------|--------|
| `boot_cpu_data` | 3.1 CPU 特性检测 | 维度 2 — vCPU 能力发现 |
| `cpu_feature_enabled()` | 3.1 | 维度 2 — 特性检测 |
| `kvm_cpu_cap_has/set/clear()` | 3.1 | 维度 2 — KVM 特性掩码 |
| `num_online_cpus` / `cpu_online_mask` | 3.2 CPU 数量和拓扑 | 维度 2 — vCPU 拓扑 |
| `nr_cpu_ids` | 3.2 | 维度 2 — CPU 边界 |
| `cpuhp_setup_state()` | 3.3 CPU 热插拔 | 维度 2 — CPU 热插拔回调 |
| `on_each_cpu()` | 3.3 | 维度 2 — 全 CPU 操作 |
| `kvm_host_page_size()` | 3.4 内存拓扑 | 维度 1 — 宿主机页面大小 |
| `kvm_x86_ops` | 3.5 虚拟化能力 | 维度 2 — 硬件虚拟化操作表 |

### 旧 4 → 新 2/6/4：虚拟机管理（大拆分）

| 原条目 | 原位置 | 新归入 |
|--------|--------|--------|
| `kvm_vcpu_init()` | 4.1 vCPU 生命周期 | 维度 2 — vCPU 初始化 |
| `kvm_vcpu_destroy()` | 4.1 | 维度 2 — vCPU 销毁 |
| `preempt_notifier` | 4.2 抢占通知 | 维度 6 — 抢占通知器 |
| `vcpu_load()` / `vcpu_put()` | 4.2 | 维度 6 — vCPU 加载/卸载 |
| `kvm_vcpu_wake_up()` | 4.3 唤醒与踢出 | 维度 6 — vCPU 唤醒 |
| `__kvm_vcpu_kick()` | 4.3 | 维度 6 — vCPU 踢出(IPI) |
| `kvm_vcpu_halt()` | 4.4 Halt/Wait | 维度 6 — vCPU halt |
| Halt Polling 自适应机制 | 4.4 | 维度 6 — 自适应 polling |
| `kvm_vcpu_yield_to()` | 4.5 Yield | 维度 6 — Directed yield |
| `kvm_vcpu_on_spin()` | 4.5 | 维度 6 — PLE 处理 |
| `kvm_make_all_cpus_request()` | 4.6 请求机制 | 维度 4 — vCPU 请求(IPI) |
| `get_pid_task()` / `put_task_struct()` | 4.7 进程关联 | 维度 6 — PID→task_struct |
| `yield_to()` | 4.7 | 维度 6 — CFS yield |
| `kvm->lock/mutex/spinlock/SRCU` | 4.8 锁与同步 | 维度 6 — KVM 三级锁层次 |
| `schedule_work()` / `queue_work()` | 4.9 Workqueue | 维度 6 — 异步工作队列 |
| `guest_state_enter/exit_irqoff()` | 4.10 Guest 上下文 | 维度 6 — 上下文管理 |

### 旧 5 → 新 1/2/3/4/7：架构相关（最大拆分）

| 原条目 | 原位置 | 新归入 |
|--------|--------|--------|
| `kvm_enable/disable_virtualization()` | 5.1 硬件虚拟化 | 维度 2 — 虚拟化启用 |
| VMX: `vmx_vcpu_load/put()` | 5.2 VMX | 维度 2 — VMCS 管理 |
| VMX: `vmx_run()` | 5.2 | 维度 2 — VMLAUNCH/VMRESUME |
| VMX: `vmx_handle_exit()` | 5.2 | 维度 2 — VM exit 处理 |
| SVM: `svm_vcpu_load/put()` | 5.2 SVM | 维度 2 — VMCB 管理 |
| SVM: `svm_vcpu_run()` | 5.2 | 维度 2 — VMRUN |
| SVM: `svm_handle_exit()` | 5.2 | 维度 2 — #VMEXIT 处理 |
| `kvm_get_msr()` / `kvm_set_msr()` | 5.3 MSR | 维度 2 — MSR 模拟 |
| `kvm_is_supported_user_return_msr()` | 5.3 | 维度 2 — MSR 支持检查 |
| `kvm_emulate_cpuid()` | 5.4 CPUID | 维度 2 — CPUID 过滤 |
| `kvm_queue_interrupt()` | 5.5 中断注入 | 维度 4 — 中断排队 |
| `kvm_inject_page_fault()` | 5.5 | 维度 4 — 页错误注入 |
| `kvm_inject_nmi()` | 5.5 | 维度 4 — NMI 注入 |
| `kvm_queue_exception()` | 5.5 | 维度 4 — 异常注入 |
| `kvm_init_shadow_ept_mmu()` | 5.6 EPT/NPT | 维度 1 — EPT shadow MMU |
| `kvm_init_shadow_npt_mmu()` | 5.6 | 维度 1 — NPT shadow MMU |
| `kvm_mmu_set_ept_masks()` | 5.6 | 维度 1 — EPT SPTE 掩码 |
| `kvm_apic_has_interrupt()` | 5.7 APIC | 维度 4 — APIC 中断检查 |
| APIC 寄存器模拟 | 5.7 | 维度 4 — LAPIC 模拟 |
| `kvm_emulate_hypercall()` | 5.8 Hypercall | **维度 3** — Hypercall |
| `kvm_io_bus_write/read()` | 5.9 PIO/MMIO | **维度 3** — I/O 总线分发 |
| Nested virt ops | 5.10 Nested | **维度 7** — 嵌套虚拟化 |
| `kvm_pmu_is_valid/get/set_msr()` | 5.11 PMU | 维度 2 — PMU 模拟 |

---

## 统计

| 旧分类 | 条目数 | 新维度 | 条目数 |
|--------|--------|--------|--------|
| 内存管理 | 17 | 维度 1：内存管理 | 21 |
| 时钟 | 16 | 维度 2：vCPU 管理 | 18 |
| 主机信息 | 8 | 维度 3：I/O 模型 | 3 |
| 虚拟机管理 | 15 | 维度 4：中断与事件 | 9 |
| 架构相关 | 19 | 维度 5：时钟与定时器 | 13 |
| **总计** | **75** | 维度 6：调度与同步 | 15 |
| | | 维度 7：安全与隔离 | 1 |
| | | **总计** | **80** |

> 部分条目因涉及多个维度而被计入多项（如 `apic_timer_expired` 同时归入维度 4 和维度 5）。
> 冗余 5 条来源于维度交叉接口的双重归属。
