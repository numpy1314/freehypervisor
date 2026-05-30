# bhyve 对 FreeBSD 接口依赖分析

> bhyve 是 FreeBSD 的原生 Hypervisor，由内核模块 vmm.ko 和用户态进程 bhyve(8) 共同构成。
> 本文档分析两者对 FreeBSD 14.x stable 的完整接口依赖。
> **源码版本**: FreeBSD stable/14, commit `47f4f76`, 2026-05-29

## 架构概览

```
bhyve(8) 用户态进程                    (设备模拟, 固件加载, PCI 直通)
    |
    |--- libvmmapi (封装 /dev/vmm ioctl)
    |
    v
/dev/vmm/<vmname>                       (设备节点, ioctl 接口)
    |
    v
vmm.ko 内核模块                         (VM 创建, vCPU 执行, 内存管理)
    |
    v
FreeBSD 内核子系统                      (pmap, vm_page, smp, intr, ...)
```

bhyve 的关键设计差异：
- **vmm.ko 在内核做核心虚拟化**（VM entry/exit, EPT/NPT, 中断注入），类似 KVM
- **bhyve(8) 在用户态做完整设备模拟**（AHCI, NVMe, virtio, XHCI, PCI 直通），类似 QEMU
- 两者通过 **libvmmapi** + **/dev/vmm** 设备节点 + **ioctl** 通信

---

## 1. 维度 1: 内存管理

### 1.1 vmm.ko 内核侧

#### `pmap_extract()` [L1] — 将 GPA 转换为 HPA
- **源码**: `sys/amd64/vmm/vmm_mem.c`
- **语义**: 通过 VM space 的 pmap 将 guest 物理地址 (GPA) 映射为宿主机物理地址 (HPA)。
- **调用上下文**: consumer — 在 EPT/NPT page fault 处理和 DMA 映射中调用
- **边界类型**: `kernel KPI`（FreeBSD pmap 子系统）
- **接口契约**: 输入 pmap + gpa；输出 hpa (vm_paddr_t)；返回 true 成功
- **hot path**: 是（EPT/NPT violation 处理）

#### `vm_page_wired()` [L1] — 检查页面是否已 wired
- **源码**: `sys/amd64/vmm/`
- **语义**: 验证 guest 内存页面已被 wired（锁定在内存中），防止被 page out。
- **边界类型**: `kernel KPI`（FreeBSD VM 子系统）
- **接口契约**: 输入 vm_page；返回 bool；wired 页面不会被 page daemon 回收
- **hot path**: 否（断言检查）

#### `malloc()` / `free()` [L1] — 内核内存分配
- **源码**: 广泛使用于整个 vmm.ko（vmx, svm, vioapic, vhpet, vrtc 等）
- **语义**: 通过 FreeBSD 内核 malloc 分配器（`M_VMX`, `M_SVM`, `M_VMM`, `M_AMDVI` 等 MALLOC_DEFINE 类型）分配/释放内存。
- **边界类型**: `kernel KPI`（FreeBSD 内核分配器）
- **接口契约**: `M_WAITOK`（可睡眠）/ `M_NOWAIT`（不可睡眠）/ `M_ZERO`；类型安全的 type 参数
- **hot path**: 否（主要在初始化路径）

#### `contigmalloc()` [L1] — 连续物理内存分配
- **语义**: 分配物理连续的宿主机页面（用于 EPT/NPT 页表、I/O 缓冲区等 DMA 区域）。
- **边界类型**: `kernel KPI`
- **hot path**: 否

#### `vm_memalloc()` [L2] — guest 内存段分配
- **语义**: bhyve 内部封装，为 guest 分配和 wired 内存段。
- **边界类型**: `kernel KPI`（内部）
- **横切标签**: host 资源

### 1.2 bhyve(8) 用户态侧

