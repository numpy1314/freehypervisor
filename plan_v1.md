# HHAL Host Service Dependency Profiler — 初版方案

## 目标

构建一个 **Linux/KVM/QEMU Host Service Profiler**，自动采集 hypervisor 对宿主 OS 的能力依赖，输出架构无关的 **Host Service Dependency Matrix**。

这是 HHAL（Hypervisor Host Abstraction Layer）论文的第一个工程交付物，核心目的是回答：

> **一个通用 hypervisor 运行时，到底依赖宿主 OS 提供哪些服务？**

---

## 输出物

| 文件 | 说明 |
|---|---|
| `raw_events.jsonl` | 原始事件流，每行一条 |
| `mapping.yaml` | 事件→抽象服务的映射规则 |
| `host_service_matrix.csv` | 按服务类×生命周期阶段的频率矩阵 |
| `phase_service_report.md` | 可读报告 |

---

## 架构：三组件 Pipeline

```
┌──────────────────┐     ┌──────────────┐     ┌──────────────┐
│   runner.sh      │────>│ analyze.py   │────>│  报告输出     │
│  采集+标注阶段    │     │ 解析+映射+统计│     │  CSV / MD    │
└──────────────────┘     └──────────────┘     └──────────────┘
         │                       ▲
         │                       │
         ▼                       │
  raw_events.jsonl        mapping.yaml
```

**不做**独立的后台采集守护进程，不做 eBPF C 程序，不做实时仪表盘。v1 的核心是 **strace + trace-cmd 采集 → Python 解析 → YAML 映射 → 报告**。

---

## 组件 1：`runner.sh` — 采集 + 阶段标注

### 职责

1. 启动 QEMU VM（最小配置）
2. 用 strace 采集 QEMU 的 syscall/ioctl
3. 用 trace-cmd 采集 KVM tracepoint
4. 通过时间戳标注 VM 生命周期阶段

### 阶段定义

| 阶段 | 标注方式 | 说明 |
|---|---|---|
| `VM_CREATE` | QEMU 启动前 → 首次 `KVM_RUN` 之前 | VM 创建、内存注册、vCPU 创建 |
| `VM_BOOT` | 首次 `KVM_RUN` → guest boot 完成 | guest 内核启动，大量 MMIO/PIO |
| `STEADY_IDLE` | boot 完成 → workload 开始 | guest 空闲，vCPU HLT/wake 循环 |
| `STEADY_IO` | workload 运行期间 | guest 执行 disk/network I/O |
| `VM_DESTROY` | QEMU 退出 | 资源释放 |

### 最小 QEMU 配置

```bash
qemu-system-x86_64 \
  -enable-kvm \
  -m 512 \
  -smp 1 \
  -nographic \
  -kernel "${VMLINUZ}" \
  -initrd "${INITRD}" \
  -append "console=ttyS0 quiet" \
  -drive file="${DISK}",format=raw,if=virtio
```

**不用**完整镜像，用 `-kernel + -initrd` 方式启动最小 Linux guest，确保可复现。

### 采集命令

```bash
# strace：抓 QEMU 用户态 syscall
sudo strace -ff -tt -T -o "${OUTDIR}/strace/qemu" \
  -e trace=ioctl,mmap,munmap,mprotect,madvise,mlock,eventfd2,\
epoll_create1,epoll_ctl,epoll_wait,futex,clone,sched_setaffinity,\
timerfd_create,timerfd_settime,clock_gettime,read,write,close \
  qemu-system-x86_64 ...

# trace-cmd：抓 KVM 内核 tracepoint
sudo trace-cmd record -o "${OUTDIR}/trace.dat" \
  -e kvm:kvm_entry -e kvm:kvm_exit \
  -e kvm:kvm_userspace_exit \
  -e kvm:kvm_mmio -e kvm:kvm_pio \
  -p nop -a
```

### 阶段标注策略

runner.sh 内部维护一个 `TIMESTAMP` 文件，记录每个阶段切换的精确时间：

```
VM_CREATE 1716000000.000000
VM_BOOT   1716000001.234567
...
```

分析阶段按时间戳归类每条事件。

---

