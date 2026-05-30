# Solo5 操作系统接口依赖分析

## 1. 架构概览

Solo5 是一个 unikernel 框架，通过多种 "target"（后端）运行于不同的 OS/Hypervisor 之上：

```
                        ┌──────────────────────────┐
                        │   Solo5 Public API        │
                        │   (solo5.h)               │
                        └─────────┬────────────────┘
                                  │
              ┌───────────────────┼───────────────────┐
              │                   │                    │
     ┌────────┴────────┐ ┌───────┴───────┐ ┌────────┴────────┐
     │   HVT Target    │ │  SPT Target   │ │  其他 Targets   │
     │ (硬件虚拟化)     │ │ (seccomp沙箱) │ │ virtio/xen/muen │
     └────────┬────────┘ └───────┬───────┘ └────────┬────────┘
              │                   │                    │
     ┌────────┴────────┐ ┌───────┴───────┐ ┌────────┴────────┐
     │   solo5-hvt     │ │   solo5-spt   │ │  各Hypervisor   │
     │   (Tender进程)   │ │  (Tender进程)  │ │  直接运行       │
     └────────┬────────┘ └───────┬───────┘ └─────────────────┘
              │                   │
     ┌────────┴──────────────────┴───────────────────┐
     │              宿主机操作系统                      │
     │     Linux / FreeBSD / OpenBSD                  │
     └───────────────────────────────────────────────┘
```

每个 Target 分为两大部分：
- **Bindings（客户机侧）**：运行在虚拟机/沙箱内的代码，通过 hypercall 或 syscall 与 host 通信
- **Tenders（宿主机侧）**：宿主机用户态进程，负责加载和管理 unikernel

---

## 2. HVT Target — 硬件虚拟化后端

### 2.1 HVT Hypercall ABI（客户机 ↔ 宿主机接口）

**通信机制**：
- x86_64：通过 PIO（Port I/O）指令 `outl`，基地址 `0x500`
- aarch64：通过 MMIO（内存映射 I/O）`str` 指令，基地址 `0x100000000`

**Hypercall 命令列表**：

| 编号 | 命令 | 功能 | 对应的宿主机操作 |
|------|------|------|-----------------|
| 1 | `HVT_HYPERCALL_WALLTIME` | 获取墙上时钟时间 | `clock_gettime(CLOCK_REALTIME)` |
| 2 | `HVT_HYPERCALL_PUTS` | 控制台输出 | `write(stdout, ...)` |
| 3 | `HVT_HYPERCALL_POLL` | 等待 I/O 就绪 | `epoll_pwait()` + `timerfd_settime()` |
| 4 | `HVT_HYPERCALL_BLOCK_WRITE` | 块设备写入 | `pwrite64()` |
| 5 | `HVT_HYPERCALL_BLOCK_READ` | 块设备读取 | `pread64()` |
| 6 | `HVT_HYPERCALL_NET_WRITE` | 网络发送 | `write(tap_fd, ...)` |
| 7 | `HVT_HYPERCALL_NET_READ` | 网络接收 | `read(tap_fd, ...)` |
| 8 | `HVT_HYPERCALL_HALT` | 停止执行 | `exit_group()` |

**启动信息结构**（`hvt_boot_info`）：
```c
struct hvt_boot_info {
    uint64_t mem_size;           // 总内存大小
    uint64_t kernel_end;         // 内核结束地址
    uint64_t cpu_cycle_freq;     // TSC 频率
    const char *cmdline;         // 命令行参数
    const void *mft;             // 应用 Manifest
    uint32_t host_features;      // 宿主机特性标志
    uint32_t guest_features;     // 客户机协商的特性
    void *net_ring;              // 网络 Ring Buffer GPA（可选）
};
```

### 2.2 HVT Tender 的 Linux/KVM 接口依赖

#### 2.2.1 KVM 设备操作

| 接口 | 用途 |
|------|------|
| `open("/dev/kvm", O_RDWR \| O_CLOEXEC)` | 打开 KVM 设备 |

#### 2.2.2 KVM ioctl 命令

**VM 生命周期管理**：

