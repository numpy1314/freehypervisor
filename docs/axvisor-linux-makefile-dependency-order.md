# AxVisor Linux Makefile 第一批依赖顺序清单

本文档承接“第一批产物清单”，只回答一件事：

- 如果从 `Makefile` 视角看，第一批新增产物之间应该按什么顺序依赖

当前仍然只覆盖：

- proc-macro 阶段

## 1. 顶层顺序

建议把第一批顺序固定成三层：

### 第一层：Linux 已有公共基础

1. `libproc_macro2.rlib`
2. `libquote.rlib`
3. `libsyn.rlib`

### 第二层：AxVisor 新增 host-side `rlib`

4. `libcfg_if.rlib`
5. `libequivalent.rlib`
6. `libmemchr.rlib`
7. `libhashbrown.rlib`
8. `libindexmap.rlib`
9. `libwinnow.rlib`
10. `libtoml_edit.rlib`
11. `libproc_macro_crate.rlib`

### 第三层：AxVisor proc-macro 动态库

12. `libax_crate_interface.<ext>`
13. `libax_percpu_macros.<ext>`
14. `libaxvisor_api_proc.<ext>`

## 2. 逐项依赖关系

## 2.1 Linux 已有公共基础

### `libproc_macro2.rlib`

- 无 AxVisor 侧新增前置

### `libquote.rlib`

依赖：

- `libproc_macro2.rlib`

### `libsyn.rlib`

依赖：

- `libproc_macro2.rlib`
- `libquote.rlib`

## 2.2 AxVisor 新增 host-side `rlib`

### `libcfg_if.rlib`

- 无新增前置

### `libequivalent.rlib`

- 无新增前置

### `libmemchr.rlib`

- 无新增前置

### `libhashbrown.rlib`

依赖：

- `libequivalent.rlib`

说明：

- 后续真实规则里要注意 feature 裁剪
- 但第一批依赖关系里，先只保留这一条显式边

### `libindexmap.rlib`

依赖：

- `libequivalent.rlib`
- `libhashbrown.rlib`

### `libwinnow.rlib`

依赖：

- `libmemchr.rlib`

### `libtoml_edit.rlib`

依赖：

- `libindexmap.rlib`
- `libwinnow.rlib`

说明：

- 这里要匹配 `proc-macro-crate 3.5.0` 所需语义：
  - `default-features = false`
  - `features = ["parse"]`

### `libproc_macro_crate.rlib`

依赖：

- `libtoml_edit.rlib`

## 2.3 AxVisor proc-macro 动态库

### `libax_crate_interface.<ext>`

依赖：

- `libproc_macro2.rlib`
- `libquote.rlib`
- `libsyn.rlib`

### `libax_percpu_macros.<ext>`

依赖：

- `libcfg_if.rlib`
- `libproc_macro2.rlib`
- `libquote.rlib`
- `libsyn.rlib`

### `libaxvisor_api_proc.<ext>`

依赖：

- `libproc_macro_crate.rlib`
- `libproc_macro2.rlib`
- `libquote.rlib`
- `libsyn.rlib`

## 3. 为什么这个顺序足够开始写规则

因为现在对于第一批产物，已经同时明确了：

1. 它们是什么
2. 它们属于哪一层
3. 它们各自依赖谁

也就是说：

- 已经不再缺“概念分析”
- 现在缺的只是“把这套关系翻译成 Makefile 语法”

## 4. 当前阶段刻意不处理的依赖

下面这些暂时不在这张顺序表里展开：

- `serde`
- `toml_datetime`
- `serde_spanned`
- `toml_write`
- `allocator-api2`
- `foldhash`

原因：

- 当前只服务 `proc-macro-crate 3.5.0` 的最小 parse 链
- 不是在写完整通用 Cargo 解析器

## 5. 下一步

这张表的直接下一步就是：

- 把这套依赖关系翻译成 `axvisor/Makefile` 的第一版草案变量与目标关系

也就是说：

- 现在已经到了可以写最小 `Makefile` 草案片段的时候
