# 面向跨 OS 底座的可移植 Hypervisor Core：以 AxVisor 解耦与 Linux 适配为例

## 摘要

Hypervisor 已经成为云计算、机密计算、嵌入式整合和轻量级隔离中的关键基础设施。现有 Hypervisor 大致沿着两条路线发展：一类系统如 Xen、ACRN、NOVA 和 seL4 CAmkES VMM 选择自建或依赖专用底座，从而获得较强控制力，但需要维护完整的系统栈；另一类系统如 KVM 选择深度复用通用 OS，显著降低工程成本，但其虚拟化核心与 Linux 内核机制强耦合，难以被其他 OS 复用。

本文关注的问题是：能否将 Hypervisor 对宿主 OS 的依赖抽象为一组显式的 Host Capability Interface，使同一个 Hypervisor Core 可以运行在不同 OS 底座之上？进一步地，对于具备 Linux ABI 兼容能力的新型 OS，能否在其上提供 KVM-compatible userspace ABI，使部分 Linux VMM workflow 无需理解底层 Hypervisor 实现即可运行？

为回答这一问题，我们将 AxVisor 从原本绑定 ArceOS 的 Hypervisor 实现中解耦出来，提炼出一组由 30 个接口函数构成的 Host Capability Interface。这组接口覆盖任务执行、同步、时间、控制台、内存分配、地址转换、中断处理和运行时入口等能力，用于刻画 portable Hypervisor Core 所需的宿主 OS runtime 能力。我们进一步在 ArceOS、Asterinas 和 Linux 上实现该接口，验证同一个 AxVisor Core 可以被差异明显的宿主底座承载。其中，Linux 适配并不试图替代 KVM，而是作为成熟通用内核上的验证目标，证明 Host Capability 抽象能够映射到真实生产级 OS 机制。

本文的核心贡献包括：提出 Host Capability Model，定义 Hypervisor Core 与 Host Adapter 的边界；将 AxVisor 解耦为 OS-independent Hypervisor Core；在 Linux 上实现 AxVisor Host Adapter，验证该抽象在成熟通用 OS 上的可实现性；在 Asterinas 上探索 KVM-compatible control plane，将 Linux 兼容从普通用户态应用扩展到虚拟化应用 workflow。

## 1. 引言

Hypervisor 是现代计算基础设施中的关键系统软件。云计算依赖 Hypervisor 实现多租户资源复用与强隔离；机密计算和基于 VM 的可信执行环境依赖 Hypervisor 构建安全边界；嵌入式与车载系统依赖 Hypervisor 整合实时任务、通用 OS 与安全关键组件；容器和 serverless 场景也越来越多地通过轻量级虚拟机增强隔离能力。换言之，Hypervisor 已经从“运行 guest OS 的工具”演化为资源复用、安全隔离、生态兼容和系统整合的基础能力。

从系统结构上看，Hypervisor 位于硬件虚拟化机制、宿主 OS 运行时和用户态虚拟机管理软件之间。它不仅需要执行 VM entry 和处理 VM exit，还需要管理 vCPU 调度、guest memory、timer、interrupt、device emulation、控制接口以及与用户态 VMM 的协作。因此，Hypervisor 的核心挑战并不只是指令级虚拟化，而是如何组织一整套虚拟化运行时。

现有系统给出了两种典型答案。一类 Hypervisor 选择自建底座，直接成为硬件之上的最低层系统。例如 Xen 和 ACRN 通过 dom0、Service VM 或管理域承载设备驱动、管理工具和 I/O 模型。NOVA、seL4 CAmkES VMM 等系统则进一步强调微内核化、隔离性和可验证性。这类系统的优势是控制力强、边界清晰，但代价是必须维护调度、内存、中断、管理域、工具链和设备后端等完整系统栈。

另一类系统选择复用通用 OS。KVM 是其中最成功的代表。KVM 没有重新实现一个完整 Hypervisor OS，而是将 Linux 本身变成虚拟化运行时：VM 表现为 Linux 进程，vCPU 对应 Linux 调度实体，guest memory 与 Linux 用户态地址空间关联，VM/vCPU/device 通过 fd 和 ioctl 管理，QEMU、Firecracker、Cloud Hypervisor 和 crosvm 等用户态 VMM 通过 `/dev/kvm` 使用内核虚拟化能力。KVM 的工程优势之一在于充分复用了 Linux 的调度、内存管理、文件对象、用户态 ABI、eventfd、poll/epoll 和设备框架。