| ioctl 命令 | 功能 |
|------------|------|
| `KVM_GET_API_VERSION` | 获取 KVM API 版本 |
| `KVM_CHECK_EXTENSION` | 检查 KVM 能力支持 |
| `KVM_CREATE_VM` | 创建虚拟机实例 |
| `KVM_CREATE_VCPU` | 创建虚拟 CPU |
| `KVM_GET_VCPU_MMAP_SIZE` | 获取 VCPU 运行结构体的 mmap 大小 |
| `KVM_RUN` | 运行 VCPU（主执行循环） |

**内存管理**：

| ioctl 命令 | 功能 |
|------------|------|
| `KVM_SET_USER_MEMORY_REGION` | 设置客户机物理内存映射 |

**x86_64 寄存器操作**：

| ioctl 命令 | 功能 |
|------------|------|
| `KVM_GET_SUPPORTED_CPUID` | 获取支持的 CPUID 特性 |
| `KVM_SET_CPUID2` | 设置 CPUID 特性 |
| `KVM_SET_SREGS` | 设置段寄存器（CS, DS, SS, ES, FS, GS） |
| `KVM_GET_REGS` | 获取通用寄存器 |
| `KVM_SET_REGS` | 设置通用寄存器 |
| `KVM_GET_TSC_KHZ` | 获取 TSC 频率 |

**aarch64 寄存器操作**：

| ioctl 命令 | 功能 |
|------------|------|
| `KVM_SET_ONE_REG` / `KVM_GET_ONE_REG` | 设置/获取单个寄存器 |
| `KVM_ARM_PREFERRED_TARGET` | 获取首选 VCPU 目标 |
| `KVM_ARM_VCPU_INIT` | 初始化 ARM VCPU |

**I/O 事件通知**：

| ioctl 命令 | 功能 |
|------------|------|
| `KVM_IOEVENTFD` | 注册 I/O 事件通知（异步 Ring I/O） |

**VM Exit 处理**（通过 `kvm_run` 结构体）：

| Exit 原因 | 处理方式 |
|-----------|---------|
| `KVM_EXIT_IO` | 处理 PIO 请求（hypercall 分发） |
| `KVM_EXIT_MMIO` | 处理 MMIO 请求（aarch64 hypercall） |
| `KVM_EXIT_FAIL_ENTRY` | VCPU 进入失败处理 |
| `KVM_EXIT_INTERNAL_ERROR` | KVM 内部错误处理 |

#### 2.2.3 POSIX 系统调用

**文件 I/O**：
- `open()`, `read()`, `write()`, `close()`, `lseek()`, `fstat()`
- `pread64()`, `pwrite64()` — 块设备按偏移读写

**内存管理**：
- `mmap()` — 映射 VCPU 运行结构体和客户机内存
- `mprotect()` — 设置内存页保护属性
- `munmap()`, `madvise()`

**进程管理**：
- `exit()` / `exit_group()`
- `getpid()`, `getppid()`
- `getuid()`, `geteuid()`, `getgid()`, `getegid()`
- `setresuid()`, `setresgid()` — 权限降级

**时间管理**：
- `clock_gettime(CLOCK_MONOTONIC)` — 单调时钟
- `clock_gettime(CLOCK_REALTIME)` — 墙上时钟

**事件通知**：
- `epoll_create1()`, `epoll_ctl()`, `epoll_wait()` / `epoll_pwait()`
- `timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK)`, `timerfd_settime()`
- `eventfd()` — 用于 KVM IOEventFD

**信号处理**：
- `sigaction()` — 注册 SIGINT, SIGTERM 处理器
- GDB 调试时还处理 SIGSEGV, SIGTRAP, SIGKILL, SIGQUIT

**网络（TAP 设备）**：
- `ioctl(TUNSETIFF)` — 绑定 TAP 接口，flags: `IFF_TAP | IFF_NO_PI`
- `ioctl(SIOCGIFMTU)` — 获取接口 MTU
- `ioctl(ETHTOOL_SGRO)` / `ioctl(ETHTOOL_SGSO)` — 禁用 GRO/GSO 卸载
- `read(tap_fd)` / `write(tap_fd)` — 网络 I/O
- `/dev/urandom` — MAC 地址生成

