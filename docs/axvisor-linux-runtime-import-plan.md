# AxVisor Linux Runtime 最小导入计划

本文档只讨论：

- 如果我们要先打通 `runtime`
- 那么 `axvisor_core::boot::run()` 背后到底需要哪些真实源码
- 这些源码现在从哪里来
- Linux 侧第一轮应该如何落位

## 1. 一个需要先修正的判断

前面我们把“第一批 crate”先记成：

- `axvisor_core`
- `axvisor_api`
- `ax-percpu`
- `ax-errno`
- `spin`

这个判断只适合作为“最先关注的入口名”。

但如果按真实 `Cargo.toml` 展开，`axvisor_core` 的 runtime 最小导入并不止这 5 个。

也就是说：

- 这 5 个 crate 不是错
- 但它们不是 runtime 真正可运行的完整最小集

## 2. 真实源码来源

当前工作区里没有这些 crate 的源码副本。

它们现在实际位于本机 cargo git cache：

- `~/.cargo/git/checkouts/tgoskits-bc6dd0ec549a6dd7/a8724b8/`

这里的关键源码位置已经确认：

- `axvisor_core`
  - `~/.cargo/git/checkouts/tgoskits-bc6dd0ec549a6dd7/a8724b8/virtualization/axvisor_core/`
- `axvisor_api`
  - `~/.cargo/git/checkouts/tgoskits-bc6dd0ec549a6dd7/a8724b8/virtualization/axvisor_api/`
- `ax-percpu`
  - `~/.cargo/git/checkouts/tgoskits-bc6dd0ec549a6dd7/a8724b8/components/percpu/percpu/`
- `ax-errno`
  - `~/.cargo/git/checkouts/tgoskits-bc6dd0ec549a6dd7/a8724b8/components/axerrno/`

这说明后续 Linux 侧如果要做第一轮接入，不能凭空写 crate 名字，必须先决定：

- 是从这个 cache 复制源码进仓库
- 还是以它为参考再人工裁剪一份最小副本

当前更推荐：

- 先以这个 cache 作为“真实上游来源”
- 再决定 Linux 树里放一份最小副本

更具体的第一轮目录方案已经单独整理在：

- `docs/axvisor-linux-upstream-vendor-layout.md`

## 3. `axvisor_core` 真实直接依赖

根据当前 `axvisor_core/Cargo.toml`，它直接依赖：

- `spin`
- `log`
- `hashbrown`
- `byte-unit`
- `ax-cpumask`
- `ax-kernel-guard`
- `ax-kspin`
- `ax-lazyinit`
- `ax-percpu`
- `ax-timer-list`
- `ax-errno`
- `ax-memory-addr`
- `ax-page-table-multiarch`
- `axaddrspace`
- `axhvc`
- `axvcpu`
- `axvm`
- `axvisor_api`
- `fdt-parser`

并且在 `riscv64` 下还直接依赖：

- `riscv_vplic`
- `riscv_vcpu`

这意味着一个非常关键的现实：

- 如果我们要让 `vendor::axvisor_core::boot::run` 真的接到“真实 `axvisor_core`”
- 那 Linux 侧第一轮真正要面对的不是 5 个 crate
- 而是一串 runtime 核心依赖链

## 4. `axvisor_api` 真实直接依赖

根据当前 `axvisor_api/Cargo.toml`，它直接依赖：

- `axvisor_api_proc`
- `ax-errno`
- `axaddrspace`
- `ax-crate-interface`
- `ax-memory-addr`
- `ax-cpumask`

这进一步说明：

- 单独把 `axvisor_api` 塞进来还不够
- 它自己也会带进一批基础设施 crate

## 5. `ax-percpu` 真实直接依赖

根据当前 `ax-percpu/Cargo.toml`，它直接依赖：

- `cfg-if`
- `ax-kernel-guard`（可选）
- `ax-percpu-macros`
- `spin`（在 `not(target_os = "none")` 下）
- `x86`（仅 x86_64）

这里对 Linux 侧最重要的是：

- 它不是一个孤立小 crate
- 它还带了 proc-macro 和 guard 相关依赖

## 6. 所以 runtime 第一轮真正该怎么理解

runtime 第一轮不应该理解成：

- “只引 5 个 crate”

而应该理解成：

- “先围绕 `axvisor_core::boot::run()` 收口一组最小可见依赖闭环”

更准确地说，第一轮目标应该是：

