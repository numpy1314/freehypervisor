# AxVisor Linux Rust 构建接入草案

本文档只讨论一件事：

- 后续如果把 `axvisor_core / axvisor_api` 真正接进 Linux kernel Rust 构建，构建层面应该长什么样

这里仍然不做实际构建修改，只先把改动点和顺序固定下来。

## 1. 当前确认到的事实

从 `linux-host-kernel/rust/Makefile` 可以明确看到：

- Linux Rust crate 之间就是通过 `--extern xxx` 连接
- `rustdoc-*`、`rusttestlib-*`、`rusttest-*` 都沿用这个模式
- 内核现有 Rust crate 并不是“不能额外接 crate”

因此，后续接入 `axvisor_core / axvisor_api` 的核心问题不是“Linux Rust 支不支持”，而是：

1. crate 源码放哪里
2. `.rlib` 怎么产出
3. `axvisor_adapter_main.rs` 所在模块怎么拿到对应 `--extern`

## 2. 当前本地 AxVisor 模块构建点

当前 AxVisor Linux 模块构建入口很简单：

```make
obj-$(CONFIG_AXVISOR_ADAPTER) += axvisor_adapter.o

axvisor_adapter-y := \
	axvisor_adapter_main.o \
	axvisor_adapter_shim.o
```

也就是说，现在 `drivers/virt/axvisor/Makefile` 只知道：

- 一个 Rust 主对象：`axvisor_adapter_main.o`
- 一个 C shim：`axvisor_adapter_shim.o`

这意味着后续如果要引额外 Rust crate，不能只改这个目录下 `Makefile` 的对象列表，还要解决：

- 这些 crate 自己怎么被编成 `.rlib`
- `axvisor_adapter_main.rs` 编译时如何拿到 `--extern axvisor_core`

## 3. 推荐分层

后续构建接入建议分两层看：

### 3.1 crate 产物层

职责：

- 让 `axvisor_core / axvisor_api / ax-percpu / ax-errno / spin` 先能在 Linux 构建树中产出可链接的 Rust crate 产物

建议理解为：

- “先能产出 `.rlib`”

### 3.2 模块使用层

职责：

- 让 `axvisor_adapter_main.rs` 这类模块 Rust 对象，在编译时拿到这些 crate 的 `--extern`

建议理解为：

- “再让当前 AxVisor adapter 用上这些 `.rlib`”

## 4. 推荐第一批 crate 顺序

后续真正改构建时，推荐顺序保持和 staging 文档一致：

1. `axvisor_core`
2. `axvisor_api`
3. `ax-percpu`
4. `ax-errno`
5. `spin`

其中 runtime 第一轮真正要先打通的，实际上是：

- `axvisor_core`

但为了让 `axvisor_core` 不停在半残可见状态，通常很快就要把下面几项一起补上：

- `axvisor_api`
- `ax-percpu`
- `ax-errno`
- `spin`

这里需要补一句：

- 这 5 个只是“入口级核心 crate”
- `axvisor_core` 的真实 runtime 直接依赖还会继续展开
- 详细展开结果见：
  - `docs/axvisor-linux-runtime-import-plan.md`

## 5. 推荐源码放置思路

这里先不决定最终一定采用哪一种，但从 Linux 侧可维护性看，推荐优先级如下：

### 方案 A：在 `drivers/virt/axvisor/vendor/` 下放 Linux 侧过渡源码

优点：

- 与当前 `vendor/` 目录语义一致
- 和 `core_link/` 边界清晰
- 不会把导入逻辑污染到 adapter 主文件

缺点：

- 如果后面变成整包 vendor，会有一次目录再整理

### 方案 B：在内核树单独开更通用的 Rust vendor 区

优点：

- 更接近“正式内核依赖”布局

缺点：

- 当前阶段过重
- 会把 AxVisor 的局部实验性工作扩成全局改动

当前阶段更推荐 A，不推荐一开始做 B。

## 6. 推荐的第一轮构建草案形状

第一轮只追求 runtime 最小可见性时，推荐目标形状可以理解为：

### 6.1 先有额外 crate 目标

例如在概念上增加：

- `axvisor_core.rlib`
- `axvisor_api.rlib`
- `ax_percpu.rlib`
- `ax_errno.rlib`
- `spin.rlib`

注意：

- 这里只是说明“应该有这样的构建产物概念”
- 不是说文件名和规则现在就照抄

### 6.2 再让 adapter 拿到 `--extern`

概念上，后续 `axvisor_adapter_main.rs` 所在 Rust 编译命令最终需要长成类似：

```text
--extern axvisor_core
--extern axvisor_api
--extern ax_percpu
--extern ax_errno
--extern spin
```

实际会不会第一轮就全加，取决于最小依赖裁剪结果。

## 7. 为什么不先改 `drivers/virt/axvisor/Makefile`

因为只改这个文件不够。

原因：

- 它只能描述本目录模块对象组成
- 它不负责凭空产出新的 Rust `.rlib`
- 真正的 crate 生成和 `--extern` 传播，还要看 `rust/Makefile` 级别的规则

所以正确顺序应该是：

1. 先决定 crate 放哪
2. 再决定 `.rlib` 怎么产出
3. 再决定模块如何消费这些 crate

而不是反过来先往 `drivers/virt/axvisor/Makefile` 里硬塞对象名。

## 8. 第一轮最小构建目标

第一轮不应该追求：

- 所有三条路径同时真实接线
- 所有依赖一次性进来
- 一次性让 timer/irq 也工作

第一轮只追求：

- `vendor::axvisor_core::boot::run`
  背后不再只是 fallback

也就是只服务于：

- runtime 路径

## 9. 推荐的后续实际落地顺序

### 第 1 步

把 `axvisor_core` 的 Linux 侧“源码放置位置”定下来。

当前推荐位置见：

- `docs/axvisor-linux-upstream-vendor-layout.md`

### 第 2 步

把 `axvisor_core` 编成 Linux 构建可见的 `.rlib`。

### 第 3 步

只给 runtime 路径加上：

- `--extern axvisor_core`

### 第 4 步

把 `vendor/axvisor_core/boot.rs` 的 fallback 替换成真实入口。

### 第 5 步

再补：

- `axvisor_api`
- `ax-percpu`
- `ax-errno`
- `spin`

### 第 6 步

最后才轮到：

- timer 真接线
- external IRQ 真接线

## 10. 当前最重要的结论

当前最重要的结论有三个：

1. Linux Rust 构建机制本身支持通过 `--extern` 组织额外 crate。
2. AxVisor 当前缺的不是 adapter 调用形状，而是 crate 产物和可见性。
3. 第一轮必须只盯 runtime，把构建接入范围压到最小。

更具体的第一轮接线顺序与最小 `--extern` 集合，已经单独整理在：

- `docs/axvisor-linux-build-wiring-checklist.md`