然而，KVM 的这种复用方式也带来了强绑定。KVM 并没有将“Hypervisor 需要哪些宿主 OS 能力”抽象成一组可由不同 OS 实现的接口，而是直接嵌入 Linux 的具体内核机制中。因此，KVM 证明了复用宿主 OS 可以显著降低 Hypervisor 工程复杂度，但没有回答同一个 Hypervisor Core 能否跨 OS 复用。

本文从 AxVisor 的解耦和适配实践出发，研究一种跨 OS 底座的 portable Hypervisor Core 架构。我们的目标不是在 Linux 上替代 KVM。如果用户只需要在 Linux 上运行虚拟机，KVM+QEMU 已经是成熟方案。AxVisor on Linux 的意义在于验证另一个问题：Hypervisor 是否可以从特定宿主 OS 中解耦为一个可复用 core，并通过一组 Host Capability Interface 被不同 OS 承载。

本文提出的核心观点是：Hypervisor 的可移植性不应仅被理解为“移植代码到另一个 OS”，而应被理解为“抽象 Hypervisor Core 与宿主 OS runtime 之间的能力契约”。在这一契约下，Hypervisor Core 负责 VM/vCPU、guest memory、VM exit 和虚拟化语义；宿主 OS 通过 Host Adapter 提供任务、同步、时间、内存、地址转换、中断和控制平面桥接等能力。

## 2. 背景与动机

### 2.1 Hypervisor 对宿主基础设施的依赖

一个完整 Hypervisor 通常依赖多类宿主能力。执行与调度能力用于承载 vCPU loop；内存能力用于分配宿主页、构造 guest memory backing 并完成地址转换；时间能力用于维护虚拟 timer 和调度超时；中断能力用于处理 host IRQ、转发事件并辅助 guest interrupt injection；同步能力用于维护 VM/vCPU 状态机；控制平面能力用于向用户态 VMM 或管理工具暴露 VM 生命周期和运行状态。

这些能力共同决定了 Hypervisor 能否从“能进入 guest”演进为“能承载完整虚拟化工作负载”。如果 Hypervisor 自建底座，它必须自己实现这些能力；如果 Hypervisor 复用宿主 OS，它必须将这些能力映射到宿主 OS 的已有机制。

KVM 的成功说明后一条路线具有强工程价值。但 KVM 的宿主依赖没有被抽象成独立模型。Linux 的 task、mm、fd、ioctl、eventfd、RCU、内存 pinning 和调度机制直接构成了 KVM 的运行环境。对于 ArceOS、Asterinas 或其他新型 OS 来说，直接复用 KVM 并不现实，因为这往往意味着同时引入大量 Linux 内核内部机制。

### 2.2 Linux ABI 兼容与虚拟化生态兼容之间的断层

近年来，许多新型 OS 通过 Linux ABI 兼容降低生态成本。例如 Asterinas 支持大量 Linux syscall，使 Linux 应用和管理工具可以运行在非 Linux 内核上；FreeBSD Linuxulator、illumos LX zones、Fuchsia Starnix、WSL 和 gVisor 也从不同路径支持 Linux userland 或 Linux-like interface。

这些系统主要解决普通 Linux 应用的兼容问题，例如 shell、编译器、数据库、Web 服务、中间件和容器 workload。虚拟化应用则更复杂。QEMU、Firecracker、Cloud Hypervisor、lkvm 和 crosvm 虽然运行在用户态，但它们依赖的不是 `open/read/write/mmap/ioctl` 这些 syscall 的表面形式，而是 `/dev/kvm` 背后定义的一整套虚拟化语义。

例如，VMM 需要通过 `KVM_CREATE_VM` 创建 VM fd，通过 `KVM_CREATE_VCPU` 创建 vCPU fd，通过 `KVM_SET_USER_MEMORY_REGION` 注册 guest memory，通过 `KVM_RUN` 进入 guest 执行，并通过 `mmap` 获取 vCPU run page 中的 exit reason、MMIO 数据和状态字段。eventfd/ioeventfd 也不仅是普通通知机制，而是用户态设备模型与内核虚拟化后端之间的事件协议。