#### `mmap()` [L1] — 映射 guest 内存
- **源码**: `lib/libvmmapi/vmmapi.c:239-470` — `vm_mmap_memseg()`, `vm_setup_memory()`
- **语义**: 通过 `VM_MMAP_MEMSEG` ioctl 将 guest 物理内存段映射到 bhyve 进程地址空间。支持 `VM_MMAP_ALL` 和 `VM_MMAP_SPARSE` 两种模式。
- **调用上下文**: consumer — VM 初始化时调用（通过 libvmmapi）
- **边界类型**: `vmm ioctl`（通过 libvmmapi 封装）
- **接口契约**: 4MB guard page 防止 guest 物理地址 0 访问；支持 `VM_MEM_F_WIRED`（wired）和 `VM_MEM_F_INCORE`（core dump 包含）
- **hot path**: 否

#### `VM_ALLOC_MEMSEG` [L1] — 分配内存段
- **源码**: `lib/libvmmapi/vmmapi.c:373`
- **语义**: 通过 ioctl 在 vmm.ko 中分配 guest 内存段。
- **边界类型**: `vmm ioctl`
- **hot path**: 否

---

## 2. 维度 2: vCPU 管理

### 2.1 vmm.ko 内核侧

#### `vmx_init()` / `svm_init()` [L1] — 硬件虚拟化初始化
- **源码**: `sys/amd64/vmm/intel/vmx.c`, `sys/amd64/vmm/amd/svm.c`
- **语义**: 初始化 Intel VMX 或 AMD SVM 硬件虚拟化。设置 VMXON region / 启用 SVM，在 `/dev/vmm` 设备首次打开时调用。
- **边界类型**: `kernel KPI`（通过 `kvm_x86_ops` 模式的结构体）
- **接口契约**: 输入 `pmap_t`（宿主机内核 pmap）；返回 0 成功 / errno
- **hot path**: 否

#### VM entry/exit [L1]
- **源码**: `sys/amd64/vmm/intel/vmx.c` (VMX), `sys/amd64/vmm/amd/svm.c` (SVM)
- **语义**: x86 VM entry (VMLAUNCH/VMRESUME / VMRUN) 和 VM exit 处理。EPT/NPT violation、I/O 拦截、MSR 拦截等由内核直接处理。
- **边界类型**: `kernel KPI`（直接操作硬件）
- **hot path**: 是

#### `make_dev()` / `destroy_dev()` [L1] — 创建设备节点
- **语义**: 创建 `/dev/vmm` 和 `/dev/vmm/<vmname>` 设备节点，供用户态 bhyve(8) 通过 open/ioctl 访问。
- **边界类型**: `kernel KPI`（FreeBSD devfs 子系统）
- **接口契约**: 通过 `struct cdevsw` 定义 ioctl 处理函数表
- **横切标签**: fd/device node

#### `sysctl_ctx_init()` / `sysctl` [L2]
- **语义**: 注册 vmm sysctl 节点（如 `hw.vmm.*`），导出统计和调试信息。
- **边界类型**: `kernel KPI`
- **横切标签**: 可观测性

### 2.2 bhyve(8) 用户态侧（通过 libvmmapi）

#### `vm_create()` / `vm_open()` [L1]
- **源码**: `lib/libvmmapi/vmmapi.c:105-128`
- **语义**: 创建/打开 VM。`vm_create()` 通过 `/dev/vmm/<name>` 设备节点创建新 VM 实例；`vm_open()` 打开已有 VM。
- **边界类型**: `syscall`（`open("/dev/vmm/...", O_RDWR)`）
- **hot path**: 否

#### `VM_RUN` [L1] — 执行 vCPU
- **源码**: `lib/libvmmapi/vmmapi.c` — `vm_run()`, `usr.sbin/bhyve/bhyverun.c:512`
- **语义**: 通过 ioctl `VM_RUN` 进入 guest 执行。每次 VM exit 后返回，携带 `struct vm_run` 中的 exit 信息。
- **调用上下文**: consumer — bhyverun.c 的 `vm_loop()` 中每 vCPU 线程的主循环
- **边界类型**: `vmm ioctl`
- **接口契约**: 输入 `struct vm_run`（含 vcpu id）；返回 `vm_exitcode`：正常 exit、MMIO/PIO/INOUT 访问、HALT、PAUSE、DEBUG、EXCEPTION 等
- **hot path**: 是

