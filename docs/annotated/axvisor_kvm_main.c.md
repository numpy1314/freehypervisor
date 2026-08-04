# axvisor_kvm_main.c 逐函数精讲注解

> 目标文件：`linux-host-kernel/drivers/virt/axvisor/axvisor_kvm_main.c`（5682 行）
> 本文档所有行号、函数名、结构体名均取自源码真实内容。

---

## 一、文件总览

### 1.1 角色

这是内核模块 `axvisor_kvm.ko` 的**主体（front-end）**。它做三件事：

1. **注册 `/dev/kvm` misc 字符设备**（`axkvm_init` / `axkvm_misc`），假冒 Linux 原生 KVM 的 `/dev/kvm`，让用户态 VMM（gvisor 的 KVM platform、Firecracker）以为自己在跟真正的 KVM 对话。
2. **实现整套 KVM ioctl ABI 的三层文件对象模型**：
   - 设备层 `/dev/kvm`（`axkvm_dev_ioctl`）：`KVM_GET_API_VERSION` / `KVM_CREATE_VM` / `KVM_CHECK_EXTENSION` / `KVM_GET_SUPPORTED_CPUID` / `KVM_GET_MSR_INDEX_LIST` 等。
   - VM 层（anon inode，`axkvm_vm_ioctl`）：`KVM_CREATE_VCPU` / `KVM_SET_USER_MEMORY_REGION` / `KVM_CREATE_IRQCHIP` / `KVM_IRQFD` / `KVM_IOEVENTFD` / `KVM_SET_GSI_ROUTING` / PIT / clock 等。
   - vCPU 层（anon inode，`axkvm_vcpu_ioctl`）：`KVM_RUN` / `KVM_GET_*` / `KVM_SET_*`（regs/sregs/fpu/lapic/mp_state/cpuid2/msrs/events/xsave/xcrs/debugregs）/ `KVM_SET_SIGNAL_MASK` 等。
3. **把 guest 的 ioctl 翻译成对 axvisor 后端（Rust 侧 `axvisor_kvm_backend` / bridge）的调用**：通过 `axvisor_kvm_backend_*`（下行调用后端）与 `axvisor_kvm_x86_bridge_*`（后端上行回调本模块）两组 ABI 边界函数交互。

本文件刻意与既有的 `axvisor_adapter.ko`（RISC-V Linux-hosted 路径）分离，以免影响现有路径（见文件头注释 L3–L8）。

### 1.2 关键数据结构

- **`struct axkvm_vm`（L376–471）**：每个 `KVM_CREATE_VM` 产生一个。含 `kref refcount`、`struct mutex lock`（VM 级大锁）、后端句柄 `backend_vm`、`memslots[AXKVM_MAX_MEMSLOTS]`、`vcpus[AXKVM_MAX_VCPUS]`；x86 专有字段包括 irqchip/PIT 状态、GSI 路由表、pending IRQ 位图、ioevent/irqfd 绑定数组、SMP bringup 节流状态（`ap_boot_queue`/`ap_admitted`/`boot_controller_id`/`current_bringup_target`/`spin_park_wq`）、kvm-clock master 参考（`pvclock_master_*`）。
- **`struct axkvm_vcpu`（L473–619）**：每个 `KVM_CREATE_VCPU` 产生一个。含 `kref`、回指 `vm`、`id`、mmap 出去的 `struct kvm_run *run`、后端句柄 `backend_vcpu`；x86 专有字段包括寄存器影子（regs/sregs/fpu/lapic/mp_state/events/xsave/xcrs/debugregs/cpuid/msrs）、多个 waitqueue（`mp_state_wq`/`halt_wq`/`admit_wq`）、超订调度状态（`in_halt_wait`/`boost_target`/`bringup_boosted`/`bringup_rt_boosted`/`spin_demoted`/`spin_parked`/`boot_state`）、pvclock per-vCPU 状态、诊断计数器。
- **`struct axkvm_memslot`（L323–347）**：一个内存槽。含 `guest_phys_addr`/`memory_size`/`userspace_addr`、GUP pin 的 `pages`、以及**惰性 fault-in** 关键三件套 `pages`/`mapped`/`writable` 位图（区分 GUP-pinned RAM 与 VM_IO/VM_PFNMAP remapped PFN）。
- **`struct axkvm_eventfd_binding`（L273–292）**：ioeventfd / irqfd 的绑定项。
- **`struct axkvm_irq_route`（L294–299）**：GSI 路由表项。

### 1.3 全局表与锁

- `axkvm_backend_vm_registry[]`（L146）+ `axkvm_backend_vm_registry_lock`（L145）：后端 VM 句柄 → `struct axkvm_vm *` 的注册表，供上行回调（wake/timer/fault-in）用 handle 反查 VM。提供加锁版 `axkvm_get_backend_vm` 与**无锁版** `axkvm_lookup_backend_vm_locklessly`（hardirq/原子上下文安全）。
- `axkvm_backend_timer` / `axkvm_backend_periodic_timer`（L148/L178）+ `axkvm_backend_timer_lock`（L147）：后端 LAPIC timer 的一次性 hrtimer + 独立周期 hrtimer + 专用高优先级 workqueue `axkvm_backend_timer_wq`。
- `axkvm_running_vcpu`（per-CPU，L1534）：当前在本物理 CPU 上跑 guest 的 vCPU，供原子注入路径无锁找到发送方。
- 各种模块参数：`dev_name` / `ap_admit_budget` / `ap_alive_spin_rip` / `periodic_kick_ns` / `debug_verbose`。

### 1.4 两条 ABI 边界

- **下行（本模块 → 后端）**：`axvisor_kvm_backend_*`（如 `create_vm` / `create_vcpu` / `run` / `map_range` / `unmap_range` / `inject_irq` / `set_regs`…），声明在 `axvisor_kvm_backend.h`。
- **上行（后端 → 本模块）**：`axvisor_kvm_x86_bridge_*`（L230–248 声明），由 Rust bridge 回调，用于定时器编程、wake vCPU、directed-yield、spin park/demote、惰性 fault-in、pvclock 刷新等。这些函数多数 `EXPORT_SYMBOL_GPL`。

### 1.5 超订（oversubscription）主题

文件大量代码服务于一个核心难题：**guest vCPU 数 > host 在线 CPU 数**时的 SMP bringup 与运行期活性。相关机制贯穿：AP 准入节流（budget）、bringup nice/RT boost、软件 PLE spin demote/park、directed-yield、周期 hrtimer 兜底 drain LAPIC timer、HLT backstop、kvm-clock/pvclock。文件中含大量诊断插桩（标注 `DIAG ... Remove after diagnosis`）。

---

## 二、逐函数讲解

（按源码出现顺序，标题带真实行号区间。）

### axkvm_backend_schedule_point (L128–L140)

运行循环里的"让核点"。刻意用 `cond_resched()` 而非 `yield()`：在"每核一个 vCPU 线程"的超订布局里 runqueue 只有本任务，`yield()` 的 CFS 后端是 no-op（重新挑回同一个任务），从不真正让出核；`cond_resched()` 只要 host tick/负载均衡置了 `NEED_RESCHED` 就重新调度，对齐 KVM `vcpu_run()` 每轮检查 `need_resched` 的语义。

### axkvm_trace_count (L301–L304)

诊断日志频率限制器：`count <= 8 || is_power_of_2(count)` 时返回 true。让"前 8 次 + 之后按 2 的幂次"打印，避免刷屏。

### axkvm_normalize_x86_sregs (L306–L319)

规整 sregs 里的 LDTR。Linux KVM 把缺失的 LDTR 报成 unusable；Firecracker 从 `KVM_GET_SREGS` 起步、改 boot 段后再整体 `KVM_SET_SREGS` 写回。若返回/接受一个全零但"usable"的 LDT 描述符，VMX 会判 guest 状态非法拒绝 VM entry。此处：当 selector/base/limit/type/present 全为 0 时强制 `ldt->unusable = 1`。

### axkvm_vm_wake_halted_vcpus (L624–L638)

持 `vm->lock`，遍历所有 vCPU，对每个置 `irq_pending_wakeup=1` 并 `wake_up_all(&halt_wq)`。用于外部事件（pending IRQ 入队后）唤醒 HLT 阻塞的 vCPU。

### axkvm_vm_oversubscribed (L647–L659)

判断本 VM 是否超订：统计 `vcpus[]` 非空数量，与 `num_online_cpus()` 比较。返回 `nr_vcpus > online`。所有"仅超订才启用"的公平性路径（HLT park、周期 kick）都以它为门，保证非超订基线 1/2/4/8/16 行为不变。

### axkvm_periodic_kick_vcpu_task (L670–L696)

**Scheme B 有界驻留打断**：L0 不给本 L1 暴露可用 VMX preemption timer 时，一个忙碌 L2 vCPU 会长时间留在 guest 里饿死 L1 的 timer/RCU 投递。此函数从周期 hrtimer 硬中断里调用，用 `kick_process()`（只戳"正在运行"的任务、不唤醒阻塞的 vCPU）强制一次重调度机会。关键点：
- L680–683：按 `last_periodic_kick_ns` + `interval_ns` 限流，防止变成 kick 风暴。
- L685–693：RCU 保护下经 refcounted `run_pid` 取 `task_struct`，`kick_process` 后 `put_task_struct`。硬中断上下文不能取睡眠锁，所以全程无锁。

