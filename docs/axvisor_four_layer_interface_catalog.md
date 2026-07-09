# Axvisor 四层接口函数清单

> 目的：把 Axvisor 通用化架构中的四层边界落成一份可对照的接口目录。
>
> 四层分别是：
>
> 1. `host-api`
> 2. `runtime contract`
> 3. `hv-provider-api`
> 4. `device-model / control-plane`
>
> 本文不追求最终 Rust 签名完全定稿，重点是把“每一层应该拥有哪些接口函数语义”列清楚，并避免层间职责混淆。

---

## 一、总览

```text
device-model / control-plane
            │
            ▼
      runtime contract
            │
            ▼
      hv-provider-api
            │
            ▼
          host-api
```

理解方式：

- `host-api` 提供宿主底座基础能力
- `hv-provider-api` 把这些能力组织成硬件虚拟化执行面
- `runtime contract` 负责 Axvisor 自身运行时组织、调度、trap 分发、状态机协作
- `device-model / control-plane` 负责设备模拟、配置和管理面

---

## 二、`host-api` 接口函数

这一层回答的问题是：

> “宿主底座 OS 需要向 Axvisor 提供哪些基础能力？”

下面开始按“函数级颗粒度”展开。每个函数都按以下方式理解：

- `函数语义`：它真正负责什么
- `直接输入/输出`：它操作的对象是什么
- `边界约束`：它为什么属于这一层，而不属于别层

### 2.1 Memory 类

#### 内存分配与释放

- `alloc_pages(order) -> HostPageBlock`
- `alloc_contiguous(size, align) -> HostMemRegion`
- `dealloc_pages(block)`
- `dealloc_contiguous(region)`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 边界约束 |
|------|----------|----------|----------|----------|
| `alloc_pages(order)` | 分配若干页宿主页框 | `order` 或页数 | `HostPageBlock` | 只负责分配宿主页，不表达 guest memory slot |
| `alloc_contiguous(size, align)` | 分配连续宿主物理内存 | 长度、对齐 | `HostMemRegion` | 只保证宿主物理连续，不负责注册到 provider |
| `dealloc_pages(block)` | 释放页块 | `HostPageBlock` | `Result` 或 `()` | 宿主资源回收 |
| `dealloc_contiguous(region)` | 释放连续内存 | `HostMemRegion` | `Result` 或 `()` | 宿主资源回收 |

#### 地址转换

- `virt_to_phys(vaddr) -> HostPhysAddr`
- `phys_to_virt(paddr) -> HostVirtAddr`
- `page_size() -> usize`
- `host_page_shift() -> usize`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 边界约束 |
|------|----------|----------|----------|----------|
| `virt_to_phys(vaddr)` | 宿主虚拟地址转宿主物理地址 | `HostVirtAddr` | `HostPhysAddr` | 只做 host 地址转换，不做 GPA 翻译 |
| `phys_to_virt(paddr)` | 宿主物理地址转宿主虚拟地址 | `HostPhysAddr` | `HostVirtAddr` | 只做 host 地址转换 |
| `page_size()` | 返回宿主页大小 | 无 | `usize` | 宿主内存属性 |
| `host_page_shift()` | 返回页大小 shift | 无 | `usize` | 宿主内存属性 |

#### 映射与解绑

- `map_host_pages(vaddr, paddr, len, perms) -> Result`
- `unmap_host_pages(vaddr, len) -> Result`
- `protect_host_pages(vaddr, len, perms) -> Result`
- `flush_host_tlb(vaddr, len) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 边界约束 |
|------|----------|----------|----------|----------|
| `map_host_pages(vaddr, paddr, len, perms)` | 建立 host 侧页表映射 | HVA/HPA/长度/权限 | `Result` | 只作用于 host 地址空间 |
| `unmap_host_pages(vaddr, len)` | 撤销 host 映射 | HVA、长度 | `Result` | 不等于 guest unmap |
| `protect_host_pages(vaddr, len, perms)` | 修改 host 页权限 | HVA、长度、权限 | `Result` | host 内存保护 |
| `flush_host_tlb(vaddr, len)` | 刷新 host 地址变换缓存 | HVA、长度 | `Result` | host TLB 语义，不是 guest TLB |

#### 物理驻留保证

- `pin_pages(vaddr, len) -> PinnedPages`
- `unpin_pages(pinned) -> Result`
- `is_pinned(vaddr, len) -> bool`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 边界约束 |
|------|----------|----------|----------|----------|
| `pin_pages(vaddr, len)` | 保证一段 host 页面物理驻留 | HVA、长度 | `PinnedPages` | 为 guest memory 注册提供前提，但不是注册本身 |
| `unpin_pages(pinned)` | 取消物理驻留保证 | `PinnedPages` | `Result` | 宿主页面生命周期 |
| `is_pinned(vaddr, len)` | 查询是否已 pin | HVA、长度 | `bool` | 查询 host 资源状态 |

#### 地址空间辅助

- `create_host_address_space() -> HostAddressSpace`
- `destroy_host_address_space(aspace) -> Result`
- `switch_host_address_space(aspace) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 边界约束 |
|------|----------|----------|----------|----------|
| `create_host_address_space()` | 创建宿主地址空间对象 | 配置或无 | `HostAddressSpace` | host 执行环境辅助 |
| `destroy_host_address_space(aspace)` | 销毁宿主地址空间 | `HostAddressSpace` | `Result` | host 资源销毁 |
| `switch_host_address_space(aspace)` | 切换宿主地址空间 | `HostAddressSpace` | `Result` | host 上下文切换原语 |

### 2.2 Time 类

#### 时间读取