#### `VM_SET_REGISTER` / `VM_GET_REGISTER` [L1]
- **语义**: 设置/获取 vCPU 寄存器（通用寄存器、控制寄存器、MSR 等）。
- **边界类型**: `vmm ioctl`

#### `VM_SET_SEGMENT_DESCRIPTOR` / `VM_GET_SEGMENT_DESCRIPTOR` [L1]
- **语义**: 设置/获取 vCPU 段描述符（CS/DS/SS/ES/FS/GS + GDTR/LDTR/IDTR/TR）。
- **边界类型**: `vmm ioctl`

#### `VM_SET_CAPABILITY` / `VM_GET_CAPABILITY` [L1]
- **语义**: 设置/查询 VM 能力（如 halted exit、pause exit、x2apic state 等）。
- **边界类型**: `vmm ioctl`

#### `VM_ACTIVATE_CPU` [L1]
- **语义**: 激活 vCPU，使其可以进入 guest 模式。
- **边界类型**: `vmm ioctl`

#### `VM_INJECT_EXCEPTION` [L1]
- **语义**: 向 guest 注入异常（page fault, GP fault 等）。
- **边界类型**: `vmm ioctl`

#### `VM_RESTART_INSTRUCTION` [L1]
- **语义**: 重新执行上次导致 VM exit 的指令（用于 MMIO/PIO 模拟后恢复执行）。
- **边界类型**: `vmm ioctl`

#### `VM_SET_INTINFO` / `VM_GET_INTINFO` [L1]
- **语义**: 设置/获取中断注入信息。
- **边界类型**: `vmm ioctl`

---

## 3. 维度 3: I/O 模型

> bhyve(8) 做全量设备模拟，包括 AHCI、NVMe、virtio、XHCI 等。vmm.ko 仅处理 I/O 指令拦截和分发。

### 3.1 vmm.ko I/O 资源访问 [子维度 3a]

#### `vm_copyin()` / `vm_copyout()` [L1]
- **语义**: 在 vmm.ko 中从 userland 拷贝数据到内核或反之。用于 VM 初始化和 snapshot。
- **边界类型**: `kernel KPI`（FreeBSD kernel 内部）

#### I/O 端口拦截 [L2]
- **源码**: `sys/amd64/vmm/vmm_ioport.c`
- **语义**: vmm.ko 拦截 guest IN/OUT 指令，将 PIO 请求传递给用户态 bhyve(8)（通过 VM exit）。
- **边界类型**: `kernel KPI`

### 3.2 bhyve(8) 设备模拟 [子维度 3b]

#### AHCI (SATA) 控制器 [L1]
- **源码**: `usr.sbin/bhyve/ahci.h`, `usr.sbin/bhyve/pci_ahci.c`
- **语义**: 完整 AHCI 控制器模拟。通过 `pwrite()`/`pread()` 访问宿主机块设备文件。
- **边界类型**: `syscall`（open/pread/pwrite/ioctl on block device fd）
- **横切标签**: host 资源

#### NVMe 控制器 [L1]
- **源码**: `usr.sbin/bhyve/pci_nvme.c`
- **语义**: NVMe 1.4 控制器模拟。高性能块设备后端。
- **边界类型**: `syscall`
- **横切标签**: host 资源

#### virtio 设备 [L1]
- **源码**: `usr.sbin/bhyve/virtio.c`, `pci_virtio_*.c`
- **语义**: virtio 框架加上具体设备：virtio-block、virtio-net（通过 tap/vmnet 后端）、virtio-console、virtio-rnd、virtio-scsi、virtio-input、virtio-gpu。
- **边界类型**: `syscall`（设备 fd 操作）/ `vmm ioctl`（MSI-X 中断路由）
- **横切标签**: host 资源

