# AxVisor Linux 适配执行路线图

本文档把当前已有分析收敛成一张真正可执行的路线图。

目标不是继续解释问题，而是明确：

- 先做什么
- 后做什么
- 每一阶段完成的标志是什么

## 1. 总目标

总目标可以分成两层：

### 1.1 第一层目标

让 Linux 侧：

- 保持现有 adapter 结构不大改
- 把真实 `axvisor_core::boot::run()` 接进来
- 至少打通 runtime 路径

### 1.2 第二层目标

在 runtime 路径之后，再逐步打通：

- timer 真实路径
- external IRQ 真实注入路径

当前阶段只盯第一层目标。

## 2. 已完成基础

当前已经具备的基础如下：

### 2.1 adapter 结构

Linux 侧已经有：

- `axvisor_adapter_main.rs`
- `core_link/`
- `vendor/`
- `axvisor_core_stub.rs`
- `arch/riscv64.rs`

### 2.2 30 个接口第一版

当前大多数接口已经有 Linux 语义封装，尤其是：

- task
- sync
- host
- console
- time
- memory

### 2.3 source staging

当前已经有：

- `vendor/upstream/*`
- `vendor/registry/*`

也就是说：

- AxVisor 主体源码和一批依赖源码已经进入 Linux 树内侧工作区

## 3. 当前真正关键路径

当前真正的关键路径，不是继续补接口壳，而是下面 4 件事：

1. host-side `proc-macro` 构建链
2. runtime 最小普通 crate 链
3. `axvisor_core/build.rs` 策略
4. runtime 真实入口切换

## 4. 分阶段执行

## Phase 0：冻结 adapter 主体结构

### 目标

明确当前阶段不再大改这几个层次：

- `axvisor_adapter_main.rs`
- `core_link/`
- `vendor/`

### 原因

因为当前问题已经不在“结构搭没搭起来”，而在：

- 真实 crate 怎么进 build

### 完成标志

- 后续新增工作优先落在文档、依赖补充、构建接线设计
- 不再反复推翻 adapter 分层

## Phase 1：打通 host-side proc-macro 链

### 目标

先把这 3 个 proc-macro crate 的 Linux 构建模型定下来：

- `ax-crate-interface`
- `ax-percpu-macros`
- `axvisor_api_proc`

### 前置条件

当前已经完成：

- 3 个 proc-macro crate 的依赖识别
- Linux `rust/Makefile` 里现有 proc-macro 规则识别

### 本阶段要做的事

1. 明确 AxVisor 侧 proc-macro 目标产物命名方式
2. 明确它们各自的 `--extern` 依赖
3. 明确哪些 host-side 依赖还没 vendor 进来
4. 补齐最小新增 host-side 依赖链

当前至少已知要补：

- `proc-macro-crate`
- `cfg-if`

并准备承接它们继续拉出的依赖。

### 为什么必须先做

因为：

- `axvisor_api`
- `ax-percpu`

都建在这些 proc-macro crate 之上。

### 完成标志

- 能写出一份 AxVisor 侧 proc-macro 规则草案
- 明确每个 proc-macro crate 的输入、输出、依赖
- host-side 缺失依赖列表稳定下来

## Phase 2：打通 runtime 最小普通链

### 目标

先只追 runtime 所需的最小普通 crate 闭环，不碰更大范围。

### 本阶段要做的事

按依赖梯子，先处理：

- `ax-errno`
- `ax-cpumask`
- `ax-lazyinit`
- `ax-kernel-guard`
- `ax-kspin`
- `ax-timer-list`
- `ax-memory-addr`
- `ax-memory-set`
- `ax-page-table-entry`
- `ax-page-table-multiarch`
- `ax-percpu`
- `axaddrspace`
- `axvisor_api`

### 为什么只做到这里

因为这一层是：

- `axvisor_core::boot::run()` 之前必须拥有的最小普通链

但还没有把问题直接放大到完整 virtualization / config 链。

### 完成标志

