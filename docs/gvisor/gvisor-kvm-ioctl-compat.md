# gVisor KVM platform 的 /dev/kvm 接口需求与 axvisor_kvm.ko 兼容性分析

分析对象：gVisor（`runsc`）的 `pkg/sentry/platform/kvm`，即 `--platform=kvm` 模式。
gVisor 源码：`/home/bullet1517/agentos-explore/src/gvisor`（commit `47af468`）。
被测 shim：`linux-host-kernel/drivers/virt/axvisor/axvisor_kvm_main.c`。

目的：与 Firecracker 同一路线，把 gVisor 当作另一个用户态 VMM 跑在我们魔改的 KVM 兼容层
（`axvisor_kvm.ko`）之上，以此测量 shim 的 KVM-API 兼容面。本文档只做源码级接口需求
分析与逐项交叉核对，不涉及运行。

## 1. gVisor KVM platform 的角色（与 Firecracker 的本质区别）

gVisor 的 KVM platform 不是传统 VMM：它没有独立的 hypervisor 进程，也不虚拟化任何硬件设备。
Sentry 进程本身同时扮演 guest OS 和 VMM 两个角色，直接 `open("/dev/kvm")` 并用 ioctl 驱动。

- 正常虚拟化：VMX root = hypervisor，VMX non-root = guest OS。
- gVisor KVM：把 **Sentry 自己**放进 VMX non-root 执行（"bluepill"），利用 EPT/页表做地址空间
  隔离，VM-exit 时回到 root 侧的 KVM 处理。它借用 KVM 只是为了拿到一个隔离的地址空间 +
  快速的 ring 切换，**不跑独立 guest 内核**。

对 shim 的含义：gVisor 用到的 ioctl 子集比 Firecracker 窄（没有 IRQCHIP/PIT/LAPIC 一整套设备
模型），但对 `KVM_RUN` 退出语义、`KVM_INTERRUPT` 注入、MSR/CPUID 处理的**精确性**要求更高，
因为 guest 侧跑的是 Sentry 自己的裸机代码，任何语义偏差都会直接 `throw()` 崩溃。

## 2. gVisor 在 amd64 上实际使用的 KVM ioctl 全集（源码级）

来源：`kvm_const.go`（ioctl 号定义）+ `*.go`/`*.s` 调用点 grep + `filters_amd64.go`（seccomp 白名单）。

### 2.1 系统 fd（`/dev/kvm`）级

| ioctl | ioctl 号 | 调用点 | 是否强制 |
|---|---|---|---|
| `KVM_GET_API_VERSION` | 0xae00 | 打开设备后校验 | 是 |
| `KVM_CREATE_VM` | 0xae01 | `kvm.go` New | 是 |
| `KVM_GET_VCPU_MMAP_SIZE` | 0xae04 | mmap kvm_run 前 | 是 |
| `KVM_CHECK_EXTENSION` | 0xae03 | 探测 CAP | 是 |
| `KVM_GET_SUPPORTED_CPUID` | 0xc008ae05 | 传给 SET_CPUID2 | 是 |

### 2.2 VM fd 级

| ioctl | ioctl 号 | 调用点 | 是否强制 |
|---|---|---|---|
| `KVM_CREATE_VCPU` | 0xae41 | 每 vCPU | 是 |
| `KVM_SET_USER_MEMORY_REGION` | 0x4020ae46 | 注册物理内存 slot | 是 |
| `KVM_SET_TSS_ADDR` | 0xae47 | Intel VMX 需要 | 是（Intel） |
| `KVM_IOEVENTFD` | 0x4040ae79 | ioeventfd（可选设备） | 否（gVisor 基本不用） |

### 2.3 vCPU fd 级

