# Hypervisor-OS 最小接口交集研究计划

## Goal Description

分析 KVM (Linux)、Firecracker (Linux/KVM)、bhyve (FreeBSD) 三种 Hypervisor 对底层 OS 的完整接口依赖，
找出三者真正的接口交集（三者都需要的 OS 功能），输出源码级分析文档和一份横向对比报告，
为 freehypervisor 的 OS 接口设计提供决策依据。

**研究范围界定：**
- "真正交集" = 三个 Hypervisor 都需要的那些 OS 接口类别
- Firecracker 分析完整栈（KVM ioctl 子集 + 额外 syscall）
- bhyve 基于 FreeBSD 14.x stable，包含 vmm.ko + bhyve(8) 两个层次
- 深度对齐现有 KVM 分析：源码级细节、调用链、数据结构

**接口粒度规范（三级分层 + 边界类型标注）：**

| 级别 | 定义 | 计数要求 | 示例 |
|------|------|---------|------|
| 一级接口 | 与 OS 边界的直接交互入口（跨特权级/跨模块边界） | ≥15 个/篇 | `hva_to_pfn()`, `KVM_RUN ioctl`, `mmap()` |
| 二级接口 | 一级接口调用的关键支撑函数（内部） | ≥35 个/篇 | `__gfn_to_memslot()`, `hva_to_pfn_fast()` |
| 三级接口 | 数据结构、配置项、常量 | 随文附带 | `kvm_mmu_notifier_ops`, `kvm_x86_ops` |

**注意**：三个 hypervisor 的 OS 接口类型不同构（KVM = kernel KPI, Firecracker = syscall/ioctl, bhyve = kernel KPI + vmm ioctl）。通过 `边界类型` 字段在对比时按类型分组，避免简单计数导致不可比结论。

**接口条目标准模板（9 字段）：**
1. 函数签名 2. 源码位置 3. 语义说明 4. 调用示例
5. 所属 OS 子系统 6. 调用上下文（provider/consumer 视角 + 谁调用它） 7. 是否 hot path
8. 边界类型（`kernel KPI` / `ioctl UAPI` / `syscall` / `libc wrapper` / `vmm ioctl` / `其他`）
9. 接口契约（输入输出约束、错误码、生命周期、锁/睡眠约束、权限要求、版本稳定性、可替代性）

**接口发现方法（五步闭环法）：**
1. 构建系统分析：从 Makefile/Kconfig/Cargo.toml 推导模块依赖链
2. Include 传递闭包：对 `#include` / `use` 语句做依赖追踪
3. 外部符号交叉引用：`EXPORT_SYMBOL` / 未定义符号 / FFI 边界
4. 用户态 syscall 提取：静态 FFI 边界分析 + 源码中的 libc 调用
5. 构建产物与运行时验证：`nm -u`/`objdump`、`cargo metadata`/`cargo tree`、seccomp policy 提取、`strace`(Linux) / `ktrace`(FreeBSD)

---
## Acceptance Criteria

- AC-1: KVM 接口分析文档按 7 大维度重构，不少于 15 个一级接口 + 35 个二级接口，每个条目含 9 个标准字段
  - Positive Tests:
    - 每个接口条目包含：函数签名、源码位置、语义说明、调用示例、所属 OS 子系统、调用上下文、hot path 标记、边界类型、接口契约
    - 文档尾部包含接口层次总览图
    - "硬件能力探测" 内容整合入维度 2（vCPU 管理）的 `vCPU 能力发现` 子节
    - 文档附录包含 "旧 5 分类 → 新 7 维度" 映射表
  - Negative Tests:
    - 不应有仅列出函数名而无语义说明的条目
    - 不包含 KVM 用户态 API（ioctl 面向用户态的部分）的内部实现细节