### axkvm_vm_periodic_kick_running_vcpus (L698–L711)

遍历 VM 的所有 vCPU 调用上面的 kick，但先 `axkvm_vm_oversubscribed` 门控——非超订直接返回。

### axkvm_vm_backstop_halted_vcpus (L734–L763)

**超订专用、限流的 HLT backstop**，从 250us workfn 里在 per-vCPU LAPIC drain 之后调用。难点在注释 L713–733：一个 idle NO_HZ AP 若 HLT 阻塞且没有 armed LAPIC timer，per-vCPU drain 就没有条目去 kick 它；若此时 BSP 广播 CALL_FUNCTION IPI 并在 `csd_lock_wait` 自旋，halted AP 永不被唤醒去跑 `flush_smp_call_function_queue()`，整机 RCU stall。
- L740–741：非超订 no-op。
- L744–758：持 `vm->lock` 遍历，只对 `in_halt_wait==1` 的 vCPU 动作，且每 vCPU 每 jiffy 最多唤醒一次（`last_halt_backstop_jiffies`），避免重新引入 HLT/wake 自旋风暴。置 `irq_pending_wakeup` 并 `wake_up_all(halt_wq)`。

### axkvm_vm_queue_pending_irq (L765–L775)

把一个 GSI 记进 `vm->pending_irq_gsis` 位图（越界则 `pr_warn` 丢弃），随后唤醒所有 halted vCPU。这是 irqfd/后端注入把中断排进"待投递"队列的入口，真正投递发生在 BSP 的 KVM_RUN 线程里（见下）。

### axkvm_vcpu_drain_pending_irqs (L777–L810)

在 vCPU 运行循环里排空 `pending_irq_gsis`。关键设计（注释 L784–789）：irqfd 回调跑在 host workqueue，而 AxVCpu 内部状态归 KVM_RUN 线程所有，所以只允许 **BSP（`vcpu->id==0`）**去 drain（L790–791 非 0 直接返回），避免 Rust 后端被无关 Linux 任务改 vCPU 状态；当前 Firecracker virtio-mmio 路由也都指向 BSP。
- L793–807：`for_each_set_bit` + `test_and_clear_bit` 原子取出每个 GSI，调 `axvisor_kvm_backend_inject_irq` 注入；失败即 `pr_err` 返回错误。

### axkvm_vm_init_default_irq_routes (L812–L824)

初始化默认 GSI 路由表：前 `KVM_IOAPIC_NUM_PINS` 条设为 `KVM_IRQ_ROUTING_IRQCHIP` / `KVM_IRQCHIP_IOAPIC`，pin == gsi。等价于 KVM 在无显式 `KVM_SET_GSI_ROUTING` 时的恒等 IOAPIC 路由。

### axkvm_vm_route_irqfd_gsi (L826–L840)

把 irqfd 的 gsi 经路由表翻译成 IOAPIC pin。仅当路由项 valid 且是 IRQCHIP/IOAPIC 时返回其 pin，否则原样返回 gsi。用 `READ_ONCE` 读（路由表可被 `KVM_SET_GSI_ROUTING` 并发替换）。

### axkvm_lapic_id / axkvm_set_lapic_id (L842–L857)

LAPIC ID 的读写辅助。ID 存于 LAPIC 寄存器影子的 `regs[0x20..0x23]`（APIC ID 寄存器偏移 0x20，ID 在最高字节 `regs[0x23]`）。set 时清低三字节、写 `regs[0x23]`。

### axkvm_trace_vcpu_backend_state (L859–L867)

一行式 dump vCPU 关键后端态（mp_state/rip/cr0/cr3/cr4/efer/apic_base/lapic_id），用于 KVM_RUN boot 路径与进入后端时的诊断。

### axkvm_init_x86_vcpu_state (L869–L912)

新建 vCPU 时初始化 x86 影子态。核心难点是初始 `mp_state`（注释 L872–892，镜像 KVM `kvm_arch_vcpu_create`）：
- L893–896：`if (!irqchip_created || id==0) RUNNABLE; else UNINITIALIZED`。因为 KVM 要求 `KVM_CREATE_IRQCHIP` 在任何 vCPU 创建前完成，`irqchip_created` 此刻已定型，是 `irqchip_in_kernel` 的精确代理。对 gvisor 这类**用户态 irqchip**（`irqchip_created==false`），每个 vCPU（含 AP）预置 RUNNABLE、由 `KVM_SET_SREGS/REGS + KVM_RUN` 直接驱动，没有内核内 INIT/SIPI，所以 AP 绝不能起于 UNINITIALIZED（否则永等一个不会来的 SIPI）；Firecracker（`irqchip_created==true`）保留经典 AP 等 SIPI 模型。
- L897–911：rflags=0x2、FPU 默认（fcw=0x37f、mxcsr=0x1f80）、apic_base 置 enable 位（BSP 另加 BSP 位）、设 LAPIC id、LDT unusable、规整 sregs、xcr0=1、tsc_khz 默认值。

### axkvm_x86_xcr0_valid (L914–L945)

校验 guest 写入的 XCR0 合法性，镜像 VMX 对 XCR0 的约束：只允许已支持位（X87/SSE/AVX/BNDREGS/BNDCSR/OPMASK/ZMM_HI256/HI16_ZMM）；必须含 X87；AVX 依赖 SSE；BNDREGS 与 BNDCSR 必须同时置/清；AVX512 三位必须全置且依赖 SSE+AVX。用于 `KVM_SET_XCRS`。

### axkvm_irqfd_inject_work (L950–L969)

irqfd 注入的 workqueue 回调。校验 binding/vm 有效且 `backend_ready`，然后经路由表把 gsi 翻译成 pin，调 `axkvm_vm_queue_pending_irq` 排队（不直接注入——注入必须在 BSP 线程里做，见上）。累加 `inject_count` 并限流打印。

### axkvm_irqfd_wakeup (L971–L994)

irqfd 的 waitqueue 回调（eventfd 被 signal 时触发）。仅在 `EPOLLIN` 时：`eventfd_ctx_do_read` 取计数，非零则累加 `wake_count`、`schedule_work(irqfd_inject_work)` 把注入推给 workqueue。返回 1。

### axkvm_irqfd_poll_func (L996–L1004)

`vfs_poll` 注册回调：把 `binding->irqfd_wait` 挂到 eventfd 的 waitqueue 上，置 `irqfd_wait_registered`。

### axkvm_eventfd_binding_release (L1006–L1020)

释放一个 eventfd 绑定：irqfd 情况下先从 eventfd waitqueue 摘除 `irqfd_wait`，`flush_work` 等注入 work 跑完，`eventfd_ctx_put`，最后 memset 清零整个 binding。

### axkvm_vm_release_eventfds (L1022–L1035)

遍历释放所有 ioevents 与 irqfds 绑定。非 x86 是空实现。

### axkvm_memslot_release (L1037–L1067)

释放一个 memslot。难点是**惰性 fault-in 的稀疏 pages[] 处理**（注释 L1045–1052）：
- L1053–1060：只对非 NULL 的 `pages[i]`（真正 GUP-pin 过的 RAM）unpin；VM_IO/VM_PFNMAP remapped 的页 `pages[i]==NULL` 跳过；且只对 `writable` 位图置位的页标 dirty（只读 pin 不能报 dirty）。
- L1061–1066：`kvfree(pages)` + `bitmap_free(mapped/writable)` + 清零。

### axkvm_backend_unmap_memslot (L1069–L1076)

若后端就绪且槽有效有大小，调 `axvisor_kvm_backend_unmap_range` 拆掉该 GPA 区间在后端 EPT 里的映射。

### axkvm_vm_backend_state (L1079–L1103)

把 `struct axkvm_vm` 的 x86 影子态打包成 `struct axkvm_backend_vm_state` 传给后端：version/arch、irqchip/pit 创建标志、pit_flags、tss_addr、identity_map_addr，以及指向 clock/irqchips/pit_state 的指针。非 x86 只填 version + `ARCH_UNKNOWN`。这是 VM 级下行 ABI 边界。

### axkvm_check_extension (L1105–L1167)

`KVM_CHECK_EXTENSION` 实现：一大张 switch，声明本 shim 支持哪些 KVM_CAP。x86 下返回 1 的能力包括 IRQCHIP/SET_TSS_ADDR/EXT_CPUID/MP_STATE/IRQFD/PIT2/IOEVENTFD/ADJUST_CLOCK/VCPU_EVENTS/DEBUGREGS/XSAVE/XCRS/TSC_CONTROL 等；`IRQ_ROUTING` 返回最大路由数；`USER_MEMORY` 返回 1；`NR_MEMSLOTS`/`NR_VCPUS`/`MAX_VCPUS` 返回各自上限；`IMMEDIATE_EXIT` 返回 1；其余返回 0（不支持）。

### axkvm_vm_release_kref / axkvm_vm_get / axkvm_vm_put (L1169–L1198)

VM 引用计数与最终释放。`axkvm_vm_release_kref`（kref 归零回调）：先撤回诊断用的 lockless 句柄 `axkvm_dbg_vm`，再逐个 unmap+release memslot、释放 eventfds、`axvisor_kvm_backend_destroy_vm`，最后 `kfree`。get/put 是 `kref_get`/`kref_put` 薄封装。