因此，一个 OS 即使能运行大量 Linux 用户态程序，也不等于能运行依赖 KVM 的 Linux VMM。虚拟化生态兼容的关键不只是 syscall ABI，而是 KVM userspace ABI 所定义的状态对象、共享内存布局和事件交互语义。

### 2.3 为什么 Linux 适配 AxVisor 仍然有意义

一个自然质疑是：Linux 已经有 QEMU 和 KVM，为什么还需要 AxVisor？本文的回答是：在 Linux 上适配 AxVisor 不是为了替代 KVM，而是为了验证 Host Capability 抽象。

Linux 是成熟、复杂、生产级的通用 OS。若 AxVisor 只能在 ArceOS 或 Asterinas 这类研究或新型 OS 上运行，外界可以质疑接口抽象是否只对受控环境成立。将同一个 AxVisor Core 适配到 Linux，能够检验这组接口是否可以映射到真实 Linux 内核对象和机制，例如 kthread、wait queue、timer、frame allocation、地址转换、IRQ 分发、console 和运行时入口。

因此，Linux 在本文中的角色不是目标替代对象，而是强验证底座。KVM 证明 Linux 可以成为 Hypervisor runtime；AxVisor on Linux 则用于证明 Linux 可以作为 portable Hypervisor Core 的一个 host adapter backend，而不是 Hypervisor 设计的唯一定义者。

## 3. 问题定义

本文围绕两个问题展开。

**问题一：Hypervisor 的宿主依赖缺少可移植抽象。**

现有 Hypervisor 要么自建底座并维护完整系统栈，要么复用通用 OS 但绑定具体内核。KVM 证明复用 Linux 是降低复杂度的有效路径，但它没有将宿主依赖抽象为可被不同 OS 实现的能力接口。本文希望回答：能否将 Hypervisor 对宿主 OS 的依赖提炼为显式 Host Capability Interface，使同一个 Hypervisor Core 可以运行在不同 OS 底座上？

**问题二：Linux 应用兼容与虚拟化生态兼容之间存在断层。**

Linux ABI 兼容主要解决普通应用运行问题，而依赖 KVM 的 VMM 还需要 `/dev/kvm`、KVM ioctl、vCPU run page、memory slot、eventfd 等虚拟化语义。本文希望进一步回答：能否在非 Linux OS 上提供 KVM-compatible userspace ABI，将 KVM 虚拟化语义映射到 portable Hypervisor Core，从而支持部分 Linux VMM workflow？

需要强调的是，问题一是本文的主线，问题二是建立在 portable Hypervisor Core 之上的生态兼容扩展。本文并不试图完整重现 Linux KVM 的所有能力，也不宣称所有 Linux VMM 可以立即无修改运行。

## 4. 设计概述

### 4.1 三层架构

本文将系统拆分为三层：

```text
Linux VMMs
QEMU / lkvm / Firecracker / Cloud Hypervisor / crosvm
        |
        | northbound: KVM-compatible userspace ABI
        v
OS-independent AxVisor Core
        |
        | southbound: Host Capability Interface
        v
ArceOS / Asterinas / Linux / other kernels
```

下层 Host Capability Interface 描述 AxVisor Core 对宿主 OS runtime 的依赖。上层 KVM-compatible userspace ABI 面向 Linux VMM，提供类似 `/dev/kvm` 的控制接口。AxVisor Core 位于中间，负责 VM/vCPU 生命周期、guest memory、VM exit、寄存器状态和虚拟化语义。

### 4.2 Host Capability Interface

Host Capability Interface 的核心作用是划定 AxVisor Core 与宿主 OS 的边界。它不是传统硬件 HAL，因为它抽象的对象不是 CPU 寄存器或设备寄存器，而是宿主 OS runtime capability。

在当前 Linux 适配中，我们将这组能力落实为 30 个接口函数。它们大致分为以下类别：

- `TaskIf` 和 `KernelTaskRuntime`：创建和管理承载 vCPU 或 runtime 逻辑的 host task，支持 `spawn`、`join`、`current` 和 `yield`。
- `SyncIf`：提供 wait queue 的创建、销毁、等待、超时等待、唤醒一个或唤醒全部等同步能力。
- `HostIf`：提供 CPU 数量查询、per-CPU 初始化和宿主退出入口。
- `ConsoleIf`：提供控制台输入输出能力。
- `TimeIf`：提供单调时间读取和 one-shot timer 设置。
- `IrqIf`：提供 IRQ handler 注册和 IRQ 分发入口。
- `MemoryIf`：提供 frame allocation、contiguous frame allocation、释放和物理/虚拟地址转换。
- runtime bridge：负责安装 runtime hook，并将宿主入口桥接到 AxVisor Core 的启动路径。