- `now_monotonic_ns() -> u64`
- `now_wallclock_ns() -> u64`
- `host_cycle_counter() -> u64`
- `host_counter_frequency() -> u64`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 边界约束 |
|------|----------|----------|----------|----------|
| `now_monotonic_ns()` | 获取单调递增宿主时间 | 无 | `u64` | host 时间源 |
| `now_wallclock_ns()` | 获取墙钟时间 | 无 | `u64` | host 时间源 |
| `host_cycle_counter()` | 读取宿主周期计数器 | 无 | `u64` | 只是 host counter，不是 guest 时间虚拟化 |
| `host_counter_frequency()` | 返回计数器频率 | 无 | `u64` | host counter 属性 |

#### 定时器

- `create_timer(deadline_ns, callback) -> HostTimer`
- `cancel_timer(timer) -> Result`
- `rearm_timer(timer, deadline_ns) -> Result`
- `timer_is_pending(timer) -> bool`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 边界约束 |
|------|----------|----------|----------|----------|
| `create_timer(deadline_ns, callback)` | 创建 host 定时器 | deadline、回调 | `HostTimer` | host timer，不等于 guest timer 寄存器编程 |
| `cancel_timer(timer)` | 取消 host 定时器 | `HostTimer` | `Result` | host timer 生命周期 |
| `rearm_timer(timer, deadline_ns)` | 重设 host 定时器 | `HostTimer`、deadline | `Result` | host timer 生命周期 |
| `timer_is_pending(timer)` | 查询 host 定时器状态 | `HostTimer` | `bool` | host timer 查询 |

#### 延迟与超时

- `sleep_ns(duration_ns) -> Result`
- `yield_until(deadline_ns) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 边界约束 |
|------|----------|----------|----------|----------|
| `sleep_ns(duration_ns)` | 当前 host 任务睡眠 | duration | `Result` | host 调度原语 |
| `yield_until(deadline_ns)` | 让出执行直到 deadline | deadline | `Result` | host 调度原语 |

### 2.3 Task / Runtime Support 类

#### 执行上下文

- `spawn_kernel_task(entry, arg) -> HostTask`
- `spawn_pinned_task(cpu_id, entry, arg) -> HostTask`
- `exit_current_task() -> !`
- `join_task(task) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 边界约束 |
|------|----------|----------|----------|----------|
| `spawn_kernel_task(entry, arg)` | 创建宿主执行体 | 入口、参数 | `HostTask` | 承载 vCPU loop，但不是 vCPU create |
| `spawn_pinned_task(cpu_id, entry, arg)` | 创建绑核执行体 | CPU、入口、参数 | `HostTask` | host 调度策略 |
| `exit_current_task()` | 结束当前执行体 | 无 | `!` | host 生命周期控制 |
| `join_task(task)` | 等待任务退出 | `HostTask` | `Result` | host 生命周期控制 |

#### 调度控制

- `yield_now()`
- `park_current() -> Result`
- `wake_task(task) -> Result`
- `set_task_affinity(task, mask) -> Result`
- `current_task_id() -> HostTaskId`
- `current_cpu_id() -> CpuId`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 边界约束 |
|------|----------|----------|----------|----------|
| `yield_now()` | 主动让出 CPU | 无 | `()` | host 调度原语 |
| `park_current()` | 挂起当前任务 | 无 | `Result` | host 调度原语 |
| `wake_task(task)` | 唤醒任务 | `HostTask` | `Result` | host 调度原语 |
| `set_task_affinity(task, mask)` | 设置 CPU 亲和性 | `HostTask`、mask | `Result` | host 调度策略 |
| `current_task_id()` | 获取当前任务 ID | 无 | `HostTaskId` | host introspection |
| `current_cpu_id()` | 获取当前 CPU ID | 无 | `CpuId` | host introspection |

#### 每 CPU / 本地状态

- `this_cpu_ptr(key) -> *mut T`
- `with_preempt_disabled(f)`
- `is_in_interrupt_context() -> bool`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 边界约束 |
|------|----------|----------|----------|----------|
| `this_cpu_ptr(key)` | 访问 per-CPU 数据 | key | 指针/引用 | host 本地状态 |
| `with_preempt_disabled(f)` | 在关抢占区执行闭包 | 闭包 | 闭包返回值 | host 执行约束 |
| `is_in_interrupt_context()` | 判断是否处于中断上下文 | 无 | `bool` | host 上下文状态 |

### 2.4 Irq 类

#### 本地中断控制

- `disable_local_irq()`
- `enable_local_irq()`
- `save_local_irq_state() -> IrqState`
- `restore_local_irq_state(state)`
- `local_irq_enabled() -> bool`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 边界约束 |
|------|----------|----------|----------|----------|
| `disable_local_irq()` | 关闭本地 CPU 中断 | 无 | `()` | host IRQ 原语 |
| `enable_local_irq()` | 开启本地 CPU 中断 | 无 | `()` | host IRQ 原语 |
| `save_local_irq_state()` | 保存并关闭 IRQ 状态 | 无 | `IrqState` | host IRQ 原语 |
| `restore_local_irq_state(state)` | 恢复 IRQ 状态 | `IrqState` | `()` | host IRQ 原语 |
| `local_irq_enabled()` | 查询 IRQ 开关 | 无 | `bool` | host IRQ 状态 |

#### IPI / CPU 间通知

- `send_ipi(target_cpu, vector) -> Result`
- `broadcast_ipi(vector) -> Result`
- `kick_cpu(target_cpu) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 边界约束 |
|------|----------|----------|----------|----------|
| `send_ipi(target_cpu, vector)` | 向目标 CPU 发送 IPI | CPU、vector | `Result` | host CPU 间通知 |
| `broadcast_ipi(vector)` | 广播 IPI | vector | `Result` | host CPU 间通知 |
| `kick_cpu(target_cpu)` | 促使目标 CPU 尽快响应 | CPU | `Result` | host CPU 间通知，不等于 kick guest vCPU 协议 |

#### trap 辅助

- `install_trap_vector(entry) -> Result`
- `current_trap_frame() -> *mut TrapFrame`
- `ack_host_interrupt(irq) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 边界约束 |
|------|----------|----------|----------|----------|
| `install_trap_vector(entry)` | 安装宿主 trap 入口 | 入口地址 | `Result` | host trap 基础设施 |
| `current_trap_frame()` | 获取当前 trap frame | 无 | trap frame 指针 | host trap 基础设施 |
| `ack_host_interrupt(irq)` | 应答宿主中断控制器 | irq | `Result` | host 中断控制 |