- AC-2: Firecracker 接口分析文档覆盖 KVM ioctl 使用子集 + Linux syscall 依赖，含源码引用
  - 分析范围：`vmm` + `firecracker` + `jailer` crate（核心），`block` / `net` 在维度 3 中作为 I/O 依赖处理
  - syscall 发现边界：以 `cargo metadata` 依赖闭包为发现范围，在报告中区分"Firecracker 自有代码直接调用"和"依赖库（rust-vmm 等）封装调用"
  - syscall 分析到 libc/FFI 调用级别
  - Positive Tests:
    - 明确列出 Firecracker 使用了哪些 KVM ioctl（与完整 KVM ioctl 集合的对比表）
    - 列出所有 syscall 依赖（含直接调用 + 依赖库封装调用，标注来源），按 7 维度类别分组
    - 标注 Firecracker 的简化设计决策（哪些 KVM ioctl 没有用、为什么）
  - Negative Tests:
    - 不应遗漏 vsock、tap、eventfd、timerfd、seccomp、cgroup、namespace 等关键非 KVM 接口

- AC-3: bhyve 接口分析文档覆盖 vmm.ko 和 bhyve(8) 对 FreeBSD 14.x 的接口依赖，含源码引用
  - 内核层（vmm.ko）：完整追踪 `#include` 传递闭包和所有外部符号引用（机器生成原始清单），正文中按 FreeBSD 内核子系统分组纳入人工确认的接口族（pmap、vm、intr、smp、taskqueue、priv、capsicum 等）
  - 用户态层（bhyve(8)）：通过 `libvmmapi` 封装 `/dev/vmm` 和 ioctl，分析 bhyve(8) 中对 vmm.ko 交互的核心路径（boot、vCPU 运行、内存映射、基本 I/O），设备模拟代码按子维度 3b 归入 I/O 设备协议
  - Positive Tests:
    - 覆盖 vmm.ko 内核接口，按 VM/pmap/smp/intr/malloc/priv 等子系统分组
    - 覆盖 bhyve(8) 用户态接口（syscall + vmm ioctl），包含 `libvmmapi` 封装层
    - 与 FreeBSD 特有机制（如 CAM 存储栈、Capsicum sandbox、jail、devfs）的关联
  - Negative Tests:
    - 不应将 Linux 特有概念直接套用到 FreeBSD
    - 不应忽略 bhyve(8) 的用户态成分和 libvmmapi 中间层

- AC-4: 对比文档对三个 Hypervisor 按统一维度进行横向对比，采用分层标注法
  - 两个层次做交集标注：(a) 类别层面——功能等价即为交集；(b) 具体接口层面——API 直接对应关系的标注
  - 按 `边界类型` 分组对比（kernel KPI / ioctl / syscall 分开统计），避免不同构接口直接计数比较
  - 定量统计维度：(a) 接口总数（按边界类型分组）；(b) 三者交集数；(c) 独有接口数（仅一个 hypervisor 使用）；(d) 部分交集（两个有、一个没有）；(e) ioctl 种类数、syscall 白名单大小、模块依赖图深度
  - Positive Tests:
    - 包含按 7 维度的分组对比表
    - 交集部分有明确的三层统计数字（类别层 + 接口层 + 定量层）
    - 每个 Hypervisor 的独特依赖有清晰标注
  - Negative Tests:
    - 不应是三个分析文档的简单粘贴拼接
    - 对比表中不应有空缺项

- AC-5: 源码按组织规则放置
  - `code/kvm-linux-reference/`：`arch/x86/kvm/` + `virt/kvm/kvm_main.c` + `include/linux/kvm_host.h`
  - `code/firecracker-reference/`：Firecracker 完整仓库（含 Cargo.toml/Cargo.lock），版本固定为 tag + commit hash + 发布日期
  - `code/bhyve-reference/`：`sys/amd64/vmm/` + `usr.sbin/bhyve/` + `lib/libvmmapi/` + `sys/modules/vmm/Makefile` + 关键头文件（`sys/sys/vmm.h` 等）
  - Positive Tests:
    - 每个 source 目录可通过 grep 做接口发现
    - 包含构建系统文件（Makefile / Cargo.toml）供依赖分析
    - bhyve 用户态源码包含 libvmmapi，接口路径完整
  - Negative Tests:
    - 不包含完整 Linux/FreeBSD 内核源码树
    - 不包含二进制文件或构建产物

