# AxVisor Linux 三十个接口状态清单

本文档把当前 Linux 侧 30 个接口分成三类：

1. 已具备 Linux 语义封装
2. 还需要补强实现
3. 必须等真实 `axvisor_core` 接入后才能验证

目的很简单：

- 不再把“已经有骨架”和“已经能真实支撑 AxVisor core”混在一起

## 1. 分类标准

### 1.1 已具备 Linux 语义封装

表示：

- 当前 Linux adapter 里已经有明确实现
- 不是单纯 `stub`
- 不是只打印日志
- 对应 Linux 内核对象或 RISC-V backend 已经落下去了

### 1.2 还需要补强实现

表示：

- 已经有第一版实现
- 但语义还偏弱，或者只完成了 adapter 侧占位
- 后面大概率还要加强边界条件、真实数据来源、架构细节

### 1.3 必须等真实 core 接入后才能验证

表示：

- 当前虽然有调用路径
- 但实际仍然落到 `fallback/stub`
- 不把真实 `axvisor_core` 接进 Linux 构建体系，就无法证明它真的成立

## 2. 已具备 Linux 语义封装

这一组可以认为已经不只是“函数壳”，而是有实质性 Linux 语义映射。

### 2.1 task / sync

1. `KernelTaskRuntime::spawn_task`
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

当前依据：

- 已经落到了 Linux `kthread`、`Task`、`CondVar`、`Mutex`、registry 这些对象上
- `spawn/join/current/yield`
  都不是空实现

### 2.2 host / console / time

4. `HostIf::get_host_cpu_num`
5. `HostIf::init_percpu`
6. `HostIf::exit`
7. `ConsoleIf::write_bytes`
8. `ConsoleIf::read_bytes`
9. `TimeIf::current_time_nanos`
10. `TimeIf::set_oneshot_timer`

当前依据：

- `get_host_cpu_num` 已经接宿主查询
- `init_percpu` 已经落到 `arch::init_percpu`
- `exit` 已经接宿主退出入口
- `console` 已经有输出/输入缓冲逻辑
- `time` 已经有单调时间与 RISC-V hrtimer backend

### 2.3 memory

23. `MemoryIf::alloc_frame`
24. `MemoryIf::alloc_contiguous_frames`
25. `MemoryIf::dealloc_frame`
26. `MemoryIf::dealloc_contiguous_frames`
27. `MemoryIf::phys_to_virt`
28. `MemoryIf::virt_to_phys`

当前依据：

- 已经接到了宿主导出的 frame / contiguous frame / 地址转换入口
- 不是占位 stub

## 3. 还需要补强实现

这一组不是没做，而是“第一版已经在，但离真正稳定可用还差一截”。

### 3.1 runtime 安装与启动胶水

2. `install_kernel_task_runtime`
29. runtime hook 安装链
30. runtime 入口桥接链

当前状态：

- runtime hook 安装链已经存在
- `run()` 也已经能整理上下文并触发 processor
- `run()` 最终已经通过
  - `core_link::boot`
  - `boot_vendor_bridge`
  - `vendor::axvisor_core::boot`
  - `axvisor_linux_bridge_boot_run()`
  进入真实 `axvisor_core::boot::run()`
- 但这条链本身仍然只是“入口桥接成立”
- 还不能单靠它证明 Linux guest 启动协议已经完全匹配

所以这组目前不能算完成，只能算：

- Linux 侧 glue 结构已成型
- runtime 入口桥接已接到真实 core

### 3.2 IRQ 组

21. `IrqIf::handle_irq`
22. `IrqIf::register_irq_handler`

当前状态：

- 本地 IRQ handler 注册/分发逻辑已经在
- RISC-V supervisor external vector 的识别也已经在
- external IRQ pending / drain 路径也已经搭起来了

但还缺一件关键事：

- 真实 `irq_id` 来源

也就是说，现在 external IRQ event 里主要还是：

- `vector`
- `cpu_id`
- `call_index`

而不是 Asterinas 那种真正能对 pending external interrupt 做遍历并逐个注入的状态。

所以 IRQ 组当前更准确应归类为：