这些接口的贡献不在于数量，而在于将 AxVisor 原本散落在 ArceOS 内部的隐式依赖显式化。过去的问题是“AxVisor 调用了哪些 ArceOS API”；现在的问题变成“一个 OS 需要提供哪些能力，才能承载 AxVisor Core”。

### 4.3 Host Adapter 与 Core 边界

在该设计中，AxVisor Core 负责可复用的虚拟化语义，包括 VM/vCPU 状态、guest memory 管理、exit handling、虚拟设备逻辑和架构相关虚拟化路径。Host Adapter 负责将 Host Capability Interface 映射到具体 OS 的机制。

以 Linux adapter 为例，当前已有多数接口具备 Linux 语义封装：task/sync 接口映射到 Linux `kthread`、`Task`、`CondVar`、`Mutex` 和 registry；host/time/console 接口映射到宿主 CPU 查询、per-CPU 初始化、单调时间、RISC-V hrtimer backend 和控制台缓冲；memory 接口映射到宿主导出的 frame allocation、contiguous allocation 和地址转换入口。

仍需补强的部分主要包括 runtime 安装与启动胶水、IRQ 真实源号获取与映射，以及 timer/IRQ 与真实 AxVisor Core 路径结合后的语义验证。这些限制说明当前 Linux 适配已经超过函数壳阶段，但尚不能仅凭接口存在就证明完整 Linux guest 启动闭环已经完成。

### 4.4 KVM-compatible Control Plane

在上层 control plane 中，我们将 KVM ABI 拆解为两类语义。

| 内容 | 归属 |
| --- | --- |
| KVM ioctl number、VM/vCPU/session 语义、`KVM_RUN`、寄存器访问、memory slot 管理 | AxVisor Core 或 KVM frontend |
| `/dev/kvm` 设备节点、fd table、`mmap` object、`copy_from/to_user`、`eventfd`、用户页 acquire/release | Host Adapter |

这种分解使 KVM compatibility 不再等同于移植 Linux KVM，而是变成在非 Linux OS 上实现一个 KVM-compatible frontend，并将其映射到 portable AxVisor Core。

在 Asterinas control mode 中，Asterinas 正常启动后通过 host adapter 将 AxVisor 暴露为 `/dev/kvm`。用户态 `lkvm` 可以通过 KVM-style ABI 创建 VM、创建 vCPU、注册 guest memory，并通过 `KVM_RUN` 启动 guest。该路径主要验证 northbound compatibility，即非 Linux OS 是否能够支持 KVM-style 虚拟化应用 workflow。

## 5. 实现

### 5.1 从 ArceOS 内嵌 AxVisor 到 Portable AxVisor Core

AxVisor 原本更接近 ArceOS 生态内的 Hypervisor 实现，其启动流程、任务模型、内存分配、地址转换、定时器、中断和控制台能力均隐式依赖 ArceOS。本文的第一步是识别这些依赖，并将其从 AxVisor Core 中剥离出来。

解耦后的 AxVisor Core 不再直接调用具体 OS 的内部 API，而是只通过 Host Capability Interface 获取宿主能力。ArceOS、Asterinas 和 Linux 分别实现自己的 Host Adapter。这样，Core 与 Host Adapter 之间形成稳定边界：Core 维护虚拟化语义，Adapter 维护 OS 绑定。

### 5.2 Linux Host Adapter

Linux Host Adapter 的目标不是提供一个 KVM 替代品，而是验证 Host Capability Interface 在成熟通用内核上的可实现性。当前 Linux 侧 30 个接口可以分为三类。

第一类是已经具备 Linux 语义封装的接口，包括 task/sync、host/console/time 和 memory 相关接口。这些接口已经落到 Linux 侧真实对象或后端上，而不是简单 stub。

第二类是已经有第一版实现但仍需补强的接口，包括 runtime hook 安装链、runtime 入口桥接链、IRQ 注册和 IRQ 分发。当前 `run()` 路径已经可以通过 `core_link::boot`、`boot_vendor_bridge`、`vendor::axvisor_core::boot` 和 `axvisor_linux_bridge_boot_run()` 进入真实 `axvisor_core::boot::run()`，但这只能证明入口桥接成立，不能单独证明 guest 启动协议完全匹配。