### axkvm_register_backend_vm / axkvm_unregister_backend_vm (L1201–L1242)

把 VM 注册进/移出全局 `axkvm_backend_vm_registry[handle]`。持 `axkvm_backend_vm_registry_lock`（mutex）。注册时对 VM 取一个 kref（`axkvm_vm_get`）并用 `WRITE_ONCE` 发布（与无锁 wake 路径的 `READ_ONCE` 配对）；重复注册返回 `-EEXIST`。注销时仅当当前项确为本 VM 才清空并 `axkvm_vm_put`。

### axkvm_get_backend_vm (L1244–L1258)

**加锁版**注册表查询：持 mutex 查 handle，命中则取 kref 返回。供可睡眠上下文用（调用者用完须 `axkvm_vm_put`）。

### axkvm_lookup_backend_vm_locklessly (L1269–L1275)

**无锁版**注册表查询（注释 L1260–1268）：只 `READ_ONCE` 读指针、**不取 kref**。供原子/硬中断 wake 路径用——调用者只在 VM 已知存活期间（guest 运行期，注册表项只在 teardown 时清）触碰它，镜像 KVM kick 路径的无锁目标查找。

### axkvm_backend_timer_workfn (L1277–L1332)

后端 timer 的 workqueue 主体（进程上下文，可睡眠/取锁/分配）。
- L1282–1284：取当前 deadline（仅诊断打印用）。
- L1299：**先** `axvisor_kvm_x86_bridge_expire_all_due_timers()` 跨所有 per-vCPU 表 drain 到期 LAPIC timer，把每个到期 tick 精确投递给目标 vCPU（内部会 wake_vcpu）。这是超订下饿死 off-core vCPU 的 tick 兜底源。
- L1301–1331：遍历注册表所有 VM。**刻意不做 blanket wake**（注释 L1306–1320）：因为 expire_all 已精确投递，全体 wake 只会把没活干的 BSP+末位 AP 变成 HLT/wake 热自旋垄断空闲核、饿死 tick owner 使 jiffies 全局冻结。唯一保留的是 PIT 的 idle wake（`pit_created` 时 wake vcpu 0，因为 PIT 跑在此 timer 上且总指向 BSP，不被 per-vCPU LAPIC drain 覆盖）。随后调 `axkvm_vm_backstop_halted_vcpus` 做超订 HLT backstop。

### axkvm_backend_timer_cb (L1334–L1347)

一次性 hrtimer 回调（硬中断）：清 `axkvm_backend_timer_active`，把 workfn 派到专用 wq（或退回 `system_wq`），返回 `HRTIMER_NORESTART`。硬中断里不能干重活，只 queue_work。

### axkvm_backend_periodic_cb (L1356–L1464)

**独立周期 hrtimer 回调**——全局活性保证的核心（注释 L1349–1355）。与一次性 timer 不同，它自我前推、不会被忙碌 vCPU 的 re-arm 推后，所以是饿死 vCPU 的 LAPIC tick 的可靠 drain 触发源。
- L1358–1388：一批 debugcon witness 诊断（周期性向 QEMU port 0xe9 发 'H'/'h'，绕开 printk/console 判断"L1 serial 卡住"还是"承载此 hrtimer 的 L1 CPU 停收 timer 中断"）。
- L1390–1403：若 `periodic_kick_ns` 非零，遍历注册表对每个 VM 调 `axkvm_vm_periodic_kick_running_vcpus`（Scheme B 有界驻留打断）。
- L1405–1408：queue 主 workfn（drain-all）。
- L1410–1460：一批 bounded/one-shot 诊断（周期心跳、~20s 后一次性 dump per-vCPU 的 dbg_wake vs dbg_run_after_wake，用于 CALL_FUNCTION CSD 的 A-vs-B 判定；跑在硬中断里正因为 workfn/kworker 在 hang 期被 CFS 饿死不打印）。
- L1462–1463：`hrtimer_forward_now` 自我前推 `AXKVM_BACKEND_PERIODIC_NS`(250us)，返回 `HRTIMER_RESTART`。

### axvisor_kvm_x86_bridge_program_timer (L1466–L1487)

上行 ABI：后端请求编程一次性 timer。持 `axkvm_backend_timer_lock`，采用**只取更早**语义：仅当当前无 active timer 或新 deadline 更早时才更新并 `hrtimer_start`（ABS 模式）。`EXPORT_SYMBOL_GPL`。

### axvisor_kvm_x86_bridge_reprogram_timer (L1502–L1510)

上行 ABI：drain/register/cancel 后重编程全局最早 deadline。注释 L1489–1501 解释为何仍用"只取更早"而非精确"!= cur"：一个健康 always-running vCPU 每 ~500us re-arm，精确语义会让它把一次性 hrtimer 的到期无限推后使回调永不触发、drain workfn 饿死；全局活性改由自我前推的独立周期 hrtimer 保证。deadline 为 0 时转 cancel。

### axvisor_kvm_x86_bridge_cancel_timer (L1512–L1523)

上行 ABI：清 active/deadline 并 `hrtimer_cancel` 一次性 timer。

### axkvm_running_vcpu (per-CPU, L1534) + axkvm_wake_vcpu_target (L1546–L1566)

`axkvm_running_vcpu`（L1534）是"当前在本物理 CPU 跑 guest 的 vCPU"，进入后端前置、退出后清，让原子注入路径无锁找到发送方。

`axkvm_wake_vcpu_target` 向单个目标 vCPU 投递唤醒：置 `irq_pending_wakeup`，累加诊断计数，`wake_up_all` 唤醒 `halt_wq` 与 `mp_state_wq`。三个操作都原子上下文安全（`atomic_set` + waitqueue 自带 irqsave 自旋锁，无睡眠锁），镜像 KVM 原子安全 kick。另 L1564–1565 顺带唤醒 `spin_park_wq` 让被 park 的 spinner 立刻重判。调用者负责保活 vcpu 及其 VM。

### axkvm_wake_vcpu_in_vm (L1573–L1581)

可睡眠上下文的按 id 唤醒：持 `vm->lock` 后调 `axkvm_wake_vcpu_target`，以对齐 vCPU teardown。

### axvisor_kvm_x86_bridge_wake_vcpu (L1615–L1644)

上行 ABI 的**原子上下文 wake**——被 guest-APIC-write/inject_interrupt 路径（preempt/IRQ 关）与 off-core timer drain（workqueue/硬中断）共用。注释 L1583–1614 是关键：绝不能取睡眠锁（曾因此 `mutex_lock(&vm->lock)` → "scheduling while atomic" → run_vcpu ret=-16 → IPI 丢失）。目标解析（KVM 忠实、无锁）：
- L1627：优先用调用方传入的 handle 经**无锁**注册表查 VM——这是 timer-drain 回调的权威路径（那时本 CPU 没跑 guest，per-CPU sender 为 NULL，缺此会静默丢 wake = "wake-hole"，饿死 off-core vCPU 的 tick）。
- L1628–1633：否则退回 per-CPU 的 `axkvm_running_vcpu`（发送方 vCPU），它保活自己的 VM。
- L1642：无锁 `READ_ONCE(vm->vcpus[vcpu_id])` 后 `axkvm_wake_vcpu_target`（vcpus[] 数组在 VM 运行期稳定）。`EXPORT_SYMBOL_GPL`。

### axkvm_effective_ap_budget (L1656–L1679)

计算 AP 准入预算。注释 L1660–1674 是重要结论：`budget==0` 意为"立即准入所有 AP"（KVM 对齐模型）。因为 Linux 6.x 并行 bringup（`CONFIG_HOTPLUG_PARALLEL`）先一次性给所有 AP 发 INIT/SIPI（phase-1 CPUHP_BP_KICK_AP）再逐个 drain，一个准入线程数少于被 kick 数的节流会**死锁**（BSP 等一个从未准入线程的 CPU，而已准入 AP 在 `cpuhp_ap_sync_alive` 等 BSP）。所以默认全准入，靠软件 PLE 的 confirmed-spinner park 保持核轮转；非零 budget 仅作 legacy/串行调试开关（clamp 到 [1, VCPUS]）。

### axkvm_bringup_boost (L1694–L1712)

**超订并行 bringup 的决定性修复之一**：把 AP 的 KVM_RUN 线程 nice 降到 -20（`AXKVM_BRINGUP_NICE`），让 host 调度器给它有界延迟以在 BSP 的 ~10s 窗口内到达 `cpuhp_ap_sync_alive` 写 ALIVE。三重有界（注释 L1681–1693）：仅施于 admitted-but-not-ALIVE 的 AP；ALIVE/settle 时撤销；`boost_watchdog` 在 `AXKVM_BRINGUP_BOOST_MS`(300ms) 后强制撤销。经 refcounted `run_pid` 取 task，`set_user_nice` 后 `mod_delayed_work` 装 watchdog。

### axkvm_bringup_target_boost (L1723–L1756)

比上者更窄：只给 BSP 当前正等的那个 AP（`current_bringup_target`）加强 boost。注释 L1736–1743 记录了一次教训：SCHED_FIFO boost 被试过又回退（RT 的 AP 自旋会抢占 L1 自己的 `rcu_preempt`/`ksoftirqd` 反而恶化 RCU stall），所以留在 CFS：若该 AP 之前被 demote 成 SCHED_IDLE 先 `sched_set_normal` 撤销，再施最强 nice。

