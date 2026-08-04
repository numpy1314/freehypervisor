# `axvisor_kvm_x86_bridge.rs` 逐函数精讲

> 源文件：`linux-host-kernel/drivers/virt/axvisor/axvisor_kvm_x86_bridge.rs`（4532 行，Rust，`#![no_std]`）
> 本文所有行号、函数名、结构体名、`extern "C"` 符号均取自真实源码。

---

## 一、文件总览

### 1.1 它在模块里的角色

`axvisor_kvm.ko` 由两部分组成：

- **C 主体**（`axvisor_kvm_main.c`）：向 Linux 用户态暴露一个仿 `/dev/kvm` 的字符设备，接收所有 KVM ioctl（`KVM_CREATE_VM`、`KVM_CREATE_VCPU`、`KVM_SET_REGS`、`KVM_RUN` 等），管理文件描述符、hrtimer、workqueue、host CPU 调度原语等一切"内核里才能做"的事。
- **本文件（Rust 桥，编译成普通 object 被链接进 `.ko`）**：把 C 主体收到的每一条 KVM 语义翻译成对 axvisor 本体 crate（`axvm`、`axvcpu`、`axaddrspace`、`axdevice` 等）的调用；反过来把 axvisor 的 vCPU 退出原因（`AxVCpuExitReason`）翻译回 C 能理解的 `AXKVM_BACKEND_EXIT_*` 数字并填出参。

因此本文件是"适配缝"（shim）的核心：它一边实现 `axvisor_api` 的各个 trait（`HostIf`、`TimeIf`、`VmmIf` 等），把 axvisor 需要的 OS 服务转发给 C；一边导出一批 `axvisor_kvm_rs_*` 的 `extern "C"` 函数，让 C 主体驱动 VM/vCPU 生命周期。它刻意**不引入完整 alloc sysroot**（见文件头注释，line 3-7），只通过 C 侧分配器 shim 满足 `alloc`。

### 1.2 两条 ABI 边界

**（A）本文件 `extern` 进来的 C 侧符号**（line 174-215，`unsafe extern "C"` 块）：全部以 `axvisor_kvm_x86_bridge_*` 命名。分几类：

- 内存分配：`_alloc` / `_realloc` / `_dealloc` / `_alloc_frame` / `_dealloc_frame` / `_phys_to_virt` / `_virt_to_phys`
- 日志：`_log`
- host 拓扑/身份：`_get_cpu_num` / `_current_cpu_id` / `_current_task_id` / `_current_time_nanos`
- 迁移与调度：`_migrate_disable` / `_migrate_enable` / `_yield_now` / `_park_now` / `_schedule_now` / `_cond_resched`
- FPU：`_guest_fpu_begin` / `_guest_fpu_end`
- 超订调度杠杆：`_wake_vcpu` / `_boost_vcpu` / `_directed_yield` / `_spin_demote` / `_spin_restore` / `_spin_park`
- 惰性内存：`_fault_in_gpa`
- pvclock：`_pvclock_write` / `_pvclock_refresh`
- timer：`_program_timer` / `_reprogram_timer` / `_cancel_timer`
- 诊断（DIAG）：`_signal_pending`（line 206-208）、`_note_ap_alive_spin`（line 211）

**（B）本文件导出给 C 的 `extern "C"` 符号**：分两组。

- axvisor 内部的算术/运行时符号：`__udivti3`（line 1395）、两个 `__rust_no_alloc_shim_is_unstable_v2` 别名（line 1388-1392）。
- KVM 后端接口 `axvisor_kvm_rs_*`（VM/vCPU 生命周期，见第五节）：`backend_init`/`backend_exit`/`create_vm`/`destroy_vm`/`set_vm_state`/`map_page`/`map_page_nolog`/`unmap_range`/`create_vcpu`/`destroy_vcpu`/`set_vcpu_state`/`set_vcpu_regs`/`get_vcpu_regs`/`set_vcpu_sregs_control`/`set_vcpu_segment`/`set_vcpu_dtable`/`set_vcpu_cpuid_entry`/`set_vcpu_msr_entry`/`set_vcpu_fpu`/`set_vcpu_xsave_legacy`/`boot_vm`/`run_vcpu`/`complete_mmio_read`/`complete_io_read`/`inject_irq`/`dbg_backend_rip`（DIAG）。
- 另有一个非 `_rs_` 前缀的导出 `axvisor_kvm_x86_bridge_expire_all_due_timers`（line 4530），供 C 的 hrtimer workfn 调用。

### 1.3 关键数据结构

- **`VMS`（line 989，`static mut [BackendVm; MAX_VMS]`）**：VM 注册表。每个 `BackendVm`（line 618）持有 `vm: Option<AxVMRef>`（即 `Arc<AxVM>`）、`booted` 标志、vCPU 计数、irqchip/pit 配置、IOAPIC 重定向表快照。`handle = index+1`，0 号 handle 非法。
- **`VCPUS`（line 990，`static mut [BackendVcpu; MAX_VCPUS]`）**：vCPU 注册表。每个 `BackendVcpu`（line 733）缓存 host 通过 KVM_SET_* 推入的寄存器/段/CPUID/MSR/FPU 状态（`state_dirty` 标记待下刷），以及 `pending_mmio_read`/`pending_io_read`（用户态回填游标）、`sipi_started`（AP 是否已收到 SIPI）。
- **`VM_REGISTRY_LOCK`（line 1002，`SpinNoIrq<()>`）**：串行化 `VMS[i].vm` 的 publish（boot_vm）/ lookup（`axvm_for_vm_id`）/ teardown（destroy_vm），弥补 C 层只串行化 ioctl 线程但不串行化异步 timer workfn 的空档，防 Arc use-after-free。
- **`KVM_TIMERS`（line 1025，`[SpinNoIrq<VcpuTimerTable>; MAX_VCPUS]`）**：每 vCPU 一张定时器表（`VcpuTimerTable`，line 705，内含 `[KvmTimerEntry; 64]`）。取代旧的单一全局无锁表（曾在 32-vCPU 超订下 double-free 回调 Box）。
- **`PAGE_MAPPINGS`（line 1023，`static mut [PageMapping; MAX_PAGE_MAPPINGS]`）**：GPA→HPA 映射重放表，供 `boot_vm` 时重建 EPT。惰性 fault-in 的页故意不进此表（会溢出 262144 条）。
- **`RUN_CONTEXTS`（line 1030）+ `FALLBACK_CURRENT_*`（line 1032-1033）**：按 host task_id 索引的"当前 vm/vcpu"上下文，供 `VmmIf::current_vm_id/current_vcpu_id` 查询。
- **`SOFT_PLE_LAST_RIP` / `LAST_RIP2` / `RIP_STREAK`（line 1017-1022）**：每 vCPU 的软件 PLE 自旋跟踪（最多两个 64 字节 RIP 窗口 + 连续计数）。
- **`PERCPUS` / `PERCPU_INITIALIZED`（line 1027-1029）**：每 host CPU 的 `AxVMPerCpu`（VMXON 状态）。

### 1.4 常量与错误码（line 58-163）

- Linux errno：`EINVAL=22`、`EOPNOTSUPP=95`、`ENODATA=61`、`ENOSPC=28`。
- 退出原因数字 `AXKVM_BACKEND_EXIT_*`（line 62-70）：MMIO/IO 读写、HLT、SHUTDOWN、FAIL_ENTRY、INTERNAL_ERROR、CPU_UP。
- x86 设备常量：PIT GSI/IRQ=0，COM1 GSI/IRQ=4。
- 容量上限 `MAX_VMS=16` / `MAX_VCPUS=64` / `MAX_HOST_CPUS=256` / `MAX_PAGE_MAPPINGS=262144` / `MAX_TIMERS_PER_VCPU=64` 等。
- 软件 PLE 阈值 `SOFT_PLE_DIRECTED_YIELD_INTERVAL=16`（line 102）、`SOFT_PLE_RIP_STREAK_THRESHOLD=3`（line 143）、`SOFT_PLE_REPARK_INTERVAL=2`（line 146）。这些常量前有大段注释解释嵌套虚拟化下硬件 PLE 不可用、必须软件近似的背景。
- FXSAVE 布局偏移（line 150-163）。