1. 先固定 `axvisor_core` 的真实源码来源
2. 先枚举它的直接依赖闭环
3. 先把 runtime 路径需要的那部分依赖树引进来
4. 暂时不追求 timer/irq 的真实执行

## 7. Linux 侧推荐落位方式

当前阶段更推荐在 Linux 树里增加一层“本地副本 staging 区”，而不是直接每次都去 cargo cache 读。

推荐概念布局：

```text
linux-host-kernel/drivers/virt/axvisor/
  vendor/
    upstream/
      axvisor_core/
      axvisor_api/
      ax-percpu/
      ax-errno/
      ...
```

这里的 `upstream/` 含义是：

- 表示这些是从 tgoskits 上游带下来的源码副本
- 不和当前手写的 `vendor::axvisor_core::*` Rust 模块命名混在一起

这样后面职责会比较清楚：

- `vendor/axvisor_core/*.rs`
  - 继续做 Linux 侧 bridge 命名层
- `vendor/upstream/*`
  - 存真实上游 crate 源码

## 8. 为什么建议加 `vendor/upstream/`

因为当前 `vendor/` 下已经有一层 Rust 模块命名空间：

- `vendor::axvisor_core`
- `vendor::axvisor_api`

如果把真实上游源码也直接塞进同一层，会马上混淆两件事：

1. Linux 侧桥接模块
2. 上游 crate 源码副本

分开之后更容易控制：

- bridge 层继续服务当前 adapter
- upstream 层只负责后续构建可见性

## 9. runtime 第一轮推荐的真实动作顺序

现在更准确的顺序应该是：

1. 固定上游来源：
   - `~/.cargo/git/checkouts/tgoskits-bc6dd0ec549a6dd7/a8724b8/`
2. 先为 Linux 侧设计 `vendor/upstream/` 目录
3. 先列出 `axvisor_core` runtime 直接依赖清单
4. 先决定第一轮只复制哪些 crate 进 `vendor/upstream/`
5. 再设计构建规则
6. 最后才让 `vendor::axvisor_core::boot::run` 去接真实入口

当前进展：

- 已经完成 `vendor/upstream/` 目录骨架
- 已经拷入第一批真实上游源码：
  - `axvisor_core`
  - `axvisor_api`
  - `axvisor_api_proc`
  - `ax-errno`
  - `ax-cpumask`
  - `ax-crate-interface`
  - `ax-lazyinit`
  - `ax-kernel-guard`
  - `ax-kspin`
  - `ax-timer-list`
  - `ax-memory-addr`
  - `ax-percpu`
  - `ax-percpu-macros`
  - `ax-page-table-multiarch`
  - `axaddrspace`
  - `ax-memory-set`
  - `ax-page-table-entry`
  - `axhvc`
  - `axvcpu`
  - `axvm`
  - `riscv_vplic`
  - `riscv_vcpu`
  - `axdevice`
  - `axdevice_base`
  - `axvmconfig`
  - `riscv-h`

这意味着现在已经从“纯规划阶段”进入“真实源码落位阶段”。

当前最新暴露出的下一层关键缺口是：

- `arm_vgic`
- `x86_vlapic`
- `riscv`

这说明：

- `axvisor_core` 的虚拟化主链主体和它们最直接的一层支撑 crate 已经基本落位
- 当前继续暴露出来的更多是架构/平台分支依赖，而不再只是通用 runtime 主链

其中 RISC-V 方向当前又已经继续推进到：

- `riscv`
- `sbi-spec`
- `sbi-rt`
- `rustsbi`
- `riscv-decode`

因此下一阶段的重点，已经逐步从“补 AxVisor 主链源码”转向：

1. 清理已复制源码中的非必要文件
2. 继续补底层第三方依赖
3. 开始设计真正的构建接线方式

其中第 1 项的执行清单已经单独整理在：

- `docs/axvisor-linux-vendor-cleanup-plan.md`

当前第 1 项已经完成第一轮低风险执行：

- `.git/.github/tests/examples/ci`
- `Cargo.lock`
- `.cargo-ok`
- `.cargo_vcs_info.json`

都已经从本地 vendor 副本中清掉。

## 10. 当前最重要的新结论

当前最重要的新结论只有一句：

- `runtime` 的第一轮真实接入，比“5 个 crate”要大，必须按 `axvisor_core` 的真实直接依赖闭环来规划。