## 组件 2：`mapping.yaml` — 事件→抽象服务映射

### 设计原则

- 映射规则 **不硬编码** 在 Python 代码中，而是维护在 YAML 文件
- 每条规则：`source + raw_name → service_class + service_name + direction`
- 后续扩展只需编辑 YAML（加新 kprobe、加新 OS 的映射）

### v1 映射范围

```yaml
# === syscall 层 ===
- source: syscall
  raw_name: mmap
  service_class: MEMORY
  service_name: HV_MEM_ALLOC_BACKING
  direction: VMM_TO_HOST_OS

- source: syscall
  raw_name: munmap
  service_class: MEMORY
  service_name: HV_MEM_FREE_BACKING
  direction: VMM_TO_HOST_OS

- source: syscall
  raw_name: mprotect
  service_class: MEMORY
  service_name: HV_MEM_PROTECT
  direction: VMM_TO_HOST_OS

- source: syscall
  raw_name: madvise
  service_class: MEMORY
  service_name: HV_MEM_ADVISE
  direction: VMM_TO_HOST_OS

- source: syscall
  raw_name: mlock
  service_class: MEMORY
  service_name: HV_MEM_PIN
  direction: VMM_TO_HOST_OS

- source: syscall
  raw_name: eventfd2
  service_class: EVENT
  service_name: HV_EVENT_CREATE
  direction: VMM_TO_HOST_OS

- source: syscall
  raw_name: epoll_create1
  service_class: EVENT
  service_name: HV_EVENT_POLL_INIT
  direction: VMM_TO_HOST_OS

- source: syscall
  raw_name: epoll_ctl
  service_class: EVENT
  service_name: HV_EVENT_POLL_CTL
  direction: VMM_TO_HOST_OS

- source: syscall
  raw_name: epoll_wait
  service_class: EVENT
  service_name: HV_EVENT_POLL_WAIT
  direction: VMM_TO_HOST_OS

- source: syscall
  raw_name: futex
  service_class: SYNC
  service_name: HV_SYNC_FUTEX
  direction: VMM_TO_HOST_OS

- source: syscall
  raw_name: clone
  service_class: THREAD
  service_name: HV_THREAD_CREATE
  direction: VMM_TO_HOST_OS

- source: syscall
  raw_name: sched_setaffinity
  service_class: THREAD
  service_name: HV_VCPU_PIN
  direction: VMM_TO_HOST_OS

- source: syscall
  raw_name: timerfd_create
  service_class: TIMER
  service_name: HV_TIMER_CREATE
  direction: VMM_TO_HOST_OS

- source: syscall
  raw_name: timerfd_settime
  service_class: TIMER
  service_name: HV_TIMER_ARM
  direction: VMM_TO_HOST_OS

# === KVM ioctl 层 ===
- source: ioctl
  raw_name: KVM_CREATE_VM
  service_class: VM
  service_name: HV_VM_CREATE
  direction: VMM_TO_HOST_KERNEL

- source: ioctl
  raw_name: KVM_CREATE_VCPU
  service_class: VCPU
  service_name: HV_VCPU_CREATE
  direction: VMM_TO_HOST_KERNEL

- source: ioctl
  raw_name: KVM_RUN
  service_class: VCPU
  service_name: HV_VCPU_ENTER
  direction: VMM_TO_HOST_KERNEL

- source: ioctl
  raw_name: KVM_SET_USER_MEMORY_REGION
  service_class: MEMORY
  service_name: HV_MEM_REGISTER_GPA_RANGE
  direction: VMM_TO_HOST_KERNEL

- source: ioctl
  raw_name: KVM_IRQFD
  service_class: IRQ
  service_name: HV_IRQ_BIND_EVENT
  direction: VMM_TO_HOST_KERNEL

- source: ioctl
  raw_name: KVM_IOEVENTFD
  service_class: IO
  service_name: HV_IO_BIND_EVENT
  direction: VMM_TO_HOST_KERNEL

- source: ioctl
  raw_name: KVM_SET_GSI_ROUTING
  service_class: IRQ
  service_name: HV_IRQ_ROUTE_CONFIG
  direction: VMM_TO_HOST_KERNEL

- source: ioctl
  raw_name: KVM_INTERRUPT
  service_class: IRQ
  service_name: HV_IRQ_INJECT
  direction: VMM_TO_HOST_KERNEL

- source: ioctl
  raw_name: KVM_GET_DIRTY_LOG
  service_class: MEMORY
  service_name: HV_MEM_DIRTY_LOG_READ
  direction: VMM_TO_HOST_KERNEL

- source: ioctl
  raw_name: KVM_SET_CPUID2
  service_class: VCPU
  service_name: HV_VCPU_SET_CPUID
  direction: VMM_TO_HOST_KERNEL

- source: ioctl
  raw_name: KVM_GET_REGS
  service_class: VCPU
  service_name: HV_VCPU_GET_REGS
  direction: VMM_TO_HOST_KERNEL

- source: ioctl
  raw_name: KVM_SET_REGS
  service_class: VCPU
  service_name: HV_VCPU_SET_REGS
  direction: VMM_TO_HOST_KERNEL

- source: ioctl
  raw_name: KVM_GET_SREGS
  service_class: VCPU
  service_name: HV_VCPU_GET_SREGS
  direction: VMM_TO_HOST_KERNEL

- source: ioctl
  raw_name: KVM_SET_SREGS
  service_class: VCPU
  service_name: HV_VCPU_SET_SREGS
  direction: VMM_TO_HOST_KERNEL

- source: ioctl
  raw_name: KVM_GET_MSRS
  service_class: VCPU
  service_name: HV_VCPU_GET_MSRS
  direction: VMM_TO_HOST_KERNEL

- source: ioctl
  raw_name: KVM_SET_MSRS
  service_class: VCPU
  service_name: HV_VCPU_SET_MSRS
  direction: VMM_TO_HOST_KERNEL

# === KVM tracepoint 层 ===
- source: tracepoint
  raw_name: kvm_exit
  service_class: VCPU
  service_name: HV_VCPU_EXIT
  direction: HYPERVISOR_TO_VMM

- source: tracepoint
  raw_name: kvm_entry
  service_class: VCPU
  service_name: HV_VCPU_ENTRY
  direction: HYPERVISOR_INTERNAL

- source: tracepoint
  raw_name: kvm_userspace_exit
  service_class: VCPU
  service_name: HV_VCPU_USERSPACE_EXIT
  direction: HYPERVISOR_TO_VMM

- source: tracepoint
  raw_name: kvm_mmio
  service_class: IO
  service_name: HV_IO_MMIO_EMULATION_REQUEST
  direction: HYPERVISOR_TO_VMM

- source: tracepoint
  raw_name: kvm_pio
  service_class: IO
  service_name: HV_IO_PORT_EMULATION_REQUEST
  direction: HYPERVISOR_TO_VMM

- source: tracepoint
  raw_name: kvm_page_fault
  service_class: MEMORY
  service_name: HV_MEM_STAGE2_FAULT_HANDLE
  direction: HYPERVISOR_INTERNAL
```