---

## 二、全局分配器与日志

### `BridgeAllocator` 的 `GlobalAlloc` 实现（line 220-253）

把 Rust 的 `alloc`/`dealloc`/`realloc` 全部转发给 C 侧分配器。
- `alloc`（221-227）：对 `size==0` 的零字节分配返回 `align`（合法非空哨兵指针，避免真正调用），否则调用 C 的 `_alloc`。
- `dealloc`（228-233）：零字节直接跳过。
- `realloc`（235-252）：分四种情况——旧块为空且新块非空→当作 alloc；新块为 0→dealloc 后返回 null；否则转发 `_realloc`。
逻辑目的：让 axvisor crate 里的 `Box`/`Vec`/`format!` 能工作，同时把内存策略交给内核（kmalloc 系）。

`GLOBAL_ALLOCATOR`（line 217-218）用 `#[global_allocator]` 注册这个零大小结构体。

### `bridge_log`（line 255-257）

把 `&str` 的指针+长度传给 C 的 `_log`（最终走 `printk`）。全文件所有日志都经此函数。

---

## 三、x86 中断注入与虚拟设备推进辅助

这一组自由函数把"设备产生了一个 IRQ"翻译成"给某个 vCPU 注入向量并唤醒它"。

### `inject_x86_ioapic_irq`（line 259-284）

给 IOAPIC 目标 vCPU 注入一个向量。
- 259-262：取目标 vCPU，取不到直接返回。
- 263-267：按 `level_triggered` 选择 `LevelTriggered`/`EdgeTriggered` 触发模式。
- 268-274：调 `vcpu.inject_interrupt_with_trigger`，失败则记日志返回。
- 275-283（关键）：注入成功后**必须唤醒目标 vCPU**。因为 HLT 现在走"无限阻塞"模型（KVM `kvm_vcpu_block` 语义），若不唤醒，一个 HLT 阻塞的 vCPU 收到跨核设备 IRQ 会永远睡下去。用 `current_vm_id()` 作为 VM handle 调 C 的 `_wake_vcpu`。

### `inject_x86_pic_irq`（line 286-308）

给 8259 PIC 注入。
- 287-289：`x86_pic_assert_irq(irq)` 取出 PIC 解析出的向量，取不到返回 false。
- 290-292：取目标 vCPU。
- 293-302：边沿触发注入，失败记日志返回 false。
- 303-307：同样唤醒目标 vCPU，返回 true 表示"PIC 路径已处理"。

### `inject_due_x86_pit_irq0`（line 310-325）

投递到期的 PIT IRQ0。
- 311-314：`x86_pit_consume_irq0_if_due(now)`——未到期直接返回（消费式：到期才吃一拍）。
- 316-318：优先走 PIC 路径（`inject_x86_pic_irq(IRQ 0)`）；成功即返回。
- 320-324：PIC 未处理则回退到 IOAPIC，用 GSI 0 断言，取目标 vCPU（默认 0）后注入。

### `complete_x86_external_eoi`（line 327-340）

处理 guest 对外部中断的 EOI（level-triggered 的重新断言）。
- 328-331：`vector` 为空直接返回；先给 PIC 发 EOI。
- 332-337：给 IOAPIC 发 EOI，若返回值带 `pending`（level-triggered 线路仍拉高，需重注入）则取出。
- 338-339：向目标 vCPU 重新注入该 IRQ。

### `inject_pending_x86_serial_irq`（line 342-356）

串口（COM1）待处理 IRQ 投递，结构与 PIT 完全对称：`x86_serial_poll_irq` 判有无→PIC 优先→IOAPIC GSI 4 回退。

### `progress_x86_virtual_irqs`（line 358-364）

汇总入口：**仅 vCPU 0** 推进虚拟设备 IRQ（359-360 早退）。因为 PIT/串口这类传统设备只挂在 BSP 上。依次调 PIT 与串口投递。

### `arm_x86_idle_wakeup_timer`（line 373-382）

为空闲（HLT）guest 编排 host one-shot hrtimer。
- 373-379：取 PIT 下一次 IRQ0 的绝对 deadline（无则返回，0 也返回）。
- 381：调 C 的 `_program_timer`。文档注释（366-372）强调：`program_timer` 只在请求 deadline 早于当前挂起的才重新编排，故不会覆盖已注册的更早 LAPIC deadline。目的：嵌套虚拟化下 VMX 抢占定时器不可用，空闲 guest 需要 host hrtimer 周期性把它从 HLT 唤醒。

---

## 四、KVM timer 表：注册 / 到期扫描 / 取消

这是本文件最精细的部分之一，锁与"单次扫"结构直接关系到超订下的 RCU stall 修复。

### `reprogram_next_kvm_timer`（line 384-422）

扫描**所有** per-vCPU 表，找出全局最早的 in-use deadline，据此重编排或取消 host hrtimer。
- 385：`selected_deadline = u64::MAX`（哨兵：无 timer）。
- 390-408（逐块）：对每张表 `KVM_TIMERS[v]` 单独 `lock()`，遍历 64 个 entry；对 in-use 项把 `deadline` 换算成 ns（>u64::MAX 则饱和到 u64::MAX），用 `min` 收敛到 `selected_deadline`。**每张表用完立即 `drop(tbl)` 再进下一张**（注释 387-389）——同一时刻只持一把锁，不可能死锁。
- 410-421：无 timer 则 `_cancel_timer`；否则 `_reprogram_timer(selected_deadline)`。注释（414-418）说明这是"only-earlier re-arm"低延迟唤醒，全局 drain-all liveness 由独立的周期 hrtimer 保证，故此处不需精确/不需过期钳制。

### `expire_due_kvm_timers`（line 424-482）

只 drain **当前 vCPU 自己那张表**的到期 timer。在 vCPU 自己的 KVM_RUN 线程上运行。
- 436（关键）：`pass_cutoff = current_time()` **在进入本 pass 时冻结一次**。注释（425-435）解释为什么：周期性 vLAPIC 回调会在 drain 过程中注册"下一周期"的 timer，其 deadline 恒在未来；若每轮重读 `now`，墙钟一旦爬过这个近未来 deadline，新 timer 会在同一 pass 里被自己的后继再次消费——在 8-vCPU 嵌套投递下服务成本超过钳制周期，就变成无界 CPU 风暴（观测 ~385k re-arm/s）。冻结 cutoff 就把本 pass 限定在"进入时已到期"的 timer，让下一次 host hrtimer fire 驱动下一拍。
- 444-449：确定要 drain 的 `vcpu_id`——优先 `current_run_context()`，否则回退 `FALLBACK_CURRENT_VCPU_ID`；越界返回。
- 459-473（**单次前向扫**，核心结构）：分配固定栈缓冲 `drained: [Option<Box<...>>; 64]`。在持锁块内（462-473）单向遍历 64 个 entry：对 `in_use && deadline <= pass_cutoff` 的项，用 `callback.take()` 摘走回调、`entry = empty()` 清空、`n += 1`。**没有外层重扫循环**——注释（450-458）明确：re-arm 的 timer会落进本表被释放的槽，但扫描已结束不再重复，所以不会本 pass 再消费；这把 SpinNoIrq（IF=0）临界区限制在 ≤64 次、保证终止（旧的无界外层循环曾在 re-arm deadline≤frozen cutoff 时持 IF=0 死转，阻塞 host 的 TLB-flush IPI→RCU stall）。
- 474-480：**释放锁之后**再逐个调用摘出的回调 `callback(pass_cutoff)`。注释（437-443）说明为何"锁外调回调"：周期回调会重新注册（再取同一 per-vCPU 锁），锁外调用避免重入死锁，也避免回调 Box 被别的线程别名/double-free。
- 481：结束后 `reprogram_next_kvm_timer()`。

### `expire_all_due_timers`（line 507-554）