### 2.5 Platform / Arch 类

#### CPU / 平台探测

- `cpu_has_feature(feature) -> bool`
- `probe_virtualization_extensions() -> VirtFeatureSet`
- `cpu_count() -> usize`
- `platform_info() -> PlatformInfo`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 边界约束 |
|------|----------|----------|----------|----------|
| `cpu_has_feature(feature)` | 查询 CPU 特性 | feature | `bool` | host/platform 探测 |
| `probe_virtualization_extensions()` | 查询硬件虚拟化基础扩展 | 无或配置 | `VirtFeatureSet` | host 平台探测，不等于 provider capability |
| `cpu_count()` | 查询 CPU 数量 | 无 | `usize` | host/platform 信息 |
| `platform_info()` | 查询平台元信息 | 无 | `PlatformInfo` | host/platform 信息 |

#### 寄存器原语

- `read_host_csr(id) -> u64`
- `write_host_csr(id, val) -> Result`
- `read_host_msr(id) -> u64`
- `write_host_msr(id, val) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 边界约束 |
|------|----------|----------|----------|----------|
| `read_host_csr(id)` | 读宿主当前 CSR | CSR 编号 | `u64` | 读的是 host 当前硬件状态 |
| `write_host_csr(id, val)` | 写宿主当前 CSR | CSR 编号、值 | `Result` | 只是寄存器原语 |
| `read_host_msr(id)` | 读宿主当前 MSR | MSR 编号 | `u64` | x86 host 寄存器原语 |
| `write_host_msr(id, val)` | 写宿主当前 MSR | MSR 编号、值 | `Result` | x86 host 寄存器原语 |

#### 平台初始化

- `early_platform_init() -> Result`
- `late_platform_init() -> Result`
- `enable_virtualization_mode() -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 边界约束 |
|------|----------|----------|----------|----------|
| `early_platform_init()` | 宿主早期初始化 | 无 | `Result` | host 生命周期 |
| `late_platform_init()` | 宿主后期初始化 | 无 | `Result` | host 生命周期 |
| `enable_virtualization_mode()` | 开启宿主硬件虚拟化基本模式 | 无 | `Result` | host 平台准备，不等价于 `create_vm()` 或 `run_vcpu()` |

#### 基础 I/O 和装载辅助

- `console_write(bytes) -> Result`
- `load_image(desc) -> LoadedImage`
- `read_fdt() -> Option<FdtBlob>`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 边界约束 |
|------|----------|----------|----------|----------|
| `console_write(bytes)` | 向宿主控制台输出 | bytes | `Result` | 基础宿主 I/O |
| `load_image(desc)` | 装载镜像到宿主内存 | 描述符 | `LoadedImage` | 基础装载，不是 VM 启动控制面 |
| `read_fdt()` | 读取平台设备树 | 无 | `Option<FdtBlob>` | 平台信息获取 |

---

## 三、`runtime contract` 接口函数

这一层回答的问题是：

> “Axvisor 自己作为一个运行中的系统，需要哪些运行时组织接口，才能把 provider、device model 和 host glue 串起来？”

注意：

- 这一层不是硬件虚拟化执行面本身
- 这一层也不是普通 host trait
- 它负责的是 Axvisor 内部的生命周期和运行时编排

### 3.1 VM / vCPU runtime 生命周期

- `register_vm(vm_ctx) -> VmRuntimeHandle`
- `unregister_vm(vm_handle) -> Result`
- `register_vcpu(vm_handle, vcpu_ctx) -> VcpuRuntimeHandle`
- `unregister_vcpu(vcpu_handle) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 runtime |
|------|----------|----------|----------|--------------------|
| `register_vm(vm_ctx)` | 把 VM 运行时对象接入 Axvisor runtime | VM 上下文 | `VmRuntimeHandle` | 这是 Axvisor 内部编排，不是 provider create |
| `unregister_vm(vm_handle)` | 从 runtime 中移除 VM | runtime handle | `Result` | Axvisor 内部生命周期 |
| `register_vcpu(vm_handle, vcpu_ctx)` | 接入 vCPU runtime 对象 | VM handle、vCPU 上下文 | `VcpuRuntimeHandle` | runtime 编排，不等于 provider vCPU 分配 |
| `unregister_vcpu(vcpu_handle)` | 移除 vCPU runtime 对象 | runtime handle | `Result` | Axvisor 内部生命周期 |

### 3.2 runtime 调度与执行

- `start_vcpu_loop(vcpu_handle) -> Result`
- `stop_vcpu_loop(vcpu_handle) -> Result`
- `pause_vcpu_loop(vcpu_handle) -> Result`
- `resume_vcpu_loop(vcpu_handle) -> Result`
- `kick_vcpu_loop(vcpu_handle) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 runtime |
|------|----------|----------|----------|--------------------|
| `start_vcpu_loop(vcpu_handle)` | 启动 Axvisor 管理的 vCPU 主循环 | vCPU runtime handle | `Result` | 它组织循环，但循环内部才会调用 `run_vcpu()` |
| `stop_vcpu_loop(vcpu_handle)` | 停止主循环 | vCPU runtime handle | `Result` | runtime 调度 |
| `pause_vcpu_loop(vcpu_handle)` | 把主循环切到暂停态 | vCPU runtime handle | `Result` | runtime 状态控制 |
| `resume_vcpu_loop(vcpu_handle)` | 恢复主循环 | vCPU runtime handle | `Result` | runtime 状态控制 |
| `kick_vcpu_loop(vcpu_handle)` | 请求主循环尽快醒来处理事件 | vCPU runtime handle | `Result` | runtime 协作，不等于 provider 的低层 kick |

### 3.3 trap / exit 分发