| ioctl | ioctl 号 | 调用点 | 是否强制 |
|---|---|---|---|
| `KVM_RUN` | 0xae80 | bluepill 主循环 | 是 |
| `KVM_SET_REGS` / `KVM_GET_REGS` | 0x4090ae82 / 0x8090ae81 | 设置/读取通用寄存器 | 是 |
| `KVM_SET_SREGS` / `KVM_GET_SREGS` | 0x4138ae84 / 0x8138ae83 | 段/控制寄存器、页表基址 | 是 |
| `KVM_SET_CPUID2` | 0x4008ae90 | 灌入 CPUID | 是 |
| `KVM_GET_MSRS` / `KVM_SET_MSRS` | 0xc008ae88 / 0x4008ae89 | 时间校准、CPUID faulting、TSC | 是 |
| `KVM_SET_SIGNAL_MASK` | 0x4004ae8b | vCPU 线程信号掩码 | 是 |
| `KVM_INTERRUPT` | 0x4004ae86 | **抢占核心机制**（见 §3） | **是** |
| `KVM_NMI` | 0xae9a | SIGBUS→NMI 注入 | 是（内存故障路径） |
| `KVM_GET_VCPU_EVENTS` / `KVM_SET_VCPU_EVENTS` | 0x8040ae9f / 0x4040aea0 | 事件状态 | 视配置 |
| `KVM_GET_TSC_KHZ` / `KVM_SET_TSC_KHZ` | 0xaea3 / 0xaea2 | TSC scaling（可降级） | 否 |
| `KVM_SET_DEVICE_ATTR` | 0x4018aee1 | TSC offset 置零（可降级） | 否 |
| `KVM_ENABLE_CAP` | 0x4068aea3 | CPUID faulting 等（非致命） | 否 |

### 2.4 seccomp 运行期热路径白名单（`filters_amd64.go` + `filters.go`）

初始化完成后，Sentry 的 seccomp 只放行这几个 KVM ioctl（其余在运行期被拦）：
`KVM_RUN`、`KVM_INTERRUPT`、`KVM_NMI`、`KVM_GET_REGS`、`KVM_SET_REGS`、
`KVM_SET_USER_MEMORY_REGION`、`KVM_IOEVENTFD`。
这印证了运行期真正的热路径就是 **RUN + 中断/NMI 注入 + REGS + 内存 slot 动态调整**。

## 3. 关键语义：gVisor 的抢占依赖 KVM_INTERRUPT（不是设备中断）

`bluepill_amd64_unsafe.go:bluepillStopGuest()`：

```
// 请求过 interrupt window 后，在 IRQ-window 退出时注入一个 bounce 中断
ioctl(vcpu_fd, KVM_INTERRUPT, &bounce);  // 失败即 throw("interrupt injection failed")
c.runData.requestInterruptWindow = 0;
```

机制：当宿主需要抢占正在 non-root 执行的 Sentry（如信号到达、需要回 host）时，gVisor 置
`kvm_run.request_interrupt_window=1`，下次 `KVM_RUN` 因 IRQ window 打开而退出
（`KVM_EXIT_IRQ_WINDOW_OPEN`），随即用 `KVM_INTERRUPT` 注入一个哑中断把 guest 弹出。
这是 gVisor 的**唯一抢占原语**，每次上下文切换都会走到，且失败是硬崩溃。

`bluepillSigBus()`：内存访问触发 SIGBUS 时用 `KVM_NMI` 注入 NMI，同样硬崩溃。

对 shim 的含义：要跑 gVisor，`axvisor_kvm.ko` 必须：
1. 正确实现 `KVM_INTERRUPT`（把中断号写入待注入队列 / VMCS event injection），并且
2. 正确处理 `kvm_run.request_interrupt_window`，在中断窗口打开时产生
   `KVM_EXIT_IRQ_WINDOW_OPEN` 退出，
3. 实现 `KVM_NMI`。

## 4. 与 axvisor_kvm.ko 的逐项交叉核对（缺口清单）

核对方法：grep `case KVM_*:` 于 `axvisor_kvm_main.c`。

