# Firecracker 对 Linux 接口依赖分析

> Firecracker 是一个基于 KVM 的用户态 VMM (Virtual Machine Monitor)，专为 serverless/容器工作负载设计。
> 本文档分析 Firecracker 对 Linux 的完整接口依赖，包括 KVM ioctl 子集和 Linux syscall。
> **源码版本**: Firecracker v1.10.1, commit `1fcdaec`, 2024-11-12

## 分析范围

- **核心 crate**: `vmm` (虚拟化管理), `firecracker` (主程序/API), `jailer` (进程沙箱)
- **syscall 发现**: 两层标注 — 自有代码直接调用 vs `rust-vmm`/`vmm-sys-util` 等依赖库封装
- **KVM ioctl**: 通过 `kvm-ioctls` 和 `kvm-bindings` crate 封装调用

## Firecracker 的设计特点

与 QEMU 相比，Firecracker 做了激进的简化：

| 方面 | QEMU/KVM | Firecracker |
|------|---------|-------------|
| 设备模拟 | 全量 (VGA, AHCI, USB, PCI...) | 仅 virtio (net, block, vsock, rng, entropy) |
| 固件 | BIOS/UEFI | Linux boot protocol (无固件) |
| vCPU 数量 | 可配置多 vCPU | 最多 32 vCPU (单 VM) |
| 内存 | 完整内存热插拔 | 静态分配，启动后不可变 |
| 安全 | QEMU sandbox (可选) | 每 vCPU 线程 seccomp + jailer (chroot/cgroup/namespace) |
| Legacy 设备 | PIT, PIC, RTC, 串口 | 无（仅 virtio-mmio） |

---

## 1. 维度 1: 内存管理

> Firecracker 使用 `mmap` + `KVM_SET_USER_MEMORY_REGION` 管理 guest 内存，不支持 balloon/memory hotplug。

### 1.1 Guest 内存分配

#### `mmap()` [L1] — 匿名内存映射
- **源码**: `src/vmm/src/vstate/memory.rs:165-215`
- **语义**: 通过 `MmapRegionBuilder` 分配 guest 物理内存。支持两种模式：
  - **私有匿名**（默认）: `MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE`
  - **共享**（用于 snapshot restore/vhost-user）: `MAP_SHARED`
- **调用上下文**: consumer — VM 初始化时由 `GuestMemoryMmap::new()` 调用
- **边界类型**: `syscall`（直接 libc 调用）
- **接口契约**: 支持 huge pages (2MB/1GB) 通过 `MAP_HUGETLB`；prot = `PROT_READ | PROT_WRITE`
- **hot path**: 否（初始化路径，但影响 guest 性能）

#### `KVM_SET_USER_MEMORY_REGION` [L1] — 注册 guest 内存到 KVM
- **源码**: `src/vmm/src/vstate/vm.rs:250` — `self.fd.set_user_memory_region(memory_region)`
- **语义**: 将 mmap 分配的内存注册为 KVM guest 物理地址空间。
- **边界类型**: `ioctl UAPI`（KVM ioctl，通过 `kvm-ioctls` crate）
- **hot path**: 否

### 1.2 页面映射优化

#### `madvise()` [L1]
- **源码**: 通过 `vm-memory` crate 间接使用
- **语义**: 提示内核页面使用模式（如 `MADV_MERGEABLE` 用于 KSM）。
- **边界类型**: `syscall`

#### `KVM_MEM_LOG_DIRTY_PAGES` [L1] — 脏页追踪
- **源码**: `src/vmm/src/vstate/vm.rs:17`
- **语义**: 在创建 memslot 时启用脏页日志，用于 snapshot/diff 迁移。
- **边界类型**: `ioctl UAPI`（通过 `kvm_userspace_memory_region.flags`）

---

## 2. 维度 2: vCPU 管理

> Firecracker 使用 KVM vCPU API 管理 vCPU。vCPU 线程通过 seccomp 隔离。

### 2.1 VM 创建

#### `KVM_CREATE_VM` [L1]
- **源码**: `src/vmm/src/vstate/vm.rs:151` — `kvm.create_vm()`
- **语义**: 通过 `/dev/kvm` fd 创建 VM 实例。
- **边界类型**: `ioctl UAPI`（kvm-ioctls: `Kvm::create_vm()`）
- **hot path**: 否