- `dispatch_vmexit(vcpu_handle, exit) -> VmexitAction`
- `dispatch_host_trap(trap_frame) -> TrapAction`
- `dispatch_hypercall(vcpu_handle, hypercall) -> HypercallResult`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 runtime |
|------|----------|----------|----------|--------------------|
| `dispatch_vmexit(vcpu_handle, exit)` | 根据 `VmExit` 决定上层动作 | vCPU handle、`VmExit` | `VmexitAction` | provider 只返回 exit，runtime 决定怎么处理 |
| `dispatch_host_trap(trap_frame)` | 分发 host trap | trap frame | `TrapAction` | Axvisor 运行时 glue |
| `dispatch_hypercall(vcpu_handle, hypercall)` | 分发 hypercall | vCPU、hypercall 结构 | `HypercallResult` | 运行时协议，不是 provider 原语 |

### 3.4 状态机管理

- `set_vm_state(vm_handle, state) -> Result`
- `get_vm_state(vm_handle) -> VmState`
- `set_vcpu_state(vcpu_handle, state) -> Result`
- `get_vcpu_state(vcpu_handle) -> VcpuState`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 runtime |
|------|----------|----------|----------|--------------------|
| `set_vm_state(vm_handle, state)` | 更新 VM 运行状态 | handle、状态 | `Result` | VM 生命周期编排 |
| `get_vm_state(vm_handle)` | 查询 VM 状态 | handle | `VmState` | runtime 状态机 |
| `set_vcpu_state(vcpu_handle, state)` | 更新 vCPU 状态 | handle、状态 | `Result` | runtime 状态机 |
| `get_vcpu_state(vcpu_handle)` | 查询 vCPU 状态 | handle | `VcpuState` | runtime 状态机 |

### 3.5 上下文协调

- `save_runtime_context(vcpu_handle) -> Result`
- `restore_runtime_context(vcpu_handle) -> Result`
- `prepare_world_switch(vcpu_handle) -> Result`
- `finish_world_switch(vcpu_handle, exit) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 runtime |
|------|----------|----------|----------|--------------------|
| `save_runtime_context(vcpu_handle)` | 保存 Axvisor 运行时关心的宿主上下文 | vCPU handle | `Result` | 不是 guest 状态读写，而是运行时 glue |
| `restore_runtime_context(vcpu_handle)` | 恢复运行时上下文 | vCPU handle | `Result` | runtime glue |
| `prepare_world_switch(vcpu_handle)` | 进入 provider 之前准备运行时环境 | vCPU handle | `Result` | world switch 外围组织 |
| `finish_world_switch(vcpu_handle, exit)` | 从 provider 返回后收尾 | vCPU handle、`VmExit` | `Result` | world switch 外围组织 |

### 3.6 同步与请求

- `enqueue_vcpu_request(vcpu_handle, req) -> Result`
- `drain_vcpu_requests(vcpu_handle) -> RequestSet`
- `enqueue_vm_request(vm_handle, req) -> Result`
- `sync_remote_vcpu(vcpu_handle, reason) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 runtime |
|------|----------|----------|----------|--------------------|
| `enqueue_vcpu_request(vcpu_handle, req)` | 给 vCPU runtime 投递请求 | handle、请求 | `Result` | Axvisor 内部协作协议 |
| `drain_vcpu_requests(vcpu_handle)` | 提取待处理请求 | handle | `RequestSet` | runtime 协作协议 |
| `enqueue_vm_request(vm_handle, req)` | 给 VM runtime 投递请求 | handle、请求 | `Result` | runtime 协作协议 |
| `sync_remote_vcpu(vcpu_handle, reason)` | 请求远端 vCPU 执行同步动作 | handle、原因 | `Result` | runtime 协作协议 |

### 3.7 资源装配

- `attach_guest_memory(vm_handle, guest_mem) -> Result`
- `attach_irq_router(vm_handle, router) -> Result`
- `attach_device_bus(vm_handle, bus) -> Result`
- `attach_console(vm_handle, console) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 runtime |
|------|----------|----------|----------|--------------------|
| `attach_guest_memory(vm_handle, guest_mem)` | 把 guest memory 对象挂到 runtime VM | VM handle、guest_mem | `Result` | runtime 资源装配，不等于 provider register |
| `attach_irq_router(vm_handle, router)` | 装配 IRQ 路由对象 | VM handle、router | `Result` | runtime 资源装配 |
| `attach_device_bus(vm_handle, bus)` | 装配设备总线 | VM handle、bus | `Result` | runtime 资源装配 |
| `attach_console(vm_handle, console)` | 装配控制台 | VM handle、console | `Result` | runtime 资源装配 |

---

## 四、`hv-provider-api` 接口函数

这一层回答的问题是：

> “谁负责让 guest 真正跑起来，以及怎么和硬件虚拟化机制交互？”

这一层是硬件虚拟化执行面核心。

### 4.1 VM 生命周期

- `create_vm(config) -> ProviderVm`
- `destroy_vm(vm) -> Result`
- `reset_vm(vm) -> Result`
- `query_vm_capability(vm, cap) -> CapabilityValue`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 provider |
|------|----------|----------|----------|---------------------|
| `create_vm(config)` | 在虚拟化提供者中创建 VM | provider config | `ProviderVm` | 这是 provider 资源和虚拟化上下文创建 |
| `destroy_vm(vm)` | 销毁 provider VM | `ProviderVm` | `Result` | provider 生命周期 |
| `reset_vm(vm)` | 重置 VM 执行面状态 | `ProviderVm` | `Result` | provider 生命周期 |
| `query_vm_capability(vm, cap)` | 查询 provider VM 级能力 | VM、cap | `CapabilityValue` | provider 能力，不是 host platform feature |

### 4.2 vCPU 生命周期

- `create_vcpu(vm, vcpu_id) -> ProviderVcpu`
- `destroy_vcpu(vcpu) -> Result`
- `reset_vcpu(vcpu) -> Result`
- `bind_vcpu(vcpu, cpu_id) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 provider |
|------|----------|----------|----------|---------------------|
| `create_vcpu(vm, vcpu_id)` | 在 provider 中创建 vCPU | VM、id | `ProviderVcpu` | 这是 guest CPU 对象，不是 host task |
| `destroy_vcpu(vcpu)` | 销毁 provider vCPU | `ProviderVcpu` | `Result` | provider 生命周期 |
| `reset_vcpu(vcpu)` | 重置 guest CPU 状态 | `ProviderVcpu` | `Result` | provider 生命周期 |
| `bind_vcpu(vcpu, cpu_id)` | 绑定 provider vCPU 到目标 CPU/执行位置 | vCPU、CPU | `Result` | provider 执行策略 |

