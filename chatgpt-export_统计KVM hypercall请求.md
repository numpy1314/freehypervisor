# 统计KVM hypercall请求

> 我们现在希望统计kvm这个hypervisor作为上层应用，向qemu请求了哪些hypercall，比如内存分配，中断，这种hypercall，你认为我们应该怎么统计

我会先把术语边界理清：这里很可能不是“KVM 向 QEMU 发 hypercall”，而是 QEMU 通过 KVM API/ioctl 驱动 KVM，Guest 通过 hypercall/VM-exit 触发 KVM 处理。统计口径不同，方案会完全不同。

你们要统计前，建议先把**统计对象拆清楚**：严格来说，不是“KVM 作为上层应用向 QEMU 请求 hypercall”。通常架构是：

**Guest → KVM：hypercall / vmcall / vmmcall**
**QEMU → KVM：KVM ioctl / eventfd / mmap 等用户态 API**
**KVM → QEMU：KVM_RUN 返回后的 exit_reason，让 QEMU 模拟设备或处理 MMIO/PIO**

Linux KVM 文档里，x86 hypercall 是 guest 执行 `vmcall` 或 `vmmcall`，hypercall number 放在 `rax`，参数放在寄存器里；这和 QEMU 调 KVM 的 `ioctl` 是两类东西。

## 我建议按三层统计

### 1. 统计 QEMU 向 KVM 发起了哪些请求：主抓 KVM ioctl

这是你们说的“内存分配、中断”最可能对应的层。

重点统计这些 ioctl：

| 类别 | 典型 KVM API | 含义 |
|---|---|---|
| VM 创建 | `KVM_CREATE_VM` | 创建 VM |
| vCPU 创建 | `KVM_CREATE_VCPU` | 创建 vCPU |
| 运行 vCPU | `KVM_RUN` | 进入 guest，返回时带 exit reason |
| 内存注册 | `KVM_SET_USER_MEMORY_REGION` / `KVM_SET_USER_MEMORY_REGION2` | QEMU 把用户态内存注册成 guest 物理内存 slot |
| 中断 | `KVM_IRQFD`, `KVM_INTERRUPT`, `KVM_SET_GSI_ROUTING`, `KVM_SIGNAL_MSI` | 中断注入、irqfd、MSI、路由 |
| I/O 快路径 | `KVM_IOEVENTFD` | guest 写某个 MMIO/PIO 地址时触发 eventfd，减少 VM-exit |
| irqchip | `KVM_CREATE_IRQCHIP`, `KVM_GET/SET_IRQCHIP`, `KVM_GET/SET_LAPIC` | 中断控制器相关 |
| 寄存器/状态 | `KVM_GET/SET_REGS`, `KVM_GET/SET_SREGS`, `KVM_GET/SET_MSRS`, `KVM_SET_CPUID2` | vCPU 状态配置 |

比如“内存分配”更准确地说通常是：**QEMU 在用户态分配 RAM，然后用 `KVM_SET_USER_MEMORY_REGION` 告诉 KVM 这段 userspace address 映射到 guest physical address**。KVM 文档明确说这个 ioctl 用于创建、修改或删除 guest physical memory slot，并包含 `guest_phys_addr`、`memory_size`、`userspace_addr` 字段。

“中断”则常见是 `KVM_IRQFD`，它把一个 eventfd 绑定到 guest interrupt，eventfd 被触发时 KVM 向 guest 注入中断。 设备 I/O 通知常见是 `KVM_IOEVENTFD`，guest 写某个 PIO/MMIO 地址时可以 signal eventfd，而不是每次都 exit 到用户态。

最小可用命令：

```bash
# 找到 QEMU pid
pidof qemu-system-x86_64

# 先用 strace 做基线，能直接看到很多 KVM_* ioctl 名字
sudo strace -ff -tt -T -yy -e trace=ioctl,mmap,munmap,eventfd2 \
  -p <qemu-pid> \
  -o /tmp/qemu-kvm-ioctl.log
```

然后统计：

```bash
grep -h "KVM_" /tmp/qemu-kvm-ioctl.log.* \
  | sed -E 's/.*ioctl\([^,]+, ([A-Z0-9_]+).*/\1/' \
  | sort | uniq -c | sort -nr
```

如果要低开销长期跑，换成 eBPF：

```bash
sudo bpftrace -e '
tracepoint:syscalls:sys_enter_ioctl
/comm == "qemu-system-x86"/
{
  @ioctl[args->cmd] = count();
}
'
```

这个只能拿到 ioctl number；后处理时再用内核头文件 `/usr/include/linux/kvm.h` 或 `strace` 的 decode 表把 number 映射成 `KVM_*` 名称。

---

### 2. 统计 Guest 真正发给 KVM 的 hypercall

这才是严格意义的 hypercall。

x86 下可重点看：

| Hypercall | 作用 |
|---|---|
| `KVM_HC_VAPIC_POLL_IRQ` | 触发 guest exit，让 host 在重新进入 guest 前检查 pending interrupt |
| `KVM_HC_KICK_CPU` | 唤醒处于 HLT 状态的 vCPU |
| `KVM_HC_SEND_IPI` | paravirt IPI |
| `KVM_HC_SCHED_YIELD` | vCPU yield |
| `KVM_HC_CLOCK_PAIRING` | clock pairing |
| `KVM_HC_MAP_GPA_RANGE` | guest 内存范围属性提示，常见于 confidential VM 场景 |
| `KVM_HC_MMU_OP` | 已废弃的 MMU 操作 |

KVM 文档中列出了这些 hypercall 的架构、状态和用途；例如 `KVM_HC_VAPIC_POLL_IRQ` 是 active，作用是触发 guest exit 以便 host 检查 pending interrupts；`KVM_HC_MMU_OP` 是 deprecated，用于 MMU 操作。

可以先确认内核有没有对应 tracepoint：

```bash
sudo perf list 'kvm:*' | grep -i hyper
```

如果有 `kvm:kvm_hypercall`，直接：

```bash
sudo trace-cmd record -e kvm:kvm_hypercall -p nop
sudo trace-cmd report
```

或者：

```bash
sudo perf record -e kvm:kvm_hypercall -a
sudo perf script
```

如果你们内核没有这个 tracepoint，就用 kprobe/fentry 打到 KVM 源码里的 hypercall handler，例如 x86 上常见路径会涉及 `kvm_emulate_hypercall` 一类函数。实际函数名要以你们内核版本为准。

---

### 3. 统计 KVM 返回给 QEMU 的 exit reason

这能回答：“哪些 guest 行为最终需要 QEMU 处理？”

`KVM_RUN` 使用一块 mmap 出来的 `struct kvm_run` 与用户态通信。KVM_RUN 返回后，QEMU 通过 `kvm_run.exit_reason` 判断为什么退出，比如 `KVM_EXIT_IO`、`KVM_EXIT_MMIO`、`KVM_EXIT_HYPERCALL` 等。KVM 文档说明，应用程序通过 mmap vCPU fd 得到 `kvm_run`，调用 `KVM_RUN` 后通过结构体成员获取返回原因。

