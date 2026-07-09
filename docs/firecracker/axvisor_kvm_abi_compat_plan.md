# AxVisor 对齐 Firecracker/KVM ABI 适配方案

## 1. 结论

要让未修改的 Firecracker 运行在 AxVisor 之上，必须在 Linux 侧提供一个 KVM UAPI 兼容层。这个兼容层的职责不是替换现有 26 个 AxVisor Linux host glue 函数，而是实现 Firecracker 依赖的 `/dev/kvm` 文件对象、`ioctl`、`mmap(struct kvm_run)` 和 fd 生命周期语义。

目标架构：

```text
Firecracker
  -> open/ioctl/mmap /dev/kvm
  -> AxVisor KVM ABI compatibility layer
  -> AxVisor VM/vCPU/provider backend
  -> hardware virtualization
```

当前已经验证的 RISC-V Linux-host AxVisor 路径说明 AxVisor 可以在 Linux 内核中运行并启动 Linux guest，但这条路径不是 Firecracker 兼容路径。未修改 Firecracker 只支持 `x86_64` 和 `aarch64`，因此 Firecracker 适配目标必须选择 `x86_64` 或 `aarch64`。如果坚持 RISC-V，需要先移植 Firecracker 本身，这不是 KVM ABI 兼容层能解决的问题。

### 1.1 2026-07-01 阶段边界冻结

当前实现阶段只验收 `x86_64 + 单 vCPU + initramfs-only Linux guest + 未修改 Firecracker`。`/dev/kvm` 必须由 `axvisor_kvm.ko` 提供，不能复用 Linux 原生 KVM。

第一阶段不挂 virtio-blk/virtio-net，但未修改 Firecracker x86_64 在创建 microVM 前会硬性检查 `KVM_CAP_IOEVENTFD` 和 `KVM_CAP_IRQFD`。因此这两个 capability 必须作为第一阶段最小 ABI 的一部分广告，并提供基础注册/注销/触发语义；只是不要求完成 virtio-blk/net 设备闭环。

## 2. 范围边界

### 2.1 必须做

- 提供真实 `/dev/kvm` ABI，支持 `open("/dev/kvm")`。
- 实现 KVM 全局 fd、VM fd、vCPU fd 三类对象。
- 实现 vCPU fd 的 `mmap`，让 Firecracker 能映射并读写 `struct kvm_run`。
- 把 `KVM_RUN` 翻译到 AxVisor vCPU 执行入口。
- 把 AxVisor VM exit 翻译成 KVM exit reason。
- 实现 Firecracker 启动 Linux microVM 所需的 x86_64 或 aarch64 架构 ioctl。
- 第一阶段只实现 initramfs-only 启动所需的最小 KVM ABI；`KVM_IOEVENTFD` 和 `KVM_IRQFD` 因 Firecracker required caps 必须保留，virtio-blk/net 设备闭环留到后续阶段。

### 2.2 不属于这层

- `eventfd`、`epoll`、`timerfd`、`pthread/clone`、`mmap`、`seccomp`、cgroup、namespace 是 Linux userspace runtime 能力，由 Linux 提供。
- TAP、block file、Unix socket、API socket 是 Firecracker 设备模型和 Linux host 资源，不是 AxVisor KVM provider 的核心职责。
- AxVisor 当前 26 个 host glue 函数服务于“AxVisor 在 Linux kernel 内运行”，不等价于 Firecracker 所需的 KVM UAPI。
- 调试期用 `/dev/axvisor-kvm` 可以降低冲突，但只要 Firecracker 仍需 patch 才能打开它，就不算完成 KVM ABI 对齐。

## 3. 当前证据

Firecracker 创建 VM 的真实路径：

```text
Vm::new()
  -> Kvm::new()
  -> KVM_GET_API_VERSION
  -> KVM_CHECK_EXTENSION for required caps
  -> KVM_CREATE_VM
  -> KVM_GET_SUPPORTED_CPUID on x86_64
  -> KVM_GET_MSR_INDEX_LIST on x86_64
```

Firecracker 注册 guest memory 的真实路径：

```text
GuestMemoryMmap::from_raw_regions()
  -> mmap anonymous/private memory
Vm::memory_init()
  -> KVM_SET_USER_MEMORY_REGION for each memslot
  -> KVM_SET_TSS_ADDR on x86_64
```

Firecracker 创建和启动 vCPU 的真实路径：

```text
KVM_CREATE_VCPU
  -> mmap(vcpu fd) to get struct kvm_run
  -> arch-specific vCPU setup
  -> KVM_RUN loop
  -> handle KVM_EXIT_MMIO/KVM_EXIT_IO/KVM_EXIT_HLT/KVM_EXIT_SHUTDOWN/KVM_EXIT_FAIL_ENTRY
```

Linux KVM 的对象模型是：

```text
/dev/kvm miscdevice
  -> KVM_CREATE_VM returns anon inode "kvm-vm" fd
  -> VM fd KVM_CREATE_VCPU returns anon inode "kvm-vcpu:<id>" fd
  -> vCPU fd mmap exposes struct kvm_run
  -> vCPU fd KVM_RUN enters guest
```

AxVisor 当前可复用的后端语义：

```text
AxVM::new()
AxVM::boot()
AxVM::map_region()
AxVM::unmap_region()
AxVM::run_vcpu()
AxVCpuExitReason::{MmioRead, MmioWrite, IoRead, IoWrite, Halt, SystemDown, FailEntry, ...}
```

当前缺口集中在 KVM UAPI 对象模型、userspace memory pin/map、架构寄存器 ioctl、irqfd/ioeventfd 和虚拟中断控制器语义。

## 4. 模块划分

推荐新增一个独立的 Linux kernel module 或 adapter 子模块：

```text
linux-host-kernel/drivers/virt/axvisor/
  axvisor_adapter.ko            # 现有 AxVisor Linux host adapter，保留
  axvisor_kvm.ko                # 新增 KVM ABI provider，推荐独立
```

推荐先独立为 `axvisor_kvm.ko`，原因：