---

## 组件 3：`analyze.py` — 解析 + 映射 + 统计

### 输入

- `strace/*.log` — strace 输出文件（每个 QEMU 线程一个）
- `trace.dat` — trace-cmd 二进制文件（`trace-cmd report` 转文本后解析）
- `mapping.yaml`
- `phases.tsv` — 阶段时间戳

### 处理流程

```
parse_strace()
  strace 文本 → 统一事件列表
  解码 ioctl number → KVM_* 名称（查 ioctl_decode 表）

parse_tracecmd()
  trace-cmd report 文本 → 统一事件列表

load_mapping()
  mapping.yaml → { (source, raw_name): (service_class, service_name, direction) }

normalize()
  统一事件 × mapping → 语义事件列表（附加 service_class, service_name, phase）

generate_reports()
  → host_service_matrix.csv
  → phase_service_report.md
```

### strace 解析逻辑

strace 输出格式形如：

```
1234  1716000000.123456 ioctl(17, KVM_RUN, 0) = 0 <0.001234>
```

正则提取：

| 字段 | 来源 |
|---|---|
| `pid` | 行首数字 |
| `timestamp` | 第二列 |
| `syscall` | `ioctl(...)` 中的函数名 |
| `raw_name` | 非 ioctl 时=syscall 名；ioctl 时解码为 `KVM_*` |
| `latency_ns` | `<...>` 括号内秒数转纳秒 |
| `result` | `= N` 或 `= -1 ...` |