**系统信息**：
- `personality()` — 检查 READ_IMPLIES_EXEC 标志

**线程（调试支持）**：
- `pthread_create()`, `pthread_join()`
- `pthread_mutex_*` — 内部使用 futex

### 2.3 HVT Tender 的 FreeBSD 接口

| 接口 | 功能 |
|------|------|
| `open("/dev/vmm/...")` | 打开 vmm 设备 |
| `VM_ALLOC_MEMSEG` | 分配内存段 |
| `VM_MMAP_MEMSEG` | 映射内存段 |
| `VM_SET_CAPABILITY` | 设置 VM 能力 |
| `VM_SET_SEGMENT_DESCRIPTOR` | 设置段描述符 |
| `VM_SET_REGISTER` / `VM_GET_REGISTER` | 设置/获取寄存器 |
| `VM_ACTIVATE_CPU` | 激活 CPU |
| `VM_RUN` | 运行 VCPU |
| `cap_enter()` | 进入 Capsicum 能力模式 |
| `cap_rights_limit()` | 限制 fd 权限 |
| `cap_ioctls_limit()` | 限制 ioctl 命令 |
| `sysctlbyname()` | 获取/设置内核参数 |

### 2.4 HVT Tender 的 OpenBSD 接口

| 接口 | 功能 |
|------|------|
| `open("/dev/vmm")` | 打开 vmm 控制设备 |
| `VMM_IOC_CREATE` | 创建 VM |
| `VMM_IOC_TERM` | 终止 VM |
| `VMM_IOC_MPROTECT_EPT` | 修改 EPT 保护 |
| `pledge()` | 系统调用限制 |
| `chroot()` | 切换根目录 |
| `getpwnam()` | 获取用户信息 |
| `setgroups()`, `setresgid()`, `setresuid()` | 权限降级 |

---

## 3. SPT Target — Seccomp 沙箱后端

### 3.1 SPT ABI（客户机 ↔ 宿主机接口）

SPT 不使用 hypercall，而是通过 **直接系统调用** 与 Linux 内核交互。

**启动信息结构**（`spt_boot_info`）：
```c
struct spt_boot_info {
    uint64_t mem_size;        // 内存大小
    uint64_t kernel_end;      // 内核结束地址
    const char *cmdline;      // 命令行参数
    const void *mft;          // 应用 Manifest
    int epollfd;              // epoll 文件描述符（用于 yield）
    int timerfd;              // timerfd（用于 yield）
};
```

### 3.2 SPT 允许的系统调用（Seccomp 白名单）

SPT 通过 seccomp-BPF 严格限制可用系统调用，仅允许以下调用：

| 系统调用 | 限制条件 | 用途 |
|----------|---------|------|
| `write` | fd == stdout | 控制台输出 |
| `exit_group` | 无限制 | 进程退出 |
| `epoll_pwait` | fd == epollfd | 等待 I/O 事件 |
| `timerfd_settime` | fd == timerfd | 设置定时器 |
| `clock_gettime` | clockid == CLOCK_MONOTONIC | 单调时钟 |
| `clock_gettime` | clockid == CLOCK_REALTIME | 墙上时钟 |
| `arch_prctl` | code == ARCH_SET_FS（仅 x86_64） | 设置 TLS |
| `read` | fd 匹配网络设备 fd | 网络接收 |
| `write` | fd 匹配网络设备 fd | 网络发送 |
| `pread64` | fd + size + offset 受限 | 块设备读取 |
| `pwrite64` | fd + size + offset 受限 | 块设备写入 |

### 3.3 SPT Tender 的 OS 接口依赖

| 接口 | 用途 |
|------|------|
| `syscall(__NR_memfd_create)` | 创建匿名内存文件（映射客户机内存） |
| `mmap(MAP_PRIVATE \| MAP_ANONYMOUS \| MAP_FIXED)` | 映射客户机内存到固定地址 |
| `mprotect()` | 设置内存页权限 |
| `prctl(PR_SET_NO_NEW_PRIVS)` | 禁止提权（seccomp 前置要求） |
| `seccomp_init()` / `seccomp_rule_add()` | 初始化 seccomp 过滤器 |
| `seccomp_export_bpf()` | 导出 BPF 程序 |
| `syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER)` | 加载 seccomp 过滤器 |
| `epoll_create1()` | 创建 epoll 实例 |
| `timerfd_create(CLOCK_MONOTONIC)` | 创建定时器 |
| `open()`, `read()`, `close()`, `fstat()` | ELF 文件加载 |
| `personality()` | 检查 READ_IMPLIES_EXEC |

