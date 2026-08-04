# tgoskits / ArceOS 生态安全增强工作进展（上游已合并）

> 面向国重 OS 课题一（安全增强，原型 = tgoskits 中的 ArceOS）汇报材料  
> 数据来源：rcore-os/tgoskits 已 **merged** 的 Pull Request（截至 2026-07-30）  
> 统计口径：仓库累计已合并 PR 656 个，经语义筛选与人工核验，安全/健壮性直接相关约 60+ 个，下列为精选代表。

## 总体判断

ArceOS/Starry 生态的安全增强**并非以修补单个 CVE 的方式推进，而是通过持续的健壮性工程,把内核与 hypervisor 在与 OS/硬件接口边界上的不安全行为系统性收敛到与 Linux 一致的安全语义**。工作可归纳为五个方向：

| 方向 | 代表 PR 数 | 安全目标 |
|------|-----------|----------|
| 内存安全加固 | 9 | 消除越界、整数溢出回绕、UAF、EOF 越界映射、信息泄露 |
| panic 消除与健壮性 | 9 | 把内核/hypervisor 崩溃改为受控处理；lockdep、栈 guard page |
| 资源 / DoS 防护 | 9 | 消除死锁、忙等、饥饿；上界化资源分配 |
| 权限 / 隔离 / ABI 校验 | 11 | seccomp、capabilities、no_new_privs；syscall 参数校验对齐 Linux |
| 虚拟化边界 | 9 | guest 内存缺页处理、MMIO 模拟、vCPU 中断加固、设备模拟收敛 |

## 一、内存安全加固（越界 / 溢出 / UAF / EOF）