### ioctl 解码

v1 用 Python 字典硬编码 ioctl number→名称映射（从 `<linux/kvm.h>` 提取）：

```python
KVM_IOCTL_MAP = {
    0xae00: "KVM_CREATE_VM",
    0xae01: "KVM_CREATE_VCPU",
    0xae02: "KVM_RUN",
    0xae08: "KVM_SET_USER_MEMORY_REGION",
    0xae76: "KVM_IRQFD",
    0xae79: "KVM_IOEVENTFD",
    # ... 从 kvm.h 补全
}
```

> **为什么不用 strace 自带的解码？** strace 可以解码 KVM ioctl 名称，但 `-ff` 多线程模式下不同线程的输出格式不完全一致，且 strace 解码依赖版本。我们自己做二次解码更可控。

### trace-cmd 解析

```bash
trace-cmd report trace.dat > trace_report.txt
```

输出格式形如：

```
qemu-system-x86-1234 [000] 1716000000.123456: kvm_exit: reason EPT_VIOLATION ...
```

正则提取 `kvm_exit`、`kvm_entry`、`kvm_mmio` 等 tracepoint 名称及参数。

### 统计输出

**表 1：服务×阶段频率矩阵** (`host_service_matrix.csv`)

```csv
service_class,service_name,VM_CREATE,VM_BOOT,STEADY_IDLE,STEADY_IO,VM_DESTROY,total
MEMORY,HV_MEM_ALLOC_BACKING,12,0,0,0,0,12
MEMORY,HV_MEM_REGISTER_GPA_RANGE,4,0,0,0,0,4
VCPU,HV_VCPU_ENTER,0,18000,5000,15000,0,38000
...
```

**表 2：服务摘要** (`phase_service_report.md`)

```markdown
## MEMORY 服务
| Service | Evidence | 总次数 | 主要阶段 |
|---|---|---:|---|
| HV_MEM_ALLOC_BACKING | mmap | 12 | VM_CREATE |
| HV_MEM_REGISTER_GPA_RANGE | KVM_SET_USER_MEMORY_REGION | 4 | VM_CREATE |
...

## VCPU 服务
...
```

---

## 目录结构

```
freehypervisor/
├── plan_v1.md              # 本文件
├── profiler/
│   ├── runner.sh           # 采集脚本
│   ├── analyze.py          # 解析+映射+统计
│   ├── mapping.yaml        # 事件→抽象服务映射规则
│   ├── kvm_ioctl_map.py    # ioctl number → 名称表
│   └── requirements.txt    # Python 依赖（pyyaml）
├── data/                   # 采集数据输出目录
│   ├── raw_events.jsonl
│   ├── host_service_matrix.csv
│   └── phase_service_report.md
└── chatgpt-export_统计KVM hypercall请求.md
```

---

## 设计决策与理由

### 1. 为什么 v1 用 strace 而不是 eBPF？

| 维度 | strace | eBPF/bpftrace |
|---|---|---|
| 上手成本 | 零，系统自带 | 需要 BTF/CO-RE 环境配置 |
| 输出可读性 | 直接输出 syscall 名+参数 | 需要后处理 ioctl number |
| 开销 | 较高（ptrace），但 v1 采集时间短（分钟级）可接受 | 低，但开发成本高 |
| 覆盖范围 | 完整 syscall + 参数 | 需要逐个写 probe |
| 可控性 | 输出格式稳定，正则可解析 | 依赖内核版本、BTF |

**结论**：v1 的目标是 **验证口径**（我们统计的东西有没有意义），不是追求低开销长期采集。strace 10 分钟内就能跑完一轮完整采集→分析→报告。等口径验证后，v2 再用 eBPF 替换。

### 2. 为什么映射规则放 YAML 而不硬编码？