第三类是必须等真实 core 和真实 guest workload 接入后才能验证的语义，主要包括 timer 真实消费和 external IRQ 真实注入。当前 timer backend 已能触发，并能进入 `axvisor_core::vmm::timer::check_events()` 路径；IRQ adapter 也具备 external IRQ event 识别、缓存和转发路径。但 Linux host adapter 目前仍需解决真实设备 IRQ 源号获取与 guest IRQ 映射问题。

### 5.3 Asterinas Control Mode

Asterinas 适配承担两类验证：一方面，它作为新型 Linux ABI-compatible OS，实现 Host Capability Interface 并承载 AxVisor Core；另一方面，它在 control mode 中提供 KVM-compatible userspace ABI，使 Linux VMM workflow 可以通过 `/dev/kvm` 风格接口访问底层 AxVisor 能力。

这一部分的关键价值在于连接 Linux application compatibility 与 Linux virtualization compatibility。普通 Linux ABI 兼容只能保证应用 syscall 表面可以执行，而 KVM-compatible control plane 进一步提供 VM/vCPU/memory/run 等虚拟化对象语义。

### 5.4 ArceOS Static Mode

ArceOS static mode 用于验证从原始运行环境中解耦后的 AxVisor Core 仍能在其原生底座上工作。在该模式中，宿主 OS 启动后自动进入 AxVisor，VM 配置和 guest 镜像在启动前准备好，不依赖复杂用户态控制平面。

该模式主要验证 southbound portability：AxVisor Core 是否能够通过 Host Capability Interface 运行，而不是继续依赖 ArceOS 内部调用。

## 6. 创新点与贡献

### 6.1 Host Capability Model

本文提出 Host Capability Model，用一组明确接口刻画 portable Hypervisor Core 所需的宿主 OS runtime 能力。与传统硬件 HAL 不同，该模型抽象的不是硬件，而是宿主 OS 提供的执行、同步、时间、中断、内存和控制平面桥接能力。

这组接口将 Hypervisor 对宿主 OS 的隐式依赖转化为显式 contract，使不同 OS 可以通过实现同一接口来承载同一个 Hypervisor Core。

### 6.2 30 个接口函数作为最小可验证边界

本文从 AxVisor 解耦实践中提炼出 30 个接口函数，覆盖 task、sync、host、console、time、IRQ、memory 和 runtime bridge 等类别。这些接口的贡献不是包装若干 OS API，而是定义了 AxVisor Core 与 Host Adapter 之间的最小可验证边界。

通过这组接口，VM/vCPU 管理、guest memory 语义、VM exit 处理和虚拟化设备逻辑保留在 AxVisor Core 中；任务创建、wait queue、timer、IRQ 分发、frame allocation、地址转换和运行时入口等宿主机制留在 Host Adapter 中。

### 6.3 Linux Host Adapter 作为生产级底座验证

本文在 Linux 上实现 AxVisor Host Adapter，证明 Linux 可以作为 portable AxVisor Core 的一种宿主 runtime，而不是只能通过 KVM 这一 Linux-native 方式提供虚拟化能力。

这一贡献需要谨慎表述：我们不声称 AxVisor 在 Linux 上替代 KVM。相反，Linux 适配用于验证 Host Capability Interface 能够映射到成熟通用内核机制。如果接口只能适配 ArceOS/Asterinas，那么它可能只是针对研究 OS 的胶水层；如果同一接口也能适配 Linux，则更能说明该抽象具有跨 OS 意义。

### 6.4 KVM-compatible Frontend Decomposition

本文将 KVM userspace ABI 分解为两部分：由 AxVisor Core 或 frontend 维护的虚拟化语义，以及由 Host Adapter 提供的 OS 对象绑定。前者包括 VM/vCPU/session、`KVM_RUN`、寄存器访问和 memory slot 管理；后者包括 `/dev/kvm` 设备节点、fd table、mmap object、用户页 acquire/release 和 eventfd。

该分解使非 Linux OS 可以在不移植 Linux KVM 内部实现的情况下，暴露 KVM-style 虚拟化服务。

### 6.5 跨底座验证

