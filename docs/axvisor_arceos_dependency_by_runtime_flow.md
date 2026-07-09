# 从 Axvisor 完整运行流程看其对 ArceOS 的真实依赖

> 目的：不再从抽象 trait 名称出发，而是从 Axvisor 的完整运行流程倒推：
>
> 1. Axvisor 实际上依赖了 ArceOS 的哪些内容？
> 2. 这些依赖分别属于底座能力、运行时能力、硬件虚拟化执行面，还是设备/控制面辅助？
> 3. 为什么“只实现五类 trait”不足以完成迁移？

---

## 一、结论先行

从完整运行流程看，Axvisor 对 ArceOS 的依赖至少分成四类：

1. **宿主底座能力**
2. **运行时基础设施**
3. **硬件虚拟化执行能力**
4. **启动与设备辅助能力**

如果用更贴近当前讨论的说法：

- 五类 trait 主要覆盖了第 1 类的一部分
- 当前 Asterinas 迁移中暴露出来的 `KernelGuardIf`、`.percpu`、初始化顺序问题属于第 2 类
- `hcounteren`、trap vector、world switch、G-stage、虚拟中断这些属于第 3 类
- 控制台、SBI、镜像装载、最小 I/O 环境属于第 4 类

因此：

> Axvisor 对 ArceOS 的真实依赖，显著超过“axvisor_api 的五类 trait”本身。

这一点已经被当前迁移实践直接证明。见 [plan_phase2_axvisor_integration.md](/home/bullet1517/freehypervisor/docs/plan_phase2_axvisor_integration.md:15) 到 [plan_phase2_axvisor_integration.md](/home/bullet1517/freehypervisor/docs/plan_phase2_axvisor_integration.md:26)。

---

## 二、分析方法

本文按 Axvisor 的完整运行流程拆成 7 个阶段：

1. 宿主启动与虚拟化初始化
2. VM 创建与 guest 内存准备
3. vCPU 创建与运行时承载
4. guest 进入执行
5. VM exit 捕获与分发
6. 虚拟中断与定时器驱动
7. guest 运行时隐式约定

每个阶段都回答三个问题：

- Axvisor 在这一阶段具体做什么
- 它依赖 ArceOS 的哪些内容
- 这些依赖在四层模型里属于哪一层

---

## 三、阶段 1：宿主启动与虚拟化初始化

### 3.1 Axvisor 在做什么

在真正创建 VM 和进入 guest 之前，Axvisor 先要求宿主已经具备以下前提：

- 内核已经启动
- CPU 和平台初始化完成
- trap / timer / IRQ 已可用
- 基础内存管理可用
- 硬件虚拟化模式已具备最小可进入条件

这一步不是 Axvisor 自己单独完成的，而是它默认宿主 ArceOS 在启动路径中已经建立了这些环境。

### 3.2 Axvisor 依赖 ArceOS 的什么

这一阶段直接依赖：

- `axhal`
  - CPU/平台初始化
  - trap/中断入口
  - timer
  - CSR/寄存器原语
  - 页表/地址空间原语
- `axruntime`
  - 初始化顺序
  - 早期运行时状态
  - `.percpu` 布局与可访问性
- `axalloc`
  - 基本分配器已经可用
- SBI firmware
  - OpenSBI / RustSBI 提供底层硬件环境

现有迁移审计中已经把其中几项显式写出来：

- `.percpu section`
- SBI firmware

见 [plan_phase2_axvisor_integration.md](/home/bullet1517/freehypervisor/docs/plan_phase2_axvisor_integration.md:23) 到 [plan_phase2_axvisor_integration.md:26](/home/bullet1517/freehypervisor/docs/plan_phase2_axvisor_integration.md:26)。

### 3.3 四层模型归类

| 依赖内容 | 归类 |
|----------|------|
| `axhal` CPU/timer/IRQ 基础 | `host-api` |
| `axruntime` 初始化顺序 / `.percpu` | `runtime contract` 的下层宿主支撑 |
| SBI firmware | `host-api` 之外的底层平台前置条件 |

