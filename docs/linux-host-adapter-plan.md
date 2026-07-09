# AxVisor Linux 宿主适配层计划

本文档用于规划一层 Linux 侧的中间层，使 `AxVisor` 可以在 Linux
内核中运行，同时保持我们已经固定下来的 30 个接口面不变。

这里的目标不是机械照搬 Asterinas 的实现细节，而是：

- 对上继续提供同样的 30 个函数
- 对下使用 Linux 内核原语和 Linux 侧的 RISC-V hypervisor backend
- 保证接口语义与当前 Asterinas 侧实现尽量等价

## 一、范围

本文档沿用已经固定的 30 个函数范围：

- runtime glue：`1-3`
- `HostIf`：`4-6`
- `ConsoleIf`：`7-8`
- `TimeIf`：`9-10`
- `SyncIf`：`11-16`
- `TaskIf`：`17-20`
- `IrqIf`：`21-22`
- `MemoryIf`：`23-28`
- `ArchIf`：`29-30`

本文档只讨论 Linux 侧如何围绕这 30 个函数构建宿主适配层。
同时也会标出哪些函数虽然在这 30 个函数之内，但实现时需要预留更深一层的架构后端钩子。

## 二、总体原则

Linux 侧建议拆成两层：

1. `axvisor_linux_host`
   - 直接对 `axvisor_core` 暴露这 30 个函数
   - 屏蔽 Linux 内核内部实现细节
2. `linux_arch_hyp`
   - 提供架构相关的底层钩子
   - 第一阶段重点是 `riscv64`

可以把它理解成：

- 第一层是“语义适配层”
- 第二层是“架构后端层”

## 三、建议的模块布局

建议 Linux 侧先按下面的方式组织：

```text
axvisor_linux_host/
  runtime.rs
  host.rs
  sync_task.rs
  irq.rs
  memory.rs
  arch/
    mod.rs
    riscv64.rs
```

建议的职责划分：

- `runtime.rs`
  - 对应 `1 2 3`
- `host.rs`
  - 对应 `4 5 6 7 8 9 10 29 30`
- `sync_task.rs`
  - 对应 `11-20`
- `irq.rs`
  - 对应 `21-22`
- `memory.rs`
  - 对应 `23-28`
- `arch/riscv64.rs`
  - 给 `5 10 21 29 30` 提供架构相关钩子
  - 后续承接 guest entry、trap glue 等更深层能力

这样做的目的有两个：

- 先把 30 个显式接口收口到一层统一中间层中
- 避免后续 `riscv64` hypervisor backend 的复杂逻辑直接污染通用封装层

## 四、30 个函数的分类

这 30 个函数不应该全部用同一种方式实现。
建议先分成三类。

### A 类：可直接包裹 Linux 原语

这类函数预期可以比较直接地映射到 Linux 内核原语：

- `1. KernelTaskRuntime::spawn_task`
- `2. install_kernel_task_runtime`
- `4. HostIf::get_host_cpu_num`
- `7. ConsoleIf::write_bytes`
- `9. TimeIf::current_time_nanos`
- `11. SyncIf::create_wait_queue`
- `12. SyncIf::destroy_wait_queue`
- `13. SyncIf::wait_queue_wait`
- `14. SyncIf::wait_queue_wait_until`
- `15. SyncIf::wait_queue_wake_one`
- `16. SyncIf::wait_queue_wake_all`
- `17. TaskIf::spawn_task_raw`
- `18. TaskIf::join_task`
- `19. TaskIf::current_task`
- `20. TaskIf::yield_now`
- `22. IrqIf::register_irq_handler`

典型可用的 Linux 原语：

- `kthread`
- `task_struct`
- `cpumask`
- `wait_queue_head_t`
- `wake_up` / `wake_up_all`
- `schedule`
- `ktime_get_ns`
- `printk`

### B 类：语义适配型函数

这类函数在 Linux 中也能实现，但不能只做“函数名对函数名”的映射，必须先把运行语义写清楚：

- `3. run`
- `5. HostIf::init_percpu`
- `6. HostIf::exit`
- `8. ConsoleIf::read_bytes`
- `10. TimeIf::set_oneshot_timer`
- `21. IrqIf::handle_irq`
- `29. ArchIf::host_fdt_paddr`
- `30. ArchIf::host_tsc_frequency_mhz`

这类函数的关键不是“Linux 有没有类似 API”，而是：

- Linux 侧到底采用什么运行策略
- 何时调用
- 在哪个上下文调用
- 最终要保证什么语义

### C 类：内存约束型函数

这类函数表面上看起来简单，但不能零散实现，必须先设计一层统一的 host memory manager：

- `23. MemoryIf::alloc_frame`
- `24. MemoryIf::alloc_contiguous_frames`
- `25. MemoryIf::dealloc_frame`
- `26. MemoryIf::dealloc_contiguous_frames`
- `27. MemoryIf::phys_to_virt`
- `28. MemoryIf::virt_to_phys`

原因是这几项必须共享同一套：

- 分配策略
- 所有权跟踪
- 地址转换语义
- 释放校验逻辑

不能把它们当成互不相关的单独 wrapper。

它们在 Linux 当前骨架中的内部映射可以直接记成：

- `23` -> `axvisor_adapter_alloc_frame`
- `24` -> `axvisor_adapter_alloc_contiguous_frames`
- `25` -> `axvisor_adapter_dealloc_frame`
- `26` -> `axvisor_adapter_dealloc_contiguous_frames`
- `27` -> `axvisor_adapter_phys_to_virt`
- `28` -> `axvisor_adapter_virt_to_phys`

## 四点五、当前实现状态

下面这个状态只描述 `linux-host-kernel/drivers/virt/axvisor/` 当前已经落下去的代码，
不代表接口已经达到可用或可验证状态。

- `已做骨架`
  - `1. KernelTaskRuntime::spawn_task`
  - `2. install_kernel_task_runtime`
  - `3. run`
  - `4. HostIf::get_host_cpu_num`
  - `5. HostIf::init_percpu`
  - `6. HostIf::exit`
  - `7. ConsoleIf::write_bytes`
  - `8. ConsoleIf::read_bytes`
  - `9. TimeIf::current_time_nanos`
  - `10. TimeIf::set_oneshot_timer`
  - `11. SyncIf::create_wait_queue`
  - `12. SyncIf::destroy_wait_queue`
  - `13. SyncIf::wait_queue_wait`
  - `14. SyncIf::wait_queue_wait_until`
  - `15. SyncIf::wait_queue_wake_one`
  - `16. SyncIf::wait_queue_wake_all`
  - `17. TaskIf::spawn_task_raw`
  - `18. TaskIf::join_task`
  - `19. TaskIf::current_task`
  - `20. TaskIf::yield_now`
  - `21. IrqIf::handle_irq`
  - `22. IrqIf::register_irq_handler`
  - `23. MemoryIf::alloc_frame`
  - `24. MemoryIf::alloc_contiguous_frames`
  - `25. MemoryIf::dealloc_frame`
  - `26. MemoryIf::dealloc_contiguous_frames`
  - `27. MemoryIf::phys_to_virt`
  - `28. MemoryIf::virt_to_phys`
  - `29. ArchIf::host_fdt_paddr`
  - `30. ArchIf::host_tsc_frequency_mhz`
- `未做`

这里特别说明一下：

- `17-20` 目前已经进入“Linux task adapter 基本语义实现”
- `4-10` 目前已经不是纯占位壳，但仍有强弱之分
- `11-16` 目前已经升级成“带 handle 和 registry 的 wait queue 骨架实现”
- `21-22` 目前已经进入“IRQ handler 表 + arch backend + runtime glue”的半成品实现
- `23-28` 目前已经升级成“带分配记录表的 memory 骨架实现”，但还远不是最终版
- `2-3` 目前已经进入“runtime hook 安装 + 启动入口 glue”的半成品实现
- `1` 目前已经不是“最小路径”，而是“按 CPU affinity 创建 kthread + TaskState/registry”的基本实现
- `29-30` 目前已经是可返回宿主架构信息的直接导出接口
- `8` 目前已经有 adapter 自己的非阻塞 console input buffer，但还没接到真实 Linux console/tty 输入源
- 当前 console input buffer 也已经开始采用固定上限，避免输入路径无限累积
- `6` 目前已经会记录宿主退出请求和退出码，而且退出码记录已开始保持有符号语义

所以如果按严格口径统计：

- `已完整实现`: `0`
- `已做骨架`: `30`
- `尚未开始`: `0`

为了后续讨论更直接，当前再按“完成度”补一版更实用的分类：

