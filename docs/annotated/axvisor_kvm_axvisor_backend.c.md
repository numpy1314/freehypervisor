# `axvisor_kvm_axvisor_backend.c` 逐函数精讲

## 文件总览

### 角色

本文件是接到 **AxVisor 本体**的**内建后端胶水层（built-in backend bridge）**。文件头注释（第 2-8 行）点明分工：

- **C 层（本文件）** 拥有 Linux 面的后端 ops 表（`struct axvisor_kvm_backend_ops axvisor_backend_ops`，第 383-400 行），负责把 Linux UAPI 结构（`kvm_regs`/`kvm_sregs`/`kvm_cpuid_entry2`/`kvm_msr_entry`/`kvm_fpu`/`kvm_xsave` 等）**拆解成标量字段**。
- **Rust 层**拥有真正的 AxVM/vCPU 状态，通过一组 `axvisor_kvm_rs_*` 符号暴露实现；当 Rust 被链接进 `axvisor_kvm.ko` 时这些符号才存在。

因此本文件是 **C↔Rust ABI 边界**：它把每个 backend op 翻译成对 `axvisor_kvm_rs_*` 的调用，并且刻意保持 ABI **scalar-only**（只传标量、指针+长度，不传 Linux UAPI struct，见第 240-243 行注释）。

### 在分派体系里的位置

- 上游：`axvisor_kvm_backend.c` 的转发函数通过 `axvisor_backend_ops` 里的函数指针调到本文件的 `axvisor_backend_*` 静态函数。
- 本层：每个 `axvisor_backend_*` 检查对应的弱符号 `axvisor_kvm_rs_*` 是否存在、拆解结构体，然后调用 Rust。
- 下游：Rust no_std AxVM 实现。

### 暴露/依赖的符号

- **依赖（Rust 侧，全部 `extern ... __weak`，第 21-84 行）**：约 25 个 `axvisor_kvm_rs_*` 函数指针。`__weak` 表示 Rust 未链接时它们为 NULL，C 层据此降级。
- **依赖（本层 API）**：`axvisor_kvm_backend_register/_unregister`（来自 `axvisor_kvm_backend.c`）。
- **提供（强符号，覆盖弱桩）**：`axvisor_kvm_builtin_backend_init` / `_exit`（第 402-435 行）。
- **提供（诊断，非 static）**：`axvisor_kvm_axvisor_backend_dbg_backend_rip`（第 361-366 行）。
- **内部状态**：`axvisor_kvm_axvisor_backend_registered`（第 86 行）、`axvisor_kvm_boot_mutex`（第 87 行）。

---

## 逐函数讲解

### 序言与 Rust 符号声明（第 10-84 行）

- 第 10 行统一 `pr_fmt` 前缀。
- 第 21-82 行是**完整的 C↔Rust ABI 契约**：每个 `extern ... __weak` 声明一个 Rust 侧函数。注意 ABI 风格——例如 `set_vm_state`（第 25-29 行）不接收 `struct`，而是逐字段展开为 `version/arch/irqchip_created/pit_created/...` 加 `const u64 *ioapic_redirtbl` + count；`set_vcpu_state`（第 39-43 行）、`set_vcpu_regs`（第 44-47 行，19 个寄存器逐个传）、`set_vcpu_segment`（第 55-58 行，段的每个属性位逐个传）同理。这种"scalar-only"约定让 Rust 侧无需知道 Linux UAPI 的内存布局。
- 第 75-77 行 `axvisor_kvm_rs_run_vcpu` 的 ABI 值得注意：出参是 `reason/width/addr/data/hardware_entry_failure_reason` 五个标量指针——**不含寄存器回流**（这正是 MEMORY 中记录的 GET_REGS 回流缺口的 ABI 层根源）。
- 第 83-84 行 `axvisor_kvm_rs_dbg_backend_rip` 是 task#99 的只读诊断符号，用于取后端 VMX 最后一次 exit 的 guest RIP。

### `axvisor_kvm_rs_backend_available`（第 89-97 行）

判断 Rust 后端是否**足够完整**可用。第 91-96 行把一组**核心**弱符号做逻辑与：init/exit、create/destroy vm、map_page(+nolog)、unmap_range、create/destroy vcpu、boot_vm、run_vcpu 全部非 NULL 才返回 true。注意它只检查核心集合——像 `set_vcpu_regs`、`set_vcpu_fpu` 等可选符号在各自使用点单独判空（体现"能力探测"式设计）。

### `axvisor_backend_create_vm` / `destroy_vm`（第 99-107 行）

最薄的一对包装，直接转调 `axvisor_kvm_rs_create_vm` / `_destroy_vm`。

### `axvisor_backend_set_vm_state`（第 109-133 行）——VM 状态拆解