#### `KVM_CHECK_EXTENSION` [L1]
- **源码**: `src/vmm/src/vstate/vm.rs:264-271` — 检查 x86_64 能力；`vm.rs:329-342` — 扩展检查
- **语义**: 查询 KVM 支持的能力（`KVM_CAP_IRQCHIP`, `KVM_CAP_IOEVENTFD`, `KVM_CAP_IRQFD`, `KVM_CAP_USER_MEMORY`, `KVM_CAP_PIT2`, `KVM_CAP_ADJUST_CLOCK` 等 20+ 能力）。
- **边界类型**: `ioctl UAPI`
- **调用上下文**: consumer — VM 初始化时能力探测
- **hot path**: 否

#### `open("/dev/kvm")` [L1]
- **源码**: kvm-ioctls crate 内部
- **语义**: 打开 KVM 设备节点获取 fd。
- **边界类型**: `syscall`（通过 kvm-ioctls `Kvm::new()` → `open("/dev/kvm")`）
- **横切标签**: fd/device node

### 2.2 vCPU 生命周期

#### `KVM_CREATE_VCPU` [L1]
- **源码**: kvm-ioctls: `VmFd::create_vcpu()`
- **语义**: 创建 vCPU fd（每 vCPU 一个 fd）。Firecracker 最多 32 vCPU。
- **边界类型**: `ioctl UAPI`
- **hot path**: 否

#### `KVM_RUN` [L1]
- **源码**: `src/vmm/src/vstate/vcpu/mod.rs:287-570`
- **语义**: 通过 `KvmRunWrapper::mmap_from_fd()` 获取 mmap 的 `kvm_run` 结构体，然后循环调用 ioctl `KVM_RUN` 进入 guest 执行。
- **调用上下文**: consumer — 每个 vCPU 线程的主循环
- **边界类型**: `ioctl UAPI`
- **接口契约**: 每次 VM exit 后返回，携带 `kvm_run.exit_reason`；支持 KVM_EXIT_IO, KVM_EXIT_MMIO, KVM_EXIT_HLT, KVM_EXIT_SHUTDOWN, KVM_EXIT_FAIL_ENTRY, KVM_EXIT_INTERNAL_ERROR
- **hot path**: 是（guest 执行的核心循环）

#### `KVM_GET_VCPU_MMAP_SIZE` [L1]
- **源码**: kvm-ioctls: `VmFd::run_size()`
- **语义**: 获取 `kvm_run` 结构体的 mmap 大小。
- **边界类型**: `ioctl UAPI`
- **hot path**: 否

#### `KVM_SET_SIGNAL_MASK` [L1]
- **源码**: kvm-ioctls（impl VcpuFd）
- **语义**: 设置 vCPU 的信号掩码，配合 guest 的 pv sched yield。
- **边界类型**: `ioctl UAPI`

### 2.3 vCPU 配置

#### `KVM_SET_REGS` / `KVM_GET_REGS` [L1]
- **语义**: 设置/获取 vCPU 通用寄存器。用于初始化 guest RIP/RSP/RFLAGS 和保存/恢复。
- **边界类型**: `ioctl UAPI`

#### `KVM_SET_SREGS` / `KVM_GET_SREGS` [L1]
- **语义**: 设置/获取 vCPU 段寄存器和特殊寄存器（CS/DS/SS/ES/FS/GS + GDTR/LDTR/IDTR/TR）。
- **边界类型**: `ioctl UAPI`

#### `KVM_SET_CPUID2` [L1]
- **源码**: `src/vmm/src/vstate/vcpu/x86_64.rs:946`
- **语义**: 设置 guest CPUID leaves。Firecracker 基于宿主机 CPUID (`KVM_GET_SUPPORTED_CPUID`) 做过滤。
- **边界类型**: `ioctl UAPI`

#### `KVM_GET_SUPPORTED_CPUID` [L1]
- **语义**: 获取宿主机 KVM 支持的 CPUID leaves。Firecracker 用此结果初始化 guest CPUID。
- **边界类型**: `ioctl UAPI`

#### `KVM_GET_MSRS` / `KVM_SET_MSRS` [L1]
- **源码**: `src/vmm/src/vstate/vcpu/x86_64.rs:368`
- **语义**: 批量读写 MSR 寄存器（EFER, STAR, LSTAR, CSTAR, SYSCALL_MASK 等）。
- **边界类型**: `ioctl UAPI`