- 不影响已验证的 RISC-V Linux-host smoke 路径。
- `/dev/kvm` 注册、anon inode、UAPI ioctl、userspace page pinning 都是 Linux KVM ABI 问题，和当前 `/proc/axvisor_shell` 控制路径不同。
- 可以独立做 KVM API smoke test，不需要每次启动完整 AxVisor shell。

内部对象建议：

```c
struct axkvm_dev {
    /* global provider state */
};

struct axkvm_vm {
    struct kref refcount;
    struct mutex lock;
    struct axvisor_vm_handle *backend;
    struct axkvm_memslot memslots[AXKVM_MAX_MEMSLOTS];
    struct axkvm_irqchip irqchip;
    struct axkvm_ioevent ioevents[AXKVM_MAX_IOEVENTS];
    struct axkvm_irqfd irqfds[AXKVM_MAX_IRQFDS];
};

struct axkvm_vcpu {
    struct kref refcount;
    struct mutex lock;
    struct axkvm_vm *vm;
    unsigned int id;
    struct kvm_run *run;
    struct page *run_page;
    struct axvisor_vcpu_handle *backend;
    sigset_t *sigmask;
};

struct axkvm_memslot {
    bool valid;
    u32 slot;
    u64 guest_phys_addr;
    u64 memory_size;
    u64 userspace_addr;
    u32 flags;
    struct page **pages;
    unsigned long nr_pages;
};
```

这里的 `axvisor_vm_handle` 和 `axvisor_vcpu_handle` 可以先是 C/Rust FFI 包装，后续再收敛成正式 `hv-provider-api`。

## 5. KVM UAPI 清单

### 5.1 `/dev/kvm` 全局 fd

| ioctl | Firecracker 用途 | 首阶段要求 | AxVisor 映射 |
|---|---|---:|---|
| `KVM_GET_API_VERSION` | `Kvm::new()` 校验版本 | 必须 | 返回 `KVM_API_VERSION` |
| `KVM_CHECK_EXTENSION` | 能力探测 | 必须 | 对已实现能力返回 1 或数量 |
| `KVM_GET_VCPU_MMAP_SIZE` | vCPU `kvm_run` mmap 大小 | 必须 | 返回至少 `PAGE_SIZE`，x86_64 可按 Linux KVM 返回额外 PIO/MMIO page |
| `KVM_CREATE_VM` | 创建 VM fd | 必须 | 分配 `axkvm_vm`，返回 anon inode fd |
| `KVM_GET_SUPPORTED_CPUID` | x86_64 CPU 模板 | x86_64 必须 | 返回可启动 Linux 的保守 CPUID |
| `KVM_GET_MSR_INDEX_LIST` | x86_64 MSR 列表 | x86_64 必须 | 返回 Firecracker 读写所需 MSR 子集 |

### 5.2 VM fd

| ioctl | Firecracker 用途 | 首阶段要求 | AxVisor 映射 |
|---|---|---:|---|
| `KVM_SET_USER_MEMORY_REGION` | 注册 guest RAM | 必须 | pin userspace pages，按 GPA 映射到 AxVisor address space |
| `KVM_CREATE_VCPU` | 创建 vCPU fd | 必须 | 创建 AxVisor vCPU backend，返回 anon inode fd |
| `KVM_CREATE_IRQCHIP` | x86_64 APIC/PIC/IOAPIC | x86_64 必须 | 建立最小 in-kernel irqchip 模型或桥接 AxVisor 中断控制器 |
| `KVM_CREATE_PIT2` | x86_64 早期时钟和 speaker dummy | x86_64 必须 | 可先实现 dummy PIT，加上 guest 启动所需时钟行为 |
| `KVM_SET_TSS_ADDR` | x86_64 保护模式 | x86_64 必须 | 保存 TSS 地址，必要时传给 x86 backend |
| `KVM_SET_IDENTITY_MAP_ADDR` | x86_64 identity map | x86_64 视启动路径需要 | 保存地址，先支持 Firecracker 传入语义 |
| `KVM_GET_CLOCK`/`KVM_SET_CLOCK` | snapshot/restore | 启动可延后 | 返回/保存 KVM clock 数据 |
| `KVM_GET_DIRTY_LOG`/`KVM_CLEAR_DIRTY_LOG` | snapshot diff | 启动可延后 | dirty bitmap 或返回不支持，取决于是否启用 snapshot |
| `KVM_IOEVENTFD` | Firecracker x86 required cap；virtio queue notify 热路径 | 必须 | 第一阶段支持注册/注销和 MMIO write signal；virtio-blk/net 完整闭环后续验证 |
| `KVM_IRQFD` | Firecracker x86 required cap；virtio interrupt 注入 | 必须 | 第一阶段支持注册/注销和 eventfd wakeup；virtio-blk/net 完整闭环后续验证 |
| `KVM_CREATE_DEVICE` | aarch64 VGIC | aarch64 必须 | 创建 VGIC device fd |

### 5.3 vCPU fd

