# AxVisor Linux 缺失 Proc-Macro 依赖清单

本文档只回答一件事：

- 当前 `proc-macro` 阶段到底还缺哪些依赖目录
- 这些依赖从哪里来
- 它们各自会继续带出什么风险

## 1. 当前已经确认缺失的两个关键目录

当前 `linux-host-kernel/drivers/virt/axvisor/vendor/` 下还没有：

- `cfg-if`
- `proc-macro-crate`

它们分别服务于：

- `ax-percpu-macros` 以及一大批普通 crate
- `axvisor_api_proc`

## 2. `cfg-if`

### 2.1 当前用途

`cfg-if` 不只是 `ax-percpu-macros` 会用，当前已经暴露出来的依赖点还包括：

- `ax-kernel-guard`
- `ax-kspin`
- `ax-percpu`
- `axaddrspace`
- `axdevice`
- `axvm`
- `riscv_vcpu`

所以它不是一个“只为宏阶段补一下”的小依赖，而是：

- 后续 runtime / virtualization 普通链也会反复用到的公共基础 crate

### 2.2 本机可复用来源

当前本机已经能看到多个 `cfg-if` vendor 副本，例如：

- `/home/bullet1517/allocator/vendor/cfg-if`
- `/home/bullet1517/arm-gic-driver/vendor/cfg-if`
- `/home/bullet1517/kernel_elf_parser/vendor/cfg-if`
- `/home/bullet1517/kspin/vendor/cfg-if`
- `/home/bullet1517/lwext4/vendor/cfg-if`

### 2.3 当前观察到的版本

已检查样本：

- `/home/bullet1517/allocator/vendor/cfg-if/Cargo.toml`

版本为：

- `1.0.3`

并且：

- `build = false`
- 基本无额外传递依赖

### 2.4 结论

`cfg-if` 是低风险可补依赖。

当前更像是：

- 目录还没搬进 AxVisor vendor 区

而不是：

- 依赖链本身存在很大技术不确定性

## 3. `proc-macro-crate`

### 3.1 当前用途

`proc-macro-crate` 当前直接只在这里暴露出来：

- `vendor/upstream/axvisor_api_proc/Cargo.toml`

也就是说，它当前的第一服务对象是：

- `axvisor_api_proc`

### 3.2 本机现状

当前在 `/home/bullet1517` 范围内，没有直接找到现成的：

- `proc-macro-crate/`

目录副本。

这说明：

- 它不像 `cfg-if` 一样能直接从本机现有其他仓库平移

### 3.3 当前已知风险

`proc-macro-crate` 最大的问题不是它自己，而是它后面的链。

根据前面依赖推断，至少要预期继续带出：

- `toml_edit`
- `indexmap`
- `equivalent`
- `winnow`
- `memchr`

以及可能的：

- `hashbrown`

### 3.4 当前本机已看到的可复用副本

虽然没找到 `proc-macro-crate` 本体，但已经找到若干后续依赖的 vendor 副本：

- `/home/bullet1517/arm-gic-driver/vendor/toml_edit`
- `/home/bullet1517/arm-gic-driver/vendor/indexmap`
- `/home/bullet1517/arm-gic-driver/vendor/equivalent`
- `/home/bullet1517/arm-gic-driver/vendor/winnow`
- `/home/bullet1517/allocator/vendor/memchr`

### 3.5 对这些后续依赖的初步判断

#### `equivalent`

特点：

- 很轻
- `build = false`
- 基本可视为低风险基础依赖

#### `memchr`

特点：

- `build = false`
- 默认 feature 带 `std`
- 如果后续通过 `winnow` 引入，要留意 feature 裁剪

#### `winnow`

特点：

- 默认 feature 是 `std`
- `memchr` 是 optional
- 如果只服务 `toml_edit parse` 路径，需要精确控制 feature

#### `indexmap`

特点：

- 依赖：
  - `equivalent`
  - `hashbrown`
- 默认 feature 是 `std`

这说明它不是单点依赖，还会继续把 `hashbrown` 带进来。

#### `toml_edit`

特点：

- 默认 feature：
  - `parse`
  - `display`
- 依赖：
  - `indexmap`
  - `winnow`
- 若启用 `serde`，还会继续放大

这说明它是这条链里最该小心控制 feature 的节点。

## 4. 目前可以下的判断

### 4.1 `cfg-if`

结论：

- 可以视为“直接补目录即可”的低风险依赖

### 4.2 `proc-macro-crate`

结论：

- 本体来源仍未落位
- 但它后面的依赖放大链已经基本可见

### 4.3 真正的不确定点

当前最大不确定点已经不是：

- `cfg-if`

而是：

- `proc-macro-crate` 本体如何引入
- 引入后要不要把 `toml_edit/indexmap/winnow` 一整条链一起补进 AxVisor vendor 区

## 5. 下一步最合理的动作

接下来最合理的顺序应当是：

1. 先把 `cfg-if` 列为可直接补入项
2. 再单独寻找或准备 `proc-macro-crate` 本体来源
3. 一旦 `proc-macro-crate` 本体确定，再一起冻结它的传递依赖名单

在这之前，不建议直接开始写最终构建规则。
