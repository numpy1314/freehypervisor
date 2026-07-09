# AxVisor Linux 构建推进记录（2026-06-15）

本文档只记录今天已经落地的构建侧收敛动作，不讨论运行结果。

## 最新状态更新

### 已推进到 `riscv_vcpu`

当前单模块构建已经先后打通了以下链路：

- `sbi-spec`
- `sbi-rt`
- `rustsbi`
- `riscv_vplic`
- `axdevice`

并继续推进到了：

- `riscv_vcpu`

### 在 `riscv_vcpu` 上暴露出的真实阻塞

当前宿主构建机为：

- `x86_64`

当前 Linux kernel out-of-tree 单模块构建也是按 `x86_64` 宿主环境在跑。

但 `riscv_vcpu` 已经不是普通 Rust 逻辑 crate，而是包含真正 RISC-V 虚拟化执行底座的 crate，里面直接包含：

- `global_asm!(include_str!("trap.S"))`
- `global_asm!(include_str!("mem_extable.S"))`
- `hfence.vvma`
- `hfence.gvma`
- `sret`
- `csrw/csrr` 到 hypervisor/guest CSRs

因此继续在 `x86_64` 宿主汇编器环境里强行编译时，已经出现了架构级错误，而不是普通依赖错误。

当前看到的代表性报错是：

- `error: <inline asm>:16:1: unknown directive`
- `.option push`

这说明：

- 现在失败的根因已经不是“三十个接口还没补齐”
- 也不是普通 vendored crate 兼容性
- 而是构建目标本身还不是一个真正的 `riscv64 Linux host kernel` 编译上下文

### 这意味着什么

这一步非常关键，说明我们已经把问题逼近到了真正的 hypervisor 执行底座：

1. adapter 层和大部分上游 Rust crate 的内核内构建兼容性已经推进了很长一段
2. 真正的下一层问题不再是“怎么包 30 个函数”
3. 而是“如何让 Linux 侧以 RISC-V hypervisor 目标架构来承载 `riscv_vcpu` 这套世界切换/VM-exit 代码”

### 当前结论

接下来要继续推进，有两个现实路径：

1. 切到真正的 `riscv64` Linux 内核构建目标

这条路径最符合最终目标。需要：

- RISC-V Linux 内核配置
- RISC-V 交叉工具链/clang target
- 让 `drivers/virt/axvisor` 在 `ARCH=riscv` 下构建

2. 在当前 `x86_64` 环境下继续做“只过语义接口、不编真实世界切换汇编”的桩化拆分

这条路径只能继续推进 adapter / trait / host glue 接线，
但无法证明 `riscv_vcpu` 真能在 Linux 上执行 guest。

所以如果目标是“最终在 Linux 上跑 AxVisor guest”，后续主线应切到路径 1。

## 已完成

### 1. 补齐了当前主链需要的 registry vendoring

已加入：

- `log`
- `arrayvec`
- `strum`
- `strum_macros`
- `heck`

说明：

- 其中 `strum / strum_macros / heck` 目前保留为备用链
- 当前主线已尽量避免把它们作为硬依赖

### 2. 收缩了 `ax-errno` 的构建复杂度

已修改：

- `linux-host-kernel/drivers/virt/axvisor/vendor/upstream/ax-errno/src/lib.rs`
- `linux-host-kernel/drivers/virt/axvisor/vendor/upstream/ax-errno/Cargo.toml`
- 新增 `linux-host-kernel/drivers/virt/axvisor/vendor/upstream/ax-errno/src/linux_errno.rs`

具体动作：

- 去掉 `strum::EnumCount`
- 去掉 `#[derive(EnumCount)]`
- 增加 `AxErrorKind::COUNT` 常量
- 把 `include!(concat!(env!(\"OUT_DIR\"), \"/linux_errno.rs\"))` 改成仓库内静态 `include!(\"linux_errno.rs\")`
- 删除 `ax-errno` 对 `strum` 的 Cargo 依赖

这一步的意义：

- 不再要求先打通 `build.rs -> OUT_DIR -> generated source`
- 不再要求 `ax-errno` 先依赖 `strum_macros` proc-macro 链
- `ax-errno` 现在退化为更普通的 `no_std rlib`

### 3. 扩展了 `drivers/virt/axvisor/Makefile` 的主链 artifact 声明

已补入：

- `liblog.rlib`
- `libarrayvec.rlib`
- `libax_errno.rlib`

并更新了：

- `axvisor_rust_proc_macro_rlibs`
- `axvisor_rust_runtime_base_rlibs`
- 对应 `always-*` / `targets`

