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