| ioctl/mmap | Firecracker 用途 | 首阶段要求 | AxVisor 映射 |
|---|---|---:|---|
| `mmap(vcpu fd)` | 映射 `struct kvm_run` | 必须 | map `run_page` 到 userspace |
| `KVM_RUN` | 进入 guest | 必须 | 调 `AxVM::run_vcpu` 或 provider run 接口 |
| `KVM_SET_SIGNAL_MASK` | vCPU signal 行为 | 必须 | 保存 sigmask，`KVM_RUN` 前后应用或最小兼容 |
| `KVM_SET_REGS`/`KVM_GET_REGS` | x86_64 boot regs/snapshot | x86_64 必须 | 转换到 AxVisor x86 vCPU register API |
| `KVM_SET_SREGS`/`KVM_GET_SREGS` | x86_64 CR0/CR3/CR4/EFER/segments | x86_64 必须 | 转换到 AxVisor x86 vCPU control-register API |
| `KVM_SET_FPU`/`KVM_GET_FPU` | x86_64 FPU init | x86_64 必须 | 保存或下发到 backend |
| `KVM_SET_CPUID2`/`KVM_GET_CPUID2` | x86_64 CPU model | x86_64 必须 | 保存 CPUID，影响 guest CPUID exit/MSR |
| `KVM_SET_MSRS`/`KVM_GET_MSRS` | x86_64 syscall/MSR setup | x86_64 必须 | 保存/下发 EFER, STAR, LSTAR 等必要 MSR |
| `KVM_GET_LAPIC`/`KVM_SET_LAPIC` | x86_64 LINT 配置 | x86_64 必须 | 最小 LAPIC 状态模型 |
| `KVM_GET_MP_STATE`/`KVM_SET_MP_STATE` | vCPU 状态/snapshot | SMP 或 snapshot 必须 | 保存 runnable/stopped 状态 |
| `KVM_GET/SET_XSAVE`, `KVM_GET/SET_XCRS`, `KVM_GET/SET_VCPU_EVENTS`, `KVM_GET/SET_DEBUGREGS` | snapshot | 启动可延后 | 完整 snapshot 前实现 |
| `KVM_GET_ONE_REG`/`KVM_SET_ONE_REG` | aarch64 regs | aarch64 必须 | 转换到 AArch64 vCPU register API |
| `KVM_ARM_VCPU_INIT`/`KVM_ARM_PREFERRED_TARGET`/`KVM_ARM_VCPU_FINALIZE` | aarch64 vCPU init | aarch64 必须 | 建立 vCPU feature/init 状态 |

## 6. VM exit 翻译

`KVM_RUN` 的核心工作是运行 AxVisor vCPU，然后写入 `struct kvm_run`：

| AxVisor exit | KVM exit | `struct kvm_run` 字段 |
|---|---|---|
| `MmioRead { addr, width, ... }` | `KVM_EXIT_MMIO` | `mmio.phys_addr`, `mmio.len`, `mmio.is_write = 0` |
| `MmioWrite { addr, width, data }` | `KVM_EXIT_MMIO` | `mmio.phys_addr`, `mmio.data`, `mmio.len`, `mmio.is_write = 1` |
| `IoRead { port, width }` | `KVM_EXIT_IO` | `io.direction = KVM_EXIT_IO_IN`, `io.port`, `io.size`, `io.count`, `io.data_offset` |
| `IoWrite { port, width, data }` | `KVM_EXIT_IO` | `io.direction = KVM_EXIT_IO_OUT`, `io.port`, `io.size`, `io.count`, `io.data_offset` |
| `Halt` | `KVM_EXIT_HLT` | `exit_reason` |
| `SystemDown` | `KVM_EXIT_SHUTDOWN` 或 `KVM_EXIT_SYSTEM_EVENT` | 先用 Firecracker 已处理的 shutdown path |
| `FailEntry { hardware_entry_failure_reason }` | `KVM_EXIT_FAIL_ENTRY` | `fail_entry.hardware_entry_failure_reason` |
| backend error | `KVM_EXIT_INTERNAL_ERROR` | `internal.suberror`, `internal.ndata` |

MMIO read 的返回值语义必须补齐：Firecracker 处理 `KVM_EXIT_MMIO` 后会把读结果写回 `kvm_run.mmio.data`，下一次 `KVM_RUN` 必须把该数据提交回 guest 目标寄存器。AxVisor 当前 `MmioRead` 带有 `reg`、`reg_width`、`signed_ext`，compat layer 需要保存 pending read context：

```text
KVM_RUN returns MMIO read
  -> save pending {reg, width, reg_width, signed_ext}
Firecracker writes run->mmio.data
next KVM_RUN
  -> complete pending read into guest register
  -> enter guest again
```

PIO read 也需要同样的 pending completion 机制。

## 7. Guest memory 方案

KVM ABI 的 guest memory 是 userspace HVA 模型：

```text
Firecracker mmap() -> HVA
KVM_SET_USER_MEMORY_REGION(userspace_addr=HVA, guest_phys_addr=GPA)
KVM pins/translates HVA pages -> maps into guest stage-2/EPT/NPT
```

AxVisor 当前 Linux RISC-V 路径更多使用内核侧或保留物理内存模型。兼容 Firecracker 必须新增 HVA memslot 模型。

首阶段建议：

1. `KVM_SET_USER_MEMORY_REGION` 校验 `guest_phys_addr`、`memory_size`、`userspace_addr` 4K 对齐。
2. 使用 GUP/pin user pages 获取 `struct page **`。
3. 对每页取得 PFN/HPA。
4. 调 AxVisor backend 映射 `GPA + offset -> HPA`。
5. VM fd release 时 unmap 并 unpin pages。

约束：

- 首阶段只支持 `KVM_MEM_LOG_DIRTY_PAGES = 0` 的普通启动路径。
- snapshot/diff 启用后再实现 dirty bitmap。
- `MAP_HUGETLB` 可以先按普通页 pin/map，只要行为正确；性能优化后续再做 hugepage 映射合并。

## 8. irqfd/ioeventfd 方案

Firecracker 的 virtio-mmio 依赖两个 KVM eventfd 加速接口：

```text
KVM_IOEVENTFD:
  guest writes MMIO notify register
  -> kernel side signals queue eventfd
  -> Firecracker device thread handles queue

KVM_IRQFD:
  Firecracker writes interrupt eventfd
  -> kernel side injects GSI/IRQ into guest
```

首阶段可以按正确性优先实现：

- `KVM_IOEVENTFD` 注册 `{addr, len, datamatch, eventfd}`。
- AxVisor 发生 `MmioWrite` 时先匹配 ioeventfd 表。
- 命中后直接 signal eventfd，并继续 guest，不返回 `KVM_EXIT_MMIO` 给 Firecracker。
- 未命中时返回 `KVM_EXIT_MMIO`，由 Firecracker MMIO bus 处理。
- `KVM_IRQFD` 注册 `{gsi, eventfd}`，用 poll/waitqueue 监听 eventfd。
- eventfd 触发后调用 AxVisor interrupt injection API，把 GSI 映射成 guest IRQ。

这两个接口不是性能可选项。对 Firecracker 的 virtio block/net 启动路径来说，它们属于正确运行所需的核心 ABI。

