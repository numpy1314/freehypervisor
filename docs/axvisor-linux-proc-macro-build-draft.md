# AxVisor Linux Proc-Macro 构建规则草案

本文档用于给 AxVisor Linux 侧的 3 个 proc-macro crate 写第一版构建规则草案。

目标不是立刻改 `Makefile`，而是先把下面几件事固定下来：

- 每个 crate 的输入路径
- 每个 crate 的输出产物
- 每个 crate 需要的 `--extern`
- 编译先后顺序
- 哪些公共规则可直接借用 Linux 现有 `rust/Makefile`

## 1. 当前范围

本草案只覆盖这 3 个 proc-macro crate：

1. `ax-crate-interface`
2. `ax-percpu-macros`
3. `axvisor_api_proc`

以及为它们服务的 host-side 普通 `rlib`：

- `proc_macro2`
- `quote`
- `syn`
- `cfg-if`
- `proc-macro-crate`
- `toml_edit`
- `indexmap`
- `equivalent`
- `winnow`
- `memchr`
- `hashbrown`

## 2. 公共规则来源

AxVisor 侧不需要重新发明 proc-macro 编译模型。

当前可以直接借鉴：

- `linux-host-kernel/rust/Makefile`

里现有的两类规则：

### 2.1 host-side 普通 `rlib`

参考：

- `rustc_procmacrolibrary`

适用对象：

- `cfg-if`
- `proc-macro-crate`
- `toml_edit`
- `indexmap`
- `equivalent`
- `winnow`
- `memchr`
- `hashbrown`

### 2.2 真正的 proc-macro 动态库

参考：

- `rustc_procmacro`

适用对象：

- `ax-crate-interface`
- `ax-percpu-macros`
- `axvisor_api_proc`

## 3. 产物分层

建议把 AxVisor 侧 proc-macro 阶段分成三层产物。

## 3.1 第一层：Linux 已有公共宏基础产物

这一层当前 Linux `rust/Makefile` 已提供：

- `libproc_macro2.rlib`
- `libquote.rlib`
- `libsyn.rlib`

当前建议：

- 直接复用 Linux 已有产物与规则
- 不在 AxVisor 侧重复造一份同名基础库

## 3.2 第二层：AxVisor 新增 host-side `rlib`

这一层由 AxVisor 自己新增：

- `libcfg_if.rlib`
- `libproc_macro_crate.rlib`
- `libequivalent.rlib`
- `libhashbrown.rlib`
- `libindexmap.rlib`
- `libmemchr.rlib`
- `libwinnow.rlib`
- `libtoml_edit.rlib`

## 3.3 第三层：AxVisor proc-macro 动态库

这一层对应：

- `libax_crate_interface.<ext>`
- `libax_percpu_macros.<ext>`
- `libaxvisor_api_proc.<ext>`

其中 `<ext>` 应沿用 Linux `proc-macro` 的动态库扩展名推导方式。

## 4. 逐个 crate 草案

## 4.1 `ax-crate-interface`

### 输入

- 源目录：
  - `linux-host-kernel/drivers/virt/axvisor/vendor/upstream/ax-crate-interface/`
- 入口：
  - `src/lib.rs`

### 类型

- `proc-macro`

### 直接依赖

- `proc_macro2`
- `quote`
- `syn`

### 建议 `--extern`

- `--extern proc_macro`
- `--extern proc_macro2`
- `--extern quote`
- `--extern syn`

### 建议产物

- `libax_crate_interface.<ext>`

### 编译顺序要求

必须晚于：

- `libproc_macro2.rlib`
- `libquote.rlib`
- `libsyn.rlib`

## 4.2 `ax-percpu-macros`

### 输入

- 源目录：
  - `linux-host-kernel/drivers/virt/axvisor/vendor/upstream/ax-percpu-macros/`
- 入口：
  - `src/lib.rs`

### 类型

- `proc-macro`

### 直接依赖

- `cfg-if`
- `proc_macro2`
- `quote`
- `syn`

### 建议 `--extern`

- `--extern proc_macro`
- `--extern cfg_if`
- `--extern proc_macro2`
- `--extern quote`
- `--extern syn`

### 建议产物

- `libax_percpu_macros.<ext>`

### 编译顺序要求

必须晚于：

- `libcfg_if.rlib`
- `libproc_macro2.rlib`
- `libquote.rlib`
- `libsyn.rlib`

### 当前 feature 策略

当前先不在构建草案阶段展开所有 feature，只先保留“后续可传递”的能力：