### axkvm_bringup_restore (L1764–L1781)

撤销 bringup boost：把线程恢复 `sched_set_normal(task, 0)`，清 `bringup_boosted`/`bringup_rt_boosted`/`spin_demoted`。幂等；不 cancel watchdog（teardown 路径显式 cancel）。

### axkvm_bringup_boost_watchdog (L1793–L1799)

delayed work 回调：AP 若永远自旋在 `cpuhp_ap_sync_alive`（错过窗口）不会到 HLT，会无限保持 nice -20 饿死 L1 内核线程；此 watchdog 在超时后强制 `axkvm_bringup_restore`。

### axkvm_spin_demote (L1820–L1838)

**超订核让渡原语**：把已确认自旋（guest RIP 长时间不动，如 `cpuhp_ap_sync_alive`）的 vCPU 线程降为 `SCHED_IDLE`（注释 L1801–1819）。此布局下 `yield()`/`cond_resched()`/裸 `schedule()` 都是 no-op、`yield_to()` 返回 -ESRCH，而 block-park 会把整 L1 冻死（离开 CFS 均衡集）。SCHED_IDLE 是折中：spinner 仍 RUNNABLE 但低于所有 NORMAL/RT，一旦 nice-boosted 的 BSP/兄弟被放到此核就立刻抢占它。经 `run_pid` 取 task、`sched_setattr_nocheck`。幂等；恢复靠 RIP 驱动（非 timer/work，后者本身在此 wedge 下被饿死）。

### axkvm_spin_restore (L1846–L1861)

撤销 spin_demote：恢复 `sched_set_normal(task, 0)`，清 `spin_demoted`。RIP 离开自旋窗口（真前进）/HLT/teardown 时调。

### axkvm_spin_park (L1888–L1911)

把已确认 spinner **真正移出 runqueue**（非 runnable），使空出的核走 newidle-balance 从别的 rq 拉饿死的兄弟——此布局下唯一真能迁移工作的机制（注释 L1863–1887）。**只在调用方已 drop migrate_disable 且卸载 VMCS 后才安全**（老 block-park 正是在 migrate_disable 窗口里 block 冻死 L1）。
- L1892：置 `spin_parked`。
- L1899–1905：`wait_event_interruptible_timeout` 在 `spin_park_wq` 上等，唤醒条件为 gen 变化 / `irq_pending_wakeup`（用 `atomic_read` 而非 xchg，避免与 HLT wait 这个唯一消费者竞争）/ immediate_exit / signal；超时 1 jiffy（`AXKVM_SPIN_PARK_TIMEOUT_JIFFIES`，线程上下文超时而非硬中断 wake，不会饿死 L1 timer-softirq）。
- L1906–1910：清 `spin_parked`；immediate_exit/signal 返回 -EINTR，否则 0（核已让出）。

### axkvm_wake_parked_spinners (L1915–L1919)

持 `vm->lock` 调用：`spin_park_gen++` 后 `wake_up_all(spin_park_wq)`，让所有 parked spinner 重判 gate。

### axkvm_yield_to_vcpu_diag / axkvm_yield_to_vcpu (L1940–L1965)

直接把当前物理 CPU 让给某目标 vCPU 的 KVM_RUN 线程。`_diag` 版返回诊断码（>0 boosted；0 无目标；-1 无 task；-2 yield_to 返 0；-3 yield_to 返负），经 refcounted `run_pid` 解析 task、`yield_to(task, true)`。非诊断版是"是否 boosted"的布尔封装。供 PLE directed-yield 与 CPU_UP 路径用。

### axvisor_kvm_x86_bridge_boost_vcpu (L1989–L2008)

上行 ABI：记录一个**延迟的 directed-yield 提示**（IPI-boost）。必须能在原子注入路径（preempt/IRQ 关）里调用，所以**不加锁、不查注册表、不调度**——只在**发送方 vCPU**（`this_cpu_read(axkvm_running_vcpu)`）上存一个整数 `boost_target=(目标id+1)`。真正的 `yield_to()` 推迟到发送方运行循环安全点（`axkvm_vcpu_drain_boost`）执行。注释 L1979–1985 给出依据：SMP 起来后 guest 在 vCPU 间发 call-function/reschedule IPI，目标常 HALTED 或 RUNNABLE-but-preempted，CFS 摊开使其 off-core 久到 CSD-lock 超时并 NMI"无响应"目标。`EXPORT_SYMBOL_GPL`。

### axkvm_vcpu_drain_boost (L2018–L2059)

在发送方运行循环安全点排空 boost 提示：`atomic_xchg` 取出 target id，仅超订时（`nr_vcpus > online`）才真 `yield_to`。经 refcounted `run_pid` 在 RCU 外解析 task 后 `yield_to(task, true)`。非超订时纯 wake 已足够，多余 yield 只增开销。

### axkvm_wake_boost_vcpu / axkvm_wake_boost_bringup_target (L2071–L2107)

**软件 directed-yield**：`yield_to` 在超订下（spinner 与 target 各占一核，rq->nr_running==1）会失败返 -ESRCH；这两个函数改为 `wake_up_process(task)` 让目标 runnable 再叠一层 nice boost（复用 `axkvm_bringup_boost`/`axkvm_bringup_target_boost` 的有界/watchdog 撤销机制），偏斜 CFS 权重使当前 spinner park 让核后 CFS 优先跑目标。后者专用于 `current_bringup_target`（更强的 target boost）。

### axkvm_admit_next_ap (L2116–L2139)

在 budget 允许下准入队列里下一个 AP。持 `vm->lock`。**严格按 BSP kick 顺序（FIFO）**准入（注释 L2109–2114）：boot CPU 按 cpu number 等待各 AP，乱序准入会启动一个仍被 hold 的 AP 的 10s 窗口。循环：从 `ap_boot_queue_head` 取 id，`head++`，仅对 `AP_BOOT_KICKED` 的置 `AP_BOOT_ADMITTED`、`ap_admitted++`、`axkvm_bringup_boost`、唤醒 `admit_wq`、`axkvm_yield_to_vcpu`。末尾 `axkvm_wake_parked_spinners`（新准入是 bringup 进展，让空核可被拉给它）。

### axkvm_ap_enqueue (L2147–L2156)

记录一次 CPU_UP：仅对 `AP_BOOT_NONE` 的 AP 置 `AP_BOOT_KICKED`、按 kick 顺序入 `ap_boot_queue`、`tail++`，再 `axkvm_admit_next_ap` 试准入。持 `vm->lock`。若无法立即准入（budget 满），其 KVM_RUN 线程会阻塞在 `axkvm_ap_wait_admitted`。

### axkvm_ap_settle (L2163–L2199)

标记 AP 为 settled（观察到首个 HLT ⇒ 保证完全 online）。注释 L2168–2180 是关键决策：**只在 SETTLED（首 HLT）而非 ALIVE 时**释放 budget + 撤 boost。因为到达 `cpuhp_ap_sync_alive`（ALIVE）的 AP 还没完全 online（还要完成 SHOULD_ONLINE 握手、per-CPU init、进 idle loop）；在 ALIVE 就撤 boost 并准入竞争者会饿死该 AP，导致后续 BSP 的 `smp_call_function_many_cond` 永等其 CSD ack（曾观察到 ~HugeTLB init 处运行期冻结）。
- L2181–2198：`ADMITTED`/`ALIVE` → `SETTLED`；`ap_admitted--`；若 `current_bringup_target==id` 则清为 -1（否则会永久 latch 在末位 AP）；`axkvm_bringup_restore` + `axkvm_admit_next_ap`。

### axkvm_ap_mark_alive (L2201–L2214)

把 `AP_BOOT_ADMITTED` 的 AP 标为 `AP_BOOT_ALIVE`，但**保留** budget 与 boost 到 settle（原因同上）。返回是否成功标记。

### axvisor_kvm_x86_bridge_note_ap_alive_spin (L2216–L2245)

上行 ABI：后端报告某 AP 的 guest RIP 命中"ALIVE 自旋点"（由模块参数 `ap_alive_spin_rip` 指定，0 禁用）。若匹配：加锁标 ALIVE（`axkvm_ap_mark_alive`），取 `boot_controller_id`，随后（解锁后）`axkvm_yield_to_vcpu(controller)`——自旋的 AP 直接把核让给它在等的 controller（BSP）。`EXPORT_SYMBOL_GPL`。

### axkvm_ap_wait_admitted (L2253–L2273)

阻塞 AP 的 KVM_RUN 线程直到被准入（脱离 KICKED）。**不持 `vm->lock`**。`wait_event_interruptible` 在 `admit_wq` 上等 `boot_state != KICKED || immediate_exit`；signal/immediate_exit 返 -EINTR，被准入返 0；从未入队（state 仍 NONE）立即返回。

### axkvm_div_frac (L2289–L2295) / axkvm_pvclock_time_scale (L2300–L2331)

pvclock 定点数辅助。`axkvm_div_frac` 算 `(dividend<<32)/divisor`。`axkvm_pvclock_time_scale` 从 guest TSC 频率推出 pvclock 的 `tsc_shift`/`tsc_to_system_mul`，使缩放后的 TSC ticks 映射到纳秒，镜像 KVM `kvm_get_time_scale()`（scaled_hz=NSEC_PER_SEC，base_hz=tsc_hz）。