## 9. 架构选择

### 9.1 x86_64 优先路线

x86_64 是更直接的 Firecracker 兼容目标，原因：

- Firecracker upstream 完整支持 x86_64。
- 不需要 aarch64 VGIC `KVM_CREATE_DEVICE` 路径。
- Linux KVM x86 UAPI 参考最完整。

必须补齐：

- `KVM_GET_SUPPORTED_CPUID`
- `KVM_GET_MSR_INDEX_LIST`
- `KVM_SET_CPUID2`/`KVM_GET_CPUID2`
- `KVM_SET_MSRS`/`KVM_GET_MSRS`
- `KVM_SET_REGS`/`KVM_GET_REGS`
- `KVM_SET_SREGS`/`KVM_GET_SREGS`
- `KVM_SET_FPU`
- `KVM_GET_LAPIC`/`KVM_SET_LAPIC`
- `KVM_CREATE_IRQCHIP`
- `KVM_CREATE_PIT2`
- `KVM_SET_TSS_ADDR`
- `KVM_GET_TSC_KHZ`，snapshot restore 前再做 `KVM_SET_TSC_KHZ`

当前 AxVisor Linux adapter 的 Makefile 是 RISC-V 专用。x86_64 路线还需要启用 AxVisor x86 backend feature，例如 `vmx` 或 `svm`，否则 `axvm/src/vcpu.rs` 会落到 `x86_no_backend`，`run()` 返回 unsupported。

### 9.2 aarch64 路线

aarch64 也能对齐 Firecracker，但必须支持 VGIC device API：

- `KVM_CAP_DEVICE_CTRL`
- `KVM_CREATE_DEVICE`
- device fd `KVM_SET_DEVICE_ATTR`
- device fd `KVM_GET_DEVICE_ATTR`
- `KVM_ARM_PREFERRED_TARGET`
- `KVM_ARM_VCPU_INIT`
- `KVM_ARM_VCPU_FINALIZE`
- `KVM_SET_ONE_REG`/`KVM_GET_ONE_REG`
- `KVM_GET_MP_STATE`/`KVM_SET_MP_STATE`

所以 aarch64 不比 x86_64 少做，只是寄存器模型不同。

## 10. 分阶段计划

### Phase 0: 目标锁定和冲突处理

交付物：

- 明确目标架构为 `x86_64` 或 `aarch64`，首选 `x86_64`。
- 确认测试 host 不加载 Linux 原生 `kvm.ko`，或者明确 dev 模式使用 `/dev/axvisor-kvm`。
- 明确最终验收必须是未修改 Firecracker 打开 `/dev/kvm`。

验收：

- `ls -l /dev/kvm` 指向 AxVisor provider。
- `KVM_GET_API_VERSION` 返回 Linux KVM API version。
- 如果 host 原生 KVM 存在，冲突处理策略写入 runbook。

### Phase 1: `/dev/kvm` ABI skeleton

交付物：

- 注册 miscdevice `/dev/kvm`。
- 实现全局 fd ioctl：
  - `KVM_GET_API_VERSION`
  - `KVM_CHECK_EXTENSION`
  - `KVM_GET_VCPU_MMAP_SIZE`
  - `KVM_CREATE_VM`
- 实现 VM fd anon inode 和 release。

验收：

- C smoke 程序能 `open("/dev/kvm")`。
- `KVM_GET_API_VERSION` 通过。
- `KVM_CREATE_VM` 返回 VM fd。
- Firecracker 能通过 `Kvm::new()` 和 `create_vm()`，失败点推进到下一个未实现 ioctl。

### Phase 2: VM memory memslot

交付物：

- 实现 `KVM_SET_USER_MEMORY_REGION`。
- 实现 userspace pages pin/unpin。
- 实现 GPA 到 HPA 的 AxVisor backend 映射。
- 支持 memslot delete，`memory_size = 0`。

验收：

- smoke 程序能 mmap 16 MiB userspace RAM 并注册到 VM。
- VM fd close 后 pages 全部 unpin。
- Firecracker 能完成 guest memory init。

### Phase 3: vCPU fd 和 `kvm_run`

交付物：

- 实现 `KVM_CREATE_VCPU`。
- 为每个 vCPU 分配 `struct kvm_run` page。
- 实现 vCPU fd `mmap`。
- 实现 `KVM_SET_SIGNAL_MASK`。
- 实现 `KVM_RUN` 基础状态机。

验收：

- smoke 程序能创建 vCPU 并 mmap `struct kvm_run`。
- `KVM_RUN` 在未配置完整 guest 时返回确定错误或 `KVM_EXIT_FAIL_ENTRY`，不 panic，不泄漏。

### Phase 4: x86_64 boot ioctl

交付物：

- 实现 x86_64 CPUID/MSR/regs/sregs/fpu/lapic/TSS/PIT/IRQCHIP 最小子集。
- CPUID 和 MSR 列表以“能启动 Linux + 满足 Firecracker 模板过滤”为准。
- `KVM_CREATE_IRQCHIP` 建立最小 APIC/PIC/IOAPIC 语义。
- `KVM_CREATE_PIT2` 至少支持 Firecracker 的 dummy speaker path。

验收：

- Firecracker 能完成 `create_vmm_and_vcpus()`。
- Firecracker 能完成 `configure_system_for_boot()`。
- vCPU 进入 `KVM_RUN`。

### Phase 5: MMIO/PIO exit 和 initramfs-only Firecracker

交付物：

- `AxVCpuExitReason` 到 `kvm_run.exit_reason` 的完整翻译。
- MMIO/PIO read pending completion。
- `KVM_IOEVENTFD` / `KVM_IRQFD` 基础 capability 和注册语义，因为未修改 Firecracker 在 initramfs-only 配置下仍检查它们。
- legacy serial/PIO exit 能被 Firecracker 处理。
- guest IRQ injection 到 AxVisor backend 的最小路径。

验收：

