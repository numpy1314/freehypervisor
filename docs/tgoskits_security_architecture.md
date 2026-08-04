# ArceOS / tgoskits 架构级安全机制增强

> 面向国重 OS 课题一（安全增强，原型 = tgoskits 中的 ArceOS）汇报材料  
> 视角：**架构级安全机制**（结构性设施），非零散 bugfix。所有机制均实证于 tgoskits 代码树中的独立 crate / 子系统。  
> 整理日期：2026-07-30

## 概述

ArceOS 的安全性不是靠事后打补丁,而是把安全机制**下沉为架构地基**：以独立 crate 承载、用 Rust 类型系统与 trait 边界强制约束、用建模错误替代裸 panic。架构级增强分布在六个层次,自底向上覆盖「语言安全 → 隔离边界 → 并发安全 → 权限模型 → 虚拟化隔离 → 可观测防御」。

| 层次 | 架构机制 | 承载组件（代码树实证） |
|------|----------|------------------------|
| L1 语言/内存安全 | Rust `#![no_std]` + `unsafe` 收敛 + 类型化地址 | `ax_memory_addr`（PhysAddr/GuestPhysAddr 强类型） |
| L2 地址空间隔离 | Guest 二级页表(NPT/stage-2) + 统一受控内存访问器 | `axaddrspace`（npt/、memory_accessor、address_space） |
| L3 并发/锁安全 | lockdep 感知自旋锁 + 原子上下文睡眠检测 | `ax-kspin`、`axtask`(might_sleep) |
| L4 执行栈保护 | 任务栈 guard page + 越界 hart park | `axtask`(stack guard)、`axruntime` |
| L5 权限/隔离模型 | seccomp + capabilities + no_new_privs + namespace | `starry-kernel`(process/namespace, security) |
| L6 虚拟化边界 | OS-neutral vCPU 后端 + 类型化 domain error + 统一模拟设备框架 + 分层 MSI-X 中断域 | `axvm`、`x86/arm/riscv/loongarch_vcpu`、`axdevice` |
| L7 可观测防御 | panic backtrace hook + memtrack 分配回溯 | `axbacktrace`、`memtrack` |

## L2 地址空间隔离：Guest 内存访问的架构边界

这是 hypervisor 安全的核心机制,作为独立 crate `axaddrspace` 存在,而非散落在各处的裸指针操作。

- **二级页表隔离**(`npt/` + `address_space/`)：guest 物理地址(GPA)经嵌套页表(NPT / stage-2)翻译到宿主物理地址(HPA),从架构上强制 guest 无法直接触及宿主内存。
- **统一受控内存访问器**(`memory_accessor.rs` 的 `GuestMemoryAccessor` trait)：所有对 guest 内存的访问(尤其 VirtIO 设备)必须经此 trait,返回 `(HPA, accessible_size)` 二元组——**把「可访问字节数」作为类型契约的一部分**,从接口层杜绝越界。注释原文即「provides a safe and consistent way to access guest memory ... handling address translation and memory safety concerns」。
- **强类型地址**：`GuestPhysAddr` / `PhysAddr` 是不同类型,编译期即阻止 GPA 与 HPA 混用——直接对应上游未修 issue #1734（GPA 被当 HPA 解引用）的根治方向。

## L3 并发/锁安全：把锁正确性变成架构可验证

并发缺陷(死锁/原子上下文睡眠)在内核里是安全事故的常见来源,ArceOS 用两个机制把它架构化。

