# AxVisor Linux Makefile 第一批产物清单

本文档从 `Makefile` 视角列出：

- AxVisor 在第一阶段应新增哪些产物
- 这些产物是否属于 `always-*`
- 它们服务于哪个目标

当前只覆盖：

- proc-macro 阶段

不覆盖：

- runtime 普通 crate 全链
- `axvisor_core/build.rs`
- timer / IRQ 真路径

## 1. 当前已有产物

当前 `linux-host-kernel/drivers/virt/axvisor/Makefile` 已有：

- `axvisor_adapter.o`

其组成对象：

- `axvisor_adapter_main.o`
- `axvisor_adapter_shim.o`

这部分继续保留，不属于本次新增清单。

## 2. 第一批新增 host-side `rlib`

这批产物的作用是支撑 AxVisor 自己的 proc-macro 动态库。

建议第一批新增：

- `libcfg_if.rlib`
- `libequivalent.rlib`
- `libmemchr.rlib`
- `libhashbrown.rlib`
- `libindexmap.rlib`
- `libwinnow.rlib`
- `libtoml_edit.rlib`
- `libproc_macro_crate.rlib`

## 3. 第一批新增 proc-macro 动态库

这批产物是 AxVisor 自己真正要消费的宏 crate。

建议第一批新增：

- `libax_crate_interface.<ext>`
- `libax_percpu_macros.<ext>`
- `libaxvisor_api_proc.<ext>`

其中 `<ext>` 应沿用 Linux 当前 proc-macro 动态库扩展名推导方式。

## 4. 这些产物为什么属于第一批

因为后续这些 crate 都建在它们之上：

- `axvisor_api`
- `ax-percpu`

而 `axvisor_core::boot::run()` 又直接依赖：

- `axvisor_api`
- `ax-percpu`

所以如果不先把这批产物准备好，后面 runtime 最小链就无从谈起。

## 5. `Makefile` 视角的分组建议

建议在 `axvisor/Makefile` 里，把这批产物至少逻辑上分成三组。

### 5.1 公共基础组

这组不是 AxVisor 自己新增，但 AxVisor 依赖它们：

- `libproc_macro2.rlib`
- `libquote.rlib`
- `libsyn.rlib`

说明：

- 这组由 Linux `rust/Makefile` 提供
- AxVisor 侧只应依赖它们，不应重复定义它们

### 5.2 AxVisor 新增 host-side `rlib` 组

- `libcfg_if.rlib`
- `libequivalent.rlib`
- `libmemchr.rlib`
- `libhashbrown.rlib`
- `libindexmap.rlib`
- `libwinnow.rlib`
- `libtoml_edit.rlib`
- `libproc_macro_crate.rlib`

### 5.3 AxVisor proc-macro 组

- `libax_crate_interface.<ext>`
- `libax_percpu_macros.<ext>`
- `libaxvisor_api_proc.<ext>`

## 6. 这些产物在当前阶段应该怎么挂

第一阶段建议都视为：

- `always-*`

而不是直接混到模块对象列表里。

原因：

- 它们不是模块对象文件
- 它们是后续 Rust crate 解析要依赖的 host-side 编译产物

## 7. 当前不放进第一批的产物

当前明确不放进第一批：

- `axvisor_api`
- `ax-percpu`
- `axaddrspace`
- `axvm`
- `axvisor_core`

原因：

- 这些属于下一层普通 crate 接线阶段
- 当前先只收 proc-macro 闭环

## 8. 这张清单的用途

这张清单下一步直接服务：

1. 写依赖顺序清单
2. 决定 `axvisor/Makefile` 里第一批 `always-*` 变量该如何组织