| PR | 说明 |
|----|------|
| [#1120](https://github.com/rcore-os/tgoskits/pull/1120) | mmap 中 addr+length 溢出直接拒绝，不再回绕（防整数溢出绕过地址检查） |
| [#920](https://github.com/rcore-os/tgoskits/pull/920) | 修复跨 split file map 共享的 page-cache 页被逐出时的 use-after-free |
| [#1534](https://github.com/rcore-os/tgoskits/pull/1534) | 拒绝越过 EOF 的私有 mmap 缺页（防越界页映射） |
| [#1164](https://github.com/rcore-os/tgoskits/pull/1164) | file-backed mmap populate 在 EOF 处设界，不为超出 EOF 的页分配 frame |
| [#1499](https://github.com/rcore-os/tgoskits/pull/1499) | per-file page-cache 预分配设上界，防 OOM |
| [#1124](https://github.com/rcore-os/tgoskits/pull/1124) | 截断文件变短时清零最后一页的残留部分（防信息泄露/脏数据） |
| [#1173](https://github.com/rcore-os/tgoskits/pull/1173) | CoW RSS 按 VA 计费跟踪，修正内存统计 |
| [#938](https://github.com/rcore-os/tgoskits/pull/938) | rename 时跳过子节点缓存转移，消除悬垂父引用（stale parent） |
| [#914](https://github.com/rcore-os/tgoskits/pull/914) | 按字节拷贝欠对齐的 epoll_event，修复非对齐访问 EFAULT |

## 二、panic 消除与内核健壮性（把 hypervisor/内核崩溃改成受控处理）

| PR | 说明 |
|----|------|
| [#919](https://github.com/rcore-os/tgoskits/pull/919) | 超过 MAX_CPU_NUM 的副 hart 改为 park，而非 panic |
| [#811](https://github.com/rcore-os/tgoskits/pull/811) | 为 task 栈增加 guard page（栈溢出检测） |
| [#1538](https://github.com/rcore-os/tgoskits/pull/1538) | unshare 期间防止 scope 锁 poisoning |
| [#1375](https://github.com/rcore-os/tgoskits/pull/1375) | 解决 Starry 锁序回归（lockdep） |
| [#1103](https://github.com/rcore-os/tgoskits/pull/1103) | 解决 Starry 锁序与日志打印问题（lockdep） |
| [#1397](https://github.com/rcore-os/tgoskits/pull/1397) | 新增 lockdep-aware 自旋读写锁 |
| [#1653](https://github.com/rcore-os/tgoskits/pull/1653) | axvisor 增加可选 panic backtrace（std::panic::set_hook）便于定位崩溃 |
| [#1029](https://github.com/rcore-os/tgoskits/pull/1029) | axbacktrace 正确性加固 + 分配优化 |
| [#1235](https://github.com/rcore-os/tgoskits/pull/1235) | 改进 might_sleep 诊断与覆盖（原子上下文睡眠检测） |

## 三、资源/DoS 防护（死锁 / 忙等 / 超时 / 饥饿）

| PR | 说明 |
|----|------|
| [#873](https://github.com/rcore-os/tgoskits/pull/873) | LoongArch 运行时 IPI 改非阻塞发送，修 SMP IPI-burst 死锁 |
| [#910](https://github.com/rcore-os/tgoskits/pull/910) | 关闭 EPOLLET 竞态窗口与 NoEvent 忙等循环 |
| [#1055](https://github.com/rcore-os/tgoskits/pull/1055) | 检测 fcntl 文件锁死锁 |
| [#1426](https://github.com/rcore-os/tgoskits/pull/1426) | 加固 SMP 唤醒与迁移重调度 |
| [#1495](https://github.com/rcore-os/tgoskits/pull/1495) | 跨核唤醒改为延迟处理，不再在远端 on_cpu 上自旋 |
| [#1380](https://github.com/rcore-os/tgoskits/pull/1380) | 从内核路径移除 spin mutex 用法 |
| [#1146](https://github.com/rcore-os/tgoskits/pull/1146) | 收窄 VFS 与 Starry 路径的自旋锁作用域 |
| [#1381](https://github.com/rcore-os/tgoskits/pull/1381) | 清除已投递的远端重调度请求 |
| [#1354](https://github.com/rcore-os/tgoskits/pull/1354) | 远端 IPI kick 强制重调度 |

## 四、权限 / 隔离 / ABI 校验（对齐 Linux 安全语义）

| PR | 说明 |
|----|------|
| [#1678](https://github.com/rcore-os/tgoskits/pull/1678) | 校验 socket 与 seccomp 标志 |
| [#1275](https://github.com/rcore-os/tgoskits/pull/1275) | 实现 seccomp 与 capabilities |
| [#810](https://github.com/rcore-os/tgoskits/pull/810) | 实现 PR_SET_NO_NEW_PRIVS（提权阻断）+ OpenSSH 测试 |
| [#797](https://github.com/rcore-os/tgoskits/pull/797) | 信号投递后 wake_task，补 dumpable/no_new_privs 字段 |
| [#1517](https://github.com/rcore-os/tgoskits/pull/1517) | 加固 path / random / icmp 行为 |
| [#1488](https://github.com/rcore-os/tgoskits/pull/1488) | 收紧 LTP 派生的 syscall 兼容性守卫 |
| [#900](https://github.com/rcore-os/tgoskits/pull/900) | epoll/sigmask 的 sigsetsize 校验对齐 Linux ABI |
| [#823](https://github.com/rcore-os/tgoskits/pull/823) | 校验 sync_file_range 的 flags 与 offset |
| [#916](https://github.com/rcore-os/tgoskits/pull/916) | x86-64 uc_mcontext 保持 Linux ABI 偏移（防信号栈错位） |
| [#854](https://github.com/rcore-os/tgoskits/pull/854) | rmdir 非空返回 ENOTEMPTY，rename 拒绝跨类型覆盖 |
| [#1119](https://github.com/rcore-os/tgoskits/pull/1119) | netlink bind/connect 接受超大 addrlen（防越界） |

## 五、虚拟化边界（axvisor / vcpu / MMIO / guest 内存）

| PR | 说明 |
|----|------|
| [#788](https://github.com/rcore-os/tgoskits/pull/788) | 恢复 RISC-V guest 内存缺页（stage-2 fault 处理） |
| [#883](https://github.com/rcore-os/tgoskits/pull/883) | 处理 RISC-V vCPU 的 HLVX 取指缺页 |
| [#1137](https://github.com/rcore-os/tgoskits/pull/1137) | 直接缓存 x86 模拟设备并加固 vCPU 中断路径 |
| [#1289](https://github.com/rcore-os/tgoskits/pull/1289) | 映射 QEMU high MMIO PCI 窗口 |
| [#1647](https://github.com/rcore-os/tgoskits/pull/1647) | dwmmc 强制 32 位响应 MMIO 读 |
| [#1205](https://github.com/rcore-os/tgoskits/pull/1205) | 避免 SVM guest 定时器校准 stall |
| [#899](https://github.com/rcore-os/tgoskits/pull/899) | LoongArch 经宿主硬件定时器透传模拟 guest timer |
| [#1661](https://github.com/rcore-os/tgoskits/pull/1661) | 新增虚拟中断模型类型与 per-vCPU 分发队列 |
| [#1722](https://github.com/rcore-os/tgoskits/pull/1722) | 统一模拟设备框架（收敛设备模拟攻击面） |

## 对课题一的启示

1. **内存安全是主战场**：溢出回绕（#1120）、UAF（#920）、EOF 越界（#1534/#1164）等是 Rust `unsafe`/裸内存操作与 Linux 兼容层交界处的高发缺陷，课题一的安全增强应优先覆盖 mmap/page-cache/文件截断这类路径。
2. **panic 即拒绝服务**：上游大量工作（#919/#1538/#1375/#1653）在把「不可恢复 panic」改成「受控错误/park/backtrace」，这与 tgoskits 未修 issue 中 `todo!` 触发 hypervisor panic（#1745）同源——**客户机/用户可达路径禁止 panic** 应作为课题的一条硬性准则。
3. **权限模型对齐 Linux**：seccomp、capabilities、no_new_privs（#1275/#810/#797）是安全隔离的地基，且必须逐字节对齐 Linux ABI（#900/#916）否则形同虚设。
4. **虚拟化边界即隔离边界**：guest 内存缺页与 MMIO 模拟（#788/#883/#1137）是 hypervisor 安全的核心，与我方 axvisor shim 的 slot-first fault-in / stage-2 翻译工作方向一致，可对标推进。

> 附：仍**未修复**的 35 个安全 issue（#1729–#1763，含 8 高危）见同目录 `tgoskits_security_issues.md`，可作为课题一后续可承接的安全增强 backlog。