- Firecracker 能进入 `KVM_RUN`。
- initramfs-only Linux guest 能通过串口打印 pass marker。
- 第一阶段不要求 virtio-block 或 virtio-net，但要求 `KVM_IOEVENTFD`、`KVM_IRQFD` 通过 Firecracker required capability 检查。

### Phase 6: virtio rootfs guest

交付物：

- virtio-mmio notify 和 interrupt 注入路径的完整设备级验证。
- virtio-blk rootfs guest 验证。

验收：

- Firecracker 能看到 `KVM_EXIT_MMIO` 并处理 virtio-mmio config 访问。
- virtio queue notify 通过 ioeventfd 生效。
- virtio interrupt 通过 irqfd 注入。
- Linux guest 能挂载 virtio-block rootfs。

### Phase 7: Firecracker microVM 启动闭环

交付物：

- runbook：启动 AxVisor KVM provider、启动 Firecracker、配置 kernel/rootfs/cmdline。
- 最小 Linux guest 镜像和结果检查脚本。

验收：

- 未修改 Firecracker 二进制启动。
- guest kernel 打印 `VFS: Mounted root`。
- guest init 写出 smoke result。
- Firecracker 正常退出或保持 microVM running。

### Phase 8: snapshot 和生产能力

交付物：

- dirty log。
- x86_64 `GET/SET_XSAVE`、`GET/SET_XCRS`、`GET/SET_VCPU_EVENTS`、`GET/SET_DEBUGREGS`。
- `KVM_GET_CLOCK`/`KVM_SET_CLOCK` 完整语义。
- aarch64 GIC state save/restore，如果选择 aarch64。

验收：

- Firecracker snapshot create/load 通过。
- Pause/resume 通过。
- 多 vCPU 通过。

## 11. 关键风险和确定修复点

| 问题 | 根因 | 修复方向 |
|---|---|---|
| Firecracker 不能直接跑在当前 RISC-V Linux-host AxVisor 路径上 | Firecracker upstream 无 RISC-V arch 支持，且当前路径不是 `/dev/kvm` provider | 选择 x86_64/aarch64，新增 KVM ABI provider |
| 26 个 glue 函数不足以运行 Firecracker | 26 个接口是 OS substrate，不包含 KVM fd/ioctl/mmap UAPI | 新增 `/dev/kvm` compatibility layer |
| Firecracker guest memory 无法直接复用当前保留内存模型 | KVM ABI 使用 userspace HVA memslot | 实现 GUP/pin pages，再映射 GPA 到 HPA |
| `KVM_RUN` 不能只调用 AxVisor run 后返回 | KVM 还要求 `struct kvm_run` ABI 和 pending read completion | 实现 `kvm_run` page 和 exit completion 状态机 |
| virtio-mmio 卡住或性能极差 | Firecracker 依赖 irqfd/ioeventfd 做通知和中断 | 实现 `KVM_IOEVENTFD` 和 `KVM_IRQFD` |
| x86_64 backend 返回 unsupported | 当前 Linux adapter 构建路径是 RISC-V，x86 backend feature 未启用 | 新建 x86_64 provider 构建配置，启用 VMX/SVM backend |

## 12. 最小 ioctl 子集排序

按 Firecracker 启动路径排序，而不是按 Linux KVM 文档排序：

1. `KVM_GET_API_VERSION`
2. `KVM_CHECK_EXTENSION`
3. `KVM_GET_VCPU_MMAP_SIZE`
4. `KVM_CREATE_VM`
5. `KVM_GET_SUPPORTED_CPUID`，x86_64
6. `KVM_GET_MSR_INDEX_LIST`，x86_64
7. `KVM_SET_USER_MEMORY_REGION`
8. `KVM_SET_TSS_ADDR`，x86_64
9. `KVM_CREATE_IRQCHIP`，x86_64
10. `KVM_CREATE_PIT2`，x86_64
11. `KVM_CREATE_VCPU`
12. `mmap(vcpu fd)`
13. `KVM_SET_CPUID2`，x86_64
14. `KVM_SET_MSRS`/`KVM_GET_MSRS`，x86_64
15. `KVM_SET_REGS`/`KVM_GET_REGS`，x86_64
16. `KVM_SET_SREGS`/`KVM_GET_SREGS`，x86_64
17. `KVM_SET_FPU`，x86_64
18. `KVM_GET_LAPIC`/`KVM_SET_LAPIC`，x86_64
19. `KVM_SET_SIGNAL_MASK`
20. `KVM_IOEVENTFD`
21. `KVM_IRQFD`
22. `KVM_RUN`
23. `KVM_GET_CLOCK`/`KVM_SET_CLOCK`，snapshot 前必须
24. `KVM_GET_DIRTY_LOG`/`KVM_CLEAR_DIRTY_LOG`，snapshot 前必须

aarch64 替换项：

- 用 `KVM_CREATE_DEVICE`、device fd `KVM_SET_DEVICE_ATTR`、`KVM_GET_DEVICE_ATTR` 替换 x86_64 `CREATE_IRQCHIP/PIT2/LAPIC`。
- 用 `KVM_ARM_PREFERRED_TARGET`、`KVM_ARM_VCPU_INIT`、`KVM_ARM_VCPU_FINALIZE`、`KVM_GET_ONE_REG`、`KVM_SET_ONE_REG` 替换 x86_64 CPUID/MSR/regs/sregs/fpu 路径。

## 13. 第一批测试程序

建议先写四个小测试，比直接跑 Firecracker 更容易定位 ABI 问题。

### 13.1 `kvm_api_smoke`

验证：

- `open("/dev/kvm")`
- `KVM_GET_API_VERSION`
- `KVM_CHECK_EXTENSION(KVM_CAP_USER_MEMORY)`
- `KVM_GET_VCPU_MMAP_SIZE`
- `KVM_CREATE_VM`

### 13.2 `kvm_mem_vcpu_smoke`

验证：

- userspace `mmap`
- `KVM_SET_USER_MEMORY_REGION`
- `KVM_CREATE_VCPU`
- vCPU fd `mmap`
- close fd 后资源释放

### 13.3 `kvm_run_exit_smoke`

验证：

