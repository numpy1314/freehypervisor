# Plan Refinement QA Ledger

> 本文件记录 `plan_hypervisor_interface_research.md` 从初版到最终精炼版的所有 CMT 处理。
> 生成日期：2026-05-30
> 收敛状态：**已收敛**（两轮共 23 个 CMT 全部处理完毕）

---

## 第一轮精炼（用户驱动的颗粒度细化）

| CMT | 位置 | 分类 | 关键决策 | 状态 |
|-----|------|------|---------|------|
| CMT-1.1 | Goal Description → 接口条目字段 | change_request | 采纳 7 字段统一模板 | ✅ |
| CMT-1.2 | Goal Description → 接口计数单位 | question | 采纳三级分层: L1≥15 + L2≥35 + L3 随文 | ✅ |
| CMT-1.3 | Goal Description → 接口发现方法 | change_request | 采纳系统化四步法 | ✅ |
| CMT-1.4 | AC-1 → KVM 维度映射 | question | 硬件能力探测归入维度 2（vCPU 管理） | ✅ |
| CMT-1.5 | AC-2 → Firecracker 代码范围 | question | vmm+firecracker+jailer 核心, block/net 归入维度 3 | ✅ |
| CMT-1.6 | AC-2 → Firecracker syscall 深度 | question | 分析到 libc 调用级别（FFI/unsafe 边界） | ✅ |
| CMT-1.7 | AC-3 → bhyve 内核追踪深度 | question | 完整追踪: include 传递闭包 + 外部符号引用 | ✅ |
| CMT-1.8 | AC-3 → bhyve(8) 设备模拟范围 | question | 核心路径全覆盖, 设备协议归入子维度 3b | ✅ |
| CMT-1.9 | AC-4 → 对比文档交集层次 | question | 分层标注法（类别层 + 接口层 + 定量层） | ✅ |
| CMT-1.10 | AC-4 → 定量统计维度 | change_request | 采纳全部统计维度 | ✅ |
| CMT-1.11 | AC-5 → 源码文件清单 | change_request | 明确三类源码的精确文件范围 | ✅ |
| CMT-1.12 | AC-6 → 新增 AC-7 质量门 | change_request | 采纳: 每个分析阶段先产接口清单再撰写 | ✅ |
| CMT-1.13 | I/O 维度拆分 | change_request | 采纳: 维度 3 拆为 3a + 3b | ✅ |
| CMT-1.14 | Pre-existing Assets → KVM 缺失文件 | research_request | 需补充 virt/kvm/kvm_main.c + kvm_host.h | ✅ |
| CMT-1.15 | M1 → KVM 重构映射表 | change_request | 采纳: 旧分类→新维度映射表作为附录 | ✅ |

---

## 第二轮精炼（Codex 审查驱动）

| CMT | Codex 发现 | 分类 | 处置 | 状态 |
|-----|-----------|------|------|------|
| CMT-2.1 | L1/L2 跨 hypervisor 不同构 → 增加 `边界类型` 字段 | change_request | 采纳：9 字段模板含 `边界类型`（kernel KPI / ioctl UAPI / syscall / libc wrapper / vmm ioctl），对比时按类型分组 | ✅ |
| CMT-2.2 | 缺"接口契约"信息 → 增加 `契约/约束` 字段 | change_request | 采纳：9 字段模板含 `接口契约`（错误码、锁约束、生命周期、权限、可替代性） | ✅ |
| CMT-2.3 | Firecracker 范围偏窄 → 用 cargo metadata 依赖闭包 | change_request | 采纳：分析范围保持 vmm+firecracker+jailer，syscall 发现边界扩展到 `cargo metadata` 依赖闭包，报告中区分"直接调用"vs"依赖库封装"，补充 seccomp/cgroup/namespace | ✅ |
| CMT-2.4 | bhyve include 闭包会爆炸 → 剪枝规则 | change_request | 采纳：保留完整闭包作为机器生成原始清单（附录），正文只纳入人工确认接口族（pmap/vm/intr/smp/taskqueue/priv/capsicum） | ✅ |
| CMT-2.5 | bhyve 源码漏 libvmmapi → 补充 | change_request | 采纳：AC-5 增加 `lib/libvmmapi/`、`sys/modules/vmm/Makefile`，bhyve(8) 分析经 libvmmapi 封装层 | ✅ |
| CMT-2.6 | 缺横切关注点 → 补充横切标签 | change_request | 采纳：6 个横切标签（控制面生命周期/fd 与 device node/host 资源/PCI-IOMMU-DMA/可观测性/配置与资源限制），作为可选的辅助标注，不增加主维度数量 | ✅ |
| CMT-2.7 | 四步发现法不够闭环 → 增加第 5 步 | change_request | 采纳：增加"构建产物与运行时验证"（nm -u/objdump、cargo metadata/cargo tree、seccomp policy 提取、strace/ktrace） | ✅ |
| CMT-2.8 | Firecracker "最新 stable" 不可复现 | change_request | 采纳：Firecracker 版本固定为 tag + commit hash + 发布日期，写入文档头部；bhyve 同理固定 commit hash | ✅ |

---

## 关键决策汇总

