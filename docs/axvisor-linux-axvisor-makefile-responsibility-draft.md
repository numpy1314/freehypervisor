# AxVisor Linux `drivers/virt/axvisor/Makefile` 责任草案

本文档用于明确：

- `linux-host-kernel/drivers/virt/axvisor/Makefile`
  将来应该承担哪些责任
- 哪些东西仍然借用 `linux-host-kernel/rust/Makefile`
- 哪些产物应该由 AxVisor 子目录自己声明

目标不是马上把完整规则写进去，而是先固定职责边界。

## 1. 当前状态

当前文件：

- `linux-host-kernel/drivers/virt/axvisor/Makefile`

只有很小的职责：

- 声明 `axvisor_adapter.o`
- 由：
  - `axvisor_adapter_main.o`
  - `axvisor_adapter_shim.o`
  组成

也就是说，当前它只处理：

- adapter module 自己的对象文件

完全没有处理：

- AxVisor 额外 Rust crate 产物
- host-side proc-macro `rlib`
- AxVisor 自己的 proc-macro 动态库

## 2. 未来职责应分成两层

建议把这个 Makefile 的职责理解成两层。

### 2.1 模块对象层

继续负责：

- `axvisor_adapter.o`
- 模块内 Rust/C shim 的组合关系

### 2.2 AxVisor 附加产物层

新增负责：

- AxVisor 自己声明的 host-side `rlib` 产物
- AxVisor 自己声明的 proc-macro 动态库产物
- 后续 runtime 最小普通 crate 的中间产物依赖链

## 3. 哪些公共能力不应该在这里重复定义

下面这些能力不应在 `axvisor/Makefile` 里重新实现一遍：

- `rustc_procmacrolibrary`
- `rustc_procmacro`
- `libproc_macro2.rlib`
- `libquote.rlib`
- `libsyn.rlib`

原因：

- 它们已经在：
  - `linux-host-kernel/rust/Makefile`
  里存在

正确思路应是：

- AxVisor 侧只声明“我要哪些产物、它们依赖谁”
- 真正的公共编译模型尽量借现有 Rust-for-Linux 规则

## 4. AxVisor Makefile 应该显式声明的第一批产物

第一批建议只覆盖 proc-macro 阶段。

### 4.1 新增 host-side `rlib`

建议未来由 AxVisor 侧显式声明：

- `libcfg_if.rlib`
- `libequivalent.rlib`
- `libmemchr.rlib`
- `libhashbrown.rlib`
- `libindexmap.rlib`
- `libwinnow.rlib`
- `libtoml_edit.rlib`
- `libproc_macro_crate.rlib`

### 4.2 新增 proc-macro 动态库

建议未来由 AxVisor 侧显式声明：

- `libax_crate_interface.<ext>`
- `libax_percpu_macros.<ext>`
- `libaxvisor_api_proc.<ext>`

## 5. 第一阶段的推荐承接方式

建议第一阶段不要试图把所有规则都塞进一个大块里。

推荐把 AxVisor Makefile 的承接方式分三步。

### 5.1 第一步：只声明产物集合

也就是先只回答：

- AxVisor 这一侧有哪些新产物
- 它们是 `always-*` 还是对象依赖

### 5.2 第二步：只声明依赖顺序

例如：

- `libindexmap.rlib` 依赖
  - `libequivalent.rlib`
  - `libhashbrown.rlib`
- `libtoml_edit.rlib` 依赖
  - `libindexmap.rlib`
  - `libwinnow.rlib`
- `libproc_macro_crate.rlib` 依赖
  - `libtoml_edit.rlib`
- `libaxvisor_api_proc.<ext>` 依赖
  - `libproc_macro_crate.rlib`
  - `libproc_macro2.rlib`
  - `libquote.rlib`
  - `libsyn.rlib`

### 5.3 第三步：再决定规则实现放哪

到这一步再决定：

- 这些规则是继续留在 `axvisor/Makefile`
- 还是提炼成 Rust 公共规则的局部复用层

## 6. 为什么不直接改 `rust/Makefile`

当前不建议一开始就把 AxVisor 特定规则直接堆进：

- `linux-host-kernel/rust/Makefile`

原因：

1. AxVisor 仍然是一个特定子系统，而不是全局 Rust 公共能力
2. 当前还在摸索它自己的 crate 链
3. 先把责任封在 `drivers/virt/axvisor/` 更容易收敛

所以当前更好的边界是：

- 公共编译命令模型继续留在 `rust/Makefile`
- AxVisor 自己的产物与依赖声明优先留在 `axvisor/Makefile`

## 7. 第一轮应该长什么样

从责任角度，第一轮最理想的 `axvisor/Makefile` 不是完整实现版，而是：

1. 保留现有模块对象定义
2. 新增一组“AxVisor proc-macro 阶段产物声明”
3. 新增一组“依赖顺序声明”
4. 暂时不把 runtime 普通 crate 一次性全塞进去

## 8. 第一轮不该承担什么

第一轮里，这个 Makefile 不应该同时承担：

- `axvisor_core/build.rs`
- runtime 全链路普通 crate
- timer / IRQ 真路径接线
- guest image 生成

原因：

- 这些都超出了当前 proc-macro 阶段的控制范围

## 9. 当前建议的实际推进顺序

下一步如果继续进入 Makefile 设计，建议顺序是：

1. 在文档层写出“第一批新增产物清单”
2. 再写“第一批依赖顺序清单”
3. 然后才决定要不要开始把最小规则真写进 `axvisor/Makefile`

## 10. 当前结论

现在可以把 `axvisor/Makefile` 的未来职责定成一句话：

- 它不负责重新定义 Rust 公共编译模型，但负责声明 AxVisor 自己需要的附加 crate 产物与依赖链

这一定义一旦固定，后面把 proc-macro 规则从草案变成真实实现就会顺很多。