### axkvm_gpa_to_hva (L2338–L2355)

把 GPA 翻译成 backing 的用户态虚拟地址，并确认 len 字节落在单个 memslot 内。遍历 memslots 找覆盖区间，`*hva = userspace_addr + (gpa - guest_phys_addr)`。持 `vm->lock`。找不到返 -EFAULT。

### axkvm_map_flags (L2363–L2370)

算 fault-in 的后端 map flags：默认 RWX，`!writable` 时叠 `AXKVM_MAP_RDONLY`(BIT(31)) 使后端装只读 EPT 叶。`AXKVM_MAP_RDONLY` 放 BIT(31) 避免与 `KVM_MEM_*` 低位冲突。

### axkvm_resolve_remapped_pfn_locked (L2388–L2432)

把 VM_IO/VM_PFNMAP 的 HVA 解析成裸 PFN，镜像 KVM `hva_to_pfn_remapped`（GUP 直接拒绝 VM_IO|VM_PFNMAP，gvisor sentry vvar 类恒等映射只能这样解析）。**必须持 `mmap_read_lock` 且 vma 来自同一加锁查找**。
- L2396–2414：`follow_pfnmap_start`；失败则 `fixup_user_fault` 显式触发缺页（GUP 不会为 VM_IO/PFNMAP 调 fault handler），若期间 mmap 锁被放开（`unlocked`）返 -EAGAIN 让调用方重查 vma，否则重试 `follow_pfnmap_start`。
- L2416–2424：写 fault 但 PFN 不可写 → -EFAULT（KVM 会返 RO_FAULT 并模拟，本 shim 无此路径故 abort）。
- L2426–2431：拷出 `hpa`/`writable`（须在 `follow_pfnmap_end` 前，之后 args 失效），`follow_pfnmap_end`。

### axkvm_gpa_has_slot (L2468–L2491)

**无锁**判断某 GPA 是否被已注册 memslot 覆盖（注释 L2455–2467）：与 `axkvm_fault_in_gpa` 取 vm->lock 前的数组扫描相同，但不碰 pin/map 状态、不睡眠，所以 Rust `run_vcpu_raw` loop 能在 `kernel_fpu`（preempt+BH 关）窗口里调用它来判 slot-vs-MMIO（memslot 数组只在 `KVM_SET_USER_MEMORY_REGION` 变更，与 KVM_RUN 由 VM ioctl 路径串行化）。命中区间且该页 idx 在 `nr_pages` 内返 true。

### axkvm_fault_in_gpa (L2493–L2639)

**惰性按需 fault-in 单个 guest 页并插入后端 EPT**——gvisor 巨大稀疏 memslot 的核心机制（注释 L2434–2454）。持 `vm->lock`。
- L2502–2526：扫 memslots 找覆盖 `aligned` 的槽；找不到槽或槽无 pages 返 **-ENOENT**（区别于真 fault 错误——调用方据此把 slotless GPA 当 MMIO decode，镜像 KVM `kvm_faultin_pfn`）。
- L2528–2540：算页 idx；`idx>=nr_pages` 返 -ENOENT；若 `mapped` 位已置（竞争/re-fault）：写但只读叶返 -EFAULT，否则返 0（已装好）。
- L2542–2568：**快路径**——普通 GUP-able RAM。`pin_user_pages_fast(hva, 1, FOLL_WRITE, &page)`（注释 L2544–2553：写意图必须与 EPT 可写性一致，否则可能 pin 到共享零页再映成可写让 guest 写绕过 COW 落错物理页；刻意去掉 `FOLL_LONGTERM`）。成功则 `axvisor_kvm_backend_map_page_nolog` 映入 EPT、记 `pages[idx]`、置 `writable`/`mapped` 位、返 0。
- L2570–2605：GUP 失败 → 查 VMA。VM_IO/VM_PFNMAP：走 `axkvm_resolve_remapped_pfn_locked`（-EAGAIN 则 retry），映裸 hpa 入 EPT，只置位图不记 pages[]（无 struct page）。
- L2607–2633：只读 VMA（如 file-backed guest kernel text）：写 fault 无法满足返 -EFAULT；读 fault 退回只读 pin（`pin_user_pages_fast(hva,1,0,&page)`）+ 只读 EPT 叶。
- L2635–2638：其余为真 fault-in 失败，`pr_info_ratelimited` 后返错误码（须 abort run）。

### axkvm_pvclock_capture_master (L2652–L2673)

**一次性**捕获 VM 级 `(host_tsc, kernel_ns)` master 对，镜像 KVM `pvclock_update_vm_gtod_copy`。`ktime_get_snapshot` 在 timekeeper seqlock 下同一瞬读 clocksource 计数与 boot 纳秒，保证内部一致。每个 vCPU 都从这单一对派生 pvclock 页，使所有页跨核互为单调——断言 `PVCLOCK_TSC_STABLE_BIT` 的前提。L2671：仅当 host clocksource 就是 TSC（`cs_id==CSID_X86_TSC`）才标 stable，否则 `.cycles` 非裸 TSC，断言 STABLE 会撒谎重新引入跨 vCPU 偏斜致 RCU stall。`master_valid` 守一次性捕获。

### axkvm_pvclock_refresh (L2681–L2737)

刷新某 vCPU 的 `pvclock_vcpu_time_info` 页。**必须在该 vCPU 自己的 KVM_RUN 线程里跑**（`current->mm` 映射 guest 内存供 `copy_to_user`）。持 `vcpu->lock`，内部取 `vm->lock` 查 memslot。
- L2691–2703：未启用 kvm-clock 直接返回；`gpa_to_hva` + `capture_master`，快照 master 对。
- L2705–2727：算 time_scale；**版本协议**（更新前置奇、后置偶，guest 见奇或读期间变化就重试）；从 VM 级 master 对（非 per-core rdtsc）派生 `tsc_timestamp`/`system_time`/`flags`，保证每 vCPU 页用同一锚点跨核单调。
- L2729–2736：`copy_to_user` 写整个 pvti，再第二次（偶版本）写 version 让 guest 见到 settled 页。

### axkvm_pvclock_write_wall_clock (L2740–L2762)

写 VM 级 `pvclock_wall_clock` 页（boot wall-clock 参考）。`gpa_to_hva` 后算 `wall = realtime - boottime`（即 system_time 为 0 时的墙钟），填 version=1/sec/nsec，`copy_to_user`。

### axvisor_kvm_x86_bridge_pvclock_write (L2769–L2797)

上行 ABI：guest 写 pvclock MSR（被拦的 MSR_WRITE VM-exit），在 vCPU 自己线程里调。`MSR_KVM_SYSTEM_TIME_NEW`：持 `vcpu->lock` 记 raw MSR、`pvclock_enabled`(bit0)、`pvclock_gpa`(掩 enable 位与页对齐)，启用则 refresh。`MSR_KVM_WALL_CLOCK_NEW`：记 VM 级 `pvclock_wall_clock_gpa` 并写墙钟页。

### axvisor_kvm_x86_bridge_pvclock_refresh (L2804–L2818)

上行 ABI：KVM_RUN entry 时刷新 vCPU pvclock 页，使 system_time 单调推进（即便 guest 不重写 MSR）。持 `vcpu->lock` 调 `axkvm_pvclock_refresh`。

### axvisor_kvm_x86_bridge_directed_yield (L2853–L3040)

上行 ABI 的 **软件 PLE directed-yield**，镜像 KVM `kvm_vcpu_on_spin`。当前 vCPU 在单次 KVM_RUN 里自旋够久（软件 PLE；此 nested setup 下硬件 PLE 不可用）时由 bridge run loop 调用。**拓扑感知**的目标选择（注释 L2820–2851）：
- L2887–2905（Priority 0）：BSP 当前正等的 AP（`current_bringup_target`）。串行 bringup 下整握手都堵在这个 AP 拿核上；`yield_to` 成功则 boosted，否则记 `dir_idx`。这是让 1.8x 超订能 boot 的关键。
- L2922–2936（Priority 1）：自旋的 AP 把核让给它在等的 boot controller——**仅在 bringup 仍在进行时**才对（`current_bringup_target>=0`）。注释 L2907–2921 记录 bug：`boot_controller_id` bringup 后永久 latch 到 BSP，若不 gate 会 post-bringup 把每个 park 错误导向已在核上自旋的 BSP，饿死 runnable band。
- L2938–2969（Priority 2）：对 RUNNABLE 兄弟轮询（`last_boosted_vcpu` 游标），镜像 KVM 的 round-robin；记 `runnable_seen`/`dir_idx`，成功则更新游标 + boosted。
- L2978–3035：解锁前抓 `dir` 指针（vcpus[] 在锁下稳定，真正 wake/boost/park 须在解锁后，因 `set_user_nice`/`schedule_timeout` 不能持 mutex）。未 boosted 时按 `dir_is_bringup_target` 选 `wake_boost_bringup_target` 或 `wake_boost_vcpu` 偏斜 CFS；并旋转 `last_boosted_vcpu` 以铺开 park。
- **返回 `should_park`**（L3020–3034）：仅当未 boosted 且（有 directed target 或 `runnable_seen>0`）时返 true，告诉调用方（Rust `soft_ple_maybe_park`）值得 park 让核；BSP 单线程早期 boot 独自自旋（无 peer）时返 false 保住其核。`EXPORT_SYMBOL_GPL`。

