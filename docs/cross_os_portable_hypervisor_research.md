# 背景调研与问题分析：面向跨 OS 底座的可移植 Hypervisor

## 1. 背景

Hypervisor 是现代计算基础设施中的关键系统软件。云计算依赖它实现多租户资源复用和强隔离；机密计算和基于 VM 的 TEE 依赖它构建可信执行边界；嵌入式和车载系统依赖它整合实时任务、通用 OS 与安全关键组件；容器与 serverless 场景也越来越多地使用轻量级虚拟机增强隔离。换言之，Hypervisor 已经从“运行 guest OS 的工具”演化为资源复用、安全隔离、生态兼容和系统整合的基础能力。

从系统结构上看，Hypervisor 位于硬件虚拟化机制、宿主 OS 运行时和用户态虚拟机管理软件之间。它既要管理 VM 和 vCPU 的执行，也要处理 guest memory、timer、interrupt、device emulation、VM exit、控制接口以及与用户态 VMM 的协作。因此，Hypervisor 的核心挑战并不只是指令级虚拟化，而是如何组织一套完整的虚拟化运行时。

这套运行时通常依赖多个 OS 级能力域：

- 执行与调度能力，用于承载 vCPU；
- 内存管理能力，用于构造 guest address space；
- 时间与中断能力，用于维持虚拟硬件语义；
- I/O 与设备模型能力，用于处理 VM exit 和外设访问；
- 控制平面能力，用于向管理工具暴露 VM 生命周期和运行状态。

这些能力共同决定了一个 Hypervisor 能否从“能进入 guest”演进为“能承载完整虚拟化工作负载”。

因此，Hypervisor 更适合理解为一种**系统级虚拟化服务**：它一方面依赖硬件虚拟化扩展，另一方面深度依赖宿主 OS 提供的基础设施。如何获得、组织和复用这些宿主能力，直接决定了 Hypervisor 的工程复杂度、可移植性和生态兼容性。

## 2. 现有 Hypervisor 如何处理宿主基础设施

### 2.1 自建底座：控制力强，但系统栈复杂

一类 Hypervisor 选择自己成为硬件之上的最底层系统，例如 Xen、ACRN 等 Type-I Hypervisor。它们通过 dom0、Service VM 或管理域承载设备驱动、管理工具和 I/O 模型。这种方式的优势在于控制力强、虚拟化边界清晰；但代价是需要维护一整套专门的 Hypervisor 系统栈，包括调度、内存管理、中断路由、管理域、工具链和设备后端。

NOVA、seL4 CAmkES VMM 等微内核或 microhypervisor 路线进一步压缩可信核心，强调安全性和组件化隔离。但它们依然依赖特定微内核对象模型和专门的组件运行时。

这类系统说明：如果 Hypervisor 自己承担底座角色，就必须解决大量原本属于 OS 基础设施的问题。

### 2.2 复用宿主 OS：工程成本低，但绑定具体内核

另一类 Hypervisor 选择复用现有通用 OS。典型代表是 KVM。KVM 并没有重新实现一个完整的 Hypervisor OS，而是将 Linux 本身变成了虚拟化运行时。

在 KVM 中：

- VM 表现为 Linux 进程；
- vCPU 对应 Linux 调度实体；
- guest memory 与 Linux 用户态地址空间关联；
- VM、vCPU、device 通过 fd 和 ioctl 管理；
- QEMU、Firecracker、Cloud Hypervisor、crosvm 等 VMM 在用户态通过 `/dev/kvm` 使用内核虚拟化能力。

KVM 的关键工程优势之一，在于它复用了 Linux 已有的调度、内存管理、文件对象、用户态 ABI、eventfd、poll/epoll 和设备框架，而不是从零构建一套完整系统。

但这种复用方式深度绑定 Linux。KVM 并没有将“Hypervisor 需要哪些宿主 OS 能力”抽象为一组可被其他 OS 实现的接口，而是直接嵌入 Linux 的具体内核机制中。

这给出了一个重要启发，也引出了第一个核心问题。

## 3. 问题一：Hypervisor 的宿主依赖缺少可移植抽象

从现有系统看，Hypervisor 大致位于两个端点之间：

| 路线 | 代表系统 | 优点 | 局限 |
| --- | --- | --- | --- |
| 自建或专用底座 | Xen, ACRN, NOVA, seL4 VMM | 控制力强，可定制安全与隔离模型 | 需要维护完整专用系统栈 |
| 复用通用 OS | KVM, bhyve | 工程成本低，可复用成熟内核设施 | 深度绑定具体宿主 OS |

KVM 证明了“复用宿主 OS”是降低 Hypervisor 复杂度的有效方式。但 KVM 复用的是 Linux 的具体机制，而不是一组与 Linux 解耦的 Host 能力抽象。

因此，第一个问题是：

> **问题一：能否将 Hypervisor 对宿主 OS 的依赖提炼为一组显式的 Host Capability Interface，使同一个 Hypervisor Core 可以运行在不同 OS 底座之上？**

这个问题的本质是：我们希望继承 KVM “复用宿主 OS” 的思想，但不继承它对 Linux 的强绑定。