可以抓 kernel tracepoint：

```bash
sudo perf list 'kvm:*' | grep exit
sudo trace-cmd record -e kvm:kvm_exit -e kvm:kvm_userspace_exit -p nop
sudo trace-cmd report
```

或者 QEMU 侧开 trace。QEMU 官方文档支持 `--trace`，可以启用 `kvm_*`、`memory_region_ops_*`、`virtio_*` 等 pattern；例如文档示例里可以用 `qemu --trace "kvm_*" --trace "virtio_*"`，也可以把事件写入文件再用 `--trace events=/tmp/events`。

```bash
cat >/tmp/qemu-events <<'EOF'
kvm_*
memory_region_ops_*
virtio_*
EOF

qemu-system-x86_64 ... \
  -enable-kvm \
  -trace events=/tmp/qemu-events
```

## 推荐的最终统计模型

不要只输出“hypercall 列表”，建议输出这张表：

| 方向 | 类型 | 事件名 | 次数 | 关联对象 | 语义分类 |
|---|---|---:|---:|---|---|
| QEMU → KVM | ioctl | `KVM_SET_USER_MEMORY_REGION` | N | slot, GPA, size | 内存注册 |
| QEMU → KVM | ioctl | `KVM_IRQFD` | N | gsi, eventfd | 中断 |
| QEMU → KVM | ioctl | `KVM_IOEVENTFD` | N | MMIO/PIO addr | I/O 通知 |
| QEMU → KVM | ioctl | `KVM_RUN` | N | vcpu id | vCPU 运行 |
| Guest → KVM | hypercall | `KVM_HC_KICK_CPU` | N | target apic id | vCPU 唤醒 |
| KVM → QEMU | exit | `KVM_EXIT_MMIO` | N | GPA, len, rw | 设备模拟 |
| KVM → QEMU | exit | `KVM_EXIT_IO` | N | port, size, direction | PIO 模拟 |
| KVM → QEMU | exit | `KVM_EXIT_HYPERCALL` | N | nr, args | hypercall 上送 |

## 我的建议落地路径

第一阶段先做 **QEMU→KVM ioctl 统计**，用 `strace` 或 eBPF 把 `KVM_*` 调用按次数、耗时、VM fd/vCPU fd 分类。这一步最快能回答“内存、中断、vCPU、设备 I/O 到底用了哪些 KVM API”。

第二阶段加 **KVM tracepoint**，统计 `kvm_exit`、`kvm_userspace_exit`、`kvm_hypercall`。这能把 guest 行为和 QEMU/KVM API 对上。

第三阶段才做 **语义归类**：
`KVM_SET_USER_MEMORY_REGION` 归“内存注册”，不是 hypercall；`KVM_IRQFD/KVM_INTERRUPT/KVM_SIGNAL_MSI` 归“中断注入”；`KVM_IOEVENTFD` 归“设备通知快路径”；`KVM_RUN exit_reason` 归“guest 触发 KVM 返回 QEMU 的原因”。

一句话：**统计时把 hypercall、KVM ioctl、VM-exit 分开，不然“内存分配”和“中断”会被错误地混在 hypercall 里。**

-----

> 1、rax和ioctl是什么？2、ebpf是如何捕获这些调用的？3、我们希望的真正的统计口径是这样的，因为hypervisor会依赖底层os提供的比如内存分配，线程管理的底层能力嘛，我们现在就希望把这些内容抽象出来，我们能够做一个上层的hypervisor，这样不管底层os是什么，只要底层os提供了这些能力，我们就能提供一个通用hypervisor来提供虚拟化支持，这应该是一个很有前景的研究课题，但我们需要做出这个架构无关的中间层的抽象，所以我们需要统计底层os向hypervisor提供了哪些服务，你认为这个统计口径应该如何调整？

我会把问题从“hypercall 统计”重新校准成“hypervisor 对宿主 OS/内核能力的依赖面统计”，这样更贴合你们要做架构无关中间层的目标。

我查了一下最新内核文档来对齐术语。关键点是：`rax` 属于 CPU/指令层，`ioctl` 属于 OS syscall/API 层，eBPF 看到的是后者和内核函数/tracepoint。

你们现在的统计口径应该从：

> “KVM/QEMU 有哪些 hypercall？”

调整为：

> **“一个 hypervisor 运行时依赖底层 OS 提供哪些宿主能力，并且这些能力在 Linux/KVM/QEMU 中分别由哪些 syscall、ioctl、内核函数、tracepoint、硬件虚拟化接口体现？”**

这样才服务于你们要做的“架构无关 hypervisor 中间层抽象”。

---

## 1. `rax` 和 `ioctl` 是什么？

### `rax`

`rax` 是 x86-64 CPU 的一个通用寄存器。
在 **KVM hypercall** 语境里，guest 执行 `vmcall` 或 `vmmcall` 指令时，会把 **hypercall number 放在 `rax`**，把最多 4 个参数放在 `rbx`、`rcx`、`rdx`、`rsi`，返回值也放回 `rax`。这属于 **Guest → Hypervisor 的 CPU 指令/寄存器层接口**。

可以理解成：

```text
Guest:
  rax = hypercall_number
  rbx/rcx/rdx/rsi = args
  vmcall / vmmcall
```

所以 `rax` 不是 API 名字，它是 **CPU 调用约定的一部分**。

---

### `ioctl`

`ioctl` 是 Linux/Unix 里一个通用的系统调用，常用于“对某个文件描述符背后的内核对象发控制命令”。

KVM 的用户态 API 就是典型 `ioctl` 风格：用户态程序先 `open("/dev/kvm")`，然后通过不同的 `KVM_* ioctl` 创建 VM、创建 vCPU、注册内存、运行 vCPU 等。Linux KVM 文档明确说，KVM API 以不同类型的 file descriptor 和发给这些 fd 的 ioctl 为中心；`KVM_CREATE_VM` 会创建 VM fd，`KVM_CREATE_VCPU` 会创建 vCPU fd。

可以理解成：

```text
QEMU:
  fd = open("/dev/kvm")
  vm_fd = ioctl(fd, KVM_CREATE_VM, ...)
  vcpu_fd = ioctl(vm_fd, KVM_CREATE_VCPU, ...)
  ioctl(vcpu_fd, KVM_RUN, ...)
```

所以：

```text
rax    = guest 调 hypervisor 时的 CPU 寄存器接口
ioctl  = QEMU/用户态 VMM 调 Linux KVM 内核模块时的 OS API 接口
```

这两个不是同一层。

---

## 2. eBPF 是如何捕获这些调用的？

eBPF 的核心思路是：**把一小段受限、安全校验过的程序挂到内核里的某个 hook 点上**。当这个 hook 点被执行时，eBPF 程序就运行，读取上下文参数，然后把统计结果写到 BPF map，用户态再定期读取 map。