- `基本语义已实现`
  - `1. KernelTaskRuntime::spawn_task`
  - `4. HostIf::get_host_cpu_num`
  - `7. ConsoleIf::write_bytes`
  - `9. TimeIf::current_time_nanos`
  - `11. SyncIf::create_wait_queue`
  - `12. SyncIf::destroy_wait_queue`
  - `13. SyncIf::wait_queue_wait`
  - `14. SyncIf::wait_queue_wait_until`
  - `15. SyncIf::wait_queue_wake_one`
  - `16. SyncIf::wait_queue_wake_all`
  - `17. TaskIf::spawn_task_raw`
  - `18. TaskIf::join_task`
  - `19. TaskIf::current_task`
  - `20. TaskIf::yield_now`
  - `23. MemoryIf::alloc_frame`
  - `24. MemoryIf::alloc_contiguous_frames`
  - `25. MemoryIf::dealloc_frame`
  - `26. MemoryIf::dealloc_contiguous_frames`
  - `27. MemoryIf::phys_to_virt`
  - `28. MemoryIf::virt_to_phys`
  - `29. ArchIf::host_fdt_paddr`
  - `30. ArchIf::host_tsc_frequency_mhz`
- `半成品 glue`
  - `2. install_kernel_task_runtime`
  - `5. HostIf::init_percpu`
  - `6. HostIf::exit`
  - `8. ConsoleIf::read_bytes`
  - `10. TimeIf::set_oneshot_timer`
  - `21. IrqIf::handle_irq`
  - `22. IrqIf::register_irq_handler`
- `仅形成形状/待接真实 AxVisor core`
  - `3. run`

如果按“能不能开始承接后续联调”再补一版更贴近当前代码状态的分类，可以写成：

- `可联调层级`
  - `1. KernelTaskRuntime::spawn_task`
  - `4. HostIf::get_host_cpu_num`
  - `5. HostIf::init_percpu`
  - `7. ConsoleIf::write_bytes`
  - `9. TimeIf::current_time_nanos`
  - `10. TimeIf::set_oneshot_timer`
  - `11. SyncIf::create_wait_queue`
  - `12. SyncIf::destroy_wait_queue`
  - `13. SyncIf::wait_queue_wait`
  - `14. SyncIf::wait_queue_wait_until`
  - `15. SyncIf::wait_queue_wake_one`
  - `16. SyncIf::wait_queue_wake_all`
  - `17. TaskIf::spawn_task_raw`
  - `18. TaskIf::join_task`
  - `19. TaskIf::current_task`
  - `20. TaskIf::yield_now`
  - `21. IrqIf::handle_irq`
  - `22. IrqIf::register_irq_handler`
  - `23. MemoryIf::alloc_frame`
  - `24. MemoryIf::alloc_contiguous_frames`
  - `25. MemoryIf::dealloc_frame`
  - `26. MemoryIf::dealloc_contiguous_frames`
  - `27. MemoryIf::phys_to_virt`
  - `28. MemoryIf::virt_to_phys`
  - `29. ArchIf::host_fdt_paddr`
  - `30. ArchIf::host_tsc_frequency_mhz`
- `可联调但明显依赖后续接线`
  - `2. install_kernel_task_runtime`
  - `6. HostIf::exit`
  - `8. ConsoleIf::read_bytes`
- `仍是核心 hook`
  - `3. run`

这版分类的意思是：

- `可联调层级`
  - 这些接口的 Linux 侧中间层形状已经比较稳定
  - 后面即使继续补真实 AxVisor core，也更像“把真实逻辑塞进既有结构里”
  - 而不是把适配层整体推翻重写
- `可联调但明显依赖后续接线`
  - 这些接口本身可以参与联调
  - 但仍然强依赖真实输入源、宿主退出策略或上层 runtime 安装场景
- `仍是核心 hook`
  - 这类接口现在最大的价值是把未来真实入口位置固定下来
  - `3` 当前即使走 fallback，也已经会先统一经过 `AxvisorCoreGlue::record_runtime_start()`
  - 这样后续把 fallback 换成真实 `axvisor_core::boot::run()` 时，不需要再整理一套新的记录路径
  - `3` 当前也已经开始显式记录最小启动边界状态：
    - `runtime_start_prepared`
    - `runtime_start_entered`
    - `runtime_start_returned`
  - 这样后续即使真实入口出现“提前返回”或“根本没进入核心启动逻辑”，也能先在 adapter 层看到
  - `3` 当前的 runtime start hook 也已经开始按更接近真实入口包装的方式拆层：
    - `prepare_runtime_start`
    - `invoke_runtime_start_core`
    - `finalize_runtime_start`
  - 后续把中间的 `invoke_runtime_start_core` 换成真实 `axvisor_core::boot::run()`，
    整体包装层次不需要再改
  - 当前 `invoke_runtime_start_core` 也已经进一步经由一个
    `runtime_core_entry_invoker` dispatcher 取到真正的 core 入口调用点
  - 后续如果要接真实 `axvisor_core::boot::run()`，
    优先只改这个 dispatcher 的返回目标，而不是改外层启动流程

这份分类的含义是：

- `基本语义已实现`
  - 这些接口已经有比较明确且自洽的 Linux 侧行为
  - 即使后面内部实现要继续打磨，也不太需要整体推翻接口内层结构
- `半成品 glue`
  - 这些接口已经开始具备 Linux 侧运行语义
  - 但还明显依赖后续 arch backend、真实输入源或 AxVisor handoff 逻辑补全
- `仅形成形状/待接真实 AxVisor core`
  - 这类接口目前主要价值是把未来真实接线点和上下文结构先固定下来

对 `23-28` 再补一条更准确的说明：

- 当前 `alloc_frame` / `alloc_contiguous_frames` 成功后，都会在适配层自己的
  `axvisor_memory_records` 链表里登记一条记录
- 记录项包含：
  - `paddr`
  - `vaddr`
  - `num_frames`
  - `size_bytes`
  - `kind`
  - `page`
- `dealloc_*` 会先按 `paddr` 找记录，再校验类型和页数
- `phys_to_virt` / `virt_to_phys` 现在只保证 adapter 自有内存的转换，不再做宽泛 fallback
- 连续页分配当前也开始把“真实分配字节数”写进记录，释放和 vaddr 覆盖范围判断统一以记录值为准

因此，严格说法应该是：

- `23-28` 已经不是“空壳”
- 但仍然只是“ownership tracking + address translation skeleton”
- 距离真正可供 AxVisor 长期依赖的 host memory manager 还有明显差距
- 当前 `27/28` 也开始收紧成“只保证 adapter 自有内存”的方向

对 `1 / 17 / 18 / 19 / 20` 当前也补一条更准确的说明：

- 这组接口已经不再只是“直接把 Linux kthread 裸露给上层”
- 当前骨架开始转向和 Asterinas 类似的语义：
  - 线程由 runtime 创建
  - 适配层自己维护 `TaskHandle`
  - `join` 依赖适配层自己的 `TaskState + CondVar`
  - 等待的是“任务自然完成”，而不是用 `kthread_stop` 强制终止
  - `current_task()` 开始优先从适配层自己的 task registry 反查 handle
  - `spawn_task()` 现在也补上了“先注册 handle，再放行线程体执行”的启动门闩语义
  - `spawn_task()` 的失败回滚路径现在也能显式取消线程启动，不再留下未注册自旋线程

但这组接口仍然没有完成，主要还差：

- 目前 registry 还是一个最小版本
- 只按 `pid` 存放 task handle 记录
- 还没有做更强的生命周期约束和去重策略
- 也还没有和后续 AxVisor vCPU task 生命周期打通

对 `11-16` 当前也补一条更准确的说明：

- 这组接口已经不再要求调用点直接持有 wait queue 对象
- 当前骨架开始转向和 Asterinas 类似的 handle 语义：
  - `create_wait_queue()` 返回整数 handle
  - 适配层自己维护 `WAIT_QUEUE_REGISTRY`
  - `wait` / `wake` 都先按 handle 查表
- 当前底层实现仍然是 `Mutex + CondVar`
- 当前也开始给 wait queue record 维护最小销毁态
- `destroy_wait_queue()` 现在也开始先从 registry 原子摘掉对应 record，再标记 destroyed 并唤醒所有 waiter
- `wait_queue_wait()` / `wait_queue_wait_until()` 现在遇到 destroyed 会主动退出
- `wait_queue_wait_until()` 现在已经改成“条件检查在外层循环进行”，避免把条件闭包长期锁在内部状态锁路径里
- `wait_queue_wake_one()` 现在也开始避免在“没有 waiter”时错误推进内部 wake ticket

但这组接口仍然没有完成，主要还差：

- registry 目前还是最小版本
- 还没有完整的销毁并发保护
- 还没有超时等待扩展
- 也还没有切到 Linux 原生 waitqueue API 语义