#### TAP 网络 [L1]
- **源码**: `usr.sbin/bhyve/net_backends.c`
- **语义**: 打开 `/dev/tapN` 设备，通过 `TAPGIFNAME` ioctl 绑定网络接口。
- **边界类型**: `syscall`（open/ioctl on /dev/tapN）
- **横切标签**: host 资源

#### PCI 直通 (PPT) [L1]
- **源码**: `usr.sbin/bhyve/pci_passthru.c`, `sys/amd64/vmm/io/ppt.c`
- **语义**: 将宿主机 PCI 设备直通给 guest。用户态通过 `VM_BIND_PPTDEV`/`VM_UNBIND_PPTDEV` ioctl 绑定/解绑，内核态通过 `ppt.c` 管理 IOMMU 映射。
- **边界类型**: `vmm ioctl`（bind/unbind）/ `syscall`（open/ioctl/mmap on /dev/pptN）
- **横切标签**: PCI/IOMMU/DMA

#### Framebuffer (VNC) [L1]
- **源码**: `usr.sbin/bhyve/framebuffer.c`
- **语义**: 通过 `VM_MMAP_MEMSEG` 映射 guest framebuffer 内存，VNC server 通过网络提供显示。
- **边界类型**: `vmm ioctl`（mmap memseg）/ `syscall`（socket/bind/listen/accept for VNC）

#### Xen/SLIRP 用户态网络 [L2]
- **源码**: `usr.sbin/bhyve/net_backend_slirp.c`, `net_backend_netmap.c`
- **边界类型**: `syscall`

---

## 4. 维度 4: 中断与事件

### 4.1 vmm.ko 内核侧

#### LAPIC 模拟 [L1]
- **源码**: `sys/amd64/vmm/vmm_lapic.c`
- **语义**: vmm.ko 在内核模拟 local APIC。处理 APIC 寄存器访问、中断优先级、APIC timer。
- **边界类型**: `kernel KPI`
- **接口契约**: 通过 vmm_dev.c 暴露 ioctl：`VM_LAPIC_IRQ`, `VM_LAPIC_LOCAL_IRQ`, `VM_LAPIC_MSI`, `VM_IOAPIC_ASSERT_IRQ` 等
- **hot path**: 否

#### IOAPIC 模拟 [L1]
- **源码**: `sys/amd64/vmm/io/vioapic.c`
- **语义**: I/O APIC 模拟，管理 24 个 IRQ 输入线的重定向。
- **边界类型**: `kernel KPI`

#### HPET 模拟 [L1]
- **源码**: `sys/amd64/vmm/io/vhpet.c`
- **语义**: 高精度事件定时器模拟。使用 FreeBSD 内核 `callout` 机制驱动定时器。
- **边界类型**: `kernel KPI`

#### RTC 模拟 [L1]
- **源码**: `sys/amd64/vmm/io/vrtc.c`
- **语义**: 实时时钟模拟。为 guest 提供时间基准和周期中断。
- **边界类型**: `kernel KPI`

#### `callout_reset()` / `callout_drain()` [L1] — 内核定时器
- **语义**: vmm.ko 使用 FreeBSD callout 机制驱动虚拟定时器设备（HPET, RTC, APIC timer）。
- **边界类型**: `kernel KPI`（FreeBSD callout 子系统）
- **hot path**: 否

#### `intr_*` 中断框架 [L1]
- **语义**: 注册中断处理（如 AMD AVIC 中使用 `intr_add_handler`）。
- **边界类型**: `kernel KPI`（FreeBSD 中断子系统）

### 4.2 bhyve(8) 用户态侧

#### MSI/MSI-X 中断 [L1]
- **语义**: bhyve 用户态通过 libvmmapi 的 `vm_lapic_msi()` 向 guest 注入 MSI/MSI-X 中断。virtio 设备广泛使用。
- **边界类型**: `vmm ioctl`