Linux 官方文档里，libbpf 把 BPF 程序生命周期分成 open、load、attach、tear down，其中 attach 阶段会把 BPF 程序挂到 tracepoints、kprobes、cgroup hooks 等 hook 点上；BPF 程序运行时可以更新 BPF maps，用户态可以读取这些 maps。

对你们这个问题，常见有三类 hook：

### A. 抓 syscall 层：统计 QEMU 调了哪些 OS/KVM API

例如抓所有 `ioctl`：

```bash
sudo bpftrace -e '
tracepoint:syscalls:sys_enter_ioctl
/comm == "qemu-system-x86_64"/
{
  @ioctl[args->cmd] = count();
}
'
```

含义是：

```text
当某个进程进入 ioctl syscall 时：
  如果进程名是 qemu-system-x86_64：
    按 ioctl command number 计数
```

这可以看到 QEMU 调了多少次 `KVM_CREATE_VM`、`KVM_CREATE_VCPU`、`KVM_SET_USER_MEMORY_REGION`、`KVM_RUN`、`KVM_IRQFD` 等。KVM 文档里 `KVM_SET_USER_MEMORY_REGION` 是 VM ioctl，用来给 guest physical memory slot 绑定 userspace allocated memory；结构体里有 `guest_phys_addr`、`memory_size`、`userspace_addr` 字段。

如果要统计耗时，可以同时抓 enter 和 exit：

```bash
sudo bpftrace -e '
tracepoint:syscalls:sys_enter_ioctl
/comm == "qemu-system-x86_64"/
{
  @start[tid] = nsecs;
  @cmd[tid] = args->cmd;
}

tracepoint:syscalls:sys_exit_ioctl
/@start[tid]/
{
  @latency[@cmd[tid]] = hist(nsecs - @start[tid]);
  delete(@start[tid]);
  delete(@cmd[tid]);
}
'
```

---

### B. 抓 KVM tracepoint：统计 VM-exit、hypercall、内存 fault 等事件

Linux tracepoint 是内核代码里的静态 hook 点。内核文档说，tracepoint 放在代码中后，可以在运行时连接 probe；tracepoint 触发时，probe 会被调用，并能拿到 tracepoint 传出的参数。

你们可以先看系统有哪些 KVM tracepoint：

```bash
sudo perf list 'kvm:*'
```

或者：

```bash
ls /sys/kernel/tracing/events/kvm/
```

然后抓：

```bash
sudo bpftrace -e '
tracepoint:kvm:kvm_exit
{
  @exit_reason[args->exit_reason] = count();
}
'
```

这类统计回答的是：

```text
Guest 运行时因为什么原因退出到 KVM/QEMU？
例如 MMIO、PIO、HLT、CPUID、MSR、EPT violation、hypercall 等。
```

`KVM_RUN` 返回后，用户态会通过 mmap 出来的 `struct kvm_run` 查看 `exit_reason`，判断为什么 vCPU 从 guest 退出来；KVM 文档明确说明，应用通过 mmap vCPU fd 得到 `kvm_run`，调用 `KVM_RUN` 后通过结构体成员获取返回原因。

---

### C. 抓内核函数：统计 KVM 内部用了哪些 Linux 内核服务

如果你们真正关心的是“底层 OS 向 hypervisor 提供哪些能力”，就不能只看 `ioctl`。还要看 KVM 内部调用了哪些 Linux 内核 primitive，例如：

```text
内存：alloc_pages, vmalloc, get_user_pages, mmu_notifier
线程/调度：kthread, wake_up, schedule, waitqueue, hrtimer
中断：eventfd_signal, irqfd, irq routing, MSI
同步：mutex, spinlock, srcu, rcu
I/O：eventfd, ioeventfd, vhost, VFIO, IOMMU
```

这类可以用 kprobe/kretprobe。Kprobes 文档说，kprobe 可以动态插入到几乎任意内核例程里，收集调试和性能信息；kretprobe 则在函数返回时触发。

例如：

```bash
sudo bpftrace -e '
kprobe:__alloc_pages
/comm == "qemu-system-x86_64" || comm == "CPU 0\/KVM"/
{
  @page_allocs[comm] = count();
}
'
```

不过这里要小心：KVM 的很多执行路径发生在内核态，`comm` 不一定总是直观等于 qemu；更可靠的是结合 pid、tgid、vCPU thread、KVM fd、stack trace、cgroup 或 VM 标识一起归因。

---

## 3. 你们真正应该调整成什么统计口径？

我建议把统计对象改成：

> **Hypervisor Host Service Dependency Surface**
> 即：hypervisor 为了创建、运行、隔离、调度、模拟和销毁 VM，依赖宿主 OS 提供哪些基础服务。

这比“统计 hypercall”更适合你们的研究目标。

因为 hypercall 只覆盖：

```text
Guest → Hypervisor 的显式调用
```

而你们真正想抽象的是：

```text
Hypervisor → Host OS 的能力依赖
```

也就是未来要设计一个类似：

```text
Generic Hypervisor Core
        ↓
Host OS Abstraction Layer
        ↓
Linux / seL4 / RTOS / Windows kernel / 自研内核 / 裸机 runtime
```

的中间层。

---

# 推荐的新统计模型

## 第一层：Host OS 基础能力分类

你们可以先把底层 OS 服务抽象成这些大类：

| 抽象能力 | Linux/KVM/QEMU 中的体现 | 中间层接口例子 |
|---|---|---|
| VM 生命周期管理 | `/dev/kvm`, `KVM_CREATE_VM`, fd 生命周期 | `hv_vm_create()`, `hv_vm_destroy()` |
| vCPU 管理 | `KVM_CREATE_VCPU`, `KVM_RUN`, pthread/thread scheduling | `hv_vcpu_create()`, `hv_vcpu_run()`, `hv_vcpu_kick()` |
| 内存分配与映射 | `mmap`, `munmap`, `madvise`, `KVM_SET_USER_MEMORY_REGION`, page allocator | `hv_mem_alloc()`, `hv_mem_map_guest()`, `hv_mem_unmap_guest()` |
| Stage-2 / EPT / NPT 管理 | KVM MMU, EPT violation, shadow page table | `hv_stage2_map()`, `hv_stage2_unmap()` |
| 内存权限与脏页跟踪 | `mprotect`, dirty log, write-protect, mmu notifier | `hv_mem_protect()`, `hv_dirty_log_start()` |
| 中断注入 | `KVM_IRQFD`, `KVM_INTERRUPT`, MSI routing | `hv_irq_inject()`, `hv_irq_route()` |
| 事件通知 | `eventfd`, `irqfd`, `ioeventfd`, `epoll` | `hv_event_create()`, `hv_event_signal()`, `hv_event_wait()` |
| 定时器/时间 | `timerfd`, `hrtimer`, pvclock, TSC handling | `hv_timer_create()`, `hv_clock_read()` |
| 线程与调度 | pthread, futex, sched affinity, wakeup | `hv_thread_create()`, `hv_thread_pin()`, `hv_thread_sleep()` |
| 同步原语 | mutex, spinlock, RCU, SRCU, waitqueue | `hv_lock()`, `hv_rcu_read_lock()`, `hv_waitqueue_wake()` |
| 设备 I/O 模拟 | MMIO exit, PIO exit, ioeventfd, vhost | `hv_io_register_region()`, `hv_io_dispatch()` |
| DMA/IOMMU | VFIO, IOMMU map/unmap, DMA pinning | `hv_dma_map()`, `hv_iommu_attach()` |
| 文件/资源句柄 | fd, refcount, lifecycle | `hv_handle_create()`, `hv_handle_close()` |
| 安全隔离 | capability, cgroup, namespace, SELinux/AppArmor | `hv_security_check()`, `hv_resource_limit()` |
| 可观测性 | tracepoint, perf, ftrace, BPF | `hv_trace_emit()`, `hv_metric_count()` |