- 已有较强骨架，但仍需补强

### 3.3 Arch 辅助语义

虽然这次 30 个编号主体里没有把 `ArchIf` 单独列为一组，但 Linux `arch/riscv64.rs` 已经在承接一些能力：

- `host_fdt_paddr`
- `host_tsc_frequency_mhz`
- `register_timer_bridge`
- `dispatch_external_irq`
- `register_irq_vector`

这说明：

- Arch backend 已经不是空白
- 但离真实 guest interrupt injection / core timer event logic 仍有距离

## 4. 必须等真实 core 接入后才能验证

这组接口最容易误判。

因为它们现在“看起来有路径”，但真正的逻辑还没有落到 AxVisor core。

### 4.1 timer 真实消费

10. `TimeIf::set_oneshot_timer`

这里要特别说明：

- “设置 one-shot timer” 这个接口本身，Linux 语义已经有了
- 但它是否真正满足 AxVisor core 对 timer event 的预期，必须等真实 core 接入后验证

原因：

- 当前 timer backend 已存在
- timer core path 现在已经是：
  - `core_link::timer`
  - `timer_vendor_bridge`
  - `vendor::axvisor_core::vmm::timer`
  - `axvisor_linux_bridge_timer_check_events()`
  - `axvisor_core::vmm::timer::check_events()`

所以它现在证明的是：

- 宿主 timer 能触发

但仍没有证明：

- `axvisor_core::vmm::timer::check_events()` 在 Linux 上真的语义正确

### 4.2 external IRQ 真实注入

21. `IrqIf::handle_irq`
22. `IrqIf::register_irq_handler`

同理：

- IRQ adapter 结构和 external pending 流水线已经有了
- 真实 guest 注入路径现在已经能落到：
  - `vendor::axvisor_core::arch::riscv64::inject_current_interrupt()`
  - `axvisor_linux_bridge_inject_current_interrupt()`
  - `axvisor_core::arch::riscv64::inject_current_interrupt(irq_id)`
- 但 Linux host adapter 目前传过去的基础数据仍然主要是 host trap `vector`
- 并不是真实设备 IRQ 源号
- 当前 `translated_guest_irq_id()` 只能算临时补丁，不是完整 passthrough 语义

所以现在只能证明：

- Linux adapter 能识别/缓存/转发 external IRQ 事件

还不能证明：

- 真正的 guest interrupt injection 成立

## 5. 每项接口的当前判断

为了后面核对方便，这里直接给出一张总表。

### 5.1 已具备 Linux 语义封装

- `1`
- `3`
- `4`
- `5`
- `6`
- `7`
- `8`
- `9`
- `10`
- `11`
- `12`
- `13`
- `14`
- `15`
- `16`
- `17`
- `18`
- `19`
- `20`
- `23`
- `24`
- `25`
- `26`
- `27`
- `28`

### 5.2 还需要补强实现

- `2`
- `21`
- `22`
- `29`
- `30`

### 5.3 必须等真实 core 接入后才能验证

- `10`
- `21`
- `22`

说明：

- 一个接口可以同时属于“已实现第一版”与“真实语义仍待验证”这两种视角中的后一类
- 比如 `10/21/22`
  不是没实现，而是只有结合真实 guest 运行路径，才能证明它们对 AxVisor 是否真的足够

## 6. 现阶段最重要的判断

如果用一句话概括当前状态：

- 这 30 个接口里，大多数 Linux 语义封装已经不空了
- `boot` / `timer` 路径已经能进真实 core
- 但真正会决定 AxVisor 能不能在 Linux 上跑 Linux guest 的，已经主要不是“接口数量”，而是：
  - RISC-V Linux guest 启动协议是否匹配当前加载模型
  - external IRQ passthrough 是否能拿到并注入真实设备 IRQ 源号

因此下一阶段的优先级，仍然应该是：

1. RISC-V Linux guest 镜像/启动协议核对
2. external IRQ 源号获取与映射
3. guest block 设备透传闭环验证
4. 最终 guest Linux 串口启动验证

而不是继续停留在“接口壳有没有继续多写几个”的层面。
