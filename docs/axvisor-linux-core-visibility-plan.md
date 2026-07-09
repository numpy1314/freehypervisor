# AxVisor Linux Core Visibility Plan

本文档专门讨论：

- `axvisor_core`
- `axvisor_api`

如何进入 Linux kernel Rust 的可见域。

这里不讨论 30 个接口本身，也不讨论最终运行结果，只讨论“第一轮如何让代码看见 crate”。

## 1. 当前现状

Linux 侧当前已经有一条完整但仍然是占位的 runtime 接线链：

```text
runtime_core_entry_invoker
  -> core_link::boot::boot_run
  -> boot_core_invoker
  -> real_boot_run_bridge
  -> boot_vendor_bridge::boot_run
  -> boot_vendor_bridge_entry
  -> boot_axvisor_core_entry::boot_run
  -> axvisor_core_boot_entry
```

其中真正未来要替换成：

- `axvisor_core::boot::run()`

的最小单点，已经被压缩到：

- `boot_axvisor_core_entry::axvisor_core_boot_entry()`

所以当前问题已经非常集中：

- 不是 adapter 不知道该调哪里
- 而是 `boot_axvisor_core_entry.rs` 还看不到 `axvisor_core`

## 2. 第一轮可见性目标

第一轮不追求：

- 全量真实运行
- 一次性把 timer / irq 也接上
- 把整个 Asterinas host 组件搬过来

第一轮只追求一件事：

- 让 `boot_axvisor_core_entry.rs` 能在语法和构建层面看到一个最小 `axvisor_core`

也就是说，第一轮成功标准应该是：

- 能把 `axvisor_core_boot_entry()` 的返回目标，从
  - `unavailable_axvisor_core_boot_entry`
  替换成
  - 一个真实可见的 `axvisor_core` boot 入口包装

## 3. 推荐最小目录布局

第一轮推荐新增一层“可见性/导入过渡层”，但不要把它和 adapter 主流程混在一起。

推荐形态：

```text
drivers/virt/axvisor/
  axvisor_adapter_main.rs
  axvisor_core_stub.rs
  core_link/
    mod.rs
    boot.rs
    boot_vendor_bridge.rs
    boot_axvisor_core_entry.rs
  vendor/
    mod.rs
    axvisor_core/
      mod.rs
    axvisor_api/
      mod.rs
```

这里的 `vendor/` 不代表已经把真实 crate 搬进来了。

它的第一轮职责只是：

- 给未来真实 vendoring 留稳定目录
- 让“可见性问题”有固定落点
- 不把导入逻辑散落在 `core_link/` 或 adapter 主文件里

## 4. 推荐职责划分

### 4.1 `core_link/*`

职责：

- 保持调用流程
- 保持 bridge/disptacher 结构
- 不直接承载大规模 vendoring 细节

### 4.2 `vendor/axvisor_core/*`

职责：

- 承载未来 `axvisor_core` 在 Linux 内核树中的最小导入落点
- 后续无论是：
  - 真实 vendor 进来的源码
  - 本地 shim
  - 手工再包装一层
  都优先收口在这里

### 4.3 `vendor/axvisor_api/*`

职责：

- 承载未来 `axvisor_api` 的最小导入落点
- 为后面如果真的需要把 API trait/类型也拉进 Linux 构建体系做准备

## 5. 第一轮推荐步骤

### 第一步

先只新增目录与空模块：

```text
drivers/virt/axvisor/vendor/
  mod.rs
  axvisor_core/mod.rs
  axvisor_api/mod.rs
```

目标：

- 先把 Linux 侧“未来 vendoring/导入位置”固定下来

当前状态：

- 已创建：
  - `drivers/virt/axvisor/vendor/mod.rs`
  - `drivers/virt/axvisor/vendor/axvisor_core/mod.rs`
  - `drivers/virt/axvisor/vendor/axvisor_core/boot.rs`
  - `drivers/virt/axvisor/vendor/axvisor_core/vmm/mod.rs`
  - `drivers/virt/axvisor/vendor/axvisor_core/vmm/timer.rs`
  - `drivers/virt/axvisor/vendor/axvisor_core/arch/mod.rs`
  - `drivers/virt/axvisor/vendor/axvisor_core/arch/riscv64.rs`
  - `drivers/virt/axvisor/vendor/axvisor_api/mod.rs`

### 第二步

让：

- `boot_axvisor_core_entry.rs`

开始只依赖这层 `vendor/` 模块，而不是直接假设未来去 `use axvisor_core`

目标：

- 把“真实 crate 是否可见”问题，集中到 `vendor/` 层

当前状态：

- `boot_axvisor_core_entry.rs` 当前已经显式依赖：
  - `vendor::axvisor_core::boot::run`
- 也就是说 runtime 这条线已经开始走 `vendor/` 边界，而不是继续停留在完全孤立的占位函数上

进一步说，当前 `vendor::axvisor_core` 这层已经开始对齐三条真实目标路径：

- `vendor::axvisor_core::boot::run`
- `vendor::axvisor_core::vmm::timer::check_events`
- `vendor::axvisor_core::arch::riscv64::inject_current_interrupt`

并且这三条路径现在都已经被整理成统一结构：

- `public bridge fn`
- `single entry resolver fn`
- `single fallback fn`

也就是说，后续真正接线时，Linux 侧只需要把各自的 `*_entry()` 从 fallback 切换到真实 `axvisor_core::*` 即可，不需要再改外层 `core_link` 或 adapter 主流程。

### 第三步

再决定 `vendor/axvisor_core/mod.rs` 走哪条路：

1. 最小 shim
2. 分阶段 vendor
3. 真实外部 crate 接线

## 6. 当前不建议的事

当前不建议：

- 直接在 `boot_axvisor_core_entry.rs` 里写大量临时 `cfg` / 注释式导入逻辑
- 在 `axvisor_adapter_main.rs` 里直接处理 crate 可见性
- 一步到位把 timer / irq 的可见性也一起做
- 在没有固定 `vendor/` 目录前，开始大规模搬 tgoskits 代码

## 7. 当前最推荐的下一步

最推荐的下一步是：

1. 新建 `drivers/virt/axvisor/vendor/`
2. 先放：
   - `mod.rs`
   - `axvisor_core/mod.rs`
   - `axvisor_api/mod.rs`
3. 让 runtime 这条线先知道：
   - 未来真实 crate 的导入层就在 `vendor/`

这样做的目的不是马上可运行，而是先把“可见性问题”固定到一个可控边界里。 