- AC-6: 分析文档放在 `docs/<hypervisor>/` 子目录下，对比文档在 `docs/` 根目录
  - `docs/kvm/` 含 KVM 接口分析文档 + 旧分类映射附录
  - `docs/firecracker/` 含 Firecracker 接口分析文档
  - `docs/bhyve/` 含 bhyve 接口分析文档
  - `docs/hypervisor_interface_comparison.md` 为对比文档

- AC-7: 每个分析阶段在开始撰写文档前，先产出接口清单（interface inventory）供评审
  - KVM 重构：产出旧 5 分类 → 新 7 维度映射表 + 接口归属清单
  - Firecracker：产出 KVM ioctl 使用子集对比表 + syscall 依赖清单（含依赖闭包来源标注）
  - bhyve：产出 vmm.ko 外部符号原始清单（机器生成）+ 人工精选接口清单 + bhyve(8) syscall/ioctl 清单
  - 清单评审通过后方可进入撰写阶段

---
## Path Boundaries

### Upper Bound (Maximum Scope)
- 每个分析文档 1000-1500 行（因从 7 字段扩展到 9 字段 + 增加边界类型和契约信息，上限从 1200 调整）
- 每个接口条目含 9 个标准字段 + 可选的横切标签
- 对比文档包含：三层统计 + 按边界类型分组对比 + 复杂度度量 + FreeBSD vs Linux OS 差异分析
- bhyve 分析覆盖 vmm.ko 完整外部符号原始清单 + 人工精选接口族，bhyve(8) 经 libvmmapi 的全路径

### Lower Bound (Minimum Scope)
- 每个分析文档 600-800 行（因字段增加，下限从 500 调整）
- 每个文档 ≥15 一级接口 + ≥35 二级接口，每个条目含 9 字段
- 接口发现方法至少使用五步中的前 4 步（构建系统分析 + Include 传递闭包 + 外部符号交叉引用 + 用户态 syscall 提取），第 5 步（构建产物与运行时验证）为推荐项
- 对比文档包含：7 维度分组对比表 + 按边界类型分组的交集统计

### Allowed Choices
- 使用 `git clone --depth 1` + git sparse-checkout 获取源码
- 使用 grep、cscope、LSP、`nm`、`cargo metadata`、`objdump` 进行接口发现
- Firecracker 版本：固定 tag（如 `v1.10.0`）+ commit hash + 发布日期，写入文档头部
- bhyve：FreeBSD 14.x stable（`stable/14` 分支），记录 checkout 的 commit hash
- KVM 源码：复用已有 + 补充 `virt/kvm/` 和关键头文件

### Prohibited
- 不能使用未经确认的二进制文件
- 不能提交 >100MB 的文件到 git
- 不要对完整 Linux/FreeBSD 内核做全量 clone

---
## Dependencies and Sequence

### Pre-existing Assets
- `code/linux-kvm-reference/` — 已有 `arch/x86/kvm/`，需补充 `virt/kvm/kvm_main.c` 和 `include/linux/kvm_host.h`
- `docs/kvm_linux_interface_analysis.md` — 现有 5 分类 KVM 分析（用途：重构为 7 维度模板）
- `docs/solo5_architecture_research.md` — Solo5 研究（用途：作为设计哲学参考而非技术对比）

### Milestones

**Milestone 1: 基础设施搭建** (不依赖外部数据)
- Phase 1.1: 目录结构调整
  - 迁移 `docs/kvm_linux_interface_analysis.md` → `docs/kvm/kvm_linux_interface_analysis.md`
  - 创建 `docs/firecracker/` 和 `docs/bhyve/` 子目录
  - Solo5 文档保留在 `docs/` 根目录不动
- Phase 1.2: 产出 KVM 重构映射表（旧 5 分类 → 新 7 维度），作为 AC-7 的第一个接口清单
- Phase 1.3: 基于映射表重构 KVM 分析文档为 7 维度，应用三级分层 + 9 字段模板 + 横切标签
- Phase 1.4: 验证 CLAUDE.md 规则生效