#### `kqueue()` / `kevent()` [L1] — 事件通知
- **语义**: bhyve(8) 使用 FreeBSD kqueue 进行事件驱动 I/O。kevent 监控设备 fd、信号等。
- **边界类型**: `syscall`

---

## 5. 维度 5: 时钟与定时器

#### TSC 虚拟化 [L1]
- **语义**: vmm.ko 利用硬件 TSC offsetting (VMX) / TSC ratio (SVM) 进行 guest TSC 虚拟化，无需软件模拟。
- **边界类型**: `kernel KPI`（直接硬件操作）

#### `callout` 定时器框架 [L1]
- **语义**: vmm.ko 使用 FreeBSD `callout_*` API 驱动 HPET/RTC/APIC timer 模拟。
- **边界类型**: `kernel KPI`（FreeBSD 定时器子系统）
- **hot path**: 否

#### `clock_gettime()` [L1]
- **语义**: bhyve(8) 用户态获取宿主机时间，用于 RTC 同步等。
- **边界类型**: `syscall`

---

## 6. 维度 6: 调度与同步

### 6.1 vmm.ko 内核侧

#### `smp_rendezvous()` [L1] — 跨 CPU 同步
- **语义**: 在多个 CPU 上同步执行操作（如 TLB shootdown、虚拟化特性全局修改）。
- **边界类型**: `kernel KPI`（FreeBSD SMP 子系统）
- **接口契约**: 在所有目标 CPU 上执行 setup/action/teardown 函数
- **hot path**: 否

#### `mutex` / `sx` / `rw` lock [L1] — 内核锁
- **语义**: vmm.ko 广泛使用 FreeBSD 内核锁原语。`mtx_lock/unlock`（spin/sleep mutex）、`sx_xlock/sx_slock`（shared/exclusive）、`rw_rlock/rw_wlock`。
- **边界类型**: `kernel KPI`（FreeBSD lock 子系统）
- **hot path**: 是（VM entry/exit 路径使用锁保护 vCPU 状态）

#### `taskqueue_create()` / `taskqueue_enqueue()` [L2]
- **语义**: 延迟执行内核工作（如 vmm stat 更新）。
- **边界类型**: `kernel KPI`

### 6.2 bhyve(8) 用户态侧

#### `pthread_create()` [L1] — vCPU 线程
- **源码**: `usr.sbin/bhyve/bhyverun.c:458`
- **语义**: 每个 vCPU 创建独立线程。线程 pin 到指定 host CPU core。
- **边界类型**: `syscall`
- **hot path**: 否（初始化）

#### `cpuset_setaffinity()` [L1]
- **语义**: 将 vCPU 线程绑定到特定物理 CPU，与 FreeBSD cpuset 集成。
- **边界类型**: `syscall`

#### `pthread_mutex` / `pthread_cond` [L2]
- **语义**: bhyve(8) 设备模拟线程的同步。
- **边界类型**: `syscall`（futex 等效的 _umtx_op）

---

## 7. 维度 7: 安全与隔离

### 7.1 vmm.ko 内核侧

#### `priv_check()` [L1] — 权限检查
- **语义**: 检查调用进程是否有权限操作 `/dev/vmm`。需要 `PRIV_VM_*` 权限。
- **边界类型**: `kernel KPI`（FreeBSD priv 子系统）
- **接口契约**: 返回 0 允许 / `EPERM` 拒绝

#### `uma_zalloc()` / `uma_zfree()` [L2]
- **语义**: 使用 FreeBSD UMA (Universal Memory Allocator) 进行高性能内存分配（如 vCPU 结构体）。
- **边界类型**: `kernel KPI`

### 7.2 bhyve(8) 用户态侧

