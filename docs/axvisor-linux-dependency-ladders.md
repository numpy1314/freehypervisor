# AxVisor Linux 依赖梯子

本文档把当前 Linux 侧 AxVisor 接入问题拆成两张“依赖梯子”：

- runtime 最小链
- config / build 放大链

目的不是罗列所有 crate，而是判断：

- 哪些可以先接
- 哪些一接就会把问题规模放大

## 1. runtime 最小链

如果我们只追求第一阶段：

- 让 `vendor::axvisor_core::boot::run`
  最终有机会接到真实 `axvisor_core::boot::run()`

那么最核心的运行链可以先理解成下面这样。

### 1.1 顶层入口

- `axvisor_core::boot::run`

它在源码里直接依赖的关键接口包括：

- `axvisor_api::host`
- `axvisor_api::task`
- `axvm::AxVMPerCpu`
- `crate::vmm`

从语义上看，它做的事情主要是：

1. 打印 logo
2. 检查硬件虚拟化支持
3. 为每个 CPU 拉起初始化任务
4. 在任务里调用：
   - `host::init_percpu()`
   - `vmm::init_timer_percpu()`
   - `AxVMPerCpu::init()`
   - `AxVMPerCpu::hardware_enable()`
5. 最后进入：
   - `vmm::init()`
   - `vmm::start()`

这说明：

- `boot::run()` 并不是一个“轻入口”
- 它一进来就会触发 task / percpu / timer / axvm 整条链

## 2. `axvisor_api` 这一层

`axvisor_api` 自身是 `#![no_std]`，但它并不轻。

它直接依赖：

- `axvisor_api_proc`
- `ax-errno`
- `axaddrspace`
- `ax-crate-interface`
- `ax-memory-addr`
- `ax-cpumask`

其中最关键的是：

- `axvisor_api_proc`
- `ax-crate-interface`

因为这两个决定了 API 定义/实现的宏展开机制。

结论：

- `axvisor_api` 必须建立在 proc-macro 闭环之后
- 它不是普通 `rlib` 随手后接的那种层

## 3. `ax-percpu` 这一层

`axvisor_core::boot::run()` 直接用了：

- `#[ax_percpu::def_percpu]`

所以 `ax-percpu` 不是可选项。

`ax-percpu` 当前依赖：

- `cfg-if`
- `ax-kernel-guard`（可选）
- `ax-percpu-macros`
- `spin`（`target_os != none` 时）

这件事非常关键，因为它说明：

- 只要我们想跑真实 `boot::run()`
- 就必须把 `ax-percpu` 和它背后的 proc-macro 一起接住

## 4. `axvm` 这一层

`axvisor_core::boot::run()` 还会直接落到：

- `axvm::AxVMPerCpu`

而 `axvm` 的依赖已经明显更重：

- `log`
- `cfg-if`
- `spin`
- `ax-errno`
- `ax-cpumask`
- `ax-kspin`
- `ax-memory-addr`
- `ax-page-table-entry`
- `ax-page-table-multiarch`
- `ax-percpu`
- `axvcpu`
- `axaddrspace`
- `axvisor_api`
- `axdevice`
- `axdevice_base`
- `axvmconfig`

RISC-V 下还会继续依赖：

- `riscv_vcpu`

这说明：

- `axvm` 是 runtime 最小链里的第一个“放大器”
- 一旦接它，就会把 `axaddrspace / axdevice / axvmconfig / riscv_vcpu` 全部带进来

## 5. `axaddrspace` 这一层

`axaddrspace` 的依赖也并不轻：

- `bit_field`
- `bitflags`
- `cfg-if`
- `ax-lazyinit`
- `log`
- `numeric-enum-macro`
- `ax-errno`
- `ax-memory-addr`
- `ax-memory-set`
- `ax-page-table-entry`
- `ax-page-table-multiarch`

这告诉我们一件事：

- 即使先不碰 `axvmconfig`
- 只要走到 `axvm`
- 普通 third-party crate 的数量也已经明显上升

## 6. config / build 放大链

真正会把复杂度再提升一个等级的，不是 `axaddrspace`，而是：

- `axvmconfig`
- `axvisor_core/build.rs`

### 6.1 `axvmconfig`

`axvmconfig` 依赖：

- `ax-errno`
- `enumerable`
- `log`
- `serde`
- `serde_repr`
- `toml`

默认 feature 还是：

- `std`

虽然 `axvm` 引它时用了：

- `default-features = false`

但这并不等于问题消失，因为它仍然保留了：

- `serde`
- `serde_repr`
- `toml`

这三条链本身就会继续放大依赖规模。

### 6.2 `axvisor_core/build.rs`

`axvisor_core` 的 `build.rs` 依赖：

- `prettyplease`
- `quote`
- `syn`
- `proc-macro2`
- `toml`
- `anyhow`

它的职责包括：

- 读取 `AXVISOR_VM_CONFIGS`
- 解析配置文件
- 生成 `OUT_DIR/vm_configs.rs`
- 在某些路径下 `include_bytes!` guest image

这说明：

- 就算普通 crate 都接好了
- 只要 `build.rs` 没策略，`axvisor_core` 也依然不能算“可接入”

## 7. 结论：现阶段最合理的切分

当前最合理的切分不是“30 个接口 vs 其余问题”，而是：

### 7.1 第一层：host-side proc-macro 链

先解决：

- `ax-crate-interface`
- `ax-percpu-macros`
- `axvisor_api_proc`

以及它们背后的：

- `cfg-if`
- `proc-macro-crate`

### 7.2 第二层：runtime 最小普通链

再解决：

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

### 7.3 第三层：virtualization 放大链

再往上是：

- `axvm`
- `axvcpu`
- `axdevice`
- `axdevice_base`
- `riscv_vcpu`
- `riscv_vplic`
- `riscv-h`

### 7.4 第四层：config / build 放大链

最后单独处理：

- `axvmconfig`
- `axvisor_core/build.rs`

当前判断：

- 真正最该优先拆的，是第一层和第四层
- 因为它们不是“多接几个 crate”就能自然解决的类型