对 `5 / 10 / 21 / 22` 当前也补一条更准确的说明：

- 这组接口已经开始从“主文件里的零散占位逻辑”收口到 `arch/riscv64.rs`
- 当前 Linux 骨架已经补了一个最小 `arch backend`：
  - `init_percpu`
  - `set_oneshot_timer`
  - `dispatch_external_irq`
  - `register_irq_vector`
- 适配层主逻辑现在会先调用这些 arch backend 钩子

但这组接口仍然没有完成，主要还差：

- `5`
  - 还没有真实 per-cpu hypervisor-local state
  - 但当前骨架已经不再混淆 `pid` 和 `cpu_id`
- `10`
  - 还没有接到 Linux `hrtimer` 或等价的 per-cpu timer 回调
  - 但已经开始从“单个 deadline 原子值”转向“timer backend state”
  - `riscv64` backend 内已经有 `HrTimer` carrier object 骨架
  - 当前已经会在 backend 内保存 active timer handle，并执行重新启动
  - 当前已经开始显式调用 `HrTimerHandle::cancel()` 处理重编程/取消路径
  - timer backend 现在也开始记录最小生命周期计数：
    - `program_count`
    - `cancel_count`
    - `last_timer_program_cpu_id`
    - `last_timer_cancel_cpu_id`
  - 当前已经开始把“绝对 deadline 纳秒值”转换成相对 timer 延迟
  - 当前也已经不再把 timer 事件的 `cpu_id` 固定写死为 `0`
  - 当前 callback state 里的 `cpu_id` 也已经改成可随当前 CPU 更新，而不是初始化时固定值
  - timer callback 触发后，也已经开始主动清除 deadline / active timer / 对应 CPU event 记录
  - 当前 callback 已经能桥接回 Linux adapter 层的 timer hook
  - adapter 层也已经补了正式的 timer event hook 落点
  - adapter 层进一步补了可注册的 timer event processor 插槽
  - timer event 入口当前也已经开始和 runtime start 一样，收口成单点 dispatcher 形状：
    - `stub_timer_core_entry`
    - `timer_core_entry_invoker`
    - `invoke_timer_event_core`
  - timer 当前也已经开始暴露最小策略态观测，例如是否处于 armed 状态
  - timer 路径当前也已经开始区分“事件到达 glue”与“glue 是否真正消费事件”两层状态
  - timer event 已经开始用正式上下文结构传递，而不只是裸参数
  - adapter 层也开始形成统一的 `AxvisorRuntimeHooks` 安装面
  - 但还没有真正桥接到 AxVisor timer event

对统一 runtime hooks 当前也补一条更准确的说明：

- `AxvisorRuntimeHooks` 已经不再只含 timer processor
- 当前已经开始同时收口：
  - `timer_event_processor`
  - `irq_event_processor`
  - `runtime_start_processor`
- 这意味着 Linux adapter 已经开始从“逐个接口补壳”进入“统一 host runtime glue”阶段
- 当前这些 processor 也开始进一步收口到一个明确的 `AxvisorCoreGlue` 安装点
- 当前 `AxvisorCoreGlue` 已经不只是“空安装点”
  - `timer_event_processor` 已经会记录最近一次 timer 事件上下文
  - `irq_event_processor` 已经会记录最近一次 irq 事件上下文
  - `runtime_start_processor` 已经会消费结构化启动上下文并打印
  - 三个 processor 也已经进一步拆成“记录上下文”和“未来真实 hook site”两层
- 这三类 processor 将来建议分别对接到：
  - `runtime_start_processor`
    - 对应 `axvisor_core::boot::run()` 启动入口
  - `timer_event_processor`
    - 对应 AxVisor 的 timer event 检查入口
    - 目标语义与 Asterinas 的 `axvisor_core::vmm::timer::check_events()` 一致
  - `irq_event_processor`
    - 对应 Linux 宿主收到中断后，决定是否交给 AxVisor 的入口
    - 在 `riscv64` 上应最终承接 external interrupt handoff / guest interrupt inject
- 当前 `runtime_start_processor` 也已经开始使用结构化上下文，而不是零参数调用
- 这类上下文至少已经包含：
  - `host_cpu_num`
  - `current_cpu_id`
  - `kernel_task_runtime_installed`
  - `run_call_index`
- adapter 侧现在也已经记录最近一次 `run()` 的关键上下文快照，便于后续真正接入 `axvisor_core::boot::run()`
- adapter 主层现在也开始显式记录 runtime 启动路径是否经过已安装 processor：
  - `runtime_processor_present`
  - `runtime_processor_invoked`
  - `runtime_fallback_used`
  - `runtime_run_call_index`
- 当前 `irq_event_processor` 也已经开始使用结构化上下文，而不再只是裸 `vector`
- 这类上下文至少已经包含：
  - `vector`
  - `dispatch_external_matched`
  - `call_index`
- irq 路径当前也已经开始区分“external interrupt 已识别”与“glue 是否真正消费事件”两层状态
- adapter 主层现在也开始显式记录 `handle_irq()` 的路径结果：
  - `irq_last_external_match`
  - `irq_last_external_consumed`
  - `irq_last_local_hit`
  - `irq_last_final_result`
- external IRQ 路径现在也开始有一个最小 pending/drain 中间层：
  - `irq_external_pushes`
  - `irq_external_drain_calls`
  - `irq_external_last_drained`
  - `irq_external_pending_depth`
- pending 项本身现在也已经不是裸 `vector`，而是最小 event record：
  - `vector`
  - `cpu_id`
  - `call_index`
- drain 路径现在也已经不再只是“返回 drained 数量”：
  - adapter 会先取出 event 列表
  - 再逐个交给 glue 的 per-event hook
  - 这已经更接近 Asterinas 里的“遍历 pending external interrupt 并逐个处理”的形状
  - external IRQ per-event 入口当前也已经和 `3 / 10` 一样收口成单点 dispatcher：
    - `stub_external_irq_core_entry`
    - `external_irq_core_entry_invoker`
    - `invoke_external_irq_core`
- 适配层当前的 `handle_irq()` 顺序也已经调整成“先 arch backend 识别，再让 runtime glue 决定是否消费，最后再回退到本地 handler”
- 当前 Linux adapter 的 `handle_irq()` 形状也已经开始显式拆成：
  - external interrupt path
  - local handler path
  这样后续把 external path 换成真实 guest interrupt inject 时，主流程不需要再重构
- `21`
  - 还没有接到真实的 RISC-V external interrupt handoff / guest interrupt inject
  - 但 `riscv64` arch backend 里已经开始把 supervisor external interrupt vector 单独建模，不再与普通本地 IRQ vector 共用一张布尔表
- `22`
  - 目前已经开始要求“首次占用这个 vector”才注册成功
  - 对于 RISC-V supervisor external interrupt vector，也已经开始走单独的首次占用语义
  - 当前 Linux adapter 里，external interrupt vector 的注册也已经开始和本地 `IRQ_HANDLERS` 表解耦
  - external interrupt 是否已经在 arch backend 上占用，也已经开始有独立状态观测
  - external vector 现在也开始形成一个正式 registration record，而不只是几个原子位：
    - `irq_external_reg_vector`
    - `irq_external_reg_call_index`
    - `irq_external_reg_pending_pushes`
    - `irq_external_reg_drain_calls`
    - `irq_external_reg_last_drained`
    - `irq_external_reg_last_cpu_id`
    - `irq_external_reg_last_event_call_index`
  - adapter 主层现在也开始记录最近一次注册尝试的关键状态：
    - `irq_last_reg_vector`
    - `irq_last_reg_external`
    - `irq_last_reg_arch_ok`
    - `irq_last_reg_local_installed`
    - `irq_last_reg_result`
    - `irq_local_installed_count`
    - `irq_external_slot_claimed`
  - 但还不是完整中断注册路径

对 `10 / 21 / 22` 当前再补一版更直接的“剩余缺口清单”：

- `10. TimeIf::set_oneshot_timer`
  - 还没有真正调用 AxVisor timer event 检查入口
  - 但当前真实接线点已经被收口到 `timer_core_entry_invoker`
  - 还没有证明 timer callback 一定运行在期望的目标 CPU 上
  - 虽然已经补上最小 cancel / reprogram 语义，但还没有处理更复杂的“迁移”策略
- `21. IrqIf::handle_irq`
  - 虽然 external interrupt path 已经开始形成 adapter 自己的 pending/drain 骨架，
    但还没有真正遍历硬件 pending interrupt 并做 guest inject
  - 当前 runtime glue 虽然已经能逐个看到 drained external IRQ event，
    但还没有真实 guest inject 消费逻辑
  - 但当前真实接线点已经被收口到 `external_irq_core_entry_invoker`
  - 也还没有区分“external interrupt 已识别”与“guest inject 实际完成”的更细粒度状态
