# AxVisor Linux 构建接线清单

本文档用于把“下一步真正怎么接构建”收敛成可执行清单。

这里仍然不直接修改：

- `linux-host-kernel/rust/Makefile`
- `linux-host-kernel/drivers/virt/axvisor/Makefile`

但会把第一轮需要的 crate 产物、模块端 `--extern` 最小集合、后置项，明确列清楚。

## 1. 当前目标

第一轮构建接线只追求一件事：

- 让 `vendor::axvisor_core::boot::run`
  背后有机会接到真实 `axvisor_core::boot::run()`

也就是说，只服务：

- runtime 路径

暂时不追求：

- timer 真接线
- external IRQ 真接线
- 一次性把所有架构分支都构建起来

## 2. 两层接线对象

### 2.1 crate 产物层

需要先能生成一批 Rust crate 产物，也就是概念上的：

- `*.rlib`
- proc-macro crate 对应的动态库产物

### 2.2 模块消费层

需要让：

- `axvisor_adapter_main.rs`

编译时拿到最小必要 `--extern`

并通过现有路径：

- `axvisor_adapter_main.rs`
- `core_link/boot*.rs`
- `vendor/axvisor_core/boot.rs`

走到真实入口。

## 3. 第一轮最小构建闭环

从当前源码落位情况看，第一轮最小闭环不应再理解成“5 个 crate”，而应理解成：

- 一组最小 runtime 主链 crate

### 3.1 第一轮必须进产物层的 crate

#### 核心入口

- `axvisor_core`
- `axvisor_api`
- `axvisor_api_proc`

#### 通用基础

- `ax-errno`
- `ax-cpumask`
- `ax-crate-interface`
- `ax-lazyinit`
- `ax-kernel-guard`
- `ax-kspin`
- `ax-timer-list`
- `ax-memory-addr`
- `ax-memory-set`
- `ax-page-table-entry`
- `ax-page-table-multiarch`
- `ax-percpu`
- `ax-percpu-macros`
- `axaddrspace`

#### 虚拟化主链

- `axhvc`
- `axvcpu`
- `axvm`
- `axdevice`
- `axdevice_base`
- `axvmconfig`
- `riscv_vplic`
- `riscv_vcpu`
- `riscv-h`

#### registry 侧 RISC-V / SBI 基础

- `riscv`
- `sbi-spec`
- `sbi-rt`
- `rustsbi`
- `riscv-decode`

### 3.2 第一轮可以暂时后置的 crate

这些当前已经暴露出来，但不必在第一轮 runtime 入口接线时同时处理：

- `arm_vgic`
- `x86_vlapic`
- `arm_vcpu`
- `x86_vcpu`
- `loongarch_vcpu`

原因：

- 它们是架构/平台分支扩展
- 当前我们先只盯 Linux + RISC-V runtime 路径

## 4. 模块端最小 `--extern` 集合

从模块消费层看，第一轮不需要让 `axvisor_adapter_main.rs` 直接 `use` 所有 crate。

第一轮最小消费目标应该是：

- 让 `vendor/axvisor_core/boot.rs` 能看到真实 `axvisor_core`

因此模块端最小 `--extern` 集合建议先分两档。

### 4.1 档 A：显式必须

- `axvisor_core`

### 4.2 档 B：会被 `axvisor_core` 继续拉到的必要传递依赖

这些不一定在 `axvisor_adapter_main.rs` 里直接 `use`，但产物层必须可见：

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
- `ax-memory-set`
- `ax-page-table-entry`
- `ax-page-table-multiarch`
- `ax-percpu`
- `ax-percpu-macros`
- `axaddrspace`
- `axhvc`
- `axvcpu`
- `axvm`
- `axdevice`
- `axdevice_base`
- `axvmconfig`
- `riscv_vplic`
- `riscv_vcpu`
- `riscv-h`
- `riscv`
- `sbi-spec`
- `sbi-rt`
- `rustsbi`
- `riscv-decode`

## 5. 第一轮真正的切换点

第一轮构建接线完成后，不应该同时改很多调用点。

应该只切一个点：

- `vendor/axvisor_core/boot.rs`

更具体地说，是把：

- `vendor_axvisor_core_boot_entry()`

从 fallback 切到真实 `axvisor_core::boot::run`

外层这些都应尽量不动：

- `axvisor_adapter_main.rs`
- `core_link/boot.rs`
- `core_link/boot_vendor_bridge.rs`

## 6. 后续建议的实际顺序

### 第 1 步

先给 proc-macro 相关 crate 建立构建方案：

- `axvisor_api_proc`
- `ax-percpu-macros`
- `ax-crate-interface`

这是因为：

- 它们不是普通 `rlib`
- 是后续很多 crate 的前置条件

### 第 1.1 步

把这 3 个 proc-macro crate 的差异单独识别清楚：

- `ax-crate-interface`
- `ax-percpu-macros`
- `axvisor_api_proc`

它们都属于 host-side `proc-macro` crate，但依赖并不完全相同。