这张表就是你们未来中间层的雏形。

---

## 第二层：把 Linux/KVM 事件映射到抽象服务

不要只统计事件名，而是统计成：

```text
原始事件 → Linux 机制 → hypervisor 语义 → 可移植抽象能力
```

例如：

| 原始观测 | Linux/KVM 机制 | Hypervisor 语义 | 抽象服务 |
|---|---|---|---|
| `mmap` | 用户态虚拟内存分配 | 为 guest RAM 准备 backing memory | `HV_MEM_ALLOC_BACKING` |
| `KVM_SET_USER_MEMORY_REGION` | KVM VM ioctl | 注册 guest physical memory slot | `HV_MEM_REGISTER_GPA_RANGE` |
| `mmu_notifier` | Linux MM 子系统通知 | host VA 映射变化时通知 KVM | `HV_MEM_HOST_MAPPING_NOTIFY` |
| `KVM_RUN` | vCPU ioctl | 进入 guest 执行 | `HV_VCPU_ENTER` |
| `KVM_EXIT_MMIO` | VM-exit reason | guest 访问模拟设备 | `HV_IO_MMIO_EXIT` |
| `KVM_IRQFD` | eventfd 绑定 guest interrupt | host event 触发 guest interrupt | `HV_IRQ_EVENT_BIND` |
| `eventfd` | Linux 事件计数 fd | host/设备/vCPU 之间事件通知 | `HV_EVENT_NOTIFY` |
| `futex` | Linux 用户态同步 | QEMU 线程同步 | `HV_THREAD_SYNC` |
| `sched_setaffinity` | Linux 调度 API | vCPU 绑核 | `HV_VCPU_PIN` |
| `VFIO_IOMMU_MAP_DMA` | VFIO/IOMMU API | 设备直通 DMA 映射 | `HV_DMA_MAP` |

这才是你们论文/系统设计里最有价值的统计结果。

---

## 第三层：统计维度不要只看“次数”

建议每个服务都统计这些字段：

| 字段 | 说明 |
|---|---|
| `service_class` | 内存、线程、中断、I/O、DMA、调度、时间、同步等 |
| `raw_event` | syscall、ioctl、tracepoint、kprobe 函数名 |
| `direction` | QEMU→KVM、KVM→Linux kernel、Guest→KVM、KVM→QEMU |
| `frequency` | 调用次数 |
| `latency` | 平均、P99、最大耗时 |
| `phase` | VM create、boot、steady-state、I/O intensive、migration、destroy |
| `criticality` | 必需、可选、优化路径 |
| `portability` | 易抽象、依赖 Linux、依赖硬件、依赖架构 |
| `replacement_candidate` | 在其他 OS 上可以用什么替代 |
| `semantic_name` | 你们定义的架构无关 API 名称 |

例如最终输出应该像这样：

| 抽象服务 | Linux 实现 | 触发阶段 | 次数 | P99 延迟 | 可移植性 |
|---|---|---:|---:|---:|---|
| `HV_MEM_REGISTER_GPA_RANGE` | `KVM_SET_USER_MEMORY_REGION` | VM init / hotplug | N | X us | 中 |
| `HV_VCPU_ENTER` | `KVM_RUN` | steady-state | N | X us | 高 |
| `HV_IRQ_EVENT_BIND` | `KVM_IRQFD` | device init | N | X us | 中 |
| `HV_EVENT_NOTIFY` | `eventfd` | I/O path | N | X us | 高 |
| `HV_THREAD_BLOCK_WAKE` | `futex`, `sched_wakeup` | steady-state | N | X us | 高 |
| `HV_DMA_MAP` | VFIO/IOMMU ioctl | device passthrough | N | X us | 低/中 |
| `HV_MEM_HOST_NOTIFY` | `mmu_notifier` | memory pressure / unmap | N | X us | 低 |

---

# 我建议你们的实际统计路径

## Phase 1：统计 QEMU 作为 VMM 使用了哪些宿主 OS API

抓：

```text
syscalls:
  mmap, munmap, mprotect, madvise, mlock
  ioctl
  eventfd2
  epoll_wait, epoll_ctl
  futex
  clone, sched_setaffinity
  timerfd_create, timerfd_settime
  read, write, pread, pwrite
```

重点从 QEMU 进程视角抽象：

```text
内存 backing
线程/vCPU 管理
事件循环
设备 I/O
中断通知
定时器
同步
```

---

## Phase 2：统计 QEMU→KVM 的 ioctl

重点 ioctl：

```text
KVM_CREATE_VM
KVM_CREATE_VCPU
KVM_SET_USER_MEMORY_REGION
KVM_RUN
KVM_IRQFD
KVM_IOEVENTFD
KVM_SET_GSI_ROUTING
KVM_INTERRUPT
KVM_SIGNAL_MSI
KVM_GET/SET_REGS
KVM_GET/SET_SREGS
KVM_GET/SET_MSRS
KVM_SET_CPUID2
```

其中 `KVM_IRQFD` 明确用于把 eventfd 直接绑定到 guest interrupt；eventfd 触发时，KVM 会向 guest 注入指定中断。

这一层的目标是回答：

```text
用户态 hypervisor runtime 需要 OS 提供哪些控制接口？
```

---

## Phase 3：统计 KVM 内核模块依赖了哪些 Linux 内核服务

这一步最关键，因为它最接近你们的研究目标。

要抓的不是简单 syscall，而是 KVM 内部调用路径：

```text
内存：
  page allocation
  vmalloc
  gup / pin_user_pages
  mmu_notifier
  rmap
  dirty page tracking

调度：
  schedule
  wake_up
  waitqueue
  hrtimer
  preemption hooks

同步：
  mutex
  spinlock
  rwsem
  RCU/SRCU

中断：
  irqfd
  eventfd_signal
  MSI routing
  APIC/GIC emulation

I/O：
  MMIO exit
  PIO exit
  ioeventfd
  vhost
  VFIO

IOMMU/DMA：
  iommu_map
  iommu_unmap
  vfio container/group/device ioctl
```

