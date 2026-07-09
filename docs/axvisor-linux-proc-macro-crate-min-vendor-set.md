# AxVisor Linux `proc-macro-crate 3.x` 最小 Vendor 名单

本文档用于冻结：

- `axvisor_api_proc`
  所需的 `proc-macro-crate 3.x` 最小 vendor 集合

目的不是列所有可能依赖，而是明确：

- 哪些目录是“必须搬进 AxVisor vendor 区”的
- 哪些依赖当前可以先不纳入

## 1. 结论先行

对于当前：

- `axvisor_api_proc`
- `proc-macro-crate = "3.1.0"`

这一需求，按本机已确认的 `3.5.0` 线来看，最小 vendor 集合应先冻结为：

1. `proc-macro-crate`
2. `toml_edit`
3. `indexmap`
4. `equivalent`
5. `winnow`
6. `memchr`
7. `hashbrown`

## 2. 为什么是这 7 个

## 2.1 第一层

`axvisor_api_proc` 直接依赖：

- `proc-macro-crate`

而 `proc-macro-crate 3.5.0` 当前直接依赖：

- `toml_edit = { version = "0.25.0", default-features = false, features = ["parse"] }`

所以第一层最少必须有：

- `proc-macro-crate`
- `toml_edit`

## 2.2 第二层

`toml_edit` 在只开 `parse`、关掉默认 feature 的情况下，最关键的下游依赖是：

- `indexmap`
- `winnow`

说明：

- `display`
  对应的 `toml_write` 当前不是最小闭环的一部分
- `serde`
  对应的 `serde_spanned/toml_datetime/serde`
  当前也不是最小闭环的一部分

所以第二层最少要有：

- `indexmap`
- `winnow`

## 2.3 第三层

`indexmap` 当前依赖：

- `equivalent`
- `hashbrown`

所以第三层最少要有：

- `equivalent`
- `hashbrown`

## 2.4 第四层

`winnow` 当前默认 feature 是 `std`，而 `memchr` 是 optional。

但在 `toml_edit parse` 路径下：

- `winnow` 是 parse 实现的重要组成
- `memchr` 需要被视作最小 vendor 集中的候选依赖一起冻结

所以第四层把：

- `memchr`

一起纳入，能避免后面规则草案阶段再补尾巴。

## 3. 当前明确不在“最小集合”里的依赖

下面这些依赖当前先不纳入最小 vendor 集合：

- `toml_write`
- `toml_datetime`
- `serde_spanned`
- `serde`
- `kstring`
- `anstream`
- `anstyle`
- `is_terminal_polyfill`
- `terminal_size`
- `foldhash`
- `allocator-api2`

原因不是它们永远不会出现，而是：

- 就当前 `proc-macro-crate 3.x`
- `toml_edit` 只开 `parse`

这一目标下，它们不应成为第一轮最小闭环的必须项

## 4. 当前各依赖的来源情况

## 4.1 已确认有本机来源

### `proc-macro-crate`

来源：

- `/home/bullet1517/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/proc-macro-crate-3.5.0`

### `cfg-if`

虽然不在本 7 个里，但它属于 proc-macro 阶段的另一个直接缺口。

来源：

- `/home/bullet1517/allocator/vendor/cfg-if`

### `toml_edit`

来源：

- `/home/bullet1517/arm-gic-driver/vendor/toml_edit`

### `indexmap`

来源：

- `/home/bullet1517/arm-gic-driver/vendor/indexmap`

### `equivalent`

来源：

- `/home/bullet1517/arm-gic-driver/vendor/equivalent`

### `winnow`

来源：

- `/home/bullet1517/arm-gic-driver/vendor/winnow`

### `memchr`

来源：

- `/home/bullet1517/allocator/vendor/memchr`

### `hashbrown`

来源：

- `/home/bullet1517/arm-gic-driver/vendor/hashbrown`

## 5. 当前最重要的技术约束

这个最小集合虽然已经冻结，但还要注意两个现实问题：

### 5.1 版本不一定完全一致

例如：

- `proc-macro-crate` 当前是 `3.5.0`
- `toml_edit` 本机现成副本是 `0.22.27`

而 `proc-macro-crate 3.5.0` 期望的是：

- `toml_edit 0.25.x`

这说明：

- “有来源”不等于“版本就已经匹配”

### 5.2 feature 必须控制

例如：

- `proc-macro-crate` 对 `toml_edit` 只开 `parse`
- `toml_edit` 默认 feature 还会带 `display`
- `winnow` 默认 feature 还会带 `std`
- `indexmap` 默认 feature 也是 `std`

这说明：

- 后续写构建规则时，不能只看目录是否在
- 还必须精确控制 feature 语义

## 6. 这份名单的用途

这份最小 vendor 名单的用途是：

1. 冻结第一轮必须补入的依赖目录集合
2. 给后续 proc-macro 构建规则草案提供输入
3. 避免还没写规则前就无限扩大依赖范围

## 7. 下一步应该做什么

有了这份名单后，下一步最合理的是：

1. 单独核对这 7 个依赖的版本兼容性
2. 标出哪些目录可直接复用本机副本
3. 标出哪些必须换成 Cargo registry 中的更匹配版本
4. 再写 AxVisor 侧 proc-macro build 规则草案

当前判断：

- 现在最该做的是第 1 步和第 3 步
- 因为“目录是否存在”已经不是主问题，真正的问题变成了“版本是否匹配”