- `22. IrqIf::register_irq_handler`
  - 还没有接到 Linux 原生 irq 注册/解绑机制
  - 当前 external vector 只是在 adapter / arch backend 层占位
  - 当前虽然已经能观测“arch 注册成功但本地 handler 未装入”这类中间态，
    但还没有形成真正的失败回滚和解绑路径
  - 当前 external registration record 也还是单实例模型，
    还没有扩展到更完整的 handler 生命周期管理
  - 也还没有形成完整的 handler 生命周期管理策略

## 四点七、三个真实接线单点

当前 Linux adapter 已经把后续最关键的三条真实接线，分别收口成三个单点 dispatcher。

后续如果要开始真正把 AxVisor core 接到 Linux host adapter 上，优先就看这三处：

- `runtime_core_entry_invoker`
  - 所在逻辑：
    - `prepare_runtime_start`
    - `invoke_runtime_start_core`
    - `finalize_runtime_start`
  - 当前返回：
    - `stub_runtime_core_entry`
  - 未来应替换为：
    - 真实 `axvisor_core::boot::run()` 入口包装
  - 作用：
    - 承接 `3. run`
    - 不改 runtime 外层包装流程，只改真正的 core entry 调用点

- `timer_core_entry_invoker`
  - 所在逻辑：
    - `linux_timer_bridge`
    - `timer_event_processor`
    - `invoke_timer_event_core`
  - 当前返回：
    - `stub_timer_core_entry`
  - 未来应替换为：
    - 真实 AxVisor timer event 检查入口
    - 目标语义与 Asterinas 的 `axvisor_core::vmm::timer::check_events()` 一致
  - 作用：
    - 承接 `10. TimeIf::set_oneshot_timer`
    - 不改 hrtimer / bridge / glue 外层流程，只改 timer core 调用点

- `external_irq_core_entry_invoker`
  - 所在逻辑：
    - external IRQ pending/drain
    - `process_external_irq_events`
    - `invoke_external_irq_core`
  - 当前返回：
    - `stub_external_irq_core_entry`
  - 未来应替换为：
    - 真实 guest interrupt inject / external interrupt handoff 入口
  - 作用：
    - 承接 `21. IrqIf::handle_irq`
    - 不改 external IRQ 的 pending/drain/event record 外层流程，只改 per-event core 调用点

这三个单点的意义是：

- 以后接真实 AxVisor core 时，不需要重新设计 Linux adapter 结构
- 优先替换 dispatcher 返回目标即可
- 只有当真实 core 对调用约束提出额外要求时，才回头微调外层包装

再往下，如果要开始第一轮真实接线，当前最直接的参考就是 Asterinas 侧已经在用的三处调用点：

- `runtime_core_entry_invoker`
  - Asterinas 参考调用：
    - `ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs`
    - `pub fn run() { axvisor_core::boot::run(); }`
  - Linux 侧未来目标：
    - 让 dispatcher 最终调用 `axvisor_core::boot::run()`
  - 第一轮前置条件：
    - 宿主 runtime、task runtime、host glue 都已经安装完毕
    - 调用点明确处于允许进入 AxVisor core 的线程上下文

- `timer_core_entry_invoker`
  - Asterinas 参考调用：
    - `ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/arch/riscv64.rs`
    - timer callback 内直接调用 `axvisor_core::vmm::timer::check_events()`
  - Linux 侧未来目标：
    - 让 dispatcher 最终调用 `axvisor_core::vmm::timer::check_events()`
  - 第一轮前置条件：
    - timer callback 运行上下文满足 AxVisor timer event 检查要求
    - 至少先确认当前 CPU / 当前 VM timer event 的进入语义是可接受的

- `external_irq_core_entry_invoker`
  - Asterinas 参考调用：
    - `ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs`
    - `axvisor_core::arch::riscv64::inject_current_interrupt(irq_id)`
  - Linux 侧未来目标：
    - 让 dispatcher 最终完成对 drained external IRQ event 的真实 guest interrupt inject
  - 第一轮前置条件：
    - 能从 Linux 侧 external IRQ path 里拿到“真正的 pending irq id”，而不是当前 adapter 里的最小 event 占位信息
    - 注入点所需的当前 VM / 当前 vCPU 上下文在 Linux host 侧可达

## 四点八、第一轮真实接线的现实阻塞

当前如果要把 `runtime_core_entry_invoker` 真接到真实 `axvisor_core::boot::run()`，
首先要面对一个很直接的现实问题：

- `axvisor_core` 目前不是 Linux 内核树里的本地 crate
- Asterinas 侧的 `axvisor_host` 组件是通过 Rust `Cargo.toml` 直接以 git 依赖方式引入：
  - `axvisor_core = { git = "https://github.com/Ivans-11/tgoskits", branch = "axvisor-core", default-features = false }`
  - `axvisor_api = { git = "https://github.com/Ivans-11/tgoskits", branch = "axvisor-core", default-features = false }`
- 当前 Linux 侧 adapter 代码位于：
  - `linux-host-kernel/drivers/virt/axvisor/`
  - 它是 Linux kernel Rust 模块代码，不是 Cargo workspace 里的普通 Rust crate

这意味着第一轮真实接线不是“把 stub 函数名直接改掉”这么简单，而至少还要先解决下面这些问题：

- `依赖接入问题`
  - Linux kernel Rust 模块当前怎么把 `axvisor_core` / `axvisor_api` 这两个外部 crate 引进来
  - 是内嵌 vendor 到内核树
  - 还是做一层手工 glue / FFI / code import
  - 还是先做一个最小本地 shim crate

- `运行环境语义问题`
  - `axvisor_core::boot::run()` 默认假设的宿主运行环境，当前是围绕 Asterinas 那套 host API 组织的
  - Linux 侧虽然已经把 30 个接口的 adapter 形状搭出来了
  - 但还没有真正证明 `axvisor_core` 直接在 Linux kernel Rust 模块环境里可被链接并正常初始化

- `构建系统问题`
  - Asterinas 侧是 Cargo 体系
  - Linux 侧这里是 kernel build + Rust-for-Linux 体系
  - 两边依赖组织方式完全不同

- `架构功能前置问题`
  - 即使 `boot::run()` 能被调起来
  - 它后续实际依赖的 timer / irq / arch hypervisor 行为，也必须至少具备最小可运行语义
  - 否则只是“链接成功但运行很快卡住”

因此，第一轮真实接线建议不要直接从“把 dispatcher 返回目标改成 `axvisor_core::boot::run()`”开始，
而应该先拆成下面几步：

1. 先解决 `axvisor_core` / `axvisor_api` 在 Linux kernel Rust 模块里的可见性问题
2. 再验证 Linux adapter 这 30 个接口是否已经足够支撑 `boot::run()` 进入最早期路径
3. 再逐步替换三个 dispatcher：
   - `runtime_core_entry_invoker`
   - `timer_core_entry_invoker`
   - `external_irq_core_entry_invoker`

按风险顺序，当前最适合先动手的仍然是：

1. `runtime_core_entry_invoker`
2. `timer_core_entry_invoker`
3. `external_irq_core_entry_invoker`

再补一个现在已经比较明确的构建侧判断：

- Linux kernel Rust 本身并不是“完全不能接外部 crate”
- 从 `linux-host-kernel/rust/Makefile` 可以看到：
  - 现有内核 Rust crate 就是通过显式 `--extern ...` 方式组织起来的
  - 例如 `kernel`、`ffi`、`pin_init`、`bindings`、`uapi`
- 这说明 `axvisor_core` / `axvisor_api` 的真正问题不是“理论上不能引入”
- 而是：
  - 要不要把它们 vendoring 到内核树
  - vendoring 之后放在哪里
  - 由哪一层 Makefile/Kbuild 规则为它们生成对应的 `.rlib/.o`
  - 以及它们还依赖哪些 Asterinas / tgoskits 侧 crate 也必须一起进来

基于这一点，当前 Linux 侧至少有三种可行引入路线：

1. `整包 vendoring 路线`
   - 把 `axvisor_core` / `axvisor_api` 以及它们依赖的最小 crate 集，直接 vendoring 到 Linux 内核树
   - 再仿照 `rust/Makefile` 的现有 `--extern` 组织方式接进去
   - 优点：
     - 最接近当前 Asterinas 侧真实 crate 结构
   - 缺点：
     - 初始改动面最大
     - 依赖传递复杂度最高