`expire_due_kvm_timers` 的"全表"变体，从 host hrtimer workqueue（进程上下文，可睡/锁/分配）调用。
- 存在理由（文档注释 484-506）：`expire_due_kvm_timers` 只 drain 当前 vCPU 表且跑在 vCPU 线程上；一个在超订下被饿死离核（RUNNABLE 但没被调度、又不是 HLT 挂起所以 `wake_halted_vcpus` 够不着）的 vCPU 永远 drain 不到自己的周期 LAPIC tick，其 guest 时钟冻结、上面 pin 的 kthread（如 rcu_preempt）饿死→RCU stall。此变体扫**每张**表，每个回调带自己捕获的 `vm_id/vcpu_id`，用 `vmm::inject_interrupt`（锁保护软件队列，非 VMCS 写）投递，故可安全从无关线程运行。
- 513：同样冻结 `pass_cutoff`。
- 514-552：外层 `while v < MAX_VCPUS` 逐表；每表内是与 `expire_due_kvm_timers` 完全相同的"单次前向扫 + 锁外调回调"结构（`drained` 固定缓冲、持锁摘取、锁外调用）。注释（516-528）补充：re-arm 落进"更晚的表"可能在扫到那张表时被拾起，但 `v` 只增、每表恰好扫一次，整趟仍终止（≤ MAX_VCPUS*64 个回调）。
- 553：结束 `reprogram_next_kvm_timer()`。

### `cancel_kvm_timers_for_vm`（line 556-572）

VM 串行销毁时调用，清掉所有表里属于该 `vm_id` 的 entry（逐表 lock、匹配 `vm_id` 清空、drop），最后 reprogram。

### `register_kvm_timer_on_table`（line 574-616）

把一个回调注册进 timer 表。
- 580：从 `NEXT_TIMER_TOKEN` 原子自增取 token（`.max(1)` 保证非零）。
- 582-584：`vcpu_id` 越界则直接返回 token（不注册）。
- 590-613（**线性探测**）：从"目标 vCPU 自己的表"开始 `(vcpu_id + probe) % MAX_VCPUS`，逐表找空槽写入 entry（`carried.take()` 转移回调 Box 所有权），成功即 `reprogram_next_kvm_timer()` 返回。注释（586-589）解释为何从捕获的目标 vCPU 而非 `current_vcpu_id()` 开始：LAPIC 周期 re-arm 可能跑在 host hrtimer workqueue 上、不在目标 vCPU 的运行上下文里，表归属必须来自捕获的目标。
- 615：全满则返回 token（未真正注册）。

---

## 五、结构体定义与注册表状态（line 618-1034）

这一大段是纯数据声明，逐块带过：

- `BackendVm`（618-656）+ `empty()`：VM 槽位。
- `PageMapping`（658-677）+ `empty()`：一条 GPA→HPA 映射记录。
- `KvmTimerEntry`（679-697）：一个 timer 槽（in_use/token/vm_id/deadline/callback）。
- `VcpuTimerTable`（699-715）：每 vCPU 64 槽 timer 表；注释（699-704）说明它取代了旧的单全局无锁表以修 double-free。
- `RunContext`（717-731）：`{task_id, vm_id, vcpu_id}` 三个原子，用于按 host task 反查当前上下文。
- `BackendVcpu`（733-795）+ `empty()`：vCPU 槽，字段多，缓存 host 推入的完整 x86 状态；注意 `xcr0` 默认 1（777）。
- `PendingMmioRead`（797-816）/ `PendingIoRead`（818-831）：用户态 MMIO/PIO 读回填游标。
- `BackendRegs`（833-878）/ `BackendSregs`（880-903）/ `BackendSegment`（905-938）/ `BackendDtable`（940-950）/ `CpuidEntry`（952-975）/ `MsrEntry`（977-987）：镜像 KVM 对应结构的平坦字段。

**静态注册表**（989-1034）：`VMS`、`VCPUS`（均 `static mut`）、`VM_REGISTRY_LOCK`、软件 PLE 三张跟踪数组、`PAGE_MAPPINGS`、`KVM_TIMERS`、`PERCPUS`/`PERCPU_INITIALIZED`、`RUN_CONTEXTS`、`FALLBACK_CURRENT_VM_ID`/`FALLBACK_CURRENT_VCPU_ID`、`NEXT_TIMER_TOKEN`。各自的用途与并发理由在 1.3 节及源码注释（992-1002、1004-1016）中说明——尤其 `VM_REGISTRY_LOCK` 的注释（992-1001）详述了 timer workfn 与 destroy/publish 竞争导致 Arc UAF（表现为 `run_vcpu_raw` 里 `ud2` panic）的历史。

### `set_current_vcpu_context`（line 1036-1073）

把当前 host task 与 (vm_id, vcpu_id) 绑定进 `RUN_CONTEXTS`。
- 1037-1042：先无条件写 `FALLBACK_CURRENT_*`（Release）作为兜底。
- 1044-1046：`task_id==0`（拿不到 task）则只留兜底返回。
- 1048-1061：遍历 `RUN_CONTEXTS`，若已有同 task_id 的槽就更新其 vm/vcpu 返回；顺带记住第一个空槽 `empty`。
- 1063-1072：用空槽写入 vm/vcpu，再用 `compare_exchange(0 → task_id)` 占用该槽（防并发占用）。

### `current_run_context`（line 1075-1092）

按当前 host task_id 在 `RUN_CONTEXTS` 里查 (vm_id, vcpu_id)；`task_id==0` 或找不到返回 `None`。这是 `VmmIf::current_*` 的底层。

---

## 六、`axvisor_api` trait 实现（line 1094-1370）

这些 `#[api_impl]` 块是 axvisor 本体向 shim 索取 OS 服务的入口。

### `HostIf`（line 1094-1119）
- `get_host_cpu_num`/`current_host_cpu_id`：转发 C。
- `init_percpu`：空（percpu 初始化在 `enter_percpu` 里按需做）。
- `release_host_filesystems`：返回 `Ok`（无操作）。
- `exit`：记日志后 `loop {}`（不真正退出内核）。
- `emerg_write_bytes`：直接走 `_log`。

### `ConsoleIf`（line 1121-1130）
`write_bytes` 走 `_log`；`read_bytes` 恒返 0（无输入）。

### `TimeIf`（line 1132-1147）
- `current_time_nanos`：转发 C 的单调时钟。
- `set_oneshot_timer`（1138-1146）：把绝对 ns deadline 交给 C 的 `_program_timer`。中文注释（1139-1141）说明嵌套虚拟化下 VMX 抢占定时器不可靠，空闲 guest 靠 host hrtimer 周期唤醒。

### `SyncIf`（line 1149-1170）
等待队列极简实现：`create` 返固定句柄 1、`destroy`/`wake_*` 空操作、`wait` 靠忙等 `yield_now`、`wait_queue_wait_until` 循环判 condition 之间 `yield_now`。真正的阻塞/唤醒由 C 侧的 wake_vcpu 机制承担。

### `TaskIf`（line 1172-1191）
- `spawn_task_raw`/`join_task`：不支持（返回 0 句柄 / 空）。vCPU 线程由 C 侧创建。
- `current_task`：转发 C task_id，0 视为无。
- `yield_now`：转发 C。

### `MemoryIf`（line 1193-1215）
`alloc_frame`/`dealloc_frame`/`phys_to_virt`/`virt_to_phys` 全部转发 C（0 物理地址视为分配失败）。

### `VmmIf`（line 1217-1370）核心业务 trait
- `current_vm_id`/`current_vcpu_id`（1219-1229）：走 `current_run_context()`，回退 `FALLBACK_*`。
- `vcpu_num`（1231-1240）：查 `VMS[index].vcpu_count`（至少 1）。
- `active_vcpus`（1242-1257）：返回该 VM 所有 in-use vCPU 的**位掩码**（按 `VCPUS[i].id` 置位）。
- `inject_interrupt`（1259-1278）：查 VM→查 vCPU→`inject_interrupt(vector)`；成功后 `_wake_vcpu`，且**若目标非自己**再 `_boost_vcpu`（超订下把本核让给 IPI 目标，避免 guest CSD-lock/smp_call_function 超时；自注入跳过）。
- `inject_interrupt_to_cpus`（1280-1299）：对 `VCpuSet` 里每个 vCPU 重复上面的注入+wake+boost。
- `register_timer`（1301-1308）：用当前 vm/vcpu 调 `register_kvm_timer_on_table`。
- `register_timer_on_vcpu`（1310-1317）：用显式目标 vm/vcpu 注册（供跨 vCPU 的周期 re-arm）。
- `cancel_timer`（1319-1357）：**快路径**先扫当前 vCPU 表（1321-1334），命中即清空+reprogram 返回；**回退**扫其余所有表（1336-1356）。
- `pvclock_write`/`pvclock_refresh`（1359-1369）：转发 C 的 pvclock hook。