## 4. 新型 OS 如何复用 Linux 应用生态

另一个相关趋势是，许多新型 OS 并不尝试从头重建应用生态，而是通过 Linux ABI 兼容复用现有软件。

例如：

- Asterinas 以 Linux ABI 兼容为目标，支持大量 Linux syscall，使 Linux 应用和管理工具能够运行在非 Linux 内核上；
- FreeBSD Linuxulator 通过 Linux binary compatibility 运行未修改的 Linux 程序；
- illumos LX zones 通过 zones 和 Linux syscall 兼容运行 Linux userland；
- Fuchsia Starnix 在用户态实现 Linux ABI 兼容层，将 Linux 程序请求翻译到 Fuchsia；
- WSL 让 Windows 用户直接运行 Linux 命令行工具和应用；
- gVisor 作为 application kernel，在用户态实现 Linux-like interface 来运行容器 workload。

这些工作说明，Linux 兼容已经成为新 OS 降低生态成本的重要路径。

但这些兼容工作主要面向普通用户态应用，例如 shell 工具、编译器、数据库、Web 服务、中间件和容器 workload。虚拟化软件则不同。QEMU、Firecracker、Cloud Hypervisor、lkvm、crosvm 等程序虽然运行在用户态，但它们依赖的不只是 `open/read/write/mmap/ioctl` 这些 syscall 表面形式，而是 Linux KVM 在这些接口背后定义的一整套虚拟化语义。

具体来说，它们依赖：

- `/dev/kvm` 设备；
- `KVM_CREATE_VM` 创建 VM fd；
- `KVM_CREATE_VCPU` 创建 vCPU fd；
- `KVM_RUN` 进入 vCPU 执行；
- `KVM_SET_USER_MEMORY_REGION` 将用户态内存注册为 guest memory；
- `mmap` vCPU run page 获取 exit reason 和 MMIO 数据；
- `eventfd/ioeventfd` 支持用户态设备模型通知。

因此，一个 OS 即使已经能够运行大量 Linux 用户态程序，也并不意味着它能够运行依赖 KVM 的 Linux VMM。

## 5. 问题二：Linux 应用兼容与虚拟化生态兼容之间存在断层

现有 Linux 兼容工作主要解决的是：

> 普通 Linux 应用如何在非 Linux OS 上运行？

但虚拟化应用提出了更深一层的问题：

> 依赖 KVM 的 Linux VMM 如何在非 Linux OS 上运行？

这里的关键难点不只是 syscall ABI 兼容，而是 **KVM userspace ABI 所定义的一组状态对象、共享内存布局和事件交互语义是否可被重现**。例如：

- `/dev/kvm` 不只是一个普通字符设备，而是虚拟化会话入口；
- `ioctl` 不只是编号兼容，而是 VM/vCPU 生命周期与控制语义兼容；
- `mmap` 不只是映射内存，而是暴露 run structure 的共享状态；
- `eventfd` 不只是“有通知机制即可”，而是要满足 VMM 所依赖的事件行为。

因此，第二个问题是：

> **问题二：能否将 Linux 兼容从普通用户态应用扩展到虚拟化应用，通过在非 Linux OS 上提供 KVM-compatible userspace ABI，使部分 Linux VMM 无需修改地运行？**

这个问题连接了两个生态：

- Linux application compatibility；
- Linux virtualization compatibility。

现有工作主要覆盖前者，而我们的目标是补上后者。

## 6. 解决思路：将 Hypervisor 拆分为三层

为同时回应上述两个问题，我们提出一种跨 OS 底座的 Hypervisor 架构，将系统分解为三层：

```text
Linux VMMs
QEMU / lkvm / Firecracker / Cloud Hypervisor / crosvm
        |
        | northbound: KVM-compatible userspace ABI
        v
OS-independent Hypervisor Core
        |
        | southbound: Host Capability Interface
        v
ArceOS / Asterinas / future Linux / other kernels
```

这一架构包含两个关键边界。

### 6.1 向下：Host Capability Interface

Host Capability Interface 描述 Hypervisor Core 对宿主 OS 的依赖，而不是依赖某个具体 OS 的内部 API。更准确地说，它抽象的是 Hypervisor 所需的 **宿主运行时能力**，而不是硬件抽象。

这些能力可以分为两类：

**Core execution capabilities**

用于支持 Hypervisor Core 的基本运行：

- CPU 和 per-CPU 虚拟化初始化；
- host task 创建、调度与 CPU affinity；
- 物理页分配与地址转换；
- timer 与 monotonic time；
- IRQ 注册、处理与转发；
- wait queue 与同步原语。

**Userspace control-plane bridge capabilities**

用于将虚拟化能力暴露给用户态 VMM：

- control endpoint；
- `copy_from_user` / `copy_to_user`；
- 用户态内存 acquire/release；
- `mmap` 绑定；
- `eventfd` 或等价事件通知机制；
- 可选的 console / filesystem 支持。

通过这样的分层，Hypervisor Core 不再直接依赖 ArceOS、Asterinas 或 Linux，而只依赖一组显式的宿主能力接口。任何 OS 只要实现这些能力，就可以承载同一个 Hypervisor Core。