- 设置最小 vCPU 状态。
- `KVM_RUN` 能返回 `KVM_EXIT_MMIO` 或 `KVM_EXIT_HLT`。
- MMIO read completion 正确。
- `KVM_RUN` 遇到 `immediate_exit` 返回 `EINTR` 或等价可处理行为。

### 13.4 `axvisor-kvm-firecracker-init-smoke`

路径：

```text
tools/axvisor-kvm-firecracker-init-smoke.c
```

验证 Firecracker x86_64 cold-boot 初始化路径的 ABI 前半段：

- 默认 x86_64 capability 检查，包括 `IRQCHIP`、`USER_MEMORY`、`SET_TSS_ADDR`、`PIT2`、`PIT_STATE2`、`ADJUST_CLOCK`、`DEBUGREGS`、`MP_STATE`、`VCPU_EVENTS`、`XCRS`、`XSAVE`、`EXT_CPUID`。
- `KVM_CREATE_VM`。
- `KVM_GET_SUPPORTED_CPUID` 和 `KVM_GET_MSR_INDEX_LIST`。
- `KVM_SET_USER_MEMORY_REGION`。
- `KVM_SET_TSS_ADDR`、`KVM_CREATE_IRQCHIP`、`KVM_CREATE_PIT2`。
- 默认检查 `KVM_IOEVENTFD` 和 `KVM_IRQFD`，因为未修改 Firecracker x86_64 required caps 包含这两项。
- `KVM_CREATE_VCPU` 和 vCPU fd `mmap`。
- `KVM_SET_CPUID2`、Linux boot MSR entries、`KVM_SET_REGS`、`KVM_SET_FPU`、`KVM_GET_SREGS`/`KVM_SET_SREGS`、`KVM_GET_LAPIC`/`KVM_SET_LAPIC`、`KVM_SET_MP_STATE`。
- `KVM_RUN immediate_exit` 返回 `EINTR` 并保留 `immediate_exit` 字段。

这个测试不替代最终验收。它的用途是把未修改 Firecracker 的前半段 KVM ABI 需求变成一个可重复检查项。

Firecracker 验收应放在这些测试之后。

## 14. 实施建议

第一轮实现不要追求完整 KVM。目标应是让 Firecracker 的失败点按启动顺序向前推进：

```text
Kvm::new()
  -> create_vm()
  -> memory_init()
  -> setup_irqchip()
  -> create_vcpu()
  -> configure_system_for_boot()
  -> KVM_RUN
  -> virtio block rootfs
```

每推进一个节点，都保留一个可复现 smoke test。这样可以避免把问题混成“Firecracker 启动失败”，而是能明确定位到某个 KVM ABI 语义尚未实现。

## 15. 对现有工作的影响

- 不删除现有 26 个 Linux host glue 函数。
- 不改变 RISC-V Linux-host Linux-guest smoke 脚本。
- 不把 `/proc/axvisor_shell` 扩展成 Firecracker 接口。
- 新增 KVM ABI provider 后，现有 AxVisor 内核内启动路径和 Firecracker 用户态 VMM 路径并存：

```text
路径 A: Linux kernel -> axvisor_adapter.ko -> AxVisor shell/config -> guest
路径 B: Firecracker userspace -> /dev/kvm -> axvisor_kvm.ko -> AxVisor backend -> guest
```

路径 B 才是对齐 KVM ABI 兼容层的工作。

## 16. 当前实现状态

截至当前工作区，已经落地的内容：