### `panic` / `alloc_error` handler（line 1372-1386）
均记日志后 `loop {}`（no_std 环境不能 unwind）。

### Rust 运行时符号垫片（line 1388-1410）
- 两个 `__rust_no_alloc_shim_is_unstable_v2` 别名（1388-1392）：满足链接器对 no-alloc-shim 符号的要求。
- `__udivti3`（1394-1410）：软件 128 位无符号除法（逐位长除），因为 no_std 内核环境没有 compiler-rt 的这个符号；`d==0` 返回 0。

---

（下一批：辅助转换函数、`make_internal_run_progress`、软件 PLE、惰性 fault-in、生命周期导出函数、run_vcpu 主循环。）

---

## 七、句柄/宽度/字节转换辅助（line 1412-1523）

- `vm_index_from_handle`（1412-1417）：handle→index（`index = handle-1`），0 或越界返 `-EINVAL`。
- `vcpu_index_from_handle`（1419-1424）：同理，for vCPU。
- `find_vcpu_slot_by_id`（1426-1435，unsafe）：按 (vm_handle, vcpu_id) 线性查 `VCPUS` 槽下标。
- `width_bytes`（1437-1439）/ `width_mask`（1441-1448）/ `sign_extend_value`（1450-1457）：`AccessWidth`（Byte/Word/Dword/Qword）到字节数、位掩码、符号扩展的转换。
- `mmio_read_value`（1459-1473）：把 C 传来的 `len` 字节小端拼成 `u64`（校验非空、`1..=8`）。
- `write_u16_le`/`write_u32_le`/`write_u64_le`（1475-1496）：小端写入字节缓冲，供 FXSAVE 组装。
- `set_default_fxsave_fields`（1498-1506）：写默认 FCW=0x37f、MXCSR=0x1f80、MXCSR_MASK。
- `copy_bytes`（1508-1519）：带边界校验的 `memcpy`（越界返 `-EINVAL`）。
- `port_number`（1521-1523）：`Port` 取 u64 端口号。

## 八、in-kernel 设备判定谓词（line 1525-1542）

- `is_x86_inkernel_irqchip_port`（1525-1530）：判断端口是否属于 shim 内核内模拟的中断芯片/PIT/串口（0x20/0x21、0x40-0x43、0x61、0xa0/0xa1、0x4d0/0x4d1、0x3f8-0x3ff）。
- `is_x86_pit_port`（1532-1534）/ `is_x86_pic_port`（1536-1538）：PIT / PIC 子集判定。
- `is_x86_inkernel_mmio_addr`（1540-1542）：IOAPIC MMIO 窗口 `0xfec0_0000..=0xfec0_0fff`。

## 九、日志节流与进度记账（line 1544-1589）

### `should_log_raw_exit`（line 1544-1572）
决定某次 raw exit 是否记日志。注释（1545-1548）：良性稳态退出（idle EOI、halt、in-kernel MMIO/PIO、内部重试）无论重试次数一律静默，防止 flood L1 内核日志把 guest 串口饿死；只有结构性退出（CpuUp、真 MMIO/IO、错误）和周期性重试检查点（`retry % 4096 == 0`）才记。逐分支列出静默条件。

### `note_internal_run_progress`（line 1574-1582）
`retry_count += 1`，每 `KVM_RUN_INTERNAL_EXIT_LOG_INTERVAL`（4096）次记一条内部进度日志。

### `clear_vcpu_pending_reads`（line 1584-1589，unsafe）
清空该 vCPU 的 `pending_mmio_read` / `pending_io_read` 游标。

## 十、退出出参组装（line 1591-1689，均 unsafe）

这组把 axvisor 的退出翻译成 C 侧 `run_vcpu` 出参 + 设置回填游标：
- `reset_backend_exit_outputs`（1591-1605）：默认把 `reason` 置 `FAIL_ENTRY`、其余出参清 0（run 入口先调一次做安全默认）。
- `prepare_userspace_mmio_read_exit`（1607-1631）：设 `reason=MMIO_READ`、写 width/addr，并把 `pending_mmio_read` 标 active（记 reg/width/reg_width/signed_ext），清 io 游标。
- `prepare_userspace_mmio_write_exit`（1633-1650）：MMIO_WRITE，清游标后写 width/addr/data。
- `prepare_userspace_io_read_exit`（1652-1670）：IO_READ，设 `pending_io_read` active。
- `prepare_userspace_io_write_exit`（1672-1689）：IO_WRITE，清游标后写 width/addr/data。

---

## 十一、超订前进保证核心：`make_internal_run_progress`（line 1691-1872）

这是超订调度修复的中枢，被 run 主循环每次良性内部退出调用。**逐块讲解**：

- 1698-1701：可选清 `pending_reads`（`clear_pending_reads` 参数）。
- 1704-1706（**一次性判超订**）：取 `vm_handle`、`online = _get_cpu_num()`、`oversubscribed = online != 0 && vm_active_vcpu_count(vm_handle) > online`。这个布尔同时决定"timer drain 范围"和"尾部 reschedule 边界"。
- 1708-1738（**timer drain**）：长注释对比 KVM——KVM 从 vCPU 自己线程投递周期 LAPIC tick，latch 回调跑在 HARD IRQ（`HRTIMER_MODE_ABS_HARD`），绝不会被 runnable vCPU 线程饿死；axvisor 却在 `WQ_HIGHPRI` workqueue worker 里 drain+re-arm（因为 re-arm/kick 要取 `vm->lock` 睡眠锁不能在 hardirq 跑），该 worker 在超订下饿死（20 runnable 线程占满 18 核，SCHED_NORMAL worker 拿不到槽），观测到 tick 全停、guest jiffies 冻、SMP bringup 卡死。**修复**：超订时 `expire_all_due_timers()`（在永不饿死的忙 vCPU 线程上 drain 每张表）；否则 `expire_due_kvm_timers()`（只 drain 自己表 + 保留 workqueue）。健康非超订 baseline（1/2/4/8/16）走后者、时序不变。
- 1739：`progress_x86_virtual_irqs`——推进 PIT/串口 IRQ。
- 1740：`note_internal_run_progress`——记账。
- 1741-1756（普通路径注释）：说明尾部本应用 `cond_resched()`——KVM-faithful 原语，仅当 host 调度器置了 `TIF_NEED_RESCHED` 才让核、vCPU 线程保持 RUNNABLE；非超订时是廉价 no-op，不拖延 timer/中断路径。长自旋/空闲振荡的让核仍留给 `soft_ple_maybe_park`。
- 1758-1785（**reschedule 边界注释**）：详述与 KVM 的关键结构差异——`enter_percpu()` 的 `migrate_disable()` 横跨整个 Rust 内层循环，把热自旋/空闲 vCPU 线程 PIN 在核上，CFS 无法迁移/再平衡，`nr_running==1` 时 `cond_resched()` 又是 no-op→pinned 线程永不让核（观测 wPVMjF：一个 vCPU 热转 20 万+次，BSP 静默饿死，AP bringup 卡死→RCU stall）。KVM 的 `vcpu_run` 外层循环开抢占，`preempt_disable` 只在 `vcpu_enter_guest` 内围绕真正的 VMRUN，reschedule 处理在其外，线程可自由迁移。**镜像做法**：超订时在这个"两次 entry 之间"的 reschedule 点，先 `leave_percpu` 丢迁移锁，再 reschedule，再 `enter_percpu` 在可能的新 pCPU 上重验 VMXON；安全性来自 `run_vcpu_raw` 已用 `vcpu.bind()/unbind()`（VMPTRLD/VMCLEAR）括起每次 guest entry，此点无 VMCS 加载。
- 1786-1869（**超订分支**，`if oversubscribed`）：
  - 1787-1826（长注释）：解释为何用 `schedule_now()`（无条件 `schedule()`）而非 `cond_resched()`/`yield_to`——在 one-thread-per-core 的 `nr_running==1` 布局下后两者都无法交出核；`schedule()` 始终进 `__schedule()` 且保持线程 TASK_RUNNING（不像 park 的 `schedule_timeout_interruptible(1)` 会把 AP 移出 runnable 集且观测到再也不恢复）。但仅 `schedule_now()` 会让 CFS 在等权重下反复重选热自旋 AP 而饿死 BSP（观测 yAMmEf：BSP 46 次 enter vs 自旋者各 7000-9000），故须先用 `directed_yield` 把 picker 偏向"必须跑才能推进 SMP bringup 的线程"。
  - 1827-1830：`directed_yield(vm_handle, id)`——按优先级 boost 目标（P0=BSP 正等的 AP、P1=自旋 AP 把核让给 boot controller、P2=轮转 RUNNABLE 兄弟）。
  - 1835：`leave_percpu()`——**在任何 block/reschedule 前**丢迁移锁 + 卸 VMCS（这是唯一安全的阻塞点；旧的 block-park 在 migrate_disable 窗口内且 VMCS 仍加载时阻塞，冻死了 L1）。
  - 1843-1846：`spin_park(vm_handle, id)`——可选的 bringup 后自旋者短 park。返回值：1=已 park+唤醒（核已让出，跳过 schedule_now）；0=不合格（回退 runnable resched）；<0=`-EINTR`（中止 run）。
  - 1847-1856：park<0：重进 percpu 后返回 park（把 `-EINTR` 上抛，让 KVM_RUN ioctl 因 immediate_exit/signal 返回）。
  - 1857-1859：park==0：调 `schedule_now()`（核心让核）。
  - 1860-1866：`enter_percpu()` 重进；失败记日志（但不阻断）。