### 4.3 Guest 内存注册

- `register_guest_memory(vm, gpa, host_region, perms) -> Result`
- `unregister_guest_memory(vm, gpa, len) -> Result`
- `modify_guest_memory(vm, gpa, len, perms) -> Result`
- `sync_guest_memory(vm) -> Result`
- `flush_guest_tlb(vm, range) -> Result`
- `read_guest_memory(vm, gpa, buf) -> Result`
- `write_guest_memory(vm, gpa, buf) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 provider |
|------|----------|----------|----------|---------------------|
| `register_guest_memory(vm, gpa, host_region, perms)` | 把 host memory 暴露为 guest 物理内存 | VM、GPA、host region、权限 | `Result` | 这是 guest 地址空间注册，不是 host pin |
| `unregister_guest_memory(vm, gpa, len)` | 移除 guest 内存区域 | VM、GPA、长度 | `Result` | provider 二阶段地址空间更新 |
| `modify_guest_memory(vm, gpa, len, perms)` | 修改 guest memory 属性 | VM、GPA、长度、权限 | `Result` | provider 地址空间管理 |
| `sync_guest_memory(vm)` | 同步 provider 内部映射状态 | VM | `Result` | provider 同步动作 |
| `flush_guest_tlb(vm, range)` | 刷新 guest 侧翻译缓存 | VM、范围 | `Result` | guest TLB 语义 |
| `read_guest_memory(vm, gpa, buf)` | 通过 provider 读 guest 内存 | VM、GPA、缓冲区 | `Result` | guest 内存语义 |
| `write_guest_memory(vm, gpa, buf)` | 通过 provider 写 guest 内存 | VM、GPA、缓冲区 | `Result` | guest 内存语义 |

### 4.4 vCPU 运行

- `run_vcpu(vcpu) -> VmExit`
- `resume_vcpu(vcpu) -> VmExit`
- `pause_vcpu(vcpu) -> Result`
- `kick_vcpu(vcpu) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 provider |
|------|----------|----------|----------|---------------------|
| `run_vcpu(vcpu)` | 进入 guest 直到第一次退出 | `ProviderVcpu` | `VmExit` | 最核心的硬件虚拟化执行语义 |
| `resume_vcpu(vcpu)` | 继续上次 guest 执行 | `ProviderVcpu` | `VmExit` | provider 执行语义 |
| `pause_vcpu(vcpu)` | 暂停 provider vCPU | `ProviderVcpu` | `Result` | provider 执行控制 |
| `kick_vcpu(vcpu)` | 强制正在运行的 vCPU 尽快返回 | `ProviderVcpu` | `Result` | provider 执行控制 |

### 4.5 Guest 状态访问

#### 通用寄存器

- `get_gpr(vcpu, reg) -> u64`
- `set_gpr(vcpu, reg, val) -> Result`
- `get_pc(vcpu) -> u64`
- `set_pc(vcpu, pc) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 provider |
|------|----------|----------|----------|---------------------|
| `get_gpr(vcpu, reg)` | 读取 guest GPR | vCPU、寄存器 ID | `u64` | 读的是 guest 状态，不是 host 当前寄存器 |
| `set_gpr(vcpu, reg, val)` | 写 guest GPR | vCPU、寄存器 ID、值 | `Result` | guest 状态设置 |
| `get_pc(vcpu)` | 读取 guest PC | vCPU | `u64` | guest 状态设置 |
| `set_pc(vcpu, pc)` | 写 guest PC | vCPU、PC | `Result` | guest 状态设置 |

#### 特权寄存器 / CSR / MSR

- `get_ctrl_reg(vcpu, reg) -> u64`
- `set_ctrl_reg(vcpu, reg, val) -> Result`
- `get_sys_reg(vcpu, reg) -> u64`
- `set_sys_reg(vcpu, reg, val) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 provider |
|------|----------|----------|----------|---------------------|
| `get_ctrl_reg(vcpu, reg)` | 读取 guest 控制寄存器 | vCPU、寄存器 ID | `u64` | guest 特权状态 |
| `set_ctrl_reg(vcpu, reg, val)` | 写 guest 控制寄存器 | vCPU、寄存器 ID、值 | `Result` | guest 特权状态 |
| `get_sys_reg(vcpu, reg)` | 读取 guest CSR/MSR/系统寄存器 | vCPU、寄存器 ID | `u64` | guest 系统状态 |
| `set_sys_reg(vcpu, reg, val)` | 写 guest CSR/MSR/系统寄存器 | vCPU、寄存器 ID、值 | `Result` | guest 系统状态 |

#### 批量状态