这一层的目标是回答：

```text
如果把 KVM 移植到另一个 OS，这个 OS 必须给 hypervisor 提供哪些 kernel primitive？
```

---

# 你们可以把中间层命名成类似这样

```text
Hypervisor Host Abstraction Layer, HHAL
```

接口可以分成：

```c
struct hv_host_memory_ops {
    void *(*alloc_backing)(size_t size, uint64_t flags);
    int (*free_backing)(void *addr, size_t size);
    int (*map_guest_phys)(struct hv_vm *vm, uint64_t gpa, void *hva, size_t size, uint64_t flags);
    int (*unmap_guest_phys)(struct hv_vm *vm, uint64_t gpa, size_t size);
    int (*protect_guest_phys)(struct hv_vm *vm, uint64_t gpa, size_t size, uint64_t perm);
    int (*start_dirty_log)(struct hv_vm *vm, uint64_t gpa, size_t size);
};

struct hv_host_vcpu_ops {
    struct hv_vcpu *(*create_vcpu)(struct hv_vm *vm, int id);
    int (*run_vcpu)(struct hv_vcpu *vcpu);
    int (*kick_vcpu)(struct hv_vcpu *vcpu);
    int (*set_affinity)(struct hv_vcpu *vcpu, int cpu);
};

struct hv_host_event_ops {
    struct hv_event *(*create_event)(void);
    int (*signal_event)(struct hv_event *event);
    int (*wait_event)(struct hv_event *event, uint64_t timeout_ns);
    int (*bind_event_to_irq)(struct hv_vm *vm, struct hv_event *event, int irq);
};
```

这比直接抽象 `KVM_* ioctl` 更有研究价值，因为它抽象的是：

```text
需求语义，而不是 Linux API 形态。
```

---

# 最核心的口径调整

你们不要再说：

> 统计 KVM 向 QEMU 请求了哪些 hypercall。

建议改成：

> **统计 hypervisor/VMM 在 VM 生命周期中对宿主 OS 的能力依赖，并将 Linux/KVM/QEMU 的 syscall、ioctl、tracepoint、内核函数调用归一化为一组架构无关的 Host Service Abstraction。**

一句话总结：

> **hypercall 是 Guest→Hypervisor 的接口；你们要研究的是 Hypervisor→Host OS 的依赖面。统计口径应从“hypercall 列表”升级为“宿主 OS 服务能力矩阵”。**

-----

> 你认为我们应该先怎么统计 hypervisor/VMM 在 VM 生命周期中对宿主 OS 的能力依赖，并将 Linux/KVM/QEMU 的 syscall、ioctl、tracepoint、内核函数调用归一化为一组架构无关的 Host Service Abstraction？从工程上我们怎么入手？

建议先做一个“最小闭环”：不要一开始就追全量内核调用，而是选定 3 个 VM 生命周期阶段和 4 类服务，先把采集、归一化、报表跑通。

我建议你们从 **“先做可解释的最小闭环”** 入手，而不是一上来追 KVM 全部内核调用栈。工程上可以分成 5 步：

```text
定义生命周期阶段
  ↓
采集原始事件：syscall / KVM ioctl / KVM tracepoint / targeted kprobe
  ↓
统一事件格式
  ↓
映射到 Host Service Abstraction
  ↓
输出服务依赖矩阵 + 频率/延迟/阶段/可移植性
```

---

# 1. 第一版先统计什么？

第一版不要追求“完整”，先覆盖 VM 生命周期里最关键的 4 类能力：

```text
1. 内存能力
2. vCPU/线程/调度能力
3. 中断/事件通知能力
4. I/O/设备模拟能力
```

生命周期阶段建议先切成：

```text
VM_CREATE      创建虚拟机
VM_BOOT        guest 启动
STEADY_IDLE    guest 空闲运行
STEADY_IO      guest 执行 I/O workload
VM_DESTROY     销毁虚拟机
```

这样你们最后能回答的问题不是“调用了哪些函数”，而是：

```text
在 VM_CREATE 阶段，hypervisor 依赖了哪些 host memory service？
在 STEADY_IO 阶段，主要依赖 eventfd、ioeventfd、KVM_EXIT_MMIO 还是 VFIO/IOMMU？
在 VM_BOOT 阶段，vCPU entry/exit、IRQ injection、MMIO exit 各占多少？
```

这比单纯列 syscall/ioctl 更有研究价值。

---

# 2. 总体工程架构

建议做一个四层 pipeline：

```text
┌──────────────────────────────────────────────┐
│ Workload Runner                              │
│ 启动 QEMU，标记 VM 生命周期阶段，运行 workload │
└──────────────────────────────────────────────┘
                    ↓
┌──────────────────────────────────────────────┐
│ Raw Collectors                               │
│ syscall collector                            │
│ KVM ioctl collector                          │
│ KVM tracepoint collector                     │
│ targeted kprobe collector                    │
└──────────────────────────────────────────────┘
                    ↓
┌──────────────────────────────────────────────┐
│ Normalizer                                   │
│ raw event → semantic service                 │
│ KVM_SET_USER_MEMORY_REGION → HV_MEM_REGISTER │
└──────────────────────────────────────────────┘
                    ↓
┌──────────────────────────────────────────────┐
│ Report Generator                             │
│ service matrix / phase matrix / latency / call graph │
└──────────────────────────────────────────────┘
```

不要让采集器直接输出“研究结论”。采集器只输出事实，归一化层再把事实翻译成架构无关服务。

---

# 3. 第一步：定义统一事件格式

你们应该先定一个统一 event schema，后面所有 syscall、ioctl、tracepoint、kprobe 都归一到这个格式。

建议每条事件长这样：

```json
{
  "timestamp_ns": 1234567890,
  "pid": 1234,
  "tid": 1235,
  "comm": "qemu-system-x86_64",
  "phase": "VM_BOOT",

  "source": "syscall",
  "raw_event": "ioctl",
  "raw_name": "KVM_SET_USER_MEMORY_REGION",

  "direction": "VMM_TO_HOST_KERNEL",
  "service_class": "MEMORY",
  "service_name": "HV_MEM_REGISTER_GPA_RANGE",

  "latency_ns": 21000,
  "result": 0,

  "attributes": {
    "gpa": "0x100000",
    "size": 1073741824,
    "slot": 0
  }
}
```

这一步非常关键。否则你们后面会被 `syscall`、`ioctl`、`tracepoint`、`kprobe` 的格式差异拖死。

---

# 4. 第二步：先做 syscall 层采集

第一层从 QEMU 进程视角看：

```text
QEMU/VMM 使用了哪些宿主 OS 用户态 API？
```

先抓这些 syscall：