- 1867-1869（**非超订分支**）：只 `cond_resched()`。
- 1871：返回 0（正常）。

## 十二、软件 PLE：`soft_ple_maybe_park`（line 1890-2003）

文档注释（1874-1889）：这是硬件 PLE 的软件替身，在忙内部退出路径（`InterruptEnd{None}`/`Nothing`）上、在良性 `make_internal_run_progress` 之前调用；仅当机器超订、本 vCPU 非 boot controller、且 guest RIP 连续 `SOFT_PLE_RIP_STREAK_THRESHOLD` 次内部退出**不变**时才交出核。**逐块**：

- 1891-1896：取 (vcpu_id, vm_handle)；`vidx` 越界返回。
- 1899-1904（超订门）：`online==0 || vm_active_vcpu_count <= online` 即非超订→`soft_ple_reset` + `spin_restore`（恢复被降级的调度优先级）后返回。这一门保证非超订 baseline 完全不受扰。
- 1906-1910：取 `current_guest_rip`（缓存值，非 live vmread），取不到→reset+restore 返回。
- 1912-1948（**≤2 窗口 streak 跟踪**，核心）：注释（1912-1926）解释为何要两个窗口——纯自旋 vCPU 卡在**一个** 64 字节 RIP 区域；但**空闲** vCPU 在 `hlt` 与 APIC-EOI 处理（`native_apic_mem_eoi`）两个远隔窗口间振荡，单窗口 streak 每翻转就重置永不成熟。逻辑：
  - `rip_window = rip & !0x3f`（64 字节粒度）。
  - 若 `rip_window` 命中 w1 或 w2→streak+1。
  - 若 w1 空（`u64::MAX`）→填 w1，streak+1。
  - 若 w2 空→填 w2，streak+1。
  - 否则（**第三个不同窗口 = 真前进**）→重置跟踪从它开始（w1=新窗口、w2=空、streak=1），并立即 `spin_restore`（RIP 驱动的恢复，绝不 timer 驱动，因为 wedge 下 timer 路径饿死）。
- 1950-1952：streak 未达阈值→返回。
- 1954-1962：达阈值后把 streak 回设为 `THRESHOLD - REPARK_INTERVAL`，使确诊自旋者每 `REPARK_INTERVAL` 次退出就 re-park，而非再等整个阈值窗口。
- 1964-2002（**确诊自旋者让核**）：长注释（1964-1998）说明三点决策——(a) best-effort `directed_yield`（KVM `kvm_vcpu_on_spin` 的 `yield_to` 类比，`nr_running==1` 下常返 `-ESRCH`，只是提示)；(b) **故意不 block-park**（旧的 `schedule_timeout_interruptible(1)` block-park 在 run-loop 上下文里把确诊 AP 移出 runqueue，冻死整个 L1 达 230s；真 KVM 的 `kvm_vcpu_on_spin` 同样从不阻塞 PLE 自旋者)；(c) **决定性手段是 SCHED_IDLE 降级**——保持 vCPU RUNNABLE（不离开 CFS 平衡集，这是 block-park 冻 L1 的原因）但沉到所有 SCHED_NORMAL/RT 之下，一旦 nice-boost 的 BSP/迁移来的兄弟/L1 kthread 落到这核就抢占它。恢复时机：guest RIP 离开自旋窗口（上面第三窗口分支）或离开超订/HLT。
  - 2000-2001：`directed_yield` + `spin_demote`。

## 十三、超订压力计数：`vm_active_vcpu_count`（line 2018-2033）

注释（2005-2017）：只数"真正启动/runnable、正在争抢 host CPU 的 vCPU"，近似 KVM 的超订压力模型（`kvm_vcpu_on_spin` 跳过 `!vcpu->ready` 的）。逻辑（2019-2032）：遍历 `VCPUS`，对 `in_use && vm_handle 匹配 && (id==0 || sipi_started)` 计数。这修了一个关键误判：gvisor 预创建所有 vCPU（如创建 12 个只跑 vcpu0），原始"已注册数"会把它误判为超订、错误降级/park 唯一的运行者（memory 记录的 task#96 修复）。注释末尾指出局限：用 `KVM_SET_MP_STATE(RUNNABLE)` 而非 SIPI 启动 AP 的 VMM 会被少计；常见 Linux/Firecracker/gvisor 的 SIPI 路径已覆盖。

## 十四、in-kernel 退出处理与 RIP/regs 快照（line 2035-2192）

### `handle_inkernel_progress_result`（line 2035-2055）
把 in-kernel 设备处理结果翻译成"是否继续内层循环"：
- `handled==0`（已处理）→调 `make_internal_run_progress`；其返回 <0（自旋 park 的 `-EINTR`）则 `Err` 上抛以中止 run，否则 `Ok(true)`（继续循环）。
- `handled==-EOPNOTSUPP`（in-kernel 不认这设备）→`Ok(false)`（交给用户态退出）。
- 其他→`Err(handled)`。

### `handle_x86_inkernel_io_read`（line 2057-2078）/ `handle_x86_inkernel_io_write`（line 2080-2103）
先 `is_x86_inkernel_irqchip_port` 判定，不是则返 `-EOPNOTSUPP`；是则按 PIT/PIC/通用端口分派给 `axvm.get_devices()` 的对应 handler，读路径再 `complete_x86_io_read` 把值回填 guest 寄存器。

### `current_guest_rip`（line 2105-2117）
取该 vCPU 在**最近一次 VM-exit 时缓存的** RIP（`get_arch_vcpu().last_exit_rip()`）。注释（2109-2116）强调**绝不能 live vmread**——`make_internal_run_progress` 在 `run_vcpu_raw` 已 unbind vCPU 之后运行，VMCS 不再加载，vmread 会失败（历史上 `.unwrap()` panic 把物理 CPU 转成 RCU stall）。

### `BackendGuestRegs` + `current_guest_regs`（line 2126-2179）
供 `get_vcpu_regs`（KVM_GET_REGS）用的真实 post-run 寄存器快照。GPR 取自 `regs()`（VM-exit 汇编 trampoline 更新的 guest_regs），RIP/RSP/RFLAGS 取自 `last_exit_*` 缓存值。2155-2157：若 `!last_exit_valid()`（首次 VM-exit 前），返回 `None` 表示"尚无 post-run 状态"，避免用零值覆盖 host 设的 entry 状态。

