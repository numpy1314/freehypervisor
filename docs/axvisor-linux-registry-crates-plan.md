# AxVisor Linux Registry Crates Plan

本文档只讨论一类依赖：

- 不属于 tgoskits workspace
- 而是来自本机 cargo registry cache 的第三方 crate

目前已经明确会影响 RISC-V 路径的包括：

- `riscv`
- `riscv-decode`
- `rustsbi`
- `sbi-rt`
- `sbi-spec`

## 1. 为什么要单独分层

到目前为止，我们一直在 `vendor/upstream/` 下落位：

- `axvisor_core`
- `axvisor_api`
- `axvm`
- `riscv_vcpu`
- 以及它们的 tgoskits 依赖

但从 `riscv_vcpu` 继续往下展开后，已经出现了另一类来源：

- crates.io registry crates

这类依赖如果继续混到 `vendor/upstream/` 里，会把来源搞乱。

因此 Linux 侧建议再单独加一层：

```text
linux-host-kernel/drivers/virt/axvisor/vendor/registry/
```

## 2. 当前建议的第一批 registry crate

### 2.1 RISC-V ISA / CSR 路径

- `riscv`
- `riscv-decode`

### 2.2 SBI 路径

- `rustsbi`
- `sbi-rt`
- `sbi-spec`

## 3. 已确认的本机来源

这些 crate 当前都能在本机 cargo cache 找到。

### 3.1 `riscv`

本机既有 registry 版本，也有 git checkout 版本。

当前更接近 AxVisor 路径的来源是：

- `~/.cargo/git/checkouts/riscv-ab2abd16c438337b/11d43cf/`

原因：

- tgoskits 当前 workspace 里 `riscv` 走的是 workspace 依赖
- 本机存在对应 git checkout

### 3.2 `riscv-decode`

可从 registry 或 git checkout 获取。

### 3.3 `rustsbi / sbi-rt / sbi-spec`

当前来源位于本机 cargo registry cache。

## 4. 目录建议

建议在 `vendor/registry/` 下按 crate 名字平铺：

```text
vendor/registry/
  riscv/
  riscv-decode/
  rustsbi/
  sbi-rt/
  sbi-spec/
```

## 5. 当前建议顺序

后续如果继续沿 RISC-V 线推进，建议顺序是：

1. `riscv`
2. `sbi-spec`
3. `sbi-rt`
4. `rustsbi`
5. `riscv-decode`

原因：

- `riscv` 和 `sbi-*` 是更基础的寄存器/SBI 层
- `rustsbi`、`riscv-decode` 则更偏上层或特定路径

## 6. 当前进展

当前已经在 Linux 树中落位：

- `vendor/registry/riscv`
- `vendor/registry/sbi-spec`
- `vendor/registry/sbi-rt`
- `vendor/registry/rustsbi`
- `vendor/registry/riscv-decode`

这意味着：

- RISC-V 路线最核心的 registry 侧 crate 已经有本地源码副本
- 当前阶段的主要问题已经逐步从“源码从哪里来”转向“后续怎样裁剪和怎样接构建”

## 7. 当前剩余注意点

当前 registry 侧还留有两类后续工作：

1. 清理非必要文件
   - 例如 `.git`、测试、examples、辅助脚本、`Cargo.lock`
2. 继续补它们自己的下一层 registry 依赖
   - 例如 `rustsbi-macros`
   - 例如 `riscv-target`
   - 以及 `bare-metal`、`bitflags`、`bit_field` 这类更底层第三方 crate

但这些已经是“继续展开 registry 依赖树”的问题，不再是 AxVisor 主链本身的第一层缺口。

当前建议先不要急着继续复制更多 registry crate，而是先参考：

- `docs/axvisor-linux-vendor-cleanup-plan.md`

把已经复制进来的源码树做一次低风险清理准备。

当前这轮低风险清理已经完成。