### 3.4 关键观察

这一阶段说明：

> Axvisor 并不只依赖“trait 方法存在”，它还依赖 ArceOS 的启动路径已经把一组运行前置条件建立好。

---

## 四、阶段 2：VM 创建与 guest 内存准备

### 4.1 Axvisor 在做什么

这一阶段 Axvisor 要完成：

- 为 VM 分配基本上下文
- 为 guest 分配内存
- 将 guest 镜像装载到这片内存
- 获取对应的宿主物理地址
- 为后续 guest 执行建立内存可见性

在 Asterinas 迁移草案中，这些动作被具体化为：

- `hyp_vm_create()`
- `hyp_pin_memory()`
- `hyp_virt_to_phys()`
- `hyp_map_guest_memory()`

见 [plan_axvisor_on_asterinas.md](/home/bullet1517/freehypervisor/docs/plan_axvisor_on_asterinas.md:63) 到 [plan_axvisor_on_asterinas.md:109)。

### 4.2 Axvisor 依赖 ArceOS 的什么

这里依赖：

- `axalloc`
  - 页分配
  - 连续内存分配
- `axhal`
  - HVA/HPA 转换或等价页表 walk 能力
  - 页表和地址空间原语
- `AxMmHal`
  - ArceOS 的内存管理 glue

迁移审计里已经把这几项单独列出来：

- `MemoryIf`
- `AxMmHal`

见 [plan_phase2_axvisor_integration.md](/home/bullet1517/freehypervisor/docs/plan_phase2_axvisor_integration.md:17) 到 [plan_phase2_axvisor_integration.md:22)。

### 4.3 四层模型归类

| 依赖内容 | 归类 |
|----------|------|
| 页分配、连续物理内存 | `host-api` |
| HVA/HPA 翻译 | `host-api` |
| G-stage / guest memory 注册 | `hv-provider-api` |
| guest 镜像装载 | `device-model / control-plane` |

### 4.4 关键观察

这一阶段最容易混层。

要明确区分：

- “分配/钉住宿主物理页”是 ArceOS 底座能力
- “把这段内存变成 guest 可见内存”已经进入硬件虚拟化执行面

因此，Axvisor 在这一阶段依赖 ArceOS 的内容，本身就已经跨越了 `host-api` 和 `hv-provider-api` 两层。

---

## 五、阶段 3：vCPU 创建与运行时承载

### 5.1 Axvisor 在做什么

这一阶段 Axvisor 要完成：

- 创建 vCPU 对象
- 为每个 vCPU 准备 host 侧执行上下文
- 维护 vCPU 生命周期和状态机
- 让 vCPU 能够被调度、暂停、唤醒、回收

### 5.2 Axvisor 依赖 ArceOS 的什么

这里最核心的依赖是：

- `axtask`
  - 每个 vCPU 对应一个可调度执行体
  - 支持唤醒、挂起、可能的绑核
- `axruntime`
  - 运行时执行环境
- `ax-kspin` / `KernelGuardIf`
  - 保护共享状态
  - 在锁临界区提供关中断语义

迁移审计里已明确指出：

- `VmmIf (7方法) | axtask + VM框架`
- `KernelGuardIf | axhal crate_interface`

见 [plan_phase2_axvisor_integration.md](/home/bullet1517/freehypervisor/docs/plan_phase2_axvisor_integration.md:20) 与 [plan_phase2_axvisor_integration.md](/home/bullet1517/freehypervisor/docs/plan_phase2_axvisor_integration.md:24)。

### 5.3 四层模型归类

| 依赖内容 | 归类 |
|----------|------|
| `axtask` 调度和执行体 | `host-api` 的 task support |
| vCPU loop 编排 | `runtime contract` |
| `KernelGuardIf` / `SpinNoIrq` | `runtime contract` 依赖的宿主 guard 原语 |
| `create_vcpu()` 真正的 guest CPU 对象 | `hv-provider-api` |

### 5.4 关键观察

这里可以直接回答一个常见误区：

