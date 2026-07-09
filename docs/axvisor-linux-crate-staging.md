# AxVisor Linux Crate 分阶段接入方案

本文档只回答一个问题：

- `axvisor_core / axvisor_api` 以及它们的第一批依赖，如何进入 Linux kernel Rust 的可见域

这里不讨论 30 个接口语义本身，也不讨论最终 guest 跑通，只讨论“先把真实 crate 接进来”的分阶段路径。

## 1. 当前事实

根据 Asterinas 侧 `aster-axvisor-host` 当前依赖：

- `axvisor_core`
- `axvisor_api`
- `ax-percpu`
- `ax-errno`
- `spin`
- 以及 Asterinas 专属：
  - `ostd`
  - `aster-console`
  - `aster-logger`
  - `aster-time`

其中 Linux 侧当前已经自己实现或半实现了 Asterinas host glue，因此：

- `ostd`
- `aster-console`
- `aster-logger`
- `aster-time`

这四个不应该作为第一批 Linux 接入目标。

Linux 第一批真正应该考虑的是：

1. `axvisor_api`
2. `axvisor_core`
3. `ax-percpu`
4. `ax-errno`
5. `spin`

补充修正：

- 上面这 5 个更适合看作“入口级核心 crate”
- 如果按 `axvisor_core` 的真实 `Cargo.toml` 展开，runtime 第一轮真正要覆盖的依赖会比这 5 个更多
- 这一点已经单独整理在：
  - `docs/axvisor-linux-runtime-import-plan.md`

## 2. 为什么不是先整包搬 `aster-axvisor-host`

原因很直接：

- `aster-axvisor-host` 本身就是 Asterinas 专用 host glue
- 它把 AxVisor 需要的 host trait 实现绑定在 `ostd/aster-*` 语义上
- Linux 侧已经在 `drivers/virt/axvisor/axvisor_adapter_main.rs` 中重新做了一套 Linux glue

所以 Linux 侧应该做的是：

- 重用 `axvisor_core / axvisor_api` 这类“上层 hypervisor crate”
- 不重用 `aster-axvisor-host` 这类“Asterinas 专用宿主 glue crate”

## 3. 三条主路径对应的最小 crate 需求

### 3.1 runtime 路径

目标调用：

- `axvisor_core::boot::run()`

最小需要：

- `axvisor_core`
- `axvisor_api`
- `ax-percpu`
- `ax-errno`
- `spin`

注意：

- 这里的“最小需要”是入口级表达，方便先排主顺序
- 不等于真实可运行依赖闭环已经只有这 5 个
- 真实展开后的 runtime 依赖请看：
  - `docs/axvisor-linux-runtime-import-plan.md`

这是第一优先级，因为：

- runtime 路径已经有完整接线形状
- 当前 Linux 侧缺的是“真实 crate 可见性”，不是调用点结构

### 3.2 timer 路径

目标调用：

- `axvisor_core::vmm::timer::check_events()`

最小需要：

- 至少 runtime 那批 crate 已可见
- 并且 `axvisor_core` 内部 timer 相关子模块能被一起编进来

额外要求：

- Linux 侧 timer callback 语义要和 AxVisor 预期兼容
- 当前 adapter 里的 `AxvisorTimerEventContext` 只是 Linux glue 侧上下文，不是 `axvisor_core` 的真实输入参数

所以 timer 不应作为第一批独立接入目标，而应跟在 runtime 后面。

### 3.3 external IRQ 路径

目标调用：

- `axvisor_core::arch::riscv64::inject_current_interrupt(irq_id)`

最小需要：

- runtime 那批 crate 已可见
- timer 路径已基本打通

额外要求：

- Linux 侧必须先拿到真实 pending external `irq_id`
- 还要确认注入时机和当前 vcpu/guest 上下文可达

所以 external IRQ 是第三优先级，不能和 runtime 同时推进。

## 4. 推荐的分阶段接入顺序

### 阶段 0

只保留当前目录边界，不改构建：

- `core_link/`
- `vendor/`
- `axvisor_core_stub.rs`

这个阶段已经完成。

### 阶段 1

先让 `vendor::axvisor_core::boot::run` 背后能看到一个真实 `axvisor_core`

目标：

- 只打通 runtime
- 不要求 timer/irq 同时切换

此阶段的最小成功标准：

- Linux Rust 构建里可以出现 `--extern axvisor_core`
- `vendor/axvisor_core/boot.rs` 不再只能走 fallback

### 阶段 2

把 `axvisor_api` 一起纳入 Linux Rust 可见域

原因：

- 虽然 Linux adapter 现在手写了 30 个接口实现
- 但后面真实 `axvisor_core` 进入以后，通常仍需要它看到自己预期的 API crate

此阶段的最小成功标准：

- Linux Rust 构建里可以出现 `--extern axvisor_api`
- `vendor/axvisor_core` 内部不再完全依赖本地占位命名层

### 阶段 3

补 `ax-percpu / ax-errno / spin`

原因：

- 这几个是 `axvisor_core` 更接近真实运行时必需的底层依赖
- 特别是 `ax-percpu`，Asterinas 侧 RISC-V timer 路径已经明确使用

此阶段的最小成功标准：

- `axvisor_core` 的 runtime 入口不再因为缺基础依赖而只能停在占位层

### 阶段 4

再切 timer 路径。

### 阶段 5

最后切 external IRQ 路径。

## 5. Linux 侧推荐目录职责

当前推荐保持：

```text
drivers/virt/axvisor/
  axvisor_adapter_main.rs
  axvisor_core_stub.rs
  core_link/
  vendor/
```

其中：

- `axvisor_adapter_main.rs`
  - 不处理真实 crate 导入
- `core_link/`
  - 不直接承载大规模依赖接入
- `vendor/`
  - 承载真实 crate 可见性过渡

因此第一批 crate 接入时，最应该改的是：

- `drivers/virt/axvisor/vendor/`

而不是：

- `axvisor_adapter_main.rs`
- `core_link/*.rs`

## 6. 推荐的第一批具体改动顺序

后续真正动代码时，建议严格按下面顺序推进：

1. 先让 Linux Rust 构建能声明 `axvisor_core`
2. 只改 `vendor/axvisor_core/boot.rs`
3. 再让 `core_link/boot_vendor_bridge.rs` 从 fallback 切到真实入口
4. 保持 `timer/irq` 仍然走 fallback
5. 再引入 `axvisor_api`
6. 再补 `ax-percpu / ax-errno / spin`
7. 最后才处理 `timer/irq`

这样做的原因是：

- runtime 是最短闭环
- timer 依赖运行时与回调语义
- irq 还依赖真实 `irq_id`

## 7. 当前阻塞点总结

当前真正的阻塞不是“30 个接口还没写”。

30 个接口的 Linux 侧骨架已经齐了。

当前真正阻塞是这三类：

1. Linux kernel Rust 还看不到 `axvisor_core / axvisor_api`
2. `axvisor_core` 的第一批底层依赖还没进 Linux 可见域
3. external IRQ 还没有真实 `irq_id` 来源

## 8. 下一步最合适的动作

下一步最合适的动作不是编译，而是继续把“第一批 crate 具体怎么挂进 Linux Rust 构建”落成代码旁边的构建草案：

- `drivers/virt/axvisor/Makefile` 需要什么形状
- `rust/Makefile` 需要新增什么 `--extern`
- 第一批 crate 先引哪几个，按什么顺序引

这一步做完之后，再开始真正改构建文件会更稳。

这部分草案已经单独整理在：

- `docs/axvisor-linux-build-integration-draft.md`
