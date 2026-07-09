# AxVisor 三十个接口与构建阻塞的边界

本文档回答一个核心问题：

- 哪些问题属于“30 个 Linux host 接口要不要实现”
- 哪些问题即使 30 个接口都实现了，仍然会继续阻塞 AxVisor 在 Linux 上运行

这份文档的目的，是把“接口适配问题”和“构建接入问题”彻底分开。

## 1. 当前编号口径

当前 Linux adapter 里已经按编号落了 28 个主接口，加上 2 个 runtime 相关入口，共 30 项：

1. `KernelTaskRuntime::spawn_task`
2. `install_kernel_task_runtime`
3. `run`
4. `HostIf::get_host_cpu_num`
5. `HostIf::init_percpu`
6. `HostIf::exit`
7. `ConsoleIf::write_bytes`
8. `ConsoleIf::read_bytes`
9. `TimeIf::current_time_nanos`
10. `TimeIf::set_oneshot_timer`
11. `SyncIf::create_wait_queue`
12. `SyncIf::destroy_wait_queue`
13. `SyncIf::wait_queue_wait`
14. `SyncIf::wait_queue_wait_until`
15. `SyncIf::wait_queue_wake_one`
16. `SyncIf::wait_queue_wake_all`
17. `TaskIf::spawn_task_raw`
18. `TaskIf::join_task`
19. `TaskIf::current_task`
20. `TaskIf::yield_now`
21. `IrqIf::handle_irq`
22. `IrqIf::register_irq_handler`
23. `MemoryIf::alloc_frame`
24. `MemoryIf::alloc_contiguous_frames`
25. `MemoryIf::dealloc_frame`
26. `MemoryIf::dealloc_contiguous_frames`
27. `MemoryIf::phys_to_virt`
28. `MemoryIf::virt_to_phys`
29. runtime hook 安装链
30. runtime 真实入口转发链

说明：

- `29/30` 不是 upstream `axvisor_api` 里的 trait 方法
- 它们是 Linux adapter 为了把 AxVisor core 接进来，额外补的 runtime glue

## 2. Asterinas 侧真正实现到 upstream API 的接口组

从 Asterinas 侧当前 `#[api_impl]` 来看，真正实现到 `axvisor_api` 的接口组是：

- `HostIf`
- `ConsoleIf`
- `TimeIf`
- `SyncIf`
- `TaskIf`
- `IrqIf`
- `MemoryIf`
- `ArchIf`

也就是说，Asterinas 侧“像 AxVisor 的 host”这一层，核心上是 8 组接口。

如果只看函数数目：

- 这 8 组一共覆盖了我们现在编号里的绝大多数项目
- 但并不自动包含 Linux adapter 额外补的 runtime glue

## 3. 哪些问题属于 30 个接口内部

下面这些问题，本质上属于“30 个接口有没有实现到 Linux 语义”：

### 3.1 task/runtime/sync

- 如何在 Linux 内核里起一个可绑定 CPU 的内核线程
- 如何把 CPU mask 语义映射给 AxVisor
- 如何做 task handle 注册、join、yield
- 如何做 wait queue 的 create/destroy/wait/wake

这些问题对应：

- `1`
- `2`
- `3`
- `11` 到 `20`

### 3.2 host/console/time

- 如何读 host CPU 数
- 如何做 percpu 初始化入口
- 如何退出 host
- 如何输出/读取 console
- 如何读当前时间
- 如何设置 one-shot timer

这些问题对应：

- `4` 到 `10`

### 3.3 irq/memory

- 如何注册中断处理器
- 如何区分本地 IRQ 与 RISC-V external IRQ
- 如何分配/释放 frame
- 如何做 phys/virt 地址转换

这些问题对应：

- `21` 到 `28`

### 3.4 runtime glue

- 如何在 Linux module init 后把 runtime hook 安进去
- 如何把 `boot/timer/irq` 三条 core link 调度起来

这些问题对应：

- `29`
- `30`

结论：