- 第 112-113 行准备 ioapic 重定向表出参（默认 NULL/0）。
- 第 115-118 行防御：Rust 符号缺失返回 `-EOPNOTSUPP`，state 为空返回 `-EINVAL`。
- 第 120-126 行 `#ifdef CONFIG_X86_64`：仅 x86_64 且 `nr_irqchips > KVM_IRQCHIP_IOAPIC` 时，从 `state->irqchips[KVM_IRQCHIP_IOAPIC].chip.ioapic.redirtbl[0].bits` 取出 IOAPIC 重定向表首地址，count 设为 `KVM_IOAPIC_NUM_PINS`。这是把嵌套 UAPI 结构降为"指针+数量"的典型手法。
- 第 128-132 行一次性把所有字段展开传给 Rust；布尔字段用 `? 1 : 0` 归一化。

### `axvisor_backend_map_page` / `map_page_nolog` / `unmap_range`（第 135-150 行）

三个直通包装，分别转调对应 `axvisor_kvm_rs_*`。

### `axvisor_backend_create_vcpu` / `destroy_vcpu`（第 152-161 行）

薄包装，转调 Rust 的 create/destroy vcpu。

### `axvisor_backend_set_vcpu_state`（第 163-292 行）——最大的拆解函数

本文件的核心。它把一整套 vCPU 初始状态从 Linux UAPI struct 拆成对多个 Rust 函数的**分步、可选、带错误短路**的调用。

- 第 169-172 行防御：核心符号缺失 `-EOPNOTSUPP`，state 空 `-EINVAL`。
- **第 174-181 行 核心标量状态**：调用 `axvisor_kvm_rs_set_vcpu_state`，传 rip/rsp/rflags/cr0/cr3/cr4/efer/apic_base/xcr0/cpuid_nent/nmsrs/tsc_khz。失败即 `goto out`。这是所有后续步骤的前置。
- **第 183-194 行 通用寄存器（可选）**：仅当 `axvisor_kvm_rs_set_vcpu_regs` 存在且 `state->regs` 非空时，把 `struct kvm_regs` 的 19 个寄存器逐个展开传入。
- **第 196-238 行 sregs（系统寄存器，可选）**：当 `state->sregs` 存在时分三步：
  - 第 198-201 行先把 8 个段（cs/ds/es/fs/gs/ss/tr/ldt）组成 `segments[]` 数组指针表。
  - 第 203-210 行 `set_vcpu_sregs_control`：传控制寄存器 cr0/cr2/cr3/cr4/cr8/efer/apic_base。
  - 第 212-224 行**遍历 8 个段**，对每段调用 `set_vcpu_segment`，把段的 base/limit/selector/type/present/dpl/db/s/l/g/avl/unusable 全部位字段逐个传出（scalar-only 的极致体现），索引 `i` 作为 `segment_id`。
  - 第 226-237 行 `set_vcpu_dtable` 两次：`table_id=0` 传 GDT（base+limit），`table_id=1` 传 IDT。
  - 每一步都 `if (ret) goto out` 短路。
- **第 240-256 行 CPUID（可选）**：注释（第 240-243 行）明确声明"保持 C/Rust ABI scalar-only：Linux UAPI struct 留在 C 侧，后端只收稳定的逐字段项"。循环 `state->cpuid_nent` 次，每个 `kvm_cpuid_entry2` 拆成 function/index/flags/eax/ebx/ecx/edx 传入，索引作 `entry_index`。
- **第 258-267 行 MSR（可选）**：循环 `state->nmsrs` 次，逐个 MSR 传 index+data。
- **第 269-279 行 FPU（可选）**：需 `fpu_valid && state->fpu`。把 `struct kvm_fpu` 的 fcw/fsw/ftwx/last_opcode/last_ip/last_dp/mxcsr 标量 + `fpr`/`xmm` 两块字节缓冲区（`(const u8 *)` + `sizeof`）传给 Rust——数组以"指针+长度"传递。
- **第 281-288 行 XSAVE legacy（可选）**：需 `xsave_valid && state->xsave`，把 `state->xsave->region`（u32 数组）以指针 + `ARRAY_SIZE` 传出。
- 第 290-291 行 `out:` 统一返回 `ret`。

整个函数体现"一个 UAPI struct → 多个标量化 Rust 调用 + 逐步错误短路 + 逐能力探测"的 ABI 翻译范式。

### `axvisor_backend_get_vcpu_regs`（第 294-307 行）——回流方向

读回方向的包装。第 297-300 行防御（符号缺失/regs 空）。第 302-306 行把 `struct kvm_regs` 的 19 个字段**取地址**传给 Rust，由 Rust 写回。这是唯一把 C 结构字段地址批量交给 Rust 填充的路径。

### `axvisor_backend_boot_vm`（第 309-319 行）——串行化 + 禁迁移

引导 VM，有额外的执行环境处理：

