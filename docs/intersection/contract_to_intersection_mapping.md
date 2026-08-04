# 从交集到契约:31 项强制交集 → 7 组底座契约函数的显式映射

> 本文档补齐论文从**归纳**(观察 KVM/Firecracker/bhyve 三个真实系统,得出 31 项强制交集)
> 到**演绎**(把 31 项收敛成一份 OS 中立的底座接口契约,即 7 个服务组)之间的关键论证环节。
>
> 这一映射在源文档中此前是**隐含**的:
> - 交集侧:[hypervisor_os_interface_intersection.md](hypervisor_os_interface_intersection.md)(31 项强制交集 + 2 可选 + 4 分歧)
> - 契约侧:`paper/sections/design.tex` 表 I(7 服务组的代表操作)
>
> 本文档把两者一一对齐,并说明收敛过程中的三类判断:**收敛(合并成契约函数)**、
> **降级为可选能力(缺失可优雅降级)**、**排除出契约主体(设计分歧,不预设边界)**。

---

## 1. 映射的三条规则

论文的契约不是交集的字面复制,而是一次有原则的收敛。规则如下:

- **R1 收敛为契约函数**:若某交集项是"三种 hypervisor 都硬性依赖、且可用一个稳定的、
  不引用具体 OS 的函数签名表达"的能力,则收敛进契约的某个服务组函数。
- **R2 降级为可选能力**:若某能力只在特定场景(passthrough、热迁移)需要,或三种系统里
  有系统可缺省,则进契约但标记 `optional`,缺失时核心**优雅降级**而非失败。
- **R3 排除出契约主体(设计分歧)**:若三种系统在此处做了**不同的内核/用户态边界选择**,
  契约**不预设该边界**,只要求底座提供底层机制,不把边界固化进契约。这正是论文
  "契约应显式暴露分歧而非静默归一"(G2 原则)的落点。

---

## 2. 总映射表(31 强制交集 → 7 契约组)

| 交集维度 | 交集项(强制 H) | 收敛去向(契约函数 / 判断) | 规则 |
|---------|----------------|---------------------------|------|
| **1 内存** | Guest 内存分配与映射 | `alloc_phys` + `map_stage2` | R1 |
| | 页面锁定/防换出(pin/wired) | `alloc_phys` 的语义约束(帧驻留、不可换出) | R1 |
| | GPA→HPA 翻译(EPT/NPT) | `map_stage2` / `unmap_stage2` / `flush_tlb` | R1 |
| | (脏页追踪,S) | 不进契约主体(仅 live-migration 需要) | R2 |
| | (MMU 反向通知,D) | 排除:KVM 有 notifier,FC/bhyve 用静态内存规避 | R3 |
| **2 vCPU** | 硬件虚拟化启用(VMX/SVM) | `init` + `vcpu_run` 的前置(进 VMX root/EL2) | R1 |
| | vCPU 生命周期(创建/销毁) | `vcpu_create` / `vcpu_destroy` | R1 |
| | vCPU 执行(VM entry) | `vcpu_run`(进 guest 直到 trap) | R1 |
| | 寄存器读写 | `vcpu_get_regs` / `vcpu_set_regs` | R1 |
| | CPUID 过滤 | 核心内 KVM-ABI shim 处理(经 `vcpu_get/set_regs` 承载) | R1 |
| | MSR 模拟 | 同上(寄存器状态传输能力) | R1 |
| | (VM exit 分发,D) | 排除:纯内核/纯用户态/混合三模式并存,契约不固化边界 | R3 |
| **3 I/O** | PIO/MMIO 拦截 | `register_mmio_handler` + `io_port` | R1 |
| | MMIO 物理访问(passthrough) | `mmio_read` / `mmio_write` | R1 |
| | I/O 事件通知(eventfd/kqueue) | 归 guest 侧 VMM 事件循环,非底座契约(见 §4) | R3 |
| | virtio 设备 | guest 侧/VMM 层,非底座契约 | R3 |
| | 网络后端(TAP/TUN) | guest 侧/VMM 层,非底座契约 | R3 |
| | (设备模拟位置,D) | 排除:内核 vs 用户态边界各异 | R3 |
| **4 中断** | 中断控制器模拟(LAPIC/IOAPIC) | 核心内虚拟设备模型 + `irq_inject`(注入到 vCPU) | R1 |
| | 中断注入 | `irq_inject` | R1 |
| | 物理中断路由到 handler | `irq_register` + `irq_eoi` | R1 |
| | (中断通知路径,D) | 排除:IPI vs eventfd vs ioctl,只要求 `irq_inject` 到达 | R3 |
| **5 时钟** | TSC 虚拟化 | 核心处理(TSC offset/scaling),底座提供时间源 | R1 |
| | 高精度定时器源(hrtimer/callout) | `timer_arm` | R1 |
| | 定时器设备模拟(LAPIC timer) | 核心内虚拟设备 + `timer_arm` + `irq_inject` | R1 |
| | 单调时间获取 | `timer_arm` 的语义依据(底座单调时间源) | R1 |
| **6 调度同步** | 每 vCPU 一线程 | `vcpu_run` 语义(底座提供执行上下文与调度) | R1 |
| | CPU 亲和性 | **底座调度策略**,契约不规定(仅要求 `vcpu_run` 阻塞至 trap) | R3(局部) |
| | vCPU 休眠/唤醒(halt/kick) | `vcpu_run` 阻塞语义 + `irq_inject` 唤醒 | R1 |
| | 事件循环(epoll/kqueue) | guest 侧 VMM,非底座契约 | R3 |
| | 锁原语(spinlock/mutex) | `spinlock` + 内存屏障(要求可在中断上下文用) | R1 |
| | (抢占通知,S) | 降级:KVM 强依赖,FC/bhyve 用更简单方式 | R2 |
| **7 安全** | 权限检查 | 底座策略,经 `init`/`query_platform` 边界托管 | R2 |
| | 进程沙箱(seccomp/Capsicum) | VMM/部署层,非核心契约 | R3 |
| | 资源限制(cgroup/jail/rctl) | VMM/部署层,非核心契约 | R3 |
| | 设备访问控制 | VMM/部署层,非核心契约 | R3 |
| **(DMA)** | (IOMMU 映射,来自维度3扩展) | `iommu_map`/`iommu_unmap`/`iommu_attach_device` | R2(可选) |