```text
内存：
  mmap, munmap, mprotect, madvise, mlock, brk

线程/调度：
  clone, futex, sched_setaffinity, sched_yield, nanosleep

事件通知：
  eventfd2, epoll_create1, epoll_ctl, epoll_wait

时间：
  timerfd_create, timerfd_settime, clock_gettime

文件/设备：
  openat, close, read, write, pread64, pwrite64

控制接口：
  ioctl
```

最小可用版本可以先用 `strace`：

```bash
sudo strace -ff -tt -T \
  -e trace=ioctl,mmap,munmap,mprotect,madvise,eventfd2,epoll_ctl,epoll_wait,futex,clone,sched_setaffinity,timerfd_create,timerfd_settime \
  -p <qemu-pid> \
  -o /tmp/qemu-host-service.log
```

但 `strace` 开销比较大，适合验证。正式采集建议用 eBPF。

例如先用 bpftrace 快速验证：

```bash
sudo bpftrace -e '
tracepoint:syscalls:sys_enter_ioctl
/comm == "qemu-system-x86_64"/
{
  @ioctl_cmd[args->cmd] = count();
}

tracepoint:syscalls:sys_enter_mmap
/comm == "qemu-system-x86_64"/
{
  @mmap_count = count();
  @mmap_size = hist(args->len);
}

tracepoint:syscalls:sys_enter_futex
/comm == "qemu-system-x86_64"/
{
  @futex_ops[args->op] = count();
}

tracepoint:syscalls:sys_enter_eventfd2
/comm == "qemu-system-x86_64"/
{
  @eventfd_count = count();
}
'
```

这一步可以得到第一版原始事实：

```text
QEMU 用了多少 mmap？
用了多少 futex？
创建了多少 eventfd？
发了多少 ioctl？
这些调用主要发生在哪个阶段？
```

---

# 5. 第三步：单独解码 KVM ioctl

`ioctl` 只是一个 syscall 容器，真正重要的是里面的 command，例如：

```text
KVM_CREATE_VM
KVM_CREATE_VCPU
KVM_RUN
KVM_SET_USER_MEMORY_REGION
KVM_IRQFD
KVM_IOEVENTFD
KVM_SET_GSI_ROUTING
KVM_INTERRUPT
KVM_GET_DIRTY_LOG
KVM_CLEAR_DIRTY_LOG
```

KVM 官方 API 本身就是围绕不同 fd 上的 ioctl 组织的，例如 `KVM_RUN` 是 vCPU ioctl，用于运行 guest vCPU，并且通过 mmap 出来的 `struct kvm_run` 作为隐式参数块返回 exit 信息。

所以你们应该把普通 ioctl 拆成：

```text
ioctl(fd, KVM_RUN)
ioctl(fd, KVM_SET_USER_MEMORY_REGION)
ioctl(fd, KVM_IRQFD)
...
```

然后映射到抽象服务：

| KVM ioctl | 抽象服务 |
|---|---|
| `KVM_CREATE_VM` | `HV_VM_CREATE` |
| `KVM_CREATE_VCPU` | `HV_VCPU_CREATE` |
| `KVM_RUN` | `HV_VCPU_ENTER` |
| `KVM_SET_USER_MEMORY_REGION` | `HV_MEM_REGISTER_GPA_RANGE` |
| `KVM_GET_DIRTY_LOG` | `HV_MEM_DIRTY_LOG_READ` |
| `KVM_CLEAR_DIRTY_LOG` | `HV_MEM_DIRTY_LOG_CLEAR` |
| `KVM_IRQFD` | `HV_IRQ_BIND_EVENT` |
| `KVM_IOEVENTFD` | `HV_IO_BIND_EVENT` |
| `KVM_SET_GSI_ROUTING` | `HV_IRQ_ROUTE_CONFIG` |
| `KVM_INTERRUPT` | `HV_IRQ_INJECT` |

这一层是你们中间层抽象的核心，因为它暴露了：

```text
VMM 需要底层 host kernel 提供哪些虚拟化控制能力？
```

---

# 6. 第四步：采集 KVM tracepoint

syscall/ioctl 只能看到 QEMU 调内核，不能看到 guest 运行过程中为什么 exit、KVM 内部发生了什么。

所以第二类 collector 要抓 KVM tracepoint。

先看当前系统有哪些：

```bash
sudo perf list 'kvm:*'
```

或者：

```bash
sudo ls /sys/kernel/tracing/events/kvm/
```

优先抓：

```text
kvm:kvm_entry
kvm:kvm_exit
kvm:kvm_userspace_exit
kvm:kvm_hypercall
kvm:kvm_mmio
kvm:kvm_pio
kvm:kvm_page_fault
```

不同内核和架构的 tracepoint 名字会有差异，所以采集器要做 capability detection。

tracepoint 本质是内核代码里的轻量 hook，打开时每次执行 tracepoint 都会调用你附加的 probe，可以用于 tracing 和性能统计。

示例：

```bash
sudo bpftrace -e '
tracepoint:kvm:kvm_exit
{
  @exit_reason[args->exit_reason] = count();
}

tracepoint:kvm:kvm_userspace_exit
{
  @userspace_exit[args->reason] = count();
}
'
```

这一层映射到抽象服务时，不要直接写成 `KVM_EXIT_MMIO`，而要写成：

| KVM tracepoint / exit | 抽象服务 |
|---|---|
| `KVM_EXIT_MMIO` | `HV_IO_MMIO_EMULATION_REQUEST` |
| `KVM_EXIT_IO` | `HV_IO_PORT_EMULATION_REQUEST` |
| `KVM_EXIT_HLT` | `HV_VCPU_BLOCK` |
| `KVM_EXIT_IRQ_WINDOW_OPEN` | `HV_IRQ_WINDOW_REQUEST` |
| `KVM_EXIT_HYPERCALL` | `HV_GUEST_HYPERCALL_DISPATCH` |
| `kvm_page_fault` / EPT violation | `HV_MEM_STAGE2_FAULT_HANDLE` |

这一步回答的是：

```text
guest 运行时，需要 host/hypervisor 介入的原因是什么？
```

---

# 7. 第五步：只对关键路径加 kprobe，不要全量追踪

你们最终想知道的是：

```text
KVM 内核模块依赖了哪些 Linux 内核 primitive？
```

这需要 kprobe/kretprobe。但这里千万不要一开始全量抓函数调用。内核路径太多，噪声会非常大。

Kprobes 可以动态探测几乎任意内核例程，kretprobe 可以在函数返回时触发，适合做非侵入式调试和性能统计。

建议只抓候选 primitive：

## 内存相关

```text
__alloc_pages
alloc_pages
vmalloc
vfree
get_user_pages
pin_user_pages
unpin_user_pages
mmu_notifier_register
mmu_notifier_unregister
```

抽象成：

```text
HV_HOST_PAGE_ALLOC
HV_HOST_VMALLOC
HV_MEM_PIN_USER_PAGES
HV_MEM_HOST_MAPPING_NOTIFY
```

## 调度/线程相关

```text
schedule
wake_up_process
try_to_wake_up
hrtimer_start_range_ns
```

