# Axvisor `host-api` 与 `hv-provider-api` 对应矩阵

> 目的：回答两个具体问题。
>
> 1. 现有“五类 trait”分别覆盖什么语义？
> 2. 硬件虚拟化执行面的哪些语义不能归入这五类 trait，必须单列为 `hv-provider-api`？

---

## 一、结论先行

现有五类 trait 可以继续保留，但它们更适合作为 `host-api`，即：

- 描述宿主底座提供的基础能力
- 为 Axvisor runtime 和虚拟化执行面提供支撑

它们**不能完整表达**硬件虚拟化执行面本身。

因此推荐结构是：

```text
host-api
  ├─ MemoryIf
  ├─ TimeIf
  ├─ TaskIf / Vmm runtime support
  ├─ IrqIf
  └─ PlatformIf / ArchIf

hv-provider-api
  ├─ VmIf
  ├─ VcpuIf
  ├─ GuestMemoryIf
  ├─ GuestIrqIf
  ├─ GuestTimeIf
  └─ VmExit
```

---

## 二、现有五类 trait 的角色定位

为避免命名争议，下文用较宽泛的类别名：

| 类别 | 角色定位 | 是否属于 `host-api` |
|------|----------|---------------------|
| Memory 类 | 宿主内存、地址空间、页管理、pin/unpin | 是 |
| Time 类 | 宿主时间源、定时器、deadline | 是 |
| Task/Vmm runtime 类 | 任务、线程、调度、执行上下文、运行时基础设施 | 是 |
| Irq 类 | 宿主中断、IPI、本地关中断、trap 辅助 | 是 |
| Platform/Arch 类 | CPU 特性探测、CSR/MSR 原语、平台初始化、控制台/镜像辅助 | 是 |

注意：

- 这里的 `Task/Vmm runtime` 仍然只是 **runtime support**
- 它不等于 `vcpu_run()` 这类硬件虚拟化执行面能力

---

## 三、硬件虚拟化执行面的核心语义

下面列出建议单列为 `hv-provider-api` 的核心语义。

| 语义类别 | 典型操作 |
|----------|----------|
| VM 生命周期 | `create_vm` / `destroy_vm` |
| vCPU 生命周期 | `create_vcpu` / `destroy_vcpu` |
| Guest 内存注册 | `map_guest_memory` / `register_memslot` / `unmap_guest_memory` |
| vCPU 运行 | `vcpu_run` / VM entry / VM exit |
| Guest 状态访问 | `get_reg` / `set_reg` / CSR/MSR/控制寄存器访问 |
| VM Exit 表达 | MMIO / PIO / page fault / ecall / halt / shutdown / fail entry |
| 虚拟中断注入 | `inject_interrupt` / `set_irq_line` / MSI 路径 |
| Guest 时间虚拟化 | TSC offset/scaling / `htimedelta` / 虚拟 timer 状态 |
| capability 探测 | irqchip / dirty log / ioeventfd / nested virt / 架构扩展能力 |
| vCPU 同步控制 | kick / pause / resume / remote request / TLB shootdown request |

---

## 四、对应矩阵

### 4.1 总矩阵

| 硬件虚拟化执行面语义 | Memory 类 | Time 类 | Task/Vmm runtime 类 | Irq 类 | Platform/Arch 类 | 结论 |
|----------------------|----------|---------|---------------------|--------|-------------------|------|
| VM 生命周期 | △ 依赖页/对象分配 | × | △ 依赖执行上下文容器 | × | △ 依赖 feature probe | 应进 `hv-provider-api` |
| vCPU 生命周期 | × | × | △ 依赖线程/CPU 绑定 | × | △ 依赖架构上下文初始化 | 应进 `hv-provider-api` |
| Guest 内存注册 | △ 提供页和地址翻译 | × | × | × | △ 提供页表/CSR 原语 | 应进 `hv-provider-api` |
| vCPU 运行 | × | × | △ 提供运行线程和调度 | △ 依赖关中断/trap 入口 | △ 依赖 world switch 原语 | 应进 `hv-provider-api` |
| Guest 状态访问 | × | × | × | × | △ 提供 CSR/MSR 访问原语 | 应进 `hv-provider-api` |
| VM Exit 表达 | × | × | △ 依赖 runtime 分发 | △ 依赖 trap/中断来源 | △ 依赖架构异常编码 | 应进 `hv-provider-api` |
| 虚拟中断注入 | × | × | × | △ 依赖 host IRQ/IPI 原语 | △ 依赖架构中断格式 | 应进 `hv-provider-api` |
| Guest 时间虚拟化 | × | △ 依赖 host clock | × | △ 可能依赖 timer interrupt 路径 | △ 依赖 TSC/CSR 机制 | 应进 `hv-provider-api` |
| capability 探测 | × | × | × | × | △ 依赖 CPU/平台 probe | 应进 `hv-provider-api` |
| vCPU 同步控制 | × | × | △ 依赖调度和线程唤醒 | △ 依赖 IPI/kick | △ 依赖某些架构请求位 | 应进 `hv-provider-api` |