### `soft_ple_reset`（line 2185-2192）
清该 vCPU 软件 PLE 跟踪（两个 RIP 窗口置 `u64::MAX`、streak=0）。在 `soft_ple_maybe_park` 的早退路径和每次新 KVM_RUN 入口调用，使 streak 只统计不间断的 in-window 退出。

## 十五、in-kernel MMIO 与 CPU-up（line 2194-2328）

### `handle_x86_inkernel_mmio_read`（line 2194-2223）/ `handle_x86_inkernel_mmio_write`（line 2225-2243）
先 `find_mmio_dev(addr)` 判定 in-kernel 是否有此 MMIO 设备，无则 `-EOPNOTSUPP`。读路径 `handle_mmio_read` 后按 `signed_ext` 做符号扩展或按 `reg_width` 掩码，`set_gpr` 回填；写路径 `handle_mmio_write`。

### `handle_x86_cpu_up_exit`（line 2250-2328，unsafe）
处理 AP 上线（SIPI）退出。返回 `CpuUpRunAction`（枚举 line 2245-2248：继续当前 run / 返回 CpuUp 退出给 C）。
- 2261-2268：记 cpu_up 日志。
- 2270-2286：取目标 vCPU 与目标槽，缺失记日志返 `-EINVAL`。
- 2288-2305（**重复 SIPI 去重**）：若目标已 `sipi_started`，记 duplicate_sipi、调 `make_internal_run_progress` 后 `ContinueCurrentRun`（不重复上线）。
- 2307-2321：`setup_x86_ap_vcpu_entry(target, entry_point)`——设置 AP 入口，成功置 `sipi_started=true`，失败记日志返回。
- 2323-2327：清游标、填 `reason=CPU_UP`、`addr=target_cpu`、`data=entry_point`，返回 `ReturnCpuUpExit`（让 C 知道有新 vCPU 要 run）。

## 十六、映射标志与 VM 查表（line 2330-2380）

- `AXKVM_MAP_RDONLY`（2333，BIT(31)）/ `KVM_MEM_READONLY`（2335，BIT(1)）：只读映射标志。
- `ram_mapping_flags`（2337-2347）：默认 `READ|EXECUTE|USER`，若两个只读位都没置才加 `WRITE`。
- `axvm_for_vm_id`（2349-2362，**关键锁**）：VM 查表。**持 `VM_REGISTRY_LOCK` 跨越可见性检查与 Arc clone**（注释 2351-2353），使并发的 `destroy_vm` 不能在"读 booted"与"clone()"之间丢掉最后一个引用（那正是 UAF）。仅当 `in_use && booted` 时 `vm.clone()`。
- `ax_result_to_errno`（2364-2369）：把 `AxError` 转成负 Linux errno。
- `bridge_errno_label`（2371-2380）：把 errno 转成可读标签字符串（供日志）。

## 十七、per-CPU VMX 使能：`enter_percpu` / `leave_percpu`（line 2382-2423）

### `enter_percpu`（line 2382-2417，unsafe）
- 2384：`migrate_disable()`——先钉住当前 CPU。
- 2386-2394：取 `cpu_id`，越界则 migrate_enable 后返 `-EINVAL`。
- 2396-2404：若该 CPU 的 `PERCPUS[cpu_id]` 未初始化则 `init(cpu_id)`。
- 2406-2416：若尚未 enable 则 `hardware_enable()`（VMXON）；失败 migrate_enable 后返错。
返回 0 表示已在本 CPU 上使能 VMX 且迁移已禁用。

### `leave_percpu`（line 2419-2423，unsafe）
只 `migrate_enable()`，返回 0。VMCS 的 unbind 由 `run_vcpu_raw` 内部的 `vcpu.unbind()` 负责，故这里只解迁移锁。

---

（下一批：config 构建、状态转换/下刷、页映射重放、生命周期导出函数、run_vcpu 主循环、完成/注入/timer 导出。）

---

## 十八、VM 配置构建与状态转换（line 2425-2665）

### `find_primary_vcpu_entry`（line 2425-2443）
找 vCPU 0 的入口点：优先 `regs.rip`，其次 `rip` 字段，都为 0 返回 0。

### `build_axvm_config`（line 2445-2506）
把 `BackendVm` 翻译成 `AxVMCrateConfig`：
- 2451-2457：设 id/name（`axkvm-{id}`）/vm_type=Linux/cpu_num/entry_point。
- 2458-2462：中断模式——`irqchip_created` 则 `Emulated`，否则 `NoIrq`。
- 2468-2475：**无条件 push 一个 in-kernel COM1 serial 设备**。注释（2463-2467）说明 KVM-backend 模式吃掉 COM1 是为避免"每退出一字节"的串口路径拖慢 SMP bringup（会破 Firecracker 2-vCPU 的调试日志场景）。
- 2476-2493：`irqchip_created` 时 push ioapic（0xfec00000）与 pic。
- 2494-2503：`pit_created` 时 push pit。

### `convert_segment`（2508-2523）/ `convert_dtable`（2525-2530）
把 `BackendSegment`/`BackendDtable` 的 u32 平坦字段转成 `X86KvmSegment`/`X86KvmDtable`（bool/u8/u16 类型化）。

### `reset_vcpu_slot_in_place`（line 2532-2577，unsafe）
把一个 `VCPUS` 槽逐字段清零（含段/dtable/cpuid/msr 数组循环清空、fxsave 清零、游标清空、`sipi_started=false`）。创建/销毁 vCPU 时调用。

### `build_kvm_vcpu_state_box`（line 2579-2665）
把 `BackendVcpu` 缓存组装成堆上的 `X86KvmVcpuState`（供下刷给 axvm）。用 `Box::new_uninit()` + `ptr::addr_of_mut!().write()` 逐字段就地写（避免大结构栈拷贝）：GPR（`GeneralRegisters::from_kvm_regs`）、RIP/RSP/RFLAGS、CR0-8/EFER/apic_base/xcr0、fxsave、段（8）、dtable（2）、cpuid（按 `cpuid_nent` 截断到 `X86_KVM_MAX_CPUID_ENTRIES`，其余填 default）、msr（同理），最后 `assume_init()`。

### `log_vcpu_state`（line 2667-2717）
调试日志：打印 vCPU 的 rip/rsp/rflags/控制寄存器/gdt/idt 及 8 个段的完整字段。

## 十九、状态下刷与 MMIO/IO 完成（line 2719-2893，均 unsafe）

### `apply_vcpu_state_if_booted`（line 2719-2760）
把某 vCPU 的脏状态下刷到已 boot 的 axvm。
- 2720-2732：`in_use` 校验；VM 未 boot 或 `!state_dirty` 直接返 0（无事可做）。
- 2733-2740（**SIPI 后跳过陈旧脏状态**）：若 `sipi_started`，说明 AP 已由 CpuUp 设了入口，host 后续的 SET_* 是陈旧的，清 `state_dirty` 后返 0 不下刷。
- 2741-2759：查 axvm→`build_kvm_vcpu_state_box`→`log`→`apply_x86_kvm_vcpu_state`；成功清 `state_dirty`。

### `apply_vm_vcpu_states_for_boot`（line 2762-2798）
boot 时遍历该 VM 所有脏 vCPU 逐个下刷（同 build+apply），任一失败记日志返回。

### `complete_pending_mmio_read`（line 2800-2846）
用户态 MMIO 读回填：校验 `pending.active` 与 `len` 匹配→`mmio_read_value` 拼值→按 `signed_ext`/`reg_width` 处理→查 vCPU `set_gpr(pending.reg, value)`→清游标。

### `complete_pending_io_read`（line 2848-2893）
用户态 PIO 读回填：类似，但走 `complete_x86_io_read`（PIO 值可能落多个寄存器/串行端口，由 axvm 处理）。

## 二十、页映射与 IOAPIC 重定向表应用（line 2895-2945，均 unsafe）