---

## 3. 按契约服务组反向汇总(7 组各自吸收了哪些交集)

### 组 1 — 内存(`alloc_phys` / `map_stage2` / `unmap_stage2` / `flush_tlb`)
吸收交集:内存分配与映射、页面锁定、EPT/NPT 翻译。
- **语义压力最大**(论文原话):底座是否直接暴露物理帧号、是否允许细粒度 stage-2 控制、
  如何处理 cache 一致性与 DMA ownership,三者差异大。
- `alloc_phys` 同时承载"分配"与"锁定/防换出"两个交集项——因为对契约而言,
  "分配一块 guest 用的物理内存"隐含"它必须驻留、不可被换出"(否则 guest 执行不正确)。
- 这也正是 gvisor 落地时的实证难点:eager-pin vs 稀疏按需、GUP vs remapped 两条腿
  (见 [gvisor 内存墙](../gvisor/gvisor-kvm-ioctl-compat.md)),即 `map_stage2` 语义在真实
  底座上的兑现成本。

### 组 2 — CPU/vCPU(`vcpu_create` / `vcpu_run` / `vcpu_get/set_regs` / `vcpu_destroy`)
吸收交集:硬件虚拟化启用、vCPU 生命周期、VM entry、寄存器读写、CPUID/MSR。
- **最深的交集**(6 项)——所有 Type-2 hypervisor 的共同底层逻辑,不依赖具体 OS,
  而依赖硬件虚拟化扩展(VMX/SVM)的标准接口。
- CPUID/MSR 不是独立契约函数:它们通过"内核↔用户态批量传输 vCPU 寄存器状态"的能力
  (即 `vcpu_get/set_regs`)+ 核心内 KVM-ABI shim 的过滤逻辑共同实现。

### 组 3 — 中断/定时器(`irq_register` / `irq_inject` / `irq_eoi` / `timer_arm`)
吸收交集:中断注入、物理中断路由、LAPIC/IOAPIC 模拟、定时器源、定时器设备、TSC、时间获取。
- **语义分歧最大**(论文原话):中断控制器模型、handler 跑在中断上下文还是延迟上下文、
  中断亲和性配置方式,三者差异大。
- LAPIC/IOAPIC 的**模拟**留在核心(虚拟设备模型),契约只要求底座
  "把物理中断投递到核心注册的回调"(`irq_register`)和"兑现注入请求"(`irq_inject`)。