- `axvisor_kvm.ko` 独立注册 `/dev/kvm`，不复用 `/proc/axvisor_shell`。
- 已实现 KVM global fd、VM fd、vCPU fd 三类 anon inode 对象模型。
- 已实现 `KVM_GET_API_VERSION`、`KVM_CHECK_EXTENSION`、`KVM_GET_VCPU_MMAP_SIZE`、`KVM_CREATE_VM`、`KVM_CREATE_VCPU`。
- `KVM_SET_USER_MEMORY_REGION` 已从“只保存 HVA/GPA/size”推进为真实 `pin_user_pages_fast(..., FOLL_WRITE | FOLL_LONGTERM)`，memslot 删除、覆盖和 VM release 会 unpin。
- x86_64 下已补 Firecracker 初始化路径需要的 ABI 外壳：`KVM_GET_SUPPORTED_CPUID`、`KVM_GET_MSR_INDEX_LIST`、`KVM_SET_TSS_ADDR`、`KVM_SET_IDENTITY_MAP_ADDR`、`KVM_CREATE_IRQCHIP`、`KVM_CREATE_PIT2`、`KVM_GET/SET_CLOCK`、`KVM_GET/SET_IRQCHIP`、`KVM_GET/SET_PIT2`。
- x86_64 vCPU fd 已保存/返回 `REGS`、`SREGS`、`FPU`、`LAPIC`、`CPUID2`、`MSRS`、`MP_STATE`、`DEBUGREGS`、`XSAVE`、`XCRS`、`VCPU_EVENTS`、`TSC_KHZ`。
- `KVM_IOEVENTFD` 已实现 eventfd 引用持有、deassign、VM release 生命周期，以及 `KVM_RUN` 中 MMIO write 命中后的 `eventfd_signal()` 快路径。
- `KVM_IRQFD` 已从 eventfd 引用持有推进到真实 waitqueue/poll 监听：assign 时通过 `eventfd_fget()`/`eventfd_ctx_fileget()`/`vfs_poll()` 注册 wakeup；eventfd 被写入后调度 work，并调用 backend `inject_irq(gsi)`。`KVM_IRQFD_FLAG_RESAMPLE` 当前不声明 capability，传入时返回 `-EOPNOTSUPP`。
- `axvisor_kvm_backend.h` 已定义 C 侧 backend ops ABI，`axvisor_kvm_backend.c` 提供注册式 backend 表；Rust/AxVisor 后端尚未注册时，provider 保持确定 fail-entry 行为。
- `axvisor_kvm.ko` 已新增内建 backend 生命周期入口：模块初始化时调用 `axvisor_kvm_builtin_backend_init()`，卸载时调用 `axvisor_kvm_builtin_backend_exit()`。无内建 backend 时弱符号保持 provider-only 行为。
- `AXVISOR_KVM_AXVISOR_BACKEND` 已提供 C bridge：`axvisor_kvm_axvisor_backend.c` 把 `struct axvisor_kvm_backend_ops` 转发到模块内 `axvisor_kvm_rs_*` Rust backend 符号。
- C bridge 到 Rust backend 的 state/exit FFI 已改成稳定标量 ABI：C 侧从 `struct axkvm_backend_vm_state` / `struct axkvm_backend_vcpu_state` 拆出 version、arch、TSS、identity map、IRQCHIP/PIT 标志、RIP/RSP/RFLAGS、CR0/CR3/CR4、EFER、APIC base、CPUID/MSR 计数和 TSC kHz 后传给 Rust；`run_vcpu()` 的 exit 输出也改为 reason、width、addr、data、fail-entry reason 标量输出指针。Rust 侧不再手写镜像 C struct 布局，避免 `bool`、padding、Linux UAPI 指针字段和 C union-like exit payload 导致的跨语言 ABI 错位。
- C bridge 到 Rust backend 的 x86_64 vCPU 状态下发已经从“只下发计数和少量核心标量”推进为“完整关键启动状态标量化”：`KVM_SET_REGS` 的 `RAX/RBX/RCX/RDX/RSI/RDI/RSP/RBP/R8-R15/RIP/RFLAGS` 会通过 `axvisor_kvm_rs_set_vcpu_regs()` 下发；`KVM_SET_SREGS` 的 CR0/CR2/CR3/CR4/CR8/EFER/APIC base、CS/DS/ES/FS/GS/SS/TR/LDT 和 GDT/IDT 会通过 `axvisor_kvm_rs_set_vcpu_sregs_control()`、`axvisor_kvm_rs_set_vcpu_segment()`、`axvisor_kvm_rs_set_vcpu_dtable()` 下发；`KVM_SET_CPUID2` 的每个 CPUID entry 会通过 `axvisor_kvm_rs_set_vcpu_cpuid_entry()` 下发；`KVM_SET_MSRS` 的每个 MSR entry 会通过 `axvisor_kvm_rs_set_vcpu_msr_entry()` 下发。这样后续真实 `AxVM/x86_vcpu` bridge 可以消费 Firecracker 配置出的 CPU 模板、MSR、通用寄存器和系统寄存器状态，而不是只看到 entry 数量。
- `AXVISOR_KVM_RUST_BACKEND` 仍保留为 provider-only/Rust handle scaffold 路径：`create_vm()` 分配 Rust VM handle，`map_page()`/`unmap_range()` 记录 memslot 页映射，`create_vcpu()`/`destroy_vcpu()` 管理 Rust vCPU handle，`set_vm_state()`/`set_vcpu_state()` 记录 VM/vCPU 标量状态快照，`boot_vm()` 记录 boot 状态。该路径用于 ABI 外壳和 fail-entry smoke，不是 Firecracker 验收路径。
- backend ops ABI 已新增 `set_vm_state()`，用于在 `boot_vm()` 前同步 x86_64 VM fd 上保存的 TSS、identity map、IRQCHIP、PIT 和 clock 状态。
- C 内部 backend vCPU state view 已覆盖 x86_64 启动状态：`REGS`、`SREGS`、`FPU`、`LAPIC`、`CPUID2`、`MSRS`、`MP_STATE`、`DEBUGREGS`、`XSAVE`、`XCRS`、`VCPU_EVENTS`、`TSC_KHZ`。当前 C->Rust bridge 只下发第一阶段真实后端接入需要的稳定标量；后续如果 AxVM x86 backend 需要完整 CPUID/MSR/LAPIC/FPU 状态，应新增显式 copy/apply ops，而不是重新把 Linux C struct 指针暴露给 Rust。
- `KVM_SET_USER_MEMORY_REGION` 已接到 backend hook：backend 可用时逐页 `page_to_phys(page)` 后调用 `axvisor_kvm_backend_map_page()`。
- `KVM_CREATE_VCPU` 和 `KVM_RUN` 已接到 backend hook：backend 可用时调用 `axvisor_kvm_backend_create_vcpu()`、`axvisor_kvm_backend_set_vm_state()`、`axvisor_kvm_backend_boot_vm()`、`axvisor_kvm_backend_set_vcpu_state()`、`axvisor_kvm_backend_run_vcpu()`，并把 backend exit 翻译为 KVM exit。
- `KVM_RUN` 已接入 MMIO read pending completion 状态机：backend 返回 MMIO read 时记录 pending 状态；Firecracker 写回 `kvm_run.mmio.data` 后，下一次 `KVM_RUN` 会先调用 `complete_mmio_read()` 再重新进入 backend。
- 当前内核 UAPI 的 `struct kvm_run` 不暴露 `immediate_exit` 字段，vCPU kick/interruption 语义需要在后端 run loop 接入时处理。
- `tools/axvisor-kvm-api-smoke.c` 和 `tools/axvisor-kvm-mem-vcpu-smoke.c` 已覆盖新增 ABI 外壳的编译期和运行期调用形状。
- `tools/build-axvisor-kvm-x86-module.sh` 已能在 x86_64 内核配置下编译 provider；`AXVISOR_KVM_BACKEND=1` 会编入 C bridge，`AXVISOR_KVM_RUST_BACKEND=1` 会同时启用 Rust backend scaffold；现有 RISC-V provider 构建路径保持可用。当前已验证三种 x86 构建形态：provider-only、provider+C bridge、provider+C bridge+Rust backend；`nm` 可见模块内强定义 `axvisor_kvm_rs_*` 符号。
- `AXVISOR_KVM_X86_BRIDGE` 已从固定容量 scaffold 推进为 x86 AxVisor backend bridge：`axvisor_kvm_x86_bridge.rs` 作为 x86_64 no_std Rust object 链入 `axvisor_kvm.ko`，导出与 C bridge 相同的 `axvisor_kvm_rs_*` 符号，并接入 `AxVM`、`x86_vcpu`、`x86_vlapic` 依赖链。
- `AXVISOR_KVM_X86_BRIDGE` 的 `run_vcpu()` 已进入 `AxVM::run_vcpu_raw()`，并把 `AxVCpuExitReason` 翻译为 KVM provider 可消费的 backend exit：`MmioRead`、`MmioWrite`、`IoRead`、`IoWrite`、`Halt`、`SystemDown`、`FailEntry` 等。
- x86 bridge 已维护 MMIO read 和 PIO read pending 状态，并提供 `complete_mmio_read()` / `complete_io_read()` 提交 Firecracker 在 `struct kvm_run` 中写回的数据。
- Firecracker Phase 1 验收已经通过：未修改 Firecracker 打开 `axvisor_kvm.ko` 注册的真实 `/dev/kvm`，通过 AxVisor backend 启动 x86_64 单 vCPU initramfs-only Linux guest，并从 guest 串口 PIO exit 字节流中解码出 `AXVISOR_FIRECRACKER_GUEST_PASS=1`。
- 固定证据目录：`output/firecracker-on-axvisor-kvm-20260701-215334/`。其中 `result.txt` 记录 `FIRECRACKER_ON_AXVISOR_KVM_PASS=1`，`verify-firecracker-run.out` 记录 `[verify] pass`，`firecracker-run/qemu.log` 记录 `/dev/kvm` provider 注册和 AxVisor KVM backend run/exit 日志。