抽象成：

```text
HV_THREAD_SCHEDULE
HV_THREAD_WAKE
HV_TIMER_ARM
```

## 同步相关

```text
mutex_lock
mutex_unlock
down_read
up_read
srcu_read_lock
srcu_read_unlock
```

抽象成：

```text
HV_SYNC_MUTEX
HV_SYNC_RWSEM
HV_SYNC_RCU
```

## 事件/中断相关

```text
eventfd_signal
irqfd_wakeup
```

抽象成：

```text
HV_EVENT_SIGNAL
HV_IRQ_EVENT_WAKEUP
```

## IOMMU/DMA 相关

```text
iommu_map
iommu_unmap
vfio_pin_pages
vfio_unpin_pages
```

抽象成：

```text
HV_DMA_MAP
HV_DMA_UNMAP
HV_DMA_PIN_PAGES
```

注意：这些函数名会随内核版本、配置、架构不同而变化，所以第一版应当把它们做成配置文件，而不是硬编码。

---

# 8. 归一化层：用 YAML/JSON 写映射规则

建议你们不要把映射逻辑写死在代码里，而是维护一个 mapping 文件。

例如：

```yaml
- source: syscall
  raw_name: mmap
  service_class: MEMORY
  service_name: HV_MEM_ALLOC_BACKING
  direction: VMM_TO_HOST_OS

- source: syscall
  raw_name: eventfd2
  service_class: EVENT
  service_name: HV_EVENT_CREATE
  direction: VMM_TO_HOST_OS

- source: ioctl
  raw_name: KVM_SET_USER_MEMORY_REGION
  service_class: MEMORY
  service_name: HV_MEM_REGISTER_GPA_RANGE
  direction: VMM_TO_HOST_KERNEL

- source: ioctl
  raw_name: KVM_RUN
  service_class: VCPU
  service_name: HV_VCPU_ENTER
  direction: VMM_TO_HOST_KERNEL

- source: tracepoint
  raw_name: KVM_EXIT_MMIO
  service_class: IO
  service_name: HV_IO_MMIO_EMULATION_REQUEST
  direction: HYPERVISOR_TO_VMM

- source: kprobe
  raw_name: eventfd_signal
  service_class: EVENT
  service_name: HV_EVENT_SIGNAL
  direction: HYPERVISOR_TO_HOST_OS
```

这样你们后面可以不断迭代：

```text
Linux/KVM 事件 → Host Service Abstraction
seL4 事件 → Host Service Abstraction
Windows Hyper-V API → Host Service Abstraction
自研 OS primitive → Host Service Abstraction
```

最终中间层不是绑定 Linux，而是绑定你们定义的语义服务。

---

# 9. 第一版报表应该长什么样？

不要只输出 raw event count。建议输出三张表。

## 表 1：按生命周期阶段统计

| Phase | Service Class | Service | Count | P50 Latency | P99 Latency |
|---|---|---|---:|---:|---:|
| VM_CREATE | MEMORY | `HV_MEM_ALLOC_BACKING` | 12 | 30 us | 2 ms |
| VM_CREATE | MEMORY | `HV_MEM_REGISTER_GPA_RANGE` | 4 | 80 us | 300 us |
| VM_BOOT | VCPU | `HV_VCPU_ENTER` | 18000 | 20 us | 1 ms |
| VM_BOOT | IO | `HV_IO_MMIO_EMULATION_REQUEST` | 9000 | - | - |
| STEADY_IO | EVENT | `HV_EVENT_SIGNAL` | 50000 | 5 us | 40 us |
| STEADY_IO | IRQ | `HV_IRQ_EVENT_WAKEUP` | 20000 | 8 us | 90 us |

## 表 2：抽象服务到 Linux 实现的映射

| Host Service | Linux/KVM/QEMU Evidence |
|---|---|
| `HV_MEM_ALLOC_BACKING` | `mmap`, `madvise`, `mlock` |
| `HV_MEM_REGISTER_GPA_RANGE` | `KVM_SET_USER_MEMORY_REGION` |
| `HV_VCPU_ENTER` | `KVM_RUN`, `kvm:kvm_entry`, `kvm:kvm_exit` |
| `HV_EVENT_CREATE` | `eventfd2` |
| `HV_EVENT_WAIT` | `epoll_wait`, `futex` |
| `HV_IRQ_BIND_EVENT` | `KVM_IRQFD` |
| `HV_IO_BIND_EVENT` | `KVM_IOEVENTFD` |
| `HV_IO_MMIO_EMULATION_REQUEST` | `KVM_EXIT_MMIO`, `kvm_mmio` |
| `HV_DMA_MAP` | `VFIO_IOMMU_MAP_DMA`, `iommu_map` |

## 表 3：可移植性评估

| Service | 是否必须 | 可移植性 | 说明 |
|---|---|---|---|
| `HV_MEM_ALLOC_BACKING` | 必须 | 高 | 所有 OS 都应提供内存分配/映射能力 |
| `HV_MEM_REGISTER_GPA_RANGE` | 必须 | 中 | 语义通用，但 Linux 通过 KVM memslot 实现 |
| `HV_VCPU_ENTER` | 必须 | 中 | 依赖硬件虚拟化和架构上下文切换 |
| `HV_IRQ_BIND_EVENT` | 可选优化 | 中 | eventfd/irqfd 是 Linux 形态，语义可抽象 |
| `HV_IO_BIND_EVENT` | 可选优化 | 中 | ioeventfd 是 Linux/KVM 优化路径 |
| `HV_DMA_MAP` | 设备直通时必须 | 低/中 | 强依赖 IOMMU/VFIO/设备模型 |

---

# 10. 推荐的工程落地顺序

## Step 0：固定实验环境

先不要多平台。第一版固定：

```text
Host: Linux + KVM
VMM: QEMU
Guest: Linux guest
Workload:
  1. boot
  2. idle
  3. memory stress
  4. disk I/O
  5. network I/O
```

每个 workload 都跑同一套采集器。否则你们分不清是架构依赖，还是 workload 差异。

---

## Step 1：生命周期 phase marker

你们需要给 trace 加阶段标签。

最简单方式是 wrapper 脚本写 trace marker：

```bash
echo "PHASE=VM_CREATE" | sudo tee /sys/kernel/tracing/trace_marker

qemu-system-x86_64 ... -enable-kvm &

echo "PHASE=VM_BOOT" | sudo tee /sys/kernel/tracing/trace_marker

# 等 guest boot 完
echo "PHASE=STEADY_IDLE" | sudo tee /sys/kernel/tracing/trace_marker

# 运行 workload
echo "PHASE=STEADY_IO" | sudo tee /sys/kernel/tracing/trace_marker

# 关闭 VM
echo "PHASE=VM_DESTROY" | sudo tee /sys/kernel/tracing/trace_marker
```

更稳定的做法是：runner 进程自己维护 phase，并在采集结果后处理时按时间戳归类。