| 决策 ID | 决策内容 | 来源 | 影响 |
|---------|---------|------|------|
| D-1 | 接口三级分层: L1≥15 + L2≥35 + L3 随文 | 用户 | 三个分析的计数标准统一 |
| D-2 | 9 字段模板（+边界类型 +接口契约） | Codex + 用户 | 条目从 7→9 字段，文档上限从 1200→1500 行 |
| D-3 | 保持 7 主维度，硬件能力探测归入维度 2 | 用户 | 避免维度膨胀 |
| D-4 | I/O 拆为 3a（资源访问）+ 3b（设备协议） | 用户 | 解决三个 hypervisor I/O 模型差异 |
| D-5 | 6 个横切标签作为可选辅助标注 | Codex + 用户 | 增加标注粒度但不增加主维度 |
| D-6 | 质量门 AC-7：接口清单先评审再撰写 | 用户 | 避免返工 |
| D-7 | 五步闭环发现法（+运行时验证） | Codex | 补全条件编译/宏/生成绑定的盲区 |
| D-8 | Firecracker syscall 发现扩展到依赖闭包 | Codex | 避免漏掉 rust-vmm 等依赖库中的 syscall |
| D-9 | bhyve include 闭包：机器清单→人工精选 | Codex | 控制正文规模，保留完整数据 |
| D-10 | bhyve 源码补充 libvmmapi + Makefile | Codex | 修复用户态接口路径断层 |
| D-11 | 对比时按边界类型分组统计 | Codex + 用户 | 避免 kernel KPI vs syscall 直接计数不可比 |
| D-12 | 版本固定 tag + commit hash + 日期 | Codex | 保证可复现性 |

---

## 变更总结（初版 → 最终版）

| 变更领域 | 初版 | 最终版 |
|---------|------|--------|
| 接口粒度 | 无统一定义 | 三级分层 + 边界类型标注 |
| 条目模板 | 4 字段 | 9 字段（+边界类型 +接口契约） |
| 接口发现 | "代码阅读 + grep" | 五步闭环法（含运行时验证） |
| 对比维度 | 未定义 | 7 主维度 + 2 子维度 + 6 横切标签 |
| 质量门 | 无 | AC-7 接口清单评审 |
| 交集标注 | 未定义 | 三层标注：类别层 + 接口层 + 定量层（按边界类型分组） |
| 文档规模 | 400-1000 行 | 600-1500 行 |
| bhyve 深度 | 未定义 | include 传递闭包(机器) → 人工精选接口族 |
| bhyve 源码 | `sys/amd64/vmm/` + `usr.sbin/bhyve/` | + `lib/libvmmapi/` + `sys/modules/vmm/Makefile` + 头文件 |
| Firecracker 范围 | 未定义 | vmm+firecracker+jailer，syscall 发现扩展到 cargo 依赖闭包 |
| Firecracker 版本 | "最新 stable" | 固定 tag + commit hash + 发布日期 |
| KVM 源码 | 仅 `arch/x86/kvm/` | + `virt/kvm/` + `include/linux/kvm_host.h` |
| AC 数量 | 6 | 7 |

---

## 第三轮：Codex 二次审查 + 收尾修正

| 项目 | 内容 |
|------|------|
| 审查日期 | 2026-05-30 |
| 审查结论 | **计划可以进入执行阶段**，无阻塞风险 |
| 审查意见路径 | `.humanize/skill/2026-05-30_14-58-12-2324806-120bda12/output.md` |
| 上一轮 8 问题修正确认 | 8/8 全部修正到位 |
| 剩余修正 | 3 个小修订（非阻塞） |

**收尾修正清单：**

| 修正 | 内容 | 状态 |
|------|------|------|
| fix-1 | 字段 6 明确为"调用上下文（provider/consumer 视角 + 谁调用它）" | ✅ |
| fix-2 | 字段 9 补充"版本稳定性" | ✅ |
| fix-3 | Lower Bound 发现方法步骤数不一致修正（原写"构建产物验证（五步中的前 4 步）"改为正确描述） | ✅ |

**审查给出的执行建议：**
1. AC-7 的接口清单评审需严控"功能等价 vs API 等价"的判定边界
2. bhyve 运行时验证（ktrace/DTrace）需 FreeBSD 环境，执行前应确认，否则降级为源码+构建产物验证

---

## 元数据

- **输入计划**: `docs/plan_hypervisor_interface_research.md`
- **精炼轮次**: 3 轮（R1: 用户颗粒度细化 15 CMT, R2: Codex 审查 8 CMT, R3: Codex 二次审查 + 3 收尾修正）
- **外部审查**: 
  - R2: Codex (gpt-5.5:high)，审查意见 `.humanize/skill/2026-05-30_14-39-16-2318718-3b29a76b/output.md`
  - R3: Codex (gpt-5.5:high)，审查意见 `.humanize/skill/2026-05-30_14-58-12-2324806-120bda12/output.md`
- **执行模式**: discussion（用户参与关键决策）
- **用户交互**: 3 轮提问（7 个问题总计）
- **语言**: 中文（统一）
- **CMT 总数**: 23（R1: 15, R2: 8）
- **收敛状态**: ✅ 已收敛 — **准备进入执行阶段**