**Milestone 2: 源码获取** (依赖网络，M2.1 和 M2.2 可并行)
- Phase 2.1: Firecracker 源码拉取（固定版本 tag，记录 commit hash）
  ```bash
  git clone --depth 1 --branch <TAG> https://github.com/firecracker-microvm/firecracker.git code/firecracker-reference/
  ```
- Phase 2.2: FreeBSD bhyve 源码提取（使用 sparse-checkout）
  ```bash
  # 从 FreeBSD stable/14 提取：
  # sys/amd64/vmm/           (vmm.ko 内核模块)
  # usr.sbin/bhyve/          (bhyve(8) 用户态)
  # lib/libvmmapi/           (vmmapi 封装库)
  # sys/modules/vmm/Makefile (构建系统)
  # sys/sys/vmm.h 等关键头文件
  ```
- Phase 2.3: 补充 KVM 缺失文件
  - 从 Linux 内核提取 `virt/kvm/kvm_main.c` 和 `include/linux/kvm_host.h`
  - 运行 `nm -u` 或等效检查确认外部符号覆盖

**Milestone 3: Firecracker 分析** (依赖: M2.1)
- Phase 3.1: 构建系统分析：运行 `cargo metadata` 和 `cargo tree` 获取完整依赖闭包
- Phase 3.2: 产出 KVM ioctl 使用子集清单（对比表：ioctl 名称、Firecracker 调用位置、完整 KVM ioctl 集的对应状态）
- Phase 3.3: 产出 syscall 依赖清单
  - 第 1 层：Firecracker 自有代码中直接的 libc/FFI 调用
  - 第 2 层：`cargo metadata` 依赖闭包中的 syscall（标注来源 crate）
  - 第 3 层：seccomp policy 中白名单 syscall 的交叉验证
  - 按 7 维度分组
- Phase 3.4: 接口清单评审（AC-7 质量门，通过后进入撰写）
- Phase 3.5: 撰写 Firecracker 接口分析文档（应用 9 字段模板 + 边界类型标注 + 横切标签）

**Milestone 4: bhyve 分析** (依赖: M2.2)
- Phase 4.1: vmm.ko 构建系统分析：从 `sys/modules/vmm/Makefile` 出发，确定模块边界
- Phase 4.2: vmm.ko 外部符号完整追踪
  - 步骤 A: `#include` 传递闭包（机器生成）
  - 步骤 B: `nm -u` 或等效工具提取未定义符号（机器生成）
  - 步骤 C: 人工筛选——从原始清单中挑出接口族（pmap、vm、intr、smp、taskqueue、priv、capsicum 等）
- Phase 4.3: 产出 vmm.ko 外部符号清单
  - 完整原始清单（机器生成，作为附录）
  - 人工精选接口清单（正文，按 FreeBSD 内核子系统分组，每组 3-8 个关键入口）
- Phase 4.4: bhyve(8) 用户态接口清单
  - 通过 `libvmmapi` 封装的 vmm ioctl 调用
  - 直接 syscall 依赖
  - Capsicum/jail/devfs 等 FreeBSD 特有机制的依赖
- Phase 4.5: 接口清单评审（AC-7 质量门）
- Phase 4.6: 撰写 bhyve 接口分析文档（应用 9 字段模板 + 边界类型标注 + 横切标签）

**Milestone 5: 对比与总结** (依赖: M3 + M4 完成)
- Phase 5.1: 以 7 维度为框架建立对比矩阵，横切标签用于辅助分组
- Phase 5.2: 分层标注交集
  - L1 类别层面：三个 hypervisor 是否都需要此功能？
  - L2 接口层面：具体 API 是否有对应关系？
  - 按 `边界类型` 分组展示，避免不同构接口直接计数比较
- Phase 5.3: 统计定量数据
  - 接口总数（按边界类型分组：kernel KPI、ioctl、syscall）
  - 三者交集数、部分交集数、独有接口数
  - ioctl 种类数、syscall 白名单大小、模块依赖图深度
- Phase 5.4: 撰写对比文档 + 7 维度交叉表 + 按边界类型分组的交集统计表
- Phase 5.5: 整理最终目录结构，更新 git