2. `最小 shim 路线`
   - 先不把完整 `axvisor_core` 搬进来
   - 只在 Linux 侧定义一个本地 shim crate / 模块层
   - 先把三个 dispatcher 对应的最小函数签名固定住
   - 后续再逐步把真实实现替换进去
   - 优点：
     - 最适合第一轮打通构建
   - 缺点：
     - 离真实运行还远

3. `分阶段 vendor 路线`
   - 先只为 `runtime_core_entry_invoker` 准备最小可编译依赖
   - 再扩到 timer / irq 路径依赖
   - 优点：
     - 适合按风险顺序推进
   - 缺点：
     - 中间阶段会出现局部可见、整体不可运行的状态

如果只看“下一步最容易落地”，当前更推荐：

1. 先走 `分阶段 vendor 路线`
2. 以 `runtime_core_entry_invoker` 为第一目标
3. 先把 `axvisor_api` / `axvisor_core` 的最小可见性问题解决掉

再补一个更具体的现状判断：

- Asterinas 侧的 `aster-axvisor-host` 组件当前并不只依赖：
  - `axvisor_core`
  - `axvisor_api`
- 它还直接依赖：
  - `ostd`
  - `spin`
  - `ax-percpu`
  - `ax-errno`
  - 以及 Asterinas 自己的 `aster-console` / `aster-logger` / `aster-time`

这意味着 Linux 侧如果想“整包照搬 Asterinas host 组件”来获得 `axvisor_core::boot::run()` 调用能力，
第一轮就会立刻遇到依赖爆炸：

- 不只是 `axvisor_core` / `axvisor_api`
- 还要一起处理一整串 Asterinas / tgoskits 生态依赖

因此，当前更现实的第一轮方案应该进一步收敛成：

### 第一轮真实接线推荐策略

1. `不直接搬 Asterinas host crate`
   - 不把 `aster-axvisor-host` 原样搬进 Linux 内核树
   - 因为它绑定了太多 Asterinas 专有依赖

2. `保留 Linux 侧现有 adapter 为主`
   - 继续以 `linux-host-kernel/drivers/virt/axvisor/axvisor_adapter_main.rs` 为宿主 glue 主体
   - 不让 Linux 侧重新依赖 `ostd`

3. `优先做最小 shim / 最小 vendor`
   - 第一轮目标不是“把整个 AxVisor host 组件跑起来”
   - 而是：
     - 先让 `runtime_core_entry_invoker` 能看到一个最小可编译的 core entry shim
     - 再逐步决定这个 shim 后面是真接 `axvisor_core`，还是继续吸收必要依赖

按这个思路，`runtime_core_entry_invoker` 的第一轮落地步骤可以先写成：

1. 在 Linux 内核树里新增一个面向 adapter 的本地 Rust crate / 模块层
   - 只暴露最小入口函数，例如：
     - `axvisor_linux_core_stub::boot_run()`
2. 先让 `runtime_core_entry_invoker` 返回这个本地 stub
3. 再逐步把这个 stub 后面的实现替换成：
   - 真正 vendor 进来的 `axvisor_core::boot::run()`
   - 或者一层更薄的本地 glue

当前这一步已经开始在 Linux 侧落文件：

- `linux-host-kernel/drivers/virt/axvisor/axvisor_core_stub.rs`
  - 当前提供：
    - `boot_run()`
    - `timer_check_events()`
    - `inject_external_interrupt()`
  - 这三个函数现在也已经开始明确写出各自未来要替换成的真实目标函数：
    - `boot_run()` -> `axvisor_core::boot::run()`
    - `timer_check_events()` -> `axvisor_core::vmm::timer::check_events()`
    - `inject_external_interrupt()` -> `axvisor_core::arch::riscv64::inject_current_interrupt(irq_id)`
- `axvisor_adapter_main.rs` 里的三个 dispatcher 当前已经改成返回这个本地 stub 模块里的入口
- `drivers/virt/axvisor/Makefile` 当前也已经把 `axvisor_core_stub.o` 纳入模块对象列表

这样做的好处是：

- 不需要第一步就把 `ostd` 整套搬进 Linux
- 不会打乱现在已经成形的 Linux adapter 结构
- 可以把“构建能见度问题”和“运行语义问题”拆开处理

## 五、各模块的计划语义

### 1. `runtime.rs`

计划职责：

- 提供 Linux 侧 runtime 安装入口，对应当前 Asterinas 的 runtime hook
- 决定 `axvisor_core::boot::run()` 在 Linux 中从哪里启动
- 保证 AxVisor 运行在一个明确的 kernel thread 上下文中

计划语义：

- `run()` 应当从一个专门的 Linux kernel thread 中启动
- 不应从任意中断上下文或模糊的初始化路径直接运行 AxVisor
- AxVisor 启动之前，Linux 侧它所依赖的宿主服务必须已经准备好

第一阶段目标：

- 让 AxVisor 的 banner 能在 Linux 中正常打印
- 让 `axvisor_core::boot::run()` 至少能进入受控的启动路径

当前建议的 Linux 侧接入关系：

- `LinuxRuntimeAdapter::run()`
  - 先走 `runtime_start_processor`
  - 最终由它进入 `axvisor_core::boot::run()`
- `linux_timer_bridge() -> linux_timer_event_hook()`
  - 最终由 `timer_event_processor` 进入 AxVisor timer event 检查入口
- `LinuxIrqAdapter::handle_irq()`
  - 在 arch backend 与本地 handler 表之间，增加 `irq_event_processor`
  - 最终由它决定哪些 IRQ 需要交给 AxVisor

### 2. `host.rs`

计划职责：

- 宿主 CPU 数量查询
- 每 CPU 的 AxVisor 宿主初始化
- 宿主退出策略
- 控制台输入输出
- 单调时间读取
- one-shot timer 编程
- 架构启动信息查询

计划语义：

- `init_percpu()` 的语义定义为“初始化每 CPU 的 AxVisor 宿主状态”
- `set_oneshot_timer()` 的语义定义为“最终能让 AxVisor 的 timer event 检查在目标 CPU 上被触发”
- `read_bytes()` 初期可以是非阻塞输入路径，例如 ring buffer
- `host_fdt_paddr()` 可能需要在 Linux 启动早期保存 DTB 指针，或复制一份 DT blob
- `host_tsc_frequency_mhz()` 在非 x86 架构上应理解为“宿主计时频率查询”，而不是严格的 x86 TSC 语义

### 3. `sync_task.rs`

计划职责：

- 创建和管理 AxVisor 自己的 wait queue
- 按 CPU affinity 创建 AxVisor task
- 提供 join 能力
- 把当前 Linux task 映射为 AxVisor task handle

计划语义：

- AxVisor task handle 应由适配层维护，不直接暴露 Linux `task_struct`
- `join` 和完成通知语义应尽量与当前 Asterinas 侧行为一致
- CPU affinity 要体现在 Linux 线程创建和调度约束中

当前 Linux 骨架已经开始朝这个方向调整：

- `1` / `17`
  - 通过 `kthread_create + set_cpus_allowed_ptr + wake_up_process` 创建承载线程
- `18`
  - 不再优先依赖 `kthread_stop`
  - 而是通过适配层自己的 `TaskState` 等待线程自然结束
- `19`
  - 现在会优先在 task registry 中按当前 `pid` 反查 handle
  - 查不到时才 fallback 成“当前 Linux task 的临时包装”
- `20`
  - 当前仍然只是 `yield()` 的直接包装
- `11`
  - 现在会分配一个 wait queue handle
  - 并把 wait queue record 挂进 `WAIT_QUEUE_REGISTRY`
- `12`
  - 现在按 handle 从 registry 删除
- `13-16`
  - 现在先按 handle 查 `WAIT_QUEUE_REGISTRY`
  - 再对对应 wait queue record 做 wait / wake
  - 对无效 handle 也已经不再直接 panic
- `5`
  - 现在已经先进入 `arch::init_percpu(...)`
- `10`
  - 现在已经先进入 `arch::set_oneshot_timer(...)`
  - `riscv64` arch backend 内部也开始维护最小 timer backend 状态
  - 也已经预留 `HrTimer` callback carrier，并会保存 active timer handle
  - 当前 timer callback 已能回到 adapter 层 bridge
  - adapter bridge 也已经转发到正式的 timer event hook
  - 当前 timer event hook 也已经会继续转发到 processor 接口
  - 当前 processor 接口收到的已经是结构化 timer event context
  - 当前 processor 也开始通过统一 runtime hooks 安装
  - 但还没有真正触发 AxVisor timer event
- `21`
  - 现在除了 arch backend 和本地 handler 表，也已经能先走 `irq_event_processor`
- `3`
  - 现在除了默认日志路径，也已经能先走 `runtime_start_processor`