### 4.1 已实现（gVisor 需要且 shim 有）
`KVM_GET_API_VERSION`、`KVM_CREATE_VM`、`KVM_GET_VCPU_MMAP_SIZE`、`KVM_CHECK_EXTENSION`、
`KVM_GET_SUPPORTED_CPUID`、`KVM_CREATE_VCPU`、`KVM_SET_USER_MEMORY_REGION`、`KVM_SET_TSS_ADDR`、
`KVM_RUN`、`KVM_GET_REGS`/`KVM_SET_REGS`、`KVM_GET_SREGS`/`KVM_SET_SREGS`、`KVM_SET_CPUID2`、
`KVM_GET_CPUID2`、`KVM_GET_MSRS`/`KVM_SET_MSRS`、`KVM_SET_SIGNAL_MASK`、
`KVM_GET_VCPU_EVENTS`/`KVM_SET_VCPU_EVENTS`、`KVM_GET_TSC_KHZ`/`KVM_SET_TSC_KHZ`、
`KVM_IOEVENTFD`。

### 4.2 缺口（gVisor 需要，shim 目前无 `case`）

| ioctl | gVisor 用途 | 阻塞级别 | 说明 |
|---|---|---|---|
| **`KVM_INTERRUPT`** | 抢占注入（§3） | **致命/必补** | shim 内 `case KVM_INTERRUPT:` grep 计数=0。无它 gVisor 每次抢占即 throw。 |
| **`KVM_NMI`** | SIGBUS→NMI（§3） | 高（内存故障路径必崩） | shim 内计数=0。 |
| `KVM_ENABLE_CAP` | CPUID faulting 等 | 低（非致命，仅告警） | 可返回 `-EINVAL`，gVisor 只打印警告继续。 |
| `KVM_SET_DEVICE_ATTR` | TSC offset 置零 | 低（可降级） | 失败会走 `setSystemTimeLegacy()`。 |

### 4.3 可降级路径（重要：这些失败不阻塞 gVisor 启动）

`machine_amd64.go:setSystemTime()` 的降级链（源码逐行确认）：
1. 先试 `setTSCOffset()`（`KVM_SET_DEVICE_ATTR`）——失败则
2. 若 `!machine.tscControl`（即 `KVM_CHECK_EXTENSION(KVM_CAP_TSC_CONTROL)` 返回 0）→ 直接
   `setSystemTimeLegacy()`；
3. `setSystemTimeLegacy()`（`machine.go:798`）只用 `KVM_GET_MSRS`+`KVM_RUN` 标定 + `KVM_SET_MSRS`
   写 `IA32_TSC`，**不需要任何 TSC scaling 能力**。

`enableCPUIDFaulting()`（`machine_amd64.go:164`）失败只 `log.Warningf` 一次，不致命。

结论：只要 shim 对 `KVM_CAP_TSC_CONTROL` 的 `KVM_CHECK_EXTENSION` 返回 0（不宣称支持），
gVisor 会自动走 legacy 时间标定，绕开 `KVM_SET_DEVICE_ATTR`/`KVM_SET_TSC_KHZ`。
**因此让 gVisor 跑起来的最小改动集只有 `KVM_INTERRUPT` + `KVM_NMI` 两个。**

## 5. gVisor 关心的 KVM_RUN 退出原因（`kvm_const.go`）

`KVM_EXIT_EXCEPTION(1)`、`KVM_EXIT_IO(2)`、`KVM_EXIT_HYPERCALL(3)`、`KVM_EXIT_DEBUG(4)`、
`KVM_EXIT_HLT(5)`、`KVM_EXIT_MMIO(6)`、`KVM_EXIT_IRQ_WINDOW_OPEN(7)`、`KVM_EXIT_SHUTDOWN(8)`、
`KVM_EXIT_FAIL_ENTRY(9)`、`KVM_EXIT_INTERNAL_ERROR(0x11)`、`KVM_EXIT_SYSTEM_EVENT(0x18)`。

热路径必须精确产生的退出：
- `KVM_EXIT_IRQ_WINDOW_OPEN`（抢占，见 §3）；
- `KVM_EXIT_MMIO` / `KVM_EXIT_IO`（Sentry 的地址空间管理触发）；
- `KVM_EXIT_HLT`（vCPU 空闲）；
- `KVM_EXIT_EXCEPTION`（缺页等，交给 bluepill fault handler）。

需要后续在实跑时对照 shim 的退出映射（`axvisor_kvm_x86_bridge.rs` 的 exit handler）逐一验证语义。

## 6. 结论与下一步