### axvisor_kvm_x86_bridge_spin_demote / _spin_restore (L3051–L3096)

上行 ABI 薄封装：用无锁注册表（或 per-CPU sender）解析 VM 后调 `axkvm_spin_demote`/`axkvm_spin_restore`。demote 版额外守 `current_bringup_target==vcpu_id` 时不 demote（正被等的 AP 不该降级）。`EXPORT_SYMBOL_GPL`。

### axvisor_kvm_x86_bridge_spin_park (L3119–L3163)

上行 ABI：把非关键 AP park 出 runqueue 让核。Rust run loop 在超订分支、**drop migrate_disable + 卸载 VMCS 后**（唯一可 block 的安全点）调用。
- L3139–3153：持 `vm->lock` 重查资格：`current_bringup_target>=0`（bringup 进行中）时**不 park**（注释 L3107–3110，bringup 期 park 非 target AP 会把它移出 CFS 均衡集，曾观察到 AP 被搁置数秒）；资格 = vcpu 就绪 && 非 controller && `confirmed_spinner`（`spin_demoted`）。
- L3155–3161：block 在锁外（`axkvm_spin_park`）；返回 1（已 park+woken，核已让出，调用方跳过 schedule_now）/ 0（不合格，回退 schedule_now）/ -EINTR（abort）。`EXPORT_SYMBOL_GPL`。

### axvisor_kvm_x86_bridge_signal_pending (L3172–L3176)

诊断上行 ABI：返回调用 KVM_RUN 线程是否有 pending signal。用于 gvisor SIGURG bounce signal 可中断性的探针。

### axvisor_kvm_x86_bridge_fault_in_gpa (L3184–L3212)

上行 ABI：Rust NestedPageFault handler 的 fault-in 入口。`WARN_ON_ONCE(preempt_count() || irqs_disabled())`（L3195，诊断：证明 fault-in 已移出原子窗口，因下面要取睡眠锁 `vm->lock`）。无锁注册表（或 per-CPU sender）解析 VM 后持 `vm->lock` 调 `axkvm_fault_in_gpa`。返回 0 或负 errno。`EXPORT_SYMBOL_GPL`。

### axvisor_kvm_x86_bridge_gpa_has_slot (L3221–L3237)

上行 ABI：`run_vcpu_raw` 的无锁 slot 覆盖探针。解析 VM 后调 `axkvm_gpa_has_slot`，返 1（有 slot，调用方应抛 NestedPageFault 让外层 loop pin+map）/ 0（slotless，调用方在 VMCS 仍绑定时按 MMIO decode）。不取睡眠锁，`kernel_fpu` 窗口内安全。`EXPORT_SYMBOL_GPL`。

### axkvm_vcpu_release_kref / axkvm_vcpu_put (L3240–L3261)

vCPU 引用归零回调：`backend_ready` 则 `destroy_vcpu`；释放 `run_pages`；x86 下 `cancel_delayed_work_sync(boost_watchdog)` + `axkvm_spin_restore`（保证不留 SCHED_IDLE 残留）+ `put_pid(run_pid)`；`axkvm_vm_put(vm)`（vCPU 持有对 VM 的引用）；`kfree`。

### axkvm_fill_fail_entry (L3263–L3274) / axkvm_fill_internal_error (L3276–L3288)

填 `kvm_run` 出口结构的样板：先保存 `request_interrupt_window`/`immediate_exit`、memset 清零 run、恢复这两字段，再设 `exit_reason`。fail_entry 填 `KVM_EXIT_FAIL_ENTRY` + hardware reason + cpu；internal_error 填 `KVM_EXIT_INTERNAL_ERROR` + `data[0]=err`。

### axkvm_ioeventfd_data_mask (L3291–L3305) / axkvm_ioeventfd_match (L3307–L3325)

ioeventfd 匹配。mask 按 width 返回 U8/U16/U32/U64_MAX。match：binding 有效、非 PIO、addr 相等、len 匹配；无 DATAMATCH 标志即匹配，否则按 mask 比较 `datamatch ^ data`。

### axkvm_signal_ioeventfd (L3327–L3362)

MMIO_WRITE 出口时扫 ioevents 找匹配 binding：命中则 `eventfd_signal(binding->ctx)` 通知 VMM 设备线程、累加计数、返回已 signal。持 `vm->lock`；`eventfd_signal_allowed()` 门控。非 x86 恒返 false。

### axkvm_handle_cpu_up (L3364–L3447)

处理后端的 `AXKVM_BACKEND_EXIT_CPU_UP`（in-kernel LAPIC/SIPI 副作用，Firecracker 路径）。
- L3375–3390：记 `boot_controller_id = source->id`；按目标 LAPIC id 找 target vCPU。
- L3392–3397：找不到 target → internal_error + -ENOENT。
- L3417–3429：持 `vm->lock` `axkvm_ap_enqueue(target)`（注释 L3412–3415：enqueue 必须在 wake mp_state_wq 前，因 AP 线程见 RUNNABLE 后立刻查 boot_state）；记 `current_bringup_target=target->id`；`axkvm_wake_parked_spinners`。
- L3431–3444：持 `target->lock` 置 target `mp_state=RUNNABLE`（**不**标 backend_state_dirty，注释 L3433–3437：Rust bridge 已从 SIPI 重建 AP VMCS，重放初始态会覆盖实模式 trampoline）；`wake_up_all(mp_state_wq)` + `axkvm_wake_boost_bringup_target`。返回 1（消费了此 exit）。非 x86 恒返 0。

### axkvm_translate_backend_exit (L3462–L3547)

把后端 `axkvm_backend_exit` 翻译成 `kvm_run` 的 KVM ABI 出口——**核心 ABI 边界**。先保存/清/恢复 run 头字段与清 pending read 标志，再 switch exit->reason：
- MMIO_READ/WRITE：填 `KVM_EXIT_MMIO`（phys_addr/len/is_write），READ 置 `pending_mmio_read`，WRITE 拷 data。width 越界 → internal_error。
- IO_READ/WRITE：填 `KVM_EXIT_IO`（direction/size/port/count，data_offset=`sizeof(*run)`），READ 置 `pending_io_read`，WRITE 拷 data 到 run 尾部。
- HLT → `KVM_EXIT_HLT`；SHUTDOWN → `KVM_EXIT_SHUTDOWN`；FAIL_ENTRY → `axkvm_fill_fail_entry`；default → internal_error -EIO。

### axkvm_vcpu_backend_state (L3550–L3598)

把 vCPU 全部 x86 影子态打包成 `axkvm_backend_vcpu_state` 传后端：rip/rsp/rflags/cr0-4/efer/apic_base、xcr0（从 xcrs[0] 取）、以及指向 regs/sregs/fpu/lapic/mp_state/debugregs/xsave/xcrs/events/cpuid/msrs 的指针 + nent/nmsrs/tsc_khz。非 x86 只填 version+ARCH_UNKNOWN。vCPU 级下行 ABI 边界。

### axkvm_vcpu_sync_backend_state (L3600–L3631)

把 vCPU 影子态同步到后端。`!backend_ready` 直接返 0。x86 下持 `vcpu->lock`：`!force && !backend_state_dirty` 跳过；否则打包（在锁内）后解锁调 `axvisor_kvm_backend_set_vcpu_state`（`-EOPNOTSUPP` 容忍），成功后清 `backend_state_dirty`。

### axkvm_vm_sync_all_vcpu_backend_states_locked (L3633–L3651)

遍历所有 vCPU 调 `axkvm_vcpu_sync_backend_state(force)`，任一失败即返回错误。VM boot 时用（force=true）。

### axkvm_vcpu_complete_pending_reads (L3653–L3690)

上一次 KVM_RUN 返回 MMIO/IO READ 出口、userspace 填好 data 后重入 KVM_RUN 时，把结果回灌后端。`pending_mmio_read` → `axvisor_kvm_backend_complete_mmio_read`（从 `run->mmio.data`）；`pending_io_read` → `axvisor_kvm_backend_complete_io_read`（从 run 尾部 offset）。清 pending 标志；失败填 internal_error 返错误。

### axkvm_vcpu_run_backend_unmasked (L3692–L4038)

