# AxVisor Linux Host Missing Items

本文档用于收口当前 Linux 侧 AxVisor host adapter 之后，仍然缺失的真实接线内容。

它不是接口设计文档，而是后续推进时直接使用的缺失项清单。

## 1. 构建接入

- `axvisor_core` 还没有进入 Linux kernel Rust 构建体系
- `axvisor_api` 还没有进入 Linux kernel Rust 构建体系
- `axvisor_api_proc` / `ax-percpu-macros` / `ax-crate-interface` 这 3 个 proc-macro crate 还没有进入 Linux kernel Rust 构建体系
- 还没有确定采用哪种引入方式：
  - 最小 shim
  - 分阶段 vendor
  - 整包 vendor
- 还没有为它们补对应的 `Makefile/rust/Makefile` 构建规则

当前判断：

- Linux kernel Rust 不是不能接额外 crate
- 但 `axvisor_core / axvisor_api` 现在并不是内核树里现成可见的 crate
- 所以第一步不是改 adapter 调用点，而是解决 crate 可见性

补充：

- Linux 自带 `rust/Makefile` 只直接覆盖了：
  - `proc_macro2`
  - `quote`
  - `syn`
  - `macros`
  - `pin_init_internal`
- AxVisor 这边额外还需要处理：
  - `proc-macro-crate`
  - `cfg-if`
- 所以不能把当前问题简化成“把 `axvisor_core` 暴露出来”这么一步

## 2. 三个真实入口还没替换

### 2.1 `runtime_core_entry_invoker`

- 当前目标：
  - `core_link::boot::boot_run()`
- 当前 `core_link::boot::boot_run()` 内部最终会走到：
  - `real_boot_run_bridge()`
- 当前 `real_boot_run_bridge()` 当前转发到：
  - `core_link::boot_vendor_bridge::boot_run()`
- 当前 `core_link::boot_vendor_bridge::boot_run()` 背后还会走到：
  - `boot_vendor_bridge_entry()`
- 当前 `boot_vendor_bridge_entry()` 仍然返回：
  - `fallback_boot_run()`
- 当前 `fallback_boot_run()` 仍然转发到：
  - `axvisor_core_stub::boot_run()`
- 当前最终 intended 真实入口文件已经开始显式依赖：
  - `vendor::axvisor_core::boot::run()`
- 未来目标：
  - `axvisor_core::boot::run()`

### 2.2 `timer_core_entry_invoker`

- 当前目标：
  - `core_link::timer::timer_check_events()`
- 当前 `core_link::timer::timer_check_events()` 当前先走到：
  - `core_link::timer_vendor_bridge::timer_check_events()`
- 当前 `core_link::timer_vendor_bridge::timer_check_events()` 仍然返回：
  - `fallback_timer_check_events()`
- 当前 `fallback_timer_check_events()` 仍然转发到：
  - `axvisor_core_stub::timer_check_events()`
- 当前最接近真实目标的 vendor 路径已经存在：
  - `vendor::axvisor_core::vmm::timer::check_events()`
- 未来目标：
  - `axvisor_core::vmm::timer::check_events()`

### 2.3 `external_irq_core_entry_invoker`

- 当前目标：
  - `core_link::irq::inject_external_interrupt()`
- 当前 `core_link::irq::inject_external_interrupt()` 当前先走到：
  - `core_link::irq_vendor_bridge::inject_external_interrupt()`
- 当前 `core_link::irq_vendor_bridge::inject_external_interrupt()` 仍然返回：
  - `fallback_inject_external_interrupt()`
- 当前 `fallback_inject_external_interrupt()` 仍然转发到：
  - `axvisor_core_stub::inject_external_interrupt()`
- 当前最接近真实目标的 vendor 路径已经存在：
  - `vendor::axvisor_core::arch::riscv64::inject_current_interrupt()`
- 未来目标：
  - `axvisor_core::arch::riscv64::inject_current_interrupt(irq_id)`

## 3. 依赖裁剪还没完成

- 还没确认 `axvisor_core` 的最小依赖集
- 还没确认 `axvisor_api` 的最小依赖集
- 还没确认 3 个 proc-macro crate 的最小 host-side 依赖集
- 还没决定哪些 tgoskits / Asterinas 依赖必须一起带进来