---
## Implementation Notes

### 统一对比框架（7 主维度 + 横切标签）

| 维度 | 覆盖内容 | 子维度 |
|------|---------|--------|
| 1. 内存管理 | 地址空间、GPA→HPA 映射、页面锁定 | — |
| 2. vCPU 管理 | 创建/销毁、运行/暂停、寄存器访问、硬件能力发现 | vCPU 生命周期、vCPU 能力发现 |
| 3. I/O 模型 | 设备模拟、PIO/MMIO、virtio | 3a. I/O 资源访问、3b. I/O 设备协议 |
| 4. 中断与事件 | 中断注入、事件通知、信号、eventfd/irqfd | — |
| 5. 时钟与定时器 | 高精度时钟、定时器源、时钟虚拟化 | — |
| 6. 调度与同步 | 线程模型、抢占、锁 | — |
| 7. 安全与隔离 | 权限模型、沙箱、资源限制 | — |

**横切标签**（可选标注，一个接口可同时属于一个主维度和多个横切标签）：

| 横切标签 | 覆盖内容 | 典型接口示例 |
|----------|---------|-------------|
| 控制面生命周期 | VM/vCPU 创建销毁、API 版本协商 | `KVM_CREATE_VM`, `VM_CREATE` |
| fd/device node | 文件描述符模型、设备节点操作 | `open("/dev/kvm")`, `open("/dev/vmm")` |
| host 资源 | 文件/镜像加载、后端存储、网络后端 | `tap`, `vhost`, block backing file |
| PCI/IOMMU/DMA | 硬件资源直通、地址翻译 | IOMMU mapping, PCI passthrough |
| 可观测性 | 日志、metrics、tracing | `kvm_debugfs`, `bhyvectl` 统计接口 |
| 配置与资源限制 | cgroup、rlimit、jail、参数配置 | `cgroup`, `rlimit`, `jail` |

### 输出文件结构（最终态）

```
code/
  kvm-linux-reference/
    arch/x86/kvm/              (已有)
    virt/kvm/kvm_main.c        (新增)
    include/linux/kvm_host.h   (新增)
  firecracker-reference/       (Firecracker 完整仓库，固定 tag)
  bhyve-reference/
    sys/amd64/vmm/             (vmm.ko)
    usr.sbin/bhyve/            (bhyve(8))
    lib/libvmmapi/             (vmmapi 封装库)
    sys/modules/vmm/Makefile   (构建系统)
    sys/sys/vmm.h              (关键头文件)
docs/
  kvm/
    kvm_linux_interface_analysis.md
  firecracker/
    firecracker_linux_interface_analysis.md
  bhyve/
    bhyve_freebsd_interface_analysis.md
  hypervisor_interface_comparison.md
  solo5_architecture_research.md       (保留)
  solo5_os_interface_analysis.md       (保留)
```

### 接口条目质量标准

每个一级/二级接口条目必须满足：
1. **可溯源**：读者可从源码位置直接找到对应代码
2. **有上下文**：不仅说明"是什么"，还说明"在什么场景下被调用"
3. **可对比**：条目描述方式便于跨 hypervisor 对比（使用统一的 OS 子系统术语 + `边界类型` 标注）
4. **有判断**：标注该接口是否为 hot path、是否可被替换（`接口契约` 字段包含可替代性评估）

### 注意事项
- 文档是分析产物，不应包含 "AC-X" 等计划术语
- 对比文档必须独立可读，不能假设读者读过其他三个分析文档
- 对比时按 `边界类型` 分组展示，避免将 kernel KPI 与用户态 syscall 直接计数比较
- Firecracker 文档头记录源码版本（tag + commit hash + 发布日期），保证可复现
- bhyve 文档头记录 FreeBSD 分支和 checkout commit hash
- Firecracker 的 syscall 清单标注两层来源：自有代码直接调用 vs 依赖库封装调用
- bhyve 分析正文只纳入人工确认接口族，include 传递闭包原始清单作为附录
- I/O 维度中 bhyve 的设备模拟代码（AHCI、virtio、NVMe 等）归入子维度 3b，以控制分析规模
