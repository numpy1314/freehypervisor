# AxVisor Linux Vendor 清理计划

本文档只讨论：

- 已经复制到 Linux 树里的 `vendor/upstream` 与 `vendor/registry` 源码副本
- 哪些文件大概率不是后续构建接线必需的
- 哪些文件当前先不要动

## 1. 为什么现在先做清理计划

当前我们已经把两类来源的源码带进来了：

- `vendor/upstream/*`
- `vendor/registry/*`

这一步已经完成了“源码从哪里来”的问题。

接下来如果马上开始接构建，而源码树里仍然混着：

- `.git`
- `.github`
- `tests`
- `examples`
- `scripts`
- `Cargo.lock`
- 各类 CI / 文档辅助文件

后面会有两个问题：

1. 树会越来越乱，难以判断哪些文件真的参与构建。
2. 后续如果需要做最小 vendoring，很难回头再统一裁剪。

所以现在更合适的动作是：

- 先形成一份明确的清理清单
- 然后再按清单执行

## 2. 当前来源分层

### 2.1 `vendor/upstream/`

这里存的是：

- tgoskits workspace 里的上游 crate 副本

### 2.2 `vendor/registry/`

这里存的是：

- cargo registry / git checkout 的第三方 crate 副本

当前尤其要注意：

- `vendor/registry/riscv/` 是从 git checkout 复制过来的
- 里面带了完整 `.git/` 目录

## 3. 第一类：大概率可删

这类文件通常不参与后续 Linux 内核 Rust 构建。

### 3.1 版本控制与元数据

- `.git/`
- `.cargo-ok`
- `.cargo_vcs_info.json`

### 3.2 CI / 仓库托管配置

- `.github/`
- `ci/`

### 3.3 测试与示例

- `tests/`
- `examples/`
- `test_crates/`

### 3.4 辅助脚本

- `scripts/`
- `check-blobs.sh`
- `assemble.sh`
- `assemble.ps1`

### 3.5 锁文件与格式化配置

- `Cargo.lock`
- `rustfmt.toml`
- `.rustfmt.toml`

### 3.6 仓库说明类文件

- `CHANGELOG.md`
- `CODE_OF_CONDUCT.md`
- `.gitignore`
- 多语言 README 的非必要副本

注意：

- `README.md` 是否保留可以后面再决定
- 但 `README_CN.md`、`README.zh-cn.md`、`README_EN.md` 这类大概率可以统一删掉

## 4. 第二类：当前先保留

这类文件虽然不是 Rust 源码本身，但当前不建议先删。

### 4.1 `Cargo.toml`

必须保留。

### 4.2 `Cargo.toml.orig`

registry crate 里经常有。

当前建议：

- 先保留
- 后面如果已经完全不需要对照原始依赖信息，再删

### 4.3 `build.rs`

必须保留，直到明确不再需要。

### 4.4 架构相关汇编 / 数据文件

例如：

- `*.S`
- `*.a`
- `descriptor/*`
- `templates/*`
- 链接脚本或测试链接脚本

当前先不要删。

原因：

- 我们还没把构建接线真正跑起来
- 这些文件里有些可能是 build.rs 或架构实现间接依赖的

## 5. 当前最需要优先清理的点

如果后面按风险最低的顺序做清理，建议优先：

1. `vendor/registry/riscv/.git/`
2. 所有 `.github/`
3. 所有 `tests/`
4. 所有 `examples/`
5. 所有 `ci/` 与 `scripts/`
6. 所有 `Cargo.lock`

这是因为这些文件最不可能参与内核 Rust 编译主路径。

## 6. 当前观察到的典型噪音

### 6.1 `vendor/registry/riscv`

目前包含：

- `.git/`
- `.github/`
- `ci/`
- `bin/`
- `descriptor/`

其中最明显的立即噪音是：

- `.git/`

但 `bin/` 与 `descriptor/` 当前先别删。

### 6.2 `vendor/registry/sbi-spec`

目前包含：

- `examples/`
- `Cargo.lock`
- `.cargo_vcs_info.json`

### 6.3 `vendor/registry/rustsbi`

目前包含：

- `examples/`
- `tests/`
- `Cargo.lock`

### 6.4 `vendor/upstream/*`

普遍包含：

- `.github/`
- `tests/`
- `scripts/`
- `CHANGELOG.md`
- 各类多语言 README

## 7. 推荐执行顺序

建议后续真正执行清理时按下面顺序：

1. 先删纯版本控制与元数据
2. 再删 CI / tests / examples
3. 再评估 `scripts/`
4. 最后才处理 `README*` 与文档类文件

这样风险最低。

## 8. 当前最重要的结论

现在已经不适合继续无差别复制更多 crate。

当前更高价值的动作是：

1. 按本文清单做一次低风险清理
2. 然后开始把已落位 crate 转成真正的构建接线方案

## 9. 当前已完成的低风险清理

当前已经实际完成：

### 9.1 已删除目录

- 所有 `.github/`
- 所有 `tests/`
- 所有 `examples/`
- 所有 `ci/`
- `vendor/registry/riscv/.git/`

### 9.2 已删除文件

- 所有 `Cargo.lock`
- 所有 `.cargo-ok`
- 所有 `.cargo_vcs_info.json`

### 9.3 当前刻意保留

为了不影响后续构建验证，当前仍然保留：

- `build.rs`
- `scripts/`
- `descriptor/`
- `templates/`
- `bin/`
- 架构相关 `*.S`
- `Cargo.toml.orig`

也就是说，本轮清理已经把最明显的仓库噪音清掉了，但还没有开始动可能影响构建的边缘文件。