- `21`
  - 现在会先尝试走 `arch::dispatch_external_irq(...)`
- `22`
  - 现在会先通知 `arch::register_irq_vector(...)`

### 4. `irq.rs`

计划职责：

- 维护适配层自己的 IRQ handler 注册表
- 将 Linux 侧 IRQ 事件桥接到 AxVisor 能理解的回调上

计划语义：

- `register_irq_handler()` 只负责在适配层登记 handler
- `handle_irq()` 负责定义哪些 Linux 侧的中断事件需要转交给 AxVisor
- guest 相关的中断注入路径，应尽量通过 arch hook 与通用 IRQ wrapper 解耦

### 5. `memory.rs`

计划职责：

- 单页分配
- 连续页分配
- 分配所有权记录
- 释放校验
- `phys <-> virt` 转换

计划语义：

- 返回给 AxVisor 的内存必须是适配层明确拥有并追踪的内存
- `phys_to_virt()` / `virt_to_phys()` 只应保证在适配层定义的分配/映射范围内成立
- 连续内存必须保留足够元数据，供后续正确释放和后续 G-stage 相关使用

建议维护的内部元数据：

- 分配基址或唯一标识
- 分配类型：单页 / 连续页
- 页数
- 对应的内核虚拟地址基址（如果有）

当前 Linux 代码已经先落了一个最小版本的元数据表：

- `struct axvisor_memory_record`
  - `paddr`
  - `vaddr`
  - `num_frames`
  - `kind`
  - `page`
  - `node`
- 全局链表：`axvisor_memory_records`
- 保护锁：`axvisor_memory_records_lock`

当前这套骨架已经提供的语义是：

- `23. alloc_frame`
  - 用 Linux 页分配器申请单页
  - 记录 `(paddr, vaddr, num_frames=1, kind=FRAME)`
- `24. alloc_contiguous_frames`
  - 当前先用 `alloc_pages_exact`
  - 当前已经要求 `frame_align == 0` 或按 `PAGE_SIZE` 对齐
  - 当前已经开始按物理地址检查 `frame_align`
  - 记录 `(paddr, vaddr, num_frames, kind=CONTIG)`
- `25. dealloc_frame`
  - 先删记录
  - 再校验 `kind == FRAME && num_frames == 1`
  - 校验成功才真正释放
- `26. dealloc_contiguous_frames`
  - 先删记录
  - 再校验 `kind == CONTIG && num_frames` 匹配
  - 校验成功才真正释放
- `27. phys_to_virt`
  - 优先从记录表命中自有分配
  - 命中则返回记录中的 `vaddr`
  - 当前版本未命中就直接返回 `0`
- `28. virt_to_phys`
  - 遍历记录表，看 `vaddr` 是否落入某条记录覆盖区间
  - 若命中，则按偏移回推 `paddr`
  - 当前版本未命中就直接返回 `0`

但要明确，当前还存在三类关键缺口：

- 对 `24` 来说：
  - `alloc_pages_exact` 仍然不能把“物理连续 + 指定 frame_align”语义彻底讲清楚
  - 但当前至少已经不再只按虚拟地址做对齐判断
  - 也已经开始拒绝非页对齐的 `frame_align` 输入
- 对 `27-28` 来说：
  - 当前已经开始拒绝对非 adapter 自有内存做兜底转换
  - 但还没有形成完整的映射生命周期管理
- 对整个 `23-28` 来说：
  - 现在只是“分配记录 + 释放校验 + 基本地址回查”
  - 还不是完整的 host memory manager
  - 还没有纳入 pinning、映射生命周期、G-stage 后续需求

### 6. `arch/riscv64.rs`

在当前 30 个函数范围内，计划职责：

- 为 `10` 提供 per-CPU timer hook
- 为 `21` 提供 external interrupt handoff 支持
- 为 `29` 提供 host DTB 查询
- 为 `30` 提供 host timebase frequency 查询

在后续更深层 hypervisor backend 阶段，预留职责：

- guest entry
- trap glue
- guest interrupt injection
- second-stage translation 相关钩子

这里要明确边界：

- 前四项属于当前 30 个函数范围内的 Linux 实现内容
- 后四项超出当前 30 个接口面，但中间层设计必须为它们预留扩展点

## 六、实现顺序

建议分五个阶段做。

### 阶段 1：先让 AxVisor 作为 Linux 内核子系统活起来

优先实现：

- `1 2 3`
- `7`
- `9`
- `11-20`

阶段目标：

- AxVisor 能从 Linux 中启动
- AxVisor 能打印日志
- AxVisor 能创建内部 task 和 wait queue

### 阶段 2：补齐 CPU 和 timer 基础能力

接着实现：

- `4 5 10`
- `22`

阶段目标：

- AxVisor 能看到宿主 CPU 拓扑
- per-CPU 状态可建立
- timer 回调最终能触发 AxVisor timer 逻辑
- IRQ handler 可注册

### 阶段 3：实现宿主内存管理层

接着实现：

- `23-28`

阶段目标：

- AxVisor 能稳定申请和释放宿主页
- 地址转换语义明确且可测试
- 把当前记录表骨架收紧成真正的 host memory ownership model

### 阶段 4：补齐剩余宿主接入点

再实现：

- `6 8 21 29 30`

阶段目标：

- 宿主退出路径有明确定义
- 控制台输入路径存在
- IRQ handoff 路径成形
- 启动期架构信息查询可用

### 阶段 5：接 Linux RISC-V hypervisor backend

这一阶段超出显式 30 个函数范围，但如果要做到 `no-KVM` 真正跑 guest，预期仍然需要。

预期工作：

- guest entry 路径
- trap 进入/退出 glue
- guest interrupt injection
- second-stage translation 的安装与维护

要求是：

- 前面 30 个函数形成的适配层不要因此被整体推翻
- 更深层 backend 逻辑应尽量通过 `arch/riscv64.rs` 继续下沉

## 七、验证里程碑

验证顺序建议从浅到深。

### 里程碑 A

- Linux 内核成功启动并编入该适配层
- AxVisor banner 成功打印

### 里程碑 B

- AxVisor 内部 task 创建正常
- AxVisor wait queue 行为正常
- timer event 路径可被触发

### 里程碑 C

- AxVisor 的 VMM 初始化能走到 VM 创建阶段
- image loading 和 config parsing 成功

### 里程碑 D

- 第一个 vCPU host task 能创建出来
- 能走到第一次 guest entry 尝试

### 里程碑 E

- guest 能输出第一条可见控制台信息

### 里程碑 F

- Linux guest 能进入 shell 或命令行

## 八、下一步建议

下一步不建议直接同时实现全部 30 个函数。

更合适的做法是：

- 继续沿用固定编号
- 针对每一个函数做逐项语义评审

每项至少写清楚：

- 当前 Asterinas 语义
- Linux 候选实现
- 对应 Linux 原语
- 语义风险
- 是否依赖 arch hook

这一部分应与
[docs/axvisor-host-interface-plan.md](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/docs/axvisor-host-interface-plan.md)
配套使用。

## 九、30 个函数的语义总表

这一节只定义“接口语义”，暂时不展开 Linux 侧具体实现。
后续逐项评审时，应以这里的语义描述作为对照基线。

### Runtime Glue

**1. `KernelTaskRuntime::spawn_task`**

语义：

- 由宿主 runtime 创建一个真正可运行的内核执行体
- 输入为一个一次性闭包和 CPU affinity
- 返回宿主侧原生 task 对象，供适配层继续包装
- 该 task 必须适合作为 AxVisor vCPU/task 的承载执行上下文

Asterinas 完整源码：

```rust
pub trait KernelTaskRuntime: Sync {
    fn spawn_task(
        &self,
        entry: Box<dyn FnOnce() + Send + 'static>,
        cpu_affinity: CpuSet,
    ) -> Arc<Task>;
}
```

```rust
impl aster_axvisor_host::KernelTaskRuntime for AxvisorKernelTaskRuntime {
    fn spawn_task(&self, entry: Box<dyn FnOnce() + Send + 'static>, cpu_affinity: CpuSet) -> Arc<Task> {
        let task = ThreadOptions::new(move || entry())
            .cpu_affinity(cpu_affinity)
            .build();
        task.run();
        task
    }
}
```

**2. `install_kernel_task_runtime`**

语义：

- 在 AxVisor 宿主适配层中安装唯一一份 runtime provider
- 安装动作只能成功一次
- 安装完成后，适配层内部所有 task 创建都通过该 runtime provider 进行

Asterinas 完整源码：

- [kernel/comps/axvisor-host/src/lib.rs](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs:131)