### 3.4 SPT 各架构系统调用机制

| 架构 | 系统调用指令 | 说明 |
|------|-------------|------|
| x86_64 | `syscall` | 通过 syscall 指令 |
| aarch64 | `svc #0` | 通过 SVC 异常 |
| ppc64le | `sc` | 通过系统调用指令 |

---

## 4. VirtIO Target — 直接 VirtIO 设备访问

VirtIO Target 不使用 Tender，直接运行在支持 VirtIO 的 Hypervisor（QEMU, GCE 等）上。

### 4.1 PCI 配置空间访问

| I/O 端口/机制 | 功能 |
|--------------|------|
| `PCI_CONFIG_ADDR (0xCF8)` | PCI 配置地址端口 |
| `PCI_CONFIG_DATA (0xCFC)` | PCI 配置数据端口 |
| Vendor ID: `0x1af4` (Qumranet/VirtIO) | 设备识别 |
| BAR (Base Address Register) | I/O 映射 |

### 4.2 VirtIO 设备类型

| 设备 | 文件 | 功能 |
|------|------|------|
| VirtIO Net | `virtio_net.c` | 网络收发 |
| VirtIO Block | `virtio_blk.c` | 块设备读写 |

### 4.3 VirtQueue 操作

| 操作 | 功能 |
|------|------|
| `virtq_init_rings()` | 初始化描述符环 |
| `virtq_add_descriptor_chain()` | 添加描述符链 |
| `VIRTQ_PCI_QUEUE_NOTIFY` | 通知 host 有新 buffer |
| `VIRTQ_PCI_ISR` | 读取中断状态 |
| `virtio_wmb/rmb/mb` | 内存屏障 |

---

## 5. Xen Target — Xen PVHv2 ABI

### 5.1 Xen Hypercall

| Hypercall | 功能 |
|-----------|------|
| `__HYPERVISOR_memory_op` (`XENMEM_add_to_physmap`) | 映射 shared_info 页 |
| `__HYPERVISOR_sched_op` (`SCHEDOP_shutdown`) | 关闭 VM |
| `__HYPERVISOR_sched_op` (`SCHEDOP_yield`) | 让出 CPU |
| `__HYPERVISOR_hvm_op` (`HVMOP_get_param/set_param`) | 获取/设置 HVM 参数 |
| `__HYPERVISOR_hvm_op` (`HVMOP_set_evtchn_upcall_vector`) | 设置事件通道向量 |
| `__HYPERVISOR_set_timer_op` | 设置定时器 |
| `__HYPERVISOR_event_channel_op` | 事件通道管理 |

### 5.2 事件通道操作

| 操作 | 功能 |
|------|------|
| `evtchn_bind_virq()` | 绑定虚拟中断 |
| `evtchn_send()` | 发送事件 |
| `evtchn_mask()` / `evtchn_unmask()` | 屏蔽/解除屏蔽事件 |

### 5.3 共享数据结构

| 结构 | 功能 |
|------|------|
| `struct shared_info` | Hypervisor-Guest 共享信息 |
| `struct vcpu_info` | 每 VCPU 信息 |
| `evtchn_pending[]` / `evtchn_mask[]` | 事件通道状态位图 |

---

## 6. Muen Target — Muen 分离内核

### 6.1 通信接口

| 接口 | 功能 |
|------|------|
| `muchannel` (SHMStream v2) | 共享内存通道协议 |
| `muen_channel_is_active()` | 检查通道状态 |
| 读写通道分离 | 输入/输出使用独立通道 |

### 6.2 特点

- 无 hypercall，纯共享内存通信
- TSC 时钟服务（带 epoch 偏移）
- 网络包大小：1514 字节
- 使用 `MUENNET_PROTO` (0x7ade5c549b08e814) 协议标识