### 4. 给主链加了最小依赖规则

已加入规则：

- `libbitflags.rlib`
- `liblog.rlib`
- `libarrayvec.rlib`
- `libspin.rlib`
- `libax_errno.rlib`
- `libaxaddrspace.rlib`
- `libax_percpu.rlib`
- `libaxvisor_api.rlib`
- `libaxvcpu.rlib`

并把：

- `libax_page_table_entry.rlib`
- `libax_page_table_multiarch.rlib`

的 `--extern` 补齐为：

- `bitflags`
- `ax_memory_addr`
- `arrayvec`
- `arrayvec`
- `log`
- `ax_memory_addr`
- `ax_page_table_entry`
- `riscv`

同时新增：

- `axaddrspace -> cfg_if + log + ax_errno + ax_lazyinit + ax_memory_addr + ax_memory_set + ax_page_table_entry + ax_page_table_multiarch`
- `ax-percpu -> cfg_if + spin + ax_percpu_macros`
- `axvisor_api -> axvisor_api_proc + ax_errno + axaddrspace + ax_crate_interface + ax_memory_addr + ax_cpumask`
- `axvcpu -> ax_errno + ax_memory_addr + ax_percpu + axaddrspace + axvisor_api + ax_kspin`

## RISC-V 路径裁剪结论

在当前 Linux + RISC-V 目标下，`axaddrspace` 的多架构源码虽然引用了：

- `bitflags`
- `bit_field`
- `numeric-enum-macro`

但目前真正进入主链的只有：

- `bitflags`

原因是：

- `bit_field`
- `numeric-enum-macro`

主要出现在 `x86_64` 路径

当前 `riscv` 路径主要使用：

- `cfg_if`
- `log`
- `ax_page_table_entry::riscv`
- `ax_page_table_multiarch::riscv`

因此这一轮只把 `bitflags` 提前接入，而没有同步接全平台依赖。

## `ax-percpu` 新结论

此前对 `ax-percpu` 的判断过于乐观。

现在已确认：

- 默认实现直接使用 `spin::once::Once`
- 因此 `spin` 不是可选背景依赖，而是当前 Linux 路径下的实际前置项

但这一轮仍然只是在“构建接线”层面纳入：

- 还没有验证 percpu section、寄存器初始化、`write_percpu_reg()` 等运行时语义

## `axvm / riscv_vcpu / riscv_vplic` 当前阻塞点

这一轮继续分析后，阻塞关系已经比较清楚：

### 1. `axvcpu`

已经可以先纳入接线层。

它当前主要依赖：

- `ax_errno`
- `ax_memory_addr`
- `ax_percpu`
- `axaddrspace`
- `axvisor_api`
- `ax_kspin`

### 2. `riscv_vplic`

暂时不能直接轻量接入，原因不是 `bitmaps` 本身，而是它还依赖：

- `axdevice_base`

而 `axdevice_base` 又直接依赖：

- `axvmconfig`
- `serde` derive
- 多个 nightly feature

所以 `riscv_vplic` 实际会被配置链卡住。

### 3. `axvm`

`axvm` 不是单纯的 VM 容器层，它会继续拉起：

- `axdevice`
- `axdevice_base`
- `axvmconfig`
- `riscv_vcpu`

因此目前也不能单独轻量推进。

### 4. `riscv_vcpu`

`riscv_vcpu` 还会额外引入：

- `bit_field`
- `bitflags`
- `riscv-decode`
- `rustsbi`
- `sbi-rt`
- `sbi-spec`
- `tock-registers`
- `memoffset`

以及更强的架构/feature 前提：

- `#![feature(riscv_ext_intrinsics)]`

所以它比 `axvcpu` 明显更靠后。

## 当前策略修正

因此当前更合理的推进顺序变为：

1. 先把 `axvcpu` 纳入主链
2. 再拆 `axvmconfig` / `serde` / `toml` 配置链
3. 配置链打通后，再推进 `axdevice_base -> axdevice -> riscv_vplic -> axvm`
4. 最后再处理 `riscv_vcpu`

## `axvmconfig` 瘦身进展

这一轮已经对 `axvmconfig` 做了第一步“内核侧瘦身”：

- 去掉了 `enumerable` 依赖
- `[[bin]] axvmconfig` 现在要求 `std` feature
- `toml` 改成了可选依赖，只在 `std` feature 下打开
- `AxVMCrateConfig::from_toml()` 改成仅在 `std + unix/windows` 下提供
- `test` 模块也收到了 `std + unix/windows`

这一步的含义是：