#### `KVM_GET_MSR_INDEX_LIST` [L1]
- **源码**: `src/vmm/src/vstate/vcpu/x86_64.rs:147`
- **语义**: 获取 KVM 支持的 MSR 索引列表。
- **边界类型**: `ioctl UAPI`

#### `KVM_SET_TSS_ADDR` [L1]
- **语义**: 设置 x86 TSS (Task State Segment) 地址。x86 保护模式需要。
- **边界类型**: `ioctl UAPI`

#### `KVM_SET_IDENTITY_MAP_ADDR` [L1]
- **语义**: 设置 identity map 地址（用于 guest 实模式启动）。
- **边界类型**: `ioctl UAPI`

#### `KVM_GET_TSC_KHZ` / `KVM_SET_TSC_KHZ` [L1]
- **语义**: 获取/设置 TSC 频率。用于 guest TSC 校准。
- **边界类型**: `ioctl UAPI`

#### `KVM_GET_CPUID2` [L2]
- **源码**: `src/vmm/src/vstate/vcpu/x86_64.rs:277`
- **语义**: 验证之前 `KVM_SET_CPUID2` 的写入结果。
- **边界类型**: `ioctl UAPI`

#### `libc::dup()` [L2] — vCPU fd 复制
- **源码**: `src/vmm/src/vstate/vcpu/mod.rs:247`
- **语义**: 为 seccomp 加载前的 vCPU 操作复制 fd。
- **边界类型**: `syscall`
- **hot path**: 否

---

## 3. 维度 3: I/O 模型

> Firecracker 仅支持 virtio-mmio 设备，不使用 PCI 总线。I/O 通过 KVM ioeventfd 实现异步通知。

### 3.1 I/O 资源访问 [子维度 3a]

#### `KVM_IOEVENTFD` [L1] — I/O 事件通知
- **源码**: `src/vmm/src/vstate/vm.rs:265` (KVM_CAP_IOEVENTFD check), `src/vmm/src/devices/virtio/mmio.rs` (使用)
- **语义**: 注册 I/O 地址空间的事件通知。当 guest 写入特定 MMIO/PIO 地址时，KVM 直接触发 eventfd，无需 VM exit。
- **边界类型**: `ioctl UAPI`
- **接口契约**: 输入地址、长度、eventfd；fire-and-forget 通知；消除 VM exit — 关键优化
- **hot path**: 是（virtio 通知路径上）

#### `KVM_IRQFD` [L1] — 中断注入通知
- **源码**: `src/vmm/src/vstate/vm.rs:266` (KVM_CAP_IRQFD check)
- **语义**: 将 eventfd 连接到 guest IRQ 线。当 eventfd 被写入时，KVM 自动向 guest 注入对应中断。
- **边界类型**: `ioctl UAPI`
- **hot path**: 是

#### `eventfd()` [L1]
- **源码**: `vmm-sys-util::eventfd::EventFd::new(libc::EFD_NONBLOCK)` — 整个 vmm crate 广泛使用（30+ 处）
- **语义**: 创建非阻塞 eventfd。用于 vCPU exit 通知、virtio 设备 kick、设备间信号等。Firecracker 的事件驱动架构核心。
- **边界类型**: `syscall`（vmm-sys-util 封装，底层调用 `syscall(SYS_eventfd2)`）
- **hot path**: 是

### 3.2 I/O 设备协议 [子维度 3b]

#### TUN/TAP 设备 [L1] — virtio-net 后端
- **源码**: `src/vmm/src/devices/virtio/net/tap.rs:40-49`
- **语义**: 通过 `/dev/net/tun` 创建 TAP 设备用于 guest 网络。关键 ioctl：
  - `TUNSETIFF` — 绑定 TAP 接口（`IFF_TAP | IFF_NO_PI`）
  - `TUNSETOFFLOAD` — 设置 offload 标志
  - `TUNSETVNETHDRSZ` — 设置 virtio-net header 大小
- **边界类型**: `ioctl`（Linux 网络设备 ioctl）
- **横切标签**: host 资源