#### Capsicum sandbox [L1]
- **源码**: `usr.sbin/bhyve/bhyverun.c` — `cap_enter()`, 各设备文件 `cap_rights_limit()`/`cap_ioctls_limit()`
- **语义**: bhyve(8) 在初始化完成后进入 Capsicum capability mode。所有后续文件操作被限制为已声明的 rights 和 ioctl 白名单。
- **调用上下文**: consumer — 在打开所有设备和 fork vCPU 线程后调用
- **边界类型**: `syscall`（`cap_enter` / `cap_rights_limit` / `cap_ioctls_limit`）
- **接口契约**: capsicum mode 后禁止隐式权限获取（不能 open 新文件）；每个 fd 有显式的 rights mask
- **hot path**: 否（初始化完成后一次性操作）

#### `jail` 集成 [L2]
- **语义**: bhyve 可运行在 FreeBSD jail 中（通过 `allow.vmm` jail 参数）。
- **边界类型**: `syscall`（jail 参数配置）
- **接口契约**: 需要 `allow.vmm` 内核参数；VM 内存限制由 jail 资源限制控制

---

## vmm ioctl 命令完整列表

| ioctl 命令 | 用途 | 分类 |
|-----------|------|------|
| `VM_RUN` | 执行 vCPU | vCPU |
| `VM_SET_REGISTER` / `VM_GET_REGISTER` | 通用/控制寄存器 | vCPU |
| `VM_SET_SEGMENT_DESCRIPTOR` / `VM_GET_SEGMENT_DESCRIPTOR` | 段描述符 | vCPU |
| `VM_SET_REGISTER_SET` / `VM_GET_REGISTER_SET` | 批量寄存器 | vCPU |
| `VM_SET_CAPABILITY` / `VM_GET_CAPABILITY` | VM 能力 | vCPU |
| `VM_ACTIVATE_CPU` | 激活 vCPU | vCPU |
| `VM_INJECT_EXCEPTION` | 注入异常 | 中断 |
| `VM_SET_INTINFO` / `VM_GET_INTINFO` | 中断信息 | 中断 |
| `VM_RESTART_INSTRUCTION` | 重新执行指令 | vCPU |
| `VM_SET_X2APIC_STATE` | x2APIC 状态 | 中断 |
| `VM_ALLOC_MEMSEG` | 分配内存段 | 内存 |
| `VM_GET_MEMSEG` | 查询内存段 | 内存 |
| `VM_MMAP_MEMSEG` | 映射内存段 | 内存 |
| `VM_MUNMAP_MEMSEG` | 取消映射 | 内存 |
| `VM_MMAP_GETNEXT` | 遍历映射 | 内存 |
| `VM_BIND_PPTDEV` / `VM_UNBIND_PPTDEV` | PCI 直通 | I/O |
| `VM_REINIT` | 重新初始化 vCPU | vCPU |
| `VM_STATS` | 获取统计信息 | 可观测 |
| `VM_SNAPSHOT_REQ` | 快照请求 | 管理 |
| `VM_SET_KERNEMU_DEV` | 内核模拟设备 | vCPU |
| `VM_GET_KERNEMU_DEV` | 内核模拟设备 | vCPU |
| `VM_SUSPEND_CPU` | 挂起 vCPU | 调度 |
| `VM_RESUME_CPU` | 恢复 vCPU | 调度 |
| `VM_GET_CPUS` | 获取活跃 CPU 集合 | 调度 |

**统计**: bhyve 使用约 **25** 个 vmm ioctl 命令。

---

## 接口统计

### vmm.ko 内核侧

| FreeBSD 内核子系统 | 关键接口 | 用途 |
|-------------------|---------|------|
| pmap | `pmap_extract`, `pmap_*` | GPA→HPA 转换 |
| VM | `vm_page_wired`, `vm_page_*` | 内存 wired |
| malloc | `malloc/free/contigmalloc` | 内存分配 |
| smp | `smp_rendezvous` | 跨 CPU 同步 |
| intr | `intr_add_handler` 等 | 中断处理 |
| callout | `callout_reset/drain` | 定时器 |
| lock | `mtx/sx/rw_lock` | 并发保护 |
| priv | `priv_check` | 权限验证 |
| devfs | `make_dev/destroy_dev` | 设备节点 |
| sysctl | `sysctl_ctx_init` | 可观测性 |
| proc | `kproc_create` | 内核线程 |