---

## Step 2：先用 strace + trace-cmd 验证事件

第一版不用直接写复杂 eBPF 程序，先用现成工具验证口径。

```bash
sudo strace -ff -tt -T \
  -e trace=ioctl,mmap,munmap,mprotect,madvise,eventfd2,epoll_ctl,epoll_wait,futex,clone,sched_setaffinity,timerfd_create,timerfd_settime \
  -o /tmp/qemu.strace \
  qemu-system-x86_64 ... -enable-kvm
```

再抓 KVM tracepoint：

```bash
sudo trace-cmd record \
  -e kvm:kvm_entry \
  -e kvm:kvm_exit \
  -e kvm:kvm_userspace_exit \
  -e kvm:kvm_mmio \
  -e kvm:kvm_pio
```

验证目标：

```text
能不能分出 VM_CREATE / VM_BOOT / STEADY_IO？
能不能看到 KVM_RUN？
能不能看到 memory region 注册？
能不能看到 MMIO/PIO exit？
能不能看到 eventfd / epoll / futex？
```

---

## Step 3：写正式 eBPF collector

验证口径后，再写正式采集器。

建议用：

```text
libbpf + CO-RE
```

而不是长期依赖 bpftrace。libbpf 支持 BPF 程序的 open/load/attach 生命周期，BPF 程序可以附加到 tracepoints、kprobes 等 hook；CO-RE 则支持编译一次、在多个内核版本上运行。

collector 可以分成几个模块：

```text
collector_syscall.bpf.c
collector_kvm_ioctl.bpf.c
collector_kvm_tracepoint.bpf.c
collector_kprobe_memory.bpf.c
collector_kprobe_event.bpf.c
```

用户态程序负责：

```text
加载 BPF
读取 ring buffer
解码 ioctl number
关联 pid/tid/phase
写 JSONL/Parquet
```

---

# 11. 最小 MVP 的采集范围

第一版我建议只做这些：

```text
syscall:
  mmap, munmap, mprotect, madvise
  eventfd2
  epoll_ctl, epoll_wait
  futex
  clone
  sched_setaffinity
  ioctl

KVM ioctl:
  KVM_CREATE_VM
  KVM_CREATE_VCPU
  KVM_SET_USER_MEMORY_REGION
  KVM_RUN
  KVM_IRQFD
  KVM_IOEVENTFD
  KVM_SET_GSI_ROUTING
  KVM_INTERRUPT
  KVM_GET_DIRTY_LOG

KVM tracepoint:
  kvm_entry
  kvm_exit
  kvm_userspace_exit
  kvm_mmio
  kvm_pio
  kvm_page_fault

kprobe:
  eventfd_signal
  try_to_wake_up
  __alloc_pages
  mmu_notifier_register
```

这已经足够形成第一版 Host Service Abstraction 矩阵。

---

# 12. 不建议一开始做什么

我不建议一开始做这几件事：

```text
1. 不要全量 ftrace function_graph
   噪声太大，后处理困难。

2. 不要直接把 Linux 函数名当抽象接口
   例如不要设计 hv_eventfd_signal()，应该设计 hv_event_signal()。

3. 不要只看 QEMU
   只看 QEMU 会漏掉 KVM 内核内部依赖。

4. 不要只看 KVM tracepoint
   只看 tracepoint 会漏掉 VMM 对 host OS 的 mmap、futex、eventfd、epoll 依赖。

5. 不要把 hypercall 作为主线
   hypercall 是 Guest→Hypervisor，不是 Hypervisor→Host OS。
```

---

# 13. 我建议你们最终抽象成这些 Host Service

第一版可以定义为：

```text
HV_VM_CREATE
HV_VM_DESTROY

HV_VCPU_CREATE
HV_VCPU_ENTER
HV_VCPU_EXIT
HV_VCPU_KICK
HV_VCPU_PIN
HV_VCPU_BLOCK
HV_VCPU_WAKE

HV_MEM_ALLOC_BACKING
HV_MEM_FREE_BACKING
HV_MEM_REGISTER_GPA_RANGE
HV_MEM_UNREGISTER_GPA_RANGE
HV_MEM_PROTECT_GPA_RANGE
HV_MEM_STAGE2_FAULT_HANDLE
HV_MEM_DIRTY_LOG_READ
HV_MEM_DIRTY_LOG_CLEAR
HV_MEM_PIN_USER_PAGES
HV_MEM_HOST_MAPPING_NOTIFY

HV_IRQ_ROUTE_CONFIG
HV_IRQ_INJECT
HV_IRQ_BIND_EVENT
HV_IRQ_WINDOW_REQUEST

HV_EVENT_CREATE
HV_EVENT_SIGNAL
HV_EVENT_WAIT
HV_EVENT_POLL
HV_EVENT_BIND_IO

HV_IO_MMIO_EMULATION_REQUEST
HV_IO_PORT_EMULATION_REQUEST
HV_IO_REGISTER_REGION
HV_IO_BIND_EVENT

HV_TIMER_CREATE
HV_TIMER_ARM
HV_CLOCK_READ

HV_SYNC_WAIT
HV_SYNC_WAKE
HV_SYNC_LOCK
HV_SYNC_RCU

HV_DMA_MAP
HV_DMA_UNMAP
HV_IOMMU_ATTACH
HV_IOMMU_DETACH
```

这组抽象不应该完全等价于 KVM API，而应该表达“任何 OS 如果想承载这个 hypervisor，需要提供什么能力”。

---

# 14. 最重要的工程原则

你们的统计系统要保留三层信息：

```text
Raw layer:
  Linux 真实事件
  例如 mmap, ioctl(KVM_RUN), kvm_exit, eventfd_signal

Semantic layer:
  架构无关服务
  例如 HV_VCPU_ENTER, HV_EVENT_SIGNAL

Evidence layer:
  为什么这样归类
  例如 KVM_RUN 是 vCPU ioctl，用于运行 guest vCPU
```

也就是说，最后不要只输出：

```text
HV_MEM_REGISTER_GPA_RANGE: 4 次
```

而要输出：

```text
HV_MEM_REGISTER_GPA_RANGE:
  count: 4
  phase: VM_CREATE
  evidence:
    - ioctl(KVM_SET_USER_MEMORY_REGION)
  attributes:
    - gpa
    - size
    - slot
```

这样你们的结果才是可审计、可复现、可迁移的。

---

## 一句话落地建议

工程上先做一个 **Linux/KVM/QEMU Host Service Profiler**：

```text
输入：
  QEMU 命令行 + workload + phase markers

采集：
  syscall + KVM ioctl + KVM tracepoint + 少量 targeted kprobe

输出：
  raw_events.jsonl
  service_mapping.yaml
  host_service_matrix.csv
  phase_service_report.html
```

第一版只覆盖内存、vCPU、事件/中断、I/O 四类服务。跑通后，再扩展到 DMA/IOMMU、迁移、confidential VM、设备直通、多架构。