本文通过 ArceOS、Asterinas 和 Linux 三种差异明显的底座验证同一个 AxVisor Core。ArceOS 验证从原始运行环境中解耦；Asterinas 验证新型 Linux ABI-compatible OS 上的 host adapter 与 KVM-compatible control plane；Linux 验证 Host Capability Interface 在成熟通用 OS 上的可实现性。

这使本文工作不只是一次单点移植，而是一种可复用 Hypervisor 架构分解方法。

## 7. 评估计划

当前原型已经形成 Host Capability Interface、Linux adapter、Asterinas control mode 和 ArceOS static mode 的基本结构。后续评估应围绕以下问题展开。

### 7.1 接口充分性

需要证明这 30 个接口足以支撑 AxVisor Core 的关键路径，包括启动 core、创建或恢复 VM 配置、运行 vCPU、处理 timer event、处理 external IRQ、管理 guest memory 和输出 guest console。

### 7.2 代码复用率与适配成本

需要统计 AxVisor Core 在 ArceOS、Asterinas 和 Linux 之间的共享代码比例，以及每个 Host Adapter 的代码规模。该数据用于回答接口是否真的降低了新 OS 承载 Hypervisor 的成本。

### 7.3 语义完整性

需要区分“接口存在”和“语义成立”。Linux 侧尤其需要验证 RISC-V Linux guest 启动协议、external IRQ 源号获取与映射、guest block 设备透传和串口启动闭环。

### 7.4 KVM-compatible ABI 覆盖

对于 Asterinas control mode，需要列出当前支持的 KVM ioctl 子集，例如 VM 创建、vCPU 创建、memory region 注册、`KVM_RUN`、寄存器访问、run page mmap 和 eventfd/ioeventfd 相关能力。应明确哪些 VMM workflow 已经验证，哪些仍是非目标。

### 7.5 性能开销

需要评估接口抽象和 adapter 层带来的开销，包括 vCPU entry/exit 路径、timer event latency、IRQ injection latency、guest memory registration cost 和启动时间。该评估不必声称超越 KVM，但需要说明抽象层成本是否可接受。

## 8. 非目标与边界

本文不试图替代 Linux KVM。对于 Linux 上的生产虚拟化工作负载，KVM+QEMU 仍然是成熟方案。AxVisor on Linux 的目标是验证 Host Capability Interface 的通用性。

本文也不追求完整复现 Linux KVM 的所有 ioctl 和语义，不宣称所有 Linux VMM 均可无修改运行。当前 KVM-compatible control plane 的目标是支持关键 VMM workflow，并验证非 Linux OS 暴露 KVM-style 虚拟化服务的可行性。

本文暂不以完整设备模型兼容、VFIO、live migration、nested virtualization 和完整性能竞争为主要目标。这些能力可以作为后续扩展，但不构成本文原型验证的必要条件。

## 9. 相关工作

### 9.1 专用底座与 Type-I Hypervisor

Xen 是经典 Type-I hypervisor，提出通过 paravirtualization 和 dom0 管理域构建虚拟化系统。Xen 证明专用 hypervisor 可以提供较强隔离和良好性能，但也需要维护 dom0、toolstack、driver backend 和 I/O 模型等完整系统栈。ACRN 面向嵌入式和 IoT 场景，通过 Service VM 承载设备和管理功能，同样属于专用 hypervisor stack 路线。这类系统的共同特点是控制力强，但宿主底座和 hypervisor 系统栈高度一体化。

NOVA 和 seL4 CAmkES VMM 代表 microhypervisor 或微内核路线。NOVA 将 hypervisor TCB 压缩到较小的 microhypervisor 中，并将策略和设备模型移到用户态；seL4 CAmkES VMM 则建立在 seL4 的形式化验证内核和组件模型之上。这类工作关注安全、隔离和可验证性，但仍依赖特定微内核对象模型和组件运行时。

本文与上述系统的区别在于：我们不为 AxVisor 选择一个固定的专用底座，也不要求宿主 OS 采用特定微内核对象模型。本文关注的是从 AxVisor 中提炼出宿主 OS runtime capability，使同一个 Hypervisor Core 可以被 ArceOS、Asterinas 和 Linux 等不同底座承载。

### 9.2 复用通用 OS 的 Hypervisor