当前完成态是 Layer2 Phase 1：`x86_64 + 单 vCPU + initramfs-only Linux guest + 未修改 Firecracker + /dev/kvm provider=axvisor_kvm.ko`。这不是完整 KVM 生态替代态；尚未覆盖 virtio-blk、virtio-net、多 vCPU、snapshot、migration、jailer 和生产级 KVM parity。

## 17. 已闭合的 Phase 1 backend ops

Firecracker Phase 1 路径已通过以下 backend ops 闭合：

1. `create_vm() -> handle`
2. `destroy_vm(handle)`
3. `map_page(handle, gpa, hpa, flags)`
4. `unmap_range(handle, gpa, size)`
5. `create_vcpu(handle, vcpu_id) -> vcpu_handle`
6. `set_vm_state(handle, tss/identity-map/irqchip/pit/clock)`
7. `set_vcpu_state(vcpu_handle, regs/sregs/msrs/cpuid/lapic/fpu/mp/xsave/xcrs/events/tsc)`
8. `boot_vm(handle)`
9. `run_vcpu(vcpu_handle, exit_out)`
10. `complete_mmio_read(vcpu_handle, data)`
11. `complete_io_read(vcpu_handle, data)`
12. `inject_irq(handle, gsi/vector)`

第 3 项直接消费 `KVM_SET_USER_MEMORY_REGION` pin 出来的 `struct page`：C 侧用 `page_to_phys(page)` 得到 HPA，并按页调用 backend 映射到 `GPA + offset`。Firecracker userspace guest RAM 因此进入 AxVisor stage-2/EPT/NPT 地址空间。

## 18. x86 AxVM backend 构建接入状态

`axvisor_kvm_rust_backend.o` 仍是 Linux kernel Rust object，只能直接依赖 Kbuild 提供的 `kernel`、`pin_init`、`core` 等 crate。真实 AxVM 依赖 `alloc` 和一批 `no_std` rlib，因此不能把 `extern crate axvm` 直接写进这个 kernel Rust object。当前正确接入方向已经落地：把 AxVisor backend 放进独立 x86_64 no_std bridge，再把 bridge object 链入 `axvisor_kvm.ko`。

```text
AxVisor no_std Rust crates
  -> axvisor_kvm_x86_bridge.o
  -> axvisor_kvm.ko
```

这个 x86 bridge 已完成：

- 提供 bridge runtime，覆盖 allocator、panic、alloc error 和 Linux 侧最小运行时 glue。
- 复用 Linux 侧分配/释放/phys-virt 转换能力，但只暴露 KVM backend 需要的最小宿主接口。
- 以 `target_arch = "x86_64"` 和 VMX 后端构建 AxVM/x86_vcpu 路径，避免落入 `x86_no_backend`。
- 编译并链接 x86 依赖链：`x86_vlapic`、`x86_vcpu`、`x86`、`x86_64`、`raw-cpuid`、`numeric-enum-macro`、`paste`、`bit`，并让 `axdevice` 选择 `x86_vlapic`。
- 将 RISC-V 专用 Makefile 规则拆分为架构条件，使 x86 KVM backend 不再依赖 `riscv_vplic`/`riscv_vcpu`。

第一阶段 bridge 导出与 C bridge 相同的 `axvisor_kvm_rs_*` 符号。C 侧 `struct axvisor_kvm_backend_ops` 没有因为真实 x86 backend 接入而变化，`/dev/kvm` UAPI 对象模型保持稳定。

当前 bridge 使用 `rustc --emit=obj` 直接生成 object，而不是 `staticlib + --whole-archive`。原因是 `staticlib` 会把 `core`、`alloc`、`compiler_builtins` archive 成员整体带入模块，x86 objtool 会扫描到未使用的格式化/浮点路径并失败。后续扩展 virtio、多 vCPU 或更多 KVM ABI 时应继续保持“只链接需要的 bridge object/rlib object”，避免把 sysroot 全量 archive whole-archive 进内核模块。

## 19. Phase 1 之后的真实缺口

下一阶段不再是证明 Firecracker 能启动 initramfs guest，而是扩展 Firecracker 设备和 KVM ABI 覆盖面：

- virtio-blk：需要验证 virtio-mmio config、queue notify、ioeventfd、irqfd 注入、guest rootfs 挂载和块设备 I/O。
- virtio-net：需要 TAP/队列通知/中断路径闭环。
- 多 vCPU：需要完善 vLAPIC、IPI、TSC、MP state 和 vCPU kick 语义。
- 生产兼容性：jailer、seccomp、snapshot、migration、dirty logging 和更完整 capability 矩阵仍未验收。