```rust
pub fn install_kernel_task_runtime(runtime: &'static dyn KernelTaskRuntime) {
    let mut is_new = false;
    KERNEL_TASK_RUNTIME.call_once(|| {
        is_new = true;
        runtime
    });
    assert!(is_new, "Axvisor kernel task runtime has already been installed");
}
```

**3. `run`**

语义：

- 作为宿主侧启动 AxVisor 的统一入口
- 在合适的宿主上下文中进入 `axvisor_core::boot::run()`
- 调用该接口时，AxVisor 依赖的宿主基础服务应已准备完毕

Asterinas 完整源码：

```rust
pub fn run() {
    aster_logger::print!("[axvisor] starting on Asterinas host runtime\n");
    axvisor_core::boot::run();
}
```

```rust
#[cfg(feature = "axvisor")]
{
    init_axvisor_host_runtime();
    aster_axvisor_host::run();
}
```

### HostIf

**4. `HostIf::get_host_cpu_num`**

语义：

- 返回当前宿主可供 AxVisor 看到和使用的 CPU 数量
- 该值用于 VM/vCPU 拓扑和 CPU 亲和性决策

Asterinas 完整源码：

- [kernel/comps/axvisor-host/src/lib.rs](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs:280)

```rust
fn get_host_cpu_num() -> usize {
    ostd::cpu::num_cpus()
}
```

**5. `HostIf::init_percpu`**

语义：

- 初始化当前 CPU 上 AxVisor 所需的本地宿主状态
- 属于每 CPU 一次的初始化钩子
- 后续本地 timer、local interrupt、hypervisor-local state 等都可能依赖它

Asterinas 完整源码：

```rust
fn init_percpu() {
    arch::init_percpu();
}
```

```rust
pub(crate) fn init_percpu() {
    timer::register_callback_on_cpu(|| {
        let deadline = TIMER_DEADLINE_TICKS.read_current();
        if deadline == NO_DEADLINE_TICKS {
            return;
        }
        let now_ticks = ostd::arch::read_tsc();
        if now_ticks < deadline {
            return;
        }
        TIMER_DEADLINE_TICKS.write_current(NO_DEADLINE_TICKS);
        axvisor_core::vmm::timer::check_events();
    });
}
```

**6. `HostIf::exit`**

语义：

- 触发宿主侧定义的 AxVisor 退出路径
- 输入 exit code
- 语义上表示“AxVisor 请求结束当前宿主运行”
- 是否最终关机、停止 VMM、还是只结束当前实例，由宿主策略决定

Asterinas 完整源码：

- [kernel/comps/axvisor-host/src/lib.rs](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs:288)

```rust
fn exit(exit_code: i32) -> ! {
    let code = if exit_code == 0 {
        ExitCode::Success
    } else {
        ExitCode::Failure
    };
    ostd::power::poweroff(code)
}
```

### ConsoleIf

**7. `ConsoleIf::write_bytes`**

语义：

- 将一段原始字节写入宿主控制台输出路径
- 主要用于 AxVisor 日志、shell、guest 透传输出等场景
- 不要求必须是 UTF-8 文本语义，按字节流处理即可

Asterinas 完整源码：

- [kernel/comps/axvisor-host/src/lib.rs](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs:300)

```rust
fn write_bytes(bytes: &[u8]) {
    let devices = aster_console::all_devices_lock();
    if devices.is_empty() {
        if let Ok(text) = str::from_utf8(bytes) {
            ostd::early_print!("{}", text);
        }
        return;
    }
    for console in devices.values() {
        console.send(bytes);
    }
}
```

**8. `ConsoleIf::read_bytes`**

语义：

- 从宿主控制台输入路径中读取尽可能多的字节
- 输入缓冲区由调用方提供
- 返回实际读取字节数
- 语义上更接近“非阻塞拉取输入字节”

Asterinas 完整源码：

```rust
fn read_bytes(bytes: &mut [u8]) -> usize {
    read_console_bytes(bytes)
}
```

```rust
fn read_console_bytes(buf: &mut [u8]) -> usize {
    if buf.is_empty() {
        return 0;
    }
    CONSOLE_INPUT.ensure_registered();
    let mut bytes = CONSOLE_INPUT.bytes.lock();
    let count = buf.len().min(bytes.len());
    for slot in buf.iter_mut().take(count) {
        *slot = bytes.pop_front().expect("console input buffer underflow");
    }
    count
}
```

### TimeIf

**9. `TimeIf::current_time_nanos`**

语义：

- 返回宿主单调时间源的纳秒值
- 要求时间单调递增
- 用于 AxVisor 内部定时与超时逻辑

Asterinas 完整源码：

- [kernel/comps/axvisor-host/src/lib.rs](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs:321)

```rust
fn current_time_nanos() -> time::Nanos {
    aster_time::read_monotonic_time().as_nanos() as u64
}
```

**10. `TimeIf::set_oneshot_timer`**

语义：

- 为当前 CPU 或当前执行上下文设置一个单次触发的 deadline
- 到达 deadline 后，应能驱动 AxVisor 的 timer event 检查逻辑被执行
- 不要求接口本身直接执行回调，但必须保证 timer 事件最终可达

Asterinas 完整源码：

```rust
fn set_oneshot_timer(deadline: time::TimeValue) {
    arch::set_oneshot_timer(deadline)
}
```

```rust
pub(crate) fn set_oneshot_timer(deadline: time::TimeValue) {
    TIMER_DEADLINE_TICKS.write_current(nanos_to_ticks(deadline.as_nanos() as u64));
}
```

### SyncIf

**11. `SyncIf::create_wait_queue`**

语义：

- 创建一个由适配层管理的 wait queue
- 返回一个不透明的 wait queue 标识符
- 标识符后续用于 wait/wake 操作

Asterinas 完整源码：

- [kernel/comps/axvisor-host/src/lib.rs](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs:333)

```rust
fn create_wait_queue() -> usize {
    let id = WAIT_QUEUE_IDS.fetch_add(1, Ordering::Relaxed);
    WAIT_QUEUES.lock().insert(id, Arc::new(WaitQueue::new()));
    id
}
```

**12. `SyncIf::destroy_wait_queue`**

语义：

- 销毁一个已创建的 wait queue
- 释放对应的宿主侧管理对象
- 调用者负责保证其生命周期使用合法

Asterinas 完整源码：

- [kernel/comps/axvisor-host/src/lib.rs](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs:339)

```rust
fn destroy_wait_queue(queue: usize) {
    WAIT_QUEUES.lock().remove(&queue);
}
```

**13. `SyncIf::wait_queue_wait`**

语义：

- 当前执行体在指定 wait queue 上进入等待
- 等待直到被显式唤醒
- 语义上是最基础的“睡眠直到 wake”

Asterinas 完整源码：

- [kernel/comps/axvisor-host/src/lib.rs](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs:343)

```rust
fn wait_queue_wait(queue: usize) {
    let queue = get_wait_queue(queue);
    let (waiter, _) = Waiter::new_pair();
    queue.enqueue(waiter.waker());
    waiter.wait();
}
```

**14. `SyncIf::wait_queue_wait_until`**

语义：

- 当前执行体在指定 wait queue 上等待，直到给定条件成立
- 允许宿主重复检查条件并在条件不成立时继续等待
- 语义上是带条件检查的等待原语

Asterinas 完整源码：

- [kernel/comps/axvisor-host/src/lib.rs](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs:350)

```rust
fn wait_queue_wait_until(queue: usize, condition: Box<dyn Fn() -> bool + Send + 'static>) {
    get_wait_queue(queue).wait_until(|| condition().then_some(()));
}
```

**15. `SyncIf::wait_queue_wake_one`**

语义：

- 从指定 wait queue 中唤醒一个等待者
- 不要求规定唤醒的是哪一个等待者

Asterinas 完整源码：

- [kernel/comps/axvisor-host/src/lib.rs](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs:354)

```rust
fn wait_queue_wake_one(queue: usize) {
    get_wait_queue(queue).wake_one();
}
```

**16. `SyncIf::wait_queue_wake_all`**

语义：

- 唤醒指定 wait queue 中的全部等待者

Asterinas 完整源码：

- [kernel/comps/axvisor-host/src/lib.rs](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs:358)

```rust
fn wait_queue_wake_all(queue: usize) {
    get_wait_queue(queue).wake_all();
}
```

### TaskIf

**17. `TaskIf::spawn_task_raw`**

语义：

- 创建一个供 AxVisor 使用的宿主 task
- 输入为 AxVisor task 选项和执行入口
- 输出为 AxVisor 自己的 task handle，而不是宿主原生线程对象
- 适配层必须维护 `task handle <-> 宿主 task` 的映射关系
- 该 task 应支持 CPU affinity 约束

Asterinas 完整源码：