KVM 是复用通用 OS 的代表。KVM 将 Linux 转化为 hypervisor runtime，使 VM 表现为 Linux 进程，vCPU 由 Linux 调度，guest memory 关联到用户态地址空间，并通过 `/dev/kvm`、fd、`mmap` 和 ioctl 向用户态 VMM 暴露控制接口。Linux KVM 文档明确将 API 组织在 `/dev/kvm`、VM fd 和 vCPU fd 周围，例如 `KVM_CREATE_VM`、`KVM_CREATE_VCPU` 和 `KVM_RUN`。

KVM/ARM 进一步说明 KVM 模型可以扩展到不同硬件架构，但它仍是 Linux 内核内部虚拟化框架。bhyve 则在 FreeBSD 上采用类似 hosted hypervisor 思路，复用 FreeBSD 内核设施提供虚拟化能力。这些系统证明复用成熟通用 OS 能显著降低 hypervisor 工程成本，但它们的核心实现仍绑定具体宿主内核机制。

本文继承 KVM 和 bhyve “复用宿主 OS” 的思想，但将该思想从 Linux 或 FreeBSD 的具体内核机制中抽象出来。AxVisor on Linux 不是为了替代 KVM，而是用于验证 Host Capability Interface 是否能够映射到成熟通用 OS runtime。

### 9.3 VMM 生态与 KVM Userspace ABI

QEMU、Firecracker、Cloud Hypervisor、crosvm 和 kvmtool 构成了 Linux 虚拟化生态的重要组成部分。QEMU 将 KVM、Xen、HVF、WHPX、NVMM 和 TCG 等视为不同 accelerator，说明用户态 VMM 可以抽象不同虚拟化后端。Firecracker 面向 serverless 场景，通过轻量级 VMM 和 KVM 提供低开销隔离能力，并已部署于 AWS Lambda 和 Fargate。Cloud Hypervisor、crosvm 和 rust-vmm 生态则强调用 Rust 和模块化组件构建 VMM。

这些工作主要模块化的是用户态 VMM 或设备模型，而不是 hypervisor core 与宿主 OS runtime 之间的边界。它们通常假设底层存在 KVM-like provider。本文关注的是更低一层的问题：当一个非 Linux OS 希望支持这类 VMM workflow 时，如何通过 portable AxVisor Core 和 KVM-compatible frontend 提供必要的 VM/vCPU/memory/run 语义。

### 9.4 Linux ABI 兼容系统

Asterinas、Fuchsia Starnix、FreeBSD Linuxulator、illumos LX zones、WSL 和 gVisor 等系统展示了 Linux compatibility 对新型 OS 生态的重要性。Asterinas 以 Linux ABI 兼容为目标，通过 Rust-based framekernel 架构支持大量 Linux syscall。Starnix 在 Fuchsia 上实现 Linux compatibility layer，将 Linux 程序请求翻译到 Fuchsia 子系统。FreeBSD Linuxulator 支持运行未修改 Linux binaries。gVisor 则作为 application kernel，在用户态实现 Linux-like syscall interface，用于容器 sandbox。

这些系统主要解决普通 Linux 应用兼容问题，例如 shell、编译器、数据库、中间件和容器 workload。它们通常不提供 `/dev/kvm` 背后的虚拟化对象语义，例如 VM fd、vCPU fd、memory slot、vCPU run page 和 eventfd/ioeventfd。本文关注 Linux application compatibility 与 Linux virtualization compatibility 之间的断层，并在 Asterinas 上探索 KVM-compatible control plane。

### 9.5 静态分区与嵌入式虚拟化

Jailhouse 和 Bao 代表静态分区 hypervisor 路线。Jailhouse 使用 Linux 完成复杂初始化，然后将硬件资源静态划分给 isolated domains，尽量减少 VM exits。Bao 面向嵌入式和 mixed-criticality 系统，强调静态资源分区、确定性和较小的运行时开销。相关工作也比较了 Jailhouse、Xen Dom0-less、Bao 和 seL4 CAmkES VMM 在 Arm mixed-criticality 系统中的表现。

这些工作说明嵌入式、实时和 mixed-criticality 场景中确实需要更轻量、更可控的虚拟化方案。但它们通常围绕固定 hypervisor 或固定底座设计，不解决同一个 Hypervisor Core 如何跨 OS runtime 复用的问题。本文的 static mode 与这类系统有相似应用背景，但研究重点是 AxVisor Core 与宿主 OS 的能力边界。

### 9.6 利用虚拟化硬件重划 OS 边界

