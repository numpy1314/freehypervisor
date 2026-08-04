# 内核安全增强进展整理（据 2026 春夏季开发日志）

> 来源：《组件化内核-2026春夏季开发日志》（腾讯文档，2026/03–07 周例会记录）
> 已逐条核对 rcore-os/tgoskits 的 GitHub PR/Issue 真实标题与状态
> 整理日期：2026-07-31

## 一、总体判断

开发日志记录的工作以 AxVisor/StarryOS 的**功能开发**为主（多平台虚拟化、启动、CI、网络栈等）。其中**内核安全增强**有一条清晰、连贯的主线——**内核并发与内存健壮性专项**，由团队成员持续推进，从锁检测机制起步，逐步扩展到栈保护、panic 加固，形成完整演进链。这条线正是研究内容3飞地所依赖的"强安全语言底座、可信隔离边界"的一部分。

## 二、内核安全增强主线：并发与内存健壮性

### 1. 锁安全检测机制（lockdep）——从无到有、逐步完善

这是贯穿整个开发周期的一条主线，仿照 Linux lockdep 为 ArceOS/Starry 建立死锁检测能力：

| PR | 工作内容 | 状态 |
|----|----------|------|
| [#164](https://github.com/rcore-os/tgoskits/pull/164) | 为 kspin 自旋锁引入轻量级 lockdep 支持（起点） | 已合并 |
| [#240](https://github.com/rcore-os/tgoskits/pull/240) | 为 ax-sync 的 mutex 加 lockdep，并借此抓出并修复 Starry 原子上下文违例 | 已提交 |
| [#415](https://github.com/rcore-os/tgoskits/pull/415) | 扩展 lockdep：任务持锁跟踪 + QEMU 回归测试 | 已合并 |
| [#616](https://github.com/rcore-os/tgoskits/pull/616) | 支持嵌套锁 subclass，区分真实死锁与父子结构同类锁 | 已合并 |
| [#1375](https://github.com/rcore-os/tgoskits/pull/1375) | 修复 Starry 的锁序回归 | 已合并 |
| [#1380](https://github.com/rcore-os/tgoskits/pull/1380) | 从内核路径移除 spin mutex 用法 | 已合并 |
| [#1390](https://github.com/rcore-os/tgoskits/pull/1390) | 引入读写锁并纳入 lockdep/might_sleep 检查，替换 spin::RwLock | 已提交 |

日志中的关键记录：
- "参照星绽的实现，引入了读写锁，并纳入 lockdep 和 might_sleep 检查范围"
- "统一了对不同锁类别的处理，可正常处理 spinlock 和 mutex 的混合嵌套"
- "打通了从外部手动启用 lockdep 的路径，发现了 Starry 一批锁的违例情况"
- "通过 might_sleep 等机制发现并修复了部分可能导致死锁的问题"（[#1682](https://github.com/rcore-os/tgoskits/pull/1682)）

### 2. 栈溢出检测——canary 到 guard page 再到编译器级保护

| PR | 工作内容 | 状态 |
|----|----------|------|
| [#416](https://github.com/rcore-os/tgoskits/pull/416) | 引入栈溢出检测机制 stack_canary（起点） | 已合并 |
| [#1239](https://github.com/rcore-os/tgoskits/pull/1239) | 编译器级栈保护，对每个栈帧增加溢出检查 | 已合并 |

日志记录："在 canary 基础上增加 guard-page 机制"；"扩展栈溢出检测，结合编译器特性对每个栈帧做溢出检查"。修复过实际栈溢出 BUG（[Issue #182](https://github.com/rcore-os/tgoskits/issues/182)）。

### 3. panic 健壮性

| PR | 工作内容 | 状态 |
|----|----------|------|
| [#420](https://github.com/rcore-os/tgoskits/pull/420) | panic 递归保护：panic 处理流程中对打印、读调用栈等做降级/限次，防止递归导致系统卡死 | 已合并 |

### 4. 并发卡死问题排查

日志多次记录对"并发卡死 BUG"（[Issue #131](https://github.com/rcore-os/tgoskits/issues/131)）的持续定位与修复，配合上述 lockdep/might_sleep 机制，属同一条并发健壮性主线。

## 三、与课题的对应

这条主线对应研究内容3飞地的"强安全语言底座 + 可信隔离边界"，也对应课题安全可信框架的"语言与组件安全（12.2）"：

| 日志中的工作 | 对应课题 |
|--------------|----------|
| lockdep 锁检测 + might_sleep（#164 #240 #415 #616 #1375 #1390） | 12.2 减少数据竞争、原子上下文违例；飞地"用 Rust 写监控器"的并发正确性前提 |
| 栈溢出检测 canary/guard page/编译器保护（#416 #1239） | 12.2 内存安全；把栈溢出从可利用破坏降级为可捕获异常 |
| panic 递归保护（#420） | 动态安全与恢复（12.5）；避免不可恢复崩溃 |
| 并发卡死排查（Issue #131） | 12.2 并发缺陷；可用性/抗 DoS |

## 四、说明

- 上表 PR 号、标题、状态均已对照 GitHub 核实；"已提交"指日志记录已提 PR 但当前在 GitHub 为 closed/未合并状态（可能已并入其它 PR 或仍在评审）。
- 日志中另有大量 AxVisor 多平台虚拟化、CI、启动、网络栈等**功能开发**工作，不属内核安全增强，未纳入本表。
- 本主线与之前从 tgoskits 已合并 PR 整理的安全工作（`kt1_设计稿待补充清单.md` 等）互为补充：日志提供了**演进脉络**（谁在何时、以什么顺序推进），已合并 PR 提供了**结果快照**。