- [kernel/comps/axvisor-host/src/lib.rs](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs:365)

```rust
fn spawn_task_raw(options: task::TaskOptions, entry: Box<dyn FnOnce() + Send + 'static>) -> task::TaskHandle {
    let handle = task::TaskHandle::from_raw(TASK_IDS.fetch_add(1, Ordering::Relaxed));
    let completion = Arc::new(TaskCompletion::new());
    let completion_for_task = completion.clone();
    let registered = Arc::new(AtomicBool::new(false));
    let registered_for_task = registered.clone();
    let cpu_affinity = options.cpu_set.map_or_else(CpuSet::new_full, cpu_set_from_mask);
    let task = spawn_kernel_task(
        Box::new(move || {
            while !registered_for_task.load(Ordering::Acquire) {
                Task::yield_now();
            }
            entry();
            completion_for_task.finish();
        }),
        cpu_affinity,
    );
    TASKS.lock().insert(handle.as_raw(), Arc::new(TaskEntry { task, completion }));
    registered.store(true, Ordering::Release);
    handle
}
```

**18. `TaskIf::join_task`**

语义：

- 等待指定的 AxVisor task 执行结束
- 以 AxVisor task handle 为输入
- 适配层负责将其映射到宿主 task 的完成通知机制

Asterinas 完整源码：

- [kernel/comps/axvisor-host/src/lib.rs](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs:396)

```rust
fn join_task(task: task::TaskHandle) {
    let entry = get_task_entry(task);
    entry.completion.wait();
    TASKS.lock().remove(&task.as_raw());
}
```

**19. `TaskIf::current_task`**

语义：

- 查询当前宿主执行体是否对应某个 AxVisor task
- 若是，则返回对应的 AxVisor task handle
- 若当前上下文不属于 AxVisor 创建的 task，则返回空

Asterinas 完整源码：

- [kernel/comps/axvisor-host/src/lib.rs](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs:402)

```rust
fn current_task() -> Option<task::TaskHandle> {
    let current = Task::current()?.cloned();
    TASKS.lock().iter().find_map(|(&handle, entry)| {
        Arc::ptr_eq(&current, &entry.task).then_some(task::TaskHandle::from_raw(handle))
    })
}
```

**20. `TaskIf::yield_now`**

语义：

- 主动让出当前执行体的 CPU 执行机会
- 用于 AxVisor 的协作式调度/等待逻辑

Asterinas 完整源码：

- [kernel/comps/axvisor-host/src/lib.rs](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs:409)

```rust
fn yield_now() {
    Task::yield_now()
}
```

### IrqIf

**21. `IrqIf::handle_irq`**

语义：

- 尝试由 AxVisor 宿主适配层处理一个给定中断向量/事件
- 若该事件属于 AxVisor 管辖范围，则完成处理并返回 `true`
- 若不属于，则返回 `false`
- 该接口同时承担“普通已注册中断回调分发”和“特定 guest 相关中断 handoff”的语义

Asterinas 完整源码：

- [kernel/comps/axvisor-host/src/lib.rs](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs:416)

```rust
fn handle_irq(vector: usize) -> bool {
    #[cfg(target_arch = "riscv64")]
    if vector == RISCV_S_EXT_VECTOR {
        ostd::arch::irq::for_each_pending_external_interrupt(|irq_id| {
            axvisor_core::arch::riscv64::inject_current_interrupt(irq_id);
        });
        return true;
    }

    if let Some(handler) = IRQ_HANDLERS.lock().get(&vector).copied() {
        handler(vector);
        return true;
    }
    false
}
```

**22. `IrqIf::register_irq_handler`**

语义：

- 向适配层注册一个向量到 handler 的映射
- 若该向量已被占用，则注册失败
- 返回值表示注册是否成功

当前 Asterinas 源码：

- [kernel/comps/axvisor-host/src/lib.rs](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs:432)

```rust
fn register_irq_handler(vector: usize, handler: irq::IrqHandler) -> bool {
    let mut handlers = IRQ_HANDLERS.lock();
    if handlers.contains_key(&vector) {
        return false;
    }
    handlers.insert(vector, handler);
    true
}
```

### MemoryIf

**23. `MemoryIf::alloc_frame`**

语义：

- 分配一个宿主物理页帧
- 返回页帧的物理地址
- 该页帧的所有权由适配层追踪，后续需可释放

当前 Asterinas 源码：

- [kernel/comps/axvisor-host/src/lib.rs](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs:444)

```rust
fn alloc_frame() -> Option<PhysAddr> {
    let frame = FrameAllocOptions::new().alloc_frame().ok()?;
    Some(store_host_memory(HostMemory::Frame(frame)))
}
```

**24. `MemoryIf::alloc_contiguous_frames`**

语义：

- 分配一段连续宿主物理页帧
- 输入包含页数和对齐要求
- 返回首物理地址
- 该分配需保留足够元数据，支持后续释放和地址转换

Asterinas 完整源码：

```rust
fn alloc_contiguous_frames(num_frames: usize, frame_align: usize) -> Option<PhysAddr> {
    let segment = alloc_aligned_segment(num_frames, frame_align)?;
    Some(store_host_memory(HostMemory::Segment(segment)))
}
```

**25. `MemoryIf::dealloc_frame`**

语义：

- 释放由 `alloc_frame` 返回的单页物理帧
- 输入为对应物理地址
- 适配层应能识别其确实属于单页分配对象

Asterinas 完整源码：

- [kernel/comps/axvisor-host/src/lib.rs](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs:454)

```rust
fn dealloc_frame(addr: PhysAddr) {
    let allocation = MEMORY_ALLOCS.lock().remove(&addr.as_usize());
    debug_assert!(matches!(allocation, Some(HostMemory::Frame(_))));
}
```

**26. `MemoryIf::dealloc_contiguous_frames`**

语义：

- 释放由 `alloc_contiguous_frames` 返回的连续页分配对象
- 输入至少包括首物理地址
- 适配层应能识别其确实属于连续页分配对象

Asterinas 完整源码：

- [kernel/comps/axvisor-host/src/lib.rs](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs:459)

```rust
fn dealloc_contiguous_frames(first_addr: PhysAddr, _num_frames: usize) {
    let allocation = MEMORY_ALLOCS.lock().remove(&first_addr.as_usize());
    debug_assert!(matches!(allocation, Some(HostMemory::Segment(_))));
}
```

**27. `MemoryIf::phys_to_virt`**

语义：

- 将一个宿主物理地址转换为宿主虚拟地址
- 该语义只保证在适配层支持的地址范围和映射策略内成立
- 不应默认等价于“任意宿主物理地址都必然可直接线性映射”

Asterinas 完整源码：

- [kernel/comps/axvisor-host/src/lib.rs](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs:464)

```rust
fn phys_to_virt(addr: PhysAddr) -> VirtAddr {
    VirtAddr::from_usize(paddr_to_vaddr(addr.as_usize()))
}
```

**28. `MemoryIf::virt_to_phys`**

语义：

- 将一个宿主虚拟地址转换为宿主物理地址
- 该语义只保证在适配层支持的地址范围和映射策略内成立
- 应与 `phys_to_virt` 的语义范围保持一致

Asterinas 完整源码：

- [kernel/comps/axvisor-host/src/lib.rs](/home/bullet1517/freehypervisor/ivans-asterinas-axvisor-host/kernel/comps/axvisor-host/src/lib.rs:468)

```rust
fn virt_to_phys(addr: VirtAddr) -> PhysAddr {
    arch::linear_mapping_virt_to_phys(addr.as_usize())
}
```

### ArchIf

**29. `ArchIf::host_fdt_paddr`**

语义：

- 返回宿主侧 device tree blob 的物理地址，若该信息可用
- 供 AxVisor 获取宿主启动期平台描述信息
- 在不具备 FDT 语义的平台上可返回空

Asterinas 完整源码：

```rust
fn host_fdt_paddr() -> Option<PhysAddr> {
    arch::host_fdt_paddr()
}
```

```rust
pub(crate) fn host_fdt_paddr() -> Option<PhysAddr> {
    DEVICE_TREE_PADDR.get().copied().map(PhysAddr::from_usize)
}
```

**30. `ArchIf::host_tsc_frequency_mhz`**

语义：

- 返回宿主侧计时基准频率信息，单位为 MHz，若该信息可用
- 在 x86 上通常对应 TSC 频率
- 在非 x86 上，本质上表示“AxVisor 所依赖的宿主计时频率信息”

Asterinas 完整源码：

```rust
fn host_tsc_frequency_mhz() -> Option<u32> {
    u32::try_from(ostd::arch::tsc_freq() / 1_000_000)
        .ok()
        .filter(|&freq| freq > 0)
}
```