#### virtio-vsock [L1]
- **源码**: `src/vmm/src/devices/virtio/vsock/`
- **语义**: 通过 Unix socket (`AF_UNIX`, `SOCK_STREAM`) 实现的 virtio-vsock 设备。guest 内通过 vsock CID 与 host 通信。
- **边界类型**: `syscall`（socket/bind/listen/accept）
- **横切标签**: host 资源

#### virtio-block [L1]
- **源码**: `src/vmm/src/devices/virtio/block/`
- **语义**: virtio-block 设备，后端可为文件/块设备（`pread/pwrite` on fd）或 vhost-user-blk。
- **边界类型**: `syscall`（open/pread/pwrite/fsync）

---

## 4. 维度 4: 中断与事件

#### `KVM_CREATE_IRQCHIP` [L1]
- **源码**: `src/vmm/src/vstate/vm.rs:329` (KVM_CAP_IRQCHIP check)
- **语义**: 在 KVM 内核侧创建虚拟中断控制器（APIC + IOAPIC）。Firecracker 使用内核 IRQCHIP 而非用户态模拟。
- **边界类型**: `ioctl UAPI`
- **hot path**: 否（初始化）

#### `KVM_CREATE_PIT2` [L1]
- **语义**: 创建 PIT 定时器（仅用于 guest 启动阶段的早期时钟）。
- **边界类型**: `ioctl UAPI`

#### VM Exit 处理 [L1]
- **源码**: `src/vmm/src/vstate/vcpu/mod.rs:503-570`
- **语义**: Firecracker 处理以下 KVM exit 原因：
  - `KVM_EXIT_IO` — PIO 指令拦截（极少，Firecracker 不使用 PIO）
  - `KVM_EXIT_MMIO` — MMIO 访问（virtio-mmio 设备读写）
  - `KVM_EXIT_HLT` — guest HLT 指令
  - `KVM_EXIT_SHUTDOWN` — guest 关机
  - `KVM_EXIT_FAIL_ENTRY` — vCPU entry 失败
  - `KVM_EXIT_INTERNAL_ERROR` — KVM 内部错误
- **边界类型**: `ioctl UAPI`（通过 kvm_run.exit_reason）

#### `EINTR` / `EAGAIN` 信号处理 [L2]
- **源码**: `src/vmm/src/vstate/vcpu/mod.rs:501, 603-604`
- **语义**: `KVM_RUN` 可能因信号（`EINTR`）或 vCPU kick（`EAGAIN`）提前返回。Firecracker 正确处理这两种情况。
- **边界类型**: `syscall`（errno 常量）

---

## 5. 维度 5: 时钟与定时器

#### `KVM_GET_CLOCK` / `KVM_SET_CLOCK` [L1]
- **语义**: 获取/设置 KVM 系统时钟（kvmclock）。用于 snapshot restore 后的时间同步。
- **边界类型**: `ioctl UAPI`

#### `KVM_CAP_ADJUST_CLOCK` [L1]
- **源码**: `src/vmm/src/vstate/vm.rs:336`
- **语义**: 检测是否支持 `KVM_CLOCK_TSC_STABLE` 等时钟调整能力。
- **边界类型**: `ioctl UAPI` (KVM_CHECK_EXTENSION)

#### `timerfd_create()` / `timerfd_settime()` [L1]
- **语义**: 创建/配置定时器 fd，用于 Firecracker 内部的速率限制（rate limiter）和操作超时。通过 `vmm-sys-util` crate 封装。
- **边界类型**: `syscall`
- **hot path**: 否（速率限制路径）

#### `KVM_GET_TSC_KHZ` [L1]
- **语义**: 获取宿主机 TSC 频率，用于 guest TSC 校准。
- **边界类型**: `ioctl UAPI`

---

## 6. 维度 6: 调度与同步

> Firecracker 将每个 vCPU 作为独立线程运行，还有一个 API 线程和多个设备工作线程。线程间通过 eventfd + epoll 通信。

#### `pthread_create()` [L1] — vCPU 线程创建
- **语义**: 为每个 vCPU 创建专用线程。每个线程绑定独立 seccomp filter。
- **边界类型**: `syscall`（通过 `std::thread::spawn` → `pthread_create`）
- **接口契约**: vCPU 线程 pin 到特定 host CPU（通过 `sched_setaffinity`）；具有独立信号掩码