1. gVisor KVM platform 需要的 KVM ioctl 面比 Firecracker 窄，但对 `KVM_INTERRUPT`
   抢占语义和 MSR/CPUID 精确性要求高。
2. shim 的**唯一硬缺口是 `KVM_INTERRUPT` 与 `KVM_NMI`**；其余时间/scaling 类 ioctl 都能通过
   "对 `KVM_CAP_TSC_CONTROL` 报不支持" 让 gVisor 自动降级绕开。
3. `KVM_ENABLE_CAP`/`KVM_SET_DEVICE_ATTR` 缺失不阻塞（非致命/可降级），初期可直接返回 `-EINVAL`。
4. 下一步（实跑准备）：
   - 获取/构建 `runsc`（本机无 go/bazel，走 docker 或预编译二进制）；
   - 先在 L0 真实 `/dev/kvm` 上跑 `runsc --platform=kvm do echo hello` 建立 baseline；
   - 再在 L1 QEMU + `axvisor_kvm.ko` 上跑，用 strace/ftrace 抓 ioctl 序列对照本清单，
     定位第一个返回 `-ENOTTY`/`-EINVAL` 的 ioctl。

## 附录 A：L0 真实 KVM 上的 gVisor baseline（已验证）

环境：L0 裸机 Meteor Lake，`/dev/kvm` 通过 ACL 授予当前用户（`user:bullet1517:rw-`）。
runsc：官方预编译 `release-20260706.0`（`/tmp/gvisor-bin/runsc`，sha512 校验通过）。
本机无 go/bazel，故不自行构建，直接用官方二进制。

复现命令：
```bash
cd /tmp/gvisor-bin
./runsc --platform=kvm --network=none --ignore-cgroups --rootless \
  do echo "HELLO_FROM_GVISOR_KVM"
```
- `--rootless`：绕开 `newuidmap`（本机无 uidmap 包）。
- `--ignore-cgroups`：绕开 `/sys/fs/cgroup/cgroup.subtree_control` 写权限。
- `--network=none`：`do` 测试模式下省去网络配置。

结果（PASS）：标准输出打印 `HELLO_FROM_GVISOR_KVM`。

带 `--debug --strace` 的证据（确属 KVM platform，非静默回退）：
- `config.go] Platform: kvm`
- `machine.go:293] The maximum number of vCPUs is 54`（= `KVM_CHECK_EXTENSION(KVM_CAP_MAX_VCPUS)`）
- `machine.go:305] The maximum number of slots is 32764`
- `machine.go:311] TSC scaling support: true`（= `KVM_CHECK_EXTENSION(KVM_CAP_TSC_CONTROL)` 返回真）
- guest `uname` 返回 `Release: 4.19.0-gvisor`（Sentry 的假内核），全程零 KVM ioctl 错误。

注意：baseline 里 `TSC scaling support: true` 意味着在真实 KVM 上 gVisor 走的是
TSC-offset/scaling 路径（`KVM_SET_DEVICE_ATTR`/`KVM_SET_TSC_KHZ`）。移到 `axvisor_kvm.ko`
时，若 shim 对 `KVM_CAP_TSC_CONTROL` 报不支持（返回 0），gVisor 会自动降级到
`setSystemTimeLegacy()`（见 §4.3），这是我们期望的兼容路径。

## 附录 B：下一步实跑计划（在 axvisor_kvm.ko 上）

1. 在 L1 QEMU + `axvisor_kvm.ko` 的 host initramfs 里放入 `runsc` 二进制与一个最小 OCI bundle
   （或用 `runsc do`）。
2. 先补齐 §4.2 的硬缺口 `KVM_INTERRUPT`、`KVM_NMI`，其余缺口（`KVM_ENABLE_CAP`/
   `KVM_SET_DEVICE_ATTR`）先返回 `-EINVAL` 让 gVisor 走非致命/降级路径。
3. 确保 shim 对 `KVM_CAP_TSC_CONTROL` 的 `KVM_CHECK_EXTENSION` 返回 0，逼 gVisor 走 legacy 时间标定。
4. 用 `runsc --debug --strace` 抓 ioctl 序列，定位第一个返回 `-ENOTTY`/`-EINVAL` 的调用，逐个补齐。
