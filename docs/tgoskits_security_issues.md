# rcore-os/tgoskits 安全漏洞修复问题整理

> 数据来源：https://github.com/rcore-os/tgoskits issue 列表（`[安全]` 标签）  
> 整理日期：2026-07-30 · 审查基线 commit `9daea706`

## 概览

该仓库经由一次自动化安全审查（发现编号统一形如 `csf_*`）批量登记了 **35 个安全问题**（issue #1729–#1763），全部带 `bug` + `安全` 标签，审查基线均为 commit `9daea706`。

**修复状态：截至整理时，35 个 issue 全部为 `open`，无一关联到修复 PR 或修复 commit。** 逐个核查 issue timeline，均只有 `labeled` 事件；近期 PR 标题/正文也未引用这些编号。当前仅有问题定位、代码证据、建议修复与验收标准，**修复尚未落地**。

严重性分布：高危 8 · 中危 14 · 低危 13。

每个 issue 的正文结构统一为：`问题` / `影响与触发条件` / `代码证据`（含精确 path:line）/ `建议修复` / `验收标准`（要求先写能稳定失败的回归测试）/ `追踪信息`（CWE 分类）。

## 按模块分类汇总

### ARM 虚拟化 (axvm / arm_vgic)

| # | 严重性 | 问题 | CWE |
|---|--------|------|-----|
| [#1730](https://github.com/rcore-os/tgoskits/issues/1730) | 高危 | axvm：GICR_INVLPIR 可导致客户机控制的宿主越界写 | CWE-129, CWE-191, CWE-787 |
| [#1734](https://github.com/rcore-os/tgoskits/issues/1734) | 高危 | arm-vgic：客户机 GITS_CBASER 被直接当作宿主物理地址解引用 | CWE-125, CWE-20 |
| [#1745](https://github.com/rcore-os/tgoskits/issues/1745) | 中危 | arm-vgic：未实现的 MMIO 偏移可由客户机触发 hypervisor panic | CWE-248, CWE-755 |

### Starry (类 Linux 内核 / syscall)

| # | 严重性 | 问题 | CWE |
|---|--------|------|-----|
| [#1747](https://github.com/rcore-os/tgoskits/issues/1747) | 高危 | starry：setns 缺少特权命名空间加入授权 | CWE-269, CWE-862 |
| [#1760](https://github.com/rcore-os/tgoskits/issues/1760) | 高危 | starry：目录变更绕过 DAC 与 sticky bit 检查 | CWE-732, CWE-862 |
| [#1761](https://github.com/rcore-os/tgoskits/issues/1761) | 高危 | starry：openat 绕过文件所有权与 mode 权限 | CWE-732, CWE-862 |
| [#1731](https://github.com/rcore-os/tgoskits/issues/1731) | 中危 | starry：超大 write 长度可触发用户缓冲区校验 panic | CWE-190, CWE-248 |
| [#1736](https://github.com/rcore-os/tgoskits/issues/1736) | 中危 | starry：异常 PT_INTERP 尺寸可耗尽内存或触发 exec panic | CWE-20, CWE-248, CWE-400 |
| [#1737](https://github.com/rcore-os/tgoskits/issues/1737) | 中危 | starry：异常 PT_LOAD 对齐可触发内核 panic | CWE-20, CWE-248 |
| [#1740](https://github.com/rcore-os/tgoskits/issues/1740) | 中危 | starry：父目录遍历可逃逸 chroot 根目录 | CWE-22, CWE-284 |
| [#1742](https://github.com/rcore-os/tgoskits/issues/1742) | 中危 | starry：getdents64 可按用户长度无界分配内核缓冲区 | CWE-248, CWE-400 |
| [#1743](https://github.com/rcore-os/tgoskits/issues/1743) | 中危 | starry：getrandom 可按用户长度无界分配内核缓冲区 | CWE-248, CWE-400 |
| [#1744](https://github.com/rcore-os/tgoskits/issues/1744) | 中危 | starry：递归 shebang 解释缺少深度和环路限制 | CWE-248, CWE-674 |
| [#1751](https://github.com/rcore-os/tgoskits/issues/1751) | 中危 | starry：mq_timedsend 在校验队列限制前复制超大消息 | CWE-400, CWE-789 |
| [#1755](https://github.com/rcore-os/tgoskits/issues/1755) | 中危 | starry：execve 缺少 argv 和 envp 聚合预算 | CWE-400 |
| [#1757](https://github.com/rcore-os/tgoskits/issues/1757) | 低危 | starry-test：OrangePi 冒烟测试以 root 执行明文 HTTP 脚本 | CWE-494 |

### 设备驱动 (rknpu / nvme / fxmac / aic8800 / mpp / uvc)

| # | 严重性 | 问题 | CWE |
|---|--------|------|-----|
| [#1732](https://github.com/rcore-os/tgoskits/issues/1732) | 高危 | rknpu：Submit 信任用户提供的内核指针与 DMA 地址 | CWE-125, CWE-20, CWE-787, CWE-822 |
| [#1739](https://github.com/rcore-os/tgoskits/issues/1739) | 高危 | mpp-service：JPEG 偏移可让 DMA 越过导入缓冲区 | CWE-20, CWE-787 |
| [#1750](https://github.com/rcore-os/tgoskits/issues/1750) | 中危 | aic8800：控制面接收队列无界增长 | CWE-400, CWE-770 |
| [#1762](https://github.com/rcore-os/tgoskits/issues/1762) | 中危 | rknpu：MemCreate 缺少 DMA 分配配额 | CWE-770, CWE-789 |
| [#1729](https://github.com/rcore-os/tgoskits/issues/1729) | 低危 | orangepi-uvc：MJPEG 尺寸计算溢出可导致 RGB 缓冲区越界 | CWE-122, CWE-190 |
| [#1733](https://github.com/rcore-os/tgoskits/issues/1733) | 低危 | fxmac：接收描述符长度可超出 DMA 缓冲区 | CWE-125, CWE-20 |
| [#1752](https://github.com/rcore-os/tgoskits/issues/1752) | 低危 | nvme-driver：管理命令缺少超时可永久忙等 | CWE-400, CWE-835 |
| [#1753](https://github.com/rcore-os/tgoskits/issues/1753) | 低危 | rknpu：提交路径忽略超时并持有设备锁忙等 | CWE-400, CWE-835 |

### 网络与文件系统 (ax-net / rsext4)

| # | 严重性 | 问题 | CWE |
|---|--------|------|-----|
| [#1738](https://github.com/rcore-os/tgoskits/issues/1738) | 中危 | ax-net：截断 IPv4 帧可触发 TCP 旁路监听 panic | CWE-20, CWE-248 |
| [#1735](https://github.com/rcore-os/tgoskits/issues/1735) | 低危 | rsext4：空 extent 内部节点可在插入时触发内核 panic | CWE-129, CWE-20, CWE-248 |
| [#1746](https://github.com/rcore-os/tgoskits/issues/1746) | 低危 | rsext4：存储与日志错误被转换为内核 panic | CWE-248 |

### 工具链 / CI / 运维

| # | 严重性 | 问题 | CWE |
|---|--------|------|-----|
| [#1763](https://github.com/rcore-os/tgoskits/issues/1763) | 高危 | ci：Fork PR 可在持久化自托管 Runner 上执行代码 | CWE-829 |
| [#1749](https://github.com/rcore-os/tgoskits/issues/1749) | 中危 | axloader：串口选择的 HTTP 内核缺少真实性校验 | CWE-319, CWE-494 |
| [#1741](https://github.com/rcore-os/tgoskits/issues/1741) | 低危 | wayland：APKINDEX 路径字段可逃逸软件包缓存目录 | CWE-22 |
| [#1748](https://github.com/rcore-os/tgoskits/issues/1748) | 低危 | arce-agent：未认证代理可消耗操作者 API 配额 | CWE-306 |
| [#1754](https://github.com/rcore-os/tgoskits/issues/1754) | 低危 | arce-agent：无界阻塞 HTTP 请求体可独占代理服务 | CWE-400 |
| [#1756](https://github.com/rcore-os/tgoskits/issues/1756) | 低危 | claw-code：构建脚本执行未固定的上游分支 | CWE-494, CWE-829 |
| [#1758](https://github.com/rcore-os/tgoskits/issues/1758) | 低危 | wayland-hvf：以 root 安装未经认证的 APK | CWE-494 |
| [#1759](https://github.com/rcore-os/tgoskits/issues/1759) | 低危 | wayland-test：以 root 安装未经认证的 APK | CWE-494 |

## 重点：ARM 虚拟化相关漏洞深入分析

这 3 条与本项目（hypervisor / OS 接口研究）最相关，均属于「不受信任客户机经由 VGIC MMIO 攻击 hypervisor」这一类，是 hypervisor 与 OS/硬件接口边界上的典型缺陷。

### #1730 [高危] 客户机控制的宿主越界写（GICR_INVLPIR）

**发现编号** `csf_b33386aeffc630abf1d71ba9` · **CWE** CWE-129, CWE-191, CWE-787

**机制**：客户机写 `GICR_INVLPIR` 时，VGICR 直接把客户机给的中断号减去 8192（LPI 基址）得到属性表偏移，**既不检查下界也不检查上界**；偏移加到宿主帧地址后做 volatile 字节写。

**影响**：
- 下溢（中断号 < 8192）在 release 构建下回绕成巨大偏移；超大中断号越过属性表末端。
- 结果是**客户机可定向写宿主物理内存**，直接击穿 guest/host 隔离。这是三条里危害最直接的一条（CWE-787 越界写 + CWE-191 下溢 + CWE-129 数组索引未校验）。

**关键代码位置**（基线 `9daea706`）：
- `virtualization/axvm/src/arch/aarch64/mod.rs:74-107`（入口）
- `virtualization/arm_vgic/src/v3/vgicr.rs:159-195`（输入源）
- `virtualization/axvm/src/architecture/exit.rs:27-33`（缺失/失效控制）
- `virtualization/arm_vgic/src/v3/vgicr.rs:274-283`（危险操作）
- `virtualization/arm_vgic/src/v3/vgicr.rs:240-269`（补充证据）

**建议修复**：减法前先断言中断号 ≥ LPI 基址；换算出的字节索引必须落在已分配属性表范围内；写入走有界表抽象而非裸指针加偏移。

### #1734 [高危] 客户机物理地址被当宿主地址解引用（GITS_CBASER）

**发现编号** `csf_e5d3ffab50136cfe016957c3` · **CWE** CWE-125, CWE-20

**机制**：虚拟 ITS 的 `GITS_CBASER`/`CREADR`/`CWRITER` 全部客户机可写。命令队列读取路径**假设 GPA==HPA**，不经 stage-2 翻译、不查已分配区域，直接 `host::phys_to_virt` 后 volatile 读 32 字节命令。

**影响**：
- 客户机可任意指定一个宿主物理地址让 hypervisor 解引用并解析成 ITS 命令，造成宿主崩溃或读取/使用宿主数据（CWE-125 越界读 + CWE-20 输入校验缺失）。
- 本质是**缺少 GPA→HPA 的 stage-2 地址翻译这一 hypervisor 核心安全边界**——恰是本项目关注的「hypervisor 依赖 OS/硬件提供的地址翻译与隔离」接口点。

**关键代码位置**（基线 `9daea706`）：
- `virtualization/axvm/src/arch/aarch64/mod.rs:74-107`（入口）
- `virtualization/arm_vgic/src/v3/gits.rs:166-225`（输入源）
- `virtualization/arm_vgic/src/v3/gits.rs:419-440`（缺失/失效控制）
- `virtualization/arm_vgic/src/v3/gits.rs:441-459`（危险操作）

**建议修复**：所有客户机命令队列地址必须过 VM stage-2 翻译；要求完整 32 字节命令落在已分配且可读的客户机区域；用可处理 fault 的 guest-memory API 复制，而非裸物理指针。

### #1745 [中危] 未实现 MMIO 偏移触发 hypervisor panic（todo!）

**发现编号** `csf_e17691077e98f36cd8701014` · **CWE** CWE-248, CWE-755

**机制**：VGICD/VGICR 已注册的 MMIO 范围内仍有大量未实现偏移，落到默认分支时执行 `todo!`。客户机只要访问这些架构寄存器偏移即可让**整个 hypervisor panic**。

**影响**：
- 客户机可单条普通 MMIO load/store 终止 hypervisor/宿主运行时（CWE-248 未捕获异常 + CWE-755 异常处理不当），属拒绝服务。
- 根因是**把「尚未实现」当成了 unreachable**：对客户机可达的输入路径用 `todo!` 是把不完整实现直接暴露成攻击面。

**关键代码位置**（基线 `9daea706`）：
- `virtualization/axvm/src/arch/aarch64/mod.rs:74-107`（入口）
- `virtualization/axvm/src/architecture/exit.rs:8-33`（缺失/失效控制）
- `virtualization/arm_vgic/src/v3/vgicd.rs:121-190`（危险操作）
- `virtualization/arm_vgic/src/v3/vgicd.rs:196-266`（危险操作）
- `virtualization/arm_vgic/src/v3/vgicr.rs:90-218`（具体实现）

**建议修复**：按 GIC 架构对客户机可见偏移实现 read-as-zero / write-ignore / 受控 emulation error；移除客户机输入路径上所有 `todo!`；覆盖完整注册范围。

> 三条共同的入口都是 `virtualization/axvm/src/arch/aarch64/mod.rs:74-107` + `architecture/exit.rs`（VM-exit 分派到 MMIO 模拟）。修复方向可归纳为两条通用原则：(1) 凡客户机可控的地址/索引一律经 stage-2 翻译与边界校验后再解引用；(2) 客户机可达路径禁止 `todo!`/`unreachable!`，改为受控错误返回。

## 全部 35 条逐条详情（按严重性、编号排序）

### #1730 [高危] axvm：GICR_INVLPIR 可导致客户机控制的宿主越界写

- **CWE**：CWE-129, CWE-191, CWE-787 · **发现编号**：`csf_b33386aeffc630abf1d71ba9` · **状态**：open（未关联修复）
- **问题**：AArch64 客户机写入 `GICR_INVLPIR` 时，VGICR 处理器直接对客户机提供的中断号减去 8192，未检查下界或 LPI 属性表上界。所得偏移被加到宿主帧地址后执行 volatile 字节写，优化构建下的下溢或超大值可越过已分配属性表。
- **建议修复**：减法前校验 INVLPIR 中断号不小于 LPI 基址，校验换算后的字节索引位于实际分配的属性表范围内，并通过有界表抽象完成写入。
- **代码证据**：`virtualization/axvm/src/arch/aarch64/mod.rs:74-107` ; `virtualization/arm_vgic/src/v3/vgicr.rs:159-195` ; `virtualization/axvm/src/architecture/exit.rs:27-33` ; `virtualization/arm_vgic/src/v3/vgicr.rs:274-283` ; `virtualization/arm_vgic/src/v3/vgicr.rs:240-269`

### #1732 [高危] rknpu：Submit 信任用户提供的内核指针与 DMA 地址

- **CWE**：CWE-125, CWE-20, CWE-787, CWE-822 · **发现编号**：`csf_039a3f5b5d8261f19ef6eb1f` · **状态**：open（未关联修复）
- **问题**：RKNPU Submit ioctl 只复制顶层结构体，随后把用户提供的 `task_obj_addr` 直接转换为 Rust 可变切片，并把描述符中的命令地址和 `task_base_addr` 直接写入 NPU DMA 寄存器。路径缺少用户地址校验、GEM 所有权/范围校验，且 IOMMU 被关闭。
- **建议修复**：所有任务描述符必须通过受检用户访问 API 复制；命令和任务地址只能由调用文件拥有的有效 GEM handle 解析，并检查 offset/length 完整包含于分配中；拒绝零任务提交，并在编程 DMA 前强制 IOMMU 隔离。
- **代码证据**：`os/StarryOS/kernel/src/pseudofs/dev/card1.rs:363-428` ; `drivers/ax-driver/src/rknpu.rs:81-83` ; `drivers/npu/rockchip-npu/src/ioctrl.rs:340-360` ; `drivers/npu/rockchip-npu/src/lib.rs:104-116` ; `drivers/npu/rockchip-npu/src/ioctrl.rs:399-406` ; `drivers/npu/rockchip-npu/src/registers/mod.rs:131-158`

### #1734 [高危] arm-vgic：客户机 GITS_CBASER 被直接当作宿主物理地址解引用

- **CWE**：CWE-125, CWE-20 · **发现编号**：`csf_e5d3ffab50136cfe016957c3` · **状态**：open（未关联修复）
- **问题**：虚拟 ITS 的 `GITS_CBASER`、`CREADR` 和 `CWRITER` 均可由客户机控制。命令队列读取路径假设 GPA/HPA 恒等，未经过 VM stage-2 翻译或已分配区域检查，直接调用 `host::phys_to_virt` 并 volatile 读取 32 字节命令。
- **建议修复**：所有客户机命令队列地址必须经 VM stage-2 地址空间翻译，要求完整 32 字节命令落在已分配且可读的客户机区域，并通过可处理 fault 的 guest-memory API 复制。
- **代码证据**：`virtualization/axvm/src/arch/aarch64/mod.rs:74-107` ; `virtualization/arm_vgic/src/v3/gits.rs:166-225` ; `virtualization/arm_vgic/src/v3/gits.rs:419-440` ; `virtualization/arm_vgic/src/v3/gits.rs:441-459`

### #1739 [高危] mpp-service：JPEG 偏移可让 DMA 越过导入缓冲区

- **CWE**：CWE-20, CWE-787 · **发现编号**：`csf_a496b8b774e0718475787a76` · **状态**：open（未关联修复）
- **问题**：MPP JPEG 路径把用户控制的 plane offset 直接加到 dma-buf 基址，并接受未绑定到导入分配大小的长度、stride 与寄存器几何。所得地址被写入未受 IOMMU 隔离的解码器，可能对导入缓冲区之外的物理内存执行 DMA。
- **建议修复**：将每个寄存器地址解析为带实际大小的导入 dma-buf，使用 checked addition 处理 plane offset，校验长度和 stride 不超出剩余分配，并用 IOMMU domain 约束解码器。
- **代码证据**：`os/StarryOS/kernel/src/pseudofs/dev/mpp_service.rs:87-105` ; `os/StarryOS/kernel/src/pseudofs/dev/mpp_service.rs:189-196` ; `drivers/vpu/rockchip-jpeg/src/mpp.rs:172-207` ; `os/StarryOS/kernel/src/pseudofs/dev/mpp_service.rs:155-176` ; `drivers/vpu/rockchip-jpeg/src/lib.rs:146-153` ; `drivers/vpu/rockchip-jpeg/src/registers.rs:38-63`

### #1747 [高危] starry：setns 缺少特权命名空间加入授权

- **CWE**：CWE-269, CWE-862 · **发现编号**：`csf_6b5642855007192f72c8d0d8` · **状态**：open（未关联修复）
- **问题**：StarryOS 可从合成的 `/proc/<pid>/ns` 条目取得其他进程 namespace 引用并调用 `setns`，但路径没有调用者/目标进程授权、user namespace owner 检查或所需 `CAP_SYS_ADMIN` 校验，随后直接替换调用者的特权 namespace 引用。
- **建议修复**：打开 namespace handle 时执行 Linux 兼容的 ptrace/read 授权，并针对每种 namespace 在 namespace-fd 与 pidfd 路径检查所需 `CAP_SYS_ADMIN` 及 owning user namespace 关系。
- **代码证据**：`os/StarryOS/kernel/src/syscall/task/namespace.rs:149-165` ; `os/StarryOS/kernel/src/syscall/fs/fd_ops.rs:258-316` ; `os/StarryOS/kernel/src/syscall/task/namespace.rs:174-240` ; `os/StarryOS/kernel/src/syscall/task/namespace.rs:248-327`

### #1760 [高危] starry：目录变更绕过 DAC 与 sticky bit 检查

- **CWE**：CWE-732, CWE-862 · **发现编号**：`csf_e6537204aac6a8f312c7b01e` · **状态**：open（未关联修复）
- **问题**：`mkdirat`、`linkat`、`unlinkat`、`renameat2` 等目录变更路径只解析对象并调用 VFS mutation，未检查相关父目录的 write/search 权限、对象所有权或 sticky-directory 规则。公共 VFS 接口也没有携带 credential 供后端统一授权。
- **建议修复**：在 create/link/unlink/rename 前对所有相关父目录执行 search/write DAC 校验，并实现 sticky directory 的文件 owner、目录 owner 与 capability 规则；credential 应进入统一 VFS mutation 边界。
- **代码证据**：`os/StarryOS/kernel/src/syscall/fs/ctl.rs:187-203` ; `os/StarryOS/kernel/src/syscall/fs/ctl.rs:355-392` ; `os/StarryOS/kernel/src/syscall/fs/ctl.rs:405-424` ; `os/StarryOS/kernel/src/syscall/fs/ctl.rs:840-874` ; `os/arceos/modules/axfs-ng/src/fs_core/context.rs:468-535`

### #1761 [高危] starry：openat 绕过文件所有权与 mode 权限

- **CWE**：CWE-732, CWE-862 · **发现编号**：`csf_9254843f53775ef70152172a` · **状态**：open（未关联修复）
- **问题**：`openat` 虽取得调用者 credential，但仅用来给新 inode 设置所有权。路径遍历和既有 inode 打开没有依据 uid/gid/supplementary groups 与 owner/group/other mode 校验 requested access；`O_TRUNC` 还可直接对拒绝写入的文件执行 `set_len(0)`。
- **建议修复**：路径遍历时执行 execute/search 校验，并在返回或修改既有节点前，依据 inode owner/group/other mode、supplementary groups 和调用者 credential 校验 read/write/append/truncate；同时按 Linux 语义处理 root/capability 与错误优先级。
- **代码证据**：`os/StarryOS/kernel/src/syscall/fs/fd_ops.rs:354-426` ; `os/arceos/modules/axfs-ng/src/file/open.rs:191-257` ; `components/axfs-ng-vfs/src/node/dir.rs:386-404` ; `os/StarryOS/kernel/src/syscall/fs/stat.rs:155-206`

### #1763 [高危] ci：Fork PR 可在持久化自托管 Runner 上执行代码

- **CWE**：CWE-829 · **发现编号**：`csf_e843d5ec486be4e09c731b2a` · **状态**：open（未关联修复）
- **问题**：CI 对所有非文档 PR 触发矩阵，自托管 job 的 owner 条件检查的是 base 仓库 `github.repository_owner`，对 fork PR 仍为真。随后 checkout PR revision 并在持久化 QCS、KVM 和物理板 runner 上执行 Cargo、build script、proc macro、测试与 xtask，缺少可信 head/actor 或维护者批准门禁。
- **建议修复**：不得在自托管 runner 上调度未受信任 PR revision。以可信 head repository/actor 或显式维护者批准为前置 gate；fork 代码仅在隔离、一次性的 GitHub-hosted runner 运行，并隔离 board/KVM 控制与凭据。自托管矩阵必须保持 `cache_key: ""`。
- **代码证据**：`.github/workflows/ci.yml:15-22` ; `.github/workflows/reusable-command.yml:89-92` ; `.github/workflows/reusable-command.yml:80-86` ; `.github/workflows/reusable-command.yml:202-223` ; `.github/workflows/ci.yml:350-356` ; `.github/workflows/ci.yml:631-639` ; `.github/workflows/ci.yml:732-739`

### #1731 [中危] starry：超大 write 长度可触发用户缓冲区校验 panic

- **CWE**：CWE-190, CWE-248 · **发现编号**：`csf_777e90210725d67d001af8f4` · **状态**：open（未关联修复）
- **问题**：`sys_write` 接受用户控制的 `usize` 长度并传入用户缓冲区校验。`UserConstPtr::get_as_slice` 对 `Layout::array::<T>(len)` 直接 `unwrap`；当长度超过 `isize::MAX` 时布局构造失败并触发内核 panic，而不是返回 syscall 错误。
- **建议修复**：移除布局构造的 `unwrap`，对传输长度和地址空间范围进行 checked validation，并按 Linux 语义将失败转换为合适的 `EINVAL`/`EFAULT`，同时核对错误优先级。
- **代码证据**：`os/StarryOS/kernel/src/syscall/fs/io.rs:138-144` ; `os/StarryOS/kernel/src/syscall/fs/io.rs:577-590` ; `os/StarryOS/kernel/src/mm/access.rs:214-223`

### #1736 [中危] starry：异常 PT_INTERP 尺寸可耗尽内存或触发 exec panic

- **CWE**：CWE-20, CWE-248, CWE-400 · **发现编号**：`csf_6aee4499dea2a7718592d05d` · **状态**：open（未关联修复）
- **问题**：`execve` 加载 ELF 解释器时，直接使用用户可控的 `PT_INTERP.p_filesz` 分配缓冲区并读取文件范围，缺少大小上限和 `offset + size` 完整性检查；短读还会进入 `assert_eq`。特制 ELF 可造成超大内核分配或断言 panic。
- **建议修复**：为 PT_INTERP 设定小且明确的上限，使用 checked addition 验证文件偏移与长度，并把短读或越界解释器路径作为无效可执行文件返回，不得断言。
- **代码证据**：`os/StarryOS/kernel/src/syscall/task/execve.rs:31-39` ; `os/StarryOS/kernel/src/syscall/task/execve.rs:176-185` ; `os/StarryOS/kernel/src/mm/loader.rs:560-575`

### #1737 [中危] starry：异常 PT_LOAD 对齐可触发内核 panic

- **CWE**：CWE-20, CWE-248 · **发现编号**：`csf_26d40ff4c85b35b0763321ae` · **状态**：open（未关联修复）
- **问题**：ELF 加载器假定 `PT_LOAD.p_vaddr` 与 `p_offset` 的页内偏移一致，并用 `assert_eq` 强制该不变量，但在进入断言前没有拒绝异常 program header。用户选择的可解析 ELF 因而可稳定触发内核 panic。
- **建议修复**：显式校验 PT_LOAD 地址/文件偏移的页内同余关系，并对所有地址和长度运算使用 checked arithmetic；异常头应返回 `ENOEXEC`。
- **代码证据**：`os/StarryOS/kernel/src/syscall/task/execve.rs:31-39` ; `os/StarryOS/kernel/src/syscall/task/execve.rs:176-185` ; `os/StarryOS/kernel/src/mm/loader.rs:185-205`

### #1738 [中危] ax-net：截断 IPv4 帧可触发 TCP 旁路监听 panic

- **CWE**：CWE-20, CWE-248 · **发现编号**：`csf_e2f30a898903db6151bb6368` · **状态**：open（未关联修复）
- **问题**：以太网接收路径在 smoltcp 完成协议校验前调用被动 TCP snooper。只要 Ethernet 头声明 IPv4，截断载荷就会进入 `IpVersion::of_packet` 的 `unwrap` 或未检查字段访问，导致内核 panic。
- **建议修复**：在 snooping 前使用 checked packet constructors 验证 IP/TCP 头和长度，异常载荷直接丢弃；接收数据路径不得使用 `unwrap` 或未检查 packet view。
- **代码证据**：`net/ax-net/src/device/ethernet.rs:337-369` ; `net/ax-net/src/router.rs:790-805` ; `net/ax-net/src/router.rs:1197-1225`

### #1740 [中危] starry：父目录遍历可逃逸 chroot 根目录

- **CWE**：CWE-22, CWE-284 · **发现编号**：`csf_538a91d041beb5d27d230bb7` · **状态**：open（未关联修复）
- **问题**：StarryOS 路径解析处理相对路径中的 `..` 时，未在进程 `FsContext.root_dir` 处截断。chroot 内进程可连续向父目录解析并获得 jail 外部祖先节点，后续文件操作随之越过 chroot 边界。
- **建议修复**：解析 `..` 时比较当前位置与进程 root_dir，并在该根处 clamp；跨 mount 和符号链接续接路径也必须保持同一不变量。
- **代码证据**：`os/StarryOS/kernel/src/syscall/fs/ctl.rs:135-151` ; `os/arceos/modules/axfs-ng/src/fs_core/context.rs:287-307` ; `os/arceos/modules/axfs-ng/src/fs_core/context.rs:325-341`

### #1742 [中危] starry：getdents64 可按用户长度无界分配内核缓冲区

- **CWE**：CWE-248, CWE-400 · **发现编号**：`csf_86a4c24107cf013c05fef3a1` · **状态**：open（未关联修复）
- **问题**：`getdents64` 在校验文件描述符前，先按调用者提供的 `len` 创建内核 `Vec`。请求没有传输上限或分块策略，即使 fd 无效也会先尝试攻击者指定大小的分配。
- **建议修复**：先校验 fd 和对象类型，再使用固定上限的内核缓冲区分块填充用户请求，不能直接按 `len` 分配。errno 和错误优先级应与目标 Linux 版本一致。
- **代码证据**：`os/StarryOS/kernel/src/syscall/fs/ctl.rs:321-327` ; `os/StarryOS/kernel/src/syscall/fs/ctl.rs:272-284`

### #1743 [中危] starry：getrandom 可按用户长度无界分配内核缓冲区

- **CWE**：CWE-248, CWE-400 · **发现编号**：`csf_918d15ce2e785a2db22afb9d` · **状态**：open（未关联修复）
- **问题**：`getrandom` 直接按用户提供的 `len` 分配 `Vec`，随后填充随机数据并复制回用户空间。请求没有大小上限或分块处理，普通 syscall 参数即可控制特权内存分配规模。
- **建议修复**：先检查用户范围的可表示性，然后使用固定大小的临时缓冲区分块生成和复制随机数据，禁止按 syscall 长度直接分配。
- **代码证据**：`os/StarryOS/kernel/src/syscall/sys.rs:850-869`

### #1744 [中危] starry：递归 shebang 解释缺少深度和环路限制

- **CWE**：CWE-248, CWE-674 · **发现编号**：`csf_1d4d8b989c64851ef1a8be9c` · **状态**：open（未关联修复）
- **问题**：脚本解释器路径会递归进入 `load_user_app`，但没有传递递归计数、检测环路或限制累计参数改写。自引用 shebang 或多个脚本组成的环会持续增长内核栈/堆，直至内核失败。
- **建议修复**：在 `load_user_app` 调用链携带解释器递归计数，采用 Linux 兼容的小深度限制并检测环路，同时限制累计改写后的 argv 数据。
- **代码证据**：`os/StarryOS/kernel/src/syscall/task/execve.rs:31-39` ; `os/StarryOS/kernel/src/syscall/task/execve.rs:176-185` ; `os/StarryOS/kernel/src/mm/loader.rs:673-713`

### #1745 [中危] arm-vgic：未实现的 MMIO 偏移可由客户机触发 hypervisor panic

- **CWE**：CWE-248, CWE-755 · **发现编号**：`csf_e17691077e98f36cd8701014` · **状态**：open（未关联修复）
- **问题**：VGICD/VGICR 已注册 MMIO 范围内仍有大量未实现偏移，读写落入默认分支时执行 `todo!`。不受信任客户机只需访问对应架构寄存器偏移即可使整个 hypervisor panic。
- **建议修复**：按 GIC 架构为客户机可见偏移实现 read-as-zero、write-ignore 或受控 emulation error，移除客户机输入路径上的 `todo!`，并覆盖完整注册范围。
- **代码证据**：`virtualization/axvm/src/arch/aarch64/mod.rs:74-107` ; `virtualization/axvm/src/architecture/exit.rs:8-33` ; `virtualization/arm_vgic/src/v3/vgicd.rs:121-190` ; `virtualization/arm_vgic/src/v3/vgicd.rs:196-266` ; `virtualization/arm_vgic/src/v3/vgicr.rs:90-218`

### #1749 [中危] axloader：串口选择的 HTTP 内核缺少真实性校验

- **CWE**：CWE-319, CWE-494 · **发现编号**：`csf_c555a3b48efcc6defa193f54` · **状态**：open（未关联修复）
- **问题**：axloader 接受未经认证的串口 BootOffer，并从明文 HTTP 下载其指定的内核。现有大小、架构、后缀、HTTP 状态与 ELF 结构检查均不验证来源，下载内容会被加载并转移最高权限控制流。
- **建议修复**：使用固定签名公钥或预期密码摘要认证 BootOffer 与内核镜像；可用时要求带证书校验的 HTTPS，任何未签名或摘要不匹配内容都必须在 ELF 加载前拒绝。
- **代码证据**：`bootloader/axloader/src/loader/control.rs:38-65` ; `bootloader/axloader/src/loader/control.rs:112-164` ; `bootloader/axloader/src/loader/mod.rs:39-74` ; `bootloader/axloader/src/loader/entry.rs:56-88` ; `bootloader/axloader/src/loader/elf_loader.rs:97-104`

### #1750 [中危] aic8800：控制面接收队列无界增长

- **CWE**：CWE-400, CWE-770 · **发现编号**：`csf_a730b92de0174c56af0b8b8a` · **状态**：open（未关联修复）
- **问题**：AIC8800 的 association、EAPOL、firmware indication/response 等控制面接收队列没有条目数或字节数上限，也没有 backpressure/drop 策略。接收路径会在容量准入前复制 payload，生产速度超过消费者或没有等待者时可持续保留内核内存。
- **建议修复**：为每类控制队列同时设置 item/byte 上限，明确 drop 或 backpressure 策略，并把容量准入放到 payload clone 之前。
- **代码证据**：`components/aic8800/src/fdrv/core/bus.rs:107-160` ; `components/aic8800/src/fdrv/core/bus.rs:171-203` ; `components/aic8800/src/fdrv/thread/rx.rs:424-433` ; `components/aic8800/src/fdrv/thread/rx.rs:568-591` ; `components/aic8800/src/fdrv/thread/rx.rs:718-747`

### #1751 [中危] starry：mq_timedsend 在校验队列限制前复制超大消息

- **CWE**：CWE-400, CWE-789 · **发现编号**：`csf_461119e62c7e5bc5280c2c80` · **状态**：open（未关联修复）
- **问题**：`mq_timedsend` 在读取消息队列并比较 `mq_msgsize` 之前，先按调用者声明的 `msg_len` 通过 `vm_load` 分配并复制用户数据。攻击者可以让内核处理远超队列配置上限的数据，之后才得到 `EMSGSIZE`。
- **建议修复**：先解析队列并比较 `msg_len` 与 `mq_msgsize`，只有验证后的有界长度才允许进入 `vm_load`；保持 Linux 兼容的错误优先级。
- **代码证据**：`os/StarryOS/kernel/src/syscall/ipc/mqueue.rs:250-267` ; `components/starry-vm/src/alloc.rs:15-27` ; `os/StarryOS/kernel/src/ipc/mqueue.rs:500-515`

### #1755 [中危] starry：execve 缺少 argv 和 envp 聚合预算

- **CWE**：CWE-400 · **发现编号**：`csf_4e6c1d738c6852ad318e9da6` · **状态**：open（未关联修复）
- **问题**：`execve` 读取 argv/envp 时只有单次读取限制，没有对指针数量与字符串总字节数做 ARG_MAX 式聚合核算。大量分别合法的字符串会先形成巨大内核集合和连续栈镜像，直到较晚的固定用户栈检查才失败。
- **建议修复**：跨 argv/envp 统一统计指针数量和字符串字节数，在 clone 或构造栈镜像前执行 Linux 兼容的 ARG_MAX 聚合上限，并对所有加法使用 checked arithmetic。
- **代码证据**：`os/StarryOS/kernel/src/syscall/task/execve.rs:104-115` ; `components/starry-vm/src/alloc.rs:35-64` ; `os/StarryOS/kernel/src/mm/loader.rs:89-145` ; `os/StarryOS/kernel/src/mm/loader.rs:719-740`

### #1762 [中危] rknpu：MemCreate 缺少 DMA 分配配额

- **CWE**：CWE-770, CWE-789 · **发现编号**：`csf_5c6faf293c0bd95d9d0c62e2` · **状态**：open（未关联修复）
- **问题**：RKNPU `MemCreate` 直接接受用户 `u64 size` 并申请页对齐连续 DMA 内存，成功分配保存在设备全局 `BTreeMap` 直到显式 destroy。路径没有单次语义上限、per-open owner、分配数/字节上限或设备聚合 quota。
- **建议修复**：设置 per-allocation 与 per-open 字节上限，把每个 GEM 对象计入调用文件 owner，在分配前执行设备总 quota，并在文件关闭时自动释放全部拥有对象和计数。
- **代码证据**：`os/StarryOS/kernel/src/pseudofs/dev/card1.rs:430-488` ; `drivers/ax-driver/src/rknpu.rs:85-87` ; `drivers/npu/rockchip-npu/src/gem.rs:67-110`

### #1729 [低危] orangepi-uvc：MJPEG 尺寸计算溢出可导致 RGB 缓冲区越界

- **CWE**：CWE-122, CWE-190 · **发现编号**：`csf_ff6fd40c5f737730bc9236f5` · **状态**：open（未关联修复）
- **问题**：UVC 回调接受设备提供的 MJPEG 数据后，`tjDecompressHeader3` 返回的宽高直接参与有符号 `int` 乘法 `width * height * 3`。该乘法溢出后可能只分配一个较小的堆缓冲区，而 `tjDecompress2` 仍按原始宽高写入完整 RGB 图像，造成堆越界写。
- **建议修复**：使用无符号宽类型保存尺寸，拒绝非正数及超出策略上限的宽高，对 `width * height * 3` 使用 checked multiplication，并确保目标缓冲区的已验证字节数覆盖解码输出。
- **代码证据**：`apps/starry/orangepi-5-plus-uvc-rknn/rknn-yolov8-image/cpp/uvc_capture.cc:77-104` ; `apps/starry/orangepi-5-plus-uvc-rknn/rknn-yolov8-image/cpp/uvc_capture.cc:119-126` ; `apps/starry/orangepi-5-plus-uvc-rknn/rknn-yolov8-image/cpp/uvc_capture.cc:133-134` ; `apps/starry/orangepi-5-plus-uvc-rknn/rknn-yolov8-image/cpp/uvc_capture.cc:141-150`

### #1733 [低危] fxmac：接收描述符长度可超出 DMA 缓冲区

- **CWE**：CWE-125, CWE-20 · **发现编号**：`csf_9db8ea0a5704bf1cf0201447` · **状态**：open（未关联修复）
- **问题**：FXMAC 接收完成路径只对设备描述符长度做位掩码，未与实际分配的一页或三页 DMA 缓冲区容量比较，随后直接用该长度构造 `from_raw_parts_mut` 切片并复制到 `Vec`，可读取分配对象之外的内存。
- **建议修复**：记录每个 RX 分配的字节容量，在构造切片前拒绝超容量长度；对异常描述符执行重置并记录设备错误，避免静默截断。
- **代码证据**：`drivers/net/fxmac_rs/src/fxmac_dma.rs:309-368` ; `drivers/net/fxmac_rs/src/fxmac_dma.rs:1040-1062` ; `drivers/net/fxmac_rs/src/fxmac_const.rs:603-620`

### #1735 [低危] rsext4：空 extent 内部节点可在插入时触发内核 panic

- **CWE**：CWE-129, CWE-20, CWE-248 · **发现编号**：`csf_a1941e6c551ba6cfc4b19645` · **状态**：open（未关联修复）
- **问题**：ext4 extent 解析允许深度大于零但 `eh_entries == 0` 的内部节点。后续文件扩展插入 extent 时会索引空向量或对子节点解析结果调用 `expect`，使恶意持久化元数据把普通写入转化为内核 panic。
- **建议修复**：当插入算法要求子节点时拒绝零条目的内部节点，用结构化损坏错误替代索引和 `expect`，并把错误完整传播到文件写入调用方。
- **代码证据**：`os/arceos/modules/axfs-ng/src/fs/ext4/rsext4/inode.rs:218-228` ; `components/rsext4/src/file/io.rs:120-134` ; `components/rsext4/src/extents_tree/parse.rs:16-90` ; `components/rsext4/src/extents_tree/insert.rs:330-357`

### #1741 [低危] wayland：APKINDEX 路径字段可逃逸软件包缓存目录

- **CWE**：CWE-22 · **发现编号**：`csf_576cca20638b464baceb24f5` · **状态**：open（未关联修复）
- **问题**：Wayland prebuild 从明文镜像读取未经认证的 APKINDEX，并把其中 P/V 字段直接拼入本地缓存路径。代码未要求单一安全路径组件，也未做 realpath containment，攻击者可通过 `../` 或绝对路径让 `open`、`os.replace`、`shutil.copy2` 写到两个缓存根之外。
- **建议修复**：强制软件包名和版本为无分隔符、无父目录的单一路径组件；解析每个目标路径并在原子替换/复制前再次确认它位于指定缓存根下。
- **代码证据**：`apps/starry/wayland/prebuild.sh:77-81` ; `apps/starry/wayland/prebuild.sh:101-107` ; `apps/starry/wayland/prebuild.sh:159-186` ; `apps/starry/wayland/prebuild.sh:207-212` ; `apps/starry/wayland/prebuild.sh:216-216`

### #1746 [低危] rsext4：存储与日志错误被转换为内核 panic

- **CWE**：CWE-248 · **发现编号**：`csf_8c1745f378a8a6d391ae0c27` · **状态**：open（未关联修复）
- **问题**：rsext4 的挂载、journal 更新/提交和卸载生产路径中存在多个 `expect`，会把正常块设备 I/O 错误或异常 journal 映射转换为内核 panic，而不是通过 `Ext4Result` 返回 VFS。
- **建议修复**：将挂载、journal update/commit 和卸载生产路径中的 `expect` 改为结构化 `Ext4Result` 传播，失败时保持事务一致性并向 VFS 返回 I/O/损坏错误。
- **代码证据**：`os/arceos/modules/axfs-ng/src/fs/ext4/rsext4/inode.rs:198-200` ; `components/rsext4/src/blockdev/journal.rs:255-270` ; `components/rsext4/src/ext4/mount.rs:205-254` ; `components/rsext4/src/ext4/mount.rs:376-388` ; `components/rsext4/src/jbd2/jbd2.rs:282-298`

### #1748 [低危] arce-agent：未认证代理可消耗操作者 API 配额

- **CWE**：CWE-306 · **发现编号**：`csf_dd27c0cd2c3ef3f42b725dfa` · **状态**：open（未关联修复）
- **问题**：ArceAgent 的宿主 LLM proxy 默认监听 `0.0.0.0:8080`，不验证客户端身份，却会为任意入站请求附加操作者配置的上游 API key。可达客户端无需知道 key 即可借用操作者身份发起请求并消耗费用/配额。
- **建议修复**：默认仅绑定 loopback；转发前要求显式客户端 token 或双向认证通道，并设置独立于调用者输入的上游费用/速率配额。
- **代码证据**：`apps/arceos/arce_agent/llm_proxy.py:31-40` ; `apps/arceos/arce_agent/llm_proxy.py:96-103` ; `apps/arceos/arce_agent/llm_proxy.py:56-68`

### #1752 [低危] nvme-driver：管理命令缺少超时可永久忙等

- **CWE**：CWE-400, CWE-835 · **发现编号**：`csf_96355de9567916ac2c3ccfb9` · **状态**：open（未关联修复）
- **问题**：NVMe 管理命令完成和 namespace 初始化使用无期限 busy-spin，控制器若不再推进 completion 或 ready 状态，初始化 CPU 会永久占用且调用无法返回。
- **建议修复**：为管理 completion 和 namespace discovery 加入 monotonic deadline，返回可匹配的 timeout error；超时后重置或隔离控制器，并在上下文允许时让出 CPU 或休眠。
- **代码证据**：`drivers/blk/nvme-driver/src/nvme.rs:152-190` ; `drivers/blk/nvme-driver/src/queue.rs:367-384` ; `drivers/blk/nvme-driver/src/queue.rs:435-451`

### #1753 [低危] rknpu：提交路径忽略超时并持有设备锁忙等

- **CWE**：CWE-400, CWE-835 · **发现编号**：`csf_ec64c02ff9a780465d23a047` · **状态**：open（未关联修复）
- **问题**：同步 RKNPU Submit 虽携带 `timeout` 字段，但完成轮询和中断清除轮询都没有 deadline。任务或设备不产生预期状态时，路径会在持有全局设备锁的情况下无限 spin，阻塞其他客户端。
- **建议修复**：用 monotonic deadline 强制执行 `RknpuSubmit.timeout`，覆盖完成与中断清除循环；超时时释放全局锁并重置/隔离卡死 core。
- **代码证据**：`os/StarryOS/kernel/src/pseudofs/dev/card1.rs:366-393` ; `drivers/npu/rockchip-npu/src/ioctrl.rs:262-288` ; `drivers/npu/rockchip-npu/src/ioctrl.rs:320-331`

### #1754 [低危] arce-agent：无界阻塞 HTTP 请求体可独占代理服务

- **CWE**：CWE-400 · **发现编号**：`csf_81c7d522cc355ba74d145501` · **状态**：open（未关联修复）
- **问题**：ArceAgent proxy 使用单线程 HTTP server，并信任未经限制的 `Content-Length` 执行阻塞读取。可达客户端可声明超大请求体造成宿主内存压力，或慢速发送以独占唯一服务循环。
- **建议修复**：配置小且明确的请求体上限，超限立即拒绝；设置 socket read 与整请求 deadline，使用有界流式读取，并采用不让单客户端独占服务的并发模型。
- **代码证据**：`apps/arceos/arce_agent/llm_proxy.py:31-40` ; `apps/arceos/arce_agent/llm_proxy.py:96-103` ; `apps/arceos/arce_agent/llm_proxy.py:40-40`

### #1756 [低危] claw-code：构建脚本执行未固定的上游分支

- **CWE**：CWE-494, CWE-829 · **发现编号**：`csf_889bc725c581cf83ec32d4c5` · **状态**：open（未关联修复）
- **问题**：Claw 应用构建 helper 对上游仓库执行浅克隆并直接编译默认分支，没有固定 commit/tag/digest，也没有保证锁定依赖图。上游分支或依赖解析变化会在开发者/CI 宿主执行新的 Cargo build script/proc macro，并把产物安装进测试镜像。
- **建议修复**：固定到审核过的不可变 commit 并验证 checkout；提交对应 lockfile 或使用 `--locked` 构建，同时记录安装二进制的来源信息。
- **代码证据**：`apps/starry/claw-code-regression/build-claw.sh:6-6` ; `apps/starry/claw-code/prebuild.sh:4-4` ; `apps/starry/claw-code-regression/build-claw.sh:25-37` ; `apps/starry/claw-code/prebuild.sh:27-42` ; `apps/starry/claw-code/prebuild.sh:62-70`

### #1757 [低危] starry-test：OrangePi 冒烟测试以 root 执行明文 HTTP 脚本

- **CWE**：CWE-494 · **发现编号**：`csf_2706839f12993d284e65238c` · **状态**：open（未关联修复）
- **问题**：OrangePi iperf 冒烟测试通过 session 明文 HTTP URL 下载 shell 脚本，未验证 TLS、摘要或签名，随后直接 `chmod` 并由 root shell 执行。实验室网络中的中间人可替换同名响应。
- **建议修复**：通过认证通道传输 session 文件，或在可信测试元数据中发布预期 SHA-256/签名；必须在 chmod/执行前验证并在不匹配时 fail closed。
- **代码证据**：`test-suit/starryos/board-orangepi-5-plus/iperf-smoke/board-orangepi-5-plus.toml:2-4` ; `test-suit/starryos/board-orangepi-5-plus/iperf-smoke/board-orangepi-5-plus.toml:7-9` ; `test-suit/starryos/board-orangepi-5-plus/iperf-smoke/board-orangepi-5-plus.toml:22-30` ; `test-suit/starryos/board-orangepi-5-plus/iperf-smoke/iperf-smoke.sh:1-23` ; `test-suit/starryos/GUIDE.md:335-339`

### #1758 [低危] wayland-hvf：以 root 安装未经认证的 APK

- **CWE**：CWE-494 · **发现编号**：`csf_e8ffa733f55d6a440d3eef23` · **状态**：open（未关联修复）
- **问题**：Wayland HVF provisioning 从明文 HTTP 镜像预取 APK，没有验证预期摘要或签名，生成的 root provisioning 又使用 `apk add --allow-untrusted --no-network` 安装并执行这些包。镜像控制者或中间人可替换可执行 APK。
- **建议修复**：使用认证传输，并校验仓库索引/包签名或固定摘要；从 HVF provisioning 移除 `--allow-untrusted`。
- **代码证据**：`apps/starry/wayland/prebuild.sh:77-81` ; `apps/starry/wayland/run-hvf.sh:245-250` ; `apps/starry/wayland/prebuild.sh:114-145` ; `apps/starry/wayland/prebuild.sh:207-224` ; `apps/starry/wayland/run-hvf.sh:252-265`

### #1759 [低危] wayland-test：以 root 安装未经认证的 APK

- **CWE**：CWE-494 · **发现编号**：`csf_0a340532627b89f664ea4cce` · **状态**：open（未关联修复）
- **问题**：普通 Wayland test 的缓存分支同样从明文 HTTP 镜像预取 APK，不校验摘要/签名，并以 root 执行 `apk add --allow-untrusted --no-network`。被替换的 Weston 或依赖包会在测试 guest 中安装并运行。
- **建议修复**：预取必须使用 HTTPS 并验证仓库签名元数据或固定包摘要，随后移除 `wayland-test.sh` 中的 `--allow-untrusted`。
- **代码证据**：`apps/starry/wayland/prebuild.sh:77-81` ; `apps/starry/wayland/prebuild.sh:114-145` ; `apps/starry/wayland/prebuild.sh:207-216` ; `apps/starry/wayland/wayland-test.sh:80-84`