`ax-crate-interface` 依赖：

- `proc-macro2`
- `quote`
- `syn`

`ax-percpu-macros` 依赖：

- `cfg-if`
- `proc-macro2`
- `quote`
- `syn`

`axvisor_api_proc` 依赖：

- `proc-macro2`
- `proc-macro-crate`
- `quote`
- `syn`

这里最关键的差异是：

- `axvisor_api_proc` 比另外两个多了一条 `proc-macro-crate` 依赖链

并且它在源码中实际用到了：

- `proc_macro_crate::crate_name`
- `proc_macro_crate::FoundCrate`

所以它不能只复用 Linux 当前已有的：

- `proc_macro2`
- `quote`
- `syn`

这一套规则，还必须补 `proc-macro-crate` 及其传递依赖。

### 第 1.2 步

对照 Linux 当前已有的 proc-macro 能力，确认可复用边界。

从 `linux-host-kernel/rust/Makefile` 已经可以确认，Linux 自带了：

- `libproc_macro2.rlib`
- `libquote.rlib`
- `libsyn.rlib`
- `libmacros.<ext>`
- `libpin_init_internal.<ext>`

以及两类成熟规则：

- `rustc_procmacrolibrary`
- `rustc_procmacro`

这说明：

- 我们不需要重新发明 proc-macro 的构建模型
- 但需要在 AxVisor 侧复制一套“同语义规则”
- 同时补上 Linux 当前没有的 host-side 依赖链

### 第 1.3 步

当前已明确但尚未进入 `vendor/` 的 host-side 依赖至少包括：

- `proc-macro-crate`
- `cfg-if`

而 `proc-macro-crate` 往下还会继续带出一串依赖，当前至少要预留：

- `toml_edit`
- `indexmap`
- `equivalent`
- `hashbrown`
- `winnow`
- `memchr`

结论：

- 第 1 步的实质不是“把 3 个 crate 列出来”
- 而是先打通一条 Linux 当前没有现成支持的 host-side 依赖链

### 第 2 步

再接通最基础 `rlib`：

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

### 第 3 步

再接：

- `ax-percpu`
- `axaddrspace`
- `axvisor_api`

这里要补一个约束：

- `axvisor_api` 不是普通 `rlib` 直接可接入
- 它依赖前面已经编出的：
  - `axvisor_api_proc`
  - `ax-crate-interface`

所以它必须放在 proc-macro 闭环之后。

### 第 4 步

再接虚拟化主链：

- `axhvc`
- `axvcpu`
- `axvm`
- `axdevice`
- `axdevice_base`
- `axvmconfig`
- `riscv_vplic`
- `riscv_vcpu`
- `riscv-h`

这一层还会继续引出更多普通依赖，至少包括：

- `spin`
- `log`
- `hashbrown`
- `byte-unit`
- `fdt-parser`

以及配置相关链路里已经暴露出来的：

- `serde`
- `serde_repr`
- `toml`
- `enumerable`

所以第 4 步开始，问题不再只是 crate 顺序，而是依赖规模会明显放大。

### 第 5 步

最后接：

- `axvisor_core`

这里必须明确一个现实：

- `axvisor_core` 自带 `build.rs`

它的 `build.rs` 依赖：

- `prettyplease`
- `quote`
- `syn`
- `proc-macro2`
- `toml`
- `anyhow`

并且职责不是可忽略的装饰性代码，而是会：

- 读取 `AXVISOR_VM_CONFIGS`
- 解析 TOML 配置
- 生成 `OUT_DIR/vm_configs.rs`
- 在某些路径下把 guest image 通过 `include_bytes!` 纳入构建

所以第 5 步不是“普通 rlib 最后编一下”这么简单，而是要回答：

- Linux kernel Rust / Kbuild 里怎么处理这个 `build.rs`

然后只改 runtime 的真实入口切换点。

## 7. 为什么先接 proc-macro

因为当前已落位源码里，有几类 crate 如果不先处理，后面普通 `rlib` 会被卡住：

- `axvisor_api_proc`
- `ax-percpu-macros`
- `ax-crate-interface`

它们在 Linux `rust/Makefile` 语义里，更接近现有：

- `macros`
- `pin_init_internal`

但还必须补充一点：

- `axvisor_api_proc` 不是 Linux 当前现成规则可以直接覆盖的那个档位
- 因为它额外引入了 `proc-macro-crate`

所以当前最真实的阻塞顺序应理解为：

1. host-side proc-macro 依赖链
2. `axvisor_core` 的 `build.rs` 语义
3. 普通 `rlib` 的接线与排序

这意味着第一轮构建接线设计里，proc-macro crate 其实应该优先，而不是最后补。

## 8. 当前最重要的结论

下一步不应该再做大规模源码搬运。

下一步应该开始围绕两件事落地：

1. 设计 proc-macro crate 的 Linux 构建规则
2. 设计普通 runtime 主链 crate 的 `.rlib` 产物顺序