说明：

- `×`：不应由该类 trait 承担
- `△`：该类 trait 只提供支撑原语，不表达最终虚拟化语义

### 4.2 阅读方法

这张矩阵表达的是：

- 左侧这些“硬件虚拟化执行面语义”确实会依赖五类 trait 提供的基础能力
- 但它们本身不是五类 trait 的自然职责

所以正确关系是：

> 五类 trait 提供 building blocks，`hv-provider-api` 负责把这些 building blocks 组织成真正的虚拟化执行语义。

---

## 五、逐项解释

### 5.1 VM 生命周期

为什么不能放进五类 trait：

- `create_vm()` 不是简单内存分配
- 它还意味着创建虚拟化上下文、分配 VMID、准备 provider 内部状态

五类 trait 里能提供的只是：

- 内存分配
- 对象生命周期辅助
- feature 探测

因此：

- `MemoryIf` 只能支撑 `create_vm()`
- 真正的 `create_vm()` 必须属于 `VmIf`

### 5.2 vCPU 生命周期

为什么不能放进 Task 类 trait：

- host task/thread 只是“承载体”
- vCPU 还包含 guest 上下文、虚拟寄存器状态、虚拟化控制块

因此：

- `TaskIf` 只负责创建或管理运行实体
- `create_vcpu()` / `destroy_vcpu()` 应该属于 `VcpuIf`

### 5.3 Guest 内存注册

这一项最容易被误归入 Memory 类 trait。

应当拆开看：

- “页分配、pin/unpin、HVA/PA 翻译”属于 `MemoryIf`
- “把 guest 区域注册给 KVM/EPT/NPT/G-stage”属于 `GuestMemoryIf`

原因是：

- `map_guest_memory()` 不只是拿到物理页
- 它还要更新虚拟化 provider 可见的二阶段地址空间
- 往往还要触发 TLB flush 或 provider 内部同步

因此不能把它简化成普通 memory trait 方法。

### 5.4 vCPU 运行

`vcpu_run()` 是最典型的“不能塞进 runtime trait”的语义。

它依赖：

- runtime 线程
- trap 入口
- 关中断区
- CSR/MSR/world switch 原语

但它本身表达的是：

- 从 host 进入 guest
- 运行到 exit
- 返回 exit reason

这是标准 `hv-provider-api` 语义。

### 5.5 Guest 状态访问

这里也容易被误归入 Platform/Arch trait。

应区分：

- `read_csr()` / `write_csr()` 这类原语可以属于 `ArchIf`
- `get_guest_reg()` / `set_guest_reg()` 属于 `VcpuIf`

因为后者不是“读宿主当前硬件寄存器”，而是“读写一个虚拟 CPU 的 guest 状态模型”。

### 5.6 VM Exit 表达

五类 trait 都不适合直接承载 `VmExit`。

`VmExit` 本质是：

- `vcpu_run()` 的返回语义
- guest 执行结果和需要上层处理的事件表达

例如：

- `MmioRead { gpa, len }`
- `MmioWrite { gpa, len, data }`
- `GuestPageFault { gpa, cause }`
- `Ecall`
- `Halt`
- `Shutdown`

这些都应是 `hv-provider-api` 的核心数据模型。

### 5.7 虚拟中断注入

这里最容易和 `IrqIf` 混淆。

应区分：

- `IrqIf` 处理 host 侧中断能力
- `GuestIrqIf` 处理 guest 侧中断语义

例如：

- 本地关中断、开中断、IPI 属于 `IrqIf`
- 给 guest 注入 VSEIP/LAPIC interrupt/MSI 属于 `GuestIrqIf`

### 5.8 Guest 时间虚拟化

`TimeIf` 只能提供 host 时间能力，例如：

- 当前时间
- host timer callback
- deadline timer

但 guest 时间虚拟化还涉及：

- TSC offset/scaling
- `htimedelta`
- kvmclock/pvclock 或 guest 可见 timer state