**KVM_RUN 的主体运行循环**（信号掩码已在外层激活）。
- L3699–3710：immediate_exit/signal 早退 -EINTR；`!backend_ready` 填 fail_entry；`complete_pending_reads` 回灌上次读结果。
- L3712–3744（x86）：若 `mp_state==UNINITIALIZED`（AP 等 SIPI），`wait_event_interruptible` 在 `mp_state_wq` 上循环等 RUNNABLE/immediate_exit；signal/immediate_exit 返 -EINTR。
- L3753–3755：`axkvm_ap_wait_admitted`（SMP bringup 准入节流；BSP 与非节流 AP 立即返回）。
- L3757–3797：首次运行（`!backend_booted`，持 `vm->lock`）：`set_vm_state` → `sync_all_vcpu_backend_states(force)` → `axvisor_kvm_backend_boot_vm` → 置 `backend_booted`。任一失败填 internal_error 返 0。
- L3799–3805：`sync_backend_state(force=false)` 同步本 vCPU 脏态。
- L3807–4031：**核心 for(;;) 循环**：
  - L3808–3810：每轮查 immediate_exit/signal 早退。
  - L3812–3816：`axkvm_vcpu_drain_pending_irqs`（仅 BSP 真 drain）。
  - L3823：`axkvm_vcpu_drain_boost`（安全点，把上轮原子注入记的 IPI-boost 转成真 yield_to）。
  - L3844–3846：**ABI 边界的关键三行**——`this_cpu_write(axkvm_running_vcpu, vcpu)` 发布运行中 vCPU、`axvisor_kvm_backend_run_vcpu(&exit)` 进 guest、返回后清 per-CPU。后端在 guest run 周围关 preempt，故 per-CPU 值一致。
  - L3855–3879：诊断（前几次 exit 的 IRQ/preempt 态；HLT exit 时对比 backend RIP vs cached regs.rip）。
  - L3880–3889：run_vcpu 失败 → `-EOPNOTSUPP` 填 fail_entry，否则 internal_error，返 0。
  - L3891–3907：`axkvm_handle_cpu_up`（>0 表示消费了 CPU_UP，`backend_cpu_ups++` 后 `axkvm_backend_schedule_point()` 让核并 continue）。
  - L3909–4019：**HLT 分派**（镜像 KVM `__kvm_emulate_halt`，注释 L3910–3936）：
    - L3937–3938：**用户态 irqchip**（`!irqchip_created`，如 gvisor）：直接 `break` 出循环把 HLT 翻成 `KVM_EXIT_HLT` 交 userspace（不 poll/block，否则会永等一个不存在的内核内 wake 源）。
    - L3956–3958：**in-kernel irqchip**（Firecracker）：首个 HLT 即 `axkvm_ap_settle`（保证过 ALIVE 完全 online，释放 budget）。
    - L3974–4001：KVM 式 halt-poll——`AXKVM_HALT_POLL_ITERS`(4000) 次忙 poll，但门控于 `single_task_running() && !need_resched()`（镜像 `kvm_vcpu_can_poll`，超订下核有竞争或置了 NEED_RESCHED 立即退出 poll 去 block 让核）。
    - L4010–4018：置 `in_halt_wait=1`，`wait_event_interruptible_timeout` 在 `halt_wq` 等（`atomic_xchg(irq_pending_wakeup)`/immediate_exit/signal），超时 `AXKVM_HALT_BLOCK_TIMEOUT_JIFFIES`(1 jiffy) 兜底；清 `in_halt_wait`，continue。
  - L4021–4030：非 HLT 出口若匹配 ioeventfd（`axkvm_signal_ioeventfd`）则 signal 后让核并返 -EINTR（把设备请求交 VMM 线程）；否则 `break`。
- L4033–4037：`axkvm_translate_backend_exit` 把出口翻成 KVM ABI，internal_error 时 `pr_err`。

### axkvm_vcpu_set_signal_mask (L4040–L4067)

`KVM_SET_SIGNAL_MASK`：argp 为 NULL 清 `signal_mask_valid`；否则拷 `kvm_signal_mask` 头（校验 len==sizeof(sigset_t)）+ sigset，删去 SIGKILL/SIGSTOP，存 `signal_mask` 并置 valid。

### axkvm_vcpu_sigset_activate (L4069–L4079) / axkvm_vcpu_sigset_deactivate (L4081–L4088)

KVM_RUN 期间临时换上 guest 指定的信号掩码。activate：`sigprocmask(SIG_SETMASK, &vcpu->signal_mask, &current->real_blocked)` 存旧掩码，返回是否激活。deactivate：恢复 `real_blocked` 并清空。这是 KVM `KVM_SET_SIGNAL_MASK` 语义（run 期间让特定信号可中断 KVM_RUN）。

### axkvm_vcpu_run_backend (L4090–L4128)

KVM_RUN 的外层包装。x86 下：更新 `run_pid`（refcounted，供 directed yield）；若启用 kvm-clock，进 guest 前在本线程刷新 pvclock 页（`current->mm` 映射 guest 内存）。然后 activate 信号掩码 → `axkvm_vcpu_run_backend_unmasked` → deactivate。

### axkvm_copy_cpuid_to_user (L4131–L4152)

CPUID2 回拷辅助：读 user 头的 nent，写回真实 nent，`user_nent < nent` 返 -E2BIG，拷 entries 数组。

### axkvm_get_supported_cpuid (L4154–L4351)

`KVM_GET_SUPPORTED_CPUID`：返回一张硬编码的 `kvm_cpuid_entry2[]`（模拟一颗 Intel Core i7 类 CPU 的 leaf 0x0/0x1/0x2/0x4/0x6/0x7/0xa/0xb/0xd/0x15/0x16/0x8000000x）。要点：
- L4168–4177（leaf 0x1 ECX）：**刻意不广告 BIT(24)=TSC_DEADLINE**——guest LAPIC TSC-deadline timer（经 WRMSR 0x6E0 arm）尚未虚拟化，逼 guest 回退到已实现的 APIC_TMICT one-shot 路径。
- L4329–4347：**刻意移除 kvm-clock（pvclock）广告**——per-vCPU pvclock 页只在各自 KVM_RUN 线程刷新，halted vCPU 页会 stale + 跨核 rdtsc 不一致，现代 guest 的 clocksource watchdog 会判 TSC unstable 卡死 RCU（4 vCPU 无超订即复现）。原 LAPIC 周期 timer bug 已修，guest 用原生 TSC/PIT/HPET 即可 boot，pvclock 变健壮前不重开。

### axkvm_get_msr_index_list (L4353–L4374)

`KVM_GET_MSR_INDEX_LIST`：回拷 `axkvm_default_msr_indices[]`（L250–271 定义的一组常用 MSR），逻辑同 CPUID（写回真实 nmsrs，`user_nmsrs < nmsrs` 返 -E2BIG）。

### VM 级简单 ioctl 处理器 (L4376–L4502)

一组持 `vm->lock` 读写 VM 影子态的短函数：
- `axkvm_vm_create_irqchip` (L4376)：置 `irqchip_created=true`（`KVM_CREATE_IRQCHIP`）。
- `axkvm_vm_create_pit2` (L4384)：校验 flags、置 `pit_created`/`pit_flags`、清 pit_state（`KVM_CREATE_PIT2`）。
- `axkvm_vm_set_identity_map_addr` (L4403)：记 `identity_map_addr`。
- `axkvm_vm_get_clock`/`set_clock` (L4417/L4428)：读写 `vm->clock`。
- `axkvm_vm_get_irqchip`/`set_irqchip` (L4441/L4457)：读写 `vm->irqchips[chip_id]`（校验 chip_id）。
- `axkvm_vm_get_pit2`/`set_pit2` (L4472/L4483)：读写 `vm->pit_state`。
- `axkvm_vm_set_tss_addr` (L4496)：记 `tss_addr`。

### axkvm_vm_ioeventfd (L4504–L4582)

`KVM_IOEVENTFD`：拷 `kvm_ioeventfd`、校验 flags/len；非 DEASSIGN 则 `eventfd_ctx_fdget`。持 `vm->lock` 扫 `ioevents[]`：找匹配项则 DEASSIGN 释放 / 否则 -EEXIST；无匹配且非 DEASSIGN 则填入空槽（记 addr/datamatch/len/flags/fd + 清计数），无空槽 -ENOSPC。末尾未消费的 ctx `eventfd_ctx_put`。

### axkvm_vm_irqfd (L4584–L4676)

`KVM_IRQFD`：拷 `kvm_irqfd`、校验 flags（RESAMPLE 返 -EOPNOTSUPP）；`eventfd_fget` + `eventfd_ctx_fileget`。持 `vm->lock` 扫 `irqfds[]`：匹配则 DEASSIGN 释放 / 否则 -EBUSY；否则填空槽（记 ctx/vm/irqfd/fd/gsi/flags/resamplefd、`INIT_WORK(irqfd_inject_work)`、`init_waitqueue_func_entry(irqfd_wakeup)`、`init_poll_funcptr(irqfd_poll_func)`、置 valid），`vfs_poll` 挂到 eventfd waitqueue，若已有 EPOLLIN 立即 schedule 注入 work。out：`fput(file)`。

### axkvm_vm_set_gsi_routing (L4678–L4773)

`KVM_SET_GSI_ROUTING`：拷头校验（flags 须 0、nr ≤ 上限），`kvcalloc` 新路由表，`memdup_user` 拷全部 entries。逐条校验（gsi 越界 -EINVAL；仅接受 `KVM_IRQ_ROUTING_IRQCHIP` type，否则 -EOPNOTSUPP），按 irqchip 类型（IOAPIC/PIC_MASTER/PIC_SLAVE）校验 pin 并填 `new_routes`。全部合法后持 `vm->lock` `memcpy` 覆盖 `vm->irq_routes`。

### axkvm_vcpu_copy_cpuid_from_user (L4775–L4812)

`KVM_SET_CPUID2` 拷入：校验 nent ≤ 上限、拷 entries、记 `cpuid_nent`。L4800–4809：**清 leaf 0x1 ECX BIT(24) TSC_DEADLINE**（Firecracker 逐字拷不 sanitize，此处逼 guest 回退 APIC_TMICT，因 WRMSR 0x6E0 路径未虚拟化会被通用 MSR handler 吞）。

### axkvm_vcpu_copy_cpuid_to_user (L4814–L4819)

`KVM_GET_CPUID2`：回拷 `vcpu->cpuid_entries`。