- **可审计**：审稿人/reviewer 可以直接看映射表，不需要读代码
- **可扩展**：后续加 seL4/RTOS 映射只需新建 `mapping_sel4.yaml`
- **可迭代**：发现新依赖只需加一行 YAML，不改 Python 逻辑
- **论文 artifact**：`mapping.yaml` 本身就是论文要展示的 deliverable

### 3. 为什么 v1 只统计次数，不统计延迟？

- strace 的 `<T>` 延迟受 ptrace 开销干扰，**不够准确**，不能作为论文数据
- v1 的核心问题是 **完整性**（有没有遗漏的服务依赖），不是性能
- 延迟/性能数据留给 v2（eBPF，低开销，数据可用）

### 4. 为什么用最小 guest 而不是完整 VM 镜像？

- `-kernel + -initrd` 方式启动最小 Linux，**可复现**、启动快（秒级）
- 完整镜像引入不必要的变量（cloud-init、systemd、多设备），干扰依赖分析
- 后续可以逐步加 workload（stress-ng、fio、iperf）来扩展依赖面

### 5. 为什么 v1 不做 kprobe？

- kprobe 探测内核函数（如 `__alloc_pages`、`eventfd_signal`），回答的是 "KVM 内部依赖了哪些 Linux kernel primitive"
- 但这需要：确认函数名在不同内核版本存在、处理 inline 函数不可 probe 的问题、处理噪声过滤
- **ROI 太低**：v1 用 syscall + KVM ioctl + KVM tracepoint 已经能覆盖 **VMM→Host OS** 这一层的主要依赖面
- kprobe 留给 v2，在 v1 口径验证后再加

### 6. 为什么 trace-cmd 而不是 perf？

- `trace-cmd report` 输出纯文本，格式稳定，容易正则解析
- `perf script` 输出格式受 perf 版本和配置影响较大
- trace-cmd 直接读 ftrace buffer，不依赖 perf 的采样模型

---

## v1 明确不做的事

| 不做 | 原因 |
|---|---|
| eBPF 采集器 | 开发成本高，v1 先用 strace 验证口径 |
| kprobe 采集 | v1 覆盖用户态+KVM API 已足够，内核内部依赖留给 v2 |
| 延迟统计 | strace ptrace 开销导致延迟不可信 |
| 多架构（ARM/RISC-V） | v1 固定 x86_64，先跑通 pipeline |
| 设备直通/VFIO | 需要硬件支持，且依赖面复杂，v1 先覆盖基础路径 |
| live migration | 非 v1 范围 |
| confidential VM (TDX/SEV) | 非 v1 范围 |
| 实时仪表盘/Web UI | 过度工程 |

---

## 验证标准

v1 完成后，应能回答以下问题：

1. **能跑通**：`runner.sh` → `analyze.py` → 报告输出，全流程无人工干预
2. **能区分阶段**：报告中有 5 个阶段列，VM_CREATE 阶段能看到 `HV_MEM_REGISTER_GPA_RANGE`、`HV_VCPU_CREATE` 等
3. **能覆盖核心服务**：报告中有 MEMORY、VCPU、IRQ、EVENT、IO 五个 service_class
4. **结果可解释**：每个 service_name 都能回溯到具体的 Linux 机制（strace 行或 tracepoint）
5. **映射可编辑**：修改 `mapping.yaml` 后重新跑 `analyze.py`，报告跟着变

---

## 后续演进路线（v1 之后）

```
v1 (当前)
  strace + trace-cmd + YAML mapping + Python 分析
  覆盖：MEMORY / VCPU / IRQ / EVENT / IO 五类服务
  │
  ▼
v2
  eBPF 采集器（libbpf + CO-RE）替换 strace
  加 kprobe 采集内核内部依赖
  加延迟统计（P50/P99）
  │
  ▼
v3
  多 workload 对比（idle / cpu / mem / disk / net）
  多 VMM 对比（QEMU vs Firecracker vs crosvm）
  多架构（ARM KVM）
  │
  ▼
v4
  HHAL API 定义（hhal.h）
  Linux/KVM 后端实现（hhal_linux.c）
  最小 VMM 验证（基于 HHAL 启动 guest）
```