> Axvisor 依赖的不是“有个 vCPU 对象”这么简单，而是“这个 vCPU 对象能被 ArceOS 运行时承载起来”。

所以：

- vCPU 本身属于虚拟化执行面
- 承载 vCPU 的 task / guard / 调度 / 状态机属于 runtime 与底座支撑

---

## 六、阶段 4：guest 进入执行

### 6.1 Axvisor 在做什么

这是最核心阶段。Axvisor 需要：

- 保存 host 上下文
- 恢复 guest GPR 和 VS 级上下文
- 配置虚拟化 CSR
- 设置 trap vector
- 进入 guest
- 等待 VM exit 返回

你们在迁移草案中对 `hyp_vcpu_run()` 的内部步骤已经做了非常完整的拆解，见 [plan_axvisor_on_asterinas.md](/home/bullet1517/freehypervisor/docs/plan_axvisor_on_asterinas.md:123) 到 [plan_axvisor_on_asterinas.md:153)。

### 6.2 Axvisor 依赖 ArceOS 的什么

这一阶段依赖 ArceOS 提供：

- `axhal`
  - CSR 读写原语
  - trap vector 设置
  - 架构级 world switch 支撑
- ArceOS 的 hypervisor mode 初始化逻辑
  - `hcounteren`
  - `hedeleg` / `hideleg`
  - `hgatp`
  - VS 级 CSR 上下文
- 汇编级 VM exit 入口
  - HS trap vector 对应的汇编 glue

这部分在迁移文档里表现为对 `ostd::arch::riscv::hypext` 的要求，但在 ArceOS 语境下，本质就是：

> ArceOS 原本已经提供了这一整套 hypervisor mode 支撑，而 Asterinas 需要补齐。

### 6.3 四层模型归类

| 依赖内容 | 归类 |
|----------|------|
| CSR/寄存器原语 | `host-api` 的 arch/platform 原语 |
| host trap vector 基础设施 | `host-api` |
| world switch 外围 glue | `runtime contract` |
| `vcpu_run()` / guest entry / VM exit | `hv-provider-api` |
| `hcounteren` 等宿主初始化副作用 | `hv-provider-api` 所依赖的宿主前置条件 |

### 6.4 关键观察

这是最能说明问题的一段：

> 即使五类 trait 都实现了，只要 ArceOS 原本在进入虚拟化前默认建立的 host 状态没有对齐，Axvisor 仍然跑不起来。

`hcounteren` 就是最直接证据。见 [plan_phase2_axvisor_integration.md](/home/bullet1517/freehypervisor/docs/plan_phase2_axvisor_integration.md:7) 到 [plan_phase2_axvisor_integration.md:9)。

---

## 七、阶段 5：VM exit 捕获与分发

### 7.1 Axvisor 在做什么

guest 退出后，Axvisor 要做：

- 捕获退出原因
- 保存 guest 状态
- 恢复 host 上下文
- 把退出事件交给 vmexit handler / MMIO / hypercall / shutdown 处理

### 7.2 Axvisor 依赖 ArceOS 的什么

这里依赖：

- trap 入口和 trap frame
- `scause` / `stval` / `htval` / `htinst` 获取
- guest 退出后的上下文保存
- 把退出事件包装成可分发的数据

迁移文档里 `ExitReason` 的设计，本质上就是把 ArceOS 原有 VM exit 信息表达显式化。见 [plan_axvisor_on_asterinas.md](/home/bullet1517/freehypervisor/docs/plan_axvisor_on_asterinas.md:216) 之后的 `ExitReason` 枚举。

### 7.3 四层模型归类

| 依赖内容 | 归类 |
|----------|------|
| trap frame / trap 原语 | `host-api` |
| 从退出点恢复运行时上下文 | `runtime contract` |
| 退出原因产生与编码 | `hv-provider-api` |
| 退出后的上层处理分发 | `runtime contract` / `device-model` |

### 7.4 关键观察

这里也能看出：