### axkvm_vcpu_find_msr (L4821–L4830) / get_msrs (L4832–L4862) / set_msrs (L4864–L4894)

MSR 影子表操作。find：线性查 index。`KVM_GET_MSRS`：逐条从用户读 entry.index，查表填 data（未找到填 0）回写，返 nmsrs。`KVM_SET_MSRS`：逐条读 entry，找到则覆盖 / 否则追加（满则返已处理数 i），返 nmsrs。

### axkvm_vcpu_ioctl_x86 (L4896–L5095)

vCPU 级 x86 ioctl 的大 switch，持 `vcpu->lock`，末尾若 `state_changed` 置 `backend_state_dirty`。
- `KVM_GET_REGS` (L4905)：**从后端真实 post-run 寄存器刷新**（注释 L4906–4914）——后端 VMX advance RIP（越过 HLT 等）不会自动回流 `vcpu->regs`；gvisor 用 HLT 作 guest→userspace 上下文切换出口，需要这里的最新寄存器，否则返 stale 会让 gvisor 永远重进同一 RIP。`axvisor_kvm_backend_get_vcpu_regs` 成功才覆盖 cache（无此 op 的后端保留 cache），再回拷 user。含 task#100 诊断。
- `KVM_SET_REGS`/`GET_SREGS`/`SET_SREGS`（后者 `normalize_x86_sregs` + 打印）/`GET_FPU`/`SET_FPU`/`GET_LAPIC`/`SET_LAPIC`/`SET_CPUID2`/`GET_CPUID2`/`GET_MSRS`/`SET_MSRS`：读写各自影子态，SET 类置 `state_changed`。
- `KVM_GET_MP_STATE`/`SET_MP_STATE`（后者若设 RUNNABLE 则 `wake_up_all(mp_state_wq)` 唤醒等 SIPI 的 AP）。
- `GET/SET_DEBUGREGS`/`XSAVE`/`XCRS`（SET_XCRS 校验 nr_xcrs 与 `axkvm_x86_xcr0_valid`）/`VCPU_EVENTS`。
- `GET_TSC_KHZ` 返 `tsc_khz`；`SET_TSC_KHZ` 记 arg。
- default → -ENOTTY。非 x86 版恒返 -ENOTTY。

### axkvm_vm_set_user_memory_region (L5097–L5193)

`KVM_SET_USER_MEMORY_REGION`——**惰性映射的注册入口**。
- L5108–5124：拷 `kvm_userspace_memory_region`，校验 slot 越界、GPA/HVA/size 页对齐、flags（`LOG_DIRTY_PAGES` 返 -EOPNOTSUPP）；算 nr_pages。
- L5126–5167：**不 eager pin/map**（注释 L5130–5139：gvisor 注册巨大稀疏 slot（如 8GiB）由未 populate 的匿名 mmap 支持，eager FOLL_LONGTERM pin 未 populate 页返 EFAULT 且破坏 overcommit）。只 `access_ok` 校验 HVA 可寻址，`kvcalloc` 稀疏 `pages[]` + `bitmap_zalloc` `mapped`/`writable` 位图，填 `new_slot`（单页由 `axkvm_fault_in_gpa` 在首次 EPT violation 时按需 pin+map）。
- L5169–5192：持 `vm->lock`：size==0 则 unmap+release 旧槽返 0；否则 unmap+release 旧槽后 `*slot = new_slot`（新槽起空、按需填）。

### axkvm_vcpu_mmap (L5195–L5209)

vCPU fd 的 mmap：把 `run_pages`（`kvm_run` 共享页，2 页）经 `remap_pfn_range` 映到 userspace。校验 size ≤ `AXKVM_VCPU_MMAP_SIZE` 且 pgoff==0。这是 `KVM_GET_VCPU_MMAP_SIZE` + `mmap(vcpu_fd)` 拿到 `struct kvm_run` 的机制。

### axkvm_vcpu_ioctl (L5211–L5235) + axkvm_vcpu_fops (L5258–L5264)

vCPU fd 的 ioctl 分派：校验 `_IOC_TYPE==KVMIO`；`KVM_RUN`（arg 须 0）→ `axkvm_vcpu_run_backend`；`KVM_SET_SIGNAL_MASK`；`KVM_KVMCLOCK_CTRL`（no-op 返 0）；其余转 `axkvm_vcpu_ioctl_x86`。`fops` 挂 release/ioctl/mmap。

### axkvm_vcpu_release (L5237–L5256)

vCPU fd close：持 `vm->lock` 把 `vcpus[id]` 清 NULL、`axkvm_wake_parked_spinners`（让 parked spinner 重判 gate 以界定 teardown 延迟）后解锁，`axkvm_vcpu_put` 放引用。

### axkvm_vm_create_vcpu (L5266–L5338)

`KVM_CREATE_VCPU`：校验 id；`kzalloc` vcpu + `__get_free_pages` run 页；`kref_init`、取 VM 引用、设 id/run；`backend_ready` 则 `axvisor_kvm_backend_create_vcpu`。x86 下初始化各 mutex/waitqueue/watchdog、`boot_state=NONE`、原子清零、`axkvm_init_x86_vcpu_state`。持 `vm->lock` 装入 `vcpus[id]`（已存在返 -EEXIST），`anon_inode_getfd` 建 vCPU fd（失败回滚 vcpus[id]）。

### axkvm_vm_ioctl (L5340–L5391) + axkvm_vm_fops (L5404–L5409)

VM fd 的 ioctl 分派：校验 KVMIO；含 diag-n1b 无条件 trace。分派 `KVM_CHECK_EXTENSION`/`KVM_CREATE_VCPU`/`KVM_SET_USER_MEMORY_REGION`，x86 下另有 `SET_TSS_ADDR`/`SET_IDENTITY_MAP_ADDR`/`CREATE_IRQCHIP`/`CREATE_PIT2`/`GET/SET_CLOCK`/`GET/SET_IRQCHIP`/`GET/SET_PIT2`/`IOEVENTFD`/`IRQFD`/`SET_GSI_ROUTING`。其余 -ENOTTY。

### axkvm_vm_release (L5393–L5402)

VM fd close：x86 下 `axkvm_unregister_backend_vm`，然后 `axkvm_vm_put`。

### axkvm_dev_create_vm (L5411–L5475)

`KVM_CREATE_VM`：校验 type==0；`get_unused_fd_flags`；`kzalloc` vm + `kref_init` + `mutex_init`；x86 下初始化 `boot_controller_id=-1`/`current_bringup_target=-1`/`spin_park_wq`/默认 IRQ 路由；`axvisor_kvm_backend_create_vm` 取后端句柄；x86 下 `axkvm_register_backend_vm` + 发布诊断 lockless 句柄 `axkvm_dbg_vm`；`anon_inode_getfile("axvisor-kvm-vm")` 建 VM fd 并 `fd_install`。

### axkvm_dev_ioctl (L5477–L5508) + axkvm_dev_fops (L5510–L5514) + axkvm_miscdev (L5516–L5520)

`/dev/kvm` 设备级 ioctl 分派：校验 KVMIO；含 diag-n1b trace。分派 `KVM_GET_API_VERSION`（返 `KVM_API_VERSION`）/`KVM_CHECK_EXTENSION`/`KVM_GET_VCPU_MMAP_SIZE`（返 `AXKVM_VCPU_MMAP_SIZE`）/`KVM_CREATE_VM`，x86 下另有 `KVM_GET_SUPPORTED_CPUID`/`KVM_GET_MSR_INDEX_LIST`。`miscdev` 默认 minor=`KVM_MINOR`、name="kvm"。

### axkvm_dbg_witness_fn / _start / _stop (L5537–L5612)

诊断 witness：一个浮动 `SCHED_FIFO` kthread，每 ~200ms 向 debugcon(0xe9) 发 'W'（不 pin 任何 CPU、RT 优先级、绕开 printk/console）。用于区分"L1 有空闲核但 console 卡"（W 仍流）与"所有 L1 核被垄断的真 wedge"（W 也停）。~25s 后一次性用 `sched_show_task` dump 每个已注册 vCPU host task 的栈（因 sysrq-l 在被 wedge 的 PID1 poll 循环里跑不出来）。start `kthread_run` + `sched_set_fifo`，stop `kthread_stop`。

### axkvm_init (L5615–L5658)

模块加载。x86 下：`hrtimer_setup` 一次性 timer（`CLOCK_MONOTONIC`/`ABS`）与周期 timer（`REL_HARD`）；`alloc_workqueue("axkvm_timer", WQ_UNBOUND|WQ_HIGHPRI|WQ_MEM_RECLAIM, 1)`（分配失败退回 system_wq）；启动周期 hrtimer（250us）；`axkvm_dbg_witness_start`。然后 `axvisor_kvm_builtin_backend_init` 初始化内置后端；按 `dev_name` 设 miscdev name/minor（"kvm"→`KVM_MINOR` 抢 `/dev/kvm`，否则动态 minor 供 smoke test）；`misc_register`（失败提示可能需卸载原生 kvm）。

### axkvm_exit (L5660–L5675)

模块卸载：`misc_deregister`；x86 下 stop witness、cancel timer、`hrtimer_cancel` 周期 timer、`cancel_work_sync` + `destroy_workqueue`；`axvisor_kvm_builtin_backend_exit`。



