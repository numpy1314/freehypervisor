# AxVisor Linux Core Layout

本文档用于设计 Linux 侧最小 `axvisor_core / axvisor_api` 接入目录布局。

这里讨论的不是最终完整 vendoring 形态，而是第一轮最小可见性与最小真实接线所需要的目录组织。

## 1. 设计目标

当前 Linux 侧已经有：

- `drivers/virt/axvisor/axvisor_adapter_main.rs`
- `drivers/virt/axvisor/arch/`
- `drivers/virt/axvisor/axvisor_core_stub.rs`

第一轮目录布局设计目标是：

- 不打乱当前 adapter 主体
- 不原样搬 Asterinas 的 `aster-axvisor-host`
- 先为三个 dispatcher 后面的真实 core 接线预留稳定落点
- 先解决最小可见性，再逐步扩展真实实现

## 2. 当前推荐布局

第一轮推荐先保持目录尽量小，只在 `drivers/virt/axvisor/` 下扩一层：

```text
drivers/virt/axvisor/
  Makefile
  Kconfig
  axvisor_adapter_main.rs
  axvisor_adapter_shim.c
  axvisor_core_stub.rs
  arch/
    mod.rs
    riscv64.rs
  core_link/
    mod.rs
    boot.rs
    boot_axvisor_core_entry.rs
    boot_vendor_bridge.rs
    timer.rs
    irq.rs
```

## 3. 各层职责

### 3.1 `axvisor_adapter_main.rs`

职责：

- 保持当前 Linux host adapter 主流程
- 保持 30 个接口和三类 dispatcher
- 不直接承载真实 `axvisor_core::*` 调用

也就是说：

- `runtime_core_entry_invoker`
- `timer_core_entry_invoker`
- `external_irq_core_entry_invoker`

这些仍然留在 adapter 主层，但它们返回的目标应该逐步转向 `core_link` 层，而不是长期停留在 stub 层。

### 3.2 `axvisor_core_stub.rs`

职责：

- 作为当前第一轮可编译占位层
- 在真实 `core_link` 还未接入前，提供三个最小入口：
  - `boot_run()`
  - `timer_check_events()`
  - `inject_external_interrupt()`

这个文件是“当前能运行的 stub 层”，不是未来长期结构中心。

### 3.3 `core_link/mod.rs`

职责：

- 成为 Linux 侧“真实 core 接线层”的入口
- 后续统一 re-export：
  - `boot`
  - `timer`
  - `irq`

建议它最终提供类似这样的调用面：

- `core_link::boot::boot_run`
- `core_link::timer::timer_check_events`
- `core_link::irq::inject_external_interrupt`

这样 adapter 主层以后只换引用目标，不改控制流程。

### 3.4 `core_link/boot.rs`

职责：

- 承接 `runtime_core_entry_invoker`
- 第一轮先解决：
  - `axvisor_core::boot::run()` 的最小可见性
- 后续再处理：
  - 进入前准备
  - 返回后收尾

建议它成为第一条真正落地的真实接线。

### 3.4.1 `core_link/boot_vendor_bridge.rs`

职责：

- 成为 runtime 这条线未来第一个真正导入 `axvisor_core` 的文件
- 隔离：
  - crate 可见性问题
  - vendor/import 细节
  - 真实 `axvisor_core::boot::run()` 调用点

当前形态：

- `boot.rs` 只保留流程包装
- `real_boot_run_bridge()` 只转发到 `boot_vendor_bridge::boot_run()`
- `boot_vendor_bridge::boot_run()` 背后也已经进一步经由：
  - `boot_vendor_bridge_entry()`
- 当前真正 fallback 位置在：
  - `boot_vendor_bridge_entry() -> fallback_boot_run()`
  - `fallback_boot_run() -> axvisor_core_stub::boot_run()`

这样后续如果要让 Linux 侧真正 `use axvisor_core`：

- 优先只改 `boot_vendor_bridge.rs`
- 更具体地说，优先替换 `boot_vendor_bridge_entry()` 返回的目标
- 不动 `boot.rs`
- 不动 `axvisor_adapter_main.rs`

### 3.4.2 `core_link/boot_axvisor_core_entry.rs`

职责：

- 成为 runtime 这条线最终 intended 的真实 `axvisor_core` 入口文件
- 后续最有可能在这里第一次写出：
  - `use axvisor_core::boot`
  - `boot::run()`

当前形态：

- 文件已存在
- 当前还没有进入 active path
- 但 `boot_vendor_bridge.rs` 已经显式知道这个未来目标位置
- 文件内部也已经进一步收口成单点：
  - `axvisor_core_boot_entry()`
  - 当前返回 `unavailable_axvisor_core_boot_entry()`

这意味着后续如果 `axvisor_core` 终于可见：

- 优先只改 `axvisor_core_boot_entry()` 返回的目标
- 而不是改 `boot_axvisor_core_entry::boot_run()` 外层流程

### 3.5 `core_link/timer.rs`

职责：

- 承接 `timer_core_entry_invoker`
- 后续接：
  - `axvisor_core::vmm::timer::check_events()`

建议在 `boot.rs` 打通后再推进。

当前形态：

- 文件已存在
- 当前已经形成：
  - `prepare_timer_check`
  - `invoke_timer_check_core`
  - `finalize_timer_check`
  - `timer_core_invoker`
  - `vendor_timer_bridge`
- 当前真正 fallback 位置在：
  - `vendor_timer_bridge -> axvisor_core_stub::timer_check_events`