- `map_page_into_axvm`（2895-2907）：`axvm.map_region(gpa, hpa, 4K, ram_mapping_flags(flags))` 的封装。
- `replay_page_mappings`（2909-2920）：遍历 `PAGE_MAPPINGS`，把属于该 VM 的项逐一 `map_page_into_axvm`（boot 时重建 EPT）。
- `apply_ioapic_redirection_table`（2922-2945）：`irqchip_created` 时把 `BackendVm.ioapic_redirtbl` 快照逐条 `x86_ioapic_set_redirection_entry` 应用，记日志。

---

## 二十一、生命周期导出函数 `axvisor_kvm_rs_*`（line 2947-3881）

这些是 C 主体驱动 VM/vCPU 生命周期的 ABI（`#[unsafe(no_mangle)] pub extern "C"`）。

- `backend_init`（2947-2950）/ `backend_exit`（2952-2953）：目前均空/返 0。
- `create_vm`（2955-2976）：在 `VMS` 找空槽，`empty()` 初始化 + `in_use=true`，`*backend_vm = index+1`；满则 `-ENOSPC`。
- `destroy_vm`（2978-3008，**关键锁**）：
  - 2987：`cancel_kvm_timers_for_vm` 清该 VM 所有 timer。
  - 2988-2994：清该 VM 的 PAGE_MAPPINGS。
  - 2995-3006（注释 2995-2998）：**持 `VM_REGISTRY_LOCK`** 撤销可见性（`booted=false`）并 `vm.take()` 取出 Arc、清空槽；**在锁外 `drop(old_vm)`**——因为 Arc 的 Drop 可能跑任意 teardown/睡眠，不能在 IF=0 窗口里跑。
- `set_vm_state`（3010-3057）：把 C 传来的 irqchip/pit/tss/identity_map/ioapic_redirtbl 等写进 `VMS[index]`（含 redirtbl 从裸指针拷入，截断到 24）。
- `map_page_nolog`（3063-3093）：**惰性 fault-in 专用**——只 `map_page_into_axvm`，**不进 PAGE_MAPPINGS 重放表**。注释（3059-3062）：gvisor 的巨大稀疏 slot 会溢出 262K 表，且这些页 boot 后才出现无需重放。
- `map_page`（3095-3151）：正常 memslot 映射——先 `map_page_into_axvm`，再在 PAGE_MAPPINGS 里 upsert（已存在同 gpa 则更新 hpa/flags，否则占首个空槽，`page_mapping_count++`），满返 `-ENOSPC`。
- `unmap_range`（3153-3196）：`axvm.unmap_region(gpa, size)` 后清区间内 PAGE_MAPPINGS 项（对齐校验、`page_mapping_count` 递减）。
- `create_vcpu`（3198-3233）：`VMS[vm_index]` 在用→在 `VCPUS` 找空槽 `reset_vcpu_slot_in_place` 后设 in_use/vm_handle/id，`vcpu_count = max(cur, id+1)`，`*backend_vcpu = index+1`；满 `-ENOSPC`。
- `destroy_vcpu`（3235-3261）：重算该 VM 的 `vcpu_count`（扫其余 vCPU 取 max id+1）后 `reset_vcpu_slot_in_place`。
- `set_vcpu_state`（3263-3307）：写 rip/rsp/rflags/CR/EFER/apic_base/xcr0/cpuid_nent/nmsrs/tsc_khz，置 `state_dirty=true`。
- `dbg_backend_rip`（3315-3344，**DIAG**）：task#99 只读诊断——返回后端 VMX 缓存的 last_exit_rip，供 C 与 KVM_GET_REGS 返回的 `vcpu->regs.rip` 比对，坐实 shim 是否未把真实 post-run RIP 同步回去（疑似 gvisor HLT-spin 根因）。纯读、无行为改变。
- `get_vcpu_regs`（3357-3426）：**寄存器回流的另一半**（KVM_GET_REGS）。注释（3346-3356）：`set_vcpu_regs` 把 host 状态推进后端，本函数把后端真实 guest 寄存器拉回；gvisor 这类 userspace-irqchip VMM 用 HLT 做 guest-ring0→用户态上下文切换出口，依赖 KVM_GET_REGS 返回**已推进**的寄存器，否则 shim 返回陈旧 `vcpu->regs` 缓存导致 gvisor 原地重进同一 RIP 自旋。逻辑：校验所有出参非空→查 vCPU→`current_guest_regs`（`None` 返 `-ENODATA`）→逐个写出 18 个寄存器。这是 task#100 的落地。
- `set_vcpu_regs`（3428-3484）：把 18 个 GPR/RIP/RFLAGS 写进 `BackendRegs`，置脏。
- `set_vcpu_sregs_control`（3486-3520）：写 CR0/2/3/4/8、EFER、apic_base 到 `BackendSregs`，置脏。
- `set_vcpu_segment`（3522-3571）：写第 `segment_id` 个段（越界 `-EINVAL`），置脏。
- `set_vcpu_dtable`（3573-3599）：写 GDT/IDT（`table_id` 0/1），置脏。
- `set_vcpu_cpuid_entry`（3601-3640）：写第 `entry_index` 条 CPUID（越界 `-EINVAL`），置脏。
- `set_vcpu_msr_entry`（3642-3668）：写第 `entry_index` 条 MSR，置脏。
- `set_vcpu_fpu`（3670-3727）：从 KVM_SET_FPU 各字段组装 512 字节 FXSAVE（校验 fpr/xmm 长度、mxcsr 合法位），置 `fxsave_valid`+脏。
- `set_vcpu_xsave_legacy`（3729-3767）：从 KVM_SET_XSAVE 的前 512 字节 legacy 区拷 FXSAVE（mxcsr_mask 为 0 时补默认），置 `fxsave_valid`+脏。

### `boot_vm`（line 3769-3881）
把已配置的 VM 真正启动。逐块：
- 3781-3783：已 booted 幂等返 0。
- 3784-3794：`build_axvm_config` + 记 begin 日志。
- 3795-3807：`AxVM::new(config)`——创建 axvm 本体，失败记日志返回。
- 3808-3818：`replay_page_mappings`——重建 EPT。
- 3819：`set_current_vcpu_context(vm, 0)`。
- 3820-3830：`enter_percpu()`（VMXON）。
- 3831-3841：`axvm.init()`（失败 leave_percpu 返回）。
- 3842-3847：`apply_vm_vcpu_states_for_boot` 下刷所有脏 vCPU 状态 + `apply_ioapic_redirection_table`。
- 3848-3858：`axvm.boot()`。
- 3859-3869：`leave_percpu()`。
- 3870-3877（**publish 锁**）：持 `VM_REGISTRY_LOCK` 同时设 `vm = Some(axvm)` 与 `booted = true`，使并发的 `axvm_for_vm_id`（如 timer workfn）看到一致的 (vm=Some, booted=true) 对，绝不撕裂。

---

## 二十二、`run_vcpu` 主循环（line 3883-4396）

这是最核心的导出函数：一次 `KVM_RUN` ioctl 的后端实现。

### 入口准备（line 3883-3948）
- 3892-3899：校验 5 个出参指针非空。
- 3908-3924：`reset_backend_exit_outputs`（默认 FAIL_ENTRY）；校验 vCPU/VM in_use 且 booted；`axvm_for_vm_id` 取 Arc。
- 3925：`set_current_vcpu_context`。
- 3926-3934：`enter_percpu()`（VMXON）；`apply_vcpu_state_if_booted` 下刷脏状态。
- 3936-3940：`run_retry_count=0`；`soft_ple_reset`——新 KVM_RUN 入口意味着 C 处理了一个真实进度边界（HLT wake/MMIO/IO/CpuUp），干净重置软件 PLE 检测器。
- 3945-3948：`spin_restore`——若此 vCPU 曾被降级为 SCHED_IDLE 自旋者，跨过真实进度边界后恢复正常优先级（幂等）。