### bhyve(8) 用户态侧

| 接口类别 | 关键接口 | 数量 |
|---------|---------|------|
| vmm ioctl（通过 libvmmapi） | `VM_RUN`, `VM_SET/GET_*`, `VM_ALLOC_*`, `VM_MMAP_*` 等 | ~25 |
| syscall: 内存 | `mmap`, `munmap`, `mprotect` | 3+ |
| syscall: 文件 | `open`, `close`, `read`, `write`, `pread`, `pwrite`, `ioctl` | 7+ |
| syscall: 网络 | `socket`, `bind`, `listen`, `accept` | 4+ |
| syscall: 线程 | `pthread_create`, `pthread_join`, `cpuset_setaffinity` | 3+ |
| syscall: 事件 | `kqueue`, `kevent` | 2+ |
| syscall: 时钟 | `clock_gettime` | 1+ |
| syscall: 安全 | `cap_enter`, `cap_rights_limit`, `cap_ioctls_limit` | 3+ |
| syscall: 其他 | `sigaction`, `fork`, `exec`, `setrlimit` | 4+ |

**总计**: vmm.ko ~11 FreeBSD 内核子系统依赖 | bhyve(8) ~25 vmm ioctl + ~27+ syscall 类别

---

## 与 KVM 的关键差异

| 方面 | KVM (Linux) | bhyve (FreeBSD) |
|------|------------|-----------------|
| 设备模型 | KVM 内核不模拟设备，I/O 分发到 QEMU | vmm.ko 在内核模拟 LAPIC/IOAPIC/HPET/RTC；其他设备在 bhyve(8) |
| 中断控制器 | LAPIC + IOAPIC 可选内核/用户态 | LAPIC + IOAPIC 固定在内核 |
| 页面锁定 | `pin_user_pages_fast()` (GUP) | `vm_page_wired()` | 
| 沙箱 | seccomp (Linux) | Capsicum (FreeBSD) |
| 设备节点 | `/dev/kvm` (单节点) | `/dev/vmm/<name>` (每 VM 一个节点) |
| 内存映射 | `KVM_SET_USER_MEMORY_REGION` | `VM_ALLOC_MEMSEG` + `VM_MMAP_MEMSEG` | 
| vCPU 线程 | `KVM_RUN` ioctl + 信号 | `VM_RUN` ioctl | 
| PCI 直通 | VFIO (`/dev/vfio/`) | PPT (`/dev/pptN` + `VM_BIND_PPTDEV`) |

## 源码参考

| 层次 | 关键文件 |
|------|---------|
| vmm.ko — VM 核心 | `sys/amd64/vmm/vmm.c`, `vmm_dev.c`, `vmm_mem.c`, `vmm_lapic.c` |
| vmm.ko — Intel VMX | `sys/amd64/vmm/intel/vmx.c`, `ept.c` |
| vmm.ko — AMD SVM | `sys/amd64/vmm/amd/svm.c`, `npt.c`, `amdv.c` |
| vmm.ko — I/O 设备 | `sys/amd64/vmm/io/vioapic.c`, `vhpet.c`, `vatpic.c`, `vrtc.c` |
| vmm.ko — PCI 直通 | `sys/amd64/vmm/io/ppt.c`, `iommu.h` |
| libvmmapi | `lib/libvmmapi/vmmapi.c`, `vmmapi.h` |
| bhyve(8) — 主程序 | `usr.sbin/bhyve/bhyverun.c` |
| bhyve(8) — 设备模拟 | `usr.sbin/bhyve/pci_ahci.c`, `pci_nvme.c`, `virtio.c`, `pci_passthru.c` |
| bhyve(8) — 网络 | `usr.sbin/bhyve/net_backends.c` |