- **`ax-kspin`(lockdep-aware spin rwlock,PR #1397)**：自旋锁内建锁序检测,SMP 下的锁序违规在测试期即暴露(PR #1375/#1103 借此消除多处锁序回归)。全仓已从裸 `spin` 迁移到 `ax-kspin`(PR #861/#1380)。
- **`might_sleep` 框架(`axtask`,PR #1235/#1689)**：检测「在原子/不可抢占上下文里调用可能睡眠的操作」——这正是我方 shim 曾踩的 `wake_vcpu` 在原子上下文 mutex_lock 的同类缺陷,已进 std CI 常态化。

## L4 执行栈保护

- **任务栈 guard page(`axtask`,PR #811)**：每个任务栈尾部映射不可访问的 guard page,栈溢出触发缺页异常而非静默踩踏相邻内存——把栈溢出从「可利用的内存破坏」降级为「可捕获的异常」。
- **越界 hart 受控 park(`axruntime`,PR #919)**：超过 `MAX_CPU_NUM` 的副核 park 而非 panic,消除一条启动期拒绝服务路径。

## L5 权限 / 隔离模型：对齐 Linux 安全语义

Starry 内核实现了 Linux 兼容的多层权限隔离,作为可组合的安全原语。

- **seccomp + capabilities(PR #1275)**：系统调用过滤与细粒度特权,配套 `security/capability`、`security/namespace` 回归测试。
- **`PR_SET_NO_NEW_PRIVS`(PR #810/#797)**：提权阻断位,execve 后不得获得新特权——容器/沙箱隔离的地基。
- **namespace / cgroup 隔离(PR #1031/#1642)**：unshare、pid/cgroup namespace,配 procfs namespace 文件。
- **ABI 逐字节对齐(PR #900/#916)**：sigsetsize、uc_mcontext 偏移严格对齐 Linux——权限检查若 ABI 错位即形同虚设,故对齐本身是安全机制。

## L6 虚拟化边界：可移植且类型安全的 hypervisor 架构

axvm 及各 arch vCPU 后端经过系统性重构,把「隔离边界」做成架构不变量。

- **OS-neutral vCPU 后端(PR #1550/#1523/#1553/#1556/#1467)**：x86/arm/riscv/loongarch 的 vCPU 逻辑与宿主 OS 解耦,通过统一 host 接口交互——攻击面收敛到一组明确的 trait 边界,而非分散的平台代码。
- **类型化 domain error(`axvm`,PR #1590)**：VM 操作返回建模错误(`AxError::InvalidInput`/`BadAddress` 等)而非 panic/裸值,客户机可达路径的失败被强制显式处理——直接对应未修 issue #1745(`todo!` 触发 hypervisor panic)的根治方向。
- **统一模拟设备框架(`axdevice`,PR #1722)**：所有模拟设备走统一注册/分发框架,收敛 MMIO 模拟攻击面。
- **分层 MSI-X 中断域(PR #1526)+ per-vCPU 虚拟中断分发队列(PR #1661)**：中断路由结构化,避免客户机可控中断号越界(对应未修 issue #1730 方向)。
- **guest 缺页受控恢复(PR #788/#883)**：RISC-V guest 内存缺页 / HLVX 取指缺页经明确路径恢复,不 panic。

## L7 可观测防御

- **panic backtrace hook(`axbacktrace`,PR #1653/#1029)**：可选的 `std::panic::set_hook`,崩溃时产出可符号化回溯,把「静默死机」变成「可诊断事件」。
- **memtrack 分配回溯(PR #1020)**：内存分配带回溯,便于定位泄露/UAF。

## 架构安全设计的三条主线（汇报要点）

1. **机制下沉为独立 crate,用类型系统强制约束**：`axaddrspace` 的 `GuestMemoryAccessor`、强类型 `GuestPhysAddr`、`ax-kspin` 的锁序检测——安全不是约定,而是编译期/框架层的不变量。
2. **以建模错误替代 panic**：`axvm` 类型化 domain error + `might_sleep` + backtrace hook,把「客户机/用户可达路径的崩溃」系统性改为受控失败,这与课题的隔离目标直接对齐。
3. **隔离边界即架构边界**：二级页表、OS-neutral vCPU 后端、统一设备框架把 guest/host 边界固化为一组明确接口,攻击面可枚举、可测试。

> 关联材料：`tgoskits_security_progress.md`（已合并的安全增强 PR 全景）、`tgoskits_security_issues.md`（35 个待修安全 issue = 课题可承接 backlog，其中 #1730/#1734/#1745 恰是上述 L6 边界机制尚未覆盖的缺口）。