- `snapshot_vcpu_state(vcpu) -> VcpuStateBlob`
- `restore_vcpu_state(vcpu, blob) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 provider |
|------|----------|----------|----------|---------------------|
| `snapshot_vcpu_state(vcpu)` | 批量导出 guest CPU 状态 | vCPU | `VcpuStateBlob` | provider 定义 guest 状态模型 |
| `restore_vcpu_state(vcpu, blob)` | 批量恢复 guest CPU 状态 | vCPU、状态 blob | `Result` | provider 定义 guest 状态模型 |

### 4.6 VM Exit 表达

建议统一由 `VmExit` 表达，至少覆盖：

- `VmExit::MmioRead { gpa, len, target }`
- `VmExit::MmioWrite { gpa, len, data }`
- `VmExit::PioRead { port, len }`
- `VmExit::PioWrite { port, len, data }`
- `VmExit::GuestPageFault { gpa, access, reason }`
- `VmExit::Hypercall { nr, args }`
- `VmExit::InterruptWindowOpen`
- `VmExit::Halt`
- `VmExit::Shutdown`
- `VmExit::Reset`
- `VmExit::FailEntry { code }`
- `VmExit::InternalError { code }`

### 4.7 虚拟中断注入

- `inject_interrupt(vcpu, irq) -> Result`
- `inject_exception(vcpu, exn) -> Result`
- `set_irq_line(vm, irq, level) -> Result`
- `signal_msi(vm, msg) -> Result`
- `create_irqchip(vm, config) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 provider |
|------|----------|----------|----------|---------------------|
| `inject_interrupt(vcpu, irq)` | 向 guest 注入中断 | vCPU、irq 描述 | `Result` | 这是 guest 中断语义 |
| `inject_exception(vcpu, exn)` | 向 guest 注入异常 | vCPU、异常描述 | `Result` | guest 异常语义 |
| `set_irq_line(vm, irq, level)` | 改变虚拟 IRQ 线电平 | VM、irq、level | `Result` | 虚拟中断控制 |
| `signal_msi(vm, msg)` | 向 guest 注入 MSI/MSI-X | VM、MSI 消息 | `Result` | 虚拟中断控制 |
| `create_irqchip(vm, config)` | 创建虚拟 irqchip | VM、配置 | `Result` | provider 虚拟中断设施 |

### 4.8 Guest 时间虚拟化

- `get_guest_time(vcpu) -> u64`
- `set_guest_time_offset(vm, offset_ns) -> Result`
- `set_guest_cycle_offset(vm, offset) -> Result`
- `set_guest_cycle_scale(vm, scale) -> Result`
- `program_guest_timer(vcpu, deadline) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 provider |
|------|----------|----------|----------|---------------------|
| `get_guest_time(vcpu)` | 读取 guest 可见时间 | vCPU | `u64` | guest 时间语义 |
| `set_guest_time_offset(vm, offset_ns)` | 设置 guest 时间偏移 | VM、offset | `Result` | guest 时间虚拟化 |
| `set_guest_cycle_offset(vm, offset)` | 设置 guest cycle/TSC 偏移 | VM、offset | `Result` | guest 时间虚拟化 |
| `set_guest_cycle_scale(vm, scale)` | 设置 cycle/TSC 缩放 | VM、scale | `Result` | guest 时间虚拟化 |
| `program_guest_timer(vcpu, deadline)` | 编程 guest 定时器状态 | vCPU、deadline | `Result` | guest 时间/中断语义 |

### 4.9 provider 扩展能力

- `check_extension(cap) -> bool`
- `enable_extension(vm, cap, args) -> Result`
- `get_dirty_log(vm, slot) -> DirtyBitmap`
- `register_ioevent(vm, event) -> Result`
- `register_irqfd(vm, irqfd) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 provider |
|------|----------|----------|----------|---------------------|
| `check_extension(cap)` | 查询 provider 是否支持某扩展 | cap | `bool` | provider 能力 |
| `enable_extension(vm, cap, args)` | 启用某 provider 扩展 | VM、cap、参数 | `Result` | provider 能力配置 |
| `get_dirty_log(vm, slot)` | 获取脏页位图 | VM、slot | `DirtyBitmap` | provider guest memory 扩展 |
| `register_ioevent(vm, event)` | 注册 ioevent 优化 | VM、event | `Result` | provider 扩展 |
| `register_irqfd(vm, irqfd)` | 注册 irqfd 优化 | VM、irqfd | `Result` | provider 扩展 |

---

## 五、`device-model / control-plane` 接口函数

这一层回答的问题是：

> “guest 跑起来以后，设备怎么模拟，配置怎么下发，控制面怎么组织？”

### 5.1 VM 配置与装载

- `create_vm_config(spec) -> VmConfig`
- `validate_vm_config(config) -> Result`
- `load_guest_kernel(vm, image) -> Result`
- `load_guest_initrd(vm, image) -> Result`
- `load_guest_fdt(vm, blob) -> Result`
- `set_boot_args(vm, args) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 control-plane |
|------|----------|----------|----------|--------------------------|
| `create_vm_config(spec)` | 从外部规格构造 VM 配置 | spec | `VmConfig` | 管理面配置 |
| `validate_vm_config(config)` | 校验配置合法性 | 配置 | `Result` | 管理面配置 |
| `load_guest_kernel(vm, image)` | 把内核映像装载到 guest | VM、镜像 | `Result` | 启动控制面 |
| `load_guest_initrd(vm, image)` | 装载 initrd | VM、镜像 | `Result` | 启动控制面 |
| `load_guest_fdt(vm, blob)` | 装载设备树 | VM、blob | `Result` | 启动控制面 |
| `set_boot_args(vm, args)` | 设置 guest 启动参数 | VM、args | `Result` | 启动控制面 |

### 5.2 设备总线与设备生命周期

- `create_device_bus(vm) -> DeviceBus`
- `register_device(bus, dev) -> Result`
- `unregister_device(bus, dev_id) -> Result`
- `reset_device(dev) -> Result`
- `snapshot_device(dev) -> DeviceStateBlob`
- `restore_device(dev, blob) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 device-model |
|------|----------|----------|----------|-------------------------|
| `create_device_bus(vm)` | 创建 VM 的设备总线 | VM | `DeviceBus` | 设备模型基础设施 |
| `register_device(bus, dev)` | 把设备接入总线 | bus、device | `Result` | 设备模型基础设施 |
| `unregister_device(bus, dev_id)` | 从总线移除设备 | bus、id | `Result` | 设备模型基础设施 |
| `reset_device(dev)` | 重置设备状态 | device | `Result` | 设备模型生命周期 |
| `snapshot_device(dev)` | 导出设备状态 | device | `DeviceStateBlob` | 设备模型生命周期 |
| `restore_device(dev, blob)` | 恢复设备状态 | device、blob | `Result` | 设备模型生命周期 |