- `sp-naive`
- `preempt`
- `arm-el2`
- `non-zero-vma`
- `custom-base`

但第一版规则里，先以：

- 无额外 feature

作为基础目标更稳妥。

## 4.3 `axvisor_api_proc`

### 输入

- 源目录：
  - `linux-host-kernel/drivers/virt/axvisor/vendor/upstream/axvisor_api_proc/`
- 入口：
  - `src/lib.rs`

### 类型

- `proc-macro`

### 直接依赖

- `proc_macro2`
- `proc-macro-crate`
- `quote`
- `syn`

### 建议 `--extern`

- `--extern proc_macro`
- `--extern proc_macro2`
- `--extern proc_macro_crate`
- `--extern quote`
- `--extern syn`

### 建议产物

- `libaxvisor_api_proc.<ext>`

### 编译顺序要求

必须晚于：

- `libproc_macro_crate.rlib`
- `libproc_macro2.rlib`
- `libquote.rlib`
- `libsyn.rlib`

## 5. 新增 host-side `rlib` 草案

## 5.1 `cfg-if`

### 类型

- 普通 host-side `rlib`

### 输入

- `vendor/registry/cfg-if/src/lib.rs`

### 建议产物

- `libcfg_if.rlib`

### 建议依赖

- 无新增 `--extern`

## 5.2 `equivalent`

### 类型

- 普通 host-side `rlib`

### 建议产物

- `libequivalent.rlib`

### 建议依赖

- 无新增 `--extern`

## 5.3 `hashbrown`

### 类型

- 普通 host-side `rlib`

### 建议产物

- `libhashbrown.rlib`

### 建议依赖

- `--extern equivalent`

### 备注

后续要严格关心 feature。

第一版草案应避免默认 feature 全开带来的额外膨胀。

## 5.4 `indexmap`

### 类型

- 普通 host-side `rlib`

### 建议产物

- `libindexmap.rlib`

### 建议依赖

- `--extern equivalent`
- `--extern hashbrown`

## 5.5 `memchr`

### 类型

- 普通 host-side `rlib`

### 建议产物

- `libmemchr.rlib`

### 建议依赖

- 无新增 `--extern`

## 5.6 `winnow`

### 类型

- 普通 host-side `rlib`

### 建议产物

- `libwinnow.rlib`

### 建议依赖

- `--extern memchr`

### 备注

第一版要围绕：

- `toml_edit parse`

这一用途控制 feature，不要默认把 debug 相关链也带进来。

## 5.7 `toml_edit`

### 类型

- 普通 host-side `rlib`

### 建议产物

- `libtoml_edit.rlib`

### 建议依赖

- `--extern indexmap`
- `--extern winnow`

### 备注

必须匹配：

- `proc-macro-crate 3.5.0`

的期望语义：

- `default-features = false`
- `features = ["parse"]`

## 5.8 `proc-macro-crate`

### 类型

- 普通 host-side `rlib`

### 建议产物

- `libproc_macro_crate.rlib`

### 建议依赖

- `--extern toml_edit`

## 6. 第一版编译顺序建议

按最小闭环，顺序建议如下：

### 第 1 组：Linux 已有公共基础

1. `libproc_macro2.rlib`
2. `libquote.rlib`
3. `libsyn.rlib`

### 第 2 组：AxVisor 新增普通 host-side `rlib`

4. `libcfg_if.rlib`
5. `libequivalent.rlib`
6. `libmemchr.rlib`
7. `libhashbrown.rlib`
8. `libindexmap.rlib`
9. `libwinnow.rlib`
10. `libtoml_edit.rlib`
11. `libproc_macro_crate.rlib`

### 第 3 组：AxVisor proc-macro 动态库

12. `libax_crate_interface.<ext>`
13. `libax_percpu_macros.<ext>`
14. `libaxvisor_api_proc.<ext>`

## 7. 当前草案阶段还不做的事

当前这份草案先不处理：

1. 普通 runtime crate 的最终规则
2. `axvisor_api` 的最终规则
3. `ax-percpu` 的最终规则
4. `axvisor_core` 的最终规则
5. `build.rs` 相关规则

原因：

- 当前只服务 proc-macro 阶段闭环

## 8. 这份草案接下来怎么用

这份草案下一步应该直接服务两件事：

1. 写 `drivers/virt/axvisor/Makefile` 的责任草案
2. 决定 AxVisor 新增 host-side `rlib` 规则到底放在哪里

也就是说：

- 现在已经可以进入“构建文件设计”阶段
- 不需要再回到依赖名单层面反复讨论