#### `epoll_create1()` / `epoll_ctl()` / `epoll_wait()` [L1]
- **源码**: `src/vmm/src/event_manager.rs` (EventManager), `src/firecracker/src/main.rs:594`
- **语义**: Firecracker 主事件循环。EventManager 基于 epoll 实现，管理 API server、vCPU exit events、virtio 设备 eventfd、timerfd 等所有 fd。
- **边界类型**: `syscall`（通过 `vmm-sys-util::epoll` crate）
- **接口契约**: `epoll_create1(EPOLL_CLOEXEC)`；epoll_wait 阻塞等待；timeout 实现速率限制
- **hot path**: 是（主事件循环）

#### `sched_setaffinity()` [L2]
- **语义**: 将 vCPU 线程绑定到特定物理 CPU core，确保 vCPU 缓存亲和性和减少迁移。
- **边界类型**: `syscall`
- **hot path**: 否（初始化）

#### `signal` / `sigaction` [L2]
- **语义**: vCPU 线程处理 SIGRT 信号，用于 kick vCPU（强制退出 KVM_RUN）。
- **边界类型**: `syscall`

---

## 7. 维度 7: 安全与隔离

> Firecracker 的安全模型是它的核心设计亮点。两层沙箱：(1) seccomp per-thread, (2) jailer 进程级隔离。

### 7.1 seccomp (线程级)

#### `seccomp()` / `seccompiler` [L1]
- **源码**: `src/vmm/src/vstate/vcpu/mod.rs:287-293`
- **语义**: 每个 vCPU 线程在进入 guest loop 前加载 seccomp-bpf filter。Firecracker 使用自定义 `seccompiler` crate 将 JSON 策略编译为 BPF 字节码。
- **调用上下文**: consumer — vCPU 线程启动时 `seccompiler::apply_filter()`
- **边界类型**: `syscall`（`prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER)` — 通过 seccompiler crate）
- **接口契约**: JSON 策略定义允许的 syscall 和参数过滤规则；violation → SIGSYS → 进程终止

### 7.2 jailer (进程级)

#### `clone()` [L1] — 命名空间创建
- **源码**: `src/jailer/src/env.rs:85-98`
- **语义**: 通过 `SYS_clone` 创建新的 PID namespace、网络 namespace 等。
- **边界类型**: `syscall`（直接 `libc::syscall(SYS_clone)`）
- **hot path**: 否（启动）

#### `chroot()` [L1]
- **源码**: `src/jailer/src/chroot.rs`
- **语义**: 将 Firecracker 进程限制在指定根目录内。jailer 在 chroot 前绑定 mount `/proc`、`/dev/kvm`、网络设备等到新 root。
- **边界类型**: `syscall`

#### `unshare()` [L1]
- **语义**: 解除与宿主命名空间的共享关系（mount namespace, UTS namespace 等）。
- **边界类型**: `syscall`

#### `mount()` / `pivot_root()` [L1]
- **语义**: 在 jailer 创建的命名空间内设置文件系统隔离。
- **边界类型**: `syscall`

#### cgroup [L1]
- **源码**: `src/jailer/src/cgroup.rs`
- **语义**: 通过写入 cgroup v1/v2 文件系统（`/sys/fs/cgroup/`）限制 Firecracker 的 CPU、内存、I/O 资源。
- **边界类型**: `syscall`（`open/write` to cgroupfs）

#### `prctl()` [L2]
- **语义**: `PR_SET_NO_NEW_PRIVS` — 禁止后续提权（seccomp 前置要求）。
- **边界类型**: `syscall`

---

## KVM ioctl 使用子集对比

Firecracker 使用的 KVM ioctl 与完整 Linux KVM ioctl 集的对比：