- runtime 最小普通链的 crate 顺序稳定
- 每个 crate 的前置依赖已经明确
- 不再有“先接哪个 crate”这个层面的不确定性

## Phase 3：单独处理 virtualization 放大链

### 目标

识别并整理 `axvm` 往上的放大依赖，不急着全部接完。

### 本阶段关注对象

- `axvm`
- `axvcpu`
- `axdevice`
- `axdevice_base`
- `riscv_vcpu`
- `riscv_vplic`
- `riscv-h`

### 风险

这一层开始会明显扩大第三方依赖规模，包括：

- `log`
- `hashbrown`
- `byte-unit`
- `fdt-parser`

### 完成标志

- virtualization 主链的 crate 依赖图稳定
- 与 runtime 最小链之间的边界清楚

## Phase 4：单独处理 `axvisor_core/build.rs`

### 目标

明确 `axvisor_core/build.rs` 在 Linux 内核构建体系里的处理策略。

### 这是单独阶段的原因

因为它不是普通 `rlib` 接线问题，而是额外涉及：

- `AXVISOR_VM_CONFIGS`
- `vm_configs.rs` 生成
- TOML 解析
- `include_bytes!` guest image

### 本阶段要做的事

在策略上至少要三选一：

1. 保留 `build.rs` 语义并想办法接入 Kbuild/Rust-for-Linux
2. 把 `build.rs` 逻辑改写成 Linux 侧预生成流程
3. 先用静态/预生成产物替代 `build.rs`

### 完成标志

- `axvisor_core/build.rs` 的处理策略确定
- 不再存在“先把其他 crate 都接上再说”的模糊状态

## Phase 5：切 runtime 真实入口

### 目标

只切一个点：

- `vendor/axvisor_core/boot.rs`

从 fallback 切到真实：

- `axvisor_core::boot::run()`

### 为什么只切这个点

因为当前第一轮只追：

- runtime path

不追：

- timer 真接线
- external IRQ 真接线

### 完成标志

- runtime path 不再落到 `axvisor_core_stub::boot_run()`
- 而是落到真实 `axvisor_core::boot::run()`

## Phase 6：再验证 timer / IRQ 真路径

### 目标

在 runtime 真入口成功之后，再继续收后两条路径：

- `axvisor_core::vmm::timer::check_events()`
- `axvisor_core::arch::riscv64::inject_current_interrupt(irq_id)`

### 前提

只有 runtime 真入口已经证明“core 能进 Linux”之后，这一步才有意义。

### 当前还缺的关键点

external IRQ 路径上，还缺：

- 真实 `irq_id` 来源

### 完成标志

- timer path 不再落到 `axvisor_core_stub::timer_check_events()`
- irq path 不再落到 `axvisor_core_stub::inject_external_interrupt()`

## 5. 当前建议的实际推进顺序

按优先级排序，当前建议顺序如下：

1. 固定当前 adapter 主体结构
2. 补 `proc-macro` host-side 依赖链设计
3. 收敛 runtime 最小普通链
4. 确定 `axvisor_core/build.rs` 策略
5. 再动 runtime 真实入口切换
6. 最后才处理 timer / IRQ 真路径

## 6. 当前不建议做的事

现阶段不建议：

1. 继续花主要精力反复重构 adapter 层次
2. 在 `axvisor_core` 还不可见时急着调 timer / IRQ 真逻辑
3. 在 `build.rs` 策略没定前就宣称 runtime 已可接通
4. 把“接口还有没有少数未补强”误当成当前主阻塞

## 7. 如何判断我们是否在前进

后续推进时，最重要的不是看“又写了多少接口”，而是看下面几个问题有没有被逐个消掉：

1. `proc-macro` crate 能不能生成产物
2. `axvisor_api` 能不能进入 Linux Rust build
3. `ax-percpu` 能不能带着宏链走通
4. `axvisor_core/build.rs` 有没有明确策略
5. `vendor::axvisor_core::boot::run` 能不能切到真实 core

如果这 5 件事没有推进，再多接口细节优化都还不在关键路径上。