Dune 使用虚拟化硬件让用户态应用安全访问部分 privileged CPU features，例如页表、异常和保护机制，同时保留传统 OS process interface。Dune 与本文的共同点在于都重新划分了硬件虚拟化能力与 OS runtime 之间的边界。

不同的是，Dune 面向用户态应用暴露 privileged CPU features；本文面向 Hypervisor Core 抽象宿主 OS runtime capabilities。换言之，Dune 改变的是应用与 OS/硬件之间的边界，本文改变的是 Hypervisor Core 与宿主 OS 之间的边界。

### 9.7 小结

综上，现有工作分别覆盖了专用 hypervisor 底座、复用通用 OS 的 hypervisor、用户态 VMM 生态、Linux ABI 兼容和静态分区虚拟化。但它们尚未同时解决两个问题：一是将 Hypervisor Core 对宿主 OS runtime 的依赖抽象为可被不同 OS 实现的 Host Capability Interface；二是在非 Linux OS 上通过 portable Hypervisor Core 提供 KVM-style 虚拟化应用兼容路径。

本文试图填补这一空白：通过 30 个接口函数定义 AxVisor Core 与 Host Adapter 的边界，在 ArceOS、Asterinas 和 Linux 上验证同一 Hypervisor Core，并进一步在 Asterinas 上探索 KVM-compatible userspace ABI。

## 参考资料

- Paul Barham, Boris Dragovic, Keir Fraser, Steven Hand, Tim Harris, Alex Ho, Rolf Neugebauer, Ian Pratt, and Andrew Warfield. "Xen and the Art of Virtualization." SOSP 2003.
- Jun Nakajima and Asit Mallick. "Hybrid-Virtualization: Enhanced Virtualization for Linux." Linux Symposium 2007. KVM 相关背景。
- Christoffer Dall and Jason Nieh. "KVM/ARM: The Design and Implementation of the Linux ARM Hypervisor." ASPLOS 2014.
- Udo Steinberg and Bernhard Kauer. "NOVA: A Microhypervisor-Based Secure Virtualization Architecture." EuroSys 2010.
- Adam Belay, Andrea Bittau, Ali Mashtizadeh, David Terei, David Mazières, and Christos Kozyrakis. "Dune: Safe User-level Access to Privileged CPU Features." OSDI 2012.
- Alexandru Agache et al. "Firecracker: Lightweight Virtualization for Serverless Applications." NSDI 2020.
- Linux Kernel Documentation. "KVM API." https://www.kernel.org/doc/html/latest/virt/kvm/api.html
- QEMU Documentation. "Introduction." https://www.qemu.org/docs/master/system/introduction.html
- Fuchsia Documentation. "Starnix." https://fuchsia.dev/fuchsia-src/concepts/starnix
- FreeBSD Handbook. "Linux Binary Compatibility." https://docs.freebsd.org/en/books/handbook/linuxemu/
- Asterinas. "A Linux ABI-Compatible, Rust-Based Framekernel OS." arXiv 2025.
- Ralf Ramsauer et al. "Look Mum, no VM Exits! (Almost)." Jailhouse related work, 2017.
- Bao Hypervisor and static partitioning hypervisor papers on embedded and mixed-criticality virtualization.

## 10. 结论

KVM 的工程优势之一在于将 Linux 变成 Hypervisor 的运行时，但 KVM 本身并不是跨 OS 可复用的 Hypervisor Core。本文以 AxVisor 解耦和 Linux 适配为例，提出一种面向跨 OS 底座的 portable Hypervisor Core 架构。

通过 30 个接口函数构成的 Host Capability Interface，本文将 Hypervisor 对宿主 OS 的复杂依赖显式化，划定 AxVisor Core 与 Host Adapter 的边界。ArceOS、Asterinas 和 Linux 三种底座上的适配说明，该接口不仅适用于原始研究环境，也可以映射到成熟通用内核机制。进一步地，Asterinas 上的 KVM-compatible control plane 展示了将 Linux 兼容从普通用户态应用扩展到虚拟化应用 workflow 的可能性。

本文工作的核心价值不在于在 Linux 上替代 KVM，而在于证明 Hypervisor runtime 可以被抽象为一组可移植 Host Capability，使同一个 AxVisor Core 能够被不同 OS 承载，并为非 Linux OS 提供 KVM-style 虚拟化生态兼容路径。