| KVM ioctl | 用途 | Firecracker | 说明 |
|-----------|------|-------------|------|
| `KVM_CREATE_VM` | 创建 VM | ✅ | 核心 |
| `KVM_CREATE_VCPU` | 创建 vCPU | ✅ | 最多 32 个 |
| `KVM_RUN` | 执行 vCPU | ✅ | 主循环 |
| `KVM_SET_USER_MEMORY_REGION` | 设置内存 | ✅ | 单次分配 |
| `KVM_SET_TSS_ADDR` | TSS 地址 | ✅ | x86 保护模式 |
| `KVM_SET_IDENTITY_MAP_ADDR` | Identity map | ✅ | 实模式启动 |
| `KVM_CREATE_IRQCHIP` | 中断控制器 | ✅ | 内核 IRQCHIP |
| `KVM_CREATE_PIT2` | PIT 定时器 | ✅ | 早期启动时钟 |
| `KVM_IOEVENTFD` | I/O 事件 | ✅ | virtio 优化 |
| `KVM_IRQFD` | IRQ 注入 | ✅ | virtio 中断 |
| `KVM_SET_REGS/GET_REGS` | 通用寄存器 | ✅ | |
| `KVM_SET_SREGS/GET_SREGS` | 段寄存器 | ✅ | |
| `KVM_SET_CPUID2` | CPUID 配置 | ✅ | |
| `KVM_GET_SUPPORTED_CPUID` | CPUID 探测 | ✅ | |
| `KVM_GET_MSRS/SET_MSRS` | MSR 读写 | ✅ | |
| `KVM_GET_MSR_INDEX_LIST` | MSR 列表 | ✅ | |
| `KVM_GET_VCPU_MMAP_SIZE` | kvm_run 大小 | ✅ | |
| `KVM_CHECK_EXTENSION` | 能力探测 | ✅ | 20+ 能力 |
| `KVM_GET_TSC_KHZ/SET_TSC_KHZ` | TSC 频率 | ✅ | |
| `KVM_GET_CLOCK/SET_CLOCK` | 系统时钟 | ✅ | snapshot |
| `KVM_SET_SIGNAL_MASK` | 信号掩码 | ✅ | |
| `KVM_GET_CPUID2` | CPUID 验证 | ✅ | |
| `KVM_DIRTY_LOG` | 脏页日志 | ✅ | snapshot diff |
| `KVM_GET_API_VERSION` | API 版本 | ✅ (kvm-ioctls 内部) | |
| `KVM_CREATE_DEVICE` | 创建设备 | ❌ | 不需要其他 KVM 设备 |
| `KVM_SET_DEVICE_ATTR` | 设备属性 | ❌ | |
| `KVM_GET_DEVICE_ATTR` | 设备属性 | ❌ | |
| `KVM_SET_GSI_ROUTING` | GSI 路由 | ❌ | 不需要 MSI 路由 |
| `KVM_SIGNAL_MSI` | MSI 信号 | ❌ | |
| `KVM_GET_MSI_STAT` | MSI 统计 | ❌ | |
| `KVM_ASSIGN_PCI_DEVICE` | PCI 直通 | ❌ | 无 PCI 支持 |
| `KVM_SET_CPUID` | CPUID (旧版) | ❌ | 使用 CPUID2 |
| `KVM_SET_NESTED_STATE` | Nested virt | ❌ | 无嵌套虚拟化 |
| `KVM_GET_NESTED_STATE` | Nested virt | ❌ | |
| `KVM_ENABLE_CAP` | 启用能力 | ❌ | |

**统计**: Firecracker 使用约 **22/45** 个 KVM ioctl（约 49%），省略了大量传统设备（PCI、MSI、嵌套虚拟化等）相关接口。

---

## syscall 依赖清单

### 第 1 层: Firecracker 自有代码直接调用

| syscall | 使用位置 | 维度 | 用途 |
|---------|---------|------|------|
| `mmap` | vstate/memory.rs | 1 | guest 内存分配 |
| `madvise` | vm-memory crate | 1 | 内存优化提示 |
| `open("/dev/kvm")` | kvm-ioctls (间接) | 2 | KVM 设备访问 |
| `dup` | vcpu/mod.rs:247 | 2 | fd 复制 |
| `close` | vcpu/x86_64.rs:877 | 2 | fd 关闭 |
| `eventfd` | 30+ 位置 | 3/4 | virtio/I/O 通知 |
| `open("/dev/net/tun")` | net/tap.rs | 3 | TAP 设备 |
| `socket/bind/listen` | vsock/ | 3 | vsock 通信 |
| `epoll_create1` | event_manager.rs | 6 | 事件循环 |
| `epoll_ctl` | event_manager.rs | 6 | fd 注册 |
| `epoll_wait` | event_manager.rs | 6 | 事件等待 |
| `timerfd_create` | rate_limiter | 5 | 速率限制 |
| `timerfd_settime` | rate_limiter | 5 | 定时器配置 |
| `pthread_create` | std::thread | 6 | vCPU 线程 |
| `sched_setaffinity` | vcpu threading | 6 | CPU 亲和性 |
| `sigaction` | vcpu signal handling | 4/6 | vCPU 信号处理 |
| `clone` (SYS_clone) | jailer/env.rs:98 | 7 | 命名空间隔离 |
| `unshare` | jailer | 7 | 命名空间解除 |
| `chroot` | jailer/chroot.rs | 7 | 根目录隔离 |
| `mount/pivot_root` | jailer | 7 | 文件系统隔离 |
| `prctl(PR_SET_NO_NEW_PRIVS)` | jailer | 7 | 禁止提权 |
| `prctl(PR_SET_SECCOMP)` | seccompiler | 7 | seccomp 加载 |
| `open/write (cgroupfs)` | jailer/cgroup.rs | 7 | cgroup 资源限制 |

