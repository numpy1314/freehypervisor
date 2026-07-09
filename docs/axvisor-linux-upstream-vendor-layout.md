# AxVisor Linux 上游源码副本布局

本文档用于把一件事说具体：

- 如果我们要把 tgoskits 里的上游 crate 带进 Linux 树
- 第一轮应该复制哪些 crate
- 它们从哪里来
- 建议在 Linux 树里放到哪里

## 1. 推荐目标目录

建议在 Linux 树里增加：

```text
linux-host-kernel/drivers/virt/axvisor/vendor/upstream/
```

第一轮建议在这下面按“crate 名字”建目录，而不是继续保留上游原始多级路径。

推荐概念形态：

```text
vendor/upstream/
  axvisor_core/
  axvisor_api/
  axvisor_api_proc/
  ax-percpu/
  ax-percpu-macros/
  ax-errno/
  ax-cpumask/
  ax-kernel-guard/
  ax-kspin/
  ax-lazyinit/
  ax-timer-list/
  ax-memory-addr/
  ax-page-table-multiarch/
  axaddrspace/
  axhvc/
  axvcpu/
  axvm/
  riscv_vplic/
  riscv_vcpu/
  ax-crate-interface/
```

## 2. 为什么不用上游原始目录结构

上游 tgoskits 使用的是 workspace 目录组织：

- `components/*`
- `memory/*`
- `virtualization/*`

但 Linux 侧第一轮不是要复制整个 workspace。

我们当前只需要一层“可控、最小、局部”的副本区，所以更推荐：

- 在 `vendor/upstream/` 下按 crate 平铺

好处是：

- 依赖清单更直观
- 后续删减或补充 crate 更方便
- 不会把整个 tgoskits workspace 形态也照搬进 Linux 树

## 3. 第一轮建议复制的 crate 清单

### 3.1 核心入口 crate

- `axvisor_core`
- `axvisor_api`
- `axvisor_api_proc`

### 3.2 runtime 直接基础依赖

- `ax-percpu`
- `ax-percpu-macros`
- `ax-errno`
- `ax-cpumask`
- `ax-kernel-guard`
- `ax-kspin`
- `ax-lazyinit`
- `ax-timer-list`
- `ax-memory-addr`
- `ax-page-table-multiarch`
- `axaddrspace`
- `ax-crate-interface`

### 3.3 runtime 虚拟化核心依赖

- `axhvc`
- `axvcpu`
- `axvm`

### 3.4 RISC-V runtime 直接架构依赖

- `riscv_vplic`
- `riscv_vcpu`

## 4. 这些 crate 的上游来源路径

当前统一上游根为：

- `~/.cargo/git/checkouts/tgoskits-bc6dd0ec549a6dd7/a8724b8/`

对应映射如下。

### 4.1 virtualization

- `virtualization/axvisor_core` -> `vendor/upstream/axvisor_core`
- `virtualization/axvisor_api` -> `vendor/upstream/axvisor_api`
- `virtualization/axvisor_api_proc` -> `vendor/upstream/axvisor_api_proc`
- `virtualization/axhvc` -> `vendor/upstream/axhvc`
- `virtualization/axvcpu` -> `vendor/upstream/axvcpu`
- `virtualization/axvm` -> `vendor/upstream/axvm`
- `virtualization/riscv_vplic` -> `vendor/upstream/riscv_vplic`
- `virtualization/riscv_vcpu` -> `vendor/upstream/riscv_vcpu`

### 4.2 components

- `components/percpu/percpu` -> `vendor/upstream/ax-percpu`
- `components/percpu/percpu_macros` -> `vendor/upstream/ax-percpu-macros`
- `components/axerrno` -> `vendor/upstream/ax-errno`
- `components/cpumask` -> `vendor/upstream/ax-cpumask`
- `components/kernel_guard` -> `vendor/upstream/ax-kernel-guard`
- `components/kspin` -> `vendor/upstream/ax-kspin`
- `components/ax-lazyinit` -> `vendor/upstream/ax-lazyinit`
- `components/timer_list` -> `vendor/upstream/ax-timer-list`
- `components/crate_interface` -> `vendor/upstream/ax-crate-interface`

### 4.3 memory

- `memory/memory_addr` -> `vendor/upstream/ax-memory-addr`
- `memory/page_table_multiarch` -> `vendor/upstream/ax-page-table-multiarch`
- `memory/axaddrspace` -> `vendor/upstream/axaddrspace`

## 5. 为什么第一轮先不继续扩大

虽然 `axvm`、`axvcpu` 这些 crate 自己还会继续带出更多依赖，但第一轮建议先停在“`axvisor_core` 的直接依赖层”和“RISC-V runtime 直接依赖层”。

原因是：

- 我们现在的目标是把依赖树第一层看清楚
- 不是立刻把整个 tgoskits workspace 搬进来

也就是说，当前这份清单的意义是：

- 先确定第一批候选副本
- 不是宣称这批复制完就一定能编过

## 6. 当前推荐策略

当前更推荐的策略是：

1. 先固定 `vendor/upstream/` 这层目录语义
2. 先按本文清单准备第一轮候选 crate
3. 再逐个展开它们的下一层依赖
4. 再决定构建接入顺序

当前状态：

- `linux-host-kernel/drivers/virt/axvisor/vendor/upstream/` 目录骨架已经创建
- 第一轮候选 crate 目录已经全部用占位 `README.md` 固定下来
- 第一批真实上游源码已经落入以下目录：
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

## 7. 和现有 bridge 层的关系

当前 Linux 侧已经有：

- `vendor::axvisor_core::*`
- `vendor::axvisor_api::*`

它们仍然保留，职责不变：

- 做 Linux 侧桥接与命名收口

新增的 `vendor/upstream/*` 不替代它们，而是给后续真实构建和 `--extern` 提供源码来源。

对应的目录总说明已经放在：

- `linux-host-kernel/drivers/virt/axvisor/vendor/README.md`

## 8. 当前最重要的结论

后续如果要真的往 Linux 树里搬源码，第一轮不应该“想到哪个搬哪个”，而应该按本文这份映射表成组引入。

当前还明显缺的下一组直接依赖主要是：

- `arm_vgic`
- `x86_vlapic`
- `riscv`