- `axvmconfig` 作为“配置类型定义 crate”可以更接近 no_std 主链
- 但它仍然保留了原有的 CLI / TOML 解析接口，只是被明确隔离到 `std` 侧

## 本轮继续推进：device/vplic 链接线

这一轮继续把配置链后面的 RISC-V device 路径接入 Makefile，但仍然没有执行编译。

### 1. 新增接入的 registry crate

已加入 `drivers/virt/axvisor/Makefile` 的 side artifacts：

- `libbare_metal.rlib`
- `libbit_field.rlib`
- `libbitmaps.rlib`
- `libriscv.rlib`

其中 `libriscv.rlib` 需要注意：

- `riscv 0.6.0` 原本依赖 `build.rs` 注入 `riscv/riscv64` cfg
- Linux Kbuild 直调 rustc 不会自动运行该 `build.rs`
- 因此当前规则显式加入了 `--cfg riscv --cfg riscv64`

### 2. `bare-metal` 兼容修补

当前 vendor 中的 `bare-metal` 是 `1.0.0`，但 `riscv 0.6.0` 仍然会 re-export：

- `CriticalSection`
- `Mutex`
- `Nr`

`bare-metal 1.0.0` 已没有 `Nr`，所以本轮在 vendored `bare-metal/src/lib.rs` 中补了一个最小兼容 trait：

- `pub unsafe trait Nr { fn nr(&self) -> u8; }`

这是构建兼容层，不改变运行时语义。

### 3. 新增接入的 upstream crate

已加入 Makefile artifact 和 rustc 规则：

- `libaxvmconfig.rlib`
- `libaxdevice_base.rlib`
- `libriscv_h.rlib`
- `libriscv_vplic.rlib`
- `libaxdevice.rlib`

目前形成的顺序是：

1. `axvmconfig`
2. `axdevice_base`
3. `riscv_h`
4. `riscv_vplic`
5. `axdevice`

这表示我们已经把 `axvm` 之前的设备抽象链往前推进了一层。

### 4. 当前仍未验证的风险

因为本阶段没有编译，所以以下问题只是静态判断出的潜在风险：

- `bitflags 2.x` 是否完全兼容 `riscv 0.6.0` 的旧宏用法，仍需首次编译确认
- `axdevice` 的 `target_arch = "riscv64"` cfg 依赖最终 Linux kernel Rust 目标是否正确设置
- `axdevice_base` 使用 nightly feature，是否被当前 Linux Rust 构建参数接受仍需确认
- `riscv_h` 和后续 `riscv_vcpu` 的 CSR/汇编路径还没有进入最终运行验证

下一步应继续推进：

1. 接 `riscv_vcpu` 的依赖链
2. 接 `axvm`
3. 接 `axvisor_core`
4. 最后再把这些 crate artifact 和当前三十个 host adapter 接到同一个 Linux module 入口里

## 本轮继续推进：接到 `axvisor_core`

这一轮继续把主链从 `axvm` 推到了 `axvisor_core`，但仍然没有执行编译。

### 1. 新增接入的 crate

已加入 Makefile artifact/规则：

- `libriscv_decode.rlib`
- `libsbi_spec.rlib`
- `libsbi_rt.rlib`
- `libtock_registers.rlib`
- `libmemoffset.rlib`
- `librustsbi_macros.so`
- `librustsbi.rlib`
- `libriscv_vcpu.rlib`
- `libaxvm.rlib`
- `libaxhvc.rlib`
- `libfdt_parser.rlib`
- `libaxvisor_core.rlib`

这意味着从 crate 依赖图角度，当前已经把：

1. `axvcpu`
2. `axvmconfig`
3. `axdevice_base`
4. `riscv_h`
5. `riscv_vplic`
6. `axdevice`
7. `riscv_vcpu`
8. `axvm`
9. `axvisor_core`

按顺序接到了 Linux adapter 的 Makefile 里。

### 2. `riscv_vcpu` 路径上做的兼容处理

为了让 `riscv_vcpu` 能先进入 Linux Kbuild 主链，这一轮做了两类兼容：

- `memoffset` 规则中手工补了它原本 `build.rs` 会生成的 cfg：
  - `tuple_ty`
  - `allow_clippy`
  - `maybe_uninit`
  - `raw_ref_macros`
  - `stable_const`
  - `stable_offset_of`
- `rustsbi` 的 derive proc-macro `rustsbi-macros` 也已独立接入

这一步仍然只是“构建接线”，不是行为验证。

### 3. `axvisor_core` 上做的裁剪