### 第 2 层: 依赖库封装调用

| 依赖 crate | 封装的 syscall | 用途 |
|-----------|---------------|------|
| `kvm-ioctls` | 全部 KVM ioctl | KVM 虚拟化接口 |
| `kvm-bindings` | (FFI 绑定) | KVM ioctl 常量/结构体 |
| `vmm-sys-util` | eventfd, epoll, timerfd, clock_gettime, signal | 系统工具 |
| `vm-memory` | mmap, madvise, mprotect | 内存管理 |
| `seccompiler` | prctl(PR_SET_SECCOMP) | seccomp-bpf 编译加载 |
| `vhost` | ioctl(VHOST_*) | vhost-user 后端 (可选) |

### 第 3 层: seccomp 白名单 (交叉验证)

Firecracker 的 seccomp filter 白名单（从 seccompiler JSON 策略中可提取）只允许上述列出的 syscall，任何未在白名单中的 syscall 会触发 SIGSYS 终止进程。

---

## 简化设计决策

| 未使用的 KVM 特性 | 原因 |
|------------------|------|
| PCI 总线 / MSI 路由 | virtio-mmio 设备，无 PCI |
| VFIO / PCI 直通 | serverless 场景不需要 |
| Nested virtualization | 不需要在 guest 中运行 hypervisor |
| KVM_SET_GSI_ROUTING | 内核 IRQCHIP 直接处理 |
| KVM_CREATE_DEVICE (非 IRQCHIP) | 无其他 KVM 设备 |
| balloon driver | 内存静态分配 |
| 传统设备 (VGA, 串口, IDE...) | 无固件启动 |
| guest_memfd | 使用传统 memslot API |

---

## 接口统计

| 维度 | L1 接口 | 边界类型分布 |
|------|---------|-------------|
| 1. 内存管理 | 4 | 2 syscall, 2 ioctl |
| 2. vCPU 管理 | 15 | 14 ioctl, 1 syscall |
| 3. I/O 模型 | 8 | 3 ioctl, 5 syscall |
| 4. 中断与事件 | 4 | 2 ioctl, 2 syscall |
| 5. 时钟与定时器 | 4 | 2 ioctl, 2 syscall |
| 6. 调度与同步 | 6 | 6 syscall |
| 7. 安全与隔离 | 8 | 8 syscall |
| **总计** | **49** | **ioctl: 23, syscall: 26** |

> Firecracker 的接口特点：KVM ioctl 集中于 vCPU 管理和 I/O 优化，安全隔离完全依赖 Linux syscall（seccomp/chroot/cgroup/clone）。

## 源码参考

| 类别 | Firecracker 源文件 |
|------|-------------------|
| VM 管理 | `src/vmm/src/vstate/vm.rs` |
| vCPU | `src/vmm/src/vstate/vcpu/mod.rs`, `src/vmm/src/vstate/vcpu/x86_64.rs` |
| 内存 | `src/vmm/src/vstate/memory.rs` |
| virtio-net | `src/vmm/src/devices/virtio/net/` |
| virtio-block | `src/vmm/src/devices/virtio/block/` |
| virtio-vsock | `src/vmm/src/devices/virtio/vsock/` |
| 事件管理 | `src/vmm/src/event_manager.rs` |
| jailer | `src/jailer/src/env.rs`, `src/jailer/src/chroot.rs`, `src/jailer/src/cgroup.rs` |
| seccomp | `src/vmm/src/seccomp_filters/` (策略 JSON) |