- 第 313 行 `mutex_lock(&axvisor_kvm_boot_mutex)`：**串行化 boot**，同一时刻只允许一个 VM 引导。
- 第 314 行 `migrate_disable()`：禁止当前线程在 boot 期间被迁移到其他 CPU（保证 per-CPU 相关的后端初始化在同一物理核上完成）。
- 第 315 行调用 Rust `boot_vm`。
- 第 316-317 行按逆序 `migrate_enable()` + 解锁。

### `axvisor_backend_run_vcpu`（第 321-347 行）——运行 + ABI 出参回填

vCPU 运行路径，是 C↔Rust 运行时 ABI 的关键点。

- 第 324-329 行准备局部出参，`reason` 预置为 `AXKVM_BACKEND_EXIT_FAIL_ENTRY`（与上层的确定性 fail-entry 语义一致）。
- 第 331-332 行 exit 为空返回 `-EINVAL`。
- 第 334 行 `migrate_disable()`：**进入 guest 前钉住当前物理核**（VMX 状态与 pCPU 绑定，迁移会破坏 VMCS）。
- 第 335-336 行调用 `axvisor_kvm_rs_run_vcpu`，传入五个出参标量地址。
- 第 337 行 `migrate_enable()` 恢复迁移。
- 第 338-339 行 Rust 返回非 0（错误）时直接透传，不回填 exit。
- 第 341-346 行成功时把 reason/width/addr/data/hardware_entry_failure_reason 五个标量回填进 `struct axkvm_backend_exit`。注意此 ABI **不回流寄存器**，只回流退出摘要。

### `axvisor_backend_complete_mmio_read`（第 349-355 行）

MMIO 读补全包装，符号缺失 `-EOPNOTSUPP`，否则转调 Rust `complete_mmio_read`。

### `axvisor_kvm_axvisor_backend_dbg_backend_rip`（第 357-366 行）——诊断导出

task#99 的只读诊断函数（非 static，可被 C 层其他文件调用），用于取后端 VMX 最后一次 exit 的 guest RIP，和 `vcpu->regs.rip`（KVM_GET_REGS 的值）比对。第 363-364 行符号缺失返回 `-EOPNOTSUPP`，否则转调 Rust。注释注明"诊断完成后应删除"。

### `axvisor_backend_complete_io_read`（第 368-374 行）

Port I/O 读补全包装，与 MMIO 变体对称。

### `axvisor_backend_inject_irq`（第 376-381 行）

按 GSI 注入中断的包装，符号缺失 `-EOPNOTSUPP`，否则转调 Rust `inject_irq`。

### `axvisor_backend_ops` ops 表（第 383-400 行）——分派表定义

这是把上面所有 `axvisor_backend_*` 静态函数**绑定成一张函数指针表**的地方，也是 `axvisor_kvm_backend.c` 分派的实际目标：

- 第 384 行 `.owner = THIS_MODULE`：让上层的 `try_module_get`/`module_put` 能对本模块正确计数。
- 第 385-399 行 15 个 `.op = axvisor_backend_op` 赋值，逐一对应 backend 抽象层的 15 个转发函数。注意本表**未提供** `set_vcpu_regs` 等独立槽——这些能力是在 `set_vcpu_state` 内部按需调用 Rust 的，不作为顶层 ops。

### `axvisor_kvm_builtin_backend_init`（第 402-424 行）——强符号覆盖 + 注册

覆盖 `axvisor_kvm_backend.c` 的 `__weak` 桩，在模块初始化时被调用：

- 第 406-409 行先 `axvisor_kvm_rs_backend_available()` 探测：Rust 未链接则打印提示并**返回 0**（不算失败，保留 fail-entry 后端语义）。
- 第 411-413 行调用 Rust `backend_init`，失败即返回其错误码。
- 第 415-419 行 `axvisor_kvm_backend_register(&axvisor_backend_ops)` 注册 ops 表；注册失败时**回滚** Rust backend（调 `_exit`）后返回错误。
- 第 421-423 行置 `registered = true` 并打印成功日志。

### `axvisor_kvm_builtin_backend_exit`（第 426-435 行）——对称拆卸

- 第 428-429 行未注册则直接返回（幂等保护）。
- 第 431-433 行按逆序：`unregister` ops 表 → Rust `backend_exit` → 清 registered 标志。
- 第 434 行打印注销日志。

---

## 小结

本文件约 435 行，是 C↔Rust 的翻译与生命周期管理层。其两大主题：(1) **scalar-only ABI 翻译**——把 Linux UAPI struct（尤其 `set_vcpu_state` 的一整套 sregs/segments/cpuid/msr/fpu/xsave）逐字段拆成 `axvisor_kvm_rs_*` 调用，配合弱符号能力探测与逐步错误短路；(2) **执行环境保障**——`boot_vm`/`run_vcpu` 用 `migrate_disable` 钉核、`boot_vm` 用 mutex 串行化，并在 init/exit 用强符号覆盖弱桩完成后端注册/注销。