---

## 7. 公共基础设施

### 7.1 网络设备（TAP）接口

| 函数/接口 | 用途 |
|-----------|------|
| `tap_attach()` | 附加到 TAP 网络接口 |
| `ioctl(TUNSETIFF, IFF_TAP \| IFF_NO_PI)` | 配置 TAP 设备 |
| `ioctl(SIOCGIFMTU)` | 获取 MTU |
| `ioctl(ETHTOOL_SGRO/ETHTOOL_SGSO)` | 禁用 GRO/GSO |
| `tap_attach_genmac()` | 生成随机 MAC（读取 `/dev/urandom`） |

### 7.2 块设备接口

| 函数/接口 | 用途 |
|-----------|------|
| `block_attach()` | 打开块设备/文件 |
| `open(O_RDWR)` | 以读写方式打开 |
| `lseek(SEEK_END)` | 获取设备容量 |

### 7.3 ELF 加载

| 函数/接口 | 用途 |
|-----------|------|
| `elf_load()` | 加载 ELF 到客户机内存 |
| `elf_load_note()` | 加载 ELF NOTE（Manifest） |
| `pread()` | 按 segment 读取 ELF 文件 |
| `mprotect()` | 设置 segment 内存保护 |

---

## 8. 接口依赖总结

### 按功能分类的接口依赖图

```
Solo5 对 OS/Hypervisor 的接口依赖
│
├── 虚拟化管理（HVT on Linux）
│   ├── /dev/kvm 设备
│   ├── 20+ KVM ioctl 命令
│   └── KVM_RUN VM Exit 处理
│
├── 进程沙箱（SPT）
│   ├── seccomp-BPF 过滤器
│   ├── memfd_create
│   ├── prctl(PR_SET_NO_NEW_PRIVS)
│   └── 11 个白名单系统调用
│
├── 内存管理
│   ├── mmap (MAP_ANONYMOUS | MAP_FIXED | MAP_PRIVATE)
│   ├── mprotect (PROT_READ | PROT_WRITE | PROT_EXEC)
│   ├── munmap, madvise
│   └── brk (glibc 内部)
│
├── 网络 I/O
│   ├── TAP 设备 (TUNSETIFF)
│   ├── ioctl (SIOCGIFMTU, ETHTOOL_*)
│   └── read/write on tap fd
│
├── 块设备 I/O
│   ├── open, read, write, close
│   ├── pread64, pwrite64
│   └── lseek, fstat
│
├── 事件与定时
│   ├── epoll_create1, epoll_ctl, epoll_pwait
│   ├── timerfd_create, timerfd_settime
│   ├── clock_gettime (MONOTONIC, REALTIME)
│   └── eventfd (用于 KVM IOEventFD)
│
├── 信号处理
│   ├── sigaction (SIGINT, SIGTERM)
│   └── 信号掩码操作
│
├── 进程/权限管理
│   ├── exit_group
│   ├── personality
│   ├── setresuid/setresgid
│   └── chroot (OpenBSD)
│
├── VirtIO（直接设备访问）
│   ├── PCI 配置空间 (0xCF8/0xCFC)
│   ├── VirtQueue 环操作
│   └── 中断处理
│
├── Xen（PVHv2）
│   ├── 7 类 Hypercall
│   ├── 事件通道操作
│   └── shared_info 共享内存
│
└── Muen（分离内核）
    ├── SHMStream v2 共享内存通道
    └── TSC 时钟
```

### 接口数量统计

| Target | 宿主 OS | 核心接口类别 | 关键接口数量 |
|--------|---------|-------------|-------------|
| HVT | Linux | KVM ioctl | ~20 个 |
| HVT | FreeBSD | vmm ioctl + Capsicum | ~12 个 |
| HVT | OpenBSD | vmm ioctl + pledge | ~8 个 |
| SPT | Linux | seccomp + syscalls | 11 个白名单系统调用 |
| VirtIO | 通用 | PCI + VirtQueue | ~10 个操作 |
| Xen | Xen | Hypercall + evtchn | ~7 个 Hypercall |
| Muen | Muen | SHMStream 通道 | ~3 个操作 |