### 5.3 MMIO / PIO 设备模型

- `handle_mmio_read(bus, gpa, len) -> MmioReadResult`
- `handle_mmio_write(bus, gpa, len, data) -> Result`
- `handle_pio_read(bus, port, len) -> PioReadResult`
- `handle_pio_write(bus, port, len, data) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 device-model |
|------|----------|----------|----------|-------------------------|
| `handle_mmio_read(bus, gpa, len)` | 解释一次 MMIO 读并返回设备数据 | bus、GPA、长度 | `MmioReadResult` | provider 只返回 trap，这里才解释设备语义 |
| `handle_mmio_write(bus, gpa, len, data)` | 解释一次 MMIO 写 | bus、GPA、长度、数据 | `Result` | 设备模型 |
| `handle_pio_read(bus, port, len)` | 解释一次 PIO 读 | bus、port、长度 | `PioReadResult` | 设备模型 |
| `handle_pio_write(bus, port, len, data)` | 解释一次 PIO 写 | bus、port、长度、数据 | `Result` | 设备模型 |

### 5.4 virtio / 块 / 网络 / 控制台

- `create_virtio_blk(cfg) -> Device`
- `create_virtio_net(cfg) -> Device`
- `create_virtio_console(cfg) -> Device`
- `create_serial(cfg) -> Device`
- `create_rng(cfg) -> Device`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 device-model |
|------|----------|----------|----------|-------------------------|
| `create_virtio_blk(cfg)` | 创建 virtio-block 设备 | 配置 | `Device` | 设备模型 |
| `create_virtio_net(cfg)` | 创建 virtio-net 设备 | 配置 | `Device` | 设备模型 |
| `create_virtio_console(cfg)` | 创建 virtio-console 设备 | 配置 | `Device` | 设备模型 |
| `create_serial(cfg)` | 创建串口设备 | 配置 | `Device` | 设备模型 |
| `create_rng(cfg)` | 创建随机设备 | 配置 | `Device` | 设备模型 |

#### 后端 I/O

- `read_block(backend, sector, buf) -> Result`
- `write_block(backend, sector, buf) -> Result`
- `recv_net_frame(backend, buf) -> usize`
- `send_net_frame(backend, buf) -> Result`
- `console_rx(console) -> usize`
- `console_tx(console, bytes) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 device-model |
|------|----------|----------|----------|-------------------------|
| `read_block(backend, sector, buf)` | 从块后端读取数据 | 后端、扇区、缓冲区 | `Result` | 设备后端 I/O |
| `write_block(backend, sector, buf)` | 向块后端写数据 | 后端、扇区、缓冲区 | `Result` | 设备后端 I/O |
| `recv_net_frame(backend, buf)` | 从网络后端收包 | 后端、缓冲区 | 长度 | 设备后端 I/O |
| `send_net_frame(backend, buf)` | 向网络后端发包 | 后端、缓冲区 | `Result` | 设备后端 I/O |
| `console_rx(console)` | 从控制台后端收字节 | console | 长度/字节数 | 设备后端 I/O |
| `console_tx(console, bytes)` | 向控制台后端发字节 | console、bytes | `Result` | 设备后端 I/O |

### 5.5 控制面