### 6.2 向上：KVM-compatible userspace ABI

面向 Linux VMM，我们在非 Linux OS 上提供一个 KVM-compatible userspace ABI。其关键设计是将 KVM ABI 中的语义分解为两部分：

| 内容 | 归属 |
| --- | --- |
| KVM ioctl number、VM/vCPU/session 语义、`KVM_RUN`、寄存器访问、memory slot 管理 | Hypervisor Core |
| `/dev/kvm` 设备节点、fd table、`mmap` object、`copy_from/to_user`、`eventfd`、用户页 acquire/release | Host adapter |

也就是说：

- Hypervisor Core 负责解释 KVM 的虚拟化语义；
- 宿主 OS 负责将这些语义接入自己的文件对象、用户地址空间和事件机制。

这样，KVM compatibility 就不再等同于“把 Linux KVM 移植到另一个 OS”，而是变成：

> 在非 Linux OS 上实现一个 KVM-compatible frontend，并将其映射到可移植的 Hypervisor Core。

## 7. 当前原型如何验证这一思路

当前 AxVisor 的解耦工作可以看作这一架构的原型验证。我们使用两种 evaluation configuration 来分别验证两个方向。

### 7.1 Static mode：验证 southbound portability

在 static mode 中，宿主 OS 启动后自动进入 AxVisor，VM 配置和 guest 镜像在启动前准备好，不依赖复杂的用户态控制平面。

这一配置主要验证：

- AxVisor Core 已经从 ArceOS 运行时中解耦；
- ArceOS 和 Asterinas 可以分别实现 Host Capability Interface；
- 同一个 Hypervisor Core 可以在不同 OS 底座上启动 guest；
- x86_64 和 riscv64 路径说明该接口并非单架构偶然设计。

因此，static mode 主要回答问题一：**Hypervisor Core 是否能够跨 OS 底座复用。**

### 7.2 Control mode：验证 northbound compatibility

在 control mode 中，Asterinas 正常启动，并通过 host adapter 将 AxVisor 暴露为 `/dev/kvm`。用户态 `lkvm` 可以通过 KVM-style ABI 创建 VM、创建 vCPU、注册 guest memory，并通过 `KVM_RUN` 启动 guest。

这一配置主要验证：

- 非 Linux OS 可以通过 host adapter 暴露 KVM-compatible control plane；
- KVM userspace ABI 的核心虚拟化语义可以由 portable Hypervisor Core 实现；
- 至少部分 Linux VMM workflow 可以在不理解 AxVisor 内部实现的情况下使用底层虚拟化能力。

因此，control mode 主要回答问题二：**非 Linux OS 是否能够支持 KVM-style 的虚拟化应用工作流。**

需要强调的是，这里的目标是验证 **KVM-compatible userspace ABI 的可行性**，而不是完整重现 Linux KVM 的全部内核能力。

## 8. 核心贡献

本文的贡献可以概括为四点：

1. **提出 Host Capability Model**

   从实际 Hypervisor 解耦过程中提炼出宿主 OS 必须提供的能力集合，并区分 Hypervisor Core 所需的执行能力与面向用户态控制平面的桥接能力。

2. **实现 OS-independent Hypervisor Core**

   将 AxVisor 从特定 OS 底座中解耦，使其依赖显式的 Host Capability Interface，而不是依赖某个特定内核的内部机制。

3. **提出 KVM-compatible frontend decomposition**

   将 KVM userspace ABI 分解为两部分：一部分是由 Hypervisor Core 实现的虚拟化语义，另一部分是由 host adapter 提供的 OS 对象绑定，从而使非 Linux OS 能够暴露 KVM-style 虚拟化服务。

4. **在两个 OS 底座上完成原型验证**

   在 ArceOS 和 Asterinas 上运行同一个 AxVisor Core，并在 Asterinas 上通过 `/dev/kvm` 支持 `lkvm` 的 control-mode workflow，验证该设计的可行性。

## 9. 非目标与边界

为了明确本文工作的边界，需要指出以下几点当前并非目标：

- 不追求完整复现 Linux KVM 的所有 ioctl 和语义；
- 不宣称所有 Linux VMM 都可立即无修改运行；
- 不以完整设备模型兼容、VFIO、live migration、nested virtualization 为当前目标；
- 不试图把所有 OS 机制统一成 Linux，而是只抽象 Hypervisor 所需的宿主能力。

因此，本工作的定位更准确地说是：

> 提出并验证一种将 Hypervisor 从特定 OS 底座中解耦的结构化方法，并证明在此基础上，非 Linux OS 可以进一步提供 KVM-compatible userspace ABI，以支持部分 Linux 虚拟化应用工作流。

## 10. 一句话总结

KVM 的工程优势之一，在于将 Linux 变成了 Hypervisor 的运行时；而我们的工作进一步将这一思想从 Linux 中抽象出来，使 Hypervisor 成为可被不同 OS 承载的核心引擎，并将 Linux 兼容从普通用户态应用扩展到 KVM 风格的虚拟化应用。