这些不是普通 host time trait 的职责，应当独立为 `GuestTimeIf`。

### 5.9 capability 探测

CPU 特性读取本身可以在 Platform/Arch trait 内完成，但：

- “这个 provider 是否支持 irqchip”
- “是否支持 dirty log”
- “是否支持 ioeventfd”
- “是否支持 nested virt”

这些属于 provider contract，不应混成普通平台特性。

因此建议：

- host CPU feature probe 保留在 `PlatformIf`
- virtualization capability probe 进入 `VmIf` 或独立 capability 接口

### 5.10 vCPU 同步控制

这一项经常被低估。

例如：

- kick 正在 `KVM_RUN` 的 vCPU
- 要求某个 vCPU 重新加载某状态
- 请求远端 vCPU 刷新某 guest 映射

这里会依赖：

- host 调度
- host IPI
- host 唤醒原语

但这些语义仍然是“围绕虚拟 CPU 的控制协议”，应属于 `VcpuIf` 或相关 provider 接口。

---

## 六、推荐的新接口边界

### 6.1 `host-api` 保留职责

推荐五类 trait 继续只做这些事：

| 类别 | 建议保留职责 |
|------|--------------|
| Memory 类 | 页分配、pin/unpin、地址翻译、页表辅助 |
| Time 类 | host clock、timer、deadline |
| Task/Vmm runtime 类 | 线程、调度、sleep/wake、CPU affinity、每 CPU 数据 |
| Irq 类 | 本地 IRQ 控制、IPI、trap 辅助 |
| Platform/Arch 类 | feature probe、CSR/MSR 原语、平台初始化、日志/控制台/镜像辅助 |

### 6.2 `hv-provider-api` 新增职责

推荐新增至少以下逻辑接口：

| 接口 | 职责 |
|------|------|
| `VmIf` | VM 生命周期、capability、VM 级扩展 |
| `VcpuIf` | vCPU 生命周期、`run()`、寄存器访问、kick/pause/resume |
| `GuestMemoryIf` | guest 内存注册、映射、撤销、dirty log |
| `GuestIrqIf` | 虚拟中断注入、irq line、MSI 路径 |
| `GuestTimeIf` | guest 时间偏移、timer virtualization |
| `VmExit` | guest 退出原因和事件表达 |

---

## 七、实践映射建议

### 7.1 Asterinas 原生后端

在 Asterinas 场景下：

- 五类 trait 由 Asterinas adapter 实现
- `hv-provider-api` 由 Asterinas 原生 hypervisor backend 实现

例如：

| 现有函数/语义 | 建议归类 |
|--------------|----------|
| `hyp_pin_memory()` | `host-api` |
| `hyp_unpin_memory()` | `host-api` |
| `hyp_timer_set()` | `host-api` |
| `hyp_vcpu_run()` | `hv-provider-api` |
| `hyp_vcpu_get_reg()` | `hv-provider-api` |
| `hyp_vcpu_set_reg()` | `hv-provider-api` |
| `hyp_inject_interrupt()` | `hv-provider-api` |
| `hyp_map_guest_memory()` | 拆分后分别落入 `host-api` + `hv-provider-api` |

### 7.2 Linux `/dev/kvm` 后端

在 Linux/KVM 场景下：

- `host-api` 提供 pthread/epoll/mmap/timerfd 等基础设施
- `hv-provider-api` 封装 `/dev/kvm`

对应关系：

| 语义 | 归类 |
|------|------|
| `mmap` guest memory | `host-api` |
| `KVM_SET_USER_MEMORY_REGION` | `hv-provider-api` |
| `KVM_RUN` | `hv-provider-api` |
| `KVM_GET_REGS` / `KVM_SET_REGS` | `hv-provider-api` |
| `epoll` / `event loop` | `host-api` / runtime support |
| virtio/MMIO 设备模型 | control plane / device model，上层职责 |

---

## 八、最终结论

一句话总结这张矩阵：

> 五类 trait 可以覆盖“硬件虚拟化执行面所依赖的宿主基础能力”，但不能覆盖“硬件虚拟化执行面本身”。

因此：

- 五类 trait 应保留为 `host-api`
- 硬件虚拟化执行面应新增一套 `hv-provider-api`

最容易出错的三项是：

1. 把 `vcpu_run()` 误塞进 runtime trait
2. 把 guest memory 注册误塞进 memory trait
3. 把虚拟中断注入误塞进 host irq trait

这三项都不应该这样做。