当前已知潜在依赖包括：

- `ax-percpu`
- `ax-errno`
- `spin`
- 以及 `axvisor_core` 间接依赖的其他 crate

当前已经明确暴露出来、但还未整理接线策略的依赖包括：

- host-side proc-macro 链：
  - `proc-macro-crate`
  - `cfg-if`
  - 以及它们的传递依赖
- runtime / virtualization 链：
  - `log`
  - `hashbrown`
  - `byte-unit`
  - `fdt-parser`
- config / build 链：
  - `serde`
  - `serde_repr`
  - `toml`
  - `enumerable`
  - `anyhow`
  - `prettyplease`

额外现实：

- Asterinas 侧 `aster-axvisor-host` 并不只依赖 `axvisor_core / axvisor_api`
- 它还直接依赖：
  - `ostd`
  - `aster-console`
  - `aster-logger`
  - `aster-time`
- 所以 Linux 侧第一轮不适合直接原样搬 `aster-axvisor-host`

## 4. 运行语义还没验证

- 还没证明 `axvisor_core::boot::run()` 能在 Linux 线程上下文正常进入
- 还没证明 `axvisor_core::vmm::timer::check_events()` 能在当前 timer callback 语义下成立
- 还没证明 external IRQ 注入所需上下文在 Linux 宿主侧可达
- 还没验证 `axvisor_core` 对宿主接口的隐含假设是否都已满足

这里还有一个更前置的问题：

- `axvisor_core` 自带 `build.rs`
- `build.rs` 会生成 `vm_configs.rs`
- `build.rs` 会解析 `AXVISOR_VM_CONFIGS` 指向的 TOML 配置

因此在没有先回答“Linux 内核侧如何承接这个 `build.rs` 语义”之前：

- 运行语义还谈不上进入真实验证阶段

## 5. IRQ 真实信息还不够

- 当前 external IRQ event 里没有真实 `irq_id`
- 现在只有 adapter 级记录：
  - `vector`
  - `cpu_id`
  - `call_index`
- 后面要接 `inject_current_interrupt(irq_id)`，必须先补真实 pending irq id 来源

## 6. 验证闭环还没建立

- 还没验证“能链接 `axvisor_core`”
- 还没验证“3 个 proc-macro crate 能在 Linux Rust build 下生成可用产物”
- 还没验证“`proc-macro-crate` 这条 host-side 依赖链”能被 Linux kernel Rust 接住
- 还没验证“`boot::run()` 真能进入”
- 还没验证 timer 真能进 `check_events()`
- 还没验证 external IRQ 真能进 inject

## 7. 当前推荐顺序

### 第一步

解决 `axvisor_core / axvisor_api` 在 Linux kernel Rust 里的可见性

### 第二步

优先替换：

- `runtime_core_entry_invoker`

目标：

- 让 `axvisor_core_stub::boot_run()` 逐步过渡到真实 `axvisor_core::boot::run()`

### 第三步

再处理：

- `timer_core_entry_invoker`
- `external_irq_core_entry_invoker`

## 8. 当前推荐路线

当前更推荐：

1. 分阶段 vendor 路线
2. 以 `runtime_core_entry_invoker` 为第一目标
3. 先做最小可见性，再做真实运行接线

不推荐一上来就：

- 原样搬 `aster-axvisor-host`
- 一次性把整套 Asterinas 依赖直接塞进 Linux 内核树

## 9. 下一步可执行动作

下一步如果继续落地，建议直接做下面一项：

1. 先设计 Linux 侧 3 个 proc-macro crate 的构建草案
2. 明确 `proc-macro-crate` / `cfg-if` 是否需要先 vendor 进内核树
3. 再决定 `axvisor_core/build.rs` 是保留、改写，还是预生成
4. 最后才为 `runtime_core_entry_invoker` 打通最小可见性

补充：

- 第一批 crate 建议顺序已经单独整理在：
  - `docs/axvisor-linux-crate-staging.md`
- 当前建议的第一批名单：
  - `axvisor_core`
  - `axvisor_api`
  - `ax-percpu`
  - `ax-errno`
  - `spin`