- 以上都是“30 个接口内部问题”
- 它们的本质是 Linux 语义封装问题

## 4. 哪些问题不属于 30 个接口内部

下面这些问题，即使 30 个接口全部实现，也仍然会挡住真实运行：

### 4.1 `proc-macro` host-side 构建链

包括：

- `ax-crate-interface`
- `ax-percpu-macros`
- `axvisor_api_proc`
- `proc-macro-crate`
- `cfg-if`

这类问题的本质不是“接口语义”，而是：

- Rust-for-Linux 里怎么把这些宏 crate 编出来

所以它不属于 30 个接口内部。

### 4.2 `axvisor_api` / `axvisor_core` crate 可见性

即：

- Linux module 编译时能不能真正 `extern` 到这些 crate

这也不属于 30 个接口内部，因为：

- 就算每个接口函数你都先写好了
- 只要 crate 进不了 Linux Rust build，它们还是不会被真实 AxVisor core 调到

### 4.3 `axvisor_core/build.rs`

这是一个更明显的“接口外问题”。

因为它涉及：

- `AXVISOR_VM_CONFIGS`
- `vm_configs.rs` 生成
- TOML 解析
- `include_bytes!` guest image

这个问题和 30 个接口实现是否完整，没有直接对应关系。

### 4.4 virtualization 主链的第三方依赖放大

包括：

- `axvm`
- `axaddrspace`
- `axdevice`
- `axdevice_base`
- `axvmconfig`
- `riscv_vcpu`
- `riscv_vplic`

以及它们继续带出的：

- `serde`
- `toml`
- `log`
- `hashbrown`
- `byte-unit`
- `fdt-parser`

这类问题的本质是：

- crate 依赖规模
- build 顺序
- Linux Rust build 接线策略

也不属于 30 个接口内部。

## 5. 为什么会出现“接口都做了还不够”

因为 Asterinas 侧当前并不是只有“接口函数实现”这么一层。

它实际上同时满足了三件事：

1. 提供了 `axvisor_api` 各组接口的具体实现
2. 让 `axvisor_core` 真能进入它的构建体系
3. 让 `run()` 最终能真实落到 `axvisor_core::boot::run()`

而我们当前 Linux 侧，虽然已经在第 1 件事上做了大量 adapter 工作，但：

- 第 2 件事还没解决
- 第 3 件事现在还是 `core_link/vendor/fallback` 链路

所以会出现一种典型状态：

- “接口语义看起来差不多都有了”
- “但真实 AxVisor core 仍然进不来”

## 6. 当前 Linux 侧实际进度怎么判断

如果分层来看，当前更准确的判断是：

### 6.1 接口语义层

Linux adapter 已经做了较完整的第一版封装。

可以说：

- 30 个接口层面的骨架和大部分 Linux 语义映射已经在

### 6.2 真实 core 接入层

现在还没有打通。

原因不是接口函数缺几个，而是：

- proc-macro 链没进 build
- `axvisor_core` 还不可见
- `build.rs` 还没定策略

### 6.3 timer/irq 的真实落点层

也还没有打通。

当前仍然是：

- runtime path 预留
- timer path 预留
- irq path 预留

其中 runtime path 是第一优先级。

## 7. 现阶段最重要的结论

所以现在可以非常明确地说：

- “30 个接口是否都要做”这个问题，和“AxVisor 能不能在 Linux 上真实跑起来”不是同一个问题

更准确地说：

1. 30 个接口是必要条件
2. 但不是充分条件
3. 当前真正阻塞真实运行的，已经主要转移到构建接入层

## 8. 对下一步工作的指导意义

这意味着后续推进时要严格区分两种工作：

### 8.1 接口内工作

继续完善：

- task
- sync
- memory
- irq
- timer
- runtime glue

### 8.2 接口外工作

优先解决：

- proc-macro build
- crate 可见性
- `axvisor_core/build.rs`

当前判断：

- 接口内工作已经有了相当基础
- 接口外工作才是眼下真正的关键路径