- `vm_create(request) -> VmId`
- `vm_start(vm_id) -> Result`
- `vm_pause(vm_id) -> Result`
- `vm_resume(vm_id) -> Result`
- `vm_shutdown(vm_id) -> Result`
- `vm_destroy(vm_id) -> Result`
- `vcpu_hotplug(vm_id, spec) -> Result`
- `mem_hotplug(vm_id, spec) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 control-plane |
|------|----------|----------|----------|--------------------------|
| `vm_create(request)` | 处理创建 VM 请求 | request | `VmId` | 用户/上层入口 |
| `vm_start(vm_id)` | 启动 VM | VM ID | `Result` | 管理操作 |
| `vm_pause(vm_id)` | 暂停 VM | VM ID | `Result` | 管理操作 |
| `vm_resume(vm_id)` | 恢复 VM | VM ID | `Result` | 管理操作 |
| `vm_shutdown(vm_id)` | 关闭 VM | VM ID | `Result` | 管理操作 |
| `vm_destroy(vm_id)` | 销毁 VM | VM ID | `Result` | 管理操作 |
| `vcpu_hotplug(vm_id, spec)` | 动态添加/移除 vCPU | VM ID、规格 | `Result` | 管理操作 |
| `mem_hotplug(vm_id, spec)` | 动态内存变更 | VM ID、规格 | `Result` | 管理操作 |

### 5.6 管理接口

- `handle_cli_command(cmd) -> Result`
- `handle_rpc_request(req) -> RpcResponse`
- `query_vm_info(vm_id) -> VmInfo`
- `query_vcpu_info(vm_id, vcpu_id) -> VcpuInfo`
- `dump_vm_state(vm_id) -> StateReport`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 control-plane |
|------|----------|----------|----------|--------------------------|
| `handle_cli_command(cmd)` | 处理 CLI 命令 | command | `Result` | 管理入口 |
| `handle_rpc_request(req)` | 处理 RPC 请求 | request | `RpcResponse` | 管理入口 |
| `query_vm_info(vm_id)` | 查询 VM 信息 | VM ID | `VmInfo` | 管理查询 |
| `query_vcpu_info(vm_id, vcpu_id)` | 查询 vCPU 信息 | VM ID、vCPU ID | `VcpuInfo` | 管理查询 |
| `dump_vm_state(vm_id)` | 导出 VM 状态报告 | VM ID | `StateReport` | 管理查询 |

### 5.7 可选高级能力

- `create_snapshot(vm_id, target) -> Result`
- `restore_snapshot(source) -> VmId`
- `start_migration(vm_id, target) -> Result`
- `complete_migration(vm_id) -> Result`

| 函数 | 函数语义 | 直接输入 | 直接输出 | 为什么属于 control-plane |
|------|----------|----------|----------|--------------------------|
| `create_snapshot(vm_id, target)` | 创建快照 | VM ID、目标 | `Result` | 高层管理能力 |
| `restore_snapshot(source)` | 从快照恢复 VM | source | `VmId` | 高层管理能力 |
| `start_migration(vm_id, target)` | 发起迁移 | VM ID、目标 | `Result` | 高层管理能力 |
| `complete_migration(vm_id)` | 完成迁移 | VM ID | `Result` | 高层管理能力 |

---

## 六、分层归类矩阵

| 接口函数语义 | `host-api` | `runtime contract` | `hv-provider-api` | `device-model / control-plane` |
|--------------|------------|--------------------|-------------------|-------------------------------|
| `pin_pages` | 是 | 否 | 否 | 否 |
| `create_timer` | 是 | 否 | 否 | 否 |
| `spawn_kernel_task` | 是 | 否 | 否 | 否 |
| `disable_local_irq` | 是 | 否 | 否 | 否 |
| `read_host_csr` | 是 | 否 | 否 | 否 |
| `register_vcpu` | 否 | 是 | 否 | 否 |
| `dispatch_vmexit` | 否 | 是 | 否 | 否 |
| `set_vcpu_state` | 否 | 是 | 否 | 否 |
| `prepare_world_switch` | 否 | 是 | 否 | 否 |
| `create_vm` | 否 | 否 | 是 | 否 |
| `register_guest_memory` | 否 | 否 | 是 | 否 |
| `run_vcpu` | 否 | 否 | 是 | 否 |
| `get_gpr` / `set_gpr` | 否 | 否 | 是 | 否 |
| `inject_interrupt` | 否 | 否 | 是 | 否 |
| `handle_mmio_read` | 否 | 否 | 否 | 是 |
| `create_virtio_blk` | 否 | 否 | 否 | 是 |
| `vm_start` | 否 | 否 | 否 | 是 |
| `handle_rpc_request` | 否 | 否 | 否 | 是 |

---

## 七、最容易混淆的接口

### 7.1 `register_guest_memory`

不要放进 `host-api`。

原因：

- `host-api` 只能负责页分配、pin/unpin、地址翻译
- 把 guest memory 注册给 KVM/EPT/NPT/G-stage 是 provider 语义

正确拆法：

- `pin_pages()` 在 `host-api`
- `register_guest_memory()` 在 `hv-provider-api`

### 7.2 `run_vcpu`

不要放进 `runtime contract`。

原因：

- runtime 负责“怎么组织循环、怎么调度”
- `run_vcpu()` 负责“怎么真正进入 guest”

正确拆法：

- `start_vcpu_loop()` 在 `runtime contract`
- `run_vcpu()` 在 `hv-provider-api`

### 7.3 `inject_interrupt`

不要放进 `IrqIf`。

原因：

- `IrqIf` 处理 host 中断原语
- `inject_interrupt()` 是 guest 中断语义

正确拆法：

- `send_ipi()` 在 `host-api`
- `inject_interrupt()` 在 `hv-provider-api`

### 7.4 `handle_mmio_read/write`

不要放进 `hv-provider-api`。

原因：

- provider 只负责把 MMIO trap 作为 `VmExit` 返回
- 真正解释这个 GPA 对应什么设备、返回什么数据，是设备模型职责

正确拆法：

- `VmExit::MmioRead/Write` 在 `hv-provider-api`
- `handle_mmio_read/write()` 在 `device-model / control-plane`

---

## 八、Asterinas 迁移中的落位建议

以你们当前 Asterinas 实践为例，可按下面理解：

### 8.1 `host-api`

- `hyp_pin_memory()`
- `hyp_unpin_memory()`
- `hyp_virt_to_phys()`
- `hyp_timer_set()`
- `hyp_timer_cancel()`
- `KernelGuardIf` 这一类 host runtime guard 原语

### 8.2 `runtime contract`

- vCPU 主循环
- world switch 前后胶水
- trap 入口到 Axvisor 分发逻辑
- VM/vCPU 状态机管理

### 8.3 `hv-provider-api`

- `hyp_vm_create()`
- `hyp_vm_destroy()`
- `hyp_vcpu_create()`
- `hyp_vcpu_destroy()`
- `hyp_map_guest_memory()`
- `hyp_vcpu_run()`
- `hyp_vcpu_get_reg()`
- `hyp_vcpu_set_reg()`
- `hyp_inject_interrupt()`
- `hyp_set_irq_line()`

### 8.4 `device-model / control-plane`

- MMIO 区域解释
- 虚拟设备总线
- shell / 配置 / 镜像启动组织
- 后续 virtio、console、block、net 等设备

---

## 九、建议

从实现顺序看，推荐按下面方式推进：

1. 先把现有五类 trait 明确标成 `host-api`
2. 补一个单独的 `hv-provider-api` 模块，把 `vcpu_run`、guest memory 注册、guest irq 注入等移进去
3. 抽出 `runtime contract`，承接现在散落在 axvisor 核心和适配层之间的运行时胶水
4. 最后再把设备模型和控制面显式化

这样做的收益是：

- Asterinas 原生后端会更清楚
- 将来接 `/dev/kvm` 时不会把边界打乱
- `axvm` 不会继续膨胀成所有逻辑的汇合点

---

## 十、结论

四层接口函数的一一展开后，可以看到：

- `host-api` 负责基础能力
- `runtime contract` 负责 Axvisor 内部运行时编排
- `hv-provider-api` 负责硬件虚拟化执行面
- `device-model / control-plane` 负责设备与管理面

这四层合起来，才足以完整描述 Axvisor 从“底座能力”到“guest 跑起来并可管理”的全链路接口。