- **这一组正是本项目 Linux 落地时最费桥接、且 bug 最集中的区域**——timer drain 关中断
  死循环、ACK_INTR_ON_EXIT 吞中断等,都是 `irq_inject`/`timer_arm` 语义在 Linux
  中断上下文里的兑现难点。**契约结构本身预测了 OS 分歧点**(论文讨论 A 的核心论点)。

### 组 4 — 同步(`spinlock` + 内存屏障)
吸收交集:锁原语。
- 关键约束:**可在中断上下文使用** + 提供与目标 ISA 内存模型兼容的顺序保证。
  因为某些底座在核心路径关抢占或屏蔽中断。

### 组 5 — 设备/MMIO(`mmio_read/write` / `io_port` / `register_mmio_handler`)
吸收交集:PIO/MMIO 拦截、MMIO 物理访问。
- passthrough 走 `mmio_read/write`(直接设备访问);emulation 走 `register_mmio_handler`
  (底座 trap guest MMIO fault 并转发)。
- virtio/网络后端/事件循环**不进此组**——它们是 VMM/guest 侧关注点,不是底座契约。

### 组 6 — DMA/IOMMU(`iommu_map/unmap` / `iommu_attach_device`,可选)
吸收交集:IOMMU 映射(passthrough 场景)。
- **唯一标记 optional 的组**:底座无 IOMMU 或不暴露时,passthrough 受限,核心优雅降级。

### 组 7 — 生命周期/日志(`init` / `query_platform` / `log`)
吸收交集:硬件虚拟化启用的入口、CPU/内存拓扑查询、权限检查边界。
- 必要但低风险,主要作用是给适配层一个"把控制权交给核心"的明确位置。

---

## 4. 一个关键澄清:并非所有交集项都进底座契约

交集分析涵盖**整条 Type-2 hypervisor 栈**(含 VMM/用户态),而底座契约只覆盖
**可移植核心↔底座 OS** 这一条缝。因此三类交集项虽是"三系统共需",却**不进底座契约**:

1. **guest 侧/VMM 层的能力**:virtio、TAP/TUN、eventfd/epoll 事件循环——这些是
   VMM(消费者)的关注点,由 guest 侧 KVM ABI 一侧承载,不是底座(提供者)契约。
2. **部署/安全层的能力**:seccomp、Capsicum、cgroup、jail——正交于虚拟化核心,
   由部署环境提供,契约不纳入。
3. **设计分歧项(4 项)**:MMU notifier、VM-exit 分发、设备模拟位置、中断通知路径——
   契约**刻意不预设**内核/用户态边界(G2 原则)。

这解释了为什么交集统计是 31 项强制交集,而契约只有 7 组:**契约是交集在"核心↔底座"
这条缝上的投影,并按"能否用 OS 中立函数表达"做了收敛。**

---

## 5. 论证意义(为什么这张映射表对论文重要)

- **补上归纳→演绎的缺环**:论文此前直接给出 7 组契约,读者无法验证"契约是否真的源自
  三系统的共同需求"。本表让每个契约函数**可追溯**到具体交集项。
- **佐证"契约即诊断工具"论点**(讨论 A):内存(组1)语义压力最大、中断(组3)语义分歧
  最大——这两组恰好是本项目 Linux/gvisor 落地时 bug 最集中、桥接成本最高的区域。
  **契约结构提前识别了 OS 分歧点**,这是可证伪的预测,已被实现经验印证。
- **佐证"双解耦降复杂度"论点**(§II-D):§4 说明了为什么大量"三系统共需"的能力
  (virtio/事件循环/沙箱)不落在底座契约,而落在 guest 侧 KVM ABI 或部署层——正是这个
  职责划分让 guest×substrate 矩阵降到 O(substrates)+O(guests)。

---

## 附录:源文档对照

| 文档 | 路径 |
|------|------|
| 三系统交集分析(31 项) | [hypervisor_os_interface_intersection.md](hypervisor_os_interface_intersection.md) |
| 契约定义(7 组,表 I) | `paper/sections/design.tex` §II-C |
| KVM 分析 | [../kvm/kvm_linux_interface_analysis.md](../kvm/kvm_linux_interface_analysis.md) |
| Firecracker 分析 | [../firecracker/firecracker_linux_interface_analysis.md](../firecracker/firecracker_linux_interface_analysis.md) |
| bhyve 分析 | [../bhyve/bhyve_freebsd_interface_analysis.md](../bhyve/bhyve_freebsd_interface_analysis.md) |