- “退出原因是谁生成的”属于 provider
- “退出后 Axvisor 怎么处理”属于 runtime

ArceOS 原来把这两件事天然串好了，而迁移时需要一项项拆出来补齐。

---

## 八、阶段 6：虚拟中断与定时器驱动

### 8.1 Axvisor 在做什么

这一阶段 Axvisor 要完成：

- 为 guest 设置定时器
- 在定时器到期时触发虚拟中断
- 在设备模型需要时向 guest 注入 IRQ
- 处理外部事件与 guest 执行之间的桥接

### 8.2 Axvisor 依赖 ArceOS 的什么

这里依赖：

- `axhal timer`
  - 宿主高精度 timer
- `axhal irq`
  - 本地中断控制
- hypervisor 寄存器支持
  - `hvip`
  - `hie`
  - `hip`
  - `hgeie` / `hgeip`

迁移草案中这部分体现在：

- `hyp_inject_interrupt()`
- `hyp_set_irq_line()`
- `hyp_timer_set()`

见 [plan_axvisor_on_asterinas.md](/home/bullet1517/freehypervisor/docs/plan_axvisor_on_asterinas.md:169) 到 [plan_axvisor_on_asterinas.md:214)。

### 8.3 四层模型归类

| 依赖内容 | 归类 |
|----------|------|
| host timer | `host-api` |
| host IRQ 控制 | `host-api` |
| 虚拟中断注入 | `hv-provider-api` |
| timer callback 到 vCPU request 的桥接 | `runtime contract` |

### 8.4 关键观察

这里最容易误判成“TimeIf + IrqIf 足够了”。

实际上不是。

因为：

- `TimeIf` 和 `IrqIf` 只提供 host 原语
- 让这些原语变成 guest timer / guest interrupt，需要 provider 和 runtime 再向上组织一层

---

## 九、阶段 7：guest 运行时的隐式约定

### 9.1 Axvisor 在做什么

这一阶段不是一段显式代码，而是整个 guest 运行过程中 Axvisor 默认依赖宿主已经满足的一组约定。

### 9.2 Axvisor 依赖 ArceOS 的什么

目前从迁移实践中已经确认至少有这些隐式约定：

- `hcounteren` 已设置
- `KernelGuardIf` 已实现
- `.percpu` 可用
- trap / world-switch 初始化顺序正确

见：

- [plan_phase2_axvisor_integration.md](/home/bullet1517/freehypervisor/docs/plan_phase2_axvisor_integration.md:7) 到 [plan_phase2_axvisor_integration.md:9)
- [plan_phase2_axvisor_integration.md](/home/bullet1517/freehypervisor/docs/plan_phase2_axvisor_integration.md:23) 到 [plan_phase2_axvisor_integration.md:24)
- [plan_phase2_axvisor_integration.md](/home/bullet1517/freehypervisor/docs/plan_phase2_axvisor_integration.md:101) 到 [plan_phase2_axvisor_integration.md:104)

### 9.3 四层模型归类

| 依赖内容 | 归类 |
|----------|------|
| `.percpu` | `runtime contract` 的宿主前提 |
| `KernelGuardIf` | `runtime contract` 的宿主前提 |
| `hcounteren` | `hv-provider-api` 的宿主前提 |
| 初始化顺序 | `runtime contract` 的宿主前提 |

### 9.4 关键观察

这是当前迁移实践给出的最重要结论之一：

> Axvisor 对 ArceOS 的依赖，除了显式 API 外，还包含大量“原宿主默认会替我做好的初始化和运行时约定”。

这也是为什么“trait 都补了，仍然跑不通”的根本原因。

---

## 十、把真实依赖重新汇总成清单

从完整运行流程看，Axvisor 真实依赖 ArceOS 的内容可以收敛成下面这张表。