- 当前最终 intended 真实目标位置在：
  - `vendor::axvisor_core::vmm::timer::check_events`

### 3.6 `core_link/irq.rs`

职责：

- 承接 `external_irq_core_entry_invoker`
- 后续接：
  - `axvisor_core::arch::riscv64::inject_current_interrupt(irq_id)`

这条线最后推进，因为它不仅依赖 crate 可见性，还依赖真实 `irq_id` 与当前 guest/vcpu 注入上下文。

当前形态：

- 文件已存在
- 当前已经形成：
  - `prepare_external_irq_inject`
  - `invoke_external_irq_core`
  - `finalize_external_irq_inject`
  - `external_irq_core_invoker`
  - `vendor_external_irq_bridge`
- 当前真正 fallback 位置在：
  - `vendor_external_irq_bridge -> axvisor_core_stub::inject_external_interrupt`
- 当前最终 intended 真实目标位置在：
  - `vendor::axvisor_core::arch::riscv64::inject_current_interrupt`

## 4. 为什么先加 `core_link/`，不直接让 adapter 调 `axvisor_core`

原因有三个：

### 4.1 降低主流程扰动

- `axvisor_adapter_main.rs` 现在已经比较大
- 如果真实接线逻辑直接堆在里面，后面很快会失控

### 4.2 隔离“构建问题”和“运行问题”

- `core_link/` 更适合承载：
  - crate 可见性过渡
  - vendor 过程中的临时 glue
  - 真正的 core 调用包装

### 4.3 便于分阶段替换

后续可以按下面顺序替换：

1. `axvisor_core_stub` -> `core_link::boot`
2. `axvisor_core_stub` -> `core_link::timer`
3. `axvisor_core_stub` -> `core_link::irq`

而不用一次性把所有真实接线全部改进主 adapter。

## 5. 第一轮最小演进路径

推荐按下面顺序推进：

### 第一步

先创建：

```text
drivers/virt/axvisor/core_link/
  mod.rs
  boot.rs
```

此时只处理 `boot`，不碰 `timer/irq`。

当前状态：

- 已创建：
  - `drivers/virt/axvisor/core_link/mod.rs`
  - `drivers/virt/axvisor/core_link/boot.rs`
  - `drivers/virt/axvisor/core_link/boot_axvisor_core_entry.rs`
  - `drivers/virt/axvisor/core_link/boot_vendor_bridge.rs`
  - `drivers/virt/axvisor/core_link/timer.rs`
  - `drivers/virt/axvisor/core_link/irq.rs`
  - `drivers/virt/axvisor/core_link/timer_vendor_bridge.rs`
  - `drivers/virt/axvisor/core_link/irq_vendor_bridge.rs`
- 当前 `core_link::boot::boot_run` 已经开始形成自己的包装层：
  - `prepare_boot_run`
  - `invoke_boot_run_core`
  - `finalize_boot_run`
- 当前 `invoke_boot_run_core` 背后也已经进一步经由：
  - `boot_core_invoker`
- 当前真正的 core 调用位置仍然在：
  - `boot_core_invoker -> real_boot_run_bridge`
  - `real_boot_run_bridge -> boot_vendor_bridge::boot_run`
  - `boot_vendor_bridge::boot_run -> boot_vendor_bridge_entry`
  - `boot_vendor_bridge_entry -> fallback_boot_run`
  - `fallback_boot_run -> axvisor_core_stub::boot_run`
- 当前最终 intended 真实目标位置在：
  - `boot_axvisor_core_entry::boot_run`
  - `boot_axvisor_core_entry::axvisor_core_boot_entry`
- 当前 timer 这条线也已经从 adapter 过渡到：
  - `core_link::timer::timer_check_events`
- 当前 irq 这条线也已经从 adapter 过渡到：
  - `core_link::irq::inject_external_interrupt`

### 第二步

让：

- `runtime_core_entry_invoker`

从：

- `axvisor_core_stub::boot_run`

过渡到：

- `core_link::boot::boot_run`

但 `core_link::boot::boot_run` 里面仍然可以先调用 stub。

当前状态：

- 这一过渡已经完成

### 第三步

在 `core_link::boot` 内部逐步解决：

- `axvisor_core / axvisor_api` 最小可见性
- 最终替换成真实 `axvisor_core::boot::run()`

当前状态：

- 外层包装已经存在
- `boot_core_invoker` 当前已经固定返回 `real_boot_run_bridge`
- 下一步只需要在 `boot_vendor_bridge.rs` 内部，把 `boot_vendor_bridge_entry()` 的返回目标从 fallback 切到 `boot_axvisor_core_entry::boot_run()`

### 第四步

再复制同样模式到：

- `core_link/timer.rs`
- `core_link/irq.rs`

## 6. 第一批不建议做的事

第一轮不建议：

- 直接把 `aster-axvisor-host` 原样搬进 Linux 内核树
- 一上来就把 `timer` 和 `irq` 一起做真实接线
- 在没有解决 crate 可见性前，继续让 stub 和 adapter 主流程深度耦合

## 7. 当前最推荐的下一步

最推荐的下一步是：

1. 新建 `drivers/virt/axvisor/core_link/`
2. 先只放 `mod.rs` 和 `boot.rs`
3. 让 `runtime_core_entry_invoker` 先改接 `core_link::boot::boot_run`

这样能以最小扰动，正式开始第一轮真实 core 接线。 
