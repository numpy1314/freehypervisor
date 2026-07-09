# AxVisor Linux Proc-Macro 阶段文件级待办

本文档只服务执行路线图里的两个阶段：

- `Phase 1`：host-side `proc-macro` 链
- `Phase 2` 前半段：先把这条链和后续普通 crate 链的文件级落点定下来

目标是明确：

- 要补哪些目录
- 要动哪些文件
- 每一步的产出是什么

## 1. 当前文件状态

### 1.1 已存在的 proc-macro 相关 upstream crate

当前已经在：

- `linux-host-kernel/drivers/virt/axvisor/vendor/upstream/`

中的目录有：

- `ax-crate-interface/`
- `ax-percpu-macros/`
- `axvisor_api_proc/`

### 1.2 当前缺失的 host-side 依赖目录

当前 `vendor/` 里还没有下面两个关键目录：

- `cfg-if/`
- `proc-macro-crate/`

这意味着：

- 仅靠现有 staged source，还不够支撑 `ax-percpu-macros` 与 `axvisor_api_proc`

### 1.3 当前构建文件状态

当前和 AxVisor 侧最直接相关的构建文件只有：

- `linux-host-kernel/drivers/virt/axvisor/Makefile`
- `linux-host-kernel/rust/Makefile`

其中：

- `drivers/virt/axvisor/Makefile`
  目前只负责编 `axvisor_adapter.o`
- 还没有任何 AxVisor crate 产物规则

## 2. 第一步：补目录，不动规则

### 2.1 需要补进 `vendor/registry/` 或等价位置的目录

最小新增目录清单：

- `linux-host-kernel/drivers/virt/axvisor/vendor/registry/cfg-if/`
- `linux-host-kernel/drivers/virt/axvisor/vendor/registry/proc-macro-crate/`

说明：

- `cfg-if` 不只是 proc-macro 阶段要用，后面普通 crate 也会频繁用到
- `proc-macro-crate` 当前先只为 `axvisor_api_proc` 服务

### 2.2 目录补入后必须立即做的核查

每补一个 crate，至少检查：

- `Cargo.toml`
- `src/lib.rs`
- 是否有 `build.rs`
- 是否有默认 feature 假设
- 是否继续拉出新的传递依赖

### 2.3 本步产出

产出应该是：

- 一份稳定的 host-side 新增依赖目录清单

而不是：

- 一边补目录一边立刻乱改 `Makefile`

## 3. 第二步：把 3 个 proc-macro crate 拆成单独规则对象

### 3.1 对象 1：`ax-crate-interface`

源目录：

- `linux-host-kernel/drivers/virt/axvisor/vendor/upstream/ax-crate-interface/`

最关键文件：

- `Cargo.toml`
- `src/lib.rs`

当前依赖：

- `proc-macro2`
- `quote`
- `syn`

文件级任务：

1. 记下 crate name
2. 记下源码入口
3. 记下最终应生成的 proc-macro 动态库名
4. 写出它需要的 `--extern` 列表

### 3.2 对象 2：`ax-percpu-macros`

源目录：

- `linux-host-kernel/drivers/virt/axvisor/vendor/upstream/ax-percpu-macros/`

最关键文件：

- `Cargo.toml`
- `src/lib.rs`

当前依赖：

- `cfg-if`
- `proc-macro2`
- `quote`
- `syn`

文件级任务：

1. 明确 `cfg-if` 是 host-side 普通 `rlib` 还是仅作为依赖转发
2. 明确 `ax-percpu-macros` 的 feature 是否需要在 Linux 侧预设
3. 写出它的 `--extern` 列表

### 3.3 对象 3：`axvisor_api_proc`

源目录：

- `linux-host-kernel/drivers/virt/axvisor/vendor/upstream/axvisor_api_proc/`

最关键文件：

- `Cargo.toml`
- `src/lib.rs`

当前依赖：

- `proc-macro2`
- `proc-macro-crate`
- `quote`
- `syn`

文件级任务：

1. 确认 `proc-macro-crate` 的完整依赖树
2. 明确 `crate_name()/FoundCrate` 这类逻辑是否对 Linux build 路径有额外要求
3. 写出它的 `--extern` 列表

## 4. 第三步：对照 Linux `rust/Makefile` 抽规则模板

### 4.1 参考文件

核心参考文件：

- `linux-host-kernel/rust/Makefile`

当前最重要的参考段落是：

- `libproc_macro2.rlib`
- `libquote.rlib`
- `libsyn.rlib`
- `rustc_procmacrolibrary`
- `rustc_procmacro`

### 4.2 本步不直接改哪里

本步先不直接改：

- `linux-host-kernel/rust/Makefile`

原因：

- 现在还处在规则抽取阶段
- 先把 AxVisor 侧规则 draft 写清楚，再决定是放进 `drivers/virt/axvisor/Makefile` 还是进一步下沉

### 4.3 本步应形成什么产出

应该形成一份明确对照：

- Linux 现有哪条规则可以直接照搬
- 哪条规则只能部分复用
- 哪些新增 crate 需要补新规则

## 5. 第四步：给 `drivers/virt/axvisor/Makefile` 规划新增责任

### 5.1 当前状态

当前文件：

- `linux-host-kernel/drivers/virt/axvisor/Makefile`

只做了：

- `axvisor_adapter_main.o`
- `axvisor_adapter_shim.o`

### 5.2 后续它至少要承接什么

它后续至少要能表达两类东西：

1. AxVisor adapter module 自己的对象编译
2. AxVisor 额外 Rust crate 产物的依赖关系

### 5.3 当前阶段不做的事

当前阶段先不直接把所有 crate 规则都写进去。

先做的是：

- 列出这个文件未来要承接哪些产物名
- 列出 adapter module 最终要依赖哪些 crate 产物

### 5.4 本步产出

一份 `drivers/virt/axvisor/Makefile` 责任草案：

- 哪些产物归它管
- 哪些产物仍然引用 `rust/Makefile` 的公共能力

## 6. 第五步：为 runtime 最小链准备 crate 名单

这一步还不直接接普通 crate，只做“名单冻结”。

### 6.1 先冻结第一批普通 crate

按 runtime 最小链，优先冻结：

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

### 6.2 文件级动作

对每个 crate，至少读取：

- `Cargo.toml`
- 必要时的 `src/lib.rs`

并记录：

- crate 名称
- feature
- 直接依赖
- 是否依赖 proc-macro crate

### 6.3 本步产出

一张稳定的普通 crate 顺序表。

## 7. 当前阶段的“不要做”

在这个阶段，不要直接做下面这些事：

1. 不要先编 `vmlinux`
2. 不要先切 `axvisor_core::boot::run()`
3. 不要先碰 timer 真路径
4. 不要先碰 external IRQ 真注入路径
5. 不要在 `build.rs` 策略没定之前宣称 runtime 可打通

## 8. 本阶段结束时应看到什么

这一阶段结束时，最理想的状态应该是：

1. `vendor/` 下缺失的 host-side 依赖目录名单稳定
2. 3 个 proc-macro crate 的规则草案稳定
3. `drivers/virt/axvisor/Makefile` 的未来责任边界清楚
4. runtime 最小普通链名单稳定

只要这 4 件事还没稳定，就还没到“动真实 runtime 入口”的时机。