### 内层 `loop`（line 3949-4388）
每轮：
- 3950-3961：`run_retry_count==0` 时**有界**记 enter 日志（前 256 次，防 flood）。
- 3962-3966：`guest_fpu_begin()`（保存 host FPU、加载 guest FPU），失败 leave_percpu 返回。
- 3967-3998（**DIAG**）：gvisor signal-interruptibility 探针，前 24 次 entry 在 `run_vcpu_raw` 前后各记一条 `gv_resume before/after`，附 `signal_pending()`——用于判断某次 vmresume 是否进 guest 且是否返回，以及 gvisor 是否送了 SIGURG。**纯诊断，非功能逻辑。**
- 3986：`run_result = axvm.run_vcpu_raw(id)`——**真正进 guest**（bind VMCS→VMRESUME→VM-exit→unbind）。
- 3999：`guest_fpu_end()`（恢复 host FPU）。
- 4000-4005：按 `should_log_raw_exit` 有条件记 raw exit。
- 4007-4387：`match run_result` 分派各 `AxVCpuExitReason`：

  - **`Nothing` / `ExternalInterrupt`**（4008-4021）：`soft_ple_maybe_park`（自旋检测）→`make_internal_run_progress`→`continue`（不出核）。
  - **`Yield`**（4022-4048）：硬件 PLE 触发。注释（4023-4032）：directed-yield 本核给可运行兄弟（best-effort），然后 `make_internal_run_progress` 的 migrate-drop + reschedule 边界给 CFS 机会重平衡且保持线程 RUNNABLE（不 block-park）→`continue`。
  - **`InterruptEnd { vector }`**（4049-4069）：`vector.is_some()`→`complete_x86_external_eoi`（处理 level-triggered 重断言）；`None`（guest 无进度重退出，超订下自旋 AP 循环点）→`soft_ple_maybe_park`。然后 `make_internal_run_progress`→`continue`。
  - **`PreemptionTimer`**（4070-4086）：同样 `soft_ple_maybe_park`（confined 到 ≤2 窗口即视为自旋/空闲振荡）→progress→continue。
  - **`MmioRead`**（4087-4129）：先 `handle_x86_inkernel_mmio_read`（in-kernel 设备）；`handle_inkernel_progress_result` 决定 continue（已处理）/ 落用户态（`-EOPNOTSUPP`）/ Err。落用户态则 `prepare_userspace_mmio_read_exit` 后 `break`（返回 C）。
  - **`MmioWrite`**（4130-4162）：对称。
  - **`IoRead`**（4163-4196）/ **`IoWrite`**（4197-4228）：对称的 PIO 版本。
  - **`Halt`**（4229-4244）：`expire_due_kvm_timers` + `progress_x86_virtual_irqs` + `arm_x86_idle_wakeup_timer`（注释 4232-4239：嵌套下无 VMX 抢占定时器，空闲 `sti;hlt` guest 无周期退出会冻 PIT/jiffies，故编排 host hrtimer 按 PIT deadline 唤醒）→清游标、`reason=HLT`、`break`。
  - **`SystemDown`**（4245-4249）：`reason=SHUTDOWN`、break。
  - **`FailEntry`**（4250-4261）：记日志、`reason=FAIL_ENTRY`、写 `hardware_entry_failure_reason`、break。
  - **`CpuUp`**（4262-4285）：`handle_x86_cpu_up_exit`；按返回 `ContinueCurrentRun`（continue）/ `ReturnCpuUpExit`（break）/ Err（leave_percpu 返回）。
  - **`Hypercall`**（4286-4316）：KVM PV hypercall（VMCALL）。注释（4287-4294）：广告了 KVM CPUID 签名（供 kvm-clock），guest 可能探 PV 服务，但均未实现；镜像原生 KVM 默认路径——把 `-KVM_ENOSYS`（1000 取负）写入 rax（`set_gpr(0, ...)`）让 guest 优雅回退原生路径（APIC IPI、raw TSC），不杀 VM。然后 progress→continue。
  - **`NestedPageFault { addr, access_flags }`**（4317-4369，**惰性 fault-in**）：注释（4321-4330）关键——NestedPageFault 抵达外层循环**仅当** `run_vcpu_raw` 的 lock-free slot 探测找到了 backing memslot（slotless GPA 在 `run_vcpu_raw` 内部 VMCS 绑定时就被解码成 MMIO 了）。所以这是惰性映射的 RAM：在 `vm->lock` 下 pin 页并映进 EPT。这段跑在 `guest_fpu_end()` 之后（脱离 kernel_fpu preempt+BH-disabled 窗口），故 `fault_in_gpa` 里的睡眠锁安全（task#101）。逻辑：
    - 4331：`write = access_flags.contains(WRITE)`。
    - 4335-4351（**DIAG**）：前 60 次记 `gv_npf` 日志（faulting GPA + flags），观察哪些页被 fault-in 及是否同 GPA 以不同 access 重复 fault。**诊断用途。**
    - 4352-4356：`axvisor_kvm_x86_bridge_fault_in_gpa(vm, gpa, write)`——C 侧完成 pin + map（内部实现 slot 优先 / MMIO / VM_IO remapped 三路径分派，见 C 文件）。
    - 4357-4358：`rc==0`（已映射）→`continue` 重进 guest。
    - 4360-4368：`rc<0`（pin/map/OOM 或竞态 slot 移除）→清游标、记 unresolved 日志、`reason=INTERNAL_ERROR`、break。
  - **`Ok(other)`**（4370-4378）：未支持退出——记日志、`reason=INTERNAL_ERROR`、break。
  - **`Err(err)`**（4379-4386）：`run_vcpu_raw` 出错——leave_percpu、记日志、返回 err。

### 出核收尾（line 4389-4396）
`break` 出循环后 `leave_percpu()`（失败返错），返回 0。注意 `continue` 路径永不到这里；只有需要返回 C 的退出（MMIO/IO/HLT/CpuUp/shutdown/error）才 break。

---

## 二十三、完成回填 / IRQ 注入 / timer drain 导出（line 4398-4532）

- `complete_mmio_read`（4398-4412）：转发 `complete_pending_mmio_read`（用户态处理完 MMIO 读后回填 guest 寄存器）。
- `complete_io_read`（4414-4428）：转发 `complete_pending_io_read`。
- `inject_irq`（4430-4518）：IRQFD/用户态注入一个 GSI。逻辑分层回退：
  - 4447-4456：`gsi < 24` 时先试 IOAPIC（`x86_ioapic_assert_gsi`），命中即 `inject_x86_ioapic_irq` 返 0。
  - 4458-4477：IOAPIC 无该 GSI 的重定向条目时，写一个 fallback 条目（vector `0x20+gsi`）后重试断言。
  - 4480-4517：再回退到通用 `axvm.inject_x86_gsi`；失败再尝试 IOAPIC fallback 条目重注、最后 `gsi<16` 时回退 PIC（`inject_x86_pic_irq`）。层层记日志。
- `axvisor_kvm_x86_bridge_expire_all_due_timers`（4529-4532）：**非 `_rs_` 前缀导出**，供 C 的 `axkvm_backend_timer_workfn`（hrtimer workqueue 进程上下文）调用，直接转发 `expire_all_due_timers()`。注释（4520-4528）：让超订下被饿死离核的 vCPU 也能靠 workqueue 线程 drain+re-arm+inject 自己的周期 tick，不依赖该 vCPU 被调度上核；每个回调用自己捕获的 id 注入，不需当前运行上下文。

---

## 附：诊断插桩（DIAG）汇总

本文件遗留以下明确标注 DIAG / 诊断用途、**非功能逻辑**的插桩，日后清理时可整体移除：

1. `extern` 符号 `axvisor_kvm_x86_bridge_signal_pending`（line 206-208）——gvisor signal 探测。
2. `extern` 符号 `axvisor_kvm_x86_bridge_note_ap_alive_spin`（line 211，本文件未见调用点）。
3. `axvisor_kvm_rs_dbg_backend_rip`（line 3315-3344）——task#99 只读 RIP 比对。
4. `run_vcpu` 内 `gv_resume before/after` 探针（line 3967-3998）——前 24 次 vmresume 的进入/返回 + signal_pending 记录。
5. `run_vcpu` 内 `gv_npf` 探针（line 4335-4351）——前 60 次 NestedPageFault 的 GPA/flags 记录。

（`get_vcpu_regs` line 3357-3426 与 `set_vcpu_regs` 是正式功能 ABI，非诊断，尽管其注释提到 gvisor 调试背景。）