`axvisor_core` 原本有两个不适合 Linux Kbuild 直连的点：

#### `byte-unit`

原来只用于打印一条镜像装载日志：

- `Byte::from(self.main_memory.size())`

为避免引入：

- `rust_decimal`
- `utf8-width`

这条额外依赖链，本轮把它改成了：

- 直接打印 `size={} bytes`

并从 `Cargo.toml` 删除了 `byte-unit` 依赖。

#### `OUT_DIR/vm_configs.rs`

原来 `axvisor_core/build.rs` 会生成：

- `static_vm_configs()`
- `get_memory_images()`

但 Linux Kbuild 不会自动跑 Cargo build.rs，所以本轮改成：

- 新增 `src/vm_configs_static.rs`
- `src/vmm/config.rs` 从 `include!(concat!(env!("OUT_DIR"), "/vm_configs.rs"))`
  改成 `include!("../vm_configs_static.rs")`

当前静态行为是：

- `static_vm_configs()` 返回默认空配置
- `get_memory_images()` 返回空切片

也就是说：

- 现在优先保证 crate 主链能被接入
- 后续再把 `AXVISOR_VM_CONFIGS` 的 build-time 注入能力，或者 Linux 侧等价机制补回来

### 4. 当前离“Linux 上真正跑 AxVisor”还差的东西

到这一轮为止，已经不只是“三十个函数接口”问题了，剩余工作大致分成四类：

1. 首次真实编译后暴露出的版本/feature/宏兼容错误还没有清扫
2. `axvisor_core` 虽然接进来了，但还没有和 Linux adapter 主入口真正合并成可加载模块
3. 三十个 host adapter 函数虽然已有骨架，但还没有逐个完成运行时语义闭合
4. 最关键的 RISC-V H 扩展执行链路仍未进入 Linux 上的真实运行验证

所以当前状态可以定义为：

- crate 依赖主链已经基本串到 `axvisor_core`
- 但还没有进入“可编译、可加载、可 world-switch”的阶段

还没解决的部分：

- `serde`
- `serde_derive`
- `serde_repr`
- `axdevice_base` 里的 derive 依赖

也就是说，`axvmconfig` 已经从“配置类型 + CLI + TOML 工具”被切成了两层，但配置类型本身仍然在使用 `serde` 派生。

## `serde` 影响面进一步收缩

这一轮又继续往前收了一步：

### 1. `axvmconfig`

现在 `axvmconfig` 中绝大多数 `serde`/`serde_repr` 派生与字段属性都已经被包进：

- `all(feature = "std", any(windows, unix))`

也就是说：

- no_std 主链仍保留这些类型定义
- 但不再默认要求这些类型在 no_std 路径上拥有序列化能力

### 2. `axdevice_base`

`axdevice_base` 已经去掉了：

- `serde` 依赖
- `EmulatedDeviceConfig` 上的 `Serialize/Deserialize` 派生

这很重要，因为它意味着：

- `riscv_vplic -> axdevice_base`

这条链不再因为 `axdevice_base` 自己额外强拉一层 `serde`

## 现在剩下的核心问题

虽然 no_std 主链上的 `serde` 影响面已经明显变小，但还没有完全消失。

当前剩下的关键点是：

- `axvmconfig` 的 `std` 配置工具路径仍然需要 `serde`
- 如果我们想真正把 `axvmconfig` 纳入当前 no_std 主链构建，还需要决定：
  - 是先在 `Makefile` 里以“关闭 std 的最小模式”接入它
  - 还是继续保留它只在后续配置链阶段接入

## 当前效果

截至现在，主链复杂度已经从：

- `ax-page-table-multiarch -> log + arrayvec`
- `ax-errno -> log + strum derive + build.rs`

收缩为：

- `ax-page-table-multiarch -> log + arrayvec`
- `ax-errno -> log`

也就是说：

- `ax-errno` 这条链已经明显变短
- 下一步可以更专注地继续往 `axaddrspace` / `axvisor_api` / `axvm` 方向推

## 还没做

- 还没跑编译验证
- 还没接 `axaddrspace`
- 还没处理 `bitflags / bit_field / numeric-enum-macro`
- 还没把 `vendor/axvisor_core/boot.rs` 切到真实 `axvisor_core::boot::run()`
- 还没处理 `axvisor_core/build.rs`

## 下一步建议

优先级建议如下：

1. 继续把 `axaddrspace` 的最小依赖链拆平
2. 再推进 `axvisor_api`
3. 然后处理 `axvcpu / axvm / riscv_vcpu / riscv_vplic`
4. 最后再切真实 boot 入口