| ArceOS 内容 | Axvisor 依赖点 | 所属层 |
|-------------|----------------|--------|
| `axalloc` | 页分配、连续内存 | `host-api` |
| `AxMmHal` | 内存管理 glue | `host-api` |
| `axhal` timer | host timer | `host-api` |
| `axhal` irq | host IRQ / IPI / trap 基础 | `host-api` |
| `axhal` cpu/platform | CPU 特性、CSR 原语、平台初始化 | `host-api` |
| `axtask` | vCPU 承载执行体、调度、唤醒 | `host-api` 支撑 `runtime contract` |
| `axruntime` | 初始化顺序、per-CPU 环境 | `runtime contract` 前提 |
| `.percpu` | 每 CPU 数据 | `runtime contract` 前提 |
| `KernelGuardIf` | 锁与关中断语义 | `runtime contract` 前提 |
| `hcounteren` 初始化 | guest 可见计数器访问 | `hv-provider-api` 前提 |
| trap / world-switch glue | host/guest 上下文切换 | `runtime contract` + `hv-provider-api` |
| hypervisor CSR / G-stage / VM exit | guest 执行面 | `hv-provider-api` |
| SBI firmware | 平台底层环境 | 前置平台依赖 |
| UART / console | guest 输出与调试 | `device-model / control-plane` 辅助 |

---

## 十一、为什么“五类 trait”不够

结合上面的流程分析，可以非常具体地说明：

### 11.1 五类 trait 能覆盖的部分

它们主要覆盖：

- 内存
- 时间
- IRQ
- CPU/平台原语
- 一部分任务/调度支撑

也就是 ArceOS 依赖中的**宿主底座能力**。

### 11.2 五类 trait 覆盖不了的部分

它们覆盖不了：

- 初始化顺序和默认宿主状态
- `.percpu`
- `KernelGuardIf`
- vCPU loop 编排
- trap 到 vmexit handler 的运行时 glue
- `hcounteren` 这类 hypervisor mode 前置状态
- world switch 和 HS trap vector 的完整语义
- G-stage / 虚拟中断 / VM exit 编码等硬件虚拟化执行面

也就是说：

> 五类 trait 只覆盖了 ArceOS 依赖中的“显式、低层、基础能力”部分，覆盖不了“运行时组织”和“硬件虚拟化执行面”。

---

## 十二、对当前迁移实践的解释

这次 Asterinas 迁移中，你们已经观察到：

- `axvisor_api` 的 20 个方法全部实现了
- 但 guest 仍然会因为 `hcounteren` 和 `KernelGuardIf` 缺失而失败

见 [plan_phase2_axvisor_integration.md](/home/bullet1517/freehypervisor/docs/plan_phase2_axvisor_integration.md:101) 到 [plan_phase2_axvisor_integration.md:104)。

这件事本身就证明了：

1. 现有 trait 集合不是 Axvisor 对宿主依赖的完整表达
2. Axvisor 真实依赖中包含运行时与 hypervisor mode 初始化约定
3. ArceOS 原本把这些约定内嵌在系统启动和架构 glue 中，因此在原宿主下“不显山露水”

---

## 十三、最终结论

从 Axvisor 的完整运行流程倒推，Axvisor 对 ArceOS 的依赖不是简单的“五类 trait + 一点补丁”。

更准确的结论是：

1. **Axvisor 依赖 ArceOS 的宿主底座能力**
   - 内存、时间、中断、CPU、平台原语

2. **Axvisor 依赖 ArceOS 的运行时基础设施**
   - `axtask`
   - `.percpu`
   - `KernelGuardIf`
   - 初始化顺序
   - trap / world-switch glue

3. **Axvisor 依赖 ArceOS 的硬件虚拟化执行能力**
   - `hcounteren`
   - hypervisor CSR
   - G-stage
   - VM exit 捕获
   - 虚拟中断注入

4. **Axvisor 还依赖一些启动与设备辅助能力**
   - SBI firmware
   - console / UART
   - 镜像装载与最小平台 I/O

因此，若要把 Axvisor 稳定迁移到 Asterinas，真正需要对齐的是：

- `host-api`
- `runtime contract`
- `hv-provider-api`
- 必要的 `device-model / control-plane` 辅助

而不是只把目光停留在现有五类 trait 上。
